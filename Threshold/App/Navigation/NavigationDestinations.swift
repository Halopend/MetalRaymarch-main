//
//  NavigationDestinations.swift
//  MetalProject
//
//  Shared navigation destinations and presentation-state enums.
//

import SwiftUI

enum ExploreRailSection: String, CaseIterable, Codable, Hashable, Sendable {
    case jumpingOff = "Jumping Off"
    case musicReactive = "Music Reactive"
    case animated = "Animated"
    case mixed = "Mixed"
    case customScenes = "Custom Scenes"

    var icon: String {
        switch self {
        case .jumpingOff: return "photo.on.rectangle.angled"
        case .musicReactive: return "waveform"
        case .animated: return "film.stack"
        case .mixed: return "circle.dashed.inset.filled"
        case .customScenes: return "chevron.left.forwardslash.chevron.right"
        }
    }

    var browseTab: FractalBrowseTab {
        switch self {
        case .jumpingOff: return .jumpingOff
        case .musicReactive: return .musicReactive
        case .animated: return .animated
        case .mixed: return .mixed
        case .customScenes: return .customScenes
        }
    }
}

enum ShapeRailSection: String, CaseIterable, Codable, Hashable, Sendable {
    /// Legacy decode-only value. Parameters now live under the Input workspace.
    case parameters = "Parameters"
    case formula = "Formula"
    case primitives = "Primitives"
    case hands = "Hands"
    case space = "Space"
    case transformations = "Transform"
    case bounding = "Bounding"
    /// Legacy decode-only value. Current presentation enumeration is authored
    /// below and never exposes it; NavigationStore redirects it to Quality.
    case performance = "Performance"

    static let allCases: [ShapeRailSection] = [
        .formula, .primitives, .hands, .space,
        .transformations, .bounding,
    ]

    var icon: String {
        switch self {
        case .parameters: return "slider.horizontal.3"
        case .formula: return "function"
        case .primitives: return "cube.transparent"
        case .hands: return "hand.raised.fingers.spread"
        case .space: return "rotate.3d"
        case .transformations: return "square.stack.3d.up"
        case .bounding: return "circle.dashed"
        case .performance: return "speedometer"
        }
    }
}

enum PerformanceRailSection: String, CaseIterable, Codable, Hashable, Sendable {
    // Overview first: the read-only live dashboard is the default landing section
    // for the Performance tab (the rail renders allCases in this order, so the
    // default-selected section also sits at the top). Tuning holds every knob —
    // the iteration/ray-step budget plus the march-acceleration techniques.
    case overview = "Overview"
    case tuning = "Tuning"

    var icon: String {
        switch self {
        case .overview: return "gauge"
        case .tuning: return "slider.horizontal.3"
        }
    }
}

enum VisualizationsRailSection: String, CaseIterable, Codable, Hashable, Sendable {
    case color = "Color"
    case mapping = "Mapping"
    case grading = "Grading"
    case motion = "Cycling"
    case atmosphere = "Atmosphere"
    case transition = "Transition"
    /// Legacy decode-only value. NavigationStore redirects it to Input.
    case reactive = "Reactive"

    static let allCases: [VisualizationsRailSection] = [
        .color, .atmosphere, .grading, .motion, .transition,
    ]

    /// A safe destination when opening the top-level Look workspace. Older
    /// installs can still have the removed `reactive` section in AppStorage;
    /// that legacy route belongs to Input now and must not make the Look button
    /// appear to open Music.
    var lookWorkspaceDestination: VisualizationsRailSection {
        Self.allCases.contains(self) ? self : .color
    }

    var title: String {
        switch self {
        case .color:
            return "Color & Mapping"
        case .grading:
            // Keep the raw value "Grading" stable for existing @AppStorage
            // navigation state while presenting the broader scene-control home.
            return "Post Processing"
        case .reactive:
            return "Audio Reactive"
        default:
            return rawValue
        }
    }

    var icon: String {
        switch self {
        case .color: return "paintpalette.fill"
        case .mapping: return "target"
        case .grading: return "camera.filters"
        case .motion: return "sparkles"
        case .atmosphere: return "cloud.fog.fill"
        case .transition: return "timer"
        case .reactive: return "waveform.path.ecg"
        }
    }
}

enum MusicRailSection: String, CaseIterable, Codable, Hashable, Sendable {
    case parameters = "Parameters"
    case playback = "Playback"
    case reactive = "Reactive"
    // Legacy persisted routes. Mappings and presets now live on the combined
    // Reactivity page, but the raw values must remain decodable from AppStorage.
    case mappings = "Mappings"
    case presets = "Presets"
    case songs = "Songs"
    case playlists = "Playlists"
    case albums = "Albums"

    static let allCases: [MusicRailSection] = [
        .parameters, .playback, .reactive, .songs, .playlists, .albums,
    ]

    var title: String {
        switch self {
        case .parameters:
            return rawValue
        case .playback:
            return "Source"
        case .reactive:
            return "Reactivity"
        case .mappings, .presets, .songs, .playlists, .albums:
            return rawValue
        }
    }

