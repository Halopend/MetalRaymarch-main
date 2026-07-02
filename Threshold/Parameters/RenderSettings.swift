 import Foundation
import os
import simd

final class RenderSettings: @unchecked Sendable {
    // Shared depth pipeline settings (raymarch + depth output + MetalFX input)
    static let maxViewDistance: Float = 12.0
    static let logDepthScale: Float = 4.0
    static let depthMissValue: Float = 2.0

    // ── INFINITE ZOOM (continuous auto-descent on the detailScale channel) ──
    // Phase 1: a steady multiplicative dive bounded to an fp32-safe scale band.
    // (Phase 2 octave-rebase lifts this ceiling to true infinity via self-similar
    // scale-folding.) Rate is signed log-units/sec: e^(rate·dt) per frame.
    static let infiniteZoomMaxRate: Float = 1.5    // cap on |log-units/sec|
    static let infiniteZoomMinScale: Float = 0.02  // deepest zoom-out (detailScale)
    static let infiniteZoomMaxScale: Float = 4096.0 // deepest zoom-in before octave-rebase is needed
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
    /// (All four loaders return the code default under
    /// `SettingsPersistence.benchmarkHermetic` — see that flag for why.)
    private static func loadBool(_ key: String, default fallback: Bool) -> Bool {
        guard !SettingsPersistence.benchmarkHermetic,
              UserDefaults.standard.object(forKey: key) != nil else { return fallback }
        return UserDefaults.standard.bool(forKey: key)
    }

    /// Load a persisted Float, returning `fallback` when the key has never been written.
    private static func loadFloat(_ key: String, default fallback: Float) -> Float {
        guard !SettingsPersistence.benchmarkHermetic,
              UserDefaults.standard.object(forKey: key) != nil else { return fallback }
        return UserDefaults.standard.float(forKey: key)
    }

    /// Load a persisted Int, returning `fallback` when the key has never been written.
    private static func loadInt(_ key: String, default fallback: Int) -> Int {
        guard !SettingsPersistence.benchmarkHermetic,
              UserDefaults.standard.object(forKey: key) != nil else { return fallback }
        return UserDefaults.standard.integer(forKey: key)
    }

    private static func loadGestureBinding(_ key: String,
                                           default fallback: GestureActionBinding) -> GestureActionBinding {
        guard !SettingsPersistence.benchmarkHermetic else { return fallback }
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode(GestureActionBinding.self, from: data) {
            return decoded
        }
        return fallback
    }

    private static func loadMusicReactiveMappings(_ key: String) -> [MusicReactiveMapping] {
        let defaults = UserDefaults.standard
        if !SettingsPersistence.benchmarkHermetic,
           let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([MusicReactiveMapping].self, from: data) {
            return sanitizeMusicReactiveMappings(decoded)
        }
        let defaultsList: [MusicReactiveMapping] = [
            MusicReactiveTarget.fractalScale.defaultMapping(enabled: true),
            MusicReactiveTarget.glow.defaultMapping(enabled: true),
            MusicReactiveTarget.fog.defaultMapping(enabled: true),
        ]
        if !SettingsPersistence.benchmarkHermetic,
           let data = try? JSONEncoder().encode(defaultsList) {
            defaults.set(data, forKey: key)
        }
        return defaultsList
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

    init() {
        // One-time migration: existing installs persisted coherentPacketEnabled /
        // foveationStrength under bare UserDefaults keys (still read at declaration
        // above). The QualityConfig domain was never written, so seed it once from
        // the already-initialized quality fields. New installs (domain present) and
        // subsequent launches skip this.
        if SettingsPersistence.load(QualityConfig.self, domain: .quality) == nil {
            SettingsPersistence.save(qualityConfig, domain: .quality)
        }
    }

    private var _minDistance: Float = 0.8           // 80% of max (1.0) for quality
    private var _scale: Float = 1.0
    private var _position: SIMD3<Float> = SIMD3<Float>(0.1, 0.1, 0.1)
    private var _fractalScale: Float = 2.8
    private var _fractalIterations: Int = 9         // Mid quality default
    private var _maxRaySteps: Int = 64              // Mid quality default
    private var _baseFractalIterations: Int = 9     // User-set base
    private var _baseMaxRaySteps: Int = 64          // User-set base
    private var _colorMix: Float = 0.5
    private var _lightingPlay: Bool = false         // Play/pause lighting effects
    private var _lightingMode: LightingMode = .animated  // Static, animated, or audio-reactive
    private var _sphericalInversionMode: SphericalInversionMode = .off
    private var _sphericalInversionRadius: Float = 2.0
    private var _sphereProjectionEnabled: Bool = false
    private var _sphereProjectionBlend: Float = 1.0
    private var _sphereProjectionRadius: Float = 1.0
    // Custom space warp (built-in "Twist" by default; a loaded .threshfx warp can
    // override the GPU function). Strength 0 = off (dead-code-eliminated).
    private var _spaceWarpStrength: Float = 0.0
    // Built-in Twist origin point (x, y, z). Origin defaults to the world center.
    private var _spaceWarpParam1: Float = 0.0
    private var _spaceWarpParam2: Float = 0.0
    private var _spaceWarpParam3: Float = 0.0
    // Built-in Twist orientation: the axis the twist rotates about (normalized in
    // the shader). Default = vertical (+Y), matching the original Y-axis twist.
    private var _spaceWarpAxis: SIMD3<Float> = SIMD3<Float>(0, 1, 0)
    // Composable domain-transform stack (Transformations UI). Order = order of
    // application; empty = off. See SpaceWarpOpValue / TransformationsSection.
    private var _spaceWarpStack: [SpaceWarpOpValue] = []
    // Transient music offsets keyed by (slot, field) → additive delta, written by the
    // music engine each frame and folded into each op's chosen field at snapshot time.
    // NOT persisted (it's live modulation, not authored state); empty = no modulation.
    private var _spaceWarpAudioOffsets: [SpaceWarpFieldKey: Float] = [:]
    // Cached GPU-packed stack (simplify + transcendental precompute + pack). It is a
    // pure function of `_spaceWarpStack` + `_spaceWarpAudioOffsets`, so it only needs
    // rebuilding when one of those changes — nil = dirty. Rebuilding it every frame
    // in snapshot() re-ran the simplifier + sin/cos/log/sqrt precompute (plus 2–3 heap
    // array allocs) for a STATIC stack; this caches the result across frames.
    private var _cachedPackedSpaceWarpStack: SpaceWarpStack?
    // RETIRED warp-stack codegen state. The transform stack now renders via the
    // bundled count-driven runtime loop (uniform-driven), so these stay at their
    // "no injected warp library" defaults forever. The render backends still read
    // them while compiling a custom FORMULA library; nil/"s0" keeps that library's
    // runtime warp loop. (See SpaceWarpStackModel.swift for why codegen was removed.)
    private var _warpStackCodegenSource: String? = nil
    private var _warpStackCodegenSignature: String = "s0"
    private var _platformRadius: Float = 1.888
    private var _platformEnabled: Bool = true
    private var _audioLevel: Float = 0.0            // Current audio level (0-1) for reactive lighting
    private var _bassLevel: Float = 0.0             // Bass frequency energy (0-1)
    private var _midLevel: Float = 0.0              // Mid frequency energy (0-1)
    private var _trebleLevel: Float = 0.0           // Treble frequency energy (0-1)
    private var _beatIntensity: Float = 0.0         // Beat onset intensity (0-1)
    private var _bassSensitivity: Float = 1.0        // Multiplier for bass band (0-2)
    private var _midSensitivity: Float = 1.0         // Multiplier for mid band (0-2)
    private var _trebleSensitivity: Float = 1.0      // Multiplier for treble band (0-2)
    private var _beatSensitivity: Float = 1.0        // Multiplier for beat intensity (0-2)
    private var _fractalAudioReactiveEnabled: Bool = loadBool("fractalAudioReactiveEnabled", default: true)
    private var _fractalAudioAmount: Float              = loadFloat("fractalAudioAmount", default: 0.6)
    private var _fractalBeatPunch: Float                = loadFloat("fractalBeatPunch", default: 0.7)
    private var _fractalAudioDamping: Float             = loadFloat("fractalAudioDamping", default: 0.0)
    private var _musicReactiveMappings: [MusicReactiveMapping] = loadMusicReactiveMappings("musicReactiveMappings")
    private var _tripletMusicGains: [String: Float] = [:]
    
    private var _foldingLimit: Float = 1.0
    private var _sphereRadius: Float = 0.5
    private var _colorIterations: Float = 8.0       // Lower = faster (was 10)
    #if os(macOS)
    // Mac renders into a full native Retina drawable; at 1.0 the MetalFX upscale
    // path is bypassed entirely (`resolutionScale < 0.985` gate in the renderer),
    // so the raymarch pays for every backing-store pixel and the GPU is pixel-bound.
    // Default to a 0.75 input scale (~56% of the pixels) and let MetalFX reconstruct
    // to native. The adaptive-resolution controller treats this as a *ceiling*: it
    // renders at or below it under load and recovers up to 0.75 when there's headroom.
    private var _resolutionScale: Float = 0.75      // Mac: MetalFX upscale on by default
    #else
    private var _resolutionScale: Float = 1.0       // Render scale for MetalFX (1.0 = native)
    #endif
    private var _renderQuality: Float = 0.5         // visionOS compositor drawable scale (default 0.5; 1.0 = native)

    private var _fractalType: FractalModelType = .mandelbox  // Current fractal type
    private var _formulaParams: FormulaParams = FractalModelType.mandelbox.defaultFormulaParams()  // Generic formula params
    private var _tileSize: Int = 0                   // 0=disabled (fragment), 8=8x8 adaptive hierarchical compute
    private var _debugHierarchical: Bool = false     // Visualize adaptive hierarchy levels
    private var _coherentPacketEnabled: Bool = loadBool("coherentPacketEnabled", default: false)  // Experimental predict-validate raymarch (Stages 0-3)
    private var _computeTemporalReprojectionEnabled: Bool = loadBool("computeTemporalReprojectionEnabled", default: false)  // Compute path: temporal reproject + tile/supertile depth seeding. Off = full coarse+fine march every frame (correct baseline; the seeding can blank disoccluded tiles)
    private var _coarsePrepassWarmStartEnabled: Bool = loadBool("coarsePrepassWarmStartEnabled", default: false)  // visionOS fragment path: conservative cone coarse-prepass warm-start. A low-res cone pass writes a provable LOWER BOUND on each 8x8 block's nearest-surface entry distance; the full march raises its start t to it (skip-to-then-full-march). Off = no cone pass, byte-identical to before. Box/fold + un-warped domain only.
    private var _foveationStrength: Float = loadFloat("foveationStrength", default: 0.0)  // Peripheral step reduction on the 8x8 compute path (0 = off)
    private var _smartAdvanceEnabled: Bool = loadBool("smartAdvanceEnabled", default: false)  // Grazing-aware lead-ahead sphere tracing (reads the along-ray DE gradient)
    private var _adaptiveRenderQualityEnabled: Bool = loadBool("adaptiveRenderQualityEnabled", default: true)  // visionOS: auto-lower compositor Render Quality to hold FPS (slider = ceiling)
    private var _coneMarchStrength: Float = loadFloat("coneMarchStrength", default: 0.0)  // 0 = off; scales the distance-growing hit threshold (projected pixel footprint, ConeMarchingPen)
    private var _overRelaxationMax: Float = loadFloat("overRelaxationMax", default: 1.4)  // Keinert over-relaxation ceiling the auto-ramp may reach (1.0 = conservative)
    private var _distanceLODStrength: Float = loadFloat("distanceLODStrength", default: 0.0)  // 0 = off; drops fractal iterations on faraway samples
    private var _shadowsEnabled: Bool = loadBool("shadowsEnabled", default: true)  // false skips the two per-pixel shadow marches
    private var _boundingSphereSkipEnabled: Bool = loadBool("boundingSphereSkipEnabled", default: false)  // reject rays that miss the fractal's bounding sphere
    private var _boundingShapeRadius: Float = loadFloat("boundingShapeRadius", default: 6.0)  // bounding shape (sphere) radius, model units
    // Bounding-edge treatment: 0 = off, 1 = Ghost Fade (translucent, the original
    // combined RGB+alpha fade), 2 = Inner Shadow (opaque RGB-only darken). Migrates
    // the old "boundingShapeFogEnabled" Bool (true → Ghost Fade) when unset.
    private var _boundingShapeFogMode: Int = loadInt("boundingShapeFogMode", default: loadBool("boundingShapeFogEnabled", default: false) ? 1 : 0)
    private var _boundingShapeShadowDepth: Float = loadFloat("boundingShapeShadowDepth", default: 0.35)  // Inner Shadow band width, fraction of boundingShapeRadius
    // Bounding Shape family/preset — same encoding as safetyBubbleShape (0...1 =
    // sphere/cube morph, 2...6 = discrete platonic solids).
    private var _boundingShapeType: Float = loadFloat("boundingShapeType", default: 0.0)
    private var _zoomFogCompensationEnabled: Bool = loadBool("zoomFogCompensationEnabled", default: false)  // scale fog intensity down on zoom-out so the fog sphere's world radius stays constant (was hardcoded on for Kleinian)
    private var _limitFlash: Float = 0.0             // Flash intensity when gesture hits parameter limit (0-1, decays)
    
    // HUD display
    private var _showMusicShortcuts: Bool = loadBool("showMusicShortcuts", default: false)
    private var _isMenuInteractionActive: Bool = false // True while interacting with menu UI (hover/drag)
    private var _activeGestureIndex: Int = 0         // Currently active gesture (0=none, 1=index, 2=middle, 3=ring)
    private var _useRelativeGestures: Bool = loadBool("useRelativeGestures", default: GestureDefaults.useRelativeGestures)
    private var _menuToggleGestureEnabled: Bool = loadBool("menuToggleGestureEnabled", default: GestureDefaults.menuToggleGestureEnabled)
    private var _menuToggleGestureMode: MenuToggleGestureMode = {
        let key = "menuToggleGestureMode"
        guard UserDefaults.standard.object(forKey: key) != nil else { return GestureDefaults.menuToggleGestureMode }
        let raw = UserDefaults.standard.integer(forKey: key)
        return MenuToggleGestureMode(rawValue: Int32(raw)) ?? GestureDefaults.menuToggleGestureMode
    }()

    // ── Per-hand × per-finger × direction gesture binding slots ──────────
    private var _gestureBindings: [String: GestureActionBinding] = {
        var bindings: [String: GestureActionBinding] = [:]
        let defaults = GestureDefaults.defaultBindings

        func handMode(for key: String) -> GestureHandMode {
            if key.hasPrefix("left")  { return .left }
            if key.hasPrefix("right") { return .right }
            return .both
        }

        for (key, fallback) in defaults {
            let loaded = loadGestureBinding(key, default: fallback)
            bindings[key] = RenderSettings.validated(loaded, forHandMode: handMode(for: key))
        }

        return bindings
    }()

    // Per-finger tap-to-palm gesture layer
    private var _perFingerTapGestureEnabled: Bool = loadBool("perFingerTapGestureEnabled", default: GestureDefaults.perFingerTapGestureEnabled)
    private var _perFingerTapLeftActions: [PerFingerTapAction] = GestureDefaults.loadPerFingerTapActions(keyPrefix: "perFingerTapLeft")
    private var _perFingerTapRightActions: [PerFingerTapAction] = GestureDefaults.loadPerFingerTapActions(keyPrefix: "perFingerTapRight")
    private var _perFingerTapActivateThreshold: Float = loadFloat("perFingerTapActivateThreshold", default: GestureDefaults.perFingerTapActivateThreshold)
    private var _perFingerTapReleaseThreshold: Float = loadFloat("perFingerTapReleaseThreshold", default: GestureDefaults.perFingerTapReleaseThreshold)
    private var _perFingerTapHoldDuration: Float = loadFloat("perFingerTapHoldDuration", default: GestureDefaults.perFingerTapHoldDuration)
    private var _perFingerTapCooldown: Float = loadFloat("perFingerTapCooldown", default: GestureDefaults.perFingerTapCooldown)

    private var _leftHandedMode: Bool = UserDefaults.standard.bool(forKey: "leftHandedMode")

    // macOS-only: orbit the fractal by tilting the laptop (Sudden Motion Sensor).
    private var _macTiltControlEnabled: Bool = UserDefaults.standard.bool(forKey: "macTiltControlEnabled")

    // === SPRING BLOB NAVIGATION (retained renderer subsystem; currently never activated) ===
    // Spring physics state — driven by translate gesture, ticked in Renderer
    private var _springDisplacement: SIMD3<Float> = .zero  // Current displacement from rest
    private var _springVelocity: SIMD3<Float> = .zero      // Current velocity
    private var _springActive: Bool = false                 // Is the user pulling the spring?

    // Safety bubble controls (defaults live on SafetyBubbleConfig: on for
    // visionOS comfort, off on desktop)
    private var _safetyBubbleEnabled: Bool = SafetyBubbleConfig.defaultEnabled  // Cut out a small safe sphere
    private var _safetyBubbleRadius: Float = 1.8    // Radius of the safe bubble (meters)
    private var _safetyBubbleShape: Float = 0.0     // 0...1 = sphere/cube morph (no rotation); 2...6 select discrete platonic solids
    private var _safetyBubbleFadeEnabled: Bool = true
    private var _safetyBubbleFadeWidth: Float = 0.1
    private var _safetyBubbleStrength: Float = SafetyBubbleConfig.defaultStrength

    // Hand Attraction: a per-hand interaction sphere (visionOS only) that pulls
    // the fractal surface toward each tracked palm — the inverse of the safety
    // bubble's push-away carve. Off by default (opt-in, not a comfort feature).
    private var _handAttractionEnabled: Bool = false
    private var _handAttractionRadius: Float = 0.35
    private var _handAttractionStrength: Float = 0.5

    // === COLOR SCHEME ===
    // Controls the color palette and post-processing for fractal coloring
    private var _colorScheme: ColorScheme = .classic      // Current color scheme
    private var _targetColorScheme: ColorScheme = .classic // Target for transitions
    private var _colorSchemeTransitionProgress: Float = 1.0 // 0 = previous, 1 = current (complete)
    private var _colorSchemeTransitionDuration: Float = 2.0 // Seconds to transition between schemes
    private var _colorSchemeAutoTransition: Bool = false    // Auto-cycle through schemes
    private var _colorSchemeAutoInterval: Float = 30.0      // Seconds between auto-transitions
    private var _colorSchemeAutoTimer: Float = 0.0          // Timer for auto-transitions
    private var _colorSchemeCycleIndex: Int = 0             // Tracked index for O(1) cycle advance
    static let colorSchemeCycle: [ColorScheme] = ColorScheme.allCases
    private var _colorSchemeSaturation: Float = 1.7         // Color saturation override
    private var _colorSchemeContrast: Float = 1.08          // Contrast override (deeper baseline contrast)
    private var _colorSchemeGamma: Float = 0.85             // Gamma override (lower = brighter, 1.0 = linear)
    private var _colorSchemeVibrance: Float = 0.8           // Vibrance boost (0-1)
    private var _colorSchemeCurve: Float = 0.0              // Midtone curve adjustment (-1 to 1)
    private var _colorSchemeShadows: Float = -0.018         // Shadow lift/crush (-0.05 to 0.05)
    private var _colorSchemeHighlights: Float = 0.02        // Highlight boost/reduction (-0.5 to 1.0)
    private var _lightingSoftness: Float = 0.35              // 0 = sharp vibrance-driven, 1 = classic soft lighting
    private var _cellShadingEnabled: Bool = false
    private var _cellShadingLevels: Float = 4.0
    private var _aoStrength: Float = 0.0                     // Ambient-occlusion blend (0 = old flat ambient, default)
    private var _tonemapStrength: Float = 0.0                // Filmic (ACES) tonemap blend (0 = old plain clamp, default)
    
    // === MODULAR LIGHTING EFFECTS ===
    // Card-based lighting system with presets and individual effect toggles
    private var _colorAnimTime: Float = 0.0                 // Running animation time (raw — drives position effects like Linear Rail)
    private var _lightAnimTime: Float = 0.0                 // Light-variation time, scaled by _lightVariationRate (reserved / general light clock)
    private var _lightVariationRate: Float = 0.5            // Master speed for color/brightness light variation (0 = hold steady, 1 = full speed). Default 0.5 keeps presets from sweeping colours too fast.
    // Integrated cycle phases. Each is ∫ rate·dt rather than clock·speed, so changing a
    // speed slider (or an audio transient nudging the rate) only bends the future curve —
    // it never rescales the accumulated phase, which is what used to snap the colours.
    private var _huePhase: Float = 0.0                      // Hue rotation phase (radians, wrapped to [0,2π))
    private var _pulsePhase: Float = 0.0                    // Pulse phase (radians, wrapped to [0,2π))
    private var _fogHuePhase: Float = 0.0                   // Fog-tint hue cycle phase (radians, wrapped to [0,2π))
    private var _gradientPhase: Float = 0.0                 // Gradient cycle offset phase (wrapped to [0,1))
    private var _animationActivityFactor: Float = 1.0
    private var _animationKillSwitchActive: Bool = false
    private var _animationKillSwitchRemaining: Float = 0.0
    private var _animationKillSwitchDuration: Float = 0.7
    private var _lightingPreset: LightingPreset = .off      // Current preset package
    private var _hueRotationEffect: HueRotationEffect = .off
    private var _pulseEffect: PulseEffect = .off
    private var _glowEffect: GlowEffect = .off
    private var _bloomEffect: BloomEffect = .off
    private var _fogEffect: FogEffect = FogEffect(enabled: true, intensity: 0.32)
    private var _gradientCycleEffect: GradientCycleEffect = .off
    private var _linearRailEffect: LinearRailEffect = .off
    private var _polarRotationEffect: PolarRotationEffect = .off
    private var _beatFlashEffect: BeatFlashEffect = .off
    private var _polarRotationAccum: Float = 0.0              // Accumulated polar rotation angle (radians)
    private var _juliaDriftEffect: JuliaDriftEffect = .off
    private var _juliaDriftAccum: Float = 0.0                 // Accumulated Julia C drift angle (radians)
    
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

    // Infinite zoom: when enabled, the per-frame smoothing pass advances the
    // detailScale (zoom) target by e^(rate·dt) for a continuous, seamless dive.
    private var _infiniteZoomEnabled: Bool = false
    private var _infiniteZoomRate: Float = 0.15   // signed log-units/sec; + = zoom in, − = zoom out

    // Animation-override model for rotation (quaternion) and zoom (detailScale).
    // These mirror the animationBase + manualOffset model used by position/shape so a
    // grab gesture overrides rotation/zoom even while the playing scene animates them.
    // applyKeyframe writes the scene value into the *base*; the grab writes the manual
    // override; the effective target is base ∘ override (quaternion compose for rotation,
    // additive for detailScale). identity/zero override == "no override".
    private var _animationBaseWorldRotation: simd_quatf = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    private var _manualRotationOffset: simd_quatf = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)  // identity = none
    private var _animationBaseDetailScale: Float = 1.0
    private var _manualOffsetDetailScale: Float = 0.0

