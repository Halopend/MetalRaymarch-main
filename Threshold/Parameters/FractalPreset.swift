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

#if os(visionOS) || os(iOS)
typealias PlatformImage = UIImage
#elseif os(macOS)
typealias PlatformImage = NSImage
#endif

// MARK: - Canonical scene state

/// Describes why a state snapshot is being restored. A shared scene is allowed
/// to opt into comfort features, but it must not turn off a user's safety bubble.
/// Session/preview restoration, on the other hand, must reproduce the captured
/// state exactly so cancel and relaunch are lossless.
enum SceneRestoreScope: Sendable {
    case scene
    case session
}

/// Scene-owned quality and containment. Device/hardware tuning (foveation,
/// temporal reprojection, cone-march strength, adaptive resolution, etc.) is
/// intentionally absent: those settings belong to the destination device.
struct SceneQualityState: Codable, Equatable {
    var baseFractalIterations: Int = 9
    var baseMaxRaySteps: Int = 64
    var resolutionScale: Float?
    var tileSize: Int?
    var coneMarchCompatible: Bool = true
    var recommendedQuality: SceneQualityTarget?
    var shadowsEnabled: Bool = true
    var boundingShapeEnabled: Bool = false
    var boundingShapeRadius: Float = 6.0
    var boundingShapeFogMode: Int = 0
    var boundingShapeShadowDepth: Float = 0.35
    var boundingShapeType: Float = 0.0
    var boundToSpaceEnabled: Bool = false
    var boundToSpaceMode: Int = 0
    var boundSpaceWidth: Float = 4.0
    var boundSpaceDepth: Float = 4.0
    var boundSpaceHeight: Float = 2.5
    var boundAmbientStrength: Float = 0.5
    var envScrunchEnabled: Bool = false
    var envScrunchMode: Int = 0
    var envScrunchStrength: Float = 0.8
    var envScrunchReach: Float = 0.75
    var envScrunchContain: Int = 0
    var envScrunchContainFeather: Float = 0.1
    var zoomFogCompensationEnabled: Bool = false

    init() {}

    init(_ config: QualityConfig,
         coneMarchCompatible: Bool,
         recommendedQuality: SceneQualityTarget?) {
        baseFractalIterations = config.baseFractalIterations
        baseMaxRaySteps = config.baseMaxRaySteps
        resolutionScale = config.resolutionScale
        tileSize = config.tileSize
        self.coneMarchCompatible = coneMarchCompatible
        self.recommendedQuality = recommendedQuality
        shadowsEnabled = config.shadowsEnabled
        boundingShapeEnabled = config.boundingSphereSkipEnabled
        boundingShapeRadius = config.boundingShapeRadius
        boundingShapeFogMode = config.boundingShapeFogMode
        boundingShapeShadowDepth = config.boundingShapeShadowDepth
        boundingShapeType = config.boundingShapeType
        boundToSpaceEnabled = config.boundToSpaceEnabled
        boundToSpaceMode = config.boundToSpaceMode
        boundSpaceWidth = config.boundSpaceWidth
        boundSpaceDepth = config.boundSpaceDepth
        boundSpaceHeight = config.boundSpaceHeight
        boundAmbientStrength = config.boundAmbientStrength
        envScrunchEnabled = config.envScrunchEnabled
        envScrunchMode = config.envScrunchMode
        envScrunchStrength = config.envScrunchStrength
        envScrunchReach = config.envScrunchReach
        envScrunchContain = config.envScrunchContain
        envScrunchContainFeather = config.envScrunchContainFeather
        zoomFogCompensationEnabled = config.zoomFogCompensationEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case baseFractalIterations, baseMaxRaySteps, resolutionScale, tileSize
        case coneMarchCompatible, recommendedQuality, shadowsEnabled
        case boundingShapeEnabled, boundingShapeRadius, boundingShapeFogMode
        case boundingShapeShadowDepth, boundingShapeType
        case boundToSpaceEnabled, boundToSpaceMode, boundSpaceWidth, boundSpaceDepth, boundSpaceHeight
        case boundAmbientStrength
        case envScrunchEnabled, envScrunchMode, envScrunchStrength, envScrunchReach
        case envScrunchContain, envScrunchContainFeather
        case zoomFogCompensationEnabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        baseFractalIterations = try c.decodeIfPresent(Int.self, forKey: .baseFractalIterations) ?? 9
        baseMaxRaySteps = try c.decodeIfPresent(Int.self, forKey: .baseMaxRaySteps) ?? 64
        resolutionScale = try c.decodeIfPresent(Float.self, forKey: .resolutionScale)
        tileSize = try c.decodeIfPresent(Int.self, forKey: .tileSize)
        coneMarchCompatible = try c.decodeIfPresent(Bool.self, forKey: .coneMarchCompatible) ?? true
        recommendedQuality = try c.decodeIfPresent(SceneQualityTarget.self, forKey: .recommendedQuality)
        shadowsEnabled = try c.decodeIfPresent(Bool.self, forKey: .shadowsEnabled) ?? true
        boundingShapeEnabled = try c.decodeIfPresent(Bool.self, forKey: .boundingShapeEnabled) ?? false
        boundingShapeRadius = try c.decodeIfPresent(Float.self, forKey: .boundingShapeRadius) ?? 6.0
        boundingShapeFogMode = try c.decodeIfPresent(Int.self, forKey: .boundingShapeFogMode) ?? 0
        boundingShapeShadowDepth = try c.decodeIfPresent(Float.self, forKey: .boundingShapeShadowDepth) ?? 0.35
        boundingShapeType = try c.decodeIfPresent(Float.self, forKey: .boundingShapeType) ?? 0.0
        boundToSpaceEnabled = try c.decodeIfPresent(Bool.self, forKey: .boundToSpaceEnabled) ?? false
        boundToSpaceMode = try c.decodeIfPresent(Int.self, forKey: .boundToSpaceMode) ?? 0
        boundSpaceWidth = try c.decodeIfPresent(Float.self, forKey: .boundSpaceWidth) ?? 4.0
        boundSpaceDepth = try c.decodeIfPresent(Float.self, forKey: .boundSpaceDepth) ?? 4.0
        boundSpaceHeight = try c.decodeIfPresent(Float.self, forKey: .boundSpaceHeight) ?? 2.5
        boundAmbientStrength = try c.decodeIfPresent(Float.self, forKey: .boundAmbientStrength) ?? 0.5
        envScrunchEnabled = try c.decodeIfPresent(Bool.self, forKey: .envScrunchEnabled) ?? false
        envScrunchMode = try c.decodeIfPresent(Int.self, forKey: .envScrunchMode) ?? 0
        envScrunchStrength = try c.decodeIfPresent(Float.self, forKey: .envScrunchStrength) ?? 0.8
        envScrunchReach = try c.decodeIfPresent(Float.self, forKey: .envScrunchReach) ?? 0.75
        envScrunchContain = try c.decodeIfPresent(Int.self, forKey: .envScrunchContain) ?? 0
        envScrunchContainFeather = try c.decodeIfPresent(Float.self, forKey: .envScrunchContainFeather) ?? 0.1
        zoomFogCompensationEnabled = try c.decodeIfPresent(Bool.self, forKey: .zoomFogCompensationEnabled) ?? false
    }
}

/// Scene-authored display state. `showMusicShortcuts` is deliberately not here;
/// it is application chrome, not part of a rendered scene.
struct SceneDisplayState: Codable, Equatable {
    var lightingPlay: Bool = false
    var lightingMode: LightingMode = .animated
    var sphericalInversionMode: SphericalInversionMode = .off
    var sphericalInversionRadius: Float = 2.0
    var sphereProjectionEnabled: Bool = false
    var sphereProjectionBlend: Float = 1.0
    var sphereProjectionRadius: Float = 1.0
    var deIterationMismatch: Float = ControlCatalog.deIterationMismatch.defaultValue
    var platformRadius: Float = ControlCatalog.platformRadius.defaultValue
    var platformEnabled: Bool = true

