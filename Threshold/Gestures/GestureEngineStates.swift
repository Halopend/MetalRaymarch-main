import Foundation
import simd

struct MenuToggleGestureState {
    var isActive: Bool = false
    var holdTimer: Float = 0
    var cooldown: Float = 0
}

struct TwoPointGrabGestureState {
    var isActive: Bool = false
    var endCooldown: Float = 0
    var mapping: GrabZoomMapping?
    var originalAxis: SIMD3<Float> = .zero
    var rotationBrokenAway: Bool = false
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
    var accumulatedPosition: SIMD3<Float> = .zero
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
