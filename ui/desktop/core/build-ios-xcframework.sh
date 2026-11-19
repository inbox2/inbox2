#!/usr/bin/env bash
# Build the inbox2-core xcframework (the iOS app links this) + the Swift bindings.
#
# Prerequisite — a rustup toolchain with the iOS targets (the host's Homebrew rust
# only has the macOS target, so this can't run against it):
#   rustup target add aarch64-apple-ios aarch64-apple-ios-sim
#
# Then: ./build-ios-xcframework.sh   (run from core/)
set -euo pipefail
cd "$(dirname "$0")" # core/

# Prefer the rustup toolchain (which carries the iOS targets) over a system/Homebrew
# rust that only has the host target.
[ -x "$HOME/.cargo/bin/rustup" ] && export PATH="$HOME/.cargo/bin:$PATH"

FEAT="--features mobile-ffi"
WS_TARGET="../target" # workspace target dir (ui/desktop/target)

echo "▸ building static libs for device + simulator"
cargo build --release $FEAT --target aarch64-apple-ios
cargo build --release $FEAT --target aarch64-apple-ios-sim

echo "▸ generating Swift bindings"
cargo build $FEAT # host lib for the bindgen --library input
mkdir -p "$WS_TARGET/uniffi-swift"
cargo run $FEAT --bin uniffi-bindgen -- generate \
  --library "$WS_TARGET/debug/libinbox2_core.dylib" \
  --language swift --out-dir "$WS_TARGET/uniffi-swift"

echo "▸ assembling the xcframework"
HDR="$WS_TARGET/uniffi-headers"
rm -rf "$HDR" && mkdir -p "$HDR"
cp "$WS_TARGET/uniffi-swift/inbox2_coreFFI.h" "$HDR/"
# xcframework expects the modulemap named module.modulemap
cp "$WS_TARGET/uniffi-swift/inbox2_coreFFI.modulemap" "$HDR/module.modulemap"

OUT="$WS_TARGET/InboxCore.xcframework"
rm -rf "$OUT"
xcodebuild -create-xcframework \
  -library "$WS_TARGET/aarch64-apple-ios/release/libinbox2_core.a" -headers "$HDR" \
  -library "$WS_TARGET/aarch64-apple-ios-sim/release/libinbox2_core.a" -headers "$HDR" \
  -output "$OUT"

echo "✓ $OUT"
echo "✓ Swift: $WS_TARGET/uniffi-swift/inbox2_core.swift  (add it + the xcframework to the Xcode app)"
echo
echo "In the Xcode app target, link: Security, CoreFoundation, SystemConfiguration,"
echo "and libc++ (the static lib's native-tls / system deps). Verified: the binding"
echo "compiles + links against the simulator slice with exactly those frameworks."
