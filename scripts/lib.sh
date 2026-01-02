#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR() {
  cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd
}

ROOT="$(ROOT_DIR)"

log() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing dependency: $1"
}

# Safe root escalation:
# - no sudo -E (prevents toxic env / SHLVL explosions)
# - minimal env via env -i
# - guard prevents recursion
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
      "$0" "$@"
  fi
}

script_path() {
  local p="$1"
  local full="${ROOT}/${p}"
  [[ -f "$full" ]] || die "Missing file: $full"
  echo "$full"
}
