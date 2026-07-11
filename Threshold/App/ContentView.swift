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
// MARK: - ContentView
// ═══════════════════════════════════════════════════════════════════════════════

struct ContentView: View {
    @Environment(AppModel.self) var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openWindow) var openWindow
    @Environment(\.dismissWindow) var dismissWindow
    
    @State var cache = UISettingsCache()
    @AppStorage("ContentView.topDockTab") private var topDockTab: TopDockTab = .explore
    @AppStorage("ContentView.exploreRailSection") private var exploreRailSection: ExploreRailSection = .jumpingOff
    @AppStorage("ContentView.shapeRailSection") private var shapeRailSection: ShapeRailSection = .parameters
    @AppStorage("ContentView.visualizationsRailSection") private var visualizationsRailSection: VisualizationsRailSection = .color
    @AppStorage("ContentView.musicRailSection") private var musicRailSection: MusicRailSection = .playback
    // Default to Budget. Key bumped to ".v2" so the new default actually lands
    // for anyone who already had a different section persisted — the tab writes
    // this on every open, so a plain default change wouldn't take effect. The old
    // Budget/Acceleration were merged into Tuning and the live dashboard split out
    // into Overview; stale raw values no longer decode, so AppStorage falls back to
    // this default (Overview is the landing section).
    @AppStorage("ContentView.performanceRailSection.v3") var performanceRailSection: PerformanceRailSection = .overview
    @AppStorage("ContentView.skipOuterNavigationSync") private var skipOuterNavigationSync = false
    // Persist last-selected tab and sub-tabs across launches.
    @AppStorage("ContentView.selectedTab") var selectedTab: SidebarTab = .fractal
    @AppStorage("FractalGridView.innerTab") var fractalBrowseTab: FractalBrowseTab = .jumpingOff
    @AppStorage("ContentView.fractalSubTab") var fractalSubTab: FractalSubTab = .shape
    @AppStorage("ContentView.shapeInnerTab") var shapeInnerTab: ShapeInnerTab = .parameters
    @State var animateEditButtonsVisible = false
    @AppStorage("ContentView.coloringSubTab") var coloringSubTab: ColoringSubTab = .gradient
    @AppStorage("ContentView.effectsSubTab") var effectsSubTab: EffectsSubTab = .dynamic
    @AppStorage("MusicTabContent.innerTab") private var musicPanelTab: MusicPanelTab = .music
    @AppStorage("ContentView.settingsSubTab") var settingsSubTab: SettingsSubTab = .display
    @AppStorage("ContentView.showPerformanceInMenu") var showPerformanceInMenu: Bool = false
    @AppStorage("ContentView.pinnedRailControls") private var pinnedRailControlsRaw: String = ""
    @State var showStopsPopover = false
    @State private var showSaveDestinationSheet = false
    /// One-time first-run prompt to choose local vs iCloud storage.
    @State private var showStorageChoice = false
    @State private var didLongPressPinnedRailControl: PinnedRailControl?
    #if os(macOS)
    @State var isHoldingSaveSheetAdjustment = false
    @State var isHoldingImportSheetAdjustment = false
    @State var isHoldingExportSheetAdjustment = false
    #endif

    // Tab-local UI state (kept here because stored properties cannot live in
    // the per-tab `extension ContentView` files).
    @State var renamingGradientIndex: Int? = nil
    @State var renamingGradientName: String = ""
    @AppStorage("allowCustomScenes") var allowCustomScenes: Bool = false
    /// Menu text size (Dynamic Type). Index into `DS.textSizeSteps`; the "Text
    /// Size" slider in Settings ▸ Display writes it and the menu body applies it
    /// via `.dynamicTypeSize`. Default is platform-aware (one step up on
    /// visionOS, system default elsewhere).
    @AppStorage(DS.textSizeStorageKey) var uiMenuTextSizeIndex: Int = DS.defaultTextSizeIndex
#if os(iOS)
    @AppStorage(TouchVisualizationSettings.defaultsKey) var showTouchIndicators: Bool = true
