//
//  ControlFinderView.swift
//  Threshold
//
//  Searchable command-palette style navigation for every user-facing control
//  destination. The catalog is deliberately UI-independent: ContentView owns
//  the actual route mutation and receives typed metadata through `onSelect`.
//

import SwiftUI

// MARK: - Destination model

enum ControlFinderPlatform: String, CaseIterable, Identifiable, Sendable {
    case macOS
    case iOS
    case visionOS

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .macOS: return "macOS"
        case .iOS: return "iPadOS"
        case .visionOS: return "visionOS"
        }
    }

    static var current: ControlFinderPlatform {
        #if os(macOS)
        return .macOS
        #elseif os(visionOS)
        return .visionOS
        #else
        return .iOS
        #endif
    }
}

struct ControlFinderPlatformAvailability: OptionSet, Sendable {
    let rawValue: UInt8

    static let macOS = Self(rawValue: 1 << 0)
    static let iOS = Self(rawValue: 1 << 1)
    static let visionOS = Self(rawValue: 1 << 2)

    static let all: Self = [.macOS, .iOS, .visionOS]
    static let iOSAndVisionOS: Self = [.iOS, .visionOS]
    static let visionOSOnly: Self = [.visionOS]

    func contains(_ platform: ControlFinderPlatform) -> Bool {
        let flag: Self
        switch platform {
        case .macOS: flag = .macOS
        case .iOS: flag = .iOS
        case .visionOS: flag = .visionOS
        }
        return !intersection(flag).isEmpty
    }

    var platforms: [ControlFinderPlatform] {
        ControlFinderPlatform.allCases.filter(contains)
    }

    var shortLabel: String? {
        guard self != .all else { return nil }
        return platforms.map(\.displayName).joined(separator: " · ")
    }

    var accessibilityDescription: String {
        if self == .all { return "Available on every platform" }
        return "Available on \(platforms.map(\.displayName).joined(separator: ", "))"
    }
}

enum ControlFinderCategory: String, CaseIterable, Identifiable, Sendable {
    case explore = "Explore"
    case shape = "Shape"
    case visualizations = "Look"
    case performance = "Quality"
    case music = "Input"
    case settings = "Settings"
    case workflow = "Workflow"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .explore: return TopDockTab.explore.icon
        case .shape: return TopDockTab.shape.icon
        case .visualizations: return TopDockTab.visualizations.icon
        case .performance: return TopDockTab.performance.icon
        case .music: return TopDockTab.music.icon
        case .settings: return SidebarTab.settings.icon
        case .workflow: return "arrow.triangle.branch"
        }
    }
}

/// Typed hand-off from the finder to ContentView. Keeping route mutation out of
/// this file makes the catalog deterministic and straightforward to test.
enum ControlFinderRouteMetadata {
    case explore(ExploreRailSection)
    case shape(ShapeRailSection)
    case visualizations(VisualizationsRailSection)
    case performance(PerformanceRailSection)
    case music(MusicRailSection)
    case settings(SettingsSubTab)
    case sidebar(SidebarTab)
    case animationEditor

    var stableID: String {
        switch self {
        case .explore(let section): return "explore.\(section.rawValue)"
        case .shape(let section): return "shape.\(section.rawValue)"
        case .visualizations(let section): return "visualizations.\(section.rawValue)"
        case .performance(let section): return "performance.\(section.rawValue)"
        case .music(let section): return "music.\(section.rawValue)"
        case .settings(let section): return "settings.\(section.rawValue)"
        case .sidebar(let tab): return "sidebar.\(tab.rawValue)"
        case .animationEditor: return "workflow.animation-editor"
        }
    }
}

struct ControlFinderDestination: Identifiable {
    let id: String
    let title: String
    let category: ControlFinderCategory
    let pathComponents: [String]
    let description: String
    let icon: String
    let searchKeywords: [String]
    let availability: ControlFinderPlatformAvailability
    let route: ControlFinderRouteMetadata?

    var path: String { pathComponents.joined(separator: " › ") }

