//
//  PresetManager.swift
//  MetalProject
//
//  Created on January 11, 2026.
//

import SwiftUI
import Foundation

/// Represents a saved preset with all render settings and a preview image
struct FractalPreset: Codable, Identifiable {
    let id: UUID
    var name: String
    var createdAt: Date
    var thumbnailData: Data?  // PNG image data
    var rating: Int  // 0-5 stars
    
    // Common settings
    var fractalIterations: Int
    var maxRaySteps: Int
    var colorMix: Float
    var glowIntensity: Float
    var colorIterations: Float
    var position: SIMD3<Float>
    var scale: Float

    // Scene-style settings
    var fractalType: FractalType
    var colorScheme: ColorScheme
    var colorSchemeSaturation: Float
    var colorSchemeContrast: Float
    var colorSchemeGamma: Float
    
    // Mandelbox parameters
    var minDistance: Float
    var fractalScale: Float
    var foldingLimit: Float
    var sphereRadius: Float
    
    // Performance settings (optional to save)
    var resolutionScale: Float?
    var tileSize: Int?
    
    // Safety bubble
    var safetyBubbleEnabled: Bool?
    var safetyBubbleRadius: Float?

    enum CodingKeys: String, CodingKey {
        case id, name, createdAt, thumbnailData, rating
        case fractalIterations, maxRaySteps, colorMix, glowIntensity, colorIterations, position, scale
        case fractalType, colorScheme, colorSchemeSaturation, colorSchemeContrast, colorSchemeGamma
        case minDistance, fractalScale, foldingLimit, sphereRadius
        case resolutionScale, tileSize, safetyBubbleEnabled, safetyBubbleRadius
    }
    
    init(id: UUID = UUID(), name: String, createdAt: Date = Date(), thumbnailData: Data? = nil) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.thumbnailData = thumbnailData
        self.rating = 0
        
        // Initialize with defaults
        self.fractalIterations = 9
        self.maxRaySteps = 64
        self.colorMix = 0.5
        self.glowIntensity = 0.2
        self.colorIterations = 8.0
        self.position = .zero
        self.scale = 1.0

        self.fractalType = .mandelbox
        self.colorScheme = .classic
        self.colorSchemeSaturation = 2.0
        self.colorSchemeContrast = 1.05
        self.colorSchemeGamma = 0.5
        
