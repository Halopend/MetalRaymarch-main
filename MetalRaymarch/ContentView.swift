//
//  ContentView.swift
//  MetalProject
//
//  Created by MU on 18/11/24.
//

import SwiftUI
import RealityKit

// MARK: - Cached UI Settings
// Local state that syncs with RenderSettings periodically to avoid lock contention
@Observable
final class UISettingsCache {
    // Fractal parameters
    var fractalType: FractalType = .mandelbox
    var fractalScale: Float = 2.0
    var targetMinDistance: Float = 0.8
    var targetFoldingLimit: Float = 1.0
    var targetSphereRadius: Float = 0.5
    var fractalIterations: Int = 9
    var maxRaySteps: Int = 64
    
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
    
    // Animation
    var hueCycleSpeed: Float = 0.0
    var pulseSpeed: Float = 0.0
    var pulseAmount: Float = 0.0
    var glowIntensity: Float = 0.0
    var bloomStrength: Float = 0.0
    var fogIntensity: Float = 0.32
    
    // Emissive
    var emissiveEnabled: Bool = false
    var emissivePattern: Int = 0
    var emissiveIntensity: Float = 1.0
    var emissiveThreshold: Float = 0.5
    var emissiveColor: SIMD3<Float> = SIMD3<Float>(0.3, 0.6, 1.0)
    var emissiveSpeed: Float = 1.0
    
    // Lighting - simplified
    var lightingMode: LightingMode = .animated
    
    // Safety & display
    var showHUD: Bool = true
    var safetyBubbleRadius: Float = 1.8
    var safetyBubbleShape: Float = 0.0
    var useRelativeGestures: Bool = true
    var extendedGestureRange: Bool = true
    var gestureSensitivity: Float = 5.0
    
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
        
        // Sync quality indicator at 4Hz (doesn't need to be faster)
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
        // Load BASE values for UI display (these are what user sets)
        fractalIterations = settings.baseFractalIterations
        maxRaySteps = settings.baseMaxRaySteps
        
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
        
        hueCycleSpeed = settings.hueCycleSpeed
        pulseSpeed = settings.pulseSpeed
        pulseAmount = settings.pulseAmount
        glowIntensity = settings.glowIntensity
        bloomStrength = settings.bloomStrength
        fogIntensity = settings.fogIntensity
        
        emissiveEnabled = settings.emissiveEnabled
        emissivePattern = settings.emissivePattern
        emissiveIntensity = settings.emissiveIntensity
        emissiveThreshold = settings.emissiveThreshold
        emissiveColor = settings.emissiveColor
        emissiveSpeed = settings.emissiveSpeed
        
        lightingMode = settings.lightingMode
        
        showHUD = settings.showHUD
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
    
    // Push a single value to settings (called on slider release or toggle change)
    // OPTIMIZATION: @inline hint for simple property forwarding
    @inline(__always)
    func push<T>(_ keyPath: WritableKeyPath<RenderSettings, T>, value: T) {
        settings?[keyPath: keyPath] = value
    }
    
    @MainActor
    func pushFractalType(_ type: FractalType, gestureController: GestureController?) {
        let oldType = settings?.fractalType
        settings?.fractalType = type
        if oldType != type {
            gestureController?.applyFractalDefaults()
            // Reload to get new defaults
            loadFromSettings()
        }
    }
    
