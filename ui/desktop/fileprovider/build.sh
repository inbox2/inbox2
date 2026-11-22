#!/usr/bin/env bash
# Builds and signs the Disk in Finder extension (docs/Disk-Sync.md):
#   ui/desktop/fileprovider/build/Inbox2Disk.appex
# Tauri copies it into Inbox2.app/Contents/PlugIns (bundle.macOS.files) and does
# not sign nested .appex bundles, so it is signed here, before the app is.
#
#   INBOX2_APP_ID           com.inbox2.desktop (default) or com.inbox2.desktop.dev
#   APPLE_SIGNING_IDENTITY  the identity the app is signed with ("-" = ad-hoc)
set -euo pipefail
cd "$(dirname "$0")"
[ -x "$HOME/.cargo/bin/rustup" ] && export PATH="$HOME/.cargo/bin:$PATH"

APP_ID="${INBOX2_APP_ID:-com.inbox2.desktop}"
IDENTITY="${APPLE_SIGNING_IDENTITY:-Developer ID Application: Waseem Sadiq (KF53B4S5HD)}"
CORE=../core
T=../target
OUT=build

export MACOSX_DEPLOYMENT_TARGET=15.0
echo "▸ Rust core (static lib + Swift bindings)"
cargo build --release --features mobile-ffi --lib --manifest-path "$CORE/Cargo.toml"
rm -rf Generated && mkdir -p Generated
cargo run -q --release --features mobile-ffi --manifest-path "$CORE/Cargo.toml" --bin uniffi-bindgen -- generate \
  --library "$T/release/libinbox2_core.dylib" --language swift --out-dir Generated
mv Generated/inbox2_coreFFI.modulemap Generated/module.modulemap
cp "$T/release/libinbox2_core.a" Generated/

echo "▸ extension ($APP_ID.disk)"
xcodegen generate --quiet
xcodebuild -project Inbox2Disk.xcodeproj -target Inbox2Disk -configuration Release \
  SYMROOT="$PWD/$OUT/xc" INBOX2_APP_ID="$APP_ID" CODE_SIGNING_ALLOWED=NO -quiet build
rm -rf "$OUT/Inbox2Disk.appex"
cp -R "$OUT/xc/Release/Inbox2Disk.appex" "$OUT/"

echo "▸ signing with $IDENTITY"
sed "s/@APP_ID@/$APP_ID/" Inbox2Disk.entitlements.in > "$OUT/Inbox2Disk.entitlements"
ts=(); [[ "$IDENTITY" == Developer\ ID* ]] && ts=(--timestamp)
codesign --force --options runtime "${ts[@]}" --entitlements "$OUT/Inbox2Disk.entitlements" \
  --sign "$IDENTITY" "$OUT/Inbox2Disk.appex"
codesign --verify --strict "$OUT/Inbox2Disk.appex"
echo "✓ $PWD/$OUT/Inbox2Disk.appex"
