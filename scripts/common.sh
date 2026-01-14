#!/run/current-system/sw/bin/bash
set -Eeuo pipefail
shopt -s inherit_errexit 2>/dev/null || true
set -o errtrace

# Pretty error reporting (file:line + command)
_on_err() {
  local exit_code="$?"
  local line_no="${BASH_LINENO[0]:-unknown}"
  local src="${BASH_SOURCE[1]:-${BASH_SOURCE[0]:-unknown}}"
  local func="${FUNCNAME[1]:-main}"
  local cmd="${BASH_COMMAND:-unknown}"

  echo >&2
  echo >&2 "[ERROR] exit=${exit_code} at ${src}:${line_no} in ${func}()"
  echo >&2 "        command: ${cmd}"
  echo >&2
  return "$exit_code"
}

# Avoid double-trapping if common.sh is sourced multiple times
if [[ -z "${__COMMON_ERR_TRAP_INSTALLED:-}" ]]; then
  trap _on_err ERR
  __COMMON_ERR_TRAP_INSTALLED=1
fi

# ============================================================================
# Logging
# ============================================================================

TALOS_LAB_VERBOSE="${TALOS_LAB_VERBOSE:-0}"
TALOS_LAB_DEBUG="${TALOS_LAB_DEBUG:-0}"
TALOS_LAB_LOG_DIR="${TALOS_LAB_LOG_DIR:-/var/log/talos-vm-lab}"
TALOS_LAB_LOG_FILE=""
TALOS_LAB_STEP=""

# Colors (disabled if not a terminal)
if [[ -t 1 ]]; then
  _RED='\033[0;31m'
  _YELLOW='\033[0;33m'
  _GREEN='\033[0;32m'
  _BLUE='\033[0;34m'
  _RESET='\033[0m'
else
  _RED='' _YELLOW='' _GREEN='' _BLUE='' _RESET=''
fi

# Internal log function with color support
_log() {
  local level="$1" color="$2"
  shift 2
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local step_prefix=""
  [[ -n "$TALOS_LAB_STEP" ]] && step_prefix="[${TALOS_LAB_STEP}] "
  local msg="${step_prefix}$*"

  # Print to terminal with color
  printf '%b[%s] [%-5s] %s%b\n' "$color" "$ts" "$level" "$msg" "$_RESET"

  # Append to log file if configured
  if [[ -n "$TALOS_LAB_LOG_FILE" && -w "$(dirname "$TALOS_LAB_LOG_FILE")" ]]; then
    printf '[%s] [%-5s] %s\n' "$ts" "$level" "$msg" >> "$TALOS_LAB_LOG_FILE"
  fi
}

log()       { _log "INFO"  "$_GREEN"  "$@"; }
log_info()  { _log "INFO"  "$_GREEN"  "$@"; }
log_warn()  { _log "WARN"  "$_YELLOW" "$@" >&2; }
log_error() { _log "ERROR" "$_RED"    "$@" >&2; }
log_debug() { [[ "$TALOS_LAB_DEBUG" == "1" ]] && _log "DEBUG" "$_BLUE" "$@"; return 0; }

# Set current step name for log context
log_step() {
  TALOS_LAB_STEP="$1"
  log_info "Starting: $1"
}

log_step_done() {
  log_info "Done: ${TALOS_LAB_STEP:-$1}"
  TALOS_LAB_STEP=""
}

log_init() {
  local profile="${1:-unknown}"
  local cmd="${2:-unknown}"
  local log_dir="${TALOS_LAB_LOG_DIR}/${profile}"

  if [[ "$EUID" -eq 0 ]]; then
    mkdir -p "$log_dir" 2>/dev/null || true
    if [[ -d "$log_dir" && -w "$log_dir" ]]; then
      local ts
      ts="$(date +%Y%m%d-%H%M%S)"
      TALOS_LAB_LOG_FILE="${log_dir}/${ts}-${cmd}.log"
      touch "$TALOS_LAB_LOG_FILE" 2>/dev/null || TALOS_LAB_LOG_FILE=""
      if [[ -n "$TALOS_LAB_LOG_FILE" ]]; then
        log_info "Log file: $TALOS_LAB_LOG_FILE"
      fi
    fi
  fi

  if [[ "$TALOS_LAB_DEBUG" == "1" ]]; then
    set -x
  fi
}

# Print next steps on error
log_next_steps() {
  log_error "Something went wrong. Try these diagnostic steps:"
  echo "  1. Check VM status:        sudo ./scripts/lab <profile> status" >&2
  echo "  2. Check libvirt VMs:      sudo virsh list --all" >&2
  echo "  3. Check kubernetes pods:  kubectl get pods -A" >&2
  echo "  4. View this run's log:    ${TALOS_LAB_LOG_FILE:-'(no log file)'}" >&2
  echo "  5. Run doctor:             sudo ./scripts/doctor <profile>" >&2
}

# ============================================================================
# Core utilities
# ============================================================================

# Compute repository root directory
root_dir() {
  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  (cd "$here/.." && pwd)
}

ROOT="$(root_dir)"

die() {
  log_error "$*"
  log_next_steps
  exit 1
}

need() { command -v "$1" >/dev/null 2>&1 || die "Missing dependency: $1"; }

# Safe root escalation (alias for require_root)
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
      TALOS_LAB_VERBOSE="${TALOS_LAB_VERBOSE:-0}" \
      TALOS_LAB_DEBUG="${TALOS_LAB_DEBUG:-0}" \
      TALOS_LAB_LOG_DIR="${TALOS_LAB_LOG_DIR:-/var/log/talos-vm-lab}" \
      "$0" "$@"
  fi
}

# Alias for require_root (backward compatibility)
as_root() { require_root "$@"; }

PROFILE=""
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

# --- Add-ons (lab defaults) ---
# Metrics Server enables `kubectl top nodes/pods`.
METRICS_SERVER_ENABLE=""
METRICS_SERVER_IMAGE=""
METRICS_SERVER_KUBELET_INSECURE_TLS=""
METRICS_SERVER_PREFERRED_ADDRESS_TYPES=""

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

  # --- Add-ons defaults (can be overridden in profiles/<lab>/vars.env) ---
  : "${METRICS_SERVER_ENABLE:=1}"
  : "${METRICS_SERVER_IMAGE:=registry.k8s.io/metrics-server/metrics-server:v0.8.0}"
  # Typical for Talos VM labs (kubelet serving certs not trusted by default).
  : "${METRICS_SERVER_KUBELET_INSECURE_TLS:=1}"
  : "${METRICS_SERVER_PREFERRED_ADDRESS_TYPES:=InternalIP,ExternalIP,Hostname}"

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
  export METRICS_SERVER_ENABLE METRICS_SERVER_IMAGE METRICS_SERVER_KUBELET_INSECURE_TLS METRICS_SERVER_PREFERRED_ADDRESS_TYPES
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
