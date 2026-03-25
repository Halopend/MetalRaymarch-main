import Foundation
import simd

/// Lean animation types used after legacy scene-system cleanup.
enum EasingFunction: String, Codable, CaseIterable {
    case linear
    case smooth

    var displayName: String {
        switch self {
        case .linear: return "Linear"
        case .smooth: return "Smooth"
        }
    }
}

struct AnimationKeyframe: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var duration: TimeInterval
    var minDistance: Float
    var foldingLimit: Float
    var sphereRadius: Float
    var fractalScale: Float
    var position: SIMD3<Float>

    init(name: String,
         duration: TimeInterval,
         minDistance: Float,
         foldingLimit: Float,
         sphereRadius: Float,
         fractalScale: Float,
         position: SIMD3<Float>) {
        self.name = name
        self.duration = duration
        self.minDistance = minDistance
        self.foldingLimit = foldingLimit
        self.sphereRadius = sphereRadius
        self.fractalScale = fractalScale
        self.position = position
    }

    init(from settings: RenderSettings, name: String = "Keyframe", duration: TimeInterval = 2.0) {
        self.init(
            name: name,
            duration: duration,
            minDistance: settings.targetMinDistance,
            foldingLimit: settings.targetFoldingLimit,
            sphereRadius: settings.targetSphereRadius,
            fractalScale: settings.fractalScale,
            position: settings.targetPosition
        )
    }
}

struct AttachedSong: Codable, Equatable {
    var trackID: String
}

struct AnimationScene: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var keyframes: [AnimationKeyframe] = []
    var fractalType: FractalModelType? = nil
    var attachedSong: AttachedSong? = nil

    init(name: String, initialKeyframe: AnimationKeyframe? = nil, fractalType: FractalModelType? = nil) {
        self.name = name
        self.fractalType = fractalType
        if let initialKeyframe {
            self.keyframes = [initialKeyframe]
        }
    }

    mutating func addKeyframe(from settings: RenderSettings, duration: TimeInterval = 2.0) {
        keyframes.append(AnimationKeyframe(from: settings, name: "Keyframe \(keyframes.count + 1)", duration: duration))
    }

    var totalDuration: TimeInterval {
        max(0, keyframes.dropFirst().reduce(0) { $0 + max(0, $1.duration) })
    }
}

enum PlaybackState: String, Codable {
    case stopped
    case playing
    case paused
}

struct AnimationPlayhead: Codable, Equatable {
    var state: PlaybackState = .stopped
    var currentKeyframeIndex: Int = 0
    var elapsedInSegment: TimeInterval = 0
}

enum AnimationError: Error, Equatable, CustomStringConvertible {
    case sceneNotFound

    var description: String {
        switch self {
        case .sceneNotFound: return "Animation scene not found."
        }
    }
}

enum DefaultAnimationScenes {
    static func all() -> [AnimationScene] { [] }
}
