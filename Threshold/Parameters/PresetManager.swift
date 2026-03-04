//
//  PresetManager.swift
//  MetalProject
//
//  Created on January 11, 2026.
//

import SwiftUI
import Foundation


/// Manages saving and loading of presets
@MainActor
@Observable
class PresetManager {
    private(set) var presets: [FractalPreset] = []
    private let presetsKey = "FractalPresets"
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
    
    /// Load all presets from disk
    func loadPresets() {
        let fileURL = presetsFileURL
        
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            presets = []
            return
        }
        
        do {
            let data = try Data(contentsOf: fileURL)
            presets = try presetDecoder.decode([FractalPreset].self, from: data)
            presets.sort { $0.createdAt > $1.createdAt }
            FractalPreset.clearThumbnailCache()
        } catch {
            print("Failed to load presets: \(error). Trying latest backup…")
            loadLatestBackup()
        }
    }

    /// Attempt to load the most recent backup if the main file is missing or corrupt
    private func loadLatestBackup() {
        do {
            let backups = try FileManager.default.contentsOfDirectory(at: backupsDirectory, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles)
            let latest = backups.max { (a, b) -> Bool in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da < db
            }
            guard let url = latest else {
                presets = []
                return
            }
            let data = try Data(contentsOf: url)
            presets = try presetDecoder.decode([FractalPreset].self, from: data)
            presets.sort { $0.createdAt > $1.createdAt }
            FractalPreset.clearThumbnailCache()
            print("✅ Loaded presets from backup: \(url.lastPathComponent)")
        } catch {
            print("Failed to load presets backup: \(error)")
            presets = []
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

    /// Write a timestamped backup and keep only the newest few
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
    func savePreset(name: String, settings: RenderSettings, thumbnailData: Data? = nil) {
        let preset = FractalPreset.fromSettings(settings, name: name, thumbnailData: thumbnailData)
        presets.insert(preset, at: 0) // Add to beginning (newest first)
        scheduleSavePresets()
        
        // Track for analytics with full preset data
        UsageAnalytics.shared.trackPresetSaved(preset: preset)
        
        // Log all parameters for recovery purposes
        print("""
        📸 PRESET SAVED: "\(name)"
        ─────────────────────────────────────────
        ID: \(preset.id)
        Position: (\(preset.position.x), \(preset.position.y), \(preset.position.z))
        Scale: \(preset.scale)
        ─────────────────────────────────────────
        Fractal Scale: \(preset.fractalScale)
        Folding Limit: \(preset.foldingLimit)
        Sphere Radius: \(preset.sphereRadius)
        Min Distance: \(preset.minDistance)
        ─────────────────────────────────────────
        Fractal Iterations: \(preset.fractalIterations)
        Max Ray Steps: \(preset.maxRaySteps)
        Color Iterations: \(preset.colorIterations)
        Color Mix: \(preset.colorMix)
        Glow Enabled: \(preset.glowEffect?.enabled ?? false)
        ─────────────────────────────────────────
        """)
    }
    
    /// Update an existing preset
    func updatePreset(_ preset: FractalPreset, settings: RenderSettings, thumbnailData: Data? = nil) {
        guard let index = presets.firstIndex(where: { $0.id == preset.id }) else { return }
        
        // Recreate preset with proper ID preservation
        var updated = createPresetWithID(preset.id, name: preset.name, createdAt: preset.createdAt, settings: settings, thumbnailData: thumbnailData ?? preset.thumbnailData)
        updated.rating = presets[index].rating  // Preserve rating when updating settings
        presets[index] = updated
        FractalPreset.clearThumbnailCache(for: preset.id)
        
        scheduleSavePresets()
    }

    /// Update rating for a preset (0-5)
    func updateRating(_ preset: FractalPreset, rating: Int) {
        guard let index = presets.firstIndex(where: { $0.id == preset.id }) else { return }
        let clamped = max(0, min(5, rating))
        presets[index].rating = clamped
        scheduleSavePresets()
    }
    
    /// Helper to create preset with specific ID
    private func createPresetWithID(_ id: UUID, name: String, createdAt: Date, settings: RenderSettings, thumbnailData: Data?) -> FractalPreset {
        var preset = FractalPreset(id: id, name: name, createdAt: createdAt, thumbnailData: thumbnailData)
        
        preset.fractalIterations = settings.fractalIterations
        preset.maxRaySteps = settings.maxRaySteps
        preset.colorMix = settings.colorMix
        preset.colorIterations = settings.colorIterations
        preset.position = settings.position
        preset.scale = settings.scale
        
        preset.fractalType = settings.fractalType
        preset.colorSchemeSaturation = settings.colorSchemeSaturation
        preset.colorSchemeContrast = settings.colorSchemeContrast
        preset.colorSchemeGamma = settings.colorSchemeGamma
        preset.colorSchemeVibrance = settings.colorSchemeVibrance
        preset.colorSchemeCurve = settings.colorSchemeCurve
        preset.colorSchemeShadows = settings.colorSchemeShadows
        preset.colorSchemeHighlights = settings.colorSchemeHighlights
        
        preset.minDistance = settings.minDistance
        preset.fractalScale = settings.fractalScale
        preset.foldingLimit = settings.foldingLimit
        preset.sphereRadius = settings.sphereRadius
        
        preset.resolutionScale = settings.resolutionScale
        preset.tileSize = settings.tileSize
        
        preset.safetyBubbleEnabled = settings.safetyBubbleEnabled
        preset.safetyBubbleRadius = settings.safetyBubbleRadius
        preset.safetyBubbleShape = settings.safetyBubbleShape
        preset.safetyBubbleBlend = settings.safetyBubbleBlend
        
        // v2.0 modular lighting effects
        preset.lightingMode = settings.lightingMode
        preset.lightingPreset = settings.lightingPreset
        preset.hueRotationEffect = settings.hueRotationEffect
        preset.pulseEffect = settings.pulseEffect
        preset.glowEffect = settings.glowEffect
        preset.bloomEffect = settings.bloomEffect
        preset.fogEffect = settings.fogEffect
        preset.gradientCycleEffect = settings.gradientCycleEffect
        
        // v2.1 gradient coloring system
        preset.gradientState = settings.gradientState
        preset.lightingSoftness = settings.lightingSoftness
        
        return preset
    }
    
    /// Rename a preset
    func renamePreset(_ preset: FractalPreset, to newName: String) {
        guard let index = presets.firstIndex(where: { $0.id == preset.id }) else { return }
        presets[index].name = newName
        scheduleSavePresets()
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
    func loadPreset(_ preset: FractalPreset, into settings: RenderSettings, includePerformance: Bool = false) {
        let fc = preset.deriveFunctionConstants()
        print("📂 [PresetLoad] Loading preset: '\(preset.name)'")
        print("   Pipeline key: \(preset.pipelineCacheKey)")
        print("   FractalIters=\(fc.fractalIterations), RaySteps=\(fc.maxRaySteps), Neon=\(fc.neonModeEnabled)")
        
        preset.apply(to: settings, includePerformance: includePerformance)
        // Track for analytics
        UsageAnalytics.shared.trackPresetLoaded(name: preset.name)
    }
    
    /// Export a preset to a file URL
    /// Uses `.threshmp` for presets with music-reactive mappings, `.threshscene` otherwise.
    func exportPreset(_ preset: FractalPreset) -> URL? {
        let hasMusicMappings = preset.musicReactiveMappings != nil && !(preset.musicReactiveMappings?.isEmpty ?? true)
        let ext = hasMusicMappings ? "threshmp" : "threshscene"
        let fileName = "\(preset.name.replacingOccurrences(of: " ", with: "_")).\(ext)"
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
    
    /// Import a preset from a file URL
    func importPreset(from url: URL) -> FractalPreset? {
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let importedPreset = try decoder.decode(FractalPreset.self, from: data)

            // Generate new ID to avoid conflicts
            var newPreset = FractalPreset(
                id: UUID(),
                name: importedPreset.name,
                createdAt: Date(),
                thumbnailData: importedPreset.thumbnailData
            )

            // Copy all settings from imported preset while keeping new id/date
            newPreset.fractalIterations = importedPreset.fractalIterations
            newPreset.maxRaySteps = importedPreset.maxRaySteps
            newPreset.colorMix = importedPreset.colorMix
            newPreset.colorIterations = importedPreset.colorIterations
            newPreset.position = importedPreset.position
            newPreset.scale = importedPreset.scale
            newPreset.minDistance = importedPreset.minDistance
            newPreset.fractalScale = importedPreset.fractalScale
            newPreset.foldingLimit = importedPreset.foldingLimit
            newPreset.sphereRadius = importedPreset.sphereRadius
            newPreset.resolutionScale = importedPreset.resolutionScale
            newPreset.tileSize = importedPreset.tileSize
            newPreset.safetyBubbleEnabled = importedPreset.safetyBubbleEnabled
            newPreset.safetyBubbleRadius = importedPreset.safetyBubbleRadius
            newPreset.safetyBubbleShape = importedPreset.safetyBubbleShape
            newPreset.safetyBubbleBlend = importedPreset.safetyBubbleBlend
            newPreset.fractalType = importedPreset.fractalType
            newPreset.colorSchemeSaturation = importedPreset.colorSchemeSaturation
            newPreset.colorSchemeContrast = importedPreset.colorSchemeContrast
            newPreset.colorSchemeGamma = importedPreset.colorSchemeGamma
            newPreset.colorSchemeVibrance = importedPreset.colorSchemeVibrance
            newPreset.colorSchemeCurve = importedPreset.colorSchemeCurve
            newPreset.colorSchemeShadows = importedPreset.colorSchemeShadows
            newPreset.colorSchemeHighlights = importedPreset.colorSchemeHighlights
            newPreset.rating = importedPreset.rating
            
            // v2.0 modular lighting effects
            newPreset.lightingMode = importedPreset.lightingMode
            newPreset.lightingPreset = importedPreset.lightingPreset
            newPreset.hueRotationEffect = importedPreset.hueRotationEffect
            newPreset.pulseEffect = importedPreset.pulseEffect
            newPreset.glowEffect = importedPreset.glowEffect
            newPreset.bloomEffect = importedPreset.bloomEffect
            newPreset.fogEffect = importedPreset.fogEffect
            newPreset.gradientCycleEffect = importedPreset.gradientCycleEffect

            // v2.1 gradient coloring system
            newPreset.gradientState = importedPreset.gradientState
            newPreset.lightingSoftness = importedPreset.lightingSoftness
            
            presets.insert(newPreset, at: 0)
            scheduleSavePresets()
            
            return newPreset
        } catch {
            print("Failed to import preset: \(error)")
            return nil
        }
    }
}

// MARK: - Default Presets (loaded from bundled .threshscene JSON files)
extension PresetManager {
    
    // ─── Bundle-loaded default scenes ────────────────────────────────────
    // Built-in presets are stored as .threshscene JSON files in
    // Examples/Scenes (bundled as app resources). This keeps the
    // preset data in the same format as user exports and avoids
    // hardcoding parameter values in Swift.
    
    /// Filenames (without extension) of bundled default scenes.
    /// Add new defaults here — they will be auto-included on first launch.
    private static let defaultSceneFiles = [
        "Metallic_Pink",
        "Bright_Preset",
        "Orbit_Density"
    ]
    
    /// Load a single preset from a bundled .threshscene file.
    private static func loadBundledPreset(named fileName: String) -> FractalPreset? {
        guard let url = Bundle.main.url(forResource: fileName, withExtension: "threshscene") else {
            print("⚠️ DefaultPresets: missing bundled file \(fileName).threshscene")
            return nil
        }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(FractalPreset.self, from: data)
        } catch {
            print("⚠️ DefaultPresets: failed to decode \(fileName).threshscene — \(error)")
            return nil
        }
    }
    
    /// The fallback preset for when no saved state exists.
    /// Loaded from Bright_Preset.threshscene; falls back to a minimal inline
    /// preset if the bundle file is somehow missing.
    static func brightPreset() -> FractalPreset {
        if let preset = loadBundledPreset(named: "Bright_Preset") {
            return preset
        }
        // Minimal inline fallback (should never be reached)
        var preset = FractalPreset(name: "Bright Preset")
        preset.fractalType = .mandelbox
        preset.fractalScale = 2.8
        preset.foldingLimit = 1.1646773
        preset.minDistance = 0.8117829
        preset.position = SIMD3<Float>(0.10157842, 1.3497616, -3.3686383)
        return preset
    }
    
    /// Add built-in presets from bundled .threshscene files if not already present
    func addBuiltInPresetsIfNeeded() {
        for fileName in Self.defaultSceneFiles {
            guard let preset = Self.loadBundledPreset(named: fileName) else { continue }
            guard !presets.contains(where: { $0.name == preset.name }) else { continue }
            presets.append(preset)
        }
        scheduleSavePresets()
    }
    
    // MARK: - Last State Auto-Save/Restore
    
    /// URL for the last state file
    private var lastStateFileURL: URL {
        presetsDirectory.appendingPathComponent("lastState.json")
    }
    
    /// Save current settings as "last state" for restore on next launch
    func saveLastState(from settings: RenderSettings) {
        let preset = FractalPreset.fromSettings(settings, name: "__lastState__")
        
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
    
    /// Restore last state to settings if available
    /// Returns true if state was restored, false if no saved state exists
    /// When no saved state exists, loads the default "Metallic Pink" preset
    @discardableResult
    func restoreLastState(to settings: RenderSettings) -> Bool {
        guard FileManager.default.fileExists(atPath: lastStateFileURL.path) else {
            print("ℹ️ No last state found - loading Bright Preset default")
            let defaultPreset = PresetManager.brightPreset()
            defaultPreset.apply(to: settings)
            return true
        }
        
        do {
            let data = try Data(contentsOf: lastStateFileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let preset = try decoder.decode(FractalPreset.self, from: data)
            preset.apply(to: settings)
            print("✅ Last state restored")
            return true
        } catch {
            print("Failed to restore last state: \(error)")
            return false
        }
    }
    
    /// Check if a last state exists
    var hasLastState: Bool {
        FileManager.default.fileExists(atPath: lastStateFileURL.path)
    }
}