    // === ANIMATION BASE + MANUAL OFFSETS ===
    // Animation drives base values. Manual gestures apply offsets when animation is playing.
    private var _isAnimationPlaying: Bool = false
    private var _animationBaseMinDistance: Float = 0.8
    private var _animationBaseFoldingLimit: Float = 1.0
    private var _animationBaseSphereRadius: Float = 0.5
    private var _animationBaseFractalScale: Float = 2.8
    private var _animationBasePosition: SIMD3<Float> = SIMD3<Float>(0.1, 0.1, 0.1)
    private var _animationBaseGlowIntensity: Float = 0.0
    private var _animationBaseBloomStrength: Float = 0.0
    private var _animationBaseFogIntensity: Float = 0.32
    private var _animationBaseSaturation: Float = 1.5
    private var _animationBaseFormulaParams: [Float] = {
        let defaults = FractalModelType.mandelbox.defaultFormulaParams()
        return (0..<16).map { FormulaCatalog.getParam(defaults, index: $0) }
    }()
    private var _manualOffsetMinDistance: Float = 0.0
    private var _manualOffsetFoldingLimit: Float = 0.0
    private var _manualOffsetSphereRadius: Float = 0.0
    private var _manualOffsetFractalScale: Float = 0.0
    private var _manualOffsetPosition: SIMD3<Float> = .zero
    private var _manualOffsetGlowIntensity: Float = 0.0
    private var _manualOffsetBloomStrength: Float = 0.0
    private var _manualOffsetFogIntensity: Float = 0.0
    private var _manualOffsetSaturation: Float = 0.0
    private var _manualOffsetFormulaParams: [Float] = Array(repeating: 0.0, count: 16)

    // === ANIMATION AUDIO (MUSIC) OFFSETS ===
    // Parallel to the gesture `_manualOffset*` layer above. During animation playback
    // applyKeyframe / the formula rebuild own the backing vars every frame, so a music
    // write that sets the absolute value is overwritten and "music stops working".
    // Instead, the dispatcher deposits the pure music delta here while playing, and the
    // same composers that add `manualOffset` also add `audioOffset` — so music modulates
    // *around* the live animated value. Centered at zero; the music engine refreshes them
    // every frame (≈0 when silent), so unlike `manualOffset` they are NOT decayed.
    private var _animationBaseHueSpeed: Float = 0.0
    private var _audioOffsetMinDistance: Float = 0.0
    private var _audioOffsetFoldingLimit: Float = 0.0
    private var _audioOffsetSphereRadius: Float = 0.0
    private var _audioOffsetFractalScale: Float = 0.0
    private var _audioOffsetGlowIntensity: Float = 0.0
    private var _audioOffsetBloomStrength: Float = 0.0
    private var _audioOffsetFogIntensity: Float = 0.0
    private var _audioOffsetSaturation: Float = 0.0
    private var _audioOffsetHueSpeed: Float = 0.0
    private var _audioOffsetFormulaParams: [Float] = Array(repeating: 0.0, count: 16)
    // Which effect channels the *current* scene keyframe drives. When false the channel
    // is user-owned and the dispatcher's plain absolute music write already survives, so
    // the playback-relative offset path (which only applyKeyframe consumes) is skipped.
    private var _sceneDrivesGlow: Bool = false
    private var _sceneDrivesBloom: Bool = false
    private var _sceneDrivesFog: Bool = false
    private var _sceneDrivesSaturation: Bool = false
    private var _sceneDrivesHueSpeed: Bool = false

    // === VELOCITY STATE FOR SMOOTH DAMP ===
    // Track velocities for critically-damped spring interpolation
    private var _velocityMinDistance: Float = 0.0
    private var _velocityFoldingLimit: Float = 0.0
    private var _velocitySphereRadius: Float = 0.0
    private var _velocityFractalScale: Float = 0.0
    private var _velocityPosition: SIMD3<Float> = .zero
    

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

    /// When true, the per-frame smoothing pass continuously advances the zoom
    /// (detailScale) target for a seamless infinite descent.
    var infiniteZoomEnabled: Bool {
        get { withLock { _infiniteZoomEnabled } }
        set { withLock { _infiniteZoomEnabled = newValue } }
    }
    /// Signed continuous-zoom rate in log-units/sec (e^(rate·dt) per frame).
    /// Positive dives in; negative pulls out. Clamped to ±infiniteZoomMaxRate.
    var infiniteZoomRate: Float {
        get { withLock { _infiniteZoomRate } }
        set { withLock { _infiniteZoomRate = max(-Self.infiniteZoomMaxRate, min(Self.infiniteZoomMaxRate, newValue)) } }
    }

    var fractalScale: Float {
        get { withLock { _fractalScale } }
        set { withLock { _fractalScale = newValue } }
    }
    
    /// Current effective fractal iterations
    var fractalIterations: Int {
        get { withLock { _fractalIterations } }
        set { withLock { _fractalIterations = newValue } }
    }
    
    /// Current effective ray steps
    var maxRaySteps: Int {
        get { withLock { _maxRaySteps } }
        set { withLock { _maxRaySteps = newValue } }
    }
    
    /// Base fractal iterations set by user
    var baseFractalIterations: Int {
        get { withLock { _baseFractalIterations } }
        set { 
            withLock { 
                _baseFractalIterations = newValue
                _fractalIterations = newValue  // Also update current
            } 
        }
    }
    
