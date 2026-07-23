import Testing
@testable import Threshold

@Suite("Platform-neutral navigation hierarchy")
struct NavigationHierarchyTests {
    private func makeHierarchy(
        allowCustomScenes: Bool = false,
        shapeSections: [ShapeRailSection] = [.parameters, .space],
        musicSections: [MusicRailSection] = [.playback, .reactive],
        includesGestureEditing: Bool = false
    ) -> NavigationHierarchy {
        NavigationHierarchy.application(availability: NavigationAvailability(
            allowsCustomScenes: allowCustomScenes,
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
            NavigationHierarchy.rootID(for: .music),
            NavigationHierarchy.rootID(for: .shape),
            NavigationHierarchy.rootID(for: .visualizations),
            NavigationHierarchy.rootID(for: .performance)
        ])
        #expect(hierarchy.workspaceRoots.map(\.title) == [
            "Explore", "Input", "Shape", "Look", "Quality"
        ])
    }

    @Test("Callers supply platform availability without redefining structure")
    func platformAvailability() {
        let hierarchy = makeHierarchy(
            allowCustomScenes: true,
            shapeSections: [.parameters, .hands, .bounding],
            musicSections: [.playback, .songs],
            includesGestureEditing: true
        )

        #expect(hierarchy.children(ofWorkspace: .explore).contains {
            $0.id == "explore.\(ExploreRailSection.customScenes.rawValue)"
        })
        #expect(hierarchy.children(ofWorkspace: .shape).map(\.id) == [
            "shape.\(ShapeRailSection.parameters.rawValue)",
            "shape.\(ShapeRailSection.hands.rawValue)",
            "shape.\(ShapeRailSection.bounding.rawValue)"
        ])
        #expect(hierarchy.children(ofWorkspace: .music).map(\.id) == [
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

    @Test("Keyboard projection is stable preorder with ancestor paths")
    func keyboardProjection() {
        let hierarchy = makeHierarchy(
            shapeSections: [.parameters],
            musicSections: []
        )
        let targets = hierarchy.flattenedKeyboardTargets()
        let shapeRoot = NavigationHierarchy.rootID(for: .shape)

        #expect(targets.first?.id == NavigationHierarchy.rootID(for: .explore))
        #expect(targets.first(where: {
            $0.id == "shape.\(ShapeRailSection.parameters.rawValue)"
        })?.ancestorPath == [shapeRoot])
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
