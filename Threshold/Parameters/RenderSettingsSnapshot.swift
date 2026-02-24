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
    let audioSource: Int32
    let bassSensitivity: Float
    let midSensitivity: Float
    let trebleSensitivity: Float
    let beatSensitivity: Float
    let fractalAudioReactiveEnabled: Bool
    let fractalAudioAmount: Float
    let fractalBeatPunch: Float
    let fractalAudioAffectsScale: Bool
    let fractalAudioAffectsFolding: Bool
    let fractalAudioAffectsRadius: Bool
    let fractalAudioAffectsColorMix: Bool
    let foldingLimit: Float
    let sphereRadius: Float
    let colorIterations: Float
    let resolutionScale: Float
    let fractalType: FractalModelType
    let tileSize: Int
    let useHierarchical: Bool
    let debugHierarchical: Bool
    let limitFlash: Float
    let showHUD: Bool
    let activeGestureIndex: Int
    let gestureSpread: Float
    let safetyBubbleEnabled: Bool
    let safetyBubbleRadius: Float
    let safetyBubbleShape: Float
    let sphereProjectionMode: Int  // 0=off, 1=outward, 2=inward, 3=intersection, 4=animated, 5=octree, 6=layered, 7=spiral
    let colorSchemeParams: ColorSchemeParams
    let lightingSoftness: Float

    // ═══════════════════════════════════════════════════════════════════════════
    // DOPPELGANGER MODE
    // Pre-fold reflection that creates an exact structural twin of the fractal
    // ═══════════════════════════════════════════════════════════════════════════
    let doppelgangerEnabled: Bool
    let doppelgangerPlane: SIMD3<Float>   // Mirror plane normal (normalized)
    let doppelgangerOffset: Float         // Signed distance of mirror plane from origin

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
