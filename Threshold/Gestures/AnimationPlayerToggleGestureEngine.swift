import Foundation

/// Right-hand middle-finger-to-palm "hold" gesture that toggles the
/// Animation Player window. Mirrors `MenuToggleGestureEngine`'s shape and
/// reuses the same hold/cooldown/threshold tuning from `RenderSettings`,
/// but is independent of the menu toggle so both can coexist.
///
/// Strength is selective (`max(0, middle - ring)`) so curling all fingers
/// doesn't trigger this and the menu's easy-open OR mode remains distinct.
@MainActor
final class AnimationPlayerToggleGestureEngine {
    private static let activationThreshold: Float = 0.44
    private static let releaseThreshold: Float = 0.24
    private static let activationDebounceFrames = 2

    var state = MenuToggleGestureState()

    func reset() {
        state = MenuToggleGestureState()
    }

    func process(context: GestureContext, settings: RenderSettings) -> [GestureOperation] {
        if state.cooldown > 0 {
            state.cooldown = max(0, state.cooldown - context.deltaTime)
        }

        guard settings.menuToggleGestureEnabled else {
            state.isActive = false
            state.holdTimer = 0
            state.consecutiveFramesAboveActivate = 0
            return []
        }

        guard context.rightHand.isTracked else {
            state.isActive = false
            state.holdTimer = 0
            state.consecutiveFramesAboveActivate = 0
            return []
        }

        let middle = context.rightHand.middleFingerTouchingPalm()
        let ring = context.rightHand.ringFingerTouchingPalm()
        let strength = max(0, middle - max(0, ring - 0.4))

        let shouldBeActive: Bool = state.isActive
            ? (strength >= Self.releaseThreshold)
            : (strength >= Self.activationThreshold)

        if shouldBeActive {
            if !state.isActive {
                state.consecutiveFramesAboveActivate += 1
                if state.consecutiveFramesAboveActivate >= Self.activationDebounceFrames {
                    state.holdTimer += context.deltaTime
                }
                if state.cooldown <= 0, state.holdTimer >= settings.menuToggleHoldDuration {
                    state.isActive = true
                    state.holdTimer = 0
                    state.cooldown = settings.menuToggleCooldown
                    state.consecutiveFramesAboveActivate = 0
                    return [.toggleAnimationPlayer]
                }
            }
        } else {
            state.isActive = false
            state.holdTimer = 0
            state.consecutiveFramesAboveActivate = 0
        }

        return []
    }
}
