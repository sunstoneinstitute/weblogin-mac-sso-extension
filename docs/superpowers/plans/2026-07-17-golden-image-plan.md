# Golden VM Image Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the maintainer-run pipeline that bakes a reusable, MDM-enrolled macOS golden VM image — Tart base image → UAMDM enroll into a disposable nanomdm → PSSO configuration profile installed → test CA trusted → guest helpers + `/etc/hosts` seam in place → shut down → `tart push` to GHCR — so that every per-test `tart clone` boots an already-enrolled machine in seconds.

**Architecture:** A `make-golden.sh` orchestrator sources focused `lib/*.sh` units (preflight, guest SSH, provisioning, enrollment). A disposable `nanomdm` (plus SCEP) runs in `docker compose` only during the bake. A `generate-psso-profile.sh` emits the Extensible/Platform SSO `.mobileconfig` carrying the four keys the extension reads (`ClientID`, `BaseURL`, `Issuer`, `Audience`) under the extension's bundle-id preferences domain (`ai.sunstoneinstitute.psso-extension.ssoe`). A `verify-golden.sh` smoke-tests a fresh clone of the baked image. Verification throughout is **smoke tests** (syntax lint, `docker compose config`, `tart exec`/ssh assertions, `profiles list`, guest→host `curl`), not unit tests — these are infrastructure/shell steps with no pure-logic surface to TDD.

**Tech Stack:** Tart (Apple Silicon, Virtualization.framework); Bash; Docker Compose; nanomdm + micromdm/scep; Apple `profiles`/`security`/`app-sso`; `cliclick` + Tart `--vnc-experimental` framebuffer for the one GUI approval click; `plutil`/`openssl` for profile and cert handling.

**This is Plan 2 of 3.** Plan 1 (`2026-07-17-idp-stack-plan.md`) = fault-injectable mock IdP + Keycloak fidelity stack. Plan 3 = pytest harness + `test-pkg.sh` + reporting + coverage spike.

