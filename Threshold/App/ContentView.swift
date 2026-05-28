//
//  ContentView.swift
//  MetalProject
//
//  Created by MU on 18/11/24.
//  Reorganized: Sidebar + Sub-Tab layout
//

import SwiftUI
import RealityKit
#if os(visionOS) || os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif


// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - Sidebar Tab Enum
// ═══════════════════════════════════════════════════════════════════════════════

enum SidebarTab: String, CaseIterable {
    case fractal = "Fractal"
    case animate = "Video"
    case coloring = "Coloring"
    case effects = "Effects"
    case music = "Music"
    case gestures = "Gestures"
    case settings = "Settings"
    
    var icon: String {
        switch self {
        case .fractal:  return "cube.fill"
        case .animate:  return "film.stack"
        case .coloring: return "paintpalette.fill"
        case .effects:  return "wand.and.stars"
        case .music:    return "music.note"
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

private enum PinnedRailControl: String, CaseIterable {
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
enum SettingsSubTab: String, CaseIterable { case general = "General", exportShare = "Export", devTools = "Dev Tools" }

private enum SaveChoice: String, CaseIterable {
    case resetLocation = "Reset Location"
    case presetCustomName = "Preset - Custom Name"
    case presetWithPreview = "Preset + Preview"
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

private enum QualityGoalPreference: Int, CaseIterable {
    case framerate = 0
    case detail = 1
    case control = 2

    var displayName: String {
        switch self {
        case .framerate: return "Framerate"
        case .detail: return "Detail"
        case .control: return "Control"
        }
    }

}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - ContentView
// ═══════════════════════════════════════════════════════════════════════════════

struct ContentView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    
    @State private var cache = UISettingsCache()
    @AppStorage("ContentView.topDockTab") private var topDockTab: TopDockTab = .explore
    @AppStorage("ContentView.exploreRailSection") private var exploreRailSection: ExploreRailSection = .jumpingOff
    @AppStorage("ContentView.shapeRailSection") private var shapeRailSection: ShapeRailSection = .parameters
    @AppStorage("ContentView.visualizationsRailSection") private var visualizationsRailSection: VisualizationsRailSection = .color
    @AppStorage("ContentView.musicRailSection") private var musicRailSection: MusicRailSection = .playback
    @AppStorage("ContentView.skipOuterNavigationSync") private var skipOuterNavigationSync = false
    // Persist last-selected tab and sub-tabs across launches.
    @AppStorage("ContentView.selectedTab") private var selectedTab: SidebarTab = .fractal
    @AppStorage("FractalGridView.innerTab") private var fractalBrowseTab: FractalBrowseTab = .jumpingOff
    @AppStorage("ContentView.fractalSubTab") private var fractalSubTab: FractalSubTab = .shape
    @AppStorage("ContentView.shapeInnerTab") private var shapeInnerTab: ShapeInnerTab = .parameters
    @State private var animateEditButtonsVisible = false
    @AppStorage("ContentView.coloringSubTab") private var coloringSubTab: ColoringSubTab = .gradient
    @AppStorage("ContentView.effectsSubTab") private var effectsSubTab: EffectsSubTab = .dynamic
    @AppStorage("MusicTabContent.innerTab") private var musicPanelTab: MusicPanelTab = .music
    @AppStorage("ContentView.settingsSubTab") private var settingsSubTab: SettingsSubTab = .general
    @AppStorage("ContentView.pinnedRailControls") private var pinnedRailControlsRaw: String = ""
    @State private var showStopsPopover = false
    @State private var showSaveDestinationSheet = false
    @State private var didLongPressPinnedRailControl: PinnedRailControl?
    @State private var animationKillSwitchTask: Task<Void, Never>?

    private let animationKillSwitchDuration: TimeInterval = 0.7

    private var activeMusicPermutationCount: Int {
        guard cache.audioReactive.fractalAudioReactiveEnabled else { return 0 }
        return cache.audioReactive.musicReactiveMappings.count
    }

    private var isAnimationPlaying: Bool {
        appModel.animationManager?.isPlaying ?? appModel.renderSettings.isAnimationPlaying
    }

    private var activeDynamicEffectCount: Int {
        var count = 0
        if cache.lighting.gradientCycleEffect.enabled { count += 1 }
        if cache.lighting.hueRotationEffect.enabled { count += 1 }
        if cache.lighting.pulseEffect.enabled { count += 1 }
        if cache.lighting.linearRailEffect.enabled { count += 1 }
        if cache.lighting.beatFlashEffect.enabled { count += 1 }
        if cache.fractalType.supports(.polarRotation), cache.lighting.polarRotationEffect.enabled { count += 1 }
        if cache.fractalType.supports(.juliaDrift), cache.lighting.juliaDriftEffect.enabled { count += 1 }
        return count
    }

    private var hasActiveAnimationSystems: Bool {
        isAnimationPlaying || activeMusicPermutationCount > 0 || activeDynamicEffectCount > 0 || animationKillSwitchTask != nil
    }

    private var hasShapeMusicMapping: Bool {
        cache.audioReactive.musicReactiveMappings.contains { mapping in
            let target = mapping.target.migrated
            return target == .iterations || target.isFormulaParam
        }
    }

    private var hasFlashingMusicVisuals: Bool {
        cache.audioReactive.musicReactiveMappings.contains(where: \.hasFlashingRisk)
    }

        private var shouldUseWorkspaceLayout: Bool {
    #if os(macOS)
        true
    #else
        appModel.immersiveSpaceState == .open
    #endif
        }

        private var isMenuContentVisible: Bool {
    #if os(macOS)
        true
    #else
        appModel.isMenuWindowVisible
    #endif
        }

        private var shouldRenderInlineTopDock: Bool {
    #if os(macOS)
        true
    #else
        false
    #endif
        }

        private var supportsGestureEditing: Bool {
    #if os(macOS)
        false
    #else
        true
    #endif
        }

    @AppStorage("qualityGoalPreference.v2") private var qualityGoalPreferenceRaw: Int = QualityGoalPreference.detail.rawValue
    @AppStorage("qualityGoalLastDirectPreference.v1") private var qualityGoalLastDirectPreferenceRaw: Int = QualityGoalPreference.detail.rawValue
    private var qualityGoalPreference: QualityGoalPreference {
        QualityGoalPreference(rawValue: qualityGoalPreferenceRaw) ?? .detail
    }

    private var lastDirectBudgetPreference: QualityGoalPreference {
        let candidate = QualityGoalPreference(rawValue: qualityGoalLastDirectPreferenceRaw) ?? .detail
        return candidate == .framerate ? .framerate : .detail
    }

    private var effectiveDirectBudgetPreference: QualityGoalPreference {
        if qualityGoalPreference == .control { return lastDirectBudgetPreference }
        return qualityGoalPreference == .framerate ? .framerate : .detail
    }

    private var effectiveDirectBudgetLabel: String {
        effectiveDirectBudgetPreference == .framerate ? "Trade Resolution for Framerate" : "Detail Budget"
    }

    private var effectiveDirectBudgetUnavailableText: String {
        if effectiveDirectBudgetPreference == .framerate {
            return "Trading resolution for framerate is unavailable in Adaptive Compute mode. Switch Renderer Mode to Fragment or Quad Shared to enable MetalFX spatial upscaling."
        }

        return "\(effectiveDirectBudgetLabel) is unavailable in Adaptive Compute mode. Switch Renderer Mode to Fragment or Quad Shared to enable MetalFX spatial upscaling."
    }

    // Developer state
    @State private var isProfilerRunning = false
    @State private var lastProfileTime: Date?
    @State private var isTestAnimationPlaying = false
#if DEBUG
    @State private var isBenchmarking = false
#endif
    

    
    var body: some View {
        @Bindable var appModel = appModel

        let isShortcutOrnamentVisible = !shouldRenderInlineTopDock && appModel.immersiveSpaceState != .closed && appModel.isMenuWindowVisible

        Group {
            if shouldUseWorkspaceLayout {
                immersiveLayout
            } else {
                preImmersiveLayout
            }
        }
        .environment(\.menuAdjustmentActions, MenuAdjustmentActions(
            begin: { appModel.beginMenuAdjustment() },
            end: { appModel.endMenuAdjustment() }
        ))
        .animation(motionSensitiveAnimation(.easeInOut(duration: 0.3)), value: appModel.immersiveSpaceState)
        .background(menuSurfaceFill, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(menuSurfaceStroke, lineWidth: 1)
        )
        .thresholdGlassBackground(cornerRadius: 20)
        .opacity(isMenuContentVisible ? 1 : 0)
        .animation(motionSensitiveAnimation(.easeInOut(duration: 0.18)), value: isMenuContentVisible)
        .allowsHitTesting(isMenuContentVisible)
        .thresholdTopDockOrnament(isVisible: isShortcutOrnamentVisible) {
            topDockOrnament
                .padding(.bottom, 10)
        }
        .onHover { hovering in
            // Treat gaze-hover as active UI interaction for robust gesture suppression.
            appModel.setMenuHovering(hovering)
        }
        .onAppear {
            appModel.openShapeMenuHandler = {
                withMotionSensitiveAnimation(.easeInOut(duration: 0.2)) {
                    activateShapeSection(.parameters)
                }
            }
            appModel.isShapeMenuActiveHandler = {
                selectedTab == .fractal && fractalSubTab == .shape
            }
            appModel.openRenderMenuHandler = {
                withMotionSensitiveAnimation(.easeInOut(duration: 0.2)) {
                    activateShapeSection(.performance)
                }
            }
            appModel.isRenderMenuActiveHandler = {
                selectedTab == .fractal && fractalSubTab == .render
            }
            appModel.openSavePresetMenuHandler = {
                showSaveDestinationSheet = true
            }
            cache.startSync(with: appModel.renderSettings, appModel: appModel)
            normalizeDesktopSelectionIfNeeded()
            syncNavigationChromeFromLegacySelection()
        }
        .onDisappear {
            cache.stopSync()
            appModel.openSavePresetMenuHandler = nil
            animationKillSwitchTask?.cancel()
            animationKillSwitchTask = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: AppModel.fractalSettingsDidChangeNotification)) { _ in
            cache.loadFromSettings()
        }
        .onChange(of: selectedTab) { _, _ in
            normalizeDesktopSelectionIfNeeded()
            syncNavigationChromeFromLegacySelectionIfNeeded()
        }
        .onChange(of: fractalSubTab) { _, _ in syncNavigationChromeFromLegacySelectionIfNeeded() }
        .onChange(of: shapeInnerTab) { _, _ in syncNavigationChromeFromLegacySelectionIfNeeded() }
        .onChange(of: fractalBrowseTab) { _, _ in syncNavigationChromeFromLegacySelectionIfNeeded() }
        .onChange(of: coloringSubTab) { _, _ in syncNavigationChromeFromLegacySelectionIfNeeded() }
        .onChange(of: effectsSubTab) { _, _ in syncNavigationChromeFromLegacySelectionIfNeeded() }
        .onChange(of: musicPanelTab) { _, _ in syncNavigationChromeFromLegacySelectionIfNeeded() }
        .onChange(of: appModel.immersiveSpaceState) { _, _ in
            // When the renderer is not ready, snap back to Explore so the user
            // never gets stuck on a tab that requires active rendering.
            if !isRendererNavigationReady, topDockTab != .explore {
                withMotionSensitiveAnimation(.easeInOut(duration: 0.2)) { activateTopDock(.explore) }
            }
        }
        .onChange(of: appModel.rendererStartupWarmupComplete) { _, isReady in
            if !isReady, topDockTab != .explore {
                withMotionSensitiveAnimation(.easeInOut(duration: 0.2)) { activateTopDock(.explore) }
            }
        }
        .sheet(isPresented: $showSaveDestinationSheet) {
            SaveDestinationSheet(
                onSave: { choice, customName in
                    switch choice {
                    case .resetLocation:
                        saveCurrentAsResetDefaults()
                    case .presetCustomName:
                        saveCurrentAsPreset(named: customName)
                    case .presetWithPreview:
                        saveCurrentAsPreset(named: customName, includeGeneratedPreview: true)
                    }
                    showSaveDestinationSheet = false
                },
                onCancel: {
                    showSaveDestinationSheet = false
                }
            )
            .presentationDetents([.height(300), .height(360)])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $appModel.pendingExternalImport) { request in
            ExternalFileImportSheet(
                request: request,
                onPreview: {
                    previewExternalFile(request)
                },
                onImport: {
                    importExternalFile(request)
                },
                onCancel: {
                    cancelExternalFileImport(request)
                }
            )
            .presentationDetents([.height(390), .height(460)])
            .presentationDragIndicator(.hidden)
            .interactiveDismissDisabled()
        }
    }

    private var menuSurfaceFill: Color {
        colorScheme == .dark ? Color.black.opacity(0.8) : Color.white.opacity(0.72)
    }

    private var menuSurfaceStroke: Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.08)
    }

    private func motionSensitiveAnimation(_ animation: Animation) -> Animation? {
        reduceMotion ? nil : animation
    }

    private func withMotionSensitiveAnimation(_ animation: Animation, _ updates: () -> Void) {
        if reduceMotion {
            updates()
        } else {
            withAnimation(animation, updates)
        }
    }

    private func resetCurrentFractalSettings() {
        if let preset = appModel.activeResetPreset {
            appModel.presetManager.loadPreset(
                preset,
                into: appModel.renderSettings,
                resetEnvironment: true
            )
            applyPresetGestureOverridesIfNeeded(for: preset)
            appModel.gestureController?.syncWithSettings()
        } else {
            appModel.gestureController?.applyFractalDefaults()
        }
        cache.loadFromSettings()
    }

    private func saveCurrentAsResetDefaults() {
        guard appModel.gestureController?.saveCurrentAsFractalDefaults() == true else { return }
        cache.loadFromSettings()
    }

    private func saveCurrentAsPreset(named providedName: String? = nil, includeGeneratedPreview: Bool = false) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd HH-mm"
        let autoName = "Preset \(formatter.string(from: Date()))"
        let presetName = providedName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = (presetName?.isEmpty == false) ? presetName! : autoName
        appModel.presetManager.savePreset(
            name: finalName,
            settings: appModel.renderSettings,
            thumbnailData: includeGeneratedPreview ? generatedPresetPreviewData(named: finalName) : nil,
            embeddedFormula: appModel.activeEmbeddedFormula
        )
    }

    private func generatedPresetPreviewData(named name: String) -> Data? {
        PresetPreviewGenerator.makePNGData(
            name: name,
            fractalType: appModel.renderSettings.fractalType,
            gradientState: appModel.renderSettings.gradientState,
            lightingPreset: appModel.renderSettings.lightingPreset
        )
    }

    private func applyPresetGestureOverridesIfNeeded(for preset: FractalPreset) {
        let normalizedName = preset.name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard ["ring around the rosie", "a space ring odyssey"].contains(normalizedName),
              preset.fractalType == .kleinian else { return }

        let triplets = ParameterNodeRegistry.shared.gestureBindableTriplets(for: .kleinian)
        guard let minsTriplet = triplets.first(where: { $0.groupName == "Mins" }),
              let maxsTriplet = triplets.first(where: { $0.groupName == "Maxs" }) else { return }

        appModel.renderSettings.setBinding(
            .parameterTriplet(minsTriplet),
            for: GestureSlot(hand: .left, finger: .middle)
        )
        appModel.renderSettings.setBinding(
            .parameterTriplet(maxsTriplet),
            for: GestureSlot(hand: .right, finger: .middle)
        )
    }

    private func previewExternalFile(_ request: ExternalFileImportRequest) {
        withAnimation(.easeInOut(duration: 0.2)) {
            routeExternalFile(request)
        }
        appModel.previewExternalImport(request)
        cache.loadFromSettings()
    }

    private func importExternalFile(_ request: ExternalFileImportRequest) {
        withAnimation(.easeInOut(duration: 0.2)) {
            routeExternalFile(request)
        }
        appModel.importExternalFile(request)
        cache.loadFromSettings()
    }

    private func cancelExternalFileImport(_ request: ExternalFileImportRequest) {
        appModel.cancelExternalImport(request)
        cache.loadFromSettings()
    }

    private func routeExternalFile(_ request: ExternalFileImportRequest) {
        switch request.payload {
        case .preset(let preset):
            if preset.isCustomScenePreset {
                activateExploreSection(.customScenes)
            } else if preset.hasMusicReactiveMappings {
                activateExploreSection(.musicReactive)
            } else {
                activateExploreSection(.jumpingOff)
            }
        case .animation:
            selectedTab = .animate
            syncNavigationChromeFromLegacySelection()
        }
    }
    
    // MARK: - Pre-Immersive Layout
    
