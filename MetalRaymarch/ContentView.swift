//
//  ContentView.swift
//  MetalProject
//
//  Created by MU on 18/11/24.
//  Reorganized: Sidebar + Sub-Tab layout
//

import SwiftUI
import RealityKit

// MARK: - Cached UI Settings
// Local state that syncs with RenderSettings periodically to avoid lock contention
@Observable
final class UISettingsCache {
    // Fractal parameters
    var fractalType: FractalModelType = .mandelbox
    var fractalScale: Float = 2.0
    var targetMinDistance: Float = 0.8
    var targetFoldingLimit: Float = 1.0
    var targetSphereRadius: Float = 0.5
    var baseFractalIterations: Int = 9
    var baseMaxRaySteps: Int = 64
    
    // Color & effects
    var colorScheme: ColorScheme = .nebula
    var colorMix: Float = 0.5
    var colorIterations: Float = 8.0
    var colorSchemeAutoTransition: Bool = false
    var colorSchemeAutoInterval: Float = 30.0
    var colorSchemeTransitionDuration: Float = 2.0
    var colorSchemeSaturation: Float = 2.0
    var colorSchemeContrast: Float = 1.05
    var colorSchemeGamma: Float = 0.5
    var colorSchemeVibrance: Float = 1.0
    var colorSchemeCurve: Float = 0.0
    var colorSchemeShadows: Float = 0.0
    var colorSchemeHighlights: Float = 0.0
    
    // === GRADIENT COLORING SYSTEM ===
    var useGradientColoring: Bool = true
    var gradientColorMap: GradientColorMap = GradientPreset.nebula.makeGradient()
    var gradientPreset: GradientPreset? = .nebula
    var colorMappingMode: ColorMappingMode = .orbitTrap
    var gradientRepeat: Float = 1.0
    var gradientOffset: Float = 0.0
    var gradientSmoothing: Float = 1.0
    
    // === MODULAR LIGHTING EFFECTS ===
    var lightingPreset: LightingPreset = .off
    var hueRotationEffect: HueRotationEffect = .off
    var pulseEffect: PulseEffect = .off
    var glowEffect: GlowEffect = .off
    var bloomEffect: BloomEffect = .off
    var fogEffect: FogEffect = FogEffect(enabled: true, intensity: 0.32)
    var gradientCycleEffect: GradientCycleEffect = .off
    
    // === SAVED CUSTOM GRADIENTS (persisted via UserDefaults) ===
    var savedCustomGradients: [GradientColorMap] = UISettingsCache.loadSavedGradients()
    
    static func loadSavedGradients() -> [GradientColorMap] {
        guard let data = UserDefaults.standard.data(forKey: "savedCustomGradients"),
              let gradients = try? JSONDecoder().decode([GradientColorMap].self, from: data) else { return [] }
        return gradients
    }
    
    func saveSavedGradients() {
        if let data = try? JSONEncoder().encode(savedCustomGradients) {
            UserDefaults.standard.set(data, forKey: "savedCustomGradients")
        }
    }
    
    func saveCurrentGradientAsCustom() {
        var copy = gradientColorMap
        // Give it a unique name
        let existingCount = savedCustomGradients.count
        copy = GradientColorMap(name: "Custom \(existingCount + 1)", stops: copy.stops,
                                 mappingMode: copy.mappingMode, repeatCount: copy.repeatCount,
                                 offset: copy.offset, smoothing: copy.smoothing)
        savedCustomGradients.append(copy)
        saveSavedGradients()
    }
    
    func deleteSavedGradient(at index: Int) {
        guard index >= 0 && index < savedCustomGradients.count else { return }
        savedCustomGradients.remove(at: index)
        saveSavedGradients()
    }
    
    func renameSavedGradient(at index: Int, to newName: String) {
        guard index >= 0 && index < savedCustomGradients.count else { return }
        savedCustomGradients[index].name = newName
        saveSavedGradients()
    }
    
    /// Overwrite a saved gradient's stops/settings with the current editor state
    func updateSavedGradient(at index: Int) {
        guard index >= 0 && index < savedCustomGradients.count else { return }
        let name = savedCustomGradients[index].name
        savedCustomGradients[index] = GradientColorMap(
            name: name, stops: gradientColorMap.stops,
            mappingMode: gradientColorMap.mappingMode,
            repeatCount: gradientColorMap.repeatCount,
            offset: gradientColorMap.offset,
            smoothing: gradientColorMap.smoothing
        )
        saveSavedGradients()
    }
    
    func applySavedGradient(_ gradient: GradientColorMap) {
        gradientColorMap = gradient
        gradientPreset = nil  // Mark as custom
        settings?.gradientColorMap = gradient
        settings?.useGradientColoring = true
    }
    
    // Emissive
    var emissiveEnabled: Bool = true
    var emissivePattern: Int = 0
    var emissiveIntensity: Float = 1.0
    var emissiveThreshold: Float = 0.5
    var emissiveColor: SIMD3<Float> = SIMD3<Float>(0.3, 0.6, 1.0)
    var emissiveSpeed: Float = 1.0
    
    // Lighting - simplified
    var lightingMode: LightingMode = .animated
    var lightingSoftness: Float = 0.0
    
    // Safety & display
    var showHUD: Bool = true
    var safetyBubbleEnabled: Bool = false
    var safetyBubbleRadius: Float = 1.8
    var safetyBubbleShape: Float = 0.0
    var useRelativeGestures: Bool = true
    var extendedGestureRange: Bool = true
    var gestureSensitivity: Float = 3.0
    
    // Dynamic quality
    var dynamicRenderQualityEnabled: Bool = true
    var dynamicRenderQualityMin: Float = 0.5
    var dynamicRenderQualityMax: Float = 1.0
    var currentRenderQuality: Float = 0.7
    
    private var syncTimer: Timer?
    private weak var settings: RenderSettings?
    
