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

echo "[1/6] Copy repo -> ${TARGET}"
mkdir -p "$TARGET"
rsync -a --delete "${REPO_DIR}/" "${TARGET}/"

echo "[2/6] Set profile = ${PROFILE}"
echo "$PROFILE" > "${TARGET}/PROFILE"
chmod 0644 "${TARGET}/PROFILE"

echo "[3/6] Write /etc/nixos/README.talos-host"
cat > /etc/nixos/README.talos-host <<'EOF'
README – Talos på libvirt via flake (/etc/nixos/talos-host)
===========================================================

Dette systemet er satt opp slik:

  - All konfig og scripts ligger her:
      /etc/nixos/talos-host

  - NixOS bygges fra flake:
      nixos-rebuild switch --flake /etc/nixos/talos-host#nixos-host

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

echo "[4/6] nixos-rebuild switch (flake)"
nixos-rebuild switch --flake "${TARGET}#nixos-host" || die "nixos-rebuild feilet. Sjekk output over."

echo "[5/6] Enable + start bootstrap service"
systemctl enable --now talos-bootstrap.service || die "Klarte ikke enable/start talos-bootstrap.service"

echo "[6/6] Done."
echo "Logs:"
echo "  journalctl -fu talos-bootstrap.service"
echo "Info:"
echo "  cat /etc/nixos/README.talos-host"
