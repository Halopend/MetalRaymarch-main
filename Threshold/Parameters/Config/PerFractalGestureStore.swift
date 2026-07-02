//
//  PerFractalGestureStore.swift
//  Threshold
//
//  Persists gesture bindings per fractal type so users' custom
//  assignments are restored when switching back to a fractal.
//

import Foundation

// MARK: - Codable ↔ UserDefaults round-trip

/// Shared JSON round-trip for the stores that persist one Codable value under a
/// single key (this file, FractalDefaultsStore, GestureSensitivityStore).
/// Lives HERE because this is the only one of the three compiled into the
/// Quick Look appex (wire_quicklook.rb) — hosting it in either of the others
/// would leave the QL target without the symbol.
extension UserDefaults {
    /// Encode `value` as JSON and store it. An encode failure writes nothing
    /// and returns false, so callers keep their historical silent no-op.
    @discardableResult
    func setCodable<T: Encodable>(_ value: T, forKey key: String) -> Bool {
        guard let data = try? JSONEncoder().encode(value) else { return false }
        set(data, forKey: key)
        return true
    }

    /// Decode a JSON-encoded value; nil when the key is absent or stale data
    /// no longer decodes — callers supply their own fallback.
    func codable<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

enum PerFractalGestureStore {
    private static let prefix = "gestureBindings_"

    static func save(_ bindings: [String: GestureActionBinding], for fractalType: FractalModelType) {
        UserDefaults.standard.setCodable(bindings, forKey: prefix + String(fractalType.rawValue))
    }

    static func load(for fractalType: FractalModelType) -> [String: GestureActionBinding]? {
        UserDefaults.standard.codable([String: GestureActionBinding].self,
                                      forKey: prefix + String(fractalType.rawValue))
    }
}
