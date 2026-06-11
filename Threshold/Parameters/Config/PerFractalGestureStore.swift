//
//  PerFractalGestureStore.swift
//  Threshold
//
//  Persists gesture bindings per fractal type so users' custom
//  assignments are restored when switching back to a fractal.
//

import Foundation

enum PerFractalGestureStore {
    private static let prefix = "gestureBindings_"

    static func save(_ bindings: [String: GestureActionBinding], for fractalType: FractalModelType) {
        guard let data = try? JSONEncoder().encode(bindings) else { return }
        UserDefaults.standard.set(data, forKey: prefix + String(fractalType.rawValue))
    }

    static func load(for fractalType: FractalModelType) -> [String: GestureActionBinding]? {
        guard let data = UserDefaults.standard.data(forKey: prefix + String(fractalType.rawValue)),
              let bindings = try? JSONDecoder().decode([String: GestureActionBinding].self, from: data)
        else { return nil }
        return bindings
    }
}