#endif
    @State var exportShareItem: ExportShareItem?

    private static let presetDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd HH-mm"
        return f
    }()

    private var sectionRailWidth: CGFloat {
    #if os(visionOS)
        228
    #elseif os(iOS)
        208
    #else
        170
    #endif
    }

    private var immersiveLayoutMinimumWidth: CGFloat? {
    #if os(visionOS)
        1240
    #elseif os(iOS)
        nil
    #else
        980
    #endif
    }

    private var activeMusicPermutationCount: Int {
        cache.audioReactive.fractalAudioReactiveEnabled
            ? cache.audioReactive.musicReactiveMappings.count
            : 0
    }

    private var musicPresetBankEffectBinding: Binding<MusicPresetBankEffect> {
        Binding(
            get: { appModel.musicPresetBankEffect },
            set: { appModel.musicPresetBankEffect = $0 }
        )
    }

    /// True when spherical inversion is warping space, or the sphere-projection
    /// option is actively layered on the Mandelbox — drives the Shape tab's
    /// active badge. Sphere projection only affects the Mandelbox fast path, so
    /// the badge ignores it on other fractal types (where it's a no-op).
    private var isSphericalInversionActive: Bool {
        cache.display.sphericalInversionMode != .off
            || (cache.display.sphereProjectionEnabled && cache.fractalType == .mandelbox)
    }

    private var activeDynamicEffectCount: Int {
        var count = 0
        if cache.lighting.gradientCycleEffect.enabled { count += 1 }
        if cache.lighting.hueRotationEffect.enabled { count += 1 }
        if cache.lighting.fogEffect.hueRotateEnabled { count += 1 }
        if cache.lighting.pulseEffect.enabled { count += 1 }
        if cache.lighting.linearRailEffect.enabled { count += 1 }
        if cache.lighting.beatFlashEffect.enabled { count += 1 }
        if cache.fractalType.supports(.polarRotation), cache.lighting.polarRotationEffect.enabled { count += 1 }
        if cache.fractalType.supports(.juliaDrift), cache.lighting.juliaDriftEffect.enabled { count += 1 }
        if appModel.musicPresetBankEffect.isEnabled { count += 1 }
        return count
    }

    var hasShapeMusicMapping: Bool {
        cache.audioReactive.musicReactiveMappings.contains { mapping in
            let target = mapping.target.migrated
            return target == .iterations || target.isFormulaParam
        }
    }

    var hasFlashingMusicVisuals: Bool {
        cache.audioReactive.musicReactiveMappings.contains(where: \.hasFlashingRisk)
    }

        private var shouldUseWorkspaceLayout: Bool {
    #if os(macOS) || os(iOS)
        true
    #else
        appModel.immersiveSpaceState == .open
    #endif
        }

        private var isMenuContentVisible: Bool {
    #if os(macOS) || os(iOS)
        true
    #else
        appModel.isMenuWindowVisible
    #endif
        }

        private var shouldRenderInlineTopDock: Bool {
    #if os(macOS) || os(iOS)
        true
    #else
        false
    #endif
        }

        private var supportsGestureEditing: Bool {
    #if os(macOS) || os(iOS)
        false
    #else
        true
    #endif
        }

    @AppStorage("qualityGoalPreference.v3") var qualityGoalPreferenceRaw: Int = QualityGoalPreference.simplified.rawValue
    var qualityGoalPreference: QualityGoalPreference {
        QualityGoalPreference(rawValue: qualityGoalPreferenceRaw) ?? .simplified
    }

    var effectiveDirectBudgetLabel: String { "Detail Budget" }

    var effectiveDirectBudgetUnavailableText: String {
        "Detail Budget is unavailable in Adaptive Compute mode. Switch Renderer Mode to Fragment to enable MetalFX spatial upscaling."
    }

    // Developer state
    @State var isProfilerRunning = false
    @State var isTestAnimationPlaying = false
#if DEBUG
    @State var isBenchmarking = false
