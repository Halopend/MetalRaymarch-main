import Foundation
import os
import simd

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
    
    // ── UserDefaults init helpers ──────────────────────────────────────────
    // Collapse the repetitive 4-line closure pattern into one-liners.
    
    /// Load a persisted Bool, returning `fallback` if the key has never been set.
    private static func loadBool(_ key: String, default fallback: Bool) -> Bool {
        guard UserDefaults.standard.object(forKey: key) != nil else { return fallback }
        return UserDefaults.standard.bool(forKey: key)
    }
    
    /// Load a persisted Float, returning `fallback` when the stored value is 0 (i.e. unset).
    private static func loadFloat(_ key: String, default fallback: Float) -> Float {
        let v = UserDefaults.standard.float(forKey: key)
        return v > 0 ? v : fallback
    }

    private static func loadGestureBinding(_ key: String,
                                           legacyKey: String? = nil,
                                           default fallback: GestureActionBinding) -> GestureActionBinding {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode(GestureActionBinding.self, from: data) {
            return decoded
        }
        // Legacy migration: old Int32 FingerGestureAction raw values
        guard let legacyKey = legacyKey,
              defaults.object(forKey: legacyKey) != nil else { return fallback }
        let legacyRaw = Int32(defaults.integer(forKey: legacyKey))
        guard let legacy = FingerGestureAction(rawValue: legacyRaw),
              FingerGestureAction.coreCases.contains(legacy) else { return fallback }
        return .core(legacy)
    }

    private static func defaultMusicReactiveMappingsFromLegacyToggles() -> [MusicReactiveMapping] {
        // Legacy toggles mapped to the new universal + formula-param targets.
        // foldingLimit → formulaParam1, sphereRadius → formulaParam2 (Mandelbox migration)
        let defaults = UserDefaults.standard
        let legacyToggleByTarget: [(MusicReactiveTarget, String, Bool)] = [
            (.fractalScale,  "fractalAudioAffectsScale", true),
            (.formulaParam1, "fractalAudioAffectsFolding", true),
            (.formulaParam2, "fractalAudioAffectsRadius", true),
            (.colorMix,      "fractalAudioAffectsColorMix", true),
            (.glow,          "fractalAudioAffectsGlow", true),
            (.fog,           "fractalAudioAffectsFog", true),
            (.bloom,         "fractalAudioAffectsBloom", true),
            (.hueSpeed,      "fractalAudioAffectsHueSpeed", true),
            (.saturation,    "fractalAudioAffectsSaturation", true),
            (.iterations,    "fractalAudioAffectsIterations", false)
        ]

        var mappings: [MusicReactiveMapping] = []
        for (target, key, fallback) in legacyToggleByTarget {
            let enabled: Bool
            if defaults.object(forKey: key) != nil {
                enabled = defaults.bool(forKey: key)
            } else {
                enabled = fallback
            }
            if enabled {
                mappings.append(target.defaultMapping(enabled: true))
            }
        }
        return mappings
    }

    private static func loadMusicReactiveMappings(_ key: String) -> [MusicReactiveMapping] {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([MusicReactiveMapping].self, from: data) {
            // Migrate legacy Mandelbox-specific targets (foldingLimit → formulaParam1, etc.)
            let migrated = MusicReactiveMapping.migrateLegacy(decoded)
            return sanitizeMusicReactiveMappings(migrated)
        }
        let migrated = defaultMusicReactiveMappingsFromLegacyToggles()
        if let data = try? JSONEncoder().encode(migrated) {
            defaults.set(data, forKey: key)
        }
        return migrated
    }

    private static func sanitizeMusicReactiveMappings(_ input: [MusicReactiveMapping]) -> [MusicReactiveMapping] {
        var uniqueTargets = Set<MusicReactiveTarget>()
        var cleaned: [MusicReactiveMapping] = []
        for var mapping in input {
            guard uniqueTargets.insert(mapping.target).inserted else { continue }
            mapping.sanitizeInPlace()
            cleaned.append(mapping)
        }
        return cleaned
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
    private var _bassLevel: Float = 0.0             // Bass frequency energy (0-1)
    private var _midLevel: Float = 0.0              // Mid frequency energy (0-1)
    private var _trebleLevel: Float = 0.0           // Treble frequency energy (0-1)
    private var _beatIntensity: Float = 0.0         // Beat onset intensity (0-1)
    private var _visualizerMode: Int32 = 0          // 0=off, 1=pulse, 2=waveform, 3=spectrum
    private var _visualizerIntensity: Float = 0.5   // How much audio affects visuals (0-1)
    private var _bassSensitivity: Float = 1.0        // Multiplier for bass band (0-2)
    private var _midSensitivity: Float = 1.0         // Multiplier for mid band (0-2)
    private var _trebleSensitivity: Float = 1.0      // Multiplier for treble band (0-2)
    private var _beatSensitivity: Float = 1.0        // Multiplier for beat intensity (0-2)
    private var _fractalAudioReactiveEnabled: Bool = loadBool("fractalAudioReactiveEnabled", default: true)
    private var _fractalAudioAmount: Float              = loadFloat("fractalAudioAmount", default: 0.6)
    private var _fractalBeatPunch: Float                = loadFloat("fractalBeatPunch", default: 0.7)
    private var _fractalAudioAffectsScale: Bool         = loadBool("fractalAudioAffectsScale", default: true)
    private var _fractalAudioAffectsFolding: Bool       = loadBool("fractalAudioAffectsFolding", default: true)
    private var _fractalAudioAffectsRadius: Bool        = loadBool("fractalAudioAffectsRadius", default: true)
    private var _fractalAudioAffectsColorMix: Bool      = loadBool("fractalAudioAffectsColorMix", default: true)
    
    // === FRACTAL FORGE–INSPIRED EXTENDED AFFECTS ===
    private var _fractalAudioAffectsGlow: Bool          = loadBool("fractalAudioAffectsGlow", default: true)
    private var _fractalAudioAffectsFog: Bool           = loadBool("fractalAudioAffectsFog", default: true)
    private var _fractalAudioAffectsBloom: Bool         = loadBool("fractalAudioAffectsBloom", default: true)
    private var _fractalAudioAffectsHueSpeed: Bool      = loadBool("fractalAudioAffectsHueSpeed", default: true)
    private var _fractalAudioAffectsSaturation: Bool    = loadBool("fractalAudioAffectsSaturation", default: true)
    private var _fractalAudioAffectsIterations: Bool    = loadBool("fractalAudioAffectsIterations", default: false)
    private var _musicReactiveMappings: [MusicReactiveMapping] = loadMusicReactiveMappings("musicReactiveMappings")
    
    private var _foldingLimit: Float = 1.0
    private var _sphereRadius: Float = 0.5
    private var _colorIterations: Float = 8.0       // Lower = faster (was 10)
    private var _resolutionScale: Float = 1.0       // Render scale for MetalFX (1.0 = native)
    
    private var _fractalType: FractalModelType = .mandelbox  // Current fractal type
    private var _formulaParams: FormulaParams = FractalModelType.mandelbox.defaultFormulaParams()  // Generic formula params
    private var _tileSize: Int = 0                   // 0=disabled, 2=2x2, 4=4x4, 8=8x8 adaptive hierarchical
    private var _debugHierarchical: Bool = false     // Visualize adaptive hierarchy levels
    private var _limitFlash: Float = 0.0             // Flash intensity when gesture hits parameter limit (0-1, decays)
    
    // HUD display
    private var _showHUD: Bool = false               // HUD disabled
    private var _showMusicShortcuts: Bool = loadBool("showMusicShortcuts", default: false)
    private var _isMenuInteractionActive: Bool = false // True while interacting with menu UI (hover/drag)
    private var _activeGestureIndex: Int = 0         // Currently active gesture (0=none, 1=index, 2=middle, 3=ring)
    private var _useRelativeGestures: Bool = true    // Use relative gestures (delta-based) instead of absolute mapping
    private var _extendedGestureRange: Bool = true   // Allow extended parameter ranges for gestures
    private var _rotationAutoSnap: Bool = false       // Snap rotation to nearest 45° multiple within snap window
    private var _rotationSnapWindowDegrees: Float = 6.0  // ±halfWindow snap threshold per axis (degrees)
    private var _rotationBreakawayDegrees: Float = loadFloat("rotationBreakawayDegrees", default: 12.0)
    private var _gestureSensitivity: Float           = loadFloat("gestureSensitivity", default: 3.0)
    private var _gestureSmoothingFactor: Float       = loadFloat("gestureSmoothingFactor", default: 0.5)
    private var _menuToggleGestureEnabled: Bool        = loadBool("menuToggleGestureEnabled", default: true)
    private var _menuToggleGestureMode: MenuToggleGestureMode = {
        let key = "menuToggleGestureMode"
        guard UserDefaults.standard.object(forKey: key) != nil else { return .middleAndRingToPalm }
        let raw = UserDefaults.standard.integer(forKey: key)
        return MenuToggleGestureMode(rawValue: Int32(raw)) ?? .middleAndRingToPalm
    }()

    // ── Per-hand × per-finger gesture binding slots (9 total) ──────────────
    // Migration: on first launch after upgrade, old 4-finger keys are mapped
    // to the new "both" hand slots (two-hand gestures), and right-index gets translate.
    private var _gestureBindings: [String: GestureActionBinding] = {
        var bindings: [String: GestureActionBinding] = [:]
        // Defaults
        let defaults: [String: GestureActionBinding] = [
            "leftIndexBinding":   .core(.none),
            "leftMiddleBinding":  .core(.none),
            "leftRingBinding":    .core(.none),
            "rightIndexBinding":  .core(.translate),
            "rightMiddleBinding": .core(.none),
            "rightRingBinding":   .core(.none),
            "bothIndexBinding":   .core(.grab),
            "bothMiddleBinding":  .core(.minDistance),
            "bothRingBinding":    .core(.fractalScale),
        ]
        // Helper: infer hand mode from persistence key for validation
        func handMode(for key: String) -> GestureHandMode {
            if key.hasPrefix("left")  { return .left }
            if key.hasPrefix("right") { return .right }
            return .both
        }

        // Check if we've already migrated (new keys exist)
        let migrated = UserDefaults.standard.data(forKey: "bothIndexBinding") != nil
        if migrated {
            // Load from new keys, validating each against its hand mode
            for (key, fallback) in defaults {
                let loaded = loadGestureBinding(key, legacyKey: nil, default: fallback)
                bindings[key] = RenderSettings.validated(loaded, forHandMode: handMode(for: key))
            }
        } else {
            // Migrate from old 4-finger keys → both-hand slots
            let oldIndex  = loadGestureBinding("indexFingerBinding",  legacyKey: "indexFingerAction",  default: .core(.grab))
            let oldMiddle = loadGestureBinding("middleFingerBinding", legacyKey: "middleFingerAction", default: .core(.minDistance))
            let oldRing   = loadGestureBinding("ringFingerBinding",   legacyKey: "ringFingerAction",   default: .core(.fractalScale))
            // Map old finger bindings → both-hand (validated for two-hand mode)
            bindings["bothIndexBinding"]  = RenderSettings.validated(oldIndex,  forHandMode: .both)
            bindings["bothMiddleBinding"] = RenderSettings.validated(oldMiddle, forHandMode: .both)
            bindings["bothRingBinding"]   = RenderSettings.validated(oldRing,   forHandMode: .both)
            // Single-hand defaults
            bindings["rightIndexBinding"]  = .core(.translate)
            bindings["rightMiddleBinding"] = .core(.none)
            bindings["rightRingBinding"]   = .core(.none)
            bindings["leftIndexBinding"]   = .core(.none)
            bindings["leftMiddleBinding"]  = .core(.none)
            bindings["leftRingBinding"]    = .core(.none)
            // Persist new keys
            let encoder = JSONEncoder()
            for (key, value) in bindings {
                if let data = try? encoder.encode(value) {
                    UserDefaults.standard.set(data, forKey: key)
                }
            }
        }

        // Final pass: enforce mutual exclusion — if both single-hand slots AND
        // the both-hand slot are non-none for the same digit, clear the both-hand.
        for finger in FingerDigit.allCases {
            let lKey = GestureSlot(hand: .left,  finger: finger).persistenceKey
            let rKey = GestureSlot(hand: .right, finger: finger).persistenceKey
            let bKey = GestureSlot(hand: .both,  finger: finger).persistenceKey
            let lNone = (bindings[lKey].map { if case .core(.none) = $0 { return true } else { return false } }) ?? true
            let rNone = (bindings[rKey].map { if case .core(.none) = $0 { return true } else { return false } }) ?? true
            let bNone = (bindings[bKey].map { if case .core(.none) = $0 { return true } else { return false } }) ?? true
            if !lNone && !rNone && !bNone {
                // Both single-hands active AND both-hand active → clear both-hand
                bindings[bKey] = .core(.none)
            }
        }

        return bindings
    }()
    private var _menuToggleHoldDuration: Float        = loadFloat("menuToggleHoldDuration", default: 0.06)
    private var _menuToggleCooldown: Float              = loadFloat("menuToggleCooldown", default: 0.35)
    private var _menuToggleActivateThreshold: Float     = loadFloat("menuToggleActivateThreshold", default: 0.48)
    private var _menuToggleReleaseThreshold: Float      = loadFloat("menuToggleReleaseThreshold", default: 0.30)
    private var _twoHandPinchActivateThreshold: Float   = loadFloat("twoHandPinchActivateThreshold", default: 0.88)
    private var _twoHandPinchReleaseThreshold: Float    = loadFloat("twoHandPinchReleaseThreshold", default: 0.65)
    private var _ringPinchActivateThreshold: Float      = loadFloat("ringPinchActivateThreshold", default: 0.58)
    private var _ringPinchReleaseThreshold: Float       = loadFloat("ringPinchReleaseThreshold", default: 0.38)
    private var _gestureMinHandDistance: Float          = loadFloat("gestureMinHandDistance", default: 0.05)
    private var _gestureMaxHandDistance: Float          = loadFloat("gestureMaxHandDistance", default: 0.60)
    private var _gestureMaxStartHandDistance: Float     = loadFloat("gestureMaxStartHandDistance", default: 0.45)
    private var _gestureMaxActiveHandDistance: Float    = loadFloat("gestureMaxActiveHandDistance", default: 0.90)
    private var _translationSensitivity: Float          = loadFloat("translationSensitivity", default: 1.0)

    // Safety bubble controls
    private var _safetyBubbleEnabled: Bool = false  // Cut out a small safe sphere (default off)
    private var _safetyBubbleRadius: Float = 1.8    // Radius of the safe bubble (meters)
    private var _safetyBubbleShape: Float = 0.0     // 0 = sphere, 1 = cube, intermediate = morph (no rotation)
    private var _safetyBubbleFadeEnabled: Bool = true
    private var _safetyBubbleFadeWidth: Float = 0.1
    private var _safetyBubbleStrength: Float = 0.5
    
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
    private var _polarRotationEffect: PolarRotationEffect = .off
    private var _beatFlashEffect: BeatFlashEffect = .off
    private var _polarRotationAccum: Float = 0.0              // Accumulated polar rotation angle (radians)
    
    // === DOPPELGANGER MODE ===
    private var _doppelgangerEnabled: Bool = false              // Pre-fold mirror creates structural twin
    private var _doppelgangerPlane: SIMD3<Float> = SIMD3<Float>(1, 0, 0)  // Mirror plane normal (x-axis default)
    private var _doppelgangerOffset: Float = 0.0               // Mirror plane distance from origin
    
    // === GEOMETRY STABILITY STATE ===
    // Tracks whether geometry parameters have settled for optimization
    private var _geometryState: GeometryState = .dynamic
    private var _isGeometryGestureActive: Bool = false
    private var _geometryStableFrameCount: Int = 0           // Frames since geometry settled
    private let geometrySettleThreshold: Float = 0.001       // Threshold for considering parameters settled
    
    // === GMT-FRACTALS OPTIMIZATIONS ===
    // Step over-relaxation: >1.0 takes larger steps for faster convergence.
    // 1.0 = safe default, 1.2-1.5 during stable geometry, reduced during interaction.
    private var _stepMultiplier: Float = 1.0
    
    // === GRADIENT COLORING SYSTEM ===
    // Replaces hardcoded palettes with user-editable gradient stops.
    private var _gradientState: GradientState = GradientState()
    
    // === GMT-FRACTALS: HALTON JITTER TEMPORAL AA ===
    // Sub-pixel jitter for free temporal supersampling when geometry is stable
    private var _haltonJitterEnabled: Bool = RenderSettings.loadBool("haltonJitterEnabled", default: true)
    
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
    private var _targetFractalScale: Float = 2.8
    private var _targetPosition: SIMD3<Float> = SIMD3<Float>(0.1, 0.1, 0.1)
    
    // === TWO-POINT GRAB GESTURE: World rotation + scale ===
    // Driven by two-hand middle-finger pinch grab gesture.
    // worldRotation is a unit quaternion applied in the model matrix.
    // detailScale is a multiplier applied on top of the base `_scale`.
    // Driven by two-hand grab gesture (pulling hands apart/together).
    // Named "detail" to distinguish from Mandelbox `fractalScale` parameter.
    private var _worldRotation: simd_quatf = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)  // identity
    private var _targetWorldRotation: simd_quatf = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    private var _detailScale: Float = 1.0         // Two-point grab scale factor (multiplied with _scale)
    private var _targetDetailScale: Float = 1.0

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
    private var _velocityFractalScale: Float = 0.0
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
    
    // --- Two-point grab world rotation (unit quaternion) ---
    var worldRotation: simd_quatf {
        get { withLock { _worldRotation } }
        set { withLock { _worldRotation = newValue } }
    }
    var targetWorldRotation: simd_quatf {
        get { withLock { _targetWorldRotation } }
        set { withLock { _targetWorldRotation = newValue } }
    }
    /// Detail scale factor (multiplied with base scale) — driven by grab gesture
    var detailScale: Float {
        get { withLock { _detailScale } }
        set { withLock { _detailScale = newValue } }
    }
    var targetDetailScale: Float {
        get { withLock { _targetDetailScale } }
        set { withLock { _targetDetailScale = newValue } }
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
    
    var bassLevel: Float {
        get { withLock { _bassLevel } }
        set { withLock { _bassLevel = max(0.0, min(1.0, newValue)) } }
    }
    
    var midLevel: Float {
        get { withLock { _midLevel } }
        set { withLock { _midLevel = max(0.0, min(1.0, newValue)) } }
    }
    
    var trebleLevel: Float {
        get { withLock { _trebleLevel } }
        set { withLock { _trebleLevel = max(0.0, min(1.0, newValue)) } }
    }
    
    var beatIntensity: Float {
        get { withLock { _beatIntensity } }
        set { withLock { _beatIntensity = max(0.0, min(1.0, newValue)) } }
    }
    
    var visualizerMode: Int32 {
        get { withLock { _visualizerMode } }
        set { withLock { _visualizerMode = newValue } }
    }
    
    var visualizerIntensity: Float {
        get { withLock { _visualizerIntensity } }
        set { withLock { _visualizerIntensity = max(0.0, min(1.0, newValue)) } }
    }
    
    var bassSensitivity: Float {
        get { withLock { _bassSensitivity } }
        set { withLock { _bassSensitivity = max(0.0, min(2.0, newValue)) } }
    }
    
    var midSensitivity: Float {
        get { withLock { _midSensitivity } }
        set { withLock { _midSensitivity = max(0.0, min(2.0, newValue)) } }
    }
    
    var trebleSensitivity: Float {
        get { withLock { _trebleSensitivity } }
        set { withLock { _trebleSensitivity = max(0.0, min(2.0, newValue)) } }
    }
    
    var beatSensitivity: Float {
        get { withLock { _beatSensitivity } }
        set { withLock { _beatSensitivity = max(0.0, min(2.0, newValue)) } }
    }

    var fractalAudioReactiveEnabled: Bool {
        get { withLock { _fractalAudioReactiveEnabled } }
        set {
            withLock { _fractalAudioReactiveEnabled = newValue }
            UserDefaults.standard.set(newValue, forKey: "fractalAudioReactiveEnabled")
        }
    }

    var fractalAudioAmount: Float {
        get { withLock { _fractalAudioAmount } }
        set {
            let clamped = max(0.0, min(1.0, newValue))
            withLock { _fractalAudioAmount = clamped }
            UserDefaults.standard.set(clamped, forKey: "fractalAudioAmount")
        }
    }

    var fractalBeatPunch: Float {
        get { withLock { _fractalBeatPunch } }
        set {
            let clamped = max(0.0, min(1.0, newValue))
            withLock { _fractalBeatPunch = clamped }
            UserDefaults.standard.set(clamped, forKey: "fractalBeatPunch")
        }
    }

    private func mappingEnabledLocked(_ target: MusicReactiveTarget) -> Bool {
        _musicReactiveMappings.first(where: { $0.target == target })?.isEnabled ?? false
    }

    private func setMappingEnabledLocked(_ target: MusicReactiveTarget, enabled: Bool) {
        if let index = _musicReactiveMappings.firstIndex(where: { $0.target == target }) {
            _musicReactiveMappings[index].isEnabled = enabled
        } else if enabled {
            _musicReactiveMappings.append(target.defaultMapping(enabled: true))
        }
        _musicReactiveMappings = Self.sanitizeMusicReactiveMappings(_musicReactiveMappings)
    }

    var musicReactiveMappings: [MusicReactiveMapping] {
        get { withLock { _musicReactiveMappings } }
        set {
            withLock {
                _musicReactiveMappings = Self.sanitizeMusicReactiveMappings(newValue)
            }
            if let data = try? JSONEncoder().encode(withLock { _musicReactiveMappings }) {
                UserDefaults.standard.set(data, forKey: "musicReactiveMappings")
            }
        }
    }

    var fractalAudioAffectsScale: Bool {
        get { withLock { mappingEnabledLocked(.fractalScale) } }
        set {
            withLock {
                _fractalAudioAffectsScale = newValue
                setMappingEnabledLocked(.fractalScale, enabled: newValue)
            }
            UserDefaults.standard.set(newValue, forKey: "fractalAudioAffectsScale")
        }
    }

    var fractalAudioAffectsFolding: Bool {
        get { withLock { mappingEnabledLocked(.formulaParam1) } }
        set {
            withLock {
                _fractalAudioAffectsFolding = newValue
                setMappingEnabledLocked(.formulaParam1, enabled: newValue)
            }
            UserDefaults.standard.set(newValue, forKey: "fractalAudioAffectsFolding")
        }
    }

    var fractalAudioAffectsRadius: Bool {
        get { withLock { mappingEnabledLocked(.formulaParam2) } }
        set {
            withLock {
                _fractalAudioAffectsRadius = newValue
                setMappingEnabledLocked(.formulaParam2, enabled: newValue)
            }
            UserDefaults.standard.set(newValue, forKey: "fractalAudioAffectsRadius")
        }
    }

    var fractalAudioAffectsColorMix: Bool {
        get { withLock { mappingEnabledLocked(.colorMix) } }
        set {
            withLock {
                _fractalAudioAffectsColorMix = newValue
                setMappingEnabledLocked(.colorMix, enabled: newValue)
            }
            UserDefaults.standard.set(newValue, forKey: "fractalAudioAffectsColorMix")
        }
    }
    
    // === FRACTAL FORGE–INSPIRED EXTENDED AFFECTS ===
    
    /// Glow intensity responds to RMS energy + beat pulses (Fractal Forge: glow)
    var fractalAudioAffectsGlow: Bool {
        get { withLock { mappingEnabledLocked(.glow) } }
        set {
            withLock {
                _fractalAudioAffectsGlow = newValue
                setMappingEnabledLocked(.glow, enabled: newValue)
            }
            UserDefaults.standard.set(newValue, forKey: "fractalAudioAffectsGlow")
        }
    }
    
    /// Fog clears on loud passages, thickens on quiet (Fractal Forge: inverse energy)
    var fractalAudioAffectsFog: Bool {
        get { withLock { mappingEnabledLocked(.fog) } }
        set {
            withLock {
                _fractalAudioAffectsFog = newValue
                setMappingEnabledLocked(.fog, enabled: newValue)
            }
            UserDefaults.standard.set(newValue, forKey: "fractalAudioAffectsFog")
        }
    }
    
    /// Bloom strength pulses with beats (Fractal Forge: beat bloom)
    var fractalAudioAffectsBloom: Bool {
        get { withLock { mappingEnabledLocked(.bloom) } }
        set {
            withLock {
                _fractalAudioAffectsBloom = newValue
                setMappingEnabledLocked(.bloom, enabled: newValue)
            }
            UserDefaults.standard.set(newValue, forKey: "fractalAudioAffectsBloom")
        }
    }
    
    /// Hue rotation speed driven by treble (Fractal Forge: brilliance → color speed)
    var fractalAudioAffectsHueSpeed: Bool {
        get { withLock { mappingEnabledLocked(.hueSpeed) } }
        set {
            withLock {
                _fractalAudioAffectsHueSpeed = newValue
                setMappingEnabledLocked(.hueSpeed, enabled: newValue)
            }
            UserDefaults.standard.set(newValue, forKey: "fractalAudioAffectsHueSpeed")
        }
    }
    
    /// Color saturation responds to tonal/harmonic energy
    var fractalAudioAffectsSaturation: Bool {
        get { withLock { mappingEnabledLocked(.saturation) } }
        set {
            withLock {
                _fractalAudioAffectsSaturation = newValue
                setMappingEnabledLocked(.saturation, enabled: newValue)
            }
            UserDefaults.standard.set(newValue, forKey: "fractalAudioAffectsSaturation")
        }
    }
    
    /// Fractal iterations increase with mid energy (detail on transients — caution: performance)
    var fractalAudioAffectsIterations: Bool {
        get { withLock { mappingEnabledLocked(.iterations) } }
        set {
            withLock {
                _fractalAudioAffectsIterations = newValue
                setMappingEnabledLocked(.iterations, enabled: newValue)
            }
            UserDefaults.standard.set(newValue, forKey: "fractalAudioAffectsIterations")
        }
    }
    
    // ═══════════════════════════════════════════════════════════════════════════
    // AUDIO MODULATION SETTERS (bypass lighting preset tracking)
    // Used by Renderer for per-frame audio-reactive modulation without
    // triggering _lightingPreset = .custom every frame.
    // ═══════════════════════════════════════════════════════════════════════════
    
    /// Modulate glow intensity (auto-enables glow if needed)
    func audioModulateGlowIntensity(_ value: Float) {
        withLock {
            _glowEffect.enabled = true
            _glowEffect.intensity = max(0.0, min(1.0, value))
        }
    }
    
    /// Modulate fog intensity (auto-enables fog if needed)
    func audioModulateFogIntensity(_ value: Float) {
        withLock {
            _fogEffect.enabled = true
            _fogEffect.intensity = max(0.0, min(1.0, value))
        }
    }
    
    /// Modulate bloom strength (auto-enables bloom if needed)
    func audioModulateBloomStrength(_ value: Float) {
        withLock {
            _bloomEffect.enabled = true
            _bloomEffect.strength = max(0.0, min(1.0, value))
        }
    }
    
    /// Modulate hue rotation speed (auto-enables hue rotation if needed)
    func audioModulateHueSpeed(_ value: Float) {
        withLock {
            _hueRotationEffect.enabled = true
            _hueRotationEffect.speed = max(0.0, min(0.5, value))
        }
    }
    
    /// Modulate color scheme saturation
    func audioModulateSaturation(_ value: Float) {
        withLock {
            _colorSchemeSaturation = max(0.0, min(3.0, value))
        }
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
        set {
            withLock {
                _fractalType = newValue
                // Auto-set default formula params when switching types
                _formulaParams = newValue.defaultFormulaParams()
                // Rebind any gesture fingers assigned to core actions unsupported by
                // the new fractal type (e.g. fractalScale on non-Mandelbox), and
                // clean cross-type .parameter() bindings that belong to a different
                // fractal type.
                let supported = Set(newValue.supportedCoreGestureActions)
                func sanitize(_ binding: inout GestureActionBinding) {
                    switch binding {
                    case .core(let action):
                        if !supported.contains(action) {
                            binding = .core(.none)
                        }
                    case .parameter(let descriptor):
                        if descriptor.fractalType != newValue {
                            binding = .core(.none)
                        }
                    case .parameterTriplet(let triplet):
                        if triplet.fractalType != newValue {
                            binding = .core(.none)
                        }
                    }
                }
                for key in _gestureBindings.keys {
                    if var binding = _gestureBindings[key] {
                        sanitize(&binding)
                        _gestureBindings[key] = binding
                    }
                }

                // Restore default both-hand bindings for any slot that was
                // cleared to .none, provided the default is supported by the new type.
                // This ensures switching back to Mandelbox automatically re-enables
                // the standard geometry gesture mappings.
                let slotDefaults: [String: GestureActionBinding] = [
                    "bothIndexBinding":   .core(.grab),
                    "bothMiddleBinding":  .core(.minDistance),
                    "bothRingBinding":    .core(.fractalScale),
                    "rightIndexBinding":  .core(.translate),
                ]
                func restoreDefault(_ binding: inout GestureActionBinding, _ fallback: GestureActionBinding) {
                    if case .core(.none) = binding,
                       case .core(let action) = fallback,
                       supported.contains(action) {
                        binding = fallback
                    }
                }
                for (key, fallback) in slotDefaults {
                    if var binding = _gestureBindings[key] {
                        restoreDefault(&binding, fallback)
                        _gestureBindings[key] = binding
                    }
                }
            }
        }
    }

    var formulaParams: FormulaParams {
        get { withLock { _formulaParams } }
        set { withLock { _formulaParams = newValue } }
    }

    // 0 = disabled (standard per-pixel raymarch)
    // 2 = 2x2 tiles (4x overhead reduction, high quality)
    // 4 = 4x4 tiles (16x overhead reduction, performance mode)
    // 8 = 8x8 adaptive hierarchical (3-8x speedup, best performance)
    var tileSize: Int {
        get { withLock { _tileSize } }
        set { withLock { _tileSize = newValue } }
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
        get { false }
        set { /* HUD disabled */ }
    }

    var showMusicShortcuts: Bool {
        get { withLock { _showMusicShortcuts } }
        set {
            withLock { _showMusicShortcuts = newValue }
            UserDefaults.standard.set(newValue, forKey: "showMusicShortcuts")
        }
    }

    /// Whether menu UI interaction is currently active.
    /// Used to suppress gesture motion bleed-through and bias rendering for UI responsiveness.
    var isMenuInteractionActive: Bool {
        get { withLock { _isMenuInteractionActive } }
        set { withLock { _isMenuInteractionActive = newValue } }
    }
    
    var activeGestureIndex: Int {
        get { withLock { _activeGestureIndex } }
        set { withLock { _activeGestureIndex = newValue } }
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

    /// Snap world rotation to nearest 45° multiple on each Euler axis when grab gesture ends
    var rotationAutoSnap: Bool {
        get { withLock { _rotationAutoSnap } }
        set { withLock { _rotationAutoSnap = newValue } }
    }

    /// Half-angle snap window in degrees (±this value). Default 6° → snaps within ±3° of target.
    var rotationSnapWindowDegrees: Float {
        get { withLock { _rotationSnapWindowDegrees } }
        set { withLock { _rotationSnapWindowDegrees = max(1.0, min(30.0, newValue)) } }
    }

    var rotationBreakawayDegrees: Float {
        get { withLock { _rotationBreakawayDegrees } }
        set {
            let clamped = max(0.0, min(45.0, newValue))
            withLock { _rotationBreakawayDegrees = clamped }
            UserDefaults.standard.set(clamped, forKey: "rotationBreakawayDegrees")
        }
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

    var gestureSmoothingFactor: Float {
        get { withLock { _gestureSmoothingFactor } }
        set {
            let clamped = max(0.0, min(1.0, newValue))
            withLock { _gestureSmoothingFactor = clamped }
            UserDefaults.standard.set(clamped, forKey: "gestureSmoothingFactor")
        }
    }

    /// Enable/disable the menu toggle gesture without disabling parameter gestures.
    var menuToggleGestureEnabled: Bool {
        get { withLock { _menuToggleGestureEnabled } }
        set {
            withLock { _menuToggleGestureEnabled = newValue }
            UserDefaults.standard.set(newValue, forKey: "menuToggleGestureEnabled")
        }
    }

    /// Which right-hand gesture toggles the floating menu window.
    var menuToggleGestureMode: MenuToggleGestureMode {
        get { withLock { _menuToggleGestureMode } }
        set {
            withLock { _menuToggleGestureMode = newValue }
            UserDefaults.standard.set(Int(newValue.rawValue), forKey: "menuToggleGestureMode")
        }
    }

    // ── Per-hand gesture binding accessors ──────────────────────────────────
    private func persistGestureBinding(_ binding: GestureActionBinding, key: String) {
        if let data = try? JSONEncoder().encode(binding) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// Get binding for a specific hand+finger slot.
    func binding(for slot: GestureSlot) -> GestureActionBinding {
        withLock { _gestureBindings[slot.persistenceKey] ?? .core(.none) }
    }

    /// Set binding for a specific hand+finger slot.
    /// Enforces mutual exclusion between single-hand and both-hand slots,
    /// and validates that the binding is appropriate for the hand mode.
    func setBinding(_ binding: GestureActionBinding, for slot: GestureSlot) {
        // Validate binding is appropriate for the hand mode
        let validated = Self.validated(binding, forHandMode: slot.hand)
        let key = slot.persistenceKey
        withLock {
            _gestureBindings[key] = validated
            // ── Mutual exclusion: single-hand vs two-hand ──────────────
            if case .core(.none) = validated { /* clearing — no conflict to resolve */ } else {
                if slot.hand == .left || slot.hand == .right {
                    let otherHand: GestureHandMode = (slot.hand == .left) ? .right : .left
                    let otherKey = GestureSlot(hand: otherHand, finger: slot.finger).persistenceKey
                    if let otherBinding = _gestureBindings[otherKey],
                       !(otherBinding == .core(.none)) {
                        let bothKey = GestureSlot(hand: .both, finger: slot.finger).persistenceKey
                        _gestureBindings[bothKey] = .core(.none)
                        persistGestureBinding(.core(.none), key: bothKey)
                    }
                } else if slot.hand == .both {
                    let leftKey = GestureSlot(hand: .left, finger: slot.finger).persistenceKey
                    let rightKey = GestureSlot(hand: .right, finger: slot.finger).persistenceKey
                    _gestureBindings[leftKey] = .core(.none)
                    _gestureBindings[rightKey] = .core(.none)
                    persistGestureBinding(.core(.none), key: leftKey)
                    persistGestureBinding(.core(.none), key: rightKey)
                }
            }
        }
        persistGestureBinding(validated, key: key)
    }

    /// Validates that a binding is appropriate for the given hand mode.
    /// Returns `.core(.none)` for invalid combinations (e.g. `.translate` on both-hand).
    static func validated(_ binding: GestureActionBinding, forHandMode hand: GestureHandMode) -> GestureActionBinding {
        switch hand {
        case .both:
            // Both-hand only supports core (except .translate) and scalar .parameter
            if case .core(.translate) = binding { return .core(.none) }
            if case .parameterTriplet = binding { return .core(.none) }
            return binding
        case .left, .right:
            // Single-hand supports .translate, .parameter, .parameterTriplet, .core(.none)
            // Does NOT support .core(.grab), .core(.minDistance), etc.
            if case .core(let action) = binding {
                if action == .none || action == .translate { return binding }
                return .core(.none) // two-hand-only core actions
            }
            return binding
        }
    }

    /// Find the slot currently assigned to a given binding, or nil.
    func slot(for binding: GestureActionBinding) -> GestureSlot? {
        withLock {
            for slot in GestureSlot.allSlots {
                if _gestureBindings[slot.persistenceKey] == binding {
                    return slot
                }
            }
            return nil
        }
    }

    /// Returns the binding for a given hand mode and digit (1=index, 2=middle, 3=ring).
    func binding(forHand hand: GestureHandMode, digit: Int) -> GestureActionBinding {
        guard let finger = FingerDigit(rawValue: digit) else { return .core(.none) }
        return binding(for: GestureSlot(hand: hand, finger: finger))
    }

    /// How long the menu gesture must be held before toggling (seconds).
    var menuToggleHoldDuration: Float {
        get { withLock { _menuToggleHoldDuration } }
        set {
            let clamped = max(0.05, min(0.6, newValue))
            withLock { _menuToggleHoldDuration = clamped }
            UserDefaults.standard.set(clamped, forKey: "menuToggleHoldDuration")
        }
    }

    /// Cooldown between menu toggle triggers (seconds).
    var menuToggleCooldown: Float {
        get { withLock { _menuToggleCooldown } }
        set {
            let clamped = max(0.1, min(2.5, newValue))
            withLock { _menuToggleCooldown = clamped }
            UserDefaults.standard.set(clamped, forKey: "menuToggleCooldown")
        }
    }

    var menuToggleActivateThreshold: Float {
        get { withLock { _menuToggleActivateThreshold } }
        set {
            let clamped = max(0.2, min(0.95, newValue))
            withLock { _menuToggleActivateThreshold = clamped }
            UserDefaults.standard.set(clamped, forKey: "menuToggleActivateThreshold")
        }
    }

    var menuToggleReleaseThreshold: Float {
        get { withLock { _menuToggleReleaseThreshold } }
        set {
            let clamped = max(0.1, min(0.9, newValue))
            withLock { _menuToggleReleaseThreshold = clamped }
            UserDefaults.standard.set(clamped, forKey: "menuToggleReleaseThreshold")
        }
    }

    var twoHandPinchActivateThreshold: Float {
        get { withLock { _twoHandPinchActivateThreshold } }
        set {
            let clamped = max(0.2, min(0.98, newValue))
            withLock { _twoHandPinchActivateThreshold = clamped }
            UserDefaults.standard.set(clamped, forKey: "twoHandPinchActivateThreshold")
        }
    }

    var twoHandPinchReleaseThreshold: Float {
        get { withLock { _twoHandPinchReleaseThreshold } }
        set {
            let clamped = max(0.1, min(0.95, newValue))
            withLock { _twoHandPinchReleaseThreshold = clamped }
            UserDefaults.standard.set(clamped, forKey: "twoHandPinchReleaseThreshold")
        }
    }

    var ringPinchActivateThreshold: Float {
        get { withLock { _ringPinchActivateThreshold } }
        set {
            let clamped = max(0.1, min(0.95, newValue))
            withLock { _ringPinchActivateThreshold = clamped }
            UserDefaults.standard.set(clamped, forKey: "ringPinchActivateThreshold")
        }
    }

    var ringPinchReleaseThreshold: Float {
        get { withLock { _ringPinchReleaseThreshold } }
        set {
            let clamped = max(0.05, min(0.9, newValue))
            withLock { _ringPinchReleaseThreshold = clamped }
            UserDefaults.standard.set(clamped, forKey: "ringPinchReleaseThreshold")
        }
    }

    var gestureMinHandDistance: Float {
        get { withLock { _gestureMinHandDistance } }
        set {
            let clamped = max(0.02, min(0.25, newValue))
            withLock { _gestureMinHandDistance = clamped }
            UserDefaults.standard.set(clamped, forKey: "gestureMinHandDistance")
        }
    }

    var gestureMaxHandDistance: Float {
        get { withLock { _gestureMaxHandDistance } }
        set {
            let clamped = max(0.2, min(1.2, newValue))
            withLock { _gestureMaxHandDistance = max(clamped, _gestureMinHandDistance + 0.05) }
            UserDefaults.standard.set(withLock { _gestureMaxHandDistance }, forKey: "gestureMaxHandDistance")
        }
    }

    var gestureMaxStartHandDistance: Float {
        get { withLock { _gestureMaxStartHandDistance } }
        set {
            let clamped = max(0.08, min(1.0, newValue))
            withLock { _gestureMaxStartHandDistance = clamped }
            UserDefaults.standard.set(clamped, forKey: "gestureMaxStartHandDistance")
        }
    }

    var gestureMaxActiveHandDistance: Float {
        get { withLock { _gestureMaxActiveHandDistance } }
        set {
            let clamped = max(0.1, min(1.5, newValue))
            withLock { _gestureMaxActiveHandDistance = max(clamped, _gestureMaxStartHandDistance) }
            UserDefaults.standard.set(withLock { _gestureMaxActiveHandDistance }, forKey: "gestureMaxActiveHandDistance")
        }
    }

    var translationSensitivity: Float {
        get { withLock { _translationSensitivity } }
        set {
            let clamped = max(0.2, min(3.0, newValue))
            withLock { _translationSensitivity = clamped }
            UserDefaults.standard.set(clamped, forKey: "translationSensitivity")
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

    /// Compatibility alias for the legacy safety-bubble blend slider.
    /// Maps onto the shader's temporal bubble-strength control.
    var safetyBubbleBlend: Float {
        get { withLock { _safetyBubbleStrength } }
        set { withLock { _safetyBubbleStrength = max(0.0, min(1.0, newValue)) } }
    }

    var safetyBubbleFadeEnabled: Bool {
        get { withLock { _safetyBubbleFadeEnabled } }
        set { withLock { _safetyBubbleFadeEnabled = newValue } }
    }

    var safetyBubbleFadeWidth: Float {
        get { withLock { _safetyBubbleFadeWidth } }
        set { withLock { _safetyBubbleFadeWidth = max(0.0, min(1.0, newValue)) } }
    }

    var safetyBubbleStrength: Float {
        get { withLock { _safetyBubbleStrength } }
        set { withLock { _safetyBubbleStrength = max(0.0, min(1.0, newValue)) } }
    }
    
    // === COLOR SCHEME SETTINGS ===
    // Controls the color palette and transitions for fractal coloring
    
    /// Current color scheme (or target when transitioning)
    var colorScheme: ColorScheme {
        get { withLock { _colorScheme } }
        set { 
            withLock { 
                if _targetColorScheme != newValue {
                    _targetColorScheme = newValue
                    _colorSchemeTransitionProgress = 0.0
                }
                syncGradientPresetForColorSchemeLocked(newValue)
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

    /// Beat flash effect (music-driven edge flash)
    var beatFlashEffect: BeatFlashEffect {
        get { withLock { _beatFlashEffect } }
        set {
            withLock {
                _beatFlashEffect = newValue
                _lightingPreset = .custom
            }
        }
    }

    /// Polar rotation effect (animates polar angle for Mandelbulb / Quaternion Julia)
    var polarRotationEffect: PolarRotationEffect {
        get { withLock { _polarRotationEffect } }
        set {
            withLock {
                _polarRotationEffect = newValue
                _lightingPreset = .custom
            }
        }
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
    
    // === GMT-FRACTALS: HALTON JITTER TEMPORAL AA ===
    
    /// Enable Halton sub-pixel jitter for temporal anti-aliasing when geometry is stable.
    /// Provides free supersampling at 90Hz via display persistence.
    var haltonJitterEnabled: Bool {
        get { withLock { _haltonJitterEnabled } }
        set {
            withLock { _haltonJitterEnabled = newValue }
            UserDefaults.standard.set(newValue, forKey: "haltonJitterEnabled")
        }
    }
    
    // === GEOMETRY STABILITY STATE (read-only) ===
    
    /// Whether a geometry-affecting gesture is currently active (read-only).
    /// Set internally by the geometry state machine in `interpolateToTargets`.
    var isGeometryGestureActive: Bool {
        get { withLock { _isGeometryGestureActive } }
        set { withLock { _isGeometryGestureActive = newValue } }
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

            // Accumulate polar rotation angle when enabled and fractal supports it
            if _polarRotationEffect.enabled && _fractalType.supports(.polarRotation) {
                _polarRotationAccum += deltaTime * _polarRotationEffect.speed * _polarRotationEffect.amplitude
            }
            
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
                    let allSchemes = ColorScheme.allCases
                    if let currentIndex = allSchemes.firstIndex(of: _targetColorScheme), !allSchemes.isEmpty {
                        let nextScheme = allSchemes[(currentIndex + 1) % allSchemes.count]
                        _colorScheme = _targetColorScheme
                        _targetColorScheme = nextScheme
                        _colorSchemeTransitionProgress = 0.0
                        syncGradientPresetForColorSchemeLocked(nextScheme)
                    }
                }
            }
        }
    }

    @inline(__always)
    private func syncGradientPresetForColorSchemeLocked(_ scheme: ColorScheme) {
        guard let preset = GradientPreset.fromColorScheme(scheme) else { return }
        if _gradientState.gradientPreset != preset || !_gradientState.useGradientColoring {
            _gradientState.applyPreset(preset)
            _gradientState.useGradientColoring = true
        }
    }
    
    private func makeColorSchemeParamsLocked() -> ColorSchemeParams {
        let currentNeon = _targetColorScheme.neonParams
        let previousNeon = _colorScheme.neonParams
        let t = _colorSchemeTransitionProgress
        
        // Interpolate neon intensity (0 for non-neon, 1 for neon)
        let prevNeonIntensity: Float = _colorScheme.isNeonMode ? 1.0 : 0.0
        let currNeonIntensity: Float = _targetColorScheme.isNeonMode ? 1.0 : 0.0
        let neonIntensity = prevNeonIntensity + (currNeonIntensity - prevNeonIntensity) * t
        
        // Interpolate neon parameters
        let hueFreq = previousNeon.hueFreq + (currentNeon.hueFreq - previousNeon.hueFreq) * t
        let hueOffset = previousNeon.hueOffset + (currentNeon.hueOffset - previousNeon.hueOffset) * t
        let bandFreq = previousNeon.bandFreq + (currentNeon.bandFreq - previousNeon.bandFreq) * t
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
            glowSharpness: glowSharpness,
            saturationPower: satPower,
            // === GRADIENT COLORING ===
            gradientStops: gs,
            gradientStopCount: Int32(gradCount),
            colorMappingMode: Int32(gradState.gradient.mappingMode.rawValue),
            gradientRepeat: gradState.gradient.repeatCount,
            gradientOffset: gradState.gradient.offset + (_gradientCycleEffect.enabled ? fmod(_colorAnimTime * _gradientCycleEffect.speed, 1.0) : 0),
            gradientSmoothing: gradState.gradient.smoothing,
            gradientLoopSmooth: _gradientCycleEffect.mirrorLoop ? 1 : 0,
            _gradPad: (0.0),
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
            beatFlashEnabled: _beatFlashEffect.enabled ? 1 : 0,
            beatFlashIntensity: _beatFlashEffect.intensity
        )
    }
    
    /// Get a snapshot of render-critical settings in a single lock.
    func snapshot() -> RenderSettingsSnapshot {
        return withLock {
            // Apply animated polar rotation offset into a local copy of formulaParams
            var fp = _formulaParams
            if _polarRotationEffect.enabled && _fractalType.supports(.polarRotation) {
                switch _fractalType {
                case .mandelbulb:
                    // params[4] = PolarRotation — add accumulated anim offset to user's static value
                    let base = FormulaCatalog.getParam(fp, index: 4)
                    FormulaCatalog.setParam(&fp, index: 4, value: base + _polarRotationAccum)
                case .quaternionJulia:
                    // Rotate the C-constant through the (x,y) plane of quaternion space
                    let cx = FormulaCatalog.getParam(fp, index: 0)
                    let cy = FormulaCatalog.getParam(fp, index: 1)
                    let cosA = cos(_polarRotationAccum)
                    let sinA = sin(_polarRotationAccum)
                    FormulaCatalog.setParam(&fp, index: 0, value: cx * cosA - cy * sinA)
                    FormulaCatalog.setParam(&fp, index: 1, value: cx * sinA + cy * cosA)
                default:
                    break
                }
            }

            return RenderSettingsSnapshot(
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
                bassLevel: _bassLevel,
                midLevel: _midLevel,
                trebleLevel: _trebleLevel,
                beatIntensity: _beatIntensity,
                visualizerMode: _visualizerMode,
                visualizerIntensity: _visualizerIntensity,
                foldingLimit: _foldingLimit,
                sphereRadius: _sphereRadius,
                colorIterations: _colorIterations,
                resolutionScale: _resolutionScale,
                fractalType: _fractalType,
                formulaParams: fp,
                tileSize: _tileSize,
                debugHierarchical: _debugHierarchical,
                limitFlash: _limitFlash,
                showHUD: _showHUD,
                activeGestureIndex: _activeGestureIndex,
                safetyBubbleEnabled: _safetyBubbleEnabled,
                safetyBubbleRadius: _safetyBubbleRadius,
                safetyBubbleShape: _safetyBubbleShape,
                safetyBubbleFadeEnabled: _safetyBubbleFadeEnabled,
                safetyBubbleFadeWidth: _safetyBubbleFadeWidth,
                safetyBubbleStrength: _safetyBubbleStrength,
                colorSchemeParams: makeColorSchemeParamsLocked(),
                lightingSoftness: _lightingSoftness,
                fogIntensity: _fogEffect.intensity,
                worldRotation: _worldRotation,
                detailScale: _detailScale,
                geometryState: _geometryState,
                isGeometryGestureActive: _isGeometryGestureActive,
                stepMultiplier: _stepMultiplier
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
            syncGradientPresetForColorSchemeLocked(scheme)
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
    
    var targetFractalScale: Float {
        get { withLock { _targetFractalScale } }
        set { withLock { _targetFractalScale = newValue } }
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
            _isAnimationPlaying ? _animationBaseFractalScale + _manualOffsetFractalScale : _targetFractalScale
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
            
            // ═══════════════════════════════════════════════════════════════════════════
            // ANIMATION OFFSET DECAY: When animation is playing and no gesture is
            // active, tween manual offsets back to zero so the animation reasserts
            // as the source of truth. This prevents "sticky" gesture perturbations
            // that cause flickering when the user stops touching.
            // ═══════════════════════════════════════════════════════════════════════════
            if _isAnimationPlaying && !_isGeometryGestureActive {
                let decayRate: Float = 1.0 - exp(-6.0 * clampedDT)  // ~6Hz half-life
                _manualOffsetMinDistance   *= (1.0 - decayRate)
                _manualOffsetFoldingLimit  *= (1.0 - decayRate)
                _manualOffsetSphereRadius  *= (1.0 - decayRate)
                _manualOffsetFractalScale  *= (1.0 - decayRate)
                _manualOffsetPosition      *= (1.0 - decayRate)
                // Snap to zero when negligible to avoid micro-drift
                if abs(_manualOffsetMinDistance)  < 1e-5 { _manualOffsetMinDistance = 0 }
                if abs(_manualOffsetFoldingLimit) < 1e-5 { _manualOffsetFoldingLimit = 0 }
                if abs(_manualOffsetSphereRadius) < 1e-5 { _manualOffsetSphereRadius = 0 }
                if abs(_manualOffsetFractalScale) < 1e-5 { _manualOffsetFractalScale = 0 }
                if simd_length_squared(_manualOffsetPosition) < 1e-10 { _manualOffsetPosition = .zero }
            }

            // ═══════════════════════════════════════════════════════════════════════════
            // MANDELBOX BRIDGE: Sync formula params → target properties
            // Mandelbox's shader reads minDistance / foldingLimit / sphereRadius from
            // dedicated uniform fields (not formulaParams).  All user-facing write paths
            // now go through formulaParams, so we bridge into the target* properties
            // here so the existing smoothDamp → snapshot → shader pipeline works.
            // During animation playback the AnimationManager drives targets directly,
            // so skip the bridge to avoid overwriting the animation's values.
            // ═══════════════════════════════════════════════════════════════════════════
            if _fractalType == .mandelbox && !_isAnimationPlaying {
                _targetMinDistance   = FormulaCatalog.getParam(_formulaParams, index: 0)
                _targetFoldingLimit  = FormulaCatalog.getParam(_formulaParams, index: 1)
                _targetSphereRadius  = FormulaCatalog.getParam(_formulaParams, index: 2)
            }
            
            // ═══════════════════════════════════════════════════════════════════════════
            // GMT-FRACTALS PATTERN: Convergence Lock
            // Like VirtualSpace.updateSmoothing which skips computation when distSq < 1e-21,
            // skip the expensive smoothDamp calls when all parameters have converged AND
            // all velocities are near zero. This saves ~7 smoothDamp calls per frame at 90Hz
            // (630 calls/sec) when the fractal is sitting still.
            // ═══════════════════════════════════════════════════════════════════════════
            let convergenceThreshold: Float = 1e-6
            let velocityThreshold: Float = 1e-5
            let distSqMinDist = (_minDistance - _targetMinDistance) * (_minDistance - _targetMinDistance)
            let distSqFold = (_foldingLimit - _targetFoldingLimit) * (_foldingLimit - _targetFoldingLimit)
            let distSqSphere = (_sphereRadius - _targetSphereRadius) * (_sphereRadius - _targetSphereRadius)
            let distSqScale = (_fractalScale - _targetFractalScale) * (_fractalScale - _targetFractalScale)
            let posDiff = _position - _targetPosition
            let distSqPos = posDiff.x * posDiff.x + posDiff.y * posDiff.y + posDiff.z * posDiff.z
            let totalDistSq = distSqMinDist + distSqFold + distSqSphere + distSqScale + distSqPos
            let totalVelSq = _velocityMinDistance * _velocityMinDistance +
                             _velocityFoldingLimit * _velocityFoldingLimit +
                             _velocitySphereRadius * _velocitySphereRadius +
                             _velocityFractalScale * _velocityFractalScale +
                             simd_dot(_velocityPosition, _velocityPosition)
            
            let isConverged = totalDistSq < convergenceThreshold && totalVelSq < velocityThreshold
            
            if isConverged {
                // Snap to exact targets and zero velocities to prevent micro-drift
                _minDistance = _targetMinDistance
                _foldingLimit = _targetFoldingLimit
                _sphereRadius = _targetSphereRadius
                _fractalScale = _targetFractalScale
                _position = _targetPosition
                _worldRotation = _targetWorldRotation
                _detailScale = _targetDetailScale
                _velocityMinDistance = 0.0
                _velocityFoldingLimit = 0.0
                _velocitySphereRadius = 0.0
                _velocityFractalScale = 0.0
                _velocityPosition = .zero
                
                // Still update geometry state machine when converged
                if !_isGeometryGestureActive && _geometryState != .stable {
                    _geometryState = .stable
                    _geometryStableFrameCount = 0
                } else if _geometryState == .stable {
                    _geometryStableFrameCount += 1
                }
                // Step multiplier stays at 1.2 when converged (already settled)
                let targetStepMultiplier: Float = 1.2
                _stepMultiplier += (targetStepMultiplier - _stepMultiplier) * 0.1
            } else {
            
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
            if _targetFractalScale.isNaN || _targetFractalScale.isInfinite {
                print("⚠️ ANOMALY: targetFractalScale is \(_targetFractalScale), resetting to 2.8")
                _targetFractalScale = 2.8
                _velocityFractalScale = 0.0
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
            
            _fractalScale = smoothDamp(
                current: _fractalScale,
                target: _targetFractalScale,
                velocity: &_velocityFractalScale,
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
            
            // Smooth interpolation for world rotation (slerp) and grab scale (exp lerp)
            let rotLerpT = 1.0 - exp(-12.0 * clampedDT)  // Same speed as main smoothing
            _worldRotation = simd_slerp(_worldRotation, _targetWorldRotation, rotLerpT)
            // Re-normalize to prevent drift
            _worldRotation = _worldRotation.normalized
            
            let scaleRatio = _targetDetailScale / max(_detailScale, 1e-6)
            let logRatio = log(max(scaleRatio, 1e-6))
            _detailScale *= exp(logRatio * rotLerpT)  // Exponential lerp for multiplicative scale
            
            // Clamp current values to sane ranges as a safety net
            // These MUST cover the full gesture/slider ranges (including negatives
            // for inverted effects) otherwise gestures and UI appear to "stop working"
            // at the clamp boundary.
            // Standard ranges:  minDist -2…8, fold -5…20, sphere -3…4
            // Extended ranges:  minDist -5…15, fold -10…30, sphere -5…8
            _minDistance = max(-5.0, min(15.0, _minDistance))
            _foldingLimit = max(-10.0, min(30.0, _foldingLimit))
            _sphereRadius = max(-5.0, min(8.0, _sphereRadius))
            _fractalScale = max(-5.0, min(8.0, _fractalScale))
            
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
            let scaleSettled = abs(_fractalScale - _targetFractalScale) < geometrySettleThreshold
            let allGeometrySettled = minDistSettled && foldSettled && sphereSettled && scaleSettled
            
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
            
            } // end convergence lock else
        }
    }
    
    /// When animation stops/pauses, bake manual offsets into targets and clear offsets.
    /// Also zeroes spring velocities to prevent overshoot/ringing.
    func commitAnimationOffsetsToTargets() {
        withLock {
            _targetMinDistance = _minDistance
            _targetFoldingLimit = _foldingLimit
            _targetSphereRadius = _sphereRadius
            _targetFractalScale = _fractalScale
            _targetPosition = _position
            _manualOffsetMinDistance = 0.0
            _manualOffsetFoldingLimit = 0.0
            _manualOffsetSphereRadius = 0.0
            _manualOffsetFractalScale = 0.0
            _manualOffsetPosition = .zero
            // Zero spring velocities so interpolation doesn't overshoot
            _velocityMinDistance = 0.0
            _velocityFoldingLimit = 0.0
            _velocitySphereRadius = 0.0
            _velocityFractalScale = 0.0
            _velocityPosition = .zero
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
    
    /// Apply grab-gesture state with lightweight one-pole lerp smoothing.
    /// Much faster than the full smooth-damp pipeline but takes the edge off
    /// hand-tracking jitter. Uses an adaptive rate: slower for tiny movements
    /// (dead-zone on noise), faster for clear intentional motion.
    func applyDetailState(position: SIMD3<Float>, worldRotation: simd_quatf, detailScale: Float, responsiveness: Float = 0.75) {
        withLock {
            // Adaptive lerp: base 0.30 (smoother), ramp up to 0.55 for large motions.
            // This damps hand-tracking micro-jitter while keeping big gestures snappy.
            let positionDelta = simd_length(position - _position)
            let scaleDelta = abs(log(max(detailScale, 1e-6)) - log(max(_detailScale, 1e-6)))
            let motionMag = positionDelta + scaleDelta * 0.5  // rough combined metric
            let tBase: Float = 0.30
            let tMax:  Float = 0.55
            let rampStart: Float = 0.001   // below this → mostly noise
            let rampEnd:   Float = 0.02    // above this → full response
            let rampT = simd_clamp((motionMag - rampStart) / (rampEnd - rampStart), 0, 1)
            let baseT = tBase + (tMax - tBase) * rampT
            let responsivenessClamped = simd_clamp(responsiveness, 0.0, 1.0)
            let t = simd_clamp(baseT * (0.5 + 0.5 * responsivenessClamped), 0.0, 1.0)
            
            // Position: lerp current toward new value, keep target = raw input
            _position = _position + (position - _position) * t
            _targetPosition = _position  // keep in sync so smooth-damp doesn't fight us
            _velocityPosition = .zero
            
            // Rotation: slerp current toward new value
            _worldRotation = simd_slerp(_worldRotation, worldRotation, t)
            _worldRotation = _worldRotation.normalized
            _targetWorldRotation = _worldRotation
            
            // Scale: exponential lerp (so doubling and halving feel symmetric)
            let logCurrent = log(max(_detailScale, 1e-6))
            let logTarget = log(max(detailScale, 1e-6))
            _detailScale = exp(logCurrent + (logTarget - logCurrent) * t)
            _targetDetailScale = _detailScale
        }
    }
    
    /// Reset detail transform to identity (worldRotation = identity, detailScale = 1)
    func resetDetailTransform() {
        withLock {
            let identity = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
            _worldRotation = identity
            _targetWorldRotation = identity
            _detailScale = 1.0
            _targetDetailScale = 1.0
        }
    }

    // MARK: - Rotation Auto-Snap

    /// Snap the world rotation target to the nearest 45° multiple on each Euler axis
    /// if the current angle is within the snap window. The current rotation is NOT changed,
    /// so `interpolateToTargets()` will slerp smoothly toward the snapped orientation.
    func applyRotationSnap() {
        withLock {
            guard _rotationAutoSnap else { return }
            let snapped = Self.snapQuaternion(_targetWorldRotation, windowDegrees: _rotationSnapWindowDegrees)
            _targetWorldRotation = snapped
        }
    }

    /// Pure function: decompose a quaternion to ZYX Euler angles, snap each to the nearest
    /// 45° multiple if within ±halfWindow, and reconstruct.
    /// Snap targets per axis: 0°, 45°, 90°, 135°, 180°, 225°, 270°, 315° (equivalently −180…180).
    static func snapQuaternion(_ q: simd_quatf, windowDegrees: Float) -> simd_quatf {
        let halfWindow = windowDegrees * 0.5 * (.pi / 180.0)   // convert half-window to radians
        let snapInterval: Float = .pi / 4.0                     // 45° in radians

        // Extract ZYX Euler angles (returns radians in −π…π range)
        var (roll, pitch, yaw) = quaternionToEulerZYX(q)

        roll  = snapAngle(roll,  interval: snapInterval, halfWindow: halfWindow)
        pitch = snapAngle(pitch, interval: snapInterval, halfWindow: halfWindow)
        yaw   = snapAngle(yaw,   interval: snapInterval, halfWindow: halfWindow)

        return eulerZYXToQuaternion(roll: roll, pitch: pitch, yaw: yaw)
    }

    /// Snap a single angle (radians, any range) to the nearest multiple of `interval`
    /// if the residual is within ±halfWindow. Otherwise return the original angle.
    private static func snapAngle(_ angle: Float, interval: Float, halfWindow: Float) -> Float {
        let nearest = (angle / interval).rounded() * interval
        let delta = abs(angle - nearest)
        return delta <= halfWindow ? nearest : angle
    }

    /// Decompose a unit quaternion into ZYX intrinsic Euler angles (roll, pitch, yaw)
    /// in radians, each in −π…π (pitch clamped to −π/2…π/2 to avoid gimbal ambiguity).
    private static func quaternionToEulerZYX(_ q: simd_quatf) -> (roll: Float, pitch: Float, yaw: Float) {
        let x = q.imag.x, y = q.imag.y, z = q.imag.z, w = q.real

        // Roll (X-axis rotation)
        let sinr_cosp = 2.0 * (w * x + y * z)
        let cosr_cosp = 1.0 - 2.0 * (x * x + y * y)
        let roll = atan2(sinr_cosp, cosr_cosp)

        // Pitch (Y-axis rotation) — clamped for stability near ±90°
        let sinp = 2.0 * (w * y - z * x)
        let pitch: Float
        if abs(sinp) >= 1.0 {
            pitch = copysign(.pi / 2.0, sinp)
        } else {
            pitch = asin(sinp)
        }

        // Yaw (Z-axis rotation)
        let siny_cosp = 2.0 * (w * z + x * y)
        let cosy_cosp = 1.0 - 2.0 * (y * y + z * z)
        let yaw = atan2(siny_cosp, cosy_cosp)

        return (roll, pitch, yaw)
    }

    /// Reconstruct a unit quaternion from ZYX intrinsic Euler angles (radians).
    private static func eulerZYXToQuaternion(roll: Float, pitch: Float, yaw: Float) -> simd_quatf {
        let cr = cos(roll  * 0.5), sr = sin(roll  * 0.5)
        let cp = cos(pitch * 0.5), sp = sin(pitch * 0.5)
        let cy = cos(yaw   * 0.5), sy = sin(yaw   * 0.5)

        return simd_quatf(
            ix: sr * cp * cy - cr * sp * sy,
            iy: cr * sp * cy + sr * cp * sy,
            iz: cr * cp * sy - sr * sp * cy,
            r:  cr * cp * cy + sr * sp * sy
        ).normalized
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

}

