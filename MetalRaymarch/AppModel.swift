//
//  AppModel.swift
//  MetalProject
//
//  Created by MU on 18/11/24.
//

import SwiftUI
import ARKit
import os  // For os_unfair_lock - fastest available lock primitive

// Fractal type enum matching ShaderTypes.h
enum FractalModelType: Int32, Codable {
    case mandelbox = 0
    case mandelbulb = 1
    case menger = 2
    case infinity = 3
    case tetrahedron = 4
    case prism = 5
    case sphereProjection = 6
    
    var displayName: String {
        switch self {
        case .mandelbox: return "Mandelbox"
        case .mandelbulb: return "Mandelbulb"
        case .menger: return "Menger"
        case .infinity: return "Infinity"
        case .tetrahedron: return "Tetrahedron"
        case .prism: return "Prism"
        case .sphereProjection: return "Sphere Projection"
        }
    }
}

/// Quality preset that bundles fractal iterations and ray steps.
/// Reduced to 4 presets to minimize pipeline permutations (each preset compiles
/// a specialized shader with baked loop counts).
enum QualityPreset: String, CaseIterable {
    case low = "Low"
    case medium = "Medium"
    case high = "High"
    case ultra = "Ultra"
    
    var fractalIterations: Int {
        switch self {
        case .low: return 6
        case .medium: return 8
        case .high: return 9
        case .ultra: return 12
        }
    }
    
    var raySteps: Int {
        switch self {
        case .low: return 32
        case .medium: return 56
        case .high: return 64
        case .ultra: return 100
        }
    }
    
    var displayName: String { rawValue }
    
    var icon: String {
        switch self {
        case .low: return "hare"
        case .medium: return "gauge.with.dots.needle.33percent"
        case .high: return "gauge.with.dots.needle.67percent"
        case .ultra: return "gauge.with.dots.needle.100percent"
        }
    }
    
    /// Try to detect preset from current settings
    static func detect(fractalIterations: Int, raySteps: Int) -> QualityPreset? {
        for preset in allCases {
            if preset.fractalIterations == fractalIterations && preset.raySteps == raySteps {
                return preset
            }
        }
        return nil
    }
}

@MainActor
@Observable
class AppModel {
    let immersiveSpaceID = "ImmersiveSpace"
    let menuWindowID = "MenuWindow"
    let developerWindowID = "DeveloperWindow"
    let scenesWindowID = "ScenesWindow"
    let colorWindowID = "ColorWindow"
    let effectsWindowID = "EffectsWindow"
    
    enum ImmersiveSpaceState {
        case closed
        case inTransition
        case open
    }
    
    var immersiveSpaceState = ImmersiveSpaceState.closed

    // App activity state (used to avoid submitting GPU work while backgrounded)
    // @ObservationIgnored + nonisolated(unsafe) allows cross-thread access without @Observable macro interference
    @ObservationIgnored nonisolated(unsafe) var isAppActive: Bool = true

    var fps: Double = 0
    
    /// Whether the renderer is currently using a specialized (compiled) pipeline vs generic fallback
    @ObservationIgnored nonisolated(unsafe) var isUsingSpecializedPipeline: Bool = false
    
    nonisolated let renderSettings = RenderSettings()
    
    // Audio analyzer for reactive lighting
    let audioAnalyzer = AudioAnalyzer()
    
    // Hand tracking state
    var handTrackingEnabled: Bool = true
    var leftHandTracked: Bool = false
    var rightHandTracked: Bool = false
    
    // Gesture controller for mapping hand gestures to parameters
    var gestureController: GestureController?
    
    nonisolated let clock = AppClock()
    
    // Preset management
    let presetManager = PresetManager()
    
    // Parameter recording
    var parameterRecorder: ParameterRecorder?
    
    // Animation/Scene playback manager
    var animationManager: AnimationManager?
    
    // Menu window visibility (toggled by gesture)
    // We hide content and glass to simulate window close while preserving position/size
    var isMenuWindowVisible: Bool = true
    
    // Screenshot capture (set by Renderer)
    var captureScreenshotHandler: (() async -> Data?)?
    
    // Pipeline preparation handler (set by Renderer)
    // Called when a preset is about to be loaded to ensure the pipeline is ready
    var preparePipelineHandler: ((FractalPreset) async -> Void)?
    
    // Pipeline preparation for specific iteration/ray step values (set by Renderer)
    // Called when sliders change to pre-compile the needed pipeline
    var preparePipelineForValuesHandler: ((Int, Int) async -> Void)?
    
    /// Prepare the shader pipeline for specific iteration and ray step values
    /// Call this when slider values change to avoid compilation hitches
    func preparePipeline(iterations: Int, raySteps: Int) {
        Task {
            await preparePipelineForValuesHandler?(iterations, raySteps)
        }
    }
    
    // Pipeline profiler trigger (set by Renderer)
    var triggerProfilerHandler: (() -> Void)?
    
    /// Run the pipeline profiler to analyze rendering costs
    func runProfiler() {
        triggerProfilerHandler?()
    }
    
    // SharePlay session for collaborative fractal exploration
    var shareSession: FractalShareSession?
    
    init() {
        // Initialize gesture controller with render settings
        gestureController = GestureController(renderSettings: renderSettings)
        
        // Initialize parameter recorder
        parameterRecorder = ParameterRecorder(renderSettings: renderSettings)
        
        // Initialize animation manager
        animationManager = AnimationManager(renderSettings: renderSettings)
        
        // Wire up animation manager's pipeline preparation callback
        animationManager?.preparePipelineHandler = { [weak self] iterations, raySteps in
            self?.preparePipeline(iterations: iterations, raySteps: raySteps)
        }
        
        // Initialize SharePlay session
        shareSession = FractalShareSession(renderSettings: renderSettings)
        
        // Setup gesture callbacks
        gestureController?.onMenuToggle = { [weak self] in
            print("📋 onMenuToggle callback fired!")
            self?.toggleMenuWindow()
        }
        
        // Add built-in presets if this is first launch
        presetManager.addBuiltInPresetsIfNeeded()
        
        // Restore last state if available
        presetManager.restoreLastState(to: renderSettings)
        
        // Configure SharePlay session listener
        shareSession?.configureGroupSessions()
    }
    
    /// Save current state for restore on next launch
    func saveLastState() {
        presetManager.saveLastState(from: renderSettings)
    }
    
    /// Toggle recording state
    func toggleRecording() {
        guard let recorder = parameterRecorder else { return }
        
        if recorder.isRecording {
            let _ = recorder.stopRecording()
        } else if recorder.isIdle {
            recorder.startRecording()
        }
    }
    
    /// Callback to open the menu window (set by App scene)
    var openMenuWindowHandler: (() -> Void)?
    
    /// Callback to dismiss the menu window (set by App scene)
    var dismissMenuWindowHandler: (() -> Void)?
    
    /// Callback to open the developer window (set by App scene)
    var openDeveloperWindowHandler: (() -> Void)?
    /// Callback to dismiss the developer window (set by App scene)
    var dismissDeveloperWindowHandler: (() -> Void)?
    /// Whether the developer window is currently open
    var isDeveloperWindowVisible = false
    
    /// Callback to open the scenes window (set by App scene)
    var openScenesWindowHandler: (() -> Void)?
    /// Callback to dismiss the scenes window (set by App scene)
    var dismissScenesWindowHandler: (() -> Void)?
    /// Whether the scenes window is currently open
    var isScenesWindowVisible = false
    
    /// Callback to open the color window (set by App scene)
    var openColorWindowHandler: (() -> Void)?
    /// Callback to dismiss the color window (set by App scene)
    var dismissColorWindowHandler: (() -> Void)?
    /// Whether the color window is currently open
    var isColorWindowVisible = false
    
    /// Callback to open the effects window (set by App scene)
    var openEffectsWindowHandler: (() -> Void)?
    /// Callback to dismiss the effects window (set by App scene)
    var dismissEffectsWindowHandler: (() -> Void)?
    /// Whether the effects window is currently open
    var isEffectsWindowVisible = false
    
    /// Toggle the developer tools window
    func toggleDeveloperWindow() {
        if isDeveloperWindowVisible {
            isDeveloperWindowVisible = false
            dismissDeveloperWindowHandler?()
        } else {
            isDeveloperWindowVisible = true
            openDeveloperWindowHandler?()
        }
    }
    
    /// Toggle the scenes window
    func toggleScenesWindow() {
        if isScenesWindowVisible {
            isScenesWindowVisible = false
            dismissScenesWindowHandler?()
        } else {
            isScenesWindowVisible = true
            openScenesWindowHandler?()
        }
    }
    
    /// Toggle the color options window
    func toggleColorWindow() {
        if isColorWindowVisible {
            isColorWindowVisible = false
            dismissColorWindowHandler?()
        } else {
            isColorWindowVisible = true
            openColorWindowHandler?()
        }
    }
    
    /// Toggle the effects window
    func toggleEffectsWindow() {
        if isEffectsWindowVisible {
            isEffectsWindowVisible = false
            dismissEffectsWindowHandler?()
        } else {
            isEffectsWindowVisible = true
            openEffectsWindowHandler?()
        }
    }
    
    /// Toggle menu window visibility — dismisses or opens the window for real
    func toggleMenuWindow() {
        if isMenuWindowVisible {
            isMenuWindowVisible = false
            dismissMenuWindowHandler?()
            print("📋 Menu window dismissed")
        } else {
            isMenuWindowVisible = true
            openMenuWindowHandler?()
            print("📋 Menu window opened")
        }
    }
    
    /// Ensure window content is visible - call when exiting immersive mode or on app launch
    /// Opens the window if it was previously dismissed
    func ensureWindowContentVisible() {
        if !isMenuWindowVisible {
            isMenuWindowVisible = true
            openMenuWindowHandler?()
            print("📋 Menu window restored (re-opened)")
        }
    }
    
    /// Capture a screenshot for preset thumbnails
    func captureScreenshot() async -> Data? {
        return await captureScreenshotHandler?()
    }
    