#endif
    

    
    var body: some View {
        @Bindable var appModel = appModel

        let isShortcutOrnamentVisible = !shouldRenderInlineTopDock && appModel.immersiveSpaceState != .closed && appModel.isMenuWindowVisible && isRendererNavigationReady

        Group {
            if shouldUseWorkspaceLayout {
                immersiveLayout
            } else {
                preImmersiveLayout
            }
        }
        .overlay(alignment: .top) {
            // Surfaces ErrorReporter failures (preset/animation import, etc.) that
            // were previously reported but never shown. Transient: self-dismisses
            // and only renders while currentError is set.
            ErrorBannerView(errorReporter: appModel.errorReporter)
                .padding(.top, 8)
        }
        .environment(\.menuAdjustmentActions, MenuAdjustmentActions(
            begin: { appModel.beginMenuAdjustment() },
            end: { appModel.endMenuAdjustment() }
        ))
        .environment(\.derivedValueProvider, DerivedValueProvider(
            resolve: { [cache] id in cache.liveDerivedValue(for: id) },
            musicActive: cache.isMusicReactiveActive
        ))
        #if os(visionOS)
        // Menu text size (Settings ▸ Display ▸ Text Size). Enlarges the menu's
        // semantic-font text crisply via Dynamic Type and reflows around it,
        // leaving icons and chrome geometry untouched.
        .dynamicTypeSize(DS.textSize(forIndex: uiMenuTextSizeIndex))
        #endif
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
            // First-run: prompt once for the storage location (local vs iCloud).
            if !StorageLocation.shared.hasChosenMode {
                showStorageChoice = true
            }
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
            appModel.openQuickTogglesHandler = {
                withMotionSensitiveAnimation(.easeInOut(duration: 0.2)) {
                    selectedTab = .quickToggles
                }
            }
            appModel.isQuickTogglesActiveHandler = {
                selectedTab == .quickToggles
            }
            appModel.openSavePresetMenuHandler = {
                showSaveDestinationSheet = true
            }
            cache.startSync(with: appModel.renderSettings, appModel: appModel)
            appModel.handTrackingEnabled = true
            appModel.renderSettings.menuToggleGestureEnabled = true
            normalizeDesktopSelectionIfNeeded()
            syncNavigationChromeFromLegacySelection()
        }
        .onDisappear {
            cache.stopSync()
            appModel.openSavePresetMenuHandler = nil
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
            if shouldGateRendererNavigation, !isRendererNavigationReady, topDockTab != .explore {
                withMotionSensitiveAnimation(.easeInOut(duration: 0.2)) { activateTopDock(.explore) }
            }
        }
        .onChange(of: appModel.rendererStartupWarmupComplete) { _, isReady in
            if shouldGateRendererNavigation, !isReady, topDockTab != .explore {
                withMotionSensitiveAnimation(.easeInOut(duration: 0.2)) { activateTopDock(.explore) }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // Returning to the app: re-mirror the store folder so any files added
            // or deleted while away (e.g. in the Files app) reflect immediately.
            if phase == .active { appModel.reloadStoresFromDisk() }
        }
        .sheet(isPresented: $showStorageChoice) {
            StorageModeChoiceSheet { chosen in
                if chosen != StorageLocation.shared.mode {
                    appModel.switchStorageMode(to: chosen)
                } else {
                    StorageLocation.shared.markModeChosen()
                }
                showStorageChoice = false
            }
            .interactiveDismissDisabled(true)
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
        #if os(macOS)
        // Sheets present as child windows on Mac, so the pointer leaves the
        // sidebar's hover region while they're open. Hold the panel open for
        // their lifetime the same way MusicTabView holds it for its popover.
        .onChange(of: showSaveDestinationSheet) { _, isPresented in
            updateMacSheetMenuAdjustment(isPresented, holding: &isHoldingSaveSheetAdjustment)
        }
        .onChange(of: appModel.pendingExternalImport != nil) { _, isPresented in
            updateMacSheetMenuAdjustment(isPresented, holding: &isHoldingImportSheetAdjustment)
        }
        #endif
    }

    #if os(macOS)
    func updateMacSheetMenuAdjustment(_ isPresented: Bool, holding flag: inout Bool) {
        guard flag != isPresented else { return }
        flag = isPresented
        if isPresented {
            appModel.beginMenuAdjustment()
        } else {
            appModel.endMenuAdjustment()
        }
    }
    #endif

    private var menuSurfaceFill: Color {
        colorScheme == .dark ? Color.black.opacity(0.8) : Color.white.opacity(0.72)
    }

    private var menuSurfaceStroke: Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.08)
    }

    var liveFPSColor: Color {
        let fps = cache.liveFPS
        if fps >= 85 { return .green }
        if fps >= 60 { return .yellow }
        return .red
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
        // Tween the reset the same way scene switching does: snapshot the current
        // displayed values, apply the reset target, then ease back to it (rather
        // than snapping). commitSceneTransition is a no-op when the transition
        // duration is 0 or an animation is playing.
        appModel.renderSettings.beginSceneTransitionSnapshot()
        if let preset = appModel.activeResetPreset {
            appModel.presetManager.loadPreset(
                preset,
                into: appModel.renderSettings,
                resetEnvironment: true
            )
            appModel.applyPresetGestureOverridesIfNeeded(for: preset)
            appModel.gestureController?.syncWithSettings()
        } else {
            appModel.gestureController?.applyFractalDefaults()
        }
        appModel.renderSettings.commitSceneTransition()
        cache.loadFromSettings()
    }

    private func saveCurrentAsResetDefaults() {
        guard appModel.gestureController?.saveCurrentAsFractalDefaults() == true else { return }
        cache.loadFromSettings()
    }

    private func saveCurrentAsPreset(named providedName: String? = nil, includeGeneratedPreview: Bool = false) {
        let autoName = "Preset \(Self.presetDateFormatter.string(from: Date()))"
        let presetName = providedName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = (presetName?.isEmpty == false) ? (presetName ?? autoName) : autoName
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
                    ("cube.transparent", "Fractals", Color.indigo),
                    ("hand.raised.fingers.spread", "Gestures", Color.green),
                    ("waveform", "Reactive", Color.blue),
                    ("paintbrush.pointed.fill", "Lights", Color.pink),
                ] as [(String, String, Color)], id: \.0) { icon, label, color in
                    VStack(spacing: 5) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(color.opacity(0.16))
                            Image(systemName: icon)
                                .font(.system(size: IconSize.large, weight: .semibold))
                                .foregroundStyle(color)
                        }
                        .frame(width: 44, height: 44)
                        Text(label)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            ToggleImmersiveSpaceButton()