        self.minDistance = 0.8
        self.fractalScale = 2.8
        self.foldingLimit = 1.0
        self.sphereRadius = 0.5
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        thumbnailData = try container.decodeIfPresent(Data.self, forKey: .thumbnailData)
        rating = try container.decodeIfPresent(Int.self, forKey: .rating) ?? 0
        fractalIterations = try container.decode(Int.self, forKey: .fractalIterations)
        maxRaySteps = try container.decode(Int.self, forKey: .maxRaySteps)
        colorMix = try container.decode(Float.self, forKey: .colorMix)
        glowIntensity = try container.decode(Float.self, forKey: .glowIntensity)
        colorIterations = try container.decode(Float.self, forKey: .colorIterations)
        position = try container.decode(SIMD3<Float>.self, forKey: .position)
        scale = try container.decode(Float.self, forKey: .scale)
        fractalType = try container.decodeIfPresent(FractalType.self, forKey: .fractalType) ?? .mandelbox
        colorScheme = try container.decodeIfPresent(ColorScheme.self, forKey: .colorScheme) ?? .classic
        colorSchemeSaturation = try container.decodeIfPresent(Float.self, forKey: .colorSchemeSaturation) ?? 2.0
        colorSchemeContrast = try container.decodeIfPresent(Float.self, forKey: .colorSchemeContrast) ?? 1.05
        colorSchemeGamma = try container.decodeIfPresent(Float.self, forKey: .colorSchemeGamma) ?? 0.5
        minDistance = try container.decode(Float.self, forKey: .minDistance)
        fractalScale = try container.decode(Float.self, forKey: .fractalScale)
        foldingLimit = try container.decode(Float.self, forKey: .foldingLimit)
        sphereRadius = try container.decode(Float.self, forKey: .sphereRadius)
        resolutionScale = try container.decodeIfPresent(Float.self, forKey: .resolutionScale)
        tileSize = try container.decodeIfPresent(Int.self, forKey: .tileSize)
        safetyBubbleEnabled = try container.decodeIfPresent(Bool.self, forKey: .safetyBubbleEnabled)
        safetyBubbleRadius = try container.decodeIfPresent(Float.self, forKey: .safetyBubbleRadius)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(thumbnailData, forKey: .thumbnailData)
        try container.encode(rating, forKey: .rating)
        try container.encode(fractalIterations, forKey: .fractalIterations)
        try container.encode(maxRaySteps, forKey: .maxRaySteps)
        try container.encode(colorMix, forKey: .colorMix)
        try container.encode(glowIntensity, forKey: .glowIntensity)
        try container.encode(colorIterations, forKey: .colorIterations)
        try container.encode(position, forKey: .position)
        try container.encode(scale, forKey: .scale)
        try container.encode(fractalType, forKey: .fractalType)
        try container.encode(colorScheme, forKey: .colorScheme)
        try container.encode(colorSchemeSaturation, forKey: .colorSchemeSaturation)
        try container.encode(colorSchemeContrast, forKey: .colorSchemeContrast)
        try container.encode(colorSchemeGamma, forKey: .colorSchemeGamma)
        try container.encode(minDistance, forKey: .minDistance)
        try container.encode(fractalScale, forKey: .fractalScale)
        try container.encode(foldingLimit, forKey: .foldingLimit)
        try container.encode(sphereRadius, forKey: .sphereRadius)
        try container.encodeIfPresent(resolutionScale, forKey: .resolutionScale)
        try container.encodeIfPresent(tileSize, forKey: .tileSize)
        try container.encodeIfPresent(safetyBubbleEnabled, forKey: .safetyBubbleEnabled)
        try container.encodeIfPresent(safetyBubbleRadius, forKey: .safetyBubbleRadius)
    }
    
    /// Create a preset from current render settings
    static func fromSettings(_ settings: RenderSettings, name: String, thumbnailData: Data? = nil) -> FractalPreset {
        var preset = FractalPreset(name: name, thumbnailData: thumbnailData)
        
        preset.fractalIterations = settings.fractalIterations
        preset.maxRaySteps = settings.maxRaySteps
        preset.colorMix = settings.colorMix
        preset.glowIntensity = settings.glowIntensity
        preset.colorIterations = settings.colorIterations
        preset.position = settings.position
        preset.scale = settings.scale

        preset.fractalType = settings.fractalType
        preset.colorScheme = settings.colorScheme
        preset.colorSchemeSaturation = settings.colorSchemeSaturation
        preset.colorSchemeContrast = settings.colorSchemeContrast
        preset.colorSchemeGamma = settings.colorSchemeGamma
        
        preset.minDistance = settings.minDistance
        preset.fractalScale = settings.fractalScale
        preset.foldingLimit = settings.foldingLimit
        preset.sphereRadius = settings.sphereRadius
        
        preset.resolutionScale = settings.resolutionScale
        preset.tileSize = settings.tileSize
        
        preset.safetyBubbleEnabled = settings.safetyBubbleEnabled
        preset.safetyBubbleRadius = settings.safetyBubbleRadius
        
        return preset
    }
    
    /// Apply this preset to render settings
    func apply(to settings: RenderSettings, includePerformance: Bool = false) {
        settings.fractalIterations = fractalIterations
        settings.maxRaySteps = maxRaySteps
        settings.colorMix = colorMix
        settings.glowIntensity = glowIntensity
        settings.colorIterations = colorIterations
        settings.position = position
        settings.scale = scale

        settings.fractalType = fractalType
        settings.transitionToColorScheme(colorScheme)
        settings.colorSchemeSaturation = colorSchemeSaturation
        settings.colorSchemeContrast = colorSchemeContrast
        settings.colorSchemeGamma = colorSchemeGamma
        
        settings.minDistance = minDistance
        settings.fractalScale = fractalScale
        settings.foldingLimit = foldingLimit
        settings.sphereRadius = sphereRadius
        
        // Also set target values for gesture-controlled parameters
        // This ensures smooth transitions when loading presets
        settings.setTargets(
            minDistance: minDistance,
            foldingLimit: foldingLimit,
            sphereRadius: sphereRadius,
            position: position
        )
        
        if includePerformance {
            if let resolutionScale = resolutionScale {
                settings.resolutionScale = resolutionScale
            }
            if let tileSize = tileSize {
                settings.tileSize = tileSize
            }
        }
        
        if let safetyBubbleEnabled = safetyBubbleEnabled {
            settings.safetyBubbleEnabled = safetyBubbleEnabled
        }
        if let safetyBubbleRadius = safetyBubbleRadius {
            settings.safetyBubbleRadius = safetyBubbleRadius
        }
        
        // Log preset load for debugging
        print("""
        📂 PRESET LOADED: "\(name)"
        ─────────────────────────────────────────
        Position: (\(position.x), \(position.y), \(position.z))
        Scale: \(scale)
        ─────────────────────────────────────────
        Fractal Scale: \(fractalScale)
        Folding Limit: \(foldingLimit)
        Sphere Radius: \(sphereRadius)
        Min Distance: \(minDistance)
        ─────────────────────────────────────────
        """)
    }
    
    /// Get the thumbnail as a UIImage (visionOS/iOS) or NSImage (macOS)
    #if os(visionOS) || os(iOS)
    var thumbnailImage: UIImage? {
        guard let data = thumbnailData else { return nil }
        return UIImage(data: data)
    }
    #elseif os(macOS)
    var thumbnailImage: NSImage? {
        guard let data = thumbnailData else { return nil }
        return NSImage(data: data)
    }
    #endif
}

