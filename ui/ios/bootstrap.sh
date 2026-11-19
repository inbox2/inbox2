#!/usr/bin/env bash
# Bootstrap the iOS app from the shared sources: build the Rust core xcframework,
# vendor the generated Swift binding, bundle the shared email-body JS, and generate
# the Xcode project. Run this after a fresh checkout (and whenever the FFI surface
# or the email-body package changes), then build with build.sh or open the project.
#
# Prereq: rustup with the iOS targets (Homebrew rust only has the host target):
#   rustup target add aarch64-apple-ios aarch64-apple-ios-sim
set -euo pipefail
cd "$(dirname "$0")" # ui/ios
[ -x "$HOME/.cargo/bin/rustup" ] && export PATH="$HOME/.cargo/bin:$PATH"

echo "▸ 1/4 building the shared Rust core xcframework"
../desktop/core/build-ios-xcframework.sh

echo "▸ 2/4 vendoring the generated Swift binding"
mkdir -p Sources/Generated
cp ../desktop/target/uniffi-swift/inbox2_core.swift Sources/Generated/inbox2_core.swift

echo "▸ 3/4 bundling @inbox2/email-body as an app resource"
mkdir -p Resources
../web/node_modules/.bin/esbuild ../../packages/email-body/src/index.js \
  --bundle --format=iife --global-name=Inbox2EmailBody --outfile=Resources/email-body.js

# The Bridge space-shooter game is native SceneKit (Sources/Game/) — no JS bundle.

echo "▸ 4/4 generating the Xcode project"
xcodegen generate

echo "✓ bootstrapped — ./build.sh to build+run, or open Inbox2.xcodeproj"
