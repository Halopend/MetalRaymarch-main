//
//  ICloudBackupManager.swift
//  Threshold
//
//  Syncs user settings, fractal presets, and animation scenes to a public
//  iCloud Drive folder named "Threshold" (declared via NSUbiquitousContainers
//  in Info.plist). Files are stored as individual JSON documents in named
//  subfolders so they are browseable in Files.app on iOS/visionOS and in
//  Finder on macOS — even on devices that do not have the app installed.
//
//  The subfolders mirror the app's internal Threshold/Examples layout.
//
//      iCloud Drive/
//        └── Threshold/
//            ├── Settings/
//            │   └── settings.json
//            ├── Scenes/            (plain presets, .threshscene)
//            │   ├── Bright_Preset.threshscene
//            │   └── Cosmic_Drift.threshscene
//            ├── Music Presets/     (music-reactive presets, .threshmp)
//            │   └── Legendary_Kid.threshmp
//            └── Animations/
//                ├── Demo_Loop.threshanim
//                └── Music_Video.threshanimv
//

import Foundation
import Observation
#if canImport(UIKit)
import UIKit
#endif

@Observable
@MainActor
final class ICloudBackupManager {

    // MARK: - Public State

    private(set) var isAvailable: Bool = false
    private(set) var lastSyncDate: Date?
    private(set) var isBusy: Bool = false
    private(set) var lastError: String?

