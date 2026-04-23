import Foundation

/// Right-hand ring-finger-to-palm "hold" gesture that toggles the
/// Animation Player window. Mirrors `MenuToggleGestureEngine`'s shape and
/// reuses the same hold/cooldown/threshold tuning from `RenderSettings`,
/// but is independent of the menu toggle so both can coexist.
///
/// Strength is selective (`max(0, ring - middle)`) so curling all fingers
/// doesn't trigger this and the menu's middle-to-palm gesture simultaneously.
@MainActor
final class AnimationPlayerToggleGestureEngine {
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
            return []
        }

        guard context.rightHand.isTracked else {
            state.isActive = false
            state.holdTimer = 0
            return []
        }

        let strength = max(
            0,
            context.rightHand.ringFingerTouchingPalm() - context.rightHand.middleFingerTouchingPalm()
        )
        let baseActivate = settings.menuToggleActivateThreshold
        let baseRelease = min(settings.menuToggleReleaseThreshold, baseActivate - 0.05)
        let activate = baseActivate
        let release = baseRelease - 0.05

        let shouldBeActive: Bool = state.isActive
            ? (strength >= release)
            : (strength >= activate)

        if shouldBeActive {
            if !state.isActive {
                state.holdTimer += context.deltaTime
                if state.cooldown <= 0, state.holdTimer >= settings.menuToggleHoldDuration {
                    state.isActive = true
                    state.holdTimer = 0
                    state.cooldown = settings.menuToggleCooldown
                    return [.toggleAnimationPlayer]
                }
            }
        } else {
            state.isActive = false
            state.holdTimer = 0
        }

        return []
    }
}