#if os(visionOS)
            ImmersionStylePicker()
                .frame(maxWidth: 320)
#endif

            VStack(spacing: 8) {
                ProgressView()
                Text("Compiling shaders — first launch may take a moment…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .opacity(isTransitioning ? 1 : 0)
            .animation(.easeInOut(duration: 0.2), value: isTransitioning)
        }
        .padding(30)
        .frame(minWidth: 300, idealWidth: 360, maxWidth: 360, minHeight: 280)
    }
    
    // MARK: - Immersive Layout (Sidebar + Content)
    
    private var immersiveLayout: some View {
        VStack(spacing: 10) {
#if os(macOS) || os(iOS)
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
    .frame(minWidth: immersiveLayoutMinimumWidth, minHeight: 576)
    }
    
    // MARK: - Top Dock

    private var topDockBar: some View {
        let visibleTabs = TopDockTab.allCases
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
                                .font(.system(size: IconSize.medium, weight: .semibold))
                            topDockBadge(for: tab)
                        }
                        Text(tab.title)
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
#if os(visionOS)
        // On visionOS the ornament's plate is the system glass — supplying our own
        // translucent RoundedRectangle fill on top of it fought the glass and left
        // the bar reading as an empty transparent card with no visible icons/text.
        // Use glassBackgroundEffect as the sole plate and keep the content in front.
        topDockBar
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .thresholdGlassBackground(cornerRadius: 18)
#else
        topDockBar
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(colorScheme == .dark ? Color.black.opacity(0.82) : Color.white.opacity(0.72))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.14), lineWidth: 1)
            )
