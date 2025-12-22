#!/usr/bin/env bash
set -euo pipefail

# talos-verify.sh
# Verifiserer en profil (lab1/lab2/...) som bootstrapper Talos på libvirt.
#
# Bruk:
#   sudo /etc/nixos/talos-host/scripts/talos-verify.sh lab1
#   sudo /etc/nixos/talos-host/scripts/talos-verify.sh lab2
#
# Den:
#  - Leser profil fra /etc/nixos/talos-host/profiles/<profile>/vars.env + nodes.csv
#  - Finner CP1 (første controlplane i nodes.csv)
#  - Sjekker libvirt-nett + leases
#  - Sjekker ping + porter 50000/6443
#  - Kjører talosctl health
#  - Kjører kubectl get nodes -o wide med riktig kubeconfig

die() { echo "ERROR: $*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Mangler kommando: $1"; }

wait_ping() {
  local ip="$1" timeout_s="${2:-180}"
  echo -n "Wait ping ${ip} "
  timeout "$timeout_s" bash -c "until ping -c1 -W1 '$ip' >/dev/null 2>&1; do echo -n '.'; sleep 1; done" \
    || die "Timeout: ping til ${ip} etter ${timeout_s}s"
  echo " OK"
}

wait_port() {
  local ip="$1" port="$2" timeout_s="${3:-180}"
  echo -n "Wait ${ip}:${port} "
  timeout "$timeout_s" bash -c "until nc -z '$ip' '$port' >/dev/null 2>&1; do echo -n '.'; sleep 1; done" \
    || die "Timeout: ${ip}:${port} etter ${timeout_s}s"
  echo " OK"
}

need awk
need grep
need nc
need ping
need timeout
need virsh
need talosctl

# kubectl er valgfritt, men anbefalt
KUBECTL_AVAILABLE=0
if command -v kubectl >/dev/null 2>&1; then
  KUBECTL_AVAILABLE=1
fi

VIR="virsh --connect qemu:///system"
BASE="/etc/nixos/talos-host"

PROFILE="${1:-}"
if [[ -z "${PROFILE}" ]]; then
  # fall back til /etc/nixos/talos-host/PROFILE hvis ingen arg
  if [[ -f "${BASE}/PROFILE" ]]; then
    PROFILE="$(cat "${BASE}/PROFILE" | xargs)"
  fi
fi
[[ -n "${PROFILE}" ]] || die "Mangler profil. Kjør: $0 lab1 (eller sørg for ${BASE}/PROFILE)"

ENVFILE="${BASE}/profiles/${PROFILE}/vars.env"
NODESFILE="${BASE}/profiles/${PROFILE}/nodes.csv"
[[ -f "$ENVFILE" ]] || die "Mangler $ENVFILE"
[[ -f "$NODESFILE" ]] || die "Mangler $NODESFILE"

set -a
# shellcheck disable=SC1090
source "$ENVFILE"
set +a

: "${TALOS_DIR:?Mangler TALOS_DIR i $ENVFILE}"
: "${TALOS_NET_NAME:?Mangler TALOS_NET_NAME i $ENVFILE}"
: "${KUBECONFIG_OUT:?Mangler KUBECONFIG_OUT i $ENVFILE}"

CP1_IP="$(
  awk -F, '
    NR==1 {next}
    $0 ~ /^[[:space:]]*#/ {next}
    NF>=3 {
      gsub(/[[:space:]]/,"",$2)
      if ($2=="controlplane") { gsub(/[[:space:]]/,"",$3); print $3; exit }
    }
  ' "$NODESFILE"
)"
[[ -n "$CP1_IP" ]] || die "Fant ingen controlplane i $NODESFILE"

echo "== Profile =="
echo "PROFILE:       $PROFILE"
echo "NET:           $TALOS_NET_NAME"
echo "CP1_IP:        $CP1_IP"
echo "TALOS_DIR:     $TALOS_DIR"
echo "TALOSCONFIG:   ${TALOS_DIR}/config/talosconfig"
echo "KUBECONFIG:    $KUBECONFIG_OUT"
echo

echo "== Libvirt status =="
$VIR uri >/dev/null 2>&1 || die "Kan ikke nå libvirt via qemu:///system (libvirtd?)"
$VIR net-info "$TALOS_NET_NAME" || die "Fant ikke nettverk $TALOS_NET_NAME"
echo

echo "== DHCP leases ($TALOS_NET_NAME) =="
$VIR net-dhcp-leases "$TALOS_NET_NAME" || true
echo

echo "== Connectivity =="
wait_ping "$CP1_IP" 240
wait_port "$CP1_IP" 50000 240
wait_port "$CP1_IP" 6443  240
echo

echo "== Talos health =="
export TALOSCONFIG="${TALOS_DIR}/config/talosconfig"
[[ -f "$TALOSCONFIG" ]] || die "Mangler TALOSCONFIG: $TALOSCONFIG (kjør talos-bootstrap først)"
talosctl config endpoint "$CP1_IP" >/dev/null
talosctl config node "$CP1_IP" >/dev/null
talosctl -n "$CP1_IP" health
echo

if [[ "$KUBECTL_AVAILABLE" -eq 1 ]]; then
  echo "== kubectl get nodes -o wide =="
  [[ -f "$KUBECONFIG_OUT" ]] || die "Mangler kubeconfig: $KUBECONFIG_OUT"
  kubectl --kubeconfig "$KUBECONFIG_OUT" get nodes -o wide
else
  echo "== kubectl =="
  echo "kubectl er ikke installert i PATH. (OK) Talos health var grønn."
fi

echo
echo "VERIFY OK (profile=$PROFILE)"
