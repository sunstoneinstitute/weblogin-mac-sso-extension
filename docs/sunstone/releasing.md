# Releasing Weblogin SSO (Sunstone)

Releases are built by `.github/workflows/release.yml` on a `v*` tag: archive →
Developer ID sign → notarize → staple → signed .pkg → GitHub Release. Fleet
installs the pkg from the release URL via the fleet-config repo (GitOps).

Release = push a **signed** tag: an annotated tag signed by an authorized
release YubiKey (`git tag -s`). `release.yml` verifies the signature against
`.github/allowed_signers` and pauses for reviewer approval before the signing
secrets unlock. Nothing reaches the fleet until fleet-config bumps the package
URL + sha256.

```bash
git tag -s v1.5.2-sunstone.1 -m v1.5.2-sunstone.1 && git push origin v1.5.2-sunstone.1
```

## Release authorization

Three independent controls gate a release; each stops a different failure:

- **Signed tag** — CI (`verify-tag` in `release.yml`) requires the tag be signed
  by a key in `.github/allowed_signers`. Holds even if a GitHub account is
  compromised (the attacker lacks the physical YubiKey).
- **Required reviewer** — the `release` environment needs manual approval before
  signing secrets unlock. Stops unauthorized triggers.
- **`v*` tag ruleset** — only org owners can create or move `v*` tags. Stops
  leaked tokens and tag re-pointing.

Recovery: if a release YubiKey is lost, remove its line from
`.github/allowed_signers` (reviewed PR) and enroll a replacement. Keep at least
two YubiKeys enrolled so a lost key never blocks releases in the meantime.

## One-time setup

### 1. Mint the two Developer ID certificates

Both are created in the Apple Developer portal by the **Account Holder** and
are long-lived (5 years). Do this on a Mac you trust — the private keys are
born in its keychain.

1. Keychain Access → Certificate Assistant → **Request a Certificate From a
   Certificate Authority…** Fill in the account email, select **Saved to
   disk**. Repeat to produce two CSRs (each request mints a fresh key pair):
   `devid-app.certSigningRequest` and `devid-installer.certSigningRequest`.
