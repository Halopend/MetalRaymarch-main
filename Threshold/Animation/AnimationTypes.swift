//
//  AnimationTypes.swift
//  Threshold
//
//  Data structures for scene-based parameter animation.
//  Similar to CSS keyframe animations - keyframes represent parameter states,
//  and we tween between them over specified durations.
//

import Foundation
import simd

// MARK: - Bezier Handle

/// Control point for a cubic Bezier easing curve.
/// The curve goes from (0,0) to (1,1), with two control points defining the shape.
/// This is the same model as CSS cubic-bezier() — e.g. ease-in-out = (0.42, 0, 0.58, 1).
struct BezierHandle: Codable, Equatable {
    var cp1x: Float  // Control point 1 x (time axis, 0-1)
    var cp1y: Float  // Control point 1 y (value axis, can overshoot)
    var cp2x: Float  // Control point 2 x (time axis, 0-1)
    var cp2y: Float  // Control point 2 y (value axis, can overshoot)
    
    /// Linear (no easing)
    static let linear = BezierHandle(cp1x: 0.0, cp1y: 0.0, cp2x: 1.0, cp2y: 1.0)
    
    /// Ease in (slow start)
    static let easeIn = BezierHandle(cp1x: 0.42, cp1y: 0.0, cp2x: 1.0, cp2y: 1.0)
    
    /// Ease out (slow end)
    static let easeOut = BezierHandle(cp1x: 0.0, cp1y: 0.0, cp2x: 0.58, cp2y: 1.0)
    
    /// Ease in-out (slow start and end)
    static let easeInOut = BezierHandle(cp1x: 0.42, cp1y: 0.0, cp2x: 0.58, cp2y: 1.0)
    
    /// Overshoot (bouncy feel)
    static let overshoot = BezierHandle(cp1x: 0.34, cp1y: 1.56, cp2x: 0.64, cp2y: 1.0)
    
    /// Anticipate (pull back then go)
    static let anticipate = BezierHandle(cp1x: 0.36, cp1y: -0.2, cp2x: 0.66, cp2y: 1.0)
    
    /// Snappy (fast start, slow end)
    static let snappy = BezierHandle(cp1x: 0.1, cp1y: 0.9, cp2x: 0.2, cp2y: 1.0)
}

// MARK: - Cubic Bezier Evaluator

/// Evaluates a cubic Bezier curve for animation easing.
/// Uses Newton-Raphson iteration (same approach as GMT-fractals' BezierMath.ts)
/// to solve for the y-value at a given t (time progress 0-1).
struct CubicBezier {
    
    /// Evaluate the Bezier easing curve at time t (0-1).
    /// Returns the eased value (0-1, can overshoot if control points allow).
    /// - Parameters:
    ///   - t: Linear time progress 0-1
    ///   - handle: The Bezier control points
    /// - Returns: Eased progress value
    static func evaluate(_ t: Float, handle: BezierHandle) -> Float {
        // Early out for endpoints and near-linear
        if t <= 0.0 { return 0.0 }
        if t >= 1.0 { return 1.0 }
        
        // Check if essentially linear
        let isLinear = abs(handle.cp1x) < 0.001 && abs(handle.cp1y) < 0.001 &&
                       abs(handle.cp2x - 1.0) < 0.001 && abs(handle.cp2y - 1.0) < 0.001
        if isLinear { return t }
        
        // Newton-Raphson: solve for the Bezier parameter u where x(u) = t
        let u = solveCurveX(t, cp1x: handle.cp1x, cp2x: handle.cp2x)
        
        // Evaluate y at that parameter
        return bezierY(u, cp1y: handle.cp1y, cp2y: handle.cp2y)
    }
    
    // Bezier x(u) = 3*(1-u)²*u*cp1x + 3*(1-u)*u²*cp2x + u³
    private static func bezierX(_ u: Float, cp1x: Float, cp2x: Float) -> Float {
        let u1 = 1.0 - u
        return 3.0 * u1 * u1 * u * cp1x + 3.0 * u1 * u * u * cp2x + u * u * u
    }
    
    // Bezier y(u) = 3*(1-u)²*u*cp1y + 3*(1-u)*u²*cp2y + u³
    private static func bezierY(_ u: Float, cp1y: Float, cp2y: Float) -> Float {
        let u1 = 1.0 - u
        return 3.0 * u1 * u1 * u * cp1y + 3.0 * u1 * u * u * cp2y + u * u * u
    }
    
    // Derivative dx/du for Newton-Raphson
    private static func bezierDX(_ u: Float, cp1x: Float, cp2x: Float) -> Float {
        let u1 = 1.0 - u
        return 3.0 * u1 * u1 * cp1x + 6.0 * u1 * u * (cp2x - cp1x) + 3.0 * u * u * (1.0 - cp2x)
    }
    
    /// Newton-Raphson iteration to find u where x(u) = t
    private static func solveCurveX(_ t: Float, cp1x: Float, cp2x: Float) -> Float {
        var u = t  // Initial guess
        
        // 8 iterations of Newton-Raphson (converges very fast)
        for _ in 0..<8 {
            let x = bezierX(u, cp1x: cp1x, cp2x: cp2x) - t
            let dx = bezierDX(u, cp1x: cp1x, cp2x: cp2x)
            
            if abs(x) < 1e-7 { break }  // Converged
            if abs(dx) < 1e-7 { break }  // Degenerate
            
            u -= x / dx
        }
        
        return simd_clamp(u, 0.0, 1.0)
    }
}

// MARK: - Animation Keyframe

