import CoreGraphics
import Testing

@testable import Threshold

@Suite("Radial focus magnification")
struct RadialFocusMagnificationTests {
    @Test("Touch focus grows subtly and deeper focus receives the most space")
    func touchFocusProgression() {
        let focused = RadialFocusMagnification.scale(
            for: .touch,
            isFocused: true
        )
        let expanded = RadialFocusMagnification.scale(
            for: .touch,
            isFocused: true,
            isExpanded: true
        )

        #expect(focused > 1)
        #expect(expanded > focused)
        #expect(expanded <= 1.06)
    }

    @Test("Layout protection includes the largest focus size")
    func protectedExtentIncludesMagnification() {
        let restingHalfHeight = RadialInteractionProfile.touch.minimumTargetSize * 0.5
        let protected = RadialFocusMagnification.protectedHalfExtent(
            restingHalfHeight,
            for: .touch
        )

        #expect(protected > restingHalfHeight)
        #expect(protected * 2 >= RadialInteractionProfile.touch.minimumTargetSize)
    }
}
