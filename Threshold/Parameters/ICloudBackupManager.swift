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
//      iCloud Drive/
//        └── Threshold/
//            ├── Settings/
//            │   └── settings.json
//            ├── Scenes/
//            │   ├── Bright_Preset.threshscene
//            │   └── Cosmic_Drift.threshscene
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
    private nonisolated static let settingsSubdir   = "Settings"
    private nonisolated static let scenesSubdir     = "Scenes"
    private nonisolated static let animationsSubdir = "Animations"
    private nonisolated static let settingsFile     = "settings.json"
    private nonisolated static let metadataFile     = ".metadata.json"

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
        for sub in [settingsSubdir, scenesSubdir, animationsSubdir] {
            let subURL = docs.appendingPathComponent(sub, isDirectory: true)
            try? FileManager.default.createDirectory(at: subURL, withIntermediateDirectories: true)
        }
        return docs
    }

    // MARK: - Sync (Push)

    /// Writes current settings, presets, and user animation scenes to iCloud
    /// Drive. Existing files in the iCloud folders are removed for items that
    /// no longer exist locally so the cloud mirrors the local state.
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

        Task { [folder] in
            let result = await Self.performSync(
                to: folder,
                settingsPayload: settingsPayload,
                presets: presets,
                scenes: scenes
            )
            switch result {
            case .success(let date):
                self.lastSyncDate = date
            case .failure(let error):
                self.lastError = error.localizedDescription
            }
            self.isBusy = false
        }
    }

    private nonisolated static func performSync(
        to folder: URL,
        settingsPayload: SettingsBackupPayload,
        presets: [FractalPreset],
        scenes: [AnimationScene]
    ) async -> Result<Date, Error> {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let fm = FileManager.default

        do {
            // ── Settings ─────────────────────────────────────────────────
            let settingsDir = folder.appendingPathComponent(settingsSubdir, isDirectory: true)
            try fm.createDirectory(at: settingsDir, withIntermediateDirectories: true)
            let settingsData = try encoder.encode(settingsPayload)
            try settingsData.write(to: settingsDir.appendingPathComponent(settingsFile),
                                   options: .atomic)

            // ── Scenes (Fractal Presets) ────────────────────────────────
            let scenesDir = folder.appendingPathComponent(scenesSubdir, isDirectory: true)
            try fm.createDirectory(at: scenesDir, withIntermediateDirectories: true)
            for preset in presets {
                let hasMusic = !(preset.musicReactiveMappings?.isEmpty ?? true)
                let ext = ThresholdExportFormat.preset(hasMusic: hasMusic).ext
                let fileName = sanitizedFileName(preset.name, id: preset.id, ext: ext)
                let url = scenesDir.appendingPathComponent(fileName)
                let data = try encoder.encode(preset)
                try data.write(to: url, options: .atomic)
            }
            // NON-DESTRUCTIVE sync: we intentionally do NOT prune cloud files that are
            // absent from the local set. The old blind mirror let a stale/empty local
            // list (a failed decode falling back to an older backup) or a second device
            // silently DELETE presets from the cloud. Deletions will propagate via
            // tombstones, not by wiping whatever isn't local at this instant.
            // (Full merge + tombstones is being built incrementally; this is step 1.)

            // ── Animations ───────────────────────────────────────────────
            let animDir = folder.appendingPathComponent(animationsSubdir, isDirectory: true)
            try fm.createDirectory(at: animDir, withIntermediateDirectories: true)
            for scene in scenes {
                let ext = ThresholdExportFormat.animation(hasSong: scene.attachedSong != nil).ext
                let fileName = sanitizedFileName(scene.name, id: scene.id, ext: ext)
                let url = animDir.appendingPathComponent(fileName)
                let data = try encoder.encode(scene)
                try data.write(to: url, options: .atomic)
            }
            // Non-destructive (see the presets block above): no prune of cloud-only
            // animation files. Deletions will come via tombstones, not a blind mirror.

            // ── Metadata ─────────────────────────────────────────────────
            let meta = BackupMetadata(date: Date(),
                                      presetsCount: presets.count,
                                      scenesCount: scenes.count)
            let metaData = try encoder.encode(meta)
            try metaData.write(to: folder.appendingPathComponent(metadataFile),
                               options: .atomic)
            return .success(meta.date)
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Restore (Pull)

    private struct RestoredData: Sendable {
        let settings: SettingsBackupPayload?
        let presets: [FractalPreset]
        let scenes: [AnimationScene]
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
                if !restored.presets.isEmpty {
                    presetManager.replaceAll(with: restored.presets)
                }
                // Only replace USER scenes from cloud — bundled defaults are
                // recreated on launch and live as overrides if the user edited
                // them. Filter out anything matching a default scene ID.
                if !restored.scenes.isEmpty {
                    let userOnly = restored.scenes.filter { !DefaultScenes.isDefault($0.id) }
                    if !userOnly.isEmpty {
                        animationManager?.replaceUserScenes(with: userOnly)
                    }
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

            // ── Scenes (Presets) ────────────────────────────────────────
            let scenesDir = folder.appendingPathComponent(scenesSubdir, isDirectory: true)
            let presets: [FractalPreset] = decodeAll(in: scenesDir,
                                                     extensions: ThresholdExportFormat.extensions(in: .preset),
                                                     decoder: decoder)

            // ── Animations ───────────────────────────────────────────────
            let animDir = folder.appendingPathComponent(animationsSubdir, isDirectory: true)
            let scenes: [AnimationScene] = decodeAll(in: animDir,
                                                     extensions: ThresholdExportFormat.extensions(in: .animation),
                                                     decoder: decoder)

            return .success(RestoredData(settings: restoredSettings,
                                         presets: presets,
                                         scenes: scenes))
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

    // NOTE: `pruneFiles` (blind "delete every cloud file not in the local set") was
    // removed — it was the mechanism that could silently wipe presets across devices
    // or after a stale/empty local load. Deletions will be reintroduced as targeted,
    // tombstone-driven removals once the merge is built.

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
