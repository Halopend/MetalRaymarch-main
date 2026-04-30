import Foundation

@MainActor
final class MenuToggleGestureEngine {
    private static let activationDebounceFrames = 2

    var state = MenuToggleGestureState()
    #if DEBUG
    private var debugFrameCounter: Int = 0
    #endif

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

        let mode = settings.menuToggleGestureMode

        // Wrist tap requires both hands; other modes require right hand only
        if mode.requiresBothHands {
            guard context.leftHand.isTracked, context.rightHand.isTracked else {
                state.isActive = false
                state.holdTimer = 0
                state.consecutiveFramesAboveActivate = 0
                return []
            }
        } else {
            guard context.rightHand.isTracked else {
                state.isActive = false
                state.holdTimer = 0
                state.consecutiveFramesAboveActivate = 0
                return []
            }
        }

        let strength = menuToggleStrength(for: mode, context: context)
        let thresholds = menuToggleThresholds(for: mode, settings: settings)

        #if DEBUG
        debugFrameCounter += 1
        if debugFrameCounter >= 90, strength > 0.1 {
            debugFrameCounter = 0
            print("🎛️ MenuToggle[\(mode.displayName)] str=\(String(format: "%.2f", strength)) act=\(String(format: "%.2f", thresholds.activate)) rel=\(String(format: "%.2f", thresholds.release)) active=\(state.isActive) hold=\(String(format: "%.2f", state.holdTimer)) cd=\(String(format: "%.2f", state.cooldown))")
        }
        #endif

        let shouldBeActive: Bool = state.isActive
            ? (strength >= thresholds.release)
            : (strength >= thresholds.activate)

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
                    return [.toggleMenu]
                }
            }
        } else {
            state.isActive = false
            state.holdTimer = 0
            state.consecutiveFramesAboveActivate = 0
        }

        return []
    }

    private func menuToggleStrength(for mode: MenuToggleGestureMode, context: GestureContext) -> Float {
        switch mode {
        case .middleToPalm:
            // Selective: middle touching palm, with a deadzone so sympathetic ring
            // movement (which naturally accompanies a middle curl) doesn't kill the
            // signal. Only a clearly-curled ring (>0.4) penalizes, which is what
            // distinguishes this from the animation-player ring-to-palm gesture.
            let middle = context.rightHand.middleFingerTouchingPalm()
            let ring = context.rightHand.ringFingerTouchingPalm()
            return max(0, middle - max(0, ring - 0.4))
        case .middleAndRingToPalm:
            return min(context.rightHand.middleFingerTouchingPalm(), context.rightHand.ringFingerTouchingPalm())
        case .fist:
            return context.rightHand.fistStrength()
        case .wristTap:
            // Use whichever wrist is being tapped by the other hand (max of both directions)
            let leftTapsRight = context.rightHand.wristTapStrength(otherHand: context.leftHand)
            let rightTapsLeft = context.leftHand.wristTapStrength(otherHand: context.rightHand)
            return max(leftTapsRight, rightTapsLeft)
        case .thumbToIndexPalmUp:
            return context.rightHand.thumbToIndexPalmUpStrength()
        case .ringToPalm:
            // Selective with deadzone — mirror of middleToPalm. Only a clearly-curled
            // middle (>0.4) penalizes ring strength.
            let ring = context.rightHand.ringFingerTouchingPalm()
            let middle = context.rightHand.middleFingerTouchingPalm()
            return max(0, ring - max(0, middle - 0.4))
        case .middleOrRingToPalm:
            // Easy-open mode: either middle OR ring touching palm can open the menu.
            // Use selective per-finger strengths to avoid cross-talk from sympathetic curl.
            let middle = context.rightHand.middleFingerTouchingPalm()
            let ring = context.rightHand.ringFingerTouchingPalm()
            let selectiveMiddle = max(0, middle - max(0, ring - 0.4))
            let selectiveRing = max(0, ring - max(0, middle - 0.4))
            return max(selectiveMiddle, selectiveRing)
        }
    }

    private func menuToggleThresholds(for mode: MenuToggleGestureMode, settings: RenderSettings) -> (activate: Float, release: Float) {
        let baseActivate = settings.menuToggleActivateThreshold
        let baseRelease = min(settings.menuToggleReleaseThreshold, baseActivate - 0.05)

        switch mode {
        case .middleToPalm:
            // No offset — the default threshold is already tuned for middle-to-palm.
            // Lower release threshold so the finger must fully extend before re-arming.
            return (activate: baseActivate, release: baseRelease - 0.05)
        case .middleAndRingToPalm:
            return (activate: baseActivate, release: baseRelease)
        case .fist:
            return (activate: min(0.90, baseActivate + 0.08), release: min(0.85, baseRelease + 0.05))
        case .wristTap:
            // Wrist tap needs a higher threshold to avoid accidental triggers
            return (activate: min(0.90, baseActivate + 0.10), release: min(0.85, baseRelease + 0.10))
        case .thumbToIndexPalmUp:
            // Combined pinch + orientation, moderate thresholds
            return (activate: baseActivate + 0.05, release: baseRelease + 0.05)
        case .ringToPalm:
            // Mirror middle-to-palm tuning. Selective math already prevents overlap
            // with the animation-player (middle-to-palm) gesture.
            return (activate: baseActivate, release: baseRelease - 0.05)
        case .middleOrRingToPalm:
            return (activate: baseActivate, release: baseRelease - 0.05)
        }
    }
}
