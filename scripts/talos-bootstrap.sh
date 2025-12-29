# =====================================================================
# FILE: /home/gunstein/nixos-talos-vm-lab/scripts/talos-bootstrap.sh
# (rsync -> /etc/nixos/talos-host/scripts/talos-bootstrap.sh)
# =====================================================================
#!/run/current-system/sw/bin/bash
set -euo pipefail

export PATH="/run/current-system/sw/bin:/run/wrappers/bin:${PATH:-}"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

require() { command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }
for c in virsh qemu-img awk sed grep tr mktemp sleep virt-install rsync; do require "$c"; done

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

ISO="${ROOT}/assets/metal-amd64.iso"
[[ -s "$ISO" ]] || die "Missing/empty ISO: $ISO"
[[ -f "$NODES_CSV" ]] || die "Missing nodes.csv: $NODES_CSV"

if [[ -f "$VARS_ENV" ]]; then
  # shellcheck disable=SC1090
  source "$VARS_ENV"
fi

NET_NAME="${TALOS_NET_NAME:-talosnet}"
BRIDGE_NAME="${TALOS_BRIDGE_NAME:-virbr-talosnet}"
GW_IP="${TALOS_GATEWAY:-192.168.123.1}"
DHCP_START="${TALOS_DHCP_START:-192.168.123.100}"
DHCP_END="${TALOS_DHCP_END:-192.168.123.254}"

DISK_DIR="${DISK_DIR:-/var/lib/libvirt/images}"
mkdir -p "$DISK_DIR"

is_mac() { [[ "$1" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]; }
is_ipv4() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }

# --- CSV parsing (any column order) ---
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

dom_state() {
  virsh --connect "$LIBVIRT_URI" domstate "$1" 2>/dev/null | head -n1 | tr -d '\r' || true
}

wait_dom_state() {
  local name="$1" want="$2" timeout="${3:-30}"
  local deadline=$((SECONDS + timeout))
  while (( SECONDS < deadline )); do
    if [[ "$(dom_state "$name")" == "$want" ]]; then
      return 0
    fi
    sleep 1
  done
  return 1
}

restart_domain() {
  local name="$1"
  log "Restarting domain '${name}'"
  virsh --connect "$LIBVIRT_URI" shutdown "$name" >/dev/null 2>&1 || true
  if ! wait_dom_state "$name" "shut off" 20; then
    virsh --connect "$LIBVIRT_URI" destroy "$name" >/dev/null 2>&1 || true
    wait_dom_state "$name" "shut off" 10 || true
  fi
  virsh --connect "$LIBVIRT_URI" start "$name" >/dev/null
}

ensure_network() {
  if ! virsh --connect "$LIBVIRT_URI" net-info "$NET_NAME" >/dev/null 2>&1; then
    log "Defining libvirt network '$NET_NAME' (GW ${GW_IP}, DHCP ${DHCP_START}-${DHCP_END})"
    local tmp
    tmp="$(mktemp)"
    cat > "$tmp" <<EOF
<network>
  <name>${NET_NAME}</name>
  <forward mode='nat'/>
  <bridge name='${BRIDGE_NAME}' stp='on' delay='0'/>
  <ip address='${GW_IP}' netmask='255.255.255.0'>
    <dhcp>
      <range start='${DHCP_START}' end='${DHCP_END}'/>
    </dhcp>
  </ip>
</network>
EOF
    virsh --connect "$LIBVIRT_URI" net-define "$tmp"
    rm -f "$tmp"
    virsh --connect "$LIBVIRT_URI" net-autostart "$NET_NAME"
  fi

  local active
  active="$(virsh --connect "$LIBVIRT_URI" net-info "$NET_NAME" | awk -F': *' '/Active:/ {print $2}' || true)"
  [[ "$active" == "yes" ]] || virsh --connect "$LIBVIRT_URI" net-start "$NET_NAME"
}

ensure_dhcp_reservation() {
  local name="$1" mac="$2" ip="$3"
  is_mac "$mac" || die "Invalid MAC for '${name}': ${mac}"
  is_ipv4 "$ip" || die "Invalid IP for '${name}': ${ip}"

  if virsh --connect "$LIBVIRT_URI" net-dumpxml "$NET_NAME" | grep -qi "mac='${mac}'"; then
    return 0
  fi

  log "Adding DHCP reservation: ${name} ${mac} -> ${ip}"
  local entry="<host mac='${mac}' name='${name}' ip='${ip}'/>"
  virsh --connect "$LIBVIRT_URI" net-update "$NET_NAME" add ip-dhcp-host "$entry" --live --config
}

