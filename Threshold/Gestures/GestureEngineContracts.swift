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
    let processingDurationNanoseconds: UInt64
}

/// Lock-safe renderer changes produced by gesture recognition. Keeping these
/// as values makes the processor independent of the render host and lets the
/// render-side worker apply a whole gesture frame without a MainActor hop.
enum GestureRenderMutation: Sendable {
    case applyGrab(GrabTransform)
    case translatePosition(SIMD3<Float>)
    case setFractalAudioAmount(Float)
    case setFractalAudioDamping(Float)
    case persistAudioReactive
}

extension GestureRenderMutation {
    func apply(to settings: RenderSettings) {
        switch self {
        case .applyGrab(let transform):
            if settings.isAnimationPlaying {
                settings.manualOffsetPosition =
                    transform.position - settings.animationBasePosition
                settings.manualRotationOffset =
                    transform.rotation * settings.animationBaseWorldRotation.inverse
                settings.manualOffsetDetailScale =
                    transform.detailScale - settings.animationBaseDetailScale
                settings.worldRotation = transform.rotation
                settings.targetWorldRotation = transform.rotation
                settings.detailScale = transform.detailScale
                settings.targetDetailScale = transform.detailScale
            } else {
                settings.applyDetailState(
                    position: transform.position,
                    worldRotation: transform.rotation,
                    detailScale: transform.detailScale,
                    responsiveness: 1
                )
            }
        case .translatePosition(let delta):
            if settings.isAnimationPlaying {
                settings.manualOffsetPosition += delta
            } else {
                settings.targetPosition += delta
            }
        case .setFractalAudioAmount(let value):
            settings.setFractalAudioAmountLive(value)
        case .setFractalAudioDamping(let value):
            settings.setFractalAudioDampingLive(value)
        case .persistAudioReactive:
            settings.persistAudioReactiveNow()
        }
    }
}

struct GestureOutput: Sendable {
    var parameterOperations: [ParameterOperation] = []
    var renderMutations: [GestureRenderMutation] = []
    var commands: [AppCommand] = []
    var menuActivationHand: GestureHandMode?
    var diagnostics: GestureDiagnostics
    var didUseGesture = false
}
