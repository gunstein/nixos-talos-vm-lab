#!/run/current-system/sw/bin/bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/common.sh"

# Parse flags before require_root (which re-execs)
while [[ $# -gt 0 ]]; do
  case "$1" in
    --verbose|-v)
      export TALOS_LAB_VERBOSE=1
      shift
      ;;
    --debug|-d)
      export TALOS_LAB_DEBUG=1
      export TALOS_LAB_VERBOSE=1
      shift
      ;;
    --help|-h)
      cat <<EOF
Usage: lab.sh [OPTIONS] <profile> <command>

Commands:
  plan          Show what will happen (dry-run preview)
  status        Show VM and network status
  up            Create VMs and start network
  provision     Generate Talos config and bootstrap cluster
  verify        Verify cluster is healthy
  all           Run up + provision + verify + demo-db + monitoring
  wipe          Destroy VMs, network, and Talos state
  net-recreate  Recreate libvirt network
  demo          Deploy demo app (in-memory backend)
  demo-db       Deploy demo app with PostgreSQL database
  monitoring    Deploy Prometheus, Loki, and Grafana
  ingress       Deploy Traefik Ingress Controller

Options:
  -v, --verbose   Show more detailed output
  -d, --debug     Enable debug mode (set -x, extra logging)
  -h, --help      Show this help message

Environment variables:
  TALOS_LAB_VERBOSE=1   Same as --verbose
  TALOS_LAB_DEBUG=1     Same as --debug
  TALOS_LAB_LOG_DIR     Log directory (default: /var/log/talos-vm-lab)

Examples:
  sudo ./scripts/lab.sh lab1 plan              # Preview what will happen
  sudo ./scripts/lab.sh lab1 all               # Full setup
  sudo ./scripts/lab.sh --verbose lab1 status  # Verbose status
  TALOS_LAB_DEBUG=1 sudo ./scripts/lab.sh lab1 up
EOF
      exit 0
      ;;
    -*)
      die "Unknown option: $1 (use --help for usage)"
      ;;
    *)
      break
      ;;
  esac
done

require_root "$@"

need virsh
need awk
need sed
need nc
need mktemp
need install
need rm
need mkdir
need date
need sleep
need ip
need virt-install
need qemu-img

PROFILE="${1:-}"
CMD="${2:-}"
[[ -n "$PROFILE" && -n "$CMD" ]] || die "Usage: lab.sh [OPTIONS] <profile> <cmd> (use --help for details)"

# Initialize logging
log_init "$PROFILE" "$CMD"

load_profile "$PROFILE"
csv_init

ISO_CACHE="${DISK_DIR}/metal-amd64.iso"

vm_disk_path() { echo "${DISK_DIR}/talos-${1}.qcow2"; }

ensure_iso_cache() {
  ensure_disk_dir
  if [[ -f "$ISO_CACHE" ]]; then return 0; fi
  [[ -f "$ISO" ]] || die "Missing Talos ISO: $ISO"
  log "Copy ISO -> $ISO_CACHE"
  install -m 0644 "$ISO" "$ISO_CACHE"
}

write_net_xml() {
  local out="$1"
  cat > "$out" <<EOF
<network>
  <name>${TALOS_NET_NAME}</name>
  <forward mode='nat'/>
  <bridge name='${TALOS_BRIDGE_NAME}' stp='on' delay='0'/>
  <ip address='${TALOS_GATEWAY}' netmask='255.255.255.0'>
    <dhcp>
      <range start='${TALOS_DHCP_START}' end='${TALOS_DHCP_END}'/>
    </dhcp>
  </ip>
</network>
EOF
}

net_bridge_of() {
  virsh -c "$LIBVIRT_URI" net-dumpxml "$1" 2>/dev/null | awk -F"'" '/<bridge name=/{print $2; exit}'
}

net_start_with_autofix() {
  local err=""
  log_debug "Attempting to start network: ${TALOS_NET_NAME}"
  if err="$(virsh -c "$LIBVIRT_URI" net-start "$TALOS_NET_NAME" 2>&1)"; then
    return 0
  fi

  if [[ "$err" =~ interface[[:space:]]+([^[:space:]]+) ]]; then
    local bad_if="${BASH_REMATCH[1]}"
    log_warn "net-start failed due to interface in use: ${bad_if}"

    if ip link show "$bad_if" >/dev/null 2>&1; then
      log_warn "Trying to delete stale bridge '${bad_if}'"
      ip link set "$bad_if" down 2>/dev/null || true
      ip link delete "$bad_if" type bridge 2>/dev/null || true
    fi

    log "Retry: net-start ${TALOS_NET_NAME}"
    virsh -c "$LIBVIRT_URI" net-start "$TALOS_NET_NAME" >/dev/null
    return 0
  fi

  log_error "Failed to start network ${TALOS_NET_NAME}"
  echo "$err" | sed 's/^/[virsh] /'
  die "libvirt refused to start ${TALOS_NET_NAME}"
}

