#!/bin/bash
# Builds "dist/AI Usage Tracker.app", signed for this Mac only.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product AIUsageTracker
BIN="$(swift build -c release --show-bin-path)/AIUsageTracker"

APP="dist/AI Usage Tracker.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/AIUsageTracker"
cp packaging/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "Built $APP"
