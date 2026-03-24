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
    
    // Two-point grab world rotation + detail scale
    let worldRotation: simd_quatf
    let detailScale: Float

    // ═══════════════════════════════════════════════════════════════════════════
    // GEOMETRY STABILITY STATE
    // When geometry parameters settle, enables optimized "stable geometry" render path
    // ═══════════════════════════════════════════════════════════════════════════
    let geometryState: GeometryState
    let isGeometryGestureActive: Bool

    // ═══════════════════════════════════════════════════════════════════════════
    // GMT-FRACTALS OPTIMIZATIONS
    // Step over-relaxation factor for raymarch convergence acceleration
    // ═══════════════════════════════════════════════════════════════════════════
    let stepMultiplier: Float
}

extension RenderSettingsSnapshot {
    /// Route explicit performance tile modes through the hierarchical compute path.
    var prefersAdaptiveComputePath: Bool {
        switch tileSize {
        case 8, 4:
            return true
        default:
            return false
        }
    }

    /// Disabled until the bound is calibrated against real scene extents.
    var estimatedBoundingSphereRadius: Float {
        0.0
    }
}
