#!/usr/bin/env bash
# Phone screenshots for the website's mobile section — the iOS analog of shots.py.
#
# Builds the iOS app for the simulator, seeds it with the same Brightfold demo DB
# the desktop shots use (ui/desktop/scripts/seed_demo.py, installed into the DEV
# desktop identity), drives the tab bar over idb, and writes each screen twice —
# <name>.webp (dark) and <name>-light.webp — exactly like the desktop stills.
#
#   website/scripts/mobile-shots.sh            # build + seed + shoot
#   SKIP_BUILD=1 website/scripts/mobile-shots.sh
#
# Needs: idb (brew install facebook/fb/idb-companion + pipx install fb-idb),
# cwebp (brew install webp), and a demo-seeded ~/Library/Application Support/
# com.inbox2.desktop.dev/inbox2.db.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
IOS="$REPO/ui/ios"
OUT="$REPO/website/public/assets/shots"
DEV="$HOME/Library/Application Support/com.inbox2.desktop.dev"
BID="com.inbox2.ios"
SIM_NAME="${SIM_NAME:-iPhone 17 Pro}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

UDID=$(xcrun simctl list devices available | grep -m1 "$SIM_NAME (" | grep -oE "[0-9A-F-]{36}")
[ -n "$UDID" ] || { echo "no '$SIM_NAME' simulator" >&2; exit 1; }
echo "▸ $SIM_NAME  $UDID"

if [ "${SKIP_BUILD:-0}" != 1 ]; then
  echo "▸ building for the simulator"
  xcodebuild -project "$IOS/Inbox2.xcodeproj" -scheme Inbox2 -sdk iphonesimulator \
    -configuration Debug -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$IOS/build" CODE_SIGNING_ALLOWED=NO ARCHS=arm64 EXCLUDED_ARCHS=x86_64 \
    build > "$TMP/build.log" 2>&1 || { tail -30 "$TMP/build.log"; exit 1; }
fi

xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl install "$UDID" "$IOS/build/Build/Products/Debug-iphonesimulator/Inbox2.app"

# Seed: launch once so the app makes Documents/inbox2/, then swap the DB under it.
echo "▸ seeding the demo store"
[ -f "$DEV/inbox2.db" ] || { echo "no demo DB at $DEV/inbox2.db — run seed_demo.py --install --dev" >&2; exit 1; }
xcrun simctl launch "$UDID" "$BID" >/dev/null 2>&1 || true
sleep 4
xcrun simctl terminate "$UDID" "$BID" >/dev/null 2>&1 || true
DATA="$(xcrun simctl get_app_container "$UDID" "$BID" data)/Documents/inbox2"
mkdir -p "$DATA"
sqlite3 "$DEV/inbox2.db" ".backup '$TMP/seed.db'"
cp "$TMP/seed.db" "$DATA/inbox2.db"
cp "$DEV/.credential_key" "$DATA/.credential_key"
: > "$DATA/inbox2.db-wal"    # neutralize the stale WAL/SHM of the copied DB
: > "$DATA/inbox2.db-shm"

# The marketing status bar: 9:41, full bars, no charging bolt.
xcrun simctl status_bar "$UDID" override --time "9:41" --dataNetwork wifi --wifiMode active \
  --wifiBars 3 --cellularMode active --cellularBars 4 --batteryState discharging --batteryLevel 100

tap() { idb ui tap --udid "$UDID" "$1" "$2"; sleep "${3:-2}"; }

shot() { # shot <name> <suffix>
  local png="$TMP/$1.png"
  xcrun simctl io "$UDID" screenshot --type=png "$png" >/dev/null 2>&1
  cwebp -quiet -q 88 -resize 800 0 "$png" -o "$OUT/$1$2.webp"
  echo "  → assets/shots/$1$2.webp"
}

# Tab bar (points, iPhone 17 Pro): inbox 70, bridge 174, compose 226, calendar 290.
for theme in dark light; do
  suffix=""; [ "$theme" = light ] && suffix="-light"
  echo "▸ $theme"
  xcrun simctl ui "$UDID" appearance "$theme"
  xcrun simctl terminate "$UDID" "$BID" >/dev/null 2>&1 || true
  xcrun simctl launch "$UDID" "$BID" >/dev/null
  sleep 6
  shot m-inbox "$suffix"
  tap 200 678 3                      # the Aurora rebrand thread
  shot m-conversation "$suffix"
  tap 38 86                          # back
  tap 174 802 3                      # Bridge
  shot m-bridge "$suffix"
  tap 290 802 3                      # Calendar
  shot m-calendar "$suffix"
  tap 70 802                         # back to the inbox for the next pass
done

echo "✓ done"
