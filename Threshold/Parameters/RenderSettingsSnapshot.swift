import Foundation
import simd

// RenderSettings uses os_unfair_lock for minimal lock overhead
// This is the fastest synchronization primitive on Apple platforms
// NSLock has ~2-3x more overhead due to Objective-C dispatch
struct RenderSettingsSnapshot {
    let minDistance: Float
    let scale: Float
    let position: SIMD3<Float>
    let fractalScale: Float
    let fractalIterations: Int
    let maxRaySteps: Int
    let colorMix: Float
    let lightingPlay: Bool
    let lightingMode: LightingMode
    let sphericalInversionMode: SphericalInversionMode
    let sphericalInversionRadius: Float
    let sphereProjectionEnabled: Bool
    let sphereProjectionBlend: Float
    let sphereProjectionRadius: Float
    let spaceWarpStrength: Float
    let spaceWarpParam1: Float
    let spaceWarpParam2: Float
    let spaceWarpParam3: Float
    let spaceWarpAxis: SIMD3<Float>
    let spaceWarpStack: SpaceWarpStack
    let platformRadius: Float
    let platformEnabled: Bool
    let audioLevel: Float
    let bassLevel: Float
    let midLevel: Float
    let trebleLevel: Float
    let beatIntensity: Float
    let foldingLimit: Float
    let sphereRadius: Float
    let colorIterations: Float
    let resolutionScale: Float
    let fractalType: FractalModelType
    let formulaParams: FormulaParams
    let tileSize: Int
    let debugHierarchical: Bool
    let coherentPacketEnabled: Bool
    let computeTemporalReprojectionEnabled: Bool
    let coarsePrepassWarmStartEnabled: Bool
    let foveationStrength: Float
    let smartAdvanceEnabled: Bool
    let coneMarchStrength: Float
    let distanceLODStrength: Float
    let shadowsEnabled: Bool
    let boundingSphereSkipEnabled: Bool
    let boundingShapeRadius: Float
    let boundingShapeFogMode: Int
    let boundingShapeShadowDepth: Float
    let boundingShapeType: Float
    let zoomFogCompensationEnabled: Bool
    let limitFlash: Float
    let activeGestureIndex: Int
    let safetyBubbleEnabled: Bool
    let safetyBubbleRadius: Float
    let safetyBubbleShape: Float
    let safetyBubbleFadeEnabled: Bool
    let safetyBubbleFadeWidth: Float
    let safetyBubbleStrength: Float
    let safetyBubbleMixedAutoShrink: Bool
    let safetyBubbleMixedRadius: Float
    let handAttractionEnabled: Bool
    let handAttractionRadius: Float
    let handAttractionStrength: Float
    let handAttractionPocketEnabled: Bool
    let handAttractionBallScale: Float
    let handAttractionSoftness: Float
    let handAttractionPocketSize: Float
    let handAttractionPocketSoftness: Float
    let handAttractionProjectionDistance: Float
    let handAttractionForearmEnabled: Bool
    let handAttractionForearmRadius: Float
    let colorSchemeParams: ColorSchemeParams
    let lightingSoftness: Float
    
    // Fog for CPU precomputation (not sent to GPU in ColorSchemeParams)
    let fogEnabled: Bool
    let fogIntensity: Float
    let fogColor: SIMD3<Float>
    
    // Two-point grab world rotation + detail scale
    let worldRotation: simd_quatf
    let detailScale: Float

    // ═══════════════════════════════════════════════════════════════════════════
    // GEOMETRY STABILITY STATE
    // When geometry parameters settle, enables the stable-geometry heuristics
    // ═══════════════════════════════════════════════════════════════════════════
    let geometryState: GeometryState
    let isGeometryGestureActive: Bool

    // ═══════════════════════════════════════════════════════════════════════════
    // GMT-FRACTALS OPTIMIZATIONS
    // Step over-relaxation factor for raymarch convergence acceleration
    // ═══════════════════════════════════════════════════════════════════════════
    let stepMultiplier: Float

    // Spring blob navigation
    let springDisplacement: SIMD3<Float>
    let springActive: Bool
    let leftHandedMode: Bool
}

extension RenderSettingsSnapshot {
    /// Route only explicit 8x8 mode through the hierarchical compute path.
    var prefersAdaptiveComputePath: Bool {
        tileSize == 8
    }

    /// Bounding shape (sphere, model space) used by the march. 0 disables it.
    /// When enabled, rays that miss the sphere skip the march — bounding the
    /// visible fractal to the shape. The radius is user-set (Bounding Shape
    /// control); the 6.0 default is generous for box/bulb families, tighter
    /// values deliberately clip the fractal (e.g. for Mixed-immersion scenes).
    var estimatedBoundingSphereRadius: Float {
        boundingSphereSkipEnabled ? boundingShapeRadius : 0.0
    }
}
