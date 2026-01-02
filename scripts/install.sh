#!/run/current-system/sw/bin/bash
set -euo pipefail

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    exec sudo env -i \
      HOME=/root \
      PATH=/run/current-system/sw/bin:/usr/bin:/bin \
      TERM="${TERM:-xterm-256color}" \
      "$0" "$@"
  fi
}

require_root "$@"

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

log "Ensure Talos ISO is present in deploy tree"
mkdir -p "${TARGET}/assets"
if [[ -f "$ISO_REPO" ]]; then
  install -m 0644 "$ISO_REPO" "$ISO_DST"
  log "ISO OK: ${ISO_DST}"
else
  log "WARN: ISO not found in repo: ${ISO_REPO}"
fi

if [[ "${NO_REBUILD:-0}" == "1" ]]; then
  log "NO_REBUILD=1 -> skipping nixos-rebuild switch"
else
  log "nixos-rebuild switch"
  nixos-rebuild switch --flake "path:${TARGET}#nixos-host"
fi

log "Done."
log ""
log "Next steps (run from canonical deploy tree):"
log "  cd ${TARGET}"
log "  sudo ./scripts/lab lab1 wipe"
log "  sudo ./scripts/lab lab1 all"
