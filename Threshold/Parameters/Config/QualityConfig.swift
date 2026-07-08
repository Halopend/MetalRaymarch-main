//
//  QualityConfig.swift
//  Threshold
//
//  Domain config: iteration counts, ray steps, and
//  sphere-tracing refinement parameters.
//  Part of the RenderSettings decomposition (Phase 1).
//

import Foundation

/// Bounding-edge treatment shown by the Shape → Bounding tab's picker.
/// Backed by `QualityConfig.boundingShapeFogMode`'s raw Int.
enum BoundingFogMode: Int, CaseIterable, Identifiable, Sendable {
    case off = 0
    case ghostFade = 1
    case innerShadow = 2

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .off: return "Off"
        case .ghostFade: return "Ghost Fade"
        case .innerShadow: return "Inner Shadow"
        }
    }

    var help: String {
        switch self {
        case .off:
            return "Hard clip at the bounding shape's edge."
        case .ghostFade:
            return "Fades the fractal out near the bounding shape's edge. In Partial/Mixed immersion the fade goes translucent, revealing passthrough."
        case .innerShadow:
            return "Darkens the fractal near the bounding shape's edge without ever going translucent — stays fully opaque, even in Partial/Mixed immersion. Depth slider controls how far the darkening reaches in."
        }
    }
}

/// Which faces of the assumed room bound the fractal (Shape → Bounding tab's
/// Bound to Space picker). Backed by `QualityConfig.boundToSpaceMode`'s raw Int.
enum BoundToSpaceMode: Int, CaseIterable, Identifiable, Sendable {
    case matchSpace = 0
    case ceilingOpen = 1
    case wallsOpen = 2

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .matchSpace: return "Match Space"
        case .ceilingOpen: return "Ceiling Open"
        case .wallsOpen: return "Walls Open"
        }
    }

    var help: String {
        switch self {
        case .matchSpace:
            return "Closed box: the fractal only renders inside the assumed room — walls, floor, and ceiling."
        case .ceilingOpen:
            return "Walls and floor bound the fractal; it can extend upward past the ceiling."
        case .wallsOpen:
            return "Only the floor and ceiling bound the fractal; it can extend outward past the walls."
        }
    }
}

/// Author-declared "aim for this render quality" hint carried per-scene
/// (`FractalPreset.recommendedQuality`). Deliberately distinct from iteration
/// count: it targets the render RESOLUTION (MetalFX input scale on Mac; the
/// compositor drawable scale on visionOS), never the fractal DE. A high/ultra
/// scene lifts the adaptive FPS governor's floor so it resists being downscaled,
/// and raises the resolution toward the target ("aim for AT LEAST this" — it only
/// ever raises, never lowers). `standard`/absent = no opinion.
///
/// This is a HINT the device consults, not a forced setting: it can only ask for
/// MORE sharpness, never impose a device-local perf technique — the same rule the
/// rest of the Quality domain follows (a scene must not force cone-march/foveation
/// onto another device).
enum SceneQualityTarget: String, Codable, CaseIterable, Sendable {
    case standard
    case high
    case ultra

    var title: String {
        switch self {
        case .standard: return "Standard"
        case .high:     return "High"
        case .ultra:    return "Ultra"
        }
    }

    /// Mac / iOS MetalFX input-scale target (`resolutionScale`, 0.33…1.0).
    var macResolutionScale: Float {
        switch self {
        case .standard: return 0.75   // platform default
        case .high:     return 1.0    // native input
        case .ultra:    return 1.0    // Mac tops out at native
        }
    }

    /// visionOS compositor drawable-scale target (`renderQuality`), within
    /// `QualityConfig.visionMin…visionMaxRenderQuality`.
    var visionRenderQuality: Float {
        switch self {
        case .standard: return 0.5
        case .high:     return 0.7
        case .ultra:    return QualityConfig.visionMaxRenderQuality  // 0.8
        }
    }

    /// Lowest compositor Render Quality the adaptive governor may drop this scene
    /// to. A high/ultra scene declares it should stay sharp, so its floor is lifted
    /// above the global minimum — the governor can still shed quality under load,
    /// just not as far. `standard` keeps the global minimum (no lift).
    var visionRenderQualityFloor: Float {
        switch self {
        case .standard: return QualityConfig.visionMinRenderQuality  // 0.05 (no lift)
        case .high:     return 0.45
        case .ultra:    return 0.6
        }
    }

    /// Whether this target actually asks for anything beyond the platform default.
    var raisesQuality: Bool { self != .standard }
}

