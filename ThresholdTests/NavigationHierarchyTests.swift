import Testing
@testable import Threshold

@Suite("Platform-neutral navigation hierarchy")
struct NavigationHierarchyTests {
    private func makeHierarchy(
        allowCustomScenes: Bool = false,
        includesMixedRealityScenes: Bool = true,
        shapeSections: [ShapeRailSection] = [.formula, .space],
        musicSections: [MusicRailSection] = [.parameters, .reactive, .playback],
        includesGestureEditing: Bool = false
    ) -> NavigationHierarchy {
        NavigationHierarchy.application(availability: NavigationAvailability(
            allowsCustomScenes: allowCustomScenes,
            includesMixedRealityScenes: includesMixedRealityScenes,
            shapeSections: shapeSections,
            musicSections: musicSections,
            includesGestureEditing: includesGestureEditing
        ))
    }

    @Test("Workspace roots preserve the shared top-dock order")
    func workspaceOrder() {
        let hierarchy = makeHierarchy()

        #expect(hierarchy.workspaceRoots.map(\.id) == [
            NavigationHierarchy.rootID(for: .explore),
            NavigationHierarchy.rootID(for: .input),
            NavigationHierarchy.rootID(for: .shape),
            NavigationHierarchy.rootID(for: .look),
            NavigationHierarchy.rootID(for: .quality)
        ])
        #expect(hierarchy.workspaceRoots.map(\.title) == [
            "Explore", "Input", "Shape", "Look", "Quality"
        ])
    }

    @Test("Callers supply platform availability without redefining structure")
    func platformAvailability() {
        let hierarchy = makeHierarchy(
            allowCustomScenes: true,
            shapeSections: [.formula, .hands, .bounding],
            musicSections: [.playback, .songs],
            includesGestureEditing: true
        )

        // Explore's second level is supplied at runtime by the filesystem
        // library tree; static navigation deliberately has no smart-view leaf.
        #expect(hierarchy.children(ofWorkspace: .explore).isEmpty)
        #expect(hierarchy.children(ofWorkspace: .shape).map(\.id) == [
            "shape.\(ShapeRailSection.formula.rawValue)",
            "shape.\(ShapeRailSection.hands.rawValue)",
            "shape.\(ShapeRailSection.bounding.rawValue)"
        ])
        #expect(hierarchy.children(ofWorkspace: .input).map(\.id) == [
            "input.\(MusicRailSection.playback.rawValue)",
            "input.\(MusicRailSection.songs.rawValue)"
        ])
        #expect(hierarchy.utilityRoots.map(\.id) == [
            "utility.gestures",
            "utility.animationEditor",
            "utility.quickToggles",
            "utility.settings"
        ])
    }

    @Test("iPad Input menu presents Parameters, Reactivity, then Sources")
    func iPadInputOrder() {
        let availability = NavigationAvailability.resolve(
            profile: .iPadOS,
            allowsCustomScenes: true,
            includesGestureEditing: false,
            includesMixedRealityScenes: true
        )
        let input = NavigationHierarchy.application(availability: availability)
            .children(ofWorkspace: .input)

        #expect(input.map(\.title) == ["Parameters", "Reactivity", "Sources"])
        #expect(input.map(\.target) == [
            .route(.input(.parameters)),
            .route(.input(.reactive)),
            .route(.input(.playback))
        ])
    }

    @Test("Explore never adds trait-based static navigation")
    func exploreIsRuntimeLibraryNavigation() {
        let included = makeHierarchy(includesMixedRealityScenes: true)
        let excluded = makeHierarchy(includesMixedRealityScenes: false)

        #expect(included.children(ofWorkspace: .explore).isEmpty)
        #expect(excluded.children(ofWorkspace: .explore).isEmpty)
    }

    @Test("Keyboard projection is stable preorder with ancestor paths")
    func keyboardProjection() {
        let hierarchy = makeHierarchy(
            shapeSections: [.formula],
            musicSections: [.parameters]
        )
        let targets = hierarchy.flattenedKeyboardTargets()

        #expect(targets.first?.id == NavigationHierarchy.rootID(for: .explore))
        #expect(targets.first(where: {
            $0.id == "input.\(MusicRailSection.parameters.rawValue)"
        })?.ancestorPath == [NavigationHierarchy.rootID(for: .input)])
        #expect(targets.last?.id == "utility.settings")
    }

    @Test("Keyboard traversal wraps independently of presentation")
    func keyboardTraversal() {
        let targets = [
            NavigationHierarchy.KeyboardTarget(id: "one", ancestorPath: []),
            NavigationHierarchy.KeyboardTarget(id: "two", ancestorPath: [])
        ]

        #expect(NavigationKeyboardTraversal.nextID(
            from: "two", in: targets, backward: false
        ) == "one")
        #expect(NavigationKeyboardTraversal.nextID(
            from: "one", in: targets, backward: true
        ) == "two")
    }
}
