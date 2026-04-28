//
//  ContentView.swift
//  MetalProject
//
//  Created by MU on 18/11/24.
//  Reorganized: Sidebar + Sub-Tab layout
//

import SwiftUI
import RealityKit


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

enum FractalSubTab: String, CaseIterable { case browse = "Browse", shape = "Shape", space = "Space", quality = "Quality" }
enum AnimateSceneSubTab: String, CaseIterable {
    case all = "All"
    case accompanied = "Accompanied"
    case solo = "Solo"
}
enum ColoringSubTab: String, CaseIterable { case gradient = "Gradient", mapping = "Mapping", grading = "Grading" }
enum EffectsSubTab: String, CaseIterable { case dynamic = "Dynamic Color", `static` = "Atmosphere", audio = "Audio" }
enum SettingsSubTab: String, CaseIterable { case general = "General", exportShare = "Export", devTools = "Dev Tools" }

private enum SaveChoice: String, CaseIterable {
    case resetLocation = "Reset Location"
    case presetAutoNamed = "Preset - Auto Named"
    case presetCustomName = "Preset - Custom Name"
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
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    
    @State private var cache = UISettingsCache()
    @State private var selectedTab: SidebarTab = .fractal
    @State private var fractalSubTab: FractalSubTab = .shape
    @State private var animateSceneSubTab: AnimateSceneSubTab = .all
    @State private var animateEditButtonsVisible = false
    @State private var coloringSubTab: ColoringSubTab = .gradient
    @State private var effectsSubTab: EffectsSubTab = .dynamic
    @State private var settingsSubTab: SettingsSubTab = .general
    @State private var showStopsPopover = false
    @State private var showSaveDestinationSheet = false

    private var activeMusicPermutationCount: Int {
        guard cache.audioReactive.fractalAudioReactiveEnabled else { return 0 }
        return cache.audioReactive.musicReactiveMappings.filter(\.isEnabled).count
    }

    private var isAnimationPlaying: Bool {
        appModel.animationManager?.isPlaying ?? appModel.renderSettings.isAnimationPlaying
    }

    private var activeDynamicEffectCount: Int {
        var count = 0
        if cache.lighting.gradientCycleEffect.enabled { count += 1 }
        if cache.lighting.hueRotationEffect.enabled { count += 1 }
        if cache.lighting.pulseEffect.enabled { count += 1 }
        if cache.lighting.beatFlashEffect.enabled { count += 1 }
        if cache.fractalType.supports(.polarRotation), cache.lighting.polarRotationEffect.enabled { count += 1 }
        if cache.fractalType.supports(.juliaDrift), cache.lighting.juliaDriftEffect.enabled { count += 1 }
        return count
    }

    @AppStorage("qualityGoalPreference.v2") private var qualityGoalPreferenceRaw: Int = QualityGoalPreference.detail.rawValue
    @AppStorage("qualityGoalLastDirectPreference.v1") private var qualityGoalLastDirectPreferenceRaw: Int = QualityGoalPreference.detail.rawValue
    private var qualityGoalPreference: QualityGoalPreference {
        let selected = QualityGoalPreference(rawValue: qualityGoalPreferenceRaw) ?? .detail
        // Control is temporarily disabled in UI; fall back to the last direct choice.
        return selected == .control ? lastDirectBudgetPreference : selected
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
        
        let isOpen = appModel.immersiveSpaceState == .open
        Group {
            if isOpen {
                immersiveLayout
            } else {
                preImmersiveLayout
            }
        }
        .environment(\.menuAdjustmentActions, MenuAdjustmentActions(
            begin: { appModel.beginMenuAdjustment() },
            end: { appModel.endMenuAdjustment() }
        ))
        .animation(.easeInOut(duration: 0.3), value: appModel.immersiveSpaceState)
        .glassBackgroundEffect(in: .rect(cornerRadius: 20))
        .onHover { hovering in
            // Treat gaze-hover as active UI interaction for robust gesture suppression.
            appModel.setMenuHovering(hovering)
        }
        .onAppear { cache.startSync(with: appModel.renderSettings, appModel: appModel) }
        .onDisappear { cache.stopSync() }
        .onReceive(NotificationCenter.default.publisher(for: AppModel.fractalSettingsDidChangeNotification)) { _ in
            cache.loadFromSettings()
        }
        .sheet(isPresented: $showSaveDestinationSheet) {
            SaveDestinationSheet(
                onSave: { choice, customName in
                    switch choice {
                    case .resetLocation:
                        saveCurrentAsResetDefaults()
                    case .presetAutoNamed:
                        saveCurrentAsPreset()
                    case .presetCustomName:
                        saveCurrentAsPreset(named: customName)
                    }
                    showSaveDestinationSheet = false
                },
                onCancel: {
                    showSaveDestinationSheet = false
                }
            )
            .presentationDetents([.height(220), .height(280)])
            .presentationDragIndicator(.visible)
        }
    }