    init(
        id: String? = nil,
        title: String,
        category: ControlFinderCategory,
        pathComponents: [String],
        description: String,
        icon: String,
        searchKeywords: [String] = [],
        availability: ControlFinderPlatformAvailability = .all,
        route: ControlFinderRouteMetadata? = nil
    ) {
        self.id = id ?? route?.stableID ?? "\(category.rawValue).\(title)"
        self.title = title
        self.category = category
        self.pathComponents = pathComponents
        self.description = description
        self.icon = icon
        self.searchKeywords = searchKeywords
        self.availability = availability
        self.route = route
    }

    func isAvailable(on platform: ControlFinderPlatform) -> Bool {
        availability.contains(platform)
    }

    // MARK: Catalog

    static let catalog: [ControlFinderDestination] = [
        // Explore
        destination(
            ExploreRailSection.jumpingOff,
            description: "Browse curated static starting scenes and saved presets.",
            keywords: ["start", "starter", "scene", "preset", "gallery", "browse"]
        ),
        destination(
            ExploreRailSection.musicReactive,
            description: "Open scenes with audio-reactive parameter mappings already configured.",
            keywords: ["audio", "reactive", "beat", "sound", "music preset"]
        ),
        destination(
            ExploreRailSection.animated,
            description: "Browse and play keyframed animated scenes.",
            keywords: ["animation", "video", "motion", "keyframe", "play"]
        ),
        destination(
            ExploreRailSection.mixed,
            description: "Browse scenes authored to blend with passthrough and your room.",
            keywords: ["mixed reality", "passthrough", "room", "surroundings", "spatial"]
        ),
        destination(
            ExploreRailSection.customScenes,
            description: "Browse imported scenes that carry custom formulas or shader effects.",
            keywords: ["custom", "import", "shader", "formula", "threshfx", "external"]
        ),

        // Shape
        destination(
            ShapeRailSection.parameters,
            description: "Adjust the active fractal's primary shape parameters.",
            keywords: ["slider", "sculpt", "fold", "scale", "radius", "iterations"]
        ),
        destination(
            ShapeRailSection.formula,
            description: "Choose the distance-estimator formula that defines the fractal.",
            keywords: ["fractal type", "distance estimator", "mandelbox", "mandelbulb", "menger", "julia"]
        ),
        destination(
            ShapeRailSection.hands,
            description: "Shape the fractal around tracked hands and forearms.",
            keywords: ["hand attraction", "tracking", "palm", "forearm", "pocket", "arkit"],
            availability: .visionOSOnly
        ),
        destination(
            ShapeRailSection.space,
            description: "Tune safety, placement, zoom, orientation, and spatial detail.",
            keywords: ["safety bubble", "platform", "zoom", "rotation", "detail", "space"]
        ),
        destination(
            ShapeRailSection.transformations,
            description: "Build a stack of domain warps and spatial transformations.",
            keywords: ["transform", "warp", "sphere projection", "inversion", "twist", "fold stack"]
        ),
        destination(
            ShapeRailSection.bounding,
            description: "Control bounding shapes and how the fractal conforms to its surroundings.",
            keywords: ["containment", "bound", "sphere", "scrunch", "shell", "environment", "room"]
        ),

        // Visualizations
        destination(
            VisualizationsRailSection.color,
            description: "Choose, save, and edit gradient colors.",
            keywords: ["gradient", "palette", "colour", "color stops", "preset"]
        ),
        destination(
            VisualizationsRailSection.mapping,
            description: "Choose how fractal distance and orbit data map into the gradient.",
            keywords: ["mapping mode", "orbit trap", "distance", "color mix", "offset"]
        ),
        destination(
            VisualizationsRailSection.grading,
            description: "Apply scene-level grading, tonemapping, shading, and output-space edge detection.",
            keywords: ["post processing", "grade", "contrast", "saturation", "gamma", "vibrance", "shadows", "highlights", "toon", "edge", "outline", "contour"]
        ),
        destination(
            VisualizationsRailSection.motion,
            description: "Animate color with cycling, pulse, hue, rail, and formula-specific effects.",
            keywords: ["dynamic color", "cycling", "hue rotation", "pulse", "gradient cycle", "linear rail"]
        ),
        destination(
            VisualizationsRailSection.atmosphere,
            description: "Shape the scene's glow, bloom, fog, and atmospheric lighting.",
            keywords: ["static effects", "glow", "bloom", "fog", "lighting", "atmosphere"]
        ),
        destination(
            VisualizationsRailSection.transition,
            description: "Set scene-change timing and interpolation behavior.",
            keywords: ["transition", "duration", "crossfade", "interpolation", "scene change"]
        ),
        // Performance
        destination(
            PerformanceRailSection.overview,
            description: "Inspect live FPS, GPU timing, render quality, and frame pacing.",
            keywords: ["metrics", "fps", "gpu", "hitch", "diagnostics", "resolution", "benchmark"]
        ),
        destination(
            PerformanceRailSection.tuning,
            description: "Balance renderer mode, iteration budget, resolution, and acceleration.",
            keywords: ["quality", "performance", "renderer", "iterations", "ray steps", "metalfx", "adaptive compute", "speed"]
        ),

        // Music
        destination(
            MusicRailSection.playback,
            description: "Choose microphone, system audio, or music playback and monitor the live signal.",
            keywords: ["music app", "now playing", "microphone", "system audio", "transport", "visualizer"]
        ),
        destination(
            MusicRailSection.reactive,
            description: "Turn audio response on and tune amount, beat punch, damping, and sensitivity.",
            keywords: ["audio reactive", "react to audio", "visualizer", "bass", "mid", "treble", "beat", "drop"]
        ),
        destination(
            MusicRailSection.mappings,
            description: "Map live audio bands and beats to shape, transform, color, lighting, and motion parameters.",
            keywords: ["audio mapping", "modulation", "target", "curve", "smoothing", "intensity"]
        ),
        destination(
            MusicRailSection.presets,
            description: "Load and save reusable audio-reactive configurations.",
            keywords: ["audio preset", "reactivity preset", "electronic", "ambient", "hip hop"]
        ),
        destination(
            MusicRailSection.songs,
            description: "Search the connected music library and play a song.",
            keywords: ["track", "library", "apple music", "search", "play"],
            availability: .iOSAndVisionOS
        ),
        destination(
            MusicRailSection.playlists,
            description: "Browse and play playlists from the connected music service.",
            keywords: ["playlist", "library", "shuffle", "apple music"],
            availability: .iOSAndVisionOS
        ),
        destination(
            MusicRailSection.albums,
            description: "Browse and play albums from the connected music service.",
            keywords: ["album", "artist", "library", "apple music"],
            availability: .iOSAndVisionOS
        ),

        // Settings
        settingsDestination(
            .display,
            description: "Configure handedness, text, touch feedback, the platform, and display experiments.",
            keywords: ["appearance", "handedness", "text size", "touch indicators", "launcher", "custom scenes"]
        ),
        settingsDestination(
            .sharing,
            description: "Choose local or iCloud storage and control community data sharing.",
            keywords: ["storage", "icloud", "sync", "privacy", "analytics", "community", "display name"]
        ),
        settingsDestination(
            .export,
            description: "Export the current setup, saved presets, formulas, and animations.",
            keywords: ["share", "file", "scene", "preset", "animation", "threshscene", "threshfx"]
        ),
        settingsDestination(
            .advanced,
            description: "Open render diagnostics, experimental acceleration, and benchmark tools.",
            keywords: ["developer", "diagnostics", "raymarcher", "benchmark", "foveation", "smart advance", "advanced"]
        ),
        ControlFinderDestination(
            title: "Gesture Controls",
            category: .settings,
            pathComponents: ["Settings", "Gestures"],
            description: "Assign menu and per-finger gestures for hands-free control.",
            icon: SidebarTab.gestures.icon,
            searchKeywords: ["gesture", "hands", "finger", "tap", "pinch", "menu", "shortcut"],
            availability: .visionOSOnly,
            route: .sidebar(.gestures)
        ),

        // Workflow shortcuts
        ControlFinderDestination(
            title: "Quick Toggles",
            category: .workflow,
            pathComponents: ["Workflow", "Quick Toggles"],
            description: "See important feature switches together in one scannable grid.",
            icon: SidebarTab.quickToggles.icon,
            searchKeywords: ["switch", "enable", "disable", "effects", "space", "audio", "performance"],
            route: .sidebar(.quickToggles)
        ),
        ControlFinderDestination(
            title: "Animation Editor",
            category: .workflow,
            pathComponents: ["Workflow", "Animation Editor"],
            description: "Create scenes, capture keyframes, adjust timing, and preview animation.",
            icon: "pencil.and.list.clipboard",
            searchKeywords: ["scene editor", "animation", "video", "keyframe", "timeline", "capture", "record"],
            route: .animationEditor
        )
    ]

