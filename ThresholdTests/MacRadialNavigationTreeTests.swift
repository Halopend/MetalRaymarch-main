#if os(macOS)
import Foundation
import Testing
@testable import Threshold

@Suite("Mac navigation hierarchy")
struct MacNavigationHierarchyTests {
    private final class SliderState {
        var isEnabled = false
        var value: Float = 2
    }

    private final class TransformStackState {
        var ops: [SpaceWarpOpValue]

        init(_ ops: [SpaceWarpOpValue]) {
            self.ops = ops
        }

        func read(_ id: UUID) -> SpaceWarpOpValue? {
            ops.first(where: { $0.id == id })
        }

        func update(_ id: UUID, _ mutate: (inout SpaceWarpOpValue) -> Void) {
            guard let index = ops.firstIndex(where: { $0.id == id }) else { return }
            mutate(&ops[index])
        }
    }

    private func transformBranch(
        _ op: SpaceWarpOpValue,
        position: Int = 0,
        state: TransformStackState
    ) -> MacNavigationNode {
        MacQuickTransformNodeFactory.branch(
            for: op,
            position: position,
            read: { state.read($0) },
            update: { id, mutation in state.update(id, mutation) }
        )
    }

    private func makeTree(clicked: @escaping (String) -> Void = { _ in }) -> [MacNavigationNode] {
        [
            MacNavigationNode(
                id: "root.a",
                title: "A",
                systemImage: "a.circle",
                children: [
                    MacNavigationNode(
                        id: "a.1",
                        title: "A1",
                        systemImage: "1.circle",
                        children: [
                            MacNavigationNode(
                                id: "slider.a.1.x",
                                title: "X",
                                systemImage: "x.circle",
                                slider: MacQuickSliderBinding(
                                    range: 0...2,
                                    read: { 0.5 },
                                    write: { _ in }
                                )
                            )
                        ]
                    ),
                    MacNavigationNode(
                        id: "a.2",
                        title: "A2",
                        systemImage: "2.circle",
                        fallbackAction: { clicked("a.2") }
                    )
                ]
            ),
            MacNavigationNode(
                id: "root.leaf",
                title: "Leaf",
                systemImage: "l.circle",
                fallbackAction: { clicked("root.leaf") }
            )
        ]
    }

    private func makeOverflowHierarchy(clicked: @escaping () -> Void = {}) -> MacNavigationHierarchy {
        let children = (1...4).map { index in
            MacNavigationNode(
                id: "section.\(index)",
                title: "Section \(index)",
                systemImage: "\(index).circle",
                children: [
                    MacNavigationNode(
                        id: "slider.section.\(index)",
                        title: "Value \(index)",
                        systemImage: "slider.horizontal.3",
                        slider: MacQuickSliderBinding(
                            range: 0...1,
                            read: { 0.5 },
                            write: { _ in }
                        )
                    )
                ]
            )
        }
        return MacNavigationHierarchy(roots: [
            MacNavigationNode(
                id: "root",
                title: "Root",
                systemImage: "square.grid.2x2",
                children: children,
                compactChildrenLimit: 3,
                overflowFallback: MacNavigationOverflowFallback(
                    MacNavigationNode(
                        id: "root.more",
                        title: "More",
                        systemImage: "ellipsis.circle",
                        fallbackAction: clicked
                    )
                )
            )
        ])
    }

    @Test("Grid and radial project the same complete hierarchy at different densities")
    func presentationProjection() {
        let hierarchy = makeOverflowHierarchy()

        let gridChildren = hierarchy.rings(along: ["root"], for: .grid)[1]
        let radialChildren = hierarchy.rings(along: ["root"], for: .radial)[1]

        #expect(gridChildren.map(\.id) == ["section.1", "section.2", "section.3", "section.4"])
        #expect(radialChildren.map(\.id) == ["section.1", "section.2", "root.more"])
        #expect(hierarchy.roots[0].children.count == 4)
    }

    @Test("Flattened keyboard traversal follows each presentation without redefining the tree")
    func presentationKeyboardProjection() {
        let hierarchy = makeOverflowHierarchy()
        let gridIDs = hierarchy.flattenedKeyboardTargets(for: .grid).map(\.id)
        let radialIDs = hierarchy.flattenedKeyboardTargets(for: .radial).map(\.id)

        #expect(gridIDs.contains("section.4"))
        #expect(!gridIDs.contains("root.more"))
        #expect(!radialIDs.contains("section.4"))
        #expect(radialIDs.contains("root.more"))
    }

