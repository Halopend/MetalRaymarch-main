import Foundation
import simd

struct MenuToggleGestureState {
    var isActive: Bool = false
    var holdTimer: Float = 0
    var cooldown: Float = 0
    var consecutiveFramesAboveActivate: Int = 0
}

struct TwoPointGrabGestureState {
    var isActive: Bool = false
    var endCooldown: Float = 0
    var mapping: GrabZoomMapping?
}

struct TwoHandScalarEngineState {
    var perDigit: [Int: TwoHandGestureState] = [
        1: TwoHandGestureState(),
        2: TwoHandGestureState(),
        3: TwoHandGestureState(),
    ]
}

struct SingleHandDragPerSlotState {
    var isActive: Bool = false
    var prevPos: SIMD3<Float> = .zero
    var prevPalm: SIMD3<Float> = .zero
    var startValues: SIMD3<Float> = .zero
    var startValue: Float = 0
}

struct SingleHandDragEngineState {
    var perSlot: [String: SingleHandDragPerSlotState] = [:]
    var accumulatedPosition: SIMD3<Float> = .zero
}

struct WindowPullGestureState {
    var isActive: Bool = false
    var startPalmPosition: SIMD3<Float> = .zero
    var hasTriggered: Bool = false
    var cooldown: Float = 0
}

/// Per-hand tracking for the open-palm "bat through the air" scene swipe.
/// The anchor marks where the current fast sideways sweep began; it re-anchors
/// whenever the hand slows down or reverses direction.
struct SceneSwipeHandState {
    var hasAnchor: Bool = false
    var anchor: SIMD3<Float> = .zero
    var anchorAge: Float = 0
    var prevPalm: SIMD3<Float> = .zero
    var hasPrev: Bool = false

    mutating func clearAnchor() {
        hasAnchor = false
        anchorAge = 0
    }
}

struct SceneSwipeGestureState {
    var left = SceneSwipeHandState()
    var right = SceneSwipeHandState()
    var cooldown: Float = 0
}
