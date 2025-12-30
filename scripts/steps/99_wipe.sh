#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")/.." && pwd)/lib.sh"

lab="${1:-}"
[[ -n "$lab" ]] || die "Usage: 99_wipe.sh <lab>"
log "Wipe lab (delegating to existing lab.sh wipe)"
"$(script_path scripts/lab.sh)" "$lab" wipe
