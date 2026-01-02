#!/run/current-system/sw/bin/bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/common.sh"

# Usage:
#   sudo ./scripts/talos-verify.sh lab2
# or (after install.sh)
#   sudo /etc/nixos/talos-host/scripts/talos-verify.sh lab2

require_root "$@"

need virsh
need nc
need awk
need grep
need sed
need sleep

# Optional tools (we’ll skip sections if missing)
HAVE_TALOSCTL=0
HAVE_KUBECTL=0
command -v talosctl >/dev/null 2>&1 && HAVE_TALOSCTL=1
command -v kubectl  >/dev/null 2>&1 && HAVE_KUBECTL=1

PROFILE="${1:-}"
load_profile "$PROFILE"
csv_init

# ----- Helpers -----
ok()   { log "OK: $*"; }
warn() { log "WARN: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

check_cmd() {
  local name="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    ok "$name"
  else
    fail "$name"
  fi
}

# Find first controlplane node
CP_NAME=""
CP_IP=""
CP_MAC=""
while IFS= read -r row; do
  role="$(csv_get "$row" role)"
  if [[ "$role" == "controlplane" ]]; then
    CP_NAME="$(csv_get "$row" name)"
    CP_IP="$(csv_get "$row" ip)"
    CP_MAC="$(csv_get "$row" mac)"
    break
  fi
done < <(csv_rows)
[[ -n "$CP_NAME" && -n "$CP_IP" ]] || fail "No controlplane node found in nodes.csv (role=controlplane)"

log "== VERIFY profile=$PROFILE =="
log "Controlplane: $CP_NAME ($CP_IP)"

# ----- Libvirt: network -----
log "== LIBVIRT NETWORK =="
check_cmd "network exists: $TALOS_NET_NAME" virsh -c "$LIBVIRT_URI" net-info "$TALOS_NET_NAME"
active="$(virsh -c "$LIBVIRT_URI" net-info "$TALOS_NET_NAME" | awk -F': *' '/Active:/ {print $2}')"
[[ "$active" == "yes" ]] || fail "network not active: $TALOS_NET_NAME"

bridge="$(virsh -c "$LIBVIRT_URI" net-dumpxml "$TALOS_NET_NAME" | awk -F"'" '/<bridge /{print $2; exit}')"
if [[ -n "$bridge" && "$bridge" != "$TALOS_BRIDGE_NAME" ]]; then
  fail "network bridge mismatch: net=$TALOS_NET_NAME bridge=$bridge expected=$TALOS_BRIDGE_NAME"
fi
ok "network active: $TALOS_NET_NAME (bridge ${bridge:-unknown})"

# ----- Libvirt: VMs and DHCP leases -----
log "== LIBVIRT VMS + DHCP =="
while IFS= read -r row; do
  name="$(csv_get "$row" name)"
  ip="$(csv_get "$row" ip)"
  mac="$(csv_get "$row" mac)"

  check_cmd "vm exists: $name" virsh -c "$LIBVIRT_URI" dominfo "$name"
  state="$(virsh -c "$LIBVIRT_URI" domstate "$name" | head -n1 || true)"
  [[ "$state" == "running" ]] || fail "vm not running: $name (state=$state)"
  ok "vm running: $name"

  # NIC attached to correct network
  src_net="$(virsh -c "$LIBVIRT_URI" domiflist "$name" 2>/dev/null | awk 'NR>2 && $1 ~ /^vnet/ {print $3; exit}')"
  [[ -z "$src_net" || "$src_net" == "$TALOS_NET_NAME" ]] || fail "vm $name attached to $src_net, expected $TALOS_NET_NAME"
  ok "vm network ok: $name -> ${src_net:-unknown}"

  # ISO sanity (cdrom not "-")
  cdsrc="$(virsh -c "$LIBVIRT_URI" domblklist "$name" 2>/dev/null | awk '$1=="sda"{print $2; exit}')"
  if [[ -n "$cdsrc" && "$cdsrc" == "-" ]]; then
    warn "vm $name cdrom is empty (sda '-')"
  else
    ok "vm cdrom ok: $name (sda=${cdsrc:-<unknown>})"
  fi

  # DHCP lease present (best-effort; sometimes it won’t show immediately)
  if virsh -c "$LIBVIRT_URI" net-dhcp-leases "$TALOS_NET_NAME" | grep -qi "$mac"; then
    ok "dhcp lease present: $name ($mac)"
  else
    warn "dhcp lease not visible yet for $name ($mac) (can be OK if Talos static config takes over)"
  fi

  # Ports
  if wait_port "$ip" 50000 120; then
    ok "talos api port open: $ip:50000"
  else
    fail "talos api port NOT reachable: $ip:50000"
  fi

  # 6443 can take time; only hard-fail for controlplane after longer wait
  if [[ "$name" == "$CP_NAME" ]]; then
    if wait_port "$ip" 6443 300; then
      ok "k8s apiserver port open: $ip:6443"
    else
      warn "k8s apiserver port not open yet on $ip:6443 (may still be starting)"
    fi
  fi
done < <(csv_rows)

# ----- Talos checks -----
log "== TALOS =="
if [[ "$HAVE_TALOSCTL" -eq 0 ]]; then
  warn "talosctl not found on host; skipping Talos health/service/log checks"
else
  export TALOSCONFIG="${TALOS_DIR}/generated/talosconfig"
  if [[ ! -f "$TALOSCONFIG" ]]; then
    warn "TALOSCONFIG not found at $TALOSCONFIG (have you run provision yet?)"
  else
    # Basic connectivity / version
    if talosctl -n "$CP_IP" -e "$CP_IP" version >/dev/null 2>&1; then
      ok "talosctl version works (mTLS)"
    else
      warn "talosctl version failed (mTLS). Try: talosctl -n $CP_IP -e $CP_IP version"
    fi

    # Health
    if talosctl -n "$CP_IP" -e "$CP_IP" health >/dev/null 2>&1; then
      ok "talos health OK"
    else
      warn "talos health NOT OK"
      talosctl -n "$CP_IP" -e "$CP_IP" health || true
    fi

    # Services (best-effort)
    if talosctl -n "$CP_IP" -e "$CP_IP" service >/dev/null 2>&1; then
      ok "talos service list OK"
    else
      warn "talos service list failed"
    fi
  fi
fi

# ----- Kubernetes checks -----
log "== KUBERNETES =="
# Prefer user kubeconfig when present, else use KUBECONFIG_OUT.
KC_USER=""
if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
  user_home="$(getent passwd "$SUDO_USER" | cut -d: -f6 || true)"
  if [[ -n "$user_home" && -f "${user_home}/.kube/config" ]]; then
    KC_USER="${user_home}/.kube/config"
  fi
fi

KC="${KC_USER:-$KUBECONFIG_OUT}"
if [[ "$HAVE_KUBECTL" -eq 0 ]]; then
  warn "kubectl not found on host; skipping Kubernetes checks"
else
  if [[ ! -f "$KC" ]]; then
    warn "kubeconfig not found at $KC (have you run provision yet?)"
  else
    ok "using kubeconfig: $KC"

    # /readyz (best signal)
    if kubectl --kubeconfig "$KC" get --raw='/readyz' >/dev/null 2>&1; then
      ok "apiserver readyz OK"
    else
      warn "apiserver readyz failed (may still be starting)"
    fi

    # Nodes
    kubectl --kubeconfig "$KC" get nodes -o wide || warn "kubectl get nodes failed"
    ready="$(kubectl --kubeconfig "$KC" get node "$CP_NAME" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
    if [[ "$ready" == "True" ]]; then
      ok "node Ready=True: $CP_NAME"
    else
      warn "node not Ready yet: $CP_NAME (Ready=${ready:-<unknown>})"
      kubectl --kubeconfig "$KC" describe node "$CP_NAME" | sed -n '/Conditions:/,/Addresses:/p' || true
    fi

    # Core system pods snapshot
    kubectl --kubeconfig "$KC" get pods -A || warn "kubectl get pods -A failed"

    # Recent events (helps spot issues quickly)
    kubectl --kubeconfig "$KC" get events -A --sort-by=.lastTimestamp | tail -n 30 || true
  fi
fi

log "== VERIFY DONE =="
log "If you see WARNs above, the cluster may still be converging, but core connectivity is verified."