    private var preImmersiveLayout: some View {
        let isTransitioning = appModel.immersiveSpaceState == .inTransition

        return VStack(spacing: 16) {
            Text("Threshold")
                .font(.title2.bold())

            // Feature icon row
            HStack(spacing: 14) {
                ForEach([
                    ("cube.transparent", "Fractals"),
                    ("hand.raised.fingers.spread", "Gestures"),
                    ("waveform", "Reactive"),
                    ("paintbrush.pointed.fill", "Color"),
                ], id: \.0) { icon, label in
                    VStack(spacing: 5) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.accentColor.opacity(0.14))
                            Image(systemName: icon)
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                        }
                        .frame(width: 44, height: 44)
                        Text(label)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            ToggleImmersiveSpaceButton()
            if isTransitioning {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Compiling shaders — first launch may take a moment…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .transition(.opacity)
            }
        }
        .padding(30)
        .frame(minWidth: 300, idealWidth: 360, maxWidth: isTransitioning ? 400 : 360, minHeight: 220)
    }
    
    // MARK: - Immersive Layout (Sidebar + Content)
    
    private var immersiveLayout: some View {
        VStack(spacing: 10) {
#if os(macOS)
            HStack(spacing: 0) {
                topDockOrnament
                Spacer(minLength: 0)
            }
#endif
            HStack(spacing: 0) {
                // ── LEFT: Context Rail ──
                sectionRail
                
                Divider()
                
                // ── RIGHT: Content Panel ──
                VStack(spacing: 0) {
                    contentPanel
                    
                    Divider()
                    
                    // ── BOTTOM BAR: Persistent controls ──
                    bottomBar
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
#if os(macOS)
    .frame(minWidth: 980, minHeight: 576)
#else
        .frame(minWidth: 980, minHeight: 576)
#endif
    }
    
    // MARK: - Top Dock

    private var topDockBar: some View {
        // Only show Shape, Visualizations, and Music once the immersive space is
        // fully open and startup pipeline warmup has finished — they require an
        // active, ready render session to be meaningful.
        let visibleTabs = TopDockTab.allCases.filter { $0 == .explore || isRendererNavigationReady }
        return HStack(spacing: 10) {
            ForEach(visibleTabs, id: \.self) { tab in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        activateTopDock(tab)
                    }
                } label: {
                    HStack(spacing: 8) {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: tab.icon)
                                .font(.system(size: 15, weight: .semibold))
                            topDockBadge(for: tab)
                        }
                        Text(tab.rawValue)
                            .font(.subheadline.weight(.semibold))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        Capsule()
                            .fill(topDockTab == tab && selectedTab != .gestures && selectedTab != .settings ? Color.blue.opacity(0.18) : Color.clear)
                    )
                    .overlay(
                        Capsule()
                            .strokeBorder(topDockTab == tab && selectedTab != .gestures && selectedTab != .settings ? Color.blue.opacity(0.22) : Color.secondary.opacity(0.14), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .foregroundStyle(topDockTab == tab && selectedTab != .gestures && selectedTab != .settings ? .primary : .secondary)
                .accessibilityAddTraits(topDockTab == tab && selectedTab != .gestures && selectedTab != .settings ? .isSelected : [])
            }
        }
    }

    private var topDockOrnament: some View {
        topDockBar
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.black.opacity(colorScheme == .dark ? 0.82 : 0.72))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.10 : 0.14), lineWidth: 1)
            )
            .thresholdGlassBackground(cornerRadius: 18)
    }

    // MARK: - Context Rail

    private var sectionRail: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 8) {
                    switch topDockTab {
                    case .explore:
                        let exploreSections = ExploreRailSection.allCases.filter { $0 != .customScenes || allowCustomScenes }
                        ForEach(exploreSections, id: \.self) { section in
                            railButton(
                                title: section.rawValue,
                                systemImage: section.icon,
                                isSelected: selectedTab != .gestures && selectedTab != .settings && topDockTab == .explore && exploreRailSection == section,
                                pinControl: pinnedRailControl(for: section)
                            ) {
                                activateExploreSection(section)
                            }
                        }
                    case .shape:
                        ForEach(ShapeRailSection.allCases, id: \.self) { section in
                            railButton(
                                title: section.rawValue,
                                systemImage: section.icon,
                                isSelected: selectedTab != .gestures && selectedTab != .settings && topDockTab == .shape && shapeRailSection == section,
                                pinControl: pinnedRailControl(for: section)
                            ) {
                                activateShapeSection(section)
                            }
                        }
                    case .visualizations:
                        ForEach(VisualizationsRailSection.allCases, id: \.self) { section in
                            railButton(
                                title: section.title,
                                systemImage: section.icon,
                                isSelected: selectedTab != .gestures && selectedTab != .settings && topDockTab == .visualizations && visualizationsRailSection == section,
                                pinControl: pinnedRailControl(for: section)
                            ) {
                                activateVisualizationsSection(section)
                            }
                        }
                    case .music:
                        ForEach(MusicRailSection.availableCases, id: \.self) { section in
                            railButton(
                                title: section.title,
                                systemImage: section.icon,
                                isSelected: selectedTab != .gestures && selectedTab != .settings && topDockTab == .music && musicRailSection == section,
                                pinControl: pinnedRailControl(for: section)
                            ) {
                                activateMusicSection(section)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .frame(maxHeight: .infinity, alignment: .top)

            VStack(spacing: 8) {
                Divider()
                    .padding(.vertical, 4)

                if supportsGestureEditing {
                    railButton(title: "Gestures", systemImage: SidebarTab.gestures.icon, isSelected: selectedTab == .gestures) {
                        selectedTab = .gestures
                    }
                }

                if !pinnedRailControls.isEmpty {
                    Divider()
                        .padding(.vertical, 4)

                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3),
                        alignment: .leading,
                        spacing: 8
                    ) {
                        ForEach(pinnedRailControls, id: \.self) { control in
                            pinnedRailButton(
                                title: control.title,
                                systemImage: control.icon,
                                isSelected: isPinnedRailControlSelected(control),
                                pinControl: control
                            ) {
                                activatePinnedRailControl(control)
                            }
                        }
                    }
                }

                railButton(title: "Settings", systemImage: SidebarTab.settings.icon, isSelected: selectedTab == .settings) {
                    selectedTab = .settings
                }
            }
            .padding(.top, 8)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: 170)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private func topDockBadge(for tab: TopDockTab) -> some View {
        switch tab {
        case .visualizations where activeDynamicEffectCount > 0:
            countBadge(activeDynamicEffectCount, color: .pink)
        case .music where activeMusicPermutationCount > 0:
            countBadge(activeMusicPermutationCount, color: .green)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func railButton(title: String, systemImage: String, isSelected: Bool, pinControl: PinnedRailControl? = nil, action: @escaping () -> Void) -> some View {
        let base = Button {
            if let pinControl, didLongPressPinnedRailControl == pinControl {
                didLongPressPinnedRailControl = nil
                return
            }
            action()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 18)

                Text(title)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? Color.blue.opacity(0.18) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(isSelected ? Color.blue.opacity(0.22) : Color.secondary.opacity(0.10), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? .primary : .secondary)
        .accessibilityAddTraits(isSelected ? .isSelected : [])

        if let pc = pinControl {
            base.simultaneousGesture(
                LongPressGesture(minimumDuration: 0.55, maximumDistance: 24)
                    .onEnded { _ in
                        didLongPressPinnedRailControl = pc
                        togglePinnedRailControl(pc)
                    }
            )
        } else {
            base
        }
    }

    private func pinnedRailButton(title: String, systemImage: String, isSelected: Bool, pinControl: PinnedRailControl, action: @escaping () -> Void) -> some View {
        Button {
            if didLongPressPinnedRailControl == pinControl {
                didLongPressPinnedRailControl = nil
                return
            }
            action()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 38)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(isSelected ? Color.blue.opacity(0.18) : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(isSelected ? Color.blue.opacity(0.22) : Color.secondary.opacity(0.10), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? .primary : .secondary)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.55, maximumDistance: 24)
                .onEnded { _ in
                    didLongPressPinnedRailControl = pinControl
                    togglePinnedRailControl(pinControl)
                }
        )
    }

    private var pinnedRailControls: [PinnedRailControl] {
        get {
            pinnedRailControlsRaw
                .split(separator: ",")
                .compactMap { PinnedRailControl(rawValue: String($0)) }
                .filter(isSupportedPinnedRailControl)
        }
        nonmutating set {
            pinnedRailControlsRaw = newValue.map(\.rawValue).joined(separator: ",")
        }
    }

    private func isSupportedPinnedRailControl(_ control: PinnedRailControl) -> Bool {
        #if os(macOS)
        switch control {
        case .musicSongs, .musicPlaylists, .musicAlbums:
            return false
        default:
            return true
        }
        #else
        return true
        #endif
    }

    private func countBadge(_ count: Int, color: Color) -> some View {
        Text("\(count)")
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white)
            .frame(minWidth: 15, minHeight: 15)
            .padding(.horizontal, 2)
            .background(Capsule().fill(color))
            .offset(x: 9, y: -7)
            .accessibilityHidden(true)
    }

    private func syncNavigationChromeFromLegacySelectionIfNeeded() {
        guard !skipOuterNavigationSync else { return }
        syncNavigationChromeFromLegacySelection()
    }

    private var isRendererNavigationReady: Bool {
#if os(macOS)
        appModel.rendererStartupWarmupComplete
#else
        appModel.immersiveSpaceState == .open && appModel.rendererStartupWarmupComplete
#endif
    }

    private func dismissMenuWindowIfNeeded() {
#if os(visionOS)
        appModel.markMenuWindowDismissed()
        dismissWindow(id: appModel.menuWindowID)
#endif
    }

    private func activateTopDock(_ tab: TopDockTab) {
        guard tab == .explore || isRendererNavigationReady else {
            activateExploreSection(.jumpingOff)
            return
        }

        switch tab {
        case .explore:
            activateExploreSection(exploreRailSection)
        case .shape:
            activateShapeSection(shapeRailSection)
        case .visualizations:
            activateVisualizationsSection(visualizationsRailSection)
        case .music:
            activateMusicSection(musicRailSection)
        }
    }

    private func activateExploreSection(_ section: ExploreRailSection) {
        topDockTab = .explore
        exploreRailSection = section
        selectedTab = .fractal
        fractalSubTab = .browse
        fractalBrowseTab = section.browseTab
    }

    private func activateShapeSection(_ section: ShapeRailSection) {
        topDockTab = .shape
        shapeRailSection = section
        selectedTab = .fractal
        switch section {
        case .parameters:
            fractalSubTab = .shape
            shapeInnerTab = .parameters
        case .formula:
            fractalSubTab = .shape
            shapeInnerTab = .formula
        case .space:
            fractalSubTab = .space
        case .performance:
            fractalSubTab = .render
        }
    }

    private func activateVisualizationsSection(_ section: VisualizationsRailSection) {
        topDockTab = .visualizations
        visualizationsRailSection = section
        switch section {
        case .color:
            selectedTab = .coloring
            coloringSubTab = .gradient
        case .mapping:
            selectedTab = .coloring
            coloringSubTab = .mapping
        case .grading:
            selectedTab = .coloring
            coloringSubTab = .grading
        case .motion:
            selectedTab = .effects
            effectsSubTab = .dynamic
        case .atmosphere:
            selectedTab = .effects
            effectsSubTab = .static
        case .reactive:
            selectedTab = .music
            musicPanelTab = .visualizations
        }
    }

    private func activateMusicSection(_ section: MusicRailSection) {
        topDockTab = .music
        let resolvedSection: MusicRailSection
        #if os(macOS)
        resolvedSection = .playback
        #else
        resolvedSection = section
        #endif
        musicRailSection = resolvedSection
        selectedTab = .music
        musicPanelTab = resolvedSection.musicPanelTab
    }

    private func togglePinnedRailControl(_ control: PinnedRailControl) {
        var controls = pinnedRailControls
        if let index = controls.firstIndex(of: control) {
            controls.remove(at: index)
        } else {
            controls.append(control)
        }
        pinnedRailControls = controls
    }

    private func isPinnedRailControlSelected(_ control: PinnedRailControl) -> Bool {
        switch control {
        case .exploreJumpingOff:
            return topDockTab == .explore && exploreRailSection == .jumpingOff && selectedTab != .gestures && selectedTab != .settings
        case .exploreMusicReactive:
            return topDockTab == .explore && exploreRailSection == .musicReactive && selectedTab != .gestures && selectedTab != .settings
        case .exploreAnimated:
            return topDockTab == .explore && exploreRailSection == .animated && selectedTab != .gestures && selectedTab != .settings
        case .exploreCustomScenes:
            return topDockTab == .explore && exploreRailSection == .customScenes && selectedTab != .gestures && selectedTab != .settings
        case .shapeParameters:
            return topDockTab == .shape && shapeRailSection == .parameters && selectedTab != .gestures && selectedTab != .settings
        case .shapeFormula:
            return topDockTab == .shape && shapeRailSection == .formula && selectedTab != .gestures && selectedTab != .settings
        case .shapeSpace:
            return topDockTab == .shape && shapeRailSection == .space && selectedTab != .gestures && selectedTab != .settings
        case .shapePerformance:
            return topDockTab == .shape && shapeRailSection == .performance && selectedTab != .gestures && selectedTab != .settings
        case .visualizationsColor:
            return topDockTab == .visualizations && visualizationsRailSection == .color && selectedTab != .gestures && selectedTab != .settings
        case .visualizationsMapping:
            return topDockTab == .visualizations && visualizationsRailSection == .mapping && selectedTab != .gestures && selectedTab != .settings
        case .visualizationsGrading:
            return topDockTab == .visualizations && visualizationsRailSection == .grading && selectedTab != .gestures && selectedTab != .settings
        case .visualizationsMotion:
            return topDockTab == .visualizations && visualizationsRailSection == .motion && selectedTab != .gestures && selectedTab != .settings
        case .visualizationsAtmosphere:
            return topDockTab == .visualizations && visualizationsRailSection == .atmosphere && selectedTab != .gestures && selectedTab != .settings
        case .visualizationsReactive:
            return topDockTab == .visualizations && visualizationsRailSection == .reactive && selectedTab != .gestures && selectedTab != .settings
        case .musicPlayback:
            return topDockTab == .music && musicRailSection == .playback && selectedTab != .gestures && selectedTab != .settings
        case .musicSongs:
            return topDockTab == .music && musicRailSection == .songs && selectedTab != .gestures && selectedTab != .settings
        case .musicPlaylists:
            return topDockTab == .music && musicRailSection == .playlists && selectedTab != .gestures && selectedTab != .settings
        case .musicAlbums:
            return topDockTab == .music && musicRailSection == .albums && selectedTab != .gestures && selectedTab != .settings
        }
    }

    private func activatePinnedRailControl(_ control: PinnedRailControl) {
        withAnimation(.easeInOut(duration: 0.2)) {
            switch control {
            case .exploreJumpingOff:
                activateExploreSection(.jumpingOff)
            case .exploreMusicReactive:
                activateExploreSection(.musicReactive)
            case .exploreAnimated:
                activateExploreSection(.animated)
            case .exploreCustomScenes:
                activateExploreSection(.customScenes)
            case .shapeParameters:
                activateShapeSection(.parameters)
            case .shapeFormula:
                activateShapeSection(.formula)
            case .shapeSpace:
                activateShapeSection(.space)
            case .shapePerformance:
                activateShapeSection(.performance)
            case .visualizationsColor:
                activateVisualizationsSection(.color)
            case .visualizationsMapping:
                activateVisualizationsSection(.mapping)
            case .visualizationsGrading:
                activateVisualizationsSection(.grading)
            case .visualizationsMotion:
                activateVisualizationsSection(.motion)
            case .visualizationsAtmosphere:
                activateVisualizationsSection(.atmosphere)
            case .visualizationsReactive:
                activateVisualizationsSection(.reactive)
            case .musicPlayback:
                activateMusicSection(.playback)
            case .musicSongs:
                activateMusicSection(.songs)
            case .musicPlaylists:
                activateMusicSection(.playlists)
            case .musicAlbums:
                activateMusicSection(.albums)
            }
        }
    }

    private func pinnedRailControl(for section: ExploreRailSection) -> PinnedRailControl {
        switch section {
        case .jumpingOff: return .exploreJumpingOff
        case .musicReactive: return .exploreMusicReactive
        case .animated: return .exploreAnimated
        case .customScenes: return .exploreCustomScenes
        }
    }

    private func pinnedRailControl(for section: ShapeRailSection) -> PinnedRailControl {
        switch section {
        case .parameters: return .shapeParameters
        case .formula: return .shapeFormula
        case .space: return .shapeSpace
        case .performance: return .shapePerformance
        }
    }

    private func pinnedRailControl(for section: VisualizationsRailSection) -> PinnedRailControl {
        switch section {
        case .color: return .visualizationsColor
        case .mapping: return .visualizationsMapping
        case .grading: return .visualizationsGrading
        case .motion: return .visualizationsMotion
        case .atmosphere: return .visualizationsAtmosphere
        case .reactive: return .visualizationsReactive
        }
    }

    private func pinnedRailControl(for section: MusicRailSection) -> PinnedRailControl {
        switch section {
        case .playback: return .musicPlayback
        case .songs: return .musicSongs
        case .playlists: return .musicPlaylists
        case .albums: return .musicAlbums
        }
    }

    private func syncNavigationChromeFromLegacySelection() {
        switch selectedTab {
        case .fractal:
            switch fractalSubTab {
            case .browse:
                topDockTab = .explore
                exploreRailSection = ExploreRailSection.allCases.first(where: { $0.browseTab == fractalBrowseTab }) ?? .jumpingOff
            case .shape:
                topDockTab = .shape
                shapeRailSection = shapeInnerTab == .formula ? .formula : .parameters
            case .space:
                topDockTab = .shape
                shapeRailSection = .space
            case .render:
                topDockTab = .shape
                shapeRailSection = .performance
            }
        case .animate:
            topDockTab = .explore
            exploreRailSection = .customScenes
        case .coloring:
            topDockTab = .visualizations
            switch coloringSubTab {
            case .gradient:
                visualizationsRailSection = .color
            case .mapping:
                visualizationsRailSection = .mapping
            case .grading:
                visualizationsRailSection = .grading
            }
        case .effects:
            topDockTab = .visualizations
            visualizationsRailSection = effectsSubTab == .dynamic ? .motion : .atmosphere
        case .music:
            if musicPanelTab == .visualizations {
                topDockTab = .visualizations
                visualizationsRailSection = .reactive
            } else {
                topDockTab = .music
                #if os(macOS)
                musicRailSection = .playback
                if musicPanelTab != .music {
                    musicPanelTab = .music
                }
                #else
                switch musicPanelTab {
                case .music:       musicRailSection = .playback
                case .songs:       musicRailSection = .songs
                case .playlists:   musicRailSection = .playlists
                case .albums:      musicRailSection = .albums
                case .visualizations: musicRailSection = .playback
                }
                #endif
            }
        case .gestures, .settings:
            break
        }
    }
    
    // MARK: - Content Panel
    
    private var contentPanel: some View {
        Group {
            if appModel.runtimeViewMode == .buddhabrot {
                BuddhabrotControlsView()
            } else {
                switch selectedTab {
                case .fractal:  fractalTabContent
                case .animate:  animateTabContent
                case .coloring: coloringTabContent
                case .effects:  effectsTabContent
                case .music:
                    #if os(macOS)
                    MusicTabContent(cache: cache, musicService: appModel.musicService, audioAnalyzer: appModel.audioAnalyzer, renderSettings: appModel.renderSettings, musicAppCapture: appModel.musicAppCapture, tabSelection: $musicPanelTab)
                    #else
                    MusicTabContent(cache: cache, musicService: appModel.musicService, audioAnalyzer: appModel.audioAnalyzer, renderSettings: appModel.renderSettings, tabSelection: $musicPanelTab)
                    #endif
                case .gestures:
                    if supportsGestureEditing {
                        gesturesTabContent
                    } else {
                        settingsTabContent
                    }
                case .settings: settingsTabContent
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func normalizeDesktopSelectionIfNeeded() {
        guard !supportsGestureEditing, selectedTab == .gestures else { return }
        selectedTab = .fractal
    }
    
    // MARK: - Bottom Bar
    
    private var bottomBar: some View {
        HStack(spacing: 12) {
            activityTrafficLights

            ToggleImmersiveSpaceButton()
                .frame(minWidth: 260, alignment: .leading)

            Spacer(minLength: 12)

            HStack(spacing: 12) {
                if let animationManager = appModel.animationManager {
                    LiveSessionRecordingControl(animationManager: animationManager, compact: true)
                        .disabled(animationManager.isPlaying)
                }

                HoldToSaveResetButton(
                    onTapReset: resetCurrentFractalSettings,
                    onHoldReady: {
                        showSaveDestinationSheet = true
                    }
                )
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var activityTrafficLights: some View {
        HStack(spacing: 6) {
            ActivityLightButton(
                title: "Music permutations",
                systemImage: "waveform",
                color: .blue,
                isActive: activeMusicPermutationCount > 0,
                count: activeMusicPermutationCount > 0 ? activeMusicPermutationCount : nil,
                action: toggleMusicPermutationsActive
            )
            ActivityLightButton(
                title: "Dynamic color",
                systemImage: "sparkles",
                color: .pink,
                isActive: activeDynamicEffectCount > 0,
                count: activeDynamicEffectCount > 0 ? activeDynamicEffectCount : nil,
                action: toggleDynamicEffectsActive
            )
            ActivityLightButton(
                title: "Playback",
                systemImage: isAnimationPlaying ? "pause.fill" : "play.fill",
                color: .orange,
                isActive: isAnimationPlaying,
                count: nil,
                action: toggleAnimationPlaybackActive
            )
            ActivityLightButton(
                title: "Kill switch",
                systemImage: animationKillSwitchTask == nil ? "stop.circle" : "stop.circle.fill",
                color: .red,
                isActive: hasActiveAnimationSystems,
                count: nil,
                action: engageAnimationKillSwitch
            )
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.secondary.opacity(0.08)))
        .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.14), lineWidth: 1))
        .help("Quick toggles for music permutations, dynamic color, playback, and the global kill switch")
    }

    private func toggleMusicPermutationsActive() {
        let shouldEnable = activeMusicPermutationCount == 0
        setMusicPermutationsEnabled(shouldEnable)
    }

    private func setMusicPermutationsEnabled(_ enabled: Bool) {
        cache.audioReactive.fractalAudioReactiveEnabled = enabled
        cache.push(\.fractalAudioReactiveEnabled, value: enabled)

        if enabled {
            cache.display.lightingMode = .audioReactive
            cache.push(\.lightingMode, value: .audioReactive)
            if cache.audioReactive.musicReactiveMappings.isEmpty {
                applyAudioReactivityPreset(.ambient)
            }
        }
    }

    private func applyAudioReactivityPreset(_ preset: ReactivityPreset) {
        let settings = preset.settings
        cache.audioReactive.fractalAudioAmount = settings.audioAmount
        cache.audioReactive.fractalBeatPunch = settings.beatPunch
        cache.audioReactive.bassSensitivity = settings.bassSensitivity
        cache.audioReactive.midSensitivity = settings.midSensitivity
        cache.audioReactive.trebleSensitivity = settings.trebleSensitivity
        cache.audioReactive.beatSensitivity = settings.beatSensitivity
        cache.push(\.fractalAudioAmount, value: settings.audioAmount)
        cache.push(\.fractalBeatPunch, value: settings.beatPunch)
        cache.push(\.bassSensitivity, value: settings.bassSensitivity)
        cache.push(\.midSensitivity, value: settings.midSensitivity)
        cache.push(\.trebleSensitivity, value: settings.trebleSensitivity)
        cache.push(\.beatSensitivity, value: settings.beatSensitivity)

        let mappings = preset.defaultMappings(for: cache.fractalType)
        cache.audioReactive.musicReactiveMappings = mappings
        cache.push(\.musicReactiveMappings, value: mappings)
    }

    private func toggleAnimationPlaybackActive() {
        guard let animationManager = appModel.animationManager else { return }
        if isAnimationPlaying {
            animationManager.stop()
            return
        }

        if animationManager.currentScene?.keyframes.count ?? 0 < 2 {
            animationManager.currentScene = animationManager.scenes.first { $0.keyframes.count >= 2 }
        }
        animationManager.play()
    }

    private func toggleDynamicEffectsActive() {
        if activeDynamicEffectCount > 0 {
            disableDynamicEffects()
        } else {
            enableDefaultDynamicEffects()
        }

        cache.lighting.lightingPreset = .custom
        cache.push(\.lightingPreset, value: .custom)
    }

    private func engageAnimationKillSwitch() {
        guard hasActiveAnimationSystems, animationKillSwitchTask == nil else { return }

        appModel.renderSettings.beginAnimationKillSwitch(duration: animationKillSwitchDuration)
        animationKillSwitchTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(animationKillSwitchDuration * 1_000_000_000))
            finalizeAnimationKillSwitch()
        }
    }

    private func finalizeAnimationKillSwitch() {
        animationKillSwitchTask?.cancel()
        animationKillSwitchTask = nil

        appModel.animationManager?.stop()
        setMusicPermutationsEnabled(false)
        disableDynamicEffects()
        appModel.parameterPipeline.clearMusicLayers(settings: appModel.renderSettings)
        appModel.renderSettings.cancelAnimationKillSwitch()
    }

    private func disableDynamicEffects() {
        cache.lighting.gradientCycleEffect.enabled = false
        cache.commitGradientCycleEffect()

        cache.lighting.hueRotationEffect.enabled = false
        cache.commitHueRotationEffect()

        cache.lighting.pulseEffect.enabled = false
        cache.commitPulseEffect()

        cache.lighting.beatFlashEffect.enabled = false
        cache.commitBeatFlashEffect()

        cache.lighting.polarRotationEffect.direction = .off
        cache.push(\.polarRotationEffect, value: cache.lighting.polarRotationEffect)

        cache.lighting.juliaDriftEffect.enabled = false
        cache.commitJuliaDriftEffect()

        cache.lighting.lightingPreset = .custom
        cache.push(\.lightingPreset, value: .custom)
    }

    private func enableDefaultDynamicEffects() {
        cache.lighting.gradientCycleEffect = .slow
        cache.commitGradientCycleEffect()

        cache.lighting.hueRotationEffect = .subtle
        cache.commitHueRotationEffect()

        cache.lighting.pulseEffect = .subtle
        cache.commitPulseEffect()

        cache.lighting.lightingPreset = .custom
        cache.push(\.lightingPreset, value: .custom)
    }
    
    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Fractal Tab
    // ═══════════════════════════════════════════════════════════════════════════
    
    private var fractalTabContent: some View {
        VStack(spacing: 0) {
            switch fractalSubTab {
            case .browse:
                FractalGridView(
                    cache: cache,
                    gestureController: appModel.gestureController,
                    animationManager: appModel.animationManager,
                    presetManager: appModel.presetManager,
                    tabSelection: $fractalBrowseTab,
                    onEditScene: openAnimationEditor,
                    onLoadAnimationScene: { _ in
                        appModel.dismissMenuWindowForSceneLoad()
                    },
                    onLoadStaticScene: { preset in
                        Task { @MainActor in
                            customSceneDiagnostic("🔬 [CSDiag] ContentView.onLoadStaticScene name='\(preset.name)' ft=\(preset.fractalType.rawValue) embeddedFormula=\(preset.embeddedFormula?.name ?? "nil")")
                            if let formula = preset.embeddedFormula {
                                let installed = await appModel.installEmbeddedFormulaIfNeededAndWait(formula)
                                customSceneDiagnostic("🔬 [CSDiag] ContentView.onLoadStaticScene installEmbeddedFormula returned \(installed)")
                                guard installed else { return }
                            } else {
                                appModel.uninstallEmbeddedFormula()
                            }

                            if preset.embeddedFormula != nil {
                                await appModel.preparePipelineHandler?(preset)
                                customSceneDiagnostic("🔬 [CSDiag] ContentView.onLoadStaticScene preparePipelineHandler completed; loading preset NOW")
                            } else {
                                Task { await appModel.preparePipelineHandler?(preset) }
                                customSceneDiagnostic("🔬 [CSDiag] ContentView.onLoadStaticScene preparePipelineHandler dispatched (fire-and-forget); loading preset NOW")
                            }
                            appModel.presetManager.loadPreset(
                                preset,
                                into: appModel.renderSettings,
                                resetEnvironment: true
                            )
                            applyPresetGestureOverridesIfNeeded(for: preset)
                            appModel.gestureController?.syncWithSettings()
                            appModel.rememberActiveResetPreset(preset)
                            cache.loadFromSettings()
                        }
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .shape:
                ScrollView(.vertical, showsIndicators: true) {
                    Group {
                        switch shapeInnerTab {
                        case .parameters:
                            fractalShapeContent
                        case .formula:
                            fractalFormulaContent
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }

            case .space:
                ScrollView(.vertical, showsIndicators: true) {
                    fractalSpaceContent
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                }

            case .render:
                ScrollView(.vertical, showsIndicators: true) {
                    fractalQualityContent
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                }
            }
        }
    }
    
    private var fractalShapeContent: some View {
        VStack(spacing: 12) {
            HStack {
                Label(cache.fractalType.displayName, systemImage: cache.fractalType.icon)
                    .font(.headline)
                Spacer()
            }

            Divider()

            // Formula-specific parameters (auto-generated from catalog.json)
            FormulaParamsEditor(cache: cache)

            if hasShapeMusicMapping {
                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Label("Music Shape Control", systemImage: "waveform.path")
                            .font(.headline)
                        if hasFlashingMusicVisuals {
                            FlashingLightIndicator()
                                .help("Current music mappings can produce flashing or rapidly changing light.")
                        }
                        Spacer()
                    }

                    Text("Global music amount for iteration and shape-parameter mappings.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    EffectSliderRow(icon: "waveform.circle", label: "Music Amount",
                        value: Binding(
                            get: { cache.audioReactive.fractalAudioAmount },
                            set: { newValue in
                                cache.audioReactive.fractalAudioAmount = newValue
                                cache.push(\.fractalAudioAmount, value: newValue)
                            }
                        ), range: 0...1,
                        enabled: .constant(true),
                        onChanged: { cache.push(\.fractalAudioAmount, value: cache.audioReactive.fractalAudioAmount) },
                        showToggle: false)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.indigo.opacity(0.08)))
            }

            // Scale slider — only visible for Mandelbox (the only fractal whose
            // distance estimator uses this uniform).
            if cache.fractalType == .mandelbox {
                Divider()
                EffectSliderRow(icon: "arrow.up.left.and.arrow.down.right", label: "Scale",
                    value: $cache.fractalScale, range: -3.0...5.0,
                    enabled: .constant(true),
                    onChanged: { cache.push(\.targetFractalScale, value: cache.fractalScale) },
                    showToggle: false)
            }
        }
    }

    private var fractalFormulaContent: some View {
        VStack(spacing: 12) {
            HStack {
                Label("Fractal Formula", systemImage: "function")
                    .font(.headline)
                Spacer()
                Text(cache.fractalType.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Text("Pick the distance estimator. Switching formulas resets shape parameters to that formula's defaults.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)

            FractalFormulaGrid(cache: cache, gestureController: appModel.gestureController)
        }
    }

    @ViewBuilder
    private var fractalSpaceContent: some View {
        let rotationEuler = eulerAngles(from: cache.liveWorldRotation)

        VStack(spacing: 12) {
            // ── Safety Bubble ────────────────────────────────────────────────
            VStack(spacing: 8) {
                HStack {
                    Label("Safety Bubble", systemImage: "shield.lefthalf.filled").font(.headline)
                    Spacer()
                    Toggle("", isOn: $cache.safetyBubble.enabled)
                        .labelsHidden()
                        .onChange(of: cache.safetyBubble.enabled) { _, val in
                            cache.push(\.safetyBubbleEnabled, value: val)
                        }
                }
                Text("Prevents the camera from entering the fractal geometry. Works with all fractal types.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if cache.safetyBubble.enabled {
                    EffectSliderRow(icon: "circle.dashed", label: "Inner Radius",
                        value: $cache.safetyBubble.radius, range: 0.5...2.5,
                        enabled: .constant(true),
                        onChanged: { cache.push(\.safetyBubbleRadius, value: cache.safetyBubble.radius) },
                        showToggle: false)
                    let selectedBubbleFamily = SafetyBubbleShapePreset.family(for: cache.safetyBubble.shape)
                    HStack {
                        Text("Shape"); Spacer()
                        Picker("Shape", selection: Binding<SafetyBubbleShapeFamily>(
                            get: { selectedBubbleFamily },
                            set: { family in
                                let newValue = SafetyBubbleShapePreset.storedValue(for: family, currentValue: cache.safetyBubble.shape)
                                cache.safetyBubble.shape = newValue
                                cache.push(\.safetyBubbleShape, value: newValue)
                            }
                        )) {
                            ForEach(SafetyBubbleShapeFamily.allCases) { family in
                                Text(family.rawValue).tag(family)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 260)
                    }
                    if selectedBubbleFamily == .platonic {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Platonic")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)

                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], spacing: 8) {
                                ForEach(SafetyBubbleShapePreset.platonicOptions) { preset in
                                    let isSelected = SafetyBubbleShapePreset(storedValue: cache.safetyBubble.shape) == preset

                                    Button {
                                        cache.safetyBubble.shape = preset.storedValue
                                        cache.push(\.safetyBubbleShape, value: preset.storedValue)
                                    } label: {
                                        Text(preset.displayName)
                                            .font(.caption.weight(.semibold))
                                            .frame(maxWidth: .infinity)
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 8)
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(isSelected ? Color.black : Color.primary)
                                    .background(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .fill(isSelected ? Color.white.opacity(0.88) : Color.white.opacity(0.08))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .strokeBorder(Color.white.opacity(isSelected ? 0.14 : 0.08), lineWidth: 1)
                                    )
                                }
                            }
                        }
                    }
                    
                    Divider()
                    
                    Text("Controls how strongly the bubble masks fractal geometry. Fine control at low values.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Label("Blend mode cost varies by scene/fractal/zoom — different values can be expensive in different conditions (Mandelbox often runs better with Blend off, but can behave differently when zoomed in).", systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    EffectSliderRow(icon: "circle.righthalf.filled", label: "Blend",
                        value: Binding<Float>(
                            get: { 1.0 - UISettingsCache.blendValueToSlider(cache.safetyBubble.strength) },
                            set: { cache.safetyBubble.strength = UISettingsCache.blendSliderToValue(1.0 - $0) }
                        ), range: 0.0...1.0,
                        enabled: .constant(true),
                        onChanged: { cache.push(\.safetyBubbleBlend, value: cache.safetyBubble.strength) },
                        showToggle: false)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.green.opacity(0.06)))

            sphericalInversionSection

            // ── Detail (Grab Gesture Transform) ──────────────────────────────
            VStack(spacing: 8) {
                HStack {
                    Label("Detail", systemImage: "move.3d").font(.headline)
                    Spacer()
                    Button {
                        appModel.renderSettings.resetDetailTransform()
                    } label: {
                        Label("Reset", systemImage: "arrow.counterclockwise")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .tint(.orange)
                    .controlSize(.small)
                }
                Text("Orientation and zoom controlled by the grab gesture (both hands pinch).")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                
                HStack {
                    Label("Zoom", systemImage: "magnifyingglass").font(.caption)
                    Spacer()
                    Text(String(format: "%.2f×", cache.liveDetailScale))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                EffectSliderRow(icon: "arrow.up.left.and.arrow.down.right", label: "Stretch",
                    value: Binding(
                        get: { cache.liveDetailScale },
                        set: { setDetailScale($0) }
                    ), range: 0.05...20.0,
                    enabled: .constant(true),
                    onChanged: {},
                    showToggle: false)
                
                HStack {
                    Label("Rotation", systemImage: "rotate.3d").font(.caption)
                    Spacer()
                    Text(String(format: "%.0f° %.0f° %.0f°", rotationEuler.x, rotationEuler.y, rotationEuler.z))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                EffectSliderRow(icon: "arrow.left.and.right", label: "Pitch",
                    value: Binding(
                        get: { rotationEuler.x },
                        set: { newValue in
                            var e = rotationEuler
                            e.x = newValue
                            setDetailRotationEuler(e)
                        }
                    ), range: -180...180,
                    enabled: .constant(true),
                    onChanged: {},
                    showToggle: false)

                EffectSliderRow(icon: "arrow.clockwise", label: "Yaw",
                    value: Binding(
                        get: { rotationEuler.y },
                        set: { newValue in
                            var e = rotationEuler
                            e.y = newValue
                            setDetailRotationEuler(e)
                        }
                    ), range: -180...180,
                    enabled: .constant(true),
                    onChanged: {},
                    showToggle: false)

                EffectSliderRow(icon: "arrow.up.and.down", label: "Roll",
                    value: Binding(
                        get: { rotationEuler.z },
                        set: { newValue in
                            var e = rotationEuler
                            e.z = newValue
                            setDetailRotationEuler(e)
                        }
                    ), range: -180...180,
                    enabled: .constant(true),
                    onChanged: {},
                    showToggle: false)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.purple.opacity(0.06)))
        }
    }

    private var sphericalInversionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Spherical Inversion", systemImage: "circle.dashed.inset.filled")
                    .font(.headline)
                Spacer()
            }

            Text("Warp space around a radius before the fractal is sampled. Useful for folded-inside-out spatial compositions.")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Picker("Spherical Inversion", selection: Binding(
                get: { cache.display.sphericalInversionMode },
                set: { newValue in
                    cache.display.sphericalInversionMode = newValue
                    cache.commitSphericalInversion()
                }
            )) {
                ForEach(SphericalInversionMode.allCases, id: \.rawValue) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if cache.display.sphericalInversionMode != .off {
                EffectSliderRow(icon: "circle", label: "Inversion Radius",
                    value: Binding(get: { cache.display.sphericalInversionRadius }, set: { cache.display.sphericalInversionRadius = $0 }),
                    range: 0.5...6.0,
                    enabled: Binding(get: { cache.display.sphericalInversionMode != .off }, set: { isEnabled in
                        cache.display.sphericalInversionMode = isEnabled ? .outwardIn : .off
                        cache.commitSphericalInversion()
                    }),
                    onChanged: { cache.commitSphericalInversion() })
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.indigo.opacity(0.06)))
    }
    
    private var fractalQualityContent: some View {
        VStack(spacing: 12) {
            HStack {
                Label("Performance", systemImage: "gauge")
                    .font(.headline)
                Spacer()
                FPSIndicatorView()
            }

            // ── Renderer Mode ──
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Renderer Mode")
                    Spacer()
                    Text(RendererModeOption.from(tileSize: cache.quality.tileSize).rawValue)
                        .fontWeight(.bold)
                }

                Picker("Renderer Mode", selection: Binding(
                    get: { RendererModeOption.from(tileSize: cache.quality.tileSize) },
                    set: { newMode in
                        guard cache.quality.tileSize != newMode.tileSize else { return }
                        cache.quality.tileSize = newMode.tileSize
                        cache.push(\.tileSize, value: newMode.tileSize)

                        // Default to full detail budget when switching render modes.
                        cache.quality.resolutionScale = 1.0
                        cache.push(\.resolutionScale, value: 1.0)
                        appModel.preparePipeline(
                            iterations: cache.quality.baseFractalIterations,
                            raySteps: cache.quality.baseMaxRaySteps
                        )
                    }
                )) {
                    ForEach(RendererModeOption.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Text(RendererModeOption.from(tileSize: cache.quality.tileSize).helperText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Target Condition")
                    Spacer()
                    Picker("Budget Goal", selection: Binding(
                        get: { qualityGoalPreference },
                        set: { newValue in
                            qualityGoalPreferenceRaw = newValue.rawValue
                            if newValue == .framerate || newValue == .detail {
                                qualityGoalLastDirectPreferenceRaw = newValue.rawValue
                            }
                        }
                    )) {
                        ForEach(QualityGoalPreference.allCases, id: \.rawValue) { goal in
                            Text(goal.displayName).tag(goal)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 340)
                }
                Text("Framerate and Detail apply curated presets. Control unlocks free-form iteration and resolution sliders.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text("Iteration Budget")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
            if qualityGoalPreference != .control {
                HStack(spacing: 8) {
                    ForEach(QualityPreset.allCases, id: \.rawValue) { preset in
                        Button {
                            let values = preset.values(for: cache.fractalType)
                            cache.quality.baseFractalIterations = values.fractalIterations
                            cache.quality.baseMaxRaySteps = values.raySteps
                            cache.push(\.baseFractalIterations, value: values.fractalIterations)
                            cache.push(\.baseMaxRaySteps, value: values.raySteps)
                            appModel.animationManager?.markIterationBudgetUserOverridden()
                            appModel.preparePipeline(iterations: values.fractalIterations, raySteps: values.raySteps)
                        } label: {
                            VStack(spacing: 2) {
                                Image(systemName: preset.icon).font(.caption)
                                Text(preset.displayName).font(.caption2)
                            }
                            .frame(maxWidth: .infinity).padding(.vertical, 6)
                        }
                        .buttonStyle(.bordered)
                        .tint(QualityPreset.detect(
                            fractalIterations: cache.quality.baseFractalIterations,
                            raySteps: cache.quality.baseMaxRaySteps,
                            fractalType: cache.fractalType
                        ) == preset ? .blue : .secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack { Text("Fractal Iterations"); Spacer(); Text("\(cache.quality.baseFractalIterations)").fontWeight(.bold).monospacedDigit() }
                        Slider(value: Binding(
                            get: { Float(cache.quality.baseFractalIterations) },
                            set: {
                                cache.quality.baseFractalIterations = Int($0)
                                cache.push(\.baseFractalIterations, value: Int($0))
                                appModel.animationManager?.markIterationBudgetUserOverridden()
                            }
                        ), in: 4...32, step: 1, onEditingChanged: { isEditing in
                            guard !isEditing else { return }
                            appModel.preparePipeline(
                                iterations: cache.quality.baseFractalIterations,
                                raySteps: cache.quality.baseMaxRaySteps
                            )
                        })
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack { Text("Max Ray Steps"); Spacer(); Text("\(cache.quality.baseMaxRaySteps)").fontWeight(.bold).monospacedDigit() }
                        Slider(value: Binding(
                            get: { Float(cache.quality.baseMaxRaySteps) },
                            set: {
                                cache.quality.baseMaxRaySteps = Int($0)
                                cache.push(\.baseMaxRaySteps, value: Int($0))
                                appModel.animationManager?.markIterationBudgetUserOverridden()
                            }
                        ), in: 32...200, step: 8, onEditingChanged: { isEditing in
                            guard !isEditing else { return }
                            appModel.preparePipeline(
                                iterations: cache.quality.baseFractalIterations,
                                raySteps: cache.quality.baseMaxRaySteps
                            )
                        })
                    }
                }
            }

            // ── Detail/Framerate Budget ──
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(effectiveDirectBudgetLabel)
                    Spacer()
                    Text("\(Int(cache.quality.resolutionScale * 100))%")
                        .fontWeight(.bold)
                        .monospacedDigit()
                }

                if qualityGoalPreference != .control {
                    HStack(spacing: 8) {
                        let presets: [(label: String, scale: Float, icon: String?)] = {
                            // Shared labels (must match Iteration Budget wording): Low / Medium / High / Full
                            let items: [(String, Float, String, String)] = [
                                // Detail mode: use a dashed screen outline + inner grid to convey pixel density.
                                ("Low", 0.33, "circle.grid.2x2", QualityPreset.low.icon),
                                ("Medium", 0.50, "circle.grid.3x3", QualityPreset.medium.icon),
                                ("High", 0.75, "circle.grid.3x3.fill", QualityPreset.high.icon),
                                ("Full", 1.0, "circle.grid.3x3.circle.fill", QualityPreset.ultra.icon)
                            ]

                            switch effectiveDirectBudgetPreference {
                            case .detail:
                                // Increasing detail left-to-right.
                                return items.map { (label: $0.0, scale: $0.1, icon: $0.2) }
                            case .framerate:
                                // Keep scale/order behavior, but label by framerate budget semantics.
                                // Left→right should read Low/Medium/High/Full for framerate.
                                let scalesAndIcons = items.reversed().map { (scale: $0.1, icon: $0.3) }
                                let framerateLabels = ["Low", "Medium", "High", "Full"]
                                return zip(framerateLabels, scalesAndIcons).map { pair in
                                    (label: pair.0, scale: pair.1.scale, icon: pair.1.icon)
                                }
                            case .control:
                                // Unreachable because we normalize control to the last direct preference.
                                return items.map { (label: $0.0, scale: $0.1, icon: $0.2) }
                            }
                        }()

                        ForEach(presets, id: \.label) { preset in
                            Button {
                                cache.quality.resolutionScale = preset.scale
                                cache.push(\.resolutionScale, value: preset.scale)
                            } label: {
                                VStack(spacing: 2) {
                                    if let icon = preset.icon {
                                        if effectiveDirectBudgetPreference == .framerate {
                                            Image(systemName: icon).font(.caption)
                                        } else {
                                            ZStack {
                                                Image(systemName: "rectangle.dashed")
                                                    .font(.caption)
                                                Image(systemName: icon)
                                                    .font(.caption2)
                                            }
                                        }
                                    }
                                    Text(preset.label).font(.caption2)
                                    Text("\(Int(preset.scale * 100))%").font(.caption.monospacedDigit())
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                            }
                            .buttonStyle(.bordered)
                            .tint(abs(cache.quality.resolutionScale - preset.scale) < 0.01 ? .blue : .secondary)
                            .disabled(cache.quality.tileSize == 8)
                        }
                    }
                }

                if qualityGoalPreference == .control {
                    Slider(value: Binding(
                        get: { cache.quality.resolutionScale },
                        set: { newValue in
                            let snapped = (newValue * 100).rounded() / 100
                            cache.quality.resolutionScale = snapped
                            cache.push(\.resolutionScale, value: snapped)
                        }
                    ), in: 0.33...1.0, step: 0.01)
                    .disabled(cache.quality.tileSize == 8)
                }

                if cache.quality.tileSize == 8 {
                    Text(effectiveDirectBudgetUnavailableText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("MetalFX on visionOS is spatial-only. 75% to 85% is the usual quality/performance sweet spot.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            
            Divider()
        }
    }
    
    private func setDetailScale(_ value: Float) {
        let clamped = max(0.05, min(20.0, value))
        appModel.renderSettings.detailScale = clamped
        appModel.renderSettings.targetDetailScale = clamped
        cache.liveDetailScale = clamped
    }

    private func setDetailRotationEuler(_ eulerDegrees: SIMD3<Float>) {
        let q = quaternionFromEulerDegrees(eulerDegrees)
        appModel.renderSettings.worldRotation = q
        appModel.renderSettings.targetWorldRotation = q
        cache.liveWorldRotation = q
    }
    
    /// Extract Euler angles (degrees) from a quaternion for display.
    private func eulerAngles(from q: simd_quatf) -> SIMD3<Float> {
        let sinP = 2.0 * (q.real * q.imag.y - q.imag.z * q.imag.x)
        let pitch: Float
        if abs(sinP) >= 1 {
            pitch = copysign(.pi / 2, sinP)
        } else {
            pitch = asin(sinP)
        }
        let sinYCosP = 2.0 * (q.real * q.imag.z + q.imag.x * q.imag.y)
        let cosYCosP = 1.0 - 2.0 * (q.imag.y * q.imag.y + q.imag.z * q.imag.z)
        let yaw = atan2(sinYCosP, cosYCosP)
        let sinRCosP = 2.0 * (q.real * q.imag.x + q.imag.y * q.imag.z)
        let cosRCosP = 1.0 - 2.0 * (q.imag.x * q.imag.x + q.imag.y * q.imag.y)
        let roll = atan2(sinRCosP, cosRCosP)
        let toDeg: Float = 180.0 / .pi
        return SIMD3<Float>(pitch * toDeg, yaw * toDeg, roll * toDeg)
    }

    /// Build quaternion from Euler angles in degrees using the same convention
    /// as eulerAngles(from:): x=pitch(Y-axis), y=yaw(Z-axis), z=roll(X-axis).
    private func quaternionFromEulerDegrees(_ euler: SIMD3<Float>) -> simd_quatf {
        let toRad: Float = .pi / 180.0
        let pitchY = euler.x * toRad
        let yawZ = euler.y * toRad
        let rollX = euler.z * toRad

        let qx = simd_quatf(angle: rollX, axis: SIMD3<Float>(1, 0, 0))
        let qy = simd_quatf(angle: pitchY, axis: SIMD3<Float>(0, 1, 0))
        let qz = simd_quatf(angle: yawZ, axis: SIMD3<Float>(0, 0, 1))

        return (qz * qy * qx).normalized
    }

    private var gesturePictographicAssignmentPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Hand Assignments", systemImage: "hand.point.up.left.and.text")
                .font(.subheadline.weight(.semibold))

            HStack(spacing: 10) {
                singleHandGesturePictograph(.left)
                singleHandGesturePictograph(.right)
            }

            Text("Tap a fingertip to map vertical and horizontal single-finger gestures.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func singleHandGesturePictograph(_ handMode: GestureHandMode) -> some View {
        VStack(spacing: 8) {
            Label(handMode.displayName, systemImage: handMode.icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.secondary.opacity(0.08))

                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 44, weight: .regular))
                    .foregroundStyle(.secondary.opacity(0.30))
                    .scaleEffect(x: handMode == .left ? -1 : 1, y: 1)
                    .offset(y: 10)

                HStack(spacing: 8) {
                    ForEach(FingerDigit.allCases, id: \.self) { finger in
                        singleFingerTipAssignmentButton(handMode: handMode, finger: finger)
                    }
                }
                .offset(y: -26)
            }
            .frame(height: 112)

            VStack(spacing: 4) {
                ForEach(FingerDigit.allCases, id: \.self) { finger in
                    singleFingerMappingSummaryRow(handMode: handMode, finger: finger)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func singleFingerTipAssignmentButton(handMode: GestureHandMode, finger: FingerDigit) -> some View {
        let verticalSlot = GestureSlot(hand: handMode, finger: finger, direction: .vertical)
        let horizontalSlot = GestureSlot(hand: handMode, finger: finger, direction: .horizontal)
        let verticalBinding = cache.gestureBinding(for: verticalSlot)
        let horizontalBinding = cache.gestureBinding(for: horizontalSlot)
        let bindings = GestureActionBinding.availableBindings(for: cache.fractalType, handMode: handMode)

        return Menu {
            Section("Vertical") {
                ForEach(bindings, id: \.self) { action in
                    Button {
                        cache.setGestureBinding(action, for: verticalSlot)
                    } label: {
                        HStack {
                            Label(action.contextualDisplayName(for: cache.fractalType), systemImage: action.icon)
                            if verticalBinding == action {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }

            Section("Horizontal") {
                ForEach(bindings, id: \.self) { action in
                    Button {
                        cache.setGestureBinding(action, for: horizontalSlot)
                    } label: {
                        HStack {
                            Label(action.contextualDisplayName(for: cache.fractalType), systemImage: action.icon)
                            if horizontalBinding == action {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }

            if verticalBinding != .core(.none) || horizontalBinding != .core(.none) {
                Divider()
                Button("Clear Finger Mappings", role: .destructive) {
                    cache.setGestureBinding(.core(.none), for: verticalSlot)
                    cache.setGestureBinding(.core(.none), for: horizontalSlot)
                }
            }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: finger.icon)
                    .font(.caption)
                HStack(spacing: 4) {
                    Image(systemName: verticalBinding.icon)
                        .font(.caption2)
                    Image(systemName: horizontalBinding.icon)
                        .font(.caption2)
                }
            }
            .frame(width: 34, height: 38)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.blue.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.blue.opacity(0.3), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func singleFingerMappingSummaryRow(handMode: GestureHandMode, finger: FingerDigit) -> some View {
        let verticalSlot = GestureSlot(hand: handMode, finger: finger, direction: .vertical)
        let horizontalSlot = GestureSlot(hand: handMode, finger: finger, direction: .horizontal)
        let verticalBinding = cache.gestureBinding(for: verticalSlot)
        let horizontalBinding = cache.gestureBinding(for: horizontalSlot)

        return HStack(spacing: 6) {
            Text(finger.displayName)
                .font(.caption2.weight(.semibold))
                .frame(width: 46, alignment: .leading)

            Text("V")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(verticalBinding.contextualDisplayName(for: cache.fractalType))
                .font(.caption2)
                .lineLimit(1)

            Text("H")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)

            Text(horizontalBinding.contextualDisplayName(for: cache.fractalType))
                .font(.caption2)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func gestureHandSection(mode: GestureHandMode) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(mode.displayName, systemImage: mode.icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 4)

            if mode == .both {
                ForEach(FingerDigit.allCases, id: \.self) { finger in
                    let slot = GestureSlot(hand: mode, finger: finger)
                    gestureSlotPicker(slot: slot, handMode: mode)
                }
            } else {
                ForEach(FingerDigit.allCases, id: \.self) { finger in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(finger.displayName)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)

                        let verticalSlot = GestureSlot(hand: mode, finger: finger, direction: .vertical)
                        gestureSlotPicker(slot: verticalSlot, handMode: mode, directionLabel: "↕")

                        let horizontalSlot = GestureSlot(hand: mode, finger: finger, direction: .horizontal)
                        gestureSlotPicker(slot: horizontalSlot, handMode: mode, directionLabel: "↔")
                    }
                }
            }
        }
    }

    /// Picker row for assigning a gesture binding to a hand+finger slot.
    @ViewBuilder
    private func gestureSlotPicker(slot: GestureSlot, handMode: GestureHandMode, directionLabel: String? = nil) -> some View {
        let bindings = GestureActionBinding.availableBindings(for: cache.fractalType, handMode: handMode)
        let currentBinding = Binding<GestureActionBinding>(
            get: { cache.gestureBinding(for: slot) },
            set: { cache.setGestureBinding($0, for: slot) }
        )
        HStack {
            if let directionLabel {
                Text(directionLabel)
                    .font(.caption2)
                    .frame(width: 16)
                    .foregroundStyle(.secondary)
            }
            if handMode == .both {
                Label(slot.finger.displayName, systemImage: slot.finger.icon).font(.subheadline)
            }
            Spacer()
            Picker(slot.finger.displayName, selection: currentBinding) {
                ForEach(bindings, id: \.self) { action in
                    Label(action.contextualDisplayName(for: cache.fractalType), systemImage: action.icon).tag(action)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 220)
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Animate Tab
    // ═══════════════════════════════════════════════════════════════════════════
    
    private var animateTabContent: some View {
        VStack(spacing: 0) {
            animateToolbar
            animatePlayContent
        }
    }

    private var animateToolbar: some View {
        HStack(spacing: 10) {
            Label("Scenes", systemImage: "film.stack")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            Spacer()

            Picker("Mode", selection: Binding(
                get: { animateEditButtonsVisible ? 1 : 0 },
                set: { newValue in
                    withAnimation(.snappy(duration: 0.22, extraBounce: 0.10)) {
                        animateEditButtonsVisible = (newValue == 1)
                    }
                    if newValue == 0 {
                        dismissWindow(id: AppModel.animationEditorWindowID)
                    }
                }
            )) {
                Text("Play").tag(0)
                Text("Edit").tag(1)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 170)

            if animateEditButtonsVisible {
                Button {
                    openAnimationEditor()
                } label: {
                    Image(systemName: "plus")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.blue)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Color.blue.opacity(0.14)))
                        .overlay(Circle().stroke(Color.blue.opacity(0.30), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.22, extraBounce: 0.10), value: animateEditButtonsVisible)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
    
    private var animatePlayContent: some View {
        VStack(spacing: 0) {
            if let animationManager = appModel.animationManager {
                List {
                    if animationManager.scenes.isEmpty {
                        ContentUnavailableView("No Scenes", systemImage: "film.stack",
                            description: Text("Open Scene Editor to create animation scenes"))
                    } else {
                        ForEach(animationManager.scenes) { scene in
                            SceneRowView(
                                scene: scene,
                                isSelected: animationManager.currentScene?.id == scene.id,
                                isDefault: animationManager.isDefaultScene(scene),
                                isEdited: animationManager.isEditedDefault(scene),
                                onSelect: { animationManager.currentScene = scene },
                                onEdit: animateEditButtonsVisible ? {
                                    openAnimationEditor(for: scene)
                                } : nil,
                                onPlay: animateEditButtonsVisible ? nil : {
                                    animationManager.currentScene = scene
                                    animationManager.play()
                                    dismissMenuWindowIfNeeded()
                                }
                            )
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    private func openAnimationEditor(for scene: AnimationScene? = nil) {
        guard let animationManager = appModel.animationManager else { return }
        if let scene {
            animationManager.currentScene = scene
        } else if animationManager.currentScene == nil {
            animationManager.currentScene = animationManager.scenes.first
        }
        openWindow(id: AppModel.animationEditorWindowID)
    }
    
    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Coloring Tab
    // ═══════════════════════════════════════════════════════════════════════════
    
    private var coloringTabContent: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 12) {
                    switch coloringSubTab {
                    case .gradient: coloringGradientContent
                    case .mapping:  coloringMappingContent
                    case .grading:  coloringGradingContent
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
            }
        }
    }
    
    @State private var savedGradientToDelete: Int? = nil
    @State private var showDeleteConfirm = false
    @State private var renamingGradientIndex: Int? = nil
    @State private var renamingGradientName: String = ""
    
    private var coloringGradientContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Gradient Coloring", systemImage: "paintbrush.fill")
                    .font(.headline)
                Spacer()
                Text("Current: \(cache.color.gradientState.gradientPreset?.displayName ?? cache.gradientLibrary.savedCustomGradients.first(where: { $0.id == cache.color.gradientState.gradient.id })?.name ?? "Custom")")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.blue)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.blue.opacity(0.12)))
            }
            GradientPreviewBar(gradient: cache.color.gradientState.gradient)
                .frame(height: 28).clipShape(RoundedRectangle(cornerRadius: 6))
                .contentShape(RoundedRectangle(cornerRadius: 6))
                .onTapGesture { showStopsPopover = true }
                .popover(isPresented: $showStopsPopover, arrowEdge: .bottom) {
                    GradientStopsPopover(cache: $cache)
                }
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.4), lineWidth: 1))
            // ── Saved Custom Gradients ──
            HStack {
                Text("Saved").font(.subheadline).foregroundColor(.secondary)
                Spacer()
                if !cache.gradientLibrary.savedCustomGradients.isEmpty {
                    Text("\(cache.gradientLibrary.savedCustomGradients.count)").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            if cache.gradientLibrary.savedCustomGradients.isEmpty {
                Text("Edit a gradient and tap Save to build your library.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            } else {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                    ForEach(Array(cache.gradientLibrary.savedCustomGradients.enumerated()), id: \.element.id) { index, saved in
                        let isActive = cache.color.gradientState.gradientPreset == nil && cache.color.gradientState.gradient.id == saved.id
                        Button {
                            cache.applySavedGradient(saved)
                        } label: {
                            VStack(spacing: 3) {
                                GradientPreviewBar(gradient: saved)
                                    .frame(height: 10)
                                    .clipShape(RoundedRectangle(cornerRadius: 3))
                                    .allowsHitTesting(false)
                                Text(saved.name).font(.caption2).lineLimit(1)
                                if isActive {
                                    Label("Selected", systemImage: "checkmark.circle.fill")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.blue)
                                }
                            }.frame(maxWidth: .infinity).padding(.vertical, 4)
                        }
                        .buttonStyle(.bordered)
                        .tint(isActive ? .purple : .indigo)
                        .accessibilityAddTraits(isActive ? .isSelected : [])
                        .contextMenu {
                            Button {
                                renamingGradientName = saved.name
                                renamingGradientIndex = index
                            } label: {
                                Label("Rename", systemImage: "pencil")
                            }
                            Button {
                                cache.updateSavedGradient(at: index)
                            } label: {
                                Label("Overwrite with Current", systemImage: "arrow.down.circle")
                            }
                            Divider()
                            Button(role: .destructive) {
                                cache.deleteSavedGradient(at: index)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .onLongPressGesture(minimumDuration: 0.5) {
                            renamingGradientName = saved.name
                            renamingGradientIndex = index
                        }
                    }
                }
            }
            
            // ── Presets ──
            Text("Presets").font(.subheadline).foregroundColor(.secondary)
                .padding(.top, 4)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                ForEach(GradientPreset.allCases, id: \.rawValue) { preset in
                    let isSelected = cache.color.gradientState.gradientPreset == preset
                    Button { cache.applyGradientPreset(preset) } label: {
                        VStack(spacing: 3) {
                            Image(systemName: preset.icon).font(.caption)
                            Text(preset.displayName).font(.caption2).lineLimit(1)
                            if isSelected {
                                Label("Selected", systemImage: "checkmark.circle.fill")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.blue)
                            }
                        }.frame(maxWidth: .infinity).padding(.vertical, 4)
                    }
                    .buttonStyle(.bordered)
                    .tint(isSelected ? .blue : .secondary)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }

            // ── Save / Edit Buttons ──
            HStack(spacing: 8) {
                Button { showStopsPopover = true } label: {
                    Label("Edit Gradient", systemImage: "slider.horizontal.3")
                        .font(.caption)
                }
                .buttonStyle(.bordered).tint(cache.color.gradientState.gradientPreset == nil ? .blue : .secondary)
            }
        }
        .alert("Rename Gradient", isPresented: .init(
            get: { renamingGradientIndex != nil },
            set: { if !$0 { renamingGradientIndex = nil } }
        )) {
            TextField("Name", text: $renamingGradientName)
            Button("Cancel", role: .cancel) { renamingGradientIndex = nil }
            Button("Rename") {
                if let idx = renamingGradientIndex {
                    cache.renameSavedGradient(at: idx, to: renamingGradientName)
                }
                renamingGradientIndex = nil
            }
        } message: {
            Text("Enter a new name for this gradient")
        }
    }
    
    private var coloringMappingContent: some View {
        VStack(spacing: 12) {
            HStack {
                Label("Mapping Mode", systemImage: "target").font(.headline)
                Spacer()
                Text(cache.color.gradientState.gradient.mappingMode.displayName)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.blue)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().fill(Color.blue.opacity(0.12)))
            }

            LazyVGrid(columns: [GridItem(.flexible(minimum: 100), spacing: 8), GridItem(.flexible(minimum: 100), spacing: 8), GridItem(.flexible(minimum: 100), spacing: 8)], spacing: 8) {
                ForEach(ColorMappingMode.allCases, id: \.rawValue) { mode in
                    let isSelected = cache.color.gradientState.gradient.mappingMode == mode
                    Button {
                        cache.color.gradientState.gradient.mappingMode = mode
                        cache.push(\.colorMappingMode, value: mode)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 5) {
                                Image(systemName: mappingModeIcon(mode))
                                    .font(.caption)
                                    .frame(width: 14)
                                    .foregroundStyle(isSelected ? Color.blue : .secondary)
                                Text(mode.displayName)
                                    .font(.caption.weight(.semibold))
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                if isSelected {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.caption2)
                                        .foregroundStyle(.blue)
                                }
                            }
                            Text(mappingModeDescription(mode))
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(isSelected ? Color.blue.opacity(0.18) : Color.white.opacity(0.05))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(isSelected ? Color.blue.opacity(0.5) : Color.secondary.opacity(0.12), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(mode.displayName)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }

            // Gradient transform controls
            VStack(spacing: 4) {
                EffectSliderRow(icon: "repeat", label: "Repeat",
                    value: $cache.color.gradientState.gradient.repeatCount, range: 0.1...5.0,
                    enabled: .constant(true),
                    onChanged: { cache.push(\.gradientRepeat, value: cache.color.gradientState.gradient.repeatCount) },
                    showToggle: false)
                Divider().padding(.leading, 159)
                EffectSliderRow(icon: "arrow.right", label: "Offset",
                    value: $cache.color.gradientState.gradient.offset, range: 0...1,
                    enabled: .constant(true),
                    onChanged: { cache.push(\.gradientOffset, value: cache.color.gradientState.gradient.offset) },
                    showToggle: false)
                Divider().padding(.leading, 159)
                EffectSliderRow(icon: "waveform.path", label: "Smoothing",
                    value: $cache.color.gradientState.gradient.smoothing, range: 0...1,
                    enabled: .constant(true),
                    onChanged: { cache.push(\.gradientSmoothing, value: cache.color.gradientState.gradient.smoothing) },
                    showToggle: false)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.purple.opacity(0.06)))

            Divider()

            // Color blend controls
            VStack(spacing: 4) {
                EffectSliderRow(icon: "circle.lefthalf.filled", label: "Color Mix",
                    value: $cache.color.colorMix, range: 0...1.0,
                    enabled: .constant(true),
                    onChanged: { cache.push(\.colorMix, value: cache.color.colorMix) },
                    showToggle: false)
                Divider().padding(.leading, 159)
                EffectSliderRow(icon: "number", label: "Iterations",
                    value: $cache.color.colorIterations, range: 4...16,
                    enabled: .constant(true),
                    onChanged: { cache.push(\.colorIterations, value: cache.color.colorIterations) },
                    showToggle: false)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.indigo.opacity(0.06)))
        }
    }

    private func mappingModeIcon(_ mode: ColorMappingMode) -> String {
        switch mode {
        case .orbitTrap:  return "scope"
        case .iterations: return "number.circle"
        case .zDepth:     return "arrow.forward.to.line"
        case .angle:      return "rotate.right"
        case .normal:     return "arrow.up.right.circle"
        case .blended:    return "blendmode"
        }
    }

    private func mappingModeDescription(_ mode: ColorMappingMode) -> String {
        switch mode {
        case .orbitTrap:  return "Distance to orbit trap"
        case .iterations: return "Normalized iteration count"
        case .zDepth:     return "Camera depth"
        case .angle:      return "Polar trap angle"
        case .normal:     return "Surface normal"
        case .blended:    return "Trap + iteration mix"
        }
    }

    private var coloringGradingContent: some View {
        VStack(spacing: 12) {
            Label("Color Grading", systemImage: "camera.filters").font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Tone controls
            VStack(spacing: 4) {
                EffectSliderRow(icon: "circle.lefthalf.filled", label: "Contrast",
                    value: $cache.color.colorSchemeContrast, range: 0.95...1.15,
                    enabled: .constant(true),
                    onChanged: { cache.push(\.colorSchemeContrast, value: cache.color.colorSchemeContrast) },
                    showToggle: false)
                Divider().padding(.leading, 159)
                EffectSliderRow(icon: "paintpalette.fill", label: "Vibrance",
                    value: $cache.color.colorSchemeVibrance, range: 0...1.0,
                    enabled: .constant(true),
                    onChanged: { cache.push(\.colorSchemeVibrance, value: cache.color.colorSchemeVibrance) },
                    showToggle: false)
                Divider().padding(.leading, 159)
                EffectSliderRow(icon: "waveform.path", label: "Midtone Curve",
                    value: $cache.color.colorSchemeCurve, range: -1.0...1.0,
                    enabled: .constant(true),
                    onChanged: { cache.push(\.colorSchemeCurve, value: cache.color.colorSchemeCurve) },
                    showToggle: false)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.06)))

            // Shadows & Highlights
            VStack(spacing: 4) {
                EffectSliderRow(icon: "shadow", label: "Shadows",
                    value: $cache.color.colorSchemeShadows, range: -0.05...0.05,
                    enabled: .constant(true),
                    onChanged: { cache.push(\.colorSchemeShadows, value: cache.color.colorSchemeShadows) },
                    showToggle: false)
                Divider().padding(.leading, 159)
                EffectSliderRow(icon: "sun.max.fill", label: "Highlights",
                    value: $cache.color.colorSchemeHighlights, range: -0.5...1.0,
                    enabled: .constant(true),
                    onChanged: { cache.push(\.colorSchemeHighlights, value: cache.color.colorSchemeHighlights) },
                    showToggle: false)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.yellow.opacity(0.06)))
        }
    }
    
    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Effects Tab
    // ═══════════════════════════════════════════════════════════════════════════
    
    private var effectsTabContent: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 12) {
                    switch effectsSubTab {
                    case .static:  effectsStaticContent
                    case .dynamic: effectsDynamicContent
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
            }
        }
    }
    
    private var effectsStaticContent: some View {
        VStack(spacing: 12) {
            // ── Atmosphere ──
            VStack(spacing: 4) {
                EffectSliderRow(icon: "light.max", label: "Glow",
                    value: Binding(get: { cache.lighting.glowEffect.intensity }, set: { cache.lighting.glowEffect.intensity = $0 }),
                    range: 0...1,
                    enabled: Binding(get: { cache.lighting.glowEffect.enabled }, set: { cache.lighting.glowEffect.enabled = $0 }),
                    onChanged: { cache.commitGlowEffect() })
                Divider().padding(.leading, 159)
                EffectSliderRow(icon: "sun.max.fill", label: "Bloom",
                    value: Binding(get: { cache.lighting.bloomEffect.strength }, set: { cache.lighting.bloomEffect.strength = $0 }),
                    range: 0...1,
                    enabled: Binding(get: { cache.lighting.bloomEffect.enabled }, set: { cache.lighting.bloomEffect.enabled = $0 }),
                    onChanged: { cache.commitBloomEffect() })
                Divider().padding(.leading, 114)
                EffectSliderRow(icon: "cloud.fog.fill", label: "Fog",
                    value: Binding(get: { cache.lighting.fogEffect.intensity }, set: { cache.lighting.fogEffect.intensity = $0 }),
                    range: 0...1,
                    enabled: Binding(get: { cache.lighting.fogEffect.enabled }, set: { cache.lighting.fogEffect.enabled = $0 }),
                    onChanged: { cache.commitFogEffect() })
                Divider().padding(.leading, 114)
                FogColorPickerRow(
                    title: "Fog Tint",
                    color: Binding(get: { cache.lighting.fogEffect.color }, set: { cache.lighting.fogEffect.color = $0 }),
                    onChanged: { cache.commitFogEffect() }
                )
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.06)))
            
        }
    }
    
    private var effectsDynamicContent: some View {
        VStack(spacing: 12) {
            dynamicPresetDisclosure

            // ── Color Animation ──
            VStack(spacing: 4) {
                EffectSliderRow(icon: "arrow.trianglehead.2.clockwise.rotate.90", label: "Gradient Cycle",
                    value: Binding(get: { cache.lighting.gradientCycleEffect.speed }, set: { cache.lighting.gradientCycleEffect.speed = $0 }),
                    range: 0...1,
                    enabled: Binding(get: { cache.lighting.gradientCycleEffect.enabled }, set: { cache.lighting.gradientCycleEffect.enabled = $0 }),
                    onChanged: { cache.commitGradientCycleEffect() })
                if cache.lighting.gradientCycleEffect.enabled {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.caption)
                            .frame(width: 16)
                        Text("Mirror Loop")
                            .font(.subheadline)
                            .frame(width: 135, alignment: .leading)
                            .lineLimit(1)
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { cache.lighting.gradientCycleEffect.mirrorLoop },
                            set: { newVal in
                                cache.lighting.gradientCycleEffect.mirrorLoop = newVal
                                cache.commitGradientCycleEffect()
                            }))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                    }
                    .frame(height: 32)
                }
                Divider().padding(.leading, 159)
                EffectSliderRow(icon: "paintpalette.fill", label: "Hue Rotation",
                    value: Binding(get: { cache.lighting.hueRotationEffect.speed }, set: { cache.lighting.hueRotationEffect.speed = $0 }),
                    range: 0...0.5,
                    enabled: Binding(get: { cache.lighting.hueRotationEffect.enabled }, set: { cache.lighting.hueRotationEffect.enabled = $0 }),
                    onChanged: { cache.commitHueRotationEffect() })
                EffectSliderRow(icon: "circle.lefthalf.filled", label: "Hue Intensity",
                    value: Binding(get: { cache.lighting.hueRotationEffect.intensity }, set: { cache.lighting.hueRotationEffect.intensity = $0 }),
                    range: 0...1,
                    enabled: Binding(get: { cache.lighting.hueRotationEffect.enabled }, set: { cache.lighting.hueRotationEffect.enabled = $0 }),
                    onChanged: { cache.commitHueRotationEffect() },
                    showToggle: false)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.blue.opacity(0.06)))
            
            // ── Pulse ──
            VStack(spacing: 4) {
                EffectSliderRow(icon: "waveform.path.ecg", label: "Pulse Speed",
                    value: Binding(get: { cache.lighting.pulseEffect.speed }, set: { cache.lighting.pulseEffect.speed = $0 }),
                    range: 0...2,
                    enabled: Binding(get: { cache.lighting.pulseEffect.enabled }, set: { cache.lighting.pulseEffect.enabled = $0 }),
                    onChanged: { cache.commitPulseEffect() })
                EffectSliderRow(icon: "waveform.path", label: "Pulse Amount",
                    value: Binding(get: { cache.lighting.pulseEffect.amount }, set: { cache.lighting.pulseEffect.amount = $0 }),
                    range: 0...1,
                    enabled: Binding(get: { cache.lighting.pulseEffect.enabled }, set: { cache.lighting.pulseEffect.enabled = $0 }),
                    onChanged: { cache.commitPulseEffect() },
                    showToggle: false)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.purple.opacity(0.06)))

            linearRailControls

            // ── Polar Rotation (fractal-specific) ──
            if cache.fractalType.supports(.polarRotation) {
                VStack(spacing: 8) {
                    HStack {
                        Label("Polar Rotation", systemImage: "arrow.trianglehead.counterclockwise.rotate.90")
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        Picker("", selection: Binding(
                            get: { cache.lighting.polarRotationEffect.direction },
                            set: { newDir in
                                cache.lighting.polarRotationEffect.direction = newDir
                                cache.push(\.polarRotationEffect, value: cache.lighting.polarRotationEffect)
                            }
                        )) {
                            ForEach(PolarRotationDirection.allCases, id: \.self) { dir in
                                Label(dir.label, systemImage: dir.icon).tag(dir)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 180)
                    }
                    if cache.lighting.polarRotationEffect.enabled {
                        EffectSliderRow(icon: "gauge.with.dots.needle.50percent", label: "Speed",
                            value: Binding(get: { cache.lighting.polarRotationEffect.speed }, set: { cache.lighting.polarRotationEffect.speed = $0 }),
                            range: 0...1,
                            enabled: .constant(true),
                            onChanged: { cache.push(\.polarRotationEffect, value: cache.lighting.polarRotationEffect) },
                            showToggle: false)
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.green.opacity(0.06)))
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
    }

    private var linearRailControls: some View {
        VStack(spacing: 8) {
            HStack {
                Label("Linear Rail", systemImage: "arrow.left.and.right")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Picker("", selection: Binding(
                    get: { cache.lighting.linearRailEffect.axis },
                    set: { axis in
                        cache.lighting.linearRailEffect.axis = axis
                        cache.commitLinearRailEffect()
                    }
                )) {
                    ForEach(LinearRailAxis.allCases, id: \.self) { axis in
                        Text(axis.label).tag(axis)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 230)
            }
            EffectSliderRow(icon: "point.3.connected.trianglepath.dotted", label: "Rail Speed",
                value: Binding(get: { cache.lighting.linearRailEffect.speed }, set: { cache.lighting.linearRailEffect.speed = $0 }),
                range: 0...1,
                enabled: Binding(get: { cache.lighting.linearRailEffect.enabled }, set: { cache.lighting.linearRailEffect.enabled = $0 }),
                onChanged: { cache.commitLinearRailEffect() })
            if cache.lighting.linearRailEffect.enabled {
                EffectSliderRow(icon: "arrow.up.left.and.arrow.down.right", label: "Rail Reach",
                    value: Binding(get: { cache.lighting.linearRailEffect.amplitude }, set: { cache.lighting.linearRailEffect.amplitude = $0 }),
                    range: 0...3,
                    enabled: .constant(true),
                    onChanged: { cache.commitLinearRailEffect() },
                    showToggle: false)
                EffectSliderRow(icon: "waveform", label: "Harmonic",
                    value: Binding(get: { cache.lighting.linearRailEffect.multiplier }, set: { cache.lighting.linearRailEffect.multiplier = $0 }),
                    range: 1...8,
                    enabled: .constant(true),
                    onChanged: { cache.commitLinearRailEffect() },
                    showToggle: false)
                EffectSliderRow(icon: "circle.dotted", label: "Orbit",
                    value: Binding(get: { cache.lighting.linearRailEffect.orbitAmount }, set: { cache.lighting.linearRailEffect.orbitAmount = $0 }),
                    range: 0...1,
                    enabled: .constant(true),
                    onChanged: { cache.commitLinearRailEffect() },
                    showToggle: false)
                if cache.lighting.linearRailEffect.orbitAmount > 0.0001 {
                    EffectSliderRow(icon: "arrow.triangle.2.circlepath", label: "Orbit Speed",
                        value: Binding(get: { cache.lighting.linearRailEffect.orbitSpeed }, set: { cache.lighting.linearRailEffect.orbitSpeed = $0 }),
                        range: 0...1,
                        enabled: .constant(true),
                        onChanged: { cache.commitLinearRailEffect() },
                        showToggle: false)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.indigo.opacity(0.06)))
    }

    private var dynamicPresetDisclosure: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Dynamic Presets", systemImage: "sparkles")
                .font(.subheadline.weight(.medium))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(LightingPreset.allCases, id: \.self) { preset in
                        PresetCardButton(preset: preset, isSelected: cache.lighting.lightingPreset == preset) {
                            cache.lighting.lightingPreset = preset
                            cache.push(\.lightingPreset, value: preset)
                            cache.reloadLightingEffects()
                        }
                    }
                }
                .padding(.horizontal, 4)
            }

            Text("Current: \(cache.lighting.lightingPreset.displayName)")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.blue)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.blue.opacity(0.12)))
                .frame(maxWidth: .infinity, alignment: .leading)

            if cache.lighting.lightingPreset != .custom {
                Text(cache.lighting.lightingPreset.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.06)))
    }
    
    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Gestures Tab
    // ═══════════════════════════════════════════════════════════════════════════
    
    private var gesturesTabContent: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(spacing: 12) {
                VStack(spacing: 8) {
                    HStack {
                        Label("Gesture Controls", systemImage: "hand.draw").font(.headline)
                        Spacer()
                    }

                    HandTrackingStatusView(state: appModel.handTrackingState)
                        .padding(.vertical, 2)

                    Toggle("Enable Hand Gesture Controls", isOn: Binding(
                        get: { appModel.handTrackingEnabled },
                        set: { appModel.handTrackingEnabled = $0 }
                    ))

                    // ── Hand Assignments ───────────────────────────────────────
                    gesturePictographicAssignmentPanel

                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(GestureHandMode.allCases, id: \.self) { mode in
                                gestureHandSection(mode: mode)
                            }
                        }
                        .padding(.top, 4)
                    } label: {
                        Label("Detailed Assignments", systemImage: "list.bullet.rectangle")
                            .font(.subheadline.weight(.semibold))
                    }

                    Divider().padding(.vertical, 2)

                    Group {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Core Behavior", systemImage: "slider.horizontal.3")
                                .font(.subheadline.weight(.semibold))

                        // Compact 2-column grid of boolean behavior toggles
                        LazyVGrid(
                            columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                            alignment: .leading,
                            spacing: 6
                        ) {
                            Toggle("Relative Gestures", isOn: $cache.gesture.useRelativeGestures)
                                .onChange(of: cache.gesture.useRelativeGestures) { _, v in cache.push(\.useRelativeGestures, value: v) }
                            Toggle("Spring Blob", isOn: $cache.gesture.useSpringBlob)
                                .onChange(of: cache.gesture.useSpringBlob) { _, v in cache.push(\.useSpringBlob, value: v) }
                            Toggle("Menu + Movement Only", isOn: $cache.gesture.menuAndMovementOnly)
                                .onChange(of: cache.gesture.menuAndMovementOnly) { _, v in cache.push(\.menuAndMovementOnly, value: v) }
                            Toggle("Extended Range", isOn: $cache.gesture.extendedGestureRange)
                                .onChange(of: cache.gesture.extendedGestureRange) { _, v in cache.push(\.extendedGestureRange, value: v) }
                            Toggle("Rotation Auto-Snap", isOn: $cache.gesture.rotationAutoSnap)
                                .onChange(of: cache.gesture.rotationAutoSnap) { _, v in cache.push(\.rotationAutoSnap, value: v) }
                        }
                        .toggleStyle(.switch)
                        .font(.subheadline)
                        if cache.gesture.menuAndMovementOnly {
                            Text("Skips shape and parameter gesture scans, keeping only menu trigger and movement gestures active.")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        if cache.gesture.rotationAutoSnap {
                            EffectSliderRow(icon: "arrow.up.left.and.arrow.down.right", label: "Breakaway Angle (°)",
                                value: $cache.gesture.rotationBreakawayDegrees, range: 0...45,
                                enabled: .constant(true),
                                onChanged: { cache.push(\.rotationBreakawayDegrees, value: cache.gesture.rotationBreakawayDegrees) },
                                showToggle: false)
                            Text("Rotation stays locked until your hands rotate past this angle, then engages smoothly.")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }

                        EffectSliderRow(icon: "gauge.with.dots.needle.50percent", label: "Global Sensitivity",
                            value: $cache.gesture.gestureSensitivity, range: 1...10,
                            enabled: .constant(true),
                            onChanged: { cache.push(\.gestureSensitivity, value: cache.gesture.gestureSensitivity) },
                            showToggle: false)

                        EffectSliderRow(icon: "move.3d", label: "Translation Sensitivity",
                            value: $cache.gesture.translationSensitivity, range: 0.2...3.0,
                            enabled: .constant(true),
                            onChanged: { cache.push(\.translationSensitivity, value: cache.gesture.translationSensitivity) },
                            showToggle: false)

                        if cache.gesture.rotationAutoSnap {
                            EffectSliderRow(icon: "rotate.3d", label: "Snap Window (°)",
                                value: $cache.gesture.rotationSnapWindowDegrees, range: 2...30,
                                enabled: .constant(true),
                                onChanged: { cache.push(\.rotationSnapWindowDegrees, value: cache.gesture.rotationSnapWindowDegrees) },
                                showToggle: false)
                        }
                        }

                        Divider().padding(.vertical, 2)

                        // ── Menu Toggle (compact) ──
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle("Menu Toggle Gesture", isOn: $cache.gesture.menuToggleGestureEnabled)
                                .onChange(of: cache.gesture.menuToggleGestureEnabled) { _, v in
                                    cache.push(\.menuToggleGestureEnabled, value: v)
                                }

                            if cache.gesture.menuToggleGestureEnabled {
                                HStack {
                                    Label("Gesture", systemImage: cache.gesture.menuToggleGestureMode.icon)
                                        .font(.subheadline)
                                    Spacer()
                                    Picker("", selection: $cache.gesture.menuToggleGestureMode) {
                                        ForEach(MenuToggleGestureMode.allCases, id: \.self) { mode in
                                            Text(mode.displayName).tag(mode)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .frame(maxWidth: 180)
                                    .onChange(of: cache.gesture.menuToggleGestureMode) { _, v in
                                        cache.push(\.menuToggleGestureMode, value: v)
                                    }
                                }
                            }
                        }

                        Divider().padding(.vertical, 2)

                        // ── Per-Finger Tap (compact) ──
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle("Per-Finger Tap", isOn: $cache.gesture.perFingerTapGestureEnabled)
                                .onChange(of: cache.gesture.perFingerTapGestureEnabled) { _, v in
                                    cache.push(\.perFingerTapGestureEnabled, value: v)
                                }

                            if cache.gesture.perFingerTapGestureEnabled {
                                HStack {
                                    Text("Middle → Menu")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                }
                            }
                        }

                        Divider().padding(.vertical, 2)

                        // ── Gesture Lab (collapsed by default) ──
                        DisclosureGroup {
                            VStack(alignment: .leading, spacing: 8) {
                                Label("Menu Toggle Tuning", systemImage: "menucard")
                                    .font(.caption.weight(.semibold))

                                EffectSliderRow(icon: "hand.tap", label: "Hold Time",
                                    value: $cache.gesture.menuToggleHoldDuration, range: 0.05...0.6,
                                    enabled: .constant(cache.gesture.menuToggleGestureEnabled),
                                    onChanged: { cache.push(\.menuToggleHoldDuration, value: cache.gesture.menuToggleHoldDuration) },
                                    showToggle: false)

                                EffectSliderRow(icon: "timer", label: "Cooldown",
                                    value: $cache.gesture.menuToggleCooldown, range: 0.1...2.5,
                                    enabled: .constant(cache.gesture.menuToggleGestureEnabled),
                                    onChanged: { cache.push(\.menuToggleCooldown, value: cache.gesture.menuToggleCooldown) },
                                    showToggle: false)

                                EffectSliderRow(icon: "bolt.horizontal", label: "Activate",
                                    value: $cache.gesture.menuToggleActivateThreshold, range: 0.2...0.95,
                                    enabled: .constant(cache.gesture.menuToggleGestureEnabled),
                                    onChanged: { cache.push(\.menuToggleActivateThreshold, value: cache.gesture.menuToggleActivateThreshold) },
                                    showToggle: false)

                                EffectSliderRow(icon: "arrow.down.to.line", label: "Release",
                                    value: $cache.gesture.menuToggleReleaseThreshold, range: 0.1...0.9,
                                    enabled: .constant(cache.gesture.menuToggleGestureEnabled),
                                    onChanged: { cache.push(\.menuToggleReleaseThreshold, value: cache.gesture.menuToggleReleaseThreshold) },
                                    showToggle: false)

                                Divider()

                                Label("Two-Hand Pinch Tuning", systemImage: "hands.sparkles")
                                    .font(.caption.weight(.semibold))

                                EffectSliderRow(icon: "dot.radiowaves.left.and.right", label: "Min Distance",
                                    value: $cache.gesture.gestureMinHandDistance, range: 0.02...0.25,
                                    enabled: .constant(true),
                                    onChanged: { cache.push(\.gestureMinHandDistance, value: cache.gesture.gestureMinHandDistance) },
                                    showToggle: false)

                                EffectSliderRow(icon: "arrow.left.and.right", label: "Max Distance",
                                    value: $cache.gesture.gestureMaxHandDistance, range: 0.2...1.2,
                                    enabled: .constant(true),
                                    onChanged: { cache.push(\.gestureMaxHandDistance, value: cache.gesture.gestureMaxHandDistance) },
                                    showToggle: false)

                                EffectSliderRow(icon: "hand.draw", label: "Pinch Activate",
                                    value: $cache.gesture.twoHandPinchActivateThreshold, range: 0.2...0.98,
                                    enabled: .constant(true),
                                    onChanged: { cache.push(\.twoHandPinchActivateThreshold, value: cache.gesture.twoHandPinchActivateThreshold) },
                                    showToggle: false)

                                EffectSliderRow(icon: "hand.raised", label: "Pinch Release",
                                    value: $cache.gesture.twoHandPinchReleaseThreshold, range: 0.1...0.95,
                                    enabled: .constant(true),
                                    onChanged: { cache.push(\.twoHandPinchReleaseThreshold, value: cache.gesture.twoHandPinchReleaseThreshold) },
                                    showToggle: false)

                                EffectSliderRow(icon: "hand.point.up.left", label: "Ring Activate",
                                    value: $cache.gesture.ringPinchActivateThreshold, range: 0.1...0.95,
                                    enabled: .constant(true),
                                    onChanged: { cache.push(\.ringPinchActivateThreshold, value: cache.gesture.ringPinchActivateThreshold) },
                                    showToggle: false)

                                EffectSliderRow(icon: "hand.point.up.braille", label: "Ring Release",
                                    value: $cache.gesture.ringPinchReleaseThreshold, range: 0.05...0.9,
                                    enabled: .constant(true),
                                    onChanged: { cache.push(\.ringPinchReleaseThreshold, value: cache.gesture.ringPinchReleaseThreshold) },
                                    showToggle: false)

                                EffectSliderRow(icon: "play.circle", label: "Start Guard",
                                    value: $cache.gesture.gestureMaxStartHandDistance, range: 0.08...1.0,
                                    enabled: .constant(true),
                                    onChanged: { cache.push(\.gestureMaxStartHandDistance, value: cache.gesture.gestureMaxStartHandDistance) },
                                    showToggle: false)

                                EffectSliderRow(icon: "checkmark.circle", label: "Active Guard",
                                    value: $cache.gesture.gestureMaxActiveHandDistance, range: 0.1...1.5,
                                    enabled: .constant(true),
                                    onChanged: { cache.push(\.gestureMaxActiveHandDistance, value: cache.gesture.gestureMaxActiveHandDistance) },
                                    showToggle: false)
                            }
                        } label: {
                            Label("Gesture Lab", systemImage: "wrench.and.screwdriver")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(!appModel.handTrackingEnabled)
                    .opacity(appModel.handTrackingEnabled ? 1.0 : 0.6)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.green.opacity(0.06)))
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
        }
    }
    
    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Settings Tab
    // ═══════════════════════════════════════════════════════════════════════════
    
    private var settingsTabContent: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 12) {
                    settingsSectionBlock(
                        title: SettingsSubTab.general.rawValue,
                        systemImage: "gearshape.2.fill"
                    ) {
                        settingsGeneralContent
                    }

                    settingsSectionBlock(
                        title: SettingsSubTab.exportShare.rawValue,
                        systemImage: "square.and.arrow.up.fill"
                    ) {
                        settingsExportContent
                    }

                    settingsSectionBlock(
                        title: SettingsSubTab.devTools.rawValue,
                        systemImage: "wrench.and.screwdriver.fill"
                    ) {
                        settingsAdvancedContent
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
            }
        }
    }

    private func settingsSectionBlock<Content: View>(title: String, systemImage: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(.primary)

            content()
        }
    }
    
    private var settingsGeneralContent: some View {
        VStack(spacing: 12) {
            // Experimental features section
            experimentalFeaturesSection

            // Community sharing section
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Community Sharing", systemImage: "person.3.fill").font(.headline)
                    Spacer()
                }

                Text("Optional. Share your setups with the Threshold community without creating an account.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Share with the community", isOn: Binding(
                    get: { UsageAnalytics.shared.analyticsEnabled },
                    set: { UsageAnalytics.shared.analyticsEnabled = $0 }
                ))

                Text("By opting in, you are letting us review your settings so they may be added to the community later on your behalf and may appear in original or altered form.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                Text("You can use Threshold normally without sharing anything, and you can change this later in Settings.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                if UsageAnalytics.shared.analyticsEnabled {
                    Divider()

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Display Name (Optional)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        TextField("Leave blank to share anonymously", text: Binding(
                            get: { UsageAnalytics.shared.communityDisplayName },
                            set: { UsageAnalytics.shared.communityDisplayName = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled(true)

                        Text("Used only for community credits. Leave blank to share anonymously.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.blue.opacity(0.06)))

            // iCloud Drive section
            iCloudDriveSection
        }
    }

    // ─────────────────────────────────────────────────────────────────
    // MARK: Experimental Features
    // ─────────────────────────────────────────────────────────────────

    @AppStorage("allowCustomScenes") private var allowCustomScenes: Bool = false

    @ViewBuilder
    private var experimentalFeaturesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Label("Experimental", systemImage: "flask.fill").font(.headline)
                Text("BETA")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.orange.opacity(0.25)))
                    .foregroundStyle(.orange)
                Spacer()
            }

            Toggle(isOn: $allowCustomScenes) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Allow custom scenes")
                        .font(.subheadline.weight(.semibold))
                    Text("Enables loading .threshfx files and custom shader formulas. Default parameters may not be ideal and some scenes may not render correctly yet.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(.orange)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.06)))
    }

    // ─────────────────────────────────────────────────────────────────
    // MARK: iCloud Drive
    // ─────────────────────────────────────────────────────────────────

    @ViewBuilder
    private var iCloudDriveSection: some View {
        let cloud = appModel.iCloudBackup
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("iCloud Drive", systemImage: "icloud").font(.headline)
                Spacer()
                if cloud.isBusy { ProgressView().controlSize(.small) }
            }

            if cloud.isAvailable {
                Text("Sync your scenes, animations, and settings to iCloud Drive. Files are stored in a public **Threshold** folder visible in the Files app and on your Mac in Finder under iCloud Drive.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("Sync to iCloud Drive", isOn: Binding(
                    get: { appModel.iCloudBackup.isSyncEnabled },
                    set: { newValue in
                        appModel.iCloudBackup.isSyncEnabled = newValue
                        if newValue {
                            // Push current state immediately on enable.
                            appModel.iCloudBackup.syncToCloud(
                                settings: appModel.renderSettings,
                                presetManager: appModel.presetManager,
                                animationManager: appModel.animationManager
                            )
                        }
                    }
                ))
                .tint(.cyan)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Folder structure:").font(.caption2).foregroundStyle(.tertiary)
                    Text("Threshold/Settings/   • settings.json").font(.caption2.monospaced()).foregroundStyle(.tertiary)
                    Text("Threshold/Scenes/     • <name>.threshscene").font(.caption2.monospaced()).foregroundStyle(.tertiary)
                    Text("Threshold/Animations/ • <name>.threshanim").font(.caption2.monospaced()).foregroundStyle(.tertiary)
                }
                .padding(.vertical, 2)

                HStack(spacing: 8) {
                    Button {
                        appModel.iCloudBackup.syncToCloud(
                            settings: appModel.renderSettings,
                            presetManager: appModel.presetManager,
                            animationManager: appModel.animationManager
                        )
                    } label: {
                        Label("Back Up Now", systemImage: "arrow.up.to.line.compact")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.cyan)
                    .disabled(cloud.isBusy || !cloud.isSyncEnabled)

                    Button {
                        appModel.iCloudBackup.restoreFromCloud(
                            into: appModel.renderSettings,
                            presetManager: appModel.presetManager,
                            animationManager: appModel.animationManager
                        )
                    } label: {
                        Label("Restore", systemImage: "arrow.down.to.line.compact")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(cloud.isBusy || !cloud.isSyncEnabled)
                }

                Button {
                    appModel.iCloudBackup.openInFilesApp()
                } label: {
                    Label("Open Threshold Folder in Files", systemImage: "folder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                if let date = cloud.lastSyncDate {
                    Text("Last sync: \(date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let error = cloud.lastError {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("iCloud Drive isn't available. Sign in to iCloud and enable iCloud Drive in System Settings to back up your scenes and animations.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    appModel.iCloudBackup.resolveContainer()
                } label: {
                    Label("Check Again", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.cyan.opacity(0.06)))
    }
    
    private var themeColor: Color {
        // Derive theme color from the current gradient preset
        switch cache.color.gradientState.gradientPreset {
        case .classic:    return Color(red: 0.8, green: 0.5, blue: 0.2)
        case .ocean:      return Color(red: 0.1, green: 0.5, blue: 0.9)
        case .fire:       return Color(red: 1.0, green: 0.4, blue: 0.1)
        case .forest:     return Color(red: 0.2, green: 0.7, blue: 0.3)
        case .nebula:     return Color(red: 0.6, green: 0.3, blue: 0.9)
        case .mono:       return Color(red: 0.5, green: 0.5, blue: 0.55)
        case .aurora:     return Color(red: 0.2, green: 0.9, blue: 0.6)
        case .volcanic:   return Color(red: 0.9, green: 0.3, blue: 0.1)
        case .neonCyber:  return Color(red: 1.0, green: 0.2, blue: 0.8)
        case .neonSunset: return Color(red: 1.0, green: 0.5, blue: 0.3)
        case .neonMatrix: return Color(red: 0.0, green: 1.0, blue: 0.4)
        case .rainbow:    return Color(red: 0.9, green: 0.4, blue: 0.5)
        case .infrared:   return Color(red: 0.8, green: 0.2, blue: 0.2)
        case .twilight:   return Color(red: 0.5, green: 0.3, blue: 0.7)
        case .none:       return Color(red: 0.6, green: 0.3, blue: 0.9)  // default nebula
        }
    }


    
    private var fpsColor: Color {
        // Use cache.liveFPS for the settings panel to avoid observation of RenderMetrics
        let fps = cache.liveFPS
        if fps >= 85 { return .green }; if fps >= 60 { return .yellow }; return .red
    }

    // MARK: - Export & Share Tab

    @State private var exportShareURL: URL?
    @State private var showExportShare = false

    private var settingsExportContent: some View {
        VStack(spacing: 12) {
            // ── Current Preset Export ────────────────────────────────────
            VStack(spacing: 8) {
                HStack {
                    Label("Current Preset", systemImage: "square.and.arrow.up")
                        .font(.headline)
                    Spacer()
                }
                Text("Export the current render settings as a shareable preset file.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 10) {
                    Button {
                        let preset = FractalPreset.fromSettings(
                            appModel.renderSettings,
                            name: "Export",
                            embeddedFormula: appModel.activeEmbeddedFormula
                        )
                        if let url = appModel.presetManager.exportPreset(preset) {
                            exportShareURL = url
                            showExportShare = true
                        }
                    } label: {
                        Label("Export Preset (.threshscene)", systemImage: "doc.badge.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(themeColor)
                }

                let hasMusicMappings = !(appModel.renderSettings.musicReactiveMappings.isEmpty)
                if hasMusicMappings {
                    Button {
                        var preset = FractalPreset.fromSettings(
                            appModel.renderSettings,
                            name: "Music Export",
                            embeddedFormula: appModel.activeEmbeddedFormula
                        )
                        preset.musicReactiveMappings = appModel.renderSettings.musicReactiveMappings
                        if let url = appModel.presetManager.exportPreset(preset) {
                            exportShareURL = url
                            showExportShare = true
                        }
                    } label: {
                        Label("Export Music Preset (.threshmp)", systemImage: "music.note.list")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(themeColor.opacity(0.06)))

            // ── Animation Scene Export ───────────────────────────────────
            VStack(spacing: 8) {
                HStack {
                    Label("Animation Scenes", systemImage: "film.stack")
                        .font(.headline)
                    Spacer()
                }
                Text("Export animation scenes. Scenes with attached songs export as music videos.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let mgr = appModel.animationManager {
                    if mgr.scenes.isEmpty {
                        Text("No scenes available.")
                            .foregroundStyle(.tertiary)
                            .font(.subheadline)
                            .padding(.vertical, 4)
                    } else {
                        ForEach(mgr.scenes) { scene in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(scene.name).font(.subheadline.weight(.medium))
                                    HStack(spacing: 6) {
                                        Text("\(scene.keyframes.count) keyframes")
                                        if scene.attachedSong != nil {
                                            Label("Music", systemImage: "music.note")
                                        }
                                    }
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button {
                                    if let url = mgr.exportSceneToFile(scene) {
                                        exportShareURL = url
                                        showExportShare = true
                                    }
                                } label: {
                                    Image(systemName: "square.and.arrow.up")
                                }
                                .buttonStyle(.bordered)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                } else {
                    Text("Animation manager not available.")
                        .foregroundStyle(.tertiary)
                        .font(.subheadline)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.blue.opacity(0.06)))

            // ── File Format Reference ───────────────────────────────────
            VStack(spacing: 8) {
                HStack {
                    Label("File Formats", systemImage: "doc.text")
                        .font(.headline)
                    Spacer()
                }
                VStack(alignment: .leading, spacing: 4) {
                    formatRow(ext: ".threshscene", desc: "Fractal preset (settings snapshot)")
                    formatRow(ext: ".threshanim", desc: "Animation scene (keyframe sequence)")
                    formatRow(ext: ".threshanimv", desc: "Animation + music (music video)")
                    formatRow(ext: ".threshmp", desc: "Music-reactive preset (audio mappings)")
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.06)))
        }
        .sheet(isPresented: $showExportShare) {
            if let url = exportShareURL {
                ShareLink(item: url) {
                    Label("Share File", systemImage: "square.and.arrow.up")
                }
                .padding()
            }
        }
    }

    private func formatRow(ext: String, desc: String) -> some View {
        HStack(spacing: 8) {
            Text(ext)
                .font(.caption.monospaced().weight(.semibold))
                .foregroundStyle(themeColor)
                .frame(width: 110, alignment: .leading)
            Text(desc)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }
    
    private var settingsAdvancedContent: some View {
        @Bindable var appModel = appModel
        return VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack { Image(systemName: "gauge.with.dots.needle.67percent").foregroundStyle(themeColor); Text("Pipeline Profiler").font(.headline) }
                HStack {
                    Button {
                        isProfilerRunning = true; appModel.runProfiler()
                        Task { try? await Task.sleep(for: .seconds(3)); await MainActor.run { isProfilerRunning = false; lastProfileTime = Date() } }
                    } label: {
                        HStack {
                            if isProfilerRunning { ProgressView().scaleEffect(0.7).frame(width: 16, height: 16) } else { Image(systemName: "play.fill") }
                            Text(isProfilerRunning ? "Profiling..." : "Run Profiler")
                        }
                    }.buttonStyle(.borderedProminent).tint(themeColor).disabled(isProfilerRunning)
                }
            }.padding().background(themeColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            
            VStack(alignment: .leading, spacing: 8) {
                HStack { Image(systemName: "chart.bar.fill").foregroundStyle(themeColor); Text("Live Stats").font(.headline) }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    StatBox(label: "FPS", value: String(format: "%.0f", cache.liveFPS), color: fpsColor)
                    StatBox(label: "Iterations", value: "\(cache.liveFractalIterations)", color: themeColor)
                    StatBox(label: "Ray Steps", value: "\(cache.liveMaxRaySteps)", color: themeColor.opacity(0.8))
                    StatBox(label: "Scale", value: String(format: "%.2f", cache.liveFractalScale), color: themeColor.opacity(0.6))
                }
            }.padding().background(themeColor.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
            
            VStack(alignment: .leading, spacing: 8) {
                HStack { Image(systemName: "film.fill").foregroundStyle(themeColor); Text("Animation Test").font(.headline) }
                Button {
                    if isTestAnimationPlaying { appModel.animationManager?.stop(); isTestAnimationPlaying = false }
                    else if let mgr = appModel.animationManager {
                        mgr.currentScene = AdvancedTestScene.create(startPosition: cache.livePosition)
                        mgr.play(); isTestAnimationPlaying = true
                    }
                } label: {
                    HStack { Image(systemName: isTestAnimationPlaying ? "stop.fill" : "play.fill"); Text(isTestAnimationPlaying ? "Stop" : "Play Test") }
                }.buttonStyle(.borderedProminent).tint(isTestAnimationPlaying ? .red : themeColor)
            }.padding().background(themeColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))

            // === EXPERIMENTAL: COHERENT PACKET RAYMARCH (Stages 0-3 prototype) ===
            // Replaces prevDepth*0.9 warm-start with single-DE-eval safety probe per
            // pixel; gates shared shadows on local normal coherence. Only takes effect
            // on the 8x8 adaptive compute path (Renderer Mode = Adaptive Compute).
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "atom").foregroundStyle(themeColor)
                    Text("Coherent Packet Raymarch")
                        .font(.headline)
                    Spacer()
                    Text("EXPERIMENTAL")
                        .font(.caption2.bold())
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                }
                Toggle(isOn: Binding(
                    get: { appModel.renderSettings.coherentPacketEnabled },
                    set: { appModel.renderSettings.coherentPacketEnabled = $0 }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Predict-validate warm-start")
                        Text("Single DE-eval safety probe + normal-coherence shadow gate. 8x8 compute path only.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }.tint(themeColor)
                Text("Layer-of-acceptance overlay shows immediately when this toggle is on (no other debug flag needed): magenta = warm-start hit, green = warm-start tight, red = warm-start rejected, cyan = shadow fallback. Untinted = legacy coarse path. 8x8 compute path only.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }.padding().background(themeColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))

#if DEBUG
            VStack(alignment: .leading, spacing: 8) {
                HStack { Image(systemName: "timer").foregroundStyle(themeColor); Text("Benchmarking").font(.headline) }
                HStack {
                    Button {
                        isBenchmarking.toggle()
                        BenchmarkManager.shared.toggleBenchmarking()
                    } label: {
                        HStack {
                            Image(systemName: isBenchmarking ? "stop.circle.fill" : "play.circle.fill")
                            Text(isBenchmarking ? "Stop Benchmarking" : "Start Benchmarking")
                        }
                    }.buttonStyle(.borderedProminent).tint(isBenchmarking ? .red : themeColor)
                    
                    if !isBenchmarking {
                        Button {
                            BenchmarkManager.shared.clearStats()
                        } label: {
                            Text("Clear Stats")
                        }.buttonStyle(.bordered)
                    }
                }
                Text("Check Xcode console for results.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }.padding().background(themeColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
#endif
        }
    }
}

private struct HoldToSaveResetButton: View {
    let onTapReset: () -> Void
    let onHoldReady: () -> Void

    @State private var isPressing = false
    @State private var holdProgress: CGFloat = 0
    @State private var holdTask: Task<Void, Never>?
    @State private var holdCompleted = false

    private let holdArmDelay: TimeInterval = 0.25
    private let holdDuration: TimeInterval = 1.1

    private var totalHoldDuration: TimeInterval {
        holdArmDelay + holdDuration
    }

    var body: some View {
        ZStack {
            Capsule()
                .fill(Color.green.opacity(0.12))

            GeometryReader { geo in
                Capsule()
                    .fill(Color.green.opacity(0.28))
                    .frame(width: max(0, geo.size.width * holdProgress))
            }
            .clipShape(Capsule())

            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .stroke(Color.primary.opacity(0.15), lineWidth: 2)
                        .frame(width: 18, height: 18)
                    Circle()
                        .trim(from: 0, to: holdProgress)
                        .stroke(Color.green,
                                style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 18, height: 18)

                    Image(systemName: isPressing ? "square.and.arrow.down" : "arrow.counterclockwise")
                        .font(.system(size: 9, weight: .semibold))
                }

                Text(isPressing ? "Save" : "Reset")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 118, height: 34)
        .contentShape(Capsule())
        .overlay(
            Capsule()
                .stroke(Color.green.opacity(0.45), lineWidth: 1)
        )
        .animation(.easeInOut(duration: 0.15), value: holdProgress)
        .animation(.easeInOut(duration: 0.2), value: isPressing)
        .help("Tap to reset. Long press to choose where to save the current settings.")
        .onTapGesture {
            guard !isPressing else { return }
            onTapReset()
        }
        .onLongPressGesture(minimumDuration: totalHoldDuration, maximumDistance: 24, pressing: handlePressingChanged) {
            completeHold()
        }
    }

    private func handlePressingChanged(_ pressing: Bool) {
        if pressing {
            holdCompleted = false
            isPressing = true
            holdTask?.cancel()
            holdTask = Task { @MainActor in
                let start = Date()
                while !Task.isCancelled {
                    let elapsed = Date().timeIntervalSince(start)
                    let activeHoldElapsed = max(0.0, elapsed - holdArmDelay)
                    holdProgress = min(1.0, activeHoldElapsed / holdDuration)
                    if elapsed >= totalHoldDuration { break }
                    try? await Task.sleep(nanoseconds: 33_000_000)
                }
            }
        } else {
            holdTask?.cancel()
            holdTask = nil
            isPressing = false
            if !holdCompleted {
                holdProgress = 0
            }
        }
    }

    private func completeHold() {
        holdCompleted = true
        holdTask?.cancel()
        holdTask = nil
        holdProgress = 1
        isPressing = false
        onHoldReady()

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 180_000_000)
            holdProgress = 0
            isPressing = false
            holdCompleted = false
        }
    }
}

private struct ActivityLightButton: View {
    let title: String
    let systemImage: String
    let color: Color
    let isActive: Bool
    let count: Int?
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(isActive ? color : Color.secondary.opacity(0.35))
                        .frame(width: 8, height: 8)
                        .shadow(color: isActive ? color.opacity(0.65) : .clear, radius: 4)

                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isActive ? color : .secondary)
                        .frame(width: 14, height: 14)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill((isActive ? color : Color.secondary).opacity(isHovering ? 0.2 : (isActive ? 0.14 : 0.08)))
                )
                .overlay(
                    Capsule()
                        .strokeBorder((isActive ? color : Color.secondary).opacity(isHovering ? 0.55 : (isActive ? 0.34 : 0.12)), lineWidth: 1)
                )
                .scaleEffect(isHovering ? 1.06 : 1.0)

                if let count {
                    Text("\(count)")
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .frame(minWidth: 13, minHeight: 13)
                        .padding(.horizontal, 1)
                        .background(Capsule().fill(color))
                        .offset(x: 5, y: -5)
                }
            }
        }
        .buttonStyle(.plain)
        .thresholdHoverEffect()
        .onHover { hovering in
            withAnimation(.snappy(duration: 0.18, extraBounce: 0.05)) {
                isHovering = hovering
            }
        }
        .help("\(title): \(isActive ? "On" : "Off")")
        .accessibilityLabel(title)
        .accessibilityValue(isActive ? "On" : "Off")
    }
}

private enum PresetPreviewGenerator {
    @MainActor
    static func makePNGData(
        name: String,
        fractalType: FractalModelType,
        gradientState: GradientState,
        lightingPreset: LightingPreset
    ) -> Data? {
        let content = PresetPreviewCard(
            name: name,
            fractalType: fractalType,
            gradientState: gradientState,
            lightingPreset: lightingPreset
        )
        .frame(width: 512, height: 320)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 2

        #if os(visionOS) || os(iOS)
        return renderer.uiImage?.pngData()
        #elseif os(macOS)
        guard let image = renderer.nsImage,
              let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
        #else
        return nil
        #endif
    }
}

private struct PresetPreviewCard: View {
    let name: String
    let fractalType: FractalModelType
    let gradientState: GradientState
    let lightingPreset: LightingPreset

    private var gradientStops: [Gradient.Stop] {
        let stops = gradientState.gradient.stops
        guard !stops.isEmpty else {
            return [
                .init(color: .blue, location: 0),
                .init(color: .purple, location: 1)
            ]
        }

        return stops.map { stop in
            Gradient.Stop(
                color: Color(
                    red: Double(max(0, min(1, stop.color.x))),
                    green: Double(max(0, min(1, stop.color.y))),
                    blue: Double(max(0, min(1, stop.color.z)))
                ),
                location: CGFloat(max(0, min(1, stop.position)))
            )
        }
    }

    var body: some View {
        ZStack {
            LinearGradient(
                gradient: Gradient(stops: gradientStops),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [.white.opacity(0.42), .clear],
                center: .center,
                startRadius: 20,
                endRadius: 260
            )

            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    Image(systemName: fractalType.icon)
                        .font(.system(size: 44, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 64, height: 64)
                        .background(Circle().fill(.black.opacity(0.22)))

                    Spacer()

                    Text(lightingPreset.displayName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(.black.opacity(0.24)))
                }

                Spacer()

                VStack(alignment: .leading, spacing: 5) {
                    Text(name)
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    Text(fractalType.displayName)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.white.opacity(0.86))
                        .lineLimit(1)
                }
            }
            .padding(26)
        }
    }
}

