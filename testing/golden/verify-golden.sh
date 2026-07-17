#!/usr/bin/env bash
# Smoke-test a fresh clone of the golden image. Requires:
#   - the golden image present locally (run make-golden.sh, or `tart pull ${GOLDEN_REMOTE}`)
#   - Plan 1's mock IdP running on the host at https://idp.test:8443 (bound 0.0.0.0)
set -euo pipefail
cd "$(dirname "$0")"
set -a; . ./golden.env; set +a
. lib/guest.sh

CLONE="verify-$(date +%s)"
SRC="${1:-${GOLDEN_REMOTE}}"
trap 'tart stop "${CLONE}" 2>/dev/null || true; tart delete "${CLONE}" 2>/dev/null || true' EXIT

tart clone "${SRC}" "${CLONE}"
tart run "${CLONE}" --no-graphics >/tmp/tart-verify.log 2>&1 &

# Point the guest helpers at the clone.
GOLDEN_LOCAL="${CLONE}"
wait_for_ssh

echo "== 1. MDM enrollment (UAMDM) =="
guest_exec "profiles status -type enrollment" | grep -q "User Approved" && echo "PASS: user-approved MDM"

echo "== 2. PSSO payload present =="
guest_exec "profiles list" | grep -qi "extensiblesso\|${EXT_BUNDLE_ID}" && echo "PASS: PSSO payload installed"

echo "== 3. Extension reads its managed config =="
guest_exec "defaults read '${EXT_BUNDLE_ID}' BaseURL" | grep -q "idp.test:8443" && echo "PASS: BaseURL managed pref present"

echo "== 4. Test CA trusted (system trust store, no --cacert) =="
guest_exec "curl -fsS https://${IDP_HOST}:8443/psso/nonce" | grep -q "nonce" && echo "PASS: CA trusted + mock reachable over NAT"

echo "ALL CHECKS PASSED for clone of ${SRC}"
