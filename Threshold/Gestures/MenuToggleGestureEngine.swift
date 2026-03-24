import Foundation

@MainActor
final class MenuToggleGestureEngine {
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

        let strength = menuToggleStrength(for: settings.menuToggleGestureMode, hand: context.rightHand)
        let thresholds = menuToggleThresholds(for: settings.menuToggleGestureMode, settings: settings)

        let shouldBeActive: Bool = state.isActive
            ? (strength >= thresholds.release)
            : (strength >= thresholds.activate)

        if shouldBeActive {
            if !state.isActive {
                state.holdTimer += context.deltaTime
                if state.cooldown <= 0, state.holdTimer >= settings.menuToggleHoldDuration {
                    state.isActive = true
                    state.holdTimer = 0
                    state.cooldown = settings.menuToggleCooldown
                    return [.toggleMenu]
                }
            }
        } else {
            state.isActive = false
            state.holdTimer = 0
        }

        return []
    }

    private func menuToggleStrength(for mode: MenuToggleGestureMode, hand: HandData) -> Float {
        switch mode {
        case .middleToPalm:
            return hand.middleFingerTouchingPalm()
        case .middleAndRingToPalm:
            return min(hand.middleFingerTouchingPalm(), hand.ringFingerTouchingPalm())
        case .fist:
            return hand.fistStrength()
        }
    }

    private func menuToggleThresholds(for mode: MenuToggleGestureMode, settings: RenderSettings) -> (activate: Float, release: Float) {
        let baseActivate = settings.menuToggleActivateThreshold
        let baseRelease = min(settings.menuToggleReleaseThreshold, baseActivate - 0.05)

        switch mode {
        case .middleToPalm:
            return (activate: baseActivate + 0.02, release: baseRelease + 0.02)
        case .middleAndRingToPalm:
            return (activate: baseActivate, release: baseRelease)
        case .fist:
            return (activate: min(0.96, baseActivate + 0.18), release: min(0.92, baseRelease + 0.15))
        }
    }
}
