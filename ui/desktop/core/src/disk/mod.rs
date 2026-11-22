//! Disk in Finder: the sync engine behind the macOS File Provider extension
//! (docs/Disk-Sync.md). Host-agnostic; the extension drives it through UniFFI
//! (`ffi.rs`), the desktop app directly.

pub mod api;
pub mod engine;
#[cfg(feature = "mobile-ffi")]
pub mod ffi;
pub mod keys;
pub mod model;
pub mod sealed;
pub mod store;

#[cfg(test)]
mod tests;
