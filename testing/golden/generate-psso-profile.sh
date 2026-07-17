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
