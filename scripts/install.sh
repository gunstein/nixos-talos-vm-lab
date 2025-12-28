#!/usr/bin/env bash
set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }

PROFILE="${1:-lab1}"

# Re-exec as root if needed
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  command -v sudo >/dev/null 2>&1 || die "Må kjøres som root (sudo mangler)."
  exec sudo -E bash "$0" "$@"
fi

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="/etc/nixos/talos-host"
ISO="${REPO_DIR}/assets/metal-amd64.iso"

[[ -f "$ISO" ]] || die "Mangler ISO: $ISO. Du må scp'e metal-amd64.iso til assets/."
[[ -s "$ISO" ]] || die "ISO finnes men er tom (0 bytes): $ISO"
[[ -d "${REPO_DIR}/profiles/${PROFILE}" ]] || die "Ukjent profil: ${PROFILE} (finnes ikke i profiles/)."

command -v nixos-rebuild >/dev/null 2>&1 || die "nixos-rebuild mangler. Er dette en NixOS-maskin?"

echo "[1/7] Copy repo -> ${TARGET}"
mkdir -p "$TARGET"
rsync -a --delete "${REPO_DIR}/" "${TARGET}/"

# Make the target flake self-contained on this host by copying the current HW config
HW_SRC="/etc/nixos/hardware-configuration.nix"
HW_DST="${TARGET}/hosts/hardware-configuration.nix"

echo "[2/7] Ensure hardware-configuration.nix exists in ${TARGET}"
[[ -f "$HW_SRC" ]] || die "Mangler ${HW_SRC}. Har du kjørt nixos-generate-config på denne maskinen?"

mkdir -p "$(dirname "$HW_DST")"

# Default: only create if missing.
# If you want to force update, run: FORCE_HWCONFIG=1 ./install.sh lab1
if [[ ! -f "$HW_DST" ]]; then
  cp -f "$HW_SRC" "$HW_DST"
  chmod 0644 "$HW_DST"
  echo "  Copied ${HW_SRC} -> ${HW_DST}"
else
  if [[ "${FORCE_HWCONFIG:-0}" == "1" ]]; then
    cp -f "$HW_SRC" "$HW_DST"
    chmod 0644 "$HW_DST"
    echo "  Updated ${HW_DST} (FORCE_HWCONFIG=1)"
  else
    echo "  Keeping existing ${HW_DST} (set FORCE_HWCONFIG=1 to overwrite)"
  fi
fi

echo "[3/7] Set profile = ${PROFILE}"
echo "$PROFILE" > "${TARGET}/PROFILE"
chmod 0644 "${TARGET}/PROFILE"

echo "[4/7] Write /etc/nixos/README.talos-host"
cat > /etc/nixos/README.talos-host <<'EOF'
README – Talos på libvirt via flake (/etc/nixos/talos-host)
===========================================================

Dette systemet er satt opp slik:

  - All konfig og scripts ligger her:
      /etc/nixos/talos-host

  - NixOS bygges fra flake:
      nixos-rebuild switch --flake path:/etc/nixos/talos-host#nixos-host

  - Hvilken "profil" som brukes (lab1/lab2/...) ligger her:
      cat /etc/nixos/talos-host/PROFILE

Profiler
--------
Profiler er i:
  /etc/nixos/talos-host/profiles/<profil>/

Typisk inneholder en profil:
  - vars.env    (nett, subnet, paths, kubeconfig-output)
  - nodes.csv   (Talos VM-noder: start med 1 node, legg til flere ved å uncommente/legge til linjer)

Bootstrap
---------
Bootstrap kjører som systemd-service:
  systemctl status talos-bootstrap.service
  journalctl -fu talos-bootstrap.service

Manuell re-run (idempotent):
  systemctl start talos-bootstrap.service

Verifisering
------------
  /etc/nixos/talos-host/scripts/talos-verify.sh <profil>

Kubeconfig per profil (eksempel):
  kubectl --kubeconfig /root/.kube/talos-lab-1.config get nodes -o wide

Vanlige feilsøk
---------------
- Sjekk libvirt nett og VMer:
    virsh --connect qemu:///system net-list --all
    virsh --connect qemu:///system list --all

- Sjekk DHCP-leases (på riktig nett):
    virsh --connect qemu:///system net-dhcp-leases <talosnetNavn>

- Sjekk porter:
    nc -vz <cp1-ip> 50000
    nc -vz <cp1-ip> 6443
EOF
chmod 0644 /etc/nixos/README.talos-host

echo "[5/7] nixos-rebuild switch (flake)"
nixos-rebuild switch --flake "path:${TARGET}#nixos-host" || die "nixos-rebuild feilet. Sjekk output over."

echo "[6/7] Enable + start bootstrap service"
systemctl enable --now talos-bootstrap.service || die "Klarte ikke enable/start talos-bootstrap.service"

echo "[7/7] Done."
echo "Logs:"
echo "  journalctl -fu talos-bootstrap.service"
echo "Info:"
echo "  cat /etc/nixos/README.talos-host"
