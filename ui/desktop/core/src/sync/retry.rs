//! Shared exponential-backoff schedule for the durable retry queues.
//!
//! Both the write-back queue ([`crate::sync::actions::WritebackQueue`]) and the
//! outbox ([`crate::sync::outbox::OutboxQueue`]) retry transient failures on the
//! same curve, so a flaky connection drains both at a comparable pace. The
//! constants + math live here once instead of being copied into each queue
//! (CLAUDE.md: no duplicated enums/constants).

/// First retry delay, doubled each attempt up to [`MAX_BACKOFF_SECS`].
pub(crate) const INITIAL_BACKOFF_SECS: i64 = 1;
/// Backoff cap (5 minutes).
pub(crate) const MAX_BACKOFF_SECS: i64 = 300;

/// Seconds to wait before the next retry of an attempt that has already failed
/// `retry_count` times. Schedule: 1s, 2s, 4s, 8s, 16s, … capped at
/// [`MAX_BACKOFF_SECS`]. The shift is clamped to avoid overflow on a runaway
/// retry count.
pub(crate) fn next_backoff_secs(retry_count: u32) -> i64 {
    std::cmp::min(
        INITIAL_BACKOFF_SECS * (1i64 << retry_count.min(20)),
        MAX_BACKOFF_SECS,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn backoff_doubles_then_caps() {
        assert_eq!(next_backoff_secs(0), 1);
        assert_eq!(next_backoff_secs(1), 2);
        assert_eq!(next_backoff_secs(2), 4);
        assert_eq!(next_backoff_secs(3), 8);
        assert_eq!(next_backoff_secs(4), 16);
        // Caps at MAX_BACKOFF_SECS and stays there (no overflow at high counts).
        assert_eq!(next_backoff_secs(20), MAX_BACKOFF_SECS);
        assert_eq!(next_backoff_secs(1000), MAX_BACKOFF_SECS);
    }
}
