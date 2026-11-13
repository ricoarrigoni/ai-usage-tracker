#!/bin/bash
# Builds a signed, notarized "dist/AI-Usage-Tracker.dmg" that other Macs can open
# without a security warning.
#
# One-time setup on the Mac that makes releases:
#   1. A "Developer ID Application" certificate in the keychain
#      (Xcode > Settings > Accounts > Manage Certificates > + > Developer ID Application).
#   2. Notarization credentials saved in the keychain under the profile name below:
#      xcrun notarytool store-credentials AI_USAGE_TRACKER_NOTARY \
#        --apple-id <your Apple ID> --team-id <your team ID> --password <app-specific password>
#      (create the app-specific password at https://account.apple.com > Sign-In and Security).
#
# Options: NOTARY_PROFILE (default AI_USAGE_TRACKER_NOTARY), SIGN_IDENTITY (default: the first
# Developer ID Application certificate), SKIP_NOTARIZE=1 to build a signed but un-notarized test copy.
set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE="${NOTARY_PROFILE:-AI_USAGE_TRACKER_NOTARY}"
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)}"
if [[ -z "$IDENTITY" ]]; then
  echo "No Developer ID Application certificate found. See the setup steps at the top of $0." >&2
  exit 1
fi
if [[ -z "${SKIP_NOTARIZE:-}" ]] && ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  echo "No notarization credentials saved as \"$PROFILE\". See the setup steps at the top of $0." >&2
  exit 1
fi

SIGN_IDENTITY="$IDENTITY" scripts/build-app.sh

# The name stays the same in every release, so .../releases/latest/download/AI-Usage-Tracker.dmg
# always downloads the newest version.
DMG="dist/AI-Usage-Tracker.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

cp -R "dist/AI Usage Tracker.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "AI Usage Tracker" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
codesign --force --sign "$IDENTITY" --timestamp "$DMG"

if [[ -n "${SKIP_NOTARIZE:-}" ]]; then
  echo "Built $DMG (signed, not notarized: other Macs will warn about it)"
  exit 0
fi

xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature --verbose "$DMG"
shasum -a 256 "$DMG"
echo "Built $DMG (signed and notarized)"
