//
//  GestureConfig.swift
//  Threshold
//
//  Domain config: gesture bindings, thresholds, and tuning.
//  Part of the RenderSettings decomposition (Phase 1).
//

import Foundation

struct GestureConfig: Codable, Equatable, Sendable {
    // 15-slot gesture binding dictionary (hand × finger × direction)
    var gestureBindings: [String: GestureActionBinding] = GestureDefaults.defaultBindings

    // Navigation mode
    var useSpringBlob: Bool = GestureDefaults.useSpringBlob

    // Sensitivity & smoothing
    var gestureSensitivity: Float = GestureDefaults.gestureSensitivity
    /// Time-smoothing for gesture-driven parameter changes (seconds).
    var gestureSmoothing: Float = GestureDefaults.gestureSmoothing
    var menuAndMovementOnly: Bool = GestureDefaults.menuAndMovementOnly
    var useRelativeGestures: Bool = GestureDefaults.useRelativeGestures
    var extendedGestureRange: Bool = GestureDefaults.extendedGestureRange
    var translationSensitivity: Float = GestureDefaults.translationSensitivity

    // Rotation auto-snap
    var rotationAutoSnap: Bool = GestureDefaults.rotationAutoSnap
    var rotationSnapWindowDegrees: Float = GestureDefaults.rotationSnapWindowDegrees
    var rotationBreakawayDegrees: Float = GestureDefaults.rotationBreakawayDegrees

    // Menu toggle gesture
    var menuToggleGestureEnabled: Bool = GestureDefaults.menuToggleGestureEnabled
    var menuToggleGestureMode: MenuToggleGestureMode = GestureDefaults.menuToggleGestureMode
    var menuToggleHoldDuration: Float = GestureDefaults.menuToggleHoldDuration
    var menuToggleCooldown: Float = GestureDefaults.menuToggleCooldown
    var menuToggleActivateThreshold: Float = GestureDefaults.menuToggleActivateThreshold
    var menuToggleReleaseThreshold: Float = GestureDefaults.menuToggleReleaseThreshold

    // Per-finger tap-to-palm gesture layer
    var perFingerTapGestureEnabled: Bool = GestureDefaults.perFingerTapGestureEnabled
    var perFingerTapLeftActions: [PerFingerTapAction] = GestureDefaults.perFingerTapLeftActions
    var perFingerTapRightActions: [PerFingerTapAction] = GestureDefaults.perFingerTapRightActions
    var perFingerTapActivateThreshold: Float = GestureDefaults.perFingerTapActivateThreshold
    var perFingerTapReleaseThreshold: Float = GestureDefaults.perFingerTapReleaseThreshold
    var perFingerTapHoldDuration: Float = GestureDefaults.perFingerTapHoldDuration
    var perFingerTapCooldown: Float = GestureDefaults.perFingerTapCooldown

    // Two-hand pinch thresholds
    var twoHandPinchActivateThreshold: Float = GestureDefaults.twoHandPinchActivateThreshold
    var twoHandPinchReleaseThreshold: Float = GestureDefaults.twoHandPinchReleaseThreshold

    // Ring pinch thresholds
    var ringPinchActivateThreshold: Float = GestureDefaults.ringPinchActivateThreshold
    var ringPinchReleaseThreshold: Float = GestureDefaults.ringPinchReleaseThreshold

    // Hand distance limits
    var gestureMinHandDistance: Float = GestureDefaults.gestureMinHandDistance
    var gestureMaxHandDistance: Float = GestureDefaults.gestureMaxHandDistance
    var gestureMaxStartHandDistance: Float = GestureDefaults.gestureMaxStartHandDistance
    var gestureMaxActiveHandDistance: Float = GestureDefaults.gestureMaxActiveHandDistance

    // MARK: - Validation

