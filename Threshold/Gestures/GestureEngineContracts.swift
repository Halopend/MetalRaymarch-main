import Foundation
import simd

struct GestureContext {
    var leftHand: HandData
    var rightHand: HandData
    var deltaTime: Float
}

enum GestureOperation {
    case toggleMenu
    case toggleAnimationPlayer
    case openShapeMenu
    case openRenderMenu
    case openQuickToggles
    case trackGestureUsage
}
