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
        
        // Capture position
        self.positionX = settings.position.x
        self.positionY = settings.position.y
        self.positionZ = settings.position.z
        
        self.colorScheme = nil
    }
    
    /// Create with explicit values
    init(id: UUID = UUID(), name: String, duration: TimeInterval,
         minDistance: Float, foldingLimit: Float, sphereRadius: Float, fractalScale: Float,
         position: SIMD3<Float>, colorScheme: Int? = nil) {
        self.id = id
        self.name = name
        self.duration = duration
        self.minDistance = minDistance
        self.foldingLimit = foldingLimit
        self.sphereRadius = sphereRadius
        self.fractalScale = fractalScale
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
        }
    }
}
