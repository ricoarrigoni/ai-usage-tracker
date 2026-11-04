#!/bin/bash
# Builds "dist/AI Usage Tracker.app". Signs with an Apple Development certificate when there
# is one, because a stable signature lets macOS keep the app's permissions across rebuilds.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product AIUsageTracker
BIN="$(swift build -c release --show-bin-path)/AIUsageTracker"

APP="dist/AI Usage Tracker.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/AIUsageTracker"
cp packaging/Info.plist "$APP/Contents/Info.plist"
cp packaging/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

IDENTITY="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' | head -1)"
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Built $APP (signed with ${IDENTITY:-ad hoc signature})"