/// A single keyframe capturing shape parameters at a point in time.
/// Duration represents how long to animate FROM the previous keyframe TO this one.
struct AnimationKeyframe: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var duration: TimeInterval  // Seconds to reach this keyframe from previous (0 for first keyframe)
    
    // ═══════════════════════════════════════════════════════════════════════════
    // EASING - Per-keyframe Bezier curve control
    // ═══════════════════════════════════════════════════════════════════════════
    
    /// Per-keyframe easing function. Overrides the global easing when set.
    var easingType: EasingFunction = .bezier
    
    /// Bezier control points for this keyframe's transition (used when easingType == .bezier)
    var bezierHandle: BezierHandle = .easeInOut
    
    // ═══════════════════════════════════════════════════════════════════════════
    // SHAPE PARAMETERS - These affect the fractal geometry
    // ═══════════════════════════════════════════════════════════════════════════
    
    var minDistance: Float
    var foldingLimit: Float
    var sphereRadius: Float
    var fractalScale: Float
    
    // Quality parameters (don't vary over time in splines)
    var baseFractalIterations: Int
    var baseMaxRaySteps: Int
    
    // Base scale factor
    var scale: Float
    
    // Position in 3D space
    var positionX: Float
    var positionY: Float
    var positionZ: Float

    // Detail transform (two-point grab): extra scale + world rotation
    var detailScale: Float
    var worldRotationX: Float
    var worldRotationY: Float
    var worldRotationZ: Float
    var worldRotationW: Float
    
    var position: SIMD3<Float> {
        get { SIMD3<Float>(positionX, positionY, positionZ) }
        set {
            positionX = newValue.x
            positionY = newValue.y
            positionZ = newValue.z
        }
    }

    var worldRotation: simd_quatf {
        get {
            simd_quatf(ix: worldRotationX, iy: worldRotationY, iz: worldRotationZ, r: worldRotationW).normalized
        }
        set {
            let q = newValue.normalized
            worldRotationX = q.imag.x
            worldRotationY = q.imag.y
            worldRotationZ = q.imag.z
            worldRotationW = q.real
        }
    }
    
    // ═══════════════════════════════════════════════════════════════════════════
    // OPTIONAL: Visual parameters (can be animated too)
    // ═══════════════════════════════════════════════════════════════════════════
    
    var colorScheme: ColorScheme?  // nil = don't change color scheme during animation
    var lightingMode: LightingMode?
    var lightingPreset: LightingPreset?
    var hueRotationEffect: HueRotationEffect?
    var pulseEffect: PulseEffect?
    var glowEffect: GlowEffect?
    var bloomEffect: BloomEffect?
    var fogEffect: FogEffect?
    var gradientCycleEffect: GradientCycleEffect?
    
    // ═══════════════════════════════════════════════════════════════════════════
    // OPTIONAL: Per-keyframe color overrides (nil = use scene-level default)
    // ═══════════════════════════════════════════════════════════════════════════
    
    var colorMappingMode: ColorMappingMode?
    var gradientRepeat: Float?
    var gradientOffset: Float?
    var gradientSmoothing: Float?
    var colorSchemeSaturation: Float?
    var colorSchemeContrast: Float?
    var colorSchemeGamma: Float?
    var colorSchemeVibrance: Float?
    var colorSchemeCurve: Float?
    var colorSchemeShadows: Float?
    var colorSchemeHighlights: Float?
    var lightingSoftness: Float?
    var gradientPreset: GradientPreset?
    
    // Formula parameters for non-Mandelbox types (16 float slots)
    var formulaParamValues: [Float]?
    
    /// Create a keyframe from current render settings
    init(from settings: RenderSettings, name: String = "Keyframe", duration: TimeInterval = 2.0) {
        self.id = UUID()
        self.name = name
        self.duration = duration
        
        // Capture current shape parameters
        self.minDistance = settings.minDistance
        self.foldingLimit = settings.foldingLimit
        self.sphereRadius = settings.sphereRadius
        self.fractalScale = settings.fractalScale
        
        // Capture quality parameters
        self.baseFractalIterations = settings.baseFractalIterations
        self.baseMaxRaySteps = settings.baseMaxRaySteps
        
        // Capture base scale
        self.scale = settings.scale
        
        // Capture position
        self.positionX = settings.position.x
        self.positionY = settings.position.y
        self.positionZ = settings.position.z

        // Capture detail transform
        self.detailScale = settings.detailScale
        self.worldRotationX = settings.worldRotation.imag.x
        self.worldRotationY = settings.worldRotation.imag.y
        self.worldRotationZ = settings.worldRotation.imag.z
        self.worldRotationW = settings.worldRotation.real
        
        self.colorScheme = settings.colorScheme
        self.lightingMode = settings.lightingMode
        self.lightingPreset = settings.lightingPreset
        self.hueRotationEffect = settings.hueRotationEffect
        self.pulseEffect = settings.pulseEffect
        self.glowEffect = settings.glowEffect
        self.bloomEffect = settings.bloomEffect
        self.fogEffect = settings.fogEffect
        self.gradientCycleEffect = settings.gradientCycleEffect
        
        // Capture color / gradient settings
        self.colorMappingMode = settings.colorMappingMode
        self.gradientRepeat = settings.gradientRepeat
        self.gradientOffset = settings.gradientOffset
        self.gradientSmoothing = settings.gradientSmoothing
        self.colorSchemeSaturation = settings.colorSchemeSaturation
        self.colorSchemeContrast = settings.colorSchemeContrast
        self.colorSchemeGamma = settings.colorSchemeGamma
        self.colorSchemeVibrance = settings.colorSchemeVibrance
        self.colorSchemeCurve = settings.colorSchemeCurve
        self.colorSchemeShadows = settings.colorSchemeShadows
        self.colorSchemeHighlights = settings.colorSchemeHighlights
        self.lightingSoftness = settings.lightingSoftness
        self.gradientPreset = settings.gradientPreset
        
        // Capture formula params for all types (unified path)
        let fp = settings.formulaParams
        var vals = [Float](repeating: 0, count: 16)
        for i in 0..<16 { vals[i] = FormulaCatalog.getParam(fp, index: i) }
        self.formulaParamValues = vals
    }
    
    /// Create with explicit values
    init(id: UUID = UUID(), name: String, duration: TimeInterval,
         minDistance: Float, foldingLimit: Float, sphereRadius: Float, fractalScale: Float,
         baseFractalIterations: Int = 9, baseMaxRaySteps: Int = 64,
            scale: Float = 1.0,
            position: SIMD3<Float>,
            detailScale: Float = 1.0,
            worldRotation: simd_quatf = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
            colorScheme: ColorScheme? = nil,
            lightingMode: LightingMode? = nil,
            lightingPreset: LightingPreset? = nil,
            hueRotationEffect: HueRotationEffect? = nil,
            pulseEffect: PulseEffect? = nil,
            glowEffect: GlowEffect? = nil,
            bloomEffect: BloomEffect? = nil,
            fogEffect: FogEffect? = nil,
            gradientCycleEffect: GradientCycleEffect? = nil,
         easingType: EasingFunction = .bezier, bezierHandle: BezierHandle = .easeInOut,
         formulaParamValues: [Float]? = nil) {
        self.id = id
        self.name = name
        self.duration = duration
        self.minDistance = minDistance
        self.foldingLimit = foldingLimit
        self.sphereRadius = sphereRadius
        self.fractalScale = fractalScale
        self.baseFractalIterations = baseFractalIterations
        self.baseMaxRaySteps = baseMaxRaySteps
        self.scale = scale
        self.positionX = position.x
        self.positionY = position.y
        self.positionZ = position.z
        self.detailScale = detailScale
        self.worldRotationX = worldRotation.imag.x
        self.worldRotationY = worldRotation.imag.y
        self.worldRotationZ = worldRotation.imag.z
        self.worldRotationW = worldRotation.real
        self.colorScheme = colorScheme
        self.lightingMode = lightingMode
        self.lightingPreset = lightingPreset
        self.hueRotationEffect = hueRotationEffect
        self.pulseEffect = pulseEffect
        self.glowEffect = glowEffect
        self.bloomEffect = bloomEffect
        self.fogEffect = fogEffect
        self.gradientCycleEffect = gradientCycleEffect
        self.easingType = easingType
        self.bezierHandle = bezierHandle
        self.formulaParamValues = formulaParamValues
    }
    
    /// Interpolate between two keyframes
    /// - Parameters:
    ///   - other: Target keyframe
    ///   - t: Progress 0...1
    /// - Returns: Interpolated keyframe (with this keyframe's id/name/duration)
    func interpolated(to other: AnimationKeyframe, t: Float) -> AnimationKeyframe {
        let clampedT = simd_clamp(t, 0, 1)
        
        // Linear interpolation helper
        func lerp(_ a: Float, _ b: Float) -> Float {
            return a + (b - a) * clampedT
        }
        
        func lerp3(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> {
            return a + (b - a) * clampedT
        }

        func pickDiscrete<T>(_ a: T?, _ b: T?) -> T? {
            clampedT < 0.5 ? a : b
        }

        func lerpHue(_ a: HueRotationEffect?, _ b: HueRotationEffect?) -> HueRotationEffect? {
            guard let a, let b else { return pickDiscrete(a, b) }
            return HueRotationEffect(enabled: clampedT < 0.5 ? a.enabled : b.enabled,
                                     speed: lerp(a.speed, b.speed),
                                     intensity: lerp(a.intensity, b.intensity))
        }

        func lerpPulse(_ a: PulseEffect?, _ b: PulseEffect?) -> PulseEffect? {
            guard let a, let b else { return pickDiscrete(a, b) }
            return PulseEffect(enabled: clampedT < 0.5 ? a.enabled : b.enabled,
                               speed: lerp(a.speed, b.speed),
                               amount: lerp(a.amount, b.amount))
        }

        func lerpGlow(_ a: GlowEffect?, _ b: GlowEffect?) -> GlowEffect? {
            guard let a, let b else { return pickDiscrete(a, b) }
            return GlowEffect(enabled: clampedT < 0.5 ? a.enabled : b.enabled,
                              intensity: lerp(a.intensity, b.intensity))
        }

        func lerpBloom(_ a: BloomEffect?, _ b: BloomEffect?) -> BloomEffect? {
            guard let a, let b else { return pickDiscrete(a, b) }
            return BloomEffect(enabled: clampedT < 0.5 ? a.enabled : b.enabled,
                               strength: lerp(a.strength, b.strength))
        }

        func lerpFog(_ a: FogEffect?, _ b: FogEffect?) -> FogEffect? {
            guard let a, let b else { return pickDiscrete(a, b) }
            return FogEffect(enabled: clampedT < 0.5 ? a.enabled : b.enabled,
                             intensity: lerp(a.intensity, b.intensity))
        }

        func lerpGradientCycle(_ a: GradientCycleEffect?, _ b: GradientCycleEffect?) -> GradientCycleEffect? {
            guard let a, let b else { return pickDiscrete(a, b) }
            return GradientCycleEffect(enabled: clampedT < 0.5 ? a.enabled : b.enabled,
                                       speed: lerp(a.speed, b.speed),
                                       smoothLoop: clampedT < 0.5 ? a.smoothLoop : b.smoothLoop)
        }
        
        func lerpFormulaParams(_ a: [Float]?, _ b: [Float]?) -> [Float]? {
            guard let a, let b, a.count == b.count else { return clampedT < 0.5 ? a : b }
            return zip(a, b).map { lerp($0, $1) }
        }
        
        var result = AnimationKeyframe(
            id: self.id,
            name: self.name,
            duration: self.duration,
            minDistance: lerp(self.minDistance, other.minDistance),
            foldingLimit: lerp(self.foldingLimit, other.foldingLimit),
            sphereRadius: lerp(self.sphereRadius, other.sphereRadius),
            fractalScale: lerp(self.fractalScale, other.fractalScale),
            baseFractalIterations: clampedT < 0.5 ? self.baseFractalIterations : other.baseFractalIterations,
            baseMaxRaySteps: clampedT < 0.5 ? self.baseMaxRaySteps : other.baseMaxRaySteps,
            scale: lerp(self.scale, other.scale),
            position: lerp3(self.position, other.position),
            detailScale: lerp(self.detailScale, other.detailScale),
            worldRotation: simd_slerp(self.worldRotation, other.worldRotation, clampedT).normalized,
            colorScheme: clampedT < 0.5 ? self.colorScheme : other.colorScheme,
            lightingMode: clampedT < 0.5 ? self.lightingMode : other.lightingMode,
            lightingPreset: clampedT < 0.5 ? self.lightingPreset : other.lightingPreset,
            hueRotationEffect: lerpHue(self.hueRotationEffect, other.hueRotationEffect),
            pulseEffect: lerpPulse(self.pulseEffect, other.pulseEffect),
            glowEffect: lerpGlow(self.glowEffect, other.glowEffect),
            bloomEffect: lerpBloom(self.bloomEffect, other.bloomEffect),
            fogEffect: lerpFog(self.fogEffect, other.fogEffect),
            gradientCycleEffect: lerpGradientCycle(self.gradientCycleEffect, other.gradientCycleEffect)
        )
        result.formulaParamValues = lerpFormulaParams(self.formulaParamValues, other.formulaParamValues)
        
        // Lerp per-keyframe color overrides (Float? fields)
        func lerpOpt(_ a: Float?, _ b: Float?) -> Float? {
            guard let a, let b else { return pickDiscrete(a, b) }
            return lerp(a, b)
        }
        result.colorMappingMode = pickDiscrete(self.colorMappingMode, other.colorMappingMode)
        result.gradientRepeat = lerpOpt(self.gradientRepeat, other.gradientRepeat)
        result.gradientOffset = lerpOpt(self.gradientOffset, other.gradientOffset)
        result.gradientSmoothing = lerpOpt(self.gradientSmoothing, other.gradientSmoothing)
        result.colorSchemeSaturation = lerpOpt(self.colorSchemeSaturation, other.colorSchemeSaturation)
        result.colorSchemeContrast = lerpOpt(self.colorSchemeContrast, other.colorSchemeContrast)
        result.colorSchemeGamma = lerpOpt(self.colorSchemeGamma, other.colorSchemeGamma)
        result.colorSchemeVibrance = lerpOpt(self.colorSchemeVibrance, other.colorSchemeVibrance)
        result.colorSchemeCurve = lerpOpt(self.colorSchemeCurve, other.colorSchemeCurve)
        result.colorSchemeShadows = lerpOpt(self.colorSchemeShadows, other.colorSchemeShadows)
        result.colorSchemeHighlights = lerpOpt(self.colorSchemeHighlights, other.colorSchemeHighlights)
        result.lightingSoftness = lerpOpt(self.lightingSoftness, other.lightingSoftness)
        result.gradientPreset = pickDiscrete(self.gradientPreset, other.gradientPreset)
        return result
    }

    // Backward-compatible coding support: old scenes may not contain detail transform keys.
    enum CodingKeys: String, CodingKey {
        case id, name, duration
        case minDistance, foldingLimit, sphereRadius, fractalScale
        case baseFractalIterations, baseMaxRaySteps
        case scale
        case positionX, positionY, positionZ
        case detailScale
        case worldRotationX, worldRotationY, worldRotationZ, worldRotationW
        case colorScheme, lightingMode, lightingPreset
        case hueRotationEffect, pulseEffect, glowEffect, bloomEffect, fogEffect, gradientCycleEffect
        case colorMappingMode = "colorMappingMode"
        case gradientRepeat = "gradientRepeat"
        case gradientOffset = "gradientOffset"
        case gradientSmoothing = "gradientSmoothing"
        case colorSchemeSaturation, colorSchemeContrast, colorSchemeGamma
        case colorSchemeVibrance, colorSchemeCurve, colorSchemeShadows, colorSchemeHighlights
        case lightingSoftness
        case gradientPreset = "gradientPreset"
        case formulaParamValues
        case easingType, bezierHandle
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.duration = try c.decode(TimeInterval.self, forKey: .duration)
        self.minDistance = try c.decode(Float.self, forKey: .minDistance)
        self.foldingLimit = try c.decode(Float.self, forKey: .foldingLimit)
        self.sphereRadius = try c.decode(Float.self, forKey: .sphereRadius)
        self.fractalScale = try c.decode(Float.self, forKey: .fractalScale)
        self.baseFractalIterations = try c.decode(Int.self, forKey: .baseFractalIterations)
        self.baseMaxRaySteps = try c.decode(Int.self, forKey: .baseMaxRaySteps)
        self.scale = try c.decodeIfPresent(Float.self, forKey: .scale) ?? 1.0
        self.positionX = try c.decode(Float.self, forKey: .positionX)
        self.positionY = try c.decode(Float.self, forKey: .positionY)
        self.positionZ = try c.decode(Float.self, forKey: .positionZ)

        self.detailScale = try c.decodeIfPresent(Float.self, forKey: .detailScale) ?? 1.0
        self.worldRotationX = try c.decodeIfPresent(Float.self, forKey: .worldRotationX) ?? 0.0
        self.worldRotationY = try c.decodeIfPresent(Float.self, forKey: .worldRotationY) ?? 0.0
        self.worldRotationZ = try c.decodeIfPresent(Float.self, forKey: .worldRotationZ) ?? 0.0
        self.worldRotationW = try c.decodeIfPresent(Float.self, forKey: .worldRotationW) ?? 1.0

        // Decode colorScheme: try ColorScheme (new string format) first,
        // fall back to raw Int (legacy integer format)
        if let scheme = try? c.decodeIfPresent(ColorScheme.self, forKey: .colorScheme) {
            self.colorScheme = scheme
        } else if let rawInt = try? c.decodeIfPresent(Int.self, forKey: .colorScheme),
                  let scheme = ColorScheme(rawValue: Int32(rawInt)) {
            self.colorScheme = scheme
        } else {
            self.colorScheme = nil
        }
        self.lightingMode = try c.decodeIfPresent(LightingMode.self, forKey: .lightingMode)
        self.lightingPreset = try c.decodeIfPresent(LightingPreset.self, forKey: .lightingPreset)
        self.hueRotationEffect = try c.decodeIfPresent(HueRotationEffect.self, forKey: .hueRotationEffect)
        self.pulseEffect = try c.decodeIfPresent(PulseEffect.self, forKey: .pulseEffect)
        self.glowEffect = try c.decodeIfPresent(GlowEffect.self, forKey: .glowEffect)
        self.bloomEffect = try c.decodeIfPresent(BloomEffect.self, forKey: .bloomEffect)
        self.fogEffect = try c.decodeIfPresent(FogEffect.self, forKey: .fogEffect)
        self.gradientCycleEffect = try c.decodeIfPresent(GradientCycleEffect.self, forKey: .gradientCycleEffect)
        self.colorMappingMode = try c.decodeIfPresent(ColorMappingMode.self, forKey: .colorMappingMode)
        self.gradientRepeat = try c.decodeIfPresent(Float.self, forKey: .gradientRepeat)
        self.gradientOffset = try c.decodeIfPresent(Float.self, forKey: .gradientOffset)
        self.gradientSmoothing = try c.decodeIfPresent(Float.self, forKey: .gradientSmoothing)
        self.colorSchemeSaturation = try c.decodeIfPresent(Float.self, forKey: .colorSchemeSaturation)
        self.colorSchemeContrast = try c.decodeIfPresent(Float.self, forKey: .colorSchemeContrast)
        self.colorSchemeGamma = try c.decodeIfPresent(Float.self, forKey: .colorSchemeGamma)
        self.colorSchemeVibrance = try c.decodeIfPresent(Float.self, forKey: .colorSchemeVibrance)
        self.colorSchemeCurve = try c.decodeIfPresent(Float.self, forKey: .colorSchemeCurve)
        self.colorSchemeShadows = try c.decodeIfPresent(Float.self, forKey: .colorSchemeShadows)
        self.colorSchemeHighlights = try c.decodeIfPresent(Float.self, forKey: .colorSchemeHighlights)
        self.lightingSoftness = try c.decodeIfPresent(Float.self, forKey: .lightingSoftness)
        self.gradientPreset = try c.decodeIfPresent(GradientPreset.self, forKey: .gradientPreset)
        self.formulaParamValues = try c.decodeIfPresent([Float].self, forKey: .formulaParamValues)

        self.easingType = try c.decodeIfPresent(EasingFunction.self, forKey: .easingType) ?? .bezier
        self.bezierHandle = try c.decodeIfPresent(BezierHandle.self, forKey: .bezierHandle) ?? .easeInOut
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(duration, forKey: .duration)
        try c.encode(minDistance, forKey: .minDistance)
        try c.encode(foldingLimit, forKey: .foldingLimit)
        try c.encode(sphereRadius, forKey: .sphereRadius)
        try c.encode(fractalScale, forKey: .fractalScale)
        try c.encode(baseFractalIterations, forKey: .baseFractalIterations)
        try c.encode(baseMaxRaySteps, forKey: .baseMaxRaySteps)
        try c.encode(scale, forKey: .scale)
        try c.encode(positionX, forKey: .positionX)
        try c.encode(positionY, forKey: .positionY)
        try c.encode(positionZ, forKey: .positionZ)
        try c.encode(detailScale, forKey: .detailScale)
        try c.encode(worldRotationX, forKey: .worldRotationX)
        try c.encode(worldRotationY, forKey: .worldRotationY)
        try c.encode(worldRotationZ, forKey: .worldRotationZ)
        try c.encode(worldRotationW, forKey: .worldRotationW)
        try c.encodeIfPresent(colorScheme, forKey: .colorScheme)
        try c.encodeIfPresent(lightingMode, forKey: .lightingMode)
        try c.encodeIfPresent(lightingPreset, forKey: .lightingPreset)
        try c.encodeIfPresent(hueRotationEffect, forKey: .hueRotationEffect)
        try c.encodeIfPresent(pulseEffect, forKey: .pulseEffect)
        try c.encodeIfPresent(glowEffect, forKey: .glowEffect)
        try c.encodeIfPresent(bloomEffect, forKey: .bloomEffect)
        try c.encodeIfPresent(fogEffect, forKey: .fogEffect)
        try c.encodeIfPresent(gradientCycleEffect, forKey: .gradientCycleEffect)
        try c.encodeIfPresent(colorMappingMode, forKey: .colorMappingMode)
        try c.encodeIfPresent(gradientRepeat, forKey: .gradientRepeat)
        try c.encodeIfPresent(gradientOffset, forKey: .gradientOffset)
        try c.encodeIfPresent(gradientSmoothing, forKey: .gradientSmoothing)
        try c.encodeIfPresent(colorSchemeSaturation, forKey: .colorSchemeSaturation)
        try c.encodeIfPresent(colorSchemeContrast, forKey: .colorSchemeContrast)
        try c.encodeIfPresent(colorSchemeGamma, forKey: .colorSchemeGamma)
        try c.encodeIfPresent(colorSchemeVibrance, forKey: .colorSchemeVibrance)
        try c.encodeIfPresent(colorSchemeCurve, forKey: .colorSchemeCurve)
        try c.encodeIfPresent(colorSchemeShadows, forKey: .colorSchemeShadows)
        try c.encodeIfPresent(colorSchemeHighlights, forKey: .colorSchemeHighlights)
        try c.encodeIfPresent(lightingSoftness, forKey: .lightingSoftness)
        try c.encodeIfPresent(gradientPreset, forKey: .gradientPreset)
        try c.encodeIfPresent(formulaParamValues, forKey: .formulaParamValues)
        try c.encode(easingType, forKey: .easingType)
        try c.encode(bezierHandle, forKey: .bezierHandle)
    }
}

