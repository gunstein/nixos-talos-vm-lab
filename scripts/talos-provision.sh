#!/run/current-system/sw/bin/bash
set -euo pipefail

# Talos cluster provisioning:
# - Generate Talos configs (controlplane + worker + talosconfig)
# - Apply configs
# - Bootstrap Kubernetes
# - Write kubeconfig (root + sudo user)
# - Install metrics-server from a vendored manifest (delete+apply overwrite)

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

require_root "$@"

need talosctl
need nc
need awk
need sed
need grep
need mktemp
need mkdir
need rm
need cp
need chmod
need chown
need getent
need cut
need id
need sleep

HAVE_KUBECTL=0
if command -v kubectl >/dev/null 2>&1; then
  HAVE_KUBECTL=1
fi

load_profile "${1:-}"
csv_init

GEN_DIR="${TALOS_DIR}/generated"
mkdir -p "$GEN_DIR"

# Repo root (assumes scripts/ is one level below repo root)
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# ---- find first controlplane node (name + ip) ----
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

# ---- talos helpers ----
talos_ok() {
  talosctl --nodes "$1" --endpoints "$1" version >/dev/null 2>&1
}

wait_talos_ok() {
  local ip="$1" timeout_s="${2:-420}"
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

# ---- kubernetes helpers ----
k8s_readyz_ok() {
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
  kubectl --kubeconfig "$KUBECONFIG_OUT" get node "$1" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true
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

# ---- metrics-server addon (overwrite strategy) ----
metrics_manifest_path() {
  echo "${REPO_ROOT}/k8s/addons/metrics-server.yaml"
}

metrics_diagnostics_short() {
  local kc="$KUBECONFIG_OUT"
  log "metrics-server status (short):"
  kubectl --kubeconfig "$kc" -n kube-system get pods -l k8s-app=metrics-server -o wide || true

  local pod
  pod="$(kubectl --kubeconfig "$kc" -n kube-system get pods -l k8s-app=metrics-server \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"

  if [[ -n "$pod" ]]; then
    log "metrics-server Events (describe pod/$pod, Events section only):"
    kubectl --kubeconfig "$kc" -n kube-system describe pod "$pod" 2>/dev/null \
      | awk 'BEGIN{p=0} /^Events:/{p=1} {if(p)print}' || true
  fi

  log "metrics-server logs (tail):"
  kubectl --kubeconfig "$kc" -n kube-system logs deploy/metrics-server --tail=120 || true
}

install_metrics_server_overwrite() {
  local kc="$KUBECONFIG_OUT"
  local manifest
  manifest="$(metrics_manifest_path)"

  [[ -f "$manifest" ]] || die "Missing metrics-server manifest: $manifest"

  log "Installing metrics-server (overwrite) from $manifest"
  kubectl --kubeconfig "$kc" delete -f "$manifest" --ignore-not-found >/dev/null 2>&1 || true
  kubectl --kubeconfig "$kc" apply -f "$manifest" >/dev/null

  if ! kubectl --kubeconfig "$kc" -n kube-system rollout status deploy/metrics-server --timeout=240s; then
    log "ERROR: metrics-server rollout failed"
    metrics_diagnostics_short
    return 1
  fi

  if ! kubectl --kubeconfig "$kc" wait --for=condition=Available --timeout=180s apiservice/v1beta1.metrics.k8s.io >/dev/null 2>&1; then
    log "ERROR: Metrics APIService not Available"
    metrics_diagnostics_short
    return 1
  fi

  log "metrics-server installed; Metrics API is Available"
}

# ---- generate talos configs ----
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
  log "WARN: talosctl gen config does not support --config-patch."
  talosctl gen config "$TALOS_CLUSTER_NAME" "https://${CP_IP}:6443" --output-dir "$GEN_DIR" >/dev/null
fi
rm -f "$PATCH_FILE"

export TALOSCONFIG="$GEN_DIR/talosconfig"

# ---- apply configs ----
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
  wait_talos_ok "$ip" 420 || die "Talos API did not become ready (mTLS) on ${ip} after apply-config"
done < <(csv_rows)

# ---- bootstrap ----
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
  sleep 2
  [[ "$i" -lt 120 ]] || die "Bootstrap failed after retries"
done

# ---- kubeconfig ----
mkdir -p "$(dirname "$KUBECONFIG_OUT")"
log "Writing kubeconfig to $KUBECONFIG_OUT"
talosctl kubeconfig "$KUBECONFIG_OUT" --nodes "$CP_IP" --endpoints "$CP_IP" --force >/dev/null
chmod 0600 "$KUBECONFIG_OUT" || true

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
  fi
fi

# ---- wait + addons ----
if [[ "$HAVE_KUBECTL" -eq 1 ]]; then
  log "Waiting for Kubernetes API (readyz) on https://${CP_IP}:6443"
  wait_k8s_readyz 600 || die "Kubernetes API not ready within timeout"

  log "Kubernetes API is ready."
  log "Waiting for node '${CP_NAME}' to become Ready=True"
  wait_node_ready "$CP_NAME" 600 || die "Node ${CP_NAME} did not become Ready within timeout"

  log "Node is Ready."

  if [[ "${METRICS_SERVER_ENABLE}" == "1" ]]; then
    install_metrics_server_overwrite || true
  else
    log "Skipping metrics-server install (METRICS_SERVER_ENABLE=0)"
  fi
else
  log "WARN: kubectl not found on host. Skipping addons."
fi

log "Done. Try:"
log "  kubectl top nodes"
log "  kubectl top pods -A"
