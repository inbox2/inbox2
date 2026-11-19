fn main() {
    // `BUNDLE_ID` in src/lib.rs reads `INBOX2_BUNDLE_ID` via `option_env!`, which
    // is captured at compile time. Cargo doesn't track env vars used that way
    // unless a build script declares them, so the prod and dev (`*.dev`) builds
    // would otherwise share a stale compiled identifier in the same target dir.
    // Declaring it here forces a recompile whenever the value changes.
    println!("cargo:rerun-if-env-changed=INBOX2_BUNDLE_ID");
}