// MARK: - Animation Scene

// MARK: - Song Attachment

/// A song linked to a scene so it auto-plays when the animation starts.
enum SongSource: String, Codable, Equatable {
    case appleMusic
    case spotify

    /// Map from a MusicServiceProvider.serviceID.
    init?(serviceID: String) {
        switch serviceID {
        case "appleMusic": self = .appleMusic
        case "spotify":    self = .spotify
        default:           return nil
        }
    }

    /// The corresponding MusicServiceProvider.serviceID.
    var serviceID: String { rawValue }
}

/// Persistable song reference attached to an animation scene.
///
/// Stores `trackIDs` — an **ordered** list of `UnifiedTrackID`s, one per
/// service where the song was found. The first element is the original
/// capture service; the rest are cross-matched alternatives. On playback
/// the system walks this list (reordered by the user's service priority)
/// until one succeeds.
///
/// Legacy fields `appleMusicID` and `spotifyURI` are kept for
/// backward-compatible decoding of scenes saved before the unification layer.
struct SongAttachment: Codable, Equatable {
    var source: SongSource
    var title: String
    var artist: String

    // ── Multi-service IDs (canonical) ─────────────────────────────────────
    /// Ordered list of service-specific identifiers for this song.
    /// The first entry is the original capture source. Additional entries
    /// are cross-matched alternatives for fallback playback.
    var trackIDs: [UnifiedTrackID]

