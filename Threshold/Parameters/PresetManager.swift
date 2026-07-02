//
//  PresetManager.swift
//  MetalProject
//
//  Created on January 11, 2026.
//

import SwiftUI
import Foundation

/// Single source of truth for Threshold's shareable file formats. The export
/// writers (PresetManager, AnimationManager, EmbeddedFormulaContainer) and the
/// export-tab format reference both read from here; the UTType declarations in
/// the platform Info.plists must mirror these extensions.
enum ThresholdExportFormat: CaseIterable, Sendable {
    case scenePreset
    case musicPreset
    case animationScene
    case musicVideoScene
    case customFormula

    /// Filename extension without the leading dot.
    var ext: String {
        switch self {
        case .scenePreset: return "threshscene"
        case .musicPreset: return "threshmp"
        case .animationScene: return "threshanim"
        case .musicVideoScene: return "threshanimv"
        case .customFormula: return "threshfx"
        }
    }

    /// One-line description shown in the export tab's format reference.
    var summary: String {
        switch self {
        case .scenePreset: return "Fractal preset (settings snapshot)"
        case .musicPreset: return "Music-reactive preset (audio mappings)"
        case .animationScene: return "Animation scene (keyframe sequence)"
        case .musicVideoScene: return "Animation + music (music video)"
        case .customFormula: return "Custom formula (standalone shader)"
        }
    }
}

/// Runs an export (JSON encode + temp-file write, tens of ms for large
/// presets) off the main actor and delivers the URL back on it for sheet
/// presentation — keeps the tap animation from hitching.
func exportOffMain(_ produce: @escaping @Sendable () -> URL?,
                   onReady: @escaping @MainActor (URL) -> Void) {
    Task.detached(priority: .userInitiated) {
        guard let url = produce() else { return }
        await onReady(url)
    }
}