**Dependencies on Plan 1 (must be satisfied before the bake runs):**
- **`testing/idp/certs/ca.crt`** — the disposable test root CA produced by Plan 1's `testing/idp/gen-test-ca.sh`. The bake copies this into the guest's System keychain as a trusted root so mock/Keycloak TLS validates inside the VM.
- **The running mock IdP at `https://idp.test:8443`** (Plan 1's `docker compose up mock-idp`, bound on `0.0.0.0`). Used by `verify-golden.sh` to prove a fresh clone can reach the host mock over Tart NAT.

**Out of scope (per the design spec, restated so no one adds it here):**
- **SE-backed registration end-to-end** — Virtualization.framework guests have no functional Secure Enclave, so hardware-bound key provisioning cannot complete in a VM. The golden image only needs to be UAMDM-enrolled with the PSSO profile present and managed state true; the `PlatformSSO` authentication method is therefore `Password`, not `UserSecureEnclaveKey`.
- **ADE/DEP enrollment** — no real serial / SEP attestation in a VM. Enrollment is **UAMDM** via manual profile install + a scripted GUI approval click.
- **Real APNs in the per-test loop** — the APNs push certificate is a one-time, gated maintainer input used only during the bake (see Task 3), never per test.

**Outcome:** A shareable OCI artifact `ghcr.io/<org>/weblogin-psso-test-vm:<macos-ver>`. Consumers (UiO + Sunstone staff, and later a self-hosted arm64 CI runner) just `tart pull` it; they never run this pipeline or touch nanomdm/APNs.

---

## File Structure

```
testing/golden/
├─ golden.env                  bake config: base image, org/tag, guest creds, PSSO key values, paths
├─ .gitignore                  nanomdm/secrets/, *.log, *.mobileconfig build artifacts
├─ make-golden.sh              orchestrator; sources lib/*.sh, runs the ordered pipeline; --dry-run
├─ verify-golden.sh            post-bake smoke test: clone → boot → assert enrolled/profile/CA/NAT
├─ generate-psso-profile.sh    emits psso-profile.mobileconfig from golden.env
├─ lib/
│  ├─ preflight.sh             assert tart, docker, ca.crt, APNs push cert present before mutating
│  ├─ guest.sh                 ssh helpers: wait_for_ssh, guest_exec, guest_push, guest_udid
│  ├─ provision.sh             install helpers (ssh key, cliclick, guest agent), /etc/hosts, trust CA
│  └─ enroll.sh                nanomdm up, enrollment profile, UAMDM approve (cliclick), push PSSO profile
├─ nanomdm/
│  ├─ compose.yaml             nanomdm + scep, 0.0.0.0 binds, file storage
│  ├─ .env.example             NANOMDM_API_KEY + push-cert paths (copy to .env, fill in)
│  └─ secrets/                 (gitignored) push.pem/push.key ← gated maintainer input
└─ README.md                   added last
```

The four `lib/*.sh` units each have one responsibility and are sourced (not executed) by `make-golden.sh`, so each is independently syntax-checkable and its functions callable in isolation.

---

### Task 1: Scaffold `testing/golden/` config and ignore rules

**Files:**
- Create: `testing/golden/golden.env`
- Create: `testing/golden/.gitignore`

- [ ] **Step 1: Create `golden.env`**

`testing/golden/golden.env`:

```bash
# Bake configuration for the Weblogin PSSO golden VM image.
# Sourced by make-golden.sh and generate-psso-profile.sh. Shell syntax.

# --- Image identity ---
ORG="sunstoneinstitute"
MACOS_VER="tahoe-26"                                     # tag suffix; see OPEN ITEM (pin exact base)
BASE_IMAGE="ghcr.io/cirruslabs/macos-tahoe-base:latest"  # OPEN ITEM: pin to a digest, not :latest
GOLDEN_LOCAL="weblogin-psso-golden-build"                # transient local Tart VM name during bake
GOLDEN_REMOTE="ghcr.io/${ORG}/weblogin-psso-test-vm:${MACOS_VER}"

# --- Guest access (cirruslabs base images ship admin/admin) ---
GUEST_USER="admin"
GUEST_PASS="admin"

# --- Extension identity (from Config/Local.xcconfig) ---
# The extension reads its managed prefs via CFPreferences with domain == its bundle id,
# so the PSSO payload MUST carry ClientID/BaseURL/Issuer/Audience under this identifier.
EXT_BUNDLE_ID="ai.sunstoneinstitute.psso-extension.ssoe"
APP_GROUP_ID="group.ai.sunstoneinstitute.psso"
TEAM_ID="REPLACE_WITH_TEAM_ID"                           # OPEN ITEM: real Apple Team ID

# --- PSSO config keys the extension reads (Helpers.swift / AuthenticationViewController.swift) ---
PSSO_CLIENT_ID="REPLACE_WITH_CLIENT_ID"                  # OPEN ITEM: real ClientID
PSSO_BASE_URL="https://idp.test:8443"                    # mock IdP (Plan 1). Keycloak: https://idp.test:8444/realms/test
PSSO_ISSUER="REPLACE_WITH_ISSUER"                        # OPEN ITEM: real Issuer
PSSO_AUDIENCE="REPLACE_WITH_AUDIENCE"                    # OPEN ITEM: real Audience

# --- Seams ---
IDP_HOST="idp.test"                                      # guest /etc/hosts maps this to the NAT gateway
CA_CRT="../idp/certs/ca.crt"                             # Plan 1 output, relative to testing/golden/

# --- Disposable MDM (bake-time only) ---
NANOMDM_URL="http://localhost:9000"                      # nanomdm command/enqueue API on the host
NANOMDM_API_KEY="testkey"                                # matches nanomdm/.env
```

- [ ] **Step 2: Create `.gitignore`**

`testing/golden/.gitignore`:

```
nanomdm/secrets/
nanomdm/.env
*.mobileconfig
*.log
```

- [ ] **Step 3: Verify the env file sources cleanly**

Run:
```bash
cd testing/golden && bash -n <(printf '%s\n' "set -e") && ( set -a; . ./golden.env; printf 'EXT=%s BASE=%s\n' "$EXT_BUNDLE_ID" "$PSSO_BASE_URL" )
```
Expected: `EXT=ai.sunstoneinstitute.psso-extension.ssoe BASE=https://idp.test:8443`

- [ ] **Step 4: Commit**

```bash
git add testing/golden/golden.env testing/golden/.gitignore
git commit -m "test(golden): scaffold golden-image bake config"
```

---

### Task 2: PSSO configuration profile generator

**Files:**
- Create: `testing/golden/generate-psso-profile.sh`

- [ ] **Step 1: Write the generator**

`testing/golden/generate-psso-profile.sh`:

```bash
#!/usr/bin/env bash
# Emit the Extensible/Platform SSO configuration profile the extension consumes.
# The four vendor keys (ClientID/BaseURL/Issuer/Audience) sit in the SSO payload dict
# and become readable by the extension via CFPreferencesCopyAppValue(key, EXT_BUNDLE_ID).
# Auth method is Password: SE-backed keys cannot provision in a VM (out of scope).
set -euo pipefail
cd "$(dirname "$0")"
set -a; . ./golden.env; set +a

OUT="${1:-psso-profile.mobileconfig}"
PAYLOAD_UUID="$(uuidgen)"
PROFILE_UUID="$(uuidgen)"

cat > "$OUT" <<PROFILE
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>PayloadType</key><string>Configuration</string>
  <key>PayloadVersion</key><integer>1</integer>
  <key>PayloadIdentifier</key><string>${EXT_BUNDLE_ID}.psso</string>
  <key>PayloadUUID</key><string>${PROFILE_UUID}</string>
  <key>PayloadDisplayName</key><string>Weblogin PSSO (test)</string>
  <key>PayloadContent</key>
  <array>
    <dict>
      <key>PayloadType</key><string>com.apple.extensiblesso</string>
      <key>PayloadVersion</key><integer>1</integer>
      <key>PayloadIdentifier</key><string>${EXT_BUNDLE_ID}.psso.sso</string>
      <key>PayloadUUID</key><string>${PAYLOAD_UUID}</string>
      <key>PayloadDisplayName</key><string>Platform SSO Extension</string>
      <key>ExtensionIdentifier</key><string>${EXT_BUNDLE_ID}</string>
      <key>TeamIdentifier</key><string>${TEAM_ID}</string>
      <key>Type</key><string>Redirect</string>
      <key>URLs</key>
      <array><string>${PSSO_BASE_URL}</string></array>
      <key>PlatformSSO</key>
      <dict>
        <key>AuthenticationMethod</key><string>Password</string>
        <key>UseSharedDeviceKeys</key><true/>
      </dict>
      <key>ClientID</key><string>${PSSO_CLIENT_ID}</string>
      <key>BaseURL</key><string>${PSSO_BASE_URL}</string>
      <key>Issuer</key><string>${PSSO_ISSUER}</string>
      <key>Audience</key><string>${PSSO_AUDIENCE}</string>
    </dict>
  </array>
</dict>
</plist>
PROFILE

echo "Wrote ${OUT}"
```

- [ ] **Step 2: Make executable and run it**

Run:
```bash
chmod +x testing/golden/generate-psso-profile.sh && testing/golden/generate-psso-profile.sh
```
Expected: prints `Wrote psso-profile.mobileconfig`

- [ ] **Step 3: Lint the emitted profile and confirm the keys are present**

Run:
```bash
plutil -lint testing/golden/psso-profile.mobileconfig
grep -c -E 'ClientID|BaseURL|Issuer|Audience|com.apple.extensiblesso' testing/golden/psso-profile.mobileconfig
```
Expected: first line ends `OK`; second prints `5` (four vendor keys + the payload type).

- [ ] **Step 4: Confirm BaseURL points at the mock by default**

Run: `grep -A1 '<key>BaseURL</key>' testing/golden/psso-profile.mobileconfig`
Expected: contains `https://idp.test:8443`. (To target Keycloak instead, set `PSSO_BASE_URL=https://idp.test:8444/realms/test` in `golden.env` and regenerate.)

- [ ] **Step 5: Commit (script only — `*.mobileconfig` is gitignored)**

```bash
git add testing/golden/generate-psso-profile.sh
git commit -m "test(golden): PSSO configuration profile generator"
```

---

### Task 3: Disposable nanomdm docker compose (APNs cert gated)

**Files:**
- Create: `testing/golden/nanomdm/compose.yaml`
- Create: `testing/golden/nanomdm/.env.example`
- Create: `testing/golden/nanomdm/secrets/.gitkeep`

> **GATED MAINTAINER STEP — APNs push certificate.** nanomdm needs an Apple **MDM push certificate** (`push.pem` + `push.key`) to send the check-in push that delivers the `InstallProfile` command during the bake. Obtaining it (Apple Push Certificates Portal, via an MDM vendor CSR) is a **one-time human step done by a maintainer**, not part of any automated run and **never executed per test**. Drop the files into `nanomdm/secrets/` (gitignored). Everything downstream of this cert lives only in the bake; consumers who `tart pull` the finished image never see nanomdm or APNs.

- [ ] **Step 1: Write the compose file**

`testing/golden/nanomdm/compose.yaml`:

```yaml
# Disposable MDM used ONLY during the golden-image bake. Not a per-test dependency.
# Binds 0.0.0.0 so the guest VM can reach the SCEP/MDM endpoints over Tart NAT.
services:
  scep:
    image: micromdm/scep:v2.1.0            # OPEN ITEM: confirm tag against upstream
    command:
      - "-allowrenew=0"
      - "-challenge=testchallenge"
      - "-depot=/depot"
      - "-port=8080"
    volumes:
      - ./secrets/scep-depot:/depot
    ports:
      - "0.0.0.0:8080:8080"

  nanomdm:
    image: ghcr.io/micromdm/nanomdm:latest  # OPEN ITEM: confirm image + flags against upstream
    command:
      - "-api=${NANOMDM_API_KEY}"
      - "-cert-header=X-Forwarded-Client-Cert"
      - "-push-cert=/secrets/push.pem"
      - "-push-key=/secrets/push.key"
      - "-storage=file"
      - "-storage-dsn=/data"
      - "-listen=0.0.0.0:9000"
    environment:
      NANOMDM_API_KEY: "${NANOMDM_API_KEY}"
    volumes:
      - ./secrets:/secrets:ro
      - ./secrets/nanomdm-data:/data
    ports:
      - "0.0.0.0:9000:9000"
    depends_on:
      - scep
```

- [ ] **Step 2: Write `.env.example`**

`testing/golden/nanomdm/.env.example`:

```
# Copy to .env and fill in. .env is gitignored.
NANOMDM_API_KEY=testkey
# Place the GATED APNs push certificate here (one-time maintainer step):
#   secrets/push.pem   secrets/push.key
```

- [ ] **Step 3: Create the secrets placeholder**

`testing/golden/nanomdm/secrets/.gitkeep`:

```
# APNs push cert (push.pem/push.key) and SCEP/nanomdm state live here at bake time.
# Gitignored. This directory is intentionally empty in git.
```

- [ ] **Step 4: Validate compose parses (no images pulled, no secrets needed)**

Run:
```bash
cd testing/golden/nanomdm && cp .env.example .env && docker compose config >/dev/null && echo COMPOSE_OK
```
Expected: prints `COMPOSE_OK` (compose interpolates `${NANOMDM_API_KEY}` and validates the two services). Then `rm .env`.

- [ ] **Step 5: Commit (compose + templates only; `secrets/` and `.env` gitignored)**

```bash
git add testing/golden/nanomdm/compose.yaml testing/golden/nanomdm/.env.example testing/golden/nanomdm/secrets/.gitkeep
git commit -m "test(golden): disposable nanomdm+scep compose (APNs cert gated)"
```

---

### Task 4: Preflight checks + guest SSH helper library

**Files:**
- Create: `testing/golden/lib/preflight.sh`
- Create: `testing/golden/lib/guest.sh`

- [ ] **Step 1: Write `lib/preflight.sh`**

`testing/golden/lib/preflight.sh`:

```bash
# Sourced by make-golden.sh. Asserts every prerequisite BEFORE anything mutates state.
# shellcheck shell=bash

preflight() {
  local ok=1
  command -v tart  >/dev/null || { echo "MISSING: tart (brew install cirruslabs/cli/tart)" >&2; ok=0; }
  command -v docker >/dev/null || { echo "MISSING: docker" >&2; ok=0; }
  command -v sshpass >/dev/null || { echo "MISSING: sshpass (brew install sshpass)" >&2; ok=0; }
  command -v cliclick >/dev/null || echo "WARN: cliclick not on host (only needed if driving VNC from host)" >&2

  # Plan 1 dependency: the disposable test CA.
  if [[ ! -f "${CA_CRT}" ]]; then
    echo "MISSING: ${CA_CRT} — run Plan 1's testing/idp/gen-test-ca.sh first" >&2
    ok=0
  fi
  # GATED APNs push cert.
  if [[ ! -f "nanomdm/secrets/push.pem" || ! -f "nanomdm/secrets/push.key" ]]; then
    echo "MISSING: nanomdm/secrets/push.{pem,key} — one-time gated APNs cert (see nanomdm/.env.example)" >&2
    ok=0
  fi
  [[ "$ok" == 1 ]] || { echo "preflight FAILED" >&2; return 1; }
  echo "preflight OK"
}
```

- [ ] **Step 2: Write `lib/guest.sh`**

`testing/golden/lib/guest.sh`:

```bash
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
```

- [ ] **Step 3: Syntax-check both libraries**

Run:
```bash
bash -n testing/golden/lib/preflight.sh && bash -n testing/golden/lib/guest.sh && echo SYNTAX_OK
```
Expected: prints `SYNTAX_OK`

- [ ] **Step 4: Smoke-test that the functions load and are callable**

Run:
```bash
( set -a; . testing/golden/golden.env; set +a
  . testing/golden/lib/guest.sh
  type wait_for_ssh guest_exec guest_udid >/dev/null && echo FUNCS_OK )
```
Expected: prints `FUNCS_OK` (functions defined without executing tart/ssh).

- [ ] **Step 5: Lint with shellcheck if available**

Run: `command -v shellcheck >/dev/null && shellcheck -x testing/golden/lib/preflight.sh testing/golden/lib/guest.sh || echo "shellcheck not installed - skipped"`
Expected: no errors, or the skip message.

- [ ] **Step 6: Commit**

```bash
git add testing/golden/lib/preflight.sh testing/golden/lib/guest.sh
git commit -m "test(golden): preflight checks + guest ssh helper lib"
```

---

### Task 5: Provisioning library (helpers, `/etc/hosts`, trust CA)

**Files:**
- Create: `testing/golden/lib/provision.sh`

- [ ] **Step 1: Write `lib/provision.sh`**

`testing/golden/lib/provision.sh`:

```bash
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
```

- [ ] **Step 2: Syntax-check**

Run: `bash -n testing/golden/lib/provision.sh && echo SYNTAX_OK`
Expected: prints `SYNTAX_OK`

- [ ] **Step 3: Confirm functions load and the gateway-discovery command is well-formed**

Run:
```bash
( set -a; . testing/golden/golden.env; set +a
  . testing/golden/lib/guest.sh; . testing/golden/lib/provision.sh
  type provision_guest trust_test_ca set_hosts_entry >/dev/null && echo FUNCS_OK )
# The gateway discovery command must parse on this macOS host too:
route -n get default | awk '/gateway/{print $1, $2}'
```
Expected: prints `FUNCS_OK`, then a line like `gateway: 192.168.x.1` (proves the `route`/`awk` idiom is valid on macOS).

- [ ] **Step 4: Lint with shellcheck if available**

Run: `command -v shellcheck >/dev/null && shellcheck -x testing/golden/lib/provision.sh || echo "shellcheck not installed - skipped"`
Expected: no errors, or the skip message.

- [ ] **Step 5: Commit**

```bash
git add testing/golden/lib/provision.sh
git commit -m "test(golden): guest provisioning - helpers, CA trust, /etc/hosts seam"
```

---

### Task 6: Enrollment library (UAMDM + PSSO profile push)

**Files:**
- Create: `testing/golden/lib/enroll.sh`

- [ ] **Step 1: Write `lib/enroll.sh`**

`testing/golden/lib/enroll.sh`:

```bash
# Sourced by make-golden.sh. Enrolls the guest into the disposable nanomdm via UAMDM,
# then pushes the PSSO configuration profile as an MDM InstallProfile command.
#
# UAMDM cannot be fully headless: macOS requires a GUI approval click for user-approved
# MDM. We install the enrollment profile over SSH, then drive the approval via cliclick
# in the guest (Tart is booted with --vnc-experimental). The exact click coordinates are
# screen/OS-version dependent — see OPEN ITEM; verify_enrolled() below is the real gate.
# shellcheck shell=bash

nanomdm_up()   { ( cd nanomdm && cp -n .env.example .env 2>/dev/null; docker compose up -d ); }
nanomdm_down() { ( cd nanomdm && docker compose down -v ); }

# The APNs topic nanomdm serves under is the UID in the push cert subject.
push_topic() {
  openssl x509 -in nanomdm/secrets/push.pem -noout -subject \
    | tr ',/' '\n' | awk -F= '/UID/{print $2}' | tr -d ' '
}

# Build the manual-enrollment .mobileconfig: SCEP identity + MDM payload -> nanomdm.
generate_enrollment_profile() {
  local gw="$1" out="enroll.mobileconfig" topic; topic="$(push_topic)"
  cat > "$out" <<ENROLL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>PayloadType</key><string>Configuration</string>
  <key>PayloadVersion</key><integer>1</integer>
  <key>PayloadIdentifier</key><string>${EXT_BUNDLE_ID}.enroll</string>
  <key>PayloadUUID</key><string>$(uuidgen)</string>
  <key>PayloadDisplayName</key><string>Weblogin PSSO Test MDM Enrollment</string>
  <key>PayloadContent</key><array>
    <dict>
      <key>PayloadType</key><string>com.apple.security.scep</string>
      <key>PayloadVersion</key><integer>1</integer>
      <key>PayloadIdentifier</key><string>${EXT_BUNDLE_ID}.enroll.scep</string>
      <key>PayloadUUID</key><string>$(uuidgen)</string>
      <key>PayloadContent</key><dict>
        <key>URL</key><string>http://${gw}:8080/scep</string>
        <key>Challenge</key><string>testchallenge</string>
        <key>Key Usage</key><integer>5</integer>
        <key>Keysize</key><integer>2048</integer>
        <key>Subject</key><array><array><array><string>CN</string><string>Weblogin PSSO Test Device</string></array></array></array>
      </dict>
    </dict>
    <dict>
      <key>PayloadType</key><string>com.apple.mdm</string>
      <key>PayloadVersion</key><integer>1</integer>
      <key>PayloadIdentifier</key><string>${EXT_BUNDLE_ID}.enroll.mdm</string>
      <key>PayloadUUID</key><string>$(uuidgen)</string>
      <key>IdentityCertificateUUID</key><string>${EXT_BUNDLE_ID}.enroll.scep</string>
      <key>Topic</key><string>${topic}</string>
      <key>ServerURL</key><string>http://${gw}:9000/mdm</string>
      <key>CheckInURL</key><string>http://${gw}:9000/checkin</string>
      <key>AccessRights</key><integer>8191</integer>
    </dict>
  </array>
</dict></plist>
ENROLL
  echo "$out"
}

# Queue an InstallProfile command carrying the PSSO profile, then push so the guest checks in.
push_psso_profile() {
  local udid="$1" b64 cmd_uuid; cmd_uuid="$(uuidgen)"
  b64="$(base64 < psso-profile.mobileconfig | tr -d '\n')"
  cat > install-profile-command.plist <<CMD
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Command</key><dict>
    <key>RequestType</key><string>InstallProfile</string>
    <key>Payload</key><data>${b64}</data>
  </dict>
  <key>CommandUUID</key><string>${cmd_uuid}</string>
</dict></plist>
CMD
  curl -sf -u "nanomdm:${NANOMDM_API_KEY}" \
    "${NANOMDM_URL/9000/9000}/v1/enqueue/${udid}?push=1" \
    -T install-profile-command.plist >/dev/null
  echo "enqueued InstallProfile for ${udid}"
}

verify_enrolled() {
  guest_exec "profiles status -type enrollment" | tee /dev/stderr | grep -q "User Approved"
}

enroll_guest() {
  local gw; gw="$(guest_exec "route -n get default | awk '/gateway/{print \$2}'")"
  nanomdm_up
  local prof; prof="$(generate_enrollment_profile "$gw")"
  guest_push "$prof" "/tmp/${prof}"
  guest_exec "sudo profiles install -type configuration -path /tmp/${prof}"
  # GUI approval click (System Settings > Device Management > Approve). OPEN ITEM: coords.
  guest_exec "open 'x-apple.systempreferences:com.apple.preferences.configurationprofiles'"
  guest_exec "cliclick w:3000 c:640,480 || true"   # placeholder click; verify_enrolled is the gate
  verify_enrolled || { echo "UAMDM not user-approved — approve manually via VNC" >&2; return 1; }
  push_psso_profile "$(guest_udid)"
}
```

- [ ] **Step 2: Syntax-check**

Run: `bash -n testing/golden/lib/enroll.sh && echo SYNTAX_OK`
Expected: prints `SYNTAX_OK`

- [ ] **Step 3: Confirm the profile heredocs produce valid plists (no VM needed)**

Run:
```bash
( set -a; . testing/golden/golden.env; set +a
  cd testing/golden
  . lib/guest.sh; . lib/enroll.sh
  # Stub the cert-topic reader so we can exercise the generator offline:
  push_topic() { echo "com.apple.mgmt.External.testtopic"; }
  generate_enrollment_profile "10.0.0.1" >/dev/null
  plutil -lint enroll.mobileconfig )
```
Expected: last line ends `OK`. Then `rm -f testing/golden/enroll.mobileconfig`.

- [ ] **Step 4: Lint with shellcheck if available**

Run: `command -v shellcheck >/dev/null && shellcheck -x testing/golden/lib/enroll.sh || echo "shellcheck not installed - skipped"`
Expected: no errors, or the skip message.

- [ ] **Step 5: Commit**

```bash
git add testing/golden/lib/enroll.sh
git commit -m "test(golden): UAMDM enrollment + PSSO profile push via nanomdm"
```

---

### Task 7: `make-golden.sh` orchestrator (with `--dry-run`)

**Files:**
- Create: `testing/golden/make-golden.sh`

- [ ] **Step 1: Write the orchestrator**

`testing/golden/make-golden.sh`:

```bash
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
```

- [ ] **Step 2: Make executable and syntax-check**

Run: `chmod +x testing/golden/make-golden.sh && bash -n testing/golden/make-golden.sh && echo SYNTAX_OK`
Expected: prints `SYNTAX_OK`

- [ ] **Step 3: Dry-run prints the ordered plan without touching tart/docker**

Run: `cd testing/golden && ./make-golden.sh --dry-run`
Expected: prints the 10-step `Golden-image bake plan:` block, ending at `cleanup`, with `${GOLDEN_REMOTE}` expanded to `ghcr.io/sunstoneinstitute/weblogin-psso-test-vm:tahoe-26`. No VM is created.

- [ ] **Step 4: Lint with shellcheck if available**

Run: `command -v shellcheck >/dev/null && shellcheck -x testing/golden/make-golden.sh || echo "shellcheck not installed - skipped"`
Expected: no errors, or the skip message.

- [ ] **Step 5: Commit**

```bash
git add testing/golden/make-golden.sh
git commit -m "test(golden): make-golden.sh bake orchestrator with --dry-run"
```

---

### Task 8: `verify-golden.sh` post-bake smoke test

**Files:**
- Create: `testing/golden/verify-golden.sh`

This is the verification that matters: after the bake, a **fresh clone** of the golden image must boot already-enrolled, with the PSSO payload present, the test CA trusted, and the host mock reachable over NAT.

- [ ] **Step 1: Write the smoke test**

`testing/golden/verify-golden.sh`:

```bash
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
```

- [ ] **Step 2: Make executable and syntax-check**

Run: `chmod +x testing/golden/verify-golden.sh && bash -n testing/golden/verify-golden.sh && echo SYNTAX_OK`
Expected: prints `SYNTAX_OK`

- [ ] **Step 3: Confirm it loads and refuses cleanly without an image (offline gate)**

Run: `cd testing/golden && bash -n verify-golden.sh && ( . lib/guest.sh; type wait_for_ssh >/dev/null && echo READY )`
Expected: prints `READY`. (A full run — clone, boot, four PASS lines ending `ALL CHECKS PASSED` — requires a baked image and Plan 1's mock running; that is the maintainer's post-bake acceptance run, not a CI step here.)

- [ ] **Step 4: Lint with shellcheck if available**

Run: `command -v shellcheck >/dev/null && shellcheck -x testing/golden/verify-golden.sh || echo "shellcheck not installed - skipped"`
Expected: no errors, or the skip message.

- [ ] **Step 5: Commit**

```bash
git add testing/golden/verify-golden.sh
git commit -m "test(golden): verify-golden.sh post-bake smoke test on a fresh clone"
```

---

### Task 9: README

**Files:**
- Create: `testing/golden/README.md`

- [ ] **Step 1: Write the README**

`testing/golden/README.md`:

````markdown
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
````

- [ ] **Step 2: Verify the README renders and the dry-run still matches it**

Run: `cd testing/golden && ./make-golden.sh --dry-run | grep -q "tart push" && echo README_OK`
Expected: prints `README_OK`

- [ ] **Step 3: Commit**

```bash
git add testing/golden/README.md
git commit -m "docs(golden): README for the golden VM image pipeline"
```

---

## Self-Review

**Spec coverage (for the "VM lifecycle & golden image" / "Directory layout" slice of `2026-07-17-vm-based-psso-testing-design.md`):**
- `testing/golden/make-golden.sh` maintainer bake: pull base → boot → enroll (UAMDM) → install PSSO profile + trust CA + guest helpers → `/etc/hosts` → shut down → `tart push` — Tasks 1-7. ✅
- Disposable nanomdm `docker compose` (nanomdm + SCEP dep), bake-time only — Task 3. ✅
- PSSO `.mobileconfig` with the exact keys the extension reads (`ClientID`/`BaseURL`/`Issuer`/`Audience`) under `ai.sunstoneinstitute.psso-extension.ssoe`, `BaseURL` → `https://idp.test:8443`, Keycloak repoint documented — Task 2 + README. ✅
- Guest helpers: SSH pubkey into the test user, `cliclick`, Tart guest agent — Task 5. ✅
- Trust Plan 1's `testing/idp/certs/ca.crt`; `/etc/hosts` `idp.test` → host NAT gateway — Task 5. ✅
- One-time APNs push cert is a **gated maintainer step**, clearly marked, not per-test — Task 3 (and preflight in Task 4, README in Task 9). ✅
- SE-backed registration OUT of scope; `PlatformSSO` auth method is `Password`; golden just needs UAMDM-enrolled + profile present + managed state true — header, Task 2, verify Task 8. ✅
- ADE/DEP out; enrollment is UAMDM via manual profile install + scripted approval — Task 6. ✅
- Post-clone acceptance: fresh VM boots already-enrolled (`profiles status`/`profiles list`), CA trusted (system-trust `curl` with no `--cacert`), guest reaches host mock over NAT — Task 8. ✅
- Shareable OCI outcome; consumers `tart pull` — header, README. ✅
- Cross-refs to Plan 1's CA + running mock at `:8443` — header dependencies, preflight, Task 8. ✅

**Verification-shape check:** No fabricated unit tests. Shell/infra tasks verify via `bash -n`, `shellcheck`, `plutil -lint`, `docker compose config`, `--dry-run`, and function-load smokes; the real end-to-end gate (`verify-golden.sh`) uses `tart`/ssh assertions with concrete expected output. The heavy bake and the full `verify-golden.sh` run are explicitly flagged as maintainer acceptance runs (need an image + Plan 1's mock), not steps a fresh CI worker can execute cold.

**Placeholder scan:** Every code step contains complete, runnable content. `REPLACE_WITH_*` tokens in `golden.env` are intentional, documented configuration inputs (real Team ID / ClientID / Issuer / Audience) carried in the Open items list — not plan gaps. The cliclick approval coordinate is a placeholder *value* by nature (screen-dependent), with `verify_enrolled()` as the actual correctness gate and an open item tracking it.

**Type/name consistency:** `golden.env` variable names (`GOLDEN_LOCAL`, `GOLDEN_REMOTE`, `EXT_BUNDLE_ID`, `PSSO_BASE_URL`, `CA_CRT`, `IDP_HOST`, `NANOMDM_URL`, `NANOMDM_API_KEY`) are used identically across `preflight.sh`, `guest.sh`, `provision.sh`, `enroll.sh`, `make-golden.sh`, and `verify-golden.sh`. Function names (`preflight`, `wait_for_ssh`, `guest_exec`, `guest_push`, `guest_udid`, `provision_guest`, `enroll_guest`, `nanomdm_up`/`nanomdm_down`, `verify_enrolled`) are defined once and called consistently. `EXT_BUNDLE_ID` is the same string in the profile payload (Task 2), the managed-pref read (Task 8 `defaults read`), and the extension's CFPreferences domain confirmed in `Config/Local.xcconfig`.

## First real bake outcome (2026-07-18)

The first end-to-end bake ran on a real Tahoe guest and reached **user-approved MDM
enrollment**, fully verified hop by hop: SCEP identity issued, `Authenticate` +
Device/User `TokenUpdate` through the nginx mTLS proxy, a live **Apple APNs push**
`Acknowledged`, and both the PSSO and PPPC profiles installed via MDM (enrollment
survives reboot). Getting there fixed five defects (commit `a95c73e`):

1. MDM payload must declare `ServerCapabilities` = `com.apple.mdm.per-user-connections`
   (Tahoe rejects it otherwise).
2. `IdentityCertificateUUID` must equal the SCEP payload's **PayloadUUID** (not its
   PayloadIdentifier), or the MDM mTLS connection presents no client cert.
3. `CheckInURL` must be `/mdm` — nanomdm serves check-in and commands on one combined
   endpoint and has no `/checkin` route.
4. The TLS **server** leaf must be Apple-trust-compliant (`basicConstraints=CA:FALSE`,
   `serverAuth` EKU, ≤397-day life) or trustd fails with "Leaf has invalid basic
   constraints".
5. Vendor keys must also ship as a `com.apple.ManagedClient.preferences` payload for the
   bundle-id domain; keys inside the SSO payload are invisible to `CFPreferencesCopyAppValue`.

## Open items carried forward

- **Base macOS Tart image + version pin.** `golden.env` uses `ghcr.io/cirruslabs/macos-tahoe-base:latest`; pin to a specific digest/tag and set `MACOS_VER` accordingly before publishing a shared image (shared design open item: "base macOS Tart image source + version pinning").
- **Real `ClientID` / `Issuer` / `Audience` / Team ID.** `golden.env` ships `REPLACE_WITH_*`. Fill from the production PSSO configuration (aligns with Plan 1's `realm-export.json` note). `BaseURL` is already correct (`https://idp.test:8443`).
- **Managed-pref live read needs the extension present.** `generate-psso-profile.sh` now delivers the vendor keys as managed preferences and the file lands correctly in `/Library/Managed Preferences/` (both scopes). But `defaults read <bundle-id> BaseURL` does **not** resolve on the bare base VM (no signed PSSO extension installed), so `verify-golden.sh` check 3 can't pass there. Decide whether the golden should include the app, or move that check to run post-app-install.
- **UAMDM approval is a manual VNC step (by design on Tahoe).** `profiles install` is gone and synthetic clicks are TCC-gated headlessly, so `enroll.sh` stages the profile (`open`) and `wait_for_manual_approval` polls `profiles status` while the maintainer approves via the Tart VNC console. `cliclick` is instead pre-authorized (Accessibility) via an MDM-pushed PPPC profile for later Plan 3 use. Confirmed working; the earlier "scripted approval-click coordinate" idea is superseded.
- **nanomdm / SCEP CLI flags — confirmed.** nanomdm `0.6.0` with push cert uploaded via the `/v1/pushcert` API (not a flag), enqueue URL `.../v1/enqueue/<udid>?push=1`, single combined `/mdm` endpoint; SCEP built from `micromdm/scep` v2.3.0. All exercised by a real device this bake.
- **APNs push at bake time — confirmed.** The nanomdm `InstallProfile` push (gated push cert) reached the guest via real Apple APNs and was `Acknowledged`. The `profiles install` fallback is no longer needed and is unavailable on Tahoe anyway.
- **Host NAT gateway discovery — confirmed.** `route -n get default | awk '/gateway/{print $2}'` mapped `idp.test` → the reachable host gateway on Tahoe under Tart NAT.
