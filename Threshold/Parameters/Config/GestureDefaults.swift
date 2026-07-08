//
//  GestureDefaults.swift
//  Threshold
//
//  Single source of truth for gesture defaults.
//
//  The sensitivity / smoothing / threshold / hand-distance values below are no
//  longer user-adjustable — the gesture engines read these constants directly.
//

import Foundation

enum GestureDefaults {
    // MARK: - Parameter gestures
    /// Relative (delta-from-start) vs absolute parameter gestures.
    static let useRelativeGestures = true
    /// Gesture sensitivity (1-10, where 1 = 10x slower, 10 = normal speed).
    static let gestureSensitivity: Float = 5.0
    /// Single-hand translate sensitivity multiplier.
    static let translationSensitivity: Float = 1.0
    /// Smoothing time (seconds) for the critically-damped spring that eases
    /// gesture-driven parameter changes toward their targets.
    static let gestureSmoothing: Float = 0.35

    // MARK: - Menu toggle gesture
    static let menuToggleGestureEnabled = true
    static let menuToggleGestureMode: MenuToggleGestureMode = .middleOrRingToPalm
    static let menuToggleHoldDuration: Float = 0.08
    static let menuToggleCooldown: Float = 0.4
    static let menuToggleActivateThreshold: Float = 0.44
    static let menuToggleReleaseThreshold: Float = 0.24

    // MARK: - Per-finger tap-to-palm gesture layer
    static let perFingerTapGestureEnabled = true
    static let perFingerTapLeftActions: [PerFingerTapAction] = [.none, .none, .none, .openShapeMenu, .openRenderMenu]
    static let perFingerTapRightActions: [PerFingerTapAction] = [.none, .none, .toggleMenu, .openQuickToggles, .none]
    static let perFingerTapActivateThreshold: Float = 0.55
    static let perFingerTapReleaseThreshold: Float = 0.25
    static let perFingerTapHoldDuration: Float = 0.08
    static let perFingerTapCooldown: Float = 0.4

    // MARK: - Arm slider (opposite-hand fingertip slides along forearm → music strength)
    /// Left forearm sets music intensity, right forearm sets music dampening.
    /// Position along elbow→wrist maps absolutely (elbow = min, wrist/hand = max).
    /// Minimum forearm length (meters) for a usable slide; below this the arm is
    /// too foreshortened to track a position reliably.
    static let armSliderMinForearmLength: Float = 0.12
    /// Perpendicular distance (meters) from the fingertip to the forearm line to
    /// ENGAGE the slider (must be close to the arm to start).
    static let armSliderEngageRadius: Float = 0.05
    /// Looser distance (meters) to stay engaged once started (hysteresis).
    static let armSliderReleaseRadius: Float = 0.09
    /// Per-frame exponential smoothing toward the touched position (0..1).
    static let armSliderSmoothing: Float = 0.35
    /// Full-slide (wrist end) music-dampening value; intensity uses its own 0…1 range.
    static let armSliderDampingMax: Float = 3.0

    // MARK: - Two-hand pinch thresholds
    static let twoHandPinchActivateThreshold: Float = 0.7
    static let twoHandPinchReleaseThreshold: Float = 0.3
    static let ringPinchActivateThreshold: Float = 0.55
    static let ringPinchReleaseThreshold: Float = 0.25

    // MARK: - Hand distance limits
    static let gestureMinHandDistance: Float = 0.06
    static let gestureMaxHandDistance: Float = 0.5
    static let gestureMaxStartHandDistance: Float = 0.35
    static let gestureMaxActiveHandDistance: Float = 0.75

    // MARK: - Ranges (only the per-finger-tap layer is still clamped)
    static let perFingerTapActivateThresholdRange: ClosedRange<Float> = 0.2...0.95
    static let perFingerTapReleaseThresholdRange: ClosedRange<Float> = 0.1...0.9
    static let perFingerTapHoldDurationRange: ClosedRange<Float> = 0.05...0.6
    static let perFingerTapCooldownRange: ClosedRange<Float> = 0.1...2.5

    // MARK: - Gesture bindings defaults
    static let defaultBindings: [String: GestureActionBinding] = [
        // Single-hand vertical (legacy keys — backward compatible)
        GestureSlot(hand: .right, finger: .index, direction: .vertical).persistenceKey: .core(.translate),
        GestureSlot(hand: .right, finger: .middle, direction: .vertical).persistenceKey: .core(.none),
        GestureSlot(hand: .right, finger: .ring, direction: .vertical).persistenceKey: .core(.none),
        GestureSlot(hand: .left, finger: .index, direction: .vertical).persistenceKey: .core(.none),
        GestureSlot(hand: .left, finger: .middle, direction: .vertical).persistenceKey: .core(.none),
        GestureSlot(hand: .left, finger: .ring, direction: .vertical).persistenceKey: .core(.none),
        // Single-hand horizontal (new directional slots)
        GestureSlot(hand: .right, finger: .index, direction: .horizontal).persistenceKey: .core(.none),
        GestureSlot(hand: .right, finger: .middle, direction: .horizontal).persistenceKey: .core(.none),
        GestureSlot(hand: .right, finger: .ring, direction: .horizontal).persistenceKey: .core(.none),
        GestureSlot(hand: .left, finger: .index, direction: .horizontal).persistenceKey: .core(.none),
        GestureSlot(hand: .left, finger: .middle, direction: .horizontal).persistenceKey: .core(.none),
        GestureSlot(hand: .left, finger: .ring, direction: .horizontal).persistenceKey: .core(.none),
        // Both-hand (no direction — these use pull-apart geometry)
        GestureSlot(hand: .both, finger: .index).persistenceKey: .core(.grab),
        GestureSlot(hand: .both, finger: .middle).persistenceKey: .core(.minDistance),
        GestureSlot(hand: .both, finger: .ring).persistenceKey: .core(.fractalScale),
    ]

    // MARK: - Persistence helpers for per-finger tap actions

    static func loadPerFingerTapActions(keyPrefix: String) -> [PerFingerTapAction] {
        var actions: [PerFingerTapAction] = []
        for finger in 0..<5 {
            let key = "\(keyPrefix)_\(finger)"
            if let raw = UserDefaults.standard.object(forKey: key) as? Int32,
               let action = PerFingerTapAction(rawValue: raw) {
                actions.append(action)
            } else {
                // Fall back to default based on prefix
                let defaults = keyPrefix.contains("Left") ? perFingerTapLeftActions : perFingerTapRightActions
                actions.append(defaults[finger])
            }
        }
        return actions
    }

    static func savePerFingerTapActions(_ actions: [PerFingerTapAction], keyPrefix: String) {
        for (finger, action) in actions.enumerated() {
            let key = "\(keyPrefix)_\(finger)"
            UserDefaults.standard.set(action.rawValue, forKey: key)
        }
    }
}
