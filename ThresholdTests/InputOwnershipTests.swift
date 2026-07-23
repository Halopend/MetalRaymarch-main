import Testing

@testable import Threshold

@MainActor
@Suite("Input ownership and radial profiles")
struct InputOwnershipTests {
    @Test("Only one semantic surface consumes an input stream")
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
    }

    @Test("Touch radial controls meet minimum target geometry")
    func touchGeometry() {
        #expect(RadialInteractionProfile.touch.minimumTargetSize >= 44)
        #expect(RadialInteractionProfile.touch.itemSpacing >= 44)
        #expect(!RadialInteractionProfile.touch.supportsHoverNavigation)
        #expect(RadialInteractionProfile.pointer.supportsHoverNavigation)
    }
}