# Explicit destructive recreate (only when requested)
net_recreate() {
  log "Recreate network ${TALOS_NET_NAME}"
  if virsh -c "$LIBVIRT_URI" net-info "$TALOS_NET_NAME" >/dev/null 2>&1; then
    virsh -c "$LIBVIRT_URI" net-destroy "$TALOS_NET_NAME" 2>/dev/null || true
    virsh -c "$LIBVIRT_URI" net-undefine "$TALOS_NET_NAME" 2>/dev/null || true
  fi

  local tmp
  tmp="$(mktemp)"
  write_net_xml "$tmp"

  virsh -c "$LIBVIRT_URI" net-define "$tmp" >/dev/null
  virsh -c "$LIBVIRT_URI" net-autostart "$TALOS_NET_NAME" >/dev/null
  net_start_with_autofix
  rm -f "$tmp"
}

# Idempotent ensure: NO destroy/undefine
net_ensure_started() {
  if ! virsh -c "$LIBVIRT_URI" net-info "$TALOS_NET_NAME" >/dev/null 2>&1; then
    log "Network missing -> define+start"
    net_recreate
    return 0
  fi

  local existing_bridge
  existing_bridge="$(net_bridge_of "$TALOS_NET_NAME" || true)"
  if [[ -n "$existing_bridge" && "$existing_bridge" != "$TALOS_BRIDGE_NAME" ]]; then
    log_error "Network drift: ${TALOS_NET_NAME} uses '${existing_bridge}', expected '${TALOS_BRIDGE_NAME}'"
    log_error "Run explicitly:"
    log_error "  sudo ${ROOT}/scripts/lab.sh ${PROFILE} net-recreate"
    die "Refusing to auto-recreate network in idempotent mode."
  fi

  local active
  active="$(virsh -c "$LIBVIRT_URI" net-info "$TALOS_NET_NAME" | awk -F': *' '/^Active:/{print $2}')"
  if [[ "$active" != "yes" ]]; then
    log "Start existing network ${TALOS_NET_NAME}"
    net_start_with_autofix
  else
    log "Network ${TALOS_NET_NAME} already active."
  fi
}

net_add_dhcp_host() {
  local name="$1" mac="$2" ipaddr="$3"
  local hostxml
  hostxml="$(mktemp)"
  cat > "$hostxml" <<EOF
<host mac='${mac}' name='${name}' ip='${ipaddr}'/>
EOF
  virsh -c "$LIBVIRT_URI" net-update "$TALOS_NET_NAME" add-last ip-dhcp-host --xml "$(cat "$hostxml")" --config >/dev/null 2>&1 || true
  virsh -c "$LIBVIRT_URI" net-update "$TALOS_NET_NAME" add-last ip-dhcp-host --xml "$(cat "$hostxml")" --live   >/dev/null 2>&1 || true
  rm -f "$hostxml"
}

vm_create() {
  local name="$1" disk_gb="$2" ram_mb="$3" vcpus="$4" mac="$5"
  local disk
  disk="$(vm_disk_path "$name")"

  ensure_disk_dir

  if [[ ! -f "$disk" ]]; then
    log "Create disk $disk (${disk_gb}G)"
    qemu-img create -f qcow2 "$disk" "${disk_gb}G" >/dev/null
  fi

  if virsh -c "$LIBVIRT_URI" dominfo "$name" >/dev/null 2>&1; then
    log "VM exists: $name (skip create)"
    return 0
  fi

  log "Create VM $name (Talos ISO first boot, VNC enabled)"
  virt-install \
    --connect "$LIBVIRT_URI" \
    --name "$name" \
    --memory "$ram_mb" \
    --vcpus "$vcpus" \
    --disk "path=$disk,format=qcow2,bus=virtio" \
    --cdrom "$ISO_CACHE" \
    --network "network=${TALOS_NET_NAME},mac=${mac},model=virtio" \
    --os-variant generic \
    --graphics "vnc,listen=127.0.0.1,port=-1" \
    --video virtio \
    --noautoconsole \
    --boot cdrom,hd >/dev/null
}

vm_start_if_needed() {
  local name="$1"
  if ! virsh -c "$LIBVIRT_URI" domstate "$name" 2>/dev/null | grep -qi running; then
    log "Start VM $name"
    virsh -c "$LIBVIRT_URI" start "$name" >/dev/null
  fi
}

first_controlplane() {
  local row role
  while IFS= read -r row; do
    role="$(csv_get "$row" role)"
    if [[ "$role" == "controlplane" ]]; then
      echo "$(csv_get "$row" name) $(csv_get "$row" ip)"
      return 0
    fi
  done < <(csv_rows)
  return 1
}

cmd_status() {
  log "== STATUS profile=${PROFILE} =="
  virsh -c "$LIBVIRT_URI" net-list --all | sed 's/^/  /'
  virsh -c "$LIBVIRT_URI" list --all | sed 's/^/  /'
}

cmd_wipe() {
  log "WIPING profile '${PROFILE}' (VMs, disks, network, talos state)"
  local row name disk

  while IFS= read -r row; do
    name="$(csv_get "$row" name)"
    disk="$(vm_disk_path "$name")"

    if virsh -c "$LIBVIRT_URI" dominfo "$name" >/dev/null 2>&1; then
      virsh -c "$LIBVIRT_URI" destroy "$name" 2>/dev/null || true
      virsh -c "$LIBVIRT_URI" undefine "$name" --nvram 2>/dev/null || virsh -c "$LIBVIRT_URI" undefine "$name" 2>/dev/null || true
    fi
    [[ -f "$disk" ]] && rm -f "$disk"
  done < <(csv_rows)

  if virsh -c "$LIBVIRT_URI" net-info "$TALOS_NET_NAME" >/dev/null 2>&1; then
    virsh -c "$LIBVIRT_URI" net-destroy "$TALOS_NET_NAME" 2>/dev/null || true
    virsh -c "$LIBVIRT_URI" net-undefine "$TALOS_NET_NAME" 2>/dev/null || true
  fi

  [[ -d "$TALOS_DIR" ]] && rm -rf "$TALOS_DIR"
  log "WIPE DONE."
}

