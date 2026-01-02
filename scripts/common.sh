#!/run/current-system/sw/bin/bash
set -euo pipefail

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "Missing dependency: $1"; }

# Safe root escalation:
# - no sudo -E
# - no "bash $0" (run script directly; rely on shebang)
# - minimal env (env -i)
# - guard prevents recursion
require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    command -v sudo >/dev/null 2>&1 || die "Must run as root (sudo missing)."
    if [[ "${TALOS_HOST_SUDO_GUARD:-}" == "1" ]]; then
      die "Refusing to sudo again (guard hit). A wrapper/script is looping."
    fi

    exec sudo env -i \
      TALOS_HOST_SUDO_GUARD=1 \
      HOME=/root \
      PATH=/run/current-system/sw/bin:/usr/bin:/bin \
      TERM="${TERM:-xterm-256color}" \
      "$0" "$@"
  fi
}

root_dir() {
  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  (cd "$here/.." && pwd)
}

PROFILE=""
ROOT=""
PROFILE_DIR=""
VARS_ENV=""
NODES_CSV=""

LIBVIRT_URI="qemu:///system"
TALOS_NET_NAME=""
TALOS_BRIDGE_NAME=""
TALOS_GATEWAY=""
TALOS_DHCP_START=""
TALOS_DHCP_END=""
TALOS_CLUSTER_NAME=""
TALOS_DIR=""
KUBECONFIG_OUT=""
ISO=""

DISK_DIR="/var/lib/libvirt/images"

ensure_disk_dir() { mkdir -p "${DISK_DIR}"; }

load_profile() {
  PROFILE="${1:-}"
  [[ -n "$PROFILE" ]] || die "Usage: <script> <profile> (e.g. lab1|lab2)"

  ROOT="$(root_dir)"
  PROFILE_DIR="$ROOT/profiles/$PROFILE"
  VARS_ENV="$PROFILE_DIR/vars.env"
  NODES_CSV="$PROFILE_DIR/nodes.csv"

  [[ -d "$PROFILE_DIR" ]] || die "Missing profile dir: $PROFILE_DIR"
  [[ -f "$VARS_ENV" ]] || die "Missing: $VARS_ENV"
  [[ -f "$NODES_CSV" ]] || die "Missing: $NODES_CSV"

  # shellcheck disable=SC1090
  source "$VARS_ENV"

  : "${LIBVIRT_URI:=qemu:///system}"
  : "${DISK_DIR:=/var/lib/libvirt/images}"

  [[ -n "${TALOS_NET_NAME:-}" ]] || die "vars.env missing TALOS_NET_NAME"
  [[ -n "${TALOS_GATEWAY:-}" ]] || die "vars.env missing TALOS_GATEWAY"
  [[ -n "${TALOS_DHCP_START:-}" ]] || die "vars.env missing TALOS_DHCP_START"
  [[ -n "${TALOS_DHCP_END:-}" ]] || die "vars.env missing TALOS_DHCP_END"
  [[ -n "${TALOS_CLUSTER_NAME:-}" ]] || die "vars.env missing TALOS_CLUSTER_NAME"

  : "${TALOS_BRIDGE_NAME:=virbr-${TALOS_NET_NAME}}"

  : "${TALOS_DIR:=/var/lib/${TALOS_CLUSTER_NAME}}"
  : "${KUBECONFIG_OUT:=/root/.kube/${TALOS_CLUSTER_NAME}.config}"

  if [[ -z "${ISO:-}" ]]; then
    if [[ -f "${ROOT}/assets/metal-amd64.iso" ]]; then
      ISO="${ROOT}/assets/metal-amd64.iso"
    elif [[ -f "${DISK_DIR}/metal-amd64.iso" ]]; then
      ISO="${DISK_DIR}/metal-amd64.iso"
    else
      ISO="${ROOT}/assets/metal-amd64.iso"
    fi
  fi

  export PROFILE ROOT PROFILE_DIR VARS_ENV NODES_CSV
  export LIBVIRT_URI DISK_DIR
  export TALOS_NET_NAME TALOS_BRIDGE_NAME TALOS_GATEWAY TALOS_DHCP_START TALOS_DHCP_END TALOS_CLUSTER_NAME
  export TALOS_DIR KUBECONFIG_OUT ISO
}

declare -A CSV_IDX

trim_ws() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

csv_init() {
  local header
  header="$(head -n1 "$NODES_CSV")"
  header="$(trim_ws "${header%%#*}")"

  IFS=',' read -r -a cols <<< "$header"
  CSV_IDX=()
  for i in "${!cols[@]}"; do
    cols[$i]="$(trim_ws "${cols[$i]}")"
    CSV_IDX["${cols[$i]}"]="$i"
  done

  for required in name role ip mac disk_gb ram_mb vcpus; do
    [[ -n "${CSV_IDX[$required]:-}" ]] || die "nodes.csv missing required column: $required"
  done
}

csv_rows() {
  tail -n +2 "$NODES_CSV" \
    | sed -e 's/\r$//' \
    | awk '
      function trim(s){ sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
      {
        line=$0
        line=trim(line)
        if (line=="") next
        if (substr(line,1,1)=="#") next
        sub(/#.*/, "", line)
        line=trim(line)
        if (line=="") next
        print line
      }'
}

csv_get() {
  local row="$1" col="$2"
  local idx="${CSV_IDX[$col]:-}"
  [[ -n "$idx" ]] || die "csv_get: unknown column '$col'"

  IFS=',' read -r -a parts <<< "$row"
  local v="${parts[$idx]:-}"
  v="$(trim_ws "$v")"
  printf '%s' "$v"
}

wait_port() {
  local ip="$1" port="$2" timeout_s="${3:-180}"
  local start now
  start="$(date +%s)"
  while true; do
    if nc -w 1 -z "$ip" "$port" >/dev/null 2>&1; then
      return 0
    fi
    now="$(date +%s)"
    if (( now - start >= timeout_s )); then
      return 1
    fi
    sleep 2
  done
}
