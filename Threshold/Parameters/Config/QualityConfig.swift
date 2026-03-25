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

    // Dynamic render quality (WWDC25 Session 294)
    var dynamicRenderQualityEnabled: Bool = true
    var dynamicRenderQualityTarget: Float = 0.7   // 0.5 - 1.0
    var dynamicRenderQualityMin: Float = 0.5      // 0.4 - 0.8
    var dynamicRenderQualityMax: Float = 1.0      // 0.8 - 1.0

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
    }
}
