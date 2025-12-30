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

PROFILE="${1:-}"
[[ -n "$PROFILE" ]] || die "Usage: sudo ./scripts/install.sh <profile>  (e.g. lab1|lab2)"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="/etc/nixos/talos-host"

HW_SRC="/etc/nixos/hardware-configuration.nix"
HW_DST="${TARGET}/hosts/hardware-configuration.nix"

ISO_NAME="metal-amd64.iso"
ISO_REPO="${REPO_ROOT}/assets/${ISO_NAME}"
ISO_DST="${TARGET}/assets/${ISO_NAME}"

log "Sync repo -> ${TARGET}"
mkdir -p "$TARGET"

# Keep your existing rsync style. If you already exclude *.iso/assets, that's OK,
# because we will explicitly copy ISO afterwards.
rsync -a --delete \
  --exclude '.git/' \
  "${REPO_ROOT}/" "${TARGET}/"

log "Write active profile"
echo "$PROFILE" > "${TARGET}/PROFILE"

log "Ensure hardware-configuration.nix is present"
mkdir -p "$(dirname "$HW_DST")"
[[ -f "$HW_SRC" ]] || die "Missing ${HW_SRC}"
cp -f "$HW_SRC" "$HW_DST"

log "Ensure secrets folder exists"
mkdir -p /etc/nixos/secrets

log "Make scripts executable"
chmod +x "${TARGET}/scripts/"*.sh 2>/dev/null || true

log "Ensure Talos ISO is present in deploy tree"
mkdir -p "${TARGET}/assets"

# Source of truth: your repo path in /home/gunstein/nixos-talos-vm-lab/assets
[[ -f "$ISO_REPO" ]] || die "Missing ISO in repo: ${ISO_REPO}"

# Always (re)copy to deploy target so lab.sh can find it at /etc/nixos/talos-host/assets
install -m 0644 "$ISO_REPO" "$ISO_DST"
log "ISO OK: ${ISO_DST}"

log "nixos-rebuild switch"
nixos-rebuild switch --flake "path:${TARGET}#nixos-host"

log "Done."
log ""
log "Next steps (choose ONE path):"
log ""
log "A) Recommended if this is the first run for this profile, or if you've had errors/drift:"
log "   sudo ${TARGET}/scripts/lab.sh ${PROFILE} wipe"
log "   sudo ${TARGET}/scripts/lab.sh ${PROFILE} all"
log ""
log "B) Minimal steps if you're confident the profile is already clean:"
log "   sudo ${TARGET}/scripts/lab.sh ${PROFILE} up"
log "   sudo ${TARGET}/scripts/lab.sh ${PROFILE} provision"