cmd_up() {
  log "== UP =="
  ensure_iso_cache
  net_ensure_started

  local row name mac ipaddr disk_gb ram_mb vcpus
  while IFS= read -r row; do
    name="$(csv_get "$row" name)"
    mac="$(csv_get "$row" mac)"
    ipaddr="$(csv_get "$row" ip)"
    net_add_dhcp_host "$name" "$mac" "$ipaddr"
  done < <(csv_rows)

  while IFS= read -r row; do
    name="$(csv_get "$row" name)"
    disk_gb="$(csv_get "$row" disk_gb)"
    ram_mb="$(csv_get "$row" ram_mb)"
    vcpus="$(csv_get "$row" vcpus)"
    mac="$(csv_get "$row" mac)"
    vm_create "$name" "$disk_gb" "$ram_mb" "$vcpus" "$mac"
  done < <(csv_rows)

  while IFS= read -r row; do
    name="$(csv_get "$row" name)"
    vm_start_if_needed "$name"
  done < <(csv_rows)

  local cp cp_name cp_ip
  cp="$(first_controlplane)" || die "No controlplane found in nodes.csv"
  cp_name="$(echo "$cp" | awk '{print $1}')"
  cp_ip="$(echo "$cp" | awk '{print $2}')"

  log "Waiting for Talos API ${cp_ip}:50000"
  if ! wait_port "$cp_ip" 50000 300; then
    log_error "Talos API not reachable. Check VNC:"
    log_error "  sudo virsh -c ${LIBVIRT_URI} vncdisplay ${cp_name}"
    die "Talos API not reachable on ${cp_ip}:50000"
  fi

  log "OK: network + VMs up."
}

cmd_provision() {
  log "== PROVISION =="
  "${ROOT}/scripts/talos-provision.sh" "$PROFILE"
}

cmd_verify() {
  log "== VERIFY =="
  "${ROOT}/scripts/talos-verify.sh" "$PROFILE"
}


cmd_demo() {
  log "== DEMO (frontend + backend) =="
  need kubectl
  need systemctl
  need sed
  need cp

  [[ -f "$KUBECONFIG_OUT" ]] || die "Missing kubeconfig: $KUBECONFIG_OUT (run: sudo ./scripts/lab ${PROFILE} provision)"

  local cp cp_name
  cp="$(first_controlplane)" || die "No controlplane found in nodes.csv"
  cp_name="$(echo "$cp" | awk '{print $1}')"

  # In single-node labs, the only node is usually tainted as control-plane:NoSchedule.
  # We keep it lab-friendly and remove those taints automatically.
  kubectl --kubeconfig "$KUBECONFIG_OUT" taint nodes "${cp_name}" node-role.kubernetes.io/control-plane- >/dev/null 2>&1 || true
  kubectl --kubeconfig "$KUBECONFIG_OUT" taint nodes "${cp_name}" node-role.kubernetes.io/master- >/dev/null 2>&1 || true

  # Build + push backend image into the local registry on the NixOS-host.
  # You can skip rebuilds by exporting DEMO_BUILD=0.
  if [[ "${DEMO_BUILD:-1}" != "0" ]]; then
    "${ROOT}/scripts/demo-backend-build.sh"
  else
    log "DEMO_BUILD=0 -> skip backend build/push"
  fi

  local manifests="$ROOT/k8s/apps/frontend-demo"
  [[ -d "$manifests" ]] || die "Missing manifests dir: $manifests"

  # Talos nodes pull images via the libvirt gateway (NixOS-host) on this lab network.
  local registry_addr
  registry_addr="${TALOS_GATEWAY}:5000"

  # Apply manifests, but first substitute the backend image registry address.
  # Exclude database-related files (51-*, 64-*, 65-*) - those are for demo-db only.
  local tmp
  tmp="$(mktemp -d)"
  cp -R "${manifests}/." "${tmp}/"
  rm -f "${tmp}"/51-*.yaml "${tmp}"/64-*.yaml "${tmp}"/65-*.yaml
  sed -i "s|__REGISTRY_ADDR__|${registry_addr}|g" "${tmp}/50-backend-deployment.yaml"

  log "Apply demo manifests (rendered) from: ${tmp}"
  kubectl --kubeconfig "$KUBECONFIG_OUT" apply -f "$tmp" >/dev/null
  rm -rf "$tmp"

  log "Wait for backend rollout"
  if ! kubectl --kubeconfig "$KUBECONFIG_OUT" -n demo rollout status deploy/demo-backend --timeout=5m; then
    log_warn "Backend rollout timed out. Quick diagnostics:"
    kubectl --kubeconfig "$KUBECONFIG_OUT" -n demo get pods -o wide || true
    kubectl --kubeconfig "$KUBECONFIG_OUT" -n demo get events --sort-by=.lastTimestamp | tail -n 25 || true
    die "demo-backend rollout timed out"
  fi

  log "Wait for frontend rollout"
  if ! kubectl --kubeconfig "$KUBECONFIG_OUT" -n demo rollout status deploy/demo-frontend --timeout=5m; then
    log_warn "Frontend rollout timed out. Quick diagnostics:"
    kubectl --kubeconfig "$KUBECONFIG_OUT" -n demo get pods -o wide || true
    kubectl --kubeconfig "$KUBECONFIG_OUT" -n demo get events --sort-by=.lastTimestamp | tail -n 25 || true
    log_warn "Node taints (common issue in single-node labs):"
    kubectl --kubeconfig "$KUBECONFIG_OUT" describe node "${cp_name}" | sed -n '/Taints:/,/Addresses:/p' || true
    die "demo-frontend rollout timed out"
  fi

  # Create Ingress resource for Traefik
  log "Create Ingress for demo"
  kubectl --kubeconfig "$KUBECONFIG_OUT" apply -f "$ROOT/k8s/apps/frontend-demo/35-ingress.yaml" >/dev/null
  log "OK. Access via: https://demo.lab.local"
}


