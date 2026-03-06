//
//  LightingTypes.swift
//  Threshold
//
//  Modular lighting effects that can be toggled on/off independently.
//  Each effect is a card in the UI with its own settings.
//  Presets bundle effects together for quick looks.
//

import Foundation

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - Effect Tags (Fractal-Effect Association)
// ═══════════════════════════════════════════════════════════════════════════════
// Each tag identifies an effect category. Fractal types declare which tags they
// support, allowing the UI to show/hide effect cards based on the active fractal.

/// Identifies a modular lighting/shape effect for fractal-type association.
enum EffectTag: String, Codable, CaseIterable {
    case hueRotation      = "HUE"       // Color cycling — universal
    case pulse            = "PLS"       // Rhythmic brightness — universal
    case glow             = "GLW"       // Ray-step glow — universal
    case bloom            = "BLM"       // Bright-area bleed — universal
    case fog              = "FOG"       // Distance fog — universal
    case gradientCycle    = "GRC"       // Gradient offset animation — universal
    case polarRotation    = "POL"       // Polar/spherical rotation animation — Mandelbulb, Quaternion Julia
    case beatFlash        = "BTF"       // Music-driven edge flash — universal (requires audio)

    var displayName: String {
        switch self {
        case .hueRotation:   return "Hue Rotation"
        case .pulse:         return "Pulse"
        case .glow:          return "Glow"
        case .bloom:         return "Bloom"
        case .fog:           return "Fog"
        case .gradientCycle: return "Gradient Cycle"
        case .polarRotation: return "Polar Rotation"
        case .beatFlash:     return "Beat Flash"
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - LightingEffect Protocol
// ═══════════════════════════════════════════════════════════════════════════════
// All lighting effects share a common toggle + primary-value pattern.
// This protocol enables generic UI controls and batch operations.

/// Common interface for all modular lighting effects.
protocol LightingEffect: Codable, Equatable {
    /// Whether this effect is currently applied.
    var enabled: Bool { get set }
    /// The main intensity / amount / strength knob (0-1 range).
    var primaryValue: Float { get set }
    /// Human-readable label for the primary knob (e.g. "Speed", "Intensity").
    static var primaryLabel: String { get }
    /// A completely disabled instance.
    static var off: Self { get }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - Concrete Effects
// ═══════════════════════════════════════════════════════════════════════════════

/// Hue rotation effect - rotates colors through YIQ color space
struct HueRotationEffect: LightingEffect {
    var enabled: Bool = false
    var speed: Float = 0.1          // Rotation speed (0-0.5)
    var intensity: Float = 0.5      // Blend amount (0-1), prevents overpowering
    
    var primaryValue: Float {
        get { speed }
        set { speed = newValue }
    }
    static let primaryLabel = "Speed"
    
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
struct PulseEffect: LightingEffect {
    var enabled: Bool = false
    var speed: Float = 0.5          // Pulse frequency (0-2)
    var amount: Float = 0.3         // Pulse intensity (0-1)
    
    var primaryValue: Float {
        get { amount }
        set { amount = newValue }
    }
    static let primaryLabel = "Amount"
    
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
struct GlowEffect: LightingEffect {
    var enabled: Bool = false
    var intensity: Float = 0.3      // Glow brightness (0-1)
    
    var primaryValue: Float {
        get { intensity }
        set { intensity = newValue }
    }
    static let primaryLabel = "Intensity"
    
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
struct BloomEffect: LightingEffect {
    var enabled: Bool = false
    var strength: Float = 0.2       // Bloom intensity (0-1)
    
    var primaryValue: Float {
        get { strength }
        set { strength = newValue }
    }
    static let primaryLabel = "Strength"
    
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
struct FogEffect: LightingEffect {
    var enabled: Bool = true
    var intensity: Float = 0.32     // Fog density (0-1)
    
    var primaryValue: Float {
        get { intensity }
        set { intensity = newValue }
    }
    static let primaryLabel = "Intensity"
    
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

/// Gradient cycle effect - animates the gradient offset over time.
/// `mirrorLoop` ping-pongs the offset 0→1→0 instead of wrapping 0→1→0 discontinuously.
struct GradientCycleEffect: LightingEffect {
    var enabled: Bool = false
    var speed: Float = 0.1          // Cycle speed (0-1), how fast the gradient animates
    var mirrorLoop: Bool = true     // When true, offset runs forward then backward (ping-pong)

    enum CodingKeys: String, CodingKey {
        case enabled, speed, mirrorLoop, smoothLoop
    }

    init(enabled: Bool = false, speed: Float = 0.1, mirrorLoop: Bool = true) {
        self.enabled = enabled
        self.speed = speed
        self.mirrorLoop = mirrorLoop
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        speed = try container.decodeIfPresent(Float.self, forKey: .speed) ?? 0.1
        mirrorLoop = try container.decodeIfPresent(Bool.self, forKey: .mirrorLoop)
            ?? (try container.decodeIfPresent(Bool.self, forKey: .smoothLoop) ?? true)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(speed, forKey: .speed)
        try container.encode(mirrorLoop, forKey: .mirrorLoop)
    }
    
    var primaryValue: Float {
        get { speed }
        set { speed = newValue }
    }
    static let primaryLabel = "Speed"
    
    static var off: GradientCycleEffect {
        GradientCycleEffect(enabled: false, speed: 0.0, mirrorLoop: true)
    }
    
    static var slow: GradientCycleEffect {
        GradientCycleEffect(enabled: true, speed: 0.05, mirrorLoop: true)
    }
    
    static var medium: GradientCycleEffect {
        GradientCycleEffect(enabled: true, speed: 0.15, mirrorLoop: true)
    }
    
    static var fast: GradientCycleEffect {
        GradientCycleEffect(enabled: true, speed: 0.4, mirrorLoop: true)
    }
}

/// Polar rotation effect — animates the polar angle offset for spherical-coordinate fractals
/// (Mandelbulb) and rotates the quaternion C-constant plane (Quaternion Julia).
/// Only meaningful for fractal types that declare `.polarRotation` in their supported tags.
struct PolarRotationEffect: LightingEffect {
    /// Direction of rotation (off / clockwise / counterclockwise).
    /// Replaces the old `enabled` bool — `.off` means disabled.
    var direction: PolarRotationDirection = .off
    var speed: Float = 0.15         // Rotation speed (0–1)

    /// Backward-compatible enabled accessor (true when direction != .off)
    var enabled: Bool {
        get { direction != .off }
        set { direction = newValue ? .clockwise : .off }
    }

    /// Legacy amplitude — now derived from direction sign.
    /// Reading returns 1.0 (cw), -1.0 (ccw), or 0 (off).
    /// Writing is accepted silently for JSON backward compatibility.
    var amplitude: Float {
        get { direction.sign }
        set { /* ignored — direction drives sign now */ }
    }

    var primaryValue: Float {
        get { speed }
        set { speed = newValue }
    }
    static let primaryLabel = "Speed"

    static var off: PolarRotationEffect {
        PolarRotationEffect(direction: .off, speed: 0.0)
    }

    static var slow: PolarRotationEffect {
        PolarRotationEffect(direction: .clockwise, speed: 0.08)
    }

    static var medium: PolarRotationEffect {
        PolarRotationEffect(direction: .clockwise, speed: 0.15)
    }

    static var fast: PolarRotationEffect {
        PolarRotationEffect(direction: .clockwise, speed: 0.4)
    }

    // ── Codable ──────────────────────────────────────────────────────────
    // Custom coding so we can read legacy files that have `enabled` + `amplitude`
    // while writing the new `direction` key.

    enum CodingKeys: String, CodingKey {
        case direction, speed
        // Legacy keys for reading old files
        case enabled, amplitude
    }

    init(direction: PolarRotationDirection = .off, speed: Float = 0.15) {
        self.direction = direction
        self.speed = speed
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        speed = try c.decodeIfPresent(Float.self, forKey: .speed) ?? 0.15

        // Prefer new `direction` key; fall back to legacy `enabled` + `amplitude`
        if let dir = try c.decodeIfPresent(PolarRotationDirection.self, forKey: .direction) {
            direction = dir
        } else {
            let wasEnabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
            let amp = try c.decodeIfPresent(Float.self, forKey: .amplitude) ?? 1.0
            if !wasEnabled {
                direction = .off
            } else {
                direction = amp < 0 ? .counterclockwise : .clockwise
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(direction, forKey: .direction)
        try c.encode(speed, forKey: .speed)
    }
}

/// Rotation direction for `PolarRotationEffect`.
enum PolarRotationDirection: String, Codable, CaseIterable, Equatable {
    case off              = "off"
    case clockwise        = "clockwise"
    case counterclockwise = "counterclockwise"

    /// Multiplier applied to the rotation accumulator.
    var sign: Float {
        switch self {
        case .off:              return 0
        case .clockwise:        return 1
        case .counterclockwise: return -1
        }
    }

    var icon: String {
        switch self {
        case .off:              return "stop.fill"
        case .clockwise:        return "arrow.clockwise"
        case .counterclockwise: return "arrow.counterclockwise"
        }
    }

    var label: String {
        switch self {
        case .off:              return "Off"
        case .clockwise:        return "CW"
        case .counterclockwise: return "CCW"
        }
    }
}

/// Beat flash effect — music-driven orange-red edge glow that fires on beat detection.
/// Intensity controls how strongly the flash drives the edge glow (shader mixes beat × intensity).
struct BeatFlashEffect: LightingEffect {
    var enabled: Bool = false
    var intensity: Float = 0.4      // Flash strength (0-1), multiplied by beat level

    var primaryValue: Float {
        get { intensity }
        set { intensity = newValue }
    }
    static let primaryLabel = "Intensity"

    static var off: BeatFlashEffect {
        BeatFlashEffect(enabled: false, intensity: 0.0)
    }

    static var subtle: BeatFlashEffect {
        BeatFlashEffect(enabled: true, intensity: 0.2)
    }

    static var medium: BeatFlashEffect {
        BeatFlashEffect(enabled: true, intensity: 0.4)
    }

    static var intense: BeatFlashEffect {
        BeatFlashEffect(enabled: true, intensity: 0.7)
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - Lighting Presets
// ═══════════════════════════════════════════════════════════════════════════════

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
