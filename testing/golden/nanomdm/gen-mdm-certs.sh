#!/usr/bin/env bash
# Mint the disposable MDM certs for the bake-time mock MDM. All output lands in the
# gitignored secrets/ dir; nothing here is real signing material. Pure openssl — no
# container images, no external registries.
#
#   secrets/scep-depot/ca.pem,ca.key  device CA: SCEP issues device identity certs from it;
#                                     nginx verifies device client certs against it; nanomdm
#                                     validates with -ca.
#   secrets/mdm-certs/mdm-server.*    TLS server cert for idp.test, signed by the shared test
#                                     CA (../idp/certs) so the already-trusting guest accepts
#                                     the nginx MDM endpoint.
set -euo pipefail
cd "$(dirname "$0")"

IDP_CA="../../idp/certs"                 # relative to testing/golden/nanomdm/
DEPOT="secrets/scep-depot"
MDMC="secrets/mdm-certs"
mkdir -p "$DEPOT" "$MDMC"

# 1. Device / SCEP CA (unencrypted key so scepserver loads it with -capass "").
if [[ -f "$DEPOT/ca.pem" ]]; then
  echo "device CA already present: $DEPOT/ca.pem"
else
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$DEPOT/ca.key" -out "$DEPOT/ca.pem" \
    -subj "/CN=Weblogin PSSO Test Device CA"
  # micromdm/scep file depot bookkeeping.
  touch "$DEPOT/index.txt"
  [[ -f "$DEPOT/serial" ]] || echo "2" > "$DEPOT/serial"
  echo "minted device CA: $DEPOT/ca.pem"
fi

# 2. MDM TLS server cert for idp.test, signed by the test CA the guest trusts.
if [[ -f "$MDMC/mdm-server.crt" ]]; then
  echo "MDM server cert already present: $MDMC/mdm-server.crt"
else
  [[ -f "$IDP_CA/ca.crt" && -f "$IDP_CA/ca.key" ]] || {
    echo "missing test CA at $IDP_CA (run ../../idp/gen-test-ca.sh first)" >&2; exit 1; }
  openssl req -newkey rsa:2048 -nodes -keyout "$MDMC/mdm-server.key" \
    -out "$MDMC/mdm-server.csr" -subj "/CN=idp.test"
  openssl x509 -req -in "$MDMC/mdm-server.csr" \
    -CA "$IDP_CA/ca.crt" -CAkey "$IDP_CA/ca.key" -CAcreateserial \
    -days 3650 -out "$MDMC/mdm-server.crt" \
    -extfile <(printf "subjectAltName=DNS:idp.test,DNS:localhost,IP:127.0.0.1")
  rm -f "$MDMC/mdm-server.csr"
  echo "minted MDM server cert: $MDMC/mdm-server.crt"
fi