    /// Base ray steps set by user
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
        set {
            withLock { _colorMix = newValue }
            persistColor()
        }
    }

    var lightingPlay: Bool {
        get { withLock { _lightingPlay } }
        set { withLock { _lightingPlay = newValue } }
    }
    
    var lightingMode: LightingMode {
        get { withLock { _lightingMode } }
        set { withLock { _lightingMode = newValue } }
    }

    var sphericalInversionMode: SphericalInversionMode {
        get { withLock { _sphericalInversionMode } }
        set {
            withLock { _sphericalInversionMode = newValue }
            persistDisplay()
        }
    }

    var sphericalInversionRadius: Float {
        get { withLock { _sphericalInversionRadius } }
        set {
            withLock { _sphericalInversionRadius = ControlCatalog.sphericalInversionRadius.clamp(newValue) }
            persistDisplay()
        }
    }

    var sphereProjectionEnabled: Bool {
        get { withLock { _sphereProjectionEnabled } }
        set {
            withLock { _sphereProjectionEnabled = newValue }
            persistDisplay()
        }
    }

    var sphereProjectionBlend: Float {
        get { withLock { _sphereProjectionBlend } }
        set {
            withLock { _sphereProjectionBlend = ControlCatalog.sphereProjectionBlend.clamp(newValue) }
            persistDisplay()
        }
    }

    var sphereProjectionRadius: Float {
        get { withLock { _sphereProjectionRadius } }
        set {
            withLock { _sphereProjectionRadius = ControlCatalog.sphereProjectionRadius.clamp(newValue) }
            persistDisplay()
        }
    }

    /// Custom space-warp strength (0 = off). Drives the built-in "Twist" warp, or
    /// a loaded `.threshfx` space-warp effect once that overrides the GPU function.
    var spaceWarpStrength: Float {
        get { withLock { _spaceWarpStrength } }
        set { withLock { _spaceWarpStrength = ControlCatalog.spaceWarpStrength.clamp(newValue) } }
    }
    var spaceWarpParam1: Float {
        get { withLock { _spaceWarpParam1 } }
        set { withLock { _spaceWarpParam1 = newValue } }
    }
    var spaceWarpParam2: Float {
        get { withLock { _spaceWarpParam2 } }
        set { withLock { _spaceWarpParam2 = newValue } }
    }
    var spaceWarpParam3: Float {
        get { withLock { _spaceWarpParam3 } }
        set { withLock { _spaceWarpParam3 = newValue } }
    }

    /// The built-in Twist's rotation axis (orientation). Normalized on the GPU;
    /// `(0, 1, 0)` reproduces the original vertical twist. The origin point is
    /// carried by `spaceWarpParam1/2/3`.
    var spaceWarpAxis: SIMD3<Float> {
        get { withLock { _spaceWarpAxis } }
        set { withLock { _spaceWarpAxis = newValue } }
    }

    /// Twist origin point (x, y, z), backed by the generic warp params.
    var spaceWarpOrigin: SIMD3<Float> {
        get { withLock { SIMD3<Float>(_spaceWarpParam1, _spaceWarpParam2, _spaceWarpParam3) } }
        set { withLock { _spaceWarpParam1 = newValue.x; _spaceWarpParam2 = newValue.y; _spaceWarpParam3 = newValue.z } }
    }

    /// The composable domain-transform stack (Transformations UI). Order is the
    /// order of application; an empty stack means no transforms.
    var spaceWarpStack: [SpaceWarpOpValue] {
        get { withLock { _spaceWarpStack } }
        set { withLock { _spaceWarpStack = newValue; _cachedPackedSpaceWarpStack = nil } }
    }

    /// Replace the music-driven per-(slot, field) offsets atomically. Called once per
    /// audio frame by the music engine; pass `[:]` to clear (mapping removed / music
    /// off). Folded into each op's chosen field at snapshot time.
    func setSpaceWarpAudioOffsets(_ offsets: [SpaceWarpFieldKey: Float]) {
        withLock {
            // Called every audio frame ("always publish"). Only invalidate the packed
            // cache when the offsets actually change, so the common no-transform-binding
            // case (an empty set re-published each frame) keeps the cache warm.
            guard _spaceWarpAudioOffsets != offsets else { return }
            _spaceWarpAudioOffsets = offsets
            _cachedPackedSpaceWarpStack = nil
        }
    }

    /// Apply the live music offsets to a copy of the stack, clamped to each op's
    /// own strength range. Lock-free — call only from inside `withLock`.
    private func spaceWarpStackWithAudioOffsetsLocked() -> [SpaceWarpOpValue] {
        guard !_spaceWarpAudioOffsets.isEmpty else { return _spaceWarpStack }
        var ops = _spaceWarpStack
        for (key, delta) in _spaceWarpAudioOffsets where key.slot >= 0 && key.slot < ops.count {
            ops[key.slot].applyAudioDelta(delta, field: key.field)
        }
        return ops
    }

    /// The GPU-packed stack, rebuilt only when the model or the audio offsets changed
    /// (`_cachedPackedSpaceWarpStack == nil`). Lock-free — call only from inside
    /// `withLock`. This is what snapshot() reads each frame; the expensive
    /// simplify+precompute+pack (`cSpaceWarpStack`) now runs once per edit, not per frame.
    private func packedSpaceWarpStackLocked() -> SpaceWarpStack {
        if let cached = _cachedPackedSpaceWarpStack { return cached }
        let packed = cSpaceWarpStack(from: spaceWarpStackWithAudioOffsetsLocked())
        _cachedPackedSpaceWarpStack = packed
        return packed
    }

    /// RETIRED warp-stack codegen hooks. The transform stack now renders via the
    /// bundled count-driven runtime loop (uniform-driven, no specialization), so
    /// these always return their `nil` / `"s0"` defaults — i.e. "no injected warp
    /// library". The render backends still read them while compiling a custom
    /// FORMULA library; `nil`/`"s0"` simply means the formula library keeps the
    /// runtime warp loop. (Kept as defaulted reads to avoid touching the custom-
    /// formula compile path; safe to delete once that threading is removed.)
    var warpStackCodegenSource: String? { withLock { _warpStackCodegenSource } }
    var warpStackCodegenSignature: String { withLock { _warpStackCodegenSignature } }

    var platformRadius: Float {
        get { withLock { _platformRadius } }
        set {
            withLock { _platformRadius = max(0.5, min(2.5, newValue)) }
            persistDisplay()
        }
    }

    /// Whether the glass-floor platform is rendered in the immersive space.
    /// Independent of `platformRadius` so toggling preserves the chosen size.
    var platformEnabled: Bool {
        get { withLock { _platformEnabled } }
        set {
            withLock { _platformEnabled = newValue }
            persistDisplay()
        }
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
    
    var bassSensitivity: Float {
        get { withLock { _bassSensitivity } }
        set {
            withLock { _bassSensitivity = max(0.0, min(2.0, newValue)) }
            persistAudioReactive()
        }
    }

    var midSensitivity: Float {
        get { withLock { _midSensitivity } }
        set {
            withLock { _midSensitivity = max(0.0, min(2.0, newValue)) }
            persistAudioReactive()
        }
    }

    var trebleSensitivity: Float {
        get { withLock { _trebleSensitivity } }
        set {
            withLock { _trebleSensitivity = max(0.0, min(2.0, newValue)) }
            persistAudioReactive()
        }
    }

    var beatSensitivity: Float {
        get { withLock { _beatSensitivity } }
        set {
            withLock { _beatSensitivity = max(0.0, min(2.0, newValue)) }
            persistAudioReactive()
        }
    }

    var fractalAudioReactiveEnabled: Bool {
        get { withLock { _fractalAudioReactiveEnabled } }
        set {
            withLock { _fractalAudioReactiveEnabled = newValue }
            persistAudioReactive()
        }
    }

    var fractalAudioAmount: Float {
        get { withLock { _fractalAudioAmount } }
        set {
            let clamped = max(0.0, min(1.0, newValue))
            withLock { _fractalAudioAmount = clamped }
            persistAudioReactive()
        }
    }

    var fractalBeatPunch: Float {
        get { withLock { _fractalBeatPunch } }
        set {
            let clamped = max(0.0, min(1.0, newValue))
            withLock { _fractalBeatPunch = clamped }
            persistAudioReactive()
        }
    }

    var fractalAudioDamping: Float {
        get { withLock { _fractalAudioDamping } }
        set {
            let clamped = max(0.0, min(3.0, newValue))
            withLock { _fractalAudioDamping = clamped }
            persistAudioReactive()
        }
    }

    var musicReactiveMappings: [MusicReactiveMapping] {
        get { withLock { _musicReactiveMappings } }
        set {
            withLock {
                _musicReactiveMappings = Self.sanitizeMusicReactiveMappings(newValue)
            }
            persistAudioReactive()
        }
    }

    var tripletMusicGains: [String: Float] {
        get { withLock { _tripletMusicGains } }
        set {
            withLock { _tripletMusicGains = newValue }
            persistAudioReactive()
        }
    }
    
    // ═══════════════════════════════════════════════════════════════════════════
    // AUDIO MODULATION SETTERS (bypass lighting preset tracking)
    // Used by Renderer for per-frame audio-reactive modulation without
    // triggering _lightingPreset = .custom every frame.
    // ═══════════════════════════════════════════════════════════════════════════
    
    /// Modulate glow intensity (respects user's enabled/disabled toggle)
    func audioModulateGlowIntensity(_ value: Float) {
        withLock {
            // Clamp to the control's authoritative 0…2 range (was 0…1 here, which
            // capped audio/animation playback below the manual slider's reach — a
            // value of e.g. 1.8 set by hand or stored in a keyframe was silently
            // clamped to 1.0 on the audio path).
            _glowEffect.intensity = ControlCatalog.glow.clamp(value)
        }
    }
    
    /// Modulate fog intensity (respects user's enabled/disabled toggle)
    func audioModulateFogIntensity(_ value: Float) {
        withLock {
            _fogEffect.intensity = ControlCatalog.fog.clamp(value)
        }
    }
    
    /// Modulate bloom strength (respects user's enabled/disabled toggle)
    func audioModulateBloomStrength(_ value: Float) {
        withLock {
            // Clamp to the control's authoritative 0…2 range (was 0…1, same
            // audio/animation under-reach bug as glow above).
            _bloomEffect.strength = ControlCatalog.bloom.clamp(value)
        }
    }
    
    /// Modulate hue rotation speed (respects user's enabled/disabled toggle)
    func audioModulateHueSpeed(_ value: Float) {
        withLock {
            _hueRotationEffect.speed = ControlCatalog.hueSpeed.clamp(value)
        }
    }
    
    /// Modulate color scheme saturation
    func audioModulateSaturation(_ value: Float) {
        withLock {
            _colorSchemeSaturation = ControlCatalog.saturation.clamp(value)
        }
    }

    /// Modulate the gradient phase offset ("Color Offset"). Writes the backing
    /// value directly (no persistence), mirroring the other `audioModulate*` setters.
    func audioModulateGradientOffset(_ value: Float) {
        withLock {
            _gradientState.gradient.offset = ControlCatalog.gradientOffset.clamp(value)
        }
    }

    /// Modulate the safety-bubble inner radius. Writes the private backing value
    /// directly (no persistence) so the audio layer can drive it every frame
    /// without spamming disk, mirroring the other `audioModulate*` effects.
    func audioModulateSafetyBubbleRadius(_ value: Float) {
        withLock {
            _safetyBubbleRadius = ControlCatalog.safetyBubbleRadius.clamp(value)
        }
    }

    /// Modulate sphere-projection blend (gesture/audio path). Writes the backing
    /// value directly (no persistence), mirroring the other `audioModulate*` setters.
    func audioModulateSphereProjectionBlend(_ value: Float) {
        withLock {
            _sphereProjectionBlend = ControlCatalog.sphereProjectionBlend.clamp(value)
        }
    }

    /// Modulate sphere-projection radius (gesture/audio path). Writes the backing
    /// value directly (no persistence), mirroring the other `audioModulate*` setters.
    func audioModulateSphereProjectionRadius(_ value: Float) {
        withLock {
            _sphereProjectionRadius = ControlCatalog.sphereProjectionRadius.clamp(value)
        }
    }

    /// Modulate built-in Twist strength (gesture/audio path). Clamps 0…2.
    func audioModulateSpaceWarpStrength(_ value: Float) {
        withLock {
            _spaceWarpStrength = ControlCatalog.spaceWarpStrength.clamp(value)
        }
    }

    /// Modulate built-in Twist origin components (gesture/audio path).
    func audioModulateSpaceWarpOriginX(_ value: Float) { withLock { _spaceWarpParam1 = value } }
    func audioModulateSpaceWarpOriginY(_ value: Float) { withLock { _spaceWarpParam2 = value } }
    func audioModulateSpaceWarpOriginZ(_ value: Float) { withLock { _spaceWarpParam3 = value } }

    /// Generic, catalog-clamped audio-modulation entry (parameter-node hierarchy
    /// Slice 9). Clamps `value` to the routed descriptor's authoritative
    /// `ParameterCatalog` spec range — the single source of truth — then writes it
    /// through that descriptor's off-main settings binding.
    ///
    /// This is the sanctioned front door for driving a routed core/effect/space
    /// scalar from the audio layer: new parameters get audio modulation for free by
    /// authoring a descriptor, instead of hand-writing a per-name `audioModulate<Name>`
    /// setter with its own copied `ControlCatalog.<spec>.clamp` literal (the "6th
    /// registry" the migration set out to retire). The per-name setters remain because
    /// the animation-playback compose loop calls them directly; `ParameterCatalogTests`
    /// asserts each one clamps to its descriptor's spec, so the two clamp paths can't
    /// silently drift. No-op for an unknown id.
    ///
    /// The clamp is computed lock-free (`spec.clamp` is pure) and the binding write is
    /// invoked outside any lock, so it composes with the lock-taking property setters
    /// without reentrancy.
    func audioModulate(targetID: String, value: Float) {
        guard let descriptor = ParameterCatalog.byID[targetID] else { return }
        descriptor.settings.write(self, descriptor.clamp(value))
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
        set {
            // Clamp via the single-source spec — feeds a per-pixel GPU loop count,
            // so an unclamped value was a watchdog-hang risk (was raw assignment).
            withLock { _colorIterations = ControlCatalog.colorIterations.clamp(newValue) }
            persistColor()
        }
    }
    
    var resolutionScale: Float {
        get { withLock { _resolutionScale } }
        // Min 0.33 (33%) for expanded low-resolution budget options
        // Max 1.0 (100%) - no upscaling needed
        // Sweet spot is 0.67-0.75 for best quality/performance balance
        set { withLock { _resolutionScale = ControlCatalog.resolutionScale.clamp(newValue) } }
    }

    /// visionOS-only: drives `layerRenderer.renderQuality`, the compositor's
    /// native, gaze-foveated drawable resolution. 1.0 = native (sharpest); lower
    /// lets the compositor render a smaller drawable and upscale it with a
    /// smoothed transition. Orthogonal to `resolutionScale` (the MetalFX input
    /// scale) — this is the preferred sharpness/perf lever on Vision Pro.
    var renderQuality: Float {
        get { withLock { _renderQuality } }
        set { withLock { _renderQuality = max(QualityConfig.visionMinRenderQuality, min(QualityConfig.visionMaxRenderQuality, newValue)) } }
    }

    /// visionOS-only: when on, the renderer auto-lowers the applied compositor
    /// Render Quality to hold the frame rate and recovers toward `renderQuality`
    /// (the ceiling) when FPS has headroom. See `AdaptiveRenderQualityController`.
    var adaptiveRenderQualityEnabled: Bool {
        get { withLock { _adaptiveRenderQualityEnabled } }
        set {
            withLock { _adaptiveRenderQualityEnabled = newValue }
            persistQuality()
        }
    }

    var fractalType: FractalModelType {
        get { withLock { _fractalType } }
        set {
            withLock {
                let oldValue = _fractalType
                _fractalType = newValue
                // Single descriptor lookup — reused for params and gesture validation.
                let desc = FractalTypeRegistry.descriptor(for: newValue)

                // ── Per-fractal gesture binding save / restore ───────────
                // Save current gesture bindings under the old fractal type.
                if oldValue != newValue {
                    PerFractalGestureStore.save(_gestureBindings, for: oldValue)
                }
                // Try to restore saved bindings for the new fractal type.
                if let saved = PerFractalGestureStore.load(for: newValue) {
                    _gestureBindings = saved
                }

                // Auto-set default formula params when switching types
                if FormulaCatalog.shared.descriptor(for: newValue) != nil {
                    _formulaParams = FormulaCatalog.shared.buildParams(for: newValue)
                } else {
                    _formulaParams = desc.defaultFormulaParams()
                }
                _syncAnimationBaseFormulaParamsFromCurrent_locked()
                _manualOffsetFormulaParams = Array(repeating: 0.0, count: 16)

                // Apply per-type default color scheme if specified.
                if let scheme = desc.defaultColorScheme {
                    _targetColorScheme = scheme
                    _colorSchemeTransitionProgress = 0.0
                    syncGradientPresetForColorSchemeLocked(scheme)
                }

                // Rebind any gesture fingers assigned to core actions unsupported by
                // the new fractal type (e.g. fractalScale on non-Mandelbox), and
                // clean cross-type .parameter() bindings that belong to a different
                // fractal type.
                let supported = Set(desc.supportedCoreGestureActions)
                func sanitize(_ binding: inout GestureActionBinding) {
                    switch binding {
                    case .core(let action):
                        if !supported.contains(action) {
                            binding = .core(.none)
                        }
                    case .parameter(let descriptor):
                        // Universal core params (no formulaIndex, e.g. sphere
                        // projection) work on every fractal — keep them. Only
                        // type-specific formula params get cleared cross-type.
                        if descriptor.formulaIndex != nil && descriptor.fractalType != newValue {
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

                // Apply per-type default triplet bindings (e.g. Kleinian Mins/Maxs).
                let tripletDefaults = desc.defaultTripletBindings
                if !tripletDefaults.isEmpty,
                   let catDesc = FormulaCatalog.shared.descriptor(for: newValue) {
                    // Build triplet lookup from catalog parameter names.
                    var prefixGroups: [String: [(index: Int, name: String, lo: Float, hi: Float)]] = [:]
                    for param in catDesc.params {
                        guard !(param.isBool ?? false) else { continue }
                        for suffix in [".x", ".y", ".z"] {
                            if param.name.hasSuffix(suffix) {
                                let prefix = String(param.name.dropLast(suffix.count))
                                prefixGroups[prefix, default: []].append(
                                    (param.index, param.name, param.min, param.max)
                                )
                            }
                        }
                    }
                    for (slot, groupName) in tripletDefaults {
                        let key = slot.persistenceKey
                        let current = _gestureBindings[key] ?? .core(.none)
                        guard case .core(.none) = current else { continue }
                        guard let members = prefixGroups[groupName], members.count == 3,
                              let x = members.first(where: { $0.name.hasSuffix(".x") }),
                              let y = members.first(where: { $0.name.hasSuffix(".y") }),
                              let z = members.first(where: { $0.name.hasSuffix(".z") })
                        else { continue }
                        let lo = Swift.min(x.lo, y.lo, z.lo)
                        let hi = Swift.max(x.hi, y.hi, z.hi)
                        let triplet = GestureBindableTriplet(
                            fractalType: newValue,
                            groupName: groupName,
                            xNodeID: ParameterTargetID.formula(fractalType: newValue, formulaIndex: x.index, name: x.name),
                            yNodeID: ParameterTargetID.formula(fractalType: newValue, formulaIndex: y.index, name: y.name),
                            zNodeID: ParameterTargetID.formula(fractalType: newValue, formulaIndex: z.index, name: z.name),
                            xFormulaIndex: x.index,
                            yFormulaIndex: y.index,
                            zFormulaIndex: z.index,
                            range: lo...hi,
                            display: GestureDisplayMetadata(
                                title: "\(groupName) XYZ",
                                subtitle: catDesc.name,
                                icon: "move.3d"
                            )
                        )
                        _gestureBindings[key] = .parameterTriplet(triplet)
                        // Mutual exclusion: clear the both-hand slot for this finger.
                        let bothKey = GestureSlot(hand: .both, finger: slot.finger).persistenceKey
                        _gestureBindings[bothKey] = .core(.none)
                    }
                }

                // Apply per-type default scalar bindings (e.g. Mandelbulb Power, PolarRotation).
                let scalarDefaults = desc.defaultScalarBindings
                if !scalarDefaults.isEmpty,
                   let catDesc = FormulaCatalog.shared.descriptor(for: newValue) {
                    let paramLookup = Dictionary(uniqueKeysWithValues: catDesc.params.map { ($0.name, $0) })
                    for (slot, paramName) in scalarDefaults {
                        let key = slot.persistenceKey
                        let current = _gestureBindings[key] ?? .core(.none)
                        guard case .core(.none) = current else { continue }
                        guard let param = paramLookup[paramName], !(param.isBool ?? false) else { continue }
                        let nodeID = ParameterTargetID.formula(fractalType: newValue, formulaIndex: param.index, name: param.name)
                        let binding = GestureBindableParameter(
                            fractalType: newValue,
                            parameterNodeID: nodeID,
                            formulaIndex: param.index,
                            display: GestureDisplayMetadata(
                                title: param.name,
                                subtitle: catDesc.name,
                                icon: "slider.horizontal.3"
                            )
                        )
                        _gestureBindings[key] = .parameter(binding)
                        // Mutual exclusion: clear the both-hand slot for this finger.
                        let bothKey = GestureSlot(hand: .both, finger: slot.finger).persistenceKey
                        _gestureBindings[bothKey] = .core(.none)
                    }
                }
            }
        }
    }

    var formulaParams: FormulaParams {
        get { withLock { _formulaParams } }
        set {
            withLock {
                _formulaParams = newValue
                if !_isAnimationPlaying {
                    _syncAnimationBaseFormulaParamsFromCurrent_locked()
                }
            }
        }
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

    /// Experimental: enable coherent-packet predict-validate raymarch path.
    /// Replaces the prevDepth*0.9 warm-start heuristic with a single-DE-eval
    /// safety probe and gates shared shadows on local normal coherence.
    /// Only takes effect on the 8x8 adaptive compute path (tileSize == 8).
    var coherentPacketEnabled: Bool {
        get { withLock { _coherentPacketEnabled } }
        set {
            withLock { _coherentPacketEnabled = newValue }
            persistQuality()
        }
    }

    /// Compute path (tileSize == 8): enable temporal reprojection and the
    /// tile/supertile previous-frame depth seeding that skips the per-tile coarse
    /// march. This is the path's main speedup, but the seed can start the fine
    /// march past disocclusion-exposed geometry, leaving whole 8x8/32x32 tiles
    /// blank. Off = full coarse+fine march every frame (correct, slower baseline).
    var computeTemporalReprojectionEnabled: Bool {
        get { withLock { _computeTemporalReprojectionEnabled } }
        set {
            withLock { _computeTemporalReprojectionEnabled = newValue }
            persistQuality()
        }
    }

    /// visionOS fragment path: conservative cone coarse-prepass warm-start. A
    /// low-res compute pass marches a CONE per 8x8 block and writes a provable
    /// LOWER BOUND on the entry distance of the nearest surface for every full-res
    /// ray in that block. The fragment march then raises its start `t` to that
    /// bound (skip-to-then-full-march), skipping provably-empty space without ever
    /// skipping a surface. Defaults OFF — when off the cone pass is never
    /// dispatched, the function constant stays undefined, and the code path is
    /// byte-for-byte identical to before. Only engages for box/fold fractals on an
    /// un-warped domain (the conservative analytic lower bound holds there).
    var coarsePrepassWarmStartEnabled: Bool {
        get { withLock { _coarsePrepassWarmStartEnabled } }
        set {
            withLock { _coarsePrepassWarmStartEnabled = newValue }
            persistQuality()
        }
    }

    /// Foveated raymarching strength (0...1). 0 = uniform full-quality march
    /// everywhere; higher values march progressively fewer ray steps in the
    /// peripheral 8x8 tiles. Only affects the 8x8 adaptive compute path.
    var foveationStrength: Float {
        get { withLock { _foveationStrength } }
        set {
            let clamped = max(0.0, min(1.0, newValue))
            withLock { _foveationStrength = clamped }
            persistQuality()
        }
    }

    /// Smart advance: grazing-aware lead-ahead sphere tracing. When on, the
    /// march reads the along-ray DE gradient each step and steps further through
    /// grazing/receding regions (where plain tracing creeps), guarded by the same
    /// overstep-failure retreat as the Keinert over-relaxation. Off by default;
    /// affects every raymarch path (Mac fragment + visionOS compute).
    var smartAdvanceEnabled: Bool {
        get { withLock { _smartAdvanceEnabled } }
        set {
            withLock { _smartAdvanceEnabled = newValue }
            persistQuality()
        }
    }

    /// Cone marching strength (0...1, 0 = off). Scales how far the march
    /// acceptance threshold grows with ray distance, so a ray stops once the
    /// distance field is within ~N projected pixels of footprint (after Mansour's
    /// ConeMarchingPen). Higher = distant geometry resolves in far fewer steps
    /// (faster) at the cost of softening far detail; near geometry keeps full
    /// sharpness. Affects every raymarch path (Mac fragment + visionOS compute).
    var coneMarchStrength: Float {
        get { withLock { _coneMarchStrength } }
        set {
            withLock { _coneMarchStrength = max(0.0, min(1.0, newValue)) }
            persistQuality()
        }
    }

    /// Over-relaxation ceiling (Keinert enhanced sphere tracing). The largest
    /// `stepMultiplier` the geometry-settle auto-ramp may reach. 1.0 = plain
    /// conservative sphere tracing; up to 1.6 takes bigger over-relaxed steps
    /// (faster, guarded by the in-shader overstep-failure retreat + per-type cap).
    var overRelaxationMax: Float {
        get { withLock { _overRelaxationMax } }
        set {
            withLock { _overRelaxationMax = max(1.0, min(1.6, newValue)) }
            persistQuality()
        }
    }

    /// Distance-based iteration LOD (0...1, 0 = off). Drops fractal iterations on
    /// faraway march samples where the lost detail is already sub-pixel.
    var distanceLODStrength: Float {
        get { withLock { _distanceLODStrength } }
        set {
            withLock { _distanceLODStrength = max(0.0, min(1.0, newValue)) }
            persistQuality()
        }
    }

    /// Self-shadowing. When false the two per-pixel shadow marches are skipped
    /// for flatter, cheaper lighting.
    var shadowsEnabled: Bool {
        get { withLock { _shadowsEnabled } }
        set {
            withLock { _shadowsEnabled = newValue }
            persistQuality()
        }
    }

    /// Bounding Shape (sphere for now). When true the uniform builders feed
    /// `boundingShapeRadius` so rays that miss the sphere skip the march
    /// entirely — bounding the visible fractal to the shape.
    var boundingSphereSkipEnabled: Bool {
        get { withLock { _boundingSphereSkipEnabled } }
        set {
            withLock { _boundingSphereSkipEnabled = newValue }
            persistQuality()
        }
    }

    /// Radius of the bounding shape in model units. Only takes effect while
    /// `boundingSphereSkipEnabled` is on.
    var boundingShapeRadius: Float {
        get { withLock { _boundingShapeRadius } }
        set {
            withLock { _boundingShapeRadius = max(0.05, min(30.0, newValue)) }
            persistQuality()
        }
    }

    /// Bounding-edge treatment: 0 = off (hard clip), 1 = Ghost Fade (fades RGB and,
    /// under passthrough, alpha too — translucent), 2 = Inner Shadow (fades RGB
    /// only — stays opaque). Only takes effect while `boundingSphereSkipEnabled` is on.
    var boundingShapeFogMode: Int {
        get { withLock { _boundingShapeFogMode } }
        set {
            withLock { _boundingShapeFogMode = max(0, min(2, newValue)) }
            persistQuality()
        }
    }

    /// Inner Shadow band width, as a fraction of `boundingShapeRadius` (0...1).
    /// Only takes effect while `boundingShapeFogMode == 2`.
    var boundingShapeShadowDepth: Float {
        get { withLock { _boundingShapeShadowDepth } }
        set {
            withLock { _boundingShapeShadowDepth = max(0.02, min(0.95, newValue)) }
            persistQuality()
        }
    }

    /// Bounding Shape family/preset. 0...1 = sphere/cube morph (no rotation),
    /// 2...6 select discrete platonic solids — same encoding as `safetyBubbleShape`.
    var boundingShapeType: Float {
        get { withLock { _boundingShapeType } }
        set {
            withLock { _boundingShapeType = max(0.0, min(SafetyBubbleShapePreset.maxStoredValue, newValue)) }
            persistQuality()
        }
    }

    /// Zoom fog compensation: scale fog intensity down as the model zooms out so
    /// the fog sphere's WORLD radius stays constant instead of swallowing the
    /// fractal. Off = raw fog at every zoom (fog operates on model-space march
    /// distance). Was previously hardcoded on for the Kleinian family.
    var zoomFogCompensationEnabled: Bool {
        get { withLock { _zoomFogCompensationEnabled } }
        set {
            withLock { _zoomFogCompensationEnabled = newValue }
            persistQuality()
        }
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
    
    var showMusicShortcuts: Bool {
        get { withLock { _showMusicShortcuts } }
        set {
            withLock { _showMusicShortcuts = newValue }
            persistDisplay()
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

    /// Enable/disable the menu toggle gesture without disabling parameter gestures.
    var menuToggleGestureEnabled: Bool {
        get { withLock { _menuToggleGestureEnabled } }
        set {
            withLock { _menuToggleGestureEnabled = newValue }
            persistGesture()
        }
    }

    /// Which right-hand gesture toggles the floating menu window.
    var menuToggleGestureMode: MenuToggleGestureMode {
        get { withLock { _menuToggleGestureMode } }
        set {
            withLock { _menuToggleGestureMode = newValue }
            persistGesture()
        }
    }

    // ── Per-hand gesture binding accessors ──────────────────────────────────

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
                    // Check if the other hand also has a binding for this finger;
                    // if so, clear the both-hand slot.
                    let otherHand: GestureHandMode = (slot.hand == .left) ? .right : .left
                    let hasOtherBinding = GestureDirection.allCases.contains { dir in
                        let otherKey = GestureSlot(hand: otherHand, finger: slot.finger, direction: dir).persistenceKey
                        if let b = _gestureBindings[otherKey], b != .core(.none) { return true }
                        return false
                    }
                    if hasOtherBinding {
                        let bothKey = GestureSlot(hand: .both, finger: slot.finger).persistenceKey
                        _gestureBindings[bothKey] = .core(.none)
                    }
                } else if slot.hand == .both {
                    // Clear all single-hand directional sub-slots for this finger
                    for dir in GestureDirection.allCases {
                        let leftKey = GestureSlot(hand: .left, finger: slot.finger, direction: dir).persistenceKey
                        let rightKey = GestureSlot(hand: .right, finger: slot.finger, direction: dir).persistenceKey
                        _gestureBindings[leftKey] = .core(.none)
                        _gestureBindings[rightKey] = .core(.none)
                    }
                }
            }
        }
        persistGesture()
        // Also save bindings under the current fractal type for per-fractal restore.
        withLock {
            PerFractalGestureStore.save(_gestureBindings, for: _fractalType)
        }
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

    /// Returns the binding for a given hand mode and digit (1=index, 2=middle, 3=ring).
    func binding(forHand hand: GestureHandMode, digit: Int) -> GestureActionBinding {
        guard let finger = FingerDigit(rawValue: digit) else { return .core(.none) }
        return binding(for: GestureSlot(hand: hand, finger: finger))
    }

    // MARK: - Per-Finger Tap Gesture Layer

    var perFingerTapGestureEnabled: Bool {
        get { withLock { _perFingerTapGestureEnabled } }
        set {
            withLock { _perFingerTapGestureEnabled = newValue }
            persistGesture()
        }
    }

    var perFingerTapLeftActions: [PerFingerTapAction] {
        get { withLock { _perFingerTapLeftActions } }
        set {
            withLock { _perFingerTapLeftActions = newValue }
            persistGesture()
        }
    }

    var perFingerTapRightActions: [PerFingerTapAction] {
        get { withLock { _perFingerTapRightActions } }
        set {
            withLock { _perFingerTapRightActions = newValue }
            persistGesture()
        }
    }

    var perFingerTapActivateThreshold: Float {
        get { withLock { _perFingerTapActivateThreshold } }
        set {
            let clamped = max(0.2, min(0.95, newValue))
            withLock { _perFingerTapActivateThreshold = clamped }
            persistGesture()
        }
    }

    var perFingerTapReleaseThreshold: Float {
        get { withLock { _perFingerTapReleaseThreshold } }
        set {
            let clamped = max(0.1, min(0.9, newValue))
            withLock { _perFingerTapReleaseThreshold = clamped }
            persistGesture()
        }
    }

    var perFingerTapHoldDuration: Float {
        get { withLock { _perFingerTapHoldDuration } }
        set {
            let clamped = max(0.05, min(0.6, newValue))
            withLock { _perFingerTapHoldDuration = clamped }
            persistGesture()
        }
    }

    var perFingerTapCooldown: Float {
        get { withLock { _perFingerTapCooldown } }
        set {
            let clamped = max(0.1, min(2.5, newValue))
            withLock { _perFingerTapCooldown = clamped }
            persistGesture()
        }
    }

    /// Device-local: hand-dominance is intentionally stored as a bare UserDefaults
    /// key and deliberately omitted from the domain save/restore + iCloud sync, since
    /// it pairs with the device-local gesture bindings and shouldn't follow a preset
    /// or sync across devices.
    var leftHandedMode: Bool {
        get { withLock { _leftHandedMode } }
        set {
            withLock { _leftHandedMode = newValue }
            UserDefaults.standard.set(newValue, forKey: "leftHandedMode")
        }
    }

    /// macOS-only: when enabled, tilting the laptop orbits the fractal via the
    /// built-in Sudden Motion Sensor (Intel MacBooks only; a no-op where the
    /// sensor is unavailable).
    ///
    /// Device-local: stored as a bare UserDefaults key and deliberately omitted from
    /// the domain save/restore + iCloud sync, since the tilt sensor only exists on
    /// Intel MacBooks and the setting is meaningless to sync to other devices.
    var macTiltControlEnabled: Bool {
        get { withLock { _macTiltControlEnabled } }
        set {
            withLock { _macTiltControlEnabled = newValue }
            UserDefaults.standard.set(newValue, forKey: "macTiltControlEnabled")
        }
    }

    // MARK: - Spring Blob State (retained renderer subsystem; no longer gesture-activated)

    var springDisplacement: SIMD3<Float> {
        get { withLock { _springDisplacement } }
        set { withLock { _springDisplacement = newValue } }
    }

    var springVelocity: SIMD3<Float> {
        get { withLock { _springVelocity } }
        set { withLock { _springVelocity = newValue } }
    }

    var springActive: Bool {
        get { withLock { _springActive } }
        set { withLock { _springActive = newValue } }
    }

    /// Tick spring physics. Call once per frame from render loop.
    /// Returns the position delta to apply to the fractal this frame.
    func tickSpring(dt: Float) -> SIMD3<Float> {
        withLock {
            let stiffness: Float = 45.0   // Spring constant (higher = snappier return)
            let damping: Float = 6.0      // Damping (higher = less oscillation)
            let maxDisplacement: Float = 0.5 // Max stretch in logical units
            let flingMultiplier: Float = 2.5 // How much velocity converts to position fling

            if _springActive {
                // While pulling: spring provides resistance (displacement grows sublinearly)
                // Velocity is stored for fling on release
                // No position delta applied while pulling — movement happens on release
                let force = -stiffness * _springDisplacement - damping * _springVelocity
                _springVelocity += force * dt
                // Clamp displacement magnitude
                let mag = simd_length(_springDisplacement)
                if mag > maxDisplacement {
                    _springDisplacement = simd_normalize(_springDisplacement) * maxDisplacement
                }
                return .zero
            } else {
                // Released: spring drives position via velocity fling + decay
                let force = -stiffness * _springDisplacement - damping * _springVelocity
                _springVelocity += force * dt
                _springDisplacement += _springVelocity * dt

                // Position delta: velocity scaled for fling effect
                let positionDelta = _springVelocity * dt * flingMultiplier

                // Kill tiny oscillations
                if simd_length(_springDisplacement) < 0.001 && simd_length(_springVelocity) < 0.001 {
                    _springDisplacement = .zero
                    _springVelocity = .zero
                }

                return positionDelta
            }
        }
    }

    /// Enable safety bubble around the camera to prevent clipping into fractal geometry
    var safetyBubbleEnabled: Bool {
        get { withLock { _safetyBubbleEnabled } }
        set {
            withLock { _safetyBubbleEnabled = newValue }
            persistSafetyBubble()
        }
    }

    /// Radius of the safety bubble in meters (0.05 - 2.5)
    var safetyBubbleRadius: Float {
        get { withLock { _safetyBubbleRadius } }
        set {
            withLock { _safetyBubbleRadius = ControlCatalog.safetyBubbleRadius.clamp(newValue) }
            persistSafetyBubble()
        }
    }
    
    /// Shape of the safety bubble.
    /// 0...1 preserve the legacy sphere/cube morph, 2...6 select discrete solids.
    /// The bubble stays axis-aligned and only translates with the viewer position.
    var safetyBubbleShape: Float {
        get { withLock { _safetyBubbleShape } }
        set {
            withLock { _safetyBubbleShape = max(0.0, min(SafetyBubbleShapePreset.maxStoredValue, newValue)) }
            persistSafetyBubble()
        }
    }

    /// Compatibility alias for the legacy safety-bubble blend slider.
    /// Maps onto the shader's temporal bubble-strength control.
    var safetyBubbleBlend: Float {
        get { withLock { _safetyBubbleStrength } }
        set {
            withLock { _safetyBubbleStrength = max(0.0, min(1.0, newValue)) }
            persistSafetyBubble()
        }
    }

    var safetyBubbleFadeEnabled: Bool { withLock { _safetyBubbleFadeEnabled } }

    var safetyBubbleFadeWidth: Float { withLock { _safetyBubbleFadeWidth } }

    var safetyBubbleStrength: Float { withLock { _safetyBubbleStrength } }

    /// Enable the Hand Attraction interaction sphere on each tracked hand (visionOS only).
    var handAttractionEnabled: Bool {
        get { withLock { _handAttractionEnabled } }
        set {
            withLock { _handAttractionEnabled = newValue }
            persistHandAttraction()
        }
    }

    /// Per-hand influence radius, in meters (0.05 - 1.0).
    var handAttractionRadius: Float {
        get { withLock { _handAttractionRadius } }
        set {
            withLock { _handAttractionRadius = max(0.05, min(1.0, newValue)) }
            persistHandAttraction()
        }
    }

    /// How strongly the fractal surface reaches for the hand within its radius (0...1).
    var handAttractionStrength: Float {
        get { withLock { _handAttractionStrength } }
        set {
            withLock { _handAttractionStrength = max(0.0, min(1.0, newValue)) }
            persistHandAttraction()
        }
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
    
    /// Transition progress (0 = start, 1 = complete)
    var colorSchemeTransitionProgress: Float {
        get { withLock { _colorSchemeTransitionProgress } }
        set { withLock { _colorSchemeTransitionProgress = max(0.0, min(1.0, newValue)) } }
    }
    
    /// Duration of color scheme transitions in seconds
    var colorSchemeTransitionDuration: Float {
        get { withLock { _colorSchemeTransitionDuration } }
        set { withLock { _colorSchemeTransitionDuration = ControlCatalog.colorSchemeTransitionDuration.clamp(newValue) } }
    }
    
    /// Enable auto-cycling through color schemes
    var colorSchemeAutoTransition: Bool {
        get { withLock { _colorSchemeAutoTransition } }
        set { withLock { _colorSchemeAutoTransition = newValue } }
    }
    
    /// Seconds between auto-transitions
    var colorSchemeAutoInterval: Float {
        get { withLock { _colorSchemeAutoInterval } }
        set { withLock { _colorSchemeAutoInterval = ControlCatalog.colorSchemeAutoInterval.clamp(newValue) } }
    }
    
    /// Saturation override (independent of scheme default)
    var colorSchemeSaturation: Float {
        get { withLock { _colorSchemeSaturation } }
        set {
            withLock { _colorSchemeSaturation = max(0.0, min(3.0, newValue)) }
            persistColor()
        }
    }
    
    /// Contrast override
    var colorSchemeContrast: Float {
        get { withLock { _colorSchemeContrast } }
        set {
            withLock { _colorSchemeContrast = ControlCatalog.colorSchemeContrast.clamp(newValue) }
            persistColor()
        }
    }
    
    /// Gamma override
    var colorSchemeGamma: Float {
        get { withLock { _colorSchemeGamma } }
        set {
            withLock { _colorSchemeGamma = ControlCatalog.colorSchemeGamma.clamp(newValue) }
            persistColor()
        }
    }
    
    /// Vibrance boost (0-1)
    var colorSchemeVibrance: Float {
        get { withLock { _colorSchemeVibrance } }
        set {
            withLock { _colorSchemeVibrance = ControlCatalog.colorSchemeVibrance.clamp(newValue) }
            persistColor()
        }
    }
    
    /// Lighting softness (0 = sharp vibrance-driven, 1 = classic soft)
    var lightingSoftness: Float {
        get { withLock { _lightingSoftness } }
        set {
            withLock { _lightingSoftness = ControlCatalog.lightingSoftness.clamp(newValue) }
            persistColor()
        }
    }

    var cellShadingEnabled: Bool {
        get { withLock { _cellShadingEnabled } }
        set {
            withLock { _cellShadingEnabled = newValue }
            persistColor()
        }
    }

    var cellShadingLevels: Float {
        get { withLock { _cellShadingLevels } }
        set {
            withLock { _cellShadingLevels = ControlCatalog.cellShadingLevels.clamp(newValue) }
            persistColor()
        }
    }

    /// Ambient-occlusion blend (0 = old flat hemisphere ambient, 1 = full SDF AO march)
    var aoStrength: Float {
        get { withLock { _aoStrength } }
        set {
            withLock { _aoStrength = ControlCatalog.aoStrength.clamp(newValue) }
            persistColor()
        }
    }

    /// Filmic (ACES) tonemap blend (0 = old plain clamp, 1 = full filmic curve)
    var tonemapStrength: Float {
        get { withLock { _tonemapStrength } }
        set {
            withLock { _tonemapStrength = ControlCatalog.tonemapStrength.clamp(newValue) }
            persistColor()
        }
    }
    
    /// Midtone curve adjustment (-1 to 1)
    var colorSchemeCurve: Float {
        get { withLock { _colorSchemeCurve } }
        set {
            withLock { _colorSchemeCurve = ControlCatalog.colorSchemeCurve.clamp(newValue) }
            persistColor()
        }
    }
    
    /// Shadow lift/crush (-0.05 to 0.05)
    var colorSchemeShadows: Float {
        get { withLock { _colorSchemeShadows } }
        set {
            withLock { _colorSchemeShadows = ControlCatalog.colorSchemeShadows.clamp(newValue) }
            persistColor()
        }
    }
    
    /// Highlight boost/reduction (-0.5 to 1.0)
    var colorSchemeHighlights: Float {
        get { withLock { _colorSchemeHighlights } }
        set {
            withLock { _colorSchemeHighlights = ControlCatalog.colorSchemeHighlights.clamp(newValue) }
            persistColor()
        }
    }
    
    // ═══════════════════════════════════════════════════════════════════════════
    // GRADIENT COLORING SYSTEM
    // ═══════════════════════════════════════════════════════════════════════════
    
    /// Current gradient color map
    var gradientColorMap: GradientColorMap {
        get { withLock { _gradientState.gradient } }
        set {
            withLock {
                var sorted = newValue
                sorted.sortStops()
                _gradientState.gradient = sorted
                _gradientState.markAsCustom()
            }
            persistColor()
        }
    }
    
    /// Current gradient preset (nil if custom)
    var gradientPreset: GradientPreset? {
        get { withLock { _gradientState.gradientPreset } }
    }
    
    /// Color mapping mode for gradient sampling
    var colorMappingMode: ColorMappingMode {
        get { withLock { _gradientState.gradient.mappingMode } }
        set {
            withLock { _gradientState.gradient.mappingMode = newValue }
            persistColor()
        }
    }
    
    /// Gradient repeat count
    var gradientRepeat: Float {
        get { withLock { _gradientState.gradient.repeatCount } }
        set {
            withLock { _gradientState.gradient.repeatCount = max(0.1, min(10.0, newValue)) }
            persistColor()
        }
    }
    
    /// Gradient offset
    var gradientOffset: Float {
        get { withLock { _gradientState.gradient.offset } }
        set {
            withLock { _gradientState.gradient.offset = newValue }
            persistColor()
        }
    }
    
    /// Gradient smoothing
    var gradientSmoothing: Float {
        get { withLock { _gradientState.gradient.smoothing } }
        set {
            withLock { _gradientState.gradient.smoothing = max(0.0, min(1.0, newValue)) }
            persistColor()
        }
    }
    
    /// Apply a gradient preset (replaces current gradient and enables gradient mode)
    func applyGradientPreset(_ preset: GradientPreset) {
        withLock {
            _gradientState.applyPreset(preset)
            
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
        persistColor()
    }
    
    /// Full gradient state (for serialization)
    var gradientState: GradientState {
        get { withLock { _gradientState } }
        set {
            withLock {
                var sorted = newValue
                sorted.gradient.sortStops()
                _gradientState = sorted
            }
            persistColor()
        }
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
                    _linearRailEffect = effects.linearRail
                }
            }
            persistLighting()
        }
    }

    /// Master speed for time-based light/color variation — hue rotation, pulse,
    /// and gradient cycle. 1.0 = full speed, 0.0 = lights hold steady. Lets the
    /// user calm overly-flashy animation without disabling individual effects or
    /// touching geometry/camera motion (Linear Rail, Polar Rotation, etc.).
    var lightVariationRate: Float {
        get { withLock { _lightVariationRate } }
        set {
            withLock { _lightVariationRate = max(0.0, min(1.0, newValue)) }
            persistLighting()
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
            persistLighting()
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
            persistLighting()
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
            persistLighting()
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
            persistLighting()
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
            persistLighting()
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
            persistLighting()
        }
    }

    /// Linear rail effect (pulses the render position along a centered axis)
    var linearRailEffect: LinearRailEffect {
        get { withLock { _linearRailEffect } }
        set {
            withLock {
                _linearRailEffect = newValue
                _lightingPreset = .custom
            }
            persistLighting()
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
            persistLighting()
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
            persistLighting()
        }
    }

    /// Julia C drift effect (orbits Julia C vector for Mandelbulb Julia)
    var juliaDriftEffect: JuliaDriftEffect {
        get { withLock { _juliaDriftEffect } }
        set {
            withLock {
                _juliaDriftEffect = newValue
                _lightingPreset = .custom
            }
            persistLighting()
        }
    }
    
    // === GEOMETRY STABILITY STATE (read-only) ===
    
    /// Whether a geometry-affecting gesture is currently active (read-only).
    /// Set internally by the geometry state machine in `interpolateToTargets`.
    var isGeometryGestureActive: Bool {
        get { withLock { _isGeometryGestureActive } }
        set { withLock { _isGeometryGestureActive = newValue } }
    }
    
    /// Update color scheme transitions and animation time. Call once per frame.
    func updateColorSchemeTransition(deltaTime: Float) {
        withLock {
            if _animationKillSwitchActive {
                _animationKillSwitchRemaining = max(0.0, _animationKillSwitchRemaining - deltaTime)
                if _animationKillSwitchDuration > 0.0001 {
                    _animationActivityFactor = max(0.0, min(1.0, _animationKillSwitchRemaining / _animationKillSwitchDuration))
                } else {
                    _animationActivityFactor = 0.0
                }

                if _animationKillSwitchRemaining <= 0.0001 {
                    _animationKillSwitchRemaining = 0.0
                    _animationActivityFactor = 0.0
                    _animationKillSwitchActive = false
                }
            }

            // Update animation time. _colorAnimTime is the raw clock (position effects);
            // _lightAnimTime is scaled by the master variation rate so the user can slow
            // down flashy hue/pulse/gradient cycling without freezing camera motion.
            _colorAnimTime += deltaTime * _animationActivityFactor
            let lightStep = deltaTime * _animationActivityFactor * _lightVariationRate
            _lightAnimTime += lightStep

            // Integrate cycle phases from the *current* speeds (and audio coupling) rather
            // than multiplying an accumulated clock by a live speed. This is the fix for
            // colours snapping when you drag a cycle speed, and for hue jumping on treble
            // transients: a rate change now only affects how fast the phase advances next.
            let twoPi = Float.pi * 2.0
            if _hueRotationEffect.enabled {
                // Treble excites the spin rate (same coupling as before — now integrated,
                // so a treble spike speeds the drift instead of teleporting the hue).
                let audioHueBoost = 1.0 + _trebleLevel * 0.35
                _huePhase += lightStep * _hueRotationEffect.speed * twoPi * audioHueBoost
                _huePhase = _huePhase.truncatingRemainder(dividingBy: twoPi)
            }
            if _pulseEffect.enabled {
                _pulsePhase += lightStep * _pulseEffect.speed * twoPi
                _pulsePhase = _pulsePhase.truncatingRemainder(dividingBy: twoPi)
            }
            if _fogEffect.hueRotateEnabled {
                // Fog tint cycles its hue on its own timer. Uses the same
                // master-variation-scaled `lightStep` as the global hue rotation
                // so the Color Shift Speed slider calms it too; no audio coupling
                // keeps it a steady atmospheric drift.
                _fogHuePhase += lightStep * _fogEffect.hueRotateSpeed * twoPi
                _fogHuePhase = _fogHuePhase.truncatingRemainder(dividingBy: twoPi)
            }
            if _gradientCycleEffect.enabled {
                _gradientPhase += lightStep * _gradientCycleEffect.speed
                _gradientPhase = _gradientPhase.truncatingRemainder(dividingBy: 1.0)
            }

            // Accumulate polar rotation angle when enabled and fractal supports it
            if _polarRotationEffect.enabled && _fractalType.supports(.polarRotation) {
                // Apply rotation based on configured speed and direction
                let effectSpeed = _polarRotationEffect.speed * _polarRotationEffect.direction.sign
                _polarRotationAccum += deltaTime * effectSpeed
            }

            // Accumulate Julia C drift angle when enabled and fractal supports it
            if _juliaDriftEffect.enabled && _fractalType.supports(.juliaDrift) {
                _juliaDriftAccum += deltaTime * _juliaDriftEffect.speed
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
                    // Advance to next scheme using cached array + tracked index (avoids firstIndex search)
                    let allSchemes = Self.colorSchemeCycle
                    if !allSchemes.isEmpty {
                        _colorSchemeCycleIndex = (_colorSchemeCycleIndex + 1) % allSchemes.count
                        let nextScheme = allSchemes[_colorSchemeCycleIndex]
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
        let preset = scheme
        if _gradientState.gradientPreset != preset {
            _gradientState.applyPreset(preset)
        }
    }
    
    /// The fog tint to render this frame. When the fog hue-cycle is enabled, the
    /// configured tint is rotated through the hue wheel by the accumulated
    /// `_fogHuePhase`; otherwise the raw configured color is returned. Caller must
    /// hold the settings lock (reads `_fogEffect` / `_fogHuePhase` backing values).
    private func effectiveFogColorLocked() -> SIMD3<Float> {
        guard _fogEffect.hueRotateEnabled else { return _fogEffect.color }
        let turns = _fogHuePhase / (Float.pi * 2.0)   // radians → [0,1) hue turns
        return Self.shiftHue(_fogEffect.color, byTurns: turns)
    }

    /// Rotates an RGB color's hue by `byTurns` (1.0 = full wheel), preserving
    /// saturation and value. Pure function; used for the fog hue cycle.
    static func shiftHue(_ rgb: SIMD3<Float>, byTurns: Float) -> SIMD3<Float> {
        let r = rgb.x, g = rgb.y, b = rgb.z
        let maxC = max(r, max(g, b))
        let minC = min(r, min(g, b))
        let delta = maxC - minC

        var h: Float = 0
        if delta > 1e-6 {
            if maxC == r {
                h = (g - b) / delta
            } else if maxC == g {
                h = 2 + (b - r) / delta
            } else {
                h = 4 + (r - g) / delta
            }
            h /= 6
        }
        let s = maxC > 1e-6 ? delta / maxC : 0
        let v = maxC

        // Shift hue and wrap into [0,1).
        h = (h + byTurns).truncatingRemainder(dividingBy: 1.0)
        if h < 0 { h += 1 }

        if s <= 1e-6 { return SIMD3<Float>(v, v, v) }   // grey: hue is undefined

        let sector = h * 6.0
        let i = Int(floor(sector)) % 6
        let f = sector - floor(sector)
        let p = v * (1 - s)
        let q = v * (1 - f * s)
        let t = v * (1 - (1 - f) * s)

        switch i {
        case 0: return SIMD3<Float>(v, t, p)
        case 1: return SIMD3<Float>(q, v, p)
        case 2: return SIMD3<Float>(p, v, t)
        case 3: return SIMD3<Float>(p, q, v)
        case 4: return SIMD3<Float>(t, p, v)
        default: return SIMD3<Float>(v, p, q)
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
        
        // === Build gradient stop data for shader (no per-frame allocations) ===
        let gradState = _gradientState
        let stops = gradState.gradient.stops
        let gradCount = min(stops.count, 8)

        @inline(__always)
        func pack(_ stop: GradientStop) -> SIMD4<Float> {
            SIMD4<Float>(stop.color.x, stop.color.y, stop.color.z, stop.position)
        }

        var s0 = SIMD4<Float>(0, 0, 0, 0)
        var s1 = SIMD4<Float>(0, 0, 0, 0)
        var s2 = SIMD4<Float>(0, 0, 0, 0)
        var s3 = SIMD4<Float>(0, 0, 0, 0)
        var s4 = SIMD4<Float>(0, 0, 0, 0)
        var s5 = SIMD4<Float>(0, 0, 0, 0)
        var s6 = SIMD4<Float>(0, 0, 0, 0)
        var s7 = SIMD4<Float>(0, 0, 0, 0)

        if gradCount > 0 { s0 = pack(stops[0]) }
        if gradCount > 1 { s1 = pack(stops[1]) }
        if gradCount > 2 { s2 = pack(stops[2]) }
        if gradCount > 3 { s3 = pack(stops[3]) }
        if gradCount > 4 { s4 = pack(stops[4]) }
        if gradCount > 5 { s5 = pack(stops[5]) }
        if gradCount > 6 { s6 = pack(stops[6]) }
        if gradCount > 7 { s7 = pack(stops[7]) }

        // C array becomes a tuple in Swift — fill all 8 slots
        let gs = (s0, s1, s2, s3, s4, s5, s6, s7)
        
        let animationActivity = _animationActivityFactor

        return ColorSchemeParams(
            saturation: _colorSchemeSaturation,
            contrast: _colorSchemeContrast,
            gamma: _colorSchemeGamma,
            brightness: 0.0,
            vibrance: _colorSchemeVibrance,
            colorCurve: _colorSchemeCurve,
            shadows: _colorSchemeShadows,
            highlights: _colorSchemeHighlights,
            cellShadingEnabled: _cellShadingEnabled ? 1 : 0,
            cellShadingLevels: _cellShadingLevels,
            aoStrength: _aoStrength,
            tonemapStrength: _tonemapStrength,
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
            gradientOffset: gradState.gradient.offset + (_gradientCycleEffect.enabled ? _gradientPhase : 0),
            gradientSmoothing: gradState.gradient.smoothing,
            gradientLoopSmooth: _gradientCycleEffect.mirrorLoop ? 1 : 0,
            _gradPad: (0.0),
            // === MODULAR LIGHTING EFFECTS ===
            animTime: _lightAnimTime,
            hueRotationEnabled: _hueRotationEffect.enabled ? 1 : 0,
            hueCyclePhase: _huePhase,
            hueRotationIntensity: _hueRotationEffect.intensity * animationActivity,
            pulseEnabled: _pulseEffect.enabled ? 1 : 0,
            pulseCyclePhase: _pulsePhase,
            pulseAmount: _pulseEffect.amount * animationActivity,
            glowEnabled: _glowEffect.enabled ? 1 : 0,
            glowIntensity: _glowEffect.intensity,
            bloomEnabled: _bloomEffect.enabled ? 1 : 0,
            bloomStrength: _bloomEffect.strength,
            beatFlashEnabled: _beatFlashEffect.enabled ? 1 : 0,
            beatFlashIntensity: _beatFlashEffect.intensity * animationActivity
        )
    }
    
    /// Get a snapshot of render-critical settings in a single lock.
    func snapshot() -> RenderSettingsSnapshot {
        return withLock {
            // Apply animated polar rotation offset into a local copy of formulaParams
            var fp = _formulaParams
            // Per-type polar-rotation animation now lives on the fractal type
            // (FractalTypeDescriptor.applyPolarRotation — Stage 3 step 5). The guard
            // (effect enabled + capability) stays here; only the per-type math moved.
            if _polarRotationEffect.enabled && _fractalType.supports(.polarRotation) {
                _fractalType.descriptor.applyPolarRotation(into: &fp, accum: _polarRotationAccum)
            }

            // Apply Julia C drift — orbit Julia C vector around diagonal axis (1,1,1)/√3
            // using Rodrigues rotation so all three components evolve smoothly.
            if _juliaDriftEffect.enabled && _fractalType.supports(.juliaDrift) {
                let cx = FormulaCatalog.getParam(fp, index: 9)
                let cy = FormulaCatalog.getParam(fp, index: 10)
                let cz = FormulaCatalog.getParam(fp, index: 11)
                let theta = _juliaDriftAccum
                let cosT = cos(theta)
                let sinT = sin(theta)
                // k = (1,1,1)/√3 — rotation axis
                let inv3: Float = 1.0 / 3.0
                let kDotV = (cx + cy + cz) * inv3  // (k·v) / √3 * √3 = (k·v)
                let oneMinusCos = 1.0 - cosT
                let invSqrt3: Float = 1.0 / sqrt(3.0)
                // k × v = (ky*vz - kz*vy, kz*vx - kx*vz, kx*vy - ky*vx) where kx=ky=kz=1/√3
                let crossX = (cz - cy) * invSqrt3
                let crossY = (cx - cz) * invSqrt3
                let crossZ = (cy - cx) * invSqrt3
                FormulaCatalog.setParam(&fp, index: 9,  value: cx * cosT + crossX * sinT + invSqrt3 * kDotV * oneMinusCos)
                FormulaCatalog.setParam(&fp, index: 10, value: cy * cosT + crossY * sinT + invSqrt3 * kDotV * oneMinusCos)
                FormulaCatalog.setParam(&fp, index: 11, value: cz * cosT + crossZ * sinT + invSqrt3 * kDotV * oneMinusCos)
            }

            let railPosition = linearRailPositionLocked(from: _position)

            return RenderSettingsSnapshot(
                minDistance: _minDistance,
                scale: _scale,
                position: railPosition,
                fractalScale: _fractalScale,
                fractalIterations: _fractalIterations,
                maxRaySteps: _maxRaySteps,
                colorMix: _colorMix,
                lightingPlay: _lightingPlay,
                lightingMode: _lightingMode,
                sphericalInversionMode: _sphericalInversionMode,
                sphericalInversionRadius: _sphericalInversionRadius,
                sphereProjectionEnabled: _sphereProjectionEnabled,
                sphereProjectionBlend: _sphereProjectionBlend,
                sphereProjectionRadius: _sphereProjectionRadius,
                spaceWarpStrength: _spaceWarpStrength,
                spaceWarpParam1: _spaceWarpParam1,
                spaceWarpParam2: _spaceWarpParam2,
                spaceWarpParam3: _spaceWarpParam3,
                spaceWarpAxis: _spaceWarpAxis,
                spaceWarpStack: packedSpaceWarpStackLocked(),
                platformRadius: _platformRadius,
                platformEnabled: _platformEnabled,
                audioLevel: _audioLevel,
                bassLevel: _bassLevel,
                midLevel: _midLevel,
                trebleLevel: _trebleLevel,
                beatIntensity: _beatIntensity,
                foldingLimit: _foldingLimit,
                sphereRadius: _sphereRadius,
                colorIterations: _colorIterations,
                resolutionScale: _resolutionScale,
                fractalType: _fractalType,
                formulaParams: fp,
                tileSize: _tileSize,
                debugHierarchical: _debugHierarchical,
                coherentPacketEnabled: _coherentPacketEnabled,
                computeTemporalReprojectionEnabled: _computeTemporalReprojectionEnabled,
                coarsePrepassWarmStartEnabled: _coarsePrepassWarmStartEnabled,
                foveationStrength: _foveationStrength,
                smartAdvanceEnabled: _smartAdvanceEnabled,
                coneMarchStrength: _coneMarchStrength,
                distanceLODStrength: _distanceLODStrength,
                shadowsEnabled: _shadowsEnabled,
                boundingSphereSkipEnabled: _boundingSphereSkipEnabled,
                boundingShapeRadius: _boundingShapeRadius,
                boundingShapeFogMode: _boundingShapeFogMode,
                boundingShapeShadowDepth: _boundingShapeShadowDepth,
                boundingShapeType: _boundingShapeType,
                zoomFogCompensationEnabled: _zoomFogCompensationEnabled,
                limitFlash: _limitFlash,
                activeGestureIndex: _activeGestureIndex,
                safetyBubbleEnabled: _safetyBubbleEnabled,
                safetyBubbleRadius: _safetyBubbleRadius,
                safetyBubbleShape: _safetyBubbleShape,
                safetyBubbleFadeEnabled: _safetyBubbleFadeEnabled,
                safetyBubbleFadeWidth: _safetyBubbleFadeWidth,
                safetyBubbleStrength: _safetyBubbleStrength,
                handAttractionEnabled: _handAttractionEnabled,
                handAttractionRadius: _handAttractionRadius,
                handAttractionStrength: _handAttractionStrength,
                colorSchemeParams: makeColorSchemeParamsLocked(),
                lightingSoftness: _lightingSoftness,
                fogEnabled: _fogEffect.enabled,
                fogIntensity: _fogEffect.intensity,
                fogColor: effectiveFogColorLocked(),
                worldRotation: _worldRotation,
                detailScale: _detailScale,
                geometryState: _geometryState,
                isGeometryGestureActive: _isGeometryGestureActive,
                stepMultiplier: _stepMultiplier,
                springDisplacement: _springDisplacement,
                springActive: _springActive,
                leftHandedMode: _leftHandedMode
            )
        }
    }

    @inline(__always)
    private func linearRailPositionLocked(from basePosition: SIMD3<Float>) -> SIMD3<Float> {
        let effect = _linearRailEffect
        guard effect.enabled, effect.amplitude > 0.0001 else {
            return basePosition
        }

        let axisVector = effect.axis.vector
        let amplitude = effect.amplitude * _animationActivityFactor
        let orbitMix = max(0.0, min(1.0, effect.orbitAmount))
        let linearMix = 1.0 - orbitMix
        let twoPi = Float.pi * 2.0

        let harmonic = max(0.0, effect.multiplier)
        let linearPhase = _colorAnimTime * effect.speed * harmonic * twoPi
        var offset = axisVector * (sin(linearPhase) * amplitude * linearMix)

        if orbitMix > 0.0001 {
            let planeNormal = simd_normalize(axisVector)
            let hintVector: SIMD3<Float> = abs(planeNormal.y) < 0.9 ? SIMD3<Float>(0, 1, 0) : SIMD3<Float>(1, 0, 0)
            let orbitBasisU = simd_normalize(simd_cross(hintVector, planeNormal))
            let orbitBasisV = simd_cross(planeNormal, orbitBasisU)
            let orbitPhase = _colorAnimTime * effect.orbitSpeed * twoPi
            offset += (orbitBasisU * cos(orbitPhase) + orbitBasisV * sin(orbitPhase)) * (amplitude * orbitMix)
        }

        return basePosition + offset
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
    
    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Smoothing Pipeline (Target → Current → Snapshot → GPU)
    // ═══════════════════════════════════════════════════════════════════════════
    //
    // ARCHITECTURE: Unified smoothing for gesture, music, and animation streams.
    //
    //   ┌─────────────┐   ┌─────────────┐   ┌─────────────┐
    //   │   Gesture    │   │    Music     │   │  Animation  │
    //   │ Controller   │   │  Renderer   │   │   Manager   │
    //   └──────┬───────┘   └──────┬───────┘   └──────┬───────┘
    //          │                   │                   │
    //          ▼                   ▼                   ▼
    //   ParameterOperation  ParameterOperation  Direct write
    //          │                   │            to current values
    //          ▼                   ▼                   │
    //   ┌──────────────────────────────┐               │
    //   │     ParameterLayerStack      │               │
    //   │  (priority + exp lerp)       │               │
    //   │  Geometry: bypass lerp (→0)  │               │
    //   │  Effects:  apply lerp        │               │
    //   └──────────────┬───────────────┘               │
    //                  │                               │
    //                  ▼                               │
    //          _target* properties ◄────────────────────┘
    //                  │
    //                  ▼
    //   ┌──────────────────────────┐
    //   │   interpolateToTargets() │  ← called every frame @90Hz
    //   │   smoothDamp (crit.      │
    //   │   damped spring)         │
    //   └──────────────┬───────────┘
    //                  │
    //                  ▼
    //          _current values
    //                  │
    //                  ▼
    //           snapshot() → GPU
    //
    // Key design decisions:
    //  • Geometry params (minDist, fold, sphere, scale, position) use smoothDamp
    //    for critically-damped spring physics — the smoothest possible motion.
    //  • Effect params (glow, fog, bloom, hue, saturation) use LayerStack's
    //    exponential lerp directly — adequate for non-positional values.
    //  • Mandelbox bridge: formulaParams[0-2] → _target{MinDist,Fold,Sphere}
    //    because the shader reads dedicated uniform fields, not formulaParams.
    //  • Animation offset decay: when animation plays, gesture perturbations
    //    exponentially decay to zero so animation reasserts as source of truth.
    // ═══════════════════════════════════════════════════════════════════════════
    
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

    var animationActivityFactor: Float {
        get { withLock { _animationActivityFactor } }
    }

    func beginAnimationKillSwitch(duration: TimeInterval) {
        let clampedDuration = max(Float(duration), 0.01)
        withLock {
            _animationKillSwitchDuration = clampedDuration
            _animationKillSwitchRemaining = clampedDuration
            _animationActivityFactor = 1.0
            _animationKillSwitchActive = true
        }
    }

    func cancelAnimationKillSwitch() {
        withLock {
            _animationKillSwitchActive = false
            _animationKillSwitchRemaining = 0.0
            _animationKillSwitchDuration = 0.7
            _animationActivityFactor = 1.0
        }
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

    var animationBaseWorldRotation: simd_quatf {
        get { withLock { _animationBaseWorldRotation } }
        set { withLock { _animationBaseWorldRotation = newValue } }
    }

    var animationBaseDetailScale: Float {
        get { withLock { _animationBaseDetailScale } }
        set { withLock { _animationBaseDetailScale = newValue } }
    }

    var animationBaseGlowIntensity: Float {
        get { withLock { _animationBaseGlowIntensity } }
        set { withLock { _animationBaseGlowIntensity = newValue } }
    }

    var animationBaseBloomStrength: Float {
        get { withLock { _animationBaseBloomStrength } }
        set { withLock { _animationBaseBloomStrength = newValue } }
    }

    var animationBaseFogIntensity: Float {
        get { withLock { _animationBaseFogIntensity } }
        set { withLock { _animationBaseFogIntensity = newValue } }
    }

    var animationBaseSaturation: Float {
        get { withLock { _animationBaseSaturation } }
        set { withLock { _animationBaseSaturation = newValue } }
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

    /// Gesture override of rotation during animation, as a delta quaternion composed
    /// onto the scene's animated base: effective = manualRotationOffset * animationBaseWorldRotation.
    /// identity == no override.
    var manualRotationOffset: simd_quatf {
        get { withLock { _manualRotationOffset } }
        set { withLock { _manualRotationOffset = newValue.normalized } }
    }

    /// Gesture override of zoom during animation, added to the scene's animated base:
    /// effective = animationBaseDetailScale + manualOffsetDetailScale. 0 == no override.
    var manualOffsetDetailScale: Float {
        get { withLock { _manualOffsetDetailScale } }
        set { withLock { _manualOffsetDetailScale = newValue } }
    }

    var manualOffsetGlowIntensity: Float {
        get { withLock { _manualOffsetGlowIntensity } }
        set { withLock { _manualOffsetGlowIntensity = newValue } }
    }

    var manualOffsetBloomStrength: Float {
        get { withLock { _manualOffsetBloomStrength } }
        set { withLock { _manualOffsetBloomStrength = newValue } }
    }

    var manualOffsetFogIntensity: Float {
        get { withLock { _manualOffsetFogIntensity } }
        set { withLock { _manualOffsetFogIntensity = newValue } }
    }

    var manualOffsetSaturation: Float {
        get { withLock { _manualOffsetSaturation } }
        set { withLock { _manualOffsetSaturation = newValue } }
    }

    // === ANIMATION AUDIO (MUSIC) OFFSET ACCESSORS ===
    // Set by the parameter dispatcher (music delta) while playing; read by applyKeyframe
    // when it composes the live value on top of the animation base.
    var animationBaseHueSpeed: Float {
        get { withLock { _animationBaseHueSpeed } }
        set { withLock { _animationBaseHueSpeed = newValue } }
    }
    var audioOffsetMinDistance: Float {
        get { withLock { _audioOffsetMinDistance } }
        set { withLock { _audioOffsetMinDistance = newValue } }
    }
    var audioOffsetFoldingLimit: Float {
        get { withLock { _audioOffsetFoldingLimit } }
        set { withLock { _audioOffsetFoldingLimit = newValue } }
    }
    var audioOffsetSphereRadius: Float {
        get { withLock { _audioOffsetSphereRadius } }
        set { withLock { _audioOffsetSphereRadius = newValue } }
    }
    var audioOffsetFractalScale: Float {
        get { withLock { _audioOffsetFractalScale } }
        set { withLock { _audioOffsetFractalScale = newValue } }
    }
    var audioOffsetGlowIntensity: Float {
        get { withLock { _audioOffsetGlowIntensity } }
        set { withLock { _audioOffsetGlowIntensity = newValue } }
    }
    var audioOffsetBloomStrength: Float {
        get { withLock { _audioOffsetBloomStrength } }
        set { withLock { _audioOffsetBloomStrength = newValue } }
    }
    var audioOffsetFogIntensity: Float {
        get { withLock { _audioOffsetFogIntensity } }
        set { withLock { _audioOffsetFogIntensity = newValue } }
    }
    var audioOffsetSaturation: Float {
        get { withLock { _audioOffsetSaturation } }
        set { withLock { _audioOffsetSaturation = newValue } }
    }
    var audioOffsetHueSpeed: Float {
        get { withLock { _audioOffsetHueSpeed } }
        set { withLock { _audioOffsetHueSpeed = newValue } }
    }
    // Scene-drives flags (set by applyKeyframe each frame; read by the dispatcher).
    var sceneDrivesGlow: Bool {
        get { withLock { _sceneDrivesGlow } }
        set { withLock { _sceneDrivesGlow = newValue } }
    }
    var sceneDrivesBloom: Bool {
        get { withLock { _sceneDrivesBloom } }
        set { withLock { _sceneDrivesBloom = newValue } }
    }
    var sceneDrivesFog: Bool {
        get { withLock { _sceneDrivesFog } }
        set { withLock { _sceneDrivesFog = newValue } }
    }
    var sceneDrivesSaturation: Bool {
        get { withLock { _sceneDrivesSaturation } }
        set { withLock { _sceneDrivesSaturation = newValue } }
    }
    var sceneDrivesHueSpeed: Bool {
        get { withLock { _sceneDrivesHueSpeed } }
        set { withLock { _sceneDrivesHueSpeed = newValue } }
    }

    /// Store the per-frame music delta for a formula param while a scene animates, so the
    /// rebuild composes it on top of the animation base instead of the dispatcher's
    /// absolute write (which the rebuild would stomp). For mandelbox the shape params are
    /// read from dedicated uniforms, so also mirror the offset into those.
    func setAudioFormulaParamOffset(index: Int, offset: Float) {
        withLock {
            guard index >= 0 && index < 16 else { return }
            _audioOffsetFormulaParams[index] = offset
            _syncMandelboxAudioShapeOffset_locked(index: index, offset: offset)
            _rebuildFormulaParamsFromAnimationState_locked()
        }
    }

    /// Zero every audio-modulation offset (e.g. music disabled, or playback stops). Cheap
    /// no-lock-reentrancy variant for callers already inside `withLock` is below.
    func clearAudioPlaybackOffsets() {
        withLock { _clearAudioPlaybackOffsets_locked() }
    }

    private func _clearAudioPlaybackOffsets_locked() {
        _audioOffsetMinDistance = 0.0
        _audioOffsetFoldingLimit = 0.0
        _audioOffsetSphereRadius = 0.0
        _audioOffsetFractalScale = 0.0
        _audioOffsetGlowIntensity = 0.0
        _audioOffsetBloomStrength = 0.0
        _audioOffsetFogIntensity = 0.0
        _audioOffsetSaturation = 0.0
        _audioOffsetHueSpeed = 0.0
        for index in 0..<16 { _audioOffsetFormulaParams[index] = 0.0 }
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

    func setAnimationBaseFormulaParams(_ values: [Float]) {
        withLock {
            for index in 0..<16 {
                let current = FormulaCatalog.getParam(_formulaParams, index: index)
                let next = index < values.count ? values[index] : current
                _animationBaseFormulaParams[index] = _clampFormulaParamValue_locked(next, index: index)
            }
            _rebuildFormulaParamsFromAnimationState_locked()
        }
    }

    func setManualFormulaParamOverride(index: Int, value: Float) {
        withLock {
            guard index >= 0 && index < 16 else { return }
            let clamped = _clampFormulaParamValue_locked(value, index: index)

            if _isAnimationPlaying {
                _manualOffsetFormulaParams[index] = clamped - _animationBaseFormulaParams[index]
                _syncMandelboxAnimationShapeOffset_locked(index: index, value: clamped)
                _rebuildFormulaParamsFromAnimationState_locked()
            } else {
                FormulaCatalog.setParam(&_formulaParams, index: index, value: clamped)
                _syncAnimationBaseFormulaParamsFromCurrent_locked()
            }
        }
    }

    func setManualFormulaParamOverrides(_ values: [Float]) {
        withLock {
            for index in 0..<16 {
                let current = FormulaCatalog.getParam(_formulaParams, index: index)
                let next = index < values.count ? values[index] : current
                let clamped = _clampFormulaParamValue_locked(next, index: index)
                _manualOffsetFormulaParams[index] = clamped - _animationBaseFormulaParams[index]
                _syncMandelboxAnimationShapeOffset_locked(index: index, value: clamped)
            }
            _rebuildFormulaParamsFromAnimationState_locked()
        }
    }

    private func _syncAnimationBaseFormulaParamsFromCurrent_locked() {
        for index in 0..<16 {
            _animationBaseFormulaParams[index] = FormulaCatalog.getParam(_formulaParams, index: index)
        }
    }

    private func _rebuildFormulaParamsFromAnimationState_locked() {
        guard _isAnimationPlaying else { return }

        var params = _formulaParams
        for index in 0..<16 {
            let resolved = _clampFormulaParamValue_locked(
                _animationBaseFormulaParams[index] + _manualOffsetFormulaParams[index] + _audioOffsetFormulaParams[index],
                index: index
            )
            FormulaCatalog.setParam(&params, index: index, value: resolved)
        }
        _formulaParams = params
    }

    private func _syncMandelboxAnimationShapeOffset_locked(index: Int, value: Float) {
        guard _fractalType == .mandelbox else { return }

        switch index {
        case 0:
            _manualOffsetMinDistance = value - _animationBaseMinDistance
        case 1:
            _manualOffsetFoldingLimit = value - _animationBaseFoldingLimit
        case 2:
            _manualOffsetSphereRadius = value - _animationBaseSphereRadius
        default:
            break
        }
    }

    /// Mandelbox reads minDistance/foldingLimit/sphereRadius from dedicated uniforms (not
    /// formulaParams), so mirror the music offset (already a pure delta from the dispatcher)
    /// into the matching dedicated-shape audio offset that applyKeyframe composes.
    private func _syncMandelboxAudioShapeOffset_locked(index: Int, offset: Float) {
        guard _fractalType == .mandelbox else { return }

        switch index {
        case 0:
            _audioOffsetMinDistance = offset
        case 1:
            _audioOffsetFoldingLimit = offset
        case 2:
            _audioOffsetSphereRadius = offset
        default:
            break
        }
    }

    private func _clampFormulaParamValue_locked(_ value: Float, index: Int) -> Float {
        guard let descriptor = FormulaCatalog.shared.descriptor(for: _fractalType),
              let param = descriptor.params.first(where: { $0.index == index }) else {
            return value
        }

        if param.isBool == true {
            return value >= 0.5 ? 1.0 : 0.0
        }

        return min(param.max, max(param.min, value))
    }
    
    // === SMOOTH DAMP PARAMETERS ===
    // Critically-damped spring with velocity/acceleration limits for buttery smooth motion
    
    /// Smooth time - how long (in seconds) to reach the target. Higher = smoother but more latency.
    /// Fixed at the gesture-smoothing default (no longer user-adjustable).
    private var smoothTime: Float { GestureDefaults.gestureSmoothing }

    /// Maximum speed the parameter can travel (units per second). Prevents jarring fast motion.
    private let maxSpeed: Float = 8.0
    
    /// Maximum speed for position (meters per second) - higher to allow responsive flicking
    private let maxPositionSpeed: Float = 12.0

    // ═══════════════════════════════════════════════════════════════════════════
    // SCENE TRANSITION ("Same Scene Transition Time")
    // One-shot eased blend of the displayed parameters toward a newly loaded
    // scene/preset's values. A preset normally snaps the displayed values to the
    // new target instantly; arming a transition restores the pre-switch values
    // and eases them toward the new target over `_sceneTransitionDuration`,
    // overriding the default smoothing time and speed caps for that window.
    // ═══════════════════════════════════════════════════════════════════════════

    /// Configured transition time in seconds (slider-driven). `0` = instant.
    private var _sceneTransitionDuration: Float = 0
    /// Snapshot taken before a preset load is applied.
    private var _sceneTransitionArmed = false
    /// Whether an eased transition is currently in progress.
    private var _sceneTransitionActive = false
    private var _sceneTransitionElapsed: Float = 0
    private var _stMinDistance: Float = 0
    private var _stFoldingLimit: Float = 0
    private var _stSphereRadius: Float = 0
    private var _stFractalScale: Float = 0
    private var _stPosition = SIMD3<Float>(repeating: 0)
    private var _stWorldRotation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    private var _stDetailScale: Float = 1
    private var _sceneLoadGeneration: UInt64 = 0
    /// Targets whose music "center of variation" the user just reset manually
    /// (slider/gesture). Drained by the music-reactive engine each frame. Only
    /// populated while audio reactivity is enabled, so the set stays bounded.
    private var _musicRecenterRequests: Set<String> = []

    /// Configured "Same Scene Transition Time" in seconds. Clamped to 0...10.
    var sceneTransitionDuration: Float {
        get { withLock { _sceneTransitionDuration } }
        set { withLock { _sceneTransitionDuration = max(0, min(10, newValue)) } }
    }

    /// Monotonic counter bumped each time a scene/preset load is committed.
    /// Lets per-renderer systems (e.g. the music-reactive engine) detect a
    /// preset load and reset accumulated state like drift offsets.
    var sceneLoadGeneration: UInt64 {
        withLock { _sceneLoadGeneration }
    }

    /// Record that the user manually changed `targetID` (slider/gesture) so the
    /// music-reactive engine re-zeros that target's accumulated drift/decay/phase
    /// and audio variation restarts around the fresh value. Guarded on the
    /// audio-reactive flag so non-reactive sessions don't accumulate entries.
    func requestMusicRecenter(targetID: String) {
        withLock {
            guard _fractalAudioReactiveEnabled else { return }
            _musicRecenterRequests.insert(targetID)
        }
    }

    /// Atomically read and clear the pending music-recenter requests.
    func drainMusicRecenterRequests() -> Set<String> {
        withLock {
            guard !_musicRecenterRequests.isEmpty else { return [] }
            let drained = _musicRecenterRequests
            _musicRecenterRequests.removeAll(keepingCapacity: true)
            return drained
        }
    }

    /// Snapshot the currently displayed transform/shape parameters before a new
    /// scene/preset is applied. Pair with `commitSceneTransition()`.
    func beginSceneTransitionSnapshot() {
        withLock {
            _stMinDistance = _minDistance
            _stFoldingLimit = _foldingLimit
            _stSphereRadius = _sphereRadius
            _stFractalScale = _fractalScale
            _stPosition = _position
            _stWorldRotation = _worldRotation
            _stDetailScale = _detailScale
            _sceneTransitionArmed = true
        }
    }

    /// Begin easing from the snapshot toward the freshly applied targets. The
    /// preset load already set both current and target to the new values, so we
    /// restore current to the snapshot and let `interpolateToTargets` ease back.
    func commitSceneTransition() {
        withLock {
            guard _sceneTransitionArmed else { return }
            _sceneTransitionArmed = false
            // A preset/scene load completed, whether or not the visual ease runs.
            _sceneLoadGeneration &+= 1

            // Skip when disabled or while the keyframe animation system owns the
            // displayed values (it drives them directly, bypassing this path).
            guard _sceneTransitionDuration > 0, !_isAnimationPlaying else {
                _sceneTransitionActive = false
                return
            }

            _minDistance = _stMinDistance
            _foldingLimit = _stFoldingLimit
            _sphereRadius = _stSphereRadius
            _fractalScale = _stFractalScale
            _position = _stPosition
            _worldRotation = _stWorldRotation
            _detailScale = _stDetailScale

            _velocityMinDistance = 0
            _velocityFoldingLimit = 0
            _velocitySphereRadius = 0
            _velocityFractalScale = 0
            _velocityPosition = .zero

            _sceneTransitionActive = true
            _sceneTransitionElapsed = 0
        }
    }
    
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
        withLock { _interpolateToTargets_locked(deltaTime: deltaTime) }
    }

    private func _interpolateToTargets_locked(deltaTime: Float) {
            // Guard against bad deltaTime values that could cause instability
            let clampedDT = max(0.001, min(0.1, deltaTime))  // 10ms to 100ms range

            // ═══════════════════════════════════════════════════════════════════════════
            // INFINITE ZOOM — continuous multiplicative descent on the zoom channel.
            // Advances the detailScale *target*; the smoothing below (exp-lerp when
            // settling, snap-to-target when converged) eases the live value toward it,
            // giving a steady seamless dive. Honors the animation kill-switch via
            // _animationActivityFactor (so the music fade / stop gestures damp it for
            // free) and is bounded to an fp32-safe band (Phase 2 octave-rebase removes
            // the ceiling). Skipped while a scene animates detailScale directly
            // (applyKeyframe owns the channel then) to avoid a per-frame fight.
            // ═══════════════════════════════════════════════════════════════════════════
            if _infiniteZoomEnabled && !_isAnimationPlaying && _animationActivityFactor > 0.0001 {
                let step = exp(_infiniteZoomRate * clampedDT * _animationActivityFactor)
                _targetDetailScale = max(Self.infiniteZoomMinScale,
                                         min(Self.infiniteZoomMaxScale, _targetDetailScale * step))
            }

            // Scene-transition override: ease toward the new target over the
            // configured duration instead of the default snappy smoothing.
            let stActive = _sceneTransitionActive
            // smoothDamp reaches ~95% of the distance in ~2× its smoothTime, so
            // halve the requested duration to make the perceived settle time match.
            let effSmoothTime = stActive ? max(0.05, _sceneTransitionDuration * 0.5) : smoothTime
            let effMaxSpeed = stActive ? Float(1e9) : maxSpeed
            let effMaxPositionSpeed = stActive ? Float(1e9) : maxPositionSpeed
            // Rotation/scale (grab) smoothing tracks gesture-smoothing but is clamped to
            // a minimum rate so direct-manipulation grab never feels frozen at high smoothing.
            let minGrabRate: Float = 10.0  // floor on the exponential rate (≈0.1s settle)
            let rotRate: Float = stActive ? (2.0 / effSmoothTime) : max(2.0 / max(effSmoothTime, 0.001), minGrabRate)
            if stActive {
                _sceneTransitionElapsed += clampedDT
                // Safety timeout so the override always releases.
                if _sceneTransitionElapsed >= max(0.1, _sceneTransitionDuration) * 2.0 {
                    _sceneTransitionActive = false
                }
            }
            
            // ═══════════════════════════════════════════════════════════════════════════
            // ANIMATION OFFSET DECAY: When animation is playing and no gesture is
            // active, tween manual offsets back to zero so the animation reasserts
            // as the source of truth. This prevents "sticky" gesture perturbations
            // that cause flickering when the user stops touching.
            // ═══════════════════════════════════════════════════════════════════════════
            if _isAnimationPlaying && !_isGeometryGestureActive && !_isMenuInteractionActive {
                let decayRate: Float = 1.0 - exp(-6.0 * clampedDT)  // ~6Hz half-life
                _manualOffsetMinDistance   *= (1.0 - decayRate)
                _manualOffsetFoldingLimit  *= (1.0 - decayRate)
                _manualOffsetSphereRadius  *= (1.0 - decayRate)
                _manualOffsetFractalScale  *= (1.0 - decayRate)
                _manualOffsetPosition      *= (1.0 - decayRate)
                _manualOffsetGlowIntensity *= (1.0 - decayRate)
                _manualOffsetBloomStrength *= (1.0 - decayRate)
                _manualOffsetFogIntensity  *= (1.0 - decayRate)
                _manualOffsetSaturation    *= (1.0 - decayRate)
                _manualOffsetDetailScale   *= (1.0 - decayRate)
                // Rotation override is a quaternion: ease it back toward identity via slerp.
                _manualRotationOffset = simd_slerp(_manualRotationOffset, simd_quatf(ix: 0, iy: 0, iz: 0, r: 1), decayRate)
                for index in 0..<16 {
                    _manualOffsetFormulaParams[index] *= (1.0 - decayRate)
                    if abs(_manualOffsetFormulaParams[index]) < 1e-5 {
                        _manualOffsetFormulaParams[index] = 0
                    }
                }
                // Snap to zero when negligible to avoid micro-drift
                if abs(_manualOffsetMinDistance)  < 1e-5 { _manualOffsetMinDistance = 0 }
                if abs(_manualOffsetFoldingLimit) < 1e-5 { _manualOffsetFoldingLimit = 0 }
                if abs(_manualOffsetSphereRadius) < 1e-5 { _manualOffsetSphereRadius = 0 }
                if abs(_manualOffsetFractalScale) < 1e-5 { _manualOffsetFractalScale = 0 }
                if simd_length_squared(_manualOffsetPosition) < 1e-10 { _manualOffsetPosition = .zero }
                if abs(_manualOffsetGlowIntensity) < 1e-5 { _manualOffsetGlowIntensity = 0 }
                if abs(_manualOffsetBloomStrength) < 1e-5 { _manualOffsetBloomStrength = 0 }
                if abs(_manualOffsetFogIntensity) < 1e-5 { _manualOffsetFogIntensity = 0 }
                if abs(_manualOffsetSaturation) < 1e-5 { _manualOffsetSaturation = 0 }
                if abs(_manualOffsetDetailScale) < 1e-5 { _manualOffsetDetailScale = 0 }
                // Snap the rotation override to identity once its angle is negligible.
                if abs(_manualRotationOffset.real) > 0.999999 { _manualRotationOffset = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1) }
                _rebuildFormulaParamsFromAnimationState_locked()
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
                // Transition (if any) has settled — release the override.
                _sceneTransitionActive = false
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
                // Step multiplier stays high when converged (already settled).
                // The march loops now run Keinert overstep-failure detection, so
                // over-relaxation is hit-identical to 1.0 — 1.4 is safe everywhere.
                let targetStepMultiplier: Float = _overRelaxationMax
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
                smoothTime: effSmoothTime,
                maxSpeed: effMaxSpeed,
                deltaTime: clampedDT
            )
            
            _foldingLimit = smoothDamp(
                current: _foldingLimit,
                target: _targetFoldingLimit,
                velocity: &_velocityFoldingLimit,
                smoothTime: effSmoothTime,
                maxSpeed: effMaxSpeed,
                deltaTime: clampedDT
            )
            
            _sphereRadius = smoothDamp(
                current: _sphereRadius,
                target: _targetSphereRadius,
                velocity: &_velocitySphereRadius,
                smoothTime: effSmoothTime,
                maxSpeed: effMaxSpeed,
                deltaTime: clampedDT
            )
            
            _fractalScale = smoothDamp(
                current: _fractalScale,
                target: _targetFractalScale,
                velocity: &_velocityFractalScale,
                smoothTime: effSmoothTime,
                maxSpeed: effMaxSpeed,
                deltaTime: clampedDT
            )
            
            // Smooth damp position (each component separately)
            _position.x = smoothDamp(
                current: _position.x,
                target: _targetPosition.x,
                velocity: &_velocityPosition.x,
                smoothTime: effSmoothTime,
                maxSpeed: effMaxPositionSpeed,
                deltaTime: clampedDT
            )
            _position.y = smoothDamp(
                current: _position.y,
                target: _targetPosition.y,
                velocity: &_velocityPosition.y,
                smoothTime: effSmoothTime,
                maxSpeed: effMaxPositionSpeed,
                deltaTime: clampedDT
            )
            _position.z = smoothDamp(
                current: _position.z,
                target: _targetPosition.z,
                velocity: &_velocityPosition.z,
                smoothTime: effSmoothTime,
                maxSpeed: effMaxPositionSpeed,
                deltaTime: clampedDT
            )
            
            // Smooth interpolation for world rotation (slerp) and grab scale (exp lerp)
            let rotLerpT = 1.0 - exp(-rotRate * clampedDT)  // Same speed as main smoothing
            _worldRotation = simd_slerp(_worldRotation, _targetWorldRotation, rotLerpT)
            // Re-normalize only when drift exceeds threshold (saves sqrt per frame)
            let rotLenSq = simd_length_squared(_worldRotation.vector)
            if abs(rotLenSq - 1.0) > 1e-4 {
                _worldRotation = _worldRotation.normalized
            }
            
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
            _fractalScale = ControlCatalog.fractalScale.clamp(_fractalScale)
            
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
            // - Parameters changing: 1.2
            // - Parameters settled: 1.4
            // The march loops run Keinert overstep-failure detection (retreat +
            // conservative fallback when unbounding spheres stop overlapping), so
            // over-relaxation can never skip a surface that 1.0 would hit — the
            // multiplier is purely a speed knob now, safe even during interaction.
            // Uses allGeometrySettled directly instead of _isGeometryGestureActive,
            // which may not be wired to all gesture sources.
            // ═══════════════════════════════════════════════════════════════════════════
            let targetStepMultiplier: Float = allGeometrySettled ? _overRelaxationMax
                                                                  : max(1.0, _overRelaxationMax - 0.2)
            // Smooth transition to avoid popping
            _stepMultiplier += (targetStepMultiplier - _stepMultiplier) * 0.1
            
            } // end convergence lock else
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
            // Bake the live (already overridden) rotation/zoom into the targets so the
            // grab override survives when playback stops, then clear the overrides.
            _targetWorldRotation = _worldRotation
            _targetDetailScale = _detailScale
            _animationBaseWorldRotation = _worldRotation
            _animationBaseDetailScale = _detailScale
            _manualRotationOffset = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
            _manualOffsetDetailScale = 0.0
            _manualOffsetMinDistance = 0.0
            _manualOffsetFoldingLimit = 0.0
            _manualOffsetSphereRadius = 0.0
            _manualOffsetFractalScale = 0.0
            _manualOffsetPosition = .zero
            _manualOffsetGlowIntensity = 0.0
            _manualOffsetBloomStrength = 0.0
            _manualOffsetFogIntensity = 0.0
            _manualOffsetSaturation = 0.0
            _manualOffsetFormulaParams = Array(repeating: 0.0, count: 16)
            // Drop any leftover music modulation so it doesn't bake a frozen offset into
            // the baked targets; the dispatcher re-centers music around the user value
            // once playback stops.
            _clearAudioPlaybackOffsets_locked()
            _sceneDrivesGlow = false
            _sceneDrivesBloom = false
            _sceneDrivesFog = false
            _sceneDrivesSaturation = false
            _sceneDrivesHueSpeed = false
            _syncAnimationBaseFormulaParamsFromCurrent_locked()
            // Zero spring velocities so interpolation doesn't overshoot
            _velocityMinDistance = 0.0
            _velocityFoldingLimit = 0.0
            _velocitySphereRadius = 0.0
            _velocityFractalScale = 0.0
            _velocityPosition = .zero
        }
    }

    /// Clear gesture/user offsets that are applied on top of animation base values.
    /// Used by animation playback reset so scene-driven values fully take over.
    func clearAnimationManualOffsets() {
        withLock {
            _manualOffsetMinDistance = 0.0
            _manualOffsetFoldingLimit = 0.0
            _manualOffsetSphereRadius = 0.0
            _manualOffsetFractalScale = 0.0
            _manualOffsetPosition = .zero
            _manualOffsetGlowIntensity = 0.0
            _manualOffsetBloomStrength = 0.0
            _manualOffsetFogIntensity = 0.0
            _manualOffsetSaturation = 0.0
            _manualRotationOffset = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
            _manualOffsetDetailScale = 0.0
            _manualOffsetFormulaParams = Array(repeating: 0.0, count: 16)
            _rebuildFormulaParamsFromAnimationState_locked()
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
        withLock { _applyDetailState_locked(position: position, worldRotation: worldRotation, detailScale: detailScale, responsiveness: responsiveness) }
    }

    private func _applyDetailState_locked(position: SIMD3<Float>, worldRotation: simd_quatf, detailScale: Float, responsiveness: Float) {
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
            let keyRotLenSq = simd_length_squared(_worldRotation.vector)
            if abs(keyRotLenSq - 1.0) > 1e-4 {
                _worldRotation = _worldRotation.normalized
            }
            _targetWorldRotation = _worldRotation
            
            // Scale: exponential lerp (so doubling and halving feel symmetric)
            let logCurrent = log(max(_detailScale, 1e-6))
            let logTarget = log(max(detailScale, 1e-6))
            _detailScale = exp(logCurrent + (logTarget - logCurrent) * t)
            _targetDetailScale = _detailScale
    }
    
    /// Reset detail transform to identity (worldRotation = identity, detailScale = 1)
    func resetDetailTransform() {
        withLock {
            let identity = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
            _worldRotation = identity
            _targetWorldRotation = identity
            _detailScale = 1.0
            _targetDetailScale = 1.0
            // Also clear the animation override so a stale grab rotation/zoom can't
            // re-apply on the next applyKeyframe during playback (the "Detail" reset
            // button calls this directly without going through clearAnimationManualOffsets).
            _animationBaseWorldRotation = identity
            _manualRotationOffset = identity
            _animationBaseDetailScale = 1.0
            _manualOffsetDetailScale = 0.0
        }
    }

    // (Rotation auto-snap removed — grab rotation now engages immediately with no snap-on-release.)


    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Domain-Level Persistence Helpers
    // Replace 30+ scattered UserDefaults.standard.set(...) calls with
    // one persist call per domain. Each saves the entire config struct as JSON.
    // ═══════════════════════════════════════════════════════════════════════════

    /// Persist the audio-reactive config (throttled — continuous sliders may fire rapidly).
    private func persistAudioReactive() {
        guard SettingsPersistence.shouldSave(domain: .audioReactive) else { return }
        SettingsPersistence.save(audioReactiveConfig, domain: .audioReactive)
    }

    /// Persist the gesture config (called after binding/threshold/sensitivity changes).
    private func persistGesture() {
        guard SettingsPersistence.shouldSave(domain: .gesture) else { return }
        SettingsPersistence.save(gestureConfig, domain: .gesture)
    }

    /// Persist the display config (called after HUD/music shortcut changes).
    private func persistDisplay() {
        SettingsPersistence.save(displayConfig, domain: .display)
    }

    /// Persist the color config (throttled — sliders/gradients may fire at 90fps).
    private func persistColor() {
        guard SettingsPersistence.shouldSave(domain: .color) else { return }
        SettingsPersistence.save(colorConfig, domain: .color)
    }

    /// Benchmark-harness only: pin every CPU-side animation accumulator to a fixed
    /// value so a PNG regression capture is phase-deterministic across runs (the
    /// phases integrate ∫speed·dt, so they otherwise land at run-dependent values
    /// and two identical builds diff as "different"). Never called in normal use.
    func benchFreezeAnimationPhases() {
        withLock {
            _colorAnimTime = 5.0
            _lightAnimTime = 5.0
            _huePhase = 1.0
            _pulsePhase = 1.0
            _fogHuePhase = 1.0
            _gradientPhase = 0.25
            _polarRotationAccum = 0.0
            _juliaDriftAccum = 0.0
            _colorSchemeAutoTimer = 0.0
            // Stop the auto color-scheme cycler and finish any in-flight
            // transition: the cycler advances on a wall-clock interval, which
            // lands at run-dependent points → a capture mid-lerp (or one cycle
            // ahead) diffs as "different" between identical builds. Disabling is
            // transient — backing var only, never persisted.
            _colorSchemeAutoTransition = false
            _colorScheme = _targetColorScheme
            _colorSchemeTransitionProgress = 1.0
        }
    }

    /// Persist the quality config (throttled — foveation slider may fire rapidly).
    private func persistQuality() {
        guard SettingsPersistence.shouldSave(domain: .quality) else { return }
        SettingsPersistence.save(qualityConfig, domain: .quality)
    }

    /// Persist the lighting config (throttled — effect intensity sliders may fire rapidly).
    private func persistLighting() {
        guard SettingsPersistence.shouldSave(domain: .lighting) else { return }
        SettingsPersistence.save(lightingConfig, domain: .lighting)
    }

    /// Persist the safety bubble config (throttled — radius/shape sliders).
    private func persistSafetyBubble() {
        guard SettingsPersistence.shouldSave(domain: .safetyBubble) else { return }
        SettingsPersistence.save(safetyBubbleConfig, domain: .safetyBubble)
    }

    /// Persist the hand attraction config (throttled — radius/strength sliders).
    private func persistHandAttraction() {
        guard SettingsPersistence.shouldSave(domain: .handAttraction) else { return }
        SettingsPersistence.save(handAttractionConfig, domain: .handAttraction)
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Domain Config Struct Accessors
    // Snapshot current state into focused config structs (get) or apply a
    // config struct back to the underlying fields (set).
    // These are the foundation for eliminating UISettingsCache, auto-deriving
    // preset serialization, and composable SwiftUI views.
    // ═══════════════════════════════════════════════════════════════════════════

    var geometryConfig: GeometryConfig {
        get {
            withLock {
                var c = GeometryConfig()
                c.fractalType = _fractalType
                c.formulaParams = _formulaParams
                c.minDistance = _minDistance
                c.fractalScale = _fractalScale
                c.foldingLimit = _foldingLimit
                c.sphereRadius = _sphereRadius
                c.position = _position
                c.scale = _scale
                c.worldRotation = _worldRotation
                c.detailScale = _detailScale
                return c
            }
        }
        set {
            withLock {
                _fractalType = newValue.fractalType
                _formulaParams = newValue.formulaParams
                _minDistance = newValue.minDistance
                _fractalScale = newValue.fractalScale
                _foldingLimit = newValue.foldingLimit
                _sphereRadius = newValue.sphereRadius
                _position = newValue.position
                _scale = newValue.scale
                _worldRotation = newValue.worldRotation
                _detailScale = newValue.detailScale
            }
        }
    }

    var qualityConfig: QualityConfig {
        get {
            withLock {
                var c = QualityConfig()
                c.baseFractalIterations = _baseFractalIterations
                c.baseMaxRaySteps = _baseMaxRaySteps
                c.resolutionScale = _resolutionScale
                c.renderQuality = _renderQuality
                c.tileSize = _tileSize
                c.debugHierarchical = _debugHierarchical
                c.coherentPacketEnabled = _coherentPacketEnabled
                c.computeTemporalReprojectionEnabled = _computeTemporalReprojectionEnabled
                c.coarsePrepassWarmStartEnabled = _coarsePrepassWarmStartEnabled
                c.foveationStrength = _foveationStrength
                c.smartAdvanceEnabled = _smartAdvanceEnabled
                c.adaptiveRenderQualityEnabled = _adaptiveRenderQualityEnabled
                c.coneMarchStrength = _coneMarchStrength
                c.overRelaxationMax = _overRelaxationMax
                c.distanceLODStrength = _distanceLODStrength
                c.shadowsEnabled = _shadowsEnabled
                c.boundingSphereSkipEnabled = _boundingSphereSkipEnabled
                c.boundingShapeRadius = _boundingShapeRadius
                c.boundingShapeFogMode = _boundingShapeFogMode
                c.boundingShapeShadowDepth = _boundingShapeShadowDepth
                c.boundingShapeType = _boundingShapeType
                c.zoomFogCompensationEnabled = _zoomFogCompensationEnabled
                return c
            }
        }
        set {
            // Activate the (previously dead) clamp() so a decoded/iCloud-restored
            // config can't bypass the property setters' clamps with out-of-band values.
            var newValue = newValue
            newValue.clamp()
            withLock {
                _baseFractalIterations = newValue.baseFractalIterations
                _fractalIterations = newValue.baseFractalIterations
                _baseMaxRaySteps = newValue.baseMaxRaySteps
                _maxRaySteps = newValue.baseMaxRaySteps
                _resolutionScale = ControlCatalog.resolutionScale.clamp(newValue.resolutionScale)
                _renderQuality = max(QualityConfig.visionMinRenderQuality, min(QualityConfig.visionMaxRenderQuality, newValue.renderQuality))
                _tileSize = newValue.tileSize
                _debugHierarchical = newValue.debugHierarchical
                _coherentPacketEnabled = newValue.coherentPacketEnabled
                _computeTemporalReprojectionEnabled = newValue.computeTemporalReprojectionEnabled
                _coarsePrepassWarmStartEnabled = newValue.coarsePrepassWarmStartEnabled
                _foveationStrength = newValue.foveationStrength
                _smartAdvanceEnabled = newValue.smartAdvanceEnabled
                _adaptiveRenderQualityEnabled = newValue.adaptiveRenderQualityEnabled
                _coneMarchStrength = max(0.0, min(1.0, newValue.coneMarchStrength))
                _overRelaxationMax = max(1.0, min(1.6, newValue.overRelaxationMax))
                _distanceLODStrength = max(0.0, min(1.0, newValue.distanceLODStrength))
                _shadowsEnabled = newValue.shadowsEnabled
                _boundingSphereSkipEnabled = newValue.boundingSphereSkipEnabled
                _boundingShapeRadius = max(0.05, min(30.0, newValue.boundingShapeRadius))
                _boundingShapeFogMode = newValue.boundingShapeFogMode
                _boundingShapeShadowDepth = newValue.boundingShapeShadowDepth
                _boundingShapeType = max(0.0, min(SafetyBubbleShapePreset.maxStoredValue, newValue.boundingShapeType))
                _zoomFogCompensationEnabled = newValue.zoomFogCompensationEnabled
            }
        }
    }

    var colorConfig: ColorConfig {
        get {
            withLock {
                var c = ColorConfig()
                c.colorScheme = _targetColorScheme
                c.gradientState = _gradientState
                c.colorMix = _colorMix
                c.colorIterations = _colorIterations
                c.colorSchemeSaturation = _colorSchemeSaturation
                c.colorSchemeContrast = _colorSchemeContrast
                c.colorSchemeGamma = _colorSchemeGamma
                c.colorSchemeVibrance = _colorSchemeVibrance
                c.colorSchemeCurve = _colorSchemeCurve
                c.colorSchemeShadows = _colorSchemeShadows
                c.colorSchemeHighlights = _colorSchemeHighlights
                c.lightingSoftness = _lightingSoftness
                c.cellShadingEnabled = _cellShadingEnabled
                c.cellShadingLevels = _cellShadingLevels
                c.aoStrength = _aoStrength
                c.tonemapStrength = _tonemapStrength
                c.colorSchemeAutoTransition = _colorSchemeAutoTransition
                c.colorSchemeAutoInterval = _colorSchemeAutoInterval
                c.colorSchemeTransitionDuration = _colorSchemeTransitionDuration
                return c
            }
        }
        set {
            // Activate the (previously dead) clamp() before restore (see qualityConfig).
            var newValue = newValue
            newValue.clamp()
            withLock {
                if _targetColorScheme != newValue.colorScheme {
                    _colorScheme = _targetColorScheme
                    _targetColorScheme = newValue.colorScheme
                    _colorSchemeTransitionProgress = 0.0
                }
                _gradientState = newValue.gradientState
                _colorMix = newValue.colorMix
                _colorIterations = ControlCatalog.colorIterations.clamp(newValue.colorIterations)
                _colorSchemeSaturation = newValue.colorSchemeSaturation
                _colorSchemeContrast = newValue.colorSchemeContrast
                _colorSchemeGamma = newValue.colorSchemeGamma
                _colorSchemeVibrance = newValue.colorSchemeVibrance
                _colorSchemeCurve = newValue.colorSchemeCurve
                _colorSchemeShadows = newValue.colorSchemeShadows
                _colorSchemeHighlights = newValue.colorSchemeHighlights
                _lightingSoftness = newValue.lightingSoftness
                _cellShadingEnabled = newValue.cellShadingEnabled
                _cellShadingLevels = ControlCatalog.cellShadingLevels.clamp(newValue.cellShadingLevels)
                _aoStrength = ControlCatalog.aoStrength.clamp(newValue.aoStrength)
                _tonemapStrength = ControlCatalog.tonemapStrength.clamp(newValue.tonemapStrength)
                _colorSchemeAutoTransition = newValue.colorSchemeAutoTransition
                _colorSchemeAutoInterval = newValue.colorSchemeAutoInterval
                _colorSchemeTransitionDuration = newValue.colorSchemeTransitionDuration
            }
        }
    }

    var lightingConfig: LightingConfig {
        get {
            withLock {
                var c = LightingConfig()
                c.lightingPreset = _lightingPreset
                c.lightVariationRate = _lightVariationRate
                c.hueRotationEffect = _hueRotationEffect
                c.pulseEffect = _pulseEffect
                c.glowEffect = _glowEffect
                c.bloomEffect = _bloomEffect
                c.fogEffect = _fogEffect
                c.gradientCycleEffect = _gradientCycleEffect
                c.linearRailEffect = _linearRailEffect
                c.beatFlashEffect = _beatFlashEffect
                c.polarRotationEffect = _polarRotationEffect
                c.juliaDriftEffect = _juliaDriftEffect
                return c
            }
        }
        set {
            withLock {
                _lightingPreset = newValue.lightingPreset
                _lightVariationRate = newValue.lightVariationRate
                _hueRotationEffect = newValue.hueRotationEffect
                _pulseEffect = newValue.pulseEffect
                _glowEffect = newValue.glowEffect
                _bloomEffect = newValue.bloomEffect
                _fogEffect = newValue.fogEffect
                _gradientCycleEffect = newValue.gradientCycleEffect
                _linearRailEffect = newValue.linearRailEffect
                _beatFlashEffect = newValue.beatFlashEffect
                _polarRotationEffect = newValue.polarRotationEffect
                _juliaDriftEffect = newValue.juliaDriftEffect
            }
        }
    }

    var audioReactiveConfig: AudioReactiveConfig {
        get {
            withLock {
                var c = AudioReactiveConfig()
                c.fractalAudioReactiveEnabled = _fractalAudioReactiveEnabled
                c.fractalAudioAmount = _fractalAudioAmount
                c.fractalBeatPunch = _fractalBeatPunch
                c.fractalAudioDamping = _fractalAudioDamping
                c.bassSensitivity = _bassSensitivity
                c.midSensitivity = _midSensitivity
                c.trebleSensitivity = _trebleSensitivity
                c.beatSensitivity = _beatSensitivity
                c.musicReactiveMappings = _musicReactiveMappings
                c.tripletMusicGains = _tripletMusicGains
                return c
            }
        }
        set {
            // Activate the (previously dead) clamp() before restore (see qualityConfig).
            var newValue = newValue
            newValue.clamp()
            withLock {
                _fractalAudioReactiveEnabled = newValue.fractalAudioReactiveEnabled
                _fractalAudioAmount = newValue.fractalAudioAmount
                _fractalBeatPunch = newValue.fractalBeatPunch
                _fractalAudioDamping = newValue.fractalAudioDamping
                _bassSensitivity = newValue.bassSensitivity
                _midSensitivity = newValue.midSensitivity
                _trebleSensitivity = newValue.trebleSensitivity
                _beatSensitivity = newValue.beatSensitivity
                _musicReactiveMappings = Self.sanitizeMusicReactiveMappings(newValue.musicReactiveMappings)
                _tripletMusicGains = newValue.tripletMusicGains
            }
        }
    }

    var gestureConfig: GestureConfig {
        get {
            withLock {
                var c = GestureConfig()
                c.gestureBindings = _gestureBindings
                c.useRelativeGestures = _useRelativeGestures
                c.menuToggleGestureEnabled = _menuToggleGestureEnabled
                c.menuToggleGestureMode = _menuToggleGestureMode
                c.perFingerTapGestureEnabled = _perFingerTapGestureEnabled
                c.perFingerTapLeftActions = _perFingerTapLeftActions
                c.perFingerTapRightActions = _perFingerTapRightActions
                c.perFingerTapActivateThreshold = _perFingerTapActivateThreshold
                c.perFingerTapReleaseThreshold = _perFingerTapReleaseThreshold
                c.perFingerTapHoldDuration = _perFingerTapHoldDuration
                c.perFingerTapCooldown = _perFingerTapCooldown
                return c
            }
        }
        set {
            // Activate the (previously dead) clamp() before restore (see qualityConfig).
            var newValue = newValue
            newValue.clamp()
            withLock {
                _gestureBindings = newValue.gestureBindings
                _useRelativeGestures = newValue.useRelativeGestures
                _menuToggleGestureEnabled = newValue.menuToggleGestureEnabled
                _menuToggleGestureMode = newValue.menuToggleGestureMode
                _perFingerTapGestureEnabled = newValue.perFingerTapGestureEnabled
                _perFingerTapLeftActions = newValue.perFingerTapLeftActions
                _perFingerTapRightActions = newValue.perFingerTapRightActions
                _perFingerTapActivateThreshold = newValue.perFingerTapActivateThreshold
                _perFingerTapReleaseThreshold = newValue.perFingerTapReleaseThreshold
                _perFingerTapHoldDuration = newValue.perFingerTapHoldDuration
                _perFingerTapCooldown = newValue.perFingerTapCooldown
            }
        }
    }

    var safetyBubbleConfig: SafetyBubbleConfig {
        get {
            withLock {
                var c = SafetyBubbleConfig()
                c.enabled = _safetyBubbleEnabled
                c.radius = _safetyBubbleRadius
                c.shape = _safetyBubbleShape
                c.fadeEnabled = _safetyBubbleFadeEnabled
                c.fadeWidth = _safetyBubbleFadeWidth
                c.strength = _safetyBubbleStrength
                return c
            }
        }
        set {
            // Activate the (previously dead) clamp() before restore (see qualityConfig).
            var newValue = newValue
            newValue.clamp()
            withLock {
                _safetyBubbleEnabled = newValue.enabled
                _safetyBubbleRadius = ControlCatalog.safetyBubbleRadius.clamp(newValue.radius)
                _safetyBubbleShape = newValue.shape
                _safetyBubbleFadeEnabled = newValue.fadeEnabled
                _safetyBubbleFadeWidth = newValue.fadeWidth
                _safetyBubbleStrength = newValue.strength
            }
        }
    }

    var handAttractionConfig: HandAttractionConfig {
        get {
            withLock {
                var c = HandAttractionConfig()
                c.enabled = _handAttractionEnabled
                c.radius = _handAttractionRadius
                c.strength = _handAttractionStrength
                return c
            }
        }
        set {
            var newValue = newValue
            newValue.clamp()
            withLock {
                _handAttractionEnabled = newValue.enabled
                _handAttractionRadius = newValue.radius
                _handAttractionStrength = newValue.strength
            }
        }
    }

    var displayConfig: DisplayConfig {
        get {
            withLock {
                var c = DisplayConfig()
                c.showMusicShortcuts = _showMusicShortcuts
                c.lightingPlay = _lightingPlay
                c.lightingMode = _lightingMode
                c.sphericalInversionMode = _sphericalInversionMode
                c.sphericalInversionRadius = _sphericalInversionRadius
                c.sphereProjectionEnabled = _sphereProjectionEnabled
                c.sphereProjectionBlend = _sphereProjectionBlend
                c.sphereProjectionRadius = _sphereProjectionRadius
                c.platformRadius = _platformRadius
                c.platformEnabled = _platformEnabled
                return c
            }
        }
        set {
            withLock {
                _showMusicShortcuts = newValue.showMusicShortcuts
                _lightingPlay = newValue.lightingPlay
                _lightingMode = newValue.lightingMode
                _sphericalInversionMode = newValue.sphericalInversionMode
                _sphericalInversionRadius = max(0.2, min(12.0, newValue.sphericalInversionRadius))
                _sphereProjectionEnabled = newValue.sphereProjectionEnabled
                _sphereProjectionBlend = max(0.0, min(1.0, newValue.sphereProjectionBlend))
                _sphereProjectionRadius = max(0.2, min(12.0, newValue.sphereProjectionRadius))
                _platformRadius = max(0.5, min(2.5, newValue.platformRadius))
                _platformEnabled = newValue.platformEnabled
            }
        }
    }

}
