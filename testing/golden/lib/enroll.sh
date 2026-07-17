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

# The APNs topic nanomdm serves under is the UID value in the push cert subject,
# e.g. subject=UID=com.apple.mgmt.External.<uuid>, CN=APSP:<uuid>, C=NO
push_topic() {
  openssl x509 -in nanomdm/secrets/push.pem -noout -subject \
    | sed -n 's/.*UID=\([^,/]*\).*/\1/p'
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
  guest_exec "profiles status -type enrollment" 2>/dev/null | grep -q "User Approved"
}

# Tahoe removed CLI profile installs and gates synthetic clicks (cliclick) behind
# Accessibility TCC, which nothing can grant on a headless SSH bake. So the maintainer
# approves the staged profile once via the VNC console; this polls until it lands.
wait_for_manual_approval() {
  local deadline=$((SECONDS + MDM_APPROVE_TIMEOUT)) vnc
  vnc="$(grep -Eo 'vnc://[^[:space:]]+' /tmp/tart-golden.log 2>/dev/null | tail -1)"
  cat >&2 <<MSG

=== MANUAL STEP: approve MDM enrollment on the guest ===
Connect a VNC viewer to the running guest:
  ${vnc:-<VNC URL not found; check /tmp/tart-golden.log>}
Then: System Settings > General > Device Management > double-click
  "Weblogin PSSO Test MDM Enrollment" > Install > Install > password: ${GUEST_PASS}
Waiting up to $((MDM_APPROVE_TIMEOUT / 60)) min for user-approved enrollment...
MSG
  while (( SECONDS < deadline )); do
    verify_enrolled && { echo "MDM enrollment user-approved" >&2; return 0; }
    sleep 5
  done
  echo "timed out waiting for manual MDM approval" >&2; return 1
}

enroll_guest() {
  local gw; gw="$(guest_exec "route -n get default | awk '/gateway/{print \$2}'")"
  nanomdm_up
  local prof; prof="$(generate_enrollment_profile "$gw")"
  guest_push "$prof" "/tmp/${prof}"
  # Stage the profile (Tahoe `profiles install` is gone); it then appears under
  # System Settings > General > Device Management awaiting the manual approval below.
  guest_exec "open /tmp/${prof}"
  guest_exec "open 'x-apple.systempreferences:com.apple.preferences.configurationprofiles'"
  wait_for_manual_approval || return 1
  push_psso_profile "$(guest_udid)"
}