/// Manages saving and loading of presets
@MainActor
@Observable
class PresetManager {
    private(set) var presets: [FractalPreset] = []
    private static var bundledPresetsCache: [FractalPreset]?
    private let maxBackupCount: Int? = nil  // nil = unlimited retention
    private var pendingSaveTask: Task<Void, Never>?
    private let saveDebounceNanoseconds: UInt64 = 250_000_000
    private var lastBackupAt: Date?
    private let backupInterval: TimeInterval = 30
    @ObservationIgnored private let presetDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
    @ObservationIgnored private let presetEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private static let backupTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated static func sanitizedExportFileNameStem(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:\n\r")
        let cleaned = name.components(separatedBy: invalid).joined()
            .replacingOccurrences(of: " ", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "._- "))
        return cleaned.isEmpty ? "Untitled" : String(cleaned.prefix(64))
    }
    
    /// URL for the presets directory in the app's documents
    private var presetsDirectory: URL {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let presetsPath = documentsPath.appendingPathComponent("FractalPresets", isDirectory: true)
        
        // Create directory if it doesn't exist
        if !FileManager.default.fileExists(atPath: presetsPath.path) {
            try? FileManager.default.createDirectory(at: presetsPath, withIntermediateDirectories: true)
        }
        
        return presetsPath
    }
    
    private var presetsFileURL: URL {
        presetsDirectory.appendingPathComponent("presets.json")
    }

    /// Directory for timestamped backups
    private var backupsDirectory: URL {
        let dir = presetsDirectory.appendingPathComponent("Backups", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }
    
    init() {
        loadPresets()
    }

    private static func bundledPresets(forceRefresh: Bool = false) -> [FractalPreset] {
        if forceRefresh || bundledPresetsCache == nil {
            bundledPresetsCache = loadBundledPresets()
        }
        return bundledPresetsCache ?? []
    }

    private func mergedPresets(local localPresets: [FractalPreset], bundled bundledPresets: [FractalPreset]? = nil) -> [FractalPreset] {
        var mergedByName: [String: FractalPreset] = [:]
        let resolvedBundledPresets = bundledPresets ?? Self.bundledPresets()

        // Seed with bundled presets, then let local presets override by name.
        for preset in resolvedBundledPresets {
            mergedByName[preset.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] = preset
        }
        for preset in localPresets {
            mergedByName[preset.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] = preset
        }

        return mergedByName.values.sorted { $0.createdAt > $1.createdAt }
    }
    
    private func loadLocalPresetsFromDisk() -> [FractalPreset] {
        let fileURL = presetsFileURL
        var loadedLocalPresets: [FractalPreset] = []

        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                let data = try Data(contentsOf: fileURL)
                loadedLocalPresets = try presetDecoder.decode([FractalPreset].self, from: data)
            } catch {
                print("Failed to load presets: \(error). Trying latest backup…")
                loadedLocalPresets = loadLatestBackupPresets()
            }
        }

        return loadedLocalPresets
    }

    /// Load all presets from disk
    func loadPresets(forceRefreshBundled: Bool = false) {
        let loadedLocalPresets = loadLocalPresetsFromDisk()
        let bundledPresets = Self.bundledPresets(forceRefresh: forceRefreshBundled)

        presets = mergedPresets(local: loadedLocalPresets, bundled: bundledPresets)
        FractalPreset.clearThumbnailCache()
    }

    /// Re-scan bundled preset resources while preserving local on-disk overrides.
    func refreshBundledPresets() {
        let loadedLocalPresets = loadLocalPresetsFromDisk()
        let bundledPresets = Self.bundledPresets(forceRefresh: true)
        presets = mergedPresets(local: loadedLocalPresets, bundled: bundledPresets)
        FractalPreset.clearThumbnailCache()
    }

    /// Attempt to load the most recent backup if the main file is missing or corrupt
    private func loadLatestBackupPresets() -> [FractalPreset] {
        do {
            let backups = try FileManager.default.contentsOfDirectory(at: backupsDirectory, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles)
            let latest = backups.max { (a, b) -> Bool in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da < db
            }
            guard let url = latest else {
                return []
            }
            let data = try Data(contentsOf: url)
            let loaded = try presetDecoder.decode([FractalPreset].self, from: data)
            print("✅ Loaded presets from backup: \(url.lastPathComponent)")
            return loaded
        } catch {
            print("Failed to load presets backup: \(error)")
            return []
        }
    }
    
    /// Save all presets to disk
    private func savePresets() {
        let fileURL = presetsFileURL
        
        do {
            let data = try presetEncoder.encode(presets)
            try data.write(to: fileURL, options: .atomic)
            writeBackup(data: data)
        } catch {
            print("Failed to save presets: \(error)")
        }
    }

    /// Force an immediate timestamped backup of the CURRENT presets, bypassing
    /// the throttle. Call this before any destructive replace (e.g. iCloud
    /// restore) so local-only scenes can always be recovered from Backups/.
    func backupCurrentPresetsNow() {
        guard !presets.isEmpty else { return }
        do {
            let data = try presetEncoder.encode(presets)
            lastBackupAt = nil // defeat the throttle for this safety snapshot
            writeBackup(data: data)
        } catch {
            print("Failed to write pre-restore safety backup: \(error)")
        }
    }

    /// Replace all presets with the given array and persist.
    func replaceAll(with newPresets: [FractalPreset]) {
        presets = newPresets
        savePresets()
    }

    /// Coalesce frequent save calls into one disk write.
    private func scheduleSavePresets() {
        pendingSaveTask?.cancel()
        pendingSaveTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: self.saveDebounceNanoseconds)
            guard !Task.isCancelled else { return }
            self.savePresets()
        }
    }

    /// Write a timestamped backup. Retention is currently unlimited:
    /// `maxBackupCount` is nil, so `pruneBackups` never removes old backups.
    private func writeBackup(data: Data) {
        let now = Date()
        if let lastBackupAt, now.timeIntervalSince(lastBackupAt) < backupInterval {
            return
        }
        self.lastBackupAt = now

        let stamp = Self.backupTimestampFormatter.string(from: now)
        let backupURL = backupsDirectory.appendingPathComponent("presets-\(stamp).json")
        do {
            try data.write(to: backupURL)
            if let limit = maxBackupCount {
                pruneBackups(keeping: limit)
            }
        } catch {
            print("Failed to write presets backup: \(error)")
        }
    }

    /// Keep only the newest N backups to avoid unbounded growth
    private func pruneBackups(keeping count: Int) {
        do {
            let files = try FileManager.default.contentsOfDirectory(at: backupsDirectory, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles)
            let sorted = files.sorted { (a, b) -> Bool in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da > db
            }
            for url in sorted.dropFirst(count) {
                try? FileManager.default.removeItem(at: url)
            }
        } catch {
            print("Failed to prune backups: \(error)")
        }
    }
    
    /// Save current settings as a new preset
    func savePreset(name: String, settings: RenderSettings, thumbnailData: Data? = nil, embeddedFormula: EmbeddedFormula? = nil) {
        let preset = FractalPreset.fromSettings(settings, name: name, thumbnailData: thumbnailData, embeddedFormula: embeddedFormula)
        presets.insert(preset, at: 0) // Add to beginning (newest first)
        scheduleSavePresets()
        
        // Track for analytics with full preset data
        UsageAnalytics.shared.trackPresetSaved(preset: preset)
        

    }
    
    /// Delete a preset
    func deletePreset(_ preset: FractalPreset) {
        presets.removeAll { $0.id == preset.id }
        FractalPreset.clearThumbnailCache(for: preset.id)
        scheduleSavePresets()
    }
    
    /// Delete preset at index
    func deletePreset(at offsets: IndexSet) {
        let removedIDs = offsets.compactMap { index in
            presets.indices.contains(index) ? presets[index].id : nil
        }
        presets.remove(atOffsets: offsets)
        removedIDs.forEach { FractalPreset.clearThumbnailCache(for: $0) }
        scheduleSavePresets()
    }
    
    /// Load a preset's settings
    func loadPreset(_ preset: FractalPreset,
                    into settings: RenderSettings,
                    includePerformance: Bool = true,
                    resetEnvironment: Bool = false) {
        preset.apply(to: settings,
                     includePerformance: includePerformance,
                     resetEnvironment: resetEnvironment)
        // Track for analytics
        UsageAnalytics.shared.trackPresetLoaded(name: preset.name)
    }
    
    /// Export a preset to a file URL.
    /// Uses `.threshmp` for presets with music-reactive mappings, `.threshscene` otherwise.
    /// Nonisolated: encoding + the temp-file write can take tens of ms for
    /// large presets — call it off the main actor (see `exportOffMain`).
    nonisolated static func exportPresetFile(_ preset: FractalPreset) -> URL? {
        let hasMusicMappings = preset.hasMusicReactiveMappings
        let format: ThresholdExportFormat = hasMusicMappings ? .musicPreset : .scenePreset
        let fileName = "\(Self.sanitizedExportFileNameStem(preset.name)).\(format.ext)"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(preset)
            try data.write(to: tempURL)
            return tempURL
        } catch {
            print("Failed to export preset: \(error)")
            return nil
        }
    }

    func decodePreset(from url: URL) throws -> FractalPreset {
        let data = try Data(contentsOf: url)
        return try presetDecoder.decode(FractalPreset.self, from: data)
    }

    @discardableResult
    func importPreset(_ preset: FractalPreset) -> FractalPreset {
        if let existingIndex = presets.firstIndex(where: { $0.id == preset.id }) {
            presets[existingIndex] = preset
        } else {
            presets.insert(preset, at: 0)
        }
        savePresets()
        FractalPreset.clearThumbnailCache(for: preset.id)
        UsageAnalytics.shared.trackPresetSaved(preset: preset)
        return preset
    }

    @discardableResult
    func importPreset(from url: URL) -> FractalPreset? {
        do {
            return importPreset(try decodePreset(from: url))
        } catch {
            print("Failed to import preset from \(url.lastPathComponent): \(error)")
            return nil
        }
    }
    
}

