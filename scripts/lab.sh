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
[[ -n "$PROFILE" && -n "$CMD" ]] || die "Usage: lab.sh <profile> <cmd>  (cmd: up|provision|all|wipe|status)"

load_profile "$PROFILE"
csv_init

ISO_CACHE="${DISK_DIR}/metal-amd64.iso"

vm_disk_path() {
  local name="$1"
  echo "${DISK_DIR}/talos-${name}.qcow2"
}

net_bridge_of() {
  local net="$1"
  virsh -c "$LIBVIRT_URI" net-dumpxml "$net" 2>/dev/null | awk -F"'" '/<bridge name=/{print $2; exit}'
}

net_owner_of_bridge() {
  local bridge="$1"
  virsh -c "$LIBVIRT_URI" net-list --all --name \
    | sed '/^$/d' \
    | while read -r n; do
        b="$(net_bridge_of "$n" || true)"
        [[ -n "$b" && "$b" == "$bridge" ]] && echo "$n"
      done
}

debug_net_map() {
  log "DEBUG: Existing network -> bridge mapping:"
  virsh -c "$LIBVIRT_URI" net-list --all --name | sed '/^$/d' | while read -r n; do
    b="$(net_bridge_of "$n" || true)"
    echo "  $n -> $b"
  done
}

ensure_iso_cache() {
  ensure_disk_dir
  if [[ -f "$ISO_CACHE" ]]; then
    return 0
  fi
  [[ -f "$ISO" ]] || die "Missing Talos ISO: $ISO"
  log "Copy ISO -> $ISO_CACHE"
  install -m 0644 "$ISO" "$ISO_CACHE"
}