    /// Persisted toggle for whether iCloud sync is active.
    /// Mirrors UserDefaults["ICloud.syncEnabled"]. Defaults to false until
    /// the user opts in from Settings.
    var isSyncEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isSyncEnabled, forKey: Self.syncEnabledKey)
            if isSyncEnabled, cloudFolderURL == nil {
                resolveContainer()
            }
        }
    }

    private nonisolated static let syncEnabledKey = "ICloud.syncEnabled"

    /// Resolved iCloud "Threshold" folder URL (nil when iCloud is unavailable).
    private(set) var cloudFolderURL: URL?

    // MARK: - Constants

    private nonisolated static let folderName       = "Threshold"
    // Subfolder names mirror the app's internal Threshold/Examples layout so the
    // iCloud "Threshold" folder browses the same way (Scenes / Music Presets /
    // Animations). Plain presets go in Scenes, music-reactive presets (.threshmp)
    // in Music Presets.
    private nonisolated static let settingsSubdir     = "Settings"
    private nonisolated static let scenesSubdir       = "Scenes"
    private nonisolated static let musicPresetsSubdir = "Music Presets"
    private nonisolated static let animationsSubdir   = "Animations"
    private nonisolated static let settingsFile     = "settings.json"
    private nonisolated static let metadataFile     = ".metadata.json"
    // Deletion records live at the Threshold root (hidden, alongside metadata) so
    // a delete on one device propagates to others instead of the item reappearing
    // from a cloud copy. Kept separate for presets vs scenes to mirror the local
    // TombstoneStores. See BackupMerge.reconcile for the resolution rules.
    private nonisolated static let presetTombstonesFile = ".tombstones-presets.json"
    private nonisolated static let sceneTombstonesFile  = ".tombstones-scenes.json"

    // MARK: - Init

    init() {
        self.isSyncEnabled = UserDefaults.standard.bool(forKey: Self.syncEnabledKey)
        if isSyncEnabled {
            resolveContainer()
        }
    }

    // MARK: - Container Resolution

    /// Posted on the main queue when `cloudFolderURL` is first resolved.
    /// The `object` is the resolved `URL`.
    nonisolated static let cloudFolderResolvedNotification = Notification.Name("ICloudBackupManager.cloudFolderResolved")

    /// Discovers the ubiquity container off the main actor and caches the
    /// resolved folder URL. Safe to call multiple times.
    func resolveContainer() {
        Task {
            let folder = await Self.discoverCloudFolder()
            if let folder {
                let alreadyResolved = self.cloudFolderURL != nil
                self.cloudFolderURL = folder
                self.isAvailable = true
                self.loadMetadata()
                if !alreadyResolved {
                    NotificationCenter.default.post(
                        name: Self.cloudFolderResolvedNotification,
                        object: folder
                    )
                }
            } else {
                self.cloudFolderURL = nil
                self.isAvailable = false
            }
        }
    }

    private nonisolated static func discoverCloudFolder() async -> URL? {
        guard let containerURL = FileManager.default
            .url(forUbiquityContainerIdentifier: nil) else {
            return nil
        }
        // The Documents subfolder is what surfaces in Files.app / Finder when
        // NSUbiquitousContainerIsDocumentScopePublic is YES. The container
        // itself is named via NSUbiquitousContainerName, so we don't add an
        // extra "Threshold" component here — Documents IS the Threshold root.
        let docs = containerURL.appendingPathComponent("Documents", isDirectory: true)
        try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        // Pre-create subfolders so they always appear, even when empty.
        for sub in [settingsSubdir, scenesSubdir, musicPresetsSubdir, animationsSubdir] {
            let subURL = docs.appendingPathComponent(sub, isDirectory: true)
            try? FileManager.default.createDirectory(at: subURL, withIntermediateDirectories: true)
        }
        return docs
    }

    // MARK: - Sync (Push)

    /// Writes current settings, presets, and user animation scenes to iCloud
    /// Drive. Reconciles with the cloud first (newest-wins union) so nothing is
    /// clobbered or dropped; deletions propagate only via tombstones (targeted
    /// removal of files the user actually deleted), never a blind mirror.
    func syncToCloud(settings: RenderSettings,
                     presetManager: PresetManager,
                     animationManager: AnimationManager?) {
        guard let folder = cloudFolderURL else {
            lastError = "iCloud Drive is not available."
            return
        }
        guard !isBusy else { return }

        isBusy = true
        lastError = nil

        // Snapshot data on main actor.
        // We intentionally upload ALL visible scenes (defaults + user-edited
        // overrides + user scenes) so users can browse every preset/animation
        // in iCloud Drive on devices that don't have the app installed.
        let settingsPayload = SettingsBackupPayload(from: settings)
        let presets = presetManager.presets
        let scenes = animationManager?.scenes ?? []
        // Snapshot local deletions so the sync can push them to the cloud (and
        // reconcile against deletions other devices pushed). Written back below.
        let localPresetTombstones = TombstoneStore.presets.tombstones
        let localSceneTombstones = TombstoneStore.scenes.tombstones

        Task { [folder] in
            let result = await Self.performSync(
                to: folder,
                settingsPayload: settingsPayload,
                presets: presets,
                scenes: scenes,
                localPresetTombstones: localPresetTombstones,
                localSceneTombstones: localSceneTombstones
            )
            switch result {
            case .success(let outcome):
                self.lastSyncDate = outcome.date
                // Persist the reconciled tombstone set (may have grown from
                // cloud deletions, or shrunk where an item was resurrected).
                TombstoneStore.presets.replaceAll(outcome.presetTombstones)
                TombstoneStore.scenes.replaceAll(outcome.sceneTombstones)
            case .failure(let error):
                self.lastError = error.localizedDescription
            }
            self.isBusy = false
        }
    }

    private struct SyncOutcome: Sendable {
        let date: Date
        let presetTombstones: [BackupTombstone]
        let sceneTombstones: [BackupTombstone]
    }

    private nonisolated static func performSync(
        to folder: URL,
        settingsPayload: SettingsBackupPayload,
        presets: [FractalPreset],
        scenes: [AnimationScene],
        localPresetTombstones: [BackupTombstone],
        localSceneTombstones: [BackupTombstone]
    ) async -> Result<SyncOutcome, Error> {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let fm = FileManager.default

        do {
            // ── Settings ─────────────────────────────────────────────────
            let settingsDir = folder.appendingPathComponent(settingsSubdir, isDirectory: true)
            try fm.createDirectory(at: settingsDir, withIntermediateDirectories: true)
            let settingsData = try encoder.encode(settingsPayload)
            try settingsData.write(to: settingsDir.appendingPathComponent(settingsFile),
                                   options: .atomic)

            // ── Presets (mirrors Examples layout: Scenes / Music Presets) ──
            let scenesDir = folder.appendingPathComponent(scenesSubdir, isDirectory: true)
            let musicPresetsDir = folder.appendingPathComponent(musicPresetsSubdir, isDirectory: true)
            try fm.createDirectory(at: scenesDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: musicPresetsDir, withIntermediateDirectories: true)
            // RECONCILE with the cloud BEFORE writing: a "Back Up Now" must not
            // overwrite a newer copy another device pushed, nor drop cloud-only
            // presets — and it must PROPAGATE deletions (local + cloud tombstones)
            // by targeted file removal, not a blind mirror. Read both folders +
            // legacy flat .threshmp in Scenes/, keeping each file's URL so a
            // tombstoned preset can be deleted by id regardless of its filename.
            let presetExts = ThresholdExportFormat.extensions(in: .preset)
            let cloudPresetFiles: [(url: URL, item: FractalPreset)] =
                decodeAllWithURLs(in: scenesDir, extensions: presetExts, decoder: decoder)
                + decodeAllWithURLs(in: musicPresetsDir, extensions: presetExts, decoder: decoder)
            let cloudPresetTombstones = readTombstones(
                folder.appendingPathComponent(presetTombstonesFile), decoder: decoder)
            let presetResult = BackupMerge.reconcile(
                local: presets, cloud: cloudPresetFiles.map(\.item),
                localTombstones: localPresetTombstones, cloudTombstones: cloudPresetTombstones,
                timestamp: { $0.updatedAt })
            let survivingPresetIDs = Set(presetResult.items.map(\.id))
            let tombstonedPresetIDs = Set(presetResult.tombstones.map(\.id))
            // Targeted delete: remove any cloud file whose id is tombstoned and
            // did not survive the reconcile (matched by decoded id, so a rename
            // can't hide it).
            for file in cloudPresetFiles
            where tombstonedPresetIDs.contains(file.item.id) && !survivingPresetIDs.contains(file.item.id) {
                try? fm.removeItem(at: file.url)
            }
            for preset in presetResult.items {
                let hasMusic = !(preset.musicReactiveMappings?.isEmpty ?? true)
                let format = ThresholdExportFormat.preset(hasMusic: hasMusic)
                let dir = hasMusic ? musicPresetsDir : scenesDir
                let fileName = sanitizedFileName(preset.name, id: preset.id, ext: format.ext)
                let url = dir.appendingPathComponent(fileName)
                let data = try encoder.encode(preset)
                try data.write(to: url, options: .atomic)
            }
            try writeTombstones(presetResult.tombstones,
                                to: folder.appendingPathComponent(presetTombstonesFile),
                                encoder: encoder)

            // ── Animations ───────────────────────────────────────────────
            let animDir = folder.appendingPathComponent(animationsSubdir, isDirectory: true)
            try fm.createDirectory(at: animDir, withIntermediateDirectories: true)
            // Same reconcile (newest-wins by modifiedAt + tombstone-driven deletion).
            let animExts = ThresholdExportFormat.extensions(in: .animation)
            let cloudSceneFiles: [(url: URL, item: AnimationScene)] =
                decodeAllWithURLs(in: animDir, extensions: animExts, decoder: decoder)
            let cloudSceneTombstones = readTombstones(
                folder.appendingPathComponent(sceneTombstonesFile), decoder: decoder)
            let sceneResult = BackupMerge.reconcile(
                local: scenes, cloud: cloudSceneFiles.map(\.item),
                localTombstones: localSceneTombstones, cloudTombstones: cloudSceneTombstones,
                timestamp: { $0.modifiedAt })
            let survivingSceneIDs = Set(sceneResult.items.map(\.id))
            let tombstonedSceneIDs = Set(sceneResult.tombstones.map(\.id))
            for file in cloudSceneFiles
            where tombstonedSceneIDs.contains(file.item.id) && !survivingSceneIDs.contains(file.item.id) {
                try? fm.removeItem(at: file.url)
            }
            for scene in sceneResult.items {
                let ext = ThresholdExportFormat.animation(hasSong: scene.attachedSong != nil).ext
                let fileName = sanitizedFileName(scene.name, id: scene.id, ext: ext)
                let url = animDir.appendingPathComponent(fileName)
                let data = try encoder.encode(scene)
                try data.write(to: url, options: .atomic)
            }
            try writeTombstones(sceneResult.tombstones,
                                to: folder.appendingPathComponent(sceneTombstonesFile),
                                encoder: encoder)

            // ── Metadata ─────────────────────────────────────────────────
            let meta = BackupMetadata(date: Date(),
                                      presetsCount: presetResult.items.count,
                                      scenesCount: sceneResult.items.count)
            let metaData = try encoder.encode(meta)
            try metaData.write(to: folder.appendingPathComponent(metadataFile),
                               options: .atomic)
            return .success(SyncOutcome(date: meta.date,
                                        presetTombstones: presetResult.tombstones,
                                        sceneTombstones: sceneResult.tombstones))
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Restore (Pull)

    private struct RestoredData: Sendable {
        let settings: SettingsBackupPayload?
        let presets: [FractalPreset]
        let scenes: [AnimationScene]
        let presetTombstones: [BackupTombstone]
        let sceneTombstones: [BackupTombstone]
    }

    /// Reads settings, presets, and animation scenes from iCloud Drive and
    /// applies them, replacing local user data.
    func restoreFromCloud(into settings: RenderSettings,
                          presetManager: PresetManager,
                          animationManager: AnimationManager?) {
        guard let folder = cloudFolderURL else {
            lastError = "iCloud Drive is not available."
            return
        }
        guard !isBusy else { return }

        isBusy = true
        lastError = nil

        Task { [folder] in
            let result = await Self.performRestore(from: folder)
            switch result {
            case .success(let restored):
                // Safety: snapshot current local presets AND animation scenes
                // before any destructive replace, so an accidental restore (or
                // an empty/stale cloud) can never permanently lose local-only
                // data. Recoverable from each manager's Backups directory.
                presetManager.backupCurrentPresetsNow()
                animationManager?.backupCurrentScenesNow()

                if let payload = restored.settings {
                    payload.apply(to: settings)
                    SettingsPersistence.saveAll(from: settings)
                }
                // RECONCILE cloud into local rather than replacing: never drops
                // presets/scenes that exist only on this device (not yet backed
                // up), keeps the newer of any conflicting edit, and APPLIES
                // deletions from either side via tombstones. Runs whenever the
                // cloud has items OR tombstones to contribute (an empty cloud with
                // no tombstones is a no-op, preserving local data).
                if !restored.presets.isEmpty || !restored.presetTombstones.isEmpty {
                    let result = BackupMerge.reconcile(
                        local: presetManager.presets, cloud: restored.presets,
                        localTombstones: TombstoneStore.presets.tombstones,
                        cloudTombstones: restored.presetTombstones,
                        timestamp: { $0.updatedAt })
                    presetManager.replaceAll(with: result.items)
                    TombstoneStore.presets.replaceAll(result.tombstones)
                }
                // Scenes: reconcile only USER scenes (bundled defaults are recreated
                // on launch and live as overrides if edited). Keep local-only user
                // scenes; apply cloud deletions.
                if !restored.scenes.isEmpty || !restored.sceneTombstones.isEmpty {
                    let cloudUser = restored.scenes.filter { !DefaultScenes.isDefault($0.id) }
                    let localUser = (animationManager?.scenes ?? []).filter { !DefaultScenes.isDefault($0.id) }
                    let result = BackupMerge.reconcile(
                        local: localUser, cloud: cloudUser,
                        localTombstones: TombstoneStore.scenes.tombstones,
                        cloudTombstones: restored.sceneTombstones,
                        timestamp: { $0.modifiedAt })
                    animationManager?.replaceUserScenes(with: result.items)
                    TombstoneStore.scenes.replaceAll(result.tombstones)
                }
                self.lastSyncDate = Date()
            case .failure(let error):
                self.lastError = error.localizedDescription
            }
            self.isBusy = false
        }
    }

    private nonisolated static func performRestore(from folder: URL) async -> Result<RestoredData, Error> {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let fm = FileManager.default

        do {
            // ── Settings ─────────────────────────────────────────────────
            var restoredSettings: SettingsBackupPayload?
            let settingsURL = folder
                .appendingPathComponent(settingsSubdir, isDirectory: true)
                .appendingPathComponent(settingsFile)
            try? fm.startDownloadingUbiquitousItem(at: settingsURL)
            if fm.fileExists(atPath: settingsURL.path) {
                let data = try Data(contentsOf: settingsURL)
                restoredSettings = try decoder.decode(SettingsBackupPayload.self, from: data)
            }

            // ── Presets ─────────────────────────────────────────────────
            // Read both "Scenes/" and "Music Presets/". "Scenes/" is also scanned for
            // .threshmp so presets backed up before the Music Presets split (legacy
            // flat layout) still restore. De-dupe by id keeping the newest updatedAt
            // (a preset can appear in both places mid-migration).
            let scenesDir = folder.appendingPathComponent(scenesSubdir, isDirectory: true)
            let musicPresetsDir = folder.appendingPathComponent(musicPresetsSubdir, isDirectory: true)
            let rawPresets: [FractalPreset] =
                decodeAll(in: scenesDir, extensions: ThresholdExportFormat.extensions(in: .preset), decoder: decoder)
                + decodeAll(in: musicPresetsDir, extensions: ThresholdExportFormat.extensions(in: .preset), decoder: decoder)
            var presetsByID: [UUID: FractalPreset] = [:]
            for p in rawPresets where (presetsByID[p.id]?.updatedAt ?? .distantPast) < p.updatedAt {
                presetsByID[p.id] = p
            }
            let presets = Array(presetsByID.values)

            // ── Animations ───────────────────────────────────────────────
            let animDir = folder.appendingPathComponent(animationsSubdir, isDirectory: true)
            let scenes: [AnimationScene] = decodeAll(in: animDir,
                                                     extensions: ThresholdExportFormat.extensions(in: .animation),
                                                     decoder: decoder)

            // ── Tombstones (deletions to apply on this device) ────────────
            let presetTombstones = readTombstones(
                folder.appendingPathComponent(presetTombstonesFile), decoder: decoder)
            let sceneTombstones = readTombstones(
                folder.appendingPathComponent(sceneTombstonesFile), decoder: decoder)

            return .success(RestoredData(settings: restoredSettings,
                                         presets: presets,
                                         scenes: scenes,
                                         presetTombstones: presetTombstones,
                                         sceneTombstones: sceneTombstones))
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Open in Files App

    /// Opens the Threshold iCloud Drive folder in the system Files app.
    /// Uses the documented `shareddocuments://` URL scheme on iOS/visionOS.
    func openInFilesApp() {
        guard let folder = cloudFolderURL else {
            lastError = "iCloud Drive is not available."
            return
        }
        #if canImport(UIKit)
        // shareddocuments:// expects an absolute path component.
        var components = URLComponents()
        components.scheme = "shareddocuments"
        components.path = folder.path
        guard let url = components.url else { return }
        UIApplication.shared.open(url, options: [:]) { [weak self] success in
            Task { @MainActor in
                if !success {
                    self?.lastError = "Could not open Files app."
                }
            }
        }
        #endif
    }

    // MARK: - Metadata

    private func loadMetadata() {
        guard let folder = cloudFolderURL else { return }
        let url = folder.appendingPathComponent(Self.metadataFile)
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let meta = try? decoder.decode(BackupMetadata.self, from: data) {
            lastSyncDate = meta.date
        }
    }

    // MARK: - File Helpers

    /// Builds a filename of the form `Sanitized_Name_<short-id>.<ext>` so that
    /// renames don't collide with other items sharing the same display name.
    private nonisolated static func sanitizedFileName(_ name: String, id: UUID, ext: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        let cleaned = name.components(separatedBy: invalid).joined()
            .replacingOccurrences(of: " ", with: "_")
        let trimmed = cleaned.isEmpty ? "Untitled" : String(cleaned.prefix(64))
        let shortID = String(id.uuidString.prefix(8))
        return "\(trimmed)_\(shortID).\(ext)"
    }

    // NOTE: the old `pruneFiles` (blind "delete every cloud file not in the local
    // set") is gone — it could silently wipe presets across devices or after a
    // stale/empty local load. Deletions now flow through tombstones: performSync
    // removes only the specific cloud files whose id is tombstoned and did not
    // survive the reconcile (see the targeted-delete loops above).

    private nonisolated static func decodeAll<T: Decodable>(in dir: URL,
                                                            extensions: [String],
                                                            decoder: JSONDecoder) -> [T] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        var results: [T] = []
        for url in contents where extensions.contains(url.pathExtension) {
            try? fm.startDownloadingUbiquitousItem(at: url)
            guard let data = try? Data(contentsOf: url) else { continue }
            if let decoded = try? decoder.decode(T.self, from: data) {
                results.append(decoded)
            }
        }
        return results
    }

    /// Like `decodeAll`, but keeps each item paired with the file it came from so
    /// the sync can delete a tombstoned item by decoded id (robust to renames).
    private nonisolated static func decodeAllWithURLs<T: Decodable & Identifiable>(
        in dir: URL, extensions: [String], decoder: JSONDecoder
    ) -> [(url: URL, item: T)] where T.ID == UUID {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        var results: [(url: URL, item: T)] = []
        for url in contents where extensions.contains(url.pathExtension) {
            try? fm.startDownloadingUbiquitousItem(at: url)
            guard let data = try? Data(contentsOf: url) else { continue }
            if let decoded = try? decoder.decode(T.self, from: data) {
                results.append((url, decoded))
            }
        }
        return results
    }

    /// Read a cloud tombstone file (missing/undecodable → empty, never fatal).
    private nonisolated static func readTombstones(_ url: URL, decoder: JSONDecoder) -> [BackupTombstone] {
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? decoder.decode([BackupTombstone].self, from: data)) ?? []
    }

    /// Write the merged tombstone set for a kind back to the cloud.
    private nonisolated static func writeTombstones(_ tombstones: [BackupTombstone],
                                                    to url: URL,
                                                    encoder: JSONEncoder) throws {
        let data = try encoder.encode(tombstones)
        try data.write(to: url, options: .atomic)
    }
}

// MARK: - Backup Payloads

/// Bundles all 8 config domains into a single Codable envelope.
private struct SettingsBackupPayload: Codable, Sendable {
    var geometry: GeometryConfig
    var quality: QualityConfig
    var color: ColorConfig
    var lighting: LightingConfig
    var audioReactive: AudioReactiveConfig
    var gesture: GestureConfig
    var safetyBubble: SafetyBubbleConfig
    var display: DisplayConfig

    init(from settings: RenderSettings) {
        geometry      = settings.geometryConfig
        quality       = settings.qualityConfig
        color         = settings.colorConfig
        lighting      = settings.lightingConfig
        audioReactive = settings.audioReactiveConfig
        gesture       = settings.gestureConfig
        safetyBubble  = settings.safetyBubbleConfig
        display       = settings.displayConfig
    }

    func apply(to settings: RenderSettings) {
        settings.geometryConfig      = geometry
        settings.qualityConfig       = quality
        settings.colorConfig         = color
        settings.lightingConfig      = lighting
        settings.audioReactiveConfig = audioReactive
        settings.gestureConfig       = gesture
        settings.safetyBubbleConfig  = safetyBubble
        settings.displayConfig       = display
    }
}

private struct BackupMetadata: Codable, Sendable {
    let date: Date
    let presetsCount: Int
    let scenesCount: Int
}
