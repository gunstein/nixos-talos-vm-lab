#!/run/current-system/sw/bin/bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/common.sh"

require_root "$@"
need talosctl
need mkdir
need awk
need nc
need sleep
need rm
need grep
need mktemp
need cp
need chmod
need chown
need getent
need cut
need id

# kubectl is optional but recommended; if missing we will warn and skip k8s readiness waits.
if command -v kubectl >/dev/null 2>&1; then
  HAVE_KUBECTL=1
else
  HAVE_KUBECTL=0
fi

load_profile "${1:-}"
csv_init

GEN_DIR="${TALOS_DIR}/generated"
mkdir -p "$GEN_DIR"

# Find first controlplane node (name + ip)
CP_IP=""
CP_NAME=""
while IFS= read -r row; do
  role="$(csv_get "$row" role)"
  if [[ "$role" == "controlplane" ]]; then
    CP_IP="$(csv_get "$row" ip)"
    CP_NAME="$(csv_get "$row" name)"
    break
  fi
done < <(csv_rows)
[[ -n "$CP_IP" && -n "$CP_NAME" ]] || die "No controlplane node found in nodes.csv (role=controlplane)"

talos_ok() {
  # Only true when Talos API is usable with our TALOSCONFIG (mTLS), not just port open
  talosctl --nodes "$1" --endpoints "$1" version >/dev/null 2>&1
}

wait_talos_ok() {
  local ip="$1" timeout_s="${2:-300}"
  local start now
  start="$(date +%s)"
  while true; do
    if talos_ok "$ip"; then
      return 0
    fi
    now="$(date +%s)"
    if (( now - start >= timeout_s )); then
      return 1
    fi
    sleep 2
  done
}

supports_flag() {
  local subcmd="$1" flag="$2"
  $subcmd --help 2>/dev/null | grep -q -- "$flag"
}

k8s_readyz_ok() {
  # returns 0 when apiserver returns "ok" on /readyz
  kubectl --kubeconfig "$KUBECONFIG_OUT" get --raw='/readyz' >/dev/null 2>&1
}

wait_k8s_readyz() {
  local timeout_s="${1:-600}"
  local start now
  start="$(date +%s)"
  while true; do
    if k8s_readyz_ok; then
      return 0
    fi
    now="$(date +%s)"
    if (( now - start >= timeout_s )); then
      return 1
    fi
    sleep 2
  done
}

node_ready_status() {
  # prints True/False/Unknown/empty
  kubectl --kubeconfig "$KUBECONFIG_OUT" get node "$1" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true
}

wait_node_ready() {
  local node="$1" timeout_s="${2:-600}"
  local start now st
  start="$(date +%s)"
  while true; do
    st="$(node_ready_status "$node")"
    if [[ "$st" == "True" ]]; then
      return 0
    fi
    now="$(date +%s)"
    if (( now - start >= timeout_s )); then
      return 1
    fi
    sleep 2
  done
}

# Patch to ensure install to disk in VM labs (metal installer ISO)
PATCH_FILE="$(mktemp)"
cat > "$PATCH_FILE" <<'EOF'
machine:
  install:
    disk: /dev/vda
EOF

log "Generating Talos configs in $GEN_DIR"
rm -f "$GEN_DIR"/{controlplane.yaml,worker.yaml,talosconfig} 2>/dev/null || true

if supports_flag "talosctl gen config" "--config-patch"; then
  talosctl gen config "$TALOS_CLUSTER_NAME" "https://${CP_IP}:6443" \
    --output-dir "$GEN_DIR" \
    --config-patch "@${PATCH_FILE}" >/dev/null
else
  log "WARN: talosctl gen config does not support --config-patch on this host."
  log "WARN: If installs become flaky, upgrade talosctl."
  talosctl gen config "$TALOS_CLUSTER_NAME" "https://${CP_IP}:6443" --output-dir "$GEN_DIR" >/dev/null
fi
rm -f "$PATCH_FILE"

export TALOSCONFIG="$GEN_DIR/talosconfig"