    /// Convenience: the primary (first) track ID.
    var trackID: UnifiedTrackID { trackIDs[0] }

    /// All service IDs that have an identifier for this song.
    var availableServiceIDs: [String] { trackIDs.map(\.serviceID) }

    // ── Legacy fields (backward compat) ──────────────────────────────────
    var appleMusicID: String?
    var spotifyURI: String?

    // ── Primary initializer (multi-service) ──────────────────────────────
    init(trackIDs: [UnifiedTrackID], title: String, artist: String) {
        precondition(!trackIDs.isEmpty, "SongAttachment requires at least one trackID")
        self.trackIDs = trackIDs
        self.source = SongSource(serviceID: trackIDs[0].serviceID) ?? .appleMusic
        self.title = title
        self.artist = artist
        // Populate legacy fields for round-trip safety
        for tid in trackIDs {
            switch tid.serviceID {
            case "appleMusic": self.appleMusicID = tid.nativeID
            case "spotify":    self.spotifyURI   = tid.nativeID
            default: break
            }
        }
    }

    /// Convenience: single-ID initializer (delegates to multi-ID).
    init(trackID: UnifiedTrackID, title: String, artist: String) {
        self.init(trackIDs: [trackID], title: title, artist: artist)
    }

    // ── Legacy initializer (kept for existing callers) ────────────────
    init(source: SongSource, title: String, artist: String,
         appleMusicID: String?, spotifyURI: String?) {
        self.source = source
        self.title = title
        self.artist = artist
        self.appleMusicID = appleMusicID
        self.spotifyURI = spotifyURI
        // Build trackIDs from legacy fields
        var ids: [UnifiedTrackID] = []
        switch source {
        case .appleMusic:
            ids.append(UnifiedTrackID(serviceID: "appleMusic",
                                      nativeID: appleMusicID ?? ""))
            if let uri = spotifyURI, !uri.isEmpty {
                ids.append(UnifiedTrackID(serviceID: "spotify", nativeID: uri))
            }
        case .spotify:
            ids.append(UnifiedTrackID(serviceID: "spotify",
                                      nativeID: spotifyURI ?? ""))
            if let amid = appleMusicID, !amid.isEmpty {
                ids.append(UnifiedTrackID(serviceID: "appleMusic", nativeID: amid))
            }
        }
        self.trackIDs = ids
    }

