import Foundation

/// Runtime capabilities that filter the shared application navigation without
/// changing its structure. Platform hosts provide capabilities; presentations
/// never redefine labels, routes, or ordering.
struct NavigationAvailability {
    let allowsCustomScenes: Bool
    let shapeSections: [ShapeRailSection]
    let musicSections: [MusicRailSection]
    let includesGestureEditing: Bool

    /// The capabilities of the current app target. Runtime feature flags remain
    /// explicit inputs while compile-time hardware features are resolved once.
    static func current(
        allowsCustomScenes: Bool,
        includesGestureEditing: Bool
    ) -> NavigationAvailability {
        let shapeSections = ShapeRailSection.allCases.filter { section in
            guard section != .performance else { return false }
            #if os(visionOS)
            return true
            #else
            return section != .hands
            #endif
        }

        return NavigationAvailability(
            allowsCustomScenes: allowsCustomScenes,
            shapeSections: shapeSections,
            musicSections: MusicRailSection.availableCases,
            includesGestureEditing: includesGestureEditing
        )
    }
}

/// The platform-neutral application navigation definition.
///
/// It owns destinations and parent/child relationships only. Grid, radial,
/// keyboard, touch, pointer, and spatial-input presentations all consume this
/// same tree and decide independently how to render or traverse it.
struct NavigationHierarchy {
    enum RootPlacement {
        case workspace
        case utility
    }

    enum Destination {
        case workspace(TopDockTab)
        case explore(ExploreRailSection)
        case shape(ShapeRailSection)
        case visualizations(VisualizationsRailSection)
        case performance(PerformanceRailSection)
        case music(MusicRailSection)
        case animationEditor
        case quickToggles
        case gestures
        case settings
    }

    struct Node: Identifiable {
        let id: String
        let title: String
        let systemImage: String
        let destination: Destination
        let rootPlacement: RootPlacement
        let children: [Node]

        var isBranch: Bool { !children.isEmpty }
    }

    struct KeyboardTarget: Equatable {
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

    func children(ofWorkspace tab: TopDockTab) -> [Node] {
        workspaceRoots.first(where: { node in
            guard case .workspace(let candidate) = node.destination else { return false }
            return candidate == tab
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
            id: String,
            title: String,
            systemImage: String,
            destination: Destination
        ) -> Node {
            Node(
                id: id,
                title: title,
                systemImage: systemImage,
                destination: destination,
                rootPlacement: .workspace,
                children: []
            )
        }

        func workspace(_ tab: TopDockTab, children: [Node]) -> Node {
            Node(
                id: rootID(for: tab),
                title: tab.title,
                systemImage: tab.icon,
                destination: .workspace(tab),
                rootPlacement: .workspace,
                children: children
            )
        }

        let explore = ExploreRailSection.allCases
            .filter { $0 != .customScenes || availability.allowsCustomScenes }
            .map { section in
                leaf(
                    id: "explore.\(section.rawValue)",
                    title: section.rawValue,
                    systemImage: section.icon,
                    destination: .explore(section)
                )
            }
        let shape = availability.shapeSections.map { section in
            leaf(
                id: "shape.\(section.rawValue)",
                title: section.rawValue,
                systemImage: section.icon,
                destination: .shape(section)
            )
        }
        let visualizations = VisualizationsRailSection.visibleCases.map { section in
            leaf(
                id: "visualizations.\(section.rawValue)",
                title: section.title,
                systemImage: section.icon,
                destination: .visualizations(section)
            )
        }
        let music = availability.musicSections.map { section in
            leaf(
                id: "music.\(section.rawValue)",
                title: section.title,
                systemImage: section.icon,
                destination: .music(section)
            )
        }
        let performance = PerformanceRailSection.allCases.map { section in
            leaf(
                id: "performance.\(section.rawValue)",
                title: section.rawValue,
                systemImage: section.icon,
                destination: .performance(section)
            )
        }

        var utilities = [
            Node(
                id: "utility.animationEditor",
                title: "Animation Editor",
                systemImage: AppIcons.pencilAndListClipboard,
                destination: .animationEditor,
                rootPlacement: .utility,
                children: []
            ),
            Node(
                id: "utility.quickToggles",
                title: "Quick Toggles",
                systemImage: SidebarTab.quickToggles.icon,
                destination: .quickToggles,
                rootPlacement: .utility,
                children: []
            ),
            Node(
                id: "utility.settings",
                title: "Settings",
                systemImage: SidebarTab.settings.icon,
                destination: .settings,
                rootPlacement: .utility,
                children: []
            )
        ]
        if availability.includesGestureEditing {
            utilities.insert(
                Node(
                    id: "utility.gestures",
                    title: "Gestures",
                    systemImage: SidebarTab.gestures.icon,
                    destination: .gestures,
                    rootPlacement: .utility,
                    children: []
                ),
                at: 0
            )
        }

        return NavigationHierarchy(roots: [
            workspace(.explore, children: explore),
            workspace(.music, children: music),
            workspace(.shape, children: shape),
            workspace(.visualizations, children: visualizations),
            workspace(.performance, children: performance)
        ] + utilities)
    }

    static func rootID(for tab: TopDockTab) -> String {
        "root.\(tab.rawValue)"
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
