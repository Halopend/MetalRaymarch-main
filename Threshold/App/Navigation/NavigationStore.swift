import Foundation
import Observation

/// Decoder used only by the one-time navigation import. It deliberately does
/// not leak into live UI state.
private enum LegacySidebarSelection: String {
    case fractal = "Fractal"
    case animate = "Video"
    case coloring = "Coloring"
    case effects = "Effects"
    case music = "Music"
    case transition = "Transition"
    case quickToggles = "Quick Toggles"
    case gestures = "Gestures"
    case settings = "Settings"
}

private enum LegacyTopDockTab: String {
    case explore = "Explore"
    case shape = "Shape"
    case visualizations = "Visualizations"
    case music = "Music"
    case performance = "Performance"
}

private enum LegacyFractalSubTab: String {
    case browse = "Browse"
    case shape = "Shape"
    case space = "Space"
    case transform = "Transform"
    case bounding = "Bounding"
    case render = "Render"
}

private enum LegacyShapeInnerTab: String {
    case parameters = "Parameters"
    case formula = "Formula"
    case primitives = "Primitives"
    case hands = "Hands"
}

private enum LegacyColoringSubTab: String {
    case gradient = "Gradient"
    case mapping = "Mapping"
    case grading = "Grading"
}

private enum LegacyEffectsSubTab: String {
    case dynamic = "Dynamic Color"
    case `static` = "Atmosphere"
}

private enum LegacyMusicPanelTab: String {
    case music = "Music"
    case reactive = "Reactive"
    case mappings = "Mappings"
    case presets = "Presets"
    case songs = "Songs"
    case playlists = "Playlists"
    case albums = "Albums"
    case visualizations = "Visualizations"
}

enum WorkspaceRoot: String, CaseIterable, Codable, Hashable, Sendable {
    case explore
    case input
    case shape
    case look
    case quality

    var displayName: String {
        switch self {
        case .explore: return "Explore"
        case .input: return "Input"
        case .shape: return "Shape"
        case .look: return "Look"
        case .quality: return "Quality"
        }
    }

    var systemImage: String {
        switch self {
        case .explore: return "sparkles.rectangle.stack"
        case .input: return "waveform"
        case .shape: return "cube.transparent"
        case .look: return "paintbrush.pointed.fill"
        case .quality: return "speedometer"
        }
    }

    var defaultRoute: AppRoute {
        switch self {
        case .explore: return .explore(.jumpingOff)
        case .input: return .input(.playback)
        case .shape: return .shape(.formula)
        case .look: return .look(.color)
        case .quality: return .quality(.tuning)
        }
    }
}

/// The single semantic destination used by every navigation presentation.
enum AppRoute: Codable, Hashable, Sendable {
    case explore(ExploreRailSection)
    case input(MusicRailSection)
    case shape(ShapeRailSection)
    case look(VisualizationsRailSection)
    case quality(PerformanceRailSection)
    case quickToggles
    case gestures
    case settings(SettingsSubTab)
    case animationLibrary

    var workspaceRoot: WorkspaceRoot? {
        switch self {
        case .explore: return .explore
        case .input: return .input
        case .shape: return .shape
        case .look: return .look
        case .quality: return .quality
        case .quickToggles, .gestures, .settings, .animationLibrary: return nil
        }
    }

    var stableID: String {
        switch self {
        case .explore(let section): return "explore.\(section.rawValue)"
        case .input(let section): return "input.\(section.canonical.rawValue)"
        case .shape(let section): return "shape.\(section.rawValue)"
        case .look(let section): return "look.\(section.rawValue)"
        case .quality(let section): return "quality.\(section.rawValue)"
        case .quickToggles: return "utility.quickToggles"
        case .gestures: return "utility.gestures"
        case .settings(let section): return "settings.\(section.rawValue)"
        case .animationLibrary: return "utility.animationLibrary"
        }
    }

    var isPinnable: Bool { workspaceRoot != nil }

    var title: String {
        switch self {
        case .explore(let section): return section.rawValue
        case .input(let section): return section.canonical.title
        case .shape(let section): return section == .performance ? "Tuning" : section.rawValue
        case .look(let section): return section.title
        case .quality(let section): return section.rawValue
        case .quickToggles: return "Quick Toggles"
        case .gestures: return "Gestures"
        case .settings(let section): return section.rawValue
        case .animationLibrary: return "Animation Library"
        }
    }

