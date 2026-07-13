# Releasing Weblogin SSO (Sunstone)

Releases are built by `.github/workflows/release.yml` on a `v*` tag: archive →
Developer ID sign → notarize → staple → signed .pkg → GitHub Release. Fleet
installs the pkg from the release URL via the fleet-config repo (GitOps).

Release = push a tag. Nothing reaches the fleet until fleet-config bumps the
package URL + sha256.

```bash
git tag v1.5.2-sunstone.1 && git push origin v1.5.2-sunstone.1
```

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
2. Identifiers → App IDs → register `ai.sunstoneinstitute.psso-extension` and
   `ai.sunstoneinstitute.psso-extension.ssoe`, each with **Associated
   Domains** and **App Groups** (assign the group) enabled.
3. Profiles → new **Developer ID** profile per App ID, selecting the Developer
   ID Application certificate. Name them exactly as `Config/Local.xcconfig`
   expects: `Sunstone PSSO App (Developer ID)` and
   `Sunstone PSSO Extension (Developer ID)`.
4. Download both and base64 them into the
   `APP_PROVISIONING_PROFILE_B64` / `SSOE_PROVISIONING_PROFILE_B64` secrets.

⚠️ These profiles are embedded in the shipped app and checked by Gatekeeper at
**every launch** (Associated Domains is a managed capability). Profile expiry
bricks the installed app — put the renewal date in the ops calendar the day
you create them.

### 3. Notarization API key

[App Store Connect → Users and Access → Integrations → App Store Connect API](https://appstoreconnect.apple.com/access/integrations/api):
generate a **Team Key** with the **Developer** role. Record the Issuer ID
(`NOTARY_ISSUER_ID`), Key ID (`NOTARY_KEY_ID`), and the downloaded `.p8`
contents (`NOTARY_KEY`). The .p8 can only be downloaded once.

### 4. GitHub secrets

```bash
gh secret set DEVID_CERTS_P12 < <(base64 -i devid-certs.p12)
gh secret set DEVID_CERTS_PASSWORD
gh secret set APP_PROVISIONING_PROFILE_B64 < <(base64 -i app.provisionprofile)
gh secret set SSOE_PROVISIONING_PROFILE_B64 < <(base64 -i ssoe.provisionprofile)
gh secret set NOTARY_ISSUER_ID
gh secret set NOTARY_KEY_ID
gh secret set NOTARY_KEY < AuthKey_XXXXXXXXXX.p8
```

## Shipping to the fleet

After the release workflow finishes, bump the pkg URL and `hash_sha256` in
fleet-config (`fleets/workstations.yml`, `software` section) — the release
notes contain the hash. Merge = fleet rollout.
