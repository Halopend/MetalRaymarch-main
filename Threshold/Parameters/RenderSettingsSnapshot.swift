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
    let foveationStrength: Float
    let smartAdvanceEnabled: Bool
    let coneMarchStrength: Float
    let distanceLODStrength: Float
    let shadowsEnabled: Bool
    let boundingSphereSkipEnabled: Bool
    let renderDistanceScale: Float
    let limitFlash: Float
    let activeGestureIndex: Int
    let safetyBubbleEnabled: Bool
    let safetyBubbleRadius: Float
    let safetyBubbleShape: Float
    let safetyBubbleFadeEnabled: Bool
    let safetyBubbleFadeWidth: Float
    let safetyBubbleStrength: Float
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

    /// Bounding sphere (model space) used by the empty-space-skip in the march.
    /// 0 disables it. When the experimental skip is enabled we feed a generous
    /// fixed radius: the box/bulb fractal families sit within a few model units of
    /// the origin, so this rarely clips while still letting rays that miss it (or
    /// approach from outside) skip the march. Sprawling families (Kleinian, large
    /// folds) may clip — hence experimental + off by default.
    var estimatedBoundingSphereRadius: Float {
        boundingSphereSkipEnabled ? 6.0 : 0.0
    }
}
