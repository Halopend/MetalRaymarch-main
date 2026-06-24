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

    // User-set base values
    var baseFractalIterations: Int = 9
    var baseMaxRaySteps: Int = 64

    // Resolution / tiling
    var resolutionScale: Float = 1.0   // 0.33 - 1.0 (MetalFX spatial upscale input scale)
    var renderQuality: Float = 0.5     // 0.1 - 1.0 (visionOS compositor drawable scale; 1.0 = native). Default 0.5 favors framerate; 0.1 floor is for probing max framerate.
    var tileSize: Int = 0              // 0=disabled, 2/4/8 adaptive hierarchical

    // Debug
    var debugHierarchical: Bool = false

    // Experimental: coherent packet predict-validate raymarch path (Stages 0-3)
    var coherentPacketEnabled: Bool = false

    // Foveated raymarching strength (0...1); peripheral 8x8 tiles march fewer steps.
    var foveationStrength: Float = 0.0

    // Smart advance: grazing-aware lead-ahead sphere tracing. Reads the along-ray
    // DE gradient to step further through grazing/receding regions. Off by default.
    var smartAdvanceEnabled: Bool = false

    // MARK: - Validation

    mutating func clamp() {
        baseFractalIterations = max(2, min(24, baseFractalIterations))
        baseMaxRaySteps = max(16, min(200, baseMaxRaySteps))
        resolutionScale = max(0.33, min(1.0, resolutionScale))
        renderQuality = max(0.1, min(Self.visionMaxRenderQuality, renderQuality))
        foveationStrength = max(0.0, min(1.0, foveationStrength))
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
        case debugHierarchical, coherentPacketEnabled, foveationStrength
        case smartAdvanceEnabled
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        baseFractalIterations = try c.decodeIfPresent(Int.self,   forKey: .baseFractalIterations) ?? 9
        baseMaxRaySteps       = try c.decodeIfPresent(Int.self,   forKey: .baseMaxRaySteps)       ?? 64
        resolutionScale       = try c.decodeIfPresent(Float.self, forKey: .resolutionScale)       ?? 1.0
        renderQuality         = try c.decodeIfPresent(Float.self, forKey: .renderQuality)         ?? 0.5
        tileSize              = try c.decodeIfPresent(Int.self,   forKey: .tileSize)              ?? 0
        debugHierarchical     = try c.decodeIfPresent(Bool.self,  forKey: .debugHierarchical)     ?? false
        coherentPacketEnabled = try c.decodeIfPresent(Bool.self,  forKey: .coherentPacketEnabled) ?? false
        foveationStrength     = try c.decodeIfPresent(Float.self, forKey: .foveationStrength)     ?? 0.0
        smartAdvanceEnabled   = try c.decodeIfPresent(Bool.self,  forKey: .smartAdvanceEnabled)   ?? false
    }
}
