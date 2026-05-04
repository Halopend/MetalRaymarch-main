import Foundation

/// Per-finger tap-to-palm gesture engine.
/// Each finger (thumb, index, middle, ring, pinky) can be independently assigned
/// an action that fires when that finger taps the palm.  Actions are mutually
/// exclusive — only one finger can trigger per hand per frame, and the strongest
/// tap wins.  The engine supports both left and right hands independently.
///
/// This replaces the monolithic menu-toggle gesture with a configurable layer
/// where any finger on either hand can be mapped to toggle the menu, control
/// playback, or perform other discrete actions.
@MainActor
final class PerFingerTapGestureEngine {
    private static let menuGestureSafetyDelay: Float = 0.75

    // MARK: - Configuration

    /// Which action each finger performs when tapped to palm.
    /// Indexed by hand (0=left, 1=right) and finger (0=thumb…4=pinky).
    var leftHandActions: [PerFingerTapAction] = Array(repeating: .none, count: 5)
    var rightHandActions: [PerFingerTapAction] = Array(repeating: .none, count: 5)

    /// Global enable / disable for the entire per-finger tap layer.
    var isEnabled: Bool = true

    /// Activation threshold (0…1) — finger must be this close to palm to trigger.
    var activateThreshold: Float = 0.55
    /// Release threshold (0…1) — finger must drop below this to re-arm.
    var releaseThreshold: Float = 0.25
    /// Minimum time (seconds) the finger must stay touching palm before firing.
    var holdDuration: Float = 0.08
    /// Cooldown (seconds) after a tap before any finger on that hand can fire again.
    var cooldown: Float = 0.4

    // MARK: - State

    private var leftState = PerHandTapState()
    private var rightState = PerHandTapState()

    func reset() {
        leftState = PerHandTapState()
        rightState = PerHandTapState()
    }

    // MARK: - Processing

    func process(context: GestureContext) -> [GestureOperation] {
        guard isEnabled else { return [] }

        var ops: [GestureOperation] = []

        // Process each hand independently
        if context.leftHand.isTracked {
            leftState.deltaTime = context.deltaTime
            ops.append(contentsOf: processHand(
                hand: context.leftHand,
                actions: leftHandActions,
                state: &leftState
            ))
        } else {
            leftState.resetTrackingState()
        }

        if context.rightHand.isTracked {
            rightState.deltaTime = context.deltaTime
            ops.append(contentsOf: processHand(
                hand: context.rightHand,
                actions: rightHandActions,
                state: &rightState
            ))
        } else {
            rightState.resetTrackingState()
        }

        return ops
    }

    // MARK: - Per-Hand Logic

    private func processHand(
        hand: HandData,
        actions: [PerFingerTapAction],
        state: inout PerHandTapState
    ) -> [GestureOperation] {
        // Tick cooldown
        if state.cooldown > 0 {
            state.cooldown = max(0, state.cooldown - state.deltaTime)
        }
        state.tickMenuSafetyDelay(deltaTime: state.deltaTime)

        // Compute tap strength for every finger
        let strengths: [Float] = (0..<5).map { finger in
            tapStrength(for: finger, hand: hand, action: actions[finger])
        }

        // Find the strongest finger that is above threshold and has a non-.none action
        var bestFinger: Int? = nil
        var bestStrength: Float = 0
        for finger in 0..<5 {
            guard actions[finger] != .none else { continue }
            guard !state.isMenuGestureCoolingDown(finger: finger, action: actions[finger]) else { continue }
            let s = strengths[finger]
            let threshold = state.isActive[finger] ? releaseThreshold : activateThreshold
            if s >= threshold, s > bestStrength {
                bestStrength = s
                bestFinger = finger
            }
        }

        // If no finger qualifies, clear all active flags and timers
        guard let winningFinger = bestFinger else {
            for i in 0..<5 {
                state.isActive[i] = false
                state.holdTimer[i] = 0
                state.consecutiveFrames[i] = 0
            }
            return []
        }

        // Winner-takes-all: only the winning finger can progress
        for i in 0..<5 where i != winningFinger {
            state.isActive[i] = false
            state.holdTimer[i] = 0
            state.consecutiveFrames[i] = 0
        }

        // Progress the winning finger
        if !state.isActive[winningFinger] {
            state.consecutiveFrames[winningFinger] += 1
            if state.consecutiveFrames[winningFinger] >= 2 {
                state.holdTimer[winningFinger] += state.deltaTime
            }
            if state.cooldown > 0 { return [] }
            if state.holdTimer[winningFinger] >= holdDuration {
                state.isActive[winningFinger] = true
                state.holdTimer[winningFinger] = 0
                state.cooldown = cooldown
                state.consecutiveFrames[winningFinger] = 0
                state.armMenuSafetyDelayIfNeeded(
                    finger: winningFinger,
                    action: actions[winningFinger],
                    delay: Self.menuGestureSafetyDelay
                )
                return [actions[winningFinger].gestureOperation]
            }
        }

        return []
    }

