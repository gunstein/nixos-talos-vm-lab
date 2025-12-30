#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")/.." && pwd)/lib.sh"

lab="${1:-}"
[[ -n "$lab" ]] || die "Usage: 30_vms.sh <lab>"
log "VM step is handled by existing lab.sh up/all (delegated)."
