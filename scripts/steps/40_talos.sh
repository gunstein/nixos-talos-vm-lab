#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")/.." && pwd)/lib.sh"

lab="${1:-}"
[[ -n "$lab" ]] || die "Usage: 40_talos.sh <lab>"

if [[ -f "$(script_path scripts/talos-provision.sh)" ]]; then
  log "Provision Talos (delegating to talos-provision.sh)"
  "$(script_path scripts/talos-provision.sh)" "$lab"
else
  log "Provision Talos (delegating to lab.sh provision)"
  "$(script_path scripts/lab.sh)" "$lab" provision
fi
