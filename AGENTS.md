# Weblogin macOS PSSO extension — agent instructions

A macOS Platform SSO (PSSO) app + Safari/authorization extension for Weblogin. UiO is
upstream; the `sunstone` branch is Sunstone Institute's deployment fork. Builds are driven
by Xcode with deployment values factored into `Config/*.xcconfig`. `testing/` holds the
VM-based test rig (mock IdP + golden Tart image); see `docs/testing.md` and
`testing/golden/README.md`.

## Never commit Developer ID, certificates, or secrets

**Hard rule — do not violate.** Any step that consumes signing material, a private key, or
a certificate MUST read it from a **gitignored path** (or the macOS keychain) and ship a
**committed template or generator** documenting what's needed — never a tracked copy of the
real material. This keeps every deployer supplying their own.

Two distinct cases, handled differently:

1. **Deployer-specific signing *configuration*** (Apple Team ID, signing identity,
   provisioning-profile names, bundle id, SSO host) → override via `Config/Local.xcconfig`,
   with `Config/Local.xcconfig.example` as the committed template and
   `Config/Deployment.xcconfig` holding the tracked defaults. The `.pbxproj` and
   `.entitlements` reference these as `$(VAR)` — never hardcode a Team ID or profile name
   into a tracked project file.
2. **Actual secret material** (Developer ID cert / `.p12` / private key, APNs push cert
   `push.pem`+`push.key`, test CA private key) → gitignored, provided out-of-band or
   generated locally. Commit a `.example` / `.gitkeep` / generator script, never the file.

Canonical patterns already in the repo — copy one when you add a new secret-consuming step:

| Material | Gitignored real path | Committed template / generator |
|---|---|---|
| Xcode signing config | `Config/Local.xcconfig` | `Config/Local.xcconfig.example` (+ `Config/Deployment.xcconfig` defaults) |
| APNs push cert + MDM env | `testing/golden/nanomdm/secrets/`, `testing/golden/nanomdm/.env` | `nanomdm/.env.example` (secrets dir created at bake time) |
| Test root CA + keys | `testing/idp/certs/` | `testing/idp/gen-test-ca.sh` |

When you add a step that needs a cert or secret:
- add the real path to the nearest `.gitignore` **before** creating the file;
- commit a `.example`, generator, or `.gitkeep` that documents the expected file(s);
- make the script read the path from config/env so each deployer supplies their own;
- never echo secret contents to logs or command output.

Exception, by design: on the `sunstone` fork `Config/Local.xcconfig` is intentionally
force-added (tracked) so fork CI is reproducible. It carries only non-secret *config*
(Team ID, identity name, profile names) — never key material. Upstream keeps it gitignored;
`git rebase upstream/main` therefore never conflicts on it.