    func pushColorScheme(_ scheme: ColorScheme) {
        settings?.transitionToColorScheme(scheme)
        colorScheme = scheme
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var appModel
    
    @State private var speed: Float = 0
    @State private var initialPosition: SIMD3<Float> = .zero
    @State private var cameraMode: Bool = false
    @State private var cache = UISettingsCache()
    @State private var showScenesSheet = false
    
    /// Get parameter ranges for current fractal type
    private var parameterRanges: (minDistance: ClosedRange<Float>, foldingLimit: ClosedRange<Float>, sphereRadius: ClosedRange<Float>) {
        appModel.gestureController?.getParameterRanges() ?? (0.1...5.0, 0.1...13.0, 0.1...2.0)
    }
    
    /// Color for quality indicator based on current quality level
    private func qualityColor(_ quality: Float) -> Color {
        if quality >= 0.8 {
            return .green
        } else if quality >= 0.6 {
            return .yellow
        } else {
            return .orange
        }
    }
    
    /// Color for FPS indicator - green at 90fps, yellow at 60fps, red below 45fps
    private var fpsIndicatorColor: Color {
        let fps = appModel.fps
        if fps >= 85 {
            return .green
        } else if fps >= 60 {
            return .yellow
        } else if fps >= 45 {
            return .orange
        } else {
            return .red
        }
    }

    var body: some View {
        @Bindable var appModel = appModel

        ZStack {
            // Main content
            VStack {
                // Recording indicator at top center
                if let recorder = appModel.parameterRecorder {
                    if recorder.isRecording {
                        RecordingIndicatorView(recorder: recorder)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                            .padding(.top, 8)
                    } else if recorder.isPlaying || recorder.isPaused {
                        PlaybackIndicatorView(recorder: recorder) {
                            recorder.stopPlayback()
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                        .padding(.top, 8)
                    }
                }
                
             
                // Menu content
                menuContent
            }
            .animation(.easeInOut(duration: 0.3), value: appModel.isMenuWindowVisible)
            .animation(.easeInOut(duration: 0.2), value: appModel.parameterRecorder?.isRecording)
            .animation(.easeInOut(duration: 0.2), value: appModel.parameterRecorder?.isPlaying)
        }
        .padding(40)
        .gesture(
            TapGesture(count: 2)
                .onEnded {
                    cameraMode.toggle()
                }
        )
        .gesture(
            DragGesture()
                .onChanged { value in
                    let sensitivityXY: Float = 0.002
                    let sensitivityZ: Float = 0.004
                    if cameraMode {
                        // Dolly camera along Z with drag Y
                        let zDelta = -Float(value.translation.height) * sensitivityZ
                        var newPos = initialPosition
                        newPos.z += zDelta
                        appModel.renderSettings.targetPosition = newPos
                    } else {
                        let delta = SIMD3<Float>(Float(value.translation.width) * sensitivityXY, -Float(value.translation.height) * sensitivityXY, 0)
                        appModel.renderSettings.targetPosition = initialPosition + delta
                    }
                }
                .onEnded { _ in
                    initialPosition = appModel.renderSettings.targetPosition
                }
        )
        .gesture(
            MagnifyGesture()
                .onChanged { value in
                    let sensitivity: Float = 1.0
                    let zDelta = (Float(value.magnification) - 1.0) * sensitivity
                    var newPos = initialPosition
                    newPos.z += zDelta
                    appModel.renderSettings.targetPosition = newPos
                }
                .onEnded { _ in
                    initialPosition = appModel.renderSettings.targetPosition
                }
        )
        // Hide content when menu window is "closed" - window stays but becomes invisible
        // This preserves window position while avoiding the white bar
        .opacity(appModel.isMenuWindowVisible ? 0.7 : 0)
        .allowsHitTesting(appModel.isMenuWindowVisible)
        .glassBackgroundEffect(in: .rect(cornerRadius: 20))
        .opacity(appModel.isMenuWindowVisible ? 0.7 : 0)  // Also hide the glass background
        .onAppear {
            cache.startSync(with: appModel.renderSettings)
            speed = Float(appModel.clock.speed)
        }
        .onDisappear {
            cache.stopSync()
        }
        .sheet(isPresented: $showScenesSheet) {
            if let animationManager = appModel.animationManager {
                SceneListView(animationManager: animationManager, appModel: appModel)
                    .presentationDetents([.large])
            }
        }
    }
    
    // MARK: - Menu Content
    
    private var menuContent: some View {
        VStack {
            VStack(spacing: 10) {
                // Presets button at the top
                HStack {
                    PresetButton(
                        presetManager: appModel.presetManager,
                        settings: appModel.renderSettings,
                        captureScreenshot: { await appModel.captureScreenshot() },
                        onLoadPreset: { preset in
                            // Ensure pipeline is ready before applying preset
                            // This builds the specialized pipeline if not already cached
                            Task {
                                await appModel.preparePipelineHandler?(preset)
                            }
                            preset.apply(to: appModel.renderSettings)
                            // Sync gesture controller to prevent jumps when gestures resume
                            appModel.gestureController?.syncWithSettings()
                        }
                    )
                    
                    // Reset button
                    Button {
                        // Reset position to origin
                        appModel.renderSettings.targetPosition = .zero
                        appModel.renderSettings.position = .zero
                        // Apply default fractal parameters
                        appModel.gestureController?.applyFractalDefaults()
                    } label: {
                        Label("Reset", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.bordered)
                    .help("Reset position to origin and parameters to defaults")
                    
                    // Developer tools button
                    Button {
                        appModel.openDeveloperWindow()
                    } label: {
                        Image(systemName: "hammer.fill")
                    }
                    .buttonStyle(.bordered)
                    .help("Open Developer Tools")
                    
                    // Scenes button
                    Button {
                        showScenesSheet = true
                    } label: {
                        Image(systemName: "film.stack")
                    }
                    .buttonStyle(.bordered)
                    .help("Animation Scenes")
                    
                    Spacer()
                    
                    // FPS display - prominent for debugging
                    if appModel.immersiveSpaceState == .open {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(fpsIndicatorColor)
                                .frame(width: 10, height: 10)
                            Text("\(appModel.fps, specifier: "%.0f") FPS")
                                .font(.headline)
                                .fontWeight(.bold)
                                .monospacedDigit()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(.bottom, 8)
                
                // Render scale control lives in Safety & Render Options.

            }
            .padding(.bottom, 16)

            ToggleImmersiveSpaceButton()
            
            // Animation playback controls (shown when a scene is active)
            if let animationManager = appModel.animationManager,
               animationManager.currentScene != nil {
                AnimationPlaybackControls(animationManager: animationManager)
                    .padding(.top, 8)
            }
            
            if appModel.immersiveSpaceState == .open {
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(spacing: 12) {
                        Divider()

                        // Fractal type picker - use cache
                        Group {
                            Text("Fractal Type")
                                .font(.headline)
                            
                            Picker("Fractal", selection: $cache.fractalType) {
                                Text("Mandelbox").tag(FractalType.mandelbox)
                            }
                            .pickerStyle(.segmented)
                            .onChange(of: cache.fractalType) { _, newValue in
                                cache.pushFractalType(newValue, gestureController: appModel.gestureController)
                            }
                        }

                        // Quality Sliders - Fractal Iterations and Ray Steps
                        Group {
                            HStack {
                                Text("Quality Settings")
                                    .font(.headline)
                                Spacer()
                                Toggle("", isOn: $cache.dynamicRenderQualityEnabled)
                                    .labelsHidden()
                                    .scaleEffect(0.8)
                            }
                            
                            // Fractal Iterations slider
                            Text("Iterations: \(cache.baseFractalIterations)")
                            Slider(
                                value: Binding(
                                    get: { Double(cache.baseFractalIterations) },
                                    set: { cache.baseFractalIterations = Int($0) }
                                ),
                                in: 4...32,
                                step: 1,
                                onEditingChanged: { editing in
                                    if !editing {
                                        cache.push(\.baseFractalIterations, value: cache.baseFractalIterations)
                                        appModel.preparePipeline(iterations: cache.baseFractalIterations, raySteps: cache.baseMaxRaySteps)
                                    }
                                }
                            )
                            
                            // Ray March Steps slider
                            Text("Max Steps: \(cache.baseMaxRaySteps)")
                            Slider(
                                value: Binding(
                                    get: { Double(cache.baseMaxRaySteps) },
                                    set: { cache.baseMaxRaySteps = Int($0) }
                                ),
                                in: 32...1024,
                                step: 16,
                                onEditingChanged: { editing in
                                    if !editing {
                                        cache.push(\.baseMaxRaySteps, value: cache.baseMaxRaySteps)
                                        appModel.preparePipeline(iterations: cache.baseFractalIterations, raySteps: cache.baseMaxRaySteps)
                                    }
                                }
                            )
                            
                            if !cache.dynamicRenderQualityEnabled {
                                Text("Dynamic scaling is disabled. These values are fixed.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        // Primary Parameter: Fractal Scale - push on editing end
                        Text("Fractal Scale (\(String(format: "%.2f", cache.fractalScale)))")
                        Slider(value: $cache.fractalScale, in: 1.0...5.0, onEditingChanged: { editing in
                            if !editing { cache.push(\.fractalScale, value: cache.fractalScale) }
                        })

                        // Shape Parameters Group - use cache with push on editing end
                        DisclosureGroup("Shape Parameters") {
                            VStack(spacing: 8) {
                                Text("Min Distance (\(String(format: "%.2f", cache.targetMinDistance)))")
                                Slider(value: $cache.targetMinDistance, in: parameterRanges.minDistance, onEditingChanged: { editing in
                                    if !editing {
                                        cache.push(\.targetMinDistance, value: cache.targetMinDistance)
                                    }
                                })

                                Text("Box Folding Limit (\(String(format: "%.2f", cache.targetFoldingLimit)))")
                                Slider(value: $cache.targetFoldingLimit, in: parameterRanges.foldingLimit, onEditingChanged: { editing in
                                    if !editing {
                                        cache.push(\.targetFoldingLimit, value: cache.targetFoldingLimit)
                                    }
                                })

                                Text("Sphere Radius (\(String(format: "%.2f", cache.targetSphereRadius)))")
                                Slider(value: $cache.targetSphereRadius, in: parameterRanges.sphereRadius, onEditingChanged: { editing in
                                    if !editing {
                                        cache.push(\.targetSphereRadius, value: cache.targetSphereRadius)
                                    }
                                })
                            }
                            .padding(.leading, 10)
                        }

                        // Color & Effects Group - simplified
                        DisclosureGroup("Color & Effects") {
                            VStack(spacing: 8) {
                                // Color scheme picker
                                Text("Color Scheme").font(.headline)
                                
                                // Standard schemes
                                Text("Standard").font(.subheadline).foregroundColor(.secondary)
                                LazyVGrid(columns: [
                                    GridItem(.flexible()),
                                    GridItem(.flexible()),
                                    GridItem(.flexible()),
                                    GridItem(.flexible())
                                ], spacing: 8) {
                                    ForEach(ColorScheme.allCases.filter { !$0.isNeonMode }, id: \.rawValue) { scheme in
                                        Button {
                                            cache.pushColorScheme(scheme)
                                        } label: {
                                            VStack(spacing: 4) {
                                                Image(systemName: scheme.icon)
                                                    .font(.title2)
                                                Text(scheme.displayName)
                                                    .font(.caption2)
                                            }
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 8)
                                        }
                                        .buttonStyle(.bordered)
                                        .tint(cache.colorScheme == scheme ? .blue : .secondary)
                                    }
                                }
                                
                                // Neon schemes
                                Text("Neon").font(.subheadline).foregroundColor(.pink)
                                LazyVGrid(columns: [
                                    GridItem(.flexible()),
                                    GridItem(.flexible()),
                                    GridItem(.flexible())
                                ], spacing: 8) {
                                    ForEach(ColorScheme.allCases.filter { $0.isNeonMode }, id: \.rawValue) { scheme in
                                        Button {
                                            cache.pushColorScheme(scheme)
                                        } label: {
                                            VStack(spacing: 4) {
                                                Image(systemName: scheme.icon)
                                                    .font(.title2)
                                                Text(scheme.displayName)
                                                    .font(.caption2)
                                            }
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 8)
                                        }
                                        .buttonStyle(.bordered)
                                        .tint(cache.colorScheme == scheme ? .pink : .purple)
                                    }
                                }
                                
                                Divider()
                                
                                // Auto-transition toggle
                                Toggle("Auto-Cycle Schemes", isOn: $cache.colorSchemeAutoTransition)
                                    .onChange(of: cache.colorSchemeAutoTransition) { _, newValue in
                                        cache.push(\.colorSchemeAutoTransition, value: newValue)
                                    }
                                
                                if cache.colorSchemeAutoTransition {
                                    Text("Cycle Interval: \(cache.colorSchemeAutoInterval, specifier: "%.0f")s")
                                    Slider(value: $cache.colorSchemeAutoInterval, in: 5...120, onEditingChanged: { editing in
                                        if !editing { cache.push(\.colorSchemeAutoInterval, value: cache.colorSchemeAutoInterval) }
                                    })
                                }
                                
                                Divider()
                                
                                // Contrast control
                                Text("Contrast: \(cache.colorSchemeContrast, specifier: "%.2f")")
                                Slider(value: $cache.colorSchemeContrast, in: 0.95...1.15, onEditingChanged: { editing in
                                    if !editing { cache.push(\.colorSchemeContrast, value: cache.colorSchemeContrast) }
                                })
                                
                                Divider()
                                
                                // Color Grading Group
                                Text("Color Grading Curves").font(.subheadline).foregroundColor(.secondary)
                                
                                Text("Vibrance: \(cache.colorSchemeVibrance, specifier: "%.2f")")
                                Slider(value: $cache.colorSchemeVibrance, in: 0...1.0, onEditingChanged: { editing in
                                    if !editing { cache.push(\.colorSchemeVibrance, value: cache.colorSchemeVibrance) }
                                })
                                
                                Text("Midtone Curve: \(cache.colorSchemeCurve, specifier: "%.2f")")
                                Slider(value: $cache.colorSchemeCurve, in: -1.0...1.0, onEditingChanged: { editing in
                                    if !editing { cache.push(\.colorSchemeCurve, value: cache.colorSchemeCurve) }
                                })
                                
                                Text("Shadows: \(cache.colorSchemeShadows, specifier: "%.3f")")
                                Slider(value: $cache.colorSchemeShadows, in: -0.05...0.05, onEditingChanged: { editing in
                                    if !editing { cache.push(\.colorSchemeShadows, value: cache.colorSchemeShadows) }
                                })
                                
                                Text("Highlights: \(cache.colorSchemeHighlights, specifier: "%.2f")")
                                Slider(value: $cache.colorSchemeHighlights, in: -0.5...1.0, onEditingChanged: { editing in
                                    if !editing { cache.push(\.colorSchemeHighlights, value: cache.colorSchemeHighlights) }
                                })
                                
                                Divider()
                                
                                // === DYNAMIC LIGHTING / ANIMATION ===
                                Text("Lighting Animation").font(.headline)
                                
                                Text("Hue Cycle Speed: \(cache.hueCycleSpeed, specifier: "%.3f")")
                                Slider(value: $cache.hueCycleSpeed, in: 0...0.5, onEditingChanged: { editing in
                                    if !editing { cache.push(\.hueCycleSpeed, value: cache.hueCycleSpeed) }
                                })
                                
                                Text("Pulse Speed: \(cache.pulseSpeed, specifier: "%.2f")")
                                Slider(value: $cache.pulseSpeed, in: 0...2, onEditingChanged: { editing in
                                    if !editing { cache.push(\.pulseSpeed, value: cache.pulseSpeed) }
                                })
                                
                                Text("Pulse Amount: \(cache.pulseAmount, specifier: "%.2f")")
                                Slider(value: $cache.pulseAmount, in: 0...1, onEditingChanged: { editing in
                                    if !editing { cache.push(\.pulseAmount, value: cache.pulseAmount) }
                                })
                                
                                Text("Glow Intensity: \(cache.glowIntensity, specifier: "%.2f")")
                                Slider(value: $cache.glowIntensity, in: 0...1, onEditingChanged: { editing in
                                    if !editing { cache.push(\.glowIntensity, value: cache.glowIntensity) }
                                })
                                
                                Text("Bloom Strength: \(cache.bloomStrength, specifier: "%.2f")")
                                Slider(value: $cache.bloomStrength, in: 0...1, onEditingChanged: { editing in
                                    if !editing { cache.push(\.bloomStrength, value: cache.bloomStrength) }
                                })
                                
                                Text("Fog Intensity: \(cache.fogIntensity, specifier: "%.2f")")
                                Slider(value: $cache.fogIntensity, in: 0...1, onEditingChanged: { editing in
                                    if !editing { cache.push(\.fogIntensity, value: cache.fogIntensity) }
                                })
                                
                                Divider()
                                
                                // === EMISSIVE GLOW ===
                                Text("Emissive Glow").font(.headline)
                                
                                Toggle("Enable Emissive", isOn: $cache.emissiveEnabled)
                                    .onChange(of: cache.emissiveEnabled) { _, newValue in
                                        cache.push(\.emissiveEnabled, value: newValue)
                                    }
                                
                                if cache.emissiveEnabled {
                                    HStack {
                                        Text("Pattern")
                                        Spacer()
                                        Picker("Pattern", selection: $cache.emissivePattern) {
                                            Text("Folds").tag(0)
                                            Text("Depth").tag(1)
                                            Text("Veins").tag(2)
                                            Text("Pulse").tag(3)
                                            Text("Edges").tag(4)
                                        }
                                        .pickerStyle(.segmented)
                                        .frame(maxWidth: 220)
                                        .onChange(of: cache.emissivePattern) { _, newValue in
                                            cache.push(\.emissivePattern, value: newValue)
                                        }
                                    }
                                    
                                    Text("Intensity: \(cache.emissiveIntensity, specifier: "%.2f")")
                                    Slider(value: $cache.emissiveIntensity, in: 0...2, onEditingChanged: { editing in
                                        if !editing { cache.push(\.emissiveIntensity, value: cache.emissiveIntensity) }
                                    })
                                    
                                    Text("Threshold: \(cache.emissiveThreshold, specifier: "%.2f")")
                                    Slider(value: $cache.emissiveThreshold, in: 0...1, onEditingChanged: { editing in
                                        if !editing { cache.push(\.emissiveThreshold, value: cache.emissiveThreshold) }
                                    })
                                    
                                    if cache.emissivePattern == 3 {
                                        Text("Pulse Speed: \(cache.emissiveSpeed, specifier: "%.1f")")
                                        Slider(value: $cache.emissiveSpeed, in: 0.1...5, onEditingChanged: { editing in
                                            if !editing { cache.push(\.emissiveSpeed, value: cache.emissiveSpeed) }
                                        })
                                    }
                                    
                                    // Color wheel picker
                                    EmissiveColorPicker(color: Binding(
                                        get: { 
                                            Color(red: Double(cache.emissiveColor.x), 
                                                  green: Double(cache.emissiveColor.y), 
                                                  blue: Double(cache.emissiveColor.z))
                                        },
                                        set: { newColor in
                                            if let components = newColor.cgColor?.components, components.count >= 3 {
                                                cache.emissiveColor = SIMD3<Float>(Float(components[0]), Float(components[1]), Float(components[2]))
                                                cache.push(\.emissiveColor, value: cache.emissiveColor)
                                            }
                                        }
                                    ))
                                }
                                
                                Divider()
                                
                                // === LIGHTING MODE - Simplified ===
                                HStack {
                                    Text("Lighting")
                                    Spacer()
                                    Picker("Lighting", selection: $cache.lightingMode) {
                                        ForEach(LightingMode.allCases, id: \.rawValue) { mode in
                                            Text(mode.displayName).tag(mode)
                                        }
                                    }
                                    .pickerStyle(.segmented)
                                    .frame(maxWidth: 200)
                                    .onChange(of: cache.lightingMode) { _, newValue in
                                        cache.push(\.lightingMode, value: newValue)
                                    }
                                }
                                
                                // Audio controls only in audio reactive mode
                                if cache.lightingMode == .audioReactive {
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Button {
                                                if appModel.audioAnalyzer.isCapturing {
                                                    appModel.audioAnalyzer.stopCapture()
                                                } else {
                                                    appModel.audioAnalyzer.startCapture()
                                                }
                                            } label: {
                                                Label(
                                                    appModel.audioAnalyzer.isCapturing ? "Stop Mic" : "Start Mic",
                                                    systemImage: appModel.audioAnalyzer.isCapturing ? "mic.fill" : "mic"
                                                )
                                            }
                                            .buttonStyle(.borderedProminent)
                                            .tint(appModel.audioAnalyzer.isCapturing ? .red : .purple)
                                            
                                            Spacer()
                                            
                                            if appModel.audioAnalyzer.isCapturing {
                                                HStack(spacing: 2) {
                                                    ForEach(0..<10, id: \.self) { i in
                                                        Rectangle()
                                                            .fill(Float(i) / 10.0 < appModel.audioAnalyzer.level ? Color.green : Color.gray.opacity(0.3))
                                                            .frame(width: 4, height: 16)
                                                    }
                                                }
                                            }
                                        }
                                        
                                        if let error = appModel.audioAnalyzer.errorMessage {
                                            Text(error)
                                                .font(.caption)
                                                .foregroundStyle(.red)
                                        }
                                    }
                                    .padding(.vertical, 4)
                                }

                                Text("Color Mix")
                                Slider(value: $cache.colorMix, in: 0...1.0, onEditingChanged: { editing in
                                    if !editing { cache.push(\.colorMix, value: cache.colorMix) }
                                })

                                Text("Color Iterations: \(cache.colorIterations, specifier: "%.0f")")
                                Slider(value: $cache.colorIterations, in: 4...16, step: 1, onEditingChanged: { editing in
                                    if !editing { cache.push(\.colorIterations, value: cache.colorIterations) }
                                })
                            }
                            .padding(.leading, 10)
                        }

                        // Safety & Options Group
                        DisclosureGroup("Safety & Options") {
                            VStack(spacing: 8) {
                                Toggle("Show HUD", isOn: $cache.showHUD)
                                    .onChange(of: cache.showHUD) { _, newValue in
                                        cache.push(\.showHUD, value: newValue)
                                    }

                                Text("Safety Bubble Radius: \(cache.safetyBubbleRadius, specifier: "%.2f")m")
                                Slider(value: $cache.safetyBubbleRadius, in: 0.5...2.5, onEditingChanged: { editing in
                                    if !editing { cache.push(\.safetyBubbleRadius, value: cache.safetyBubbleRadius) }
                                })

                                Text("Bubble Shape: \(cache.safetyBubbleShape < 0.33 ? "Sphere" : (cache.safetyBubbleShape > 0.66 ? "Cube" : "Blend"))")
                                Slider(value: $cache.safetyBubbleShape, in: 0...1, onEditingChanged: { editing in
                                    if !editing { cache.push(\.safetyBubbleShape, value: cache.safetyBubbleShape) }
                                })
                                
                                Divider()
                                
                                Toggle("Relative Gestures", isOn: $cache.useRelativeGestures)
                                    .onChange(of: cache.useRelativeGestures) { _, newValue in
                                        cache.push(\.useRelativeGestures, value: newValue)
                                    }
                                    .help("Relative: fine-tune from current value. Absolute: hand distance maps directly to range.")
                                
                                Toggle("Extended Range", isOn: $cache.extendedGestureRange)
                                    .onChange(of: cache.extendedGestureRange) { _, newValue in
                                        cache.push(\.extendedGestureRange, value: newValue)
                                    }
                                    .help("Allow wider parameter ranges for gesture controls.")
                                
                                Text("Gesture Sensitivity: \(Int(cache.gestureSensitivity))")
                                Slider(value: $cache.gestureSensitivity, in: 1...10, step: 1, onEditingChanged: { editing in
                                    if !editing { cache.push(\.gestureSensitivity, value: cache.gestureSensitivity) }
                                })
                                .help("1 = 10x slower, 10 = normal speed")
                                
                                Divider()
                                
                                // === DYNAMIC RENDER QUALITY ===
                                Toggle("Dynamic Render Quality", isOn: $cache.dynamicRenderQualityEnabled)
                                    .onChange(of: cache.dynamicRenderQualityEnabled) { _, newValue in
                                        cache.push(\.dynamicRenderQualityEnabled, value: newValue)
                                    }
                                    .help("Automatically adjust render quality to maintain frame rate")
                                
                                if cache.dynamicRenderQualityEnabled {
                                    // Current quality indicator (reads from cache, synced at 4Hz)
                                    HStack {
                                        Text("Current Quality:")
                                            .font(.caption)
                                        Spacer()
                                        Text("\(Int(cache.currentRenderQuality * 100))%")
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(qualityColor(cache.currentRenderQuality))
                                        
                                        GeometryReader { geo in
                                            ZStack(alignment: .leading) {
                                                RoundedRectangle(cornerRadius: 2)
                                                    .fill(Color.gray.opacity(0.3))
                                                RoundedRectangle(cornerRadius: 2)
                                                    .fill(qualityColor(cache.currentRenderQuality))
                                                    .frame(width: geo.size.width * CGFloat(cache.currentRenderQuality))
                                            }
                                        }
                                        .frame(width: 60, height: 8)
                                    }
                                    
                                    // Show effective parameters being used
                                    HStack {
                                        Text("Effective:")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                        let effectiveIters = Int(Float(cache.fractalIterations) * (0.6 + 0.4 * cache.currentRenderQuality))
                                        let effectiveSteps = Int(Float(cache.maxRaySteps) * (0.5 + 0.5 * cache.currentRenderQuality))
                                        Text("FI: \(effectiveIters) RS: \(effectiveSteps)")
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                    
                                    // Min/Max quality range
                                    VStack(spacing: 4) {
                                        HStack {
                                            Text("Min Quality:")
                                                .font(.caption)
                                            Slider(value: $cache.dynamicRenderQualityMin, in: 0.4...0.8, onEditingChanged: { editing in
                                                if !editing { cache.push(\.dynamicRenderQualityMin, value: cache.dynamicRenderQualityMin) }
                                            })
                                            Text("\(Int(cache.dynamicRenderQualityMin * 100))%")
                                                .font(.caption.monospacedDigit())
                                                .frame(width: 40, alignment: .trailing)
                                        }
                                        
                                        HStack {
                                            Text("Max Quality:")
                                                .font(.caption)
                                            Slider(value: $cache.dynamicRenderQualityMax, in: 0.8...1.0, onEditingChanged: { editing in
                                                if !editing { cache.push(\.dynamicRenderQualityMax, value: cache.dynamicRenderQualityMax) }
                                            })
                                            Text("\(Int(cache.dynamicRenderQualityMax * 100))%")
                                                .font(.caption.monospacedDigit())
                                                .frame(width: 40, alignment: .trailing)
                                        }
                                    }
                                }
                            }
                            .padding(.leading, 10)
                        }

                        // Gesture hints
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Gesture Controls:")
                                .font(.caption)
                                .fontWeight(.semibold)
                            Text("✊ Left fist: Start/stop recording")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text("👆 Right middle→palm: Toggle menu")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 8)
                        
                        // Analytics (TestFlight)
                        Divider()
                        HStack {
                            Toggle("Share Usage Analytics", isOn: Binding(
                                get: { UsageAnalytics.shared.analyticsEnabled },
                                set: { UsageAnalytics.shared.analyticsEnabled = $0 }
                            ))
                            .font(.caption)
                        }
                        .help("Help improve the app by sharing anonymous usage statistics")
                    }
                    .padding(.horizontal)
                }
                .frame(height: 550)  // Fixed height for immersive controls - ScrollView handles overflow
            }
        }
    }
}

// MARK: - SharePlay Controls View

struct SharePlayControlsView: View {
    @Bindable var shareSession: FractalShareSession
    var appModel: AppModel
    
    var body: some View {
        VStack(spacing: 8) {
            // Connection status and main action button
            HStack {
                // Status indicator
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 10, height: 10)
                    
                    Text(statusText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                // Main action button
                Button {
                    Task {
                        switch shareSession.state {
                        case .inactive:
                            await shareSession.startSharing()
                        default:
                            shareSession.stopSharing()
                        }
                    }
                } label: {
                    Label(
                        buttonText,
                        systemImage: buttonIcon
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(buttonTint)
            }
            
            // Role picker (only when connected)
            if case .connected = shareSession.state {
                HStack {
                    Text("Role:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    Picker("Role", selection: $shareSession.role) {
                        ForEach(SharePlayRole.allCases, id: \.self) { role in
                            Text(role.rawValue).tag(role)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 220)
                }
                
                // Role explanation
                Text(roleExplanation)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
    
    // MARK: - Computed Properties
    
    private var statusColor: Color {
        switch shareSession.state {
        case .inactive: return .gray
        case .waiting: return .yellow
        case .connected: return .green
        case .error: return .red
        }
    }
    
    private var statusText: String {
        switch shareSession.state {
        case .inactive: return "Not sharing"
        case .waiting: return "Waiting for others..."
        case .connected(let count): return "\(count) connected"
        case .error(let msg): return "Error: \(msg)"
        }
    }
    
    private var buttonText: String {
        switch shareSession.state {
        case .inactive: return "Share via FaceTime"
        default: return "Stop Sharing"
        }
    }
    
    private var buttonIcon: String {
        switch shareSession.state {
        case .inactive: return "shareplay"
        default: return "shareplay.slash"
        }
    }
    
    private var buttonTint: Color {
        switch shareSession.state {
        case .inactive: return .blue
        default: return .red
        }
    }
    
    private var roleExplanation: String {
        switch shareSession.role {
        case .driver:
            return "You control the view. Others follow your perspective."
        case .viewer:
            return "You follow the driver's view. Your inputs are local only."
        case .collaborative:
            return "Everyone can control. Last change wins."
        }
    }
}

// MARK: - Emissive Color Picker
// Compact color wheel for selecting emissive glow color
struct EmissiveColorPicker: View {
    @Binding var color: Color
    
    // Preset emissive colors
    private let presets: [(name: String, color: Color)] = [
        ("Cyan", Color(red: 0.3, green: 0.8, blue: 1.0)),
        ("Pink", Color(red: 1.0, green: 0.3, blue: 0.6)),
        ("Green", Color(red: 0.3, green: 1.0, blue: 0.4)),
        ("Gold", Color(red: 1.0, green: 0.8, blue: 0.2)),
        ("Purple", Color(red: 0.7, green: 0.3, blue: 1.0)),
        ("White", Color(red: 1.0, green: 1.0, blue: 1.0)),
    ]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Emissive Color")
                .font(.subheadline)
            
            // Quick preset buttons
            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 6) {
                ForEach(presets, id: \.name) { preset in
                    Button {
                        color = preset.color
                    } label: {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(preset.color)
                            .frame(height: 32)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(isSelected(preset.color) ? Color.white : Color.clear, lineWidth: 2)
                            )
                            .overlay(
                                Text(preset.name)
                                    .font(.caption2)
                                    .foregroundColor(.white)
                                    .shadow(radius: 2)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            
            // Full color picker for custom colors
            ColorPicker("Custom", selection: $color, supportsOpacity: false)
                .labelsHidden()
        }
    }
    
    private func isSelected(_ presetColor: Color) -> Bool {
        // Compare colors approximately
        guard let c1 = color.cgColor?.components,
              let c2 = presetColor.cgColor?.components,
              c1.count >= 3, c2.count >= 3 else { return false }
        
        let tolerance: CGFloat = 0.05
        return abs(c1[0] - c2[0]) < tolerance &&
               abs(c1[1] - c2[1]) < tolerance &&
               abs(c1[2] - c2[2]) < tolerance
    }
}

#Preview(windowStyle: .automatic) {
    ContentView()
        .environment(AppModel())
}