// MARK: - Default Presets (loaded from bundled preset JSON files)
extension PresetManager {
    
    // ─── Bundle-loaded default scenes ────────────────────────────────────
    // Built-in presets are stored as .threshscene / .threshmp JSON files in
    // Examples/Scenes (bundled as app resources). This keeps the
    // preset data in the same format as user exports and avoids
    // hardcoding parameter values in Swift.
    
    private static func loadBundledPresets() -> [FractalPreset] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        // Bundled scene files use either `.threshscene` / `.threshmp` or the
        // double extension `.threshscene.json` / `.threshmp.json` (some assets
        // were exported with the `.json` suffix to keep editor syntax
        // highlighting). Synchronized Xcode resource folders may flatten some
        // resources into the bundle root, so collect from every known location.
        var sceneURLs: [URL] = []
        var musicPresetURLs: [URL] = []
        let sceneExts = ["threshscene", "json"]
        let musicExts = ["threshmp", "json"]

        for ext in sceneExts {
            sceneURLs += Bundle.main.urls(forResourcesWithExtension: ext, subdirectory: "Examples/Scenes") ?? []
            sceneURLs += Bundle.main.urls(forResourcesWithExtension: ext, subdirectory: "Examples/Mixed") ?? []
            sceneURLs += Bundle.main.urls(forResourcesWithExtension: ext, subdirectory: nil) ?? []
        }
        for ext in musicExts {
            musicPresetURLs += Bundle.main.urls(forResourcesWithExtension: ext, subdirectory: "Examples/Scenes") ?? []
            musicPresetURLs += Bundle.main.urls(forResourcesWithExtension: ext, subdirectory: nil) ?? []
        }
        // Filter the .json hits down to ones that are actually our preset files.
        sceneURLs = sceneURLs.filter {
            let n = $0.lastPathComponent
            return n.hasSuffix(".threshscene") || n.hasSuffix(".threshscene.json")
        }
        musicPresetURLs = musicPresetURLs.filter {
            let n = $0.lastPathComponent
            return n.hasSuffix(".threshmp") || n.hasSuffix(".threshmp.json")
        }

