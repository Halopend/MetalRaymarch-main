#if os(macOS)
import Testing
@testable import Threshold

@Suite("Mac radial navigation tree")
struct MacRadialNavigationTreeTests {
    private func makeTree(clicked: @escaping (String) -> Void = { _ in }) -> [MacRadialNavNode] {
        [
            MacRadialNavNode(
                id: "root.a",
                title: "A",
                systemImage: "a.circle",
                children: [
                    MacRadialNavNode(
                        id: "a.1",
                        title: "A1",
                        systemImage: "1.circle",
                        children: [
                            MacRadialNavNode(
                                id: "slider.a.1.x",
                                title: "X",
                                systemImage: "x.circle",
                                slider: MacRadialSliderBinding(
                                    range: 0...2,
                                    read: { 0.5 },
                                    write: { _ in }
                                )
                            )
                        ],
                        clickAction: { clicked("a.1") }
                    ),
                    MacRadialNavNode(
                        id: "a.2",
                        title: "A2",
                        systemImage: "2.circle",
                        clickAction: { clicked("a.2") }
                    )
                ]
            ),
            MacRadialNavNode(
                id: "root.leaf",
                title: "Leaf",
                systemImage: "l.circle",
                clickAction: { clicked("root.leaf") }
            )
        ]
    }

    @Test("Path walk yields one ring per selected branch level")
    func ringsFollowPath() {
        let tree = makeTree()

        let rootOnly = tree.rings(along: [])
        #expect(rootOnly.count == 1)
        #expect(rootOnly[0].map(\.id) == ["root.a", "root.leaf"])

        let twoRings = tree.rings(along: ["root.a"])
        #expect(twoRings.count == 2)
        #expect(twoRings[1].map(\.id) == ["a.1", "a.2"])

        let threeRings = tree.rings(along: ["root.a", "a.1"])
        #expect(threeRings.count == 3)
        #expect(threeRings[2].map(\.id) == ["slider.a.1.x"])
    }

    @Test("A stale or leaf path entry truncates the walk instead of orphaning rings")
    func staleAndLeafPathsTruncate() {
        let tree = makeTree()

        // Unknown id (e.g. a fractal switch removed a formula branch).
        #expect(tree.rings(along: ["root.gone", "a.1"]).count == 1)

        // Leaf id: leaves never open a deeper ring.
        #expect(tree.rings(along: ["root.leaf"]).count == 1)

        // Valid first hop, stale second hop.
        #expect(tree.rings(along: ["root.a", "a.gone"]).count == 2)

        // Slider leaves terminate the walk even if the path claims otherwise.
        #expect(tree.rings(along: ["root.a", "a.1", "slider.a.1.x"]).count == 3)
    }

    @Test("Depth-first lookup finds nested nodes")
    func nodeLookup() {
        let tree = makeTree()
        #expect(tree.node(withID: "slider.a.1.x") != nil)
        #expect(tree.node(withID: "a.2") != nil)
        #expect(tree.node(withID: "missing") == nil)
    }

    @Test("Activation policy is carried by node shape")
    func activationPolicyFromShape() {
        let tree = makeTree()

        // Branches navigate on hover; the window-opening leaves and the
        // branch's own click action are the only side-effectful paths.
        let branch = tree.node(withID: "root.a")!
        #expect(branch.isBranch)
        #expect(branch.clickAction == nil)

        let sectionWithSliders = tree.node(withID: "a.1")!
        #expect(sectionWithSliders.isBranch)
        #expect(sectionWithSliders.clickAction != nil)

        let windowLeaf = tree.node(withID: "root.leaf")!
        #expect(!windowLeaf.isBranch)
        #expect(windowLeaf.clickAction != nil)

        let slider = tree.node(withID: "slider.a.1.x")!
        #expect(!slider.isBranch)
        #expect(slider.slider != nil)
        #expect(slider.clickAction == nil)
    }

    @Test("Slider binding normalization round-trips and clamps")
    func sliderNormalization() {
        let binding = MacRadialSliderBinding(range: -2...6, read: { 0 }, write: { _ in })

        #expect(abs(binding.normalized(-2) - 0) < 0.0001)
        #expect(abs(binding.normalized(6) - 1) < 0.0001)
        #expect(abs(binding.normalized(2) - 0.5) < 0.0001)

        #expect(abs(binding.denormalized(0) - -2) < 0.0001)
        #expect(abs(binding.denormalized(1) - 6) < 0.0001)
        #expect(abs(binding.denormalized(1.7) - 6) < 0.0001)
        #expect(abs(binding.denormalized(-0.3) - -2) < 0.0001)

        // Degenerate range must not divide by zero.
        let flat = MacRadialSliderBinding(range: 3...3, read: { 3 }, write: { _ in })
        #expect(flat.normalized(3) == 0)
        #expect(flat.denormalized(0.5) == 3)
    }

    @Test("Horizontal slider travel increases to the right")
    func horizontalSliderDirection() {
        let binding = MacRadialSliderBinding(range: 0...10, read: { 5 }, write: { _ in })

        #expect(binding.value(startingAt: 5, horizontalTranslation: 90, fullRangeTravel: 180) == 10)
        #expect(binding.value(startingAt: 5, horizontalTranslation: -90, fullRangeTravel: 180) == 0)
        #expect(binding.value(startingAt: 5, horizontalTranslation: 18, fullRangeTravel: 180) == 6)
    }
}
#endif
