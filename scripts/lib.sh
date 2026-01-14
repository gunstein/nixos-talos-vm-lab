#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR() {
  cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd
}

ROOT="$(ROOT_DIR)"

# Logging configuration
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

# Internal log function
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

log_info() {
  _log "INFO" "$_GREEN" "$@"
}

log_warn() {
  _log "WARN" "$_YELLOW" "$@" >&2
}

log_error() {
  _log "ERROR" "$_RED" "$@" >&2
}

log_debug() {
  [[ "$TALOS_LAB_DEBUG" == "1" ]] && _log "DEBUG" "$_BLUE" "$@"
  return 0
}

# Backward-compatible log function
log() {
  log_info "$@"
}

# Set current step name for log context
log_step() {
  TALOS_LAB_STEP="$1"
  log_info "Starting: $1"
}

log_step_done() {
  log_info "Done: ${TALOS_LAB_STEP:-$1}"
  TALOS_LAB_STEP=""
}

# Initialize logging for a run
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

  # Enable debug mode if requested
  if [[ "$TALOS_LAB_DEBUG" == "1" ]]; then
    set -x
  fi
}

# Print next steps on error
log_next_steps() {
  log_error "Something went wrong. Try these diagnostic steps:"
  echo "  1. Check VM status:        sudo ./scripts/lab.sh <profile> status" >&2
  echo "  2. Check libvirt VMs:      sudo virsh list --all" >&2
  echo "  3. Check kubernetes pods:  kubectl --kubeconfig=<kubeconfig> get pods -A" >&2
  echo "  4. View this run's log:    ${TALOS_LAB_LOG_FILE:-'(no log file)'}" >&2
  echo "  5. Check VM console:       sudo virsh vncdisplay <vm-name>" >&2
}

die() {
  log_error "$*"
  log_next_steps
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing dependency: $1"
}

# Safe root escalation:
# - no sudo -E (prevents toxic env / SHLVL explosions)
# - minimal env via env -i
# - guard prevents recursion
# - passes through TALOS_LAB_* logging config
as_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
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

script_path() {
  local p="$1"
  local full="${ROOT}/${p}"
  [[ -f "$full" ]] || die "Missing file: $full"
  echo "$full"
}
