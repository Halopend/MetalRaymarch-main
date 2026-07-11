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

/// Per-forearm state for the arm-slider music gesture. The opposite hand's
/// index fingertip slides along the forearm (elbow→wrist); its normalized
/// position sets a music-reactivity value absolutely (elbow = min, wrist = max).
/// `value` is the smoothed normalized position; `engaged` gates writes and
/// drives persist-on-release.
struct ArmSliderHandState {
    var engaged: Bool = false
    var value: Float = 0
    var hasValue: Bool = false
}

struct ArmSliderGestureState {
    var left = ArmSliderHandState()   // left forearm  → music intensity
    var right = ArmSliderHandState()  // right forearm → music dampening
}
