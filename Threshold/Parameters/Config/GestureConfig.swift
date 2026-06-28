//
//  GestureConfig.swift
//  Threshold
//
//  Domain config: gesture bindings + the menu/per-finger-tap gesture layer.
//  Part of the RenderSettings decomposition (Phase 1).
//
//  Tuning knobs (sensitivities, smoothing, pinch/menu thresholds, hand-distance
//  guards) are no longer user-adjustable — they live as fixed constants in
//  `GestureDefaults` and are read directly by the gesture engines.
//

import Foundation

struct GestureConfig: Codable, Equatable, Sendable {
    // 15-slot gesture binding dictionary (hand × finger × direction)
    var gestureBindings: [String: GestureActionBinding] = GestureDefaults.defaultBindings

    // Relative vs absolute parameter gestures
    var useRelativeGestures: Bool = GestureDefaults.useRelativeGestures

    // Menu toggle gesture
    var menuToggleGestureEnabled: Bool = GestureDefaults.menuToggleGestureEnabled
    var menuToggleGestureMode: MenuToggleGestureMode = GestureDefaults.menuToggleGestureMode

    // Per-finger tap-to-palm gesture layer
    var perFingerTapGestureEnabled: Bool = GestureDefaults.perFingerTapGestureEnabled
    var perFingerTapLeftActions: [PerFingerTapAction] = GestureDefaults.perFingerTapLeftActions
    var perFingerTapRightActions: [PerFingerTapAction] = GestureDefaults.perFingerTapRightActions
    var perFingerTapActivateThreshold: Float = GestureDefaults.perFingerTapActivateThreshold
    var perFingerTapReleaseThreshold: Float = GestureDefaults.perFingerTapReleaseThreshold
    var perFingerTapHoldDuration: Float = GestureDefaults.perFingerTapHoldDuration
    var perFingerTapCooldown: Float = GestureDefaults.perFingerTapCooldown

    // MARK: - Validation

    mutating func clamp() {
        perFingerTapActivateThreshold = perFingerTapActivateThreshold.clamped(to: GestureDefaults.perFingerTapActivateThresholdRange)
        perFingerTapReleaseThreshold = perFingerTapReleaseThreshold.clamped(to: GestureDefaults.perFingerTapReleaseThresholdRange)
        perFingerTapHoldDuration = perFingerTapHoldDuration.clamped(to: GestureDefaults.perFingerTapHoldDurationRange)
        perFingerTapCooldown = perFingerTapCooldown.clamped(to: GestureDefaults.perFingerTapCooldownRange)
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
        useRelativeGestures = try c.decodeIfPresent(Bool.self, forKey: .useRelativeGestures) ?? GestureDefaults.useRelativeGestures
        menuToggleGestureEnabled = try c.decodeIfPresent(Bool.self, forKey: .menuToggleGestureEnabled) ?? GestureDefaults.menuToggleGestureEnabled
        menuToggleGestureMode = try c.decodeIfPresent(MenuToggleGestureMode.self, forKey: .menuToggleGestureMode) ?? GestureDefaults.menuToggleGestureMode
        perFingerTapGestureEnabled = try c.decodeIfPresent(Bool.self, forKey: .perFingerTapGestureEnabled) ?? GestureDefaults.perFingerTapGestureEnabled
        perFingerTapLeftActions = try c.decodeIfPresent([PerFingerTapAction].self, forKey: .perFingerTapLeftActions) ?? GestureDefaults.perFingerTapLeftActions
        perFingerTapRightActions = try c.decodeIfPresent([PerFingerTapAction].self, forKey: .perFingerTapRightActions) ?? GestureDefaults.perFingerTapRightActions
        perFingerTapActivateThreshold = try c.decodeIfPresent(Float.self, forKey: .perFingerTapActivateThreshold) ?? GestureDefaults.perFingerTapActivateThreshold
        perFingerTapReleaseThreshold = try c.decodeIfPresent(Float.self, forKey: .perFingerTapReleaseThreshold) ?? GestureDefaults.perFingerTapReleaseThreshold
        perFingerTapHoldDuration = try c.decodeIfPresent(Float.self, forKey: .perFingerTapHoldDuration) ?? GestureDefaults.perFingerTapHoldDuration
        perFingerTapCooldown = try c.decodeIfPresent(Float.self, forKey: .perFingerTapCooldown) ?? GestureDefaults.perFingerTapCooldown
    }
}