    static func results(
        matching query: String,
        on platform: ControlFinderPlatform = .current,
        includeUnavailable: Bool = false
    ) -> [ControlFinderDestination] {
        let eligible = catalog.filter { includeUnavailable || $0.isAvailable(on: platform) }
        let tokens = searchTokens(in: query)
        guard !tokens.isEmpty else { return eligible }

        let catalogOrder = Dictionary(uniqueKeysWithValues: catalog.enumerated().map { ($1.id, $0) })
        return eligible
            .compactMap { destination -> (ControlFinderDestination, Int)? in
                guard let score = destination.searchScore(for: tokens) else { return nil }
                return (destination, score)
            }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
                return (catalogOrder[lhs.0.id] ?? .max) < (catalogOrder[rhs.0.id] ?? .max)
            }
            .map(\.0)
    }

    private func searchScore(for tokens: [String]) -> Int? {
        let titleText = Self.normalizedSearchText(title)
        let pathText = Self.normalizedSearchText(path)
        let descriptionText = Self.normalizedSearchText(description)
        let keywordTexts = searchKeywords.map(Self.normalizedSearchText)

        var total = 0
        for token in tokens {
            let score: Int
            if titleText == token {
                score = 0
            } else if titleText.hasPrefix(token) {
                score = 1
            } else if titleText.contains(token) {
                score = 3
            } else if pathText.contains(token) {
                score = 5
            } else if keywordTexts.contains(token) {
                score = 6
            } else if keywordTexts.contains(where: { $0.contains(token) }) {
                score = 7
            } else if descriptionText.contains(token) {
                score = 9
            } else {
                return nil
            }
            total += score
        }
        return total
    }

    private static func searchTokens(in text: String) -> [String] {
        normalizedSearchText(text)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private static func normalizedSearchText(_ text: String) -> String {
        text
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
    }

    private static func destination(
        _ section: ExploreRailSection,
        description: String,
        keywords: [String],
        availability: ControlFinderPlatformAvailability = .all
    ) -> ControlFinderDestination {
        ControlFinderDestination(
            title: section.rawValue,
            category: .explore,
            pathComponents: [TopDockTab.explore.rawValue, section.rawValue],
            description: description,
            icon: section.icon,
            searchKeywords: keywords,
            availability: availability,
            route: .explore(section)
        )
    }

    private static func destination(
        _ section: ShapeRailSection,
        description: String,
        keywords: [String],
        availability: ControlFinderPlatformAvailability = .all
    ) -> ControlFinderDestination {
        ControlFinderDestination(
            title: section.rawValue,
            category: .shape,
            pathComponents: [TopDockTab.shape.rawValue, section.rawValue],
            description: description,
            icon: section.icon,
            searchKeywords: keywords,
            availability: availability,
            route: .shape(section)
        )
    }

    private static func destination(
        _ section: VisualizationsRailSection,
        description: String,
        keywords: [String],
        availability: ControlFinderPlatformAvailability = .all
    ) -> ControlFinderDestination {
        ControlFinderDestination(
            title: section.title,
            category: .visualizations,
            pathComponents: [TopDockTab.visualizations.title, section.title],
            description: description,
            icon: section.icon,
            searchKeywords: keywords,
            availability: availability,
            route: .visualizations(section)
        )
    }

    private static func destination(
        _ section: PerformanceRailSection,
        description: String,
        keywords: [String],
        availability: ControlFinderPlatformAvailability = .all
    ) -> ControlFinderDestination {
        ControlFinderDestination(
            title: section.rawValue,
            category: .performance,
            pathComponents: [TopDockTab.performance.title, section.rawValue],
            description: description,
            icon: section.icon,
            searchKeywords: keywords,
            availability: availability,
            route: .performance(section)
        )
    }

    private static func destination(
        _ section: MusicRailSection,
        description: String,
        keywords: [String],
        availability: ControlFinderPlatformAvailability = .all
    ) -> ControlFinderDestination {
        ControlFinderDestination(
            title: section.title,
            category: .music,
            pathComponents: [TopDockTab.music.title, section.title],
            description: description,
            icon: section.icon,
            searchKeywords: keywords,
            availability: availability,
            route: .music(section)
        )
    }

    private static func settingsDestination(
        _ section: SettingsSubTab,
        description: String,
        keywords: [String],
        availability: ControlFinderPlatformAvailability = .all
    ) -> ControlFinderDestination {
        ControlFinderDestination(
            title: section.rawValue,
            category: .settings,
            pathComponents: [SidebarTab.settings.rawValue, section.rawValue],
            description: description,
            icon: section.icon,
            searchKeywords: keywords,
            availability: availability,
            route: .settings(section)
        )
    }
}

