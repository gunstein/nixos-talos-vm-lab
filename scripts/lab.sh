#!/run/current-system/sw/bin/bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/common.sh"

require_root "$@"

need virsh
need awk
need sed
need nc
need mktemp
need install
need rm
need mkdir
need date
need sleep
need ip
need virt-install
need qemu-img

PROFILE="${1:-}"
CMD="${2:-}"
[[ -n "$PROFILE" && -n "$CMD" ]] || die "Usage: lab.sh <profile> <cmd> (status|up|provision|verify|all|wipe|net-recreate)"

load_profile "$PROFILE"
csv_init

ISO_CACHE="${DISK_DIR}/metal-amd64.iso"

vm_disk_path() { echo "${DISK_DIR}/talos-${1}.qcow2"; }

ensure_iso_cache() {
  ensure_disk_dir
  if [[ -f "$ISO_CACHE" ]]; then return 0; fi
  [[ -f "$ISO" ]] || die "Missing Talos ISO: $ISO"
  log "Copy ISO -> $ISO_CACHE"
  install -m 0644 "$ISO" "$ISO_CACHE"
}

write_net_xml() {
  local out="$1"
  cat > "$out" <<EOF
<network>
  <name>${TALOS_NET_NAME}</name>
  <forward mode='nat'/>
  <bridge name='${TALOS_BRIDGE_NAME}' stp='on' delay='0'/>
  <ip address='${TALOS_GATEWAY}' netmask='255.255.255.0'>
    <dhcp>
      <range start='${TALOS_DHCP_START}' end='${TALOS_DHCP_END}'/>
    </dhcp>
  </ip>
</network>
EOF
}

net_bridge_of() {
  virsh -c "$LIBVIRT_URI" net-dumpxml "$1" 2>/dev/null | awk -F"'" '/<bridge name=/{print $2; exit}'
}

net_start_with_autofix() {
  local err=""
  if err="$(virsh -c "$LIBVIRT_URI" net-start "$TALOS_NET_NAME" 2>&1)"; then
    return 0
  fi

  if [[ "$err" =~ interface[[:space:]]+([^[:space:]]+) ]]; then
    local bad_if="${BASH_REMATCH[1]}"
    log "WARN: net-start failed due to interface in use: ${bad_if}"

    if ip link show "$bad_if" >/dev/null 2>&1; then
      log "WARN: Trying to delete stale bridge '${bad_if}'"
      ip link set "$bad_if" down 2>/dev/null || true
      ip link delete "$bad_if" type bridge 2>/dev/null || true
    fi

    log "Retry: net-start ${TALOS_NET_NAME}"
    virsh -c "$LIBVIRT_URI" net-start "$TALOS_NET_NAME" >/dev/null
    return 0
  fi

  log "ERROR: Failed to start network ${TALOS_NET_NAME}"
  echo "$err" | sed 's/^/[virsh] /'
  die "libvirt refused to start ${TALOS_NET_NAME}"
}

# Explicit destructive recreate (only when requested)
net_recreate() {
  log "Recreate network ${TALOS_NET_NAME}"
  if virsh -c "$LIBVIRT_URI" net-info "$TALOS_NET_NAME" >/dev/null 2>&1; then
    virsh -c "$LIBVIRT_URI" net-destroy "$TALOS_NET_NAME" 2>/dev/null || true
    virsh -c "$LIBVIRT_URI" net-undefine "$TALOS_NET_NAME" 2>/dev/null || true
  fi

  local tmp
  tmp="$(mktemp)"
  write_net_xml "$tmp"

  virsh -c "$LIBVIRT_URI" net-define "$tmp" >/dev/null
  virsh -c "$LIBVIRT_URI" net-autostart "$TALOS_NET_NAME" >/dev/null
  net_start_with_autofix
  rm -f "$tmp"
}

# Idempotent ensure: NO destroy/undefine
net_ensure_started() {
  if ! virsh -c "$LIBVIRT_URI" net-info "$TALOS_NET_NAME" >/dev/null 2>&1; then
    log "Network missing -> define+start"
    net_recreate
    return 0
  fi

  local existing_bridge
  existing_bridge="$(net_bridge_of "$TALOS_NET_NAME" || true)"
  if [[ -n "$existing_bridge" && "$existing_bridge" != "$TALOS_BRIDGE_NAME" ]]; then
    log "ERROR: Network drift: ${TALOS_NET_NAME} uses '${existing_bridge}', expected '${TALOS_BRIDGE_NAME}'"
    log "Run explicitly:"
    log "  sudo ${ROOT}/scripts/lab.sh ${PROFILE} net-recreate"
    die "Refusing to auto-recreate network in idempotent mode."
  fi

  local active
  active="$(virsh -c "$LIBVIRT_URI" net-info "$TALOS_NET_NAME" | awk -F': *' '/^Active:/{print $2}')"
  if [[ "$active" != "yes" ]]; then
    log "Start existing network ${TALOS_NET_NAME}"
    net_start_with_autofix
  else
    log "Network ${TALOS_NET_NAME} already active."
  fi
}

net_add_dhcp_host() {
  local name="$1" mac="$2" ipaddr="$3"
  local hostxml
  hostxml="$(mktemp)"
  cat > "$hostxml" <<EOF
<host mac='${mac}' name='${name}' ip='${ipaddr}'/>
EOF
  virsh -c "$LIBVIRT_URI" net-update "$TALOS_NET_NAME" add-last ip-dhcp-host --xml "$(cat "$hostxml")" --config >/dev/null 2>&1 || true
  virsh -c "$LIBVIRT_URI" net-update "$TALOS_NET_NAME" add-last ip-dhcp-host --xml "$(cat "$hostxml")" --live   >/dev/null 2>&1 || true
  rm -f "$hostxml"
}