ensure_domain_events() {
  # Force on_poweroff/on_reboot/on_crash = restart (idempotent)
  local name="$1"
  virsh --connect "$LIBVIRT_URI" dominfo "$name" >/dev/null 2>&1 || return 0

  local live_xml inactive_xml tmp
  live_xml="$(virsh --connect "$LIBVIRT_URI" dumpxml "$name" 2>/dev/null || true)"
  inactive_xml="$(virsh --connect "$LIBVIRT_URI" dumpxml --inactive "$name" 2>/dev/null || true)"

  tmp="$(mktemp)"
  if [[ -n "$inactive_xml" ]]; then
    printf "%s" "$inactive_xml" > "$tmp"
  else
    printf "%s" "$live_xml" > "$tmp"
  fi

  sed -i -E 's#<on_poweroff>[^<]*</on_poweroff>#<on_poweroff>restart</on_poweroff>#' "$tmp"
  sed -i -E 's#<on_reboot>[^<]*</on_reboot>#<on_reboot>restart</on_reboot>#' "$tmp"
  sed -i -E 's#<on_crash>[^<]*</on_crash>#<on_crash>restart</on_crash>#' "$tmp"

  if ! grep -q "<on_poweroff>" "$tmp" || ! grep -q "<on_reboot>" "$tmp" || ! grep -q "<on_crash>" "$tmp"; then
    sed -i "/<on_poweroff>/d; /<on_reboot>/d; /<on_crash>/d" "$tmp"
    sed -i "0,/<name>[^<]*<\/name>/s##&\n  <on_poweroff>restart<\/on_poweroff>\n  <on_reboot>restart<\/on_reboot>\n  <on_crash>restart<\/on_crash>#" "$tmp"
  fi

  virsh --connect "$LIBVIRT_URI" define "$tmp" >/dev/null
  rm -f "$tmp"

  # If live policy still shows destroy, restart once
  if [[ "$(dom_state "$name")" == "running" ]]; then
    if printf "%s" "$live_xml" | grep -q "<on_reboot>destroy</on_reboot>" \
      || printf "%s" "$live_xml" | grep -q "<on_poweroff>destroy</on_poweroff>"
    then
      restart_domain "$name"
    fi
  fi
}

ensure_vm() {
  local name="$1" role="$2" ip="$3" mac="$4" disk_gb="$5" ram_mb="$6" vcpus="$7"
  local disk="${DISK_DIR}/talos-${name}.qcow2"

  [[ -n "$name" ]] || die "Empty VM name"
  is_mac "$mac" || die "Invalid MAC for '${name}': ${mac}"
  is_ipv4 "$ip" || die "Invalid IP for '${name}': ${ip}"
  [[ "$disk_gb" =~ ^[0-9]+$ ]] || die "Invalid disk_gb for '${name}': ${disk_gb}"
  [[ "$ram_mb" =~ ^[0-9]+$ ]] || die "Invalid ram_mb for '${name}': ${ram_mb}"
  [[ "$vcpus" =~ ^[0-9]+$ ]] || die "Invalid vcpus for '${name}': ${vcpus}"

  if [[ ! -f "$disk" ]]; then
    log "Creating disk: $disk (${disk_gb}G qcow2)"
    qemu-img create -f qcow2 "$disk" "${disk_gb}G" >/dev/null
  fi

  if virsh --connect "$LIBVIRT_URI" dominfo "$name" >/dev/null 2>&1; then
    # IMPORTANT: do NOT re-insert ISO or rewrite boot order for existing VMs.
    ensure_domain_events "$name"
    if [[ "$(dom_state "$name")" != "running" ]]; then
      virsh --connect "$LIBVIRT_URI" start "$name" >/dev/null
    fi
    return 0
  fi

  log "Defining NEW VM '$name' (role=${role}) (first boot from ISO)"
  virt-install \
    --connect "$LIBVIRT_URI" \
    --name "$name" \
    --memory "$ram_mb" \
    --vcpus "$vcpus" \
    --cpu host-model \
    --machine q35 \
    --osinfo generic \
    --disk "path=${disk},format=qcow2,bus=virtio" \
    --cdrom "$ISO" \
    --network "network=${NET_NAME},model=virtio,mac=${mac}" \
    --graphics none \
    --boot cdrom,hd \
    --events on_poweroff=restart,on_reboot=restart,on_crash=restart \
    --autostart \
    --noautoconsole \
    --wait 0 >/dev/null

  ensure_domain_events "$name"
}

main() {
  csv_init
  ensure_network

  while IFS= read -r row; do
    local name role ip mac disk_gb ram_mb vcpus
    name="$(csv_get "$row" name)"
    role="$(csv_get "$row" role)"
    ip="$(csv_get "$row" ip)"
    mac="$(csv_get "$row" mac)"
    disk_gb="$(csv_get "$row" disk_gb)"
    ram_mb="$(csv_get "$row" ram_mb)"
    vcpus="$(csv_get "$row" vcpus)"

    ensure_dhcp_reservation "$name" "$mac" "$ip"
    ensure_vm "$name" "$role" "$ip" "$mac" "$disk_gb" "$ram_mb" "$vcpus"
  done < <(csv_rows)

  log "Bootstrap completed for profile '${PROFILE}'."
}

main "$@"