# Apply configs
while IFS= read -r row; do
  name="$(csv_get "$row" name)"
  role="$(csv_get "$row" role)"
  ip="$(csv_get "$row" ip)"

  log "Waiting for Talos port on ${name} ${ip}:50000"
  wait_port "$ip" 50000 300 || die "Talos API port not reachable on ${ip}:50000"

  cfg="$GEN_DIR/worker.yaml"
  [[ "$role" == "controlplane" ]] && cfg="$GEN_DIR/controlplane.yaml"

  log "Apply config -> ${name} (${ip})"
  talosctl apply-config --insecure --nodes "$ip" --file "$cfg" >/dev/null

  log "Waiting for Talos mTLS API to become ready on ${ip}"
  if ! wait_talos_ok "$ip" 420; then
    log "DEBUG: talosctl version:"
    talosctl --nodes "$ip" --endpoints "$ip" version || true
    die "Talos API did not become ready (mTLS) on ${ip} after apply-config"
  fi
done < <(csv_rows)

# Bootstrap with retries (API may flap briefly)
log "Bootstrap on ${CP_IP}"
for i in $(seq 1 120); do
  if talosctl bootstrap --nodes "$CP_IP" --endpoints "$CP_IP" >/dev/null 2>&1; then
    log "Bootstrap OK"
    break
  fi
  out="$(talosctl bootstrap --nodes "$CP_IP" --endpoints "$CP_IP" 2>&1 || true)"
  if echo "$out" | grep -qi "already"; then
    log "Bootstrap already done"
    break
  fi
  if (( i % 5 == 1 )); then
    log "bootstrap retry ${i}/120 -> ${out}"
  else
    log "bootstrap retry ${i}/120 (waiting) - sleep 2s"
  fi
  sleep 2
  [[ "$i" -lt 120 ]] || die "Bootstrap failed after retries"
done

# Write kubeconfig (Talos syntax: kubeconfig <local-path>)
mkdir -p "$(dirname "$KUBECONFIG_OUT")"
log "Writing kubeconfig to $KUBECONFIG_OUT"
talosctl kubeconfig "$KUBECONFIG_OUT" --nodes "$CP_IP" --endpoints "$CP_IP" --force >/dev/null
chmod 0600 "$KUBECONFIG_OUT" || true

# Make kubectl work WITHOUT manual exports:
mkdir -p /root/.kube
cp -f "$KUBECONFIG_OUT" /root/.kube/config
chmod 0600 /root/.kube/config || true

if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
  user_home="$(getent passwd "$SUDO_USER" | cut -d: -f6 || true)"
  user_group="$(id -gn "$SUDO_USER" 2>/dev/null || true)"
  if [[ -n "$user_home" && -d "$user_home" && -n "$user_group" ]]; then
    mkdir -p "${user_home}/.kube"
    cp -f "$KUBECONFIG_OUT" "${user_home}/.kube/config"
    cp -f "$KUBECONFIG_OUT" "${user_home}/.kube/${TALOS_CLUSTER_NAME}.config"
    chown "$SUDO_USER:$user_group" "${user_home}/.kube" "${user_home}/.kube/config" "${user_home}/.kube/${TALOS_CLUSTER_NAME}.config" || true
    chmod 0700 "${user_home}/.kube" || true
    chmod 0600 "${user_home}/.kube/config" "${user_home}/.kube/${TALOS_CLUSTER_NAME}.config" || true
    log "Also wrote kubeconfig for user ${SUDO_USER}: ${user_home}/.kube/config"
  else
    log "WARN: could not resolve home/group for SUDO_USER='${SUDO_USER}', skipped user kubeconfig copy."
  fi
fi

# ---- NEW: Wait until apiserver and node are actually ready ----
if [[ "$HAVE_KUBECTL" -eq 1 ]]; then
  log "Waiting for Kubernetes API (readyz) on https://${CP_IP}:6443"
  # Port can be briefly closed; readyz is the real signal.
  if ! wait_k8s_readyz 600; then
    log "WARN: Kubernetes API not ready within timeout. You can check with:"
    log "  kubectl --kubeconfig $KUBECONFIG_OUT get nodes"
  else
    log "Kubernetes API is ready."

    log "Waiting for node '${CP_NAME}' to become Ready=True"
    if wait_node_ready "$CP_NAME" 600; then
      log "Node is Ready."
    else
      st="$(node_ready_status "$CP_NAME")"
      log "WARN: node did not become Ready within timeout (current Ready=${st:-<unknown>})."
      log "You can inspect:"
      log "  kubectl get pods -A"
      log "  kubectl describe node ${CP_NAME}"
    fi
  fi
else
  log "WARN: kubectl not found on host. Skipping Kubernetes readiness waits."
  log "Tip: install kubectl or run:"
  log "  export KUBECONFIG=$KUBECONFIG_OUT"
  log "  kubectl get nodes"
fi

log "Kubeconfig ready."
log "Now this should work without exports:"
log "  kubectl get nodes"
