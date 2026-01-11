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
    
    // Scene selection
    var sceneIndex: Int
    
    // Common settings
    var fractalIterations: Int
    var maxRaySteps: Int
    var colorMix: Float
    var glowIntensity: Float
    var colorIterations: Float
    var position: SIMD3<Float>
    var scale: Float
    
    // Mandelbox-specific (scene 0)
    var minDistance: Float
    var fractalScale: Float
    var foldingLimit: Float
    var sphereRadius: Float
    
    // IFS-specific (scene 1)
    var ifsScale: Float
    var ifsOffset: Float
    var ifsGlow: Float
    
    // Performance settings (optional to save)
    var resolutionScale: Float?
    var tileSize: Int?
    var useGST: Bool?
    
    // Safety bubble
    var safetyBubbleEnabled: Bool?
    var safetyBubbleRadius: Float?
    
    init(id: UUID = UUID(), name: String, createdAt: Date = Date(), thumbnailData: Data? = nil) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.thumbnailData = thumbnailData
        
        // Initialize with defaults
        self.sceneIndex = 0
        self.fractalIterations = 6
        self.maxRaySteps = 32
        self.colorMix = 0.5
        self.glowIntensity = 0.2
        self.colorIterations = 8.0
        self.position = .zero
        self.scale = 1.0
        
        self.minDistance = 0.8
        self.fractalScale = 2.8
        self.foldingLimit = 1.0
        self.sphereRadius = 0.5
        
        self.ifsScale = 1.74
        self.ifsOffset = 0.98
        self.ifsGlow = 1.0
    }
    
    /// Create a preset from current render settings
    static func fromSettings(_ settings: RenderSettings, name: String, thumbnailData: Data? = nil) -> FractalPreset {
        var preset = FractalPreset(name: name, thumbnailData: thumbnailData)
        
        preset.sceneIndex = settings.sceneIndex
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
        
        preset.ifsScale = settings.ifsScale
        preset.ifsOffset = settings.ifsOffset
        preset.ifsGlow = settings.ifsGlow
        
        preset.resolutionScale = settings.resolutionScale
        preset.tileSize = settings.tileSize
        preset.useGST = settings.useGST
        
        preset.safetyBubbleEnabled = settings.safetyBubbleEnabled
        preset.safetyBubbleRadius = settings.safetyBubbleRadius
        
        return preset
    }
    
    /// Apply this preset to render settings
    func apply(to settings: RenderSettings, includePerformance: Bool = false) {
        settings.sceneIndex = sceneIndex
        settings.fractalIterations = fractalIterations
        settings.maxRaySteps = maxRaySteps
        settings.colorMix = colorMix
        settings.glowIntensity = glowIntensity
        settings.colorIterations = colorIterations
        settings.position = position
        settings.scale = scale
        
        settings.minDistance = minDistance
        settings.fractalScale = fractalScale
        settings.foldingLimit = foldingLimit
        settings.sphereRadius = sphereRadius
        
        settings.ifsScale = ifsScale
        settings.ifsOffset = ifsOffset
        settings.ifsGlow = ifsGlow
        
        if includePerformance {
            if let resolutionScale = resolutionScale {
                settings.resolutionScale = resolutionScale
            }
            if let tileSize = tileSize {
                settings.tileSize = tileSize
            }
            if let useGST = useGST {
                settings.useGST = useGST
            }
        }
        
        if let safetyBubbleEnabled = safetyBubbleEnabled {
            settings.safetyBubbleEnabled = safetyBubbleEnabled
        }
        if let safetyBubbleRadius = safetyBubbleRadius {
            settings.safetyBubbleRadius = safetyBubbleRadius
        }
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

// MARK: - Codable support for SIMD3<Float>
extension SIMD3: Codable where Scalar == Float {
    enum CodingKeys: String, CodingKey {
        case x, y, z
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let x = try container.decode(Float.self, forKey: .x)
        let y = try container.decode(Float.self, forKey: .y)
        let z = try container.decode(Float.self, forKey: .z)
        self.init(x, y, z)
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(x, forKey: .x)
        try container.encode(y, forKey: .y)
        try container.encode(z, forKey: .z)
    }
}

/// Manages saving and loading of presets
@MainActor
@Observable
class PresetManager {
    private(set) var presets: [FractalPreset] = []
    private let presetsKey = "FractalPresets"
    
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
            // Sort by creation date, newest first
            presets.sort { $0.createdAt > $1.createdAt }
        } catch {
            print("Failed to load presets: \(error)")
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
        } catch {
            print("Failed to save presets: \(error)")
        }
    }
    
    /// Save current settings as a new preset
    func savePreset(name: String, settings: RenderSettings, thumbnailData: Data? = nil) {
        let preset = FractalPreset.fromSettings(settings, name: name, thumbnailData: thumbnailData)
        presets.insert(preset, at: 0) // Add to beginning (newest first)
        savePresets()
    }
    
    /// Update an existing preset
    func updatePreset(_ preset: FractalPreset, settings: RenderSettings, thumbnailData: Data? = nil) {
        guard let index = presets.firstIndex(where: { $0.id == preset.id }) else { return }
        
        var updatedPreset = FractalPreset.fromSettings(settings, name: preset.name, thumbnailData: thumbnailData ?? preset.thumbnailData)
        updatedPreset = FractalPreset(
            id: preset.id,  // Keep original ID
            name: preset.name,
            createdAt: preset.createdAt,
            thumbnailData: thumbnailData ?? preset.thumbnailData
        )
        
        // Copy settings from the new preset
        let newPreset = FractalPreset.fromSettings(settings, name: preset.name, thumbnailData: thumbnailData ?? preset.thumbnailData)
        presets[index] = FractalPreset(
            id: preset.id,
            name: preset.name,
            createdAt: preset.createdAt,
            thumbnailData: thumbnailData ?? preset.thumbnailData
        )
        
        // We need to manually copy all fields since we're preserving id/name/date
        var finalPreset = newPreset
        finalPreset = FractalPreset.fromSettings(settings, name: preset.name, thumbnailData: thumbnailData ?? preset.thumbnailData)
        // Recreate with proper ID preservation
        presets[index] = createPresetWithID(preset.id, name: preset.name, createdAt: preset.createdAt, settings: settings, thumbnailData: thumbnailData ?? preset.thumbnailData)
        
        savePresets()
    }
    
    /// Helper to create preset with specific ID
    private func createPresetWithID(_ id: UUID, name: String, createdAt: Date, settings: RenderSettings, thumbnailData: Data?) -> FractalPreset {
        var preset = FractalPreset(id: id, name: name, createdAt: createdAt, thumbnailData: thumbnailData)
        
        preset.sceneIndex = settings.sceneIndex
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
        
        preset.ifsScale = settings.ifsScale
        preset.ifsOffset = settings.ifsOffset
        preset.ifsGlow = settings.ifsGlow
        
        preset.resolutionScale = settings.resolutionScale
        preset.tileSize = settings.tileSize
        preset.useGST = settings.useGST
        
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
            newPreset.sceneIndex = importedPreset.sceneIndex
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
            newPreset.ifsScale = importedPreset.ifsScale
            newPreset.ifsOffset = importedPreset.ifsOffset
            newPreset.ifsGlow = importedPreset.ifsGlow
            newPreset.resolutionScale = importedPreset.resolutionScale
            newPreset.tileSize = importedPreset.tileSize
            newPreset.useGST = importedPreset.useGST
            newPreset.safetyBubbleEnabled = importedPreset.safetyBubbleEnabled
            newPreset.safetyBubbleRadius = importedPreset.safetyBubbleRadius
            
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
        guard presets.isEmpty else { return }
        
        // Classic Mandelbox
        var classic = FractalPreset(name: "Classic Mandelbox")
        classic.sceneIndex = 0
        classic.fractalScale = 2.8
        classic.fractalIterations = 6
        classic.foldingLimit = 1.0
        classic.sphereRadius = 0.5
        classic.colorMix = 0.5
        classic.glowIntensity = 0.2
        presets.append(classic)
        
        // Deep Dive
        var deepDive = FractalPreset(name: "Deep Dive")
        deepDive.sceneIndex = 0
        deepDive.fractalScale = 2.2
        deepDive.fractalIterations = 10
        deepDive.foldingLimit = 1.5
        deepDive.sphereRadius = 0.3
        deepDive.colorMix = 0.7
        deepDive.glowIntensity = 0.4
        presets.append(deepDive)
        
        // Cosmic IFS
        var cosmicIFS = FractalPreset(name: "Cosmic IFS")
        cosmicIFS.sceneIndex = 1
        cosmicIFS.ifsScale = 1.74
        cosmicIFS.ifsOffset = 0.98
        cosmicIFS.ifsGlow = 1.5
        cosmicIFS.colorIterations = 12
        presets.append(cosmicIFS)
        
        // Neon Dreams
        var neonDreams = FractalPreset(name: "Neon Dreams")
        neonDreams.sceneIndex = 1
        neonDreams.ifsScale = 2.0
        neonDreams.ifsOffset = 0.75
        neonDreams.ifsGlow = 2.5
        neonDreams.colorMix = 0.3
        neonDreams.colorIterations = 8
        presets.append(neonDreams)
        
        savePresets()
    }
}
