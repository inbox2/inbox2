import XCTest

/// Logic tests for the streaming Kokoro lane's pure pieces (no sherpa, no audio): the
/// segmenter and the streaming-loop orchestration. The streaming guarantee — first chunk
/// delivered before full synthesis completes — is asserted with a fake `synthSegment`.
final class KokoroStreamTests: XCTestCase {

    // MARK: Segmentation

    func testShortTextIsASingleSegment() {
        XCTAssertEqual(KokoroSegmenter.segments("Good morning."), ["Good morning."])
    }

    func testSplitsOnSentenceBoundaries() {
        let segs = KokoroSegmenter.segments("One thing. Two things. Three things.")
        XCTAssertEqual(segs, ["One thing.", "Two things.", "Three things."])
    }

    func testLongSentenceSplitsOnClauses() {
        // A single sentence well over `segmentMaxChars` (120) should clause-split so the
        // first segment is short — that's the first-audio-latency win.
        let long = "This opening sentence runs on for quite a while before it ends, "
            + "carrying a clause, then another clause, and even a third clause, "
            + "so that it clearly exceeds the segment length threshold we set."
        let segs = KokoroSegmenter.segments(long)
        XCTAssertGreaterThan(segs.count, 1)
        XCTAssertLessThanOrEqual(segs.first!.count, long.count)
        XCTAssertTrue(segs.allSatisfy { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
    }

    func testEmptyTextProducesNoSegments() {
        XCTAssertEqual(KokoroSegmenter.segments("   \n  "), [])
    }

    // MARK: Streaming loop

    /// The core guarantee: the first chunk reaches the sink BEFORE the last segment begins
    /// synthesizing — i.e. audio starts before full synthesis completes.
    func testFirstChunkArrivesBeforeFullSynthesis() {
        var log: [String] = []
        let emitted = runKokoroStream(
            segments: ["one", "two", "three"],
            isCancelled: { false },
            sink: { _ in log.append("play"); return true },
            synthSegment: { seg, emit in
                log.append("synth-start:\(seg)")
                _ = emit([0.1, 0.2])   // one chunk per segment
            }
        )
        XCTAssertEqual(emitted, 3)
        let firstPlay = log.firstIndex(of: "play")
        let lastSynthStart = log.firstIndex(of: "synth-start:three")
        XCTAssertNotNil(firstPlay)
        XCTAssertNotNil(lastSynthStart)
        XCTAssertLessThan(firstPlay!, lastSynthStart!,
                          "first audio chunk must be delivered before the final segment synthesizes")
    }

    func testEmptyChunksDoNotCount() {
        let emitted = runKokoroStream(
            segments: ["a", "b"],
            isCancelled: { false },
            sink: { _ in true },
            synthSegment: { _, emit in _ = emit([]) }   // every chunk empty
        )
        XCTAssertEqual(emitted, 0, "empty audio ⇒ caller falls back to non-streaming synth")
    }

    func testCancellationStopsAfterCurrentSegment() {
        var synthCount = 0
        let emitted = runKokoroStream(
            segments: ["a", "b", "c"],
            isCancelled: { synthCount >= 1 },   // cancelled once the first segment ran
            sink: { _ in true },
            synthSegment: { _, emit in synthCount += 1; _ = emit([0.3]) }
        )
        XCTAssertEqual(synthCount, 1)
        XCTAssertEqual(emitted, 1)
    }
}
