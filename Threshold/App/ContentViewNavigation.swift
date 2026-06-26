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

    var icon: String {
        switch self {
        case .explore: return "sparkles.rectangle.stack"
        case .shape: return "cube.transparent"
        case .visualizations: return "paintbrush.pointed.fill"
        case .music: return "music.note"
        }
    }
}

enum ExploreRailSection: String, CaseIterable {
    case jumpingOff = "Jumping Off"
    case musicReactive = "Music Reactive"
    case animated = "Animated"
    case customScenes = "Custom Scenes"

    var icon: String {
        switch self {
        case .jumpingOff: return "photo.on.rectangle.angled"
        case .musicReactive: return "waveform"
        case .animated: return "film.stack"
        case .customScenes: return "chevron.left.forwardslash.chevron.right"
        }
    }

    var browseTab: FractalBrowseTab {
        switch self {
        case .jumpingOff: return .jumpingOff
        case .musicReactive: return .musicReactive
        case .animated: return .animated
        case .customScenes: return .customScenes
        }
    }
}

enum ShapeRailSection: String, CaseIterable {
    case parameters = "Parameters"
    case formula = "Formula"
    case space = "Space"
    case performance = "Performance"

    var icon: String {
        switch self {
        case .parameters: return "slider.horizontal.3"
        case .formula: return "function"
        case .space: return "rotate.3d"
        case .performance: return "speedometer"
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

    var title: String {
        switch self {
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
    case songs = "Songs"
    case playlists = "Playlists"
    case albums = "Albums"

    var title: String {
        #if os(macOS)
        switch self {
        case .playback:
            return "Music App"
        case .songs, .playlists, .albums:
            return rawValue
        }
        #else
        return rawValue
        #endif
    }

    var icon: String {
        switch self {
        case .playback:
            #if os(macOS)
            return "waveform.circle.fill"
            #else
            return "play.circle.fill"
            #endif
        case .songs:     return "music.note"
        case .playlists: return "music.note.list"
        case .albums:    return "square.stack"
        }
    }

    static var availableCases: [MusicRailSection] {
        #if os(macOS)
        return [.playback]
        #else
        return allCases
        #endif
    }

    var musicPanelTab: MusicPanelTab {
        switch self {
        case .playback:  return .music
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
    case exploreCustomScenes
    case shapeParameters
    case shapeFormula
    case shapeSpace
    case shapePerformance
    case visualizationsColor
    case visualizationsMapping
    case visualizationsGrading
    case visualizationsMotion
    case visualizationsAtmosphere
    case visualizationsTransition
    case visualizationsReactive
    case musicPlayback
    case musicSongs
    case musicPlaylists
    case musicAlbums

    var title: String {
        switch self {
        case .exploreJumpingOff: return ExploreRailSection.jumpingOff.rawValue
        case .exploreMusicReactive: return ExploreRailSection.musicReactive.rawValue
        case .exploreAnimated: return ExploreRailSection.animated.rawValue
        case .exploreCustomScenes: return ExploreRailSection.customScenes.rawValue
        case .shapeParameters: return ShapeRailSection.parameters.rawValue
        case .shapeFormula: return ShapeRailSection.formula.rawValue
        case .shapeSpace: return ShapeRailSection.space.rawValue
        case .shapePerformance: return ShapeRailSection.performance.rawValue
        case .visualizationsColor: return VisualizationsRailSection.color.title
        case .visualizationsMapping: return VisualizationsRailSection.mapping.title
        case .visualizationsGrading: return VisualizationsRailSection.grading.title
        case .visualizationsMotion: return VisualizationsRailSection.motion.title
        case .visualizationsAtmosphere: return VisualizationsRailSection.atmosphere.title
        case .visualizationsTransition: return VisualizationsRailSection.transition.title
        case .visualizationsReactive: return VisualizationsRailSection.reactive.title
        case .musicPlayback: return MusicRailSection.playback.title
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
        case .exploreCustomScenes: return ExploreRailSection.customScenes.icon
        case .shapeParameters: return ShapeRailSection.parameters.icon
        case .shapeFormula: return ShapeRailSection.formula.icon
        case .shapeSpace: return ShapeRailSection.space.icon
        case .shapePerformance: return ShapeRailSection.performance.icon
        case .visualizationsColor: return VisualizationsRailSection.color.icon
        case .visualizationsMapping: return VisualizationsRailSection.mapping.icon
        case .visualizationsGrading: return VisualizationsRailSection.grading.icon
        case .visualizationsMotion: return VisualizationsRailSection.motion.icon
        case .visualizationsAtmosphere: return VisualizationsRailSection.atmosphere.icon
        case .visualizationsTransition: return VisualizationsRailSection.transition.icon
        case .visualizationsReactive: return VisualizationsRailSection.reactive.icon
        case .musicPlayback: return MusicRailSection.playback.icon
        case .musicSongs: return MusicRailSection.songs.icon
        case .musicPlaylists: return MusicRailSection.playlists.icon
        case .musicAlbums: return MusicRailSection.albums.icon
        }
    }
}

enum FractalSubTab: String, CaseIterable { case browse = "Browse", shape = "Shape", space = "Space", render = "Render" }
enum ShapeInnerTab: String, CaseIterable { case parameters = "Parameters", formula = "Formula" }
enum ColoringSubTab: String, CaseIterable { case gradient = "Gradient", mapping = "Mapping", grading = "Grading" }
enum EffectsSubTab: String, CaseIterable { case dynamic = "Dynamic Color", `static` = "Atmosphere" }
/// Inner tabs of the Settings panel. Drives the segmented picker in
/// `ContentView.settingsTabContent` and the corresponding switch dispatch.
enum SettingsSubTab: String, CaseIterable, Identifiable {
    case display   = "Display"
    case gestures  = "Gestures"
    case sharing   = "Sharing"
    case export    = "Export"
    case advanced  = "Advanced"

    var id: String { rawValue }

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
    case quadShared = "Quad Shared"
    case adaptiveCompute = "Adaptive Compute"

    var tileSize: Int {
        switch self {
        case .fragment: return 0
        case .quadShared: return 2
        case .adaptiveCompute: return 8
        }
    }

    static func from(tileSize: Int) -> RendererModeOption {
        switch tileSize {
        case 8:
            return .adaptiveCompute
        case 2:
            return .quadShared
        default:
            return .fragment
        }
    }

    var helperText: String {
        switch self {
        case .fragment:
            return "Default path with full shading. Supports MetalFX spatial upscaling."
        case .quadShared:
            return "Fragment path with quad-shared traversal. Supports MetalFX spatial upscaling."
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
