#!/run/current-system/sw/bin/bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/common.sh"

require_root "$@"
need virsh
need rm
need awk
need getent
need cut

load_profile "${1:-}"
csv_init

log "WIPING profile '$PROFILE' (VMs, disks, network, talos state, kubeconfig)"

# VMs + disks
while IFS= read -r row; do
  name="$(csv_get "$row" name)"
  disk="${DISK_DIR}/talos-${name}.qcow2"

  if virsh -c "$LIBVIRT_URI" dominfo "$name" >/dev/null 2>&1; then
    log "Destroy $name"
    virsh -c "$LIBVIRT_URI" destroy "$name" >/dev/null 2>&1 || true
    log "Undefine $name"
    virsh -c "$LIBVIRT_URI" undefine "$name" --remove-all-storage >/dev/null 2>&1 || true
  fi

  if [[ -f "$disk" ]]; then
    log "Delete disk $disk"
    rm -f "$disk"
  fi
done < <(csv_rows)

# Network
if virsh -c "$LIBVIRT_URI" net-info "$TALOS_NET_NAME" >/dev/null 2>&1; then
  log "Destroy network $TALOS_NET_NAME"
  virsh -c "$LIBVIRT_URI" net-destroy "$TALOS_NET_NAME" >/dev/null 2>&1 || true
  log "Undefine network $TALOS_NET_NAME"
  virsh -c "$LIBVIRT_URI" net-undefine "$TALOS_NET_NAME" >/dev/null 2>&1 || true
fi

# Talos generated state
if [[ -d "$TALOS_DIR" ]]; then
  log "Remove Talos dir $TALOS_DIR"
  rm -rf "$TALOS_DIR"
fi

# Kubeconfig outputs we create
if [[ -f "$KUBECONFIG_OUT" ]]; then
  log "Remove kubeconfig $KUBECONFIG_OUT"
  rm -f "$KUBECONFIG_OUT"
fi

# Root default
if [[ -f /root/.kube/config ]]; then
  log "Remove /root/.kube/config"
  rm -f /root/.kube/config
fi

# User default (if called via sudo)
if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
  user_home="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
  if [[ -n "$user_home" && -d "$user_home" ]]; then
    if [[ -f "${user_home}/.kube/config" ]]; then
      log "Remove ${user_home}/.kube/config"
      rm -f "${user_home}/.kube/config"
    fi
    if [[ -f "${user_home}/.kube/${TALOS_CLUSTER_NAME}.config" ]]; then
      log "Remove ${user_home}/.kube/${TALOS_CLUSTER_NAME}.config"
      rm -f "${user_home}/.kube/${TALOS_CLUSTER_NAME}.config"
    fi
  fi
fi

log "WIPE DONE."
log "Next:"
log "  sudo $ROOT/scripts/lab.sh $PROFILE all"