    init() {}

    init(_ config: DisplayConfig) {
        lightingPlay = config.lightingPlay
        lightingMode = config.lightingMode
        sphericalInversionMode = config.sphericalInversionMode
        sphericalInversionRadius = config.sphericalInversionRadius
        sphereProjectionEnabled = config.sphereProjectionEnabled
        sphereProjectionBlend = config.sphereProjectionBlend
        sphereProjectionRadius = config.sphereProjectionRadius
        deIterationMismatch = config.deIterationMismatch
        platformRadius = config.platformRadius
        platformEnabled = config.platformEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case lightingPlay, lightingMode, sphericalInversionMode, sphericalInversionRadius
        case sphereProjectionEnabled, sphereProjectionBlend, sphereProjectionRadius
        case deIterationMismatch, platformRadius, platformEnabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lightingPlay = try c.decodeIfPresent(Bool.self, forKey: .lightingPlay) ?? false
        lightingMode = try c.decodeIfPresent(LightingMode.self, forKey: .lightingMode) ?? .animated
        sphericalInversionMode = try c.decodeIfPresent(SphericalInversionMode.self, forKey: .sphericalInversionMode) ?? .off
        sphericalInversionRadius = try c.decodeIfPresent(Float.self, forKey: .sphericalInversionRadius) ?? 2.0
        sphereProjectionEnabled = try c.decodeIfPresent(Bool.self, forKey: .sphereProjectionEnabled) ?? false
        sphereProjectionBlend = try c.decodeIfPresent(Float.self, forKey: .sphereProjectionBlend) ?? 1.0
        sphereProjectionRadius = try c.decodeIfPresent(Float.self, forKey: .sphereProjectionRadius) ?? 1.0
        deIterationMismatch = try c.decodeIfPresent(Float.self, forKey: .deIterationMismatch)
            ?? ControlCatalog.deIterationMismatch.defaultValue
        platformRadius = try c.decodeIfPresent(Float.self, forKey: .platformRadius)
            ?? ControlCatalog.platformRadius.defaultValue
        platformEnabled = try c.decodeIfPresent(Bool.self, forKey: .platformEnabled) ?? true
    }
}

/// Both the legacy/custom single warp and the composable transform stack. The
/// former was previously live-only and therefore disappeared on save/reset.
struct SceneSpaceState: Codable, Equatable {
    var warpStrength: Float = 0.0
    var warpOrigin: SIMD3<Float> = .zero
    var warpAxis: SIMD3<Float> = SIMD3<Float>(0, 1, 0)
    var warpStack: [SpaceWarpOpValue] = []
}

struct SceneMotionState: Codable, Equatable {
    var infiniteZoomEnabled: Bool = false
    var infiniteZoomRate: Float = 0.15
}

/// Presentation intent is kept as a stable string instead of coupling the file
/// format to AppModel. It preserves all three modes; the old `mixedModeScene`
/// Boolean could not distinguish Window from Immersive.
struct ScenePresentationState: Codable, Equatable {
    var immersionStyle: String?
}

/// Versioned, domain-shaped source of truth for scene capture/restore. The old
/// flat FractalPreset fields remain encoded for older app builds and are applied
/// after this envelope as compatibility overrides.
struct SceneState: Codable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int = currentSchemaVersion
    var geometry: GeometryConfig = GeometryConfig()
    var color: ColorConfig = ColorConfig()
    var lighting: LightingConfig = LightingConfig()
    var quality: SceneQualityState = SceneQualityState()
    var display: SceneDisplayState = SceneDisplayState()
    var safetyBubble: SafetyBubbleConfig = SafetyBubbleConfig()
    var handAttraction: HandAttractionConfig = HandAttractionConfig()
    var audioReactive: AudioReactiveConfig = AudioReactiveConfig()
    var space: SceneSpaceState = SceneSpaceState()
    var motion: SceneMotionState = SceneMotionState()
    var presentation: ScenePresentationState = ScenePresentationState()

    init() {}

    init(capturing settings: RenderSettings, immersionStyle: String? = nil) {
        geometry = settings.geometryConfig
        color = settings.colorConfig
        lighting = settings.lightingConfig
        quality = SceneQualityState(
            settings.qualityConfig,
            coneMarchCompatible: settings.sceneConeMarchCompatible,
            recommendedQuality: settings.recommendedQuality
        )
        display = SceneDisplayState(settings.displayConfig)
        safetyBubble = settings.safetyBubbleConfig
        handAttraction = settings.handAttractionConfig
        audioReactive = settings.audioReactiveConfig
        space = SceneSpaceState(
            warpStrength: settings.spaceWarpStrength,
            warpOrigin: settings.spaceWarpOrigin,
            warpAxis: settings.spaceWarpAxis,
            warpStack: settings.spaceWarpStack
        )
        motion = SceneMotionState(
            infiniteZoomEnabled: settings.infiniteZoomEnabled,
            infiniteZoomRate: settings.infiniteZoomRate
        )
        presentation = ScenePresentationState(immersionStyle: immersionStyle)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, geometry, color, lighting, quality, display
        case safetyBubble, handAttraction, audioReactive, space, motion, presentation
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        geometry = (try? c.decodeIfPresent(GeometryConfig.self, forKey: .geometry)) ?? GeometryConfig()
        color = (try? c.decodeIfPresent(ColorConfig.self, forKey: .color)) ?? ColorConfig()
        lighting = (try? c.decodeIfPresent(LightingConfig.self, forKey: .lighting)) ?? LightingConfig()
        quality = (try? c.decodeIfPresent(SceneQualityState.self, forKey: .quality)) ?? SceneQualityState()
        display = (try? c.decodeIfPresent(SceneDisplayState.self, forKey: .display)) ?? SceneDisplayState()
        safetyBubble = (try? c.decodeIfPresent(SafetyBubbleConfig.self, forKey: .safetyBubble)) ?? SafetyBubbleConfig()
        handAttraction = (try? c.decodeIfPresent(HandAttractionConfig.self, forKey: .handAttraction)) ?? HandAttractionConfig()
        audioReactive = (try? c.decodeIfPresent(AudioReactiveConfig.self, forKey: .audioReactive)) ?? AudioReactiveConfig()
        space = (try? c.decodeIfPresent(SceneSpaceState.self, forKey: .space)) ?? SceneSpaceState()
        // Heal repeat groups split by an interloper op — scene files are external
        // input, and everything downstream (the Transformations editor above all)
        // assumes one groupID names one contiguous run.
        space.warpStack = space.warpStack.normalizingGroupContiguity()
        motion = (try? c.decodeIfPresent(SceneMotionState.self, forKey: .motion)) ?? SceneMotionState()
        presentation = (try? c.decodeIfPresent(ScenePresentationState.self, forKey: .presentation)) ?? ScenePresentationState()
    }

    /// Apply only scene-owned lanes, merging them over the destination device's
    /// acceleration preferences. Domain config setters are non-persisting, which
    /// also makes this safe for animation playback and external preview.
    func apply(to settings: RenderSettings,
               includePerformance: Bool,
               scope: SceneRestoreScope) {
        settings.geometryConfig = geometry
        settings.targetMinDistance = geometry.minDistance
        settings.targetFoldingLimit = geometry.foldingLimit
        settings.targetSphereRadius = geometry.sphereRadius
        settings.targetFractalScale = geometry.fractalScale
        settings.targetPosition = geometry.position
        settings.targetWorldRotation = geometry.worldRotation
        settings.targetDetailScale = geometry.detailScale

        var mergedQuality = settings.qualityConfig
        mergedQuality.baseFractalIterations = quality.baseFractalIterations
        mergedQuality.baseMaxRaySteps = quality.baseMaxRaySteps
        if includePerformance {
            if let resolutionScale = quality.resolutionScale {
                mergedQuality.resolutionScale = resolutionScale
            }
            if let tileSize = quality.tileSize {
                mergedQuality.tileSize = tileSize
            }
        }
        mergedQuality.shadowsEnabled = quality.shadowsEnabled
        mergedQuality.boundingSphereSkipEnabled = quality.boundingShapeEnabled
        mergedQuality.boundingShapeRadius = quality.boundingShapeRadius
        mergedQuality.boundingShapeFogMode = quality.boundingShapeFogMode
        mergedQuality.boundingShapeShadowDepth = quality.boundingShapeShadowDepth
        mergedQuality.boundingShapeType = quality.boundingShapeType
        // Bound to Space is scene-authored containment, just like the shape
        // bound. Preserve its enable bit as well as its dimensions.
        mergedQuality.boundToSpaceEnabled = quality.boundToSpaceEnabled
        mergedQuality.boundToSpaceMode = quality.boundToSpaceMode
        mergedQuality.boundSpaceWidth = quality.boundSpaceWidth
        mergedQuality.boundSpaceDepth = quality.boundSpaceDepth
        mergedQuality.boundSpaceHeight = quality.boundSpaceHeight
        mergedQuality.boundAmbientStrength = quality.boundAmbientStrength
        mergedQuality.envScrunchEnabled = quality.envScrunchEnabled
        mergedQuality.envScrunchMode = quality.envScrunchMode
        mergedQuality.envScrunchStrength = quality.envScrunchStrength
        mergedQuality.envScrunchReach = quality.envScrunchReach
        mergedQuality.envScrunchContain = quality.envScrunchContain
        mergedQuality.envScrunchContainFeather = quality.envScrunchContainFeather
        mergedQuality.zoomFogCompensationEnabled = quality.zoomFogCompensationEnabled
        settings.qualityConfig = mergedQuality
        settings.sceneConeMarchCompatible = quality.coneMarchCompatible
        settings.applyRecommendedQuality(quality.recommendedQuality)

        settings.colorConfig = color
        settings.lightingConfig = lighting

        var mergedDisplay = settings.displayConfig
        mergedDisplay.lightingPlay = display.lightingPlay
        mergedDisplay.lightingMode = display.lightingMode
        mergedDisplay.sphericalInversionMode = display.sphericalInversionMode
        mergedDisplay.sphericalInversionRadius = display.sphericalInversionRadius
        mergedDisplay.sphereProjectionEnabled = display.sphereProjectionEnabled
        mergedDisplay.sphereProjectionBlend = display.sphereProjectionBlend
        mergedDisplay.sphereProjectionRadius = display.sphereProjectionRadius
        mergedDisplay.deIterationMismatch = display.deIterationMismatch
        mergedDisplay.platformRadius = display.platformRadius
        mergedDisplay.platformEnabled = display.platformEnabled
        settings.displayConfig = mergedDisplay

        if scope == .session || safetyBubble.enabled {
            settings.safetyBubbleConfig = safetyBubble
        }
        settings.handAttractionConfig = handAttraction
        settings.audioReactiveConfig = audioReactive

        settings.spaceWarpStrength = space.warpStrength
        settings.spaceWarpOrigin = space.warpOrigin
        settings.spaceWarpAxis = space.warpAxis
        settings.spaceWarpStack = space.warpStack
        settings.infiniteZoomEnabled = motion.infiniteZoomEnabled
        settings.infiniteZoomRate = motion.infiniteZoomRate
    }
}

