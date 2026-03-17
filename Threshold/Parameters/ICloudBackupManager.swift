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
    private static let folderName = "threshold"
    private static let settingsFile = "settings.json"
    private static let presetsFile  = "presets.json"
    private static let scenesFile   = "scenes.json"
    private static let metadataFile = "backup_metadata.json"

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
        Task.detached { [weak self] in
            // url(forUbiquityContainerIdentifier:) can block — run off-main.
            guard let containerURL = FileManager.default
                    .url(forUbiquityContainerIdentifier: nil) else {
                await MainActor.run { self?.isAvailable = false }
                return
            }

            let folder = containerURL
                .appendingPathComponent("Documents", isDirectory: true)
                .appendingPathComponent(Self.folderName, isDirectory: true)

            // Ensure the directory exists (FileManager creates intermediates).
            try? FileManager.default.createDirectory(
                at: folder, withIntermediateDirectories: true)

            await MainActor.run {
                self?.cloudFolderURL = folder
                self?.isAvailable = true
                self?.loadMetadata()
            }
        }
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

        Task.detached { [weak self, encoder] in
            do {
                // Settings
                let settingsData = try encoder.encode(settingsPayload)
                try settingsData.write(to: folder.appendingPathComponent(Self.settingsFile), options: .atomic)

                // Presets
                let presetsData = try encoder.encode(presets)
                try presetsData.write(to: folder.appendingPathComponent(Self.presetsFile), options: .atomic)

                // User scenes
                let scenesData = try encoder.encode(scenes)
                try scenesData.write(to: folder.appendingPathComponent(Self.scenesFile), options: .atomic)

                // Metadata
                let meta = BackupMetadata(date: Date(), settingsCount: 8, presetsCount: presets.count, scenesCount: scenes.count)
                let metaData = try encoder.encode(meta)
                try metaData.write(to: folder.appendingPathComponent(Self.metadataFile), options: .atomic)

                await MainActor.run {
                    self?.lastBackupDate = meta.date
                    self?.isBusy = false
                }
            } catch {
                await MainActor.run {
                    self?.lastError = error.localizedDescription
                    self?.isBusy = false
                }
            }
        }
    }

    // MARK: - Restore

    /// Reads settings, presets, and scenes from iCloud Drive and applies them.
    func restore(into settings: RenderSettings, presetManager: PresetManager, animationManager: AnimationManager) {
        guard let folder = cloudFolderURL else {
            lastError = "iCloud Drive is not available"
            return
        }
        guard !isBusy else { return }

        isBusy = true
        lastError = nil

        Task.detached { [weak self, decoder] in
            do {
                // Settings
                let settingsURL = folder.appendingPathComponent(Self.settingsFile)
                if FileManager.default.fileExists(atPath: settingsURL.path) {
                    let data = try Data(contentsOf: settingsURL)
                    let payload = try decoder.decode(SettingsBackupPayload.self, from: data)
                    await MainActor.run {
                        payload.apply(to: settings)
                        SettingsPersistence.saveAll(from: settings)
                    }
                }

                // Presets
                let presetsURL = folder.appendingPathComponent(Self.presetsFile)
                if FileManager.default.fileExists(atPath: presetsURL.path) {
                    let data = try Data(contentsOf: presetsURL)
                    let presets = try decoder.decode([FractalPreset].self, from: data)
                    await MainActor.run {
                        presetManager.replaceAll(with: presets)
                    }
                }

                // Scenes
                let scenesURL = folder.appendingPathComponent(Self.scenesFile)
                if FileManager.default.fileExists(atPath: scenesURL.path) {
                    let data = try Data(contentsOf: scenesURL)
                    let scenes = try decoder.decode([AnimationScene].self, from: data)
                    await MainActor.run {
                        animationManager.replaceUserScenes(with: scenes)
                    }
                }

                await MainActor.run {
                    self?.isBusy = false
                }
            } catch {
                await MainActor.run {
                    self?.lastError = error.localizedDescription
                    self?.isBusy = false
                }
            }
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