    var systemImage: String {
        switch self {
        case .explore(let section): return section.icon
        case .input(let section): return section.canonical.icon
        case .shape(let section): return section.icon
        case .look(let section): return section.icon
        case .quality(let section): return section.icon
        case .quickToggles: return "switch.2"
        case .gestures: return "hand.draw"
        case .settings(let section): return section.icon
        case .animationLibrary: return AppIcons.pencilAndListClipboard
        }
    }

    static let allWorkspaceRoutes: [AppRoute] =
        ExploreRailSection.allCases.map(AppRoute.explore)
        + MusicRailSection.allCases.map(AppRoute.input)
        + ShapeRailSection.allCases.map(AppRoute.shape)
        + VisualizationsRailSection.allCases.map(AppRoute.look)
        + PerformanceRailSection.allCases.map(AppRoute.quality)

    static func route(withStableID id: String) -> AppRoute? {
        allWorkspaceRoutes.first { $0.stableID == id }
            ?? (id == "shape.Parameters" ? .shape(.parameters) : nil)
    }
}

enum AppCommand: Hashable, Sendable {
    case openAnimationEditor
    case toggleRadialMenu
    case dismissRadialMenu
    case resetViewport
    case toggleAnimationPlayback
    case selectRoute(AppRoute)
}

enum AppNavigationTarget: Hashable, Sendable {
    case workspace(WorkspaceRoot)
    case route(AppRoute)
    case command(AppCommand)

    var stableID: String {
        switch self {
        case .workspace(let root): return "root.\(root.rawValue)"
        case .route(let route): return route.stableID
        case .command(.openAnimationEditor): return "workflow.animation-editor"
        case .command(.toggleRadialMenu): return "command.toggle-radial-menu"
        case .command(.dismissRadialMenu): return "command.dismiss-radial-menu"
        case .command(.resetViewport): return "command.reset-viewport"
        case .command(.toggleAnimationPlayback): return "command.toggle-animation-playback"
        case .command(.selectRoute(let route)): return "command.select-route.\(route.stableID)"
        }
    }
}

struct NavigationState: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version: Int
    var currentRoute: AppRoute
    var lastRouteByWorkspace: [String: AppRoute]
    var returnRoute: AppRoute?
    var pinnedRouteIDs: [String]

    init(
        version: Int = currentVersion,
        currentRoute: AppRoute = .explore(.jumpingOff),
        lastRouteByWorkspace: [String: AppRoute] = [:],
        returnRoute: AppRoute? = nil,
        pinnedRouteIDs: [String] = []
    ) {
        self.version = version
        self.currentRoute = currentRoute
        self.lastRouteByWorkspace = lastRouteByWorkspace
        self.returnRoute = returnRoute
        self.pinnedRouteIDs = pinnedRouteIDs
    }

    func lastRoute(for root: WorkspaceRoot) -> AppRoute? {
        lastRouteByWorkspace[root.rawValue]
    }

    mutating func setLastRoute(_ route: AppRoute, for root: WorkspaceRoot) {
        lastRouteByWorkspace[root.rawValue] = route
    }
}

enum NavigationAction: Hashable, Sendable {
    case select(AppRoute)
    case selectRoot(WorkspaceRoot)
    case returnToWorkspace
    case togglePin(AppRoute)
    case clearPins
}

/// App-owned reducer and persistence boundary for all navigation presentations.
@MainActor
@Observable
final class NavigationStore {
    static let snapshotKey = "Navigation.state.v1"

    private(set) var state: NavigationState

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let profile: PlatformProfile
    @ObservationIgnored private let allowsCustomScenes: Bool
    @ObservationIgnored private let encoder = JSONEncoder()
    @ObservationIgnored private let decoder = JSONDecoder()

    var currentRoute: AppRoute { state.currentRoute }
    var pinnedRouteIDs: [String] { state.pinnedRouteIDs }