/// Represents a saved preset with all render settings and a preview image
struct FractalPreset: Codable, Identifiable {
    static let currentSchemaVersion = 3

    let id: UUID
    var name: String
    var createdAt: Date
    /// Last time this preset's content was created or modified. Drives newest-wins
    /// conflict resolution in the iCloud merge. Decodes to `createdAt` for presets
    /// saved before this field existed (backward-compatible).
    var updatedAt: Date
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

    // === PER-SCENE PERFORMANCE PROFILE ===
    // Author HINTS about how this scene renders best. Both optional/backward-
    // compatible: older files decode to nil and apply() falls back to the safe
    // default (compatible / no quality opinion). Unlike the rest of the Quality
    // domain these DO travel with the scene, because they only ever gate or REQUEST
    // MORE quality — never force a device-local perf technique on (see
    // RenderSettings.applyRecommendedQuality / the cone-march snapshot gate).
    //   coneMarchCompatible: nil/true = the device's Cone Marching setting applies
    //     as usual; false suppresses cone marching for this scene (scenes where it
    //     inflates silhouettes badly). Never turns cone marching ON.
    var coneMarchCompatible: Bool?
    //   recommendedQuality: the render RESOLUTION tier to aim for. high/ultra raise
    //     resolutionScale (Mac) / renderQuality (visionOS) toward the target and lift
    //     the adaptive governor's floor so the scene resists downscaling.
    var recommendedQuality: SceneQualityTarget?
    
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

