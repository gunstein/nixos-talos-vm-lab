# =====================================================================
# FILE: /home/gunstein/nixos-talos-vm-lab/scripts/talos-provision.sh
# (rsync -> /etc/nixos/talos-host/scripts/talos-provision.sh)
# =====================================================================
#!/run/current-system/sw/bin/bash
set -euo pipefail

export PATH="/run/current-system/sw/bin:/run/wrappers/bin:${PATH:-}"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

require() { command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }
for c in talosctl awk tr nc grep sed sleep mktemp mkdir rm chmod ln virsh; do require "$c"; done

LIBVIRT_URI="${LIBVIRT_URI:-qemu:///system}"

ROOT="/etc/nixos/talos-host"
PROFILE_FILE="${ROOT}/PROFILE"

PROFILE="${1:-}"
if [[ -z "$PROFILE" ]]; then
  [[ -f "$PROFILE_FILE" ]] || die "Missing $PROFILE_FILE"
  PROFILE="$(cat "$PROFILE_FILE")"
fi

PROFILE_DIR="${ROOT}/profiles/${PROFILE}"
VARS_ENV="${PROFILE_DIR}/vars.env"
NODES_CSV="${PROFILE_DIR}/nodes.csv"
[[ -f "$NODES_CSV" ]] || die "Missing nodes.csv: $NODES_CSV"

if [[ -f "$VARS_ENV" ]]; then
  # shellcheck disable=SC1090
  source "$VARS_ENV"
fi

CLUSTER_NAME="${TALOS_CLUSTER_NAME:-talos-${PROFILE}}"
STATE_DIR="${TALOS_DIR:-/var/lib/talos-${PROFILE}}"
KUBECONFIG_OUT="${KUBECONFIG_OUT:-/root/.kube/talos-${PROFILE}.config}"

# THIS is the key bit for install-to-disk determinism:
INSTALL_DISK="${TALOS_INSTALL_DISK:-/dev/vda}"   # virtio disk is usually /dev/vda

CFG_DIR="${STATE_DIR}/generated"
NODECFG_DIR="${STATE_DIR}/node-configs"

mkdir -p "$CFG_DIR" "$NODECFG_DIR"
chmod 0700 "$STATE_DIR" || true

declare -A COL=()

csv_init() {
  local header
  header="$(head -n1 "$NODES_CSV" | tr -d '\r')"
  IFS=',' read -r -a cols <<<"$header"
  local i
  for i in "${!cols[@]}"; do
    COL["${cols[$i]}"]="$i"
  done
  for req in name role ip mac disk_gb ram_mb vcpus; do
    [[ -n "${COL[$req]:-}" ]] || die "nodes.csv missing required column: '$req' (header is: $header)"
  done
}

