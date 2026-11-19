// Bridging header that exposes the sherpa-onnx C API to Swift (SherpaOnnx.swift
// wraps it). The header ships inside Vendor/sherpa-onnx.xcframework; linking that
// xcframework puts its Headers dir on the search path. Fetch the frameworks with
// `bin/fetch-sherpa-onnx`. Only the Kokoro free-lane TTS engine uses these symbols
// (compiled when BRIDGE_KOKORO is set).
#include "sherpa-onnx/c-api/c-api.h"

// NSException catcher for Cocoa APIs that raise ObjC exceptions Swift can't catch
// (AVAudioEngine graph mutations). Compiled from ObjCExceptionCatcher.m alongside.
#include "ObjCExceptionCatcher.h"
