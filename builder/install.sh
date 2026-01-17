#!/usr/bin/env bash
# Install script for builder-VM
# Sets up NixOS configuration and Python environment
set -euo pipefail

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Require root for NixOS rebuild
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    exec sudo "$0" "$@"
fi

# Check if running on NixOS
if [[ ! -f /etc/NIXOS ]]; then
    die "This install script is for NixOS. For other systems, install Python 3.11+ and run: pip install -e .[test]"
fi

log "Detected NixOS"

# Ensure hardware-configuration.nix exists
HW_SRC="/etc/nixos/hardware-configuration.nix"
HW_DST="${REPO_ROOT}/hosts/hardware-configuration.nix"

if [[ ! -f "$HW_DST" ]]; then
    if [[ -f "$HW_SRC" ]]; then
        log "Copying hardware-configuration.nix"
        cp "$HW_SRC" "$HW_DST"
    else
        die "Missing ${HW_SRC}. Run nixos-generate-config first."
    fi
fi

# Run nixos-rebuild
log "Running nixos-rebuild switch --flake ${REPO_ROOT}#builder-vm"
nixos-rebuild switch --flake "${REPO_ROOT}#builder-vm"

# Now install Python package as the original user
ORIG_USER="${SUDO_USER:-gunstein}"
ORIG_HOME=$(eval echo "~$ORIG_USER")

log "Installing labctl package for user $ORIG_USER"
cd "$SCRIPT_DIR"

# Install as the original user
sudo -u "$ORIG_USER" pip3 install --user -e ".[test]"

log ""
log "Installation complete!"
log ""
log "Next steps:"
log "  1. Ensure SSH access to nixos-host:"
log "     ssh-copy-id gunstein@<nixos-host-ip>"
log ""
log "  2. Set environment variables (add to ~/.bashrc):"
log "     export NIXOS_HOST=<nixos-host-ip>"
log "     export NIXOS_USER=gunstein"
log "     export LAB_PROFILE=lab1"
log "     export PATH=\"\$HOME/.local/bin:\$PATH\""
log ""
log "  3. Test connection:"
log "     labctl provision status"
log ""
log "  4. Deploy and provision lab:"
log "     labctl deploy --local ~/nixos-talos-vm-lab"
log "     labctl provision all"
log ""
log "  5. Run tests:"
log "     labctl test --smoke"