struct QualityConfig: Codable, Equatable, Sendable {
    /// visionOS compositor render-quality ceiling. Single source of truth for both
    /// `configuration.maxRenderQuality` (set at layer creation — governs drawable
    /// texture memory) and the Render Quality slider's top. 0.8 follows Apple's
    /// "set max to the minimum your content needs" guidance: it trims drawable
    /// memory vs 1.0 while staying visually near-native.
    static let visionMaxRenderQuality: Float = 0.8

    /// Lowest compositor Render Quality the slider / adaptive governor may reach.
    /// Below the old 0.1 floor so the FPS-holding governor (and manual probing) can
    /// trade more sharpness for headroom on heavy scenes.
    static let visionMinRenderQuality: Float = 0.05

    // User-set base values
    var baseFractalIterations: Int = 9
    var baseMaxRaySteps: Int = 64

    // Resolution / tiling
    var resolutionScale: Float = 1.0   // 0.33 - 1.0 (MetalFX spatial upscale input scale)
    var renderQuality: Float = 0.5     // visionMinRenderQuality - 1.0 (visionOS compositor drawable scale; 1.0 = native). Default 0.5 favors framerate; the floor is for probing max framerate / the adaptive governor.
    var tileSize: Int = 0              // 0=disabled (fragment), 8=adaptive hierarchical compute

    // Vision Pro: auto-lower Render Quality to hold the frame rate, recovering
    // toward the slider (treated as a ceiling) when FPS has headroom. The slider
    // value is the maximum; the governor only renders at or below it. See
    // `AdaptiveRenderQualityController`.
    var adaptiveRenderQualityEnabled: Bool = true

    // Debug
    var debugHierarchical: Bool = false

    // Experimental: coherent packet predict-validate raymarch path (Stages 0-3)
    var coherentPacketEnabled: Bool = false

    // Experimental: reconstruct the surface normal from the previous frame's
    // depth buffer (4 taps/axis) instead of GetNormal()'s extra DE evaluations.
    // Mac direct/native-res render path only — silently falls back to
    // GetNormal() whenever history isn't available (see RaymarchRenderView's
    // depth-history ping-pong). Off by default for a correct baseline.
    var depthNormalReconstructionEnabled: Bool = false

    // Compute path (tileSize == 8): temporal reprojection + tile/supertile depth
    // seeding. The path's main speedup, but can blank disoccluded tiles — off by
    // default for a correct baseline.
    var computeTemporalReprojectionEnabled: Bool = false

    // visionOS fragment path: conservative cone coarse-prepass warm-start. A
    // low-res cone pass writes a provable LOWER BOUND on each 8x8 block's
    // nearest-surface entry distance; the full march raises its start t to it.
    // Off by default — when off, the code path is byte-identical to before.
    var coarsePrepassWarmStartEnabled: Bool = false

    // Foveated raymarching strength (0...1); peripheral 8x8 tiles march fewer steps.
    var foveationStrength: Float = 0.0

    // Smart advance: grazing-aware lead-ahead sphere tracing. Reads the along-ray
    // DE gradient to step further through grazing/receding regions. Off by default.
    var smartAdvanceEnabled: Bool = false

    // Cone marching strength (0...1): grow the march hit-threshold with ray
    // distance so each ray stops once the distance field falls within ~N pixels
    // of its projected footprint (after Mansour's ConeMarchingPen). 0 = off.
    // Higher = far geometry resolves in far fewer steps (faster) at the cost of
    // softening distant detail; near geometry always keeps full sharpness. The
    // baseline march is already a ~1-pixel cone, so meaningful strength scales the
    // footprint up to ~16 px. Works on every render path.
    var coneMarchStrength: Float = 0.0

    // Cone-coverage anti-aliasing (CTSS-lite). Derives a silhouette edge-coverage
    // alpha from the cone footprint at the closest lateral approach and composites
    // the near-miss surface over the background. Decouples edge quality from the
    // Cone Marching threshold so that knob can run harder (fewer steps) without
    // blobby, inflated silhouettes. Softens outer edges only (no sub-pixel thin-
    // feature recovery). Fragment path only for now. Off by default.
    var coneCoverageAAEnabled: Bool = false

    // Over-relaxation ceiling (Keinert enhanced sphere tracing): the largest
    // step multiplier the auto-ramp may reach once geometry settles. 1.0 = plain
    // conservative sphere tracing (sharpest on thin features, slowest); higher
    // takes larger over-relaxed steps (faster, guarded by overstep-failure
    // retreat). The shader still clamps per fractal type. Default 1.4 = the
    // previous hardcoded ceiling.
    var overRelaxationMax: Float = 1.4

