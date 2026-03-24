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
    case animate = "Animate"
    case coloring = "Coloring"
    case effects = "Effects"
    case music = "Music"
    case settings = "Settings"
    
    var icon: String {
        switch self {
        case .fractal:  return "cube.fill"
        case .animate:  return "film.stack"
        case .coloring: return "paintpalette.fill"
        case .effects:  return "wand.and.stars"
        case .music:    return "music.note"
        case .settings: return "gearshape.fill"
        }
    }
}

enum FractalSubTab: String, CaseIterable { case shape = "Shape", space = "Space", quality = "Quality" }
enum ColoringSubTab: String, CaseIterable { case gradient = "Gradient", mapping = "Mapping", grading = "Grading" }
enum EffectsSubTab: String, CaseIterable { case dynamic = "Dynamic", `static` = "Static" }
enum SettingsSubTab: String, CaseIterable { case general = "General", exportShare = "Export", advanced = "Advanced" }

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - ContentView
// ═══════════════════════════════════════════════════════════════════════════════

struct ContentView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.openWindow) private var openWindow
    
    @State private var cache = UISettingsCache()
    @State private var selectedTab: SidebarTab = .fractal
    @State private var fractalSubTab: FractalSubTab = .shape
    @State private var coloringSubTab: ColoringSubTab = .gradient
    @State private var effectsSubTab: EffectsSubTab = .dynamic
    @State private var settingsSubTab: SettingsSubTab = .general
    @State private var showStopsPopover = false
    @State private var showFractalTypePopover = false
    
    // Developer state
    @State private var isProfilerRunning = false
    @State private var lastProfileTime: Date?
    @State private var isTestAnimationPlaying = false
#if DEBUG
    @State private var isBenchmarking = false
