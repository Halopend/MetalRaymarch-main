//
//  ICloudBackupManager.swift
//  Threshold
//
//  Backs up and restores user settings, presets, and scenes to iCloud Drive
//  under a "threshold" folder.  Uses FileManager ubiquity container so files
//  are visible in Files.app and sync automatically across devices.
//

import Foundation
import Observation

@Observable
@MainActor
final class ICloudBackupManager {

    // MARK: - Public State

    private(set) var isAvailable: Bool = false
    private(set) var lastBackupDate: Date?
    private(set) var isBusy: Bool = false
    private(set) var lastError: String?

    // MARK: - Constants

    /// Folder name inside the ubiquity container's Documents directory.
    private nonisolated(unsafe) static let folderName = "threshold"
    private nonisolated(unsafe) static let settingsFile = "settings.json"
    private nonisolated(unsafe) static let presetsFile  = "presets.json"
    private nonisolated(unsafe) static let scenesFile   = "scenes.json"
    private nonisolated(unsafe) static let metadataFile = "backup_metadata.json"

    // MARK: - Private

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Resolved iCloud folder URL (nil when iCloud is unavailable).
    private var cloudFolderURL: URL?

    // MARK: - Init

    init() {
        resolveContainer()
    }

    // MARK: - Container Resolution

    /// Discovers the ubiquity container on a background thread and caches the
    /// resolved folder URL.  Safe to call multiple times.
    func resolveContainer() {
        Task {
            let folder = await Self.discoverCloudFolder()
            if let folder {
                self.cloudFolderURL = folder
                self.isAvailable = true
                self.loadMetadata()
            } else {
                self.isAvailable = false
            }
        }
    }

    /// Blocking ubiquity lookup — runs off main actor via nonisolated async.
    private nonisolated static func discoverCloudFolder() async -> URL? {
        guard let containerURL = FileManager.default
                .url(forUbiquityContainerIdentifier: nil) else {
            return nil
        }
        let folder = containerURL
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
        try? FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true)
        return folder
    }

    // MARK: - Backup

    /// Writes current settings, presets, and user scenes to iCloud Drive.
    func backup(settings: RenderSettings, presetManager: PresetManager, animationManager: AnimationManager) {
        guard let folder = cloudFolderURL else {
            lastError = "iCloud Drive is not available"
            return
        }
        guard !isBusy else { return }

        isBusy = true
        lastError = nil

        // Gather data on main actor (settings uses os_unfair_lock internally).
        let settingsPayload = SettingsBackupPayload(from: settings)
        let presets = presetManager.presets
        let scenes = animationManager.userScenes

        Task {
            let result = await Self.performBackup(
                to: folder, settingsPayload: settingsPayload,
                presets: presets, scenes: scenes
            )
            switch result {
            case .success(let date):
                self.lastBackupDate = date
            case .failure(let error):
                self.lastError = error.localizedDescription
            }
            self.isBusy = false
        }
    }

    /// File I/O for backup — runs off main actor.
    private nonisolated static func performBackup(
        to folder: URL,
        settingsPayload: SettingsBackupPayload,
        presets: [FractalPreset],
        scenes: [AnimationScene]
    ) async -> Result<Date, Error> {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        do {
            let settingsData = try encoder.encode(settingsPayload)
            try settingsData.write(to: folder.appendingPathComponent(settingsFile), options: .atomic)

            let presetsData = try encoder.encode(presets)
            try presetsData.write(to: folder.appendingPathComponent(presetsFile), options: .atomic)

            let scenesData = try encoder.encode(scenes)
            try scenesData.write(to: folder.appendingPathComponent(scenesFile), options: .atomic)

            let meta = BackupMetadata(date: Date(), settingsCount: 8, presetsCount: presets.count, scenesCount: scenes.count)
            let metaData = try encoder.encode(meta)
            try metaData.write(to: folder.appendingPathComponent(metadataFile), options: .atomic)

            return .success(meta.date)
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Restore

    private struct RestoredData: Sendable {
        let settings: SettingsBackupPayload?
        let presets: [FractalPreset]?
        let scenes: [AnimationScene]?
    }

    /// Reads settings, presets, and scenes from iCloud Drive and applies them.
    func restore(into settings: RenderSettings, presetManager: PresetManager, animationManager: AnimationManager) {
        guard let folder = cloudFolderURL else {
            lastError = "iCloud Drive is not available"
            return
        }
        guard !isBusy else { return }

        isBusy = true
        lastError = nil

        Task {
            let result = await Self.performRestore(from: folder)
            switch result {
            case .success(let restored):
                if let payload = restored.settings {
                    payload.apply(to: settings)
                    SettingsPersistence.saveAll(from: settings)
                }
                if let presets = restored.presets {
                    presetManager.replaceAll(with: presets)
                }
                if let scenes = restored.scenes {
                    animationManager.replaceUserScenes(with: scenes)
                }
            case .failure(let error):
                self.lastError = error.localizedDescription
            }
            self.isBusy = false
        }
    }

    /// File I/O for restore — runs off main actor.
    private nonisolated static func performRestore(from folder: URL) async -> Result<RestoredData, Error> {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        do {
            var restoredSettings: SettingsBackupPayload?
            var restoredPresets: [FractalPreset]?
            var restoredScenes: [AnimationScene]?

            let settingsURL = folder.appendingPathComponent(settingsFile)
            if FileManager.default.fileExists(atPath: settingsURL.path) {
                let data = try Data(contentsOf: settingsURL)
                restoredSettings = try decoder.decode(SettingsBackupPayload.self, from: data)
            }

            let presetsURL = folder.appendingPathComponent(presetsFile)
            if FileManager.default.fileExists(atPath: presetsURL.path) {
                let data = try Data(contentsOf: presetsURL)
                restoredPresets = try decoder.decode([FractalPreset].self, from: data)
            }

            let scenesURL = folder.appendingPathComponent(scenesFile)
            if FileManager.default.fileExists(atPath: scenesURL.path) {
                let data = try Data(contentsOf: scenesURL)
                restoredScenes = try decoder.decode([AnimationScene].self, from: data)
            }

            return .success(RestoredData(settings: restoredSettings, presets: restoredPresets, scenes: restoredScenes))
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Metadata

    private func loadMetadata() {
        guard let folder = cloudFolderURL else { return }
        let url = folder.appendingPathComponent(Self.metadataFile)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let meta = try? decoder.decode(BackupMetadata.self, from: data) else { return }
        lastBackupDate = meta.date
    }
}

// MARK: - Backup Payload

/// Bundles all 8 config domains into a single Codable envelope.
private struct SettingsBackupPayload: Codable {
    var geometry: GeometryConfig
    var quality: QualityConfig
    var color: ColorConfig
    var lighting: LightingConfig
    var audioReactive: AudioReactiveConfig
    var gesture: GestureConfig
    var safetyBubble: SafetyBubbleConfig
    var display: DisplayConfig

    init(from settings: RenderSettings) {
        geometry     = settings.geometryConfig
        quality      = settings.qualityConfig
        color        = settings.colorConfig
        lighting     = settings.lightingConfig
        audioReactive = settings.audioReactiveConfig
        gesture      = settings.gestureConfig
        safetyBubble = settings.safetyBubbleConfig
        display      = settings.displayConfig
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

private struct BackupMetadata: Codable {
    let date: Date
    let settingsCount: Int
    let presetsCount: Int
    let scenesCount: Int
}
