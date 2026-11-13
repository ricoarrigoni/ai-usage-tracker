#!/bin/bash
# Builds "dist/AI Usage Tracker.app" for Apple silicon and Intel Macs.
#
# Signing:
#   - SIGN_IDENTITY set: signs with that certificate. A "Developer ID Application" certificate also
#     gets the hardened runtime and a secure timestamp, which notarization needs (see make-dmg.sh).
#   - Otherwise: uses an Apple Development certificate when there is one, because a stable signature
#     lets macOS keep the app's permissions across rebuilds, or an ad hoc signature for this Mac only.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product AIUsageTracker --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/AIUsageTracker"

APP="dist/AI Usage Tracker.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/AIUsageTracker"
cp packaging/Info.plist "$APP/Contents/Info.plist"
cp packaging/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Bundled so people who install from the .dmg can turn on limit readings too.
cp scripts/statusline-capture.sh "$APP/Contents/Resources/statusline-capture.sh"
chmod 755 "$APP/Contents/Resources/statusline-capture.sh"

IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' | head -1)}"
OPTIONS=()
if [[ "$IDENTITY" == "Developer ID Application:"* ]]; then
  OPTIONS=(--options runtime --timestamp)
fi
codesign --force --sign "${IDENTITY:--}" ${OPTIONS[@]+"${OPTIONS[@]}"} "$APP"
codesign --verify --strict "$APP"
echo "Built $APP (signed with ${IDENTITY:-ad hoc signature})"
