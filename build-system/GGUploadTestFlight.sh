#!/bin/bash
# Upload a Ghostgram IPA to TestFlight (App Store Connect).
#
#   build-system/GGUploadTestFlight.sh [path/to/Ghostgram.ipa]
#
# Default IPA: build-output/ipa/Ghostgram.ipa (what GGBuildRelease.sh produces).
# Key:  build-system/ghostgram-appstoreconnect.json (gitignored) — {"keyId": "...", "issuerId": "..."};
#       the private key itself is ~/.appstoreconnect/private_keys/AuthKey_<keyId>.p8, where altool
#       looks for it. Never print the issuer or the key.
# Docs: GGREMAKE/TESTFLIGHT.md.

set -uo pipefail
cd "$(dirname "$0")/.."

IPA="${1:-build-output/ipa/Ghostgram.ipa}"
CONFIG="build-system/ghostgram-appstoreconnect.json"

[ -f "$IPA" ] || { echo "ERROR: $IPA is missing. Build it first: build-system/GGBuildRelease.sh <buildNumber>" >&2; exit 1; }
[ -f "$CONFIG" ] || { echo "ERROR: $CONFIG is missing (see GGREMAKE/TESTFLIGHT.md, «Ключ»)." >&2; exit 1; }

KEY_ID="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["keyId"])' "$CONFIG")" || exit 1
ISSUER_ID="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["issuerId"])' "$CONFIG")" || exit 1
[ -f "$HOME/.appstoreconnect/private_keys/AuthKey_$KEY_ID.p8" ] || { echo "ERROR: ~/.appstoreconnect/private_keys/AuthKey_$KEY_ID.p8 is missing." >&2; exit 1; }

# What is about to go up: bundle id, version and build number, read from the IPA itself.
INFO="$(mktemp -d)"
trap 'rm -rf "$INFO"' EXIT
unzip -q -o "$IPA" 'Payload/*.app/Info.plist' -d "$INFO" || { echo "ERROR: $IPA is not an IPA." >&2; exit 1; }
PLIST="$(ls "$INFO"/Payload/*.app/Info.plist | head -1)"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
echo "ipa        : $IPA"
echo "app        : $BUNDLE_ID $VERSION ($BUILD)"
echo "key        : $KEY_ID"
echo
[ "$BUNDLE_ID" = "org.ghostgram.app" ] || { echo "ERROR: unexpected bundle id $BUNDLE_ID." >&2; exit 1; }

xcrun altool --upload-app -f "$IPA" -t ios --apiKey "$KEY_ID" --apiIssuer "$ISSUER_ID" 2>&1 | grep -v '^$'
status=${PIPESTATUS[0]}
echo
if [ "$status" = "0" ]; then
    echo "UPLOAD OK: $VERSION ($BUILD). TestFlight shows it after Apple's processing (usually 10–30 min)."
else
    echo "UPLOAD FAILED (exit $status). 401 = wrong key id / issuer; «bundle version must be higher» = raise the build number."
fi
exit "$status"
