#!/usr/bin/env bash
# One-time: clear the PROD data dir (com.inbox2.desktop) so the installed
# Inbox2.app starts empty for your real mail. The demo/fake database has already
# been copied to the DEV dir (com.inbox2.desktop.dev) by the setup, so this only
# moves the prod copy aside (it is NOT deleted — renamed to *.predev_<ts>.bak).
#
# Refuses to run while any Inbox2 desktop process is alive, because the live app
# holds the SQLite file open and moving it would corrupt the handoff. Quit the
# app (and any `yarn dev`) first.
set -euo pipefail

PROD="$HOME/Library/Application Support/com.inbox2.desktop"

if pgrep -f "inbox2-desktop|target/(debug|release)/Inbox2|/Applications/Inbox2.app/Contents/MacOS/" >/dev/null 2>&1; then
  echo "error: an Inbox2 desktop process is running."
  echo "  Quit Inbox2 and any 'yarn dev' instance, then re-run."
  pgrep -fl "inbox2-desktop|target/(debug|release)/Inbox2|/Applications/Inbox2.app/Contents/MacOS/" | grep -v grep || true
  exit 1
fi

ts="$(date +%Y%m%d_%H%M%S)"
moved=0
for f in inbox2.db inbox2.db-wal inbox2.db-shm; do
  if [ -f "$PROD/$f" ]; then
    mv "$PROD/$f" "$PROD/$f.predev_$ts.bak"
    moved=1
  fi
done

if [ "$moved" = 1 ]; then
  echo "• prod demo DB moved aside (*.predev_$ts.bak). Inbox2.app will start empty."
else
  echo "• prod dir already had no inbox2.db — nothing to move."
fi
echo "• keychain credential key + on-device models are untouched."
echo "Done. Launch /Applications/Inbox2.app and connect your real accounts."
