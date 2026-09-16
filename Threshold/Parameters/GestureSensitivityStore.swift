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
    /// Trailing save debounce. Every slider tick used to run a full
    /// JSON-encode + UserDefaults write, and each write fired the app-wide
    /// `didChangeNotification` whose observer re-decodes persisted
    /// transformation JSON — a write storm during a drag.
    private let saveTaskLock = Mutex<Task<Void, Never>?>(nil)
    private static let saveDebounce: Duration = .milliseconds(300)

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
        scheduleSave()
    }

    /// Reset a single parameter back to default sensitivity.
    func resetSensitivity(for parameterID: String) {
        _ = _sensitivities.withLock {
            $0.removeValue(forKey: parameterID)
        }
        scheduleSave()
    }

    // MARK: - Persistence

    /// Coalesce rapid edits into one trailing save (the final value always
    /// persists — same trailing-debounce contract as SettingsPersistence).
    private func scheduleSave() {
        saveTaskLock.withLock { task in
            task?.cancel()
            task = Task.detached(priority: .utility) { [weak self] in
                try? await Task.sleep(for: Self.saveDebounce)
                guard !Task.isCancelled else { return }
                self?.save()
            }
        }
    }

    private func save() {
        let snapshot = _sensitivities.withLock { $0 }
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}
