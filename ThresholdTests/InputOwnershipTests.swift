import Testing

@testable import Threshold

@MainActor
@Suite("Input ownership and radial profiles")
struct InputOwnershipTests {
    @Test("Ownership stays exclusive except for viewport navigation beneath the pointer radial")
    func exclusiveOwnership() {
        let store = InputOwnershipStore()
        #expect(store.claim(.viewport))
        #expect(store.claim(.viewport))
        #expect(!store.claim(.radialMenu))
        #expect(!store.canConsume(.inspector))

        store.release(.viewport)
        #expect(store.owner == .viewport)
        store.release(.viewport)
        #expect(store.owner == nil)
        #expect(store.claim(.radialMenu))
        #expect(!store.canConsume(.viewport))
        #expect(store.canConsumeViewportInput(allowsPointerRadialPassthrough: true))
        #expect(!store.canConsumeViewportInput(allowsPointerRadialPassthrough: false))
        #expect(!store.canConsume(.inspector))
    }

    @Test("Touch radial controls meet minimum target geometry")
    func touchGeometry() {
        #expect(RadialInteractionProfile.touch.minimumTargetSize >= 44)
        #expect(RadialInteractionProfile.touch.itemSpacing >= 44)
        #expect(!RadialInteractionProfile.touch.supportsHoverNavigation)
        #expect(RadialInteractionProfile.pointer.supportsHoverNavigation)
    }

    @Test("Double activation rejects drags and accepts low movement")
    func doubleActivationArbitration() {
        #expect(!RadialActivationPolicy.shouldToggle(
            activationCount: 1, movement: 0, profile: .pointer
        ))
        #expect(RadialActivationPolicy.shouldToggle(
            activationCount: 2, movement: 0, profile: .pointer
        ))
        #expect(RadialActivationPolicy.shouldToggle(
            activationCount: 2,
            movement: RadialActivationPolicy.maximumMovement(for: .pointer),
            profile: .pointer
        ))
        #expect(!RadialActivationPolicy.shouldToggle(
            activationCount: 2,
            movement: RadialActivationPolicy.maximumMovement(for: .pointer) + 0.01,
            profile: .pointer
        ))
        #expect(RadialActivationPolicy.maximumMovement(for: .touch)
                > RadialActivationPolicy.maximumMovement(for: .pointer))
    }
}