        // Deep scan as a final safety net for mixed resource layouts.
        if let resourcePath = Bundle.main.resourcePath {
            let enumerator = FileManager.default.enumerator(atPath: resourcePath)
            while let file = enumerator?.nextObject() as? String {
                let url = URL(fileURLWithPath: resourcePath).appendingPathComponent(file)
                if file.hasSuffix(".threshscene") || file.hasSuffix(".threshscene.json") {
                    sceneURLs.append(url)
                } else if file.hasSuffix(".threshmp") || file.hasSuffix(".threshmp.json") {
                    musicPresetURLs.append(url)
                }
            }
        }

        let allURLs = Array(Set(sceneURLs + musicPresetURLs))
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        guard !allURLs.isEmpty else {
            print("⚠️ DefaultPresets: no bundled .threshscene/.threshmp files found anywhere in bundle")
            return []
        }
        print("ℹ️ DefaultPresets: found \(allURLs.count) bundled preset file(s): \(allURLs.map(\.lastPathComponent))")

        var presets: [FractalPreset] = []
        for url in allURLs {
            do {
                let data = try Data(contentsOf: url)
                var preset = try decoder.decode(FractalPreset.self, from: data)
                // Scenes shipped under Examples/Mixed are authored for Mixed
                // immersion: mark them even when the file predates the
                // mixedModeScene field, so loading one switches the headset to
                // Mixed and they populate the Mixed browse section.
                if url.pathComponents.contains("Mixed") {
                    preset.mixedModeScene = true
                }
                presets.append(preset)
            } catch {
                print("⚠️ DefaultPresets: failed to decode \(url.lastPathComponent) — \(error)")
            }
        }
        // The multi-location scan can find the same file both in its Examples
        // subdirectory and flattened at the bundle root. Dedupe by preset id,
        // letting a Mixed-marked copy win regardless of scan order.
        let mixedIDs = Set(presets.filter { $0.mixedModeScene == true }.map(\.id))
        var seenIDs = Set<UUID>()
        var uniquePresets: [FractalPreset] = []
        for var preset in presets where seenIDs.insert(preset.id).inserted {
            if mixedIDs.contains(preset.id) {
                preset.mixedModeScene = true
            }
            uniquePresets.append(preset)
        }
        print("ℹ️ DefaultPresets: successfully decoded \(uniquePresets.count) unique preset(s) (\(mixedIDs.count) mixed-mode)")
        return uniquePresets
    }
    
    /// Clean Mandelbox at the default/reset position, used as the first-launch
    /// default when no `__lastState__` has been saved yet.
    static func mandelboxDefaultPreset() -> FractalPreset {
        var preset = FractalPreset(name: "Mandelbox")
        preset.fractalType = .mandelbox
        preset.fractalScale = 2.8
        preset.foldingLimit = 1.0
        preset.sphereRadius = 0.5
        preset.minDistance = 0.18
        preset.position = SIMD3<Float>(0, 0, -1.15)
        preset.scale = 1.0
        return preset
    }
    
    /// Merge built-in presets with local presets.
    func addBuiltInPresetsIfNeeded() {
        refreshBundledPresets()
    }
    
    // MARK: - Last State Auto-Save/Restore
    
    /// URL for the last state file
    private var lastStateFileURL: URL {
        presetsDirectory.appendingPathComponent("lastState.json")
    }
    
    /// Save current settings as "last state" for restore on next launch
    func saveLastState(from settings: RenderSettings, embeddedFormula: EmbeddedFormula? = nil) {
        let preset = FractalPreset.fromSettings(settings, name: "__lastState__", embeddedFormula: embeddedFormula)
        
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(preset)
            try data.write(to: lastStateFileURL, options: .atomic)
            print("💾 Last state saved")
        } catch {
            print("Failed to save last state: \(error)")
        }
    }
    
    /// Restore last state to settings if available.
    /// Returns the applied preset so callers can restore auxiliary state
    /// (for example embedded custom formulas) alongside render settings.
    /// When no saved state exists, loads and returns the default Mandelbox preset.
    @discardableResult
    func restoreLastState(to settings: RenderSettings) -> FractalPreset? {
        guard FileManager.default.fileExists(atPath: lastStateFileURL.path) else {
            print("ℹ️ No last state found - loading Mandelbox default")
            let defaultPreset = PresetManager.mandelboxDefaultPreset()
            defaultPreset.apply(to: settings)
            return defaultPreset
        }
        
        do {
            let data = try Data(contentsOf: lastStateFileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let preset = try decoder.decode(FractalPreset.self, from: data)
            preset.apply(to: settings)
            print("✅ Last state restored")
            return preset
        } catch {
            print("Failed to restore last state: \(error)")
            return nil
        }
    }
}
