# VM-based PSSO testing

Setup guide for testing the Platform SSO (PSSO) extension against a real macOS
Extensible SSO stack, using a prebaked "golden" Tart VM image instead of
provisioning MDM enrollment on every test run.

## 1. Overview

The golden image is a reusable, **UAMDM-enrolled** macOS Tart VM with the
Weblogin PSSO configuration profile already installed and the test harness's
disposable CA already trusted. A maintainer bakes it occasionally; everyone
else — UiO/Sunstone staff, and later CI — just clones it. Per-test VMs boot
already enrolled, with the extension's managed config in place, so a test run
never touches MDM, APNs, or enrollment UI.

See `testing/golden/README.md` for the full pipeline (the two seams that make
a clone "just work", and what's out of scope) and `testing/idp/README.md` for
the mock IdP / Keycloak stack the extension talks to.

## 2. Prerequisites

- Apple Silicon Mac (Tart requires Virtualization.framework).
- `tart` (`brew install cirruslabs/cli/tart`), `docker`, `sshpass`.
- Plan 1's test CA: run `testing/idp/gen-test-ca.sh` so `testing/idp/certs/ca.crt`
  exists.
- The **gated one-time APNs push certificate** in
  `testing/golden/nanomdm/secrets/push.pem` + `push.key` — only needed to bake
  the golden image, not to consume it.
- A **signed test build of the extension**. The golden image bakes in a real
  `.mobileconfig` referencing a specific code-signing team; whichever build you
  install must be signed by the team you put in `golden.env`'s `TEAM_ID` (see
  §6–7) or the extension won't load.

## 3. The APNs push certificate

The disposable nanomdm needs one Apple **MDM push certificate** (`push.pem` +
its private key `push.key`, in `testing/golden/nanomdm/secrets/`) to complete
UAMDM enrollment during the bake: nanomdm derives the enrollment profile's
`Topic` from this cert and uses it to send the wake-up push that makes the VM
fetch the `InstallProfile` command. It is a **bake-only** input — per-test
clones never push over APNs (§8), and the profile's `AuthenticationMethod` is
`Password`.

An APNs MDM push certificate is the same kind of certificate every Apple MDM
uses to wake managed devices — it is issued by the **Apple Push Certificates
Portal** (<https://identity.apple.com>) and bound to a *topic*, not to any one
server. So there are two ways to obtain the `push.pem` / `push.key` pair.

### Option A — reuse the push cert your org's MDM already has (recommended)

If your organization already operates an Apple MDM (Jamf, Kandji, Mosyle,
Fleet, Intune, a MicroMDM/nanomdm deployment, …), it already holds a push
certificate of exactly this kind. Reusing it is the pragmatic choice for a
disposable bake:

- Copy the MDM's APNs **certificate *and* its matching private key** into
  `testing/golden/nanomdm/secrets/` as `push.pem` and `push.key`. You need both
  halves — the key is the one generated for the CSR Apple signed, and most MDMs
  cannot hand it back after the fact, so export it wherever it was created.
- nanomdm auto-derives the `Topic` from the cert, so the baked enrollment
  profile simply carries that cert's topic. That's fine.
- **No cross-talk with your production fleet.** MDM pushes are addressed per
  device (via the push-magic token each device sends in its `TokenUpdate`), so
  a bake push only wakes the test VM that checked in to nanomdm — it can never
  reach a production device just because they share a topic.
- The only shared thing is the certificate, hence its **renewal fate**:
  renewing or revoking it in one place affects the other. Acceptable for a
  disposable bake — just don't point production renewal tooling at these copies.

### Option B — mint a dedicated cert

Prefer this only if you'd rather keep test infrastructure from touching
production signing material. The Portal will only accept a CSR that has been
signed by an Apple-approved MDM **vendor** certificate, so unless you are an
approved vendor yourself you need some MDM tool to sign the CSR for you:

1. Use your MDM's "generate/renew APNs certificate" workflow (e.g.
   `fleetctl generate mdm-apple`, MicroMDM's `mdmctl`, or your vendor's
   equivalent) to produce a **vendor-signed CSR** and keep the **private key**
   it generates.
