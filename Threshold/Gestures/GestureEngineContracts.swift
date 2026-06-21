import Foundation
import simd

struct GestureContext {
    var leftHand: HandData
    var rightHand: HandData
    var leftHandStable: Bool
    var suppressParameterGestures: Bool
    var deltaTime: Float
    var ranges: GestureParamRanges
    var frameIndex: UInt64
}

enum GestureOperation {
    case toggleMenu
    case toggleAnimationPlayer
    case openShapeMenu
    case openRenderMenu
    case setActiveGestureIndex(Int)
    case setGeometryGestureActive(Bool)
    case trackGestureUsage
}