cmd_demo_db() {
  log "== DEMO WITH DATABASE =="
  need kubectl
  need systemctl
  need sed
  need cp

  [[ -f "$KUBECONFIG_OUT" ]] || die "Missing kubeconfig: $KUBECONFIG_OUT (run: sudo ./scripts/lab ${PROFILE} provision)"

  local cp cp_name cp_ip
  cp="$(first_controlplane)" || die "No controlplane found in nodes.csv"
  cp_name="$(echo "$cp" | awk '{print $1}')"
  cp_ip="$(echo "$cp" | awk '{print $2}')"

  # In single-node labs, the only node is usually tainted as control-plane:NoSchedule.
  kubectl --kubeconfig "$KUBECONFIG_OUT" taint nodes "${cp_name}" node-role.kubernetes.io/control-plane- >/dev/null 2>&1 || true
  kubectl --kubeconfig "$KUBECONFIG_OUT" taint nodes "${cp_name}" node-role.kubernetes.io/master- >/dev/null 2>&1 || true

  # Install local-path-provisioner for storage (idempotent)
  log "Install local-path-provisioner (storage)"
  kubectl --kubeconfig "$KUBECONFIG_OUT" apply -f "$ROOT/k8s/addons/local-path-provisioner.yaml" >/dev/null

  log "Wait for local-path-provisioner"
  if ! kubectl --kubeconfig "$KUBECONFIG_OUT" -n local-path-storage rollout status deploy/local-path-provisioner --timeout=2m; then
    log_warn "local-path-provisioner rollout timed out."
    kubectl --kubeconfig "$KUBECONFIG_OUT" -n local-path-storage get pods -o wide || true
    die "local-path-provisioner rollout timed out"
  fi

  # Install CloudNativePG operator (idempotent)
  log "Install CloudNativePG operator"
  kubectl --kubeconfig "$KUBECONFIG_OUT" apply --server-side -f "$ROOT/k8s/addons/cloudnativepg-operator.yaml" >/dev/null

  log "Wait for CloudNativePG operator"
  if ! kubectl --kubeconfig "$KUBECONFIG_OUT" -n cnpg-system rollout status deploy/cnpg-controller-manager --timeout=3m; then
    log_warn "CloudNativePG operator rollout timed out."
    kubectl --kubeconfig "$KUBECONFIG_OUT" -n cnpg-system get pods -o wide || true
    die "cnpg-controller-manager rollout timed out"
  fi

  # Build + push backend image
  if [[ "${DEMO_BUILD:-1}" != "0" ]]; then
    "${ROOT}/scripts/demo-backend-build.sh"
  else
    log "DEMO_BUILD=0 -> skip backend build/push"
  fi

  local manifests="$ROOT/k8s/apps/frontend-demo"
  [[ -d "$manifests" ]] || die "Missing manifests dir: $manifests"

  local registry_addr
  registry_addr="${TALOS_GATEWAY}:5000"

  # Apply manifests in correct order:
  # 1. First apply everything except backend (namespace, frontend, database cluster)
  # 2. Wait for database to be ready (creates the secret)
  # 3. Then apply backend with DATABASE_URL

  local tmp
  tmp="$(mktemp -d)"
  cp -R "${manifests}/." "${tmp}/"

  # Remove both backend deployments for now
  rm -f "${tmp}/50-backend-deployment.yaml"
  rm -f "${tmp}/51-backend-deployment-db.yaml"

  log "Apply demo manifests (without backend) from: ${tmp}"
  kubectl --kubeconfig "$KUBECONFIG_OUT" apply -f "$tmp" >/dev/null

  log "Wait for database cluster to be ready"
  if ! kubectl --kubeconfig "$KUBECONFIG_OUT" -n demo wait --for=condition=Ready cluster/demo-db --timeout=5m 2>/dev/null; then
    log_warn "Database cluster not ready. Quick diagnostics:"
    kubectl --kubeconfig "$KUBECONFIG_OUT" -n demo get cluster demo-db -o wide || true
    kubectl --kubeconfig "$KUBECONFIG_OUT" -n demo get pods -l cnpg.io/cluster=demo-db -o wide || true
    kubectl --kubeconfig "$KUBECONFIG_OUT" -n demo get events --sort-by=.lastTimestamp | tail -n 25 || true
    rm -rf "$tmp"
    die "demo-db cluster not ready"
  fi

  # Now apply backend with DATABASE_URL (secret exists now)
  cp "${manifests}/51-backend-deployment-db.yaml" "${tmp}/"
  sed -i "s|__REGISTRY_ADDR__|${registry_addr}|g" "${tmp}/51-backend-deployment-db.yaml"

  log "Apply backend deployment (with DATABASE_URL)"
  kubectl --kubeconfig "$KUBECONFIG_OUT" apply -f "${tmp}/51-backend-deployment-db.yaml" >/dev/null
  rm -rf "$tmp"

  log "Wait for backend rollout"
  if ! kubectl --kubeconfig "$KUBECONFIG_OUT" -n demo rollout status deploy/demo-backend --timeout=5m; then
    log "Backend rollout timed out. Quick diagnostics:"
    kubectl --kubeconfig "$KUBECONFIG_OUT" -n demo get pods -o wide || true
    kubectl --kubeconfig "$KUBECONFIG_OUT" -n demo get events --sort-by=.lastTimestamp | tail -n 25 || true
    die "demo-backend rollout timed out"
  fi

  log "Wait for frontend rollout"
  if ! kubectl --kubeconfig "$KUBECONFIG_OUT" -n demo rollout status deploy/demo-frontend --timeout=5m; then
    log "Frontend rollout timed out. Quick diagnostics:"
    kubectl --kubeconfig "$KUBECONFIG_OUT" -n demo get pods -o wide || true
    die "demo-frontend rollout timed out"
  fi

  # Create Ingress resource for Traefik
  log "Create Ingress for demo"
  kubectl --kubeconfig "$KUBECONFIG_OUT" apply -f "$ROOT/k8s/apps/frontend-demo/35-ingress.yaml" >/dev/null
  log "OK. Access via: https://demo.lab.local"

  log ""
  log "Database endpoints:"
  log "  curl -sS https://demo.lab.local/api/items"
  log "  curl -X POST https://demo.lab.local/api/items -H 'Content-Type: application/json' -d '{\"name\":\"test\"}'"
  log ""
  log "Connect to database:"
  log "  kubectl -n demo exec -it demo-db-1 -- psql -U demo -d demo"
}


