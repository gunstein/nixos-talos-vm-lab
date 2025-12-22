#!/usr/bin/env bash
set -euo pipefail

# talos-bootstrap.sh
# - Profile-driven (lab1/lab2/...)
# - Offline ISO (assets/metal-amd64.iso)
# - Multi-node via profiles/<profile>/nodes.csv (start med 1 node; legg til flere ved å uncommente/legge til linjer)
# - Idempotent-ish: kan kjøres flere ganger uten å ødelegge
#
# Logs: journalctl -fu talos-bootstrap.service

die()  { echo "ERROR: $*" >&2; exit 1; }
warn() { echo "WARN:  $*" >&2; }

need() { command -v "$1" >/dev/null 2>&1 || die "Mangler kommando: $1"; }

wait_ping() {
  local ip="$1" timeout_s="${2:-300}"
  echo -n "Wait ping ${ip} "
  timeout "$timeout_s" bash -c "until ping -c1 -W1 '$ip' >/dev/null 2>&1; do echo -n '.'; sleep 1; done" \
    || die "Timeout: ping til ${ip} etter ${timeout_s}s"
  echo " OK"
}

wait_port() {
  local ip="$1" port="$2" timeout_s="${3:-300}"
  echo -n "Wait ${ip}:${port} "
  timeout "$timeout_s" bash -c "until nc -z '$ip' '$port' >/dev/null 2>&1; do echo -n '.'; sleep 1; done" \
    || die "Timeout: ${ip}:${port} etter ${timeout_s}s"
  echo " OK"
}

trim() { echo "$1" | xargs; }

# --- prereqs ---
need virsh
need virt-install
need qemu-img
need talosctl
need envsubst
need awk
need sed
need grep
need nc
need ping
need timeout
need mkdir
need cp
need chmod
need head
need tail
need date

VIR="virsh --connect qemu:///system"
BASE="/etc/nixos/talos-host"
PROFILE_FILE="${BASE}/PROFILE"

[[ -d "$BASE" ]] || die "Mangler repo på $BASE. Kjør install.sh først."
[[ -f "$PROFILE_FILE" ]] || die "Mangler $PROFILE_FILE. Kjør install.sh <profil> først."

PROFILE="$(cat "$PROFILE_FILE" | xargs)"
[[ -n "$PROFILE" ]] || die "PROFILE er tom i $PROFILE_FILE."

ENVFILE="${BASE}/profiles/${PROFILE}/vars.env"
NODESFILE="${BASE}/profiles/${PROFILE}/nodes.csv"
NET_TEMPLATE="${BASE}/assets/talosnet.xml.template"
ISO_SRC="${BASE}/assets/metal-amd64.iso"

[[ -f "$ENVFILE" ]] || die "Mangler envfile: $ENVFILE"
[[ -f "$NODESFILE" ]] || die "Mangler nodes.csv: $NODESFILE"
[[ -f "$NET_TEMPLATE" ]] || die "Mangler talosnet template: $NET_TEMPLATE"
[[ -f "$ISO_SRC" && -s "$ISO_SRC" ]] || die "Mangler ISO (offline): $ISO_SRC (scp den til assets/)"

# Load profile env
set -a
# shellcheck disable=SC1090
source "$ENVFILE"
set +a

# Required vars
: "${TALOS_CLUSTER_NAME:?Mangler TALOS_CLUSTER_NAME i $ENVFILE}"
: "${TALOS_DIR:?Mangler TALOS_DIR i $ENVFILE}"
: "${TALOS_NET_NAME:?Mangler TALOS_NET_NAME i $ENVFILE}"
: "${TALOS_BRIDGE_NAME:?Mangler TALOS_BRIDGE_NAME i $ENVFILE}"
: "${TALOS_GATEWAY:?Mangler TALOS_GATEWAY i $ENVFILE}"
: "${TALOS_DHCP_START:?Mangler TALOS_DHCP_START i $ENVFILE}"
: "${TALOS_DHCP_END:?Mangler TALOS_DHCP_END i $ENVFILE}"
: "${KUBECONFIG_OUT:?Mangler KUBECONFIG_OUT i $ENVFILE}"

# State dirs
ISO_DST_DIR="${TALOS_DIR}/iso"
IMG_DIR="${TALOS_DIR}/images"
CFG_DIR="${TALOS_DIR}/config"
STATE_DIR="${TALOS_DIR}/state"
DONE_FILE="${TALOS_DIR}/DONE"

mkdir -p "$ISO_DST_DIR" "$IMG_DIR" "$CFG_DIR" "$STATE_DIR"
chmod 0755 "$TALOS_DIR" "$ISO_DST_DIR" "$IMG_DIR" "$CFG_DIR" "$STATE_DIR" || true

ISO_DST="${ISO_DST_DIR}/metal-amd64.iso"