    // Distance-based iteration LOD: drop fractal iterations on faraway samples,
    // where the lost detail is already sub-pixel. 0 = off (full iterations
    // everywhere). Higher = more aggressive falloff — faster on deep/dense scenes
    // without inflating the silhouette the way cone marching does.
    var distanceLODStrength: Float = 0.0

    // Self-shadowing. Off skips the two per-pixel shadow marches (a large saving
    // on every lit pixel) for flatter, faster lighting. On = full soft shadows.
    var shadowsEnabled: Bool = true

    // Bounding-sphere empty-space skip: reject rays that miss a sphere enclosing
    // the fractal before marching. Off by default — the bound is a generous
    // estimate, so it mainly culls background rays; too-tight a bound could clip
    // geometry. Experimental.
    var boundingSphereSkipEnabled: Bool = false

    // Bounding shape (sphere) radius in model units; used while the skip is on.
    var boundingShapeRadius: Float = 6.0

    // Bounding-edge treatment: 0 = off (hard clip), 1 = Ghost Fade (fades RGB
    // and, under passthrough, alpha too — translucent), 2 = Inner Shadow (fades
    // RGB only, stays opaque — the original pre-passthrough fog behavior).
    var boundingShapeFogMode: Int = 0

    // Inner Shadow band width, as a fraction of boundingShapeRadius (0...1).
    // Only used while boundingShapeFogMode == 2 (Ghost Fade keeps a fixed band).
    var boundingShapeShadowDepth: Float = 0.35

    // Bounding Shape family/preset — same encoding as SafetyBubbleConfig.shape:
    // 0...1 = sphere/cube morph, 2...6 = discrete platonic solids.
    var boundingShapeType: Float = 0.0

    // Bound to Space: clip the fractal to an assumed rectangular room in WORLD
    // meters — floor at y = 0 (the visionOS floor), footprint centered on the
    // user's starting position. Mode: 0 = Match Space (closed box), 1 = Ceiling
    // Open, 2 = Walls Open (see BoundToSpaceMode).
    var boundToSpaceEnabled: Bool = false
    var boundToSpaceMode: Int = 0
    var boundSpaceWidth: Float = 4.0
    var boundSpaceDepth: Float = 4.0
    var boundSpaceHeight: Float = 2.5
    var boundAmbientStrength: Float = 0.5   // room-derived ambient occlusion, 0 = off

    // Environment Scrunch: the scanned surroundings (visionOS scene
    // reconstruction; synthetic primitives on Mac) baked to a distance grid
    // that the fractal scrunches/bulges around — a mixed positive/negative
    // proximity field (the hand-attraction model applied to the room).
    var envScrunchEnabled: Bool = false
    var envScrunchMode: Int = 0             // 0 = Scrunch (bulge around surfaces), 1 = Shell (render only within Reach of surfaces)
    var envScrunchStrength: Float = 0.8     // 0-1 blend toward the scrunched field
    var envScrunchReach: Float = 0.75       // engage band / shell thickness around surfaces, meters
    var envScrunchContain: Int = 0          // 0 = off, 1 = hard clip to scanned room box, 2 = soft blend
    var envScrunchContainFeather: Float = 0.1 // soft-blend feather half-width, meters (mode 2)

    // Zoom fog compensation: scale fog intensity down on zoom-out so the fog
    // sphere's world radius stays constant instead of swallowing the fractal.
    // Off = raw fog at every zoom (was hardcoded on for the Kleinian family).
    var zoomFogCompensationEnabled: Bool = false

    // MARK: - Validation

