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

// MARK: - Animation Keyframe

/// A single keyframe capturing shape parameters at a point in time.
/// Duration represents how long to animate FROM the previous keyframe TO this one.
struct AnimationKeyframe: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var duration: TimeInterval  // Seconds to reach this keyframe from previous (0 for first keyframe)
    
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
        
        self.colorScheme = nil
    }
    
    /// Create with explicit values
    init(id: UUID = UUID(), name: String, duration: TimeInterval,
         minDistance: Float, foldingLimit: Float, sphereRadius: Float, fractalScale: Float,
         baseFractalIterations: Int = 9, baseMaxRaySteps: Int = 64,
         position: SIMD3<Float>, colorScheme: Int? = nil) {
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
    
    var displayName: String {
        switch self {
        case .linear: return "Linear"
        case .easeIn: return "Ease In"
        case .easeOut: return "Ease Out"
        case .easeInOut: return "Ease In/Out"
        case .smooth: return "Smooth (Spline)"
        }
    }
    
    /// Whether this easing uses spline interpolation (needs multiple keyframes)
    var usesSplineInterpolation: Bool {
        self == .smooth
    }
    
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