/// Manages saving and loading of presets
@MainActor
@Observable
class PresetManager {
    private(set) var presets: [FractalPreset] = []
    private let presetsKey = "FractalPresets"
    private let maxBackupCount: Int? = nil  // nil = unlimited retention
    
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
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            presets = try decoder.decode([FractalPreset].self, from: data)
            presets.sort { $0.createdAt > $1.createdAt }
        } catch {
            print("Failed to load presets: \(error). Trying latest backup…")
            loadLatestBackup()
        }
    }

    /// Attempt to load the most recent backup if the main file is missing or corrupt
    private func loadLatestBackup() {
        do {
            let backups = try FileManager.default.contentsOfDirectory(at: backupsDirectory, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles)
            let latest = backups.sorted { (a, b) -> Bool in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da > db
            }.first
            guard let url = latest else {
                presets = []
                return
            }
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            presets = try decoder.decode([FractalPreset].self, from: data)
            presets.sort { $0.createdAt > $1.createdAt }
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
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(presets)
            try data.write(to: fileURL)
            writeBackup(data: data)
        } catch {
            print("Failed to save presets: \(error)")
        }
    }

    /// Write a timestamped backup and keep only the newest few
    private func writeBackup(data: Data) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = formatter.string(from: Date())
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
        savePresets()
        
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
        Glow Intensity: \(preset.glowIntensity)
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
        
        savePresets()
    }

    /// Update rating for a preset (0-5)
    func updateRating(_ preset: FractalPreset, rating: Int) {
        guard let index = presets.firstIndex(where: { $0.id == preset.id }) else { return }
        let clamped = max(0, min(5, rating))
        presets[index].rating = clamped
        savePresets()
    }
    
    /// Helper to create preset with specific ID
    private func createPresetWithID(_ id: UUID, name: String, createdAt: Date, settings: RenderSettings, thumbnailData: Data?) -> FractalPreset {
        var preset = FractalPreset(id: id, name: name, createdAt: createdAt, thumbnailData: thumbnailData)
        
        preset.fractalIterations = settings.fractalIterations
        preset.maxRaySteps = settings.maxRaySteps
        preset.colorMix = settings.colorMix
        preset.glowIntensity = settings.glowIntensity
        preset.colorIterations = settings.colorIterations
        preset.position = settings.position
        preset.scale = settings.scale
        
        preset.minDistance = settings.minDistance
        preset.fractalScale = settings.fractalScale
        preset.foldingLimit = settings.foldingLimit
        preset.sphereRadius = settings.sphereRadius
        
        preset.resolutionScale = settings.resolutionScale
        preset.tileSize = settings.tileSize
        
        preset.safetyBubbleEnabled = settings.safetyBubbleEnabled
        preset.safetyBubbleRadius = settings.safetyBubbleRadius
        
        return preset
    }
    
    /// Rename a preset
    func renamePreset(_ preset: FractalPreset, to newName: String) {
        guard let index = presets.firstIndex(where: { $0.id == preset.id }) else { return }
        presets[index].name = newName
        savePresets()
    }
    
    /// Delete a preset
    func deletePreset(_ preset: FractalPreset) {
        presets.removeAll { $0.id == preset.id }
        savePresets()
    }
    
    /// Delete preset at index
    func deletePreset(at offsets: IndexSet) {
        presets.remove(atOffsets: offsets)
        savePresets()
    }
    
    /// Load a preset's settings
    func loadPreset(_ preset: FractalPreset, into settings: RenderSettings, includePerformance: Bool = false) {
        preset.apply(to: settings, includePerformance: includePerformance)
    }
    
    /// Export a preset to a file URL
    func exportPreset(_ preset: FractalPreset) -> URL? {
        let fileName = "\(preset.name.replacingOccurrences(of: " ", with: "_")).fractal"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted
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
            var preset = try decoder.decode(FractalPreset.self, from: data)
            
            // Generate new ID to avoid conflicts
            preset = FractalPreset(
                id: UUID(),
                name: preset.name,
                createdAt: Date(),
                thumbnailData: preset.thumbnailData
            )
            
            // Copy all the settings manually (since we changed the ID)
            let importedPreset = try decoder.decode(FractalPreset.self, from: data)
            var newPreset = preset
            newPreset.fractalIterations = importedPreset.fractalIterations
            newPreset.maxRaySteps = importedPreset.maxRaySteps
            newPreset.colorMix = importedPreset.colorMix
            newPreset.glowIntensity = importedPreset.glowIntensity
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
            newPreset.fractalType = importedPreset.fractalType
            newPreset.colorScheme = importedPreset.colorScheme
            newPreset.colorSchemeSaturation = importedPreset.colorSchemeSaturation
            newPreset.colorSchemeContrast = importedPreset.colorSchemeContrast
            newPreset.colorSchemeGamma = importedPreset.colorSchemeGamma
            newPreset.rating = importedPreset.rating
            
            presets.insert(newPreset, at: 0)
            savePresets()
            
            return newPreset
        } catch {
            print("Failed to import preset: \(error)")
            return nil
        }
    }
}

