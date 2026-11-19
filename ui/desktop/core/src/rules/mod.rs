//! Local-rules engine — the portable half of the agentic-filters funnel
//! (docs/Agentic-Filters.md). This is the part that runs on **every** host
//! (desktop today, native iOS/Android later):
//!
//!   - [`conditions`] — Tier-0 static matching over a message's envelope.
//!   - [`gate`] — Tier-1 on-device embedding gate.
//!   - [`actions`] — built-in actions (archive / delete / mark-read / triage /
//!     label), applied through the sync engine's durable write-back queue.
//!   - [`ai`] — the [`ai::OnDeviceAi`] trait the gate and AI-backed actions call,
//!     so this crate never depends on a concrete inference engine. The host
//!     injects an implementation (desktop: ONNX Runtime; mobile: Apple FM / its
//!     own runtime), or `None` to run Tier-0 only.
//!
//! The desktop-only CLI-agent harness (spawning Claude Code/Codex/… for the
//! Tier-2 `run_agent` action) stays in the desktop crate — mobile can't spawn
//! external processes, and built-in actions cover it there.

pub mod actions;
pub mod ai;
pub mod conditions;
pub mod gate;

pub use ai::OnDeviceAi;
pub use conditions::{conditions_match, Condition, MessageFields};
