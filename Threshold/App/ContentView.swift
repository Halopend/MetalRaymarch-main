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
    /// Radial navigation already supplies the app hierarchy around the pointer.
    /// Its fallback panel therefore renders only the selected destination and
    /// persistent actions; standalone and conventional panel presentations keep
    /// the complete top dock and section rail.
    let showsOuterNavigation: Bool

    init(showsOuterNavigation: Bool = true) {
        self.showsOuterNavigation = showsOuterNavigation
    }

    @Environment(AppModel.self) var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
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
#if os(macOS)
    @AppStorage("MacTabLauncher.style") var macTabLauncherStyle: NavigationPresentationStyle = .radial
#endif
    @AppStorage("ContentView.showPerformanceInMenu") var showPerformanceInMenu: Bool = false
    @AppStorage("ContentView.showFPSInHUD") var showFPSInHUD: Bool = true
    @AppStorage("ContentView.pinnedRailControls") private var pinnedRailControlsRaw: String = ""
    @State var showStopsPopover = false
    @State private var showSaveDestinationSheet = false
    @State private var saveConfirmationMessage: String?
    @State private var isControlFinderPresented = false
    #if os(iOS)
    @State var isAnimationEditorPresented = false
    @State var isWelcomePresented = false
    #endif
    /// One-time first-run prompt to choose local vs iCloud storage.
    @State private var showStorageChoice = false
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
        showsOuterNavigation ? 980 : 720
    #endif
    }

    private var immersiveLayoutMinimumHeight: CGFloat? {
    #if os(iOS)
        // iPad windows can be shorter than the desktop workspace in Stage
        // Manager, Split View, and while the software keyboard is visible.
        nil
    #else
        576
    #endif
    }

    private var usesCompactWorkspaceLayout: Bool {
    #if os(iOS)
        horizontalSizeClass == .compact
    #else
        false
    #endif
    }

    /// Shared definition consumed by the regular top-dock/rail grid, compact
    /// iPad grid, keyboard navigation, and any radial presentation.
    private var navigationHierarchy: NavigationHierarchy {
        NavigationHierarchy.application(availability: .current(
            allowsCustomScenes: allowCustomScenes,
            includesGestureEditing: supportsGestureEditing
        ))
    }

    private var activeWorkspaceNavigationNodes: [NavigationHierarchy.Node] {
        navigationHierarchy.children(ofWorkspace: topDockTab)
    }

    private var activeMusicPermutationCount: Int {
        guard cache.audioReactive.fractalAudioReactiveEnabled else { return 0 }
        return cache.audioReactive.musicReactiveMappings.count
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
        return count
    }

    private var isPrimaryWorkspaceSelection: Bool {
        selectedTab != .gestures && selectedTab != .settings && selectedTab != .quickToggles
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
            VStack(spacing: 8) {
                // Surfaces ErrorReporter failures (preset/animation import, etc.) that
                // were previously reported but never shown. Transient: self-dismisses
                // and only renders while currentError is set.
                ErrorBannerView(errorReporter: appModel.errorReporter)

                if let saveConfirmationMessage {
                    Label(saveConfirmationMessage, systemImage: AppIcons.checkmarkCircleFill)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.green.opacity(0.45), lineWidth: 1))
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .accessibilityLabel(saveConfirmationMessage)
                }
            }
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
            .presentationDetents([.height(430), .height(500)])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $isControlFinderPresented) {
            ControlFinderView(
                onSelect: navigateFromControlFinder,
                onDismiss: { isControlFinderPresented = false }
            )
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $isAnimationEditorPresented) {
            AnimationEditorWindowView()
                .environment(appModel)
        }
        .fullScreenCover(isPresented: $isWelcomePresented) {
            FirstLaunchWindowView()
                .environment(appModel)
        }
        #endif
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
        if let activeResetPreset = appModel.activeResetPreset {
            // Preserve the source scene's identity so keyboard scene cycling can
            // still locate it after the user replaces its reset values.
            appModel.rememberActiveResetPreset(activeResetPreset)
        } else {
            appModel.rememberActiveResetPresetFromCurrent()
        }
        cache.loadFromSettings()
        showSaveConfirmation("Reset point updated")
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
        showSaveConfirmation("Saved \"\(finalName)\"")
    }

    private func showSaveConfirmation(_ message: String) {
        withMotionSensitiveAnimation(.easeOut(duration: 0.18)) {
            saveConfirmationMessage = message
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.4))
            guard saveConfirmationMessage == message else { return }
            withMotionSensitiveAnimation(.easeIn(duration: 0.16)) {
                saveConfirmationMessage = nil
            }
        }
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
        Group {
            if usesCompactWorkspaceLayout {
                compactWorkspaceLayout
            } else {
                regularWorkspaceLayout
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(minWidth: immersiveLayoutMinimumWidth, minHeight: immersiveLayoutMinimumHeight)
    }

    private var regularWorkspaceLayout: some View {
        VStack(spacing: 10) {
#if os(macOS) || os(iOS)
            if showsOuterNavigation {
                HStack(spacing: 0) {
                    topDockOrnament
                    Spacer(minLength: 0)
                }
            }
#endif
            HStack(spacing: 0) {
                if showsOuterNavigation {
                    // ── LEFT: Context Rail ──
                    sectionRail

                    Divider()
                }
                
                // ── RIGHT: Content Panel ──
                VStack(spacing: 0) {
                    contentPanel
                    
                    Divider()
                    
                    // ── BOTTOM BAR: Persistent controls ──
                    bottomBar
                }
            }
        }
    }

    /// Compact inspector layout used by narrow iPad windows. The persistent
    /// 208-point rail left too little room for the editor; sections become a
    /// horizontal, keyboard/VoiceOver-addressable strip and the bottom bar only
    /// keeps actions that are meaningful on iPad.
    private var compactWorkspaceLayout: some View {
        VStack(spacing: 8) {
            topDockOrnament

            compactSectionBar

            Divider()

            contentPanel

            Divider()

            compactBottomBar
        }
    }

    private var compactSectionBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(activeWorkspaceNavigationNodes) { node in
                    compactSectionButton(
                        title: node.title,
                        systemImage: node.systemImage,
                        isSelected: isNavigationNodeSelected(node)
                    ) { activateNavigationNode(node) }
                }

                Divider()
                    .frame(height: 28)

                ForEach(navigationHierarchy.utilityRoots) { node in
                    compactSectionButton(
                        title: node.title,
                        systemImage: node.systemImage,
                        isSelected: isNavigationNodeSelected(node)
                    ) { activateNavigationNode(node) }
                }
            }
            .padding(.horizontal, 2)
        }
        .frame(minHeight: 44)
    }

    private func compactSectionButton(title: String, systemImage: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 11)
                .frame(minHeight: 40)
                .background(
                    Capsule().fill(isSelected ? Color.blue.opacity(0.20) : Color.secondary.opacity(0.08))
                )
                .overlay(
                    Capsule().strokeBorder(isSelected ? Color.blue.opacity(0.38) : Color.secondary.opacity(0.14), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? .primary : .secondary)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var compactBottomBar: some View {
        HStack(spacing: 10) {
            if let animationManager = appModel.animationManager {
                LiveSessionRecordingControl(animationManager: animationManager, compact: true)
                    .disabled(animationManager.isPlaying)
            }

            ResetControl(onReset: resetCurrentFractalSettings)

            Spacer(minLength: 8)

            SaveControl {
                showSaveDestinationSheet = true
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
    }
    
    // MARK: - Top Dock

    private var topDockBar: some View {
        return HStack(spacing: 10) {
            ForEach(navigationHierarchy.workspaceRoots) { node in
                if case .workspace(let tab) = node.destination {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            activateNavigationNode(node)
                        }
                    } label: {
                        HStack(spacing: 8) {
                            ZStack(alignment: .topTrailing) {
                                Image(systemName: node.systemImage)
                                    .font(.system(size: IconSize.medium, weight: .semibold))
                                topDockBadge(for: tab)
                            }
                            Text(node.title)
                                .font(.subheadline.weight(.semibold))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(
                            Capsule()
                                .fill(topDockTab == tab && isPrimaryWorkspaceSelection ? Color.blue.opacity(0.18) : Color.clear)
                        )
                        .overlay(
                            Capsule()
                                .strokeBorder(topDockTab == tab && isPrimaryWorkspaceSelection ? Color.blue.opacity(0.22) : Color.secondary.opacity(0.14), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(topDockTab == tab && isPrimaryWorkspaceSelection ? .primary : .secondary)
                    .accessibilityAddTraits(topDockTab == tab && isPrimaryWorkspaceSelection ? .isSelected : [])
                }
            }

            Divider()
                .frame(height: 24)

            Button(action: presentControlFinder) {
                Label("Find", systemImage: AppIcons.magnifyingglass)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 13)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Color.secondary.opacity(0.08)))
                    .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.16), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Find any control or setting (⌘K)")
            .accessibilityLabel("Find controls")
            #if !os(macOS)
            .keyboardShortcut("k", modifiers: .command)
            #endif
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
#elseif os(iOS)
        ScrollView(.horizontal, showsIndicators: false) {
            topDockBar
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(colorScheme == .dark ? Color.black.opacity(0.82) : Color.white.opacity(0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.14), lineWidth: 1)
        )
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
                    ForEach(activeWorkspaceNavigationNodes) { node in
                        railButton(
                            title: node.title,
                            systemImage: node.systemImage,
                            isSelected: isNavigationNodeSelected(node),
                            pinControl: pinnedRailControl(for: node.destination)
                        ) {
                            activateNavigationNode(node)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .frame(maxHeight: .infinity, alignment: .top)

            VStack(spacing: 8) {
                Divider()
                    .padding(.vertical, 4)

                ForEach(navigationHierarchy.utilityRoots.filter(isLeadingUtilityNode)) { node in
                    railButton(
                        title: node.title,
                        systemImage: node.systemImage,
                        isSelected: isNavigationNodeSelected(node)
                    ) {
                        activateNavigationNode(node)
                    }
                }

                if !pinnedRailControls.isEmpty {
                    Divider()
                        .padding(.vertical, 4)

                    HStack {
                        Label("Quick Access", systemImage: AppIcons.pinFill)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        Button("Clear") {
                            pinnedRailControls = []
                        }
                        .buttonStyle(.plain)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.blue)
                        .accessibilityLabel("Clear Quick Access")
                    }
                    .padding(.horizontal, 4)

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

                ForEach(navigationHierarchy.utilityRoots.filter { !isLeadingUtilityNode($0) }) { node in
                    railButton(
                        title: node.title,
                        systemImage: node.systemImage,
                        isSelected: isNavigationNodeSelected(node)
                    ) {
                        activateNavigationNode(node)
                    }
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
        let isPinned = pinControl.map { pinnedRailControls.contains($0) } ?? false

        HStack(spacing: 2) {
            Button(action: action) {
                HStack(spacing: 10) {
                    Image(systemName: systemImage)
                        .font(.system(size: IconSize.medium, weight: .semibold))
                        .frame(width: 18)

                    Text(title)
                        .font(.footnote.weight(.semibold))
                        .lineLimit(1)

                    Spacer(minLength: 0)
                }
                .padding(.leading, 10)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            if let pinControl {
                Button {
                    togglePinnedRailControl(pinControl)
                } label: {
                    Image(systemName: isPinned ? AppIcons.pinFill : AppIcons.pin)
                        .font(.system(size: IconSize.small, weight: .semibold))
                        .frame(width: 34, height: 42)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(isPinned ? Color.blue : Color.secondary.opacity(0.8))
                .help(isPinned ? "Remove \(title) from Quick Access" : "Pin \(title) to Quick Access")
                .accessibilityLabel(isPinned ? "Unpin \(title)" : "Pin \(title)")
            }
        }
        .padding(.trailing, pinControl == nil ? 10 : 4)
        .frame(maxWidth: .infinity, minHeight: 44)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isSelected ? Color.blue.opacity(0.18) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isSelected ? Color.blue.opacity(0.22) : Color.secondary.opacity(0.10), lineWidth: 1)
        )
        .foregroundStyle(isSelected ? .primary : .secondary)
    }

    private func pinnedRailButton(title: String, systemImage: String, isSelected: Bool, pinControl: PinnedRailControl, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: IconSize.medium, weight: .semibold))
                .frame(maxWidth: .infinity)
                .frame(minHeight: 44)
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
        .accessibilityAction(named: Text("Remove from Quick Access")) {
            togglePinnedRailControl(pinControl)
        }
        .contextMenu {
            Button("Remove from Quick Access", systemImage: AppIcons.pin) {
                togglePinnedRailControl(pinControl)
            }
        }
    }

    private var pinnedRailControls: [PinnedRailControl] {
        get {
            let decoded = pinnedRailControlsRaw
                .split(separator: ",")
                .compactMap { PinnedRailControl(rawValue: String($0)) }
            return PinnedRailControl.canonicalized(decoded)
                .filter(isSupportedPinnedRailControl)
        }
        nonmutating set {
            pinnedRailControlsRaw = newValue.map(\.rawValue).joined(separator: ",")
        }
    }

    private func isSupportedPinnedRailControl(_ control: PinnedRailControl) -> Bool {
        #if os(macOS)
        switch control {
        case .shapeHands, .musicSongs, .musicPlaylists, .musicAlbums:
            return false
        default:
            return true
        }
        #elseif os(iOS)
        return control != .shapeHands
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

    private func activateNavigationNode(_ node: NavigationHierarchy.Node) {
        switch node.destination {
        case .workspace(let tab):
            activateTopDock(tab)
        case .explore(let section):
            activateExploreSection(section)
        case .shape(let section):
            activateShapeSection(section)
        case .visualizations(let section):
            activateVisualizationsSection(section)
        case .performance(let section):
            activatePerformanceSection(section)
        case .music(let section):
            activateMusicSection(section)
        case .animationEditor:
            openAnimationEditor()
        case .quickToggles:
            selectedTab = .quickToggles
        case .gestures:
            selectedTab = .gestures
        case .settings:
            selectedTab = .settings
        }
    }

    private func isNavigationNodeSelected(_ node: NavigationHierarchy.Node) -> Bool {
        switch node.destination {
        case .workspace(let tab): return isPrimaryWorkspaceSelection && topDockTab == tab
        case .explore(let section):
            return isPrimaryWorkspaceSelection && topDockTab == .explore && exploreRailSection == section
        case .shape(let section):
            return isPrimaryWorkspaceSelection && topDockTab == .shape && shapeRailSection == section
        case .visualizations(let section):
            return isPrimaryWorkspaceSelection
                && topDockTab == .visualizations
                && visualizationsRailSection == section
        case .performance(let section):
            return isPrimaryWorkspaceSelection
                && topDockTab == .performance
                && performanceRailSection == section
        case .music(let section):
            return isPrimaryWorkspaceSelection
                && topDockTab == .music
                && musicRailSection.canonical == section.canonical
        case .quickToggles: return selectedTab == .quickToggles
        case .gestures: return selectedTab == .gestures
        case .settings: return selectedTab == .settings
        case .animationEditor: return false
        }
    }

    private func isLeadingUtilityNode(_ node: NavigationHierarchy.Node) -> Bool {
        switch node.destination {
        case .gestures, .animationEditor: return true
        default: return false
        }
    }

    private func pinnedRailControl(
        for destination: NavigationHierarchy.Destination
    ) -> PinnedRailControl? {
        switch destination {
        case .explore(let section): return pinnedRailControl(for: section)
        case .shape(let section): return pinnedRailControl(for: section)
        case .visualizations(let section): return pinnedRailControl(for: section)
        case .music(let section): return pinnedRailControl(for: section)
        case .workspace, .performance, .animationEditor, .quickToggles, .gestures, .settings:
            return nil
        }
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
            activateVisualizationsSection(visualizationsRailSection.lookWorkspaceDestination)
        case .music:
            activateMusicSection(musicRailSection)
        case .performance:
            activatePerformanceSection(performanceRailSection)
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
        case .primitives:
            fractalSubTab = .shape
            shapeInnerTab = .primitives
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
            activateMusicSection(.reactive)
        }
    }

    private func activatePerformanceSection(_ section: PerformanceRailSection) {
        topDockTab = .performance
        performanceRailSection = section
        selectedTab = .fractal
        fractalSubTab = .render
    }

    private func activateMusicSection(_ section: MusicRailSection) {
        let section = section.canonical
        topDockTab = .music
        musicRailSection = section
        selectedTab = .music
        musicPanelTab = section.musicPanelTab
    }

    private func presentControlFinder() {
        #if os(macOS)
        if let openControlFinderHandler = appModel.openControlFinderHandler {
            openControlFinderHandler()
            return
        }
        #endif
        isControlFinderPresented = true
    }

    private func navigateFromControlFinder(_ destination: ControlFinderDestination) {
        guard let route = destination.route else { return }
        withMotionSensitiveAnimation(.easeInOut(duration: 0.2)) {
            switch route {
            case .explore(let section):
                activateExploreSection(section)
            case .shape(let section):
                activateShapeSection(section)
            case .visualizations(let section):
                activateVisualizationsSection(section)
            case .performance(let section):
                activatePerformanceSection(section)
            case .music(let section):
                activateMusicSection(section)
            case .settings(let section):
                selectedTab = .settings
                settingsSubTab = section
            case .sidebar(let tab):
                selectedTab = tab
            case .animationEditor:
                openAnimationEditor()
            }
        }
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
        guard isPrimaryWorkspaceSelection else { return false }
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
        case .shapePrimitives:
            return topDockTab == .shape && shapeRailSection == .primitives && selectedTab != .gestures && selectedTab != .settings
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
        case .visualizationsReactive, .musicReactive, .musicMappings, .musicPresets:
            return topDockTab == .music && musicRailSection.canonical == .reactive && selectedTab != .gestures && selectedTab != .settings
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
            case .exploreMixed:
                activateExploreSection(.mixed)
            case .exploreCustomScenes:
                activateExploreSection(.customScenes)
            case .shapeParameters:
                activateShapeSection(.parameters)
            case .shapeFormula:
                activateShapeSection(.formula)
            case .shapePrimitives:
                activateShapeSection(.primitives)
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
            case .visualizationsReactive, .musicReactive, .musicMappings, .musicPresets:
                activateMusicSection(.reactive)
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
        case .mixed: return .exploreMixed
        case .customScenes: return .exploreCustomScenes
        }
    }

    private func pinnedRailControl(for section: ShapeRailSection) -> PinnedRailControl {
        switch section {
        case .parameters: return .shapeParameters
        case .formula: return .shapeFormula
        case .primitives: return .shapePrimitives
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
        case .reactive: return .musicReactive
        case .mappings: return .musicMappings
        case .presets: return .musicPresets
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
                switch shapeInnerTab {
                case .formula: shapeRailSection = .formula
                case .primitives: shapeRailSection = .primitives
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
            topDockTab = .music
            let canonicalTab = musicPanelTab.canonical
            if musicPanelTab != canonicalTab {
                musicPanelTab = canonicalTab
            }
            switch canonicalTab {
            case .music:       musicRailSection = .playback
            case .reactive:    musicRailSection = .reactive
            case .mappings, .presets, .visualizations: musicRailSection = .reactive
            case .songs:       musicRailSection = .songs
            case .playlists:   musicRailSection = .playlists
            case .albums:      musicRailSection = .albums
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
            selectedTab = .music; musicPanelTab = .reactive
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
                    MusicTabContent(cache: cache,
                                    musicService: appModel.musicService,
                                    audioHub: appModel.audioHub,
                                    renderSettings: appModel.renderSettings,
                                    tabSelection: $musicPanelTab)
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
        if !supportsGestureEditing, selectedTab == .gestures {
            selectedTab = .fractal
        }

        #if !os(visionOS)
        if selectedTab == .fractal, fractalSubTab == .shape, shapeInnerTab == .hands {
            shapeInnerTab = .parameters
            shapeRailSection = .parameters
        }
        #endif
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

            #if !os(iOS)
            HStack(spacing: 10) {
                ToggleImmersiveSpaceButton()
                    .frame(width: 132, alignment: .center)

#if os(visionOS)
                ImmersionStylePicker(showsCaption: false)
                    .frame(width: 220)
#endif
            }
            .frame(maxWidth: .infinity, alignment: .center)
            #endif

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
