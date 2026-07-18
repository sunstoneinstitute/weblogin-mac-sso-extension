#!/usr/bin/env bash
# Boot an already-built golden VM plus the disposable nanomdm stack, for inspection or
# manual poking WITHOUT re-running the full bake. Idempotent — safe to run when either is
# already up. Pair: stop-golden.sh tears both back down.
#
# Usage:
#   ./run-golden.sh            boot ${GOLDEN_LOCAL} (the bake's build VM)
#   ./run-golden.sh <vm-name>  boot a specific local Tart VM instead
set -euo pipefail
cd "$(dirname "$0")"
set -a; . ./golden.env; set +a
. lib/guest.sh; . lib/enroll.sh

VM="${1:-${GOLDEN_LOCAL}}"
GOLDEN_LOCAL="${VM}"                # so guest_ip/wait_for_ssh target this VM
LOG="/tmp/tart-${VM}.log"

vm_running() { tart list 2>/dev/null | grep -w "${VM}" | grep -qw running; }

echo "== nanomdm stack =="
nanomdm_up

echo "== VM ${VM} =="
if vm_running; then
  echo "already running"
else
  nohup tart run "${VM}" --no-graphics --vnc-experimental >"${LOG}" 2>&1 &
  disown
fi

wait_for_ssh
echo
echo "VM ready:  ssh ${GUEST_USER}@$(guest_ip)   (password: ${GUEST_PASS})"
echo "VNC:       $(grep -Eo 'vnc://[^[:space:]]+' "${LOG}" 2>/dev/null | tail -1 || echo '<see '"${LOG}"'>')"
echo "MDM API:   ${NANOMDM_URL}   (device endpoint: https://${IDP_HOST}:9000/mdm via nginx mTLS)"
echo "Down with: ./stop-golden.sh ${VM}"
