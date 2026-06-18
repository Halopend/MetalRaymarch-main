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
// Uses decodeIfPresent for gestureSmoothing so existing saved data (which lacks
// this key) continues to decode successfully with the default value.
extension GestureConfig {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        gestureBindings = try c.decode([String: GestureActionBinding].self, forKey: .gestureBindings)
        useSpringBlob = try c.decode(Bool.self, forKey: .useSpringBlob)
        gestureSensitivity = try c.decode(Float.self, forKey: .gestureSensitivity)
        gestureSmoothing = try c.decodeIfPresent(Float.self, forKey: .gestureSmoothing) ?? GestureDefaults.gestureSmoothing
        menuAndMovementOnly = try c.decode(Bool.self, forKey: .menuAndMovementOnly)
        useRelativeGestures = try c.decode(Bool.self, forKey: .useRelativeGestures)
        extendedGestureRange = try c.decode(Bool.self, forKey: .extendedGestureRange)
        translationSensitivity = try c.decode(Float.self, forKey: .translationSensitivity)
        rotationAutoSnap = try c.decode(Bool.self, forKey: .rotationAutoSnap)
        rotationSnapWindowDegrees = try c.decode(Float.self, forKey: .rotationSnapWindowDegrees)
        rotationBreakawayDegrees = try c.decode(Float.self, forKey: .rotationBreakawayDegrees)
        menuToggleGestureEnabled = try c.decode(Bool.self, forKey: .menuToggleGestureEnabled)
        menuToggleGestureMode = try c.decode(MenuToggleGestureMode.self, forKey: .menuToggleGestureMode)
        menuToggleHoldDuration = try c.decode(Float.self, forKey: .menuToggleHoldDuration)
        menuToggleCooldown = try c.decode(Float.self, forKey: .menuToggleCooldown)
        menuToggleActivateThreshold = try c.decode(Float.self, forKey: .menuToggleActivateThreshold)
        menuToggleReleaseThreshold = try c.decode(Float.self, forKey: .menuToggleReleaseThreshold)
        perFingerTapGestureEnabled = try c.decode(Bool.self, forKey: .perFingerTapGestureEnabled)
        perFingerTapLeftActions = try c.decode([PerFingerTapAction].self, forKey: .perFingerTapLeftActions)
        perFingerTapRightActions = try c.decode([PerFingerTapAction].self, forKey: .perFingerTapRightActions)
        perFingerTapActivateThreshold = try c.decode(Float.self, forKey: .perFingerTapActivateThreshold)
        perFingerTapReleaseThreshold = try c.decode(Float.self, forKey: .perFingerTapReleaseThreshold)
        perFingerTapHoldDuration = try c.decode(Float.self, forKey: .perFingerTapHoldDuration)
        perFingerTapCooldown = try c.decode(Float.self, forKey: .perFingerTapCooldown)
        twoHandPinchActivateThreshold = try c.decode(Float.self, forKey: .twoHandPinchActivateThreshold)
        twoHandPinchReleaseThreshold = try c.decode(Float.self, forKey: .twoHandPinchReleaseThreshold)
        ringPinchActivateThreshold = try c.decode(Float.self, forKey: .ringPinchActivateThreshold)
        ringPinchReleaseThreshold = try c.decode(Float.self, forKey: .ringPinchReleaseThreshold)
        gestureMinHandDistance = try c.decode(Float.self, forKey: .gestureMinHandDistance)
        gestureMaxHandDistance = try c.decode(Float.self, forKey: .gestureMaxHandDistance)
        gestureMaxStartHandDistance = try c.decode(Float.self, forKey: .gestureMaxStartHandDistance)
        gestureMaxActiveHandDistance = try c.decode(Float.self, forKey: .gestureMaxActiveHandDistance)
    }
}

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        max(range.lowerBound, min(range.upperBound, self))
    }
}

// MARK: - Gesture Binding Presets

/// A saved snapshot of the 9-slot gesture binding assignments.
struct GestureBindingPreset: Codable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var createdAt: Date
    var bindings: [String: GestureActionBinding]

    init(name: String, bindings: [String: GestureActionBinding]) {
        self.id = UUID()
        self.name = name
        self.createdAt = Date()
        self.bindings = bindings
    }
}

/// Persistence for gesture binding presets (UserDefaults-backed).
enum GestureBindingPresetStore {
    private static let key = "gestureBindingPresets"

    static func loadAll() -> [GestureBindingPreset] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([GestureBindingPreset].self, from: data)) ?? []
    }

    static func saveAll(_ presets: [GestureBindingPreset]) {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func add(_ preset: GestureBindingPreset) {
        var all = loadAll()
        all.append(preset)
        saveAll(all)
    }

    static func remove(id: UUID) {
        var all = loadAll()
        all.removeAll { $0.id == id }
        saveAll(all)
    }
}
