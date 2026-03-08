//
//  QualityConfig.swift
//  Threshold
//
//  Domain config: iteration counts, ray steps, dynamic quality, and
//  sphere-tracing refinement parameters.
//  Part of the RenderSettings decomposition (Phase 1).
//

import Foundation

struct QualityConfig: Codable, Equatable, Sendable {
    // User-set base values (before dynamic quality adjustment)
    var baseFractalIterations: Int = 9
    var baseMaxRaySteps: Int = 64

    // Resolution / tiling
    var resolutionScale: Float = 1.0   // 0.5 - 1.0
    var tileSize: Int = 0              // 0=disabled, 2/4/8 adaptive hierarchical

    // Halton jitter temporal AA
    var haltonJitterEnabled: Bool = true

    // Dynamic render quality (WWDC25 Session 294)
    var dynamicRenderQualityEnabled: Bool = true
    var dynamicRenderQualityTarget: Float = 0.7   // 0.5 - 1.0
    var dynamicRenderQualityMin: Float = 0.5      // 0.4 - 0.8
    var dynamicRenderQualityMax: Float = 1.0      // 0.8 - 1.0

    // Sphere-tracing refinement (Polychronakis 2024 / Keinert 2014)
    var relaxFactor: Float = 1.6            // Over-relaxation multiplier (1.0 - 2.0)
    var relaxBacktrack: Float = 0.7         // Backtrack factor (0.5 - 1.0)
    var sdfScaleCoarse: Float = 1.3         // SDF scaling coarse pass (1.0 - 2.0)
    var sdfScaleSuperCoarse: Float = 1.5    // SDF scaling super-coarse pass (1.0 - 2.5)
    var earlyTermRatio: Float = 0.3         // Early termination ratio (0.1 - 0.5)
    var earlyTermCount: Int = 3             // Steps before early termination (1 - 5)

    // Debug
    var debugHierarchical: Bool = false

    // MARK: - Validation

    mutating func clamp() {
        baseFractalIterations = max(2, min(24, baseFractalIterations))
        baseMaxRaySteps = max(16, min(256, baseMaxRaySteps))
        resolutionScale = max(0.5, min(1.0, resolutionScale))
        dynamicRenderQualityTarget = max(0.5, min(1.0, dynamicRenderQualityTarget))
        dynamicRenderQualityMin = max(0.4, min(0.8, dynamicRenderQualityMin))
        dynamicRenderQualityMax = max(0.8, min(1.0, dynamicRenderQualityMax))
        relaxFactor = max(1.0, min(2.0, relaxFactor))
        relaxBacktrack = max(0.5, min(1.0, relaxBacktrack))
        sdfScaleCoarse = max(1.0, min(2.0, sdfScaleCoarse))
        sdfScaleSuperCoarse = max(1.0, min(2.5, sdfScaleSuperCoarse))
        earlyTermRatio = max(0.1, min(0.5, earlyTermRatio))
        earlyTermCount = max(1, min(5, earlyTermCount))
    }
}
