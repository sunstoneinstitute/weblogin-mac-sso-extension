#!/usr/bin/env bash
# Generate a DISPOSABLE, TEST-ONLY root CA and an idp.test server cert.
# The CA is deliberately low-value and is trusted only inside test VMs.
# Never trust this CA on a real machine.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p certs
cd certs

if [[ -f ca.crt && "${1:-}" != "--force" ]]; then
  echo "certs/ca.crt already exists; pass --force to regenerate" >&2
  exit 0
fi

# Root CA
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout ca.key -out ca.crt \
  -subj "/CN=Weblogin PSSO Test Root CA"

# Server key + CSR for idp.test
openssl req -newkey rsa:2048 -nodes \
  -keyout idp.test.key -out idp.test.csr \
  -subj "/CN=idp.test"

# Sign with SAN
openssl x509 -req -in idp.test.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -days 3650 -out idp.test.crt \
  -extfile <(printf "subjectAltName=DNS:idp.test,DNS:localhost,IP:127.0.0.1")

rm -f idp.test.csr
echo "Wrote certs/ca.crt, certs/idp.test.crt, certs/idp.test.key"