    func startSync(with settings: RenderSettings) {
        self.settings = settings
        loadFromSettings()
        syncTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.syncQualityOnly()
        }
    }
    
    func stopSync() {
        syncTimer?.invalidate()
        syncTimer = nil
    }
    
    private func syncQualityOnly() {
        guard let settings else { return }
        currentRenderQuality = settings.currentRenderQuality
    }
    
    func loadFromSettings() {
        guard let settings else { return }
        fractalType = settings.fractalType
        fractalScale = settings.fractalScale
        targetMinDistance = settings.targetMinDistance
        targetFoldingLimit = settings.targetFoldingLimit
        targetSphereRadius = settings.targetSphereRadius
        baseFractalIterations = settings.baseFractalIterations
        baseMaxRaySteps = settings.baseMaxRaySteps
        colorScheme = settings.colorScheme
        colorMix = settings.colorMix
        colorIterations = settings.colorIterations
        colorSchemeAutoTransition = settings.colorSchemeAutoTransition
        colorSchemeAutoInterval = settings.colorSchemeAutoInterval
        colorSchemeTransitionDuration = settings.colorSchemeTransitionDuration
        colorSchemeSaturation = settings.colorSchemeSaturation
        colorSchemeContrast = settings.colorSchemeContrast
        colorSchemeGamma = settings.colorSchemeGamma
        colorSchemeVibrance = settings.colorSchemeVibrance
        colorSchemeCurve = settings.colorSchemeCurve
        colorSchemeShadows = settings.colorSchemeShadows
        colorSchemeHighlights = settings.colorSchemeHighlights
        useGradientColoring = settings.useGradientColoring
        gradientColorMap = settings.gradientColorMap
        gradientPreset = settings.gradientPreset
        colorMappingMode = settings.colorMappingMode
        gradientRepeat = settings.gradientRepeat
        gradientOffset = settings.gradientOffset
        gradientSmoothing = settings.gradientSmoothing
        lightingPreset = settings.lightingPreset
        hueRotationEffect = settings.hueRotationEffect
        pulseEffect = settings.pulseEffect
        glowEffect = settings.glowEffect
        bloomEffect = settings.bloomEffect
        fogEffect = settings.fogEffect
        gradientCycleEffect = settings.gradientCycleEffect
        emissiveEnabled = settings.emissiveEnabled
        emissivePattern = settings.emissivePattern
        emissiveIntensity = settings.emissiveIntensity
        emissiveThreshold = settings.emissiveThreshold
        emissiveColor = settings.emissiveColor
        emissiveSpeed = settings.emissiveSpeed
        lightingMode = settings.lightingMode
        lightingSoftness = settings.lightingSoftness
        showHUD = settings.showHUD
        safetyBubbleEnabled = settings.safetyBubbleEnabled
        safetyBubbleRadius = settings.safetyBubbleRadius
        safetyBubbleShape = settings.safetyBubbleShape
        useRelativeGestures = settings.useRelativeGestures
        extendedGestureRange = settings.extendedGestureRange
        gestureSensitivity = settings.gestureSensitivity
        dynamicRenderQualityEnabled = settings.dynamicRenderQualityEnabled
        dynamicRenderQualityMin = settings.dynamicRenderQualityMin
        dynamicRenderQualityMax = settings.dynamicRenderQualityMax
        currentRenderQuality = settings.currentRenderQuality
    }
    
    @inline(__always)
    func push<T>(_ keyPath: WritableKeyPath<RenderSettings, T>, value: T) {
        settings?[keyPath: keyPath] = value
    }
    
    @MainActor
    func pushFractalType(_ type: FractalModelType, gestureController: GestureController?) {
        let oldType = settings?.fractalType
        settings?.fractalType = type
        if oldType != type {
            gestureController?.applyFractalDefaults()
            loadFromSettings()
        }
    }
    
    func pushColorScheme(_ scheme: ColorScheme) {
        settings?.transitionToColorScheme(scheme)
        colorScheme = scheme
    }
    
    func pushGradientEnabled(_ enabled: Bool) {
        settings?.useGradientColoring = enabled
    }
    
    func pushGradientMap(_ map: GradientColorMap) {
        settings?.gradientColorMap = map
    }
    
    func applyGradientPreset(_ preset: GradientPreset) {
        settings?.applyGradientPreset(preset)
        gradientColorMap = preset.makeGradient()
        gradientPreset = preset
        useGradientColoring = true
        let pp = preset.postProcessing
        colorSchemeSaturation = pp.saturation
        colorSchemeContrast = pp.contrast
        colorSchemeGamma = pp.gamma
    }
    
    func reloadLightingEffects() {
        guard let settings = settings else { return }
        hueRotationEffect = settings.hueRotationEffect
        pulseEffect = settings.pulseEffect
        glowEffect = settings.glowEffect
        bloomEffect = settings.bloomEffect
        fogEffect = settings.fogEffect
        gradientCycleEffect = settings.gradientCycleEffect
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - Sidebar Tab Enum
// ═══════════════════════════════════════════════════════════════════════════════

enum SidebarTab: String, CaseIterable {
    case fractal = "Fractal"
    case animate = "Animate"
    case coloring = "Coloring"
    case effects = "Effects"
    case settings = "Settings"
    
    var icon: String {
        switch self {
        case .fractal:  return "cube.fill"
        case .animate:  return "film.stack"
        case .coloring: return "paintpalette.fill"
        case .effects:  return "wand.and.stars"
        case .settings: return "gearshape.fill"
        }
    }
}

enum FractalSubTab: String, CaseIterable { case shape = "Shape", space = "Space", quality = "Quality" }
enum AnimateSubTab: String, CaseIterable { case play = "Play", edit = "Edit" }
enum ColoringSubTab: String, CaseIterable { case gradient = "Gradient", mapping = "Mapping", grading = "Grading" }
enum EffectsSubTab: String, CaseIterable { case dynamic = "Dynamic", `static` = "Static" }
enum SettingsSubTab: String, CaseIterable { case general = "General", advanced = "Advanced" }

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - ContentView
// ═══════════════════════════════════════════════════════════════════════════════

struct ContentView: View {
    @Environment(AppModel.self) private var appModel
    
    @State private var cache = UISettingsCache()
    @State private var selectedTab: SidebarTab = .fractal
    @State private var fractalSubTab: FractalSubTab = .shape
    @State private var animateSubTab: AnimateSubTab = .play
    @State private var coloringSubTab: ColoringSubTab = .gradient
    @State private var effectsSubTab: EffectsSubTab = .dynamic
    @State private var settingsSubTab: SettingsSubTab = .general
    @State private var showStopsPopover = false
    @State private var editingScene: AnimationScene?
    
    // Developer state
    @State private var isProfilerRunning = false
    @State private var lastProfileTime: Date?
    @State private var isTestAnimationPlaying = false
    
    private var parameterRanges: (minDistance: ClosedRange<Float>, foldingLimit: ClosedRange<Float>, sphereRadius: ClosedRange<Float>) {
        appModel.gestureController?.getParameterRanges() ?? (0.1...5.0, 0.1...13.0, 0.1...2.0)
    }
    
    private var fpsIndicatorColor: Color {
        let fps = appModel.fps
        if fps >= 85 { return .green }
        else if fps >= 60 { return .yellow }
        else if fps >= 45 { return .orange }
        else { return .red }
    }
    
    var body: some View {
        @Bindable var appModel = appModel
        
        ZStack {
            if appModel.immersiveSpaceState == .open {
                immersiveLayout
            } else {
                preImmersiveLayout
            }
        }
        .glassBackgroundEffect(in: .rect(cornerRadius: 20))
        .animation(.easeInOut(duration: 0.3), value: appModel.immersiveSpaceState)
        .onHover { hovering in
            // Suppress fractal hand-tracking gestures while the user is
            // looking at (and therefore interacting with) the menu window.
            appModel.gestureController?.suppressParameterGestures = hovering
        }
        .onAppear { cache.startSync(with: appModel.renderSettings) }
        .onDisappear { cache.stopSync() }
    }
    
    // MARK: - Pre-Immersive Layout
    
    private var preImmersiveLayout: some View {
        VStack(spacing: 16) {
            Text("MetalRaymarch")
                .font(.title2.bold())
            ToggleImmersiveSpaceButton()
        }
        .padding(30)
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
                    
                    // ── PLAYER: Fixed playback bar (visible when a scene is loaded) ──
                    if let animationManager = appModel.animationManager,
                       animationManager.currentScene != nil {
                        Divider()
                        AnimationPlaybackControls(animationManager: animationManager)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                    }
                    
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
                        Image(systemName: tab.icon)
                            .font(.system(size: 18))
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
                .accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
            }
            Spacer()
        }
        .padding(.vertical, 8)
        .frame(width: 72)
    }
    
    // MARK: - Content Panel
    
    private var contentPanel: some View {
        Group {
            switch selectedTab {
            case .fractal:  fractalTabContent
            case .animate:  animateTabContent
            case .coloring: coloringTabContent
            case .effects:  effectsTabContent
            case .settings: settingsTabContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - Bottom Bar
    
    private var bottomBar: some View {
        HStack(spacing: 10) {
            ToggleImmersiveSpaceButton()
            
            Divider().frame(height: 20)
            
            // Performance indicator
            HStack(spacing: 6) {
                Image(systemName: appModel.isUsingSpecializedPipeline ? "bolt.fill" : "bolt.slash")
                    .font(.caption2)
                    .foregroundStyle(appModel.isUsingSpecializedPipeline ? .green : .orange)
                Circle().fill(fpsIndicatorColor).frame(width: 8, height: 8)
                Text("\(appModel.fps, specifier: "%.0f") FPS")
                    .font(.caption.bold()).monospacedDigit()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(.ultraThinMaterial))
            
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
            
            Button {
                appModel.renderSettings.targetPosition = .zero
                appModel.renderSettings.position = .zero
                appModel.gestureController?.applyFractalDefaults()
                cache.loadFromSettings()
            } label: {
                Label("Reset", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(.bordered)
            .tint(.orange)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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
            .padding(.horizontal, 16).padding(.vertical, 8)
            
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 12) {
                    switch fractalSubTab {
                    case .shape:   fractalShapeContent
                    case .space:   fractalSpaceContent
                    case .quality: fractalQualityContent
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
            }
        }
    }
    
    private var fractalShapeContent: some View {
        VStack(spacing: 12) {
            HStack {
                Label("Fractal Type", systemImage: "cube.fill").font(.headline)
                Spacer()
                Picker("Type", selection: $cache.fractalType) {
                    ForEach(FractalModelType.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.menu).frame(maxWidth: 180)
                .onChange(of: cache.fractalType) { _, newValue in
                    cache.pushFractalType(newValue, gestureController: appModel.gestureController)
                }
            }

            Divider()

            // Scale slider with icon
            EffectSliderRow(icon: "arrow.up.left.and.arrow.down.right", label: "Scale",
                value: $cache.fractalScale, range: -3.0...5.0,
                enabled: .constant(true),
                onChanged: { cache.push(\.fractalScale, value: cache.fractalScale) },
                showToggle: false)

            Divider()

            // Shape parameters grouped
            VStack(spacing: 4) {
                HStack {
                    Label("Shape Parameters", systemImage: "skew").font(.headline)
                    Spacer()
                }
                .padding(.bottom, 4)

                EffectSliderRow(icon: "arrow.down.right.and.arrow.up.left", label: "Min Distance",
                    value: $cache.targetMinDistance, range: parameterRanges.minDistance,
                    enabled: .constant(true),
                    onChanged: { cache.push(\.targetMinDistance, value: cache.targetMinDistance) },
                    showToggle: false)
                Divider().padding(.leading, 114)
                EffectSliderRow(icon: "arrow.triangle.branch", label: "Folding Limit",
                    value: $cache.targetFoldingLimit, range: parameterRanges.foldingLimit,
                    enabled: .constant(true),
                    onChanged: { cache.push(\.targetFoldingLimit, value: cache.targetFoldingLimit) },
                    showToggle: false)
                Divider().padding(.leading, 114)
                EffectSliderRow(icon: "circle.dashed", label: "Sphere Radius",
                    value: $cache.targetSphereRadius, range: parameterRanges.sphereRadius,
                    enabled: .constant(true),
                    onChanged: { cache.push(\.targetSphereRadius, value: cache.targetSphereRadius) },
                    showToggle: false)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.blue.opacity(0.06)))
        }
    }
    
    private var fractalSpaceContent: some View {
        VStack(spacing: 12) {
            VStack(spacing: 8) {
                HStack {
                    Label("Safety Bubble", systemImage: "shield.lefthalf.filled").font(.headline)
                    Spacer()
                    Toggle("", isOn: $cache.safetyBubbleEnabled)
                        .labelsHidden()
                        .onChange(of: cache.safetyBubbleEnabled) { _, val in
                            cache.push(\.safetyBubbleEnabled, value: val)
                        }
                }
                Text("Prevents the camera from entering the fractal geometry.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if cache.safetyBubbleEnabled {
                    EffectSliderRow(icon: "circle.dashed", label: "Radius",
                        value: $cache.safetyBubbleRadius, range: 0.5...2.5,
                        enabled: .constant(true),
                        onChanged: { cache.push(\.safetyBubbleRadius, value: cache.safetyBubbleRadius) },
                        showToggle: false)
                    HStack {
                        Text("Shape"); Spacer()
                        Picker("Shape", selection: Binding<Int>(
                            get: { cache.safetyBubbleShape < 0.5 ? 0 : 1 },
                            set: { cache.safetyBubbleShape = $0 == 0 ? 0.0 : 1.0; cache.push(\.safetyBubbleShape, value: cache.safetyBubbleShape) }
                        )) { Text("Sphere").tag(0); Text("Cube").tag(1) }
                        .pickerStyle(.segmented).frame(maxWidth: 160)
                    }
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.green.opacity(0.06)))
        }
    }
    
    private var fractalQualityContent: some View {
        VStack(spacing: 12) {
            Text("Quality Presets").font(.headline)
            HStack(spacing: 8) {
                ForEach(QualityPreset.allCases, id: \.rawValue) { preset in
                    Button {
                        cache.baseFractalIterations = preset.fractalIterations
                        cache.baseMaxRaySteps = preset.raySteps
                        cache.push(\.baseFractalIterations, value: preset.fractalIterations)
                        cache.push(\.baseMaxRaySteps, value: preset.raySteps)
                        appModel.preparePipeline(iterations: preset.fractalIterations, raySteps: preset.raySteps)
                    } label: {
                        VStack(spacing: 2) {
                            Image(systemName: preset.icon).font(.caption)
                            Text(preset.displayName).font(.caption2)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                    .tint(QualityPreset.detect(fractalIterations: cache.baseFractalIterations, raySteps: cache.baseMaxRaySteps) == preset ? .blue : .secondary)
                }
            }
            Divider()
            Toggle("Dynamic Render Quality", isOn: $cache.dynamicRenderQualityEnabled)
                .onChange(of: cache.dynamicRenderQualityEnabled) { _, v in cache.push(\.dynamicRenderQualityEnabled, value: v) }
            if cache.dynamicRenderQualityEnabled {
                qualityIndicator
                HStack {
                    Text("Min Quality:").font(.caption)
                    Slider(value: $cache.dynamicRenderQualityMin, in: 0.4...0.8, onEditingChanged: { e in if !e { cache.push(\.dynamicRenderQualityMin, value: cache.dynamicRenderQualityMin) } })
                    Text("\(Int(cache.dynamicRenderQualityMin * 100))%").font(.caption.monospacedDigit()).frame(width: 40, alignment: .trailing)
                }
                HStack {
                    Text("Max Quality:").font(.caption)
                    Slider(value: $cache.dynamicRenderQualityMax, in: 0.8...1.0, onEditingChanged: { e in if !e { cache.push(\.dynamicRenderQualityMax, value: cache.dynamicRenderQualityMax) } })
                    Text("\(Int(cache.dynamicRenderQualityMax * 100))%").font(.caption.monospacedDigit()).frame(width: 40, alignment: .trailing)
                }
            }
        }
    }
    
    private func qualityColor(_ quality: Float) -> Color {
        if quality >= 0.8 { return .green } else if quality >= 0.6 { return .yellow } else { return .orange }
    }
    
    private var qualityIndicator: some View {
        HStack {
            Text("Current Quality:").font(.caption); Spacer()
            Text("\(Int(cache.currentRenderQuality * 100))%").font(.caption.monospacedDigit()).foregroundStyle(qualityColor(cache.currentRenderQuality))
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.gray.opacity(0.3))
                    RoundedRectangle(cornerRadius: 2).fill(qualityColor(cache.currentRenderQuality))
                        .frame(width: geo.size.width * CGFloat(cache.currentRenderQuality))
                }
            }.frame(width: 60, height: 8)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Render quality")
        .accessibilityValue("\(Int(cache.currentRenderQuality * 100)) percent")
    }
    
    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Animate Tab
    // ═══════════════════════════════════════════════════════════════════════════
    
    private var animateTabContent: some View {
        VStack(spacing: 0) {
            Picker("", selection: $animateSubTab) {
                ForEach(AnimateSubTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16).padding(.vertical, 8)
            
            switch animateSubTab {
            case .play: animatePlayContent
            case .edit: animateEditContent
            }
        }
    }
    
    private var animatePlayContent: some View {
        VStack(spacing: 0) {
            if let animationManager = appModel.animationManager {
                List {
                    if animationManager.scenes.isEmpty {
                        ContentUnavailableView("No Scenes", systemImage: "film.stack",
                            description: Text("Switch to Edit to create animation scenes"))
                    } else {
                        ForEach(animationManager.scenes) { scene in
                            SceneRowView(
                                scene: scene,
                                isSelected: animationManager.currentScene?.id == scene.id,
                                isDefault: animationManager.isDefaultScene(scene),
                                isEdited: animationManager.isEditedDefault(scene),
                                onSelect: { animationManager.currentScene = scene },
                                onPlay: { animationManager.currentScene = scene; animationManager.play() }
                            )
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
    }
    
    private var animateEditContent: some View {
        HStack(spacing: 0) {
            // Scene list (left)
            Group {
                if let animationManager = appModel.animationManager {
                    SceneListView(
                        animationManager: animationManager,
                        appModel: appModel,
                        onEditScene: { scene in
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                if editingScene?.id == scene.id {
                                    editingScene = nil
                                } else {
                                    editingScene = scene
                                }
                            }
                        },
                        isInline: true,
                        isEditing: editingScene != nil
                    )
                } else {
                    ContentUnavailableView("Not Available", systemImage: "exclamationmark.triangle",
                        description: Text("Animation manager not initialized"))
                }
            }
            .frame(maxWidth: editingScene != nil ? 220 : .infinity)
            
            // Scene editor side pane (right)
            if let scene = editingScene, let animationManager = appModel.animationManager {
                Divider()
                SceneEditorView(
                    scene: scene,
                    animationManager: animationManager,
                    appModel: appModel,
                    onDismiss: {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            editingScene = nil
                        }
                    },
                    isInline: true
                )
                .id(scene.id)
                .frame(minWidth: 420, maxWidth: .infinity)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
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
            Label("Gradient Coloring", systemImage: "paintbrush.fill").font(.headline)
            GradientPreviewBar(gradient: cache.gradientColorMap)
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
                    Button { cache.applyGradientPreset(preset) } label: {
                        VStack(spacing: 2) {
                            Image(systemName: preset.icon).font(.caption)
                            Text(preset.displayName).font(.caption2).lineLimit(1)
                        }.frame(maxWidth: .infinity).padding(.vertical, 4)
                    }
                    .buttonStyle(.bordered).tint(cache.gradientPreset == preset ? .blue : .secondary)
                }
            }
            
            // ── Saved Custom Gradients ──
            if !cache.savedCustomGradients.isEmpty {
                HStack {
                    Text("Saved").font(.subheadline).foregroundColor(.secondary)
                    Spacer()
                    Text("\(cache.savedCustomGradients.count)").font(.caption2).foregroundStyle(.tertiary)
                }
                .padding(.top, 4)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                    ForEach(Array(cache.savedCustomGradients.enumerated()), id: \.element.id) { index, saved in
                        let isActive = cache.gradientPreset == nil && cache.gradientColorMap.id == saved.id
                        Button {
                            cache.applySavedGradient(saved)
                        } label: {
                            VStack(spacing: 2) {
                                GradientPreviewBar(gradient: saved)
                                    .frame(height: 10)
                                    .clipShape(RoundedRectangle(cornerRadius: 3))
                                    .allowsHitTesting(false)
                                Text(saved.name).font(.caption2).lineLimit(1)
                            }.frame(maxWidth: .infinity).padding(.vertical, 4)
                        }
                        .buttonStyle(.bordered)
                        .tint(isActive ? .purple : .indigo)
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
                .buttonStyle(.bordered).tint(cache.gradientPreset == nil ? .blue : .secondary)
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
                Picker("Mapping", selection: $cache.colorMappingMode) {
                    ForEach(ColorMappingMode.allCases, id: \.rawValue) { Text($0.displayName).tag($0) }
                }.pickerStyle(.menu).frame(maxWidth: 140)
                .onChange(of: cache.colorMappingMode) { _, v in cache.push(\.colorMappingMode, value: v) }
            }

            // Gradient transform controls
            VStack(spacing: 4) {
                EffectSliderRow(icon: "repeat", label: "Repeat",
                    value: $cache.gradientRepeat, range: 0.1...5.0,
                    enabled: .constant(true),
                    onChanged: { cache.push(\.gradientRepeat, value: cache.gradientRepeat) },
                    showToggle: false)
                Divider().padding(.leading, 114)
                EffectSliderRow(icon: "arrow.right", label: "Offset",
                    value: $cache.gradientOffset, range: 0...1,
                    enabled: .constant(true),
                    onChanged: { cache.push(\.gradientOffset, value: cache.gradientOffset) },
                    showToggle: false)
                Divider().padding(.leading, 114)
                EffectSliderRow(icon: "waveform.path", label: "Smoothing",
                    value: $cache.gradientSmoothing, range: 0...1,
                    enabled: .constant(true),
                    onChanged: { cache.push(\.gradientSmoothing, value: cache.gradientSmoothing) },
                    showToggle: false)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.purple.opacity(0.06)))

            Divider()

            // Color blend controls
            VStack(spacing: 4) {
                EffectSliderRow(icon: "circle.lefthalf.filled", label: "Color Mix",
                    value: $cache.colorMix, range: 0...1.0,
                    enabled: .constant(true),
                    onChanged: { cache.push(\.colorMix, value: cache.colorMix) },
                    showToggle: false)
                Divider().padding(.leading, 114)
                EffectSliderRow(icon: "number", label: "Iterations",
                    value: $cache.colorIterations, range: 4...16,
                    enabled: .constant(true),
                    onChanged: { cache.push(\.colorIterations, value: cache.colorIterations) },
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
                    value: $cache.colorSchemeContrast, range: 0.95...1.15,
                    enabled: .constant(true),
                    onChanged: { cache.push(\.colorSchemeContrast, value: cache.colorSchemeContrast) },
                    showToggle: false)
                Divider().padding(.leading, 114)
                EffectSliderRow(icon: "paintpalette.fill", label: "Vibrance",
                    value: $cache.colorSchemeVibrance, range: 0...1.0,
                    enabled: .constant(true),
                    onChanged: { cache.push(\.colorSchemeVibrance, value: cache.colorSchemeVibrance) },
                    showToggle: false)
                Divider().padding(.leading, 114)
                EffectSliderRow(icon: "waveform.path", label: "Midtone Curve",
                    value: $cache.colorSchemeCurve, range: -1.0...1.0,
                    enabled: .constant(true),
                    onChanged: { cache.push(\.colorSchemeCurve, value: cache.colorSchemeCurve) },
                    showToggle: false)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.06)))

            // Shadows & Highlights
            VStack(spacing: 4) {
                EffectSliderRow(icon: "shadow", label: "Shadows",
                    value: $cache.colorSchemeShadows, range: -0.05...0.05,
                    enabled: .constant(true),
                    onChanged: { cache.push(\.colorSchemeShadows, value: cache.colorSchemeShadows) },
                    showToggle: false)
                Divider().padding(.leading, 114)
                EffectSliderRow(icon: "sun.max.fill", label: "Highlights",
                    value: $cache.colorSchemeHighlights, range: -0.5...1.0,
                    enabled: .constant(true),
                    onChanged: { cache.push(\.colorSchemeHighlights, value: cache.colorSchemeHighlights) },
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
                    value: Binding(get: { cache.glowEffect.intensity }, set: { cache.glowEffect.intensity = $0 }),
                    range: 0...1,
                    enabled: Binding(get: { cache.glowEffect.enabled }, set: { cache.glowEffect.enabled = $0 }),
                    onChanged: { cache.push(\.glowEffect, value: cache.glowEffect) })
                Divider().padding(.leading, 114)
                EffectSliderRow(icon: "sun.max.fill", label: "Bloom",
                    value: Binding(get: { cache.bloomEffect.strength }, set: { cache.bloomEffect.strength = $0 }),
                    range: 0...1,
                    enabled: Binding(get: { cache.bloomEffect.enabled }, set: { cache.bloomEffect.enabled = $0 }),
                    onChanged: { cache.push(\.bloomEffect, value: cache.bloomEffect) })
                Divider().padding(.leading, 114)
                EffectSliderRow(icon: "cloud.fog.fill", label: "Fog",
                    value: Binding(get: { cache.fogEffect.intensity }, set: { cache.fogEffect.intensity = $0 }),
                    range: 0...1,
                    enabled: Binding(get: { cache.fogEffect.enabled }, set: { cache.fogEffect.enabled = $0 }),
                    onChanged: { cache.push(\.fogEffect, value: cache.fogEffect) })
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.06)))
            
            // ── Emissive ──
            VStack(spacing: 8) {
                HStack {
                    Label("Emissive Glow", systemImage: "sparkle").font(.subheadline.weight(.medium))
                    Spacer()
                    Picker("Pattern", selection: Binding<Int>(
                        get: { cache.emissiveEnabled ? cache.emissivePattern + 1 : 0 },
                        set: { v in
                            if v == 0 {
                                cache.emissiveEnabled = false
                                cache.push(\.emissiveEnabled, value: false)
                            } else {
                                cache.emissiveEnabled = true
                                cache.emissivePattern = v - 1
                                cache.push(\.emissiveEnabled, value: true)
                                cache.push(\.emissivePattern, value: v - 1)
                            }
                        }
                    )) {
                        Text("Off").tag(0)
                        Text("Folds").tag(1); Text("Depth").tag(2); Text("Veins").tag(3); Text("Pulse").tag(4); Text("Edges").tag(5)
                    }.pickerStyle(.menu).frame(maxWidth: 120)
                }
                if cache.emissiveEnabled {
                    HStack { Text("Intensity").font(.caption); Slider(value: $cache.emissiveIntensity, in: 0...2, onEditingChanged: { e in if !e { cache.push(\.emissiveIntensity, value: cache.emissiveIntensity) } }) }
                    HStack { Text("Threshold").font(.caption); Slider(value: $cache.emissiveThreshold, in: 0...1, onEditingChanged: { e in if !e { cache.push(\.emissiveThreshold, value: cache.emissiveThreshold) } }) }
                    Divider()
                    HStack {
                        Text("Emissive Color").font(.subheadline)
                        Spacer()
                        ColorPicker("", selection: Binding(
                            get: { Color(red: Double(cache.emissiveColor.x), green: Double(cache.emissiveColor.y), blue: Double(cache.emissiveColor.z)) },
                            set: { c in if let comps = c.cgColor?.components, comps.count >= 3 {
                                cache.emissiveColor = SIMD3<Float>(Float(comps[0]), Float(comps[1]), Float(comps[2]))
                                cache.push(\.emissiveColor, value: cache.emissiveColor)
                            }}
                        ), supportsOpacity: false).labelsHidden()
                    }
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.cyan.opacity(0.06)))
            
            // ── Lighting Presets (collapsible) ──
            DisclosureGroup(isExpanded: $showLightingPresets) {
                VStack(spacing: 10) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(LightingPreset.allCases, id: \.self) { preset in
                                PresetCardButton(preset: preset, isSelected: cache.lightingPreset == preset) {
                                    cache.lightingPreset = preset
                                    cache.push(\.lightingPreset, value: preset)
                                    cache.reloadLightingEffects()
                                }
                            }
                        }.padding(.horizontal, 4)
                    }
                    if cache.lightingPreset != .custom {
                        Text(cache.lightingPreset.description).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 8)
            } label: {
                Label("Lighting Presets", systemImage: "sparkles")
                    .font(.subheadline.weight(.medium))
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.06)))
        }
    }
    
    private var effectsDynamicContent: some View {
        VStack(spacing: 12) {
            // ── Color Animation ──
            VStack(spacing: 4) {
                EffectSliderRow(icon: "arrow.trianglehead.2.clockwise.rotate.90", label: "Gradient Cycle",
                    value: Binding(get: { cache.gradientCycleEffect.speed }, set: { cache.gradientCycleEffect.speed = $0 }),
                    range: 0...1,
                    enabled: Binding(get: { cache.gradientCycleEffect.enabled }, set: { cache.gradientCycleEffect.enabled = $0 }),
                    onChanged: { cache.push(\.gradientCycleEffect, value: cache.gradientCycleEffect) })
                if cache.gradientCycleEffect.enabled {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.caption)
                            .frame(width: 16)
                        Text("Smooth Loop")
                            .font(.subheadline)
                            .frame(width: 90, alignment: .leading)
                            .lineLimit(1)
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { cache.gradientCycleEffect.smoothLoop },
                            set: { newVal in
                                cache.gradientCycleEffect.smoothLoop = newVal
                                cache.push(\.gradientCycleEffect, value: cache.gradientCycleEffect)
                            }))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                    }
                    .frame(height: 32)
                }
                Divider().padding(.leading, 114)
                EffectSliderRow(icon: "paintpalette.fill", label: "Hue Rotation",
                    value: Binding(get: { cache.hueRotationEffect.speed }, set: { cache.hueRotationEffect.speed = $0 }),
                    range: 0...0.5,
                    enabled: Binding(get: { cache.hueRotationEffect.enabled }, set: { cache.hueRotationEffect.enabled = $0 }),
                    onChanged: { cache.push(\.hueRotationEffect, value: cache.hueRotationEffect) })
                EffectSliderRow(icon: "circle.lefthalf.filled", label: "Hue Intensity",
                    value: Binding(get: { cache.hueRotationEffect.intensity }, set: { cache.hueRotationEffect.intensity = $0 }),
                    range: 0...1,
                    enabled: Binding(get: { cache.hueRotationEffect.enabled }, set: { cache.hueRotationEffect.enabled = $0 }),
                    onChanged: { cache.push(\.hueRotationEffect, value: cache.hueRotationEffect) },
                    showToggle: false)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.blue.opacity(0.06)))
            
            // ── Pulse ──
            VStack(spacing: 4) {
                EffectSliderRow(icon: "waveform.path.ecg", label: "Pulse Speed",
                    value: Binding(get: { cache.pulseEffect.speed }, set: { cache.pulseEffect.speed = $0 }),
                    range: 0...2,
                    enabled: Binding(get: { cache.pulseEffect.enabled }, set: { cache.pulseEffect.enabled = $0 }),
                    onChanged: { cache.push(\.pulseEffect, value: cache.pulseEffect) })
                EffectSliderRow(icon: "waveform.path", label: "Pulse Amount",
                    value: Binding(get: { cache.pulseEffect.amount }, set: { cache.pulseEffect.amount = $0 }),
                    range: 0...1,
                    enabled: Binding(get: { cache.pulseEffect.enabled }, set: { cache.pulseEffect.enabled = $0 }),
                    onChanged: { cache.push(\.pulseEffect, value: cache.pulseEffect) },
                    showToggle: false)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.purple.opacity(0.06)))
            
            // ── Emissive Pulse (only when pulse pattern selected) ──
            if cache.emissivePattern == 3 {
                VStack(spacing: 4) {
                    HStack {
                        Label("Emissive Pulse", systemImage: "sparkle").font(.subheadline.weight(.medium))
                        Spacer()
                    }
                    HStack { Text("Speed").font(.caption); Slider(value: $cache.emissiveSpeed, in: 0.1...5, onEditingChanged: { e in if !e { cache.push(\.emissiveSpeed, value: cache.emissiveSpeed) } }) }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.cyan.opacity(0.06)))
            }
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
                    case .general:   settingsGeneralContent
                    case .advanced:  settingsAdvancedContent
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
            }
        }
    }
    
    private var settingsGeneralContent: some View {
        VStack(spacing: 12) {
            // Display section
            VStack(spacing: 8) {
                HStack {
                    Label("Display", systemImage: "eye").font(.headline)
                    Spacer()
                }
                Toggle("Show HUD Overlay", isOn: $cache.showHUD)
                    .onChange(of: cache.showHUD) { _, v in cache.push(\.showHUD, value: v) }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.blue.opacity(0.06)))

            // Gesture section
            VStack(spacing: 8) {
                HStack {
                    Label("Gesture Controls", systemImage: "hand.draw").font(.headline)
                    Spacer()
                }
                Toggle("Relative Gestures", isOn: $cache.useRelativeGestures)
                    .onChange(of: cache.useRelativeGestures) { _, v in cache.push(\.useRelativeGestures, value: v) }
                Toggle("Extended Range", isOn: $cache.extendedGestureRange)
                    .onChange(of: cache.extendedGestureRange) { _, v in cache.push(\.extendedGestureRange, value: v) }

                EffectSliderRow(icon: "gauge.with.dots.needle.50percent", label: "Sensitivity",
                    value: $cache.gestureSensitivity, range: 1...5,
                    enabled: .constant(true),
                    onChanged: { cache.push(\.gestureSensitivity, value: cache.gestureSensitivity) },
                    showToggle: false)

                Text("Adjust how hand movements map to fractal parameter changes.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.green.opacity(0.06)))

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
        }
    }
    
    private var themeColor: Color {
        switch appModel.renderSettings.colorScheme {
        case .classic: return Color(red: 0.8, green: 0.5, blue: 0.2)
        case .ocean: return Color(red: 0.1, green: 0.5, blue: 0.9)
        case .fire: return Color(red: 1.0, green: 0.4, blue: 0.1)
        case .forest: return Color(red: 0.2, green: 0.7, blue: 0.3)
        case .nebula: return Color(red: 0.6, green: 0.3, blue: 0.9)
        case .mono: return Color(red: 0.5, green: 0.5, blue: 0.55)
        case .aurora: return Color(red: 0.2, green: 0.9, blue: 0.6)
        case .volcanic: return Color(red: 0.9, green: 0.3, blue: 0.1)
        case .neonCyber: return Color(red: 1.0, green: 0.2, blue: 0.8)
        case .neonSunset: return Color(red: 1.0, green: 0.5, blue: 0.3)
        case .neonMatrix: return Color(red: 0.0, green: 1.0, blue: 0.4)
        }
    }
    
    private var fpsColor: Color {
        if appModel.fps >= 85 { return .green }; if appModel.fps >= 60 { return .yellow }; return .red
    }
    
    private var settingsAdvancedContent: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack { Image(systemName: "slider.horizontal.3").foregroundStyle(themeColor); Text("Quality Constraints").font(.headline) }
                VStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack { Text("Fractal Iterations"); Spacer(); Text("\(appModel.renderSettings.baseFractalIterations)").fontWeight(.bold).monospacedDigit() }
                        Slider(value: Binding(get: { Float(appModel.renderSettings.baseFractalIterations) }, set: { appModel.renderSettings.baseFractalIterations = Int($0) }), in: 4...32, step: 1)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack { Text("Max Ray Steps"); Spacer(); Text("\(appModel.renderSettings.baseMaxRaySteps)").fontWeight(.bold).monospacedDigit() }
                        Slider(value: Binding(get: { Float(appModel.renderSettings.baseMaxRaySteps) }, set: { appModel.renderSettings.baseMaxRaySteps = Int($0) }), in: 32...1024, step: 16)
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        HStack { Text("Quality Floor (Min)"); Spacer(); Text(String(format: "%.0f%%", appModel.renderSettings.dynamicRenderQualityMin * 100)).fontWeight(.bold) }
                        Slider(value: Binding(get: { appModel.renderSettings.dynamicRenderQualityMin }, set: { appModel.renderSettings.dynamicRenderQualityMin = $0 }), in: 0.1...0.8, step: 0.05)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack { Text("Quality Ceiling (Max)"); Spacer(); Text(String(format: "%.0f%%", appModel.renderSettings.dynamicRenderQualityMax * 100)).fontWeight(.bold) }
                        Slider(value: Binding(get: { appModel.renderSettings.dynamicRenderQualityMax }, set: { appModel.renderSettings.dynamicRenderQualityMax = $0 }), in: 0.8...1.0, step: 0.05)
                    }
                }
            }.padding().background(themeColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            
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
                    StatBox(label: "FPS", value: String(format: "%.0f", appModel.fps), color: fpsColor)
                    StatBox(label: "Iterations", value: "\(appModel.renderSettings.fractalIterations)", color: themeColor)
                    StatBox(label: "Ray Steps", value: "\(appModel.renderSettings.maxRaySteps)", color: themeColor.opacity(0.8))
                    StatBox(label: "Scale", value: String(format: "%.2f", appModel.renderSettings.fractalScale), color: themeColor.opacity(0.6))
                }
            }.padding().background(themeColor.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
            
            VStack(alignment: .leading, spacing: 8) {
                HStack { Image(systemName: "film.fill").foregroundStyle(themeColor); Text("Animation Test").font(.headline) }
                Button {
                    if isTestAnimationPlaying { appModel.animationManager?.stop(); isTestAnimationPlaying = false }
                    else if let mgr = appModel.animationManager {
                        mgr.currentScene = AdvancedTestScene.create(startPosition: appModel.renderSettings.position)
                        mgr.play(); isTestAnimationPlaying = true
                    }
                } label: {
                    HStack { Image(systemName: isTestAnimationPlaying ? "stop.fill" : "play.fill"); Text(isTestAnimationPlaying ? "Stop" : "Play Test") }
                }.buttonStyle(.borderedProminent).tint(isTestAnimationPlaying ? .red : themeColor)
            }.padding().background(themeColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - Advanced Test Scene Helper
// ═══════════════════════════════════════════════════════════════════════════════

enum AdvancedTestScene {
    static func create(startPosition: SIMD3<Float>) -> AnimationScene {
        var scene = AnimationScene(name: "Dev Test")
        scene.isLooping = true
        scene.keyframes.append(AnimationKeyframe(name: "Start", duration: 0, minDistance: 0.8, foldingLimit: 1.0, sphereRadius: 0.5, fractalScale: 2.8, position: startPosition))
        scene.keyframes.append(AnimationKeyframe(name: "Open", duration: 2.0, minDistance: 2.0, foldingLimit: 3.0, sphereRadius: 0.8, fractalScale: 2.5, position: startPosition + SIMD3<Float>(0.1, 0, 0)))
        scene.keyframes.append(AnimationKeyframe(name: "Tight", duration: 2.0, minDistance: 0.5, foldingLimit: 0.8, sphereRadius: 0.3, fractalScale: 3.2, position: startPosition + SIMD3<Float>(0, 0.1, 0)))
        scene.keyframes.append(AnimationKeyframe(name: "Wild", duration: 2.0, minDistance: 1.5, foldingLimit: 5.0, sphereRadius: 1.2, fractalScale: 2.2, position: startPosition + SIMD3<Float>(-0.1, 0, 0.1)))
        scene.keyframes.append(AnimationKeyframe(name: "Return", duration: 2.0, minDistance: 0.8, foldingLimit: 1.0, sphereRadius: 0.5, fractalScale: 2.8, position: startPosition))
        return scene
    }
}

// MARK: - SharePlay Controls View

struct SharePlayControlsView: View {
    @Bindable var shareSession: FractalShareSession
    var appModel: AppModel
    
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                HStack(spacing: 6) {
                    Circle().fill(statusColor).frame(width: 10, height: 10)
                    Text(statusText).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task {
                        switch shareSession.state {
                        case .inactive: await shareSession.startSharing()
                        default: shareSession.stopSharing()
                        }
                    }
                } label: { Label(buttonText, systemImage: buttonIcon) }
                .buttonStyle(.borderedProminent).tint(buttonTint)
            }
            if case .connected = shareSession.state {
                HStack {
                    Text("Role:").font(.caption).foregroundStyle(.secondary)
                    Picker("Role", selection: $shareSession.role) {
                        ForEach(SharePlayRole.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented).frame(maxWidth: 220)
                }
            }
        }
        .padding(.horizontal).padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
    
    private var statusColor: Color { switch shareSession.state { case .inactive: return .gray; case .waiting: return .yellow; case .connected: return .green; case .error: return .red } }
    private var statusText: String { switch shareSession.state { case .inactive: return "Not sharing"; case .waiting: return "Waiting for others..."; case .connected(let c): return "\(c) connected"; case .error(let m): return "Error: \(m)" } }
    private var buttonText: String { switch shareSession.state { case .inactive: return "Share via FaceTime"; default: return "Stop Sharing" } }
    private var buttonIcon: String { switch shareSession.state { case .inactive: return "shareplay"; default: return "shareplay.slash" } }
    private var buttonTint: Color { switch shareSession.state { case .inactive: return .blue; default: return .red } }
}

// MARK: - Condensed Effect Slider Row

/// Single-line effect row: icon + label | slider | on/off toggle
struct EffectSliderRow: View {
    let icon: String
    let label: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    @Binding var enabled: Bool
    let onChanged: () -> Void
    var showToggle: Bool = true
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(enabled ? .primary : .secondary)
                .frame(width: 16)
            Text(label)
                .font(.subheadline)
                .foregroundStyle(enabled ? .primary : .secondary)
                .frame(width: 90, alignment: .leading)
                .lineLimit(1)
            Slider(value: $value, in: range, onEditingChanged: { editing in
                if !editing { onChanged() }
            })
            .disabled(!enabled)
            if showToggle {
                Toggle("", isOn: $enabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .onChange(of: enabled) { _, _ in onChanged() }
            } else {
                Spacer().frame(width: 44)
            }
        }
        .frame(height: 32)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .accessibilityValue(String(format: "%.2f", value))
    }
}

// MARK: - Emissive Color Picker

// MARK: - StatBox

struct StatBox: View {
    let label: String
    let value: String
    let color: Color
    
    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.title3.monospacedDigit())
                .fontWeight(.semibold)
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }
}

#Preview(windowStyle: .automatic) {
    ContentView().environment(AppModel())
}