# If already done, exit fast (but allow manual re-run by deleting DONE)
if [[ -f "$DONE_FILE" ]]; then
  echo "Already bootstrapped (profile=$PROFILE)."
  echo "  DONE: $DONE_FILE"
  echo "  If you changed nodes.csv and want to expand: delete $DONE_FILE and run again,"
  echo "  or just run talos-bootstrap again (it will still create/start missing VMs)."
fi

# Verify libvirt is reachable
$VIR uri >/dev/null 2>&1 || die "Kan ikke nå libvirt via qemu:///system. Sjekk at libvirtd kjører."

# Copy ISO to state (so we don't depend on /etc/nixos path later)
if [[ ! -f "$ISO_DST" ]] || ! cmp -s "$ISO_SRC" "$ISO_DST"; then
  echo "Copy ISO -> $ISO_DST"
  cp -f "$ISO_SRC" "$ISO_DST"
  chmod 0644 "$ISO_DST"
fi

# Define + start network from template (does not include host reservations; those are net-update per node)
NET_XML="${STATE_DIR}/${TALOS_NET_NAME}.xml"
envsubst < "$NET_TEMPLATE" > "$NET_XML"

if ! $VIR net-info "$TALOS_NET_NAME" >/dev/null 2>&1; then
  echo "Define network ${TALOS_NET_NAME}"
  $VIR net-define "$NET_XML" || die "net-define feilet for ${TALOS_NET_NAME}"
else
  # Keep existing (but ensure it's started/autostart)
  :
fi

$VIR net-start "$TALOS_NET_NAME" >/dev/null 2>&1 || true
$VIR net-autostart "$TALOS_NET_NAME" >/dev/null

# Find CP1 IP (first controlplane in nodes.csv, ignoring commented lines)
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
[[ -n "$CP1_IP" ]] || die "Fant ingen controlplane i $NODESFILE. Du må ha minst én controlplane-linje."

echo "Profile: $PROFILE"
echo "Network: $TALOS_NET_NAME ($TALOS_GATEWAY/24) bridge=$TALOS_BRIDGE_NAME"
echo "Cluster: $TALOS_CLUSTER_NAME"
echo "CP1:     $CP1_IP"
echo "Kubeconfig output: $KUBECONFIG_OUT"
echo

# Generate Talos config once (controlplane.yaml + worker.yaml + talosconfig)
if [[ ! -f "${CFG_DIR}/talosconfig" ]]; then
  echo "Generate Talos config -> $CFG_DIR"
  (
    cd "$CFG_DIR"
    talosctl gen config "$TALOS_CLUSTER_NAME" "https://${CP1_IP}:6443" || die "talosctl gen config feilet"
    # virtio disks for KVM/libvirt
    sed -i 's#/dev/sd[a-z]#/dev/vda#g' controlplane.yaml worker.yaml
  )
else
  echo "Talos config exists -> $CFG_DIR (reusing)"
fi

export TALOSCONFIG="${CFG_DIR}/talosconfig"

# Helper: apply config, first try insecure; if cert required, retry secure
apply_config() {
  local ip="$1" file="$2"
  set +e
  local out rc
  out="$(talosctl apply-config --insecure --nodes "$ip" --file "$file" 2>&1)"
  rc=$?
  set -e
  if [[ $rc -eq 0 ]]; then
    return 0
  fi
  if echo "$out" | grep -qi "certificate required"; then
    echo "apply-config: node $ip krever sertifikat (ok). Retrying uten --insecure..."
    talosctl apply-config --nodes "$ip" --file "$file" >/dev/null
    return 0
  fi
  echo "$out" >&2
  return 1
}

