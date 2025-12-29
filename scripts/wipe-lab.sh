#!/run/current-system/sw/bin/bash
set -euo pipefail

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

PROFILE="${1:-}"
[[ -n "$PROFILE" ]] || die "Usage: sudo $0 <profile> (e.g. lab1)"

LIBVIRT_URI="${LIBVIRT_URI:-qemu:///system}"
DISK_DIR="${DISK_DIR:-/var/lib/libvirt/images}"
TALOS_STATE_ROOT="${TALOS_STATE_ROOT:-/var/lib/talos}"

ROOT="/etc/nixos/talos-host"
PROFILE_DIR="${ROOT}/profiles/${PROFILE}"
VARS_ENV="${PROFILE_DIR}/vars.env"
NODES_CSV="${PROFILE_DIR}/nodes.csv"

command -v virsh >/dev/null 2>&1 || die "virsh not found"
command -v awk >/dev/null 2>&1 || die "awk not found"
command -v tr  >/dev/null 2>&1 || die "tr not found"

[[ -f "$NODES_CSV" ]] || die "Missing nodes.csv: $NODES_CSV"

# Load profile vars (TALOS_*)
if [[ -f "$VARS_ENV" ]]; then
  # shellcheck disable=SC1090
  source "$VARS_ENV"
fi

NET_NAME="${TALOS_NET_NAME:-talosnet}"

# --- CSV parsing tolerant of column order ---
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

stop_services() {
  log "Stopping Talos services (if present)"
  systemctl stop talos-provision.service talos-bootstrap.service >/dev/null 2>&1 || true
  systemctl reset-failed talos-provision.service talos-bootstrap.service >/dev/null 2>&1 || true
}

wipe_vms_and_disks() {
  log "Wiping VMs + disks from nodes.csv for profile '${PROFILE}'"
  while IFS= read -r row; do
    local name
    name="$(csv_get "$row" name)"
    [[ -n "$name" ]] || continue

    if virsh --connect "$LIBVIRT_URI" dominfo "$name" >/dev/null 2>&1; then
      log "Destroying VM: $name"
      virsh --connect "$LIBVIRT_URI" destroy "$name" >/dev/null 2>&1 || true

      log "Undefining VM: $name (and NVRAM if any)"
      virsh --connect "$LIBVIRT_URI" undefine "$name" --nvram >/dev/null 2>&1 || \
        virsh --connect "$LIBVIRT_URI" undefine "$name" >/dev/null 2>&1 || true
    else
      log "VM not found (ok): $name"
    fi

    # Delete both naming conventions to be safe
    local d1="${DISK_DIR}/talos-${name}.qcow2"
    local d2="${DISK_DIR}/talos-talos-${name}.qcow2"
    if [[ -f "$d1" ]]; then log "Deleting disk: $d1"; rm -f "$d1"; fi
    if [[ -f "$d2" ]]; then log "Deleting disk: $d2"; rm -f "$d2"; fi
  done < <(csv_rows)
}

wipe_network_and_dnsmasq() {
  log "Wiping libvirt network '${NET_NAME}' (and dnsmasq state)"
  if virsh --connect "$LIBVIRT_URI" net-info "$NET_NAME" >/dev/null 2>&1; then
    local active
    active="$(virsh --connect "$LIBVIRT_URI" net-info "$NET_NAME" | awk -F': *' '/Active:/ {print $2}' || true)"
    if [[ "$active" == "yes" ]]; then
      log "Stopping network: $NET_NAME"
      virsh --connect "$LIBVIRT_URI" net-destroy "$NET_NAME" >/dev/null 2>&1 || true
    fi
    log "Undefining network: $NET_NAME"
    virsh --connect "$LIBVIRT_URI" net-undefine "$NET_NAME" >/dev/null 2>&1 || true
  else
    log "Network not found (ok): $NET_NAME"
  fi

  log "Removing dnsmasq lease/status files for ${NET_NAME}"
  rm -f "/var/lib/libvirt/dnsmasq/${NET_NAME}.leases" "/var/lib/libvirt/dnsmasq/${NET_NAME}.status" 2>/dev/null || true
  rm -f "/var/lib/libvirt/dnsmasq/${NET_NAME}.conf" 2>/dev/null || true

  log "Restarting libvirtd"
  systemctl restart libvirtd >/dev/null 2>&1 || systemctl restart libvirtd.service >/dev/null 2>&1 || true
}

wipe_talos_state_and_kubeconfig() {
  local state_dir
  state_dir="${TALOS_DIR:-${TALOS_STATE_ROOT}/${PROFILE}}"
  local kube
  kube="${KUBECONFIG_OUT:-/root/.kube/talos-${PROFILE}.config}"

  log "Removing Talos state dir: ${state_dir}"
  rm -rf "$state_dir"

  log "Removing kubeconfig: ${kube}"
  rm -f "$kube"

  if [[ -L /root/.kube/config ]]; then
    local target
    target="$(readlink -f /root/.kube/config || true)"
    if [[ "$target" == "$kube" ]]; then
      log "Removing /root/.kube/config symlink (it pointed to ${kube})"
      rm -f /root/.kube/config
    fi
  fi
}

summary() {
  log "Wipe completed for profile '${PROFILE}'."
  log "Next steps:"
  log "  sudo /etc/nixos/talos-host/scripts/talos-bootstrap.sh ${PROFILE}"
  log "  sudo /etc/nixos/talos-host/scripts/talos-provision.sh ${PROFILE}"
}

main() {
  csv_init
  stop_services
  wipe_vms_and_disks
  wipe_network_and_dnsmasq
  wipe_talos_state_and_kubeconfig
  summary
}

main "$@"