#endif
    

    
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
            // Treat gaze-hover as active UI interaction for robust gesture suppression.
            appModel.setMenuHovering(hovering)
        }
        .onAppear { cache.startSync(with: appModel.renderSettings, appModel: appModel) }
        .onDisappear { cache.stopSync() }
        .onReceive(NotificationCenter.default.publisher(for: AppModel.fractalSettingsDidChangeNotification)) { _ in
            cache.loadFromSettings()
        }
    }

    private func resetCurrentFractalSettings() {
        appModel.gestureController?.applyFractalDefaults()
        cache.loadFromSettings()
    }

    private func saveCurrentAsResetDefaults() {
        guard appModel.gestureController?.saveCurrentAsFractalDefaults() == true else { return }
        cache.loadFromSettings()
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
                    
                    // ── PLAYER: Fixed playback bar (only in Animate tab) ──
                    if selectedTab == .animate,
                       let animationManager = appModel.animationManager,
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
            if appModel.runtimeViewMode == .buddhabrot {
                BuddhabrotControlsView()
            } else {
                switch selectedTab {
                case .fractal:  fractalTabContent
                case .animate:  animateTabContent
                case .coloring: coloringTabContent
                case .effects:  effectsTabContent
                case .music:    MusicTabContent(cache: cache)
                case .settings: settingsTabContent
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - Bottom Bar
    
    private var bottomBar: some View {
        HStack(spacing: 10) {
            ToggleImmersiveSpaceButton()
            
            Divider().frame(height: 20)
            
            FPSIndicatorView()
            
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
                onHoldSave: saveCurrentAsResetDefaults
            )
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
                ScrollViewReader { scrollProxy in
                    VStack(spacing: 12) {
                        switch fractalSubTab {
                        case .shape:   fractalShapeContent
                        case .space:   fractalSpaceContent
                        case .quality: fractalQualityContent
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .environment(\.scrollProxy, scrollProxy)
                }
            }
        }
    }
    
    private var fractalShapeContent: some View {
        VStack(spacing: 12) {
            HStack {
                Label("Fractal Type", systemImage: "cube.fill").font(.headline)
                Spacer()
                Button {
                    openWindow(id: AppModel.fractalBrowserWindowID)
                } label: {
                    Label("Browser", systemImage: "rectangle.on.rectangle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    showFractalTypePopover.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: cache.fractalType.icon)
                        Text(cache.fractalType.displayName)
                            .lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .popover(isPresented: $showFractalTypePopover, arrowEdge: .top) {
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(FractalModelType.selectableCases, id: \.self) { type in
                                Button {
                                    cache.fractalType = type
                                    cache.pushFractalType(type, gestureController: appModel.gestureController)
                                    showFractalTypePopover = false
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: type.icon)
                                        Text(type.displayName)
                                            .lineLimit(1)
                                        Spacer()
                                        if type == cache.fractalType {
                                            Image(systemName: "checkmark")
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 8)
                                }
                                .buttonStyle(.plain)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(type == cache.fractalType ? Color.blue.opacity(0.14) : Color.clear)
                                )
                            }
                        }
                        .padding(8)
                    }
                    .frame(width: 280, height: 320)
                }
            }

            Divider()

            // Scale slider with icon
            EffectSliderRow(icon: "arrow.up.left.and.arrow.down.right", label: "Scale",
                value: $cache.fractalScale, range: -3.0...5.0,
                enabled: .constant(true),
                onChanged: { cache.push(\.targetFractalScale, value: cache.fractalScale) },
                showToggle: false)

            Divider()

            // Formula-specific parameters (auto-generated from catalog.json — includes Mandelbox)
            FormulaParamsEditor(cache: cache)
        }
    }
    
    private var fractalSpaceContent: some View {
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
                    
                    EffectSliderRow(icon: "circle.righthalf.filled", label: "Blend",
                        value: Binding<Float>(
                            get: { UISettingsCache.blendValueToSlider(cache.safetyBubble.strength) },
                            set: { cache.safetyBubble.strength = UISettingsCache.blendSliderToValue($0) }
                        ), range: 0.0...1.0,
                        enabled: .constant(true),
                        onChanged: { cache.push(\.safetyBubbleBlend, value: cache.safetyBubble.strength) },
                        showToggle: false)
                    Text("Controls how strongly the bubble masks fractal geometry. Fine control at low values.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
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
                    let euler = eulerAngles(from: cache.liveWorldRotation)
                    Text(String(format: "%.0f° %.0f° %.0f°", euler.x, euler.y, euler.z))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                EffectSliderRow(icon: "arrow.left.and.right", label: "Pitch",
                    value: Binding(
                        get: { eulerAngles(from: cache.liveWorldRotation).x },
                        set: { newValue in
                            var e = eulerAngles(from: cache.liveWorldRotation)
                            e.x = newValue
                            setDetailRotationEuler(e)
                        }
                    ), range: -180...180,
                    enabled: .constant(true),
                    onChanged: {},
                    showToggle: false)

                EffectSliderRow(icon: "arrow.clockwise", label: "Yaw",
                    value: Binding(
                        get: { eulerAngles(from: cache.liveWorldRotation).y },
                        set: { newValue in
                            var e = eulerAngles(from: cache.liveWorldRotation)
                            e.y = newValue
                            setDetailRotationEuler(e)
                        }
                    ), range: -180...180,
                    enabled: .constant(true),
                    onChanged: {},
                    showToggle: false)

                EffectSliderRow(icon: "arrow.up.and.down", label: "Roll",
                    value: Binding(
                        get: { eulerAngles(from: cache.liveWorldRotation).z },
                        set: { newValue in
                            var e = eulerAngles(from: cache.liveWorldRotation)
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
            Text("Quality Presets").font(.headline)
            HStack(spacing: 8) {
                ForEach(QualityPreset.allCases, id: \.rawValue) { preset in
                    Button {
                        cache.quality.baseFractalIterations = preset.fractalIterations
                        cache.quality.baseMaxRaySteps = preset.raySteps
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
                    .tint(QualityPreset.detect(fractalIterations: cache.quality.baseFractalIterations, raySteps: cache.quality.baseMaxRaySteps) == preset ? .blue : .secondary)
                }
            }
            Divider()
            Toggle("Dynamic Render Quality", isOn: $cache.quality.dynamicRenderQualityEnabled)
                .onChange(of: cache.quality.dynamicRenderQualityEnabled) { _, v in cache.push(\.dynamicRenderQualityEnabled, value: v) }
            if cache.quality.dynamicRenderQualityEnabled {
                qualityIndicator
                HStack {
                    Text("Min Quality:").font(.caption)
                    Slider(value: $cache.quality.dynamicRenderQualityMin, in: 0.4...0.8, onEditingChanged: { e in if !e { cache.push(\.dynamicRenderQualityMin, value: cache.quality.dynamicRenderQualityMin) } })
                    Text("\(Int(cache.quality.dynamicRenderQualityMin * 100))%").font(.caption.monospacedDigit()).frame(width: 40, alignment: .trailing)
                }
                HStack {
                    Text("Max Quality:").font(.caption)
                    Slider(value: $cache.quality.dynamicRenderQualityMax, in: 0.8...1.0, onEditingChanged: { e in if !e { cache.push(\.dynamicRenderQualityMax, value: cache.quality.dynamicRenderQualityMax) } })
                    Text("\(Int(cache.quality.dynamicRenderQualityMax * 100))%").font(.caption.monospacedDigit()).frame(width: 40, alignment: .trailing)
                }
            }
        }
    }
    
    private func qualityColor(_ quality: Float) -> Color {
        if quality >= 0.8 { return .green } else if quality >= 0.6 { return .yellow } else { return .orange }
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

    /// Picker row for assigning a gesture binding to a hand+finger slot.
    @ViewBuilder
    private func gestureSlotPicker(slot: GestureSlot, handMode: GestureHandMode) -> some View {
        let bindings = GestureActionBinding.availableBindings(for: cache.fractalType, handMode: handMode)
        let currentBinding = Binding<GestureActionBinding>(
            get: { cache.gestureBinding(for: slot) },
            set: { cache.setGestureBinding($0, for: slot) }
        )
        HStack {
            Label(slot.finger.displayName, systemImage: slot.finger.icon).font(.subheadline)
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

    private var qualityIndicator: some View {
        HStack {
            Text("Current Quality:").font(.caption); Spacer()
            Text("\(Int(cache.currentRenderQuality * 100))%").font(.caption.monospacedDigit()).foregroundStyle(qualityColor(cache.currentRenderQuality))
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(Color.gray.opacity(0.3))
                    .frame(width: 60, height: 8)
                RoundedRectangle(cornerRadius: 2).fill(qualityColor(cache.currentRenderQuality))
                    .frame(width: 60 * CGFloat(cache.currentRenderQuality), height: 8)
            }
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
            animateToolbar
            animatePlayContent
        }
    }

    private var animateToolbar: some View {
        HStack(spacing: 12) {
            if let animationManager = appModel.animationManager {
                Button {
                    guard let scene = animationManager.currentScene ?? animationManager.scenes.first else { return }
                    animationManager.currentScene = scene
                    animationManager.play()
                } label: {
                    Label("Play", systemImage: "play.fill")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderedProminent)
                .disabled(animationManager.scenes.isEmpty)

                Button {
                    openAnimationEditor()
                } label: {
                    Label("Edit Scenes", systemImage: "pencil.and.list.clipboard")
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .buttonStyle(.bordered)
            }
        }
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
                                onEdit: {
                                    openAnimationEditor(for: scene)
                                },
                                onPlay: { animationManager.currentScene = scene; animationManager.play() }
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
                    Button { cache.applyGradientPreset(preset) } label: {
                        VStack(spacing: 2) {
                            Image(systemName: preset.icon).font(.caption)
                            Text(preset.displayName).font(.caption2).lineLimit(1)
                        }.frame(maxWidth: .infinity).padding(.vertical, 4)
                    }
                    .buttonStyle(.bordered).tint(cache.color.gradientState.gradientPreset == preset ? .blue : .secondary)
                }
            }
            
            // ── Saved Custom Gradients ──
            if !cache.gradientLibrary.savedCustomGradients.isEmpty {
                HStack {
                    Text("Saved").font(.subheadline).foregroundColor(.secondary)
                    Spacer()
                    Text("\(cache.gradientLibrary.savedCustomGradients.count)").font(.caption2).foregroundStyle(.tertiary)
                }
                .padding(.top, 4)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                    ForEach(Array(cache.gradientLibrary.savedCustomGradients.enumerated()), id: \.element.id) { index, saved in
                        let isActive = cache.color.gradientState.gradientPreset == nil && cache.color.gradientState.gradient.id == saved.id
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
            
            // ── Lighting Presets (collapsible) ──
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
                        }.padding(.horizontal, 4)
                    }
                    if cache.lighting.lightingPreset != .custom {
                        Text(cache.lighting.lightingPreset.description).font(.caption).foregroundStyle(.secondary)
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
                    case .advanced:    settingsAdvancedContent
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
                Toggle("Show Music Shortcuts", isOn: $cache.display.showMusicShortcuts)
                    .onChange(of: cache.display.showMusicShortcuts) { _, v in cache.push(\.showMusicShortcuts, value: v) }
                if cache.display.showMusicShortcuts {
                    Text("Shows music reactivity controls in the parameter sensitivity panel.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.blue.opacity(0.06)))

            // Gesture section
            VStack(spacing: 8) {
                HStack {
                    Label("Gesture Controls", systemImage: "hand.draw").font(.headline)
                    Spacer()
                }

                HandTrackingStatusView()
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
                        VStack(alignment: .leading, spacing: 4) {
                            Label(mode.displayName, systemImage: mode.icon)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.top, 4)
                            ForEach(FingerDigit.allCases, id: \.self) { finger in
                                let slot = GestureSlot(hand: mode, finger: finger)
                                gestureSlotPicker(slot: slot, handMode: mode)
                            }
                        }
                    }
                }

                Divider().padding(.vertical, 2)

                Group {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Core Behavior", systemImage: "slider.horizontal.3")
                            .font(.subheadline.weight(.semibold))

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
        // Use cache.liveFPS for the settings panel to avoid @Observable invalidation from appModel.fps
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
            VStack(alignment: .leading, spacing: 12) {
                HStack { Image(systemName: "slider.horizontal.3").foregroundStyle(themeColor); Text("Quality Constraints").font(.headline) }
                VStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack { Text("Fractal Iterations"); Spacer(); Text("\(cache.quality.baseFractalIterations)").fontWeight(.bold).monospacedDigit() }
                        Slider(value: Binding(
                            get: { Float(cache.quality.baseFractalIterations) },
                            set: { cache.quality.baseFractalIterations = Int($0); cache.push(\.baseFractalIterations, value: Int($0)) }
                        ), in: 4...32, step: 1)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack { Text("Max Ray Steps"); Spacer(); Text("\(cache.quality.baseMaxRaySteps)").fontWeight(.bold).monospacedDigit() }
                        Slider(value: Binding(
                            get: { Float(cache.quality.baseMaxRaySteps) },
                            set: { cache.quality.baseMaxRaySteps = Int($0); cache.push(\.baseMaxRaySteps, value: Int($0)) }
                        ), in: 32...1024, step: 16)
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        HStack { Text("Quality Floor (Min)"); Spacer(); Text(String(format: "%.0f%%", cache.quality.dynamicRenderQualityMin * 100)).fontWeight(.bold) }
                        Slider(value: $cache.quality.dynamicRenderQualityMin, in: 0.1...0.8, step: 0.05, onEditingChanged: { e in
                            if !e { cache.push(\.dynamicRenderQualityMin, value: cache.quality.dynamicRenderQualityMin) }
                        })
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack { Text("Quality Ceiling (Max)"); Spacer(); Text(String(format: "%.0f%%", cache.quality.dynamicRenderQualityMax * 100)).fontWeight(.bold) }
                        Slider(value: $cache.quality.dynamicRenderQualityMax, in: 0.8...1.0, step: 0.05, onEditingChanged: { e in
                            if !e { cache.push(\.dynamicRenderQualityMax, value: cache.quality.dynamicRenderQualityMax) }
                        })
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
    let onHoldSave: () -> Void

    @State private var isPressing = false
    @State private var holdProgress: CGFloat = 0
    @State private var holdTask: Task<Void, Never>?
    @State private var justSaved = false
    @State private var holdCompleted = false

    private let holdDuration: TimeInterval = 3.0

    private var countdownValue: Int {
        max(1, Int(ceil((1.0 - holdProgress) * holdDuration)))
    }

    var body: some View {
        ZStack {
            Capsule()
                .fill(justSaved ? Color.green.opacity(0.16) : Color.orange.opacity(0.12))

            GeometryReader { geo in
                Capsule()
                    .fill((justSaved ? Color.green : Color.orange).opacity(0.28))
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
                        .stroke(justSaved ? Color.green : Color.orange,
                                style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 18, height: 18)

                    Image(systemName: justSaved ? "checkmark" : "arrow.counterclockwise")
                        .font(.system(size: 9, weight: .semibold))
                }

                Text(justSaved ? "Saved Reset" : (isPressing ? "Hold \(countdownValue)" : "Reset"))
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
                .stroke(justSaved ? Color.green.opacity(0.5) : Color.orange.opacity(0.45), lineWidth: 1)
        )
        .animation(.easeInOut(duration: 0.15), value: holdProgress)
        .animation(.easeInOut(duration: 0.2), value: justSaved)
        .help("Tap to reset. Hold for 3 seconds to save the current settings as this fractal's reset defaults.")
        .onTapGesture {
            guard !isPressing && !justSaved else { return }
            onTapReset()
        }
        .onLongPressGesture(minimumDuration: holdDuration, maximumDistance: 24, pressing: handlePressingChanged) {
            completeHold()
        }
    }

    private func handlePressingChanged(_ pressing: Bool) {
        if pressing {
            justSaved = false
            holdCompleted = false
            isPressing = true
            holdTask?.cancel()
            holdTask = Task { @MainActor in
                let start = Date()
                while !Task.isCancelled {
                    let elapsed = Date().timeIntervalSince(start)
                    holdProgress = min(1.0, elapsed / holdDuration)
                    if elapsed >= holdDuration { break }
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
        onHoldSave()
        justSaved = true

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            justSaved = false
            holdProgress = 0
            isPressing = false
            holdCompleted = false
        }
    }
}

// MARK: - FPS Indicator (isolated to prevent 90Hz invalidation of ContentView)

/// Standalone view that reads `appModel.fps` so the ~90Hz render-loop updates
/// only invalidate this small capsule, not the entire ContentView tree.
private struct FPSIndicatorView: View {
    @Environment(AppModel.self) private var appModel

    private var indicatorColor: Color {
        let fps = appModel.fps
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
            Text("\(appModel.fps, specifier: "%.0f") FPS")
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