cmd_monitoring() {
  log "== MONITORING STACK =="
  need kubectl

  [[ -f "$KUBECONFIG_OUT" ]] || die "Missing kubeconfig: $KUBECONFIG_OUT (run: sudo ./scripts/lab ${PROFILE} provision)"

  local cp cp_name cp_ip
  cp="$(first_controlplane)" || die "No controlplane found in nodes.csv"
  cp_name="$(echo "$cp" | awk '{print $1}')"
  cp_ip="$(echo "$cp" | awk '{print $2}')"

  # In single-node labs, the only node is usually tainted as control-plane:NoSchedule.
  kubectl --kubeconfig "$KUBECONFIG_OUT" taint nodes "${cp_name}" node-role.kubernetes.io/control-plane- >/dev/null 2>&1 || true
  kubectl --kubeconfig "$KUBECONFIG_OUT" taint nodes "${cp_name}" node-role.kubernetes.io/master- >/dev/null 2>&1 || true

  # Install local-path-provisioner for storage (idempotent)
  log "Install local-path-provisioner (storage)"
  kubectl --kubeconfig "$KUBECONFIG_OUT" apply -f "$ROOT/k8s/addons/local-path-provisioner.yaml" >/dev/null

  log "Wait for local-path-provisioner"
  if ! kubectl --kubeconfig "$KUBECONFIG_OUT" -n local-path-storage rollout status deploy/local-path-provisioner --timeout=2m; then
    log "local-path-provisioner rollout timed out."
    kubectl --kubeconfig "$KUBECONFIG_OUT" -n local-path-storage get pods -o wide || true
    die "local-path-provisioner rollout timed out"
  fi

  # Install Prometheus
  log "Install Prometheus"
  kubectl --kubeconfig "$KUBECONFIG_OUT" apply -f "$ROOT/k8s/addons/prometheus.yaml" >/dev/null

  # Install Loki (log aggregation)
  log "Install Loki"
  kubectl --kubeconfig "$KUBECONFIG_OUT" apply -f "$ROOT/k8s/addons/loki.yaml" >/dev/null

  # Install Promtail (log collector)
  log "Install Promtail"
  kubectl --kubeconfig "$KUBECONFIG_OUT" apply -f "$ROOT/k8s/addons/promtail.yaml" >/dev/null

  # Install Grafana (includes Loki datasource)
  log "Install Grafana"
  kubectl --kubeconfig "$KUBECONFIG_OUT" apply -f "$ROOT/k8s/addons/grafana.yaml" >/dev/null

  log "Wait for Prometheus rollout"
  if ! kubectl --kubeconfig "$KUBECONFIG_OUT" -n monitoring rollout status deploy/prometheus --timeout=3m; then
    log_warn "Prometheus rollout timed out. Quick diagnostics:"
    kubectl --kubeconfig "$KUBECONFIG_OUT" -n monitoring get pods -o wide || true
    kubectl --kubeconfig "$KUBECONFIG_OUT" -n monitoring get events --sort-by=.lastTimestamp | tail -n 25 || true
    die "prometheus rollout timed out"
  fi

  log "Wait for Loki rollout"
  if ! kubectl --kubeconfig "$KUBECONFIG_OUT" -n monitoring rollout status deploy/loki --timeout=3m; then
    log_warn "Loki rollout timed out. Quick diagnostics:"
    kubectl --kubeconfig "$KUBECONFIG_OUT" -n monitoring get pods -o wide || true
    kubectl --kubeconfig "$KUBECONFIG_OUT" -n monitoring get events --sort-by=.lastTimestamp | tail -n 25 || true
    die "loki rollout timed out"
  fi

  log "Wait for Promtail rollout"
  if ! kubectl --kubeconfig "$KUBECONFIG_OUT" -n monitoring rollout status daemonset/promtail --timeout=3m; then
    log_warn "Promtail rollout timed out. Quick diagnostics:"
    kubectl --kubeconfig "$KUBECONFIG_OUT" -n monitoring get pods -o wide || true
    die "promtail rollout timed out"
  fi

  log "Wait for Grafana rollout"
  if ! kubectl --kubeconfig "$KUBECONFIG_OUT" -n monitoring rollout status deploy/grafana --timeout=3m; then
    log_warn "Grafana rollout timed out. Quick diagnostics:"
    kubectl --kubeconfig "$KUBECONFIG_OUT" -n monitoring get pods -o wide || true
    kubectl --kubeconfig "$KUBECONFIG_OUT" -n monitoring get events --sort-by=.lastTimestamp | tail -n 25 || true
    die "grafana rollout timed out"
  fi

  # Configure Ingress for monitoring (requires Traefik)
  if kubectl --kubeconfig "$KUBECONFIG_OUT" -n traefik-system get deploy/traefik >/dev/null 2>&1; then
    log "Traefik detected - configuring Ingress for monitoring"
    kubectl --kubeconfig "$KUBECONFIG_OUT" apply -f "$ROOT/k8s/addons/grafana-ingress.yaml" >/dev/null
    kubectl --kubeconfig "$KUBECONFIG_OUT" apply -f "$ROOT/k8s/addons/prometheus-ingress.yaml" >/dev/null
  else
    log_warn "Traefik not installed - run 'lab <profile> ingress' first for HTTPS access"
  fi

  log "OK. Monitoring stack deployed!"
  log ""
  log "Grafana: https://grafana.lab.local (admin/admin)"
  log "Prometheus: https://prometheus.lab.local"
}


