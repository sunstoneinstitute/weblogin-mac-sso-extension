# VM-based PSSO testing infrastructure — design

**Date:** 2026-07-17
**Status:** Approved (design); ready for implementation planning
**Scope:** A local-first, snapshot-based testing rig for the Weblogin macOS Platform SSO (PSSO) extension, running against MDM-enrolled macOS VMs, able to provoke fault/error scenarios that are hard or destructive to reproduce on physical Macs.

## Goal

Test the extension end-to-end against a controllable IdP inside disposable, MDM-enrolled macOS VMs — install a freshly built `.pkg`, drive the login/registration UI, inject faults, and assert on guest state, IdP-received requests, extension logs, and UI. One command per pkg. Structured to graduate to CI later.

## Constraints & hard limits (why the design looks like this)

- **No functional Secure Enclave in Virtualization.framework macOS guests.** The guest SEP is a stub. Platform SSO provisions hardware-bound (SE-backed) keys during device/user registration, so **real end-to-end SE-backed registration cannot complete in a VM** — this is a VZ limitation, not a tooling one, and applies to Tart and raw VZ alike.
- **ADE/DEP enrollment fails in VMs** (no real serial, no SEP attestation). Enrollment uses **user-approved MDM (UAMDM)** via profile install, which does work.
- Consequence: VMs cover extension loading/invocation, config-profile ingestion, login/registration **UI flows**, mock-IdP request/response handling, non-SE code paths, token plumbing, and error handling. True SE-backed E2E stays on physical hardware (manual, later).

## Foundational decisions (settled during brainstorming)

| Decision | Choice | Rationale |
|---|---|---|
| Virtualization stack | **Tart** on Apple Silicon | Free framebuffer VNC (`--vnc-experimental`) for driving the login sheet; CoW clone-from-golden snapshots; OCI image sharing. All without building VZ plumbing ourselves. |
| Snapshot model | **Clone-per-test from a golden image** | `tart clone` is near-instant CoW; gives a clean enrolled machine each run without re-enrolling. Live in-VM memory rollback (raw VZ `saveMachineStateTo`) deemed unnecessary. |
| MDM / profile delivery | **Disposable nanomdm**, used only at golden-image bake time | Enroll the golden VM once (UAMDM), install the PSSO profile, snapshot. Not a live dependency of test runs. |
| Image distribution | **Publish golden image to GHCR**, shared by UiO + Sunstone staff | Tart images are OCI artifacts; consumers `tart pull`. |
| Test IdP | **Both**: scriptable mock IdP (fault injection, primary) + dockerized real Keycloak + psso-extension (happy-path fidelity) | Mock provokes bugs deterministically; Keycloak validates the happy path matches production. |
| Run target | **Local-first, CI-ready structure** | Runs on a dev Mac now; a self-hosted arm64 GitHub runner can invoke the same harness later. No CI plumbing built yet. |
| Harness language | **Python + pytest** | Fixtures, parametrized scenarios, JUnit XML + HTML reporting for free; `vncdotool` is Python-native. Chosen over a bash/Swift harness. |
| Coverage | **Attempt in-VM `llvm-cov` line coverage (spike); fall back to scenario matrix + existing `ssoeTests` XCTest** | System-extension `.profraw` collection may be too fragile; the scenario matrix is the guaranteed, meaningful coverage measure. |

## Architecture

```
Host (Apple Silicon Mac)
├─ Tart              golden image → clone-per-test → delete
├─ docker compose
│   ├─ mock-idp      scriptable fake IdP + fault-injection control API   (0.0.0.0:8443)
│   ├─ keycloak      real Keycloak + psso-extension, seeded realm        (0.0.0.0:8444)
│   └─ nanomdm       disposable MDM — only runs during golden-image bake
└─ pytest harness    clones VM, installs pkg, drives UI, asserts, reports

Guest VM (macOS, UAMDM-enrolled, PSSO profile installed, test CA trusted)
   /etc/hosts:  idp.test → host gateway IP     reaches mock/keycloak over NAT
   driven via:  SSH (scriptable steps) + VNC/vncdotool (login sheet)
```

Two seams make it work: the guest **trusts a test root CA** (so mock/Keycloak TLS validates) and **`/etc/hosts`** redirects the IdP hostname to the host's NAT gateway. No production infrastructure is touched.

### Networking specifics
- Tart **NAT** mode. Host services bind `0.0.0.0` (not `127.0.0.1`). From the guest, the host is the NAT default gateway; the guest reaches `https://idp.test:8443` via the `/etc/hosts` mapping to that gateway IP.
- The test root CA is deliberately low-value (test-only, disposable), so shipping it inside the shared golden image is acceptable. It must never be trusted outside the test VM.

## Components