write_net_xml() {
  # Generate XML directly (no template), so bridge cannot drift.
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

remove_networks_using_bridge() {
  local bridge="$1"
  local owners
  owners="$(net_owner_of_bridge "$bridge" || true)"

  if [[ -z "$owners" ]]; then
    log "WARN: No libvirt network owns bridge/interface '${bridge}' (maybe stale interface)."
    return 0
  fi

  log "WARN: Bridge/interface '${bridge}' is owned by libvirt network(s). Removing them:"
  echo "$owners" | while read -r n; do
    [[ -z "$n" ]] && continue
    log "WARN:   - destroy/undefine $n"
    virsh -c "$LIBVIRT_URI" net-destroy "$n" 2>/dev/null || true
    virsh -c "$LIBVIRT_URI" net-undefine "$n" 2>/dev/null || true
  done
}

net_start_with_autofix() {
  local err=""
  if err="$(virsh -c "$LIBVIRT_URI" net-start "$TALOS_NET_NAME" 2>&1)"; then
    return 0
  fi

  # Example error:
  # error: Failed to start network talosnet1
  # error: internal error: Network is already in use by interface virbr-talosnet
  if [[ "$err" =~ interface[[:space:]]+([^[:space:]]+) ]]; then
    local bad_if="${BASH_REMATCH[1]}"
    log "WARN: net-start failed due to interface in use: ${bad_if}"
    remove_networks_using_bridge "$bad_if"

    # best-effort: if interface still exists after removing owner networks, try deleting it
    if ip link show "$bad_if" >/dev/null 2>&1; then
      local still_owner
      still_owner="$(net_owner_of_bridge "$bad_if" || true)"
      if [[ -z "$still_owner" ]]; then
        log "WARN: Interface '${bad_if}' still exists without an owning network. Deleting it."
        ip link set "$bad_if" down 2>/dev/null || true
        ip link delete "$bad_if" type bridge 2>/dev/null || true
      fi
    fi

    log "Retry: starting network ${TALOS_NET_NAME}"
    if err="$(virsh -c "$LIBVIRT_URI" net-start "$TALOS_NET_NAME" 2>&1)"; then
      return 0
    fi
  fi

  log "ERROR: Failed to start network ${TALOS_NET_NAME}"
  echo "$err" | sed 's/^/[virsh] /'
  debug_net_map
  die "libvirt refused to start ${TALOS_NET_NAME} (bridge conflict)."
}

net_define_start() {
  log "Define network ${TALOS_NET_NAME} (requested bridge ${TALOS_BRIDGE_NAME})"

  # If network exists, remove it (avoid drift)
  if virsh -c "$LIBVIRT_URI" net-info "$TALOS_NET_NAME" >/dev/null 2>&1; then
    log "Destroy existing network ${TALOS_NET_NAME}"
    virsh -c "$LIBVIRT_URI" net-destroy "$TALOS_NET_NAME" 2>/dev/null || true
    log "Undefine existing network ${TALOS_NET_NAME}"
    virsh -c "$LIBVIRT_URI" net-undefine "$TALOS_NET_NAME" 2>/dev/null || true
  fi

  local tmp
  tmp="$(mktemp)"
  write_net_xml "$tmp"

  local xml_bridge
  xml_bridge="$(awk -F"'" '/<bridge name=/{print $2; exit}' "$tmp")"
  log "Network XML bridge = ${xml_bridge}"

  virsh -c "$LIBVIRT_URI" net-define "$tmp" >/dev/null
  virsh -c "$LIBVIRT_URI" net-autostart "$TALOS_NET_NAME" >/dev/null

  # Start with auto-fix on bridge conflicts
  net_start_with_autofix

  rm -f "$tmp"
  log "Network ${TALOS_NET_NAME} started."
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

vm_fix_on_policy() {
  local name="$1"
  local tmp
  tmp="$(mktemp)"
  virsh -c "$LIBVIRT_URI" dumpxml "$name" > "$tmp"

  sed -i \
    -e 's|<on_poweroff>[^<]*</on_poweroff>|<on_poweroff>destroy</on_poweroff>|' \
    -e 's|<on_reboot>[^<]*</on_reboot>|<on_reboot>restart</on_reboot>|' \
    -e 's|<on_crash>[^<]*</on_crash>|<on_crash>restart</on_crash>|' \
    "$tmp"

  virsh -c "$LIBVIRT_URI" define "$tmp" >/dev/null
  rm -f "$tmp"
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

  log "Create VM $name (first boot from ISO)"
  virt-install \
    --connect "$LIBVIRT_URI" \
    --name "$name" \
    --memory "$ram_mb" \
    --vcpus "$vcpus" \
    --disk "path=$disk,format=qcow2,bus=virtio" \
    --cdrom "$ISO_CACHE" \
    --network "network=${TALOS_NET_NAME},mac=${mac},model=virtio" \
    --os-variant generic \
    --graphics none \
    --noautoconsole \
    --boot cdrom,hd >/dev/null

  vm_fix_on_policy "$name"
}

cmd_status() {
  log "== STATUS profile=${PROFILE} =="
  log "Network: ${TALOS_NET_NAME}  bridge=${TALOS_BRIDGE_NAME}"
  log "Networks:"
  virsh -c "$LIBVIRT_URI" net-list --all | sed 's/^/  /'
  debug_net_map
}

cmd_wipe() {
  log "WIPING profile '${PROFILE}' (VMs, disks, network, talos state, kubeconfig)"

  # VMs + disks
  while IFS= read -r row; do
    name="$(csv_get "$row" name)"
    disk="$(vm_disk_path "$name")"

    if virsh -c "$LIBVIRT_URI" dominfo "$name" >/dev/null 2>&1; then
      log "Destroy $name"
      virsh -c "$LIBVIRT_URI" destroy "$name" 2>/dev/null || true
      log "Undefine $name"
      virsh -c "$LIBVIRT_URI" undefine "$name" --nvram 2>/dev/null || virsh -c "$LIBVIRT_URI" undefine "$name" 2>/dev/null || true
    fi

    if [[ -f "$disk" ]]; then
      log "Delete disk $disk"
      rm -f "$disk"
    fi
  done < <(csv_rows)

  # Network
  if virsh -c "$LIBVIRT_URI" net-info "$TALOS_NET_NAME" >/dev/null 2>&1; then
    log "Destroy network $TALOS_NET_NAME"
    virsh -c "$LIBVIRT_URI" net-destroy "$TALOS_NET_NAME" 2>/dev/null || true
    log "Undefine network $TALOS_NET_NAME"
    virsh -c "$LIBVIRT_URI" net-undefine "$TALOS_NET_NAME" 2>/dev/null || true
  fi

  # State
  if [[ -d "$TALOS_DIR" ]]; then
    log "Remove Talos dir $TALOS_DIR"
    rm -rf "$TALOS_DIR"
  fi

  log "WIPE DONE."
  log "Next:"
  log "  sudo ${ROOT}/scripts/lab.sh ${PROFILE} all"
}

cmd_up() {
  log "== UP =="

  ensure_iso_cache
  net_define_start

  while IFS= read -r row; do
    name="$(csv_get "$row" name)"
    mac="$(csv_get "$row" mac)"
    ipaddr="$(csv_get "$row" ip)"
    log "DHCP host: ${name} ${mac} -> ${ipaddr}"
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
    if ! virsh -c "$LIBVIRT_URI" domstate "$name" 2>/dev/null | grep -qi running; then
      virsh -c "$LIBVIRT_URI" start "$name" >/dev/null
    fi
  done < <(csv_rows)

  local cp_ip="" cp_name=""
  while IFS= read -r row; do
    role="$(csv_get "$row" role)"
    if [[ "$role" == "controlplane" ]]; then
      cp_ip="$(csv_get "$row" ip)"
      cp_name="$(csv_get "$row" name)"
      break
    fi
  done < <(csv_rows)

  [[ -n "$cp_ip" ]] || die "No controlplane found in nodes.csv"

  log "Waiting for ${cp_name} API ${cp_ip}:50000"
  if ! wait_port "$cp_ip" 50000 300; then
    die "Talos API not reachable on ${cp_ip}:50000"
  fi

  log "OK: network + VMs up for ${PROFILE}"
  log "Tip: sudo virsh -c ${LIBVIRT_URI} console ${cp_name}   (exit Ctrl+])"
}

cmd_provision() {
  log "== PROVISION =="
  "${ROOT}/scripts/talos-provision.sh" "$PROFILE"
}

cmd_all() {
  cmd_up
  cmd_provision
}

case "$CMD" in
  status) cmd_status ;;
  wipe) cmd_wipe ;;
  up) cmd_up ;;
  provision) cmd_provision ;;
  all) cmd_all ;;
  *) die "Unknown cmd: $CMD (use: up|provision|all|wipe|status)" ;;
esac
