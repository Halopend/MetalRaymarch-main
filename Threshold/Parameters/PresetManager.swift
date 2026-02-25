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
        preset.colorScheme = settings.colorScheme
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
        
        // v2.0 modular lighting effects
        preset.lightingMode = settings.lightingMode
        preset.lightingPreset = settings.lightingPreset
        preset.hueRotationEffect = settings.hueRotationEffect
        preset.pulseEffect = settings.pulseEffect
        preset.glowEffect = settings.glowEffect
        preset.bloomEffect = settings.bloomEffect
        preset.fogEffect = settings.fogEffect
        preset.gradientCycleEffect = settings.gradientCycleEffect
        
        // Doppelganger
        preset.doppelgangerEnabled = settings.doppelgangerEnabled
        preset.doppelgangerPlane = settings.doppelgangerPlane
        preset.doppelgangerOffset = settings.doppelgangerOffset
        
        // Color scheme auto-transition
        preset.colorSchemeAutoTransition = settings.colorSchemeAutoTransition
        preset.colorSchemeAutoInterval = settings.colorSchemeAutoInterval
        preset.colorSchemeTransitionDuration = settings.colorSchemeTransitionDuration
        
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
    func exportPreset(_ preset: FractalPreset) -> URL? {
        let fileName = "\(preset.name.replacingOccurrences(of: " ", with: "_")).fractal"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
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
            newPreset.fractalType = importedPreset.fractalType
            newPreset.colorScheme = importedPreset.colorScheme
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

            // Doppelganger
            newPreset.doppelgangerEnabled = importedPreset.doppelgangerEnabled
            newPreset.doppelgangerPlane = importedPreset.doppelgangerPlane
            newPreset.doppelgangerOffset = importedPreset.doppelgangerOffset

            // Color scheme auto-transition
            newPreset.colorSchemeAutoTransition = importedPreset.colorSchemeAutoTransition
            newPreset.colorSchemeAutoInterval = importedPreset.colorSchemeAutoInterval
            newPreset.colorSchemeTransitionDuration = importedPreset.colorSchemeTransitionDuration

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

// MARK: - Default Presets
extension PresetManager {
    /// The default preset loaded when there is no saved state
    static func metallicPinkPreset() -> FractalPreset {
        var preset = FractalPreset(name: "Metallic Pink")
        preset.fractalType = .mandelbox
        preset.colorScheme = .neonSunset
        preset.colorSchemeSaturation = 1.5
        preset.colorSchemeContrast = 1.02
        preset.colorSchemeGamma = 0.75
        preset.colorSchemeVibrance = 1.0
        preset.colorSchemeCurve = -0.2481237
        preset.colorSchemeShadows = -0.023361081
        preset.colorSchemeHighlights = 0.3
        preset.fractalIterations = 7
        preset.maxRaySteps = 48
        preset.fractalScale = 3.8917305
        preset.foldingLimit = 0.98709714
        preset.sphereRadius = 0.05
        preset.minDistance = 1.3423144
        preset.colorIterations = 16
        preset.colorMix = 0.45099074
        preset.scale = 1.0
        preset.position = SIMD3<Float>(0.09840668, 1.4379398, -3.6177335)
        preset.safetyBubbleEnabled = false
        preset.safetyBubbleRadius = 1.8
        // v2.0 modular lighting effects
        preset.lightingMode = .staticLight
        preset.lightingPreset = .atmospheric
        preset.hueRotationEffect = HueRotationEffect(enabled: false, speed: 0.0, intensity: 0.5)
        preset.pulseEffect = PulseEffect(enabled: true, speed: 0.46227682, amount: 0.1637325)
        preset.glowEffect = GlowEffect(enabled: true, intensity: 0.18124515)
        preset.bloomEffect = BloomEffect(enabled: true, strength: 0.7048401)
        preset.fogEffect = FogEffect(enabled: true, intensity: 0.14822857)
        return preset
    }
    
    /// The default preset loaded when there is no saved state
    static func brightPreset() -> FractalPreset {
        var preset = FractalPreset(name: "Bright Preset")
        preset.fractalType = .mandelbox
        preset.colorScheme = .classic
        preset.colorSchemeSaturation = 1.5
        preset.colorSchemeContrast = 1.02
        preset.colorSchemeGamma = 0.75
        preset.colorSchemeVibrance = 1.0
        preset.colorSchemeCurve = -0.3
        preset.colorSchemeShadows = -0.007
        preset.colorSchemeHighlights = 0.15
        preset.fractalIterations = 7
        preset.maxRaySteps = 48
        preset.fractalScale = 2.8
        preset.foldingLimit = 1.1646773
        preset.sphereRadius = 0.05
        preset.minDistance = 0.8117829
        preset.colorIterations = 15
        preset.colorMix = 0.61749166
        preset.scale = 1.0
        preset.position = SIMD3<Float>(0.10157842, 1.3497616, -3.3686383)
        preset.safetyBubbleEnabled = false
        preset.safetyBubbleRadius = 1.8
        // v2.0 modular lighting effects
        preset.lightingMode = .staticLight
        preset.lightingPreset = .subtle
        preset.hueRotationEffect = HueRotationEffect(enabled: true, speed: 0.059446618, intensity: 0.3)
        preset.pulseEffect = PulseEffect(enabled: true, speed: 0.46227682, amount: 0.1637325)
        preset.glowEffect = GlowEffect(enabled: false, intensity: 0.0)
        preset.bloomEffect = BloomEffect(enabled: true, strength: 0.7048401)
        preset.fogEffect = FogEffect(enabled: true, intensity: 0.14822857)
        return preset
    }
    
    /// Add some built-in presets for users to start with
    func addBuiltInPresetsIfNeeded() {
        func ensurePreset(named name: String, build: () -> FractalPreset) {
            guard !presets.contains(where: { $0.name == name }) else { return }
            presets.append(build())
        }
        
        // Metallic Pink - the default launch preset
        ensurePreset(named: "Metallic Pink") {
            return PresetManager.metallicPinkPreset()
        }
        
        // Bright Preset - the default launch preset
        ensurePreset(named: "Bright Preset") {
            return PresetManager.brightPreset()
        }
        
        // Orbit Density (originally 3D Buddhabrot-style, now Mandelbox)
        ensurePreset(named: "Orbit Density") {
            var orbit = FractalPreset(name: "Orbit Density")
            orbit.fractalType = .mandelbox
            orbit.colorScheme = .nebula
            orbit.colorSchemeSaturation = 2.2
            orbit.colorSchemeContrast = 1.1
            orbit.colorSchemeGamma = 0.6
            orbit.fractalIterations = 10
            orbit.maxRaySteps = 128
            orbit.fractalScale = 2.4
            orbit.foldingLimit = 1.1
            orbit.sphereRadius = 0.6
            orbit.minDistance = 0.7
            orbit.colorIterations = 8
            orbit.colorMix = 0.55
            orbit.glowEffect = GlowEffect(enabled: true, intensity: 0.45)
            orbit.scale = 1.0
            orbit.position = SIMD3<Float>(0.0, 0.0, -1.4)
            return orbit
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