    // ── Custom Codable for backward compatibility ──────────────────────
    enum CodingKeys: String, CodingKey {
        case source, title, artist, trackID, trackIDs
        case appleMusicID, spotifyURI
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decode(SongSource.self, forKey: .source)
        title  = try c.decode(String.self, forKey: .title)
        artist = try c.decode(String.self, forKey: .artist)
        appleMusicID = try c.decodeIfPresent(String.self, forKey: .appleMusicID)
        spotifyURI   = try c.decodeIfPresent(String.self, forKey: .spotifyURI)

        // 1) Prefer trackIDs array if present (new format)
        if let ids = try? c.decode([UnifiedTrackID].self, forKey: .trackIDs), !ids.isEmpty {
            trackIDs = ids
        }
        // 2) Fall back to single trackID (previous format)
        else if let tid = try? c.decode(UnifiedTrackID.self, forKey: .trackID) {
            trackIDs = [tid]
        }
        // 3) Synthesize from legacy fields (oldest format)
        else {
            var ids: [UnifiedTrackID] = []
            switch source {
            case .appleMusic:
                ids.append(UnifiedTrackID(serviceID: "appleMusic",
                                          nativeID: appleMusicID ?? ""))
            case .spotify:
                ids.append(UnifiedTrackID(serviceID: "spotify",
                                          nativeID: spotifyURI ?? ""))
            }
            trackIDs = ids
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(source, forKey: .source)
        try c.encode(title, forKey: .title)
        try c.encode(artist, forKey: .artist)
        try c.encode(trackIDs, forKey: .trackIDs)
        // Also write single trackID for forward compat with older builds
        try c.encode(trackID, forKey: .trackID)
        try c.encodeIfPresent(appleMusicID, forKey: .appleMusicID)
        try c.encodeIfPresent(spotifyURI, forKey: .spotifyURI)
    }
}

/// A scene is a sequence of keyframes that play in order.
/// Think of it like a CSS @keyframes animation.
struct AnimationScene: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var keyframes: [AnimationKeyframe]
    var isLooping: Bool
    var createdAt: Date
    var modifiedAt: Date
    