private struct SaveDestinationSheet: View {
    let onSave: (SaveChoice, String?) -> Void
    let onCancel: () -> Void

    @State private var choice: SaveChoice = .resetLocation
    @State private var manualPresetName = ""

    private var canSave: Bool {
        if choice != .presetCustomName && choice != .presetWithPreview { return true }
        return !manualPresetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Save Current Settings")
                    .font(.headline)
                Text("Choose one destination.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 8) {
                saveChoiceButton(
                    choice: .resetLocation,
                    title: "Reset Location",
                    subtitle: "Replace the current reset/default state.",
                    systemImage: "arrow.counterclockwise"
                )

                saveChoiceButton(
                    choice: .presetCustomName,
                    title: "Preset - Custom Name",
                    subtitle: "Save with a name you enter.",
                    systemImage: "character.cursor.ibeam"
                )

                saveChoiceButton(
                    choice: .presetWithPreview,
                    title: "Save + Convert Preview",
                    subtitle: "Save a named preset with a generated image.",
                    systemImage: "photo.badge.plus"
                )
            }

            if choice == .presetCustomName || choice == .presetWithPreview {
                TextField("Preset name", text: $manualPresetName)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Button("Cancel", role: .cancel) {
                    onCancel()
                }
                Spacer()

                Button("Save") {
                    let trimmed = manualPresetName.trimmingCharacters(in: .whitespacesAndNewlines)
                    onSave(choice, trimmed.isEmpty ? nil : trimmed)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
            }
        }
        .padding(16)
        .frame(width: 360)
    }