# Helper: install Traefik if not already running
install_traefik() {
  # Check if Traefik is already running
  if kubectl --kubeconfig "$KUBECONFIG_OUT" -n traefik-system get deploy/traefik >/dev/null 2>&1; then
    log "Traefik already installed"
    return 0
  fi

  # Generate CA and certificates if not present
  local cert_dir="${ROOT}/certs"
  if [[ ! -f "${cert_dir}/ca.crt" ]]; then
    log "Generate TLS certificates"
    "${ROOT}/scripts/generate-ca.sh" "${cert_dir}"
  fi

  log "Install Traefik Ingress Controller"
  kubectl --kubeconfig "$KUBECONFIG_OUT" apply -f "$ROOT/k8s/addons/traefik.yaml" >/dev/null

  # Create TLS secret in traefik-system namespace
  log "Create TLS secret for Traefik"
  kubectl --kubeconfig "$KUBECONFIG_OUT" -n traefik-system create secret tls traefik-tls \
    --cert="${cert_dir}/server.crt" \
    --key="${cert_dir}/server.key" \
    --dry-run=client -o yaml | kubectl --kubeconfig "$KUBECONFIG_OUT" apply -f - >/dev/null

  # Also create in demo and monitoring namespaces (for Ingress resources)
  for ns in demo monitoring; do
    kubectl --kubeconfig "$KUBECONFIG_OUT" create namespace "$ns" --dry-run=client -o yaml | kubectl --kubeconfig "$KUBECONFIG_OUT" apply -f - >/dev/null 2>&1 || true
    kubectl --kubeconfig "$KUBECONFIG_OUT" -n "$ns" create secret tls traefik-tls \
      --cert="${cert_dir}/server.crt" \
      --key="${cert_dir}/server.key" \
      --dry-run=client -o yaml | kubectl --kubeconfig "$KUBECONFIG_OUT" apply -f - >/dev/null
  done

  log "Wait for Traefik rollout"
  if ! kubectl --kubeconfig "$KUBECONFIG_OUT" -n traefik-system rollout status deploy/traefik --timeout=3m; then
    log_warn "Traefik rollout timed out. Quick diagnostics:"
    kubectl --kubeconfig "$KUBECONFIG_OUT" -n traefik-system get pods -o wide || true
    kubectl --kubeconfig "$KUBECONFIG_OUT" -n traefik-system get events --sort-by=.lastTimestamp | tail -n 25 || true
    die "traefik rollout timed out"
  fi

  log ""
  log "TLS certificates generated. To trust the CA, import:"
  log "  ${cert_dir}/ca.crt"
}

# Helper: configure ingress proxy on NixOS-host
configure_ingress_proxy() {
  local cp_ip="$1"

  log "Configure NixOS-host forwarder (443 -> ${cp_ip}:30443)"
  cat > /etc/talos-ingress-proxy.env <<EOF
LISTEN_PORT=443
TARGET_IP=${cp_ip}
TARGET_PORT=30443
EOF

  systemctl restart talos-ingress-proxy.service || log "WARN: talos-ingress-proxy.service not found - run nixos-rebuild switch"
}

