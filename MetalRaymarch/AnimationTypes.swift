//
//  AnimationTypes.swift
//  MetalRaymarch
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
    
    // Position in 3D space
    var positionX: Float
    var positionY: Float
    var positionZ: Float
    
    var position: SIMD3<Float> {
        get { SIMD3<Float>(positionX, positionY, positionZ) }
        set {
            positionX = newValue.x
            positionY = newValue.y
            positionZ = newValue.z
        }
    }
    
    // ═══════════════════════════════════════════════════════════════════════════
    // OPTIONAL: Visual parameters (can be animated too)
    // ═══════════════════════════════════════════════════════════════════════════
    
    var colorScheme: Int?  // nil = don't change color scheme during animation
    
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
        
        // Capture position
        self.positionX = settings.position.x
        self.positionY = settings.position.y
        self.positionZ = settings.position.z
        
        self.colorScheme = Int(settings.colorScheme.rawValue)
    }
    
    /// Create with explicit values
    init(id: UUID = UUID(), name: String, duration: TimeInterval,
         minDistance: Float, foldingLimit: Float, sphereRadius: Float, fractalScale: Float,
         baseFractalIterations: Int = 9, baseMaxRaySteps: Int = 64,
         position: SIMD3<Float>, colorScheme: Int? = nil,
         easingType: EasingFunction = .bezier, bezierHandle: BezierHandle = .easeInOut) {
        self.id = id
        self.name = name
        self.duration = duration
        self.minDistance = minDistance
        self.foldingLimit = foldingLimit
        self.sphereRadius = sphereRadius
        self.fractalScale = fractalScale
        self.baseFractalIterations = baseFractalIterations
        self.baseMaxRaySteps = baseMaxRaySteps
        self.positionX = position.x
        self.positionY = position.y
        self.positionZ = position.z
        self.colorScheme = colorScheme
        self.easingType = easingType
        self.bezierHandle = bezierHandle
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
        
        return AnimationKeyframe(
            id: self.id,
            name: self.name,
            duration: self.duration,
            minDistance: lerp(self.minDistance, other.minDistance),
            foldingLimit: lerp(self.foldingLimit, other.foldingLimit),
            sphereRadius: lerp(self.sphereRadius, other.sphereRadius),
            fractalScale: lerp(self.fractalScale, other.fractalScale),
            baseFractalIterations: clampedT < 0.5 ? self.baseFractalIterations : other.baseFractalIterations,
            baseMaxRaySteps: clampedT < 0.5 ? self.baseMaxRaySteps : other.baseMaxRaySteps,
            position: lerp3(self.position, other.position),
            colorScheme: clampedT < 0.5 ? self.colorScheme : other.colorScheme
        )
    }
}

// MARK: - Animation Scene

/// A scene is a sequence of keyframes that play in order.
/// Think of it like a CSS @keyframes animation.
struct AnimationScene: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var keyframes: [AnimationKeyframe]
    var isLooping: Bool
    var createdAt: Date
    var modifiedAt: Date
    
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
    init(name: String, initialKeyframe: AnimationKeyframe) {
        self.id = UUID()
        self.name = name
        self.keyframes = [initialKeyframe]
        self.isLooping = true
        self.createdAt = Date()
        self.modifiedAt = Date()
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
            position: interpolate(p0.position, p1.position, p2.position, p3.position, t: t),
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
            position: 2 * anchor.position - away.position,
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
    
    /// All default scene IDs for easy lookup
    static let allIDs: Set<UUID> = [sceneOneID]
    
    /// Check whether a scene ID belongs to a built-in default
    static func isDefault(_ id: UUID) -> Bool {
        allIDs.contains(id)
    }
    
    // ─── Scene One ───────────────────────────────────────────────────────
    
    /// A gentle introductory animation that showcases the fractal opening
    /// and closing through several interesting parameter states.
    static func sceneOne() -> AnimationScene {
        var scene = AnimationScene(id: sceneOneID, name: "Scene One")
        scene.isLooping = true
        scene.keyframes = [
            AnimationKeyframe(
                name: "Origin",
                duration: 0,
                minDistance: 0.8,
                foldingLimit: 1.0,
                sphereRadius: 0.5,
                fractalScale: 2.8,
                position: .zero,
                easingType: .bezier,
                bezierHandle: .easeInOut
            ),
            AnimationKeyframe(
                name: "Unfold",
                duration: 4.0,
                minDistance: 1.6,
                foldingLimit: 2.5,
                sphereRadius: 0.7,
                fractalScale: 2.4,
                position: SIMD3<Float>(0.05, 0.02, 0.0),
                easingType: .bezier,
                bezierHandle: .easeInOut
            ),
            AnimationKeyframe(
                name: "Deep",
                duration: 3.5,
                minDistance: 0.5,
                foldingLimit: 0.8,
                sphereRadius: 0.35,
                fractalScale: 3.0,
                position: SIMD3<Float>(0.0, 0.04, 0.03),
                easingType: .bezier,
                bezierHandle: .easeOut
            ),
            AnimationKeyframe(
                name: "Bloom",
                duration: 4.0,
                minDistance: 2.0,
                foldingLimit: 4.0,
                sphereRadius: 1.0,
                fractalScale: 2.2,
                position: SIMD3<Float>(-0.03, 0.0, 0.02),
                easingType: .bezier,
                bezierHandle: .easeInOut
            ),
            AnimationKeyframe(
                name: "Return",
                duration: 3.5,
                minDistance: 0.8,
                foldingLimit: 1.0,
                sphereRadius: 0.5,
                fractalScale: 2.8,
                position: .zero,
                easingType: .bezier,
                bezierHandle: .easeIn
            ),
        ]
        return scene
    }
    
    /// All built-in scenes (add more here in the future)
    static func all() -> [AnimationScene] {
        [sceneOne()]
    }
}