    init(
        profile: PlatformProfile,
        defaults: UserDefaults = .standard,
        allowsCustomScenes: Bool? = nil
    ) {
        self.defaults = defaults
        self.profile = profile
        self.allowsCustomScenes = allowsCustomScenes ?? true

        if let data = defaults.data(forKey: Self.snapshotKey),
           let decoded = try? decoder.decode(NavigationState.self, from: data),
           decoded.version == NavigationState.currentVersion {
            state = Self.canonicalized(decoded, profile: profile, allowsCustomScenes: self.allowsCustomScenes)
            persist()
        } else {
            state = Self.importLegacyState(
                defaults: defaults,
                profile: profile,
                allowsCustomScenes: self.allowsCustomScenes
            )
            persistAndRemoveLegacyKeysAfterVerification()
        }
    }

    func dispatch(_ action: NavigationAction) {
        switch action {
        case .select(let route):
            select(route)
        case .selectRoot(let root):
            let remembered = state.lastRoute(for: root) ?? root.defaultRoute
            select(remembered)
        case .returnToWorkspace:
            guard let route = state.returnRoute else { return }
            select(route)
        case .togglePin(let route):
            let route = canonical(route)
            guard route.isPinnable else { return }
            if let index = state.pinnedRouteIDs.firstIndex(of: route.stableID) {
                state.pinnedRouteIDs.remove(at: index)
            } else {
                state.pinnedRouteIDs.append(route.stableID)
            }
            persist()
        case .clearPins:
            state.pinnedRouteIDs.removeAll(keepingCapacity: true)
            persist()
        }
    }

    func select(_ proposedRoute: AppRoute) {
        let route = canonical(proposedRoute)
        if let root = route.workspaceRoot {
            state.currentRoute = route
            state.returnRoute = route
            state.setLastRoute(route, for: root)
        } else {
            if let currentRoot = state.currentRoute.workspaceRoot {
                state.returnRoute = state.currentRoute
                state.setLastRoute(state.currentRoute, for: currentRoot)
            }
            state.currentRoute = route
        }
        persist()
    }

    func selectRoot(_ root: WorkspaceRoot) {
        dispatch(.selectRoot(root))
    }

    /// Shared activation seam for flat, radial, spatial, Finder, intent, and
    /// gesture sources. Commands are returned to the platform host; routes are
    /// reduced and persisted here.
    @discardableResult
    func activate(_ target: AppNavigationTarget) -> AppCommand? {
        switch target {
        case .workspace(let root):
            selectRoot(root)
            return nil
        case .route(let route):
            select(route)
            return nil
        case .command(.selectRoute(let route)):
            select(route)
            return nil
        case .command(let command):
            return command
        }
    }

    func isPinned(_ route: AppRoute) -> Bool {
        state.pinnedRouteIDs.contains(canonical(route).stableID)
    }

    func lastRoute(for root: WorkspaceRoot) -> AppRoute {
        canonical(state.lastRoute(for: root) ?? root.defaultRoute)
    }

    func canonical(_ route: AppRoute) -> AppRoute {
        Self.canonical(route, profile: profile, allowsCustomScenes: allowsCustomScenes)
    }

    private func persist() {
        guard let data = try? encoder.encode(state) else { return }
        defaults.set(data, forKey: Self.snapshotKey)
    }

    private func persistAndRemoveLegacyKeysAfterVerification() {
        guard let data = try? encoder.encode(state) else { return }
        defaults.set(data, forKey: Self.snapshotKey)
        guard defaults.data(forKey: Self.snapshotKey) == data,
              let verified = try? decoder.decode(NavigationState.self, from: data),
              verified == state else { return }
        Self.legacyKeys.forEach(defaults.removeObject(forKey:))
    }

    private static func canonicalized(
        _ decoded: NavigationState,
        profile: PlatformProfile,
        allowsCustomScenes: Bool
    ) -> NavigationState {
        var result = decoded
        result.version = NavigationState.currentVersion
        result.currentRoute = canonical(decoded.currentRoute, profile: profile, allowsCustomScenes: allowsCustomScenes)
        result.returnRoute = decoded.returnRoute.map {
            canonical($0, profile: profile, allowsCustomScenes: allowsCustomScenes)
        }
        result.lastRouteByWorkspace = Dictionary(uniqueKeysWithValues: WorkspaceRoot.allCases.map { root in
            let route = decoded.lastRoute(for: root) ?? root.defaultRoute
            return (root.rawValue, canonical(route, profile: profile, allowsCustomScenes: allowsCustomScenes))
        })
        var seen = Set<String>()
        result.pinnedRouteIDs = decoded.pinnedRouteIDs.compactMap { id in
            guard let route = AppRoute.route(withStableID: id) else { return nil }
            let canonicalID = canonical(route, profile: profile, allowsCustomScenes: allowsCustomScenes).stableID
            return seen.insert(canonicalID).inserted ? canonicalID : nil
        }
        return result
    }

