import Foundation
import os

// MARK: - Per-Parameter Gesture Sensitivity Store
//
// Stores a user-tunable multiplier (default 1.0) for each parameter that can be
// gesture-controlled.  The multiplier scales the *effect* of the gesture on the
// parameter value — it does NOT change the gesture distance/speed calculation.
//
// Excluded from this system: the two-point grab gesture (scale/rotate), which has
// a direct spatial mapping (hand distance ↔ world scale) and should remain 1:1.
//
// Persistence: the full dictionary is JSON-encoded to UserDefaults under a single
// key so there's no per-parameter key explosion.

final class GestureSensitivityStore: @unchecked Sendable {
    static let shared = GestureSensitivityStore()

    static let defaultSensitivity: Float = 1.0
    static let range: ClosedRange<Float> = 0.1...10.0

    private var sensitivities: [String: Float] = [:]
    private let lock = os_unfair_lock_t.allocate(capacity: 1)
    private let defaultsKey = "parameterGestureSensitivities"

    private init() {
        lock.initialize(to: os_unfair_lock())
        load()
    }

    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    // MARK: - Public API

    /// Returns the gesture sensitivity multiplier for a parameter.
    /// 1.0 means default; >1 = more responsive, <1 = less responsive.
    func sensitivity(for parameterID: String) -> Float {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return sensitivities[parameterID] ?? Self.defaultSensitivity
    }

    /// Set the gesture sensitivity multiplier for a parameter.
    func setSensitivity(_ value: Float, for parameterID: String) {
        let clamped = min(Self.range.upperBound, max(Self.range.lowerBound, value))
        os_unfair_lock_lock(lock)
        if abs(clamped - Self.defaultSensitivity) < 0.001 {
            // Remove entries that are ~default to keep the dictionary lean
            sensitivities.removeValue(forKey: parameterID)
        } else {
            sensitivities[parameterID] = clamped
        }
        os_unfair_lock_unlock(lock)
        save()
    }

    /// Reset a single parameter back to default sensitivity.
    func resetSensitivity(for parameterID: String) {
        os_unfair_lock_lock(lock)
        sensitivities.removeValue(forKey: parameterID)
        os_unfair_lock_unlock(lock)
        save()
    }

    /// Reset all parameters back to default sensitivity.
    func resetAll() {
        os_unfair_lock_lock(lock)
        sensitivities.removeAll()
        os_unfair_lock_unlock(lock)
        save()
    }

    /// Returns all parameter IDs that have non-default sensitivity.
    func customizedParameterIDs() -> [String] {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return Array(sensitivities.keys)
    }

    // MARK: - Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([String: Float].self, from: data) else {
            return
        }
        sensitivities = decoded
    }

    private func save() {
        os_unfair_lock_lock(lock)
        let snapshot = sensitivities
        os_unfair_lock_unlock(lock)
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}