    private func tapStrength(for finger: Int, hand: HandData, action: PerFingerTapAction) -> Float {
        switch finger {
        case 0:
            return hand.thumbTouchingPalm()
        case 1:
            return hand.indexFingerTouchingPalm()
        case 2:
            return hand.middleFingerTouchingPalm()
        case 3:
            if action == .openShapeMenu {
                return max(hand.ringFingerTouchingPalm(), hand.ringFingerTouchingWrist())
            }
            return hand.ringFingerTouchingPalm()
        case 4:
            return hand.pinkyFingerTouchingPalm()
        default:
            return 0
        }
    }
}

// MARK: - Supporting Types

enum PerFingerTapAction: Int32, CaseIterable, Codable, Hashable, Sendable {
    case none         = 0
    case toggleMenu   = 1
    case toggleAnimationPlayer = 2
    case openShapeMenu = 3
    case openRenderMenu = 4

    var displayName: String {
        switch self {
        case .none:         return "None"
        case .toggleMenu:   return "Toggle Menu"
        case .toggleAnimationPlayer: return "Toggle Video Playback"
        case .openShapeMenu: return "Open Shape Menu"
        case .openRenderMenu: return "Open Render Menu"
        }
    }

    var icon: String {
        switch self {
        case .none:         return "xmark.circle"
        case .toggleMenu:   return "menucard"
        case .toggleAnimationPlayer: return "film.stack"
        case .openShapeMenu: return "square.grid.2x2"
        case .openRenderMenu: return "camera.aperture"
        }
    }

    var gestureOperation: GestureOperation {
        switch self {
        case .none:         return .trackGestureUsage // no-op
        case .toggleMenu:   return .toggleMenu
        case .toggleAnimationPlayer: return .toggleAnimationPlayer
        case .openShapeMenu: return .openShapeMenu
        case .openRenderMenu: return .openRenderMenu
        }
    }
}

/// Mutable state tracked per hand for the tap-to-palm engine.
private struct PerHandTapState {
    var isActive: [Bool] = Array(repeating: false, count: 5)
    var holdTimer: [Float] = Array(repeating: 0, count: 5)
    var cooldown: Float = 0
    var consecutiveFrames: [Int] = Array(repeating: 0, count: 5)
    var menuSafetyDelay: [Float] = Array(repeating: 0, count: 5)
    var deltaTime: Float = 1.0 / 90.0

    mutating func tickMenuSafetyDelay(deltaTime: Float) {
        for index in menuSafetyDelay.indices {
            if menuSafetyDelay[index] > 0 {
                menuSafetyDelay[index] = max(0, menuSafetyDelay[index] - deltaTime)
            }
        }
    }

    func isMenuGestureCoolingDown(finger: Int, action: PerFingerTapAction) -> Bool {
        action.isMenuEssentialAction && menuSafetyDelay[finger] > 0
    }

    mutating func armMenuSafetyDelayIfNeeded(finger: Int, action: PerFingerTapAction, delay: Float) {
        guard action.isMenuEssentialAction else { return }
        menuSafetyDelay[finger] = delay
    }

    mutating func resetTrackingState() {
        isActive = Array(repeating: false, count: 5)
        holdTimer = Array(repeating: 0, count: 5)
        consecutiveFrames = Array(repeating: 0, count: 5)
    }

    mutating func reset() {
        resetTrackingState()
        cooldown = 0
    }
}
