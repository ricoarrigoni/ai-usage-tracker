#!/bin/bash
# Builds the app, replaces the copy in /Applications, and opens it.
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/build-app.sh

pkill -x AIUsageTracker 2>/dev/null || true
# Give the old copy a moment to quit before replacing it.
while pgrep -x AIUsageTracker >/dev/null; do sleep 0.2; done

rm -rf "/Applications/AI Usage Tracker.app"
# Move it rather than copy, so only one copy of the app exists for macOS to find.
mv "dist/AI Usage Tracker.app" "/Applications/"
open "/Applications/AI Usage Tracker.app"
echo "Installed to /Applications"
