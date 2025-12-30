#!/run/current-system/sw/bin/bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/common.sh"

require_root "$@"
need virsh
need virt-install
need qemu-img
need awk
need grep
need sed
need mktemp
need nc
need sleep
need install
need cmp
need tail

load_profile "${1:-}"
csv_init

mkdir -p "$DISK_DIR"

prepare_iso() {
  local src="$ISO"
  local dst="/var/lib/libvirt/images/$(basename "$ISO")"

  [[ -s "$src" ]] || die "Missing Talos ISO: $src"
  mkdir -p /var/lib/libvirt/images

  if [[ ! -f "$dst" ]] || ! cmp -s "$src" "$dst"; then
    log "Copy ISO -> $dst"
    install -m 0644 "$src" "$dst"
  else
    chmod 0644 "$dst" || true
  fi

  ISO="$dst"
}

ensure_network() {
  if virsh --connect "$LIBVIRT_URI" net-info "$TALOS_NET_NAME" >/dev/null 2>&1; then
    local bridge
    bridge="$(virsh --connect "$LIBVIRT_URI" net-dumpxml "$TALOS_NET_NAME" | awk -F"'" '/<bridge /{print $2; exit}')"
    [[ "$bridge" == "$TALOS_BRIDGE_NAME" ]] || die "Network '$TALOS_NET_NAME' uses bridge '$bridge' but profile expects '$TALOS_BRIDGE_NAME'. Run: lab.sh $PROFILE wipe"
  else
    log "Define network ${TALOS_NET_NAME} (bridge ${TALOS_BRIDGE_NAME})"
    local tmp
    tmp="$(mktemp)"
    cat > "$tmp" <<EOF
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
    virsh --connect "$LIBVIRT_URI" net-define "$tmp"
    rm -f "$tmp"
    virsh --connect "$LIBVIRT_URI" net-autostart "$TALOS_NET_NAME"
  fi

  local active
  active="$(virsh --connect "$LIBVIRT_URI" net-info "$TALOS_NET_NAME" | awk -F': *' '/Active:/ {print $2}')"
  [[ "$active" == "yes" ]] || virsh --connect "$LIBVIRT_URI" net-start "$TALOS_NET_NAME"
}

ensure_dhcp_host() {
  local name="$1" mac="$2" ip="$3"
  if virsh --connect "$LIBVIRT_URI" net-dumpxml "$TALOS_NET_NAME" | grep -q "mac='${mac}'"; then
    return 0
  fi
  log "DHCP host: ${name} ${mac} -> ${ip}"
  virsh --connect "$LIBVIRT_URI" net-update "$TALOS_NET_NAME" add ip-dhcp-host "<host mac='${mac}' name='${name}' ip='${ip}'/>" --live --config
}

fix_domain_events() {
  local name="$1"
  local tmp
  tmp="$(mktemp)"

  # Prefer inactive XML (persistent). If domain is running and inactive not available, fall back to live.
  if ! virsh --connect "$LIBVIRT_URI" dumpxml --inactive "$name" > "$tmp" 2>/dev/null; then
    virsh --connect "$LIBVIRT_URI" dumpxml "$name" > "$tmp"
  fi

  # Always restart on poweroff/reboot/crash
  if grep -q "<on_poweroff>" "$tmp"; then
    sed -i -E 's#<on_poweroff>[^<]*</on_poweroff>#<on_poweroff>restart</on_poweroff>#' "$tmp"
  else
    sed -i -E 's#</name>#</name>\n  <on_poweroff>restart</on_poweroff>#' "$tmp"
  fi

  if grep -q "<on_reboot>" "$tmp"; then
    sed -i -E 's#<on_reboot>[^<]*</on_reboot>#<on_reboot>restart</on_reboot>#' "$tmp"
  else
    sed -i -E 's#</name>#</name>\n  <on_reboot>restart</on_reboot>#' "$tmp"
  fi

  if grep -q "<on_crash>" "$tmp"; then
    sed -i -E 's#<on_crash>[^<]*</on_crash>#<on_crash>restart</on_crash>#' "$tmp"
  else
    sed -i -E 's#</name>#</name>\n  <on_crash>restart</on_crash>#' "$tmp"
  fi

  virsh --connect "$LIBVIRT_URI" define "$tmp" >/dev/null
  rm -f "$tmp"
}

