#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")/.." && pwd)/lib.sh"

lab="${1:-}"
[[ -n "$lab" ]] || die "Usage: 90_diag.sh <lab>"

if [[ -f "$(script_path scripts/diag.sh)" ]]; then
  "$(script_path scripts/diag.sh)" "$lab"
else
  log "No diag.sh found; basic virsh status:"
  virsh -c qemu:///system net-list --all || true
  virsh -c qemu:///system list --all || true
fi