    mutating func clamp() {
        gestureSensitivity = gestureSensitivity.clamped(to: GestureDefaults.gestureSensitivityRange)
        gestureSmoothing = gestureSmoothing.clamped(to: GestureDefaults.gestureSmoothingRange)
        translationSensitivity = translationSensitivity.clamped(to: GestureDefaults.translationSensitivityRange)
        rotationSnapWindowDegrees = rotationSnapWindowDegrees.clamped(to: GestureDefaults.rotationSnapWindowDegreesRange)
        rotationBreakawayDegrees = rotationBreakawayDegrees.clamped(to: GestureDefaults.rotationBreakawayDegreesRange)
        menuToggleHoldDuration = menuToggleHoldDuration.clamped(to: GestureDefaults.menuToggleHoldDurationRange)
        menuToggleCooldown = menuToggleCooldown.clamped(to: GestureDefaults.menuToggleCooldownRange)
        menuToggleActivateThreshold = menuToggleActivateThreshold.clamped(to: GestureDefaults.menuToggleActivateThresholdRange)
        menuToggleReleaseThreshold = menuToggleReleaseThreshold.clamped(to: GestureDefaults.menuToggleReleaseThresholdRange)
        perFingerTapActivateThreshold = perFingerTapActivateThreshold.clamped(to: GestureDefaults.perFingerTapActivateThresholdRange)
        perFingerTapReleaseThreshold = perFingerTapReleaseThreshold.clamped(to: GestureDefaults.perFingerTapReleaseThresholdRange)
        perFingerTapHoldDuration = perFingerTapHoldDuration.clamped(to: GestureDefaults.perFingerTapHoldDurationRange)
        perFingerTapCooldown = perFingerTapCooldown.clamped(to: GestureDefaults.perFingerTapCooldownRange)
        twoHandPinchActivateThreshold = twoHandPinchActivateThreshold.clamped(to: GestureDefaults.twoHandPinchActivateThresholdRange)
        twoHandPinchReleaseThreshold = twoHandPinchReleaseThreshold.clamped(to: GestureDefaults.twoHandPinchReleaseThresholdRange)
        ringPinchActivateThreshold = ringPinchActivateThreshold.clamped(to: GestureDefaults.ringPinchActivateThresholdRange)
        ringPinchReleaseThreshold = ringPinchReleaseThreshold.clamped(to: GestureDefaults.ringPinchReleaseThresholdRange)
        gestureMinHandDistance = gestureMinHandDistance.clamped(to: GestureDefaults.gestureMinHandDistanceRange)
        gestureMaxHandDistance = max(
            gestureMinHandDistance + GestureDefaults.gestureMaxHandDistanceDeltaFromMin,
            min(GestureDefaults.gestureMaxHandDistanceUpperBound, gestureMaxHandDistance)
        )
        gestureMaxStartHandDistance = gestureMaxStartHandDistance.clamped(to: GestureDefaults.gestureMaxStartHandDistanceRange)
        gestureMaxActiveHandDistance = max(
            gestureMaxStartHandDistance,
            min(GestureDefaults.gestureMaxActiveHandDistanceUpperBound, gestureMaxActiveHandDistance)
        )
    }
}

