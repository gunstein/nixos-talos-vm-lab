#!/run/current-system/sw/bin/bash
set -euo pipefail

# Repo-root uansett hvor du kjører fra
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Reuse common helpers if present
if [[ -f "$SCRIPT_DIR/common.sh" ]]; then
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/common.sh"
else
  # minimal fallback
  log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }
  die() { echo "ERROR: $*" >&2; exit 1; }
  trim_ws(){ local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }
  load_profile(){ die "Missing scripts/common.sh (expected at $SCRIPT_DIR/common.sh)"; }
  csv_init(){ :; }
  csv_rows(){ :; }
  csv_get(){ :; }
fi

need() { command -v "$1" >/dev/null 2>&1 || die "Missing dependency: $1"; }

# best-effort runner (never exits the script)
run() {
  echo
  echo "--- $* ---"
  set +e
  eval "$@"
  local rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    echo "(rc=$rc)"
  fi
  return 0
}

# like run(), but with timeout to avoid hangs
run_t() {
  local t="$1"; shift
  echo
  echo "--- timeout ${t}s: $* ---"
  set +e
  timeout "${t}s" bash -lc "$*"
  local rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    echo "(rc=$rc)"
  fi
  return 0
}

PROFILE="${1:-}"

# If no profile arg: read repo-root PROFILE file if it exists
if [[ -z "$PROFILE" && -f "$ROOT/PROFILE" ]]; then
  PROFILE="$(cat "$ROOT/PROFILE" | head -n1 | tr -d '\r' | xargs)"
fi

[[ -n "$PROFILE" ]] || die "Usage: sudo $0 <profile>   (e.g. lab1|lab2). Or create $ROOT/PROFILE"

# Load profile vars + nodes.csv indexes
load_profile "$PROFILE"
csv_init

need virsh
need ip
need awk
need sed
need tail
need nc
need timeout

LIBVIRT_URI="${LIBVIRT_URI:-qemu:///system}"

# Find controlplane node from nodes.csv
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

[[ -n "$CP_NAME" && -n "$CP_IP" ]] || die "Could not find controlplane in $PROFILE nodes.csv"

echo "== $(date -u) =="
echo "PROFILE=$PROFILE"
echo "CLUSTER=${TALOS_CLUSTER_NAME:-}"
echo "NET=${TALOS_NET_NAME:-}  BRIDGE=${TALOS_BRIDGE_NAME:-}"
echo "CP_NAME=$CP_NAME  CP_IP=$CP_IP  CP_MAC=$CP_MAC"
echo "TALOS_DIR=${TALOS_DIR:-}  KUBECONFIG_OUT=${KUBECONFIG_OUT:-}"

# Networks overview
run "virsh -c '$LIBVIRT_URI' net-list --all"
run "virsh -c '$LIBVIRT_URI' net-info '${TALOS_NET_NAME}'"
run "virsh -c '$LIBVIRT_URI' net-dumpxml '${TALOS_NET_NAME}' | sed -n '1,120p'"

# Host bridge / routes
run "ip link show '${TALOS_BRIDGE_NAME}'"
run "ip addr show '${TALOS_BRIDGE_NAME}'"
run "ip route | sed -n '1,120p'"

# Domain state
run "virsh -c '$LIBVIRT_URI' domstate '${CP_NAME}' --reason"
run "virsh -c '$LIBVIRT_URI' domiflist '${CP_NAME}'"
run "virsh -c '$LIBVIRT_URI' domblklist '${CP_NAME}' --details"

# on_* policy + console devices (useful when virsh console is blank)
run "virsh -c '$LIBVIRT_URI' dumpxml '${CP_NAME}' | grep -nE '<on_poweroff>|<on_reboot>|<on_crash>|<serial|<console|<graphics' || true"

# DHCP leases
run "virsh -c '$LIBVIRT_URI' net-dhcp-leases '${TALOS_NET_NAME}' || true"

# Ports (Talos + kube-apiserver)
run_t 3 "nc -vz '$CP_IP' 50000"
run_t 3 "nc -vz '$CP_IP' 6443"

# QEMU log tail (if exists)
QLOG="/var/log/libvirt/qemu/${CP_NAME}.log"
run "test -f '$QLOG' && tail -n 120 '$QLOG' || echo 'No qemu log: $QLOG'"

# Talosctl checks (best-effort)
TALOSCONFIG_CANDIDATE=""
if [[ -n "${TALOS_DIR:-}" && -f "${TALOS_DIR}/generated/talosconfig" ]]; then
  TALOSCONFIG_CANDIDATE="${TALOS_DIR}/generated/talosconfig"
elif [[ -f "/root/.talos/config" ]]; then
  TALOSCONFIG_CANDIDATE="/root/.talos/config"
fi

if command -v talosctl >/dev/null 2>&1 && [[ -n "$TALOSCONFIG_CANDIDATE" ]]; then
  run "talosctl --talosconfig '$TALOSCONFIG_CANDIDATE' -e '$CP_IP' -n '$CP_IP' version || true"
  run "talosctl --talosconfig '$TALOSCONFIG_CANDIDATE' -e '$CP_IP' -n '$CP_IP' health || true"
else
  echo
  echo "--- talosctl ---"
  echo "talosctl not found OR no talosconfig found (looked for \$TALOS_DIR/generated/talosconfig or /root/.talos/config)"
fi

# kubectl checks (best-effort)
KCFG=""
if [[ -n "${SUDO_USER:-}" && -f "/home/${SUDO_USER}/.kube/config" ]]; then
  KCFG="/home/${SUDO_USER}/.kube/config"
elif [[ -f "/root/.kube/config" ]]; then
  KCFG="/root/.kube/config"
elif [[ -n "${KUBECONFIG_OUT:-}" && -f "${KUBECONFIG_OUT}" ]]; then
  KCFG="${KUBECONFIG_OUT}"
fi

if command -v kubectl >/dev/null 2>&1 && [[ -n "$KCFG" ]]; then
  run "kubectl --kubeconfig '$KCFG' get nodes -o wide || true"
  run "kubectl --kubeconfig '$KCFG' get pods -A || true"
else
  echo
  echo "--- kubectl ---"
  echo "kubectl not found OR kubeconfig not found"
fi

echo
echo "== DONE =="
echo "Tip: run like this:"
echo "  sudo $0 lab1"
echo "  sudo $0 lab2"
