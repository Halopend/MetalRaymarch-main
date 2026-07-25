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

    // MARK: Namespaced Keys

    enum Domain: String {
        case geometry       = "cfg.geometry"
        case quality        = "cfg.quality"
        case color          = "cfg.color"
        case lighting       = "cfg.lighting"
        case audioReactive  = "cfg.audioReactive"
        case gesture        = "cfg.gesture"
        case safetyBubble   = "cfg.safetyBubble"
        case handAttraction = "cfg.handAttraction"
        case display        = "cfg.display"
        case buddhabrot     = "cfg.buddhabrot"
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

    // MARK: Trailing debounce

    /// Slider-driven domains use a trailing debounce: each edit replaces the
    /// pending write, guaranteeing that the final value is persisted. The old
    /// leading-only throttle routinely lost the last edit inside its one-second
    /// window.
    private struct PendingSaveState {
        var nextGeneration: UInt64 = 0
        var latestGenerations: [Domain: UInt64] = [:]
        var tasks: [Domain: (generation: UInt64, data: Data, task: Task<Void, Never>)] = [:]
        var deferredWrites: [Domain: (generation: UInt64, data: Data)] = [:]
        /// Writes that are eligible to reach UserDefaults now. Debounced values
        /// only enter this map when their delay expires (or they are flushed).
        /// Keeping the newest generation lets an older concurrent writer repair
        /// the stored value if it happens to finish last.
        var latestReadyWrites: [Domain: (generation: UInt64, data: Data)] = [:]
    }
    private static let pendingSaves = Mutex(PendingSaveState())
    private static let debounceDelay: Duration = .milliseconds(300)

    // MARK: Generic Save / Load

    /// Benchmark launches must be hermetic in BOTH directions: reading the
    /// user's persisted state lets a live session's device-local settings
    /// silently change what a benchmark measures (observed 2026-07-01: stale
    /// persisted fractalIterations rendered the canonical scene black and the
    /// harness reported a 4× "speedup"), and writing lets an unattended run
    /// stomp the user's real app settings. Checked via the environment directly
    /// (not BenchmarkMode) so the Quick Look shared-source closure, which
    /// includes this file but not BenchmarkMode.swift, still compiles.
    static let benchmarkHermetic =
        ProcessInfo.processInfo.environment["THRESHOLD_BENCHMARK"] == "1"

    static func save<T: Codable>(_ value: T, domain: Domain) {
        guard !benchmarkHermetic else { return }
        guard let data = encode(value) else { return }
        let generation = pendingSaves.withLock { state -> UInt64 in
            state.nextGeneration &+= 1
            state.tasks.removeValue(forKey: domain)?.task.cancel()
            state.deferredWrites.removeValue(forKey: domain)
            state.latestGenerations[domain] = state.nextGeneration
            state.latestReadyWrites[domain] = (state.nextGeneration, data)
            return state.nextGeneration
        }
        commit(data, generation: generation, domain: domain)
    }

    static func saveDebounced<T: Codable & Sendable>(_ value: T, domain: Domain) {
        guard !benchmarkHermetic, let data = encode(value) else { return }

        let generation = pendingSaves.withLock { state -> UInt64 in
            state.nextGeneration &+= 1
            state.tasks.removeValue(forKey: domain)?.task.cancel()
            state.latestGenerations[domain] = state.nextGeneration
            state.deferredWrites[domain] = (state.nextGeneration, data)
            return state.nextGeneration
        }

        let task = Task.detached(priority: .utility) {
            try? await Task.sleep(for: debounceDelay)
            guard !Task.isCancelled else { return }
            let shouldCommit = pendingSaves.withLock { state -> Bool in
                guard state.deferredWrites[domain]?.generation == generation else { return false }
                state.tasks.removeValue(forKey: domain)
                state.deferredWrites.removeValue(forKey: domain)
                state.latestReadyWrites[domain] = (generation, data)
                return true
            }
            guard shouldCommit else { return }
            commit(data, generation: generation, domain: domain)
        }

        pendingSaves.withLock { state in
            // A newer call can win between generation allocation and task install.
            guard state.latestGenerations[domain] == generation,
                  state.deferredWrites[domain]?.generation == generation else {
                task.cancel()
                return
            }
            state.tasks[domain] = (generation, data, task)
        }
    }

    /// Commit only writes that originated from an explicit user edit and are
    /// still waiting for the trailing debounce. This is intentionally different
    /// from `saveAll(from:)`: a lifecycle checkpoint must not serialize the live
    /// scene back into device/user preference domains after a suppressed scene
    /// load or animation frame.
    static func flushPendingSaves() {
        guard !benchmarkHermetic else { return }
        let writes = pendingSaves.withLock { state -> [(Domain, UInt64, Data)] in
            for pending in state.tasks.values {
                pending.task.cancel()
            }
            let writes = state.deferredWrites.map { domain, pending in
                state.latestReadyWrites[domain] = pending
                return (domain, pending.generation, pending.data)
            }
            state.tasks.removeAll()
            state.deferredWrites.removeAll()
            return writes
        }
        for (domain, generation, data) in writes {
            commit(data, generation: generation, domain: domain)
        }
    }

    /// UserDefaults posts change notifications synchronously. Never hold one of
    /// our mutexes across `set`: a background write can wait for main-thread
    /// notification delivery while the main thread waits for that mutex.
    private static func commit(_ data: Data, generation: UInt64, domain: Domain) {
        var candidate = (generation: generation, data: data)
        while true {
            defaults.set(candidate.data, forKey: domain.rawValue)
            guard let newer = pendingSaves.withLock({ state -> (generation: UInt64, data: Data)? in
                guard let latest = state.latestReadyWrites[domain],
                      latest.generation > candidate.generation else { return nil }
                return latest
            }) else { return }
            candidate = newer
        }
    }

    private static func encode<T: Encodable>(_ value: T) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try? encoder.encode(value)
    }

    static func load<T: Codable>(_ type: T.Type, domain: Domain) -> T? {
        guard !benchmarkHermetic else { return nil }
        let decoder = JSONDecoder()
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
        save(settings.handAttractionConfig, domain: .handAttraction)
        save(settings.displayConfig, domain: .display)
    }

    /// Restore all persisted domains into a RenderSettings instance.
    /// Only overwrites fields that were previously persisted (returns silently
    /// if a domain has never been saved, preserving the hard-coded defaults).
    static func restoreAll(into settings: RenderSettings) {
        if let c = load(GeometryConfig.self,      domain: .geometry)      { settings.geometryConfig = c }
        if let c = load(QualityConfig.self,       domain: .quality) {
            settings.qualityConfig = migrateConeMarchStrengthDefault(migrateMacResolutionScale(c))
        }
        if let c = load(ColorConfig.self,         domain: .color)         { settings.colorConfig = c }
        if let c = load(LightingConfig.self,      domain: .lighting)      { settings.lightingConfig = c }
        if let c = load(AudioReactiveConfig.self, domain: .audioReactive) { settings.audioReactiveConfig = c }
        if let c = load(GestureConfig.self,       domain: .gesture)       { settings.gestureConfig = c }
        if let c = load(SafetyBubbleConfig.self,  domain: .safetyBubble)  { settings.safetyBubbleConfig = migrateSafetyBubbleDefaultOn(c) }
        if let c = load(HandAttractionConfig.self, domain: .handAttraction) {
            settings.handAttractionConfig = migrateHandAttractionDefaultOn(c)
        }
        if let c = load(DisplayConfig.self,       domain: .display)       { settings.displayConfig = c }
    }

    /// One-time visionOS migration: installs that persisted a bubble config before
    /// the comfort default flipped to ON carry `enabled = false` / the old 0.5
    /// strength forward forever, so the new default would never be visible on an
    /// existing device. Nudge to the new defaults exactly once; the flag keeps a
    /// user who deliberately disables the bubble afterward from being re-stomped.
    private static func migrateSafetyBubbleDefaultOn(_ config: SafetyBubbleConfig) -> SafetyBubbleConfig {
        #if os(visionOS)
        let flagKey = "didMigrateSafetyBubbleDefaultOn"
        guard !defaults.bool(forKey: flagKey) else { return config }
        defaults.set(true, forKey: flagKey)
        var migrated = config
        migrated.enabled = SafetyBubbleConfig.defaultEnabled
        migrated.strength = SafetyBubbleConfig.defaultStrength
        save(migrated, domain: .safetyBubble)
        return migrated
        #else
        return config
        #endif
    }

    /// One-time migration: Hand Interaction graduated from beta (previously off
    /// until the user opted in) to on-by-default. Installs that persisted a
    /// config before the change carry `enabled = false` forward forever, so
    /// nudge to on exactly once; a user who deliberately disables it afterward
    /// is never re-stomped.
    private static func migrateHandAttractionDefaultOn(_ config: HandAttractionConfig) -> HandAttractionConfig {
        let flagKey = "didMigrateHandAttractionDefaultOn"
        guard !defaults.bool(forKey: flagKey) else { return config }
        defaults.set(true, forKey: flagKey)
        var migrated = config
        migrated.enabled = true
        save(migrated, domain: .handAttraction)
        return migrated
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

    /// One-time migration from the former off-by-default Cone Marching setting.
    /// Only the exact old default is changed; any tuned nonzero value survives.
    private static func migrateConeMarchStrengthDefault(_ config: QualityConfig) -> QualityConfig {
        let flagKey = "didMigrateConeMarchStrengthDefaultTo84"
        guard !defaults.bool(forKey: flagKey) else { return config }
        defaults.set(true, forKey: flagKey)
        guard config.coneMarchStrength == 0 else { return config }
        var migrated = config
        migrated.coneMarchStrength = QualityConfig.defaultConeMarchStrength
        save(migrated, domain: .quality)
        return migrated
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
            decoder: JSONDecoder(),
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
