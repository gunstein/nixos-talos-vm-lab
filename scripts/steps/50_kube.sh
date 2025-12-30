#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")/.." && pwd)/lib.sh"

lab="${1:-}"
[[ -n "$lab" ]] || die "Usage: 50_kube.sh <lab>"

if [[ -f "$(script_path scripts/verify.sh)" ]]; then
  log "Verify cluster (delegating to verify.sh)"
  "$(script_path scripts/verify.sh)" "$lab"
else
  log "Verify cluster (delegating to lab.sh verify)"
  "$(script_path scripts/lab.sh)" "$lab" verify
fi
