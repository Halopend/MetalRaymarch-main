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
    var colorSchemeVibrance: Float?
    var colorSchemeCurve: Float?
    var colorSchemeShadows: Float?
    var colorSchemeHighlights: Float?
    
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
    
    // === LIGHTING & EFFECTS (new in v1.1) ===
    // These capture the full visual look of a preset
    var fogIntensity: Float?
    var lightingMode: LightingMode?
    var hueCycleSpeed: Float?
    var pulseSpeed: Float?
    var pulseAmount: Float?
    var bloomStrength: Float?
    
    // === EMISSIVE SETTINGS (new in v1.1) ===
    var emissiveEnabled: Bool?
    var emissivePattern: Int?
    var emissiveIntensity: Float?
    var emissiveThreshold: Float?
    var emissiveColor: SIMD3<Float>?
    var emissiveSpeed: Float?

    enum CodingKeys: String, CodingKey {
        case id, name, createdAt, thumbnailData, rating
        case fractalIterations, maxRaySteps, colorMix, glowIntensity, colorIterations, position, scale
        case fractalType, colorScheme, colorSchemeSaturation, colorSchemeContrast, colorSchemeGamma
        case colorSchemeVibrance, colorSchemeCurve, colorSchemeShadows, colorSchemeHighlights
        case minDistance, fractalScale, foldingLimit, sphereRadius
        case resolutionScale, tileSize, safetyBubbleEnabled, safetyBubbleRadius
        // v1.1 lighting & effects
        case fogIntensity, lightingMode, hueCycleSpeed, pulseSpeed, pulseAmount, bloomStrength
        case emissiveEnabled, emissivePattern, emissiveIntensity, emissiveThreshold, emissiveColor, emissiveSpeed
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
        self.colorSchemeVibrance = 0.0
        self.colorSchemeCurve = 0.0
        self.colorSchemeShadows = 0.0
        self.colorSchemeHighlights = 0.0
        
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
        colorSchemeVibrance = try container.decodeIfPresent(Float.self, forKey: .colorSchemeVibrance) ?? 0.0
        colorSchemeCurve = try container.decodeIfPresent(Float.self, forKey: .colorSchemeCurve) ?? 0.0
        colorSchemeShadows = try container.decodeIfPresent(Float.self, forKey: .colorSchemeShadows) ?? 0.0
        colorSchemeHighlights = try container.decodeIfPresent(Float.self, forKey: .colorSchemeHighlights) ?? 0.0
        minDistance = try container.decode(Float.self, forKey: .minDistance)
        fractalScale = try container.decode(Float.self, forKey: .fractalScale)
        foldingLimit = try container.decode(Float.self, forKey: .foldingLimit)
        sphereRadius = try container.decode(Float.self, forKey: .sphereRadius)
        resolutionScale = try container.decodeIfPresent(Float.self, forKey: .resolutionScale)
        tileSize = try container.decodeIfPresent(Int.self, forKey: .tileSize)
        safetyBubbleEnabled = try container.decodeIfPresent(Bool.self, forKey: .safetyBubbleEnabled)
        safetyBubbleRadius = try container.decodeIfPresent(Float.self, forKey: .safetyBubbleRadius)
        
        // v1.1 lighting & effects
        fogIntensity = try container.decodeIfPresent(Float.self, forKey: .fogIntensity)
        lightingMode = try container.decodeIfPresent(LightingMode.self, forKey: .lightingMode)
        hueCycleSpeed = try container.decodeIfPresent(Float.self, forKey: .hueCycleSpeed)
        pulseSpeed = try container.decodeIfPresent(Float.self, forKey: .pulseSpeed)
        pulseAmount = try container.decodeIfPresent(Float.self, forKey: .pulseAmount)
        bloomStrength = try container.decodeIfPresent(Float.self, forKey: .bloomStrength)
        
        // v1.1 emissive settings
        emissiveEnabled = try container.decodeIfPresent(Bool.self, forKey: .emissiveEnabled)
        emissivePattern = try container.decodeIfPresent(Int.self, forKey: .emissivePattern)
        emissiveIntensity = try container.decodeIfPresent(Float.self, forKey: .emissiveIntensity)
        emissiveThreshold = try container.decodeIfPresent(Float.self, forKey: .emissiveThreshold)
        emissiveColor = try container.decodeIfPresent(SIMD3<Float>.self, forKey: .emissiveColor)
        emissiveSpeed = try container.decodeIfPresent(Float.self, forKey: .emissiveSpeed)
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
        try container.encodeIfPresent(colorSchemeVibrance, forKey: .colorSchemeVibrance)
        try container.encodeIfPresent(colorSchemeCurve, forKey: .colorSchemeCurve)
        try container.encodeIfPresent(colorSchemeShadows, forKey: .colorSchemeShadows)
        try container.encodeIfPresent(colorSchemeHighlights, forKey: .colorSchemeHighlights)
        try container.encode(minDistance, forKey: .minDistance)
        try container.encode(fractalScale, forKey: .fractalScale)
        try container.encode(foldingLimit, forKey: .foldingLimit)
        try container.encode(sphereRadius, forKey: .sphereRadius)
        try container.encodeIfPresent(resolutionScale, forKey: .resolutionScale)
        try container.encodeIfPresent(tileSize, forKey: .tileSize)
        try container.encodeIfPresent(safetyBubbleEnabled, forKey: .safetyBubbleEnabled)
        try container.encodeIfPresent(safetyBubbleRadius, forKey: .safetyBubbleRadius)
        
        // v1.1 lighting & effects
        try container.encodeIfPresent(fogIntensity, forKey: .fogIntensity)
        try container.encodeIfPresent(lightingMode, forKey: .lightingMode)
        try container.encodeIfPresent(hueCycleSpeed, forKey: .hueCycleSpeed)
        try container.encodeIfPresent(pulseSpeed, forKey: .pulseSpeed)
        try container.encodeIfPresent(pulseAmount, forKey: .pulseAmount)
        try container.encodeIfPresent(bloomStrength, forKey: .bloomStrength)
        
        // v1.1 emissive settings
        try container.encodeIfPresent(emissiveEnabled, forKey: .emissiveEnabled)
        try container.encodeIfPresent(emissivePattern, forKey: .emissivePattern)
        try container.encodeIfPresent(emissiveIntensity, forKey: .emissiveIntensity)
        try container.encodeIfPresent(emissiveThreshold, forKey: .emissiveThreshold)
        try container.encodeIfPresent(emissiveColor, forKey: .emissiveColor)
        try container.encodeIfPresent(emissiveSpeed, forKey: .emissiveSpeed)
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
        
        // v1.1 lighting & effects
        preset.fogIntensity = settings.fogIntensity
        preset.lightingMode = settings.lightingMode
        preset.hueCycleSpeed = settings.hueCycleSpeed
        preset.pulseSpeed = settings.pulseSpeed
        preset.pulseAmount = settings.pulseAmount
        preset.bloomStrength = settings.bloomStrength
        
        // v1.1 emissive settings
        preset.emissiveEnabled = settings.emissiveEnabled
        preset.emissivePattern = settings.emissivePattern
        preset.emissiveIntensity = settings.emissiveIntensity
        preset.emissiveThreshold = settings.emissiveThreshold
        preset.emissiveColor = settings.emissiveColor
        preset.emissiveSpeed = settings.emissiveSpeed
        
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
        settings.colorSchemeVibrance = colorSchemeVibrance ?? 0.0
        settings.colorSchemeCurve = colorSchemeCurve ?? 0.0
        settings.colorSchemeShadows = colorSchemeShadows ?? 0.0
        settings.colorSchemeHighlights = colorSchemeHighlights ?? 0.0
        
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
        
        // v1.1 lighting & effects
        if let fogIntensity = fogIntensity {
            settings.fogIntensity = fogIntensity
        }
        if let lightingMode = lightingMode {
            settings.lightingMode = lightingMode
        }
        if let hueCycleSpeed = hueCycleSpeed {
            settings.hueCycleSpeed = hueCycleSpeed
        }
        if let pulseSpeed = pulseSpeed {
            settings.pulseSpeed = pulseSpeed
        }
        if let pulseAmount = pulseAmount {
            settings.pulseAmount = pulseAmount
        }
        if let bloomStrength = bloomStrength {
            settings.bloomStrength = bloomStrength
        }
        
        // v1.1 emissive settings
        if let emissiveEnabled = emissiveEnabled {
            settings.emissiveEnabled = emissiveEnabled
        }
        if let emissivePattern = emissivePattern {
            settings.emissivePattern = emissivePattern
        }
        if let emissiveIntensity = emissiveIntensity {
            settings.emissiveIntensity = emissiveIntensity
        }
        if let emissiveThreshold = emissiveThreshold {
            settings.emissiveThreshold = emissiveThreshold
        }
        if let emissiveColor = emissiveColor {
            settings.emissiveColor = emissiveColor
        }
        if let emissiveSpeed = emissiveSpeed {
            settings.emissiveSpeed = emissiveSpeed
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
        
        // v1.1 lighting & effects
        preset.fogIntensity = settings.fogIntensity
        preset.lightingMode = settings.lightingMode
        preset.hueCycleSpeed = settings.hueCycleSpeed
        preset.pulseSpeed = settings.pulseSpeed
        preset.pulseAmount = settings.pulseAmount
        preset.bloomStrength = settings.bloomStrength
        
        // v1.1 emissive settings
        preset.emissiveEnabled = settings.emissiveEnabled
        preset.emissivePattern = settings.emissivePattern
        preset.emissiveIntensity = settings.emissiveIntensity
        preset.emissiveThreshold = settings.emissiveThreshold
        preset.emissiveColor = settings.emissiveColor
        preset.emissiveSpeed = settings.emissiveSpeed
        
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
            newPreset.colorSchemeVibrance = importedPreset.colorSchemeVibrance
            newPreset.colorSchemeCurve = importedPreset.colorSchemeCurve
            newPreset.colorSchemeShadows = importedPreset.colorSchemeShadows
            newPreset.colorSchemeHighlights = importedPreset.colorSchemeHighlights
            newPreset.rating = importedPreset.rating
            
            // v1.1 lighting & effects
            newPreset.fogIntensity = importedPreset.fogIntensity
            newPreset.lightingMode = importedPreset.lightingMode
            newPreset.hueCycleSpeed = importedPreset.hueCycleSpeed
            newPreset.pulseSpeed = importedPreset.pulseSpeed
            newPreset.pulseAmount = importedPreset.pulseAmount
            newPreset.bloomStrength = importedPreset.bloomStrength
            
            // v1.1 emissive settings
            newPreset.emissiveEnabled = importedPreset.emissiveEnabled
            newPreset.emissivePattern = importedPreset.emissivePattern
            newPreset.emissiveIntensity = importedPreset.emissiveIntensity
            newPreset.emissiveThreshold = importedPreset.emissiveThreshold
            newPreset.emissiveColor = importedPreset.emissiveColor
            newPreset.emissiveSpeed = importedPreset.emissiveSpeed
            
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
    /// The default preset loaded when there is no saved state
    static func metallicPinkPreset() -> FractalPreset {
        var preset = FractalPreset(name: "Metallic Pink")
        preset.fractalType = .mandelbox
        preset.colorScheme = .neonSunset
        preset.colorSchemeSaturation = 2.0
        preset.colorSchemeContrast = 1.0658348
        preset.colorSchemeGamma = 0.5
        preset.colorSchemeVibrance = 1.0
        preset.colorSchemeCurve = -0.2481237
        preset.colorSchemeShadows = -0.023361081
        preset.colorSchemeHighlights = 0.7755921
        preset.fractalIterations = 7
        preset.maxRaySteps = 48
        preset.fractalScale = 3.8917305
        preset.foldingLimit = 0.98709714
        preset.sphereRadius = 0.05
        preset.minDistance = 1.3423144
        preset.colorIterations = 16
        preset.colorMix = 0.45099074
        preset.glowIntensity = 0.18124515
        preset.scale = 1.0
        preset.position = SIMD3<Float>(0.09840668, 1.4379398, -3.6177335)
        preset.safetyBubbleEnabled = true
        preset.safetyBubbleRadius = 1.8
        preset.fogIntensity = 0.14822857
        preset.lightingMode = .staticLight
        preset.hueCycleSpeed = 0.0
        preset.pulseSpeed = 0.46227682
        preset.pulseAmount = 0.1637325
        preset.bloomStrength = 0.7048401
        preset.emissiveEnabled = true
        preset.emissivePattern = 1
        preset.emissiveIntensity = 0.04231105
        preset.emissiveThreshold = 0.70703346
        preset.emissiveColor = SIMD3<Float>(0.99658203, 0.11701965, 1.0)
        preset.emissiveSpeed = 2.7824872
        return preset
    }
    
    /// The default preset loaded when there is no saved state
    static func brightPreset() -> FractalPreset {
        var preset = FractalPreset(name: "Bright Preset")
        preset.fractalType = .mandelbox
        preset.colorScheme = .classic
        preset.colorSchemeSaturation = 2.0
        preset.colorSchemeContrast = 1.0576694
        preset.colorSchemeGamma = 0.5
        preset.colorSchemeVibrance = 1.0
        preset.colorSchemeCurve = -1.0
        preset.colorSchemeShadows = -0.0066674873
        preset.colorSchemeHighlights = 0.28305644
        preset.fractalIterations = 7
        preset.maxRaySteps = 48
        preset.fractalScale = 2.8
        preset.foldingLimit = 1.1646773
        preset.sphereRadius = 0.05
        preset.minDistance = 0.8117829
        preset.colorIterations = 15
        preset.colorMix = 0.61749166
        preset.glowIntensity = 0.0
        preset.scale = 1.0
        preset.position = SIMD3<Float>(0.10157842, 1.3497616, -3.3686383)
        preset.safetyBubbleEnabled = true
        preset.safetyBubbleRadius = 1.8
        preset.fogIntensity = 0.14822857
        preset.lightingMode = .staticLight
        preset.hueCycleSpeed = 0.059446618
        preset.pulseSpeed = 0.46227682
        preset.pulseAmount = 0.1637325
        preset.bloomStrength = 0.7048401
        preset.emissiveEnabled = true
        preset.emissivePattern = 0
        preset.emissiveIntensity = 0.04231105
        preset.emissiveThreshold = 0.70703346
        preset.emissiveColor = SIMD3<Float>(0.99658203, 0.11701965, 1.0)
        preset.emissiveSpeed = 2.7824872
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
            orbit.glowIntensity = 0.45
            orbit.scale = 1.0
            orbit.position = SIMD3<Float>(0.0, 0.0, -1.4)
            return orbit
        }
        
        savePresets()
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
            try data.write(to: lastStateFileURL)
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