2. [developer.apple.com → Certificates](https://developer.apple.com/account/resources/certificates/add):
   - **Developer ID Application** (G2 Sub-CA) → upload `devid-app.certSigningRequest` → download, double-click to install.
   - **Developer ID Installer** → upload `devid-installer.certSigningRequest` → download, double-click to install.
3. Verify both resolve to identities:
   ```bash
   security find-identity -v -p codesigning | grep 'Developer ID Application'
   security find-identity -v -p basic | grep 'Developer ID Installer'
   ```
4. Export for CI: in Keychain Access (My Certificates), select **both**
   certificates (their private keys come along), right-click → Export →
   `devid-certs.p12` with a strong password. Then:
   ```bash
   base64 -i devid-certs.p12 | pbcopy   # → secret DEVID_CERTS_P12
   ```

Notes:
- Developer ID Application certs are capped at 5 per account and are not
  revocable through the portal — treat the .p12 like a production secret.
- Keep the keychain copies; the .p12 is for CI only.

### 2. Create the provisioning profiles (after the certs exist)

Portal order matters: **certificates → App Group → App IDs → profiles.**

1. Identifiers → App Groups → register `group.ai.sunstoneinstitute.psso`.
2. Identifiers → App IDs → register both App IDs with the capabilities below
   checked (must match the `.entitlements` files exactly, or the archive step
   fails with "Provisioning profile doesn't include the ... capability"):
   - `ai.sunstoneinstitute.psso-extension` (main app — see `Weblogin SSO/Weblogin_SSO.entitlements`):
     * **Associated Domains**
     * **App Groups**
     * **AutoFill Credential Provider**
     * **Network Extensions**
   - `ai.sunstoneinstitute.psso-extension.ssoe` (extension — see `ssoe/ssoe.entitlements`):
     * **Associated Domains**
     * **App Groups**
     * **AutoFill Credential Provider**
     * **Network Extensions**
     *  **App Attest**

   Checking **App Groups** does *not* prompt you to pick a group inline — save
   the App ID first, then:
   - **Re-open its Edit page**
   - Click **Configure** (or **Edit**) next to App Groups
   - Click **+**
   - select your `*.psso` from the list of existing groups (created in step 1)
   - **Continue → Done → Save**
   Do this for both App IDs; the group association is otherwise silently
   left empty and the resulting profile fails with "doesn't support the group...psso App Group".
3. Profiles → new **Developer ID** profile per App ID, selecting the Developer
   ID Application certificate. Name them exactly as `Config/Local.xcconfig`
   expects: `Sunstone PSSO App (Developer ID)` and
   `Sunstone PSSO Extension (Developer ID)`.
4. Download both and base64 them into the
   `APP_PROVISIONING_PROFILE_B64` / `SSOE_PROVISIONING_PROFILE_B64` secrets.

 These profiles are embedded in the shipped app and checked by Gatekeeper at
**every launch** (Associated Domains is a managed capability). Profile expiry
bricks the installed app — put the renewal date in the ops calendar the day
you create them.

 If you add or change a capability in the `.entitlements` files later, the
App ID's capabilities (and profile) must be updated to match — regenerate the
profile (Profiles → edit → Save re-signs it with current capabilities) and
re-upload the `_PROVISIONING_PROFILE_B64` secret. A stale profile fails the
same way as never having enabled the capability at all.

### 3. Notarization API key

[App Store Connect → Users and Access → Integrations → App Store Connect API](https://appstoreconnect.apple.com/access/integrations/api):
generate a **Team Key** with the **Developer** role. Record the Issuer ID
(`NOTARY_ISSUER_ID`), Key ID (`NOTARY_KEY_ID`), and the downloaded `.p8`
contents (`NOTARY_KEY`). The .p8 can only be downloaded once.

### 4. GitHub secrets

These go in the `release` **environment**, not plain repository secrets —
repository secrets are visible to every PR build, environment secrets are
only available to jobs that declare `environment: release` (see
`.github/workflows/release.yml`).

The environment is further locked to tag refs matching `v*` via a deployment
branch policy, so even a `workflow_dispatch` run off `main` can't read these
secrets:

```bash
gh api -X PUT repos/<owner>/<repo>/environments/release \
  -F 'deployment_branch_policy[protected_branches]=false' \
  -F 'deployment_branch_policy[custom_branch_policies]=true'
gh api -X POST repos/<owner>/<repo>/environments/release/deployment-branch-policies \
  -f name='v*' -f type='tag'

gh secret set DEVID_CERTS_P12 --env release < <(base64 -i devid-certs.p12)
gh secret set DEVID_CERTS_PASSWORD --env release
gh secret set APP_PROVISIONING_PROFILE_B64 --env release < <(base64 -i app.provisionprofile)
gh secret set SSOE_PROVISIONING_PROFILE_B64 --env release < <(base64 -i ssoe.provisionprofile)
gh secret set NOTARY_ISSUER_ID --env release
gh secret set NOTARY_KEY_ID --env release
gh secret set NOTARY_KEY --env release < AuthKey_XXXXXXXXXX.p8
```

### 5. Release-signing YubiKey

The tag signature comes from a FIDO2 key resident on a YubiKey — the private key
never leaves the device and each signature needs a touch. Enroll one per key
(`sunstone1`, `sunstone2`, …):

```bash
# macOS: Apple's /usr/bin/ssh-keygen can't drive FIDO keys — use Homebrew openssh.
brew install openssh
/opt/homebrew/bin/ssh-keygen -t ed25519-sk -O resident \
  -O application=ssh:sunstone-release -f ~/.ssh/id_ed25519_sk_sunstoneN

git config --local gpg.format ssh
git config --local gpg.ssh.program /opt/homebrew/bin/ssh-keygen
git config --local user.signingkey ~/.ssh/id_ed25519_sk_sunstoneN
git config --local tag.gpgsign true
git config --local commit.gpgsign false      # only tags are signed, not commits
```

Then add the public key as a line in `.github/allowed_signers`
(`* namespaces="git" <type> <base64>`) and upload it to GitHub as a **Signing
Key**. Enroll a second YubiKey the same way for backup.

## Shipping to the fleet

After the release workflow finishes, bump the pkg URL and `hash_sha256` in
fleet-config (`fleets/workstations.yml`, `software` section) — the release
notes contain the hash. Merge = fleet rollout.
