# Sourced by make-golden.sh. SSH plumbing against the booting guest.
# shellcheck shell=bash

_ssh() { sshpass -p "${GUEST_PASS}" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$@"; }
_scp() { sshpass -p "${GUEST_PASS}" scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$@"; }

guest_ip() { tart ip "${GOLDEN_LOCAL}"; }

wait_for_ssh() {
  local ip deadline=$((SECONDS + 300))
  echo "waiting for guest SSH..."
  while (( SECONDS < deadline )); do
    ip="$(tart ip "${GOLDEN_LOCAL}" 2>/dev/null || true)"
    if [[ -n "$ip" ]] && _ssh "${GUEST_USER}@${ip}" true 2>/dev/null; then
      echo "guest reachable at ${ip}"; return 0
    fi
    sleep 5
  done
  echo "timed out waiting for guest SSH" >&2; return 1
}

guest_exec() { _ssh "${GUEST_USER}@$(guest_ip)" "$@"; }
guest_push() { _scp "$1" "${GUEST_USER}@$(guest_ip):$2"; }

# Hardware UUID (== MDM UDID) for addressing nanomdm commands.
guest_udid() {
  guest_exec "ioreg -rd1 -c IOPlatformExpertDevice | awk -F'\"' '/IOPlatformUUID/{print \$4}'"
}
