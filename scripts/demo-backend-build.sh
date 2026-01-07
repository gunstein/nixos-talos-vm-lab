#!/run/current-system/sw/bin/bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/common.sh"

require_root "$@"

need podman
need systemctl

# Get repo root (scripts/ is one level below)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Local registry on the NixOS-host (NixOS module: services.dockerRegistry)
# We push to 127.0.0.1, but Talos nodes will pull via TALOS_GATEWAY:5000.
REGISTRY_PUSH="${REGISTRY_PUSH:-127.0.0.1:5000}"
IMAGE="${REGISTRY_PUSH}/demo-backend:latest"
APP_DIR="${REPO_ROOT}/apps/demo-backend"

log "Ensure local registry is running (docker-registry.service)"
systemctl start docker-registry.service >/dev/null

log "Build backend image: ${IMAGE}"
podman build -t "${IMAGE}" "${APP_DIR}" >/dev/null

log "Push backend image to local registry: ${REGISTRY_PUSH}"
# Talos pulls over HTTP, so we disable TLS verification here too.
podman push --tls-verify=false "${IMAGE}" >/dev/null

log "OK: pushed ${IMAGE}"