csv_rows() {
  tail -n +2 "$NODES_CSV" | while IFS= read -r line; do
    line="${line%$'\r'}"
    [[ -z "$line" ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    echo "$line"
  done
}

csv_get() {
  local line="$1" key="$2"
  IFS=',' read -r -a f <<<"$line"
  local idx="${COL[$key]}"
  echo "${f[$idx]}"
}

wait_port() {
  local ip="$1" port="$2" timeout="${3:-900}"
  local deadline=$((SECONDS + timeout))
  while (( SECONDS < deadline )); do
    if nc -vz "$ip" "$port" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}

first_controlplane_ip() {
  while IFS= read -r r; do
    if [[ "$(csv_get "$r" role)" == "controlplane" ]]; then
      echo "$(csv_get "$r" ip)"
      return 0
    fi
  done < <(csv_rows)
  return 1
}

talos_insecure_flag_for() {
  local cmd="$1"
  if talosctl "$cmd" --help 2>/dev/null | grep -q -- '--insecure-skip-verify'; then
    echo "--insecure-skip-verify"; return 0
  fi
  if talosctl "$cmd" --help 2>/dev/null | grep -q -- '--insecure'; then
    echo "--insecure"; return 0
  fi
  echo ""
}

talos_try() {
  local cmd="$1"; shift
  talosctl --talosconfig "${CFG_DIR}/talosconfig" "$cmd" "$@"
}

talos_try_insecure() {
  local cmd="$1"; shift
  local flag
  flag="$(talos_insecure_flag_for "$cmd")"
  [[ -n "$flag" ]] || return 127
  talosctl --talosconfig "${CFG_DIR}/talosconfig" "$cmd" "$flag" "$@"
}

talos_run_with_fallback() {
  local cmd="$1"; shift
  local tmp rc err
  tmp="$(mktemp)"
  if talos_try "$cmd" "$@" 2> "$tmp"; then
    rm -f "$tmp"; return 0
  fi
  rc=$?
  err="$(cat "$tmp" || true)"
  rm -f "$tmp"

  if echo "$err" | grep -qiE 'x509:|certificate|authentication handshake failed|unknown authority'; then
    local flag
    flag="$(talos_insecure_flag_for "$cmd")"
    if [[ -n "$flag" ]]; then
      log "Secure '${cmd}' failed due to TLS; retrying with ${flag}..."
      talos_try_insecure "$cmd" "$@"
      return $?
    fi
  fi

  echo "$err" >&2
  return $rc
}

talos_tls_ok() {
  local ip="$1"
  talosctl --talosconfig "${CFG_DIR}/talosconfig" version --nodes "$ip" --endpoints "$ip" >/dev/null 2>&1
}

wait_talos_tls_ok() {
  local ip="$1" timeout="${2:-600}"
  local deadline=$((SECONDS + timeout))
  while (( SECONDS < deadline )); do
    if talos_tls_ok "$ip"; then
      return 0
    fi
    sleep 2
  done
  return 1
}

gen_base_configs_if_missing() {
  local cp_ip="$1"
  if [[ -s "${CFG_DIR}/talosconfig" && -s "${CFG_DIR}/controlplane.yaml" && -s "${CFG_DIR}/worker.yaml" ]]; then
    log "Talos base configs already exist in ${CFG_DIR}."
    return 0
  fi

  log "Generating Talos base configs: cluster=${CLUSTER_NAME}, endpoint=https://${cp_ip}:6443"
  rm -f "${CFG_DIR}/talosconfig" "${CFG_DIR}/controlplane.yaml" "${CFG_DIR}/worker.yaml" || true
  (cd "$CFG_DIR" && talosctl gen config "$CLUSTER_NAME" "https://${cp_ip}:6443")

  [[ -s "${CFG_DIR}/talosconfig" ]] || die "talosconfig was not generated."
  [[ -s "${CFG_DIR}/controlplane.yaml" ]] || die "controlplane.yaml was not generated."
  [[ -s "${CFG_DIR}/worker.yaml" ]] || die "worker.yaml was not generated."
}

make_node_config() {
  local name="$1" role="$2" mac="$3"

  local base
  if [[ "$role" == "controlplane" ]]; then
    base="${CFG_DIR}/controlplane.yaml"
  else
    base="${CFG_DIR}/worker.yaml"
  fi

  local patch="${NODECFG_DIR}/${name}.patch.yaml"
  local out="${NODECFG_DIR}/${name}.yaml"

  # IMPORTANT:
  # - interface select by MAC
  # - FORCE install to disk (virtio -> /dev/vda by default)
  cat > "$patch" <<EOF
machine:
  install:
    disk: "${INSTALL_DISK}"
  network:
    interfaces:
      - deviceSelector:
          hardwareAddr: "${mac}"
        dhcp: true
EOF

  talosctl machineconfig patch "$base" --patch @"$patch" --output "$out" >/dev/null
  chmod 0600 "$patch" "$out"
  echo "$out"
}

# After Talos is installed and TLS works, we *must* stop booting ISO.
finalize_boot_from_disk() {
  local vm="$1"

  # Eject ISO (ignore errors)
  local tgt
  tgt="$(virsh --connect "$LIBVIRT_URI" domblklist "$vm" --details 2>/dev/null | awk '$3=="cdrom"{print $4; exit}' || true)"
  if [[ -n "$tgt" ]]; then
    log "Ejecting ISO from ${vm} (cdrom target ${tgt})"
    virsh --connect "$LIBVIRT_URI" change-media "$vm" "$tgt" --eject >/dev/null 2>&1 || true
  fi

  # Set boot order: hd first
  local tmp
  tmp="$(mktemp)"
  if ! virsh --connect "$LIBVIRT_URI" dumpxml --inactive "$vm" > "$tmp" 2>/dev/null; then
    virsh --connect "$LIBVIRT_URI" dumpxml "$vm" > "$tmp"
  fi
  sed -i "/<boot dev=/d" "$tmp"
  sed -i "0,/<os[^>]*>/s//&\n    <boot dev='hd'\/>\n    <boot dev='cdrom'\/>/" "$tmp"
  virsh --connect "$LIBVIRT_URI" define "$tmp" >/dev/null
  rm -f "$tmp"
}

restart_domain() {
  local vm="$1"
  log "Restarting ${vm} to ensure it boots from disk"
  virsh --connect "$LIBVIRT_URI" shutdown "$vm" >/dev/null 2>&1 || true
  sleep 2
  virsh --connect "$LIBVIRT_URI" destroy "$vm" >/dev/null 2>&1 || true
  virsh --connect "$LIBVIRT_URI" start "$vm" >/dev/null
}

apply_node_config() {
  local name="$1" role="$2" mac="$3" ip="$4"

  local cfg stamp
  cfg="$(make_node_config "$name" "$role" "$mac")"
  stamp="${STATE_DIR}/applied.${name}"

  log "Waiting for Talos API on ${ip}:50000 before apply-config..."
  wait_port "$ip" 50000 900 || die "Talos API not reachable on ${ip}:50000"

  log "Applying config to ${name} (${ip})"
  talosctl --talosconfig "${CFG_DIR}/talosconfig" apply-config \
    --insecure \
    --nodes "$ip" \
    --endpoints "$ip" \
    --file "$cfg"

  log "Waiting for Talos API to return on ${ip}:50000 after apply-config..."
  wait_port "$ip" 50000 1200 || die "Talos API did not come back on ${ip}:50000"

  log "Waiting for TLS to become valid on ${ip} (this can take time if it's installing to disk)..."
  if ! wait_talos_tls_ok "$ip" 900; then
    die "TLS still failing after apply-config on ${name} (${ip}). Most likely still booting ISO/maintenance or install to disk didn't happen (check INSTALL_DISK=${INSTALL_DISK})."
  fi

  # Now we are confident the node is using our generated CA -> stop booting ISO.
  finalize_boot_from_disk "$name"
  restart_domain "$name"

  # Wait for it to come back again after reboot-from-disk
  wait_port "$ip" 50000 1200 || die "Talos API did not come back after forcing disk boot: ${ip}:50000"
  wait_talos_tls_ok "$ip" 600 || die "TLS failed after forcing disk boot on ${name} (${ip})."

  touch "$stamp"
}

bootstrap_once() {
  local cp_ip="$1"
  local stamp="${STATE_DIR}/bootstrapped"
  if [[ -f "$stamp" ]]; then
    log "Cluster already bootstrapped (stamp exists)."
    return 0
  fi
  log "Bootstrapping etcd on ${cp_ip}"
  talos_run_with_fallback bootstrap --nodes "$cp_ip" --endpoints "$cp_ip"
  touch "$stamp"
}

write_kubeconfig() {
  local cp_ip="$1"
  mkdir -p /root/.kube
  chmod 0700 /root/.kube

  log "Writing kubeconfig to ${KUBECONFIG_OUT}"
  # Your talosctl expects kubeconfig output path as POSITIONAL arg.
  talos_run_with_fallback kubeconfig \
    "$KUBECONFIG_OUT" \
    --nodes "$cp_ip" \
    --endpoints "$cp_ip" \
    --force

  [[ -s "$KUBECONFIG_OUT" ]] || die "kubeconfig was not created: ${KUBECONFIG_OUT}"
  chmod 0600 "$KUBECONFIG_OUT"
  ln -sf "$KUBECONFIG_OUT" /root/.kube/config || true
}

main() {
  log "Provisioning Talos for profile '${PROFILE}'"
  csv_init

  local cp_ip
  cp_ip="$(first_controlplane_ip || true)"
  [[ -n "$cp_ip" ]] || die "No controlplane node found in nodes.csv"

  gen_base_configs_if_missing "$cp_ip"

  while IFS= read -r row; do
    local name role ip mac
    name="$(csv_get "$row" name)"
    role="$(csv_get "$row" role)"
    ip="$(csv_get "$row" ip)"
    mac="$(csv_get "$row" mac)"
    apply_node_config "$name" "$role" "$mac" "$ip"
  done < <(csv_rows)

  bootstrap_once "$cp_ip"
  write_kubeconfig "$cp_ip"

  log "Talos provision completed for profile '${PROFILE}'."
}

main "$@"
