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

# Source version pins
# shellcheck source=../versions.env
source "${REPO_ROOT}/versions.env"

# --- Cleanup old NixOS generations to free disk space ---
cleanup_nix() {
  local avail_gb
  avail_gb=$(df -BG / | awk 'NR==2 {print $4}' | tr -d 'G')

  if [[ "$avail_gb" -lt 5 ]]; then
    log "Low disk space (${avail_gb}GB). Running nix garbage collection..."
    nix-collect-garbage -d 2>/dev/null || true

    # Show new available space
    local new_avail
    new_avail=$(df -BG / | awk 'NR==2 {print $4}' | tr -d 'G')
    log "Freed $((new_avail - avail_gb))GB. Now ${new_avail}GB available."
  elif [[ "$avail_gb" -lt 10 ]]; then
    log "Disk space getting low (${avail_gb}GB). Consider running: sudo nix-collect-garbage -d"
  fi
}

cleanup_nix
TARGET="/etc/nixos/talos-host"

HW_SRC="/etc/nixos/hardware-configuration.nix"
HW_DST="${TARGET}/hosts/hardware-configuration.nix"

ISO_NAME="metal-amd64.iso"
ISO_REPO="${REPO_ROOT}/assets/${ISO_NAME}"
ISO_DST="${TARGET}/assets/${ISO_NAME}"

# --- Idempotent sync ---
log "Sync repo -> ${TARGET}"
mkdir -p "$TARGET"

# Show what will change (dry-run first for visibility)
CHANGES="$(rsync -a --delete --exclude '.git/' --dry-run --itemize-changes "${REPO_ROOT}/" "${TARGET}/" 2>/dev/null | head -20 || true)"
if [[ -n "$CHANGES" ]]; then
  log "Changes to apply:"
  echo "$CHANGES" | sed 's/^/  /'
  [[ $(echo "$CHANGES" | wc -l) -ge 20 ]] && log "  ... (truncated)"
else
  log "No file changes detected"
fi

rsync -a --delete \
  --exclude '.git/' \
  "${REPO_ROOT}/" "${TARGET}/"

# --- hardware-configuration.nix ---
log "Ensure hardware-configuration.nix is present"
mkdir -p "$(dirname "$HW_DST")"
[[ -f "$HW_SRC" ]] || die "Missing ${HW_SRC}"
if [[ -f "$HW_DST" ]] && cmp -s "$HW_SRC" "$HW_DST"; then
  log "hardware-configuration.nix unchanged"
else
  cp -f "$HW_SRC" "$HW_DST"
  log "hardware-configuration.nix updated"
fi

# --- secrets folder ---
if [[ -d /etc/nixos/secrets ]]; then
  log "Secrets folder already exists"
else
  mkdir -p /etc/nixos/secrets
  log "Created secrets folder"
fi

# --- scripts executable ---
log "Ensure scripts are executable"
chmod +x "${TARGET}/scripts/"*.sh 2>/dev/null || true
chmod +x "${TARGET}/scripts/lab" 2>/dev/null || true
chmod +x "${TARGET}/scripts/doctor" 2>/dev/null || true

# --- Talos ISO ---
log "Ensure Talos ISO is present in deploy tree"
mkdir -p "${TARGET}/assets"
if [[ -f "$ISO_REPO" ]]; then
  if [[ -f "$ISO_DST" ]] && cmp -s "$ISO_REPO" "$ISO_DST"; then
    log "ISO unchanged: ${ISO_DST}"
  else
    install -m 0644 "$ISO_REPO" "$ISO_DST"
    log "ISO installed: ${ISO_DST}"
  fi
else
  if [[ -f "$ISO_DST" ]]; then
    log "Using existing ISO: ${ISO_DST}"
  else
    log "WARN: ISO not found. Download with:"
    log "  curl -L -o ${ISO_REPO} https://github.com/siderolabs/talos/releases/download/${TALOS_VERSION}/metal-amd64.iso"
  fi
fi

# --- NixOS rebuild ---
if [[ "${NO_REBUILD:-0}" == "1" ]]; then
  log "NO_REBUILD=1 -> skipping nixos-rebuild switch"
else
  log "Running nixos-rebuild switch (idempotent)"
  nixos-rebuild switch --flake "path:${TARGET}#nixos-host"
fi

log "Done."
log ""
log "Next steps:"
log "  cd ${TARGET}"
log "  sudo ./scripts/doctor lab1     # Check prerequisites"
log "  sudo ./scripts/lab lab1 plan   # Preview what will happen"
log "  sudo ./scripts/lab lab1 all    # Full setup"
