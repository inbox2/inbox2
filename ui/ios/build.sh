#!/usr/bin/env bash
# Build the app for the simulator, install, and launch it. Pass `reader` to open
# straight into the shared email-body WebView reader.
#   ./build.sh           # home screen (core status + accounts)
#   ./build.sh reader    # the WebView reading screen
set -euo pipefail
cd "$(dirname "$0")" # ui/ios

SIM_NAME="${SIM_NAME:-iPhone 16}"
UDID=$(xcrun simctl list devices available | grep -m1 "$SIM_NAME (" | grep -oE "[0-9A-F-]{36}")
[ -n "$UDID" ] || { echo "No '$SIM_NAME' simulator found"; exit 1; }

# Apple-Silicon-only sim slice → arm64 only (the Rust lib has no x86_64 sim slice).
xcodebuild -project Inbox2.xcodeproj -scheme Inbox2 -sdk iphonesimulator -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath build CODE_SIGNING_ALLOWED=NO \
  ARCHS=arm64 EXCLUDED_ARCHS=x86_64 build

xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl install "$UDID" build/Build/Products/Debug-iphonesimulator/Inbox2.app
xcrun simctl terminate "$UDID" com.inbox2.ios 2>/dev/null || true
if [ "${1:-}" = "reader" ]; then
  SIMCTL_CHILD_INBOX2_SCREEN=reader xcrun simctl launch "$UDID" com.inbox2.ios
else
  xcrun simctl launch "$UDID" com.inbox2.ios
fi
open -a Simulator
