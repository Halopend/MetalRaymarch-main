import Foundation
import Testing
@testable import Threshold

@MainActor
@Suite("Parameter slider preview")
struct ParameterSliderPreviewTests {
    @Test("Ending one touch keeps the preview until the other touch ends")
    func overlappingTouches() {
        let preview = ParameterSliderPreview()
        let first = UUID()
        let second = UUID()
        preview.setEditing(true, for: first)
        preview.setEditing(true, for: second)
        preview.setEditing(false, for: first)
        #expect(preview.isAdjusting)
        preview.setEditing(false, for: second)
        #expect(!preview.isAdjusting)
    }

    @Test("Duplicate begin and cancellation edges cannot strand or clear another touch")
    func repeatedLifecycleEdges() {
        let preview = ParameterSliderPreview()
        let removedControl = UUID()
        let activeControl = UUID()
        preview.setEditing(true, for: removedControl)
        preview.setEditing(true, for: removedControl)
        preview.setEditing(false, for: removedControl)
        #expect(!preview.isAdjusting)

        preview.setEditing(true, for: activeControl)
        // A late touch-up after onDisappear must not affect a new control.
        preview.setEditing(false, for: removedControl)
        #expect(preview.isAdjusting)
        preview.setEditing(false, for: activeControl)
        #expect(!preview.isAdjusting)
    }
}
