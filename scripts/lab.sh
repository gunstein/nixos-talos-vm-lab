#!/run/current-system/sw/bin/bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/common.sh"

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
[[ -n "$PROFILE" && -n "$CMD" ]] || die "Usage: lab.sh <profile> <cmd> (status|up|provision|verify|all|wipe|net-recreate|demo)"

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
  if err="$(virsh -c "$LIBVIRT_URI" net-start "$TALOS_NET_NAME" 2>&1)"; then
    return 0
  fi

  if [[ "$err" =~ interface[[:space:]]+([^[:space:]]+) ]]; then
    local bad_if="${BASH_REMATCH[1]}"
    log "WARN: net-start failed due to interface in use: ${bad_if}"

    if ip link show "$bad_if" >/dev/null 2>&1; then
      log "WARN: Trying to delete stale bridge '${bad_if}'"
      ip link set "$bad_if" down 2>/dev/null || true
      ip link delete "$bad_if" type bridge 2>/dev/null || true
    fi

    log "Retry: net-start ${TALOS_NET_NAME}"
    virsh -c "$LIBVIRT_URI" net-start "$TALOS_NET_NAME" >/dev/null
    return 0
  fi

  log "ERROR: Failed to start network ${TALOS_NET_NAME}"
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
    log "ERROR: Network drift: ${TALOS_NET_NAME} uses '${existing_bridge}', expected '${TALOS_BRIDGE_NAME}'"
    log "Run explicitly:"
    log "  sudo ${ROOT}/scripts/lab.sh ${PROFILE} net-recreate"
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
    log "Talos API not reachable. Check VNC:"
    log "  sudo virsh -c ${LIBVIRT_URI} vncdisplay ${cp_name}"
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

  local cp cp_name cp_ip
  cp="$(first_controlplane)" || die "No controlplane found in nodes.csv"
  cp_name="$(echo "$cp" | awk '{print $1}')"
  cp_ip="$(echo "$cp" | awk '{print $2}')"

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
  local tmp
  tmp="$(mktemp -d)"
  cp -R "${manifests}/." "${tmp}/"
  sed -i "s|__REGISTRY_ADDR__|${registry_addr}|g" "${tmp}/50-backend-deployment.yaml"

  log "Apply demo manifests (rendered) from: ${tmp}"
  kubectl --kubeconfig "$KUBECONFIG_OUT" apply -f "$tmp" >/dev/null
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
    kubectl --kubeconfig "$KUBECONFIG_OUT" -n demo get events --sort-by=.lastTimestamp | tail -n 25 || true
    log "Node taints (common issue in single-node labs):"
    kubectl --kubeconfig "$KUBECONFIG_OUT" describe node "${cp_name}" | sed -n '/Taints:/,/Addresses:/p' || true
    die "demo-frontend rollout timed out"
  fi

  log "Configure NixOS-host forwarder (8080 -> ${cp_ip}:30080)"
  cat > /etc/talos-frontend-proxy.env <<EOF
LISTEN_PORT=8080
TARGET_IP=${cp_ip}
TARGET_PORT=30080
EOF

  systemctl restart talos-frontend-proxy.service

  log "OK. Test from inside this VM:"
  log "  curl -sS http://127.0.0.1:8080/"
  log "  curl -sS http://127.0.0.1:8080/api/hello"
  log "Or directly inside the Talos lab network:"
  log "  curl -sS http://${cp_ip}:30080/"
  log "  curl -sS http://${cp_ip}:30080/api/hello"

  log "To make it reachable from your LAN (outside the Ubuntu host):"
  log "  set up a forwarder on Ubuntu: extras/ubuntu/install-frontend-forward.sh"
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
    log "local-path-provisioner rollout timed out."
    kubectl --kubeconfig "$KUBECONFIG_OUT" -n local-path-storage get pods -o wide || true
    die "local-path-provisioner rollout timed out"
  fi

  # Install CloudNativePG operator (idempotent)
  log "Install CloudNativePG operator"
  kubectl --kubeconfig "$KUBECONFIG_OUT" apply --server-side -f "$ROOT/k8s/addons/cloudnativepg-operator.yaml" >/dev/null

  log "Wait for CloudNativePG operator"
  if ! kubectl --kubeconfig "$KUBECONFIG_OUT" -n cnpg-system rollout status deploy/cnpg-controller-manager --timeout=3m; then
    log "CloudNativePG operator rollout timed out."
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
    log "Database cluster not ready. Quick diagnostics:"
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

  log "Configure NixOS-host forwarder (8080 -> ${cp_ip}:30080)"
  cat > /etc/talos-frontend-proxy.env <<EOF
LISTEN_PORT=8080
TARGET_IP=${cp_ip}
TARGET_PORT=30080
EOF

  systemctl restart talos-frontend-proxy.service

  log "OK. Demo with database deployed!"
  log ""
  log "Test from inside this VM:"
  log "  curl -sS http://127.0.0.1:8080/"
  log "  curl -sS http://127.0.0.1:8080/api/hello"
  log "  curl -sS http://127.0.0.1:8080/api/items"
  log "  curl -X POST http://127.0.0.1:8080/api/items -H 'Content-Type: application/json' -d '{\"name\":\"test\"}'"
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

  # Install Grafana
  log "Install Grafana"
  kubectl --kubeconfig "$KUBECONFIG_OUT" apply -f "$ROOT/k8s/addons/grafana.yaml" >/dev/null

  log "Wait for Prometheus rollout"
  if ! kubectl --kubeconfig "$KUBECONFIG_OUT" -n monitoring rollout status deploy/prometheus --timeout=3m; then
    log "Prometheus rollout timed out. Quick diagnostics:"
    kubectl --kubeconfig "$KUBECONFIG_OUT" -n monitoring get pods -o wide || true
    kubectl --kubeconfig "$KUBECONFIG_OUT" -n monitoring get events --sort-by=.lastTimestamp | tail -n 25 || true
    die "prometheus rollout timed out"
  fi

  log "Wait for Grafana rollout"
  if ! kubectl --kubeconfig "$KUBECONFIG_OUT" -n monitoring rollout status deploy/grafana --timeout=3m; then
    log "Grafana rollout timed out. Quick diagnostics:"
    kubectl --kubeconfig "$KUBECONFIG_OUT" -n monitoring get pods -o wide || true
    kubectl --kubeconfig "$KUBECONFIG_OUT" -n monitoring get events --sort-by=.lastTimestamp | tail -n 25 || true
    die "grafana rollout timed out"
  fi

  log "Configure NixOS-host forwarder for Grafana (3000 -> ${cp_ip}:30300)"
  cat > /etc/talos-grafana-proxy.env <<EOF
LISTEN_PORT=3000
TARGET_IP=${cp_ip}
TARGET_PORT=30300
EOF

  systemctl restart talos-grafana-proxy.service

  log "OK. Monitoring stack deployed!"
  log ""
  log "Grafana: http://127.0.0.1:3000 (admin/admin)"
  log "Prometheus (port-forward): kubectl -n monitoring port-forward svc/prometheus 9090:9090"
}


cmd_all() {
  cmd_up
  cmd_provision
  cmd_verify
}

case "$CMD" in
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
  *) die "Unknown cmd: $CMD (use: status|up|provision|verify|all|wipe|net-recreate|demo|demo-db|monitoring)" ;;
esac