    var icon: String {
        switch self {
        case .parameters:
            return "slider.horizontal.3"
        case .playback:
            return "waveform.circle.fill"
        case .reactive:  return "waveform.path.ecg"
        case .mappings:  return "point.3.connected.trianglepath.dotted"
        case .presets:   return "square.stack.3d.up"
        case .songs:     return "music.note"
        case .playlists: return "music.note.list"
        case .albums:    return "square.stack"
        }
    }

    static func availableCases(for profile: PlatformProfile) -> [MusicRailSection] {
        profile.supports(.musicLibraryBrowsing) ? allCases : [.parameters, .playback, .reactive]
    }

    /// Resolves old split-page routes to their single current destination.
    var canonical: MusicRailSection {
        switch self {
        case .mappings, .presets:
            return .reactive
        case .parameters, .playback, .reactive, .songs, .playlists, .albums:
            return self
        }
    }

}

/// How a scene is contained in the room — the headline framing over the two
/// mutually-exclusive grounding modes (Bounding Shape vs surroundings
/// containment). This is the concept that distinguishes an intentionally
/// *unbounded* Mixed scene from a bounded one:
///
///  - `.bounded`      — a bounding shape holds the fractal. The safe default:
///                      big/overwhelming fractals stay pre-gated behind a shape.
///  - `.space`        — an authored room-sized box holds the fractal in world
///                      space without depending on a scanned environment.
///  - `.surroundings` — no bounding shape; the fractal conforms to the scanned
///                      room (Scrunch), grounding it to real surfaces. Best in
///                      Mixed immersion.
///  - `.environment`  — no bounding shape; Shell mode renders only near scanned
///                      walls/objects, leaving open space empty.
///  - `.free`         — no containment; the fractal fills the space unbounded.
///
/// Derived from the underlying enable flags (all scene-persisted), so it needs
/// no separate saved field — a scene records its mode simply by saving its
/// Bounding Shape / Scrunch toggles.
enum MixedContainment: String, CaseIterable, Identifiable {
    case bounded = "Shape"
    case space = "Space"
    case surroundings = "Surroundings"
    case environment = "Environment"
    case free = "Free"
    /// Derived, read-only override state: multiple containment systems are on
    /// at once. Only reachable by flipping the individual side/quick toggles
    /// (the top-bar picker is mutually exclusive); tapping it in the picker is a
    /// no-op. Pick Shape/Surroundings/Environment/Free to snap back to a
    /// single mode.
    case custom = "Custom"

    var id: String { rawValue }

    var help: String {
        switch self {
        case .bounded:
            return "The fractal is held inside a sphere shape instead of filling your space."
        case .space:
            return "The fractal is clipped to the authored room dimensions, independent of scanned surroundings."
        case .surroundings:
            return "No bounding shape — Scrunch makes the fractal conform to scanned surroundings, grounding it to the real room."
        case .environment:
            return "No bounding shape — the fractal becomes a shell on scanned walls and objects, leaving open space empty."
        case .free:
            return "No containment — the fractal fills the space unbounded. Most immersive, least predictable."
        case .custom:
            return "A manual mix — more than one containment system is on. Pick Shape, Space, Surroundings, Environment, or Free to snap back to a single mode."
        }
    }
}
/// Inner tabs of the Settings panel. Drives the segmented picker in
/// `ContentView.settingsTabContent` and the corresponding switch dispatch.
enum SettingsSubTab: String, CaseIterable, Identifiable, Codable, Hashable, Sendable {
    case display   = "Display"
    case gestures  = "Gestures"
    case sharing   = "Sharing"
    case export    = "Export"
    case advanced  = "Advanced"

    var id: String { rawValue }

    static var visibleCases: [SettingsSubTab] {
        [.display, .sharing, .export, .advanced]
    }

    var icon: String {
        switch self {
        case .display:   return "rectangle.on.rectangle.angled"
        case .gestures:  return "hand.draw"
        case .sharing:   return "person.2.wave.2"
        case .export:    return "square.and.arrow.up"
        case .advanced:  return "wrench.and.screwdriver"
        }
    }

}

// Used by SaveDestinationSheet (ContentViewComponents.swift); kept internal.
// Plain enum: cases are referenced directly and compared for equality; the
// rawValues/allCases were never read (UI labels are hardcoded at the call site).
enum SaveChoice {
    case resetLocation
    case presetCustomName
    case presetWithPreview
}

enum RendererModeOption: String, CaseIterable {
    case fragment = "Fragment"
    case adaptiveCompute = "Adaptive Compute"

    var tileSize: Int {
        switch self {
        case .fragment: return 0
        case .adaptiveCompute: return 8
        }
    }

    static func from(tileSize: Int) -> RendererModeOption {
        switch tileSize {
        case 8:
            return .adaptiveCompute
        default:
            return .fragment
        }
    }

    var helperText: String {
        switch self {
        case .fragment:
            return "Default path with full shading. Supports MetalFX spatial upscaling."
        case .adaptiveCompute:
            return "8x8 adaptive compute path. Best for raw performance; MetalFX is disabled in this mode."
        }
    }
}

enum QualityGoalPreference: Int, CaseIterable {
    case simplified = 0
    case advanced = 1

    var displayName: String {
        switch self {
        case .simplified: return "Simplified"
        case .advanced: return "Advanced"
        }
    }
}
