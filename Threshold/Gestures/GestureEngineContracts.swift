import Foundation
import simd

struct GestureFeatureFlags: Sendable {
    var useMenuToggleEngine: Bool = true
    var useArbitrationEngine: Bool = true
    var useModeEngines: Bool = false
}

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
    case setActiveGestureIndex(Int)
    case setGeometryGestureActive(Bool)
    case trackGestureUsage
}

protocol GestureEngine {
    associatedtype State
    func update(context: GestureContext) -> [GestureOperation]
}
