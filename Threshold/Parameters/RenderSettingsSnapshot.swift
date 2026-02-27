import Foundation

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
    let visualizerMode: Int32
    let visualizerIntensity: Float
    let foldingLimit: Float
    let sphereRadius: Float
    let colorIterations: Float
    let resolutionScale: Float
    let fractalType: FractalModelType
    let formulaParams: FormulaParams
    let tileSize: Int
    let debugHierarchical: Bool
    let limitFlash: Float
    let showHUD: Bool
    let activeGestureIndex: Int
    let gestureSpread: Float
    let safetyBubbleEnabled: Bool
    let safetyBubbleRadius: Float
    let safetyBubbleShape: Float
    let colorSchemeParams: ColorSchemeParams
    let lightingSoftness: Float

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
