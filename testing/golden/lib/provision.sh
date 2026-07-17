# Sourced by make-golden.sh. Installs guest helpers and wires the two test seams:
#   1) trust the disposable test CA so mock/Keycloak TLS validates in the guest
#   2) /etc/hosts: idp.test -> the host NAT gateway (the guest's default gateway)
# shellcheck shell=bash

install_helpers() {
  # SSH pubkey into the test user (passwordless steps for the harness in Plan 3).
  if [[ -f "${HOME}/.ssh/id_ed25519.pub" ]]; then
    guest_exec "mkdir -p ~/.ssh && chmod 700 ~/.ssh"
    guest_exec "cat >> ~/.ssh/authorized_keys" < "${HOME}/.ssh/id_ed25519.pub"
    guest_exec "chmod 600 ~/.ssh/authorized_keys"
  else
    echo "WARN: no ~/.ssh/id_ed25519.pub on host; skipping key install" >&2
  fi
  # Homebrew is preinstalled on the cirruslabs base at /opt/homebrew, but its shellenv is
  # only wired into ~/.zprofile (login shells). guest_exec runs non-interactive, non-login
  # SSH commands, which source ~/.zshenv only — so persist brew's shellenv there to put
  # brew (and everything it installs: cliclick, tart-guest-agent) on PATH for every
  # subsequent guest_exec, including the cliclick call in enroll.sh.
  # shellcheck disable=SC2016  # $(...) is deliberately literal — evaluated in the guest.
  guest_exec 'grep -q "brew shellenv" ~/.zshenv 2>/dev/null || \
    echo '\''eval "$(/opt/homebrew/bin/brew shellenv)"'\'' >> ~/.zshenv'
  # cliclick drives the UAMDM approval sheet (enroll.sh); homebrew/core, fail loud on error.
  guest_exec "brew install cliclick"
  # tart-guest-agent ships preinstalled on the base; reinstall only if a future base drops
  # it (third-party tap, so bypass the interactive trust gate on that fallback path).
  guest_exec "command -v tart-guest-agent >/dev/null || \
    HOMEBREW_NO_REQUIRE_TAP_TRUST=1 brew install cirruslabs/cli/tart-guest-agent"
  # Never ship a golden image with the helpers missing — fail the bake instead.
  guest_exec "command -v cliclick >/dev/null && command -v tart-guest-agent >/dev/null" \
    || { echo "FATAL: helper tools missing after install (cliclick/tart-guest-agent)" >&2; return 1; }
}

trust_test_ca() {
  guest_push "${CA_CRT}" "/tmp/test-ca.crt"
  # System keychain trust requires sudo; cirruslabs admin has passwordless sudo.
  guest_exec "sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain /tmp/test-ca.crt"
}

set_hosts_entry() {
  # Inside a Tart NAT guest the host is the default gateway. Map idp.test to it.
  guest_exec "GW=\$(route -n get default | awk '/gateway/{print \$2}'); \
    echo \"\$GW ${IDP_HOST}\" | sudo tee -a /etc/hosts >/dev/null; \
    echo \"mapped ${IDP_HOST} -> \$GW\""
}

provision_guest() {
  install_helpers
  trust_test_ca
  set_hosts_entry
}
