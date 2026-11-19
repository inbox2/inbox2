//! Version-matched UniFFI bindgen entry point. Generates the Swift/Kotlin
//! bindings for the mobile apps from the compiled library, e.g.:
//!
//! ```sh
//! cargo run -p inbox2-core --features mobile-ffi --bin uniffi-bindgen -- \
//!   generate --library target/debug/libinbox2_core.dylib \
//!   --language swift --out-dir target/uniffi-swift
//! ```
fn main() {
    uniffi::uniffi_bindgen_main()
}