    private func toggleAnimationPlayerWindow() {
        appModel.toggleAnimationPlayerWindow()
    }

    private func resetCurrentFractalSettings() {
        appModel.gestureController?.applyFractalDefaults()
        cache.loadFromSettings()
    }

    private func saveCurrentAsResetDefaults() {
        guard appModel.gestureController?.saveCurrentAsFractalDefaults() == true else { return }
        cache.loadFromSettings()
    }

    private func saveCurrentAsPreset(named providedName: String? = nil) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let autoName = "Quick Save \(formatter.string(from: Date()))"
        let presetName = providedName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = (presetName?.isEmpty == false) ? presetName! : autoName
        appModel.presetManager.savePreset(name: finalName, settings: appModel.renderSettings)
    }
    
    // MARK: - Pre-Immersive Layout
    
    private var preImmersiveLayout: some View {
        VStack(spacing: 16) {
            Text("Threshold")
                .font(.title2.bold())
            ToggleImmersiveSpaceButton()
            if appModel.immersiveSpaceState == .inTransition {
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
        .frame(minWidth: 320, minHeight: 180)
    }
    
    // MARK: - Immersive Layout (Sidebar + Content)
    
    private var immersiveLayout: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                // ── LEFT: Sidebar ──
                sidebarColumn
                
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
        .frame(minWidth: 980, minHeight: 576)
    }
    
    // MARK: - Sidebar Column
    
    private var sidebarColumn: some View {
        VStack(spacing: 4) {
            ForEach(SidebarTab.allCases, id: \.self) { tab in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { selectedTab = tab }
                } label: {
                    VStack(spacing: 4) {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: tab.icon)
                                .font(.system(size: 18))
                                .frame(width: 28, height: 22)
                            sidebarBadge(for: tab)
                        }
                        Text(tab.rawValue)
                            .font(.caption2)
                    }
                    .frame(width: 64, height: 54)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(selectedTab == tab ? Color.blue.opacity(0.25) : Color.clear)
                    )
                    .foregroundStyle(selectedTab == tab ? .primary : .secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.rawValue)
                .accessibilityValue(sidebarAccessibilityValue(for: tab))
                .accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
            }

            Spacer()

            Button {
                toggleAnimationPlayerWindow()
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: appModel.isAnimationPlayerWindowVisible ? "xmark.rectangle.fill" : "play.rectangle")
                        .font(.system(size: 18))
                    Text("Player")
                        .font(.caption2)
                    Text(appModel.isAnimationPlayerWindowVisible ? "Close" : "Open")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .frame(width: 64, height: 54)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.secondary.opacity(0.12))
                )
                .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
            .help("Open or close Animation Player")
        }
        .padding(.vertical, 8)
        .frame(width: 72)
    }

    @ViewBuilder
    private func sidebarBadge(for tab: SidebarTab) -> some View {
        switch tab {
        case .animate where isAnimationPlaying:
            Image(systemName: "play.fill")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 15, height: 15)
                .background(Circle().fill(Color.green))
                .offset(x: 9, y: -7)
                .accessibilityHidden(true)
        case .effects where activeDynamicEffectCount > 0:
            sidebarCountBadge(activeDynamicEffectCount, color: .pink)
        case .music where activeMusicPermutationCount > 0:
            sidebarCountBadge(activeMusicPermutationCount, color: .green)
        default:
            EmptyView()
        }
    }

    private func sidebarCountBadge(_ count: Int, color: Color) -> some View {
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

    private func sidebarAccessibilityValue(for tab: SidebarTab) -> String {
        switch tab {
        case .animate where isAnimationPlaying:
            return "animation playing"
        case .effects where activeDynamicEffectCount > 0:
            return "\(activeDynamicEffectCount) dynamic effects active"
        case .music where activeMusicPermutationCount > 0:
            return "\(activeMusicPermutationCount) music permutations active"
        default:
            return ""
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
                case .music:    MusicTabContent(cache: cache, musicService: appModel.musicService, audioAnalyzer: appModel.audioAnalyzer, renderSettings: appModel.renderSettings)
                case .gestures: gesturesTabContent
                case .settings: settingsTabContent
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - Bottom Bar
    
    private var bottomBar: some View {
        ZStack {
            HStack(spacing: 10) {
                Spacer()

                PresetButton(
                    presetManager: appModel.presetManager,
                    settings: appModel.renderSettings,
                    animationManager: appModel.animationManager,
                    captureScreenshot: { await appModel.captureScreenshot() },
                    onLoadPreset: { preset in
                        Task { await appModel.preparePipelineHandler?(preset) }
                        preset.apply(to: appModel.renderSettings)
                        appModel.gestureController?.syncWithSettings()
                        cache.loadFromSettings()
                    }
                )

                HoldToSaveResetButton(
                    onTapReset: resetCurrentFractalSettings,
                    onHoldReady: {
                        showSaveDestinationSheet = true
                    }
                )
            }

            ToggleImmersiveSpaceButton()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var activityTrafficLights: some View {
        HStack(spacing: 6) {
            ActivityLightButton(
                title: "Music permutations",
                systemImage: "waveform",
                color: .green,
                isActive: activeMusicPermutationCount > 0,
                count: activeMusicPermutationCount > 0 ? activeMusicPermutationCount : nil,
                action: toggleMusicPermutationsActive
            )
            ActivityLightButton(
                title: "Animation",
                systemImage: "play.fill",
                color: .blue,
                isActive: isAnimationPlaying,
                count: nil,
                action: toggleAnimationPlaybackActive
            )
            ActivityLightButton(
                title: "Dynamic color",
                systemImage: "sparkles",
                color: .pink,
                isActive: activeDynamicEffectCount > 0,
                count: activeDynamicEffectCount > 0 ? activeDynamicEffectCount : nil,
                action: toggleDynamicEffectsActive
            )
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.secondary.opacity(0.08)))
        .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.14), lineWidth: 1))
        .help("Quick toggles for music permutations, animation, and dynamic color")
    }

    private func toggleMusicPermutationsActive() {
        let shouldEnable = activeMusicPermutationCount == 0
        cache.audioReactive.fractalAudioReactiveEnabled = shouldEnable
        cache.push(\.fractalAudioReactiveEnabled, value: shouldEnable)

        if shouldEnable {
            cache.display.lightingMode = .audioReactive
            cache.push(\.lightingMode, value: .audioReactive)
            if cache.audioReactive.musicReactiveMappings.isEmpty {
                applyAudioReactivityPreset(.ambient)
            } else if !cache.audioReactive.musicReactiveMappings.contains(where: \.isEnabled) {
                var mappings = cache.audioReactive.musicReactiveMappings
                for index in mappings.indices {
                    mappings[index].isEnabled = true
                    mappings[index].sanitizeInPlace()
                }
                cache.audioReactive.musicReactiveMappings = mappings
                cache.push(\.musicReactiveMappings, value: mappings)
            }
        }
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
        } else {
            cache.lighting.gradientCycleEffect = .slow
            cache.commitGradientCycleEffect()

            cache.lighting.hueRotationEffect = .subtle
            cache.commitHueRotationEffect()

            cache.lighting.pulseEffect = .subtle
            cache.commitPulseEffect()
        }

        cache.lighting.lightingPreset = .custom
        cache.push(\.lightingPreset, value: .custom)
    }
    
    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Fractal Tab
    // ═══════════════════════════════════════════════════════════════════════════
    
    private var fractalTabContent: some View {
        VStack(spacing: 0) {
            Picker("", selection: $fractalSubTab) {
                ForEach(FractalSubTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            
            switch fractalSubTab {
            case .browse:
                FractalGridView(
                    cache: cache,
                    gestureController: appModel.gestureController,
                    animationManager: appModel.animationManager,
                    presetManager: appModel.presetManager,
                    activitySummary: AnyView(activityTrafficLights),
                    onEditScene: openAnimationEditor,
                    onLoadAnimationScene: { _ in
                        appModel.dismissMenuWindowForSceneLoad()
                    },
                    onLoadStaticScene: { preset in
                        Task { await appModel.preparePipelineHandler?(preset) }
                        appModel.presetManager.loadPreset(
                            preset,
                            into: appModel.renderSettings,
                            resetEnvironment: true
                        )
                        appModel.gestureController?.syncWithSettings()
                        cache.loadFromSettings()
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .shape:
                ScrollView(.vertical, showsIndicators: true) {
                    fractalShapeContent
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                }

            case .space:
                ScrollView(.vertical, showsIndicators: true) {
                    fractalSpaceContent
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                }

            case .quality:
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
                Button {
                    fractalSubTab = .browse
                } label: {
                    Label("Change", systemImage: "square.grid.2x2")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Divider()

            // Formula-specific parameters (auto-generated from catalog.json)
            FormulaParamsEditor(cache: cache)

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
                    HStack {
                        Text("Shape"); Spacer()
                        Picker("Shape", selection: Binding<Int>(
                            get: { cache.safetyBubble.shape < 0.5 ? 0 : 1 },
                            set: { cache.safetyBubble.shape = $0 == 0 ? 0.0 : 1.0; cache.push(\.safetyBubbleShape, value: cache.safetyBubble.shape) }
                        )) { Text("Sphere").tag(0); Text("Cube").tag(1) }
                        .pickerStyle(.segmented).frame(maxWidth: 160)
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
                            guard newValue != .control else { return }
                            qualityGoalPreferenceRaw = newValue.rawValue
                            if newValue == .framerate || newValue == .detail {
                                qualityGoalLastDirectPreferenceRaw = newValue.rawValue
                            }
                        }
                    )) {
                        ForEach(QualityGoalPreference.allCases, id: \.rawValue) { goal in
                            Text(goal.displayName)
                                .tag(goal)
                                .disabled(goal == .control)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 340)
                }
                Text("Framerate and Detail optimize preset behavior. Control is currently disabled.")
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

                if cache.quality.tileSize != 8 && cache.quality.resolutionScale < 0.999 {
                    Label(
                        effectiveDirectBudgetPreference == .framerate
                        ? "Beta: output may look distorted at aggressive Framerate Budgets."
                        : "Beta: output may look distorted at lower Detail Budgets.",
                        systemImage: "exclamationmark.triangle"
                    )
                        .font(.caption2)
                        .foregroundStyle(.secondary)
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
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                if appModel.animationManager != nil {
                    Spacer()

                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            animateEditButtonsVisible.toggle()
                        }
                        if !animateEditButtonsVisible {
                            dismissWindow(id: AppModel.animationEditorWindowID)
                        }
                    } label: {
                        Label(
                            animateEditButtonsVisible ? "Done Editing" : "Edit Animation",
                            systemImage: animateEditButtonsVisible ? "checkmark.circle" : "pencil.and.list.clipboard"
                        )
                    }
                    .buttonStyle(.bordered)
                }
            }

            Picker("Scene Type", selection: $animateSceneSubTab) {
                ForEach(AnimateSceneSubTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
    
    private var animatePlayContent: some View {
        VStack(spacing: 0) {
            if let animationManager = appModel.animationManager {
                let filteredScenes = animateFilteredScenes(from: animationManager.scenes)

                List {
                    if animationManager.scenes.isEmpty {
                        ContentUnavailableView("No Scenes", systemImage: "film.stack",
                            description: Text("Open Scene Editor to create animation scenes"))
                    } else if filteredScenes.isEmpty {
                        ContentUnavailableView(
                            animateEmptyStateTitle,
                            systemImage: animateEmptyStateSymbol,
                            description: Text(animateEmptyStateDescription)
                        )
                    } else {
                        ForEach(filteredScenes) { scene in
                            SceneRowView(
                                scene: scene,
                                isSelected: animationManager.currentScene?.id == scene.id,
                                isDefault: animationManager.isDefaultScene(scene),
                                isEdited: animationManager.isEditedDefault(scene),
                                onSelect: { animationManager.currentScene = scene },
                                onEdit: animateEditButtonsVisible ? {
                                    openAnimationEditor(for: scene)
                                } : nil,
                                onPlay: {
                                    animationManager.currentScene = scene
                                    animationManager.play()
                                    openWindow(id: AppModel.animationPlayerWindowID)
                                    dismissWindow(id: appModel.menuWindowID)
                                }
                            )
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    private func animateFilteredScenes(from scenes: [AnimationScene]) -> [AnimationScene] {
        switch animateSceneSubTab {
        case .all:
            return scenes
        case .accompanied:
            return scenes.filter { $0.attachedSong != nil }
        case .solo:
            return scenes.filter { $0.attachedSong == nil }
        }
    }

    private var animateEmptyStateTitle: String {
        switch animateSceneSubTab {
        case .all:
            return "No Scenes"
        case .accompanied:
            return "No Accompanied Scenes"
        case .solo:
            return "No Solo Scenes"
        }
    }

    private var animateEmptyStateSymbol: String {
        switch animateSceneSubTab {
        case .all:
            return "film.stack"
        case .accompanied:
            return "music.note"
        case .solo:
            return "speaker.slash"
        }
    }

    private var animateEmptyStateDescription: String {
        switch animateSceneSubTab {
        case .all:
            return "Open Scene Editor to create animation scenes."
        case .accompanied:
            return "Attach songs to scenes to see them here."
        case .solo:
            return "Scenes without attached songs will appear here."
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
            Picker("", selection: $coloringSubTab) {
                ForEach(ColoringSubTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16).padding(.vertical, 8)
            
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
            Text("Presets").font(.subheadline).foregroundColor(.secondary)
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
            
            // ── Saved Custom Gradients ──
            HStack {
                Text("Saved").font(.subheadline).foregroundColor(.secondary)
                Spacer()
                if !cache.gradientLibrary.savedCustomGradients.isEmpty {
                    Text("\(cache.gradientLibrary.savedCustomGradients.count)").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .padding(.top, 4)
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
                Picker("Mapping", selection: $cache.color.gradientState.gradient.mappingMode) {
                    ForEach(ColorMappingMode.allCases, id: \.rawValue) { Text($0.displayName).tag($0) }
                }.pickerStyle(.menu).frame(maxWidth: 140)
                .onChange(of: cache.color.gradientState.gradient.mappingMode) { _, v in cache.push(\.colorMappingMode, value: v) }
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
            Picker("", selection: $effectsSubTab) {
                ForEach(EffectsSubTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16).padding(.vertical, 8)
            
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 12) {
                    switch effectsSubTab {
                    case .static:  effectsStaticContent
                    case .dynamic: effectsDynamicContent
                    case .audio:   effectsAudioContent
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
            }
        }
    }
    
    @State private var showLightingPresets = false
    
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

    private var dynamicPresetDisclosure: some View {
        DisclosureGroup(isExpanded: $showLightingPresets) {
            VStack(spacing: 10) {
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
            .padding(.top, 8)
        } label: {
            Label("Dynamic Presets", systemImage: "sparkles")
                .font(.subheadline.weight(.medium))
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.06)))
    }

    private var effectsAudioContent: some View {
        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: cache.audioReactive.fractalAudioReactiveEnabled ? "waveform.badge.plus" : "waveform.badge.minus")
                        .font(.title2)
                        .foregroundStyle(cache.audioReactive.fractalAudioReactiveEnabled ? .blue : .secondary)
                        .frame(width: 30)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Audio Reactive Effects")
                            .font(.headline)
                        Text("Keep music-driven visuals one tap away from the rest of your effects.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                }

                Toggle(isOn: Binding(
                    get: { cache.audioReactive.fractalAudioReactiveEnabled },
                    set: { isOn in
                        cache.audioReactive.fractalAudioReactiveEnabled = isOn
                        cache.push(\.fractalAudioReactiveEnabled, value: isOn)
                        if isOn {
                            cache.display.lightingMode = .audioReactive
                            cache.push(\.lightingMode, value: .audioReactive)
                        }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Music Reactive Visual Effects")
                            .font(.subheadline.weight(.semibold))
                        Text(cache.audioReactive.fractalAudioReactiveEnabled ? "Live audio can drive lighting and mapped parameters." : "Turn this on to let music modulate the fractal.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)

                Toggle("Show Music Shortcuts on Parameters", isOn: $cache.display.showMusicShortcuts)
                    .onChange(of: cache.display.showMusicShortcuts) { _, value in
                        cache.push(\.showMusicShortcuts, value: value)
                    }

                if cache.audioReactive.fractalAudioReactiveEnabled {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Music permutations active")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text("\(activeMusicPermutationCount)")
                                .font(.title3.weight(.semibold))
                                .monospacedDigit()
                        }

                        Spacer()

                        VStack(alignment: .trailing, spacing: 3) {
                            Text("Lighting mode")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(cache.display.lightingMode.displayName)
                                .font(.subheadline.weight(.medium))
                        }
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.08)))
                }

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selectedTab = .music
                    }
                } label: {
                    HStack {
                        Label("Open Full Audio Controls", systemImage: "slider.horizontal.3")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Image(systemName: "arrow.right")
                            .font(.caption.weight(.bold))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.blue.opacity(0.14)))
                }
                .buttonStyle(.plain)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.cyan.opacity(0.08)))

            if cache.audioReactive.fractalAudioReactiveEnabled {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Genre Presets")
                        .font(.subheadline.weight(.medium))

                    HStack(spacing: 6) {
                        ForEach(ReactivityPreset.allCases, id: \.self) { preset in
                            Button {
                                applyAudioReactivityPreset(preset)
                            } label: {
                                VStack(spacing: 2) {
                                    Image(systemName: preset.icon)
                                        .font(.caption)
                                    Text(preset.rawValue)
                                        .font(.system(size: 9))
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 7)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.cyan.opacity(0.06)))

                VStack(alignment: .leading, spacing: 8) {
                    Text("Quick Mix")
                        .font(.subheadline.weight(.medium))

                    Slider(value: Binding(
                        get: { cache.audioReactive.fractalAudioAmount },
                        set: { value in
                            cache.audioReactive.fractalAudioAmount = value
                            cache.push(\.fractalAudioAmount, value: value)
                        }
                    ), in: 0...1)

                    HStack {
                        Text("Subtle")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("Intensity \(Int(cache.audioReactive.fractalAudioAmount * 100))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("Max")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Slider(value: Binding(
                        get: { cache.audioReactive.fractalBeatPunch },
                        set: { value in
                            cache.audioReactive.fractalBeatPunch = value
                            cache.push(\.fractalBeatPunch, value: value)
                        }
                    ), in: 0...1)

                    HStack {
                        Text("Soft Beat")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("Beat Punch \(Int(cache.audioReactive.fractalBeatPunch * 100))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("Hard Beat")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.blue.opacity(0.06)))

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Mapped Parameters")
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        Menu {
                            let available = availableAudioMappingTargetsToAdd
                            let universalTargets = available.filter { !$0.isFormulaParam }
                            let formulaTargets = available.filter { $0.isFormulaParam }

                            if !universalTargets.isEmpty {
                                Section("Universal") {
                                    ForEach(universalTargets, id: \.self) { target in
                                        Button {
                                            addAudioMapping(target)
                                        } label: {
                                            Label(target.displayName, systemImage: target.icon)
                                        }
                                    }
                                }
                            }

                            if !formulaTargets.isEmpty {
                                Section("\(cache.fractalType.displayName) Params") {
                                    ForEach(formulaTargets, id: \.self) { target in
                                        Button {
                                            addAudioMapping(target)
                                        } label: {
                                            Label(target.displayName(for: cache.fractalType), systemImage: target.icon(for: cache.fractalType))
                                        }
                                    }
                                }
                            }

                            if available.isEmpty {
                                Text("All targets added")
                            }
                        } label: {
                            Label("Add Mapping", systemImage: "plus")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    if cache.audioReactive.musicReactiveMappings.isEmpty {
                        Text("No mapped parameters yet. Add one here or open the full Audio controls for advanced shaping.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(cache.audioReactive.musicReactiveMappings.enumerated()), id: \.element.id) { index, mapping in
                            HStack(spacing: 10) {
                                Toggle("", isOn: Binding(
                                    get: { audioMappingAt(index)?.isEnabled ?? false },
                                    set: { newValue in updateAudioMapping(index) { $0.isEnabled = newValue } }
                                ))
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.small)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(mapping.target.displayName(for: cache.fractalType))
                                        .font(.caption.weight(.semibold))
                                    Text(mapping.source.displayName)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Text("\(Int(abs(mapping.amount) * 100))%")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)

                                Button {
                                    removeAudioMapping(at: index)
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.caption2)
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)

                            if index < cache.audioReactive.musicReactiveMappings.count - 1 {
                                Divider()
                            }
                        }
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.green.opacity(0.06)))
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

    private var availableAudioMappingTargetsToAdd: [MusicReactiveTarget] {
        let existing = Set(cache.audioReactive.musicReactiveMappings.map(\.target))
        return MusicReactiveTarget.availableCases(for: cache.fractalType).filter { target in
            !existing.contains(target)
        }
    }

    private func audioMappingAt(_ index: Int) -> MusicReactiveMapping? {
        guard cache.audioReactive.musicReactiveMappings.indices.contains(index) else { return nil }
        return cache.audioReactive.musicReactiveMappings[index]
    }

    private func updateAudioMapping(_ index: Int, mutate: (inout MusicReactiveMapping) -> Void) {
        guard cache.audioReactive.musicReactiveMappings.indices.contains(index) else { return }
        var mappings = cache.audioReactive.musicReactiveMappings
        mutate(&mappings[index])
        mappings[index].sanitizeInPlace()
        cache.audioReactive.musicReactiveMappings = mappings
        cache.push(\.musicReactiveMappings, value: mappings)
    }

    private func addAudioMapping(_ target: MusicReactiveTarget) {
        var mappings = cache.audioReactive.musicReactiveMappings
        guard !mappings.contains(where: { $0.target == target }) else { return }
        mappings.append(target.defaultMapping(for: cache.fractalType, enabled: true))
        cache.audioReactive.musicReactiveMappings = mappings
        cache.push(\.musicReactiveMappings, value: mappings)
    }

    private func removeAudioMapping(at index: Int) {
        guard cache.audioReactive.musicReactiveMappings.indices.contains(index) else { return }
        var mappings = cache.audioReactive.musicReactiveMappings
        mappings.remove(at: index)
        cache.audioReactive.musicReactiveMappings = mappings
        cache.push(\.musicReactiveMappings, value: mappings)
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

                    // ── Hand Assignments (per-hand × per-finger) ──────────────
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Hand Assignments", systemImage: "hand.point.up.braille")
                            .font(.subheadline.weight(.semibold))

                        ForEach(GestureHandMode.allCases, id: \.self) { mode in
                            gestureHandSection(mode: mode)
                        }
                    }

                    Divider().padding(.vertical, 2)

                    Group {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Core Behavior", systemImage: "slider.horizontal.3")
                                .font(.subheadline.weight(.semibold))

                        Toggle("Spring Blob Navigation", isOn: $cache.gesture.useSpringBlob)
                            .onChange(of: cache.gesture.useSpringBlob) { _, v in cache.push(\.useSpringBlob, value: v) }
                        Toggle("Relative Gestures", isOn: $cache.gesture.useRelativeGestures)
                            .onChange(of: cache.gesture.useRelativeGestures) { _, v in cache.push(\.useRelativeGestures, value: v) }
                        Toggle("Extended Range", isOn: $cache.gesture.extendedGestureRange)
                            .onChange(of: cache.gesture.extendedGestureRange) { _, v in cache.push(\.extendedGestureRange, value: v) }
                        Toggle("Rotation Auto-Snap", isOn: $cache.gesture.rotationAutoSnap)
                            .onChange(of: cache.gesture.rotationAutoSnap) { _, v in cache.push(\.rotationAutoSnap, value: v) }
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
            Picker("", selection: $settingsSubTab) {
                ForEach(SettingsSubTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16).padding(.vertical, 8)
            
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 12) {
                    switch settingsSubTab {
                    case .general:     settingsGeneralContent
                    case .exportShare: settingsExportContent
                    case .devTools:    settingsAdvancedContent
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
            }
        }
    }
    
    private var settingsGeneralContent: some View {
        VStack(spacing: 12) {
            // SharePlay section
            if let shareSession = appModel.shareSession {
                VStack(spacing: 8) {
                    HStack {
                        Label("SharePlay", systemImage: "shareplay").font(.headline)
                        Spacer()
                    }
                    SharePlayControlsView(shareSession: shareSession, appModel: appModel)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.purple.opacity(0.06)))
            }

            // Privacy & Analytics section
            VStack(spacing: 8) {
                HStack {
                    Label("Privacy", systemImage: "shield.lefthalf.filled").font(.headline)
                    Spacer()
                }
                Toggle("Send anonymous usage data", isOn: Binding(
                    get: { UsageAnalytics.shared.analyticsEnabled },
                    set: { UsageAnalytics.shared.analyticsEnabled = $0 }
                ))
                Text("Shares aggregated stats (popular fractals, average FPS, feature usage) to help improve Threshold. No personal information, Apple ID, or location is ever collected.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.blue.opacity(0.06)))
        }
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
                        let preset = FractalPreset.fromSettings(appModel.renderSettings, name: "Export")
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
                        var preset = FractalPreset.fromSettings(appModel.renderSettings, name: "Music Export")
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

    private let holdArmDelay: TimeInterval = 1.2
    private let holdDuration: TimeInterval = 3.0

    private var totalHoldDuration: TimeInterval {
        holdArmDelay + holdDuration
    }

    var body: some View {
        ZStack {
            Capsule()
                .fill(Color.orange.opacity(0.12))

            GeometryReader { geo in
                Capsule()
                    .fill(Color.orange.opacity(0.28))
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
                        .stroke(Color.orange,
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
                .stroke(Color.orange.opacity(0.45), lineWidth: 1)
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
                .background(Capsule().fill((isActive ? color : Color.secondary).opacity(isActive ? 0.14 : 0.08)))
                .overlay(Capsule().strokeBorder((isActive ? color : Color.secondary).opacity(isActive ? 0.34 : 0.12), lineWidth: 1))

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
        .help("\(title): \(isActive ? "On" : "Off")")
        .accessibilityLabel(title)
        .accessibilityValue(isActive ? "On" : "Off")
    }
}

private struct SaveDestinationSheet: View {
    let onSave: (SaveChoice, String?) -> Void
    let onCancel: () -> Void

    @State private var choice: SaveChoice = .resetLocation
    @State private var manualPresetName = ""

    private var canSave: Bool {
        if choice != .presetCustomName { return true }
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
                    choice: .presetAutoNamed,
                    title: "Preset - Auto Named",
                    subtitle: "Save with a timestamped preset name.",
                    systemImage: "clock.badge.checkmark"
                )

                saveChoiceButton(
                    choice: .presetCustomName,
                    title: "Preset - Custom Name",
                    subtitle: "Save with a name you enter.",
                    systemImage: "character.cursor.ibeam"
                )
            }

            if choice == .presetCustomName {
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

#Preview(windowStyle: .automatic) {
    ContentView().environment(AppModel())
}
