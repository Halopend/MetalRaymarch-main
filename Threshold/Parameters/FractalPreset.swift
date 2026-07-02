//
//  FractalPreset.swift
//  Threshold
//
//  Represents a saved preset with all render settings and a preview image.
//  Extracted from PresetManager.swift for single-responsibility.
//

import SwiftUI
import Foundation
import ImageIO
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
    
    // Orientation & detail zoom
    var worldRotationX: Float?
    var worldRotationY: Float?
    var worldRotationZ: Float?
    var worldRotationW: Float?
    var detailScale: Float?
    
    // Safety bubble
    var safetyBubbleEnabled: Bool?
    var safetyBubbleRadius: Float?
    var safetyBubbleShape: Float?
    var safetyBubbleBlend: Float?

    // === SPACE TRANSFORMS (Space module) ===
    // Domain/space-level transforms owned by DisplayConfig. These were previously
    // dropped on save/load (the fields existed only in DisplayConfig, never in the
    // preset), so a scene authored with sphere inversion/projection silently lost
    // them. Optional for backward compatibility — older files decode to nil and the
    // live settings keep their current values.
    var sphericalInversionMode: SphericalInversionMode?
    var sphericalInversionRadius: Float?
    var sphereProjectionEnabled: Bool?
    var sphereProjectionBlend: Float?
    var sphereProjectionRadius: Float?
    // Composable domain-transform stack (Transformations section). Optional for
    // backward compatibility — older files decode to nil and keep live values.
    var spaceWarpOps: [SpaceWarpOpValue]?

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
    var linearRailEffect: LinearRailEffect?
    
    // === COLOR SCHEME AUTO-TRANSITION ===
    var colorSchemeAutoTransition: Bool?
    var colorSchemeAutoInterval: Float?
    var colorSchemeTransitionDuration: Float?
    
    // === GRADIENT COLORING SYSTEM (v2.1) ===
    var gradientState: GradientState?
    var lightingSoftness: Float?
    /// Legacy field — mappings array only. Kept for backward compatibility with builds
    /// that cannot read `audioReactiveConfig`. New code always uses `audioReactiveConfig`.
    var musicReactiveMappings: [MusicReactiveMapping]?
    /// Full audio-reactive configuration: master toggle, amount, sensitivities,
    /// beat punch, triplet gains, and per-target mappings.
    var audioReactiveConfig: AudioReactiveConfig?

    /// Optional embedded distance estimator + parameter metadata.
    /// When present, the preset is self-contained: the renderer compiles the embedded
    /// Metal source at load time and renders via `FractalModelType.custom` instead of
    /// a built-in formula. Older app versions ignore this field.
    var embeddedFormula: EmbeddedFormula?

    // === MODULE LAYER (additive, backward-compatible) ===
    /// Scene schema version. Purely diagnostic — decoding never depends on it.
    var schemaVersion: Int?
    /// Typed/keyed params grouped by module (see `ModuleRegistry`). Coexists with
    /// the flat fields above: on load, flat fields apply first, then these module
    /// blocks apply with per-fractal capability filtering. Absent in older scenes.
    var modules: [String: ModuleParamBlock]?

    // === ADDITIONAL SCENE STATE (previously dropped on save) ===
    // Visual scene state that lives in the domain configs but was never captured
    // into the preset, so authoring it then saving silently lost it on reload
    // (same class of bug as the sphere transforms above). All optional for
    // backward compatibility — older files decode to nil and `apply` leaves the
    // live value untouched. Device-local performance/acceleration settings
    // (QualityConfig) are intentionally NOT included: a scene must not force
    // foveation/cone-march/etc. onto another device.
    var platformEnabled: Bool?            // DisplayConfig — glass-floor on/off
    var mixedModeScene: Bool?             // visionOS — scene authored for Mixed immersion (passthrough background); nil for Full/Partial
    var boundingShapeEnabled: Bool?       // Bounding Shape (sphere) clip on/off
    var boundingShapeRadius: Float?       // Bounding Shape radius, model units
    var boundingShapeFogEnabled: Bool?    // legacy — migrated into boundingShapeFogMode on load
    var boundingShapeFogMode: Int?        // Bounding edge treatment: 0=off, 1=Ghost Fade, 2=Inner Shadow
    var boundingShapeShadowDepth: Float?  // Inner Shadow band width, fraction of boundingShapeRadius
    var platformRadius: Float?            // DisplayConfig — glass-floor size
    var cellShadingEnabled: Bool?         // ColorConfig — toon shading on/off
    var cellShadingLevels: Float?         // ColorConfig — toon banding levels
    var aoStrength: Float?                // ColorConfig — ambient-occlusion blend (0 = old flat ambient)
    var tonemapStrength: Float?           // ColorConfig — filmic (ACES) tonemap blend (0 = old plain clamp)
    var lightVariationRate: Float?        // LightingConfig — master time-variation speed
    var beatFlashEffect: BeatFlashEffect?       // LightingConfig — beat-driven flash
    var polarRotationEffect: PolarRotationEffect? // LightingConfig — polar-angle drift
    var juliaDriftEffect: JuliaDriftEffect?       // LightingConfig — Julia-C orbit
    var safetyBubbleFadeEnabled: Bool?    // SafetyBubbleConfig — edge fade on/off
    var safetyBubbleFadeWidth: Float?     // SafetyBubbleConfig — edge fade width

    enum CodingKeys: String, CodingKey {
        case id, name, createdAt, thumbnailData, rating
        case fractalIterations, maxRaySteps, colorMix, colorIterations, position, scale
        case fractalType, colorScheme, colorSchemeSaturation, colorSchemeContrast, colorSchemeGamma
        case colorSchemeVibrance, colorSchemeCurve, colorSchemeShadows, colorSchemeHighlights
        case minDistance, fractalScale, foldingLimit, sphereRadius, formulaParamValues
        case worldRotationX, worldRotationY, worldRotationZ, worldRotationW, detailScale
        case resolutionScale, tileSize, safetyBubbleEnabled, safetyBubbleRadius, safetyBubbleShape, safetyBubbleBlend
        // Space module (domain transforms)
        case sphericalInversionMode, sphericalInversionRadius
        case sphereProjectionEnabled, sphereProjectionBlend, sphereProjectionRadius
        case spaceWarpOps
        // v2.0 modular lighting effects
        case lightingMode, lightingPreset, hueRotationEffect, pulseEffect, glowEffect, bloomEffect, fogEffect, gradientCycleEffect, linearRailEffect
        // Color scheme auto-transition
        case colorSchemeAutoTransition, colorSchemeAutoInterval, colorSchemeTransitionDuration
        // v2.1 gradient coloring system
        case gradientState, lightingSoftness
        case musicReactiveMappings  // legacy — mappings only
        case audioReactiveConfig    // canonical — full config
        case embeddedFormula        // optional self-contained DE shader payload
        case schemaVersion, modules // module layer (typed/keyed params)
        // Additional scene state (previously dropped on save)
        case platformEnabled, platformRadius
        case mixedModeScene, boundingShapeEnabled, boundingShapeRadius, boundingShapeFogEnabled
        case boundingShapeFogMode, boundingShapeShadowDepth
        case cellShadingEnabled, cellShadingLevels, aoStrength, tonemapStrength
        case lightVariationRate, beatFlashEffect, polarRotationEffect, juliaDriftEffect
        case safetyBubbleFadeEnabled, safetyBubbleFadeWidth
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
        self.colorSchemeSaturation = 1.7
        self.colorSchemeContrast = 1.08
        self.colorSchemeGamma = 0.85
        self.colorSchemeVibrance = 0.8
        self.colorSchemeCurve = 0.0
        self.colorSchemeShadows = -0.018
        self.colorSchemeHighlights = 0.02
        
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
        // Peek the raw fractalType marker BEFORE it maps through the alias so we
        // can detect a legacy "mandelboxSphereProjection" scene. The type itself
        // decodes to `.mandelbox` (FractalModelType back-compat alias); the
        // sphere-projection fields are filled below from params[4]/[5].
        let legacyMandelboxSphereProjection: Bool = {
            if let str = try? container.decode(String.self, forKey: .fractalType) {
                return str == "mandelboxSphereProjection"
            }
            if let raw = try? container.decode(Int32.self, forKey: .fractalType) {
                return raw == 21
            }
            return false
        }()
        fractalType = try container.decodeIfPresent(FractalModelType.self, forKey: .fractalType) ?? .mandelbox
        colorScheme = try container.decodeIfPresent(ColorScheme.self, forKey: .colorScheme) ?? .classic
        colorSchemeSaturation = try container.decodeIfPresent(Float.self, forKey: .colorSchemeSaturation) ?? 1.7
        colorSchemeContrast = try container.decodeIfPresent(Float.self, forKey: .colorSchemeContrast) ?? 1.08
        colorSchemeGamma = try container.decodeIfPresent(Float.self, forKey: .colorSchemeGamma) ?? 0.85
        colorSchemeVibrance = try container.decodeIfPresent(Float.self, forKey: .colorSchemeVibrance) ?? 0.8
        colorSchemeCurve = try container.decodeIfPresent(Float.self, forKey: .colorSchemeCurve) ?? 0.0
        colorSchemeShadows = try container.decodeIfPresent(Float.self, forKey: .colorSchemeShadows) ?? -0.018
        colorSchemeHighlights = try container.decodeIfPresent(Float.self, forKey: .colorSchemeHighlights) ?? 0.02
        minDistance = try container.decodeIfPresent(Float.self, forKey: .minDistance) ?? 0.8
        fractalScale = try container.decodeIfPresent(Float.self, forKey: .fractalScale) ?? 2.8
        foldingLimit = try container.decodeIfPresent(Float.self, forKey: .foldingLimit) ?? 1.0
        sphereRadius = try container.decodeIfPresent(Float.self, forKey: .sphereRadius) ?? 0.5
        formulaParamValues = try container.decodeIfPresent([Float].self, forKey: .formulaParamValues)
        resolutionScale = try container.decodeIfPresent(Float.self, forKey: .resolutionScale)
        let decodedTileSize = try container.decodeIfPresent(Int.self, forKey: .tileSize)
        tileSize = decodedTileSize == 2 ? nil : decodedTileSize  // Old "Quad Shared" mode removed → degrade to fragment
        worldRotationX = try container.decodeIfPresent(Float.self, forKey: .worldRotationX)
        worldRotationY = try container.decodeIfPresent(Float.self, forKey: .worldRotationY)
        worldRotationZ = try container.decodeIfPresent(Float.self, forKey: .worldRotationZ)
        worldRotationW = try container.decodeIfPresent(Float.self, forKey: .worldRotationW)
        detailScale = try container.decodeIfPresent(Float.self, forKey: .detailScale)
        safetyBubbleEnabled = try container.decodeIfPresent(Bool.self, forKey: .safetyBubbleEnabled)
        safetyBubbleRadius = try container.decodeIfPresent(Float.self, forKey: .safetyBubbleRadius)
        safetyBubbleShape = try container.decodeIfPresent(Float.self, forKey: .safetyBubbleShape)
        safetyBubbleBlend = try container.decodeIfPresent(Float.self, forKey: .safetyBubbleBlend)

        // Space module (domain transforms) — optional; older files have none.
        sphericalInversionMode = try container.decodeIfPresent(SphericalInversionMode.self, forKey: .sphericalInversionMode)
        sphericalInversionRadius = try container.decodeIfPresent(Float.self, forKey: .sphericalInversionRadius)
        sphereProjectionEnabled = try container.decodeIfPresent(Bool.self, forKey: .sphereProjectionEnabled)
        sphereProjectionBlend = try container.decodeIfPresent(Float.self, forKey: .sphereProjectionBlend)
        sphereProjectionRadius = try container.decodeIfPresent(Float.self, forKey: .sphereProjectionRadius)
        spaceWarpOps = try container.decodeIfPresent([SpaceWarpOpValue].self, forKey: .spaceWarpOps)

        // Legacy "mandelboxSphereProjection" migration: the dedicated MSP type read
        // the projection blend/radius from formula params[4]/[5] and always projected.
        // Base Mandelbox reproduces the identical look via the Space-tab "Sphere
        // Projection" control (DisplayConfig.sphereProjection*), so turn it on and
        // seed blend/radius from params[4]/[5] — but only when the scene didn't
        // already carry its own sphere-projection values (don't double-apply / stomp
        // a newer explicit format).
        if legacyMandelboxSphereProjection,
           sphereProjectionEnabled == nil,
           sphereProjectionBlend == nil,
           sphereProjectionRadius == nil,
           let vals = formulaParamValues, vals.count > 5 {
            sphereProjectionEnabled = true
            sphereProjectionBlend = vals[4]
            sphereProjectionRadius = vals[5]
            // CRITICAL: the dedicated MSP type read its Mandelbox SHAPE from formula
            // params[0..3] (MinDistance/FoldingLimit/SphereRadius/Scale); the
            // top-level minDistance/foldingLimit/sphereRadius/fractalScale stayed at
            // catalog defaults (0.8/1/0.5/2.8) and were never the real shape. Base
            // Mandelbox reads its shape from those top-level fields, so without this
            // copy a migrated scene renders a DEFAULT box with projection instead of
            // the saved form. (Faithful only when MinDistance ≥ 0 — base Mandelbox
            // forces the DE denominator positive, so negative-MinDistance scenes
            // can't be reproduced without the old formula.)
            minDistance = vals[0]
            foldingLimit = vals[1]
            sphereRadius = vals[2]
            fractalScale = vals[3]
        }

        // v2.0 modular lighting effects
        lightingMode = try container.decodeIfPresent(LightingMode.self, forKey: .lightingMode)
        lightingPreset = try container.decodeIfPresent(LightingPreset.self, forKey: .lightingPreset)
        hueRotationEffect = try container.decodeIfPresent(HueRotationEffect.self, forKey: .hueRotationEffect)
        pulseEffect = try container.decodeIfPresent(PulseEffect.self, forKey: .pulseEffect)
        glowEffect = try container.decodeIfPresent(GlowEffect.self, forKey: .glowEffect)
        bloomEffect = try container.decodeIfPresent(BloomEffect.self, forKey: .bloomEffect)
        fogEffect = try container.decodeIfPresent(FogEffect.self, forKey: .fogEffect)
        gradientCycleEffect = try container.decodeIfPresent(GradientCycleEffect.self, forKey: .gradientCycleEffect)
        linearRailEffect = try container.decodeIfPresent(LinearRailEffect.self, forKey: .linearRailEffect)
        
        // Color scheme auto-transition
        colorSchemeAutoTransition = try container.decodeIfPresent(Bool.self, forKey: .colorSchemeAutoTransition)
        colorSchemeAutoInterval = try container.decodeIfPresent(Float.self, forKey: .colorSchemeAutoInterval)
        colorSchemeTransitionDuration = try container.decodeIfPresent(Float.self, forKey: .colorSchemeTransitionDuration)
        
        // v2.1 gradient coloring system
        gradientState = try container.decodeIfPresent(GradientState.self, forKey: .gradientState)
        lightingSoftness = try container.decodeIfPresent(Float.self, forKey: .lightingSoftness)
        // Decode legacy mappings-only field (still needed to populate audioReactiveConfig
        // when reading files written by older builds that predate audioReactiveConfig).
        musicReactiveMappings = try container.decodeIfPresent([MusicReactiveMapping].self, forKey: .musicReactiveMappings)
            .map { MusicReactiveMapping.migrateLegacy($0) }

        // Full config (written by current builds). Fall back to migrating from legacy
        // musicReactiveMappings so older files regain their mappings without data loss.
        if let fullConfig = try container.decodeIfPresent(AudioReactiveConfig.self, forKey: .audioReactiveConfig) {
            audioReactiveConfig = fullConfig
        } else if let legacyMappings = musicReactiveMappings, !legacyMappings.isEmpty {
            var migrated = AudioReactiveConfig()
            migrated.musicReactiveMappings = legacyMappings
            migrated.fractalAudioReactiveEnabled = true
            audioReactiveConfig = migrated
        } else {
            audioReactiveConfig = nil
        }

        if let formula = try container.decodeIfPresent(EmbeddedFormula.self, forKey: .embeddedFormula) {
            try formula.validate()
            // Only a fractal DE drives FractalModelType.custom; a space-warp
            // effect rides whatever fractalType was decoded.
            if formula.effectKind == .fractal {
                fractalType = .custom
            }
            embeddedFormula = formula
        } else {
            embeddedFormula = nil
        }

        // Module layer (typed/keyed params). Optional — older scenes have none.
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
        modules = try container.decodeIfPresent([String: ModuleParamBlock].self, forKey: .modules)

        // Additional scene state (previously dropped) — all optional/backward-compatible.
        platformEnabled = try container.decodeIfPresent(Bool.self, forKey: .platformEnabled)
        mixedModeScene = try container.decodeIfPresent(Bool.self, forKey: .mixedModeScene)
        boundingShapeEnabled = try container.decodeIfPresent(Bool.self, forKey: .boundingShapeEnabled)
        boundingShapeRadius = try container.decodeIfPresent(Float.self, forKey: .boundingShapeRadius)
        boundingShapeFogEnabled = try container.decodeIfPresent(Bool.self, forKey: .boundingShapeFogEnabled)
        boundingShapeFogMode = try container.decodeIfPresent(Int.self, forKey: .boundingShapeFogMode)
        boundingShapeShadowDepth = try container.decodeIfPresent(Float.self, forKey: .boundingShapeShadowDepth)
        platformRadius = try container.decodeIfPresent(Float.self, forKey: .platformRadius)
        cellShadingEnabled = try container.decodeIfPresent(Bool.self, forKey: .cellShadingEnabled)
        cellShadingLevels = try container.decodeIfPresent(Float.self, forKey: .cellShadingLevels)
        aoStrength = try container.decodeIfPresent(Float.self, forKey: .aoStrength) ?? 0.0
        tonemapStrength = try container.decodeIfPresent(Float.self, forKey: .tonemapStrength) ?? 0.0
        lightVariationRate = try container.decodeIfPresent(Float.self, forKey: .lightVariationRate)
        beatFlashEffect = try container.decodeIfPresent(BeatFlashEffect.self, forKey: .beatFlashEffect)
        polarRotationEffect = try container.decodeIfPresent(PolarRotationEffect.self, forKey: .polarRotationEffect)
        juliaDriftEffect = try container.decodeIfPresent(JuliaDriftEffect.self, forKey: .juliaDriftEffect)
        safetyBubbleFadeEnabled = try container.decodeIfPresent(Bool.self, forKey: .safetyBubbleFadeEnabled)
        safetyBubbleFadeWidth = try container.decodeIfPresent(Float.self, forKey: .safetyBubbleFadeWidth)
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
        try container.encodeIfPresent(worldRotationX, forKey: .worldRotationX)
        try container.encodeIfPresent(worldRotationY, forKey: .worldRotationY)
        try container.encodeIfPresent(worldRotationZ, forKey: .worldRotationZ)
        try container.encodeIfPresent(worldRotationW, forKey: .worldRotationW)
        try container.encodeIfPresent(detailScale, forKey: .detailScale)
        try container.encodeIfPresent(safetyBubbleEnabled, forKey: .safetyBubbleEnabled)
        try container.encodeIfPresent(safetyBubbleRadius, forKey: .safetyBubbleRadius)
        try container.encodeIfPresent(safetyBubbleShape, forKey: .safetyBubbleShape)
        try container.encodeIfPresent(safetyBubbleBlend, forKey: .safetyBubbleBlend)

        // Space module (domain transforms)
        try container.encodeIfPresent(sphericalInversionMode, forKey: .sphericalInversionMode)
        try container.encodeIfPresent(sphericalInversionRadius, forKey: .sphericalInversionRadius)
        try container.encodeIfPresent(sphereProjectionEnabled, forKey: .sphereProjectionEnabled)
        try container.encodeIfPresent(sphereProjectionBlend, forKey: .sphereProjectionBlend)
        try container.encodeIfPresent(sphereProjectionRadius, forKey: .sphereProjectionRadius)
        try container.encodeIfPresent(spaceWarpOps, forKey: .spaceWarpOps)

        // v2.0 modular lighting effects
        try container.encodeIfPresent(lightingMode, forKey: .lightingMode)
        try container.encodeIfPresent(lightingPreset, forKey: .lightingPreset)
        try container.encodeIfPresent(hueRotationEffect, forKey: .hueRotationEffect)
        try container.encodeIfPresent(pulseEffect, forKey: .pulseEffect)
        try container.encodeIfPresent(glowEffect, forKey: .glowEffect)
        try container.encodeIfPresent(bloomEffect, forKey: .bloomEffect)
        try container.encodeIfPresent(fogEffect, forKey: .fogEffect)
        try container.encodeIfPresent(gradientCycleEffect, forKey: .gradientCycleEffect)
        try container.encodeIfPresent(linearRailEffect, forKey: .linearRailEffect)
        
        // Color scheme auto-transition
        try container.encodeIfPresent(colorSchemeAutoTransition, forKey: .colorSchemeAutoTransition)
        try container.encodeIfPresent(colorSchemeAutoInterval, forKey: .colorSchemeAutoInterval)
        try container.encodeIfPresent(colorSchemeTransitionDuration, forKey: .colorSchemeTransitionDuration)
        
        // v2.1 gradient coloring system
        try container.encodeIfPresent(gradientState, forKey: .gradientState)
        try container.encodeIfPresent(lightingSoftness, forKey: .lightingSoftness)
        // Write full config (canonical) and flat mappings (legacy compat for older builds).
        try container.encodeIfPresent(audioReactiveConfig, forKey: .audioReactiveConfig)
        try container.encodeIfPresent(audioReactiveConfig?.musicReactiveMappings ?? musicReactiveMappings,
                                      forKey: .musicReactiveMappings)
        try container.encodeIfPresent(embeddedFormula, forKey: .embeddedFormula)

        // Module layer (typed/keyed params)
        try container.encodeIfPresent(schemaVersion, forKey: .schemaVersion)
        try container.encodeIfPresent(modules, forKey: .modules)

        // Additional scene state (previously dropped on save)
        try container.encodeIfPresent(platformEnabled, forKey: .platformEnabled)
        try container.encodeIfPresent(mixedModeScene, forKey: .mixedModeScene)
        try container.encodeIfPresent(boundingShapeEnabled, forKey: .boundingShapeEnabled)
        try container.encodeIfPresent(boundingShapeRadius, forKey: .boundingShapeRadius)
        try container.encodeIfPresent(boundingShapeFogMode, forKey: .boundingShapeFogMode)
        try container.encodeIfPresent(boundingShapeShadowDepth, forKey: .boundingShapeShadowDepth)
        try container.encodeIfPresent(platformRadius, forKey: .platformRadius)
        try container.encodeIfPresent(cellShadingEnabled, forKey: .cellShadingEnabled)
        try container.encodeIfPresent(cellShadingLevels, forKey: .cellShadingLevels)
        try container.encodeIfPresent(aoStrength, forKey: .aoStrength)
        try container.encodeIfPresent(tonemapStrength, forKey: .tonemapStrength)
        try container.encodeIfPresent(lightVariationRate, forKey: .lightVariationRate)
        try container.encodeIfPresent(beatFlashEffect, forKey: .beatFlashEffect)
        try container.encodeIfPresent(polarRotationEffect, forKey: .polarRotationEffect)
        try container.encodeIfPresent(juliaDriftEffect, forKey: .juliaDriftEffect)
        try container.encodeIfPresent(safetyBubbleFadeEnabled, forKey: .safetyBubbleFadeEnabled)
        try container.encodeIfPresent(safetyBubbleFadeWidth, forKey: .safetyBubbleFadeWidth)
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
        qualityMode: Int32,
        mandelbulbPower: Int32?
    ) {
        // Derive quality mode from iteration count
        let qualityMode: Int32
        switch fractalIterations {
        case 0...7: qualityMode = 2   // Low
        case 8...9: qualityMode = 1   // Medium  
        default: qualityMode = 0      // High
        }

        let mandelbulbPower: Int32? = {
            guard fractalType == .mandelbulb,
                  let rawPower = formulaParamValues?.first else { return nil }
            let rounded = roundf(rawPower)
            guard abs(rawPower - rounded) < 0.01,
                  [2, 3, 4, 5, 6, 8, 10, 12, 16].contains(Int(rounded)) else {
                return nil
            }
            return Int32(rounded)
        }()
        
        return (
            fractalIterations: Int32(fractalIterations),
            shadowIterations: Int32(max(fractalIterations - 2, 2)),
            maxRaySteps: Int32(maxRaySteps),
            neonModeEnabled: colorScheme.isNeonMode,
            colorIterations: Int32(colorIterations),
            safetyBubbleEnabled: safetyBubbleEnabled ?? true,
            qualityMode: qualityMode,
            mandelbulbPower: mandelbulbPower
        )
    }
    
    /// Effective safety-bubble bake for this preset. Mirrors the renderer's
    /// `effectiveSafetyBubbleEnabled` (mandelbulb force-disables the bubble) so the
    /// preset-built pipeline and `selectPipeline` agree on the baked FC and key.
    var effectiveSafetyBubbleEnabled: Bool {
        fractalType != .mandelbulb && (safetyBubbleEnabled ?? true)
    }

    /// Whether this preset needs the space-warp seam compiled in (FC_HAS_SPACEWARP).
    /// Conservative: any transform stack OR a custom library (which may carry a
    /// `.threshfx` warp) keeps it ON. Only a pure built-in with an empty stack bakes
    /// it OFF, letting the whole warp path dead-code-eliminate. Over-approximation
    /// only ever costs the optimization, never correctness (mirrors the renderer's
    /// live derivation in `selectPipeline`, which is authoritative per frame).
    var effectiveHasSpaceWarp: Bool {
        !(spaceWarpOps?.isEmpty ?? true) || fractalType == .custom || embeddedFormula != nil
    }

    /// Returns a unique key for pipeline caching based on function constants.
    /// Presets with identical function constant values can share pipelines.
    ///
    /// The `_B..._SW...` scene segment must match `RenderPipelineKeyContext`'s exact
    /// key (inserted between RS and _N). Without it, `getPipeline(forPreset:)` stores
    /// the prewarmed pipeline under a key `selectPipeline` never looks up once the
    /// preset is applied, so preset loads miss the prewarm and rebuild/fall back.
    var pipelineCacheKey: String {
        let fc = deriveFunctionConstants()
        let powerKey = fc.mandelbulbPower.map { "_P\($0)" } ?? ""
        let sceneKey = "_B\(effectiveSafetyBubbleEnabled ? 1 : 0)_SW\(effectiveHasSpaceWarp ? 1 : 0)"
        return "FT\(fractalType.rawValue)_FI\(fc.fractalIterations)_RS\(fc.maxRaySteps)\(sceneKey)_N\(fc.neonModeEnabled ? 1 : 0)_Q\(fc.qualityMode)_CI\(fc.colorIterations)\(powerKey)"
    }
    
    /// Create a preset from current render settings
    static func fromSettings(_ settings: RenderSettings, name: String, id: UUID = UUID(), createdAt: Date = Date(), thumbnailData: Data? = nil, embeddedFormula: EmbeddedFormula? = nil) -> FractalPreset {
        var preset = FractalPreset(id: id, name: name, createdAt: createdAt, thumbnailData: thumbnailData)

        // ── Geometry domain (1 lock acquisition) ──
        let geo = settings.geometryConfig
        preset.fractalType = geo.fractalType
        preset.minDistance = geo.minDistance
        preset.fractalScale = geo.fractalScale
        preset.foldingLimit = geo.foldingLimit
        preset.sphereRadius = geo.sphereRadius
        preset.position = geo.position
        preset.scale = geo.scale
        // Capture orientation and detail zoom
        let rot = geo.worldRotation
        preset.worldRotationX = rot.imag.x
        preset.worldRotationY = rot.imag.y
        preset.worldRotationZ = rot.imag.z
        preset.worldRotationW = rot.real
        preset.detailScale = geo.detailScale
        // Capture formula params as [Float] for Codable
        var vals = [Float](repeating: 0, count: 16)
        for i in 0..<16 { vals[i] = FormulaCatalog.getParam(geo.formulaParams, index: i) }
        preset.formulaParamValues = vals

        // ── Quality domain (1 lock acquisition) ──
        let qual = settings.qualityConfig
        preset.fractalIterations = qual.baseFractalIterations
        preset.maxRaySteps = qual.baseMaxRaySteps
        preset.resolutionScale = qual.resolutionScale
        preset.tileSize = qual.tileSize

        // ── Color domain (1 lock acquisition) ──
        let col = settings.colorConfig
        preset.colorScheme = col.colorScheme
        preset.colorMix = col.colorMix
        preset.colorIterations = col.colorIterations
        preset.colorSchemeSaturation = col.colorSchemeSaturation
        preset.colorSchemeContrast = col.colorSchemeContrast
        preset.colorSchemeGamma = col.colorSchemeGamma
        preset.colorSchemeVibrance = col.colorSchemeVibrance
        preset.colorSchemeCurve = col.colorSchemeCurve
        preset.colorSchemeShadows = col.colorSchemeShadows
        preset.colorSchemeHighlights = col.colorSchemeHighlights
        preset.lightingSoftness = col.lightingSoftness
        preset.colorSchemeAutoTransition = col.colorSchemeAutoTransition
        preset.colorSchemeAutoInterval = col.colorSchemeAutoInterval
        preset.colorSchemeTransitionDuration = col.colorSchemeTransitionDuration
        preset.gradientState = col.gradientState
        // Cell (toon) shading (previously dropped).
        preset.cellShadingEnabled = col.cellShadingEnabled
        preset.cellShadingLevels = col.cellShadingLevels
        preset.aoStrength = col.aoStrength
        preset.tonemapStrength = col.tonemapStrength

        // ── Lighting domain (1 lock acquisition) ──
        let lit = settings.lightingConfig
        preset.lightingPreset = lit.lightingPreset
        preset.hueRotationEffect = lit.hueRotationEffect
        preset.pulseEffect = lit.pulseEffect
        preset.glowEffect = lit.glowEffect
        preset.bloomEffect = lit.bloomEffect
        preset.fogEffect = lit.fogEffect
        preset.gradientCycleEffect = lit.gradientCycleEffect
        preset.linearRailEffect = lit.linearRailEffect
        // Remaining lighting state (previously dropped).
        preset.lightVariationRate = lit.lightVariationRate
        preset.beatFlashEffect = lit.beatFlashEffect
        preset.polarRotationEffect = lit.polarRotationEffect
        preset.juliaDriftEffect = lit.juliaDriftEffect

        // ── Display domain (1 lock acquisition) ──
        let disp = settings.displayConfig
        preset.lightingMode = disp.lightingMode
        // Space-module transforms live in DisplayConfig — capture them so they
        // round-trip through save/load (previously dropped).
        preset.sphericalInversionMode = disp.sphericalInversionMode
        preset.sphericalInversionRadius = disp.sphericalInversionRadius
        preset.sphereProjectionEnabled = disp.sphereProjectionEnabled
        preset.sphereProjectionBlend = disp.sphereProjectionBlend
        preset.sphereProjectionRadius = disp.sphereProjectionRadius
        // Glass-floor platform (previously dropped).
        preset.platformEnabled = disp.platformEnabled
        preset.platformRadius = disp.platformRadius
        // Bounding Shape (sphere) — artistic clip, round-trips with the scene.
        preset.boundingShapeEnabled = settings.boundingSphereSkipEnabled
        preset.boundingShapeRadius = settings.boundingShapeRadius
        preset.boundingShapeFogMode = settings.boundingShapeFogMode
        preset.boundingShapeShadowDepth = settings.boundingShapeShadowDepth
        // Mixed-immersion scene marker (visionOS): recorded only when the scene
        // is saved while Mixed is active, so loading it can restore the
        // passthrough presentation. Full/Partial saves leave it nil and loading
        // never *exits* Mixed — the user controls that from the picker.
        #if os(visionOS)
        if AppModel.shared?.immersionStyleForRenderer == .mixed {
            preset.mixedModeScene = true
        }
        #endif
        // Composable domain-transform stack (Transformations section). Direct
        // RenderSettings property, not in DisplayConfig. Empty array → nil so older
        // readers and round-trips stay clean.
        let warpOps = settings.spaceWarpStack
        preset.spaceWarpOps = warpOps.isEmpty ? nil : warpOps

        // ── Safety bubble domain (1 lock acquisition) ──
        let sb = settings.safetyBubbleConfig
        preset.safetyBubbleEnabled = sb.enabled
        preset.safetyBubbleRadius = sb.radius
        preset.safetyBubbleShape = sb.shape
        preset.safetyBubbleBlend = sb.strength
        // Bubble edge fade (previously dropped).
        preset.safetyBubbleFadeEnabled = sb.fadeEnabled
        preset.safetyBubbleFadeWidth = sb.fadeWidth

        // ── Audio reactive domain (1 lock acquisition) ──
        let arc = settings.audioReactiveConfig
        preset.audioReactiveConfig = arc
        // Keep legacy field in sync so files remain readable by older builds.
        preset.musicReactiveMappings = arc.musicReactiveMappings
        // Persist any embedded effect (custom fractal OR space warp). The decoder
        // only forces fractalType = .custom for a `.fractal` kind, so a warp
        // round-trips on top of whatever built-in fractal is active.
        preset.embeddedFormula = embeddedFormula

        return preset
    }
    
    /// Apply this preset to render settings
    func apply(to settings: RenderSettings, includePerformance: Bool = true, resetEnvironment: Bool = false) {
        if resetEnvironment {
            settings.audioReactiveConfig = AudioReactiveConfig()
        }

        settings.baseFractalIterations = fractalIterations
        settings.baseMaxRaySteps = maxRaySteps
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
        
        // Restore orientation and detail zoom (fall back to identity for older presets)
        if let rx = worldRotationX, let ry = worldRotationY,
           let rz = worldRotationZ, let rw = worldRotationW {
            let q = simd_quatf(ix: rx, iy: ry, iz: rz, r: rw)
            settings.worldRotation = q
            settings.targetWorldRotation = q
        } else {
            let identity = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
            settings.worldRotation = identity
            settings.targetWorldRotation = identity
        }
        let ds = detailScale ?? 1.0
        settings.detailScale = ds
        settings.targetDetailScale = ds
        
        if includePerformance {
            if let resolutionScale = resolutionScale {
                settings.resolutionScale = resolutionScale
            }
            if let tileSize = tileSize {
                settings.tileSize = tileSize
            }
        }
        
        // The safety bubble is user-owned comfort state: users can disable it,
        // scenes cannot. A scene that uses the bubble as part of its authored
        // look applies its full bubble state, but a scene saved without it
        // must NOT silently disable (or reshape) the user's bubble on load.
        if safetyBubbleEnabled == true {
            settings.safetyBubbleEnabled = true
            if let safetyBubbleRadius = safetyBubbleRadius {
                settings.safetyBubbleRadius = safetyBubbleRadius
            }
            if let safetyBubbleShape = safetyBubbleShape {
                settings.safetyBubbleShape = safetyBubbleShape
            }
            if let safetyBubbleBlend = safetyBubbleBlend {
                settings.safetyBubbleBlend = safetyBubbleBlend
            }
            // Bubble edge fade — get-only on RenderSettings, so restore through the
            // whole-config setter (reads current values set just above, mutates fade).
            if safetyBubbleFadeEnabled != nil || safetyBubbleFadeWidth != nil {
                var sb = settings.safetyBubbleConfig
                if let safetyBubbleFadeEnabled = safetyBubbleFadeEnabled {
                    sb.fadeEnabled = safetyBubbleFadeEnabled
                }
                if let safetyBubbleFadeWidth = safetyBubbleFadeWidth {
                    sb.fadeWidth = safetyBubbleFadeWidth
                }
                settings.safetyBubbleConfig = sb
            }
        }

        // Space module (domain transforms) — restore when present.
        if let sphericalInversionMode = sphericalInversionMode {
            settings.sphericalInversionMode = sphericalInversionMode
        }
        if let sphericalInversionRadius = sphericalInversionRadius {
            settings.sphericalInversionRadius = sphericalInversionRadius
        }
        // Sphere projection must be RESET (not left untouched) when the incoming
        // scene doesn't carry it — otherwise the previous scene's enabled state
        // leaks forward. Legacy MSP scenes now turn this ON via the migration above,
        // so a plain `if let` would persist projection into the next non-projection
        // scene. Treat a missing value as the DisplayConfig default (off, 1.0/1.0).
        settings.sphereProjectionEnabled = sphereProjectionEnabled ?? false
        settings.sphereProjectionBlend = sphereProjectionBlend ?? 1.0
        settings.sphereProjectionRadius = sphereProjectionRadius ?? 1.0

        // Composable domain-transform stack (Transformations section). A scene fully
        // defines its transforms, so apply AUTHORITATIVELY: nil/absent (an empty stack
        // or an older pre-transform scene) clears any transforms the previous scene
        // left live, instead of leaking them into this one.
        settings.spaceWarpStack = spaceWarpOps ?? []

        // Glass-floor platform — restore when present (older scenes leave it as-is).
        if let platformEnabled = platformEnabled {
            settings.platformEnabled = platformEnabled
        }
        if let platformRadius = platformRadius {
            settings.platformRadius = platformRadius
        }

        // Bounding Shape (sphere) — restore when present (older scenes leave it as-is).
        if let boundingShapeEnabled = boundingShapeEnabled {
            settings.boundingSphereSkipEnabled = boundingShapeEnabled
        }
        if let boundingShapeRadius = boundingShapeRadius {
            settings.boundingShapeRadius = boundingShapeRadius
        }
        if let boundingShapeFogMode = boundingShapeFogMode {
            settings.boundingShapeFogMode = boundingShapeFogMode
        } else if let boundingShapeFogEnabled = boundingShapeFogEnabled {
            // Legacy scenes: the old on/off toggle mapped to Ghost Fade.
            settings.boundingShapeFogMode = boundingShapeFogEnabled ? 1 : 0
        }
        if let boundingShapeShadowDepth = boundingShapeShadowDepth {
            settings.boundingShapeShadowDepth = boundingShapeShadowDepth
        }

        // Mixed-immersion scene (visionOS): switch the presentation style to
        // Mixed when the scene was authored for it. Never switches *away* from
        // Mixed — that stays a user choice in the immersion picker.
        #if os(visionOS)
        if mixedModeScene == true {
            Task { @MainActor in
                AppModel.shared?.immersionStylePreference = .mixed
            }
        }
        #endif

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
        if let linearRailEffect = linearRailEffect {
            settings.linearRailEffect = linearRailEffect
        }
        // Remaining lighting state (previously dropped). The effect setters force
        // lightingPreset = .custom, exactly like the effects above, so this is
        // consistent with the existing restore behavior.
        if let lightVariationRate = lightVariationRate {
            settings.lightVariationRate = lightVariationRate
        }
        if let beatFlashEffect = beatFlashEffect {
            settings.beatFlashEffect = beatFlashEffect
        }
        if let polarRotationEffect = polarRotationEffect {
            settings.polarRotationEffect = polarRotationEffect
        }
        if let juliaDriftEffect = juliaDriftEffect {
            settings.juliaDriftEffect = juliaDriftEffect
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
        // Cell (toon) shading — restore when present.
        if let cellShadingEnabled = cellShadingEnabled {
            settings.cellShadingEnabled = cellShadingEnabled
        }
        if let cellShadingLevels = cellShadingLevels {
            settings.cellShadingLevels = cellShadingLevels
        }
        settings.aoStrength = aoStrength ?? 0.0
        settings.tonemapStrength = tonemapStrength ?? 0.0
        if let arc = audioReactiveConfig {
            // Full config present (files saved by current builds): restore everything.
            settings.audioReactiveConfig = arc
        } else if let mappings = musicReactiveMappings, !mappings.isEmpty {
            // Legacy file (mappings-only): restore mappings and auto-enable.
            var audioConfig = settings.audioReactiveConfig
            audioConfig.musicReactiveMappings = mappings
            audioConfig.fractalAudioReactiveEnabled = true
            settings.audioReactiveConfig = audioConfig
        }

        // === MODULE LAYER ===
        // Apply typed/keyed module params AFTER the flat fields, so a module can
        // refine a flat preset. Each param is capability-filtered against the
        // active fractal (e.g. sphere projection on an unsupported type is
        // skipped). No-op for older scenes that carry no `modules` block.
        if let modules = modules {
            for (rawKey, block) in modules {
                guard let key = ModuleKey(rawValue: rawKey) else { continue }
                ModuleRegistry.apply(key, block: block, to: settings)
            }
        }
    }
    
    /// Get the thumbnail as a UIImage (visionOS/iOS) or NSImage (macOS)
    /// Uses ImageIO to downsample to display size, avoiding full-resolution decoding.
    private static let thumbnailMaxPixelSize: CGFloat = 240 // 120pt @2x

    #if os(visionOS) || os(iOS)
    nonisolated(unsafe) private static let thumbnailCache = NSCache<NSString, UIImage>()

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
        guard let decoded = Self.downsampledImage(from: data) else {
            return nil
        }
        Self.thumbnailCache.setObject(decoded, forKey: cacheKey)
        return decoded
    }

    private static func downsampledImage(from data: Data) -> UIImage? {
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary) else {
            return nil
        }
        let downsampleOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailMaxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, downsampleOptions as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
    #elseif os(macOS)
    nonisolated(unsafe) private static let thumbnailCache = NSCache<NSString, NSImage>()

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
        guard let decoded = Self.downsampledImage(from: data) else {
            return nil
        }
        Self.thumbnailCache.setObject(decoded, forKey: cacheKey)
        return decoded
    }

    private static func downsampledImage(from data: Data) -> NSImage? {
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary) else {
            return nil
        }
        let downsampleOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailMaxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, downsampleOptions as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
    #endif
}

