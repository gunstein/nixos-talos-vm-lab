# =====================================================================
# FILE: /home/gunstein/nixos-talos-vm-lab/scripts/install.sh
# (rsync -> /etc/nixos/talos-host/scripts/install.sh)
# =====================================================================
#!/run/current-system/sw/bin/bash
set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }

PROFILE="${1:-lab1}"

# Optional behavior:
#   WIPE=1       -> run wipe-lab.sh <profile> before bootstrap/provision (destructive)
#   USE_SYSTEMD=1 -> also restart systemd units at the end (optional)
WIPE="${WIPE:-0}"
USE_SYSTEMD="${USE_SYSTEMD:-0}"

# Re-exec as root if needed
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  command -v sudo >/dev/null 2>&1 || die "Must run as root (sudo is missing)."
  exec sudo -E bash "$0" "$@"
fi

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="/etc/nixos/talos-host"
ISO="${REPO_DIR}/assets/metal-amd64.iso"

HOST_HW_SRC="/etc/nixos/hardware-configuration.nix"
HOST_HW_DST="${TARGET}/hosts/hardware-configuration.nix"

SECRETS_DIR="/etc/nixos/secrets"
PASSFILE="${SECRETS_DIR}/gunstein.passwd"

[[ -d "${REPO_DIR}/profiles/${PROFILE}" ]] || die "Unknown profile: ${PROFILE} (missing profiles/${PROFILE})."
[[ -f "$ISO" ]] || die "Missing Talos ISO: ${ISO} (copy metal-amd64.iso into assets/)."
[[ -s "$ISO" ]] || die "Talos ISO exists but is empty (0 bytes): ${ISO}."
[[ -f "$HOST_HW_SRC" ]] || die "Missing ${HOST_HW_SRC}. Did you run nixos-generate-config during install?"
command -v nixos-rebuild >/dev/null 2>&1 || die "nixos-rebuild not found. Are you on NixOS?"

log "[1/8] Sync repo -> ${TARGET}"
mkdir -p "$TARGET"
rsync -a --delete --exclude '.git' "${REPO_DIR}/" "${TARGET}/"

log "[2/8] Ensure hardware-configuration.nix exists in ${TARGET}"
mkdir -p "$(dirname "$HOST_HW_DST")"
cp -f "$HOST_HW_SRC" "$HOST_HW_DST"
chmod 0644 "$HOST_HW_DST"
log "  Copied ${HOST_HW_SRC} -> ${HOST_HW_DST}"

log "[3/8] Ensure password hash file exists (host-local secret)"
mkdir -p "$SECRETS_DIR"
chmod 0700 "$SECRETS_DIR"

if [[ ! -s "$PASSFILE" ]]; then
  if grep -qE '^gunstein:' /etc/shadow; then
    HASH="$(awk -F: '$1=="gunstein"{print $2}' /etc/shadow)"
    if [[ -n "$HASH" ]]; then
      printf '%s\n' "$HASH" > "$PASSFILE"
      chmod 0600 "$PASSFILE"
      log "  Created ${PASSFILE} from existing /etc/shadow hash."
    else
      printf '%s\n' '!' > "$PASSFILE"
      chmod 0600 "$PASSFILE"
      log "  Created ${PASSFILE} with locked password ('!'). Run: passwd gunstein"
    fi
  else
    printf '%s\n' '!' > "$PASSFILE"
    chmod 0600 "$PASSFILE"
    log "  Created ${PASSFILE} with locked password ('!'). Run: passwd gunstein"
  fi
else
  log "  Found existing ${PASSFILE}"
fi

log "[4/8] Set active profile = ${PROFILE}"
echo "$PROFILE" > "${TARGET}/PROFILE"
chmod 0644 "${TARGET}/PROFILE"

log "[5/8] Make scripts executable"
chmod +x "${TARGET}/scripts/"*.sh || true

log "[6/8] nixos-rebuild switch (flake) (non-fatal if units fail)"
set +e
nixos-rebuild switch --flake "path:${TARGET}#nixos-host"
REBUILD_RC=$?
set -e
if [[ $REBUILD_RC -ne 0 ]]; then
  log "WARN: nixos-rebuild returned rc=$REBUILD_RC (often caused by failing systemd units). Continuing with deterministic scripts..."
fi

# Prevent restart-loop/rate-limit from masking real failures
systemctl reset-failed talos-bootstrap.service talos-provision.service >/dev/null 2>&1 || true

log "[7/8] Optional wipe (destructive) + deterministic bootstrap/provision"
if [[ "$WIPE" == "1" ]]; then
  log "WIPE=1 -> wiping profile '${PROFILE}'"
  "${TARGET}/scripts/wipe-lab.sh" "$PROFILE"
else
  log "WIPE=0 -> skipping wipe"
fi

"${TARGET}/scripts/talos-bootstrap.sh" "$PROFILE"
"${TARGET}/scripts/talos-provision.sh" "$PROFILE"

log "[8/8] Optional systemd restart (not required)"
if [[ "$USE_SYSTEMD" == "1" ]]; then
  systemctl restart talos-bootstrap.service || true
  systemctl restart talos-provision.service || true
  log "USE_SYSTEMD=1 -> restarted talos-bootstrap/provision units"
else
  log "USE_SYSTEMD=0 -> not restarting units"
fi

log "Done."