    /// The fractal type this scene was authored for.
    /// Restored on playback so the scene always renders with the correct fractal.
    var fractalType: FractalModelType?
    
    /// The color scheme this scene was authored for.
    /// Restored on playback so the scene always starts with the correct palette.
    var colorScheme: ColorScheme?
    
    // ═══════════════════════════════════════════════════════════════════════════
    // COLOR / GRADIENT — scene-level defaults (applied once at start)
    // Per-keyframe overrides can override these for individual segments.
    // ═══════════════════════════════════════════════════════════════════════════
    var gradientPreset: GradientPreset?
    var colorMappingMode: ColorMappingMode?
    var gradientRepeat: Float?
    var gradientOffset: Float?
    var gradientSmoothing: Float?
    var colorSchemeSaturation: Float?
    var colorSchemeContrast: Float?
    var colorSchemeGamma: Float?
    var colorSchemeVibrance: Float?
    var colorSchemeCurve: Float?
    var colorSchemeShadows: Float?
    var colorSchemeHighlights: Float?
    var lightingSoftness: Float?

    // ═══════════════════════════════════════════════════════════════════════════
    // SAFETY BUBBLE / BLEND WINDOW — scene-level settings
    // These are applied once when the scene starts playing, not interpolated.
    // ═══════════════════════════════════════════════════════════════════════════
    var safetyBubbleEnabled: Bool?
    var safetyBubbleRadius: Float?
    var safetyBubbleShape: Float?
    var safetyBubbleBlend: Float?
    
    /// Optional song that auto-plays when this scene starts
    var attachedSong: SongAttachment?
    
    /// Total duration of the scene (sum of all keyframe durations)
    var totalDuration: TimeInterval {
        keyframes.reduce(0) { $0 + $1.duration }
    }
    
    /// Create a new empty scene
    init(name: String = "New Scene") {
        self.id = UUID()
        self.name = name
        self.keyframes = []
        self.isLooping = true
        self.createdAt = Date()
        self.modifiedAt = Date()
    }
    
    /// Create a new empty scene with a specific ID (used for built-in defaults)
    init(id: UUID, name: String) {
        self.id = id
        self.name = name
        self.keyframes = []
        self.isLooping = true
        self.createdAt = Date()
        self.modifiedAt = Date()
    }
    