    /// Update the recorder (call from render loop)
    func updateRecorder(deltaTime: Float) {
        guard let recorder = parameterRecorder else { return }
        
        // Update recording if active
        if recorder.isRecording {
            recorder.update()
        }
        
        // Update playback if active
        if recorder.isPlaying {
            recorder.updatePlayback(deltaTime: deltaTime)
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - Geometry State - Stable Geometry Rendering
// ═══════════════════════════════════════════════════════════════════════════════
// Tracks whether geometry parameters (minDistance, foldingLimit, sphereRadius,
// fractalScale) are actively changing or have settled. When stable, the renderer
// can switch to an optimized path with temporal accumulation.
// ═══════════════════════════════════════════════════════════════════════════════

enum GeometryState: Int, CaseIterable {
    case dynamic   = 0  // Geometry parameters are actively changing
    case settling  = 1  // Parameters stopped changing, waiting for confirmation
    case stable    = 2  // Parameters confirmed stable, optimized rendering enabled
}

// Lighting mode controls animated light movement and audio reactivity
enum LightingMode: Int32, CaseIterable, Codable {
    case staticLight = 0    // Lights stay fixed (no wobble, no animation)
    case animated = 1       // Original animated lighting (pulsing, moving spotlight)
    case audioReactive = 2  // Lights respond to audio/music input
    
    var displayName: String {
        switch self {
        case .staticLight: return "Static"
        case .animated: return "Animated"
        case .audioReactive: return "Audio Reactive"
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - Lighting Effects System
// ═══════════════════════════════════════════════════════════════════════════════
// Modular lighting effects that can be toggled on/off independently.
// Each effect is a card in the UI with its own settings.
// Presets bundle effects together for quick looks.
// ═══════════════════════════════════════════════════════════════════════════════

/// Hue rotation effect - rotates colors through YIQ color space
struct HueRotationEffect: Codable {
    var enabled: Bool = false
    var speed: Float = 0.1          // Rotation speed (0-0.5)
    var intensity: Float = 0.5      // Blend amount (0-1), prevents overpowering
    
    static var off: HueRotationEffect {
        HueRotationEffect(enabled: false, speed: 0.0, intensity: 0.0)
    }
    
    static var subtle: HueRotationEffect {
        HueRotationEffect(enabled: true, speed: 0.05, intensity: 0.3)
    }
    
    static var medium: HueRotationEffect {
        HueRotationEffect(enabled: true, speed: 0.1, intensity: 0.5)
    }
    
    static var intense: HueRotationEffect {
        HueRotationEffect(enabled: true, speed: 0.2, intensity: 0.8)
    }
}

/// Pulse effect - rhythmic brightness and saturation variation
struct PulseEffect: Codable {
    var enabled: Bool = false
    var speed: Float = 0.5          // Pulse frequency (0-2)
    var amount: Float = 0.3         // Pulse intensity (0-1)
    
    static var off: PulseEffect {
        PulseEffect(enabled: false, speed: 0.0, amount: 0.0)
    }
    
    static var subtle: PulseEffect {
        PulseEffect(enabled: true, speed: 0.3, amount: 0.15)
    }
    
    static var medium: PulseEffect {
        PulseEffect(enabled: true, speed: 0.5, amount: 0.3)
    }
    
    static var intense: PulseEffect {
        PulseEffect(enabled: true, speed: 1.0, amount: 0.5)
    }
}

/// Glow effect - ray-step based inner glow
struct GlowEffect: Codable {
    var enabled: Bool = false
    var intensity: Float = 0.3      // Glow brightness (0-1)
    
    static var off: GlowEffect {
        GlowEffect(enabled: false, intensity: 0.0)
    }
    
    static var subtle: GlowEffect {
        GlowEffect(enabled: true, intensity: 0.2)
    }
    
    static var medium: GlowEffect {
        GlowEffect(enabled: true, intensity: 0.4)
    }
    
    static var intense: GlowEffect {
        GlowEffect(enabled: true, intensity: 0.7)
    }
}

/// Bloom effect - bright areas bleed
struct BloomEffect: Codable {
    var enabled: Bool = false
    var strength: Float = 0.2       // Bloom intensity (0-1)
    
    static var off: BloomEffect {
        BloomEffect(enabled: false, strength: 0.0)
    }
    
    static var subtle: BloomEffect {
        BloomEffect(enabled: true, strength: 0.15)
    }
    
    static var medium: BloomEffect {
        BloomEffect(enabled: true, strength: 0.3)
    }
    
    static var intense: BloomEffect {
        BloomEffect(enabled: true, strength: 0.5)
    }
}

/// Fog effect - distance-based atmospheric fog
struct FogEffect: Codable {
    var enabled: Bool = true
    var intensity: Float = 0.32     // Fog density (0-1)
    
    static var off: FogEffect {
        FogEffect(enabled: false, intensity: 0.0)
    }
    
    static var subtle: FogEffect {
        FogEffect(enabled: true, intensity: 0.2)
    }
    
    static var medium: FogEffect {
        FogEffect(enabled: true, intensity: 0.35)
    }
    
    static var dense: FogEffect {
        FogEffect(enabled: true, intensity: 0.6)
    }
}

/// Gradient cycle effect - rotates the gradient offset over time so colors loop through the fractal
struct GradientCycleEffect: Codable {
    var enabled: Bool = false
    var speed: Float = 0.1          // Cycle speed (0-1), how fast the gradient rotates
    
    static var off: GradientCycleEffect {
        GradientCycleEffect(enabled: false, speed: 0.0)
    }
    
    static var slow: GradientCycleEffect {
        GradientCycleEffect(enabled: true, speed: 0.05)
    }
    
    static var medium: GradientCycleEffect {
        GradientCycleEffect(enabled: true, speed: 0.15)
    }
    
    static var fast: GradientCycleEffect {
        GradientCycleEffect(enabled: true, speed: 0.4)
    }
}

/// Lighting preset packages - bundles of effects that work well together
enum LightingPreset: String, CaseIterable, Codable {
    case off = "Off"
    case subtle = "Subtle"
    case dynamic = "Dynamic"
    case psychedelic = "Psychedelic"
    case atmospheric = "Atmospheric"
    case custom = "Custom"
    
    var displayName: String { rawValue }
    
    var icon: String {
        switch self {
        case .off: return "moon.zzz"
        case .subtle: return "sun.min"
        case .dynamic: return "sparkle"
        case .psychedelic: return "wand.and.rays"
        case .atmospheric: return "cloud.fog"
        case .custom: return "slider.horizontal.3"
        }
    }
    
    var description: String {
        switch self {
        case .off: return "No lighting effects"
        case .subtle: return "Gentle ambient effects"
        case .dynamic: return "Moderate animation"
        case .psychedelic: return "Maximum visual intensity"
        case .atmospheric: return "Moody fog and glow"
        case .custom: return "Manual control"
        }
    }
    
    /// Get the effect bundle for this preset
    func effects() -> (hue: HueRotationEffect, pulse: PulseEffect, glow: GlowEffect, bloom: BloomEffect, fog: FogEffect, gradientCycle: GradientCycleEffect) {
        switch self {
        case .off:
            return (.off, .off, .off, .off, .off, .off)
            
        case .subtle:
            return (.subtle, .off, .subtle, .subtle, .subtle, .off)
            
        case .dynamic:
            return (.medium, .medium, .medium, .medium, .medium, .slow)
            
        case .psychedelic:
            return (.intense, .intense, .intense, .intense, .medium, .medium)
            
        case .atmospheric:
            return (.off, .subtle, .medium, .subtle, .dense, .off)
            
        case .custom:
            // Return current settings unchanged
            return (.off, .off, .off, .off, .off, .off)
        }
    }
}

// Color scheme enum with built-in presets matching ShaderTypes.h
enum ColorScheme: Int32, CaseIterable, Codable {
    case classic = 0        // Original Mandelbox colors (red/gray/gold)
    case ocean = 1          // Deep blues and teals
    case fire = 2           // Warm oranges and reds
    case forest = 3         // Greens and browns
    case nebula = 4         // Purple/pink cosmic
    case mono = 5           // Grayscale with subtle tints
    case aurora = 6         // Northern lights (greens/blues/purples)
    case volcanic = 7       // Dark with lava accents
    case neonCyber = 8      // Neon cyberpunk (hot pink/cyan/purple)
    case neonSunset = 9     // Neon sunset (orange/magenta/violet)
    case neonMatrix = 10    // Neon matrix (bright greens/black)
    
    var displayName: String {
        switch self {
        case .classic: return "Classic"
        case .ocean: return "Ocean"
        case .fire: return "Fire"
        case .forest: return "Forest"
        case .nebula: return "Nebula"
        case .mono: return "Mono"
        case .aurora: return "Aurora"
        case .volcanic: return "Volcanic"
        case .neonCyber: return "Neon Cyber"
        case .neonSunset: return "Neon Sunset"
        case .neonMatrix: return "Neon Matrix"
        }
    }
    
    var icon: String {
        switch self {
        case .classic: return "paintpalette"
        case .ocean: return "water.waves"
        case .fire: return "flame"
        case .forest: return "leaf"
        case .nebula: return "sparkles"
        case .mono: return "circle.lefthalf.filled"
        case .aurora: return "rainbow"
        case .volcanic: return "mountain.2"
        case .neonCyber: return "bolt.circle.fill"
        case .neonSunset: return "sun.horizon.fill"
        case .neonMatrix: return "chevron.left.forwardslash.chevron.right"
        }
    }
    
    // Returns true if this scheme uses neon HSV mode
    var isNeonMode: Bool {
        switch self {
        case .neonCyber, .neonSunset, .neonMatrix: return true
        default: return false
        }
    }
    
    // Get the color palette for this scheme (col1, col2, col3, altColor1, altMixFactors)
    // VIBRANT palettes - high saturation primary colors for bold, colorful fractals
    var palette: (color1: SIMD3<Float>, color2: SIMD3<Float>, color3: SIMD3<Float>, 
                  altColor1: SIMD3<Float>, altMixFactors: SIMD3<Float>) {
        switch self {
        case .classic:
            // Vibrant red, electric blue, bright gold
            return (SIMD3<Float>(1.0, 0.1, 0.1),    // Bright red
                    SIMD3<Float>(0.2, 0.4, 0.9),    // Electric blue
                    SIMD3<Float>(1.0, 0.8, 0.0),    // Bright gold
                    SIMD3<Float>(0.0, 0.2, 0.8),    // Alt blue
                    SIMD3<Float>(1.0, 1.0, 0.5))    // Alt mix factors
                    
        case .ocean:
            // Electric blues, vibrant teals, bright cyan
            return (SIMD3<Float>(0.0, 0.3, 1.0),    // Electric blue
                    SIMD3<Float>(0.0, 0.9, 0.8),    // Bright teal
                    SIMD3<Float>(0.4, 1.0, 1.0),    // Bright cyan
                    SIMD3<Float>(0.1, 0.5, 1.0),    // Sky blue
                    SIMD3<Float>(0.6, 1.0, 0.3))
                    
        case .fire:
            // Intense oranges, reds, bright yellows
            return (SIMD3<Float>(1.0, 0.2, 0.0),    // Bright red-orange
                    SIMD3<Float>(1.0, 0.6, 0.0),    // Vivid orange
                    SIMD3<Float>(1.0, 1.0, 0.2),    // Bright yellow
                    SIMD3<Float>(0.9, 0.1, 0.0),    // Pure red
                    SIMD3<Float>(1.0, 0.8, 0.5))
                    
        case .forest:
            // Vibrant greens, rich browns, lime accents
            return (SIMD3<Float>(0.1, 0.8, 0.2),    // Bright green
                    SIMD3<Float>(0.6, 0.4, 0.1),    // Rich brown
                    SIMD3<Float>(0.8, 1.0, 0.2),    // Lime green
                    SIMD3<Float>(0.2, 0.6, 0.1),    // Forest green
                    SIMD3<Float>(0.8, 0.9, 0.4))
                    
        case .nebula:
            // Vivid purple, hot pink, electric blue
            return (SIMD3<Float>(0.6, 0.0, 1.0),    // Vivid purple
                    SIMD3<Float>(1.0, 0.2, 0.6),    // Hot pink
                    SIMD3<Float>(0.2, 0.6, 1.0),    // Electric blue
                    SIMD3<Float>(0.8, 0.1, 0.9),    // Magenta
                    SIMD3<Float>(1.0, 1.0, 0.5))
                    
        case .mono:
            // High contrast black and white with blue tint
            return (SIMD3<Float>(0.1, 0.1, 0.15),   // Near black (blue tint)
                    SIMD3<Float>(0.5, 0.5, 0.55),   // Mid gray
                    SIMD3<Float>(1.0, 1.0, 0.95),   // Near white (warm)
                    SIMD3<Float>(0.3, 0.35, 0.4),   // Cool gray
                    SIMD3<Float>(1.0, 1.0, 0.2))
                    
        case .aurora:
            // Neon greens, electric blues, vivid purples
            return (SIMD3<Float>(0.0, 1.0, 0.4),    // Neon green
                    SIMD3<Float>(0.0, 0.6, 1.0),    // Electric blue
                    SIMD3<Float>(0.8, 0.2, 1.0),    // Vivid purple
                    SIMD3<Float>(0.0, 0.9, 0.7),    // Bright teal
                    SIMD3<Float>(0.9, 1.2, 0.6))
                    
        case .volcanic:
            // Deep blacks with bright lava oranges and reds
            return (SIMD3<Float>(0.05, 0.02, 0.02), // Near black
                    SIMD3<Float>(1.0, 0.3, 0.0),    // Bright orange
                    SIMD3<Float>(1.0, 0.8, 0.1),    // Lava yellow
                    SIMD3<Float>(0.8, 0.1, 0.0),    // Deep red
                    SIMD3<Float>(1.5, 0.7, 0.4))
                    
        case .neonCyber:
            // Cyberpunk neon - hot pink, electric cyan, purple
            return (SIMD3<Float>(1.0, 0.0, 0.6),    // Hot pink
                    SIMD3<Float>(0.0, 1.0, 1.0),    // Electric cyan
                    SIMD3<Float>(0.6, 0.0, 1.0),    // Purple
                    SIMD3<Float>(1.0, 0.3, 0.8),    // Magenta
                    SIMD3<Float>(1.0, 1.0, 0.8))
                    
        case .neonSunset:
            // Neon sunset - orange, magenta, violet
            return (SIMD3<Float>(1.0, 0.4, 0.0),    // Neon orange
                    SIMD3<Float>(1.0, 0.0, 0.5),    // Magenta
                    SIMD3<Float>(0.5, 0.0, 1.0),    // Violet
                    SIMD3<Float>(1.0, 0.6, 0.2),    // Light orange
                    SIMD3<Float>(1.2, 0.9, 0.7))
                    
        case .neonMatrix:
            // Matrix green on black
            return (SIMD3<Float>(0.0, 1.0, 0.0),    // Pure neon green
                    SIMD3<Float>(0.0, 0.6, 0.2),    // Dark green
                    SIMD3<Float>(0.5, 1.0, 0.5),    // Light green
                    SIMD3<Float>(0.0, 0.8, 0.3),    // Medium green
                    SIMD3<Float>(0.8, 1.0, 0.6))
        }
    }
    
    // Suggested post-processing for this scheme - BOOSTED saturation values
    var postProcessing: (saturation: Float, contrast: Float, gamma: Float) {
        switch self {
        case .classic:    return (2.0, 1.15, 0.45)   // Boosted saturation
        case .ocean:      return (1.8, 1.12, 0.48)
        case .fire:       return (2.2, 1.2, 0.42)    // Extra vibrant
        case .forest:     return (1.8, 1.1, 0.5)
        case .nebula:     return (2.3, 1.15, 0.42)   // Very saturated
        case .mono:       return (0.6, 1.3, 0.46)    // Low saturation, high contrast
        case .aurora:     return (2.5, 1.15, 0.4)    // Maximum vibrancy
        case .volcanic:   return (2.0, 1.35, 0.38)   // High contrast for drama
        case .neonCyber:  return (2.8, 1.2, 0.38)    // Extreme saturation for neon
        case .neonSunset: return (2.6, 1.25, 0.4)    // Warm neon
        case .neonMatrix: return (3.0, 1.4, 0.35)    // Maximum green intensity
        }
    }
    
    // Neon mode parameters (only used when isNeonMode is true)
    // hueFreq: color variation speed (low=smooth gradients, high=more color zones)
    // hueOffset: shifts which palette color appears at center
    // bandFreq: radial glow rings (0=none, higher=more rings)
    // stripeFreq: (unused in new impl)
    // stripeStrength: (unused in new impl)
    // glowSharpness: how quickly glow falls off (higher=sharper edges)
    // satPower: saturation boost (lower=more saturated)
    var neonParams: (hueFreq: Float, hueOffset: Float, bandFreq: Float, stripeFreq: Float, 
                     stripeStrength: Float, glowSharpness: Float, satPower: Float) {
        switch self {
        case .neonCyber:
            // Hot pink/cyan - smooth gradient, subtle rings, sharp glow
            return (1.5, 0.0, 3.0, 0.0, 0.0, 4.0, 0.2)
        case .neonSunset:
            // Orange/magenta/violet - medium gradient, no rings, softer glow
            return (2.0, 0.33, 0.0, 0.0, 0.0, 2.5, 0.25)
        case .neonMatrix:
            // Pure green tones - tight color (low freq), strong rings, very sharp
            return (0.5, 0.0, 6.0, 0.0, 0.0, 5.0, 0.15)
        default:
            return (1.5, 0.0, 2.0, 0.0, 0.0, 3.0, 0.3)
        }
    }
    
    // Create shader-compatible ColorSchemeParams with new modular lighting effects
    func toShaderParams(colorMix: Float, transitionProgress: Float = 1.0, previousScheme: ColorScheme? = nil,
                        animTime: Float = 0.0, 
                        hueRotation: HueRotationEffect = .off,
                        pulse: PulseEffect = .off,
                        glow: GlowEffect = .off,
                        bloom: BloomEffect = .off,
                        fog: FogEffect = .off) -> ColorSchemeParams {
        let pal = palette
        let pp = postProcessing
        let neon = neonParams
        return ColorSchemeParams(
            color1: pal.color1,
            color2: pal.color2,
            color3: pal.color3,
            altColor1: pal.altColor1,
            altMixFactors: pal.altMixFactors,
            saturation: pp.saturation,
            contrast: pp.contrast,
            gamma: pp.gamma,
            brightness: 0.0,
            vibrance: 1.0,
            colorCurve: 1.0,
            shadows: 1.0,
            highlights: 1.0,
            neonIntensity: isNeonMode ? 1.0 : 0.0,
            hueFrequency: neon.hueFreq,
            hueOffset: neon.hueOffset,
            bandFrequency: neon.bandFreq,
            stripeFrequency: neon.stripeFreq,
            stripeStrength: neon.stripeStrength,
            glowSharpness: neon.glowSharpness,
            saturationPower: neon.satPower,
            // === GRADIENT (legacy path — disabled) ===
            gradientStops: (
                SIMD4<Float>(0,0,0,0), SIMD4<Float>(0,0,0,0), SIMD4<Float>(0,0,0,0), SIMD4<Float>(0,0,0,0),
                SIMD4<Float>(0,0,0,0), SIMD4<Float>(0,0,0,0), SIMD4<Float>(0,0,0,0), SIMD4<Float>(0,0,0,0)
            ),
            gradientStopCount: 0,
            colorMappingMode: 0,
            gradientRepeat: 1.0,
            gradientOffset: 0.0,
            useGradientColoring: 0,
            gradientSmoothing: 1.0,
            _gradPad: (0.0, 0.0),
            // === MODULAR LIGHTING EFFECTS ===
            animTime: animTime,
            hueRotationEnabled: hueRotation.enabled ? 1 : 0,
            hueRotationSpeed: hueRotation.speed,
            hueRotationIntensity: hueRotation.intensity,
            pulseEnabled: pulse.enabled ? 1 : 0,
            pulseSpeed: pulse.speed,
            pulseAmount: pulse.amount,
            glowEnabled: glow.enabled ? 1 : 0,
            glowIntensity: glow.intensity,
            bloomEnabled: bloom.enabled ? 1 : 0,
            bloomStrength: bloom.strength,
            fogEnabled: fog.enabled ? 1 : 0,
            fogIntensity: fog.intensity,
            transitionProgress: transitionProgress,
            previousScheme: previousScheme?.rawValue ?? self.rawValue,
            currentScheme: self.rawValue,
            _padding: 0
        )
    }
}

// RenderSettings uses os_unfair_lock for minimal lock overhead
// This is the fastest synchronization primitive on Apple platforms
// NSLock has ~2-3x more overhead due to Objective-C dispatch
struct RenderSettingsSnapshot {
    let minDistance: Float
    let scale: Float
    let position: SIMD3<Float>
    let fractalScale: Float
    let fractalIterations: Int
    let maxRaySteps: Int
    let colorMix: Float
    let lightingPlay: Bool
    let lightingMode: LightingMode
    let audioLevel: Float
    let foldingLimit: Float
    let sphereRadius: Float
    let colorIterations: Float
    let resolutionScale: Float
    let fractalType: FractalModelType
    let tileSize: Int
    let useHierarchical: Bool
    let debugHierarchical: Bool
    let limitFlash: Float
    let showHUD: Bool
    let activeGestureIndex: Int
    let gestureSpread: Float
    let safetyBubbleEnabled: Bool
    let safetyBubbleRadius: Float
    let safetyBubbleShape: Float
    let sphereProjectionMode: Int  // 0=off, 1=outward, 2=inward, 3=intersection, 4=animated, 5=octree, 6=layered, 7=spiral
    let emissiveEnabled: Bool
    let emissivePattern: Int
    let emissiveIntensity: Float
    let emissiveThreshold: Float
    let emissiveColor: SIMD3<Float>
    let emissiveSpeed: Float
    let colorSchemeParams: ColorSchemeParams
    let lightingSoftness: Float
    
    // ═══════════════════════════════════════════════════════════════════════════
    // DOPPELGANGER MODE
    // Pre-fold reflection that creates an exact structural twin of the fractal
    // ═══════════════════════════════════════════════════════════════════════════
    let doppelgangerEnabled: Bool
    let doppelgangerPlane: SIMD3<Float>   // Mirror plane normal (normalized)
    let doppelgangerOffset: Float         // Signed distance of mirror plane from origin
    
    // ═══════════════════════════════════════════════════════════════════════════
    // GEOMETRY STABILITY STATE
    // When geometry parameters settle, enables optimized "stable geometry" render path
    // ═══════════════════════════════════════════════════════════════════════════
    let geometryState: GeometryState
    let isGeometryGestureActive: Bool
    
    // ═══════════════════════════════════════════════════════════════════════════
    // GMT-FRACTALS OPTIMIZATIONS
    // Step over-relaxation factor for raymarch convergence acceleration
    // ═══════════════════════════════════════════════════════════════════════════
    let stepMultiplier: Float
}

final class RenderSettings: @unchecked Sendable {
    // Shared depth pipeline settings (raymarch + depth output + MetalFX input)
    static let maxViewDistance: Float = 12.0
    static let logDepthScale: Float = 4.0
    static let depthMissValue: Float = 2.0
    // os_unfair_lock is a low-level spinlock - fastest for short critical sections
    private var _lock = os_unfair_lock()
    
    // Inline lock/unlock for zero function call overhead
    @inline(__always)
    private func withLock<T>(_ body: () -> T) -> T {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        return body()
    }
    
    private var _minDistance: Float = 0.8           // 80% of max (1.0) for quality
    private var _scale: Float = 1.0
    private var _position: SIMD3<Float> = SIMD3<Float>(0.1, 0.1, 0.1)
    private var _fractalScale: Float = 2.8
    private var _fractalIterations: Int = 9         // Mid quality default
    private var _maxRaySteps: Int = 64              // Mid quality default
    private var _baseFractalIterations: Int = 9     // User-set base (before dynamic quality adjustment)
    private var _baseMaxRaySteps: Int = 64          // User-set base (before dynamic quality adjustment)
    private var _colorMix: Float = 0.5
    private var _lightingPlay: Bool = false         // Play/pause lighting effects
    private var _lightingMode: LightingMode = .animated  // Static, animated, or audio-reactive
    private var _audioLevel: Float = 0.0            // Current audio level (0-1) for reactive lighting
    private var _foldingLimit: Float = 1.0
    private var _sphereRadius: Float = 0.5
    private var _colorIterations: Float = 8.0       // Lower = faster (was 10)
    private var _resolutionScale: Float = 1.0       // Render scale for MetalFX (1.0 = native)
    
    private var _fractalType: FractalModelType = .mandelbox  // Current fractal type
    private var _preferFoveated: Bool = false        // Legacy flag (no longer mutually exclusive)
    private var _tileSize: Int = 0                   // 0=disabled, 2=2x2, 4=4x4, 8=8x8 adaptive hierarchical
    private var _useHierarchical: Bool = true        // Use hierarchical coarse/fine raymarching
    private var _debugHierarchical: Bool = false     // Visualize adaptive hierarchy levels
    private var _limitFlash: Float = 0.0             // Flash intensity when gesture hits parameter limit (0-1, decays)
    
    // HUD display
    private var _showHUD: Bool = true                // Show in-world HUD (default on)
    private var _activeGestureIndex: Int = 0         // Currently active gesture (0=none, 1=index, 2=middle, 3=ring)
    private var _gestureSpread: Float = 0            // Normalized hand spread (0-1) for debug visualization
    private var _useRelativeGestures: Bool = true    // Use relative gestures (delta-based) instead of absolute mapping
    private var _extendedGestureRange: Bool = true   // Allow extended parameter ranges for gestures
    private var _gestureSensitivity: Float = {
        let stored = UserDefaults.standard.float(forKey: "gestureSensitivity")
        return stored > 0 ? stored : 3.0  // Default 3.0 if never saved
    }()

    // Safety bubble controls
    private var _safetyBubbleEnabled: Bool = true   // Cut out a small safe sphere (default on)
    private var _safetyBubbleRadius: Float = 1.8    // Radius of the safe bubble (meters)
    private var _safetyBubbleShape: Float = 0.0     // 0 = sphere, 1 = cube, intermediate = morph (no rotation)
    
    // Sphere projection mode
    // 0 = off (normal fractal), 1 = outward projection, 2 = inward projection, 
    // 3 = intersection highlight, 4 = animated blend, 5 = reverse octree,
    // 6 = layered depth, 7 = spiral sample
    private var _sphereProjectionMode: Int = 0
    
    // === COLOR SCHEME ===
    // Controls the color palette and post-processing for fractal coloring
    private var _colorScheme: ColorScheme = .nebula      // Current color scheme
    private var _targetColorScheme: ColorScheme = .nebula // Target for transitions
    private var _colorSchemeTransitionProgress: Float = 1.0 // 0 = previous, 1 = current (complete)
    private var _colorSchemeTransitionDuration: Float = 2.0 // Seconds to transition between schemes
    private var _colorSchemeAutoTransition: Bool = false    // Auto-cycle through schemes
    private var _colorSchemeAutoInterval: Float = 30.0      // Seconds between auto-transitions
    private var _colorSchemeAutoTimer: Float = 0.0          // Timer for auto-transitions
    private var _colorSchemeSaturation: Float = 1.5         // Color saturation override
    private var _colorSchemeContrast: Float = 1.02          // Contrast override (subtle)
    private var _colorSchemeGamma: Float = 0.75             // Gamma override (lower = brighter, 1.0 = linear)
    private var _colorSchemeVibrance: Float = 1.0           // Vibrance boost (0-1)
    private var _colorSchemeCurve: Float = 0.0              // Midtone curve adjustment (-1 to 1)
    private var _colorSchemeShadows: Float = 0.0            // Shadow lift/crush (-0.5 to 0.5)
    private var _colorSchemeHighlights: Float = 0.0         // Highlight boost/reduction (-0.5 to 1.0)
    private var _lightingSoftness: Float = 0.0               // 0 = sharp vibrance-driven, 1 = classic soft lighting
    
    // === MODULAR LIGHTING EFFECTS ===
    // Card-based lighting system with presets and individual effect toggles
    private var _colorAnimTime: Float = 0.0                 // Running animation time
    private var _lightingPreset: LightingPreset = .off      // Current preset package
    private var _hueRotationEffect: HueRotationEffect = .off
    private var _pulseEffect: PulseEffect = .off
    private var _glowEffect: GlowEffect = .off
    private var _bloomEffect: BloomEffect = .off
    private var _fogEffect: FogEffect = FogEffect(enabled: true, intensity: 0.32)
    private var _gradientCycleEffect: GradientCycleEffect = .off
    
    // === EMISSIVE GLOW (Self-illuminating regions) ===
    private var _emissiveEnabled: Bool = false              // Enable emissive glow regions
    private var _emissivePattern: Int = 0                   // 0=folds, 1=depth, 2=position, 3=pulse, 4=edges
    private var _emissiveIntensity: Float = 1.0             // Glow brightness (0-2)
    private var _emissiveThreshold: Float = 0.5             // Threshold for triggering glow (0-1)
    private var _emissiveColor: SIMD3<Float> = SIMD3<Float>(0.3, 0.6, 1.0)  // Blue-white default
    private var _emissiveSpeed: Float = 1.0                 // Animation speed for pulse mode
    
    // === DOPPELGANGER MODE ===
    private var _doppelgangerEnabled: Bool = false              // Pre-fold mirror creates structural twin
    private var _doppelgangerPlane: SIMD3<Float> = SIMD3<Float>(1, 0, 0)  // Mirror plane normal (x-axis default)
    private var _doppelgangerOffset: Float = 0.0               // Mirror plane distance from origin
    
    // === GEOMETRY STABILITY STATE ===
    // Tracks whether geometry parameters have settled for optimization
    private var _geometryState: GeometryState = .dynamic
    private var _isGeometryGestureActive: Bool = false
    private var _stableGeometryEnabled: Bool = true          // Enable geometry stability tracking
    private var _geometryStableFrameCount: Int = 0           // Frames since geometry settled
    private let geometrySettleThreshold: Float = 0.001       // Threshold for considering parameters settled
    
    // === GMT-FRACTALS OPTIMIZATIONS ===
    // Step over-relaxation: >1.0 takes larger steps for faster convergence.
    // 1.0 = safe default, 1.2-1.5 during stable geometry, reduced during interaction.
    private var _stepMultiplier: Float = 1.0
    
    // === GRADIENT COLORING SYSTEM ===
    // Replaces hardcoded palettes with user-editable gradient stops.
    private var _gradientState: GradientState = GradientState()
    
    // === DYNAMIC RENDER QUALITY (WWDC25 Session 294) ===
    // Automatically adjusts LayerRenderer.renderQuality based on FPS performance
    private var _dynamicRenderQualityEnabled: Bool = true   // Enable dynamic quality adjustment
    private var _dynamicRenderQualityTarget: Float = 0.7    // Target quality when stable (0.5-1.0)
    private var _dynamicRenderQualityMin: Float = 0.5       // Minimum quality floor (0.4-0.8)
    private var _dynamicRenderQualityMax: Float = 1.0       // Maximum quality ceiling (0.8-1.0)
    private var _currentRenderQuality: Float = 0.7          // Current quality level (read-only from manager)
    
    // === GESTURE TARGET VALUES ===
    // These are set by gestures asynchronously. Renderer interpolates from current to target each frame.
    // This decouples gesture detection (30Hz async) from render smoothing (90Hz sync).
    private var _targetMinDistance: Float = 0.8
    private var _targetFoldingLimit: Float = 1.0
    private var _targetSphereRadius: Float = 0.5
    private var _targetPosition: SIMD3<Float> = SIMD3<Float>(0.1, 0.1, 0.1)
    
    // === ANIMATION BASE + MANUAL OFFSETS ===
    // Animation drives base values. Manual gestures apply offsets when animation is playing.
    private var _isAnimationPlaying: Bool = false
    private var _animationBaseMinDistance: Float = 0.8
    private var _animationBaseFoldingLimit: Float = 1.0
    private var _animationBaseSphereRadius: Float = 0.5
    private var _animationBaseFractalScale: Float = 2.8
    private var _animationBasePosition: SIMD3<Float> = SIMD3<Float>(0.1, 0.1, 0.1)
    private var _manualOffsetMinDistance: Float = 0.0
    private var _manualOffsetFoldingLimit: Float = 0.0
    private var _manualOffsetSphereRadius: Float = 0.0
    private var _manualOffsetFractalScale: Float = 0.0
    private var _manualOffsetPosition: SIMD3<Float> = .zero
    
    // === VELOCITY STATE FOR SMOOTH DAMP ===
    // Track velocities for critically-damped spring interpolation
    private var _velocityMinDistance: Float = 0.0
    private var _velocityFoldingLimit: Float = 0.0
    private var _velocitySphereRadius: Float = 0.0
    private var _velocityPosition: SIMD3<Float> = .zero
    
    // === REFINING PARAMETERS (Polychronakis 2024 / Keinert 2014) ===
    // These control the sphere tracing optimization thresholds
    private var _relaxFactor: Float = 1.6            // Over-relaxation multiplier (1.0-2.0)
    private var _relaxBacktrack: Float = 0.7         // Backtrack factor when overshooting (0.5-1.0)
    private var _sdfScaleCoarse: Float = 1.3         // SDF scaling for coarse pass (1.0-2.0)
    private var _sdfScaleSuperCoarse: Float = 1.5    // SDF scaling for super-coarse pass (1.0-2.5)
    private var _earlyTermRatio: Float = 0.3         // Early termination convergence ratio (0.1-0.5)
    private var _earlyTermCount: Int = 3             // Steps before early termination (1-5)

    var minDistance: Float {
        get { withLock { _minDistance } }
        set { withLock { _minDistance = newValue } }
    }
    
    var scale: Float {
        get { withLock { _scale } }
        set { withLock { _scale = newValue } }
    }
    
    var position: SIMD3<Float> {
        get { withLock { _position } }
        set { withLock { _position = newValue } }
    }
    
    var fractalScale: Float {
        get { withLock { _fractalScale } }
        set { withLock { _fractalScale = newValue } }
    }
    
    /// Current effective fractal iterations (may be adjusted by dynamic quality)
    var fractalIterations: Int {
        get { withLock { _fractalIterations } }
        set { withLock { _fractalIterations = newValue } }
    }
    
    /// Current effective ray steps (may be adjusted by dynamic quality)
    var maxRaySteps: Int {
        get { withLock { _maxRaySteps } }
        set { withLock { _maxRaySteps = newValue } }
    }
    
    /// Base fractal iterations set by user (before dynamic quality adjustment)
    var baseFractalIterations: Int {
        get { withLock { _baseFractalIterations } }
        set { 
            withLock { 
                _baseFractalIterations = newValue
                _fractalIterations = newValue  // Also update current
            } 
        }
    }
    
    /// Base ray steps set by user (before dynamic quality adjustment)
    var baseMaxRaySteps: Int {
        get { withLock { _baseMaxRaySteps } }
        set { 
            withLock { 
                _baseMaxRaySteps = newValue
                _maxRaySteps = newValue  // Also update current
            } 
        }
    }
    
    var colorMix: Float {
        get { withLock { _colorMix } }
        set { withLock { _colorMix = newValue } }
    }

    var lightingPlay: Bool {
        get { withLock { _lightingPlay } }
        set { withLock { _lightingPlay = newValue } }
    }
    
    var lightingMode: LightingMode {
        get { withLock { _lightingMode } }
        set { withLock { _lightingMode = newValue } }
    }
    
    var audioLevel: Float {
        get { withLock { _audioLevel } }
        set { withLock { _audioLevel = max(0.0, min(1.0, newValue)) } }
    }
    
    var foldingLimit: Float {
        get { withLock { _foldingLimit } }
        set { withLock { _foldingLimit = newValue } }
    }
    
    var sphereRadius: Float {
        get { withLock { _sphereRadius } }
        set { withLock { _sphereRadius = newValue } }
    }
    
    var colorIterations: Float {
        get { withLock { _colorIterations } }
        set { withLock { _colorIterations = newValue } }
    }
    
    var resolutionScale: Float {
        get { withLock { _resolutionScale } }
        // Min 0.5 (50%) - below this spatial upscaling quality degrades significantly
        // Max 1.0 (100%) - no upscaling needed
        // Sweet spot is 0.67-0.75 for best quality/performance balance
        set { withLock { _resolutionScale = max(0.5, min(1.0, newValue)) } }
    }
    
    var fractalType: FractalModelType {
        get { withLock { _fractalType } }
        set { withLock { _fractalType = newValue } }
    }

    /// Prefer system foveated rendering over MetalFX upscaling (legacy; now allowed together)
    var preferFoveated: Bool {
        get { withLock { _preferFoveated } }
        set { withLock { _preferFoveated = newValue } }
    }

    // 0 = disabled (standard per-pixel raymarch)
    // 2 = 2x2 tiles (4x overhead reduction, high quality)
    // 4 = 4x4 tiles (16x overhead reduction, performance mode)
    // 8 = 8x8 adaptive hierarchical (3-8x speedup, best performance)
    var tileSize: Int {
        get { withLock { _tileSize } }
        set { withLock { _tileSize = newValue } }
    }
    
    var useHierarchical: Bool {
        get { withLock { _useHierarchical } }
        set { withLock { _useHierarchical = newValue } }
    }
    
    var debugHierarchical: Bool {
        get { withLock { _debugHierarchical } }
        set { withLock { _debugHierarchical = newValue } }
    }
    
    /// Flash intensity for limit feedback (0-1). Set to 1.0 to trigger flash, decays automatically.
    var limitFlash: Float {
        get { withLock { _limitFlash } }
        set { withLock { _limitFlash = newValue } }
    }
    
    /// Decay the limit flash. Call once per frame.
    func updateLimitFlash(deltaTime: Float) {
        withLock {
            if _limitFlash > 0 {
                _limitFlash = max(0, _limitFlash - deltaTime * 4.0) // Fade over ~0.25s
            }
        }
    }
    
    /// Trigger a limit flash
    func triggerLimitFlash() {
        withLock {
            _limitFlash = 1.0
        }
    }
    
    var showHUD: Bool {
        get { withLock { _showHUD } }
        set { withLock { _showHUD = newValue } }
    }
    
    var activeGestureIndex: Int {
        get { withLock { _activeGestureIndex } }
        set { withLock { _activeGestureIndex = newValue } }
    }
    
    var gestureSpread: Float {
        get { withLock { _gestureSpread } }
        set { withLock { _gestureSpread = newValue } }
    }

    var useRelativeGestures: Bool {
        get { withLock { _useRelativeGestures } }
        set { withLock { _useRelativeGestures = newValue } }
    }

    /// Allow extended parameter ranges for gestures (wider min/max values)
    var extendedGestureRange: Bool {
        get { withLock { _extendedGestureRange } }
        set { withLock { _extendedGestureRange = newValue } }
    }

    /// Gesture sensitivity (1-10, where 1 = 10x slower, 10 = normal speed)
    var gestureSensitivity: Float {
        get { withLock { _gestureSensitivity } }
        set {
            let clamped = max(1.0, min(10.0, newValue))
            withLock { _gestureSensitivity = clamped }
            UserDefaults.standard.set(clamped, forKey: "gestureSensitivity")
        }
    }

    /// Enable safety bubble around the camera to prevent clipping into fractal geometry
    var safetyBubbleEnabled: Bool {
        get { withLock { _safetyBubbleEnabled } }
        set { withLock { _safetyBubbleEnabled = newValue } }
    }

    /// Radius of the safety bubble in meters (0.05 - 2.5)
    var safetyBubbleRadius: Float {
        get { withLock { _safetyBubbleRadius } }
        set { withLock { _safetyBubbleRadius = max(0.05, min(2.5, newValue)) } }
    }
    
    /// Shape of the safety bubble (0 = sphere, 1 = cube, intermediate = morph)
    /// Cube does not rotate with view, only translates with position
    var safetyBubbleShape: Float {
        get { withLock { _safetyBubbleShape } }
        set { withLock { _safetyBubbleShape = max(0.0, min(1.0, newValue)) } }
    }
    
    /// Sphere projection mode
    /// 0 = off (normal fractal rendering)
    /// 1 = outward projection (sample fractal from beyond sphere)
    /// 2 = inward projection (sample fractal from center toward surface)
    /// 3 = intersection highlight (rim where fractal meets sphere)
    /// 4 = animated blend (pulsing between sphere and fractal)
    /// 5 = reverse octree (sample from 8 octant directions, blend)
    /// 6 = layered depth (multiple depth samples blended)
    /// 7 = spiral sample (rotating sample position)
    var sphereProjectionMode: Int {
        get { withLock { _sphereProjectionMode } }
        set { withLock { _sphereProjectionMode = max(0, min(7, newValue)) } }
    }
    
    // === COLOR SCHEME SETTINGS ===
    // Controls the color palette and transitions for fractal coloring
    
    /// Current color scheme (or target when transitioning)
    var colorScheme: ColorScheme {
        get { withLock { _colorScheme } }
        set { 
            withLock { 
                if _colorScheme != newValue {
                    _targetColorScheme = newValue
                    _colorSchemeTransitionProgress = 0.0
                }
            } 
        }
    }
    
    /// Previous color scheme (for transitions)
    var previousColorScheme: ColorScheme {
        get { withLock { _colorScheme } }
    }
    
    /// Transition progress (0 = start, 1 = complete)
    var colorSchemeTransitionProgress: Float {
        get { withLock { _colorSchemeTransitionProgress } }
        set { withLock { _colorSchemeTransitionProgress = max(0.0, min(1.0, newValue)) } }
    }
    
    /// Duration of color scheme transitions in seconds
    var colorSchemeTransitionDuration: Float {
        get { withLock { _colorSchemeTransitionDuration } }
        set { withLock { _colorSchemeTransitionDuration = max(0.1, min(10.0, newValue)) } }
    }
    
    /// Enable auto-cycling through color schemes
    var colorSchemeAutoTransition: Bool {
        get { withLock { _colorSchemeAutoTransition } }
        set { withLock { _colorSchemeAutoTransition = newValue } }
    }
    
    /// Seconds between auto-transitions
    var colorSchemeAutoInterval: Float {
        get { withLock { _colorSchemeAutoInterval } }
        set { withLock { _colorSchemeAutoInterval = max(5.0, min(120.0, newValue)) } }
    }
    
    /// Saturation override (independent of scheme default)
    var colorSchemeSaturation: Float {
        get { withLock { _colorSchemeSaturation } }
        set { withLock { _colorSchemeSaturation = max(0.0, min(3.0, newValue)) } }
    }
    
    /// Contrast override
    var colorSchemeContrast: Float {
        get { withLock { _colorSchemeContrast } }
        set { withLock { _colorSchemeContrast = max(0.95, min(1.15, newValue)) } }
    }
    
    /// Gamma override
    var colorSchemeGamma: Float {
        get { withLock { _colorSchemeGamma } }
        set { withLock { _colorSchemeGamma = max(0.2, min(1.0, newValue)) } }
    }
    
    /// Vibrance boost (0-1)
    var colorSchemeVibrance: Float {
        get { withLock { _colorSchemeVibrance } }
        set { withLock { _colorSchemeVibrance = max(0.0, min(1.0, newValue)) } }
    }
    
    /// Lighting softness (0 = sharp vibrance-driven, 1 = classic soft)
    var lightingSoftness: Float {
        get { withLock { _lightingSoftness } }
        set { withLock { _lightingSoftness = max(0.0, min(1.0, newValue)) } }
    }
    
    /// Midtone curve adjustment (-1 to 1)
    var colorSchemeCurve: Float {
        get { withLock { _colorSchemeCurve } }
        set { withLock { _colorSchemeCurve = max(-1.0, min(1.0, newValue)) } }
    }
    
    /// Shadow lift/crush (-0.05 to 0.05)
    var colorSchemeShadows: Float {
        get { withLock { _colorSchemeShadows } }
        set { withLock { _colorSchemeShadows = max(-0.05, min(0.05, newValue)) } }
    }
    
    /// Highlight boost/reduction (-0.5 to 1.0)
    var colorSchemeHighlights: Float {
        get { withLock { _colorSchemeHighlights } }
        set { withLock { _colorSchemeHighlights = max(-0.5, min(1.0, newValue)) } }
    }
    
    // ═══════════════════════════════════════════════════════════════════════════
    // GRADIENT COLORING SYSTEM
    // ═══════════════════════════════════════════════════════════════════════════
    
    /// Whether gradient coloring is enabled (vs legacy 3-color palette)
    var useGradientColoring: Bool {
        get { withLock { _gradientState.useGradientColoring } }
        set { withLock { _gradientState.useGradientColoring = newValue } }
    }
    
    /// Current gradient color map
    var gradientColorMap: GradientColorMap {
        get { withLock { _gradientState.gradient } }
        set { withLock { _gradientState.gradient = newValue; _gradientState.markAsCustom() } }
    }
    
    /// Current gradient preset (nil if custom)
    var gradientPreset: GradientPreset? {
        get { withLock { _gradientState.gradientPreset } }
    }
    
    /// Color mapping mode for gradient sampling
    var colorMappingMode: ColorMappingMode {
        get { withLock { _gradientState.gradient.mappingMode } }
        set { withLock { _gradientState.gradient.mappingMode = newValue } }
    }
    
    /// Gradient repeat count
    var gradientRepeat: Float {
        get { withLock { _gradientState.gradient.repeatCount } }
        set { withLock { _gradientState.gradient.repeatCount = max(0.1, min(10.0, newValue)) } }
    }
    
    /// Gradient offset
    var gradientOffset: Float {
        get { withLock { _gradientState.gradient.offset } }
        set { withLock { _gradientState.gradient.offset = newValue } }
    }
    
    /// Gradient smoothing
    var gradientSmoothing: Float {
        get { withLock { _gradientState.gradient.smoothing } }
        set { withLock { _gradientState.gradient.smoothing = max(0.0, min(1.0, newValue)) } }
    }
    
    /// Apply a gradient preset (replaces current gradient and enables gradient mode)
    func applyGradientPreset(_ preset: GradientPreset) {
        withLock {
            _gradientState.applyPreset(preset)
            _gradientState.useGradientColoring = true
            
            // Also update post-processing to match preset suggestion
            let pp = preset.postProcessing
            _colorSchemeSaturation = pp.saturation
            _colorSchemeContrast = pp.contrast
            _colorSchemeGamma = pp.gamma
            
            // Update neon params if applicable
            if preset.isNeonMode {
                // Neon presets keep neon active through the gradient system
            }
        }
    }
    
    /// Full gradient state (for serialization)
    var gradientState: GradientState {
        get { withLock { _gradientState } }
        set { withLock { _gradientState = newValue } }
    }
    
    // ═══════════════════════════════════════════════════════════════════════════
    // MODULAR LIGHTING EFFECTS - Card-based system with presets
    // ═══════════════════════════════════════════════════════════════════════════
    
    /// Current lighting preset package
    var lightingPreset: LightingPreset {
        get { withLock { _lightingPreset } }
        set {
            withLock {
                _lightingPreset = newValue
                // If not custom, apply the preset's effect bundle
                if newValue != .custom {
                    let effects = newValue.effects()
                    _hueRotationEffect = effects.hue
                    _pulseEffect = effects.pulse
                    _glowEffect = effects.glow
                    _bloomEffect = effects.bloom
                    _fogEffect = effects.fog
                    _gradientCycleEffect = effects.gradientCycle
                }
            }
        }
    }
    
    /// Hue rotation effect (color cycling through YIQ space)
    var hueRotationEffect: HueRotationEffect {
        get { withLock { _hueRotationEffect } }
        set {
            withLock {
                _hueRotationEffect = newValue
                _lightingPreset = .custom  // Switch to custom when manually adjusted
            }
        }
    }
    
    /// Pulse effect (rhythmic brightness and saturation)
    var pulseEffect: PulseEffect {
        get { withLock { _pulseEffect } }
        set {
            withLock {
                _pulseEffect = newValue
                _lightingPreset = .custom
            }
        }
    }
    
    /// Glow effect (ray-step based inner glow)
    var glowEffect: GlowEffect {
        get { withLock { _glowEffect } }
        set {
            withLock {
                _glowEffect = newValue
                _lightingPreset = .custom
            }
        }
    }
    
    /// Bloom effect (bright areas bleed)
    var bloomEffect: BloomEffect {
        get { withLock { _bloomEffect } }
        set {
            withLock {
                _bloomEffect = newValue
                _lightingPreset = .custom
            }
        }
    }
    
    /// Fog effect (distance-based atmospheric haze)
    var fogEffect: FogEffect {
        get { withLock { _fogEffect } }
        set {
            withLock {
                _fogEffect = newValue
                _lightingPreset = .custom
            }
        }
    }
    
    /// Gradient cycle effect (animates the gradient offset to rotate colors)
    var gradientCycleEffect: GradientCycleEffect {
        get { withLock { _gradientCycleEffect } }
        set {
            withLock {
                _gradientCycleEffect = newValue
                _lightingPreset = .custom
            }
        }
    }
    
    // === EMISSIVE GLOW ===
    
    /// Enable emissive glow regions
    var emissiveEnabled: Bool {
        get { withLock { _emissiveEnabled } }
        set { withLock { _emissiveEnabled = newValue } }
    }
    
    /// Emissive pattern type: 0=folds, 1=depth, 2=position, 3=pulse, 4=edges
    var emissivePattern: Int {
        get { withLock { _emissivePattern } }
        set { withLock { _emissivePattern = max(0, min(4, newValue)) } }
    }
    
    /// Emissive glow intensity (0-2)
    var emissiveIntensity: Float {
        get { withLock { _emissiveIntensity } }
        set { withLock { _emissiveIntensity = max(0.0, min(2.0, newValue)) } }
    }
    
    /// Threshold for triggering emissive glow (0-1)
    var emissiveThreshold: Float {
        get { withLock { _emissiveThreshold } }
        set { withLock { _emissiveThreshold = max(0.0, min(1.0, newValue)) } }
    }
    
    /// Emissive color tint
    var emissiveColor: SIMD3<Float> {
        get { withLock { _emissiveColor } }
        set { withLock { _emissiveColor = newValue } }
    }
    
    /// Emissive animation speed (for pulse mode)
    var emissiveSpeed: Float {
        get { withLock { _emissiveSpeed } }
        set { withLock { _emissiveSpeed = max(0.1, min(5.0, newValue)) } }
    }
    
    // === DOPPELGANGER MODE ===
    
    /// Enable doppelganger pre-fold (creates structural twin)
    var doppelgangerEnabled: Bool {
        get { withLock { _doppelgangerEnabled } }
        set { withLock { _doppelgangerEnabled = newValue } }
    }
    
    /// Mirror plane normal (normalized direction vector)
    var doppelgangerPlane: SIMD3<Float> {
        get { withLock { _doppelgangerPlane } }
        set { withLock { _doppelgangerPlane = simd_normalize(newValue) } }
    }
    
    /// Mirror plane offset from origin along the plane normal
    var doppelgangerOffset: Float {
        get { withLock { _doppelgangerOffset } }
        set { withLock { _doppelgangerOffset = newValue } }
    }
    
    // === DYNAMIC RENDER QUALITY (WWDC25 Session 294) ===
    
    /// Enable dynamic render quality adjustment based on FPS
    var dynamicRenderQualityEnabled: Bool {
        get { withLock { _dynamicRenderQualityEnabled } }
        set { withLock { _dynamicRenderQualityEnabled = newValue } }
    }
    
    /// Target render quality when stable (0.5-1.0)
    var dynamicRenderQualityTarget: Float {
        get { withLock { _dynamicRenderQualityTarget } }
        set { withLock { _dynamicRenderQualityTarget = max(0.5, min(1.0, newValue)) } }
    }
    
    /// Minimum render quality floor (0.4-0.8)
    var dynamicRenderQualityMin: Float {
        get { withLock { _dynamicRenderQualityMin } }
        set { withLock { _dynamicRenderQualityMin = max(0.4, min(0.8, newValue)) } }
    }
    
    /// Maximum render quality ceiling (0.8-1.0)
    var dynamicRenderQualityMax: Float {
        get { withLock { _dynamicRenderQualityMax } }
        set { withLock { _dynamicRenderQualityMax = max(0.8, min(1.0, newValue)) } }
    }
    
    /// Current render quality level (read-only, updated by DynamicRenderQualityManager)
    var currentRenderQuality: Float {
        get { withLock { _currentRenderQuality } }
        set { withLock { _currentRenderQuality = newValue } }
    }
    
    /// Update color scheme transitions and animation time. Call once per frame.
    func updateColorSchemeTransition(deltaTime: Float) {
        withLock {
            // Update animation time
            _colorAnimTime += deltaTime
            
            // Handle ongoing transition
            if _colorSchemeTransitionProgress < 1.0 {
                let step = deltaTime / _colorSchemeTransitionDuration
                _colorSchemeTransitionProgress = min(1.0, _colorSchemeTransitionProgress + step)
                
                // When transition completes, update current scheme
                if _colorSchemeTransitionProgress >= 1.0 {
                    _colorScheme = _targetColorScheme
                }
            }
            
            // Handle auto-cycling
            // OPTIMIZATION: Use rawValue arithmetic instead of allCases iteration
            if _colorSchemeAutoTransition && _colorSchemeTransitionProgress >= 1.0 {
                _colorSchemeAutoTimer += deltaTime
                if _colorSchemeAutoTimer >= _colorSchemeAutoInterval {
                    _colorSchemeAutoTimer = 0.0
                    // Transition to next scheme using rawValue arithmetic (faster than allCases lookup)
                    let currentRaw = _targetColorScheme.rawValue
                    let nextRaw = (currentRaw + 1) % Int32(ColorScheme.allCases.count)
                    if let nextScheme = ColorScheme(rawValue: nextRaw) {
                        _colorScheme = _targetColorScheme
                        _targetColorScheme = nextScheme
                        _colorSchemeTransitionProgress = 0.0
                    }
                }
            }
        }
    }
    
    private func makeColorSchemeParamsLocked() -> ColorSchemeParams {
        let currentPal = _targetColorScheme.palette
        let previousPal = _colorScheme.palette
        let currentNeon = _targetColorScheme.neonParams
        let previousNeon = _colorScheme.neonParams
        
        // Interpolate between previous and target palettes
        let t = _colorSchemeTransitionProgress
        let color1 = simd_mix(previousPal.color1, currentPal.color1, SIMD3<Float>(repeating: t))
        let color2 = simd_mix(previousPal.color2, currentPal.color2, SIMD3<Float>(repeating: t))
        let color3 = simd_mix(previousPal.color3, currentPal.color3, SIMD3<Float>(repeating: t))
        let altColor1 = simd_mix(previousPal.altColor1, currentPal.altColor1, SIMD3<Float>(repeating: t))
        let altMixFactors = simd_mix(previousPal.altMixFactors, currentPal.altMixFactors, SIMD3<Float>(repeating: t))
        
        // Interpolate neon intensity (0 for non-neon, 1 for neon)
        let prevNeonIntensity: Float = _colorScheme.isNeonMode ? 1.0 : 0.0
        let currNeonIntensity: Float = _targetColorScheme.isNeonMode ? 1.0 : 0.0
        let neonIntensity = prevNeonIntensity + (currNeonIntensity - prevNeonIntensity) * t
        
        // Interpolate neon parameters
        let hueFreq = previousNeon.hueFreq + (currentNeon.hueFreq - previousNeon.hueFreq) * t
        let hueOffset = previousNeon.hueOffset + (currentNeon.hueOffset - previousNeon.hueOffset) * t
        let bandFreq = previousNeon.bandFreq + (currentNeon.bandFreq - previousNeon.bandFreq) * t
        let stripeFreq = previousNeon.stripeFreq + (currentNeon.stripeFreq - previousNeon.stripeFreq) * t
        let stripeStrength = previousNeon.stripeStrength + (currentNeon.stripeStrength - previousNeon.stripeStrength) * t
        let glowSharpness = previousNeon.glowSharpness + (currentNeon.glowSharpness - previousNeon.glowSharpness) * t
        let satPower = previousNeon.satPower + (currentNeon.satPower - previousNeon.satPower) * t
        
        // === Build gradient stop data for shader ===
        let gradState = _gradientState
        let (gradStops, gradCount) = gradState.gradient.toShaderStops()
        // C array becomes a tuple in Swift — fill all 8 slots
        let gs = (
            gradStops[0], gradStops[1], gradStops[2], gradStops[3],
            gradStops[4], gradStops[5], gradStops[6], gradStops[7]
        )
        
        return ColorSchemeParams(
            color1: color1,
            color2: color2,
            color3: color3,
            altColor1: altColor1,
            altMixFactors: altMixFactors,
            saturation: _colorSchemeSaturation,
            contrast: _colorSchemeContrast,
            gamma: _colorSchemeGamma,
            brightness: 0.0,
            vibrance: _colorSchemeVibrance,
            colorCurve: _colorSchemeCurve,
            shadows: _colorSchemeShadows,
            highlights: _colorSchemeHighlights,
            neonIntensity: neonIntensity,
            hueFrequency: hueFreq,
            hueOffset: hueOffset,
            bandFrequency: bandFreq,
            stripeFrequency: stripeFreq,
            stripeStrength: stripeStrength,
            glowSharpness: glowSharpness,
            saturationPower: satPower,
            // === GRADIENT COLORING ===
            gradientStops: gs,
            gradientStopCount: Int32(gradCount),
            colorMappingMode: Int32(gradState.gradient.mappingMode.rawValue),
            gradientRepeat: gradState.gradient.repeatCount,
            gradientOffset: gradState.gradient.offset + (_gradientCycleEffect.enabled ? fmod(_colorAnimTime * _gradientCycleEffect.speed, 1.0) : 0),
            useGradientColoring: gradState.useGradientColoring ? 1 : 0,
            gradientSmoothing: gradState.gradient.smoothing,
            _gradPad: (0.0, 0.0),
            // === MODULAR LIGHTING EFFECTS ===
            animTime: _colorAnimTime,
            hueRotationEnabled: _hueRotationEffect.enabled ? 1 : 0,
            hueRotationSpeed: _hueRotationEffect.speed,
            hueRotationIntensity: _hueRotationEffect.intensity,
            pulseEnabled: _pulseEffect.enabled ? 1 : 0,
            pulseSpeed: _pulseEffect.speed,
            pulseAmount: _pulseEffect.amount,
            glowEnabled: _glowEffect.enabled ? 1 : 0,
            glowIntensity: _glowEffect.intensity,
            bloomEnabled: _bloomEffect.enabled ? 1 : 0,
            bloomStrength: _bloomEffect.strength,
            fogEnabled: _fogEffect.enabled ? 1 : 0,
            fogIntensity: _fogEffect.intensity,
            transitionProgress: t,
            previousScheme: _colorScheme.rawValue,
            currentScheme: _targetColorScheme.rawValue,
            _padding: 0
        )
    }
    
    /// Get a snapshot of render-critical settings in a single lock.
    func snapshot() -> RenderSettingsSnapshot {
        return withLock {
            RenderSettingsSnapshot(
                minDistance: _minDistance,
                scale: _scale,
                position: _position,
                fractalScale: _fractalScale,
                fractalIterations: _fractalIterations,
                maxRaySteps: _maxRaySteps,
                colorMix: _colorMix,
                lightingPlay: _lightingPlay,
                lightingMode: _lightingMode,
                audioLevel: _audioLevel,
                foldingLimit: _foldingLimit,
                sphereRadius: _sphereRadius,
                colorIterations: _colorIterations,
                resolutionScale: _resolutionScale,
                fractalType: _fractalType,
                tileSize: _tileSize,
                useHierarchical: _useHierarchical,
                debugHierarchical: _debugHierarchical,
                limitFlash: _limitFlash,
                showHUD: _showHUD,
                activeGestureIndex: _activeGestureIndex,
                gestureSpread: _gestureSpread,
                safetyBubbleEnabled: _safetyBubbleEnabled,
                safetyBubbleRadius: _safetyBubbleRadius,
                safetyBubbleShape: _safetyBubbleShape,
                sphereProjectionMode: _sphereProjectionMode,
                emissiveEnabled: _emissiveEnabled,
                emissivePattern: _emissivePattern,
                emissiveIntensity: _emissiveIntensity,
                emissiveThreshold: _emissiveThreshold,
                emissiveColor: _emissiveColor,
                emissiveSpeed: _emissiveSpeed,
                colorSchemeParams: makeColorSchemeParamsLocked(),
                lightingSoftness: _lightingSoftness,
                doppelgangerEnabled: _doppelgangerEnabled,
                doppelgangerPlane: _doppelgangerPlane,
                doppelgangerOffset: _doppelgangerOffset,
                geometryState: _stableGeometryEnabled ? _geometryState : .dynamic,
                isGeometryGestureActive: _isGeometryGestureActive,
                stepMultiplier: _stepMultiplier
            )
        }
    }
    
    /// Get shader parameters for the current color scheme state
    func getColorSchemeParams() -> ColorSchemeParams {
        return withLock {
            makeColorSchemeParamsLocked()
        }
    }
    
    /// Manually trigger a transition to a new scheme
    func transitionToColorScheme(_ scheme: ColorScheme) {
        withLock {
            if _targetColorScheme != scheme {
                // Current becomes previous
                _colorScheme = _targetColorScheme
                _targetColorScheme = scheme
                _colorSchemeTransitionProgress = 0.0
            }
        }
    }
    
    /// Cycle to the next color scheme
    func nextColorScheme() {
        withLock {
            let allSchemes = ColorScheme.allCases
            let currentIndex = allSchemes.firstIndex(of: _targetColorScheme) ?? 0
            let nextIndex = (currentIndex + 1) % allSchemes.count
            let nextScheme = allSchemes[nextIndex]
            
            _colorScheme = _targetColorScheme
            _targetColorScheme = nextScheme
            _colorSchemeTransitionProgress = 0.0
        }
    }
    
    // === GESTURE TARGET VALUES ===
    // UI/gestures set these asynchronously. Renderer interpolates current → target each frame.
    // This cleanly separates: (1) intent (targets) from (2) animation (smoothing)
    
    var targetMinDistance: Float {
        get { withLock { _targetMinDistance } }
        set { withLock { _targetMinDistance = newValue } }
    }
    
    var targetFoldingLimit: Float {
        get { withLock { _targetFoldingLimit } }
        set { withLock { _targetFoldingLimit = newValue } }
    }
    
    var targetSphereRadius: Float {
        get { withLock { _targetSphereRadius } }
        set { withLock { _targetSphereRadius = newValue } }
    }
    
    var targetPosition: SIMD3<Float> {
        get { withLock { _targetPosition } }
        set { withLock { _targetPosition = newValue } }
    }
    
    var isAnimationPlaying: Bool {
        get { withLock { _isAnimationPlaying } }
        set { withLock { _isAnimationPlaying = newValue } }
    }
    
    var animationBaseMinDistance: Float {
        get { withLock { _animationBaseMinDistance } }
        set { withLock { _animationBaseMinDistance = newValue } }
    }
    
    var animationBaseFoldingLimit: Float {
        get { withLock { _animationBaseFoldingLimit } }
        set { withLock { _animationBaseFoldingLimit = newValue } }
    }
    
    var animationBaseSphereRadius: Float {
        get { withLock { _animationBaseSphereRadius } }
        set { withLock { _animationBaseSphereRadius = newValue } }
    }
    
    var animationBaseFractalScale: Float {
        get { withLock { _animationBaseFractalScale } }
        set { withLock { _animationBaseFractalScale = newValue } }
    }
    
    var animationBasePosition: SIMD3<Float> {
        get { withLock { _animationBasePosition } }
        set { withLock { _animationBasePosition = newValue } }
    }
    
    var manualOffsetMinDistance: Float {
        get { withLock { _manualOffsetMinDistance } }
        set { withLock { _manualOffsetMinDistance = newValue } }
    }
    
    var manualOffsetFoldingLimit: Float {
        get { withLock { _manualOffsetFoldingLimit } }
        set { withLock { _manualOffsetFoldingLimit = newValue } }
    }
    
    var manualOffsetSphereRadius: Float {
        get { withLock { _manualOffsetSphereRadius } }
        set { withLock { _manualOffsetSphereRadius = newValue } }
    }
    
    var manualOffsetFractalScale: Float {
        get { withLock { _manualOffsetFractalScale } }
        set { withLock { _manualOffsetFractalScale = newValue } }
    }
    
    var manualOffsetPosition: SIMD3<Float> {
        get { withLock { _manualOffsetPosition } }
        set { withLock { _manualOffsetPosition = newValue } }
    }
    
    var effectiveTargetMinDistance: Float {
        withLock {
            _isAnimationPlaying ? _animationBaseMinDistance + _manualOffsetMinDistance : _targetMinDistance
        }
    }
    
    var effectiveTargetFoldingLimit: Float {
        withLock {
            _isAnimationPlaying ? _animationBaseFoldingLimit + _manualOffsetFoldingLimit : _targetFoldingLimit
        }
    }
    
    var effectiveTargetSphereRadius: Float {
        withLock {
            _isAnimationPlaying ? _animationBaseSphereRadius + _manualOffsetSphereRadius : _targetSphereRadius
        }
    }
    
    var effectiveTargetFractalScale: Float {
        withLock {
            _isAnimationPlaying ? _animationBaseFractalScale + _manualOffsetFractalScale : _fractalScale
        }
    }
    
    var effectiveTargetPosition: SIMD3<Float> {
        withLock {
            _isAnimationPlaying ? _animationBasePosition + _manualOffsetPosition : _targetPosition
        }
    }
    
    // === SMOOTH DAMP PARAMETERS ===
    // Critically-damped spring with velocity/acceleration limits for buttery smooth motion
    
    /// Smooth time - how long (in seconds) to reach the target. Higher = smoother but more latency.
    private let smoothTime: Float = 0.35
    
    /// Maximum speed the parameter can travel (units per second). Prevents jarring fast motion.
    private let maxSpeed: Float = 8.0
    
    /// Maximum speed for position (meters per second) - higher to allow responsive flicking
    private let maxPositionSpeed: Float = 12.0
    
    /// Critically-damped smooth damp function (like Unity's SmoothDamp)
    /// Smoothly moves a value toward a target with velocity tracking and limits
    /// OPTIMIZATION: Precompute repeated calculations
    @inline(__always)
    private func smoothDamp(
        current: Float,
        target: Float,
        velocity: inout Float,
        smoothTime: Float,
        maxSpeed: Float,
        deltaTime: Float
    ) -> Float {
        // Based on Game Programming Gems 4, Chapter 1.10
        // OPTIMIZATION: Precompute omega and derived values
        let omega = 2.0 / smoothTime
        let x = omega * deltaTime
        let x2 = x * x
        let exp_factor = 1.0 / (1.0 + x + 0.48 * x2 + 0.235 * x2 * x)
        
        var change = current - target
        let originalTo = target
        
        // Clamp maximum speed
        let maxChange = maxSpeed * smoothTime
        change = max(-maxChange, min(maxChange, change))
        let clampedTarget = current - change
        
        let omegaChange = omega * change
        let temp = (velocity + omegaChange) * deltaTime
        velocity = (velocity - omega * temp) * exp_factor
        var output = clampedTarget + (change + temp) * exp_factor
        
        // Prevent overshooting
        if (originalTo - current > 0.0) == (output > originalTo) {
            output = originalTo
            velocity = (output - originalTo) / deltaTime
        }
        
        return output
    }
    
    /// Called by Renderer every frame to smoothly interpolate current values toward targets.
    /// Uses critically-damped spring physics for smooth acceleration/deceleration.
    /// - Parameter deltaTime: Time since last frame in seconds
    func interpolateToTargets(deltaTime: Float) {
        withLock {
            // Guard against bad deltaTime values that could cause instability
            let clampedDT = max(0.001, min(0.1, deltaTime))  // 10ms to 100ms range
            
            // Check for NaN/Inf in targets before interpolating
            if _targetMinDistance.isNaN || _targetMinDistance.isInfinite {
                print("⚠️ ANOMALY: targetMinDistance is \(_targetMinDistance), resetting to 0.8")
                _targetMinDistance = 0.8
                _velocityMinDistance = 0.0
            }
            if _targetFoldingLimit.isNaN || _targetFoldingLimit.isInfinite {
                print("⚠️ ANOMALY: targetFoldingLimit is \(_targetFoldingLimit), resetting to 1.0")
                _targetFoldingLimit = 1.0
                _velocityFoldingLimit = 0.0
            }
            if _targetSphereRadius.isNaN || _targetSphereRadius.isInfinite {
                print("⚠️ ANOMALY: targetSphereRadius is \(_targetSphereRadius), resetting to 0.5")
                _targetSphereRadius = 0.5
                _velocitySphereRadius = 0.0
            }
            if _targetPosition.x.isNaN || _targetPosition.y.isNaN || _targetPosition.z.isNaN {
                print("⚠️ ANOMALY: targetPosition contains NaN, resetting to zero")
                _targetPosition = .zero
                _velocityPosition = .zero
            }
            
            // Apply smooth damp to each parameter
            _minDistance = smoothDamp(
                current: _minDistance,
                target: _targetMinDistance,
                velocity: &_velocityMinDistance,
                smoothTime: smoothTime,
                maxSpeed: maxSpeed,
                deltaTime: clampedDT
            )
            
            _foldingLimit = smoothDamp(
                current: _foldingLimit,
                target: _targetFoldingLimit,
                velocity: &_velocityFoldingLimit,
                smoothTime: smoothTime,
                maxSpeed: maxSpeed,
                deltaTime: clampedDT
            )
            
            _sphereRadius = smoothDamp(
                current: _sphereRadius,
                target: _targetSphereRadius,
                velocity: &_velocitySphereRadius,
                smoothTime: smoothTime,
                maxSpeed: maxSpeed,
                deltaTime: clampedDT
            )
            
            // Smooth damp position (each component separately)
            _position.x = smoothDamp(
                current: _position.x,
                target: _targetPosition.x,
                velocity: &_velocityPosition.x,
                smoothTime: smoothTime,
                maxSpeed: maxPositionSpeed,
                deltaTime: clampedDT
            )
            _position.y = smoothDamp(
                current: _position.y,
                target: _targetPosition.y,
                velocity: &_velocityPosition.y,
                smoothTime: smoothTime,
                maxSpeed: maxPositionSpeed,
                deltaTime: clampedDT
            )
            _position.z = smoothDamp(
                current: _position.z,
                target: _targetPosition.z,
                velocity: &_velocityPosition.z,
                smoothTime: smoothTime,
                maxSpeed: maxPositionSpeed,
                deltaTime: clampedDT
            )
            
            // Clamp current values to sane ranges as a safety net
            // These MUST cover the full gesture/slider ranges (including negatives
            // for inverted effects) otherwise gestures and UI appear to "stop working"
            // at the clamp boundary.
            // Standard ranges:  minDist -2…8, fold -5…20, sphere -3…4
            // Extended ranges:  minDist -5…15, fold -10…30, sphere -5…8
            _minDistance = max(-5.0, min(15.0, _minDistance))
            _foldingLimit = max(-10.0, min(30.0, _foldingLimit))
            _sphereRadius = max(-5.0, min(8.0, _sphereRadius))
            
            // Clamp position to prevent drifting to infinity
            let maxPos: Float = 100.0
            _position.x = max(-maxPos, min(maxPos, _position.x))
            _position.y = max(-maxPos, min(maxPos, _position.y))
            _position.z = max(-maxPos, min(maxPos, _position.z))
            
            // ═══════════════════════════════════════════════════════════════════════════
            // GEOMETRY STABILITY STATE MACHINE UPDATE
            // Check if geometry-affecting parameters have settled (interpolation complete)
            // ═══════════════════════════════════════════════════════════════════════════
            let minDistSettled = abs(_minDistance - _targetMinDistance) < geometrySettleThreshold
            let foldSettled = abs(_foldingLimit - _targetFoldingLimit) < geometrySettleThreshold
            let sphereSettled = abs(_sphereRadius - _targetSphereRadius) < geometrySettleThreshold
            // Note: fractalScale is set directly (no smoothing), so it's always "settled"
            let allGeometrySettled = minDistSettled && foldSettled && sphereSettled
            
            switch _geometryState {
            case .dynamic:
                // Stay dynamic while gesture is active
                if !_isGeometryGestureActive {
                    _geometryState = .settling
                    _geometryStableFrameCount = 0
                }
                
            case .settling:
                // Transition to stable once interpolation completes
                if _isGeometryGestureActive {
                    _geometryState = .dynamic
                    _geometryStableFrameCount = 0
                } else if allGeometrySettled {
                    _geometryState = .stable
                    _geometryStableFrameCount = 0
                    #if DEBUG
                    print("🎯 GEOMETRY: Transition to STABLE (parameters settled)")
                    #endif
                }
                
            case .stable:
                // Break out of stable if gesture starts or parameters drift
                if _isGeometryGestureActive {
                    _geometryState = .dynamic
                    _geometryStableFrameCount = 0
                    #if DEBUG
                    print("🎯 GEOMETRY: Transition to DYNAMIC (gesture started)")
                    #endif
                } else if allGeometrySettled {
                    _geometryStableFrameCount += 1
                } else {
                    // Parameters changed externally (e.g., slider)
                    _geometryState = .settling
                    _geometryStableFrameCount = 0
                }
            }
            
            // ═══════════════════════════════════════════════════════════════════════════
            // GMT-FRACTALS: ADAPTIVE STEP MULTIPLIER
            // Over-relaxation factor adjusts based on geometry stability:
            // - Parameters changing: 1.0 (safe, no over-stepping thin features)
            // - Parameters settled: 1.2 (moderate convergence speedup)
            // Uses allGeometrySettled directly instead of _isGeometryGestureActive,
            // which may not be wired to all gesture sources.
            // ═══════════════════════════════════════════════════════════════════════════
            let targetStepMultiplier: Float = allGeometrySettled ? 1.2 : 1.0
            // Smooth transition to avoid popping
            _stepMultiplier += (targetStepMultiplier - _stepMultiplier) * 0.1
        }
    }
    
    /// Snap current values immediately to targets (no smoothing)
    /// Use when loading presets or resetting state
    func snapToTargets() {
        withLock {
            _minDistance = _targetMinDistance
            _foldingLimit = _targetFoldingLimit
            _sphereRadius = _targetSphereRadius
            _position = _targetPosition
            // Reset velocities when snapping
            _velocityMinDistance = 0.0
            _velocityFoldingLimit = 0.0
            _velocitySphereRadius = 0.0
            _velocityPosition = .zero
        }
    }
    
    /// When animation stops/pauses, bake manual offsets into targets and clear offsets.
    func commitAnimationOffsetsToTargets() {
        withLock {
            _targetMinDistance = _minDistance
            _targetFoldingLimit = _foldingLimit
            _targetSphereRadius = _sphereRadius
            _targetPosition = _position
            _manualOffsetMinDistance = 0.0
            _manualOffsetFoldingLimit = 0.0
            _manualOffsetSphereRadius = 0.0
            _manualOffsetFractalScale = 0.0
            _manualOffsetPosition = .zero
        }
    }
    
    /// Set all targets at once (for preset loading)
    func setTargets(minDistance: Float, foldingLimit: Float, sphereRadius: Float, position: SIMD3<Float>) {
        withLock {
            _targetMinDistance = minDistance
            _targetFoldingLimit = foldingLimit
            _targetSphereRadius = sphereRadius
            _targetPosition = position
        }
    }
    
    // === REFINING PARAMETERS ===
    // Over-relaxation multiplier (Keinert 2014)
    var relaxFactor: Float {
        get { withLock { _relaxFactor } }
        set { 
            withLock { _relaxFactor = newValue }
            print("[REFINE] relaxFactor = \(newValue)")
        }
    }
    
    // Backtrack factor when overshooting
    var relaxBacktrack: Float {
        get { withLock { _relaxBacktrack } }
        set { 
            withLock { _relaxBacktrack = newValue }
            print("[REFINE] relaxBacktrack = \(newValue)")
        }
    }
    
    // SDF scaling for coarse pass (Polychronakis 2024)
    var sdfScaleCoarse: Float {
        get { withLock { _sdfScaleCoarse } }
        set { 
            withLock { _sdfScaleCoarse = newValue }
            print("[REFINE] sdfScaleCoarse = \(newValue)")
        }
    }
    
    // SDF scaling for super-coarse pass
    var sdfScaleSuperCoarse: Float {
        get { withLock { _sdfScaleSuperCoarse } }
        set { 
            withLock { _sdfScaleSuperCoarse = newValue }
            print("[REFINE] sdfScaleSuperCoarse = \(newValue)")
        }
    }
    
    // Early termination convergence ratio
    var earlyTermRatio: Float {
        get { withLock { _earlyTermRatio } }
        set { 
            withLock { _earlyTermRatio = newValue }
            print("[REFINE] earlyTermRatio = \(newValue)")
        }
    }
    
    // Steps before early termination
    var earlyTermCount: Int {
        get { withLock { _earlyTermCount } }
        set { 
            withLock { _earlyTermCount = newValue }
            print("[REFINE] earlyTermCount = \(newValue)")
        }
    }
    
    // Log all current refining values
    func logRefiningValues() {
        print("[REFINE] === Current Refining Values ===")
        print("[REFINE] relaxFactor = \(relaxFactor)")
        print("[REFINE] relaxBacktrack = \(relaxBacktrack)")
        print("[REFINE] sdfScaleCoarse = \(sdfScaleCoarse)")
        print("[REFINE] sdfScaleSuperCoarse = \(sdfScaleSuperCoarse)")
        print("[REFINE] earlyTermRatio = \(earlyTermRatio)")
        print("[REFINE] earlyTermCount = \(earlyTermCount)")
        print("[REFINE] ================================")
    }
}

class AppClock {
    private var accumulatedTime: TimeInterval = 0
    private var startTime: Date?
    
    var speed: Double = 0 {
        willSet {
            accumulatedTime = time
        }
        didSet {
            startTime = (speed > 0 ? Date.now : nil)
        }
    }
    
    var time: TimeInterval {
        accumulatedTime + abs(startTime?.timeIntervalSinceNow ?? 0) * speed
    }
}