    private static func canonical(
        _ route: AppRoute,
        profile: PlatformProfile,
        allowsCustomScenes: Bool
    ) -> AppRoute {
        switch route {
        case .explore(.customScenes) where !allowsCustomScenes:
            return .explore(.jumpingOff)
        case .shape(.parameters):
            return .input(.parameters)
        case .shape(.hands) where !profile.supports(.handTracking):
            return .shape(.formula)
        case .shape(.performance):
            return .quality(.tuning)
        case .look(.reactive):
            return .input(.reactive)
        case .input(let section):
            let canonical = section.canonical
            if [.songs, .playlists, .albums].contains(canonical),
               !profile.supports(.musicLibraryBrowsing) {
                return .input(.playback)
            }
            return .input(canonical)
        case .gestures where !profile.supports(.gestureEditing):
            return .settings(.display)
        case .settings(.gestures):
            return profile.supports(.gestureEditing) ? .gestures : .settings(.display)
        default:
            return route
        }
    }

    private static func importLegacyState(
        defaults: UserDefaults,
        profile: PlatformProfile,
        allowsCustomScenes: Bool
    ) -> NavigationState {
        func value<E: RawRepresentable>(_ key: String, as: E.Type) -> E? where E.RawValue == String {
            guard let raw = defaults.string(forKey: key) else { return nil }
            return E(rawValue: raw)
        }

        let explore = value("ContentView.exploreRailSection", as: ExploreRailSection.self) ?? .jumpingOff
        let shape = value("ContentView.shapeRailSection", as: ShapeRailSection.self) ?? .formula
        let look = value("ContentView.visualizationsRailSection", as: VisualizationsRailSection.self) ?? .color
        let input = (value("ContentView.musicRailSection", as: MusicRailSection.self) ?? .playback).canonical
        let quality = value("ContentView.performanceRailSection.v3", as: PerformanceRailSection.self) ?? .tuning

        var state = NavigationState(lastRouteByWorkspace: [
            WorkspaceRoot.explore.rawValue: .explore(explore),
            WorkspaceRoot.input.rawValue: .input(input),
            WorkspaceRoot.shape.rawValue: .shape(shape),
            WorkspaceRoot.look.rawValue: .look(look),
            WorkspaceRoot.quality.rawValue: .quality(quality)
        ])

        let preciseRoute: AppRoute? = {
            guard let tab = value("ContentView.selectedTab", as: LegacySidebarSelection.self) else { return nil }
            switch tab {
            case .fractal:
                let sub = value("ContentView.fractalSubTab", as: LegacyFractalSubTab.self) ?? .shape
                switch sub {
                case .browse:
                    let browse = value("FractalGridView.innerTab", as: FractalBrowseTab.self) ?? .jumpingOff
                    return .explore(ExploreRailSection.allCases.first { $0.browseTab == browse } ?? .jumpingOff)
                case .shape:
                    switch value("ContentView.shapeInnerTab", as: LegacyShapeInnerTab.self) ?? .parameters {
                    case .parameters: return .input(.parameters)
                    case .formula: return .shape(.formula)
                    case .primitives: return .shape(.primitives)
                    case .hands: return .shape(.hands)
                    }
                case .space: return .shape(.space)
                case .transform: return .shape(.transformations)
                case .bounding: return .shape(.bounding)
                case .render: return .quality(.tuning)
                }
            case .animate: return .animationLibrary
            case .coloring:
                switch value("ContentView.coloringSubTab", as: LegacyColoringSubTab.self) ?? .gradient {
                case .gradient: return .look(.color)
                case .mapping: return .look(.mapping)
                case .grading: return .look(.grading)
                }
            case .effects:
                return value("ContentView.effectsSubTab", as: LegacyEffectsSubTab.self) == .static
                    ? .look(.atmosphere) : .look(.motion)
            case .music:
                let panel = value("MusicTabContent.innerTab", as: LegacyMusicPanelTab.self) ?? .music
                switch panel {
                case .music: return .input(.playback)
                case .songs: return .input(.songs)
                case .playlists: return .input(.playlists)
                case .albums: return .input(.albums)
                case .reactive, .mappings, .presets, .visualizations: return .input(.reactive)
                }
            case .transition: return .look(.transition)
            case .quickToggles: return .quickToggles
            case .gestures: return .gestures
            case .settings:
                return .settings(value("ContentView.settingsSubTab", as: SettingsSubTab.self) ?? .display)
            }
        }()

        let fallbackRoute: AppRoute = {
            let tab = value("ContentView.topDockTab", as: LegacyTopDockTab.self) ?? .explore
            switch tab {
            case .explore: return .explore(explore)
            case .shape: return .shape(shape)
            case .visualizations: return .look(look)
            case .music: return .input(input)
            case .performance: return .quality(quality)
            }
        }()

        state.currentRoute = preciseRoute ?? fallbackRoute
        if let root = state.currentRoute.workspaceRoot {
            state.returnRoute = state.currentRoute
            state.setLastRoute(state.currentRoute, for: root)
        } else {
            let fallback = canonical(fallbackRoute, profile: profile, allowsCustomScenes: allowsCustomScenes)
            state.returnRoute = fallback
            if let root = fallback.workspaceRoot { state.setLastRoute(fallback, for: root) }
        }

        let pins = (defaults.string(forKey: "ContentView.pinnedRailControls") ?? "")
            .split(separator: ",")
            .compactMap { legacyPinnedRoute(String($0)) }
        state.pinnedRouteIDs = pins.map(\.stableID)
        return canonicalized(state, profile: profile, allowsCustomScenes: allowsCustomScenes)
    }

