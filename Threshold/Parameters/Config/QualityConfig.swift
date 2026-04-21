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
    // User-set base values
    var baseFractalIterations: Int = 9
    var baseMaxRaySteps: Int = 64

    // Resolution / tiling
    var resolutionScale: Float = 1.0   // 0.5 - 1.0
    var tileSize: Int = 0              // 0=disabled, 2/4/8 adaptive hierarchical

    // Debug
    var debugHierarchical: Bool = false

    // MARK: - Validation

    mutating func clamp() {
        baseFractalIterations = max(2, min(24, baseFractalIterations))
        baseMaxRaySteps = max(16, min(200, baseMaxRaySteps))
        resolutionScale = max(0.5, min(1.0, resolutionScale))
    }
}
