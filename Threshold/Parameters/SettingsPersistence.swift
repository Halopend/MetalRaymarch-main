//
//  SettingsPersistence.swift
//  Threshold
//
//  Centralized typed persistence for domain config structs.
//  Replaces 30+ scattered UserDefaults.standard.set(...) calls with
//  one save/load per domain.  Each config struct is stored as a JSON
//  blob under a namespaced key.
//
//  Phase 2 of the architecture rebuild.
//

import Foundation

// MARK: - SettingsPersistence

enum SettingsPersistence {

    private static let defaults = UserDefaults.standard
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = .sortedKeys
        return e
    }()
    private static let decoder = JSONDecoder()

    // MARK: Namespaced Keys

    enum Domain: String {
        case geometry       = "cfg.geometry"
        case quality        = "cfg.quality"
        case color          = "cfg.color"
        case lighting       = "cfg.lighting"
        case audioReactive  = "cfg.audioReactive"
        case gesture        = "cfg.gesture"
        case safetyBubble   = "cfg.safetyBubble"
        case display        = "cfg.display"
    }

    // MARK: Throttle

    /// Minimum interval (seconds) between consecutive saves for the same domain.
    /// Prevents excessive UserDefaults writes from continuous slider drags / gestures.
    private static let throttleInterval: TimeInterval = 1.0

    /// Timestamp of the last successful save per domain.
    private static var lastSaveTime: [Domain: TimeInterval] = [:]
    private static let throttleLock = NSLock()

    // MARK: Generic Save / Load

    static func save<T: Codable>(_ value: T, domain: Domain) {
        guard let data = try? encoder.encode(value) else { return }
        defaults.set(data, forKey: domain.rawValue)
    }

    /// Returns true if the domain is eligible for a save (throttle window has elapsed).
    /// Call this BEFORE constructing the config struct to avoid unnecessary work.
    static func shouldSave(domain: Domain) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        throttleLock.lock()
        let last = lastSaveTime[domain] ?? 0
        if now - last < throttleInterval {
            throttleLock.unlock()
            return false
        }
        lastSaveTime[domain] = now
        throttleLock.unlock()
        return true
    }

    static func load<T: Codable>(_ type: T.Type, domain: Domain) -> T? {
        guard let data = defaults.data(forKey: domain.rawValue),
              let decoded = try? decoder.decode(type, from: data) else { return nil }
        return decoded
    }

    // MARK: Save All

    /// Persist all domains from a RenderSettings instance.
    static func saveAll(from settings: RenderSettings) {
        save(settings.geometryConfig, domain: .geometry)
        save(settings.qualityConfig, domain: .quality)
        save(settings.colorConfig, domain: .color)
        save(settings.lightingConfig, domain: .lighting)
        save(settings.audioReactiveConfig, domain: .audioReactive)
        save(settings.gestureConfig, domain: .gesture)
        save(settings.safetyBubbleConfig, domain: .safetyBubble)
        save(settings.displayConfig, domain: .display)
    }

    /// Restore all persisted domains into a RenderSettings instance.
    /// Only overwrites fields that were previously persisted (returns silently
    /// if a domain has never been saved, preserving the hard-coded defaults).
    static func restoreAll(into settings: RenderSettings) {
        if let c = load(GeometryConfig.self,      domain: .geometry)      { settings.geometryConfig = c }
        if let c = load(QualityConfig.self,       domain: .quality)       { settings.qualityConfig = c }
        if let c = load(ColorConfig.self,         domain: .color)         { settings.colorConfig = c }
        if let c = load(LightingConfig.self,      domain: .lighting)      { settings.lightingConfig = c }
        if let c = load(AudioReactiveConfig.self, domain: .audioReactive) { settings.audioReactiveConfig = c }
        if let c = load(GestureConfig.self,       domain: .gesture)       { settings.gestureConfig = c }
        if let c = load(SafetyBubbleConfig.self,  domain: .safetyBubble)  { settings.safetyBubbleConfig = c }
        if let c = load(DisplayConfig.self,       domain: .display)       { settings.displayConfig = c }
    }
}