    private static func legacyPinnedRoute(_ raw: String) -> AppRoute? {
        switch raw {
        case "exploreJumpingOff": return .explore(.jumpingOff)
        case "exploreMusicReactive": return .explore(.musicReactive)
        case "exploreAnimated": return .explore(.animated)
        case "exploreMixed": return .explore(.mixed)
        case "exploreCustomScenes": return .explore(.customScenes)
        case "shapeParameters": return .input(.parameters)
        case "shapeFormula": return .shape(.formula)
        case "shapePrimitives": return .shape(.primitives)
        case "shapeHands": return .shape(.hands)
        case "shapeSpace": return .shape(.space)
        case "shapeTransformations": return .shape(.transformations)
        case "shapeBounding": return .shape(.bounding)
        case "shapePerformance": return .quality(.tuning)
        case "visualizationsColor": return .look(.color)
        case "visualizationsMapping": return .look(.mapping)
        case "visualizationsGrading": return .look(.grading)
        case "visualizationsMotion": return .look(.motion)
        case "visualizationsAtmosphere": return .look(.atmosphere)
        case "visualizationsTransition": return .look(.transition)
        case "visualizationsReactive", "musicReactive", "musicMappings", "musicPresets": return .input(.reactive)
        case "musicPlayback": return .input(.playback)
        case "musicSongs": return .input(.songs)
        case "musicPlaylists": return .input(.playlists)
        case "musicAlbums": return .input(.albums)
        default: return nil
        }
    }

    private static let legacyKeys = [
        "ContentView.topDockTab",
        "ContentView.exploreRailSection",
        "ContentView.shapeRailSection",
        "ContentView.visualizationsRailSection",
        "ContentView.musicRailSection",
        "ContentView.performanceRailSection.v3",
        "ContentView.skipOuterNavigationSync",
        "ContentView.selectedTab",
        "FractalGridView.innerTab",
        "ContentView.fractalSubTab",
        "ContentView.shapeInnerTab",
        "ContentView.coloringSubTab",
        "ContentView.effectsSubTab",
        "MusicTabContent.innerTab",
        "ContentView.settingsSubTab",
        "ContentView.pinnedRailControls"
    ]
}
