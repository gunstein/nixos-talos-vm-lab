#!/usr/bin/env bash
set -euo pipefail

# Small shared helpers for the new entrypoint.
# Intentionally minimal to reduce risk.

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

as_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    exec sudo -E "$0" "$@"
  fi
}

# Resolve a script path in a safe way
script_path() {
  local p="$1"
  local full="${ROOT}/${p}"
  [[ -f "$full" ]] || die "Missing file: $full"
  echo "$full"
}