extension FractalPreset {
    var isCustomScenePreset: Bool {
        embeddedFormula != nil
    }

    var hasMusicReactiveMappings: Bool {
        !(musicReactiveMappings?.isEmpty ?? true)
    }

    /// Names that should appear in the "Jumping Off" browse tab even though they
    /// carry music-reactive mappings. Shared by the browse UI and the keyboard
    /// scene-switch cycling so both classify presets identically.
    static let jumpingOffNameOverrides: Set<String> = [
        "mandel box flower",
        "replace that",
        "the lovely bones",
        "definitely aliens",
        "ladybug two",
        "ring around the rosie",
        "a space ring odyssey"
    ]

    /// Whether this preset belongs to the "Jumping Off" (static starting point)
    /// collection. Custom embedded-formula presets are excluded.
    var isJumpingOffPreset: Bool {
        guard !isCustomScenePreset else { return false }
        let normalizedName = name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if FractalPreset.jumpingOffNameOverrides.contains(normalizedName) {
            return true
        }
        return !hasMusicReactiveMappings
    }

    /// Whether this preset should participate in desktop left/right scene
    /// switching. Includes both Jumping Off and Music Reactive presets, while
    /// excluding custom embedded-formula scenes.
    var isKeyboardSwitchableStaticPreset: Bool {
        !isCustomScenePreset
    }
}
