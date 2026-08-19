//
//  LightingTypes.swift
//  Threshold
//
//  Modular lighting effects that can be toggled on/off independently.
//  Each effect is a card in the UI with its own settings.
//  Presets bundle effects together for quick looks.
//

import Foundation
import simd

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
    case linearRail       = "LNR"       // Straight-axis position cycling — universal
    case polarRotation    = "POL"       // Polar/spherical rotation animation — Mandelbulb, Quaternion Julia
    case beatFlash        = "BTF"       // Music-driven edge flash — universal (requires audio)
    case juliaDrift       = "JLD"       // Animated Julia C drift — Mandelbulb Julia only

    var displayName: String {
        switch self {
        case .hueRotation:   return "Hue Rotation"
        case .pulse:         return "Pulse"
        case .glow:          return "Glow"
        case .bloom:         return "Bloom"
        case .fog:           return "Fog"
        case .gradientCycle: return "Gradient Cycle"
        case .linearRail:    return "Linear Rail"
        case .polarRotation: return "Polar Rotation"
        case .beatFlash:     return "Beat Flash"
        case .juliaDrift:    return "Julia Drift"
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
    var color: SIMD3<Float> = Self.defaultColor

    /// Matches the cool-white tint used by the shader before glow became
    /// user-colorable, preserving the appearance of existing scenes.
    static let defaultColor = SIMD3<Float>(0.95, 0.97, 1.0)

    enum CodingKeys: String, CodingKey {
        case enabled, intensity, colorRed, colorGreen, colorBlue
    }

    init(enabled: Bool = false,
         intensity: Float = 0.3,
         color: SIMD3<Float> = GlowEffect.defaultColor) {
        self.enabled = enabled
        self.intensity = intensity
        self.color = color
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        intensity = try container.decodeIfPresent(Float.self, forKey: .intensity) ?? 0.3
        color = SIMD3<Float>(
            try container.decodeIfPresent(Float.self, forKey: .colorRed) ?? Self.defaultColor.x,
            try container.decodeIfPresent(Float.self, forKey: .colorGreen) ?? Self.defaultColor.y,
            try container.decodeIfPresent(Float.self, forKey: .colorBlue) ?? Self.defaultColor.z
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(intensity, forKey: .intensity)
        try container.encode(color.x, forKey: .colorRed)
        try container.encode(color.y, forKey: .colorGreen)
        try container.encode(color.z, forKey: .colorBlue)
    }

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
    var color: SIMD3<Float> = Self.defaultColor

    /// Matches the warm-white tint used by the shader before bloom became
    /// user-colorable, preserving the appearance of existing scenes.
    static let defaultColor = SIMD3<Float>(1.0, 0.96, 0.88)

    enum CodingKeys: String, CodingKey {
        case enabled, strength, colorRed, colorGreen, colorBlue
    }

    init(enabled: Bool = false,
         strength: Float = 0.2,
         color: SIMD3<Float> = BloomEffect.defaultColor) {
        self.enabled = enabled
        self.strength = strength
        self.color = color
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        strength = try container.decodeIfPresent(Float.self, forKey: .strength) ?? 0.2
        color = SIMD3<Float>(
            try container.decodeIfPresent(Float.self, forKey: .colorRed) ?? Self.defaultColor.x,
            try container.decodeIfPresent(Float.self, forKey: .colorGreen) ?? Self.defaultColor.y,
            try container.decodeIfPresent(Float.self, forKey: .colorBlue) ?? Self.defaultColor.z
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(strength, forKey: .strength)
        try container.encode(color.x, forKey: .colorRed)
        try container.encode(color.y, forKey: .colorGreen)
        try container.encode(color.z, forKey: .colorBlue)
    }

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

// MARK: - Ordered output-filter stack

/// Stable catalog identity shared by scene persistence and the Metal ABI.
///
/// Raw values are deliberately numeric and append-only: saved scenes and the GPU
/// `PostFilterOp.type` switch both depend on them. Display strings are kept out of
/// the wire format so labels can evolve without changing scene identity.
enum PostProcessingFilterKind: Int32, CaseIterable, Identifiable, Codable, Hashable, Sendable {
    case edgeDetection = 1
    case monochrome = 2
    case sepia = 3
    case invert = 4
    case posterize = 5
    case grain = 6
    case scanlines = 7

    var id: Int32 { rawValue }

    var displayName: String {
        switch self {
        case .edgeDetection: return "Edge Detection"
        case .monochrome: return "Monochrome"
        case .sepia: return "Sepia"
        case .invert: return "Invert"
        case .posterize: return "Posterize"
        case .grain: return "Grain"
        case .scanlines: return "Scanlines"
        }
    }

    var icon: String {
        switch self {
        case .edgeDetection: return "circle.lefthalf.filled"
        case .monochrome: return "circle.lefthalf.striped.horizontal"
        case .sepia: return "camera.filters"
        case .invert: return "circle.righthalf.filled.inverse"
        case .posterize: return "square.stack.3d.up.fill"
        case .grain: return "aqi.medium"
        case .scanlines: return "line.3.horizontal"
        }
    }

    var summary: String {
        switch self {
        case .edgeDetection:
            return "Outline luminance transitions in the final rendered scene."
        case .monochrome:
            return "Blend the final image toward perceptual grayscale."
        case .sepia:
            return "Apply a warm photographic sepia treatment."
        case .invert:
            return "Invert the final scene colors."
        case .posterize:
            return "Reduce each color channel to a smaller number of levels."
        case .grain:
            return "Add animated fine-grained texture to the final image."
        case .scanlines:
            return "Darken repeating horizontal lines for a display-like texture."
        }
    }

    var searchKeywords: [String] {
        switch self {
        case .edgeDetection: return ["edge", "outline", "contour", "threshold", "softness", "window size"]
        case .monochrome: return ["black and white", "grayscale", "desaturate"]
        case .sepia: return ["warm", "vintage", "photographic"]
        case .invert: return ["negative", "inverse", "opposite colors"]
        case .posterize: return ["levels", "quantize", "bands"]
        case .grain: return ["noise", "film", "texture", "scale"]
        case .scanlines: return ["lines", "crt", "display", "density", "darkening"]
        }
    }

    /// A fresh, visibly useful instance for an Add Filter action.
    var defaultInstance: PostFilterInstance { PostFilterInstance(kind: self) }
}

/// One authored occurrence in the ordered output-filter stack.
///
/// Parameter slots have a stable, compact meaning shared with Metal:
/// - Edge Detection: x threshold, y softness, z integer window radius (1...3)
/// - Posterize: x color levels (2...32)
/// - Grain: x spatial frequency/scale (1...2048)
/// - Scanlines: x line density (1...2048), y line darkening (0...1)
/// - Monochrome, Sepia, and Invert use only `amount`.
struct PostFilterInstance: Codable, Identifiable, Equatable, Sendable {
    static let maximumCount = 8
    static let activationEpsilon: Float = 0.001

    var id: UUID
    var kind: PostProcessingFilterKind
    var isEnabled: Bool
    var amount: Float
    var params: SIMD4<Float>
    var color: SIMD3<Float>

    /// Seed a newly-added filter with a useful visible treatment.
    init(kind: PostProcessingFilterKind) {
        self.id = UUID()
        self.kind = kind
        self.isEnabled = true
        switch kind {
        case .edgeDetection:
            self.amount = 0.8
            self.params = SIMD4<Float>(0.10, 0.06, 1, 0)
            self.color = .zero
        case .monochrome, .sepia, .invert:
            self.amount = 1
            self.params = .zero
            self.color = SIMD3<Float>(repeating: 1)
        case .posterize:
            self.amount = 1
            self.params = SIMD4<Float>(6, 0, 0, 0)
            self.color = SIMD3<Float>(repeating: 1)
        case .grain:
            self.amount = 0.25
            self.params = SIMD4<Float>(240, 0, 0, 0)
            self.color = SIMD3<Float>(repeating: 1)
        case .scanlines:
            self.amount = 0.5
            self.params = SIMD4<Float>(480, 0.35, 0, 0)
            self.color = SIMD3<Float>(repeating: 1)
        }
    }

    init(
        id: UUID = UUID(),
        kind: PostProcessingFilterKind,
        isEnabled: Bool,
        amount: Float,
        params: SIMD4<Float>,
        color: SIMD3<Float>
    ) {
        self.id = id
        self.kind = kind
        self.isEnabled = isEnabled
        self.amount = amount
        self.params = params
        self.color = color
        normalize()
    }

    var isActive: Bool { isEnabled && amount > Self.activationEpsilon }

    /// Clamp authored/imported values without coupling enable state to amount.
    /// Keeping the remembered amount while disabled lets a toggle restore the
    /// exact treatment; GPU packing independently drops disabled/zero instances.
    mutating func normalize() {
        let defaults = PostFilterInstance(kind: kind)
        amount = amount.isFinite ? min(max(amount, 0), 1) : 0

        for index in 0..<4 where !params[index].isFinite {
            params[index] = defaults.params[index]
        }
        switch kind {
        case .edgeDetection:
            params.x = ControlCatalog.edgeThreshold.clamp(params.x)
            params.y = ControlCatalog.edgeSoftness.clamp(params.y)
            params.z = ControlCatalog.edgeWindowRadius.clamp(params.z).rounded()
            params.w = 0
        case .posterize:
            params = SIMD4<Float>(min(max(params.x.rounded(), 2), 32), 0, 0, 0)
        case .grain:
            params = SIMD4<Float>(min(max(params.x, 1), 2048), 0, 0, 0)
        case .scanlines:
            params = SIMD4<Float>(min(max(params.x, 1), 2048), min(max(params.y, 0), 1), 0, 0)
        case .monochrome, .sepia, .invert:
            params = .zero
        }

        color = SIMD3<Float>(
            color.x.isFinite ? min(max(color.x, 0), 1) : defaults.color.x,
            color.y.isFinite ? min(max(color.y, 0), 1) : defaults.color.y,
            color.z.isFinite ? min(max(color.z, 0), 1) : defaults.color.z
        )
    }

    /// Compatibility projection from the legacy one-off edge model.
    init(edgeEffect: EdgeDetectionEffect, id: UUID = UUID()) {
        var edge = edgeEffect
        edge.normalize()
        self.init(
            id: id,
            kind: .edgeDetection,
            isEnabled: edge.enabled,
            amount: edge.strength,
            params: SIMD4<Float>(edge.threshold, edge.softness, Float(edge.windowRadius), 0),
            color: edge.color
        )
    }

    /// Compatibility projection back to the legacy render/persistence fields.
    var edgeDetectionEffect: EdgeDetectionEffect? {
        guard kind == .edgeDetection else { return nil }
        var edge = EdgeDetectionEffect(
            enabled: isEnabled,
            strength: amount,
            threshold: params.x,
            softness: params.y,
            windowRadius: Int(params.z.rounded()),
            color: color
        )
        edge.normalize()
        return edge
    }
}

extension Array where Element == PostFilterInstance {
    /// Normalize imported values, preserve authored order, enforce the one-edge
    /// invariant, and cap the bounded GPU/editor stack at eight instances.
    func normalizedPostFilterStack() -> [PostFilterInstance] {
        var result: [PostFilterInstance] = []
        result.reserveCapacity(Swift.min(count, PostFilterInstance.maximumCount))
        var hasEdge = false

        for var instance in self {
            instance.normalize()
            if instance.kind == .edgeDetection {
                guard !hasEdge else { continue }
                hasEdge = true
            }
            result.append(instance)
            if result.count == PostFilterInstance.maximumCount { break }
        }
        return result
    }
}

@inline(__always)
private func packPostFilterRGB10(_ color: SIMD3<Float>) -> UInt32 {
    @inline(__always)
    func channel(_ value: Float) -> UInt32 {
        let safeValue = value.isFinite ? min(max(value, 0), 1) : 0
        return UInt32((safeValue * 1023).rounded())
    }
    return channel(color.x) | (channel(color.y) << 10) | (channel(color.z) << 20)
}

/// Pack only active filters into the fixed Swift↔Metal ABI. Disabled and
/// amount-zero instances are true bypasses and consume no shader loop slot.
func cPostFilterStack(from filters: [PostFilterInstance]) -> PostFilterStack {
    var stack = PostFilterStack()
    let active = filters.normalizedPostFilterStack().filter(\.isActive)
    withUnsafeMutablePointer(to: &stack.ops) { tuplePtr in
        tuplePtr.withMemoryRebound(
            to: PostFilterOp.self,
            capacity: PostFilterInstance.maximumCount
        ) { base in
            for (index, filter) in active.enumerated() {
                base[index] = PostFilterOp(
                    type: filter.kind.rawValue,
                    amount: filter.amount,
                    param1: filter.params.x,
                    param2: filter.params.y,
                    param3: filter.params.z,
                    colorRGB10: packPostFilterRGB10(filter.color),
                    _pad0: 0,
                    _pad1: 0
                )
            }
        }
    }
    stack.count = Int32(active.count)
    return stack
}

/// Screen-space edge detector. The fragment path uses a local luminance
/// gradient, so this is a lightweight convolution-style outline pass.
struct EdgeDetectionEffect: LightingEffect {
    /// Below this value the output is indistinguishable from the source. Use the
    /// same cutoff for UI state and uniform packing so an apparently-off edge
    /// effect never allocates or dispatches the compute post-process pass.
    static let activationEpsilon: Float = 0.001

    var enabled: Bool = false
    var strength: Float = 0.0
    var threshold: Float = 0.12
    var softness: Float = 0.08
    var windowRadius: Int = 1
    var color: SIMD3<Float> = Self.defaultColor

    /// Existing scenes used black outlines before edge tinting was exposed.
    /// Keeping black as the decode fallback preserves their rendered look.
    static let defaultColor = SIMD3<Float>(repeating: 0.0)

    enum CodingKeys: String, CodingKey {
        case enabled, strength, threshold, softness, windowRadius
        case colorRed, colorGreen, colorBlue
    }

    init(enabled: Bool = false,
         strength: Float = 0.0,
         threshold: Float = 0.12,
         softness: Float = 0.08,
         windowRadius: Int = 1,
         color: SIMD3<Float> = EdgeDetectionEffect.defaultColor) {
        self.enabled = enabled
        self.strength = strength
        self.threshold = threshold
        self.softness = softness
        self.windowRadius = windowRadius
        self.color = color
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        strength = try container.decodeIfPresent(Float.self, forKey: .strength) ?? 0.0
        threshold = try container.decodeIfPresent(Float.self, forKey: .threshold) ?? 0.12
        softness = try container.decodeIfPresent(Float.self, forKey: .softness) ?? 0.08
        windowRadius = try container.decodeIfPresent(Int.self, forKey: .windowRadius) ?? 1
        color = SIMD3<Float>(
            try container.decodeIfPresent(Float.self, forKey: .colorRed) ?? Self.defaultColor.x,
            try container.decodeIfPresent(Float.self, forKey: .colorGreen) ?? Self.defaultColor.y,
            try container.decodeIfPresent(Float.self, forKey: .colorBlue) ?? Self.defaultColor.z
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(strength, forKey: .strength)
        try container.encode(threshold, forKey: .threshold)
        try container.encode(softness, forKey: .softness)
        try container.encode(windowRadius, forKey: .windowRadius)
        try container.encode(color.x, forKey: .colorRed)
        try container.encode(color.y, forKey: .colorGreen)
        try container.encode(color.z, forKey: .colorBlue)
    }

    var isActive: Bool {
        enabled && strength > Self.activationEpsilon
    }

    var primaryValue: Float {
        get { strength }
        set { setStrength(newValue) }
    }
    static let primaryLabel = "Strength"

    /// Edge strength is the authoritative on/off control. Dependent tuning is
    /// intentionally preserved while off so raising strength restores the prior
    /// threshold/softness/window settings.
    mutating func setStrength(_ value: Float) {
        strength = ControlCatalog.edgeStrength.clamp(value)
        enabled = strength > Self.activationEpsilon
        if !enabled { strength = 0 }
    }

    /// Clamp data arriving from scenes/UserDefaults. Legacy files could encode
    /// `enabled: false` with a non-zero remembered strength; migrate that state
    /// to the new zero-is-off representation without unexpectedly enabling it.
    mutating func normalize() {
        strength = ControlCatalog.edgeStrength.clamp(strength)
        threshold = ControlCatalog.edgeThreshold.clamp(threshold)
        softness = ControlCatalog.edgeSoftness.clamp(softness)
        let radius = ControlCatalog.edgeWindowRadius.clamp(Float(windowRadius))
        windowRadius = Int(radius.rounded())
        color = SIMD3<Float>(
            color.x.isFinite ? min(max(color.x, 0), 1) : Self.defaultColor.x,
            color.y.isFinite ? min(max(color.y, 0), 1) : Self.defaultColor.y,
            color.z.isFinite ? min(max(color.z, 0), 1) : Self.defaultColor.z
        )
        if !enabled || strength <= Self.activationEpsilon {
            enabled = false
            strength = 0
        }
    }

    static var off: EdgeDetectionEffect {
        EdgeDetectionEffect(enabled: false, strength: 0.0)
    }

    static var outline: EdgeDetectionEffect {
        EdgeDetectionEffect(enabled: true, strength: 0.8, threshold: 0.10, softness: 0.06, windowRadius: 1)
    }
}

/// Fog effect - distance-based atmospheric fog
struct FogEffect: LightingEffect {
    var enabled: Bool = true
    var intensity: Float = 0.32     // Fog density (0-1)
    var color: SIMD3<Float> = Self.defaultColor
    /// When true, the fog tint cycles its hue over time on its own timer,
    /// independent of the global Hue Rotation effect.
    var hueRotateEnabled: Bool = false
    /// Fog-tint hue cycle speed (0–0.5), independent of the global hue rotation.
    var hueRotateSpeed: Float = 0.1

    static let defaultColor = SIMD3<Float>(0.01, 0.015, 0.02)

    enum CodingKeys: String, CodingKey {
        case enabled, intensity, colorRed, colorGreen, colorBlue
        case hueRotateEnabled, hueRotateSpeed
    }

    init(enabled: Bool = true,
         intensity: Float = 0.32,
         color: SIMD3<Float> = FogEffect.defaultColor,
         hueRotateEnabled: Bool = false,
         hueRotateSpeed: Float = 0.1) {
        self.enabled = enabled
        self.intensity = intensity
        self.color = color
        self.hueRotateEnabled = hueRotateEnabled
        self.hueRotateSpeed = hueRotateSpeed
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        intensity = try container.decodeIfPresent(Float.self, forKey: .intensity) ?? 0.32
        color = SIMD3<Float>(
            try container.decodeIfPresent(Float.self, forKey: .colorRed) ?? Self.defaultColor.x,
            try container.decodeIfPresent(Float.self, forKey: .colorGreen) ?? Self.defaultColor.y,
            try container.decodeIfPresent(Float.self, forKey: .colorBlue) ?? Self.defaultColor.z
        )
        hueRotateEnabled = try container.decodeIfPresent(Bool.self, forKey: .hueRotateEnabled) ?? false
        hueRotateSpeed = try container.decodeIfPresent(Float.self, forKey: .hueRotateSpeed) ?? 0.1
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(intensity, forKey: .intensity)
        try container.encode(color.x, forKey: .colorRed)
        try container.encode(color.y, forKey: .colorGreen)
        try container.encode(color.z, forKey: .colorBlue)
        try container.encode(hueRotateEnabled, forKey: .hueRotateEnabled)
        try container.encode(hueRotateSpeed, forKey: .hueRotateSpeed)
    }
    
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
    var direction: PolarRotationDirection = .off
    var speed: Float = 0.15         // Rotation speed (0–1)

    var enabled: Bool {
        get { direction != .off }
        set { direction = newValue ? .clockwise : .off }
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

    init(direction: PolarRotationDirection = .off, speed: Float = 0.15) {
        self.direction = direction
        self.speed = speed
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

/// Julia C drift effect — slowly orbits the Julia C vector (params 9-11) around
/// the diagonal axis (1,1,1)/√3, causing the fractal shape to morph continuously.
/// Only meaningful for mandelbulbJulia.
struct JuliaDriftEffect: LightingEffect {
    var enabled: Bool = false
    var speed: Float = 0.1          // Orbit speed (0–1)

    var primaryValue: Float {
        get { speed }
        set { speed = newValue }
    }
    static let primaryLabel = "Speed"

    static var off: JuliaDriftEffect {
        JuliaDriftEffect(enabled: false, speed: 0.0)
    }

    static var slow: JuliaDriftEffect {
        JuliaDriftEffect(enabled: true, speed: 0.05)
    }

    static var medium: JuliaDriftEffect {
        JuliaDriftEffect(enabled: true, speed: 0.1)
    }

    static var fast: JuliaDriftEffect {
        JuliaDriftEffect(enabled: true, speed: 0.25)
    }
}

enum LinearRailAxis: String, Codable, CaseIterable, Equatable {
    case x
    case y
    case z
    case diagonal

    var vector: SIMD3<Float> {
        switch self {
        case .x:
            return SIMD3<Float>(1, 0, 0)
        case .y:
            return SIMD3<Float>(0, 1, 0)
        case .z:
            return SIMD3<Float>(0, 0, 1)
        case .diagonal:
            let component: Float = 1.0 / sqrt(3.0)
            return SIMD3<Float>(component, component, component)
        }
    }

    var label: String {
        switch self {
        case .x: return "X"
        case .y: return "Y"
        case .z: return "Depth"
        case .diagonal: return "Diag"
        }
    }
}

struct LinearRailEffect: LightingEffect {
    var enabled: Bool = false
    var axis: LinearRailAxis = .z
    var speed: Float = 0.12
    var amplitude: Float = 0.7
    var multiplier: Float = 1.0
    var orbitAmount: Float = 0.0
    var orbitSpeed: Float = 0.18

    enum CodingKeys: String, CodingKey {
        case enabled, axis, speed, amplitude, multiplier, orbitAmount, orbitSpeed
    }

    init(enabled: Bool = false,
         axis: LinearRailAxis = .z,
         speed: Float = 0.12,
         amplitude: Float = 0.7,
         multiplier: Float = 1.0,
         orbitAmount: Float = 0.0,
         orbitSpeed: Float = 0.18) {
        self.enabled = enabled
        self.axis = axis
        self.speed = speed
        self.amplitude = amplitude
        self.multiplier = multiplier
        self.orbitAmount = orbitAmount
        self.orbitSpeed = orbitSpeed
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        axis = try container.decodeIfPresent(LinearRailAxis.self, forKey: .axis) ?? .z
        speed = try container.decodeIfPresent(Float.self, forKey: .speed) ?? 0.12
        amplitude = try container.decodeIfPresent(Float.self, forKey: .amplitude) ?? 0.7
        multiplier = try container.decodeIfPresent(Float.self, forKey: .multiplier) ?? 1.0
        orbitAmount = try container.decodeIfPresent(Float.self, forKey: .orbitAmount) ?? 0.0
        orbitSpeed = try container.decodeIfPresent(Float.self, forKey: .orbitSpeed) ?? 0.18
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(axis, forKey: .axis)
        try container.encode(speed, forKey: .speed)
        try container.encode(amplitude, forKey: .amplitude)
        try container.encode(multiplier, forKey: .multiplier)
        try container.encode(orbitAmount, forKey: .orbitAmount)
        try container.encode(orbitSpeed, forKey: .orbitSpeed)
    }

    var primaryValue: Float {
        get { speed }
        set { speed = newValue }
    }
    static let primaryLabel = "Speed"

    static var off: LinearRailEffect {
        LinearRailEffect(enabled: false, axis: .z, speed: 0.0, amplitude: 0.0)
    }

    static var slow: LinearRailEffect {
        LinearRailEffect(enabled: true, axis: .z, speed: 0.08, amplitude: 0.45)
    }

    static var medium: LinearRailEffect {
        LinearRailEffect(enabled: true, axis: .z, speed: 0.14, amplitude: 0.7)
    }

    static var fast: LinearRailEffect {
        LinearRailEffect(enabled: true, axis: .z, speed: 0.24, amplitude: 1.0)
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
    case edgeDetection = "Edge Detection"
    case custom = "Custom"
    
    var displayName: String { rawValue }
    
    var icon: String {
        switch self {
        case .off: return "moon.zzz"
        case .subtle: return "sun.min"
        case .dynamic: return "sparkle"
        case .psychedelic: return "wand.and.rays"
        case .atmospheric: return "cloud.fog"
        case .edgeDetection: return "lines.measurement.horizontal"
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
        case .edgeDetection: return "Outline surfaces with a manual luminance edge detector"
        case .custom: return "Manual control"
        }
    }
    
    /// Get the effect bundle for this preset
    func effects() -> (hue: HueRotationEffect, pulse: PulseEffect, glow: GlowEffect, bloom: BloomEffect, edge: EdgeDetectionEffect, fog: FogEffect, gradientCycle: GradientCycleEffect, linearRail: LinearRailEffect) {
        switch self {
        case .off:
            return (.off, .off, .off, .off, .off, .off, .off, .off)
            
        case .subtle:
            return (.subtle, .off, .subtle, .subtle, .off, .subtle, .off, .off)
            
        case .dynamic:
            return (.medium, .medium, .medium, .medium, .off, .medium, .slow, .slow)
            
        case .psychedelic:
            return (.intense, .intense, .intense, .intense, .off, .medium, .medium, .medium)
            
        case .atmospheric:
            return (.off, .subtle, .medium, .subtle, .off, .dense, .off, .off)

        case .edgeDetection:
            return (.off, .off, .subtle, .off, .outline, .off, .off, .off)
            
        case .custom:
            // Return current settings unchanged
            return (.off, .off, .off, .off, .off, .off, .off, .off)
        }
    }
}