    private func saveChoiceButton(choice: SaveChoice, title: String, subtitle: String, systemImage: String) -> some View {
        Button {
            self.choice = choice
        } label: {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if self.choice == choice {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.blue)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(self.choice == choice ? Color.blue.opacity(0.12) : Color.secondary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(self.choice == choice ? Color.blue.opacity(0.4) : Color.secondary.opacity(0.12), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct ExternalFileImportSheet: View {
    let request: ExternalFileImportRequest
    let onPreview: () -> Void
    let onImport: () -> Void
    let onCancel: () -> Void

    private var fileKind: String {
        switch request.payload {
        case .preset: return request.fileExtension == "threshmp" ? "Music Preset" : "Fractal Scene"
        case .animation: return request.fileExtension == "threshanimv" ? "Music Video Animation" : "Animation"
        }
    }

    private var accentColor: Color {
        switch request.payload {
        case .preset: return request.fileExtension == "threshmp" ? .blue : .purple
        case .animation: return .green
        }
    }

    private var iconName: String {
        switch request.payload {
        case .preset: return request.fileExtension == "threshmp" ? "music.note.list" : "cube.transparent"
        case .animation: return request.fileExtension == "threshanimv" ? "music.note.tv" : "film.stack"
        }
    }

    private var title: String {
        switch request.payload {
        case .preset(let preset): return preset.name
        case .animation(let scene): return scene.name
        }
    }

    private var subtitle: String {
        switch request.payload {
        case .preset(let preset): return preset.fractalType.displayName
        case .animation(let scene):
            let duration = Self.durationFormatter.string(from: scene.totalDuration) ?? String(format: "%.1fs", scene.totalDuration)
            return "\(scene.keyframes.count) keyframes, \(duration)"
        }
    }

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: iconName)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(accentColor)
                    .frame(width: 52, height: 52)
                    .background(Circle().fill(accentColor.opacity(0.14)))

                VStack(alignment: .leading, spacing: 4) {
                    Text("Open Threshold File")
                        .font(.headline)
                    Text(request.fileName)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.title3.weight(.semibold))
                            .lineLimit(2)
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text(fileKind)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(accentColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(accentColor.opacity(0.13)))
                }

                VStack(spacing: 7) {
                    ForEach(detailRows, id: \.0) { label, value in
                        HStack(alignment: .firstTextBaseline) {
                            Text(label)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 12)
                            Text(value)
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.07)))
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(accentColor.opacity(0.07)))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(accentColor.opacity(0.18), lineWidth: 1)
            )

