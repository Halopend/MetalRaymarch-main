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
        translationSensitivity = translationSensitivity.clamped(to: GestureDefaults.translationSensitivityRange)
        rotationSnapWindowDegrees = rotationSnapWindowDegrees.clamped(to: GestureDefaults.rotationSnapWindowDegreesRange)
        rotationBreakawayDegrees = rotationBreakawayDegrees.clamped(to: GestureDefaults.rotationBreakawayDegreesRange)
        menuToggleHoldDuration = menuToggleHoldDuration.clamped(to: GestureDefaults.menuToggleHoldDurationRange)
        menuToggleCooldown = menuToggleCooldown.clamped(to: GestureDefaults.menuToggleCooldownRange)
        menuToggleActivateThreshold = menuToggleActivateThreshold.clamped(to: GestureDefaults.menuToggleActivateThresholdRange)
        menuToggleReleaseThreshold = menuToggleReleaseThreshold.clamped(to: GestureDefaults.menuToggleReleaseThresholdRange)
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
