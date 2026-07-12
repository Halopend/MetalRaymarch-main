//
//  ContentViewNavigation.swift
//  MetalProject
//
//  Navigation taxonomy enums for ContentView (sidebar tabs, top-dock tabs,
//  rail sections, sub-tabs). Extracted from ContentView.swift during the
//  Phase 3 architecture refactor.
//

import SwiftUI

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - Sidebar Tab Enum
// ═══════════════════════════════════════════════════════════════════════════════

enum SidebarTab: String, CaseIterable {
    case fractal = "Fractal"
    case animate = "Video"
    case coloring = "Coloring"
    case effects = "Effects"
    case music = "Music"
    case transition = "Transition"
    case quickToggles = "Quick Toggles"
    case gestures = "Gestures"
    case settings = "Settings"

    var icon: String {
        switch self {
        case .fractal:  return "cube.fill"
        case .animate:  return "film.stack"
        case .coloring: return "paintpalette.fill"
        case .effects:  return "wand.and.stars"
        case .music:    return "music.note"
        case .transition: return "timer"
        case .quickToggles: return "switch.2"
        case .gestures: return "hand.draw"
        case .settings: return "gearshape.fill"
        }
    }
}

enum TopDockTab: String, CaseIterable {
    case explore = "Explore"
    case shape = "Shape"
    case visualizations = "Visualizations"
    case music = "Music"
    case performance = "Performance"

    /// User-facing workspace order. Raw values intentionally remain unchanged so
    /// existing AppStorage navigation state survives the information-architecture
    /// update.
    static var allCases: [TopDockTab] { [.explore, .music, .shape, .visualizations, .performance] }

    var title: String {
        switch self {
        case .music: return "Input"
        case .visualizations: return "Look"
        case .performance: return "Quality"
        default: return rawValue
        }
    }

    var icon: String {
        switch self {
        case .explore: return "sparkles.rectangle.stack"
        case .shape: return "cube.transparent"
        case .visualizations: return "paintbrush.pointed.fill"
        case .music: return "waveform"
        case .performance: return "speedometer"
        }
    }
}

enum ExploreRailSection: String, CaseIterable {
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

enum ShapeRailSection: String, CaseIterable {
    case parameters = "Parameters"
    case formula = "Formula"
    case hands = "Hands"
    case space = "Space"
    case transformations = "Transform"
    case bounding = "Bounding"
    case performance = "Performance"

    var icon: String {
        switch self {
        case .parameters: return "slider.horizontal.3"
        case .formula: return "function"
        case .hands: return "hand.raised.fingers.spread"
        case .space: return "rotate.3d"
        case .transformations: return "square.stack.3d.up"
        case .bounding: return "circle.dashed"
        case .performance: return "speedometer"
        }
    }
}

enum PerformanceRailSection: String, CaseIterable {
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

enum VisualizationsRailSection: String, CaseIterable {
    case color = "Color"
    case mapping = "Mapping"
    case grading = "Grading"
    case motion = "Cycling"
    case atmosphere = "Atmosphere"
    case transition = "Transition"
    case reactive = "Reactive"

    /// Audio reactivity now lives in Input. Keep the legacy case decodable so
    /// saved routes can be redirected without losing user state.
    static var visibleCases: [VisualizationsRailSection] {
        [.color, .mapping, .atmosphere, .grading, .motion, .transition]
    }