cmd_ingress() {
  log "== INGRESS (Traefik) =="
  need kubectl

  [[ -f "$KUBECONFIG_OUT" ]] || die "Missing kubeconfig: $KUBECONFIG_OUT (run: sudo ./scripts/lab ${PROFILE} provision)"

  local cp cp_name cp_ip
  cp="$(first_controlplane)" || die "No controlplane found in nodes.csv"
  cp_name="$(echo "$cp" | awk '{print $1}')"
  cp_ip="$(echo "$cp" | awk '{print $2}')"

  # In single-node labs, remove control-plane taints
  kubectl --kubeconfig "$KUBECONFIG_OUT" taint nodes "${cp_name}" node-role.kubernetes.io/control-plane- >/dev/null 2>&1 || true
  kubectl --kubeconfig "$KUBECONFIG_OUT" taint nodes "${cp_name}" node-role.kubernetes.io/master- >/dev/null 2>&1 || true

  install_traefik

  # Create Ingress for demo (if demo namespace exists)
  if kubectl --kubeconfig "$KUBECONFIG_OUT" get namespace demo >/dev/null 2>&1; then
    log "Create Ingress for demo"
    kubectl --kubeconfig "$KUBECONFIG_OUT" apply -f "$ROOT/k8s/apps/frontend-demo/35-ingress.yaml" >/dev/null
  fi

  # Apply monitoring ingress resources (if monitoring namespace exists)
  if kubectl --kubeconfig "$KUBECONFIG_OUT" get namespace monitoring >/dev/null 2>&1; then
    log "Apply Ingress for Grafana and Prometheus"
    kubectl --kubeconfig "$KUBECONFIG_OUT" apply -f "$ROOT/k8s/addons/grafana-ingress.yaml" >/dev/null
    kubectl --kubeconfig "$KUBECONFIG_OUT" apply -f "$ROOT/k8s/addons/prometheus-ingress.yaml" >/dev/null
  fi

  configure_ingress_proxy "$cp_ip"

  log "OK. Ingress deployed!"
  log ""
  log "On this NixOS-host, /etc/hosts is already configured (127.0.0.1)."
  log "Test with: curl -k https://demo.lab.local"
  log ""
  log "From external machines, use SSH tunnel:"
  log "  ssh -L 443:127.0.0.1:443 user@<nixos-host-ip>"
  log "  Then add to /etc/hosts: 127.0.0.1 demo.lab.local grafana.lab.local prometheus.lab.local"
  log ""
  log "Services:"
  log "  https://demo.lab.local"
  log "  https://grafana.lab.local"
  log "  https://prometheus.lab.local"
}


cmd_all() {
  cmd_up
  cmd_provision
  cmd_verify

  # Install Traefik Ingress Controller
  log "== INGRESS SETUP =="
  local cp cp_ip
  cp="$(first_controlplane)" || die "No controlplane found in nodes.csv"
  cp_ip="$(echo "$cp" | awk '{print $2}')"

  install_traefik
  configure_ingress_proxy "$cp_ip"

  # Deploy demo app (with database) and monitoring stack
  cmd_demo_db
  cmd_monitoring

  log ""
  log "Lab ready!"
  log ""
  log "On this NixOS-host, /etc/hosts is already configured (127.0.0.1)."
  log "Test with: curl -k https://demo.lab.local"
  log ""
  log "From external machines, use SSH tunnel:"
  log "  ssh -L 443:127.0.0.1:443 user@<nixos-host-ip>"
  log "  Then add to /etc/hosts: 127.0.0.1 demo.lab.local grafana.lab.local prometheus.lab.local"
  log ""
  log "Services:"
  log "  https://demo.lab.local"
  log "  https://grafana.lab.local (admin/admin)"
  log "  https://prometheus.lab.local"
}