    mutating func clamp() {
        boundingShapeRadius = max(0.05, min(30.0, boundingShapeRadius))
        boundingShapeFogMode = boundingShapeFogMode.clamped(to: 0...2)
        boundingShapeShadowDepth = boundingShapeShadowDepth.clamped(to: 0.02...0.95)
        boundingShapeType = boundingShapeType.clamped(to: 0.0...SafetyBubbleShapePreset.maxStoredValue)
        boundToSpaceMode = boundToSpaceMode.clamped(to: 0...2)
        boundSpaceWidth = boundSpaceWidth.clamped(to: 1.0...20.0)
        boundSpaceDepth = boundSpaceDepth.clamped(to: 1.0...20.0)
        boundSpaceHeight = boundSpaceHeight.clamped(to: 1.0...10.0)
        boundAmbientStrength = boundAmbientStrength.clamped(to: 0.0...1.0)
        envScrunchMode = envScrunchMode.clamped(to: 0...1)
        envScrunchStrength = envScrunchStrength.clamped(to: 0.0...1.0)
        envScrunchReach = envScrunchReach.clamped(to: 0.2...2.0)
        envScrunchContain = envScrunchContain.clamped(to: 0...2)
        envScrunchContainFeather = envScrunchContainFeather.clamped(to: 0.0...0.5)
        baseFractalIterations = baseFractalIterations.clamped(to: 2...24)
        baseMaxRaySteps = baseMaxRaySteps.clamped(to: 16...200)
        resolutionScale = resolutionScale.clamped(to: ControlCatalog.resolutionScale)
        renderQuality = renderQuality.clamped(to: Self.visionMinRenderQuality...Self.visionMaxRenderQuality)
        foveationStrength = foveationStrength.clamped(to: 0.0...1.0)
        coneMarchStrength = coneMarchStrength.clamped(to: 0.0...1.0)
        overRelaxationMax = overRelaxationMax.clamped(to: 1.0...1.6)
        distanceLODStrength = distanceLODStrength.clamped(to: 0.0...1.0)
    }

    // MARK: - Codable
    //
    // Decoding is tolerant of missing keys: every field falls back to its
    // default. This keeps older persisted configs (which predate newer fields
    // like `renderQuality`) loading intact instead of failing to decode and
    // silently resetting the user's whole quality setup to defaults.

    private enum CodingKeys: String, CodingKey {
        case baseFractalIterations, baseMaxRaySteps
        case resolutionScale, renderQuality, tileSize
        case debugHierarchical, coherentPacketEnabled, depthNormalReconstructionEnabled, computeTemporalReprojectionEnabled, coarsePrepassWarmStartEnabled, foveationStrength
        case smartAdvanceEnabled, coneMarchStrength, coneCoverageAAEnabled
        case overRelaxationMax, distanceLODStrength, shadowsEnabled, boundingSphereSkipEnabled, boundingShapeRadius
        case boundingShapeFogEnabled  // legacy Bool key, migrated into boundingShapeFogMode on decode
        case boundingShapeFogMode, boundingShapeShadowDepth, boundingShapeType
        case boundToSpaceEnabled, boundToSpaceMode, boundSpaceWidth, boundSpaceDepth, boundSpaceHeight
        case boundAmbientStrength
        case envScrunchEnabled, envScrunchMode, envScrunchStrength, envScrunchReach
        case envScrunchContain, envScrunchContainFeather
        case zoomFogCompensationEnabled
        case adaptiveRenderQualityEnabled
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        baseFractalIterations = try c.decodeIfPresent(Int.self,   forKey: .baseFractalIterations) ?? 9
        baseMaxRaySteps       = try c.decodeIfPresent(Int.self,   forKey: .baseMaxRaySteps)       ?? 64
        resolutionScale       = try c.decodeIfPresent(Float.self, forKey: .resolutionScale)       ?? 1.0
        renderQuality         = try c.decodeIfPresent(Float.self, forKey: .renderQuality)         ?? 0.5
        let decodedTileSize   = try c.decodeIfPresent(Int.self,   forKey: .tileSize)              ?? 0
        tileSize              = decodedTileSize == 2 ? 0 : decodedTileSize  // Old "Quad Shared" mode removed → degrade to fragment
        debugHierarchical     = try c.decodeIfPresent(Bool.self,  forKey: .debugHierarchical)     ?? false
        coherentPacketEnabled = try c.decodeIfPresent(Bool.self,  forKey: .coherentPacketEnabled) ?? false
        depthNormalReconstructionEnabled = try c.decodeIfPresent(Bool.self, forKey: .depthNormalReconstructionEnabled) ?? false
        computeTemporalReprojectionEnabled = try c.decodeIfPresent(Bool.self, forKey: .computeTemporalReprojectionEnabled) ?? false
        coarsePrepassWarmStartEnabled = try c.decodeIfPresent(Bool.self, forKey: .coarsePrepassWarmStartEnabled) ?? false
        foveationStrength     = try c.decodeIfPresent(Float.self, forKey: .foveationStrength)     ?? 0.0
        smartAdvanceEnabled   = try c.decodeIfPresent(Bool.self,  forKey: .smartAdvanceEnabled)   ?? false
        coneMarchStrength     = try c.decodeIfPresent(Float.self, forKey: .coneMarchStrength)     ?? 0.0
        coneCoverageAAEnabled = try c.decodeIfPresent(Bool.self,  forKey: .coneCoverageAAEnabled) ?? false
        overRelaxationMax     = try c.decodeIfPresent(Float.self, forKey: .overRelaxationMax)     ?? 1.4
        distanceLODStrength   = try c.decodeIfPresent(Float.self, forKey: .distanceLODStrength)   ?? 0.0
        shadowsEnabled        = try c.decodeIfPresent(Bool.self,  forKey: .shadowsEnabled)        ?? true
        boundingSphereSkipEnabled = try c.decodeIfPresent(Bool.self, forKey: .boundingSphereSkipEnabled) ?? false
        boundingShapeRadius   = try c.decodeIfPresent(Float.self, forKey: .boundingShapeRadius)   ?? 6.0
        if let mode = try c.decodeIfPresent(Int.self, forKey: .boundingShapeFogMode) {
            boundingShapeFogMode = mode
        } else {
            // Migrate the old on/off toggle: true meant the (now-named) Ghost Fade behavior.
            let legacyFogEnabled = try c.decodeIfPresent(Bool.self, forKey: .boundingShapeFogEnabled) ?? false
            boundingShapeFogMode = legacyFogEnabled ? 1 : 0
        }
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
        adaptiveRenderQualityEnabled = try c.decodeIfPresent(Bool.self, forKey: .adaptiveRenderQualityEnabled) ?? true
    }

