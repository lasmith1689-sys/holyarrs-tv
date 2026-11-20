#!/bin/bash
# Builds HolyArrs TV (tvOS) and, with App Store Connect credentials, uploads it to TestFlight for internal testing,
# the same way RTX 4K ship: archive on GitHub's Mac runner, then Xcode signs it for distribution
# during export with a cloud-managed certificate, using the App Store Connect API key. No certificates or
# provisioning profiles.
#
# Environment:
#   BUILD_NUMBER                  required (must grow with every upload)
#   HOLYARRS_BUNDLE_ID               the App Store Connect app's bundle ID
#   APPLE_TEAM_ID, ASC_KEY_ID,    optional; without all four the script stops after an unsigned
#   ASC_ISSUER_ID, ASC_KEY_P8     compile-check build. ASC_KEY_P8 is the text of the AuthKey_XXXX.p8 file.
set -euo pipefail

OUT="${RUNNER_TEMP:-/tmp}/testflight"
rm -rf "$OUT"
mkdir -p "$OUT"

export APP_BUNDLE_ID="$HOLYARRS_BUNDLE_ID"
export DEVELOPMENT_TEAM="${APPLE_TEAM_ID:-}"
xcodegen generate

if [ -z "${APPLE_TEAM_ID:-}" ] || [ -z "${ASC_KEY_ID:-}" ] || [ -z "${ASC_ISSUER_ID:-}" ] || [ -z "${ASC_KEY_P8:-}" ]; then
  echo "▶ Compile check only (no App Store Connect secrets): unsigned build for tvOS"
  set -o pipefail
  for pair in "HolyArrsTV:tvOS" "HolyArrsPhone:iOS"; do
    scheme=${pair%%:*}; plat=${pair##*:}
    xcodebuild build -project HolyArrsTV.xcodeproj -scheme "$scheme" -configuration Release \
      -destination "generic/platform=$plat" CODE_SIGNING_ALLOWED=NO CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
      > "$OUT/build.log" 2>&1 || { grep -E "error:|warning: .*deprecated" "$OUT/build.log" | head -n 40; tail -n 40 "$OUT/build.log"; echo "::error::$scheme did not compile."; exit 1; }
  done
  tail -n 5 "$OUT/build.log"
  echo "::notice::HolyArrs TV compiles. Nothing was uploaded: add the App Store Connect secrets to send builds to TestFlight."
  exit 0
fi

key="$OUT/AuthKey_$ASC_KEY_ID.p8"
# Accept the .p8 text however it was pasted: Windows line endings, or without the BEGIN/END lines.
p8=$(printf '%s' "$ASC_KEY_P8" | tr -d '\r')
if [[ "$p8" != *"BEGIN PRIVATE KEY"* ]]; then
  p8=$(printf -- '-----BEGIN PRIVATE KEY-----\n%s\n-----END PRIVATE KEY-----' "$(printf '%s' "$p8" | tr -d ' \n' | fold -w 64)")
fi
(umask 077 && printf '%s\n' "$p8" > "$key")
unset p8
trap 'rm -f "$key"' EXIT
auth=(-allowProvisioningUpdates -authenticationKeyPath "$key" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")

cat > "$OUT/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>app-store-connect</string>
	<key>destination</key>
	<string>upload</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>teamID</key>
	<string>$APPLE_TEAM_ID</string>
	<key>testFlightInternalTestingOnly</key>
	<true/>
	<key>uploadSymbols</key>
	<false/>
	<key>manageAppVersionAndBuildNumber</key>
	<false/>
</dict>
</plist>
EOF


ship() {
  local scheme=$1 plat=$2
  local archive="$OUT/$scheme.xcarchive"
  # Archive unsigned (like GoldenPad): a signed archive needs a development profile, which needs a registered
  # device. The export step below signs with the cloud-managed distribution certificate instead.
  echo "▶ Archiving $scheme ($plat) $HOLYARRS_BUNDLE_ID ($BUILD_NUMBER)"
  if ! xcodebuild archive -project HolyArrsTV.xcodeproj -scheme "$scheme" -configuration Release \
      -destination "generic/platform=$plat" -archivePath "$archive" \
      DEVELOPMENT_TEAM="$APPLE_TEAM_ID" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
      CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
      > "$OUT/archive-$scheme.log" 2>&1; then
    grep -E "error:" "$OUT/archive-$scheme.log" | head -n 40 || true
    tail -n 60 "$OUT/archive-$scheme.log"
    echo "::error::Archive failed. See the log above."
    exit 1
  fi
  tail -n 5 "$OUT/archive-$scheme.log"

  echo "▶ Signing and uploading $scheme to App Store Connect"
  if ! xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist "$OUT/ExportOptions.plist" \
      -exportPath "$OUT/export-$scheme" "${auth[@]}" > "$OUT/export-$scheme.log" 2>&1; then
    tail -n 60 "$OUT/export-$scheme.log"
    log=$(cat "$OUT/export-$scheme.log")
    hint="See the log above."
    case "$log" in
      *"No suitable application records"*|*"Cannot determine the Apple ID from Bundle ID"*)
        hint="The App Store Connect app record for $HOLYARRS_BUNDLE_ID was not found. Create it (platform tvOS) with exactly that bundle ID." ;;
      *"NOT_AUTHORIZED"*|*"not authorized"*|*"credentials are missing or invalid"*|*"loud signing permission"*|*"does not have permission"*|*"invalid key"*|*"Invalid key"*)
        hint="Check the API key: it needs the Admin role, and ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_P8 must all come from that key." ;;
      *"bundle version must be higher"*)
        hint="That build number was already used. Run the workflow again to get a new one." ;;
    esac
    echo "::error::Upload to TestFlight failed. $hint"
    exit 1
  fi
  grep -iE "upload|success|export" "$OUT/export-$scheme.log" | tail -n 5 || true
  echo "::notice::Uploaded $scheme ($plat) build $BUILD_NUMBER. It shows up in TestFlight on the Apple TV once Apple finishes processing it, usually within 5-30 minutes."
}

ship HolyArrsTV tvOS
ship HolyArrsPhone iOS