2. Upload the signed CSR to the Apple Push Certificates Portal
   (<https://identity.apple.com>), signed in with the Apple ID that should own
   the cert, and download the issued `.pem`.
3. Place the downloaded `.pem` as `secrets/push.pem` and the private key from
   step 1 as `secrets/push.key`.

Either way both files are **gitignored** (`testing/golden/.gitignore`); only
`secrets/.gitkeep` is tracked. Never commit the cert or key.

## 4. Creating the golden image

Maintainer-run, occasional — not part of the per-test loop.

```bash
cd testing/golden
./make-golden.sh --dry-run     # preview the 10-step plan, no side effects
./make-golden.sh               # full bake
```

The bake: pull the base image, boot it headless, wait for SSH, provision it
(trust the test CA, point `idp.test` at the host), enroll it into a disposable
local nanomdm via UAMDM, push the PSSO profile as an `InstallProfile` command,
shut the VM down, and `tart push` the result. See `make-golden.sh`'s own
header comment and `testing/golden/README.md` for the exact step list.

## 5. Pushing to ghcr.io

`make-golden.sh` pushes automatically at the end of a full bake, to
`${GOLDEN_REMOTE}` = `ghcr.io/<org>/weblogin-psso-test-vm:<macos-ver>` (from
`ORG` and `MACOS_VER` in `golden.env`). You need to be authenticated to GHCR
first with a GitHub PAT that has `write:packages`.

**OPEN ITEM — confirm exact syntax.** Two plausible ways to authenticate `tart`
against GHCR:

```bash
# Option A (tart-native, if supported):
tart login ghcr.io --username <github-user> --password <PAT>

# Option B (via the shared Docker credential store, which tart may reuse):
echo "$PAT" | docker login ghcr.io -u <github-user> --password-stdin
```

Confirm the correct form against current `tart` docs/`tart login --help`
before relying on it — this doc does not assert which one is right.

Once pushed, make the package readable by consumers: either set it **public**
in the GHCR package settings, or grant the org's members **read** access. With
that in place, consumers only ever run:

```bash
tart pull ghcr.io/<org>/weblogin-psso-test-vm:<macos-ver>
```

## 6. Configuring TEAM_ID / ClientID / Issuer / Audience

Four keys in `testing/golden/golden.env` land in the `com.apple.extensiblesso`
payload of the generated `.mobileconfig` (see
`testing/golden/generate-psso-profile.sh`), under the extension's bundle id
`ai.sunstoneinstitute.psso-extension.ssoe`.

| Key | What it is | Where the value comes from |
|---|---|---|
| `TEAM_ID` | Apple Developer Team ID that code-signed the extension binary being installed. Becomes the profile's `TeamIdentifier`. | `SIGNING_TEAM` in `Config/Deployment.xcconfig` (UiO default `L6H6YNBUBK`) or `Config/Local.xcconfig` (Sunstone fork `HZ76GWS9YM`) — must match whichever build you actually install in the VM. |
| `PSSO_CLIENT_ID` | OAuth/OIDC client id the extension presents to the IdP. | The IdP's client registration — for Plan 1's Keycloak realm, `psso-client` (`testing/idp/keycloak/realm-export.json`). The mock IdP doesn't validate `ClientID` at all, so any value works against it. |
| `PSSO_ISSUER` | Expected `iss` claim on minted ID tokens. | The IdP. Mock IdP default is `https://idp.test/realms/test` (`IDP_ISSUER` env var, default in `testing/idp/mock_idp/__main__.py`); Keycloak's real issuer is `https://idp.test:8444/realms/test`. |
| `PSSO_AUDIENCE` | Expected `aud` claim on minted ID tokens. | The IdP. Mock IdP default is `psso-aud` (`IDP_AUDIENCE` env var, same file); Keycloak's realm export has no explicit audience mapper configured, so confirm what `aud` it actually issues before using it as the expected value. |
| `PSSO_BASE_URL` | Redirect/base URL the extension calls (`/psso/nonce`, `/psso/token`, etc., appended to this). | Already correct for the mock: `https://idp.test:8443`. To bake against Keycloak instead, set it to `https://idp.test:8444/realms/test` and re-run the bake (see `testing/golden/README.md`, "Repointing the profile at Keycloak"). |

`golden.env` ships `TEAM_ID`, `PSSO_CLIENT_ID`, `PSSO_ISSUER`, and
`PSSO_AUDIENCE` as `REPLACE_WITH_*` placeholders — fill them in before baking
a real (non-smoke-test) image.

### Does every organization need its own TEAM_ID?

**No.** `TEAM_ID` is not per-MDM-tenant configuration — it is the signing team
of the specific extension binary being installed in the VM. The macOS
ExtensibleSSO subsystem checks that `ExtensionIdentifier`
(`ai.sunstoneinstitute.psso-extension.ssoe`) is actually code-signed by
`TeamIdentifier` in the profile; a mismatch means the extension silently fails
to load (no crash, no visible error — it just never registers).

Two cases:

- **Org deploys a Sunstone-signed binary** → the profile must carry Sunstone's
  team, `HZ76GWS9YM`.
- **Org builds and signs its own copy** (overriding `SIGNING_TEAM` in their own
  `Config/Local.xcconfig`) → the profile must carry *that org's* team instead.

The rule is simple: `TEAM_ID` in `golden.env` must always equal the
`SIGNING_TEAM` of the exact build baked into the VM. Nothing else about the
`.mobileconfig` needs to vary by org for this reason.

By contrast, `PSSO_CLIENT_ID` / `PSSO_ISSUER` / `PSSO_AUDIENCE` genuinely are
per-IdP / per-deployment — they describe which OIDC client and issuer the
extension is authenticating against, which is an IdP-side concern, not a
code-signing one.

## 7. Verifying

```bash
cd testing/idp && docker compose up -d mock-idp   # host-side mock IdP, if not already up
cd ../golden && ./verify-golden.sh
```

`verify-golden.sh` clones the golden image fresh and asserts:

1. user-approved MDM enrollment (`profiles status -type enrollment`),
2. the PSSO payload is present (`profiles list`),
3. the managed `BaseURL` preference is readable under the extension's domain,
4. the test CA is trusted and the mock IdP is reachable over the Tart NAT
   gateway (`curl` with no `--cacert` override).

Each check prints its own `PASS: ...` line — that's the real signal. A failed
check simply skips its `PASS:` line and lets the script continue; read the
per-check output rather than trusting only the final `ALL CHECKS PASSED`
banner.

## 8. Open items / caveats

- `BASE_IMAGE` in `golden.env` is pinned to `:latest`; pin to a specific digest
  before treating a baked image as reproducible.
- `PSSO_CLIENT_ID` / `PSSO_ISSUER` / `PSSO_AUDIENCE` are `REPLACE_WITH_*`
  placeholders — fill in real values from production PSSO configuration before
  using the golden image for anything beyond a mock-IdP smoke test.
- nanomdm / SCEP image tags and CLI flags in `testing/golden/nanomdm/compose.yaml`
  are plausible but unconfirmed against current upstream docs.
- UAMDM approval is driven by a `cliclick` click at a placeholder screen
  coordinate — it's screen/OS-version dependent; `verify_enrolled()` in the
  enrollment library is the actual correctness gate, not the click itself.
- Out of scope entirely: Secure-Enclave-backed key registration (no functional
  guest SE), ADE/DEP enrollment, and per-test APNs pushes. The profile's
  `AuthenticationMethod` is `Password` for this reason.
