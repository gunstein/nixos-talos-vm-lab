#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")/.." && pwd)/lib.sh"

# Minimal host checks (safe, read-only)
need_cmd virsh || true
need_cmd ip || true
log "Host checks OK (minimal)"