    /// Create scene with initial keyframe from current settings
    init(name: String, initialKeyframe: AnimationKeyframe, fractalType: FractalModelType? = nil) {
        self.id = UUID()
        self.name = name
        self.keyframes = [initialKeyframe]
        self.isLooping = true
        self.createdAt = Date()
        self.modifiedAt = Date()
        self.fractalType = fractalType
    }
    
    /// Add a keyframe from current settings
    mutating func addKeyframe(from settings: RenderSettings, duration: TimeInterval = 2.0) {
        let index = keyframes.count + 1
        var keyframe = AnimationKeyframe(from: settings, name: "Keyframe \(index)", duration: duration)
        
        // First keyframe should have 0 duration (starting point)
        if keyframes.isEmpty {
            keyframe.duration = 0
        }
        
        keyframes.append(keyframe)
        modifiedAt = Date()
    }
    
    /// Remove keyframe at index
    mutating func removeKeyframe(at index: Int) {
        guard keyframes.indices.contains(index) else { return }
        keyframes.remove(at: index)
        modifiedAt = Date()
    }
    
    /// Move keyframe from one index to another
    mutating func moveKeyframe(from source: IndexSet, to destination: Int) {
        keyframes.move(fromOffsets: source, toOffset: destination)
        modifiedAt = Date()
    }
}

// MARK: - Animation Playback State

/// Current state of animation playback
enum AnimationPlaybackState: Equatable {
    case stopped
    case playing
    case paused
}

/// Represents the current position in an animation
struct AnimationPlayhead {
    var sceneID: UUID?
    var currentKeyframeIndex: Int = 0
    var elapsedInSegment: TimeInterval = 0  // Time elapsed in current segment
    var state: AnimationPlaybackState = .stopped
    
    /// Progress through current segment (0...1)
    func segmentProgress(segmentDuration: TimeInterval) -> Float {
        guard segmentDuration > 0 else { return 1.0 }
        return Float(min(elapsedInSegment / segmentDuration, 1.0))
    }
    
    /// Reset to beginning
    mutating func reset() {
        currentKeyframeIndex = 0
        elapsedInSegment = 0
    }
}

// MARK: - Easing Functions

/// Easing functions for smooth interpolation
enum EasingFunction: String, Codable, CaseIterable {
    case linear
    case easeIn
    case easeOut
    case easeInOut
    case smooth  // Catmull-Rom spline - maintains velocity through keyframes
    case bezier  // Cubic Bezier - per-keyframe custom curves
    
    var displayName: String {
        switch self {
        case .linear: return "Linear"
        case .easeIn: return "Ease In"
        case .easeOut: return "Ease Out"
        case .easeInOut: return "Ease In/Out"
        case .smooth: return "Smooth (Spline)"
        case .bezier: return "Bezier Curve"
        }
    }
    
    var icon: String {
        switch self {
        case .linear: return "line.diagonal"
        case .easeIn: return "arrow.right"
        case .easeOut: return "arrow.down.right"
        case .easeInOut: return "arrow.left.and.right"
        case .smooth: return "waveform.path"
        case .bezier: return "point.topleft.down.to.point.bottomright.curvepath"
        }
    }
    
    /// Whether this easing uses spline interpolation (needs multiple keyframes)
    var usesSplineInterpolation: Bool {
        self == .smooth
    }
    
    /// Whether this easing uses per-keyframe Bezier handles
    var usesBezierHandles: Bool {
        self == .bezier
    }
    
    /// Apply the easing function to a linear t (0-1).
    /// For .bezier, use CubicBezier.evaluate() with the keyframe's handle instead.
    func apply(_ t: Float) -> Float {
        switch self {
        case .linear:
            return t
        case .easeIn:
            return t * t
        case .easeOut:
            return 1 - (1 - t) * (1 - t)
        case .easeInOut:
            return t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
        case .smooth:
            // For smooth mode, t is used directly in Catmull-Rom interpolation
            // This case shouldn't be called directly - see spline interpolation
            return t
        case .bezier:
            // Bezier needs a handle; fallback to easeInOut when called without one
            return CubicBezier.evaluate(t, handle: .easeInOut)
        }
    }
    
    /// Apply easing with a Bezier handle (used for per-keyframe curves)
    func apply(_ t: Float, bezierHandle: BezierHandle) -> Float {
        switch self {
        case .bezier:
            return CubicBezier.evaluate(t, handle: bezierHandle)
        default:
            return apply(t)
        }
    }
}

// MARK: - Catmull-Rom Spline Interpolation

/// Catmull-Rom spline interpolation for smooth continuous motion through keyframes.
/// Unlike standard easing which slows to a stop at each keyframe, Catmull-Rom
/// uses the surrounding keyframes to compute tangents, maintaining velocity continuity.
struct CatmullRomSpline {
    
    /// Tension parameter: 0.0 = Catmull-Rom, 0.5 = more relaxed curves
    /// Lower values = sharper turns, higher values = smoother curves
    static let tension: Float = 0.0
    
    /// Interpolate a single float value using Catmull-Rom spline
    /// - Parameters:
    ///   - p0: Value before the start point
    ///   - p1: Start point value
    ///   - p2: End point value
    ///   - p3: Value after the end point
    ///   - t: Progress 0...1 between p1 and p2
    /// - Returns: Interpolated value that smoothly passes through p1 and p2
    static func interpolate(_ p0: Float, _ p1: Float, _ p2: Float, _ p3: Float, t: Float) -> Float {
        let t2 = t * t
        let t3 = t2 * t
        
        // Catmull-Rom basis functions
        let a = -0.5 * p0 + 1.5 * p1 - 1.5 * p2 + 0.5 * p3
        let b = p0 - 2.5 * p1 + 2.0 * p2 - 0.5 * p3
        let c = -0.5 * p0 + 0.5 * p2
        let d = p1
        
        return a * t3 + b * t2 + c * t + d
    }
    
    /// Interpolate SIMD3 values using Catmull-Rom
    static func interpolate(_ p0: SIMD3<Float>, _ p1: SIMD3<Float>, 
                            _ p2: SIMD3<Float>, _ p3: SIMD3<Float>, t: Float) -> SIMD3<Float> {
        return SIMD3<Float>(
            interpolate(p0.x, p1.x, p2.x, p3.x, t: t),
            interpolate(p0.y, p1.y, p2.y, p3.y, t: t),
            interpolate(p0.z, p1.z, p2.z, p3.z, t: t)
        )
    }
    