ensure_vm() {
  local name="$1" mac="$2" disk_gb="$3" ram_mb="$4" vcpus="$5"
  local disk="${DISK_DIR}/talos-${name}.qcow2"

  if [[ ! -f "$disk" ]]; then
    log "Create disk ${disk} (${disk_gb}G)"
    qemu-img create -f qcow2 "$disk" "${disk_gb}G" >/dev/null
  fi

  if virsh --connect "$LIBVIRT_URI" dominfo "$name" >/dev/null 2>&1; then
    # sanity: correct network
    local src_net
    src_net="$(virsh --connect "$LIBVIRT_URI" domiflist "$name" 2>/dev/null | awk 'NR>2 && $1 ~ /^vnet/ {print $3; exit}')"
    [[ -z "$src_net" || "$src_net" == "$TALOS_NET_NAME" ]] || die "VM '$name' is attached to '$src_net' but profile expects '$TALOS_NET_NAME'. Run: lab.sh $PROFILE wipe"

    fix_domain_events "$name"

    local state
    state="$(virsh --connect "$LIBVIRT_URI" domstate "$name" 2>/dev/null | head -n1 || true)"
    [[ "$state" == "running" ]] || virsh --connect "$LIBVIRT_URI" start "$name" >/dev/null
    return 0
  fi

  log "Create VM ${name} (first boot from ISO)"

  # IMPORTANT: use --disk device=cdrom (deterministic), NOT --cdrom (can leave empty tray)
  virt-install \
    --connect "$LIBVIRT_URI" \
    --name "$name" \
    --memory "$ram_mb" \
    --vcpus "$vcpus" \
    --machine q35 \
    --osinfo generic \
    --disk "path=${disk},format=qcow2,bus=virtio" \
    --disk "path=${ISO},device=cdrom,readonly=on,bus=sata" \
    --network "network=${TALOS_NET_NAME},model=virtio,mac=${mac}" \
    --graphics none \
    --serial pty \
    --console pty,target_type=serial \
    --boot cdrom,hd \
    --autostart \
    --noautoconsole \
    --wait 0 >/dev/null

  sleep 1
  fix_domain_events "$name"
}

main() {
  prepare_iso
  ensure_network

  while IFS= read -r row; do
    name="$(csv_get "$row" name)"
    ip="$(csv_get "$row" ip)"
    mac="$(csv_get "$row" mac)"
    disk_gb="$(csv_get "$row" disk_gb)"
    ram_mb="$(csv_get "$row" ram_mb)"
    vcpus="$(csv_get "$row" vcpus)"

    ensure_dhcp_host "$name" "$mac" "$ip"
    ensure_vm "$name" "$mac" "$disk_gb" "$ram_mb" "$vcpus"

    log "Waiting for ${name} API ${ip}:50000"
    if ! wait_port "$ip" 50000 300; then
      log "DEBUG domblklist:"
      virsh --connect "$LIBVIRT_URI" domblklist "$name" || true
      log "DEBUG dhcp leases:"
      virsh --connect "$LIBVIRT_URI" net-dhcp-leases "$TALOS_NET_NAME" || true
      log "DEBUG qemu log tail:"
      tail -n 80 "/var/log/libvirt/qemu/${name}.log" 2>/dev/null || true
      die "Talos API not reachable on ${ip}:50000"
    fi
  done < <(csv_rows)

  log "OK: network + VMs up for ${PROFILE}"
  log "Tip: sudo virsh -c ${LIBVIRT_URI} console talos2-cp-1   (exit Ctrl+])"
}

main