    var title: String {
        switch self {
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

enum MusicRailSection: String, CaseIterable {
    case playback = "Playback"
    case reactive = "Reactive"
    case mappings = "Mappings"
    case presets = "Presets"
    case songs = "Songs"
    case playlists = "Playlists"
    case albums = "Albums"

    var title: String {
        switch self {
        case .playback:
            return "Source"
        case .reactive, .mappings, .presets, .songs, .playlists, .albums:
            return rawValue
        }
    }

    var icon: String {
        switch self {
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

    static var availableCases: [MusicRailSection] {
        #if os(macOS)
        return [.playback, .reactive, .mappings, .presets]
        #else
        return [.playback, .reactive, .mappings, .presets, .songs, .playlists, .albums]
        #endif
    }

    var musicPanelTab: MusicPanelTab {
        switch self {
        case .playback:  return .music
        case .reactive:  return .reactive
        case .mappings:  return .mappings
        case .presets:   return .presets
        case .songs:     return .songs
        case .playlists: return .playlists
        case .albums:    return .albums
        }
    }
}

enum PinnedRailControl: String, CaseIterable {
    case exploreJumpingOff
    case exploreMusicReactive
    case exploreAnimated
    case exploreMixed
    case exploreCustomScenes
    case shapeParameters
    case shapeFormula
    case shapeHands
    case shapeSpace
    case shapeTransformations
    case shapeBounding
    case shapePerformance
    case visualizationsColor
    case visualizationsMapping
    case visualizationsGrading
    case visualizationsMotion
    case visualizationsAtmosphere
    case visualizationsTransition
    case visualizationsReactive
    case musicPlayback
    case musicReactive
    case musicMappings
    case musicPresets
    case musicSongs
    case musicPlaylists
    case musicAlbums

    var title: String {
        switch self {
        case .exploreJumpingOff: return ExploreRailSection.jumpingOff.rawValue
        case .exploreMusicReactive: return ExploreRailSection.musicReactive.rawValue
        case .exploreAnimated: return ExploreRailSection.animated.rawValue
        case .exploreMixed: return ExploreRailSection.mixed.rawValue
        case .exploreCustomScenes: return ExploreRailSection.customScenes.rawValue
        case .shapeParameters: return ShapeRailSection.parameters.rawValue
        case .shapeFormula: return ShapeRailSection.formula.rawValue
        case .shapeHands: return ShapeRailSection.hands.rawValue
        case .shapeSpace: return ShapeRailSection.space.rawValue
        case .shapeTransformations: return ShapeRailSection.transformations.rawValue
        case .shapeBounding: return ShapeRailSection.bounding.rawValue
        case .shapePerformance: return ShapeRailSection.performance.rawValue
        case .visualizationsColor: return VisualizationsRailSection.color.title
        case .visualizationsMapping: return VisualizationsRailSection.mapping.title
        case .visualizationsGrading: return VisualizationsRailSection.grading.title
        case .visualizationsMotion: return VisualizationsRailSection.motion.title
        case .visualizationsAtmosphere: return VisualizationsRailSection.atmosphere.title
        case .visualizationsTransition: return VisualizationsRailSection.transition.title
        case .visualizationsReactive: return VisualizationsRailSection.reactive.title
        case .musicPlayback: return MusicRailSection.playback.title
        case .musicReactive: return MusicRailSection.reactive.title
        case .musicMappings: return MusicRailSection.mappings.title
        case .musicPresets: return MusicRailSection.presets.title
        case .musicSongs: return MusicRailSection.songs.title
        case .musicPlaylists: return MusicRailSection.playlists.title
        case .musicAlbums: return MusicRailSection.albums.title
        }
    }

    var icon: String {
        switch self {
        case .exploreJumpingOff: return ExploreRailSection.jumpingOff.icon
        case .exploreMusicReactive: return ExploreRailSection.musicReactive.icon
        case .exploreAnimated: return ExploreRailSection.animated.icon
        case .exploreMixed: return ExploreRailSection.mixed.icon
        case .exploreCustomScenes: return ExploreRailSection.customScenes.icon
        case .shapeParameters: return ShapeRailSection.parameters.icon
        case .shapeFormula: return ShapeRailSection.formula.icon
        case .shapeHands: return ShapeRailSection.hands.icon
        case .shapeSpace: return ShapeRailSection.space.icon
        case .shapeTransformations: return ShapeRailSection.transformations.icon
        case .shapeBounding: return ShapeRailSection.bounding.icon
        case .shapePerformance: return ShapeRailSection.performance.icon
        case .visualizationsColor: return VisualizationsRailSection.color.icon
        case .visualizationsMapping: return VisualizationsRailSection.mapping.icon
        case .visualizationsGrading: return VisualizationsRailSection.grading.icon
        case .visualizationsMotion: return VisualizationsRailSection.motion.icon
        case .visualizationsAtmosphere: return VisualizationsRailSection.atmosphere.icon
        case .visualizationsTransition: return VisualizationsRailSection.transition.icon
        case .visualizationsReactive: return VisualizationsRailSection.reactive.icon
        case .musicPlayback: return MusicRailSection.playback.icon
        case .musicReactive: return MusicRailSection.reactive.icon
        case .musicMappings: return MusicRailSection.mappings.icon
        case .musicPresets: return MusicRailSection.presets.icon
        case .musicSongs: return MusicRailSection.songs.icon
        case .musicPlaylists: return MusicRailSection.playlists.icon
        case .musicAlbums: return MusicRailSection.albums.icon
        }
    }
}

enum FractalSubTab: String, CaseIterable { case browse = "Browse", shape = "Shape", space = "Space", transform = "Transform", bounding = "Bounding", render = "Render" }
enum ShapeInnerTab: String, CaseIterable { case parameters = "Parameters", formula = "Formula", hands = "Hands" }
enum ColoringSubTab: String, CaseIterable { case gradient = "Gradient", mapping = "Mapping", grading = "Grading" }
enum EffectsSubTab: String, CaseIterable { case dynamic = "Dynamic Color", `static` = "Atmosphere" }

/// Where a Quick Toggles tile's full controls live. Long-pressing a tile
/// navigates to the matching tab/sub-tab via `ContentView.openQuickToggleHome(_:)`.
enum QuickToggleHome {
    case effectsAtmosphere      // Glow, Bloom, Fog
    case effectsDynamic         // Hue Rotation, Pulse, Gradient Cycle, Linear Rail, Polar Rotation, Julia Drift, Beat Flash
    case shapeSpace             // Spherical Inversion, Safety Bubble, Detail
    case shapeTransformations   // Sphere Projection, Spherical Inversion, warp stack
    case shapeBounding          // Containment: Bounding Shape, Scrunch to Surroundings, Bound to Space
    case shapePerformance       // Smart Advance, Coherent Packet, Self-Shadows, Bounding Sphere Skip
    case audioReactive          // Audio Reactive + bass/mid/treble/beat
}

/// How a scene is contained in the room — the headline framing over the two
/// mutually-exclusive grounding modes (Bounding Shape vs surroundings
/// containment). This is the concept that distinguishes an intentionally
/// *unbounded* Mixed scene from a bounded one:
///
///  - `.bounded`      — a bounding shape holds the fractal. The safe default:
///                      big/overwhelming fractals stay pre-gated behind a shape.
///  - `.surroundings` — no bounding shape; the fractal conforms to the scanned
///                      room (Scrunch), grounding it to real surfaces. Best in
///                      Mixed immersion.
///  - `.environment`  — no bounding shape; Shell mode renders only near scanned
///                      walls/objects, leaving open space empty.
///  - `.free`         — no containment; the fractal fills the space unbounded.
///
/// Derived from the underlying enable flags (both scene-persisted), so it needs
/// no separate saved field — a scene records its mode simply by saving its
/// Bounding Shape / Scrunch toggles.
enum MixedContainment: String, CaseIterable, Identifiable {
    case bounded = "Shape"
    case surroundings = "Surroundings"
    case environment = "Environment"
    case free = "Free"
    /// Derived, read-only override state: BOTH a bounding shape and Scrunch are
    /// on at once. Only reachable by flipping the individual side/quick toggles
    /// (the top-bar picker is mutually exclusive); tapping it in the picker is a
    /// no-op. Pick Shape/Surroundings/Environment/Free to snap back to a
    /// single mode.
    case custom = "Custom"

    var id: String { rawValue }

    var help: String {
        switch self {
        case .bounded:
            return "The fractal is held inside a sphere shape instead of filling your space."
        case .surroundings:
            return "No bounding shape — Scrunch makes the fractal conform to scanned surroundings, grounding it to the real room."
        case .environment:
            return "No bounding shape — the fractal becomes a shell on scanned walls and objects, leaving open space empty."
        case .free:
            return "No containment — the fractal fills the space unbounded. Most immersive, least predictable."
        case .custom:
            return "A manual mix — both Shape and surroundings containment are on at once. Pick Shape, Surroundings, Environment, or Free to snap back to a single mode."
        }
    }
}
/// Inner tabs of the Settings panel. Drives the segmented picker in
/// `ContentView.settingsTabContent` and the corresponding switch dispatch.
enum SettingsSubTab: String, CaseIterable, Identifiable {
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