    /// Interpolate between keyframes using surrounding keyframes for smooth motion
    /// - Parameters:
    ///   - keyframes: Array of all keyframes
    ///   - fromIndex: Current keyframe index (p1)
    ///   - toIndex: Next keyframe index (p2)
    ///   - t: Progress 0...1
    ///   - isLooping: Whether the animation loops
    /// - Returns: Smoothly interpolated keyframe
    static func interpolateKeyframes(_ keyframes: [AnimationKeyframe],
                                     fromIndex: Int,
                                     toIndex: Int,
                                     t: Float,
                                     isLooping: Bool) -> AnimationKeyframe {
        let count = keyframes.count
        guard count >= 2 else { 
            return keyframes.first ?? keyframes[fromIndex]
        }
        
        // Get the four keyframes for Catmull-Rom interpolation
        let p1 = keyframes[fromIndex]
        let p2 = keyframes[toIndex]
        
        // p0: point before p1
        let p0: AnimationKeyframe
        if fromIndex > 0 {
            p0 = keyframes[fromIndex - 1]
        } else if isLooping {
            p0 = keyframes[count - 1]  // Wrap to last keyframe
        } else {
            // Extrapolate: reflect p2 around p1
            p0 = extrapolateKeyframe(p1, away: p2)
        }
        
        // p3: point after p2
        let p3: AnimationKeyframe
        if toIndex < count - 1 {
            p3 = keyframes[toIndex + 1]
        } else if isLooping {
            p3 = keyframes[0]  // Wrap to first keyframe
        } else {
            // Extrapolate: reflect p1 around p2
            p3 = extrapolateKeyframe(p2, away: p1)
        }
        
        // Perform Catmull-Rom interpolation for each parameter
        return AnimationKeyframe(
            id: p1.id,
            name: p1.name,
            duration: p1.duration,
            minDistance: interpolate(p0.minDistance, p1.minDistance, p2.minDistance, p3.minDistance, t: t),
            foldingLimit: interpolate(p0.foldingLimit, p1.foldingLimit, p2.foldingLimit, p3.foldingLimit, t: t),
            sphereRadius: interpolate(p0.sphereRadius, p1.sphereRadius, p2.sphereRadius, p3.sphereRadius, t: t),
            fractalScale: interpolate(p0.fractalScale, p1.fractalScale, p2.fractalScale, p3.fractalScale, t: t),
            baseFractalIterations: t < 0.5 ? p1.baseFractalIterations : p2.baseFractalIterations,
            baseMaxRaySteps: t < 0.5 ? p1.baseMaxRaySteps : p2.baseMaxRaySteps,
            scale: interpolate(p0.scale, p1.scale, p2.scale, p3.scale, t: t),
            position: interpolate(p0.position, p1.position, p2.position, p3.position, t: t),
            detailScale: interpolate(p0.detailScale, p1.detailScale, p2.detailScale, p3.detailScale, t: t),
            worldRotation: simd_slerp(p1.worldRotation, p2.worldRotation, simd_clamp(t, 0, 1)).normalized,
            colorScheme: t < 0.5 ? p1.colorScheme : p2.colorScheme
        )
    }
    
    /// Create an extrapolated keyframe for smooth endpoints
    /// Reflects `away` keyframe around `anchor` to create a phantom point
    private static func extrapolateKeyframe(_ anchor: AnimationKeyframe, away: AnimationKeyframe) -> AnimationKeyframe {
        return AnimationKeyframe(
            id: UUID(),
            name: "phantom",
            duration: anchor.duration,
            minDistance: 2 * anchor.minDistance - away.minDistance,
            foldingLimit: 2 * anchor.foldingLimit - away.foldingLimit,
            sphereRadius: 2 * anchor.sphereRadius - away.sphereRadius,
            fractalScale: 2 * anchor.fractalScale - away.fractalScale,
            baseFractalIterations: anchor.baseFractalIterations,
            baseMaxRaySteps: anchor.baseMaxRaySteps,
            scale: 2 * anchor.scale - away.scale,
            position: 2 * anchor.position - away.position,
            detailScale: 2 * anchor.detailScale - away.detailScale,
            worldRotation: anchor.worldRotation,
            colorScheme: anchor.colorScheme
        )
    }
}

// MARK: - Default Scenes

/// Built-in scenes that ship with the app.
/// These can be hidden by the user but never truly deleted — only tucked away.
/// If a user edits one, their edited copy overlays the original.
enum DefaultScenes {
    
    /// Stable UUID so we can always identify the built-in scene across launches.
    static let sceneOneID = UUID(uuidString: "00000000-0001-0000-0000-000000000001")!
    static let ambientBlurID = UUID(uuidString: "00000000-0002-0000-0000-000000000002")!
    
    /// All default scene IDs for easy lookup
    static let allIDs: Set<UUID> = [ambientBlurID]
    
    /// Check whether a scene ID belongs to a built-in default
    static func isDefault(_ id: UUID) -> Bool {
        allIDs.contains(id)
    }
    
    // ─── Bundle-loaded default animations ────────────────────────────────
    // Default scenes are stored as .threshanim JSON files in
    // Examples/Animations (bundled as app resources). This keeps the
    // animation data in the same format as user exports and avoids
    // hardcoding hundreds of lines of keyframe construction in Swift.
    
    /// All built-in scenes, decoded once from bundled .threshanim files.
    private static let cachedScenes: [AnimationScene] = {
        let fileNames = ["Ambient_Blur"]  // Add more default scene filenames here
        var scenes: [AnimationScene] = []
        let decoder = JSONDecoder()
        for name in fileNames {
            guard let url = Bundle.main.url(forResource: name, withExtension: "threshanim") else {
                print("⚠️ DefaultScenes: missing bundled file \(name).threshanim")
                continue
            }
            do {
                let data = try Data(contentsOf: url)
                let scene = try decoder.decode(AnimationScene.self, from: data)
                scenes.append(scene)
            } catch {
                print("⚠️ DefaultScenes: failed to decode \(name).threshanim — \(error)")
            }
        }
        return scenes
    }()

    static func all() -> [AnimationScene] {
        cachedScenes
    }
}
