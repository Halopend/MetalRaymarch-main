//
//  FunctionConstantIndices.swift
//  Threshold
//
//  Swift names for the function-constant map whose numeric source of truth is
//  ShaderTypes.h. Keeping the values in the shared C/Metal header makes every
//  app, Quick Look, benchmark, and shader target consume the same indices.
//

extension FunctionConstantIndex {
    static let fractalIterations = Self.FCIndexFractalIterations
    static let shadowIterations = Self.FCIndexShadowIterations
    static let safetyBubbleEnabled = Self.FCIndexSafetyBubbleEnabled
    static let hasSpaceWarp = Self.FCIndexHasSpaceWarp
    static let qualityMode = Self.FCIndexQualityMode
    static let debugHierarchical = Self.FCIndexDebugHierarchical
    static let maxRaySteps = Self.FCIndexMaxRaySteps
    static let fractalType = Self.FCIndexFractalType
    static let neonModeEnabled = Self.FCIndexNeonModeEnabled
    static let colorIterations = Self.FCIndexColorIterations
    static let shareShadows = Self.FCIndexShareShadows
    static let shadowsEnabled = Self.FCIndexShadowsEnabled
    static let mandelbulbPower = Self.FCIndexMandelbulbPower
    static let warmStart = Self.FCIndexWarmStart
    static let coherentPacketEnabled = Self.FCIndexCoherentPacket
    static let coarseWarmStart = Self.FCIndexCoarseWarmStart
    static let hasEnvScrunch = Self.FCIndexHasEnvScrunch
    static let sphereProjectionEnabled = Self.FCIndexSphereProjection
    static let hasHandField = Self.FCIndexHasHandField

    static let shaderSpecializationCases: [Self] = [
        .fractalIterations, .shadowIterations, .safetyBubbleEnabled,
        .hasSpaceWarp, .qualityMode, .debugHierarchical, .maxRaySteps,
        .fractalType, .neonModeEnabled, .colorIterations, .shareShadows,
        .shadowsEnabled, .mandelbulbPower, .warmStart,
        .coherentPacketEnabled, .coarseWarmStart, .hasEnvScrunch,
        .sphereProjectionEnabled, .hasHandField,
    ]
}