### 1. VM lifecycle & golden image (`testing/golden/`)
- **`make-golden.sh`** (maintainer, occasional): pull base macOS Tart image → boot → enroll into nanomdm (UAMDM) → install PSSO config profile + test CA + guest helpers (SSH key, `cliclick`, Tart guest agent) → set `/etc/hosts` → shut down → `tart push ghcr.io/<org>/weblogin-psso-test-vm:<macos-ver>`. The APNs-cert-gated step lives only here.
- **Per test run:** `tart clone <golden> run-<id>` → boot → run → `tart delete`. CoW clone = clean enrolled machine in seconds.
- nanomdm is a live dependency **only** for scenarios that exercise profile change/re-push; otherwise the snapshotted profile + managed state suffice.

### 2. Test IdPs (`testing/idp/`)
- **mock-idp** — small Python/Starlette (or FastAPI) app serving the OAuth/nonce/token endpoints the extension calls, plus a **control API**:
  - `POST /control/fault {type: "bad_nonce" | "token_500" | "timeout" | "expired_id_token" | ...}` — arm a fault for the next relevant request.
  - `GET /control/requests` — read back what the extension actually sent (for assertions).
  - `POST /control/reset` — clear faults/state between tests.
- **keycloak** — official image + psso-extension, seeded realm/users/clients via an import file. Used for happy-path and reauthentication (Password method) fidelity.
- Selected per test via a fixture; default is mock.

### 3. Harness (`testing/harness/`) — Python + pytest
Layered so each unit is independently understandable and testable:
- **`vm` fixture** — clone/boot/teardown; exposes guest IP.
- **`guest` driver** — SSH: install pkg (`installer -pkg`), query state (`app-sso platform -s`, `profiles list`), pull extension logs (`log show --predicate 'subsystem == "<ext subsystem>"'`), inspect keychain / app-group state.
- **`ui` driver** — `vncdotool` against Tart's `--vnc-experimental` framebuffer: screenshot, click (coordinate + image match), type. Required for the login/registration sheet, which runs in `loginwindow` where AppleScript UI scripting is restricted.
- **`idp` fixture** — start clean, inject faults, assert received requests; chooses mock vs Keycloak.
- **Assertions** span guest state, IdP-received requests, extension log lines, and UI screenshots.
- Each test function is one **scenario**.

### 4. Entry point — `testing/test-pkg.sh <pkg>`
Brings up the IdP stack → clones the VM → installs the pkg → triggers extension activation → runs the pytest suite → collects report + per-scenario artifacts → tears down. This is the developer-facing command.

### 5. Reporting
- pytest-html summary + JUnit XML (CI-ready).
- Per-run artifacts directory: screenshots, extension-log extracts, mock-idp request log — so a failure is diagnosable without re-running.
- Scenario matrix rendered as a table (pass/fail/skip per scenario).

### 6. Coverage
- **Spike:** build the extension with LLVM coverage instrumentation, run in-VM, pull `.profraw`, produce `llvm-cov` line coverage.
- **Fallback (guaranteed):** the scenario matrix as the primary coverage measure, plus the existing `ssoeTests` XCTest line coverage for pure helpers (`Helpers.swift`, `RegistrationState.swift`).

## Seed scenarios (the hard/destructive ones)

Grounded in the real code; each row tracks pass/fail/skip per run:

- Happy-path registration & login (Keycloak).
- Invalid / expired / malformed `id_token`; wrong `nonce`.
- Token endpoint HTTP 500 / timeout / connection drop mid-registration.
- **Registration save failure → assert no double completion** — permanent regression for commit `89c5a0a` ("return after registration save failure to avoid double completion").
- Profile removed, then re-pushed (needs nanomdm live).
- Reauthentication required, Password method (Keycloak-driven).
- Concurrent / duplicate auth requests.
- Corrupt app-group state / leftover `RegistrationState`.

## Directory layout

```
testing/
├─ golden/        make-golden.sh, nanomdm compose, profiles, test-CA
├─ idp/           mock-idp/ (+control API), keycloak/ (compose, realm seed)
├─ harness/       pytest: conftest fixtures, drivers/{guest,ui,idp}.py, scenarios/
├─ test-pkg.sh    one-command entrypoint
└─ README.md
```

## Out of scope (explicit)

- SE-backed registration end-to-end (no functional guest SEP) — manual physical-Mac testing, later.
- ADE/DEP enrollment.
- Real APNs in the per-test loop (only nanomdm at golden-bake time).
- CI plumbing itself (self-hosted arm64 runner integration) — the harness is structured for it, but building it is a later effort.

## Open items to resolve during implementation

- **Coverage spike outcome:** confirm whether `.profraw` can be collected from the sandboxed system extension; if not, drop cleanly to the scenario matrix + XCTest.
- **PSSO subsystem/category** for the `log show` predicate — confirm the exact values the extension logs under.
- **Base macOS Tart image source + version pinning** for the golden image.
- **Exact IdP hostname(s)** the extension is configured to call, to drive the `/etc/hosts` and test-CA SAN.