            HStack(spacing: 10) {
                Button(role: .cancel) {
                    onCancel()
                } label: {
                    Label("Cancel", systemImage: "xmark")
                }

                Spacer()

                Button {
                    onPreview()
                } label: {
                    Label("Preview", systemImage: "eye")
                }
                .buttonStyle(.bordered)

                Button {
                    onImport()
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .tint(accentColor)
            }
        }
        .padding(18)
        .frame(width: 440)
    }

    private var detailRows: [(String, String)] {
        switch request.payload {
        case .preset(let preset):
            let musicEnabled = preset.audioReactiveConfig?.fractalAudioReactiveEnabled ?? !(preset.musicReactiveMappings?.isEmpty ?? true)
            return [
                ("Format", ".\(request.fileExtension)"),
                ("Iterations", "\(preset.fractalIterations)"),
                ("Ray Steps", "\(preset.maxRaySteps)"),
                ("Music Reactive", musicEnabled ? "Yes" : "No")
            ]
        case .animation(let scene):
            return [
                ("Format", ".\(request.fileExtension)"),
                ("Looping", scene.isLooping ? "Yes" : "No"),
                ("Fractal", scene.fractalType?.displayName ?? "Scene default"),
                ("Song", scene.attachedSong.map { "\($0.title) - \($0.artist)" } ?? "None")
            ]
        }
    }
}

