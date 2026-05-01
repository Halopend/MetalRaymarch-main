//
//  GestureDefaults.swift
//  Threshold
//
//  Single source of truth for gesture defaults and valid ranges.
//

import Foundation

enum GestureDefaults {
    // MARK: - Navigation mode
    static let useSpringBlob = false

    // MARK: - Sensitivity & smoothing
    static let gestureSensitivity: Float = 5.0
    static let useRelativeGestures = false
    static let extendedGestureRange = false
    static let translationSensitivity: Float = 1.0

    // MARK: - Rotation auto-snap
    static let rotationAutoSnap = false
    static let rotationSnapWindowDegrees: Float = 6.0
    static let rotationBreakawayDegrees: Float = 10.0

    // MARK: - Menu toggle gesture
    static let menuToggleGestureEnabled = true
    static let menuToggleGestureMode: MenuToggleGestureMode = .middleOrRingToPalm
    static let menuToggleHoldDuration: Float = 0.08
    static let menuToggleCooldown: Float = 0.4
    static let menuToggleActivateThreshold: Float = 0.44
    static let menuToggleReleaseThreshold: Float = 0.24

    // MARK: - Pinch thresholds
    static let twoHandPinchActivateThreshold: Float = 0.7
    static let twoHandPinchReleaseThreshold: Float = 0.3
    static let ringPinchActivateThreshold: Float = 0.55
    static let ringPinchReleaseThreshold: Float = 0.25

    // MARK: - Hand distance limits
    static let gestureMinHandDistance: Float = 0.06
    static let gestureMaxHandDistance: Float = 0.5
    static let gestureMaxStartHandDistance: Float = 0.35
    static let gestureMaxActiveHandDistance: Float = 0.75

    // MARK: - Ranges
    static let gestureSensitivityRange: ClosedRange<Float> = 1.0...10.0
    static let translationSensitivityRange: ClosedRange<Float> = 0.2...3.0
    static let rotationSnapWindowDegreesRange: ClosedRange<Float> = 1.0...30.0
    static let rotationBreakawayDegreesRange: ClosedRange<Float> = 0.0...45.0
    static let menuToggleHoldDurationRange: ClosedRange<Float> = 0.05...0.6
    static let menuToggleCooldownRange: ClosedRange<Float> = 0.1...2.5
    static let menuToggleActivateThresholdRange: ClosedRange<Float> = 0.2...0.95
    static let menuToggleReleaseThresholdRange: ClosedRange<Float> = 0.1...0.9
    static let twoHandPinchActivateThresholdRange: ClosedRange<Float> = 0.2...0.98
    static let twoHandPinchReleaseThresholdRange: ClosedRange<Float> = 0.1...0.95
    static let ringPinchActivateThresholdRange: ClosedRange<Float> = 0.1...0.95
    static let ringPinchReleaseThresholdRange: ClosedRange<Float> = 0.05...0.9
    static let gestureMinHandDistanceRange: ClosedRange<Float> = 0.02...0.25
    static let gestureMaxHandDistanceUpperBound: Float = 1.2
    static let gestureMaxHandDistanceDeltaFromMin: Float = 0.05
    static let gestureMaxStartHandDistanceRange: ClosedRange<Float> = 0.08...1.0
    static let gestureMaxActiveHandDistanceUpperBound: Float = 1.5

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
}
