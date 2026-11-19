#!/usr/bin/env bash
# Build the inbox2-core native libraries + Kotlin bindings for the (future) Android
# client. The shared Rust core is platform-agnostic — this is the Android analog of
# build-ios-xcframework.sh, so the Compose app reuses the exact same `InboxEngine`
# UniFFI surface (see docs/iOS-App.md §3 + the Android-port notes).
#
# Prerequisites:
#   rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android
#   cargo install cargo-ndk
#   Android NDK installed (ANDROID_NDK_HOME set)
#
# Then: ./build-android-jni.sh   (run from core/)
set -euo pipefail
cd "$(dirname "$0")" # core/

[ -x "$HOME/.cargo/bin/rustup" ] && export PATH="$HOME/.cargo/bin:$PATH"

FEAT="--features mobile-ffi"
WS_TARGET="../target"
JNILIBS="$WS_TARGET/android-jniLibs" # drop into the Android :inboxcore module's src/main/jniLibs

echo "▸ building native libs for android ABIs (cargo-ndk + NDK)"
cargo ndk -t arm64-v8a -t armeabi-v7a -t x86_64 -o "$JNILIBS" build --release $FEAT

echo "▸ generating Kotlin bindings"
cargo build $FEAT # host lib for the bindgen --library input
mkdir -p "$WS_TARGET/uniffi-kotlin"
# The host library: .dylib on a Mac, .so on a Linux CI runner.
HOST_LIB="$WS_TARGET/debug/libinbox2_core.dylib"
[ -f "$HOST_LIB" ] || HOST_LIB="$WS_TARGET/debug/libinbox2_core.so"
cargo run $FEAT --bin uniffi-bindgen -- generate \
  --library "$HOST_LIB" \
  --language kotlin --out-dir "$WS_TARGET/uniffi-kotlin"

echo "✓ native libs:    $JNILIBS/{arm64-v8a,armeabi-v7a,x86_64}/libinbox2_core.so"
echo "✓ Kotlin binding: $WS_TARGET/uniffi-kotlin/.../inbox2_core.kt"
echo
echo "Add both to the Android app's :inboxcore module (jniLibs + the generated .kt),"
echo "depend on net.java.dev.jna:jna (aar) for the UniFFI runtime, then drive the"
echo "identical InboxEngine surface from Compose. The three-lane Bridge model manager,"
echo "availability, selection, and downloads are already shared — Android only adds the"
echo "Compose UI + audio I/O + the JNI inference engines (sherpa-onnx / LiteRT)."