// MARK: - FPS Indicator (isolated to prevent 90Hz invalidation of ContentView)

/// Standalone view that reads `renderMetrics.fps` so the ~2Hz render-loop updates
/// only invalidate this small capsule, not the entire ContentView tree.
private struct FPSIndicatorView: View {
    @Environment(AppModel.self) private var appModel

    private var indicatorColor: Color {
        let fps = appModel.renderMetrics.fps
        if fps >= 85 { return .green }
        else if fps >= 60 { return .yellow }
        else if fps >= 45 { return .orange }
        else { return .red }
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: appModel.isUsingSpecializedPipeline ? "bolt.fill" : "bolt.slash")
                .font(.caption2)
                .foregroundStyle(appModel.isUsingSpecializedPipeline ? .green : .orange)
            Circle().fill(indicatorColor).frame(width: 8, height: 8)
            Text("\(appModel.renderMetrics.fps, specifier: "%.0f") FPS")
                .font(.caption.bold()).monospacedDigit()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(.ultraThinMaterial))
    }
}

private extension View {
    @ViewBuilder
    func thresholdGlassBackground(cornerRadius: CGFloat) -> some View {
#if os(visionOS)
        glassBackgroundEffect(in: .rect(cornerRadius: cornerRadius))
#else
        self
#endif
    }

    @ViewBuilder
    func thresholdTopDockOrnament<Content: View>(
        isVisible: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
#if os(visionOS)
        ornament(
            visibility: isVisible ? .visible : .hidden,
            attachmentAnchor: .scene(.top),
            contentAlignment: .bottom,
            ornament: content
        )
#else
        self
#endif
    }

    @ViewBuilder
    func thresholdHoverEffect() -> some View {
#if os(visionOS)
        hoverEffect()
#else
        self
#endif
    }
}

#if os(visionOS)
#Preview(windowStyle: .automatic) {
    ContentView().environment(AppModel())
}
#else
#Preview {
    ContentView().environment(AppModel())
}
#endif