// MARK: - Default Presets
extension PresetManager {
    /// Add some built-in presets for users to start with
    func addBuiltInPresetsIfNeeded() {
        func ensurePreset(named name: String, build: () -> FractalPreset) {
            guard !presets.contains(where: { $0.name == name }) else { return }
            presets.append(build())
        }
        
        // Classic Mandelbox
        ensurePreset(named: "Classic Mandelbox") {
            var classic = FractalPreset(name: "Classic Mandelbox")
            classic.fractalScale = 2.8
            classic.fractalIterations = 6
            classic.foldingLimit = 1.0
            classic.sphereRadius = 0.5
            classic.colorMix = 0.5
            classic.glowIntensity = 0.2
            return classic
        }
        
        // Deep Dive
        ensurePreset(named: "Deep Dive") {
            var deepDive = FractalPreset(name: "Deep Dive")
            deepDive.fractalScale = 2.2
            deepDive.fractalIterations = 10
            deepDive.foldingLimit = 1.5
            deepDive.sphereRadius = 0.3
            deepDive.colorMix = 0.7
            deepDive.glowIntensity = 0.4
            return deepDive
        }

        // Nebulabrot Drift (color-driven scene inspired by Nebulabrot aesthetics)
        ensurePreset(named: "Nebulabrot Drift") {
            var nebulabrot = FractalPreset(name: "Nebulabrot Drift")
            nebulabrot.fractalType = .mandelbox
            nebulabrot.colorScheme = .nebula
            nebulabrot.colorSchemeSaturation = 2.4
            nebulabrot.colorSchemeContrast = 1.1
            nebulabrot.colorSchemeGamma = 0.55
            nebulabrot.fractalIterations = 12
            nebulabrot.maxRaySteps = 100
            nebulabrot.fractalScale = 2.6
            nebulabrot.foldingLimit = 1.2
            nebulabrot.sphereRadius = 0.45
            nebulabrot.minDistance = 0.6
            nebulabrot.colorIterations = 10
            nebulabrot.colorMix = 0.65
            nebulabrot.glowIntensity = 0.35
            nebulabrot.scale = 1.1
            nebulabrot.position = SIMD3<Float>(0.0, 0.1, -1.6)
            return nebulabrot
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
            orbit.glowIntensity = 0.45
            orbit.scale = 1.0
            orbit.position = SIMD3<Float>(0.0, 0.0, -1.4)
            return orbit
        }

        // Taurus66 Rotbox (approx) - tuned from Mandelbulber settings
        ensurePreset(named: "Taurus66 Rotbox") {
            var rotbox = FractalPreset(name: "Taurus66 Rotbox")
            rotbox.fractalType = .mandelbox
            rotbox.colorScheme = .fire
            rotbox.colorSchemeSaturation = 2.0
            rotbox.colorSchemeContrast = 1.15
            rotbox.colorSchemeGamma = 0.55
            rotbox.fractalIterations = 12
            rotbox.maxRaySteps = 128
            rotbox.fractalScale = 2.8
            rotbox.foldingLimit = 1.0
            rotbox.sphereRadius = 0.5
            rotbox.minDistance = 0.4
            rotbox.colorIterations = 10
            rotbox.colorMix = 0.6
            rotbox.glowIntensity = 0.1
            rotbox.scale = 1.0
            rotbox.position = SIMD3<Float>(0.0, 0.0, -1.6)
            return rotbox
        }

        // Yip Yip Martians - fuzzy, playful chaos inspired by Sesame Street's aliens
        ensurePreset(named: "Yip Yip Martians") {
            var yipyip = FractalPreset(name: "Yip Yip Martians")
            yipyip.fractalType = .mandelbox  // Originally Nebulabrot-style, now Mandelbox
            yipyip.colorScheme = .neonSunset    // Orange/magenta/violet - playful retro
            yipyip.colorSchemeSaturation = 2.6  // Vibrant retro 70s/80s colors
            yipyip.colorSchemeContrast = 0.95   // Soft, fuzzy contrast like their fur
            yipyip.colorSchemeGamma = 0.5       // Balanced for multi-channel glow
            yipyip.fractalIterations = 12       // More iterations for richer RGB channels
            yipyip.maxRaySteps = 110            // More steps for detailed volume
            yipyip.fractalScale = 2.4           // Wobbly, blobby alien scale
            yipyip.foldingLimit = 1.25          // Extra folding = fuzzy texture
            yipyip.sphereRadius = 0.65          // Rounder shapes like their heads
            yipyip.minDistance = 0.85           // Space between blobs
            yipyip.colorIterations = 8          // Color cycling rhythm
            yipyip.colorMix = 0.55              // Orbit trap influence for structure
            yipyip.glowIntensity = 0.45         // Ethereal glow - "uh huh uh huh"
            yipyip.scale = 0.85
            yipyip.position = SIMD3<Float>(0.0, 0.15, -1.25)
            return yipyip
        }

        // Deep Nebula - originally multi-channel Nebulabrot, now Mandelbox
        ensurePreset(named: "Deep Nebula") {
            var nebula = FractalPreset(name: "Deep Nebula")
            nebula.fractalType = .mandelbox
            nebula.colorScheme = .nebula        // Astronomical false-color
            nebula.colorSchemeSaturation = 2.3
            nebula.colorSchemeContrast = 1.05
            nebula.colorSchemeGamma = 0.55
            nebula.fractalIterations = 16       // High iterations for rich RGB separation
            nebula.maxRaySteps = 140            // Dense volume sampling
            nebula.fractalScale = 2.3
            nebula.foldingLimit = 1.15
            nebula.sphereRadius = 0.55
            nebula.minDistance = 0.75
            nebula.colorIterations = 12
            nebula.colorMix = 0.7               // Strong orbit trap influence
            nebula.glowIntensity = 0.35
            nebula.scale = 1.0
            nebula.position = SIMD3<Float>(0.0, 0.0, -1.5)
            return nebula
        }
        
        savePresets()
    }
}
