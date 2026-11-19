import Foundation

/// Splits a brief into ordered synthesis segments for the streaming Kokoro lane, and the
/// pure streaming-loop orchestration that drives per-segment synthesis. Both are free of
/// sherpa / AVFoundation so they unit-test standalone (see `Tests/KokoroStreamTests.swift`).
///
/// Streaming Kokoro = one synth pass per segment, playing segment N while N+1 synthesizes.
/// First-audio latency is therefore "synthesize segment 0", so we make the *first* segment
/// short: split on sentence-final punctuation first, then clause-split any sentence longer
/// than `segmentMaxChars`.
enum KokoroSegmenter {
    /// Above this many characters, a sentence is further split on clause delimiters to
    /// lower time-to-first-audio (a long opening sentence shouldn't gate the first sound).
    static let segmentMaxChars = 120
    /// A clause split only happens where both sides keep at least this many non-space
    /// characters — so we never chop a tiny fragment or split inside "3,000".
    static let clauseMinRun = 24

    /// Sentence-level split first; clause-level only for sentences over `segmentMaxChars`.
    /// Trimmed, no empties. Clause splits keep both sides ≥ `clauseMinRun`, so no segment is
    /// a micro-fragment; short whole sentences are preserved as their own segments.
    static func segments(_ text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var out: [String] = []
        for sentence in splitKeeping(trimmed, delimiters: [".", "?", "!"], minRun: 1) {
            if sentence.count <= segmentMaxChars {
                out.append(sentence)
            } else {
                out.append(contentsOf: splitKeeping(sentence, delimiters: [";", ":", ",", "—"], minRun: clauseMinRun))
            }
        }
        return out
    }

    /// Split after each delimiter, but only when both the run so far and the remainder have
    /// at least `minRun` non-space characters — keeping the delimiter on the left side.
    private static func splitKeeping(_ s: String, delimiters: Set<Character>, minRun: Int) -> [String] {
        var pieces: [String] = []
        var current = ""
        let chars = Array(s)
        var remaining = chars.reduce(0) { $0 + ($1.isWhitespace ? 0 : 1) }
        for (i, c) in chars.enumerated() {
            current.append(c)
            if !c.isWhitespace { remaining -= 1 }
            guard delimiters.contains(c) else { continue }
            let leftCount = current.reduce(0) { $0 + ($1.isWhitespace ? 0 : 1) }
            if leftCount >= minRun && remaining >= minRun {
                let piece = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !piece.isEmpty { pieces.append(piece) }
                current = ""
            }
            _ = i
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { pieces.append(tail) }
        return pieces.isEmpty ? [s.trimmingCharacters(in: .whitespacesAndNewlines)] : pieces
    }
}

/// Thread-safe cancel flag shared between the audio engine (which calls `cancel()` on
/// barge-in / interruption) and the running sherpa synthesis (whose chunk callback returns
/// 0 to abort). Read from the synthesis thread, set from the main actor.
final class KokoroCancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

/// Pure streaming orchestration (no sherpa, no audio): synthesize each segment in order,
/// forwarding every chunk to `sink` the instant it's produced — so playback of segment N
/// overlaps synthesis of N+1. `synthSegment` runs one segment, calling its `emit` for each
/// chunk; `emit` returns false to abort that segment mid-pass (wired to barge-in via
/// `isCancelled`). Stops early when cancelled or when the sink says so. Returns the number
/// of non-empty chunks emitted (0 ⇒ produced nothing → caller falls back).
///
/// Extracted from the sherpa engine so the streaming guarantee ("first chunk before full
/// synthesis") is unit-testable with a fake `synthSegment`.
@discardableResult
func runKokoroStream(
    segments: [String],
    isCancelled: @escaping () -> Bool,
    sink: @escaping (_ chunk: [Float]) -> Bool,
    synthSegment: (_ segment: String, _ emit: (_ chunk: [Float]) -> Bool) -> Void
) -> Int {
    var emitted = 0
    for seg in segments {
        if isCancelled() { break }
        var keepGoing = true
        synthSegment(seg) { chunk in
            if !chunk.isEmpty { emitted += 1 }
            // Forward to playback; stop on sink request or a barge-in mid-segment.
            keepGoing = sink(chunk) && !isCancelled()
            return keepGoing
        }
        if !keepGoing { break }
    }
    return emitted
}