    @Test("Switching presentation keeps the longest visible hierarchy path")
    func presentationPathReconciliation() {
        let hierarchy = makeOverflowHierarchy()
        let deepGridPath = ["root", "section.4"]

        #expect(hierarchy.reconciledPath(deepGridPath, for: .grid) == deepGridPath)
        #expect(hierarchy.reconciledPath(deepGridPath, for: .radial) == ["root"])
    }

    @Test("Compact overflow is an explicit full-controls fallback")
    func compactOverflowFallback() {
        var clicked = false
        let hierarchy = makeOverflowHierarchy { clicked = true }
        let fallback = hierarchy.node(withID: "root.more", for: .radial)

        #expect(fallback?.fallbackAction != nil)
        fallback?.fallbackAction?()
        #expect(clicked)
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

    @Test("Flattened keyboard targets use preorder and carry only ancestor ids")
    func flattenedKeyboardTargets() {
        let targets = makeTree().flattenedKeyboardTargets()

        #expect(targets == [
            MacNavigationKeyboardTarget(id: "root.a", ancestorPath: []),
            MacNavigationKeyboardTarget(id: "a.1", ancestorPath: ["root.a"]),
            MacNavigationKeyboardTarget(
                id: "slider.a.1.x",
                ancestorPath: ["root.a", "a.1"]
            ),
            MacNavigationKeyboardTarget(id: "a.2", ancestorPath: ["root.a"]),
            MacNavigationKeyboardTarget(id: "root.leaf", ancestorPath: [])
        ])
    }

    @Test("Keyboard traversal wraps in both directions")
    func keyboardTraversalWraps() {
        let targets = makeTree().flattenedKeyboardTargets()

        #expect(MacNavigationKeyboardTraversal.nextID(
            from: "root.a", in: targets, backward: false
        ) == "a.1")
        #expect(MacNavigationKeyboardTraversal.nextID(
            from: "root.leaf", in: targets, backward: false
        ) == "root.a")
        #expect(MacNavigationKeyboardTraversal.nextID(
            from: "root.a", in: targets, backward: true
        ) == "root.leaf")
        #expect(MacNavigationKeyboardTraversal.nextID(
            from: "root.leaf", in: targets, backward: true
        ) == "a.2")
    }

    @Test("Nil and stale keyboard focus recover at the requested edge")
    func keyboardTraversalRecovers() {
        let targets = makeTree().flattenedKeyboardTargets()
        let empty: [MacNavigationKeyboardTarget] = []

        #expect(MacNavigationKeyboardTraversal.nextID(
            from: nil, in: targets, backward: false
        ) == "root.a")
        #expect(MacNavigationKeyboardTraversal.nextID(
            from: nil, in: targets, backward: true
        ) == "root.leaf")
        #expect(MacNavigationKeyboardTraversal.nextID(
            from: "removed", in: targets, backward: false
        ) == "root.a")
        #expect(MacNavigationKeyboardTraversal.nextID(
            from: "removed", in: targets, backward: true
        ) == "root.leaf")
        #expect(MacNavigationKeyboardTraversal.nextID(
            from: nil, in: empty, backward: false
        ) == nil)
    }

    @Test("Building and traversing keyboard targets never fires node actions")
    func keyboardTraversalHasNoSideEffects() {
        var clicked: [String] = []
        let targets = makeTree { clicked.append($0) }.flattenedKeyboardTargets()
        var focusedID: String?

        for _ in targets {
            focusedID = MacNavigationKeyboardTraversal.nextID(
                from: focusedID,
                in: targets,
                backward: false
            )
        }

        #expect(focusedID == "root.leaf")
        #expect(clicked.isEmpty)
    }

    @Test("Only leaves without quick inputs carry full-controls fallbacks")
    func activationPolicyFromShape() {
        let tree = makeTree()

        // Branches navigate in place; only fallback leaves open full controls.
        let branch = tree.node(withID: "root.a")!
        #expect(branch.isBranch)
        #expect(branch.fallbackAction == nil)

        let sectionWithSliders = tree.node(withID: "a.1")!
        #expect(sectionWithSliders.isBranch)
        #expect(sectionWithSliders.fallbackAction == nil)

        let nestedFallback = tree.node(withID: "a.2")!
        #expect(!nestedFallback.isBranch)
        #expect(nestedFallback.fallbackAction != nil)

        let windowLeaf = tree.node(withID: "root.leaf")!
        #expect(!windowLeaf.isBranch)
        #expect(windowLeaf.fallbackAction != nil)

        let slider = tree.node(withID: "slider.a.1.x")!
        #expect(!slider.isBranch)
        #expect(slider.slider != nil)
        #expect(slider.fallbackAction == nil)
    }

    @Test("Slider binding normalization round-trips and clamps")
    func sliderNormalization() {
        let binding = MacQuickSliderBinding(range: -2...6, read: { 0 }, write: { _ in })

        #expect(abs(binding.normalized(-2) - 0) < 0.0001)
        #expect(abs(binding.normalized(6) - 1) < 0.0001)
        #expect(abs(binding.normalized(2) - 0.5) < 0.0001)

        #expect(abs(binding.denormalized(0) - -2) < 0.0001)
        #expect(abs(binding.denormalized(1) - 6) < 0.0001)
        #expect(abs(binding.denormalized(1.7) - 6) < 0.0001)
        #expect(abs(binding.denormalized(-0.3) - -2) < 0.0001)

        // Degenerate range must not divide by zero.
        let flat = MacQuickSliderBinding(range: 3...3, read: { 3 }, write: { _ in })
        #expect(flat.normalized(3) == 0)
        #expect(flat.denormalized(0.5) == 3)
    }

    @Test("Horizontal slider travel increases to the right")
    func horizontalSliderDirection() {
        let binding = MacQuickSliderBinding(range: 0...10, read: { 5 }, write: { _ in })

        #expect(binding.value(startingAt: 5, horizontalTranslation: 90, fullRangeTravel: 180) == 10)
        #expect(binding.value(startingAt: 5, horizontalTranslation: -90, fullRangeTravel: 180) == 0)
        #expect(binding.value(startingAt: 5, horizontalTranslation: 18, fullRangeTravel: 180) == 6)
    }

    @Test("Slider binding is enabled by default and evaluates availability live")
    func sliderEnabledState() {
        let state = SliderState()
        let defaultBinding = MacQuickSliderBinding(
            range: 0...10,
            read: { 5 },
            write: { _ in }
        )
        let dynamicBinding = MacQuickSliderBinding(
            range: 0...10,
            read: { state.value },
            write: { state.value = $0 },
            isEnabled: { state.isEnabled }
        )

        #expect(defaultBinding.isEnabled())
        #expect(!dynamicBinding.isEnabled())

        state.isEnabled = true
        #expect(dynamicBinding.isEnabled())
    }

    @Test("Guarded slider writes are ignored while disabled")
    func disabledSliderWriteGuard() {
        let state = SliderState()
        let binding = MacQuickSliderBinding(
            range: 0...10,
            read: { state.value },
            write: { state.value = $0 },
            isEnabled: { state.isEnabled }
        )

        binding.writeIfEnabled(8)
        #expect(state.value == 2)

        state.isEnabled = true
        binding.writeIfEnabled(8)
        #expect(state.value == 8)

        state.isEnabled = false
        binding.writeIfEnabled(4)
        #expect(state.value == 8)
    }

    @Test("Slider keyboard stepping uses range fractions, clamps, and stays disabled live")
    func sliderKeyboardStep() {
        let state = SliderState()
        let binding = MacQuickSliderBinding(
            range: 0...10,
            read: { state.value },
            write: { state.value = $0 },
            isEnabled: { state.isEnabled }
        )

        binding.step(by: 1)
        #expect(state.value == 2)

        state.isEnabled = true
        binding.step(by: 1)
        #expect(state.value == 2.5)
        binding.step(by: -1)
        #expect(state.value == 2)

        state.value = 9.8
        binding.step(by: 1)
        #expect(state.value == 10)
        binding.step(by: -100)
        #expect(state.value == 0)

        state.isEnabled = false
        binding.step(by: 1, fraction: 0.2)
        #expect(state.value == 0)
    }

    @Test("Transform branches derive their complete control shape from the warp catalog")
    func transformControlsFollowWarpCatalog() {
        for kind in SpaceWarpKind.allCases {
            let op = SpaceWarpOpValue(kind: kind)
            let state = TransformStackState([op])
            let branch = transformBranch(op, state: state)
            let expectedCount = 1
                + (kind == .coxeter ? 0 : 1)
                + kind.params.count
                + (kind.toggle == nil ? 0 : 1)
                + (kind.usesAxis ? 3 : 0)

            #expect(branch.children.count == expectedCount)
            #expect(branch.title == "1 · \(kind.displayName)")
            #expect(branch.children.first?.title == "Enabled")

            if kind != .coxeter {
                let strength = branch.children.first(where: { $0.title == kind.amountLabel })
                #expect(strength?.slider?.range == kind.strengthRange)
            }
            for spec in kind.params {
                let parameter = branch.children.first(where: { $0.title == spec.label })
                #expect(parameter?.slider?.range == spec.range)
            }
            if kind.usesAxis {
                #expect(branch.children.contains(where: { $0.title == "\(kind.axisLabel) X" }))
                #expect(branch.children.contains(where: { $0.title == "\(kind.axisLabel) Y" }))
                #expect(branch.children.contains(where: { $0.title == "\(kind.axisLabel) Z" }))
            }
        }
    }

    @Test("Duplicate transform kinds keep unique UUID-backed keyboard routes")
    func duplicateTransformRoutesAreUnique() {
        let first = SpaceWarpOpValue(kind: .twist)
        let second = SpaceWarpOpValue(kind: .twist)
        let state = TransformStackState([first, second])
        let roots = [
            transformBranch(first, position: 0, state: state),
            transformBranch(second, position: 1, state: state)
        ]
        let targets = roots.flattenedKeyboardTargets()

        #expect(Set(targets.map(\.id)).count == targets.count)
        #expect(roots[0].id != roots[1].id)
        #expect(targets.contains(where: {
            $0.id.hasPrefix("slider.\(roots[1].id)") && $0.ancestorPath == [roots[1].id]
        }))
    }

    @Test("Transform writes follow UUID after reorder and become inert after deletion")
    func transformWriteFollowsLiveIdentity() {
        var first = SpaceWarpOpValue(kind: .twist)
        first.strength = 0.25
        var second = SpaceWarpOpValue(kind: .twist)
        second.strength = 1.25
        let state = TransformStackState([first, second])
        let secondBranch = transformBranch(second, position: 1, state: state)
        let strength = secondBranch.children.first(where: { $0.title == second.kind.amountLabel })!.slider!

        state.ops.swapAt(0, 1)
        strength.writeIfEnabled(1.75)

        #expect(state.read(second.id)?.strength == 1.75)
        #expect(state.read(first.id)?.strength == 0.25)
        #expect(state.ops.map(\.id) == [second.id, first.id])

        state.ops.removeAll(where: { $0.id == second.id })
        strength.writeIfEnabled(0.5)
        #expect(state.ops.count == 1)
        #expect(state.read(first.id)?.strength == 0.25)
    }

    @Test("Disabled transforms retain an enabled control while guarding their parameters")
    func disabledTransformControls() {
        var op = SpaceWarpOpValue(kind: .ripple)
        op.isEnabled = false
        let state = TransformStackState([op])
        let branch = transformBranch(op, state: state)
        let enabled = branch.children.first(where: { $0.title == "Enabled" })!.slider!
        let strength = branch.children.first(where: { $0.title == op.kind.amountLabel })!.slider!

        #expect(enabled.isEnabled())
        #expect(!strength.isEnabled())
        strength.writeIfEnabled(1.4)
        #expect(state.read(op.id)?.strength == op.strength)

        enabled.step(by: 1)
        #expect(state.read(op.id)?.isEnabled == true)
        #expect(strength.isEnabled())
        strength.writeIfEnabled(1.4)
        #expect(state.read(op.id)?.strength == 1.4)
    }

    @Test("Transform controls clamp authored ranges and step discrete values by one")
    func transformControlRangesAndDiscreteSteps() {
        var coxeter = SpaceWarpOpValue(kind: .coxeter)
        coxeter.p1 = 5
        var kaleidoscope = SpaceWarpOpValue(kind: .kaleidoscope)
        kaleidoscope.p1 = 6
        let state = TransformStackState([coxeter, kaleidoscope])

        let coxeterBranch = transformBranch(coxeter, position: 0, state: state)
        let p = coxeterBranch.children.first(where: { $0.title == "p" })!.slider!
        p.step(by: 1)
        #expect(state.read(coxeter.id)?.p1 == 6)
        p.writeIfEnabled(99)
        #expect(state.read(coxeter.id)?.p1 == 8)

        let kaleidoscopeBranch = transformBranch(kaleidoscope, position: 1, state: state)
        let segments = kaleidoscopeBranch.children.first(where: { $0.title == "Segments" })!.slider!
        segments.step(by: 1)
        #expect(state.read(kaleidoscope.id)?.p1 == 7)
    }

    @Test("UI cache commits transform edits by UUID to RenderSettings")
    @MainActor
    func cacheCommitsTransformByIdentity() {
        let settings = RenderSettings()
        var first = SpaceWarpOpValue(kind: .mirror)
        first.strength = 0.4
        var second = SpaceWarpOpValue(kind: .twist)
        second.strength = 0.8
        settings.spaceWarpStack = [first, second]
        let cache = UISettingsCache(renderSettings: settings)

        settings.spaceWarpStack = [second, first]
        let changed = cache.updateSpaceWarpOp(id: second.id) { $0.strength = 1.6 }

        #expect(changed)
        #expect(settings.spaceWarpStack.map(\.id) == [second.id, first.id])
        #expect(settings.spaceWarpStack.first?.strength == 1.6)
        #expect(cache.spaceWarpStack == settings.spaceWarpStack)
    }
}
#endif