// MARK: - Search view

struct ControlFinderView: View {
    let platform: ControlFinderPlatform
    let onSelect: (ControlFinderDestination) -> Void
    let onDismiss: () -> Void

    @State private var query = ""
    @State private var highlightedDestinationID: String?
    @FocusState private var focusTarget: FocusTarget?

    private enum FocusTarget: Hashable {
        case search
        case destination(String)
    }

    init(
        platform: ControlFinderPlatform = .current,
        onSelect: @escaping (ControlFinderDestination) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.platform = platform
        self.onSelect = onSelect
        self.onDismiss = onDismiss
    }

    private var results: [ControlFinderDestination] {
        ControlFinderDestination.results(matching: query, on: platform)
    }

    private var resultIDs: [String] { results.map(\.id) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            searchField
            Divider()
            resultsPane
            Divider()
            footer
        }
        .background(.regularMaterial)
        #if os(macOS)
        .frame(minWidth: 620, idealWidth: 700, minHeight: 520, idealHeight: 680)
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
        .onAppear {
            highlightedDestinationID = results.first?.id
            Task { @MainActor in focusTarget = .search }
        }
        .onChange(of: resultIDs) { _, ids in
            if let highlightedDestinationID, ids.contains(highlightedDestinationID) {
                return
            }
            highlightedDestinationID = ids.first
        }
        #if os(macOS)
        .onMoveCommand(perform: handleMoveCommand)
        #endif
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "scope")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.blue)
                .frame(width: 34, height: 34)
                .background(Color.blue.opacity(0.14), in: RoundedRectangle(cornerRadius: 9))

            VStack(alignment: .leading, spacing: 2) {
                Text("Find a Control")
                    .font(.headline)
                Text("Jump directly to any Threshold feature or setting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 30, height: 30)
                    .background(Color.secondary.opacity(0.10), in: Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Close Control Finder")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search controls, features, and settings", text: $query)
                .textFieldStyle(.plain)
                .focused($focusTarget, equals: .search)
                .submitLabel(.go)
                .onSubmit(activateHighlightedDestination)
                .accessibilityLabel("Search controls")
                .accessibilityHint("Type a feature name, setting, or related keyword")

            if !query.isEmpty {
                Button {
                    query = ""
                    focusTarget = .search
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(focusTarget == .search ? Color.blue.opacity(0.55) : Color.secondary.opacity(0.15), lineWidth: 1)
        )
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var resultsPane: some View {
        if results.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("No controls found")
                    .font(.headline)
                Text("Try a feature name such as “fog,” “gesture,” “FPS,” or “export.”")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Clear Search") {
                    query = ""
                    focusTarget = .search
                }
                .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(32)
            .accessibilityElement(children: .combine)
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(ControlFinderCategory.allCases) { category in
                            let categoryResults = results.filter { $0.category == category }
                            if !categoryResults.isEmpty {
                                resultSection(category, destinations: categoryResults)
                            }
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                }
                .onChange(of: highlightedDestinationID) { _, destinationID in
                    guard let destinationID else { return }
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(destinationID, anchor: .center)
                    }
                }
            }
        }
    }

    private func resultSection(
        _ category: ControlFinderCategory,
        destinations: [ControlFinderDestination]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: category.icon)
                    .font(.caption.weight(.semibold))
                Text(category.rawValue)
                    .font(.caption.weight(.bold))
                Text("\(destinations.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(category.rawValue), \(destinations.count) results")

            VStack(spacing: 6) {
                ForEach(destinations) { destination in
                    destinationRow(destination)
                }
            }
        }
    }

    private func destinationRow(_ destination: ControlFinderDestination) -> some View {
        let isHighlighted = highlightedDestinationID == destination.id
        return Button {
            select(destination)
        } label: {
            ControlFinderDestinationRowLabel(
                destination: destination,
                isHighlighted: isHighlighted
            )
        }
        .buttonStyle(.plain)
        .focused($focusTarget, equals: .destination(destination.id))
        .id(destination.id)
        #if os(macOS) || os(visionOS)
        .onHover { hovering in
            if hovering { highlightedDestinationID = destination.id }
        }
        #endif
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(destination.title), \(destination.path). \(destination.description)")
        .accessibilityHint("Opens this control. \(destination.availability.accessibilityDescription).")
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text("\(results.count) \(results.count == 1 ? "destination" : "destinations")")
            Text("•")
            Text(platform.displayName)
            Spacer()
            #if os(macOS)
            Text("↑↓ Navigate   ↵ Open   esc Close")
                .monospaced()
            #endif
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    private func select(_ destination: ControlFinderDestination) {
        onDismiss()
        // Let the finder presentation leave the hierarchy before a destination
        // opens another sheet/window (notably Animation Editor on iPad).
        Task { @MainActor in
            await Task.yield()
            onSelect(destination)
        }
    }

    private func activateHighlightedDestination() {
        guard let destination = results.first(where: { $0.id == highlightedDestinationID }) ?? results.first else {
            return
        }
        select(destination)
    }

    #if os(macOS)
    private func handleMoveCommand(_ direction: MoveCommandDirection) {
        switch direction {
        case .down:
            moveHighlight(by: 1)
        case .up:
            moveHighlight(by: -1)
        default:
            break
        }
    }

    private func moveHighlight(by delta: Int) {
        guard !results.isEmpty else { return }

        if focusTarget == .search {
            let index = delta > 0 ? 0 : results.count - 1
            focus(destinationAt: index)
            return
        }

        let currentIndex = results.firstIndex(where: { $0.id == highlightedDestinationID }) ?? 0
        let nextIndex = currentIndex + delta
        if nextIndex < 0 {
            focusTarget = .search
            return
        }
        focus(destinationAt: min(nextIndex, results.count - 1))
    }

    private func focus(destinationAt index: Int) {
        guard results.indices.contains(index) else { return }
        let destination = results[index]
        highlightedDestinationID = destination.id
        focusTarget = .destination(destination.id)
    }
    #endif
}

