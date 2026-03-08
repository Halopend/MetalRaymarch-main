//
//  GestureConfig.swift
//  Threshold
//
//  Domain config: gesture bindings, thresholds, and tuning.
//  Part of the RenderSettings decomposition (Phase 1).
//

import Foundation

struct GestureConfig: Codable, Equatable, Sendable {
    // 9-slot gesture binding dictionary (hand × finger)
    var gestureBindings: [String: GestureActionBinding] = GestureConfig.defaultBindings

    // Sensitivity & smoothing
    var gestureSensitivity: Float = 5.0          // 1.0 - 10.0
    var gestureSmoothingFactor: Float = 0.5      // 0.0 - 1.0
    var useRelativeGestures: Bool = false
    var extendedGestureRange: Bool = false
    var translationSensitivity: Float = 1.0      // 0.2 - 3.0

    // Rotation auto-snap
    var rotationAutoSnap: Bool = false
    var rotationSnapWindowDegrees: Float = 6.0   // 1.0 - 30.0
    var rotationBreakawayDegrees: Float = 10.0   // 0.0 - 45.0

    // Menu toggle gesture
    var menuToggleGestureEnabled: Bool = true
    var menuToggleGestureMode: MenuToggleGestureMode = .middleToPalm
    var menuToggleHoldDuration: Float = 0.15     // 0.05 - 0.6
    var menuToggleCooldown: Float = 0.5          // 0.1 - 2.5
    var menuToggleActivateThreshold: Float = 0.6 // 0.2 - 0.95
    var menuToggleReleaseThreshold: Float = 0.3  // 0.1 - 0.9

    // Two-hand pinch thresholds
    var twoHandPinchActivateThreshold: Float = 0.7   // 0.2 - 0.98
    var twoHandPinchReleaseThreshold: Float = 0.3    // 0.1 - 0.95

    // Ring pinch thresholds
    var ringPinchActivateThreshold: Float = 0.55     // 0.1 - 0.95
    var ringPinchReleaseThreshold: Float = 0.25      // 0.05 - 0.9

    // Hand distance limits
    var gestureMinHandDistance: Float = 0.06     // 0.02 - 0.25
    var gestureMaxHandDistance: Float = 0.5      // 0.2 - 1.2
    var gestureMaxStartHandDistance: Float = 0.35    // 0.08 - 1.0
    var gestureMaxActiveHandDistance: Float = 0.75   // 0.1 - 1.5

    // MARK: - Defaults

    static let defaultBindings: [String: GestureActionBinding] = [
        GestureSlot(hand: .right, finger: .index).persistenceKey: .core(.translate),
        GestureSlot(hand: .right, finger: .middle).persistenceKey: .core(.none),
        GestureSlot(hand: .right, finger: .ring).persistenceKey: .core(.none),
        GestureSlot(hand: .left, finger: .index).persistenceKey: .core(.none),
        GestureSlot(hand: .left, finger: .middle).persistenceKey: .core(.none),
        GestureSlot(hand: .left, finger: .ring).persistenceKey: .core(.none),
        GestureSlot(hand: .both, finger: .index).persistenceKey: .core(.grab),
        GestureSlot(hand: .both, finger: .middle).persistenceKey: .core(.minDistance),
        GestureSlot(hand: .both, finger: .ring).persistenceKey: .core(.fractalScale),
    ]

    // MARK: - Validation

    mutating func clamp() {
        gestureSensitivity = max(1.0, min(10.0, gestureSensitivity))
        gestureSmoothingFactor = max(0.0, min(1.0, gestureSmoothingFactor))
        translationSensitivity = max(0.2, min(3.0, translationSensitivity))
        rotationSnapWindowDegrees = max(1.0, min(30.0, rotationSnapWindowDegrees))
        rotationBreakawayDegrees = max(0.0, min(45.0, rotationBreakawayDegrees))
        menuToggleHoldDuration = max(0.05, min(0.6, menuToggleHoldDuration))
        menuToggleCooldown = max(0.1, min(2.5, menuToggleCooldown))
        menuToggleActivateThreshold = max(0.2, min(0.95, menuToggleActivateThreshold))
        menuToggleReleaseThreshold = max(0.1, min(0.9, menuToggleReleaseThreshold))
        twoHandPinchActivateThreshold = max(0.2, min(0.98, twoHandPinchActivateThreshold))
        twoHandPinchReleaseThreshold = max(0.1, min(0.95, twoHandPinchReleaseThreshold))
        ringPinchActivateThreshold = max(0.1, min(0.95, ringPinchActivateThreshold))
        ringPinchReleaseThreshold = max(0.05, min(0.9, ringPinchReleaseThreshold))
        gestureMinHandDistance = max(0.02, min(0.25, gestureMinHandDistance))
        gestureMaxHandDistance = max(gestureMinHandDistance + 0.05, min(1.2, gestureMaxHandDistance))
        gestureMaxStartHandDistance = max(0.08, min(1.0, gestureMaxStartHandDistance))
        gestureMaxActiveHandDistance = max(gestureMaxStartHandDistance, min(1.5, gestureMaxActiveHandDistance))
    }
}
