//
//  FractalPreset.swift
//  Threshold
//
//  Represents a saved preset with all render settings and a preview image.
//  Extracted from PresetManager.swift for single-responsibility.
//

import SwiftUI
import Foundation
import simd

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
    var colorIterations: Float
    var position: SIMD3<Float>
    var scale: Float

    // Scene-style settings
    var fractalType: FractalModelType
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
    
    // Formula parameters (non-Mandelbox fractal types)
    // Stored as raw float array [0..15] to avoid C-struct Codable issues.
    var formulaParamValues: [Float]?
    
    // Performance settings (optional to save)
    var resolutionScale: Float?
    var tileSize: Int?
    
    // Safety bubble
    var safetyBubbleEnabled: Bool?
    var safetyBubbleRadius: Float?
    var safetyBubbleShape: Float?
    
    // === MODULAR LIGHTING EFFECTS (v2.0) ===
    // Card-based lighting system with presets
    var lightingMode: LightingMode?
    var lightingPreset: LightingPreset?
    var hueRotationEffect: HueRotationEffect?
    var pulseEffect: PulseEffect?
    var glowEffect: GlowEffect?
    var bloomEffect: BloomEffect?
    var fogEffect: FogEffect?
    var gradientCycleEffect: GradientCycleEffect?
    
    // === DOPPELGANGER MODE ===
    var doppelgangerEnabled: Bool?
    var doppelgangerPlane: SIMD3<Float>?
    var doppelgangerOffset: Float?
    
    // === COLOR SCHEME AUTO-TRANSITION ===
    var colorSchemeAutoTransition: Bool?
    var colorSchemeAutoInterval: Float?
    var colorSchemeTransitionDuration: Float?
    
    // === GRADIENT COLORING SYSTEM (v2.1) ===
    var gradientState: GradientState?
    var lightingSoftness: Float?
    var musicReactiveMappings: [MusicReactiveMapping]?

    enum CodingKeys: String, CodingKey {
        case id, name, createdAt, thumbnailData, rating
        case fractalIterations, maxRaySteps, colorMix, colorIterations, position, scale
        case fractalType, colorScheme, colorSchemeSaturation, colorSchemeContrast, colorSchemeGamma
        case colorSchemeVibrance, colorSchemeCurve, colorSchemeShadows, colorSchemeHighlights
        case minDistance, fractalScale, foldingLimit, sphereRadius, formulaParamValues
        case resolutionScale, tileSize, safetyBubbleEnabled, safetyBubbleRadius, safetyBubbleShape
        // v2.0 modular lighting effects
        case lightingMode, lightingPreset, hueRotationEffect, pulseEffect, glowEffect, bloomEffect, fogEffect, gradientCycleEffect
        // Doppelganger
        case doppelgangerEnabled, doppelgangerPlane, doppelgangerOffset
        // Color scheme auto-transition
        case colorSchemeAutoTransition, colorSchemeAutoInterval, colorSchemeTransitionDuration
        // v2.1 gradient coloring system
        case gradientState, lightingSoftness
        case musicReactiveMappings
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
        self.colorIterations = 8.0
        self.position = .zero
        self.scale = 1.0

        self.fractalType = .mandelbox
        self.colorScheme = .classic
        self.colorSchemeSaturation = 1.5
        self.colorSchemeContrast = 1.02
        self.colorSchemeGamma = 0.75
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
        colorIterations = try container.decode(Float.self, forKey: .colorIterations)
        position = try container.decode(SIMD3<Float>.self, forKey: .position)
        scale = try container.decode(Float.self, forKey: .scale)
        fractalType = try container.decodeIfPresent(FractalModelType.self, forKey: .fractalType) ?? .mandelbox
        colorScheme = try container.decodeIfPresent(ColorScheme.self, forKey: .colorScheme) ?? .classic
        colorSchemeSaturation = try container.decodeIfPresent(Float.self, forKey: .colorSchemeSaturation) ?? 1.5
        colorSchemeContrast = try container.decodeIfPresent(Float.self, forKey: .colorSchemeContrast) ?? 1.02
        colorSchemeGamma = try container.decodeIfPresent(Float.self, forKey: .colorSchemeGamma) ?? 0.75
        colorSchemeVibrance = try container.decodeIfPresent(Float.self, forKey: .colorSchemeVibrance) ?? 0.0
        colorSchemeCurve = try container.decodeIfPresent(Float.self, forKey: .colorSchemeCurve) ?? 0.0
        colorSchemeShadows = try container.decodeIfPresent(Float.self, forKey: .colorSchemeShadows) ?? 0.0
        colorSchemeHighlights = try container.decodeIfPresent(Float.self, forKey: .colorSchemeHighlights) ?? 0.0
        minDistance = try container.decode(Float.self, forKey: .minDistance)
        fractalScale = try container.decode(Float.self, forKey: .fractalScale)
        foldingLimit = try container.decode(Float.self, forKey: .foldingLimit)
        sphereRadius = try container.decode(Float.self, forKey: .sphereRadius)
        formulaParamValues = try container.decodeIfPresent([Float].self, forKey: .formulaParamValues)
        resolutionScale = try container.decodeIfPresent(Float.self, forKey: .resolutionScale)
        tileSize = try container.decodeIfPresent(Int.self, forKey: .tileSize)
        safetyBubbleEnabled = try container.decodeIfPresent(Bool.self, forKey: .safetyBubbleEnabled)
        safetyBubbleRadius = try container.decodeIfPresent(Float.self, forKey: .safetyBubbleRadius)
        safetyBubbleShape = try container.decodeIfPresent(Float.self, forKey: .safetyBubbleShape)
        
        // v2.0 modular lighting effects
        lightingMode = try container.decodeIfPresent(LightingMode.self, forKey: .lightingMode)
        lightingPreset = try container.decodeIfPresent(LightingPreset.self, forKey: .lightingPreset)
        hueRotationEffect = try container.decodeIfPresent(HueRotationEffect.self, forKey: .hueRotationEffect)
        pulseEffect = try container.decodeIfPresent(PulseEffect.self, forKey: .pulseEffect)
        glowEffect = try container.decodeIfPresent(GlowEffect.self, forKey: .glowEffect)
        bloomEffect = try container.decodeIfPresent(BloomEffect.self, forKey: .bloomEffect)
        fogEffect = try container.decodeIfPresent(FogEffect.self, forKey: .fogEffect)
        gradientCycleEffect = try container.decodeIfPresent(GradientCycleEffect.self, forKey: .gradientCycleEffect)
        
        // Doppelganger
        doppelgangerEnabled = try container.decodeIfPresent(Bool.self, forKey: .doppelgangerEnabled)
        doppelgangerPlane = try container.decodeIfPresent(SIMD3<Float>.self, forKey: .doppelgangerPlane)
        doppelgangerOffset = try container.decodeIfPresent(Float.self, forKey: .doppelgangerOffset)
        
        // Color scheme auto-transition
        colorSchemeAutoTransition = try container.decodeIfPresent(Bool.self, forKey: .colorSchemeAutoTransition)
        colorSchemeAutoInterval = try container.decodeIfPresent(Float.self, forKey: .colorSchemeAutoInterval)
        colorSchemeTransitionDuration = try container.decodeIfPresent(Float.self, forKey: .colorSchemeTransitionDuration)
        
        // v2.1 gradient coloring system
        gradientState = try container.decodeIfPresent(GradientState.self, forKey: .gradientState)
        lightingSoftness = try container.decodeIfPresent(Float.self, forKey: .lightingSoftness)
        musicReactiveMappings = try container.decodeIfPresent([MusicReactiveMapping].self, forKey: .musicReactiveMappings)
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
        try container.encodeIfPresent(formulaParamValues, forKey: .formulaParamValues)
        try container.encodeIfPresent(resolutionScale, forKey: .resolutionScale)
        try container.encodeIfPresent(tileSize, forKey: .tileSize)
        try container.encodeIfPresent(safetyBubbleEnabled, forKey: .safetyBubbleEnabled)
        try container.encodeIfPresent(safetyBubbleRadius, forKey: .safetyBubbleRadius)
        try container.encodeIfPresent(safetyBubbleShape, forKey: .safetyBubbleShape)
        
        // v2.0 modular lighting effects
        try container.encodeIfPresent(lightingMode, forKey: .lightingMode)
        try container.encodeIfPresent(lightingPreset, forKey: .lightingPreset)
        try container.encodeIfPresent(hueRotationEffect, forKey: .hueRotationEffect)
        try container.encodeIfPresent(pulseEffect, forKey: .pulseEffect)
        try container.encodeIfPresent(glowEffect, forKey: .glowEffect)
        try container.encodeIfPresent(bloomEffect, forKey: .bloomEffect)
        try container.encodeIfPresent(fogEffect, forKey: .fogEffect)
        try container.encodeIfPresent(gradientCycleEffect, forKey: .gradientCycleEffect)
        
        // Doppelganger
        try container.encodeIfPresent(doppelgangerEnabled, forKey: .doppelgangerEnabled)
        try container.encodeIfPresent(doppelgangerPlane, forKey: .doppelgangerPlane)
        try container.encodeIfPresent(doppelgangerOffset, forKey: .doppelgangerOffset)
        
        // Color scheme auto-transition
        try container.encodeIfPresent(colorSchemeAutoTransition, forKey: .colorSchemeAutoTransition)
        try container.encodeIfPresent(colorSchemeAutoInterval, forKey: .colorSchemeAutoInterval)
        try container.encodeIfPresent(colorSchemeTransitionDuration, forKey: .colorSchemeTransitionDuration)
        
        // v2.1 gradient coloring system
        try container.encodeIfPresent(gradientState, forKey: .gradientState)
        try container.encodeIfPresent(lightingSoftness, forKey: .lightingSoftness)
        try container.encodeIfPresent(musicReactiveMappings, forKey: .musicReactiveMappings)
    }
    
    // MARK: - Function Constant Derivation
    
    /// Derives optimal shader function constants from this preset's settings.
    /// This enables the Metal compiler to specialize shaders for this preset,
    /// eliminating unused code paths and enabling loop unrolling.
    ///
    /// The derived constants include:
    /// - `fractalIterations`: Enables Map() loop unrolling
    /// - `shadowIterations`: Typically fractalIterations - 2
    /// - `maxRaySteps`: Enables raymarch loop optimization
    /// - `neonModeEnabled`: Eliminates neon orbit tracking when false
    /// - `colorIterations`: Enables color loop unrolling
    /// - `safetyBubbleEnabled`: Eliminates bubble distance check when false
    ///
    /// Usage:
    /// ```swift
    /// let config = preset.deriveFunctionConstants()
    /// let pipeline = try Renderer.buildSpecializedPipeline(config: config, ...)
    /// ```
    func deriveFunctionConstants() -> (
        fractalIterations: Int32,
        shadowIterations: Int32,
        maxRaySteps: Int32,
        neonModeEnabled: Bool,
        colorIterations: Int32,
        safetyBubbleEnabled: Bool,
        qualityMode: Int32
    ) {
        // Derive quality mode from iteration count
        let qualityMode: Int32
        switch fractalIterations {
        case 0...7: qualityMode = 2   // Low
        case 8...9: qualityMode = 1   // Medium  
        default: qualityMode = 0      // High
        }
        
        return (
            fractalIterations: Int32(fractalIterations),
            shadowIterations: Int32(max(fractalIterations - 2, 2)),
            maxRaySteps: Int32(maxRaySteps),
            neonModeEnabled: colorScheme.isNeonMode,
            colorIterations: Int32(colorIterations),
            safetyBubbleEnabled: safetyBubbleEnabled ?? true,
            qualityMode: qualityMode
        )
    }
    
    /// Returns a unique key for pipeline caching based on function constants.
    /// Presets with identical function constant values can share pipelines.
    var pipelineCacheKey: String {
        let fc = deriveFunctionConstants()
        return "FT\(fractalType.rawValue)_FI\(fc.fractalIterations)_RS\(fc.maxRaySteps)_N\(fc.neonModeEnabled ? 1 : 0)_Q\(fc.qualityMode)"
    }
    
    /// Create a preset from current render settings
    static func fromSettings(_ settings: RenderSettings, name: String, thumbnailData: Data? = nil) -> FractalPreset {
        var preset = FractalPreset(name: name, thumbnailData: thumbnailData)
        
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
        
        // Capture formula params for all types (unified path)
        let fp = settings.formulaParams
        var vals = [Float](repeating: 0, count: 16)
        for i in 0..<16 { vals[i] = FormulaCatalog.getParam(fp, index: i) }
        preset.formulaParamValues = vals
        
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
        preset.musicReactiveMappings = settings.musicReactiveMappings
        
        return preset
    }
    
    /// Apply this preset to render settings
    func apply(to settings: RenderSettings, includePerformance: Bool = false) {
        settings.fractalIterations = fractalIterations
        settings.maxRaySteps = maxRaySteps
        settings.colorMix = colorMix
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
        settings.targetFractalScale = fractalScale
        settings.foldingLimit = foldingLimit
        settings.sphereRadius = sphereRadius
        
        // Restore formula params for all types (unified path)
        if let vals = formulaParamValues {
            var fp = fractalType.defaultFormulaParams()
            for i in 0..<min(16, vals.count) {
                FormulaCatalog.setParam(&fp, index: i, value: vals[i])
            }
            settings.formulaParams = fp
        }
        
        // Also set target values for gesture-controlled parameters
        // This ensures smooth transitions when loading presets
        settings.setTargets(
            minDistance: minDistance,
            foldingLimit: foldingLimit,
            sphereRadius: sphereRadius,
            position: position
        )
        
        // Reset detail transform to identity when loading a preset
        let identity = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        settings.worldRotation = identity
        settings.targetWorldRotation = identity
        settings.detailScale = 1.0
        settings.targetDetailScale = 1.0
        
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
        if let safetyBubbleShape = safetyBubbleShape {
            settings.safetyBubbleShape = safetyBubbleShape
        }
        
        // v2.0 modular lighting effects
        if let lightingMode = lightingMode {
            settings.lightingMode = lightingMode
        }
        if let lightingPreset = lightingPreset {
            settings.lightingPreset = lightingPreset
        }
        if let hueRotationEffect = hueRotationEffect {
            settings.hueRotationEffect = hueRotationEffect
        }
        if let pulseEffect = pulseEffect {
            settings.pulseEffect = pulseEffect
        }
        if let glowEffect = glowEffect {
            settings.glowEffect = glowEffect
        }
        if let bloomEffect = bloomEffect {
            settings.bloomEffect = bloomEffect
        }
        if let fogEffect = fogEffect {
            settings.fogEffect = fogEffect
        }
        if let gradientCycleEffect = gradientCycleEffect {
            settings.gradientCycleEffect = gradientCycleEffect
        }
        
        // Doppelganger
        if let doppelgangerEnabled = doppelgangerEnabled {
            settings.doppelgangerEnabled = doppelgangerEnabled
        }
        if let doppelgangerPlane = doppelgangerPlane {
            settings.doppelgangerPlane = doppelgangerPlane
        }
        if let doppelgangerOffset = doppelgangerOffset {
            settings.doppelgangerOffset = doppelgangerOffset
        }
        
        // Color scheme auto-transition
        if let colorSchemeAutoTransition = colorSchemeAutoTransition {
            settings.colorSchemeAutoTransition = colorSchemeAutoTransition
        }
        if let colorSchemeAutoInterval = colorSchemeAutoInterval {
            settings.colorSchemeAutoInterval = colorSchemeAutoInterval
        }
        if let colorSchemeTransitionDuration = colorSchemeTransitionDuration {
            settings.colorSchemeTransitionDuration = colorSchemeTransitionDuration
        }
        
        // v2.1 gradient coloring system
        if let gradientState = gradientState {
            settings.gradientState = gradientState
        }
        if let lightingSoftness = lightingSoftness {
            settings.lightingSoftness = lightingSoftness
        }
        if let musicReactiveMappings = musicReactiveMappings {
            settings.musicReactiveMappings = musicReactiveMappings
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
    private static let thumbnailCache = NSCache<NSString, UIImage>()

    static func clearThumbnailCache(for id: UUID) {
        thumbnailCache.removeObject(forKey: id.uuidString as NSString)
    }

    static func clearThumbnailCache() {
        thumbnailCache.removeAllObjects()
    }

    var thumbnailImage: UIImage? {
        let cacheKey = id.uuidString as NSString
        guard let data = thumbnailData else {
            Self.thumbnailCache.removeObject(forKey: cacheKey)
            return nil
        }
        if let cached = Self.thumbnailCache.object(forKey: cacheKey) {
            return cached
        }
        guard let decoded = UIImage(data: data) else {
            return nil
        }
        Self.thumbnailCache.setObject(decoded, forKey: cacheKey)
        return decoded
    }
    #elseif os(macOS)
    private static let thumbnailCache = NSCache<NSString, NSImage>()

    static func clearThumbnailCache(for id: UUID) {
        thumbnailCache.removeObject(forKey: id.uuidString as NSString)
    }

    static func clearThumbnailCache() {
        thumbnailCache.removeAllObjects()
    }

    var thumbnailImage: NSImage? {
        let cacheKey = id.uuidString as NSString
        guard let data = thumbnailData else {
            Self.thumbnailCache.removeObject(forKey: cacheKey)
            return nil
        }
        if let cached = Self.thumbnailCache.object(forKey: cacheKey) {
            return cached
        }
        guard let decoded = NSImage(data: data) else {
            return nil
        }
        Self.thumbnailCache.setObject(decoded, forKey: cacheKey)
        return decoded
    }
    #endif
}