vm_create() {
  local name="$1" disk_gb="$2" ram_mb="$3" vcpus="$4" mac="$5"
  local disk
  disk="$(vm_disk_path "$name")"

  ensure_disk_dir

  if [[ ! -f "$disk" ]]; then
    log "Create disk $disk (${disk_gb}G)"
    qemu-img create -f qcow2 "$disk" "${disk_gb}G" >/dev/null
  fi

  if virsh -c "$LIBVIRT_URI" dominfo "$name" >/dev/null 2>&1; then
    log "VM exists: $name (skip create)"
    return 0
  fi

  log "Create VM $name (Talos ISO first boot, VNC enabled)"
  virt-install \
    --connect "$LIBVIRT_URI" \
    --name "$name" \
    --memory "$ram_mb" \
    --vcpus "$vcpus" \
    --disk "path=$disk,format=qcow2,bus=virtio" \
    --cdrom "$ISO_CACHE" \
    --network "network=${TALOS_NET_NAME},mac=${mac},model=virtio" \
    --os-variant generic \
    --graphics "vnc,listen=127.0.0.1,port=-1" \
    --video virtio \
    --noautoconsole \
    --boot cdrom,hd >/dev/null
}

vm_start_if_needed() {
  local name="$1"
  if ! virsh -c "$LIBVIRT_URI" domstate "$name" 2>/dev/null | grep -qi running; then
    log "Start VM $name"
    virsh -c "$LIBVIRT_URI" start "$name" >/dev/null
  fi
}

first_controlplane() {
  local row role
  while IFS= read -r row; do
    role="$(csv_get "$row" role)"
    if [[ "$role" == "controlplane" ]]; then
      echo "$(csv_get "$row" name) $(csv_get "$row" ip)"
      return 0
    fi
  done < <(csv_rows)
  return 1
}

cmd_status() {
  log "== STATUS profile=${PROFILE} =="
  virsh -c "$LIBVIRT_URI" net-list --all | sed 's/^/  /'
  virsh -c "$LIBVIRT_URI" list --all | sed 's/^/  /'
}

cmd_wipe() {
  log "WIPING profile '${PROFILE}' (VMs, disks, network, talos state)"
  local row name disk

  while IFS= read -r row; do
    name="$(csv_get "$row" name)"
    disk="$(vm_disk_path "$name")"

    if virsh -c "$LIBVIRT_URI" dominfo "$name" >/dev/null 2>&1; then
      virsh -c "$LIBVIRT_URI" destroy "$name" 2>/dev/null || true
      virsh -c "$LIBVIRT_URI" undefine "$name" --nvram 2>/dev/null || virsh -c "$LIBVIRT_URI" undefine "$name" 2>/dev/null || true
    fi
    [[ -f "$disk" ]] && rm -f "$disk"
  done < <(csv_rows)

  if virsh -c "$LIBVIRT_URI" net-info "$TALOS_NET_NAME" >/dev/null 2>&1; then
    virsh -c "$LIBVIRT_URI" net-destroy "$TALOS_NET_NAME" 2>/dev/null || true
    virsh -c "$LIBVIRT_URI" net-undefine "$TALOS_NET_NAME" 2>/dev/null || true
  fi

  [[ -d "$TALOS_DIR" ]] && rm -rf "$TALOS_DIR"
  log "WIPE DONE."
}

cmd_up() {
  log "== UP =="
  ensure_iso_cache
  net_ensure_started

  local row name mac ipaddr disk_gb ram_mb vcpus
  while IFS= read -r row; do
    name="$(csv_get "$row" name)"
    mac="$(csv_get "$row" mac)"
    ipaddr="$(csv_get "$row" ip)"
    net_add_dhcp_host "$name" "$mac" "$ipaddr"
  done < <(csv_rows)

  while IFS= read -r row; do
    name="$(csv_get "$row" name)"
    disk_gb="$(csv_get "$row" disk_gb)"
    ram_mb="$(csv_get "$row" ram_mb)"
    vcpus="$(csv_get "$row" vcpus)"
    mac="$(csv_get "$row" mac)"
    vm_create "$name" "$disk_gb" "$ram_mb" "$vcpus" "$mac"
  done < <(csv_rows)

  while IFS= read -r row; do
    name="$(csv_get "$row" name)"
    vm_start_if_needed "$name"
  done < <(csv_rows)

  local cp cp_name cp_ip
  cp="$(first_controlplane)" || die "No controlplane found in nodes.csv"
  cp_name="$(echo "$cp" | awk '{print $1}')"
  cp_ip="$(echo "$cp" | awk '{print $2}')"

  log "Waiting for Talos API ${cp_ip}:50000"
  if ! wait_port "$cp_ip" 50000 300; then
    log "Talos API not reachable. Check VNC:"
    log "  sudo virsh -c ${LIBVIRT_URI} vncdisplay ${cp_name}"
    die "Talos API not reachable on ${cp_ip}:50000"
  fi

  log "OK: network + VMs up."
}

cmd_provision() {
  log "== PROVISION =="
  "${ROOT}/scripts/talos-provision.sh" "$PROFILE"
}

cmd_verify() {
  log "== VERIFY =="
  "${ROOT}/scripts/talos-verify.sh" "$PROFILE"
}

cmd_all() {
  cmd_up
  cmd_provision
  cmd_verify
}

case "$CMD" in
  status) cmd_status ;;
  net-recreate) net_recreate ;;
  wipe) cmd_wipe ;;
  up) cmd_up ;;
  provision) cmd_provision ;;
  verify) cmd_verify ;;
  all) cmd_all ;;
  *) die "Unknown cmd: $CMD (use: status|up|provision|verify|all|wipe|net-recreate)" ;;
esac
