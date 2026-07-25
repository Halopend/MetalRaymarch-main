import Foundation

/// Runtime capabilities that filter the shared application navigation without
/// changing its structure. Platform hosts provide capabilities; presentations
/// never redefine labels, routes, or ordering.
struct NavigationAvailability: Sendable {
    let allowsCustomScenes: Bool
    let shapeSections: [ShapeRailSection]
    let musicSections: [MusicRailSection]
    let includesGestureEditing: Bool

    /// Runtime feature flags remain explicit inputs; platform support comes
    /// from the injected profile rather than target-conditional navigation.
    static func resolve(
        profile: PlatformProfile,
        allowsCustomScenes: Bool,
        includesGestureEditing: Bool
    ) -> NavigationAvailability {
        let shapeSections = ShapeRailSection.allCases.filter {
            $0 != .hands || profile.supports(.handTracking)
        }

        return NavigationAvailability(
            allowsCustomScenes: allowsCustomScenes,
            shapeSections: shapeSections,
            musicSections: MusicRailSection.availableCases(for: profile),
            includesGestureEditing: includesGestureEditing && profile.supports(.gestureEditing)
        )
    }
}

/// The platform-neutral application navigation definition.
///
/// It owns destinations and parent/child relationships only. Grid, radial,
/// keyboard, touch, pointer, and spatial-input presentations all consume this
/// same tree and decide independently how to render or traverse it.
struct NavigationHierarchy: Sendable {
    enum RootPlacement: Sendable {
        case workspace
        case utility
    }

    struct Node: Identifiable, Sendable {
        let id: String
        let title: String
        let systemImage: String
        let target: AppNavigationTarget
        let rootPlacement: RootPlacement
        let children: [Node]

        var isBranch: Bool { !children.isEmpty }
    }

    struct KeyboardTarget: Equatable, Sendable {
        let id: String
        let ancestorPath: [String]
    }

    let roots: [Node]

    var workspaceRoots: [Node] {
        roots.filter { $0.rootPlacement == .workspace }
    }

    var utilityRoots: [Node] {
        roots.filter { $0.rootPlacement == .utility }
    }

    func children(ofWorkspace root: WorkspaceRoot) -> [Node] {
        workspaceRoots.first(where: { node in
            guard case .workspace(let candidate) = node.target else { return false }
            return candidate == root
        })?.children ?? []
    }

    func node(withID id: String) -> Node? {
        func find(in nodes: [Node]) -> Node? {
            for node in nodes {
                if node.id == id { return node }
                if let match = find(in: node.children) { return match }
            }
            return nil
        }
        return find(in: roots)
    }

    /// Stable preorder used by keyboard and alternate-input presentations.
    func flattenedKeyboardTargets() -> [KeyboardTarget] {
        var targets: [KeyboardTarget] = []
        func append(_ nodes: [Node], ancestors: [String]) {
            for node in nodes {
                targets.append(KeyboardTarget(id: node.id, ancestorPath: ancestors))
                append(node.children, ancestors: ancestors + [node.id])
            }
        }
        append(roots, ancestors: [])
        return targets
    }

    static func application(availability: NavigationAvailability) -> NavigationHierarchy {
        func leaf(
            title: String,
            systemImage: String,
            route: AppRoute
        ) -> Node {
            Node(
                id: route.stableID,
                title: title,
                systemImage: systemImage,
                target: .route(route),
                rootPlacement: .workspace,
                children: []
            )
        }

        func workspace(_ root: WorkspaceRoot, children: [Node]) -> Node {
            Node(
                id: rootID(for: root),
                title: root.displayName,
                systemImage: root.systemImage,
                target: .workspace(root),
                rootPlacement: .workspace,
                children: children
            )
        }

        let explore = ExploreRailSection.allCases
            .filter { $0 != .customScenes || availability.allowsCustomScenes }
            .map { section in
                leaf(
                    title: section.rawValue,
                    systemImage: section.icon,
                    route: .explore(section)
                )
            }
        let shape = availability.shapeSections.map { section in
            leaf(
                title: section.rawValue,
                systemImage: section.icon,
                route: .shape(section)
            )
        }
        let visualizations = VisualizationsRailSection.allCases.map { section in
            leaf(
                title: section.title,
                systemImage: section.icon,
                route: .look(section)
            )
        }
        let music = availability.musicSections.map { section in
            leaf(
                title: section.title,
                systemImage: section.icon,
                route: .input(section)
            )
        }
        let performance = PerformanceRailSection.allCases.map { section in
            leaf(
                title: section.rawValue,
                systemImage: section.icon,
                route: .quality(section)
            )
        }

        var utilities = [
            Node(
                id: "utility.animationEditor",
                title: "Animation Editor",
                systemImage: AppIcons.pencilAndListClipboard,
                target: .command(.openAnimationEditor),
                rootPlacement: .utility,
                children: []
            ),
            Node(
                id: "utility.quickToggles",
                title: "Quick Toggles",
                systemImage: "switch.2",
                target: .route(.quickToggles),
                rootPlacement: .utility,
                children: []
            ),
            Node(
                id: "utility.settings",
                title: "Settings",
                systemImage: "gearshape.fill",
                target: .route(.settings(.display)),
                rootPlacement: .utility,
                children: []
            )
        ]
        if availability.includesGestureEditing {
            utilities.insert(
                Node(
                    id: "utility.gestures",
                    title: "Gestures",
                    systemImage: "hand.draw",
                    target: .route(.gestures),
                    rootPlacement: .utility,
                    children: []
                ),
                at: 0
            )
        }

        return NavigationHierarchy(roots: [
            workspace(.explore, children: explore),
            workspace(.input, children: music),
            workspace(.shape, children: shape),
            workspace(.look, children: visualizations),
            workspace(.quality, children: performance)
        ] + utilities)
    }

    static func rootID(for root: WorkspaceRoot) -> String {
        "root.\(root.rawValue)"
    }
}

/// Layout-independent wraparound policy for keyboard and alternate input.
enum NavigationKeyboardTraversal {
    static func nextID(
        from currentID: String?,
        in targets: [NavigationHierarchy.KeyboardTarget],
        backward: Bool
    ) -> String? {
        guard !targets.isEmpty else { return nil }
        guard let currentID,
              let currentIndex = targets.firstIndex(where: { $0.id == currentID }) else {
            return backward ? targets.last?.id : targets.first?.id
        }
        let delta = backward ? -1 : 1
        return targets[(currentIndex + delta + targets.count) % targets.count].id
    }
}
