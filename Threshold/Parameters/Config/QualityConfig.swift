//
//  QualityConfig.swift
//  Threshold
//
//  Domain config: iteration counts, ray steps, and
//  sphere-tracing refinement parameters.
//  Part of the RenderSettings decomposition (Phase 1).
//

import Foundation

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

    // Compute path (tileSize == 8): temporal reprojection + tile/supertile depth
    // seeding. The path's main speedup, but can blank disoccluded tiles — off by
    // default for a correct baseline.
    var computeTemporalReprojectionEnabled: Bool = false

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

    // Render-distance multiplier (1 = current behavior). Scales how far rays march
    // before giving up (and the per-frame view-distance cap), so geometry farther
    // than the default ~12-unit horizon resolves. Costs steps — pair with a higher
    // ray-step budget or the acceleration levers. Clamped against the projection
    // far plane CPU-side.
    var renderDistanceScale: Float = 1.0

    // MARK: - Validation

    mutating func clamp() {
        baseFractalIterations = baseFractalIterations.clamped(to: 2...24)
        baseMaxRaySteps = baseMaxRaySteps.clamped(to: 16...200)
        resolutionScale = resolutionScale.clamped(to: ControlCatalog.resolutionScale)
        renderQuality = renderQuality.clamped(to: Self.visionMinRenderQuality...Self.visionMaxRenderQuality)
        foveationStrength = foveationStrength.clamped(to: 0.0...1.0)
        coneMarchStrength = coneMarchStrength.clamped(to: 0.0...1.0)
        overRelaxationMax = overRelaxationMax.clamped(to: 1.0...1.6)
        distanceLODStrength = distanceLODStrength.clamped(to: 0.0...1.0)
        renderDistanceScale = renderDistanceScale.clamped(to: 1.0...8.0)
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
        case debugHierarchical, coherentPacketEnabled, computeTemporalReprojectionEnabled, foveationStrength
        case smartAdvanceEnabled, coneMarchStrength
        case overRelaxationMax, distanceLODStrength, shadowsEnabled, boundingSphereSkipEnabled
        case renderDistanceScale, adaptiveRenderQualityEnabled
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
        computeTemporalReprojectionEnabled = try c.decodeIfPresent(Bool.self, forKey: .computeTemporalReprojectionEnabled) ?? false
        foveationStrength     = try c.decodeIfPresent(Float.self, forKey: .foveationStrength)     ?? 0.0
        smartAdvanceEnabled   = try c.decodeIfPresent(Bool.self,  forKey: .smartAdvanceEnabled)   ?? false
        coneMarchStrength     = try c.decodeIfPresent(Float.self, forKey: .coneMarchStrength)     ?? 0.0
        overRelaxationMax     = try c.decodeIfPresent(Float.self, forKey: .overRelaxationMax)     ?? 1.4
        distanceLODStrength   = try c.decodeIfPresent(Float.self, forKey: .distanceLODStrength)   ?? 0.0
        shadowsEnabled        = try c.decodeIfPresent(Bool.self,  forKey: .shadowsEnabled)        ?? true
        boundingSphereSkipEnabled = try c.decodeIfPresent(Bool.self, forKey: .boundingSphereSkipEnabled) ?? false
        renderDistanceScale   = try c.decodeIfPresent(Float.self, forKey: .renderDistanceScale)   ?? 1.0
        adaptiveRenderQualityEnabled = try c.decodeIfPresent(Bool.self, forKey: .adaptiveRenderQualityEnabled) ?? true
    }
}