cmd_plan() {
  log "== PLAN for profile: ${PROFILE} =="
  echo ""

  # Network info
  echo "Network:"
  echo "  Name:       ${TALOS_NET_NAME}"
  echo "  Bridge:     ${TALOS_BRIDGE_NAME}"
  echo "  Gateway:    ${TALOS_GATEWAY}"
  echo "  DHCP range: ${TALOS_DHCP_START} - ${TALOS_DHCP_END}"

  # Check current network state
  local net_state="not defined"
  if virsh -c "$LIBVIRT_URI" net-info "$TALOS_NET_NAME" >/dev/null 2>&1; then
    local active
    active="$(virsh -c "$LIBVIRT_URI" net-info "$TALOS_NET_NAME" | awk -F': *' '/^Active:/{print $2}')"
    if [[ "$active" == "yes" ]]; then
      net_state="active"
    else
      net_state="defined (inactive)"
    fi
  fi
  echo "  Status:     ${net_state}"
  echo ""

  # VMs table
  echo "VMs:"
  printf "  %-20s %-12s %-17s %-8s %-8s %-6s %s\n" "NAME" "ROLE" "IP" "DISK" "RAM" "vCPUs" "STATUS"
  printf "  %-20s %-12s %-17s %-8s %-8s %-6s %s\n" "--------------------" "------------" "-----------------" "--------" "--------" "------" "----------"

  local total_disk=0 total_ram=0 total_vcpus=0
  local row name role ip mac disk_gb ram_mb vcpus vm_status

  while IFS= read -r row; do
    name="$(csv_get "$row" name)"
    role="$(csv_get "$row" role)"
    ip="$(csv_get "$row" ip)"
    disk_gb="$(csv_get "$row" disk_gb)"
    ram_mb="$(csv_get "$row" ram_mb)"
    vcpus="$(csv_get "$row" vcpus)"

    # Check current VM state
    vm_status="to create"
    if virsh -c "$LIBVIRT_URI" dominfo "$name" >/dev/null 2>&1; then
      local state
      state="$(virsh -c "$LIBVIRT_URI" domstate "$name" 2>/dev/null || echo "unknown")"
      vm_status="$state"
    fi

    printf "  %-20s %-12s %-17s %-8s %-8s %-6s %s\n" \
      "$name" "$role" "$ip" "${disk_gb}GB" "${ram_mb}MB" "$vcpus" "[$vm_status]"

    total_disk=$((total_disk + disk_gb))
    total_ram=$((total_ram + ram_mb))
    total_vcpus=$((total_vcpus + vcpus))
  done < <(csv_rows)

  echo ""
  echo "  Total resources: ${total_disk}GB disk, $((total_ram / 1024))GB RAM, ${total_vcpus} vCPUs"
  echo ""

  # Talos state
  echo "Talos state directory: ${TALOS_DIR}"
  if [[ -d "$TALOS_DIR" ]]; then
    echo "  Status: exists"
    [[ -f "${TALOS_DIR}/controlplane.yaml" ]] && echo "  - controlplane.yaml present"
    [[ -f "${TALOS_DIR}/worker.yaml" ]] && echo "  - worker.yaml present"
    [[ -f "${TALOS_DIR}/talosconfig" ]] && echo "  - talosconfig present"
  else
    echo "  Status: will be created"
  fi
  echo ""

  # Kubeconfig
  echo "Kubeconfig: ${KUBECONFIG_OUT}"
  if [[ -f "$KUBECONFIG_OUT" ]]; then
    echo "  Status: exists"
  else
    echo "  Status: will be created after provision"
  fi
  echo ""

  # ISO
  echo "Talos ISO: ${ISO}"
  if [[ -f "$ISO" ]]; then
    local iso_size
    iso_size="$(du -h "$ISO" 2>/dev/null | cut -f1)"
    echo "  Status: present (${iso_size})"
  else
    echo "  Status: MISSING - download required!"
  fi
  echo ""

  # Addons that 'all' command will install
  echo "Addons (installed by 'all' command):"
  echo "  - local-path-provisioner (storage)"
  echo "  - traefik (ingress controller)"
  echo "  - cloudnativepg-operator (database operator)"
  echo "  - prometheus (metrics)"
  echo "  - loki + promtail (logs)"
  echo "  - grafana (dashboards)"
  echo "  - demo-db (demo app with PostgreSQL)"
  echo ""

  # What will happen
  echo "Actions for each command:"
  echo ""
  echo "  'up' will:"
  if [[ "$net_state" == "not defined" ]]; then
    echo "    - Create and start network ${TALOS_NET_NAME}"
  elif [[ "$net_state" == "defined (inactive)" ]]; then
    echo "    - Start network ${TALOS_NET_NAME}"
  else
    echo "    - Network ${TALOS_NET_NAME} already active (no change)"
  fi

  while IFS= read -r row; do
    name="$(csv_get "$row" name)"
    if virsh -c "$LIBVIRT_URI" dominfo "$name" >/dev/null 2>&1; then
      local state
      state="$(virsh -c "$LIBVIRT_URI" domstate "$name" 2>/dev/null || echo "unknown")"
      if [[ "$state" == "running" ]]; then
        echo "    - VM ${name}: already running (no change)"
      else
        echo "    - VM ${name}: start (currently ${state})"
      fi
    else
      echo "    - VM ${name}: create and start"
    fi
  done < <(csv_rows)
  echo ""

  echo "  'provision' will:"
  if [[ -d "$TALOS_DIR" ]] && [[ -f "${TALOS_DIR}/controlplane.yaml" ]]; then
    echo "    - Talos configs exist (will apply to nodes)"
  else
    echo "    - Generate Talos configs (secrets, controlplane.yaml, worker.yaml)"
  fi
  echo "    - Apply config to each node"
  echo "    - Bootstrap cluster (if not already bootstrapped)"
  echo "    - Generate kubeconfig"
  echo ""

  echo "  'wipe' will:"
  echo "    - Destroy and undefine all VMs"
  echo "    - Delete VM disks from ${DISK_DIR}"
  echo "    - Destroy and undefine network ${TALOS_NET_NAME}"
  echo "    - Delete Talos state directory ${TALOS_DIR}"
  echo ""

  log "Plan complete. Run 'sudo ./scripts/lab.sh ${PROFILE} <command>' to execute."
}

case "$CMD" in
  plan) cmd_plan ;;
  status) cmd_status ;;
  net-recreate) net_recreate ;;
  wipe) cmd_wipe ;;
  up) cmd_up ;;
  provision) cmd_provision ;;
  verify) cmd_verify ;;
  all) cmd_all ;;
  demo) cmd_demo ;;
  demo-db) cmd_demo_db ;;
  monitoring) cmd_monitoring ;;
  ingress) cmd_ingress ;;
  *) die "Unknown cmd: $CMD (use: plan|status|up|provision|verify|all|wipe|net-recreate|demo|demo-db|monitoring|ingress)" ;;
esac
