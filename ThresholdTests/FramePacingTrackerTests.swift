import Testing
@testable import Threshold

@Suite("Presented-frame pacing")
struct FramePacingTrackerTests {
    @Test("FPS and percentiles use actual presentation gaps")
    func presentationStatistics() {
        var tracker = FramePacingTracker()
        _ = tracker.recordPresentation(at: 1.0)
        for index in 1...120 {
            _ = tracker.recordPresentation(at: 1.0 + Double(index) / 120.0)
        }

        let snapshot = tracker.snapshot()
        #expect(abs(snapshot.fps - 120) < 0.01)
        #expect(abs(snapshot.frameGapP95Ms - (1_000.0 / 120.0)) < 0.01)
        #expect(snapshot.hitchCount == 0)
        #expect(snapshot.sampleCount == 120)
    }

    @Test("A long presented-frame gap is counted as a hitch")
    func hitchDetection() {
        var tracker = FramePacingTracker()
        _ = tracker.recordPresentation(at: 1.0)
        for index in 1...30 {
            _ = tracker.recordPresentation(at: 1.0 + Double(index) / 60.0)
        }
        _ = tracker.recordPresentation(at: 1.75)

        let snapshot = tracker.snapshot()
        #expect(snapshot.hitchCount == 1)
        #expect(snapshot.frameGapP99Ms > 100)
        #expect(snapshot.maximumFrameGapMs >= 250)
    }

    @Test("Wake-sized gaps reset the rolling window without inflating every percentile")
    func wakeGapReset() {
        var tracker = FramePacingTracker()
        _ = tracker.recordPresentation(at: 1.0)
        _ = tracker.recordPresentation(at: 1.0 + 1.0 / 60.0)
        let snapshot = tracker.recordPresentation(at: 5.0)

        #expect(snapshot.hitchCount == 1)
        #expect(snapshot.sampleCount == 0)
        #expect(snapshot.maximumFrameGapMs > 3_000)
    }
}
