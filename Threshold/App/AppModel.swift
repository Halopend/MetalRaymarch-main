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
enum FractalModelType: Int32, Codable, CaseIterable {
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

@MainActor
@Observable
class AppModel {
    let immersiveSpaceID = "ImmersiveSpace"
    let menuWindowID = "MenuWindow"
    
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
    
    // Spotify integration for music visualizer
    let spotifyManager = SpotifyManager()

    // Apple Music integration for music visualizer
    let appleMusicManager = AppleMusicManager()
    
    // Hand tracking state
    var handTrackingEnabled: Bool = {
        let key = "handTrackingEnabled"
        guard UserDefaults.standard.object(forKey: key) != nil else { return true }
        return UserDefaults.standard.bool(forKey: key)
    }() {
        didSet {
            UserDefaults.standard.set(handTrackingEnabled, forKey: "handTrackingEnabled")
            if !handTrackingEnabled {
                leftHandTracked = false
                rightHandTracked = false
                gestureController?.syncWithSettings()
            }
        }
    }
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
// MARK: - Lighting Effects System
// ═══════════════════════════════════════════════════════════════════════════════
// Modular lighting effects that can be toggled on/off independently.
// Each effect is a card in the UI with its own settings.
// Presets bundle effects together for quick looks.
// ═══════════════════════════════════════════════════════════════════════════════

/// Hue rotation effect - rotates colors through YIQ color space
struct HueRotationEffect: Codable, Equatable {
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
struct PulseEffect: Codable, Equatable {
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
struct GlowEffect: Codable, Equatable {
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
struct BloomEffect: Codable, Equatable {
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
struct FogEffect: Codable, Equatable {
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
struct GradientCycleEffect: Codable, Equatable {
    var enabled: Bool = false
    var speed: Float = 0.1          // Cycle speed (0-1), how fast the gradient rotates
    var smoothLoop: Bool = true     // When true, gradient wraps smoothly (last stop blends back to first)
    
    static var off: GradientCycleEffect {
        GradientCycleEffect(enabled: false, speed: 0.0, smoothLoop: true)
    }
    
    static var slow: GradientCycleEffect {
        GradientCycleEffect(enabled: true, speed: 0.05, smoothLoop: true)
    }
    
    static var medium: GradientCycleEffect {
        GradientCycleEffect(enabled: true, speed: 0.15, smoothLoop: true)
    }
    
    static var fast: GradientCycleEffect {
        GradientCycleEffect(enabled: true, speed: 0.4, smoothLoop: true)
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
            gradientLoopSmooth: 0,
            _gradPad: (0.0),
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