# Iterate nodes.csv and converge desired state
# CSV: name,role,ip,mac,disk_gb,ram_mb,vcpus
echo "Converge Talos nodes from $NODESFILE"
tail -n +2 "$NODESFILE" | while IFS=, read -r name role ip mac disk_gb ram_mb vcpus; do
  name="$(trim "${name:-}")"
  role="$(trim "${role:-}")"
  ip="$(trim "${ip:-}")"
  mac="$(trim "${mac:-}")"
  disk_gb="$(trim "${disk_gb:-}")"
  ram_mb="$(trim "${ram_mb:-}")"
  vcpus="$(trim "${vcpus:-}")"

  # Skip empty or commented lines
  [[ -z "$name" ]] && continue
  [[ "$name" =~ ^# ]] && continue

  [[ -n "$role" && -n "$ip" && -n "$mac" ]] || die "nodes.csv linje mangler felt: name=$name role=$role ip=$ip mac=$mac"
  [[ -n "$disk_gb" && -n "$ram_mb" && -n "$vcpus" ]] || die "nodes.csv linje mangler ressurser: disk_gb=$disk_gb ram_mb=$ram_mb vcpus=$vcpus"

  echo
  echo "== Node: $name ($role) ip=$ip mac=$mac =="

  # Ensure DHCP reservation (safe to run repeatedly)
  $VIR net-update "$TALOS_NET_NAME" add ip-dhcp-host \
    "<host mac='${mac}' name='${name}' ip='${ip}'/>" \
    --live --config >/dev/null 2>&1 || true

  # Ensure disk
  DISK="${IMG_DIR}/${name}.qcow2"
  if [[ ! -f "$DISK" ]]; then
    echo "Create disk $DISK (${disk_gb}G)"
    qemu-img create -f qcow2 "$DISK" "${disk_gb}G" >/dev/null
  fi

  # Ensure VM exists
  if $VIR dominfo "$name" >/dev/null 2>&1; then
    # Validate that NIC matches network + mac (avoid silent wrong wiring)
    IFINFO="$($VIR domiflist "$name" | awk 'NR>2 && NF{print $3,$5}' || true)"
    echo "$IFINFO" | grep -q "${TALOS_NET_NAME} ${mac}" \
      || die "VM '$name' finnes men har ikke NIC på network='${TALOS_NET_NAME}' med MAC='${mac}'. Fiks VM eller nodes.csv."
  else
    echo "Create VM $name"
    virt-install \
      --connect qemu:///system \
      --name "$name" \
      --memory "$ram_mb" \
      --vcpus "$vcpus" \
      --disk "path=${DISK},format=qcow2,bus=virtio" \
      --cdrom "$ISO_DST" \
      --network "network=${TALOS_NET_NAME},model=virtio,mac=${mac}" \
      --graphics none \
      --osinfo detect=on,require=off \
      --noautoconsole \
      || die "virt-install feilet for $name"
  fi

  $VIR autostart "$name" >/dev/null
  $VIR start "$name" >/dev/null 2>&1 || true

  # Wait for Talos API
  wait_ping "$ip" 300
  wait_port "$ip" 50000 300

  # Apply appropriate config
  if [[ "$role" == "controlplane" ]]; then
    echo "Apply controlplane config -> $ip"
    apply_config "$ip" "${CFG_DIR}/controlplane.yaml" || die "apply-config controlplane feilet for $name ($ip)"
  elif [[ "$role" == "worker" ]]; then
    echo "Apply worker config -> $ip"
    apply_config "$ip" "${CFG_DIR}/worker.yaml" || die "apply-config worker feilet for $name ($ip)"
  else
    die "Ukjent role '$role' for node '$name' (må være controlplane eller worker)"
  fi

  # Patch stable hostname (prevents stale node confusion)
  PATCH_HOST="${CFG_DIR}/patch-hostname-${name}.yaml"
  cat > "$PATCH_HOST" <<EOF
machine:
  network:
    hostname: ${name}
EOF
  talosctl patch mc --nodes "$ip" --patch @"$PATCH_HOST" >/dev/null 2>&1 || true

  # For CP1 only: patch apiserver IPv4 bind/advertise (helps avoid weird bind behavior)
  if [[ "$ip" == "$CP1_IP" ]]; then
    PATCH_API="${CFG_DIR}/patch-apiserver-ipv4.yaml"
    cat > "$PATCH_API" <<EOF
cluster:
  apiServer:
    extraArgs:
      bind-address: 0.0.0.0
      advertise-address: ${CP1_IP}
EOF
    talosctl patch mc --nodes "$CP1_IP" --patch @"$PATCH_API" >/dev/null 2>&1 || true
  fi
done

echo
echo "Bootstrap etcd on CP1 (safe to retry)"
talosctl bootstrap --nodes "$CP1_IP" >/dev/null 2>&1 || true

echo "Wait for Kubernetes API on CP1"
wait_port "$CP1_IP" 6443 600

echo "Write kubeconfig -> $KUBECONFIG_OUT"
mkdir -p "$(dirname "$KUBECONFIG_OUT")"
talosctl kubeconfig --nodes "$CP1_IP" --kubeconfig "$KUBECONFIG_OUT" --force || die "kubeconfig fetch feilet"

echo "Talos health (proof)"
talosctl -n "$CP1_IP" health || die "talosctl health feilet"

# Optional kubectl check if kubectl exists
if command -v kubectl >/dev/null 2>&1; then
  echo "kubectl get nodes (using $KUBECONFIG_OUT)"
  kubectl --kubeconfig "$KUBECONFIG_OUT" get nodes -o wide || warn "kubectl feilet (men talosctl health var OK)"
fi

date -Is > "$DONE_FILE"
echo
echo "BOOTSTRAP COMPLETE (profile=$PROFILE)"
echo "  DONE:       $DONE_FILE"
echo "  KUBECONFIG: $KUBECONFIG_OUT"
