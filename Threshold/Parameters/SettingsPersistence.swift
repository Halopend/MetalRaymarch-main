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
import Synchronization

// MARK: - SettingsPersistence

enum SettingsPersistence {

    nonisolated(unsafe) private static let defaults = UserDefaults.standard
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
        case music          = "cfg.music"
    }

    enum LegacyKey {
        static let musicPreferredServiceID = "music.preferredServiceID"
        static let musicServicePriority = "music.servicePriority"
        static let musicReactivePresets = "musicReactivePresets"
    }

    enum Music {
        static func loadPreferences(defaultServicePriority: [String] = []) -> MusicPreferences {
            SettingsPersistence.loadMusicConfig(defaultServicePriority: defaultServicePriority).preferences
        }

        static func savePreferences(_ preferences: MusicPreferences, defaultServicePriority: [String] = []) {
            var config = SettingsPersistence.loadMusicConfig(defaultServicePriority: defaultServicePriority)
            config.preferences = preferences
            SettingsPersistence.saveMusicConfig(config)
        }

        static func preferredServiceID(defaultServicePriority: [String] = []) -> String? {
            loadPreferences(defaultServicePriority: defaultServicePriority).preferredServiceID
        }

        static func setPreferredServiceID(_ serviceID: String?, defaultServicePriority: [String] = []) {
            var preferences = loadPreferences(defaultServicePriority: defaultServicePriority)
            preferences.preferredServiceID = serviceID
            savePreferences(preferences, defaultServicePriority: defaultServicePriority)
        }

        static func servicePriority(defaultServicePriority: [String] = []) -> [String] {
            let preferences = loadPreferences(defaultServicePriority: defaultServicePriority)
            return preferences.servicePriority.isEmpty ? defaultServicePriority : preferences.servicePriority
        }

        static func setServicePriority(_ priority: [String], defaultServicePriority: [String] = []) {
            var preferences = loadPreferences(defaultServicePriority: defaultServicePriority)
            preferences.servicePriority = priority
            savePreferences(preferences, defaultServicePriority: defaultServicePriority)
        }

        static func loadPresets() -> [MusicReactivePreset] {
            SettingsPersistence.loadMusicConfig().presets
        }

        static func savePresets(_ presets: [MusicReactivePreset]) {
            var config = SettingsPersistence.loadMusicConfig()
            config.presets = presets
            SettingsPersistence.saveMusicConfig(config)
        }
    }

    struct MusicPreferences: Codable, Sendable {
        var preferredServiceID: String?
        var servicePriority: [String]

        init(preferredServiceID: String? = nil, servicePriority: [String] = []) {
            self.preferredServiceID = preferredServiceID
            self.servicePriority = servicePriority
        }
    }

    struct MusicConfig: Codable, Sendable {
        var preferences: MusicPreferences
        var presets: [MusicReactivePreset]

        init(preferences: MusicPreferences = .init(), presets: [MusicReactivePreset] = []) {
            self.preferences = preferences
            self.presets = presets
        }
    }

    // MARK: Throttle

    /// Minimum interval (seconds) between consecutive saves for the same domain.
    /// Prevents excessive UserDefaults writes from continuous slider drags / gestures.
    private static let throttleInterval: TimeInterval = 1.0

    /// Timestamp of the last successful save per domain.
    private static let _lastSaveTime = Mutex<[Domain: TimeInterval]>([:])

    // MARK: Generic Save / Load

    static func save<T: Codable>(_ value: T, domain: Domain) {
        guard let data = try? encoder.encode(value) else { return }
        defaults.set(data, forKey: domain.rawValue)
    }

    /// Returns true if the domain is eligible for a save (throttle window has elapsed).
    /// Call this BEFORE constructing the config struct to avoid unnecessary work.
    static func shouldSave(domain: Domain) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        return _lastSaveTime.withLock { lastSaveTime in
            let last = lastSaveTime[domain] ?? 0
            if now - last < throttleInterval {
                return false
            }
            lastSaveTime[domain] = now
            return true
        }
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
        if let c = load(QualityConfig.self,       domain: .quality)       { settings.qualityConfig = migrateMacResolutionScale(c) }
        if let c = load(ColorConfig.self,         domain: .color)         { settings.colorConfig = c }
        if let c = load(LightingConfig.self,      domain: .lighting)      { settings.lightingConfig = c }
        if let c = load(AudioReactiveConfig.self, domain: .audioReactive) { settings.audioReactiveConfig = c }
        if let c = load(GestureConfig.self,       domain: .gesture)       { settings.gestureConfig = c }
        if let c = load(SafetyBubbleConfig.self,  domain: .safetyBubble)  { settings.safetyBubbleConfig = c }
        if let c = load(DisplayConfig.self,       domain: .display)       { settings.displayConfig = c }
    }

    /// One-time macOS migration: installs that ran before the Mac MetalFX default
    /// existed persisted `resolutionScale` at the old native 1.0, which bypasses the
    /// upscale path and makes the raymarch pay for every Retina pixel. Nudge a
    /// still-native value down to the new 0.75 Mac default exactly once. The flag
    /// makes it idempotent and one-directional, so a user who deliberately returns to
    /// native afterward is never re-stomped; an already sub-native value is left alone.
    private static func migrateMacResolutionScale(_ config: QualityConfig) -> QualityConfig {
        #if os(macOS)
        let flagKey = "didMigrateMacResolutionScaleToMetalFX"
        guard !defaults.bool(forKey: flagKey) else { return config }
        defaults.set(true, forKey: flagKey)
        guard config.resolutionScale >= 0.985 else { return config }
        var migrated = config
        migrated.resolutionScale = 0.75
        save(migrated, domain: .quality)
        return migrated
        #else
        return config
        #endif
    }

    // MARK: - Music (Typed Section)

    static func loadMusicConfig(defaultServicePriority: [String] = []) -> MusicConfig {
        var config = load(MusicConfig.self, domain: .music) ?? .init()
        let migrated = migrateLegacyMusicKeys(into: &config, defaultServicePriority: defaultServicePriority)
        if config.preferences.servicePriority.isEmpty {
            config.preferences.servicePriority = defaultServicePriority
        }
        if migrated {
            save(config, domain: .music)
        }
        return config
    }

    static func saveMusicConfig(_ config: MusicConfig) {
        save(config, domain: .music)
    }

    @discardableResult
    private static func migrateLegacyMusicKeys(into config: inout MusicConfig, defaultServicePriority: [String]) -> Bool {
        MusicLegacyMigrationAdapter.migrate(
            defaults: defaults,
            decoder: decoder,
            config: &config,
            defaultServicePriority: defaultServicePriority
        )
    }

    private enum MusicLegacyMigrationAdapter {
        @discardableResult
        static func migrate(
            defaults: UserDefaults,
            decoder: JSONDecoder,
            config: inout MusicConfig,
            defaultServicePriority: [String]
        ) -> Bool {
            var migrated = false

            if config.preferences.preferredServiceID == nil,
               let preferred = defaults.string(forKey: LegacyKey.musicPreferredServiceID) {
                config.preferences.preferredServiceID = preferred
                migrated = true
            }

            if config.preferences.servicePriority.isEmpty,
               let data = defaults.data(forKey: LegacyKey.musicServicePriority),
               let ids = try? decoder.decode([String].self, from: data),
               !ids.isEmpty {
                config.preferences.servicePriority = ids
                migrated = true
            }

            if config.presets.isEmpty,
               let data = defaults.data(forKey: LegacyKey.musicReactivePresets),
               let presets = try? decoder.decode([MusicReactivePreset].self, from: data),
               !presets.isEmpty {
                config.presets = presets
                migrated = true
            }

            if config.preferences.servicePriority.isEmpty, !defaultServicePriority.isEmpty {
                config.preferences.servicePriority = defaultServicePriority
            }

            if migrated {
                defaults.removeObject(forKey: LegacyKey.musicPreferredServiceID)
                defaults.removeObject(forKey: LegacyKey.musicServicePriority)
                defaults.removeObject(forKey: LegacyKey.musicReactivePresets)
            }

            return migrated
        }
    }
}
