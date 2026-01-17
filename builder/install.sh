#!/usr/bin/env bash
# Install script for builder-VM (nixos-control)
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
log "Running nixos-rebuild switch --flake path:${REPO_ROOT}#builder-vm"
nixos-rebuild switch --flake "path:${REPO_ROOT}#builder-vm"

# Now install Python package as the original user
ORIG_USER="${SUDO_USER:-gunstein}"
ORIG_HOME=$(eval echo "~$ORIG_USER")

log "Installing labctl package for user $ORIG_USER"
cd "$SCRIPT_DIR"

# Create and use a virtual environment
VENV_DIR="${ORIG_HOME}/.venv/labctl"
if [[ ! -d "$VENV_DIR" ]]; then
    log "Creating virtual environment at $VENV_DIR"
    sudo -u "$ORIG_USER" python3 -m venv "$VENV_DIR"
fi

# Upgrade pip first
log "Upgrading pip"
sudo -u "$ORIG_USER" "$VENV_DIR/bin/pip" install --upgrade pip

# Install in the venv
sudo -u "$ORIG_USER" "$VENV_DIR/bin/pip" install -e ".[test]"

# Create symlink to labctl in ~/.local/bin
LOCALBIN="${ORIG_HOME}/.local/bin"
sudo -u "$ORIG_USER" mkdir -p "$LOCALBIN"
ln -sf "$VENV_DIR/bin/labctl" "$LOCALBIN/labctl"

# Create config directory and file
CONFIG_DIR="${ORIG_HOME}/.config/labctl"
CONFIG_FILE="${CONFIG_DIR}/config.toml"

sudo -u "$ORIG_USER" mkdir -p "$CONFIG_DIR"

if [[ ! -f "$CONFIG_FILE" ]]; then
    log "Creating config file at $CONFIG_FILE"
    cat > "$CONFIG_FILE" << 'EOF'
# labctl configuration
# See: labctl config

[lab]
profile = "lab1"
local_repo = "~/nixos-talos-vm-lab"

[nixos-host]
# Set this to the IP address of nixos-host
host = "nixos-host"
user = "gunstein"
# port = 22
# ssh_key = "~/.ssh/id_rsa"

[tunnel]
local_port = 8443
remote_port = 443

# [github]
# repo = "gunstein/nixos-talos-vm-lab"
# branch = "main"
EOF
    chown "$ORIG_USER:$(id -gn "$ORIG_USER")" "$CONFIG_FILE"
    log "Edit $CONFIG_FILE to set nixos-host IP address"
else
    log "Config file already exists: $CONFIG_FILE"
fi

# Ensure PATH includes ~/.local/bin
BASHRC="${ORIG_HOME}/.bashrc"
if ! grep -q '\.local/bin' "$BASHRC" 2>/dev/null; then
    log "Adding ~/.local/bin to PATH in .bashrc"
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$BASHRC"
fi

log ""
log "Installation complete!"
log ""
log "Next steps:"
log "  1. Edit config file with nixos-host IP:"
log "     nano ~/.config/labctl/config.toml"
log ""
log "  2. Ensure SSH access to nixos-host:"
log "     ssh-copy-id gunstein@<nixos-host-ip>"
log ""
log "  3. Reload shell (or run: source ~/.bashrc)"
log ""
log "  4. Test connection:"
log "     labctl config       # Show current config"
log "     labctl provision status"
log ""
log "  5. Deploy and provision lab:"
log "     labctl deploy"
log "     labctl provision all"