// Custom Decodable init in extension so the memberwise initializer is preserved.
// Every field uses decodeIfPresent so any config written by an older (or newer,
// field-removed) build still decodes, falling back to the default for missing
// keys instead of throwing and discarding the user's entire gesture config.
extension GestureConfig {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        gestureBindings = try c.decodeIfPresent([String: GestureActionBinding].self, forKey: .gestureBindings) ?? GestureDefaults.defaultBindings
        useSpringBlob = try c.decodeIfPresent(Bool.self, forKey: .useSpringBlob) ?? GestureDefaults.useSpringBlob
        gestureSensitivity = try c.decodeIfPresent(Float.self, forKey: .gestureSensitivity) ?? GestureDefaults.gestureSensitivity
        gestureSmoothing = try c.decodeIfPresent(Float.self, forKey: .gestureSmoothing) ?? GestureDefaults.gestureSmoothing
        menuAndMovementOnly = try c.decodeIfPresent(Bool.self, forKey: .menuAndMovementOnly) ?? GestureDefaults.menuAndMovementOnly
        useRelativeGestures = try c.decodeIfPresent(Bool.self, forKey: .useRelativeGestures) ?? GestureDefaults.useRelativeGestures
        extendedGestureRange = try c.decodeIfPresent(Bool.self, forKey: .extendedGestureRange) ?? GestureDefaults.extendedGestureRange
        translationSensitivity = try c.decodeIfPresent(Float.self, forKey: .translationSensitivity) ?? GestureDefaults.translationSensitivity
        rotationAutoSnap = try c.decodeIfPresent(Bool.self, forKey: .rotationAutoSnap) ?? GestureDefaults.rotationAutoSnap
        rotationSnapWindowDegrees = try c.decodeIfPresent(Float.self, forKey: .rotationSnapWindowDegrees) ?? GestureDefaults.rotationSnapWindowDegrees
        rotationBreakawayDegrees = try c.decodeIfPresent(Float.self, forKey: .rotationBreakawayDegrees) ?? GestureDefaults.rotationBreakawayDegrees
        menuToggleGestureEnabled = try c.decodeIfPresent(Bool.self, forKey: .menuToggleGestureEnabled) ?? GestureDefaults.menuToggleGestureEnabled
        menuToggleGestureMode = try c.decodeIfPresent(MenuToggleGestureMode.self, forKey: .menuToggleGestureMode) ?? GestureDefaults.menuToggleGestureMode
        menuToggleHoldDuration = try c.decodeIfPresent(Float.self, forKey: .menuToggleHoldDuration) ?? GestureDefaults.menuToggleHoldDuration
        menuToggleCooldown = try c.decodeIfPresent(Float.self, forKey: .menuToggleCooldown) ?? GestureDefaults.menuToggleCooldown
        menuToggleActivateThreshold = try c.decodeIfPresent(Float.self, forKey: .menuToggleActivateThreshold) ?? GestureDefaults.menuToggleActivateThreshold
        menuToggleReleaseThreshold = try c.decodeIfPresent(Float.self, forKey: .menuToggleReleaseThreshold) ?? GestureDefaults.menuToggleReleaseThreshold
        perFingerTapGestureEnabled = try c.decodeIfPresent(Bool.self, forKey: .perFingerTapGestureEnabled) ?? GestureDefaults.perFingerTapGestureEnabled
        perFingerTapLeftActions = try c.decodeIfPresent([PerFingerTapAction].self, forKey: .perFingerTapLeftActions) ?? GestureDefaults.perFingerTapLeftActions
        perFingerTapRightActions = try c.decodeIfPresent([PerFingerTapAction].self, forKey: .perFingerTapRightActions) ?? GestureDefaults.perFingerTapRightActions
        perFingerTapActivateThreshold = try c.decodeIfPresent(Float.self, forKey: .perFingerTapActivateThreshold) ?? GestureDefaults.perFingerTapActivateThreshold
        perFingerTapReleaseThreshold = try c.decodeIfPresent(Float.self, forKey: .perFingerTapReleaseThreshold) ?? GestureDefaults.perFingerTapReleaseThreshold
        perFingerTapHoldDuration = try c.decodeIfPresent(Float.self, forKey: .perFingerTapHoldDuration) ?? GestureDefaults.perFingerTapHoldDuration
        perFingerTapCooldown = try c.decodeIfPresent(Float.self, forKey: .perFingerTapCooldown) ?? GestureDefaults.perFingerTapCooldown
        twoHandPinchActivateThreshold = try c.decodeIfPresent(Float.self, forKey: .twoHandPinchActivateThreshold) ?? GestureDefaults.twoHandPinchActivateThreshold
        twoHandPinchReleaseThreshold = try c.decodeIfPresent(Float.self, forKey: .twoHandPinchReleaseThreshold) ?? GestureDefaults.twoHandPinchReleaseThreshold
        ringPinchActivateThreshold = try c.decodeIfPresent(Float.self, forKey: .ringPinchActivateThreshold) ?? GestureDefaults.ringPinchActivateThreshold
        ringPinchReleaseThreshold = try c.decodeIfPresent(Float.self, forKey: .ringPinchReleaseThreshold) ?? GestureDefaults.ringPinchReleaseThreshold
        gestureMinHandDistance = try c.decodeIfPresent(Float.self, forKey: .gestureMinHandDistance) ?? GestureDefaults.gestureMinHandDistance
        gestureMaxHandDistance = try c.decodeIfPresent(Float.self, forKey: .gestureMaxHandDistance) ?? GestureDefaults.gestureMaxHandDistance
        gestureMaxStartHandDistance = try c.decodeIfPresent(Float.self, forKey: .gestureMaxStartHandDistance) ?? GestureDefaults.gestureMaxStartHandDistance
        gestureMaxActiveHandDistance = try c.decodeIfPresent(Float.self, forKey: .gestureMaxActiveHandDistance) ?? GestureDefaults.gestureMaxActiveHandDistance
    }
}
