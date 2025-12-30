#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")/.." && pwd)/lib.sh"

lab="${1:-}"
[[ -n "$lab" ]] || die "Usage: 20_network.sh <lab>"
log "Delegating network setup via existing lab.sh"
"$(script_path scripts/lab.sh)" "$lab" up
