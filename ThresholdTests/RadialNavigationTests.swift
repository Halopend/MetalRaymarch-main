import Foundation
import Testing
@testable import Threshold

@Suite("Radial navigation projection")
struct RadialNavigationProjectionTests {
    private final class SliderState {
        var isEnabled = false
        var value: Float = 2
    }

    private final class ToggleState {
        var isEnabled = true
        var value = false
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
    ) -> RadialNavigationNode {
        RadialTransformNodeFactory.branch(
            for: op,
            position: position,
            read: { state.read($0) },
            update: { id, mutation in state.update(id, mutation) }
        )
    }

    private func makeTree(clicked: @escaping (String) -> Void = { _ in }) -> [RadialNavigationNode] {
        [
            RadialNavigationNode(
                id: "root.a",
                title: "A",
                systemImage: "a.circle",
                children: [
                    RadialNavigationNode(
                        id: "a.1",
                        title: "A1",
                        systemImage: "1.circle",
                        children: [
                            RadialNavigationNode(
                                id: "slider.a.1.x",
                                title: "X",
                                systemImage: "x.circle",
                                slider: RadialSliderBinding(
                                    range: 0...2,
                                    read: { 0.5 },
                                    write: { _ in }
                                )
                            )
                        ]
                    ),
                    RadialNavigationNode(
                        id: "a.2",
                        title: "A2",
                        systemImage: "2.circle",
                        fallbackAction: { clicked("a.2") }
                    )
                ]
            ),
            RadialNavigationNode(
                id: "root.leaf",
                title: "Leaf",
                systemImage: "l.circle",
                fallbackAction: { clicked("root.leaf") }
            )
        ]
    }

