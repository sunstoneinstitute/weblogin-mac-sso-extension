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
  # cliclick (drives the login sheet in Plan 3) + Tart guest agent, via preinstalled brew.
  guest_exec "brew install cliclick || true"
  guest_exec "brew install cirruslabs/cli/tart-guest-agent || true"
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
