import Foundation
import simd

struct GestureContext: Sendable {
    var leftHand: HandData
    var rightHand: HandData
    var deltaTime: Float
}

enum GestureOperation: Equatable, Sendable {
    case toggleMenu
    case toggleAnimationPlayer
    case openShapeMenu
    case openRenderMenu
    case openQuickToggles
    case trackGestureUsage
}

struct GestureDiagnostics: Sendable {
    let leftTracked: Bool
    let rightTracked: Bool
    let activeGestureIndex: Int
    let parametersSuppressed: Bool
}

struct GestureOutput: Sendable {
    var commands: [AppCommand] = []
    var diagnostics: GestureDiagnostics
    var didUseGesture = false
}