#endif
    }

    // MARK: - Context Rail

    private var sectionRail: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 8) {
                    switch topDockTab {
                    case .explore:
                        let exploreSections = ExploreRailSection.allCases.filter { section in
                            #if os(macOS)
                            guard section != .mixed else { return false }
                            #endif
                            return section != .customScenes || allowCustomScenes
                        }
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
                        // Performance moved out to its own top-dock tab; drop it here.
                        ForEach(ShapeRailSection.allCases.filter { $0 != .performance }, id: \.self) { section in
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
                    case .performance:
                        ForEach(PerformanceRailSection.allCases, id: \.self) { section in
                            railButton(
                                title: section.rawValue,
                                systemImage: section.icon,
                                isSelected: selectedTab != .gestures && selectedTab != .settings && topDockTab == .performance && performanceRailSection == section
                            ) {
                                activatePerformanceSection(section)
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

                railButton(title: "Quick Toggles", systemImage: SidebarTab.quickToggles.icon, isSelected: selectedTab == .quickToggles) {
                    selectedTab = .quickToggles
                }

                railButton(title: "Settings", systemImage: SidebarTab.settings.icon, isSelected: selectedTab == .settings) {
                    selectedTab = .settings
                }
            }
            .padding(.top, 8)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: sectionRailWidth)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private func topDockBadge(for tab: TopDockTab) -> some View {
        switch tab {
        case .visualizations where activeDynamicEffectCount > 0:
            countBadge(activeDynamicEffectCount, color: .pink)
        case .music where activeMusicPermutationCount > 0:
            countBadge(activeMusicPermutationCount, color: .green)
        case .shape where isSphericalInversionActive:
            dotBadge(color: .indigo)
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
                    .font(.system(size: IconSize.medium, weight: .semibold))
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
                .font(.system(size: IconSize.medium, weight: .semibold))
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
        case .exploreMixed, .musicSongs, .musicPlaylists, .musicAlbums:
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

    /// Small filled dot for boolean "active" states (e.g. spherical inversion on the Shape tab).
    private func dotBadge(color: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .overlay(Circle().strokeBorder(Color.white.opacity(0.85), lineWidth: 1))
            .offset(x: 5, y: -5)
            .accessibilityHidden(true)
    }

    private func syncNavigationChromeFromLegacySelectionIfNeeded() {
        guard !skipOuterNavigationSync else { return }
        syncNavigationChromeFromLegacySelection()
    }

            private var shouldGateRendererNavigation: Bool {
        #if os(iOS)
            false
        #else
            true
        #endif
            }

            private var isRendererNavigationReady: Bool {
        #if os(iOS)
            true
        #elseif os(macOS)
        appModel.rendererStartupWarmupComplete
    #else
        appModel.immersiveSpaceState == .open && appModel.rendererStartupWarmupComplete
    #endif
        }

    func dismissMenuWindowIfNeeded() {
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
        case .performance:
            activatePerformanceSection(performanceRailSection)
        }
    }

    private func activateExploreSection(_ section: ExploreRailSection) {
        topDockTab = .explore
        #if os(macOS)
        let resolvedSection: ExploreRailSection = section == .mixed ? .jumpingOff : section
        #else
        let resolvedSection = section
        #endif
        exploreRailSection = resolvedSection
        selectedTab = .fractal
        fractalSubTab = .browse
        fractalBrowseTab = resolvedSection.browseTab
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
        case .hands:
            fractalSubTab = .shape
            shapeInnerTab = .hands
        case .space:
            fractalSubTab = .space
        case .transformations:
            fractalSubTab = .transform
        case .bounding:
            fractalSubTab = .bounding
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
        case .transition:
            selectedTab = .transition
        case .reactive:
            selectedTab = .music
            musicPanelTab = .visualizations
        }
    }

    private func activatePerformanceSection(_ section: PerformanceRailSection) {
        topDockTab = .performance
        performanceRailSection = section
        selectedTab = .fractal
        fractalSubTab = .render
    }

    private func activateMusicSection(_ section: MusicRailSection) {
        topDockTab = .music
        musicRailSection = section
        selectedTab = .music
        musicPanelTab = section.musicPanelTab
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
        case .exploreMixed:
            return topDockTab == .explore && exploreRailSection == .mixed && selectedTab != .gestures && selectedTab != .settings
        case .exploreCustomScenes:
            return topDockTab == .explore && exploreRailSection == .customScenes && selectedTab != .gestures && selectedTab != .settings
        case .shapeParameters:
            return topDockTab == .shape && shapeRailSection == .parameters && selectedTab != .gestures && selectedTab != .settings
        case .shapeFormula:
            return topDockTab == .shape && shapeRailSection == .formula && selectedTab != .gestures && selectedTab != .settings
        case .shapeHands:
            return topDockTab == .shape && shapeRailSection == .hands && selectedTab != .gestures && selectedTab != .settings
        case .shapeSpace:
            return topDockTab == .shape && shapeRailSection == .space && selectedTab != .gestures && selectedTab != .settings
        case .shapeTransformations:
            return topDockTab == .shape && shapeRailSection == .transformations && selectedTab != .gestures && selectedTab != .settings
        case .shapeBounding:
            return topDockTab == .shape && shapeRailSection == .bounding && selectedTab != .gestures && selectedTab != .settings
        case .shapePerformance:
            return topDockTab == .performance && selectedTab != .gestures && selectedTab != .settings
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
        case .visualizationsTransition:
            return topDockTab == .visualizations && visualizationsRailSection == .transition && selectedTab != .gestures && selectedTab != .settings
        case .visualizationsReactive:
            return topDockTab == .visualizations && visualizationsRailSection == .reactive && selectedTab != .gestures && selectedTab != .settings
        case .musicPlayback:
            return topDockTab == .music && musicRailSection == .playback && selectedTab != .gestures && selectedTab != .settings
        case .musicLFO:
            return topDockTab == .music && musicRailSection == .lfo && selectedTab != .gestures && selectedTab != .settings
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
            case .exploreMixed:
                activateExploreSection(.mixed)
            case .exploreCustomScenes:
                activateExploreSection(.customScenes)
            case .shapeParameters:
                activateShapeSection(.parameters)
            case .shapeFormula:
                activateShapeSection(.formula)
            case .shapeHands:
                activateShapeSection(.hands)
            case .shapeSpace:
                activateShapeSection(.space)
            case .shapeTransformations:
                activateShapeSection(.transformations)
            case .shapeBounding:
                activateShapeSection(.bounding)
            case .shapePerformance:
                activatePerformanceSection(.tuning)
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
            case .visualizationsTransition:
                activateVisualizationsSection(.transition)
            case .visualizationsReactive:
                activateVisualizationsSection(.reactive)
            case .musicPlayback:
                activateMusicSection(.playback)
            case .musicLFO:
                activateMusicSection(.lfo)
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
        case .mixed: return .exploreMixed
        case .customScenes: return .exploreCustomScenes
        }
    }

    private func pinnedRailControl(for section: ShapeRailSection) -> PinnedRailControl {
        switch section {
        case .parameters: return .shapeParameters
        case .formula: return .shapeFormula
        case .hands: return .shapeHands
        case .space: return .shapeSpace
        case .transformations: return .shapeTransformations
        case .bounding: return .shapeBounding
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
        case .transition: return .visualizationsTransition
        case .reactive: return .visualizationsReactive
        }
    }

    private func pinnedRailControl(for section: MusicRailSection) -> PinnedRailControl {
        switch section {
        case .playback: return .musicPlayback
        case .lfo: return .musicLFO
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
                #if os(macOS)
                exploreRailSection = ExploreRailSection.allCases.first(where: {
                    $0 != .mixed && $0.browseTab == fractalBrowseTab
                }) ?? .jumpingOff
                #else
                exploreRailSection = ExploreRailSection.allCases.first(where: { $0.browseTab == fractalBrowseTab }) ?? .jumpingOff
                #endif
            case .shape:
                topDockTab = .shape
                switch shapeInnerTab {
                case .formula: shapeRailSection = .formula
                case .hands: shapeRailSection = .hands
                case .parameters: shapeRailSection = .parameters
                }
            case .space:
                topDockTab = .shape
                shapeRailSection = .space
            case .transform:
                topDockTab = .shape
                shapeRailSection = .transformations
            case .bounding:
                topDockTab = .shape
                shapeRailSection = .bounding
            case .render:
                // Performance is now its own top-dock tab, not a Shape rail entry.
                topDockTab = .performance
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
                if musicPanelTab == .lfo {
                    musicRailSection = .lfo
                } else {
                    musicRailSection = .playback
                    if musicPanelTab != .music {
                        musicPanelTab = .music
                    }
                }
                #else
                switch musicPanelTab {
                case .music:       musicRailSection = .playback
                case .lfo:         musicRailSection = .lfo
                case .songs:       musicRailSection = .songs
                case .playlists:   musicRailSection = .playlists
                case .albums:      musicRailSection = .albums
                case .visualizations: musicRailSection = .playback
                }
                #endif
            }
        case .transition:
            topDockTab = .visualizations
            visualizationsRailSection = .transition
        case .quickToggles, .gestures, .settings:
            break
        }
    }
    
    /// Navigate from a Quick Toggles tile (long-press) to where that control's
    /// full slider/controls live. Setting the sidebar tab + sub-tab is enough;
    /// the dock chrome re-syncs via the `onChange` hooks. Lives here (not in the
    /// settings extension) so it can reach the file-private `musicPanelTab`.
    func openQuickToggleHome(_ home: QuickToggleHome) {
        switch home {
        case .effectsAtmosphere:
            selectedTab = .effects; effectsSubTab = .static
        case .effectsDynamic:
            selectedTab = .effects; effectsSubTab = .dynamic
        case .shapeSpace:
            selectedTab = .fractal; fractalSubTab = .space
        case .shapeTransformations:
            selectedTab = .fractal; fractalSubTab = .transform
        case .shapeBounding:
            selectedTab = .fractal; fractalSubTab = .bounding
        case .shapePerformance:
            selectedTab = .fractal; fractalSubTab = .render
        case .audioReactive:
            selectedTab = .music; musicPanelTab = .visualizations
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
                    MusicTabContent(cache: cache, musicService: appModel.musicService, audioAnalyzer: appModel.audioAnalyzer, renderSettings: appModel.renderSettings, systemAudioCapture: appModel.systemAudioCapture, presetBankEffect: musicPresetBankEffectBinding, onAdvancePresetBank: { appModel.advanceMusicPresetBank() }, tabSelection: $musicPanelTab)
                    #else
                    MusicTabContent(cache: cache, musicService: appModel.musicService, audioAnalyzer: appModel.audioAnalyzer, renderSettings: appModel.renderSettings, presetBankEffect: musicPresetBankEffectBinding, onAdvancePresetBank: { appModel.advanceMusicPresetBank() }, tabSelection: $musicPanelTab)
                    #endif
                case .transition:
                    if let animationManager = appModel.animationManager {
                        TransitionTabContent(animationManager: animationManager)
                    } else {
                        EmptyView()
                    }
                case .gestures:
                    if supportsGestureEditing {
                        gesturesTabContent
                    } else {
                        settingsTabContent
                    }
                case .quickToggles: quickTogglesTabContent
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
        HStack(spacing: 14) {
            HStack(spacing: 10) {
                if let animationManager = appModel.animationManager {
                    LiveSessionRecordingControl(animationManager: animationManager, compact: true)
                        .disabled(animationManager.isPlaying)
                }

                ResetControl(onReset: resetCurrentFractalSettings)
            }
            .frame(minWidth: 220, alignment: .leading)

            HStack(spacing: 10) {
                ToggleImmersiveSpaceButton()
                    .frame(width: 132, alignment: .center)

#if os(visionOS)
                ImmersionStylePicker(showsCaption: false)
                    .frame(width: 220)
#endif
            }
            .frame(maxWidth: .infinity, alignment: .center)

            if showPerformanceInMenu {
                bottomPerformanceStrip
            }

            HStack(spacing: 12) {
                SaveControl(onAdd: {
                    showSaveDestinationSheet = true
                })
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var bottomPerformanceStrip: some View {
        let metrics = appModel.renderMetrics
        return HStack(spacing: 10) {
            bottomMetric("FPS", metrics.fps > 0 ? String(format: "%.0f", metrics.fps) : "—", color: liveFPSColor)
            bottomMetric("GPU", metrics.gpuFrameMs > 0 ? String(format: "%.1f", metrics.gpuFrameMs) : "—", color: .cyan)
            bottomMetric("Q", metrics.renderQuality > 0 ? "\(Int((metrics.renderQuality * 100).rounded()))%" : "—", color: .blue)
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(Capsule().fill(Color.secondary.opacity(0.10)))
        .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.18), lineWidth: 1))
        .accessibilityLabel("Performance")
    }

    private func bottomMetric(_ label: String, _ value: String, color: Color) -> some View {
        VStack(spacing: 0) {
            Text(value)
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(color)
            Text(label)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 34)
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Fractal Tab
    // ═══════════════════════════════════════════════════════════════════════════
    // (Extracted to ContentView+FractalTab.swift)
    
    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Animate Tab
    // ═══════════════════════════════════════════════════════════════════════════
    // (Extracted to ContentView+AnimateTab.swift)
    
    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Coloring Tab
    // ═══════════════════════════════════════════════════════════════════════════
    // (Extracted to ContentView+ColoringTab.swift)
    
    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Effects Tab
    // ═══════════════════════════════════════════════════════════════════════════
    // (Extracted to ContentView+EffectsTab.swift)
    
    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Gestures Tab
    // ═══════════════════════════════════════════════════════════════════════════
    // (Extracted to ContentView+GesturesTab.swift)
    
}

// MARK: - Extracted Components
//
// ResetControl, SaveControl, PresetPreviewGenerator,
// PresetPreviewCard, SaveDestinationSheet, ExternalFileImportSheet, and
// FPSIndicatorView moved to ContentViewComponents.swift (Phase 3 refactor).
// The platform-gated View helpers (thresholdGlassBackground, etc.) moved to
// ContentViewModifiers.swift.

#if os(visionOS)
#Preview(windowStyle: .automatic) {
    ContentView().environment(AppModel())
}
#else
#Preview {
    ContentView().environment(AppModel())
}
#endif