/// Kept separate from `ControlFinderView` so Swift's result-builder type checker
/// does not have to solve the complete row and focus/hover modifier chain as one
/// large expression.
private struct ControlFinderDestinationRowLabel: View {
    let destination: ControlFinderDestination
    let isHighlighted: Bool

    private var accent: Color { isHighlighted ? .blue : .secondary }
    private var fill: Color {
        isHighlighted ? Color.blue.opacity(0.12) : Color.secondary.opacity(0.045)
    }
    private var stroke: Color {
        isHighlighted ? Color.blue.opacity(0.34) : Color.secondary.opacity(0.10)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            leadingIcon
            copy
            Image(systemName: "arrow.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(isHighlighted ? Color.blue : Color.secondary.opacity(0.65))
                .padding(.top, 8)
        }
        .padding(10)
        .contentShape(RoundedRectangle(cornerRadius: 11))
        .background(RoundedRectangle(cornerRadius: 11).fill(fill))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(stroke, lineWidth: 1))
    }

    private var leadingIcon: some View {
        Image(systemName: destination.icon)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(accent)
            .frame(width: 32, height: 32)
            .background(accent.opacity(isHighlighted ? 0.16 : 0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private var copy: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(destination.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(destination.path)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                availabilityBadge
            }

            Text(destination.description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
        }
    }

    @ViewBuilder
    private var availabilityBadge: some View {
        if let availability = destination.availability.shortLabel {
            Text(availability)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.secondary.opacity(0.10), in: Capsule())
        }
    }
}