    // Hand Attraction (visionOS): whole domain config saved as one blob —
    // its own Codable is tolerant, so new fields never break old scenes.
    var handAttraction: HandAttractionConfig?

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
    // Legacy DE iteration mismatch ("Accidental Sphere Projection" look); nil/0 = off.
    var deIterationMismatch: Float?
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
    var edgeDetectionEffect: EdgeDetectionEffect?
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
    /// Canonical domain-shaped scene snapshot. Flat fields remain alongside it
    /// for older builds and externally-authored v1/v2 scenes.
    var sceneState: SceneState?
    /// Decode-only/apply routing for a valid schema-3 document that contains the
    /// canonical envelope but omits the legacy compatibility projection. Current
    /// writers normally dual-write; retaining this marker makes a decode/encode
    /// cycle keep canonical-only semantics instead of inventing default overrides.
    private var appliesLegacyFlatFields: Bool = true

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
    var boundingShapeType: Float?         // Bounding Shape family/preset (sphere/cube/platonic), same encoding as safetyBubbleShape
    var boundToSpaceEnabled: Bool?        // Bound to Space (assumed-room clip) on/off
    var boundToSpaceMode: Int?            // 0 = Match Space, 1 = Ceiling Open, 2 = Walls Open
    var boundSpaceWidth: Float?           // assumed room width (world x), meters
    var boundSpaceDepth: Float?           // assumed room depth (world z), meters
    var boundSpaceHeight: Float?          // assumed room height (world y), meters
    var boundAmbientStrength: Float?      // room-derived ambient occlusion, 0 = off
    // Environment Scrunch — scene-authored artistic parameters (mode/strength/
    // reach/contain). The room SCAN itself is always live/device-local and never
    // saved; only how the fractal scrunches travels with the scene. (Reverses the
    // earlier envScrunchStaysDeviceLocal decision — TECH_DEBT #14 — so a bounded
    // scene can carry its scrunch look.)
    var envScrunchEnabled: Bool?          // Scrunch to Surroundings on/off
    var envScrunchMode: Int?              // 0 = Scrunch (bulge), 1 = Shell
    var envScrunchStrength: Float?        // 0…1 blend toward the scrunched field
    var envScrunchReach: Float?           // engage band / shell thickness, meters
    var envScrunchContain: Int?           // 0 = off, 1 = hard clip, 2 = soft blend
    var envScrunchContainFeather: Float?  // soft-blend feather half-width, meters
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
        case id, name, createdAt, updatedAt, thumbnailData, rating
        case fractalIterations, maxRaySteps, colorMix, colorIterations, position, scale
        case fractalType, colorScheme, colorSchemeSaturation, colorSchemeContrast, colorSchemeGamma
        case colorSchemeVibrance, colorSchemeCurve, colorSchemeShadows, colorSchemeHighlights
        case minDistance, fractalScale, foldingLimit, sphereRadius, formulaParamValues
        case worldRotationX, worldRotationY, worldRotationZ, worldRotationW, detailScale
        case resolutionScale, tileSize, safetyBubbleEnabled, safetyBubbleRadius, safetyBubbleShape, safetyBubbleBlend
        case coneMarchCompatible, recommendedQuality  // per-scene performance profile
        // Space module (domain transforms)
        case sphericalInversionMode, sphericalInversionRadius
        case sphereProjectionEnabled, sphereProjectionBlend, sphereProjectionRadius
        case deIterationMismatch
        case spaceWarpOps
        // v2.0 modular lighting effects
        case lightingMode, lightingPreset, hueRotationEffect, pulseEffect, glowEffect, bloomEffect, edgeDetectionEffect, fogEffect, gradientCycleEffect, linearRailEffect
        // Color scheme auto-transition
        case colorSchemeAutoTransition, colorSchemeAutoInterval, colorSchemeTransitionDuration
        // v2.1 gradient coloring system
        case gradientState, lightingSoftness
        case musicReactiveMappings  // legacy — mappings only
        case audioReactiveConfig    // canonical — full config
        case embeddedFormula        // optional self-contained DE shader payload
        case schemaVersion, modules, sceneState, canonicalStateOnly // canonical state + legacy module layer
        // Additional scene state (previously dropped on save)
        case platformEnabled, platformRadius
        case mixedModeScene, boundingShapeEnabled, boundingShapeRadius, boundingShapeFogEnabled
        case boundingShapeFogMode, boundingShapeShadowDepth, boundingShapeType
        case boundToSpaceEnabled, boundToSpaceMode, boundSpaceWidth, boundSpaceDepth, boundSpaceHeight
        case boundAmbientStrength
        case envScrunchEnabled, envScrunchMode, envScrunchStrength, envScrunchReach
        case envScrunchContain, envScrunchContainFeather
        case cellShadingEnabled, cellShadingLevels, aoStrength, tonemapStrength
        case lightVariationRate, beatFlashEffect, polarRotationEffect, juliaDriftEffect
        case safetyBubbleFadeEnabled, safetyBubbleFadeWidth
        case handAttraction
    }
    
    init(id: UUID = UUID(), name: String, createdAt: Date = Date(), updatedAt: Date? = nil, thumbnailData: Data? = nil) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
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
        var decodedSceneState = try container.decodeIfPresent(SceneState.self, forKey: .sceneState)
        let explicitlyCanonicalOnly = try container.decodeIfPresent(Bool.self, forKey: .canonicalStateOnly) ?? false
        let hasLegacyCore = container.contains(.fractalIterations)
            && container.contains(.maxRaySteps)
            && container.contains(.colorMix)
            && container.contains(.colorIterations)
            && container.contains(.position)
            && container.contains(.scale)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        thumbnailData = try container.decodeIfPresent(Data.self, forKey: .thumbnailData)
        rating = try container.decodeIfPresent(Int.self, forKey: .rating) ?? 0
        fractalIterations = try container.decodeIfPresent(Int.self, forKey: .fractalIterations)
            ?? decodedSceneState?.quality.baseFractalIterations ?? 9
        maxRaySteps = try container.decodeIfPresent(Int.self, forKey: .maxRaySteps)
            ?? decodedSceneState?.quality.baseMaxRaySteps ?? 64
        colorMix = try container.decodeIfPresent(Float.self, forKey: .colorMix)
            ?? decodedSceneState?.color.colorMix ?? 0.5
        colorIterations = try container.decodeIfPresent(Float.self, forKey: .colorIterations)
            ?? decodedSceneState?.color.colorIterations ?? 8.0
        position = try container.decodeIfPresent(SIMD3<Float>.self, forKey: .position)
            ?? decodedSceneState?.geometry.position ?? .zero
        scale = try container.decodeIfPresent(Float.self, forKey: .scale)
            ?? decodedSceneState?.geometry.scale ?? 1.0
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
        fractalType = try container.decodeIfPresent(FractalModelType.self, forKey: .fractalType)
            ?? decodedSceneState?.geometry.fractalType ?? .mandelbox
        colorScheme = try container.decodeIfPresent(ColorScheme.self, forKey: .colorScheme)
            ?? decodedSceneState?.color.colorScheme ?? .classic
        colorSchemeSaturation = try container.decodeIfPresent(Float.self, forKey: .colorSchemeSaturation)
            ?? decodedSceneState?.color.colorSchemeSaturation ?? 1.7
        colorSchemeContrast = try container.decodeIfPresent(Float.self, forKey: .colorSchemeContrast)
            ?? decodedSceneState?.color.colorSchemeContrast ?? 1.08
        colorSchemeGamma = try container.decodeIfPresent(Float.self, forKey: .colorSchemeGamma)
            ?? decodedSceneState?.color.colorSchemeGamma ?? 0.85
        colorSchemeVibrance = try container.decodeIfPresent(Float.self, forKey: .colorSchemeVibrance)
            ?? decodedSceneState?.color.colorSchemeVibrance ?? 0.8
        colorSchemeCurve = try container.decodeIfPresent(Float.self, forKey: .colorSchemeCurve)
            ?? decodedSceneState?.color.colorSchemeCurve ?? 0.0
        colorSchemeShadows = try container.decodeIfPresent(Float.self, forKey: .colorSchemeShadows)
            ?? decodedSceneState?.color.colorSchemeShadows ?? -0.018
        colorSchemeHighlights = try container.decodeIfPresent(Float.self, forKey: .colorSchemeHighlights)
            ?? decodedSceneState?.color.colorSchemeHighlights ?? 0.02
        minDistance = try container.decodeIfPresent(Float.self, forKey: .minDistance)
            ?? decodedSceneState?.geometry.minDistance ?? 0.8
        fractalScale = try container.decodeIfPresent(Float.self, forKey: .fractalScale)
            ?? decodedSceneState?.geometry.fractalScale ?? 2.8
        foldingLimit = try container.decodeIfPresent(Float.self, forKey: .foldingLimit)
            ?? decodedSceneState?.geometry.foldingLimit ?? 1.0
        sphereRadius = try container.decodeIfPresent(Float.self, forKey: .sphereRadius)
            ?? decodedSceneState?.geometry.sphereRadius ?? 0.5
        formulaParamValues = try container.decodeIfPresent([Float].self, forKey: .formulaParamValues)
            ?? decodedSceneState.map { state in
                (0..<16).map { FormulaCatalog.getParam(state.geometry.formulaParams, index: $0) }
            }
        resolutionScale = try container.decodeIfPresent(Float.self, forKey: .resolutionScale)
        let decodedTileSize = try container.decodeIfPresent(Int.self, forKey: .tileSize)
        tileSize = decodedTileSize == 2 ? nil : decodedTileSize  // Old "Quad Shared" mode removed → degrade to fragment
        coneMarchCompatible = try container.decodeIfPresent(Bool.self, forKey: .coneMarchCompatible)
        recommendedQuality = try container.decodeIfPresent(SceneQualityTarget.self, forKey: .recommendedQuality)
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
        deIterationMismatch = try container.decodeIfPresent(Float.self, forKey: .deIterationMismatch)
        // Heal repeat groups split by an interloper op — external files can't be
        // trusted to keep one groupID contiguous (see `normalizingGroupContiguity`).
        spaceWarpOps = try container.decodeIfPresent([SpaceWarpOpValue].self, forKey: .spaceWarpOps)?
            .normalizingGroupContiguity()

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
        edgeDetectionEffect = try container.decodeIfPresent(EdgeDetectionEffect.self, forKey: .edgeDetectionEffect)
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
            if let primitive = formula.bundledConstructionPrimitiveKind {
                // Migrate scenes saved by the first runtime-compiled primitive
                // implementation. Both the legacy flat lane and canonical v3
                // geometry may say `.custom`; rewrite both to the static type
                // and its new selector/size parameter layout.
                let params = primitive.bundledFormulaParams
                fractalType = .constructionPrimitive
                formulaParamValues = (0..<16).map {
                    FormulaCatalog.getParam(params, index: $0)
                }
                decodedSceneState?.geometry.fractalType = .constructionPrimitive
                decodedSceneState?.geometry.formulaParams = params
            } else if formula.effectKind == .fractal {
                fractalType = .custom
            }
            embeddedFormula = formula
        } else {
            embeddedFormula = nil
        }

        // Module layer (typed/keyed params). Optional — older scenes have none.
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
        modules = try container.decodeIfPresent([String: ModuleParamBlock].self, forKey: .modules)
        sceneState = decodedSceneState
        appliesLegacyFlatFields = !explicitlyCanonicalOnly && (decodedSceneState == nil || hasLegacyCore)

        // Additional scene state (previously dropped) — all optional/backward-compatible.
        platformEnabled = try container.decodeIfPresent(Bool.self, forKey: .platformEnabled)
        mixedModeScene = try container.decodeIfPresent(Bool.self, forKey: .mixedModeScene)
        boundingShapeEnabled = try container.decodeIfPresent(Bool.self, forKey: .boundingShapeEnabled)
        boundingShapeRadius = try container.decodeIfPresent(Float.self, forKey: .boundingShapeRadius)
        boundingShapeFogEnabled = try container.decodeIfPresent(Bool.self, forKey: .boundingShapeFogEnabled)
        boundingShapeFogMode = try container.decodeIfPresent(Int.self, forKey: .boundingShapeFogMode)
        boundingShapeShadowDepth = try container.decodeIfPresent(Float.self, forKey: .boundingShapeShadowDepth)
        boundingShapeType = try container.decodeIfPresent(Float.self, forKey: .boundingShapeType)
        boundToSpaceEnabled = try container.decodeIfPresent(Bool.self, forKey: .boundToSpaceEnabled)
        boundToSpaceMode = try container.decodeIfPresent(Int.self, forKey: .boundToSpaceMode)
        boundSpaceWidth = try container.decodeIfPresent(Float.self, forKey: .boundSpaceWidth)
        boundSpaceDepth = try container.decodeIfPresent(Float.self, forKey: .boundSpaceDepth)
        boundSpaceHeight = try container.decodeIfPresent(Float.self, forKey: .boundSpaceHeight)
        boundAmbientStrength = try container.decodeIfPresent(Float.self, forKey: .boundAmbientStrength)
        envScrunchEnabled = try container.decodeIfPresent(Bool.self, forKey: .envScrunchEnabled)
        envScrunchMode = try container.decodeIfPresent(Int.self, forKey: .envScrunchMode)
        envScrunchStrength = try container.decodeIfPresent(Float.self, forKey: .envScrunchStrength)
        envScrunchReach = try container.decodeIfPresent(Float.self, forKey: .envScrunchReach)
        envScrunchContain = try container.decodeIfPresent(Int.self, forKey: .envScrunchContain)
        envScrunchContainFeather = try container.decodeIfPresent(Float.self, forKey: .envScrunchContainFeather)
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
        handAttraction = try container.decodeIfPresent(HandAttractionConfig.self, forKey: .handAttraction)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
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
        try container.encodeIfPresent(coneMarchCompatible, forKey: .coneMarchCompatible)
        try container.encodeIfPresent(recommendedQuality, forKey: .recommendedQuality)
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
        try container.encodeIfPresent(deIterationMismatch, forKey: .deIterationMismatch)
        try container.encodeIfPresent(spaceWarpOps, forKey: .spaceWarpOps)

        // v2.0 modular lighting effects
        try container.encodeIfPresent(lightingMode, forKey: .lightingMode)
        try container.encodeIfPresent(lightingPreset, forKey: .lightingPreset)
        try container.encodeIfPresent(hueRotationEffect, forKey: .hueRotationEffect)
        try container.encodeIfPresent(pulseEffect, forKey: .pulseEffect)
        try container.encodeIfPresent(glowEffect, forKey: .glowEffect)
        try container.encodeIfPresent(bloomEffect, forKey: .bloomEffect)
        try container.encodeIfPresent(edgeDetectionEffect, forKey: .edgeDetectionEffect)
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
        try container.encodeIfPresent(sceneState, forKey: .sceneState)
        if !appliesLegacyFlatFields {
            try container.encode(true, forKey: .canonicalStateOnly)
        }

        // Additional scene state (previously dropped on save)
        try container.encodeIfPresent(platformEnabled, forKey: .platformEnabled)
        try container.encodeIfPresent(mixedModeScene, forKey: .mixedModeScene)
        try container.encodeIfPresent(boundingShapeEnabled, forKey: .boundingShapeEnabled)
        try container.encodeIfPresent(boundingShapeRadius, forKey: .boundingShapeRadius)
        try container.encodeIfPresent(boundingShapeFogMode, forKey: .boundingShapeFogMode)
        try container.encodeIfPresent(boundingShapeShadowDepth, forKey: .boundingShapeShadowDepth)
        try container.encodeIfPresent(boundingShapeType, forKey: .boundingShapeType)
        try container.encodeIfPresent(boundToSpaceEnabled, forKey: .boundToSpaceEnabled)
        try container.encodeIfPresent(boundToSpaceMode, forKey: .boundToSpaceMode)
        try container.encodeIfPresent(boundSpaceWidth, forKey: .boundSpaceWidth)
        try container.encodeIfPresent(boundSpaceDepth, forKey: .boundSpaceDepth)
        try container.encodeIfPresent(boundSpaceHeight, forKey: .boundSpaceHeight)
        try container.encodeIfPresent(boundAmbientStrength, forKey: .boundAmbientStrength)
        try container.encodeIfPresent(envScrunchEnabled, forKey: .envScrunchEnabled)
        try container.encodeIfPresent(envScrunchMode, forKey: .envScrunchMode)
        try container.encodeIfPresent(envScrunchStrength, forKey: .envScrunchStrength)
        try container.encodeIfPresent(envScrunchReach, forKey: .envScrunchReach)
        try container.encodeIfPresent(envScrunchContain, forKey: .envScrunchContain)
        try container.encodeIfPresent(envScrunchContainFeather, forKey: .envScrunchContainFeather)
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
        try container.encodeIfPresent(handAttraction, forKey: .handAttraction)
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
            return FormulaCatalog.specializedMandelbulbPower(rawPower: rawPower)
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
        // Presets prewarm the DE-tail-OFF variant on macOS (env-scrunch device
        // toggle off, hand field absent). nil on other platforms → empty segment,
        // matching selectPipeline's non-Mac key.
        let deTailKey = Self.deTailCacheKey(hasEnvScrunch: prewarmEnvScrunch,
                                            hasHandField: prewarmHandField)
        let sceneKey = "_B\(effectiveSafetyBubbleEnabled ? 1 : 0)_SW\(effectiveHasSpaceWarp ? 1 : 0)\(deTailKey)"
        return "FT\(fractalType.rawValue)_FI\(fc.fractalIterations)_RS\(fc.maxRaySteps)\(sceneKey)_N\(fc.neonModeEnabled ? 1 : 0)_Q\(fc.qualityMode)_CI\(fc.colorIterations)\(powerKey)"
    }

    /// The DE-tail cache-key segment (`_ES{0,1}_HF{0,1}`), shared by
    /// `selectPipeline` and `pipelineCacheKey` so prewarm and live lookup agree.
    /// A `nil` axis contributes nothing — on non-macOS both are nil, so the
    /// segment is empty and keys stay byte-identical to before this feature.
    static func deTailCacheKey(hasEnvScrunch: Bool?, hasHandField: Bool?) -> String {
        var key = ""
        if let es = hasEnvScrunch { key += "_ES\(es ? 1 : 0)" }
        if let hf = hasHandField { key += "_HF\(hf ? 1 : 0)" }
        return key
    }

    /// What the prewarm bakes for the DE-tail constants (see
    /// `FunctionConstantConfig.fromPreset`): macOS prewarms both OFF; other
    /// platforms leave them undefined (nil → empty key segment).
    private var prewarmEnvScrunch: Bool? {
        #if os(macOS)
        return false
        #else
        return nil
        #endif
    }
    private var prewarmHandField: Bool? {
        #if os(macOS)
        return false
        #else
        return nil
        #endif
    }
    
    /// Create a preset from current render settings
    static func fromSettings(_ settings: RenderSettings, name: String, id: UUID = UUID(), createdAt: Date = Date(), thumbnailData: Data? = nil, embeddedFormula: EmbeddedFormula? = nil) -> FractalPreset {
        var preset = FractalPreset(id: id, name: name, createdAt: createdAt, thumbnailData: thumbnailData)
        var immersionStyle: String?
        #if os(visionOS)
        immersionStyle = AppModel.shared?.immersionStyleForRenderer.rawValue
        #endif
        // Capture each authored lane once, then derive the legacy projection from
        // this exact canonical value. This prevents canonical and compatibility
        // fields from representing two different instants during live playback.
        let state = SceneState(capturing: settings, immersionStyle: immersionStyle)

        // ── Geometry domain (1 lock acquisition) ──
        let geo = state.geometry
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
        let qual = state.quality
        preset.fractalIterations = qual.baseFractalIterations
        preset.maxRaySteps = qual.baseMaxRaySteps
        preset.resolutionScale = qual.resolutionScale
        preset.tileSize = qual.tileSize
        // Per-scene performance profile (live scene-load state, not part of QualityConfig).
        preset.coneMarchCompatible = qual.coneMarchCompatible
        preset.recommendedQuality = qual.recommendedQuality

        // ── Color domain (1 lock acquisition) ──
        let col = state.color
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
        let lit = state.lighting
        preset.lightingPreset = lit.lightingPreset
        preset.hueRotationEffect = lit.hueRotationEffect
        preset.pulseEffect = lit.pulseEffect
        preset.glowEffect = lit.glowEffect
        preset.bloomEffect = lit.bloomEffect
        preset.edgeDetectionEffect = lit.edgeDetectionEffect
        preset.fogEffect = lit.fogEffect
        preset.gradientCycleEffect = lit.gradientCycleEffect
        preset.linearRailEffect = lit.linearRailEffect
        // Remaining lighting state (previously dropped).
        preset.lightVariationRate = lit.lightVariationRate
        preset.beatFlashEffect = lit.beatFlashEffect
        preset.polarRotationEffect = lit.polarRotationEffect
        preset.juliaDriftEffect = lit.juliaDriftEffect

        // ── Display domain (1 lock acquisition) ──
        let disp = state.display
        preset.lightingMode = disp.lightingMode
        // Space-module transforms live in DisplayConfig — capture them so they
        // round-trip through save/load (previously dropped).
        preset.sphericalInversionMode = disp.sphericalInversionMode
        preset.sphericalInversionRadius = disp.sphericalInversionRadius
        preset.sphereProjectionEnabled = disp.sphereProjectionEnabled
        preset.sphereProjectionBlend = disp.sphereProjectionBlend
        preset.sphereProjectionRadius = disp.sphereProjectionRadius
        preset.deIterationMismatch = disp.deIterationMismatch
        // Glass-floor platform (previously dropped).
        preset.platformEnabled = disp.platformEnabled
        preset.platformRadius = disp.platformRadius
        // Bounding Shape (sphere) — artistic clip, round-trips with the scene.
        preset.boundingShapeEnabled = qual.boundingShapeEnabled
        preset.boundingShapeRadius = qual.boundingShapeRadius
        preset.boundingShapeFogMode = qual.boundingShapeFogMode
        preset.boundingShapeShadowDepth = qual.boundingShapeShadowDepth
        preset.boundingShapeType = qual.boundingShapeType
        // Bound to Space (assumed-room clip) — round-trips with the scene.
        preset.boundToSpaceEnabled = qual.boundToSpaceEnabled
        preset.boundToSpaceMode = qual.boundToSpaceMode
        preset.boundSpaceWidth = qual.boundSpaceWidth
        preset.boundSpaceDepth = qual.boundSpaceDepth
        preset.boundSpaceHeight = qual.boundSpaceHeight
        preset.boundAmbientStrength = qual.boundAmbientStrength
        preset.envScrunchEnabled = qual.envScrunchEnabled
        preset.envScrunchMode = qual.envScrunchMode
        preset.envScrunchStrength = qual.envScrunchStrength
        preset.envScrunchReach = qual.envScrunchReach
        preset.envScrunchContain = qual.envScrunchContain
        preset.envScrunchContainFeather = qual.envScrunchContainFeather
        // Mixed-immersion scene marker (visionOS): recorded only when the scene
        // is saved while Mixed is active, so loading it can restore the
        // passthrough presentation. Full/Partial saves leave it nil and loading
        // never *exits* Mixed — the user controls that from the picker.
        #if os(visionOS)
        if state.presentation.immersionStyle == AppModel.ImmersionStylePreference.mixed.rawValue {
            preset.mixedModeScene = true
        }
        #endif
        // Composable domain-transform stack (Transformations section). Direct
        // RenderSettings property, not in DisplayConfig. Empty array → nil so older
        // readers and round-trips stay clean.
        let warpOps = state.space.warpStack
        preset.spaceWarpOps = warpOps.isEmpty ? nil : warpOps

        // ── Safety bubble domain (1 lock acquisition) ──
        let sb = state.safetyBubble
        preset.safetyBubbleEnabled = sb.enabled
        preset.safetyBubbleRadius = sb.radius
        preset.safetyBubbleShape = sb.shape
        preset.safetyBubbleBlend = sb.strength
        // Bubble edge fade (previously dropped).
        preset.safetyBubbleFadeEnabled = sb.fadeEnabled
        preset.safetyBubbleFadeWidth = sb.fadeWidth

        // ── Hand Attraction domain (1 lock acquisition) ──
        preset.handAttraction = state.handAttraction

        // ── Audio reactive domain (1 lock acquisition) ──
        let arc = state.audioReactive
        preset.audioReactiveConfig = arc
        // Keep legacy field in sync so files remain readable by older builds.
        preset.musicReactiveMappings = arc.musicReactiveMappings
        // Persist any embedded effect (custom fractal OR space warp). The decoder
        // only forces fractalType = .custom for a `.fractal` kind, so a warp
        // round-trips on top of whatever built-in fractal is active.
        preset.embeddedFormula = embeddedFormula

        // Canonical v3 envelope. Keep every legacy field above populated so the
        // same file remains useful to older app builds; current builds restore
        // through this domain-shaped snapshot first, then apply those flat fields
        // as compatibility overrides.
        preset.schemaVersion = Self.currentSchemaVersion
        preset.sceneState = state

        return preset
    }
    
    /// Apply this preset without allowing scene-driven mutations to rewrite the
    /// user's persisted device preferences. `scope: .session` is used for exact
    /// preview rollback and relaunch checkpoints; ordinary shared scenes use the
    /// comfort-preserving `.scene` policy.
    func apply(to settings: RenderSettings,
               includePerformance: Bool = true,
               resetEnvironment: Bool = false,
               scope: SceneRestoreScope = .scene) {
        settings.withPersistenceSuppressed {
            applyWithoutPersistence(
                to: settings,
                includePerformance: includePerformance,
                resetEnvironment: resetEnvironment,
                scope: scope
            )
        }
    }

    private func applyWithoutPersistence(to settings: RenderSettings,
                                         includePerformance: Bool,
                                         resetEnvironment: Bool,
                                         scope: SceneRestoreScope) {
        if resetEnvironment {
            settings.audioReactiveConfig = AudioReactiveConfig()
        }
        if scope == .scene {
            settings.resetSceneAnimationPhases()
        }

        // v3's canonical domain snapshot fills every scene-owned lane (including
        // fields the legacy flat format never knew about). The flat fields below
        // are still applied afterward so older files work and callers that edit a
        // decoded legacy property continue to get the expected override.
        sceneState?.apply(to: settings, includePerformance: includePerformance, scope: scope)
        if sceneState == nil {
            // Fields that did not exist in v1/v2 must still be authoritative so
            // an older scene cannot inherit motion/warps from whatever was loaded
            // immediately before it.
            settings.spaceWarpStrength = 0.0
            settings.spaceWarpOrigin = .zero
            settings.spaceWarpAxis = SIMD3<Float>(0, 1, 0)
            settings.infiniteZoomEnabled = false
            settings.infiniteZoomRate = 0.15
            settings.lightingPlay = false
            settings.shadowsEnabled = true
            settings.zoomFogCompensationEnabled = false
        }

        // A scene load must start from a CLEAN slate: live gesture offsets
        // (zoom/rotation/param nudges ride in _manualOffset* even outside
        // animation playback) and music offsets otherwise carry into the loaded
        // scene, so the same scene restores differently depending on what the
        // user did before. Clearing here is what makes apply reproducible.
        settings.clearAnimationManualOffsets()
        settings.clearAudioPlaybackOffsets()
        settings.setSpaceWarpAudioOffsets([:])

        // A canonical-only schema-3 document has no legacy compatibility
        // projection to layer. Applying synthesized/default flat values here
        // would immediately stomp the canonical domains we just restored.
        if sceneState != nil, !appliesLegacyFlatFields {
            applyPresentationIntent()
            applyModuleOverrides(to: settings)
            return
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
        
        // Restore formula params for all types (unified path). AUTHORITATIVE:
        // a scene without values means the type's defaults — never the previous
        // scene's parameters.
        var fp = fractalType.defaultFormulaParams()
        if let vals = formulaParamValues {
            for i in 0..<min(16, vals.count) {
                FormulaCatalog.setParam(&fp, index: i, value: vals[i])
            }
        }
        settings.formulaParams = fp
        
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

        // Per-scene performance profile — AUTHORITATIVE (applies on every load,
        // including the scene-switch path where includePerformance is false, so the
        // gate/floor can't leak from the previously loaded scene):
        //   • Cone-march gate — absent/true means "compatible" (device setting
        //     applies); only an explicit false suppresses it for this scene.
        //   • Recommended quality — high/ultra raise resolution toward target + lift
        //     the governor floor; nil/standard reset the floor to the global minimum.
        // Ordered AFTER the resolutionScale restore above so the Mac quality raise
        // composes on top of the scene's own saved resolution.
        settings.sceneConeMarchCompatible = coneMarchCompatible ?? true
        settings.applyRecommendedQuality(recommendedQuality)

        // The safety bubble is user-owned comfort state: users can disable it,
        // scenes cannot. A scene that uses the bubble as part of its authored
        // look applies its full bubble state, but a scene saved without it
        // must NOT silently disable (or reshape) the user's bubble on load.
        let shouldApplyBubble = (scope == .session)
            ? (safetyBubbleEnabled != nil)
            : (safetyBubbleEnabled == true)
        if shouldApplyBubble {
            if let safetyBubbleEnabled {
                settings.safetyBubbleEnabled = safetyBubbleEnabled
            }
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

        // Hand Attraction: scene-authored interaction feel — restore the whole
        // config (including its enabled state) when the scene saved one. Older
        // scenes without a config leave the user's current config untouched.
        if let handAttraction = handAttraction {
            settings.handAttractionConfig = handAttraction
        }

        // Space module (domain transforms) — AUTHORITATIVE like the sphere
        // projection below: a scene without the field means the default, never
        // the previous scene's inversion.
        settings.sphericalInversionMode = sphericalInversionMode ?? .off
        settings.sphericalInversionRadius = sphericalInversionRadius ?? 2.0
        // Sphere projection must be RESET (not left untouched) when the incoming
        // scene doesn't carry it — otherwise the previous scene's enabled state
        // leaks forward. Legacy MSP scenes now turn this ON via the migration above,
        // so a plain `if let` would persist projection into the next non-projection
        // scene. Treat a missing value as the DisplayConfig default (off, 1.0/1.0).
        settings.sphereProjectionEnabled = sphereProjectionEnabled ?? false
        settings.sphereProjectionBlend = sphereProjectionBlend ?? 1.0
        settings.sphereProjectionRadius = sphereProjectionRadius ?? 1.0
        // Same authoritative-reset rule: a scene without the mismatch field
        // means a correct DE, so clear any δ the previous scene left live.
        settings.deIterationMismatch = deIterationMismatch
            ?? ControlCatalog.deIterationMismatch.defaultValue

        // Composable domain-transform stack (Transformations section). A scene fully
        // defines its transforms, so apply AUTHORITATIVELY: nil/absent (an empty stack
        // or an older pre-transform scene) clears any transforms the previous scene
        // left live, instead of leaking them into this one.
        settings.spaceWarpStack = spaceWarpOps ?? []

        // Glass-floor platform — AUTHORITATIVE: absent means the defaults
        // (platform on at 1.888), never the previous scene's platform.
        settings.platformEnabled = platformEnabled ?? true
        settings.platformRadius = platformRadius ?? ControlCatalog.platformRadius.defaultValue

        // Bounding Shape (sphere) — a scene's explicit setting wins; otherwise
        // bounding follows the Mixed-immersion rule: scenes marked Mixed are
        // bounded, everything else is unbounded. (The user can still flip the
        // toggle live afterward — this only sets the state at scene load.)
        if let boundingShapeEnabled = boundingShapeEnabled {
            settings.boundingSphereSkipEnabled = boundingShapeEnabled
        } else {
            settings.boundingSphereSkipEnabled = (mixedModeScene == true)
        }
        // Bounding-shape knobs — AUTHORITATIVE to the declaration defaults
        // (the enabled flag above keeps its deliberate Mixed-immersion rule;
        // the legacy fogEnabled → Ghost Fade mapping is preserved).
        settings.boundingShapeRadius = boundingShapeRadius ?? 6.0
        if let boundingShapeFogMode = boundingShapeFogMode {
            settings.boundingShapeFogMode = boundingShapeFogMode
        } else if let boundingShapeFogEnabled = boundingShapeFogEnabled {
            settings.boundingShapeFogMode = boundingShapeFogEnabled ? 1 : 0
        } else {
            settings.boundingShapeFogMode = 0
        }
        settings.boundingShapeShadowDepth = boundingShapeShadowDepth ?? 0.35
        settings.boundingShapeType = boundingShapeType ?? 0.0
        // Bound to Space — AUTHORITATIVE to the declaration defaults. An
        // explicit saved value must survive scene switches; an older scene
        // without the field clears a previously-live room bound back to OFF.
        settings.boundToSpaceEnabled = boundToSpaceEnabled ?? false
        settings.boundToSpaceMode = boundToSpaceMode ?? 0
        settings.boundSpaceWidth = boundSpaceWidth ?? 4.0
        settings.boundSpaceDepth = boundSpaceDepth ?? 4.0
        settings.boundSpaceHeight = boundSpaceHeight ?? 2.5
        settings.boundAmbientStrength = boundAmbientStrength ?? 0.5
        // Environment Scrunch — AUTHORITATIVE to the QualityConfig defaults, like
        // every other bounding field: a scene without scrunch means scrunch OFF
        // (default), never the previous scene's. Only the parameters travel; the
        // scanned-room SDF grid is always live/device-local.
        settings.envScrunchEnabled = envScrunchEnabled ?? false
        settings.envScrunchMode = envScrunchMode ?? 0
        settings.envScrunchStrength = envScrunchStrength ?? 0.8
        settings.envScrunchReach = envScrunchReach ?? 0.75
        settings.envScrunchContain = envScrunchContain ?? 0
        settings.envScrunchContainFeather = envScrunchContainFeather ?? 0.1

        // Scene-driven immersion (visionOS). v3 preserves Window distinctly;
        // older files fall back to the legacy Mixed/Immersive Boolean.
        applyPresentationIntent()

        // v2.0 modular lighting effects — AUTHORITATIVE: every field falls
        // back to its RenderSettings declaration default when absent, so an
        // older scene loads to a defined look instead of inheriting whatever
        // the previous scene left live. (The effect setters force
        // lightingPreset = .custom, matching the pre-existing restore order.)
        settings.lightingMode = lightingMode ?? .animated
        settings.lightingPreset = lightingPreset ?? .off
        settings.hueRotationEffect = hueRotationEffect ?? .off
        settings.pulseEffect = pulseEffect ?? .off
        settings.glowEffect = glowEffect ?? .off
        settings.bloomEffect = bloomEffect ?? .off
        // Pre-field scene files could still select the dedicated Edge Detection
        // lighting preset. Preserve that authored outline; other missing fields
        // remain authoritatively OFF so the previous scene cannot leak through.
        settings.edgeDetectionEffect = edgeDetectionEffect
            ?? (lightingPreset ?? .off).effects().edge
        // Fog is opt-in: a scene must explicitly save it enabled. Absent a
        // saved fogEffect, load with fog OFF so it never persists from the
        // previously-live scene (matches every other effect defaulting to .off).
        settings.fogEffect = fogEffect ?? .off
        settings.gradientCycleEffect = gradientCycleEffect ?? .off
        settings.linearRailEffect = linearRailEffect ?? .off
        settings.lightVariationRate = lightVariationRate ?? 0.5
        settings.beatFlashEffect = beatFlashEffect ?? .off
        settings.polarRotationEffect = polarRotationEffect ?? .off
        settings.juliaDriftEffect = juliaDriftEffect ?? .off

        // Color scheme auto-transition — authoritative.
        settings.colorSchemeAutoTransition = colorSchemeAutoTransition ?? false
        settings.colorSchemeAutoInterval = colorSchemeAutoInterval ?? 30.0
        settings.colorSchemeTransitionDuration = colorSchemeTransitionDuration ?? 2.0

        // v2.1 gradient coloring system — authoritative.
        settings.gradientState = gradientState ?? GradientState()
        settings.lightingSoftness = lightingSoftness ?? 0.35
        // Cell (toon) shading — authoritative.
        settings.cellShadingEnabled = cellShadingEnabled ?? false
        settings.cellShadingLevels = cellShadingLevels ?? 4.0
        settings.aoStrength = aoStrength ?? 0.0
        settings.tonemapStrength = tonemapStrength ?? 0.0
        // Vignette is canonical-domain-only. Legacy scenes predate the control
        // but were rendered with the historical fixed vignette, so restore its
        // historical-look default instead of leaking the previous scene's
        // authored value. A present SceneState already applied the saved value.
        if sceneState == nil {
            settings.vignetteStrength = ControlCatalog.vignetteStrength.defaultValue
        }
        if let arc = audioReactiveConfig {
            // Full config present (files saved by current builds): restore everything.
            settings.audioReactiveConfig = arc
        } else if let mappings = musicReactiveMappings, !mappings.isEmpty {
            // Legacy file (mappings-only): restore mappings and auto-enable.
            var audioConfig = settings.audioReactiveConfig
            audioConfig.musicReactiveMappings = mappings
            audioConfig.fractalAudioReactiveEnabled = true
            settings.audioReactiveConfig = audioConfig
        } else {
            // No audio state at all (pre-music scene): reset, so the previous
            // scene's mappings don't keep driving this one.
            settings.audioReactiveConfig = AudioReactiveConfig()
        }

        // === MODULE LAYER ===
        // Apply typed/keyed module params AFTER the flat fields, so a module can
        // refine a flat preset. Each param is capability-filtered against the
        // active fractal (e.g. sphere projection on an unsupported type is
        // skipped). No-op for older scenes that carry no `modules` block.
        applyModuleOverrides(to: settings)
    }

    private func applyPresentationIntent() {
        #if os(visionOS)
        let sceneStyle: AppModel.ImmersionStylePreference
        if mixedModeScene == true {
            // Flat compatibility marker wins when a bundled-scene classifier
            // adds it after decoding an older document.
            sceneStyle = .mixed
        } else if let rawStyle = sceneState?.presentation.immersionStyle {
            sceneStyle = .fromPersisted(rawStyle)
        } else {
            sceneStyle = .immersive
        }
        Task { @MainActor in
            guard let app = AppModel.shared else { return }
            app.immersionChangeIsSceneDriven = true
            app.immersionStylePreference = sceneStyle
            app.immersionChangeIsSceneDriven = false
        }
        #endif
    }

    private func applyModuleOverrides(to settings: RenderSettings) {
        guard let modules else { return }
        for (rawKey, block) in modules {
            guard let key = ModuleKey(rawValue: rawKey) else { continue }
            ModuleRegistry.apply(key, block: block, to: settings)
        }
    }
    
    /// Get the thumbnail as a platform image.
    /// Uses ImageIO to downsample to display size, avoiding full-resolution decoding.
    private static let thumbnailMaxPixelSize: CGFloat = 240 // 120pt @2x
    nonisolated(unsafe) private static let thumbnailCache = NSCache<NSString, PlatformImage>()

    static func clearThumbnailCache(for id: UUID) {
        thumbnailCache.removeObject(forKey: id.uuidString as NSString)
    }

    static func clearThumbnailCache() {
        thumbnailCache.removeAllObjects()
    }

    var thumbnailImage: PlatformImage? {
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

    private static func downsampledImage(from data: Data) -> PlatformImage? {
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
        #if os(visionOS) || os(iOS)
        return UIImage(cgImage: cgImage)
        #elseif os(macOS)
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        #endif
    }
}

extension FractalPreset {
    var isCustomScenePreset: Bool {
        embeddedFormula != nil
    }

    var hasMusicReactiveMappings: Bool {
        let mappings = audioReactiveConfig?.musicReactiveMappings
            ?? sceneState?.audioReactive.musicReactiveMappings
            ?? musicReactiveMappings
            ?? []
        return !mappings.isEmpty
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
