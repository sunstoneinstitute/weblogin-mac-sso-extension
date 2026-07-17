# Golden VM image pipeline

Bakes a reusable, UAMDM-enrolled macOS Tart image with the Weblogin PSSO
configuration profile installed and the disposable test CA trusted, then pushes
it to GHCR. Per-test runs (Plan 3) just `tart clone` this image — they never run
this pipeline, nanomdm, or APNs.

## Who runs what

- **Maintainer, occasionally:** `./make-golden.sh` — the full bake. Needs a
  one-time **gated APNs push certificate** in `nanomdm/secrets/` (see
  `nanomdm/.env.example`). Never runs per test.
- **Consumers (UiO + Sunstone staff, CI later):** `tart pull ghcr.io/<org>/weblogin-psso-test-vm:<macos-ver>`.
  Nothing else.

## Prerequisites

- Apple Silicon Mac; `tart` (`brew install cirruslabs/cli/tart`), `docker`, `sshpass`.
- **Plan 1's test CA:** run `../idp/gen-test-ca.sh` so `../idp/certs/ca.crt` exists.
- Gated **APNs push cert**: `nanomdm/secrets/push.pem` + `push.key`.

## Bake

    ./make-golden.sh --dry-run     # preview the 10-step plan
    ./make-golden.sh               # full bake -> tart push

## Verify the result

Start Plan 1's mock IdP on the host (`cd ../idp && docker compose up -d mock-idp`),
then:

    ./verify-golden.sh             # clones the golden image, asserts:
                                   #   user-approved MDM, PSSO payload present,
                                   #   managed BaseURL pref, CA trusted + mock
                                   #   reachable over NAT

## The two seams (why a clone "just works")

1. **Test CA trusted** in the guest System keychain, so mock/Keycloak TLS
   validates. The CA is disposable and test-only — never trust it on a real Mac.
2. **`/etc/hosts`**: `idp.test` -> the guest's default gateway (the host under
   Tart NAT), so the guest reaches `https://idp.test:8443` (mock) or
   `:8444/realms/test` (Keycloak).

## Repointing the profile at Keycloak

The PSSO profile's `BaseURL` defaults to the mock (`https://idp.test:8443`). To
bake against real Keycloak instead, set
`PSSO_BASE_URL=https://idp.test:8444/realms/test` in `golden.env` and re-run.

## Out of scope

SE-backed registration (no functional guest Secure Enclave), ADE/DEP enrollment,
and real APNs in the per-test loop. See the design spec.
