import Foundation
import Synchronization

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

final class GestureSensitivityStore: Sendable {
    static let shared = GestureSensitivityStore()

    static let defaultSensitivity: Float = 1.0
    static let range: ClosedRange<Float> = 0.1...10.0

    private let _sensitivities: Mutex<[String: Float]>
    private let defaultsKey = "parameterGestureSensitivities"

    private init() {
        // Load persisted data during init
        let initial: [String: Float]
        if let data = UserDefaults.standard.data(forKey: "parameterGestureSensitivities"),
           let decoded = try? JSONDecoder().decode([String: Float].self, from: data) {
            initial = decoded
        } else {
            initial = [:]
        }
        _sensitivities = Mutex(initial)
    }

    // MARK: - Public API

    /// Returns the gesture sensitivity multiplier for a parameter.
    /// 1.0 means default; >1 = more responsive, <1 = less responsive.
    func sensitivity(for parameterID: String) -> Float {
        _sensitivities.withLock { sensitivities in
            sensitivities[parameterID] ?? Self.defaultSensitivity
        }
    }

    /// Set the gesture sensitivity multiplier for a parameter.
    func setSensitivity(_ value: Float, for parameterID: String) {
        let clamped = min(Self.range.upperBound, max(Self.range.lowerBound, value))
        _sensitivities.withLock { sensitivities in
            if abs(clamped - Self.defaultSensitivity) < 0.001 {
                sensitivities.removeValue(forKey: parameterID)
            } else {
                sensitivities[parameterID] = clamped
            }
        }
        save()
    }

    /// Reset a single parameter back to default sensitivity.
    func resetSensitivity(for parameterID: String) {
        _sensitivities.withLock { sensitivities in
            sensitivities.removeValue(forKey: parameterID)
        }
        save()
    }

    /// Reset all parameters back to default sensitivity.
    func resetAll() {
        _sensitivities.withLock { sensitivities in
            sensitivities.removeAll()
        }
        save()
    }

    /// Returns all parameter IDs that have non-default sensitivity.
    func customizedParameterIDs() -> [String] {
        _sensitivities.withLock { sensitivities in
            Array(sensitivities.keys)
        }
    }

    // MARK: - Persistence

    private func save() {
        let snapshot = _sensitivities.withLock { $0 }
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}
