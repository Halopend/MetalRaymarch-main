//
//  AppModel.swift
//  MetalProject
//
//  Created by MU on 18/11/24.
//

import SwiftUI
import ARKit
import os  // For os_unfair_lock - fastest available lock primitive

/// Quality preset that bundles fractal iterations and ray steps
enum QualityPreset: String, CaseIterable {
    case iter6 = "6"
    case iter9 = "9"
    case iter10 = "10"
    case iter12 = "12"
    case iter16 = "16"
    
    var fractalIterations: Int {
        switch self {
        case .iter6: return 6
        case .iter9: return 9
        case .iter10: return 10
        case .iter12: return 12
        case .iter16: return 16
        }
    }
    
    var raySteps: Int {
        switch self {
        case .iter6: return 32
        case .iter9: return 64
        case .iter10: return 80
        case .iter12: return 100
        case .iter16: return 128
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
    
    enum ImmersiveSpaceState {
        case closed
        case inTransition
        case open
    }
    
    var immersiveSpaceState = ImmersiveSpaceState.closed

    // App activity state (used to avoid submitting GPU work while backgrounded)
    nonisolated(unsafe) var isAppActive: Bool = true

    var fps: Double = 0
    
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
    
    // Menu window visibility (toggled by gesture)
    // We hide content and glass to simulate window close while preserving position/size
    var isMenuWindowVisible: Bool = true
    
    // Screenshot capture (set by Renderer)
    var captureScreenshotHandler: (() async -> Data?)?
    
    // SharePlay session for collaborative fractal exploration
    var shareSession: FractalShareSession?
    
    init() {
        // Initialize gesture controller with render settings
        gestureController = GestureController(renderSettings: renderSettings)
        
        // Initialize parameter recorder
        parameterRecorder = ParameterRecorder(renderSettings: renderSettings)
        
        // Initialize SharePlay session
        shareSession = FractalShareSession(renderSettings: renderSettings)
        
        // Setup gesture callbacks
        gestureController?.onRecordingToggle = { [weak self] in
            self?.toggleRecording()
        }
        
        gestureController?.onMenuToggle = { [weak self] in
            print("📋 onMenuToggle callback fired!")
            self?.toggleMenuWindow()
        }
        
        // Add built-in presets if this is first launch
        presetManager.addBuiltInPresetsIfNeeded()
        
        // Configure SharePlay session listener
        shareSession?.configureGroupSessions()
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
    
    /// Toggle menu window visibility (hides content while preserving window position/size)
    func toggleMenuWindow() {
        withAnimation(.easeInOut(duration: 0.25)) {
            isMenuWindowVisible.toggle()
        }
        print("📋 Menu window: \(isMenuWindowVisible ? "shown" : "hidden")")
    }
    
    /// Ensure window content is visible - call when exiting immersive mode or on app launch
    /// This prevents the window from being invisible when gestures toggled it hidden during immersive mode
    func ensureWindowContentVisible() {
        if !isMenuWindowVisible {
            withAnimation(.easeInOut(duration: 0.25)) {
                isMenuWindowVisible = true
            }
            print("📋 Menu window restored to visible state")
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

// Fractal type enum matching ShaderTypes.h
enum FractalType: Int32, Codable {
    case mandelbox = 0
    case triforce = 1
    case negativeMandelbox = 2  // Scale = -1.5 Mandelbox (organic, dense)
    case orbitDensity = 3       // 3D orbit-density variant (Buddhabrot-style)
    
    var displayName: String {
        switch self {
        case .mandelbox: return "Mandelbox"
        case .triforce: return "Triforce"
        case .negativeMandelbox: return "Negative Mandelbox"
        case .orbitDensity: return "Orbit Density"
        }
    }
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
    
    // Create shader-compatible ColorSchemeParams
    func toShaderParams(colorMix: Float, transitionProgress: Float = 1.0, previousScheme: ColorScheme? = nil,
                        animTime: Float = 0.0, hueCycleSpeed: Float = 0.0, pulseSpeed: Float = 0.0,
                        pulseAmount: Float = 0.0, glowIntensity: Float = 0.0, bloomStrength: Float = 0.0) -> ColorSchemeParams {
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
            neonIntensity: isNeonMode ? 1.0 : 0.0,
            hueFrequency: neon.hueFreq,
            hueOffset: neon.hueOffset,
            bandFrequency: neon.bandFreq,
            stripeFrequency: neon.stripeFreq,
            stripeStrength: neon.stripeStrength,
            glowSharpness: neon.glowSharpness,
            saturationPower: neon.satPower,
            animTime: animTime,
            hueCycleSpeed: hueCycleSpeed,
            pulseSpeed: pulseSpeed,
            pulseAmount: pulseAmount,
            glowIntensity: glowIntensity,
            bloomStrength: bloomStrength,
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
final class RenderSettings: @unchecked Sendable {
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
    private var _position: SIMD3<Float> = .zero
    private var _fractalScale: Float = 2.8
    private var _fractalIterations: Int = 9         // Mid quality default
    private var _maxRaySteps: Int = 64              // Mid quality default
    private var _colorMix: Float = 0.5
    private var _lightingPlay: Bool = false         // Play/pause lighting effects
    private var _lightingMode: LightingMode = .animated  // Static, animated, or audio-reactive
    private var _audioLevel: Float = 0.0            // Current audio level (0-1) for reactive lighting
    private var _foldingLimit: Float = 1.0
    private var _sphereRadius: Float = 0.5
    private var _colorIterations: Float = 8.0       // Lower = faster (was 10)
    private var _resolutionScale: Float = 1.0       // Render scale for MetalFX (1.0 = native)
    private var _fractalType: FractalType = .mandelbox  // Current fractal type
    private var _preferFoveated: Bool = false        // Legacy flag (no longer mutually exclusive)
    private var _tileSize: Int = 0                   // 0=disabled, 2=2x2, 4=4x4, 8=8x8 adaptive hierarchical
    private var _useHierarchical: Bool = true        // Use hierarchical coarse/fine raymarching
    private var _debugHierarchical: Bool = false     // Visualize adaptive hierarchy levels
    private var _limitFlash: Float = 0.0             // Flash intensity when gesture hits parameter limit (0-1, decays)
    
    // HUD display
    private var _showHUD: Bool = true                // Show in-world HUD (default on)
    private var _activeGestureIndex: Int = 0         // Currently active gesture (0=none, 1=index, 2=middle, 3=ring)
    private var _useRelativeGestures: Bool = false   // Use relative gestures (delta-based) instead of absolute mapping

    // Safety bubble controls
    private var _safetyBubbleEnabled: Bool = true   // Cut out a small safe sphere (default on)
    private var _safetyBubbleRadius: Float = 1.8    // Radius of the safe bubble (meters)
    private var _safetyBubbleShape: Float = 0.0     // 0 = sphere, 1 = cube, intermediate = morph (no rotation)
    
    // === COLOR SCHEME ===
    // Controls the color palette and post-processing for fractal coloring
    private var _colorScheme: ColorScheme = .classic     // Current color scheme
    private var _targetColorScheme: ColorScheme = .classic // Target for transitions
    private var _colorSchemeTransitionProgress: Float = 1.0 // 0 = previous, 1 = current (complete)
    private var _colorSchemeTransitionDuration: Float = 2.0 // Seconds to transition between schemes
    private var _colorSchemeAutoTransition: Bool = false    // Auto-cycle through schemes
    private var _colorSchemeAutoInterval: Float = 30.0      // Seconds between auto-transitions
    private var _colorSchemeAutoTimer: Float = 0.0          // Timer for auto-transitions
    private var _colorSchemeSaturation: Float = 2.0         // Color saturation override (boosted)
    private var _colorSchemeContrast: Float = 1.05          // Contrast override (default 1.05)
    private var _colorSchemeGamma: Float = 0.5              // Gamma override (default 0.5)
    
    // === DYNAMIC COLOR ANIMATION ===
    // All animation effects default to OFF (0.0) so user must enable them
    private var _colorAnimTime: Float = 0.0                 // Running animation time
    private var _hueCycleSpeed: Float = 0.0                 // Hue rotation speed (0 = off, 0.05 = slow, 0.2 = fast)
    private var _pulseSpeed: Float = 0.0                    // Pulse frequency (0 = off, 0.3 = slow, 1.0 = fast)
    private var _pulseAmount: Float = 0.0                   // Pulse intensity (0 = off, 0.15 = subtle)
    private var _glowIntensity: Float = 0.0                 // Ray-step glow (0 = off, 0.3 = moderate)
    private var _bloomStrength: Float = 0.0                 // Bloom effect (0 = off, 0.2 = subtle)
    
    // === EMISSIVE GLOW (Self-illuminating regions) ===
    private var _emissiveEnabled: Bool = false              // Enable emissive glow regions
    private var _emissivePattern: Int = 0                   // 0=folds, 1=depth, 2=position, 3=pulse, 4=edges
    private var _emissiveIntensity: Float = 1.0             // Glow brightness (0-2)
    private var _emissiveThreshold: Float = 0.5             // Threshold for triggering glow (0-1)
    private var _emissiveColor: SIMD3<Float> = SIMD3<Float>(0.3, 0.6, 1.0)  // Blue-white default
    private var _emissiveSpeed: Float = 1.0                 // Animation speed for pulse mode
    
    // === KUWAHARA FILTER (Painterly Effect) ===
    private var _kuwaharaEnabled: Bool = false              // Enable anisotropic Kuwahara filter
    private var _kuwaharaRadius: Float = 4.0                // Filter radius (2-8, higher = more painterly)
    private var _kuwaharaSharpness: Float = 8.0             // Edge sharpness (1-16, higher = sharper edges)
    
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
    private var _targetPosition: SIMD3<Float> = .zero
    
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
    
    var fractalIterations: Int {
        get { withLock { _fractalIterations } }
        set { withLock { _fractalIterations = newValue } }
    }
    
    var maxRaySteps: Int {
        get { withLock { _maxRaySteps } }
        set { withLock { _maxRaySteps = newValue } }
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
    
    var fractalType: FractalType {
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

    var useRelativeGestures: Bool {
        get { withLock { _useRelativeGestures } }
        set { withLock { _useRelativeGestures = newValue } }
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
        set { withLock { _colorSchemeContrast = max(0.5, min(2.0, newValue)) } }
    }
    
    /// Gamma override
    var colorSchemeGamma: Float {
        get { withLock { _colorSchemeGamma } }
        set { withLock { _colorSchemeGamma = max(0.2, min(1.0, newValue)) } }
    }
    
    /// Hue cycle speed (rotations per second, 0 = static)
    var hueCycleSpeed: Float {
        get { withLock { _hueCycleSpeed } }
        set { withLock { _hueCycleSpeed = max(0.0, min(1.0, newValue)) } }
    }
    
    /// Pulse animation speed (Hz)
    var pulseSpeed: Float {
        get { withLock { _pulseSpeed } }
        set { withLock { _pulseSpeed = max(0.0, min(2.0, newValue)) } }
    }
    
    /// Pulse animation amount (0-1)
    var pulseAmount: Float {
        get { withLock { _pulseAmount } }
        set { withLock { _pulseAmount = max(0.0, min(1.0, newValue)) } }
    }
    
    /// Ray-step based glow intensity (0-1)
    var glowIntensity: Float {
        get { withLock { _glowIntensity } }
        set { withLock { _glowIntensity = max(0.0, min(1.0, newValue)) } }
    }
    
    /// Bloom effect strength (0-1)
    var bloomStrength: Float {
        get { withLock { _bloomStrength } }
        set { withLock { _bloomStrength = max(0.0, min(1.0, newValue)) } }
    }
    
    /// Enable anisotropic Kuwahara filter for painterly effect
    var kuwaharaEnabled: Bool {
        get { withLock { _kuwaharaEnabled } }
        set { withLock { _kuwaharaEnabled = newValue } }
    }
    
    /// Kuwahara filter radius (2-8, higher = more painterly)
    var kuwaharaRadius: Float {
        get { withLock { _kuwaharaRadius } }
        set { withLock { _kuwaharaRadius = max(2.0, min(8.0, newValue)) } }
    }
    
    /// Kuwahara edge sharpness (1-16, higher = sharper edges)
    var kuwaharaSharpness: Float {
        get { withLock { _kuwaharaSharpness } }
        set { withLock { _kuwaharaSharpness = max(1.0, min(16.0, newValue)) } }
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
            if _colorSchemeAutoTransition && _colorSchemeTransitionProgress >= 1.0 {
                _colorSchemeAutoTimer += deltaTime
                if _colorSchemeAutoTimer >= _colorSchemeAutoInterval {
                    _colorSchemeAutoTimer = 0.0
                    // Transition to next scheme
                    let allSchemes = ColorScheme.allCases
                    if let currentIndex = allSchemes.firstIndex(of: _targetColorScheme) {
                        let nextIndex = (allSchemes.distance(from: allSchemes.startIndex, to: currentIndex) + 1) % allSchemes.count
                        let nextScheme = allSchemes[allSchemes.index(allSchemes.startIndex, offsetBy: nextIndex)]
                        _colorScheme = _targetColorScheme
                        _targetColorScheme = nextScheme
                        _colorSchemeTransitionProgress = 0.0
                    }
                }
            }
        }
    }
    
    /// Get shader parameters for the current color scheme state
    func getColorSchemeParams() -> ColorSchemeParams {
        return withLock {
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
                neonIntensity: neonIntensity,
                hueFrequency: hueFreq,
                hueOffset: hueOffset,
                bandFrequency: bandFreq,
                stripeFrequency: stripeFreq,
                stripeStrength: stripeStrength,
                glowSharpness: glowSharpness,
                saturationPower: satPower,
                animTime: _colorAnimTime,
                hueCycleSpeed: _hueCycleSpeed,
                pulseSpeed: _pulseSpeed,
                pulseAmount: _pulseAmount,
                glowIntensity: _glowIntensity,
                bloomStrength: _bloomStrength,
                transitionProgress: t,
                previousScheme: _colorScheme.rawValue,
                currentScheme: _targetColorScheme.rawValue,
                _padding: 0
            )
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
    
    /// Interpolation speed for gesture-controlled parameters (higher = faster convergence)
    /// 18.0 = ~63% convergence in 55ms, very responsive while still smooth
    private let gestureInterpolationSpeed: Float = 18.0
    
    /// Called by Renderer every frame to smoothly interpolate current values toward targets.
    /// This is the ONLY place smoothing happens for gesture parameters - single source of truth.
    /// Uses frame-rate independent exponential decay for consistent feel at any FPS.
    /// - Parameter deltaTime: Time since last frame in seconds
    func interpolateToTargets(deltaTime: Float) {
        withLock {
            // Guard against bad deltaTime values that could cause instability
            let clampedDT = max(0.001, min(0.1, deltaTime))  // 10ms to 100ms range
            
            // Exponential decay: factor = 1 - e^(-speed * dt)
            // At speed=18, dt=1/90: factor ≈ 0.18 (smooth 90fps)
            // At speed=18, dt=1/45: factor ≈ 0.33 (catches up on slow frames)
            let factor = 1.0 - exp(-gestureInterpolationSpeed * clampedDT)
            
            // Check for NaN/Inf in targets before interpolating
            if _targetMinDistance.isNaN || _targetMinDistance.isInfinite {
                print("⚠️ ANOMALY: targetMinDistance is \(_targetMinDistance), resetting to 0.8")
                _targetMinDistance = 0.8
            }
            if _targetFoldingLimit.isNaN || _targetFoldingLimit.isInfinite {
                print("⚠️ ANOMALY: targetFoldingLimit is \(_targetFoldingLimit), resetting to 1.0")
                _targetFoldingLimit = 1.0
            }
            if _targetSphereRadius.isNaN || _targetSphereRadius.isInfinite {
                print("⚠️ ANOMALY: targetSphereRadius is \(_targetSphereRadius), resetting to 0.5")
                _targetSphereRadius = 0.5
            }
            if _targetPosition.x.isNaN || _targetPosition.y.isNaN || _targetPosition.z.isNaN {
                print("⚠️ ANOMALY: targetPosition contains NaN, resetting to zero")
                _targetPosition = .zero
            }
            
            _minDistance += (_targetMinDistance - _minDistance) * factor
            _foldingLimit += (_targetFoldingLimit - _foldingLimit) * factor
            _sphereRadius += (_targetSphereRadius - _sphereRadius) * factor
            _position += (_targetPosition - _position) * factor
            
            // Clamp current values to sane ranges as a safety net
            _minDistance = max(0.1, min(10.0, _minDistance))
            _foldingLimit = max(0.1, min(20.0, _foldingLimit))
            _sphereRadius = max(0.05, min(5.0, _sphereRadius))
            
            // Clamp position to prevent drifting to infinity
            let maxPos: Float = 100.0
            _position.x = max(-maxPos, min(maxPos, _position.x))
            _position.y = max(-maxPos, min(maxPos, _position.y))
            _position.z = max(-maxPos, min(maxPos, _position.z))
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