    @MainActor
    @Test("Quick Access pins become stable persistent radial shortcuts")
    func quickAccessPinsArePersistentShortcuts() {
        let routes: [AppRoute] = [
            .input(.reactive),
            .shape(.formula),
            .explore(.jumpingOff)
        ]
        let shortcuts = RadialMenuProjectionFactory.quickAccessShortcuts(
            pinnedRouteIDs: [
                routes[0].stableID,
                "removed.route",
                routes[1].stableID,
                routes[0].stableID,
                routes[2].stableID
            ],
            selectedRoute: routes[1]
        )

        #expect(shortcuts.map(\.id) == [
            "quickAccess.\(routes[0].stableID)",
            "quickAccess.\(routes[1].stableID)",
            "quickAccess.\(routes[2].stableID)"
        ])
        #expect(shortcuts.map(\.title) == routes.map(\.title))
        #expect(shortcuts.map(\.systemImage) == routes.map(\.systemImage))
        #expect(shortcuts.map(\.isSelected) == [false, true, false])
        #expect(shortcuts.map(\.route) == routes)
    }

    private func makeOverflowHierarchy(clicked: @escaping () -> Void = {}) -> RadialNavigationProjection {
        let children = (1...4).map { index in
            RadialNavigationNode(
                id: "section.\(index)",
                title: "Section \(index)",
                systemImage: "\(index).circle",
                children: [
                    RadialNavigationNode(
                        id: "slider.section.\(index)",
                        title: "Value \(index)",
                        systemImage: "slider.horizontal.3",
                        slider: RadialSliderBinding(
                            range: 0...1,
                            read: { 0.5 },
                            write: { _ in }
                        )
                    )
                ]
            )
        }
        return RadialNavigationProjection(roots: [
            RadialNavigationNode(
                id: "root",
                title: "Root",
                systemImage: "square.grid.2x2",
                children: children,
                compactChildrenLimit: 3,
                overflowFallback: RadialOverflowFallback(
                    RadialNavigationNode(
                        id: "root.more",
                        title: "More",
                        systemImage: "ellipsis.circle",
                        fallbackAction: clicked
                    )
                )
            )
        ])
    }

    @Test("Radial projection applies an explicit compact fallback")
    func compactProjection() {
        let projection = makeOverflowHierarchy()
        let children = projection.rings(along: ["root"])[1]

        #expect(children.map(\.id) == ["section.1", "section.2", "root.more"])
        #expect(projection.roots[0].children.count == 4)
    }

    @Test("Touch route layout removes section traversal without dropping controls")
    func touchRouteLayoutIsFlat() {
        let sections = (1...2).map { section in
            RadialNavigationNode(
                id: "section.\(section)",
                title: "Section \(section)",
                systemImage: "square.stack",
                children: (1...2).map { control in
                    RadialNavigationNode(
                        id: "control.\(section).\(control)",
                        title: "Control \(section).\(control)",
                        systemImage: "slider.horizontal.3",
                        slider: RadialSliderBinding(
                            range: 0...1,
                            read: { 0 },
                            write: { _ in }
                        )
                    )
                }
            )
        }

        #expect(RadialRouteLayoutPolicy.children(
            from: sections,
            flattenSections: false
        ).map(\.id) == ["section.1", "section.2"])
        #expect(RadialRouteLayoutPolicy.children(
            from: sections,
            flattenSections: true
        ).map(\.id) == [
            "control.1.1", "control.1.2", "control.2.1", "control.2.2"
        ])
    }

    @Test("Radial keyboard traversal follows the compact projection")
    func compactKeyboardProjection() {
        let ids = makeOverflowHierarchy().flattenedKeyboardTargets().map(\.id)

        #expect(!ids.contains("section.4"))
        #expect(ids.contains("root.more"))
    }

    @Test("Dynamic inputs keep the longest path visible in radial")
    func radialPathReconciliation() {
        let projection = makeOverflowHierarchy()

        #expect(projection.reconciledPath(["root", "section.4"]) == ["root"])
        #expect(projection.reconciledPath(["root", "section.1"]) == ["root", "section.1"])
    }

    @Test("Singleton branch levels are transparent to radial navigation")
    func singletonBranchesAreSkipped() {
        let firstControl = RadialNavigationNode(
            id: "control.first",
            title: "First",
            systemImage: "slider.horizontal.3",
            slider: RadialSliderBinding(range: 0...1, read: { 0 }, write: { _ in })
        )
        let secondControl = RadialNavigationNode(
            id: "control.second",
            title: "Second",
            systemImage: "switch.2",
            toggle: RadialToggleBinding(read: { false }, write: { _ in })
        )
        let projection = RadialNavigationProjection(roots: [
            RadialNavigationNode(
                id: "root.quality",
                title: "Quality",
                systemImage: "gauge.with.dots.needle.67percent",
                children: [
                    RadialNavigationNode(
                        id: "quality.tuning",
                        title: "Tuning",
                        systemImage: "slider.horizontal.3",
                        children: [
                            RadialNavigationNode(
                                id: "quality.tuning.only-section",
                                title: "Only Section",
                                systemImage: "square.stack",
                                children: [firstControl, secondControl]
                            )
                        ]
                    )
                ]
            )
        ])

        let rings = projection.rings(along: ["root.quality"])
        #expect(rings.count == 2)
        #expect(rings[1].map(\.id) == ["control.first", "control.second"])

        let keyboardTargets = projection.flattenedKeyboardTargets()
        #expect(keyboardTargets.map(\.id) == [
            "root.quality", "control.first", "control.second"
        ])
        #expect(keyboardTargets.last?.ancestorPath == ["root.quality"])

        let visiblePath = projection.reconciledPath([
            "root.quality", "quality.tuning", "quality.tuning.only-section"
        ])
        #expect(visiblePath == ["root.quality"])
        #expect(RadialNavigationPathPolicy.retreating(from: visiblePath) == [])
    }

    @Test("Authored singleton paths retain deeper visible selections")
    func singletonPathReconciliationPreservesVisibleTail() {
        func section(_ id: String) -> RadialNavigationNode {
            RadialNavigationNode(
                id: "section.\(id)",
                title: "Section \(id)",
                systemImage: "square.stack",
                children: [
                    RadialNavigationNode(
                        id: "control.\(id)",
                        title: "Control \(id)",
                        systemImage: "slider.horizontal.3",
                        slider: RadialSliderBinding(
                            range: 0...1,
                            read: { 0 },
                            write: { _ in }
                        )
                    )
                ]
            )
        }

        let projection = RadialNavigationProjection(roots: [
            RadialNavigationNode(
                id: "root",
                title: "Root",
                systemImage: "square.grid.2x2",
                children: [
                    RadialNavigationNode(
                        id: "only.category",
                        title: "Only Category",
                        systemImage: "square.stack",
                        children: [section("a"), section("b")]
                    )
                ]
            )
        ])

        let visiblePath = projection.reconciledPath([
            "root", "only.category", "section.a"
        ])
        #expect(visiblePath == ["root", "section.a"])
        #expect(projection.rings(along: visiblePath).map { $0.map(\.id) } == [
            ["root"],
            ["section.a", "section.b"],
            ["control.a"]
        ])
        #expect(RadialNavigationPathPolicy.retreating(from: visiblePath) == ["root"])
    }

    @Test("A sole terminal control remains visible")
    func singletonLeafIsNotSkipped() {
        let projection = RadialNavigationProjection(roots: [
            RadialNavigationNode(
                id: "root",
                title: "Root",
                systemImage: "square.grid.2x2",
                children: [
                    RadialNavigationNode(
                        id: "control.only",
                        title: "Only Control",
                        systemImage: "slider.horizontal.3",
                        slider: RadialSliderBinding(
                            range: 0...1,
                            read: { 0 },
                            write: { _ in }
                        )
                    )
                ]
            )
        ])

        #expect(projection.rings(along: ["root"])[1].map(\.id) == ["control.only"])
    }

    @Test("Activating an expanded branch collapses exactly that level")
    func expandedBranchActivationRetreatsOneLevel() {
        #expect(RadialNavigationPathPolicy.activatingBranch(
            nodeID: "shape.parameters",
            depth: 1,
            in: ["root.shape", "shape.parameters", "parameters.formula"]
        ) == ["root.shape"])

        // The pre-opened workspace root is the first Mac radial level. It must
        // be collapsible by clicking its selected pill instead of being a no-op.
        #expect(RadialNavigationPathPolicy.activatingBranch(
            nodeID: "root.shape",
            depth: 0,
            in: ["root.shape"]
        ).isEmpty)
    }

    @Test("Activating a sibling replaces only that depth and stale descendants")
    func siblingBranchActivationReplacesTail() {
        #expect(RadialNavigationPathPolicy.activatingBranch(
            nodeID: "shape.transformations",
            depth: 1,
            in: ["root.shape", "shape.parameters", "parameters.formula"]
        ) == ["root.shape", "shape.transformations"])
    }

    @Test("Back removes one visible radial ring independent of focus")
    func radialBackAlwaysRetreatsOneLevel() {
        #expect(RadialNavigationPathPolicy.retreating(
            from: ["root.shape", "shape.parameters", "parameters.formula"]
        ) == ["root.shape", "shape.parameters"])
        #expect(RadialNavigationPathPolicy.retreating(from: ["root.shape"]) == [])
        #expect(RadialNavigationPathPolicy.retreating(from: []) == nil)
    }

    @Test("Compact overflow is an explicit full-controls fallback")
    func compactOverflowFallback() {
        var clicked = false
        let projection = makeOverflowHierarchy { clicked = true }
        let fallback = projection.node(withID: "root.more")

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

    @Test("Branches can expose full controls without becoming fallback leaves")
    func branchFullControlsAction() {
        var opened = false
        let node = RadialNavigationNode(
            id: "look.post-processing",
            title: "Post Processing",
            systemImage: "camera.filters",
            children: [
                RadialNavigationNode(
                    id: "slider.bloom",
                    title: "Bloom",
                    systemImage: "sun.max",
                    slider: RadialSliderBinding(
                        range: 0...1,
                        read: { 0.5 },
                        write: { _ in }
                    )
                )
            ],
            fullControlsAction: { opened = true }
        )

        #expect(node.isBranch)
        #expect(node.fallbackAction == nil)
        node.fullControlsAction?()
        #expect(opened)
    }

    @Test("Full controls require a double activation and a routed branch action")
    func fullControlsActivationPolicy() {
        #expect(!RadialActivationPolicy.shouldOpenFullControls(
            activationCount: 1,
            hasFullControlsAction: true
        ))
        #expect(!RadialActivationPolicy.shouldOpenFullControls(
            activationCount: 2,
            hasFullControlsAction: false
        ))
        #expect(RadialActivationPolicy.shouldOpenFullControls(
            activationCount: 2,
            hasFullControlsAction: true
        ))
    }

    @Test("Phone edge menu dismisses only toward its owning edge")
    func phoneEdgeMenuDismissalPolicy() {
        #expect(PhoneEdgeMenuGesturePolicy.shouldDismiss(
            opensLeft: true,
            horizontalTranslation: PhoneEdgeMenuGesturePolicy.dismissalDistance
        ))
        #expect(!PhoneEdgeMenuGesturePolicy.shouldDismiss(
            opensLeft: true,
            horizontalTranslation: -40
        ))
        #expect(PhoneEdgeMenuGesturePolicy.shouldDismiss(
            opensLeft: false,
            horizontalTranslation: -PhoneEdgeMenuGesturePolicy.dismissalDistance
        ))
        #expect(!PhoneEdgeMenuGesturePolicy.shouldDismiss(
            opensLeft: false,
            horizontalTranslation: 40
        ))
    }

    @Test("Phone edge menu reveal tracks the finger and commits past the threshold")
    func phoneEdgeMenuRevealPolicy() {
        #expect(PhoneEdgeMenuGesturePolicy.revealProgress(for: 0) == 0)
        #expect(PhoneEdgeMenuGesturePolicy.revealProgress(for: PhoneEdgeMenuGesturePolicy.revealDistance * 0.5) == 0.5)
        #expect(PhoneEdgeMenuGesturePolicy.revealProgress(for: PhoneEdgeMenuGesturePolicy.revealDistance + 40) == 1)
        #expect(!PhoneEdgeMenuGesturePolicy.shouldPresent(translation: PhoneEdgeMenuGesturePolicy.revealDistance * 0.71))
        #expect(PhoneEdgeMenuGesturePolicy.shouldPresent(translation: PhoneEdgeMenuGesturePolicy.revealDistance * 0.72))
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
            NavigationHierarchy.KeyboardTarget(id: "root.a", ancestorPath: []),
            NavigationHierarchy.KeyboardTarget(id: "a.1", ancestorPath: ["root.a"]),
            NavigationHierarchy.KeyboardTarget(
                id: "slider.a.1.x",
                ancestorPath: ["root.a", "a.1"]
            ),
            NavigationHierarchy.KeyboardTarget(id: "a.2", ancestorPath: ["root.a"]),
            NavigationHierarchy.KeyboardTarget(id: "root.leaf", ancestorPath: [])
        ])
    }

    @Test("Keyboard traversal wraps in both directions")
    func keyboardTraversalWraps() {
        let targets = makeTree().flattenedKeyboardTargets()

        #expect(NavigationKeyboardTraversal.nextID(
            from: "root.a", in: targets, backward: false
        ) == "a.1")
        #expect(NavigationKeyboardTraversal.nextID(
            from: "root.leaf", in: targets, backward: false
        ) == "root.a")
        #expect(NavigationKeyboardTraversal.nextID(
            from: "root.a", in: targets, backward: true
        ) == "root.leaf")
        #expect(NavigationKeyboardTraversal.nextID(
            from: "root.leaf", in: targets, backward: true
        ) == "a.2")
    }

    @Test("Nil and stale keyboard focus recover at the requested edge")
    func keyboardTraversalRecovers() {
        let targets = makeTree().flattenedKeyboardTargets()
        let empty: [NavigationHierarchy.KeyboardTarget] = []

        #expect(NavigationKeyboardTraversal.nextID(
            from: nil, in: targets, backward: false
        ) == "root.a")
        #expect(NavigationKeyboardTraversal.nextID(
            from: nil, in: targets, backward: true
        ) == "root.leaf")
        #expect(NavigationKeyboardTraversal.nextID(
            from: "removed", in: targets, backward: false
        ) == "root.a")
        #expect(NavigationKeyboardTraversal.nextID(
            from: "removed", in: targets, backward: true
        ) == "root.leaf")
        #expect(NavigationKeyboardTraversal.nextID(
            from: nil, in: empty, backward: false
        ) == nil)
    }

    @Test("Building and traversing keyboard targets never fires node actions")
    func keyboardTraversalHasNoSideEffects() {
        var clicked: [String] = []
        let targets = makeTree { clicked.append($0) }.flattenedKeyboardTargets()
        var focusedID: String?

        for _ in targets {
            focusedID = NavigationKeyboardTraversal.nextID(
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
        let binding = RadialSliderBinding(range: -2...6, read: { 0 }, write: { _ in })

        #expect(abs(binding.normalized(-2) - 0) < 0.0001)
        #expect(abs(binding.normalized(6) - 1) < 0.0001)
        #expect(abs(binding.normalized(2) - 0.5) < 0.0001)

        #expect(abs(binding.denormalized(0) - -2) < 0.0001)
        #expect(abs(binding.denormalized(1) - 6) < 0.0001)
        #expect(abs(binding.denormalized(1.7) - 6) < 0.0001)
        #expect(abs(binding.denormalized(-0.3) - -2) < 0.0001)

        // Degenerate range must not divide by zero.
        let flat = RadialSliderBinding(range: 3...3, read: { 3 }, write: { _ in })
        #expect(flat.normalized(3) == 0)
        #expect(flat.denormalized(0.5) == 3)
    }

    @Test("Horizontal slider travel increases to the right")
    func horizontalSliderDirection() {
        let binding = RadialSliderBinding(range: 0...10, read: { 5 }, write: { _ in })

        #expect(binding.value(startingAt: 5, horizontalTranslation: 90, fullRangeTravel: 180) == 10)
        #expect(binding.value(startingAt: 5, horizontalTranslation: -90, fullRangeTravel: 180) == 0)
        #expect(binding.value(startingAt: 5, horizontalTranslation: 18, fullRangeTravel: 180) == 6)
    }

    @Test("Slider binding is enabled by default and evaluates availability live")
    func sliderEnabledState() {
        let state = SliderState()
        let defaultBinding = RadialSliderBinding(
            range: 0...10,
            read: { 5 },
            write: { _ in }
        )
        let dynamicBinding = RadialSliderBinding(
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
        let binding = RadialSliderBinding(
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
        let binding = RadialSliderBinding(
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

    @Test("Binary binding toggles explicitly and guards unavailable writes")
    func binaryToggleBinding() {
        let state = ToggleState()
        let binding = RadialToggleBinding(
            read: { state.value },
            write: { state.value = $0 },
            isEnabled: { state.isEnabled }
        )

        binding.toggle()
        #expect(state.value)
        binding.set(false)
        #expect(!state.value)

        state.isEnabled = false
        binding.toggle()
        #expect(!state.value)
        binding.set(true)
        #expect(!state.value)
    }

    @Test("Transform branches derive their complete control shape from the warp catalog")
    func transformControlsFollowWarpCatalog() {
        for kind in SpaceWarpKind.allCases {
            let op = SpaceWarpOpValue(kind: kind)
            let state = TransformStackState([op])
            let branch = transformBranch(op, state: state)
            let expectedCount = 1
                + 1
                + kind.params.count
                + (kind.toggle == nil ? 0 : 1)
                + (kind.sourceAngle == nil ? 0 : 1)
                + (kind.usesAxis ? 3 : 0)

            #expect(branch.children.count == expectedCount)
            #expect(branch.title == "1 · \(kind.displayName)")
            #expect(branch.children.first?.title == "Enabled")
            #expect(branch.children.first?.toggle != nil)
            #expect(branch.children.first?.slider == nil)

            let strength = branch.children.first(where: { $0.title == kind.amountLabel })
            #expect(strength?.slider?.range == kind.strengthRange)
            if let sourceAngle = kind.sourceAngle {
                let angle = branch.children.first(where: { $0.title == sourceAngle.label })
                #expect(angle?.slider?.range == sourceAngle.range)
            }
            for spec in kind.params {
                let parameter = branch.children.first(where: { $0.title == spec.label })
                #expect(parameter?.slider?.range == spec.range)
            }
            if let toggle = kind.toggle {
                let binary = branch.children.first(where: { $0.title == toggle.label })
                #expect(binary?.toggle != nil)
                #expect(binary?.slider == nil)
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
            $0.id == "toggle.\(roots[1].id).enabled" && $0.ancestorPath == [roots[1].id]
        }))
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
        let enabled = branch.children.first(where: { $0.title == "Enabled" })!.toggle!
        let strength = branch.children.first(where: { $0.title == op.kind.amountLabel })!.slider!

        #expect(enabled.isEnabled())
        #expect(!strength.isEnabled())
        strength.writeIfEnabled(1.4)
        #expect(state.read(op.id)?.strength == op.strength)

        enabled.toggle()
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
        let mirror = coxeterBranch.children.first(where: { $0.title == "Mirror" })!.slider!
        let p = coxeterBranch.children.first(where: { $0.title == "p" })!.slider!
        let sourceAngle = coxeterBranch.children.first(where: { $0.title == "Source Angle" })!.slider!
        mirror.writeIfEnabled(0.4)
        #expect(state.read(coxeter.id)?.strength == 0.4)
        p.step(by: 1)
        #expect(state.read(coxeter.id)?.p1 == 6)
        p.writeIfEnabled(99)
        #expect(state.read(coxeter.id)?.p1 == 8)
        sourceAngle.writeIfEnabled(.pi / 2)
        #expect(abs((state.read(coxeter.id)?.axis.z ?? 0) - .pi / 2) < 1e-5)
        #expect(sourceAngle.format(.pi / 2) == "90°")

        let kaleidoscopeBranch = transformBranch(kaleidoscope, position: 1, state: state)
        let segments = kaleidoscopeBranch.children.first(where: { $0.title == "Segments" })!.slider!
        segments.step(by: 1)
        #expect(state.read(kaleidoscope.id)?.p1 == 7)
    }

    @Test("Imported duplicate op ids collapse to the first occurrence instead of colliding")
    func duplicatePersistedOpIDsCollapse() {
        // Scene files decode SpaceWarpOpValue.id verbatim, so a hand-edited or
        // merged file can carry the same UUID twice. Every projection consumer
        // is id-addressed; presenting both twins used to trap the menu's
        // keyboard-focus dictionary on every body evaluation.
        let sharedID = UUID()
        var original = SpaceWarpOpValue(kind: .twist)
        original.id = sharedID
        var duplicate = SpaceWarpOpValue(kind: .twist)
        duplicate.id = sharedID
        duplicate.strength = 1.3
        let state = TransformStackState([original, duplicate])
        let projection = RadialNavigationProjection(roots: [
            RadialNavigationNode(
                id: "root.transform",
                title: "Transform",
                systemImage: "arrow.triangle.2.circlepath",
                children: [
                    transformBranch(original, position: 0, state: state),
                    transformBranch(duplicate, position: 1, state: state)
                ]
            )
        ])

        let targets = projection.flattenedKeyboardTargets()
        #expect(Set(targets.map(\.id)).count == targets.count)

        let retainedID = "transform.op.\(sharedID.uuidString.lowercased())"
        #expect(projection.node(withID: retainedID)?.title == "1 · \(SpaceWarpKind.twist.displayName)")

        // De-duplication leaves one transform branch, so the generic singleton
        // rule promotes that branch's controls into the visible ring.
        let presented = projection.rings(along: ["root.transform"])[1]
        #expect(!presented.map(\.id).contains(retainedID))
        #expect(presented.map(\.id) == transformBranch(original, state: state).children.map(\.id))
    }

    @Test("Duplicate roots and duplicate siblings keep only their first occurrence")
    func duplicateNodesKeepFirstOccurrence() {
        let projection = RadialNavigationProjection(roots: [
            RadialNavigationNode(id: "dup", title: "First", systemImage: "1.circle"),
            RadialNavigationNode(id: "dup", title: "Second", systemImage: "2.circle"),
            RadialNavigationNode(
                id: "branch",
                title: "Branch",
                systemImage: "b.circle",
                children: [
                    RadialNavigationNode(id: "child", title: "Kept", systemImage: "1.circle"),
                    RadialNavigationNode(id: "child", title: "Dropped", systemImage: "2.circle")
                ]
            )
        ])

        #expect(projection.roots.map(\.title) == ["First", "Branch"])
        let branch = projection.node(withID: "branch")!
        #expect(projection.presentedChildren(of: branch).map(\.title) == ["Kept"])
    }

    @Test("Duplicates never consume the compact item budget")
    func duplicatesDoNotConsumeCompactBudget() {
        func child(_ id: String) -> RadialNavigationNode {
            RadialNavigationNode(
                id: id,
                title: id,
                systemImage: "circle",
                children: [
                    RadialNavigationNode(
                        id: "slider.\(id)",
                        title: id,
                        systemImage: "slider.horizontal.3",
                        slider: RadialSliderBinding(range: 0...1, read: { 0 }, write: { _ in })
                    )
                ]
            )
        }
        func projection(_ children: [RadialNavigationNode]) -> RadialNavigationProjection {
            RadialNavigationProjection(roots: [RadialNavigationNode(
                id: "root",
                title: "Root",
                systemImage: "square.grid.2x2",
                children: children,
                compactChildrenLimit: 3,
                overflowFallback: RadialOverflowFallback(RadialNavigationNode(
                    id: "root.more",
                    title: "More",
                    systemImage: "ellipsis.circle",
                    fallbackAction: {}
                ))
            )])
        }

        // Three unique ids fit the budget once the duplicate is dropped.
        let fitting = projection([child("a"), child("a"), child("b"), child("c")])
        #expect(fitting.rings(along: ["root"])[1].map(\.id) == ["a", "b", "c"])

        // Four unique ids still overflow into the explicit fallback.
        let overflowing = projection(
            [child("a"), child("a"), child("b"), child("c"), child("d")]
        )
        #expect(overflowing.rings(along: ["root"])[1].map(\.id) == ["a", "b", "root.more"])
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
        let cache = ControlStateStore(renderSettings: settings)

        settings.spaceWarpStack = [second, first]
        let changed = cache.updateSpaceWarpOp(id: second.id) { $0.strength = 1.6 }

        #expect(changed)
        #expect(settings.spaceWarpStack.map(\.id) == [second.id, first.id])
        #expect(settings.spaceWarpStack.first?.strength == 1.6)
        #expect(cache.spaceWarpStack == settings.spaceWarpStack)
    }
}
