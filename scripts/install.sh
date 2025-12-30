#!/run/current-system/sw/bin/bash
set -euo pipefail

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    exec sudo -E bash "$0" "$@"
  fi
}

require_root "$@"

# Best practice:
# - install.sh is deploy + rebuild only (no lab selection, no lab execution)
# - labs are controlled explicitly via scripts/lab

# Backwards compatibility: allow an optional argument but ignore it.
if [[ $# -ge 1 ]]; then
  log "WARN: install.sh no longer takes a <profile>. Ignoring argument(s): $*"
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="/etc/nixos/talos-host"

HW_SRC="/etc/nixos/hardware-configuration.nix"
HW_DST="${TARGET}/hosts/hardware-configuration.nix"

ISO_NAME="metal-amd64.iso"
ISO_REPO="${REPO_ROOT}/assets/${ISO_NAME}"
ISO_DST="${TARGET}/assets/${ISO_NAME}"

log "Sync repo -> ${TARGET}"
mkdir -p "$TARGET"

# Keep rsync deploy model.
# If you later add large artifacts to .gitignore, they will not be deployed unless explicitly copied.
rsync -a --delete \
  --exclude '.git/' \
  "${REPO_ROOT}/" "${TARGET}/"

log "Ensure hardware-configuration.nix is present"
mkdir -p "$(dirname "$HW_DST")"
[[ -f "$HW_SRC" ]] || die "Missing ${HW_SRC}"
cp -f "$HW_SRC" "$HW_DST"

log "Ensure secrets folder exists"
mkdir -p /etc/nixos/secrets

log "Make scripts executable"
chmod +x "${TARGET}/scripts/"*.sh 2>/dev/null || true
chmod +x "${TARGET}/scripts/lab" 2>/dev/null || true
chmod +x "${TARGET}/scripts/steps/"*.sh 2>/dev/null || true

log "Ensure Talos ISO is present in deploy tree"
mkdir -p "${TARGET}/assets"

if [[ -f "$ISO_REPO" ]]; then
  # Always (re)copy to deploy target so scripts can find it at /etc/nixos/talos-host/assets
  install -m 0644 "$ISO_REPO" "$ISO_DST"
  log "ISO OK: ${ISO_DST}"
else
  log "WARN: ISO not found in repo: ${ISO_REPO}"
  log "WARN: If your scripts require an ISO, place it at: ${ISO_REPO}"
  log "WARN: (We do not store ISOs in git; they are treated as build artifacts.)"
fi

log "nixos-rebuild switch"
nixos-rebuild switch --flake "path:${TARGET}#nixos-host"

log "Done."
log ""
log "Next steps (explicit lab control):"
log "  sudo ${TARGET}/scripts/lab lab1 all"
log "  sudo ${TARGET}/scripts/lab lab2 all"
log ""
log "Switch labs safely (wipes both source + target first):"
log "  sudo ${TARGET}/scripts/lab switch lab1 lab2"
log ""
log "Diagnostics:"
log "  sudo ${TARGET}/scripts/lab lab1 diag"