    // Manual (not synthesized): CodingKeys carries a legacy `boundingShapeFogEnabled`
    // key with no matching stored property (read-only migration in init(from:)),
    // which blocks Encodable auto-synthesis.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(baseFractalIterations, forKey: .baseFractalIterations)
        try c.encode(baseMaxRaySteps, forKey: .baseMaxRaySteps)
        try c.encode(resolutionScale, forKey: .resolutionScale)
        try c.encode(renderQuality, forKey: .renderQuality)
        try c.encode(tileSize, forKey: .tileSize)
        try c.encode(debugHierarchical, forKey: .debugHierarchical)
        try c.encode(coherentPacketEnabled, forKey: .coherentPacketEnabled)
        try c.encode(depthNormalReconstructionEnabled, forKey: .depthNormalReconstructionEnabled)
        try c.encode(computeTemporalReprojectionEnabled, forKey: .computeTemporalReprojectionEnabled)
        try c.encode(coarsePrepassWarmStartEnabled, forKey: .coarsePrepassWarmStartEnabled)
        try c.encode(foveationStrength, forKey: .foveationStrength)
        try c.encode(smartAdvanceEnabled, forKey: .smartAdvanceEnabled)
        try c.encode(coneMarchStrength, forKey: .coneMarchStrength)
        try c.encode(coneCoverageAAEnabled, forKey: .coneCoverageAAEnabled)
        try c.encode(overRelaxationMax, forKey: .overRelaxationMax)
        try c.encode(distanceLODStrength, forKey: .distanceLODStrength)
        try c.encode(shadowsEnabled, forKey: .shadowsEnabled)
        try c.encode(boundingSphereSkipEnabled, forKey: .boundingSphereSkipEnabled)
        try c.encode(boundingShapeRadius, forKey: .boundingShapeRadius)
        try c.encode(boundingShapeFogMode, forKey: .boundingShapeFogMode)
        try c.encode(boundingShapeShadowDepth, forKey: .boundingShapeShadowDepth)
        try c.encode(boundingShapeType, forKey: .boundingShapeType)
        try c.encode(boundToSpaceEnabled, forKey: .boundToSpaceEnabled)
        try c.encode(boundToSpaceMode, forKey: .boundToSpaceMode)
        try c.encode(boundSpaceWidth, forKey: .boundSpaceWidth)
        try c.encode(boundSpaceDepth, forKey: .boundSpaceDepth)
        try c.encode(boundSpaceHeight, forKey: .boundSpaceHeight)
        try c.encode(boundAmbientStrength, forKey: .boundAmbientStrength)
        try c.encode(envScrunchEnabled, forKey: .envScrunchEnabled)
        try c.encode(envScrunchMode, forKey: .envScrunchMode)
        try c.encode(envScrunchStrength, forKey: .envScrunchStrength)
        try c.encode(envScrunchReach, forKey: .envScrunchReach)
        try c.encode(envScrunchContain, forKey: .envScrunchContain)
        try c.encode(envScrunchContainFeather, forKey: .envScrunchContainFeather)
        try c.encode(zoomFogCompensationEnabled, forKey: .zoomFogCompensationEnabled)
        try c.encode(adaptiveRenderQualityEnabled, forKey: .adaptiveRenderQualityEnabled)
    }
}
