#!/usr/bin/env bash
# Stop a running golden VM and tear down the disposable nanomdm stack. Mirrors the EXIT
# trap in make-golden.sh. Does NOT delete the VM (use `tart delete <vm>` for that) and
# keeps the gitignored nanomdm/secrets/ (push cert, CAs, enrollment data bind mount).
#
# Usage:
#   ./stop-golden.sh            stop ${GOLDEN_LOCAL}
#   ./stop-golden.sh <vm-name>  stop a specific local Tart VM instead
set -euo pipefail
cd "$(dirname "$0")"
set -a; . ./golden.env; set +a
. lib/enroll.sh

VM="${1:-${GOLDEN_LOCAL}}"

if tart stop "${VM}" 2>/dev/null; then echo "stopped VM ${VM}"; else echo "VM ${VM} was not running"; fi
nanomdm_down
echo "nanomdm stack down"
