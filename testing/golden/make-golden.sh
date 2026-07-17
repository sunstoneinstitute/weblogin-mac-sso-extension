#!/usr/bin/env bash
# Bake the Weblogin PSSO golden VM image. Maintainer-run, occasional. NOT per test.
#
# Pipeline: preflight -> pull base -> boot headless (VNC) -> wait SSH -> provision
# (helpers, trust test CA, /etc/hosts) -> UAMDM enroll + push PSSO profile -> shut down
# -> tart push. Requires Plan 1's testing/idp/certs/ca.crt and a gated APNs push cert.
#
# Usage:
#   ./make-golden.sh            run the full bake
#   ./make-golden.sh --dry-run  print the ordered plan without mutating anything
set -euo pipefail
cd "$(dirname "$0")"
set -a; . ./golden.env; set +a
. lib/preflight.sh; . lib/guest.sh; . lib/provision.sh; . lib/enroll.sh

DRY_RUN=0; [[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

plan() {
  cat <<PLAN
Golden-image bake plan:
  1. preflight            (tart, docker, sshpass, ${CA_CRT}, APNs push cert)
  2. tart clone           ${BASE_IMAGE} -> ${GOLDEN_LOCAL}
  3. tart run             ${GOLDEN_LOCAL} --no-graphics --vnc-experimental (background)
  4. wait_for_ssh
  5. generate PSSO profile (BaseURL=${PSSO_BASE_URL})
  6. provision_guest      (ssh key, cliclick, guest-agent, trust CA, idp.test -> gateway)
  7. enroll_guest         (nanomdm up, UAMDM approve, push InstallProfile)
  8. shutdown + tart stop
  9. tart push            ${GOLDEN_LOCAL} -> ${GOLDEN_REMOTE}
 10. cleanup              (tart delete ${GOLDEN_LOCAL}, nanomdm_down)
PLAN
}

if [[ "$DRY_RUN" == 1 ]]; then plan; exit 0; fi

preflight
plan
tart clone "${BASE_IMAGE}" "${GOLDEN_LOCAL}"
tart run "${GOLDEN_LOCAL}" --no-graphics --vnc-experimental >/tmp/tart-golden.log 2>&1 &
TART_PID=$!
trap 'tart stop "${GOLDEN_LOCAL}" 2>/dev/null || true; nanomdm_down 2>/dev/null || true' EXIT

wait_for_ssh
./generate-psso-profile.sh
provision_guest
enroll_guest

guest_exec "sudo shutdown -h now" || true
tart stop "${GOLDEN_LOCAL}" 2>/dev/null || true
wait "${TART_PID}" 2>/dev/null || true

tart push "${GOLDEN_LOCAL}" "${GOLDEN_REMOTE}"
echo "PUSHED ${GOLDEN_REMOTE}"

nanomdm_down
tart delete "${GOLDEN_LOCAL}"
echo "BAKE COMPLETE"
