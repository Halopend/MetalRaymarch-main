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
enum AnimateSubTab: String, CaseIterable { case play = "Play", edit = "Edit" }
enum ColoringSubTab: String, CaseIterable { case gradient = "Gradient", mapping = "Mapping", grading = "Grading" }
enum EffectsSubTab: String, CaseIterable { case dynamic = "Dynamic", `static` = "Static" }
enum SettingsSubTab: String, CaseIterable { case general = "General", advanced = "Advanced" }

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - ContentView
// ═══════════════════════════════════════════════════════════════════════════════

struct ContentView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.openWindow) private var openWindow
    
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
#if DEBUG
    @State private var isBenchmarking = false
#endif
    
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
            // Treat gaze-hover as active UI interaction for robust gesture suppression.
            appModel.setMenuHovering(hovering)
        }
        .onAppear { cache.startSync(with: appModel.renderSettings, appModel: appModel) }
        .onDisappear { cache.stopSync() }
    }
    
    // MARK: - Pre-Immersive Layout
    
    private var preImmersiveLayout: some View {
        VStack(spacing: 16) {
            Text("Threshold")
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
            if appModel.runtimeViewMode == .flame {
                FlameRuntimeView()
            } else if appModel.runtimeViewMode == .buddhabrot {
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
                appModel.renderSettings.resetDetailTransform()
                appModel.gestureController?.applyFractalDefaults()
                cache.loadFromSettings()
            } label: {
                Label("Reset", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(.bordered)
            .tint(.orange)
            
            // Render mode switcher
            Menu {
                Button {
                    appModel.runtimeViewMode = .raymarch
                } label: {
                    Label("Fractal Raymarch", systemImage: "cube.fill")
                }
                Button {
                    appModel.runtimeViewMode = .buddhabrot
                } label: {
                    Label("3D Buddhabrot", systemImage: "atom")
                }
            } label: {
                Label(
                    appModel.runtimeViewMode == .buddhabrot ? "Buddhabrot" : "Raymarch",
                    systemImage: appModel.runtimeViewMode == .buddhabrot ? "atom" : "cube.fill"
                )
            }
            .menuStyle(.borderlessButton)
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
                Button {
                    openWindow(id: AppModel.fractalBrowserWindowID)
                } label: {
                    Label("Browser", systemImage: "rectangle.on.rectangle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Picker("Type", selection: $cache.fractalType) {
                    ForEach(FractalModelType.allCases, id: \.self) { type in
                        Label(type.displayName, systemImage: type.icon).tag(type)
                    }
                }
                .pickerStyle(.menu).frame(maxWidth: 180)
                .onChange(of: cache.fractalType) { _, newValue in
                    cache.pushFractalType(newValue, gestureController: appModel.gestureController)
                }
            }

            EffectSliderRow(icon: "waveform.path.ecg", label: "Gesture Smoothing",
                value: $cache.gestureSmoothingFactor, range: 0.0...1.0,
                enabled: .constant(true),
                onChanged: { cache.push(\.gestureSmoothingFactor, value: cache.gestureSmoothingFactor) },
                showToggle: false)

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
            
            // ── Safety Bubble ────────────────────────────────────────────────
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
            Toggle("Halton Jitter TAA", isOn: $cache.haltonJitterEnabled)
                .onChange(of: cache.haltonJitterEnabled) { _, v in cache.push(\.haltonJitterEnabled, value: v) }
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

    /// Picker row for assigning a `FingerGestureAction` to a finger pair.
    @ViewBuilder
    private func fingerActionPicker(
        finger: String,
        icon: String,
        selection: Binding<GestureActionBinding>,
        settingsKeyPath: WritableKeyPath<RenderSettings, GestureActionBinding>
    ) -> some View {
        HStack {
            Label(finger, systemImage: icon).font(.subheadline)
            Spacer()
            Picker(finger, selection: selection) {
                ForEach(GestureActionBinding.availableBindings(for: cache.fractalType), id: \.self) { action in
                    Label(action.contextualDisplayName(for: cache.fractalType), systemImage: action.icon).tag(action)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 220)
            .onChange(of: selection.wrappedValue) { _, v in
                cache.push(settingsKeyPath, value: v)
            }
        }
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
                Divider().padding(.leading, 159)
                EffectSliderRow(icon: "arrow.right", label: "Offset",
                    value: $cache.gradientOffset, range: 0...1,
                    enabled: .constant(true),
                    onChanged: { cache.push(\.gradientOffset, value: cache.gradientOffset) },
                    showToggle: false)
                Divider().padding(.leading, 159)
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
                Divider().padding(.leading, 159)
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
                Divider().padding(.leading, 159)
                EffectSliderRow(icon: "paintpalette.fill", label: "Vibrance",
                    value: $cache.colorSchemeVibrance, range: 0...1.0,
                    enabled: .constant(true),
                    onChanged: { cache.push(\.colorSchemeVibrance, value: cache.colorSchemeVibrance) },
                    showToggle: false)
                Divider().padding(.leading, 159)
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
                Divider().padding(.leading, 159)
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
                Divider().padding(.leading, 159)
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
                            .frame(width: 135, alignment: .leading)
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
                Divider().padding(.leading, 159)
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

            // ── Polar Rotation (fractal-specific) ──
            if cache.fractalType.supports(.polarRotation) {
                VStack(spacing: 4) {
                    EffectSliderRow(icon: "arrow.trianglehead.counterclockwise.rotate.90", label: "Polar Speed",
                        value: Binding(get: { cache.polarRotationEffect.speed }, set: { cache.polarRotationEffect.speed = $0 }),
                        range: 0...1,
                        enabled: Binding(get: { cache.polarRotationEffect.enabled }, set: { cache.polarRotationEffect.enabled = $0 }),
                        onChanged: { cache.push(\.polarRotationEffect, value: cache.polarRotationEffect) })
                    EffectSliderRow(icon: "dial.medium", label: "Polar Amplitude",
                        value: Binding(get: { cache.polarRotationEffect.amplitude }, set: { cache.polarRotationEffect.amplitude = $0 }),
                        range: 0...2,
                        enabled: Binding(get: { cache.polarRotationEffect.enabled }, set: { cache.polarRotationEffect.enabled = $0 }),
                        onChanged: { cache.push(\.polarRotationEffect, value: cache.polarRotationEffect) },
                        showToggle: false)
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

                // Gesture diagnostic status
                HStack(spacing: 6) {
                    Circle()
                        .fill(gestureStatusColor)
                        .frame(width: 8, height: 8)
                    Text(appModel.gestureStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if appModel.leftHandTracked || appModel.rightHandTracked {
                        HStack(spacing: 4) {
                            if appModel.leftHandTracked {
                                Image(systemName: "hand.raised.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.green)
                            }
                            if appModel.rightHandTracked {
                                Image(systemName: "hand.raised.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.green)
                            }
                        }
                    }
                }
                .padding(.vertical, 2)

                Toggle("Enable Hand Gesture Controls", isOn: Binding(
                    get: { appModel.handTrackingEnabled },
                    set: { appModel.handTrackingEnabled = $0 }
                ))

                Group {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Core Behavior", systemImage: "slider.horizontal.3")
                            .font(.subheadline.weight(.semibold))

                    Toggle("Relative Gestures", isOn: $cache.useRelativeGestures)
                        .onChange(of: cache.useRelativeGestures) { _, v in cache.push(\.useRelativeGestures, value: v) }
                    Toggle("Extended Range", isOn: $cache.extendedGestureRange)
                        .onChange(of: cache.extendedGestureRange) { _, v in cache.push(\.extendedGestureRange, value: v) }
                    Toggle("Rotation Auto-Snap", isOn: $cache.rotationAutoSnap)
                        .onChange(of: cache.rotationAutoSnap) { _, v in cache.push(\.rotationAutoSnap, value: v) }

                    EffectSliderRow(icon: "gauge.with.dots.needle.50percent", label: "Global Sensitivity",
                        value: $cache.gestureSensitivity, range: 1...10,
                        enabled: .constant(true),
                        onChanged: { cache.push(\.gestureSensitivity, value: cache.gestureSensitivity) },
                        showToggle: false)

                    EffectSliderRow(icon: "waveform.path.ecg", label: "Gesture Smoothing",
                        value: $cache.gestureSmoothingFactor, range: 0.0...1.0,
                        enabled: .constant(true),
                        onChanged: { cache.push(\.gestureSmoothingFactor, value: cache.gestureSmoothingFactor) },
                        showToggle: false)

                    EffectSliderRow(icon: "move.3d", label: "Translation Sensitivity",
                        value: $cache.translationSensitivity, range: 0.2...3.0,
                        enabled: .constant(true),
                        onChanged: { cache.push(\.translationSensitivity, value: cache.translationSensitivity) },
                        showToggle: false)

                    if cache.rotationAutoSnap {
                        EffectSliderRow(icon: "rotate.3d", label: "Snap Window (°)",
                            value: $cache.rotationSnapWindowDegrees, range: 2...30,
                            enabled: .constant(true),
                            onChanged: { cache.push(\.rotationSnapWindowDegrees, value: cache.rotationSnapWindowDegrees) },
                            showToggle: false)
                    }
                    }

                    Divider().padding(.vertical, 2)

                    // ── Finger → Action Assignments ─────────────────────────────
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Finger Assignments", systemImage: "hand.point.up.braille")
                            .font(.subheadline.weight(.semibold))

                        fingerActionPicker(
                            finger: "Index",
                            icon: "1.circle.fill",
                            selection: $cache.indexFingerBinding,
                            settingsKeyPath: \.indexFingerBinding
                        )
                        fingerActionPicker(
                            finger: "Middle",
                            icon: "2.circle.fill",
                            selection: $cache.middleFingerBinding,
                            settingsKeyPath: \.middleFingerBinding
                        )
                        fingerActionPicker(
                            finger: "Ring",
                            icon: "3.circle.fill",
                            selection: $cache.ringFingerBinding,
                            settingsKeyPath: \.ringFingerBinding
                        )
                        fingerActionPicker(
                            finger: "Pinky",
                            icon: "4.circle.fill",
                            selection: $cache.pinkyFingerBinding,
                            settingsKeyPath: \.pinkyFingerBinding
                        )
                    }

                    Divider().padding(.vertical, 2)

                    VStack(alignment: .leading, spacing: 8) {
                        Label("Menu Toggle", systemImage: "menucard")
                            .font(.subheadline.weight(.semibold))

                    Toggle("Menu Toggle Gesture", isOn: $cache.menuToggleGestureEnabled)
                        .onChange(of: cache.menuToggleGestureEnabled) { _, v in
                            cache.push(\.menuToggleGestureEnabled, value: v)
                        }

                    HStack {
                        Label("Menu Gesture", systemImage: cache.menuToggleGestureMode.icon)
                            .font(.subheadline)
                        Spacer()
                        Picker("Menu Gesture", selection: $cache.menuToggleGestureMode) {
                            ForEach(MenuToggleGestureMode.allCases, id: \.self) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(maxWidth: 220)
                        .disabled(!cache.menuToggleGestureEnabled)
                        .onChange(of: cache.menuToggleGestureMode) { _, v in
                            cache.push(\.menuToggleGestureMode, value: v)
                        }
                    }

                    EffectSliderRow(icon: "hand.tap", label: "Hold Time",
                        value: $cache.menuToggleHoldDuration, range: 0.05...0.6,
                        enabled: .constant(cache.menuToggleGestureEnabled),
                        onChanged: { cache.push(\.menuToggleHoldDuration, value: cache.menuToggleHoldDuration) },
                        showToggle: false)

                    EffectSliderRow(icon: "timer", label: "Cooldown",
                        value: $cache.menuToggleCooldown, range: 0.1...2.5,
                        enabled: .constant(cache.menuToggleGestureEnabled),
                        onChanged: { cache.push(\.menuToggleCooldown, value: cache.menuToggleCooldown) },
                        showToggle: false)

                    EffectSliderRow(icon: "bolt.horizontal", label: "Activate Threshold",
                        value: $cache.menuToggleActivateThreshold, range: 0.2...0.95,
                        enabled: .constant(cache.menuToggleGestureEnabled),
                        onChanged: { cache.push(\.menuToggleActivateThreshold, value: cache.menuToggleActivateThreshold) },
                        showToggle: false)

                    EffectSliderRow(icon: "arrow.down.to.line", label: "Release Threshold",
                        value: $cache.menuToggleReleaseThreshold, range: 0.1...0.9,
                        enabled: .constant(cache.menuToggleGestureEnabled),
                        onChanged: { cache.push(\.menuToggleReleaseThreshold, value: cache.menuToggleReleaseThreshold) },
                        showToggle: false)
                    }

                    Divider().padding(.vertical, 2)

                    VStack(alignment: .leading, spacing: 8) {
                        Label("Two-Hand Gesture Tuning", systemImage: "hands.sparkles")
                            .font(.subheadline.weight(.semibold))

                    EffectSliderRow(icon: "dot.radiowaves.left.and.right", label: "Min Hand Distance",
                        value: $cache.gestureMinHandDistance, range: 0.02...0.25,
                        enabled: .constant(true),
                        onChanged: { cache.push(\.gestureMinHandDistance, value: cache.gestureMinHandDistance) },
                        showToggle: false)

                    EffectSliderRow(icon: "arrow.left.and.right", label: "Max Hand Distance",
                        value: $cache.gestureMaxHandDistance, range: 0.2...1.2,
                        enabled: .constant(true),
                        onChanged: { cache.push(\.gestureMaxHandDistance, value: cache.gestureMaxHandDistance) },
                        showToggle: false)

                    EffectSliderRow(icon: "play.circle", label: "Start Distance Guard",
                        value: $cache.gestureMaxStartHandDistance, range: 0.08...1.0,
                        enabled: .constant(true),
                        onChanged: { cache.push(\.gestureMaxStartHandDistance, value: cache.gestureMaxStartHandDistance) },
                        showToggle: false)

                    EffectSliderRow(icon: "checkmark.circle", label: "Active Distance Guard",
                        value: $cache.gestureMaxActiveHandDistance, range: 0.1...1.5,
                        enabled: .constant(true),
                        onChanged: { cache.push(\.gestureMaxActiveHandDistance, value: cache.gestureMaxActiveHandDistance) },
                        showToggle: false)

                    EffectSliderRow(icon: "hand.draw", label: "Pinch Activate",
                        value: $cache.twoHandPinchActivateThreshold, range: 0.2...0.98,
                        enabled: .constant(true),
                        onChanged: { cache.push(\.twoHandPinchActivateThreshold, value: cache.twoHandPinchActivateThreshold) },
                        showToggle: false)

                    EffectSliderRow(icon: "hand.raised", label: "Pinch Release",
                        value: $cache.twoHandPinchReleaseThreshold, range: 0.1...0.95,
                        enabled: .constant(true),
                        onChanged: { cache.push(\.twoHandPinchReleaseThreshold, value: cache.twoHandPinchReleaseThreshold) },
                        showToggle: false)

                    EffectSliderRow(icon: "hand.point.up.left", label: "Ring Activate",
                        value: $cache.ringPinchActivateThreshold, range: 0.1...0.95,
                        enabled: .constant(true),
                        onChanged: { cache.push(\.ringPinchActivateThreshold, value: cache.ringPinchActivateThreshold) },
                        showToggle: false)

                    EffectSliderRow(icon: "hand.point.up.braille", label: "Ring Release",
                        value: $cache.ringPinchReleaseThreshold, range: 0.05...0.9,
                        enabled: .constant(true),
                        onChanged: { cache.push(\.ringPinchReleaseThreshold, value: cache.ringPinchReleaseThreshold) },
                        showToggle: false)
                    }

                    Text("Gesture Lab: tune menu triggering, pinch hysteresis, and hand-distance mapping for your hands and room setup.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
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
        // Read from cache instead of appModel.renderSettings to avoid lock contention
        switch cache.colorScheme {
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

    /// Color for the gesture status indicator dot
    private var gestureStatusColor: Color {
        let status = appModel.gestureStatus
        if status.hasPrefix("Active:") { return .green }
        if status.hasPrefix("Ready") { return .cyan }
        if status.contains("Suppressed") { return .yellow }
        if status.contains("disabled") || status.contains("not authorized") || status.contains("not running") || status.contains("stopped") || status.contains("failed") {
            return .red
        }
        if status.contains("No hands") { return .orange }
        return .gray
    }
    
    private var fpsColor: Color {
        // Use cache.liveFPS for the settings panel to avoid @Observable invalidation from appModel.fps
        let fps = cache.liveFPS
        if fps >= 85 { return .green }; if fps >= 60 { return .yellow }; return .red
    }
    
    private var settingsAdvancedContent: some View {
        @Bindable var appModel = appModel
        return VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack { Image(systemName: "slider.horizontal.3").foregroundStyle(themeColor); Text("Quality Constraints").font(.headline) }
                VStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack { Text("Fractal Iterations"); Spacer(); Text("\(cache.baseFractalIterations)").fontWeight(.bold).monospacedDigit() }
                        Slider(value: Binding(
                            get: { Float(cache.baseFractalIterations) },
                            set: { cache.baseFractalIterations = Int($0); cache.push(\.baseFractalIterations, value: Int($0)) }
                        ), in: 4...32, step: 1)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack { Text("Max Ray Steps"); Spacer(); Text("\(cache.baseMaxRaySteps)").fontWeight(.bold).monospacedDigit() }
                        Slider(value: Binding(
                            get: { Float(cache.baseMaxRaySteps) },
                            set: { cache.baseMaxRaySteps = Int($0); cache.push(\.baseMaxRaySteps, value: Int($0)) }
                        ), in: 32...1024, step: 16)
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        HStack { Text("Quality Floor (Min)"); Spacer(); Text(String(format: "%.0f%%", cache.dynamicRenderQualityMin * 100)).fontWeight(.bold) }
                        Slider(value: $cache.dynamicRenderQualityMin, in: 0.1...0.8, step: 0.05, onEditingChanged: { e in
                            if !e { cache.push(\.dynamicRenderQualityMin, value: cache.dynamicRenderQualityMin) }
                        })
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack { Text("Quality Ceiling (Max)"); Spacer(); Text(String(format: "%.0f%%", cache.dynamicRenderQualityMax * 100)).fontWeight(.bold) }
                        Slider(value: $cache.dynamicRenderQualityMax, in: 0.8...1.0, step: 0.05, onEditingChanged: { e in
                            if !e { cache.push(\.dynamicRenderQualityMax, value: cache.dynamicRenderQualityMax) }
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
            
            VStack(alignment: .leading, spacing: 8) {
                HStack { Image(systemName: "scope").foregroundStyle(themeColor); Text("Parameter Debug Logs").font(.headline) }
                Toggle("Enable Debug Logs + Metrics", isOn: $appModel.showParameterDebugPanel)

                if appModel.showParameterDebugPanel {
                    Text(appModel.parameterDiagnosticsText())
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
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

#Preview(windowStyle: .automatic) {
    ContentView().environment(AppModel())
}
