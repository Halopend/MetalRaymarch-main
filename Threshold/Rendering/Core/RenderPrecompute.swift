import Foundation
import simd

/// Cross-platform CPU precomputation of frame-uniform shader values.
///
/// These pure functions are shared by every rendering backend — the visionOS
/// `Renderer` (via the `Renderer` extension in `RendererPrecomputeHelpers.swift`)
/// and the macOS/iOS `ThresholdMacRenderer` (in `RaymarchRenderView.swift`). The
/// `Precomputed*` result types come from the shared `ShaderTypes.h` bridging
/// header, so this file compiles unchanged on all targets and is the single
/// source of truth for the math. Computing these once per frame on the CPU
/// eliminates expensive per-pixel work on the GPU (e.g. `powr()`, divisions and
/// `CameraPath` trig).
enum RenderPrecompute {

    /// Perspective projection matrix (right-handed, reverse-Z to `[0, 1]`).
    static func makePerspectiveProjection(fovyRadians: Float, aspect: Float, nearZ: Float, farZ: Float) -> matrix_float4x4 {
        let yScale = 1.0 / tan(fovyRadians * 0.5)
        let xScale = yScale / aspect
        let zScale = farZ / (nearZ - farZ)
        let wzScale = nearZ * farZ / (nearZ - farZ)

        return matrix_float4x4(columns: (
            SIMD4<Float>(xScale, 0, 0, 0),
            SIMD4<Float>(0, yScale, 0, 0),
            SIMD4<Float>(0, 0, zScale, -1),
            SIMD4<Float>(0, 0, wzScale, 0)
        ))
    }

    /// Largest cone-marching footprint tolerance, in pixels, at `strength == 1`.
    /// The baseline march threshold (`fma(t, 0.0008, …)` in `Shaders.metal`) is
    /// already a ~1-pixel cone, so the strength slider has to push the footprint
    /// past a single pixel to reduce step counts. The cost is that each ray stops
    /// this many pixels short of the true surface, so the rendered isosurface
    /// inflates by ~`strength·coneMarchMaxPixels` pixels everywhere ("fattening").
    /// Kept modest so even full strength stays a gentle puff, not a balloon.
    static let coneMarchMaxPixels: Float = 6.0

    /// Cone-marching hit-threshold growth per unit ray distance.
    ///
    /// Returns the world-space radius of one ray's projected footprint at depth 1,
    /// widened to `strength · coneMarchMaxPixels` pixels (after Mansour's
    /// *ConeMarchingPen* stop test). In the march the acceptance threshold becomes
    /// `max(baseEpsilon, coneMarchScale · t)`, so distant geometry — where a pixel
    /// already spans many surface units — stops well short while near geometry
    /// keeps the full fixed-epsilon sharpness. Returns 0 (a no-op) at `strength == 0`
    /// or for degenerate inputs.
    ///
    /// `projection.columns.1.y` is `cot(fovY/2)` (the `yScale` of every perspective
    /// matrix this app builds, and of `computeProjection` on visionOS — its
    /// asymmetry shifts only the frustum center, not this per-pixel size), so one
    /// pixel's angular size is `2·tan(fovY/2) / viewportHeight`.
    static func coneMarchScale(strength: Float,
                               projection: matrix_float4x4,
                               viewportHeight: Float) -> Float {
        let s = max(0.0, min(1.0, strength))
        guard s > 0, viewportHeight > 1 else { return 0 }
        let cotHalfFovY = abs(projection.columns.1.y)   // = 1 / tan(fovY/2)
        guard cotHalfFovY > 1e-5 else { return 0 }
        let tanHalfFovY = 1.0 / cotHalfFovY
        let pixelFootprintPerDist = 2.0 * tanHalfFovY / viewportHeight
        return pixelFootprintPerDist * s * coneMarchMaxPixels
    }

    /// Precompute fractal parameters (eliminates per-pixel `powr()` and division).
    static func makePrecomputedFractal(from settings: RenderSettingsSnapshot) -> PrecomputedFractalParams {
        let invMinRad = 1.0 / settings.minDistance
        var scale = SIMD4<Float>(repeating: settings.fractalScale * invMinRad)
        scale.w = abs(scale.w)

        let absScalem1 = abs(settings.fractalScale - 1.0)
        let absScalePow = pow(max(abs(settings.fractalScale), 1e-6), Float(1 - settings.fractalIterations))
        let sphereRadiusSq = settings.sphereRadius * settings.sphereRadius

        return PrecomputedFractalParams(
            scale: scale,
            absScalem1: absScalem1,
            absScalePow: absScalePow,
            invSphereRadiusSq: 1.0 / sphereRadiusSq,
            sphereRadiusSq: sphereRadiusSq
        )
    }

    /// Sun direction endpoints for the vibrance/softness lighting blend.
    /// `sunDirSoft` is the original un-normalized direction (length ~0.44), which
    /// naturally softens shadows, diffuse, and specular; `sunDirSharp` is its
    /// normalized counterpart for crisper shadows and stronger specular. The
    /// blend between them is precomputed here (frame-uniform) and passed to the
    /// GPU, so the shaders no longer need their own copies.
    static let sunDirSoft = SIMD3<Float>(0.3235, 0.0924, 0.2773)
    static let sunDirSharp = SIMD3<Float>(0.7420, 0.2119, 0.6360)

    /// Precompute lighting parameters (eliminates per-pixel `CameraPath` trig
    /// and the per-pixel vibrance/softness sun blend, which are frame-uniform).
    static func makePrecomputedLighting(time: Float,
                                        lightingMode: LightingMode,
                                        audioLevel: Float,
                                        bassLevel: Float = 0,
                                        midLevel: Float = 0,
                                        trebleLevel: Float = 0,
                                        beatIntensity: Float = 0,
                                        vibrance: Float = 0,
                                        lightingSoftness: Float = 0) -> PrecomputedLighting {
        let gTime = time * 0.01 + 15.00

        let spotLightPosition: SIMD3<Float>
        let lightIntensity: Float

        switch lightingMode {
        case .staticLight:
            spotLightPosition = SIMD3<Float>(2.0, 1.5, 2.0)
            lightIntensity = 1.0
        case .audioReactive:
            // Enhanced: use per-band data for richer light animation
            let basePos = SIMD3<Float>(1.5, 1.0, 1.5)
            let bassAmplitude = max(audioLevel, bassLevel) * 2.0
            let trebleSpeed = 2.0 + trebleLevel * 4.0  // Treble drives orbit speed
            let audioOffset = SIMD3<Float>(
                sin(gTime * trebleSpeed) * bassAmplitude,
                midLevel * 2.0,  // Mids drive vertical
                cos(gTime * trebleSpeed) * bassAmplitude
            )
            spotLightPosition = basePos + audioOffset
            lightIntensity = 0.5 + audioLevel * 1.0 + bassLevel * 0.5
        case .visualizer:
            // Dramatic: position jumps on beats, wide orbits, intensity pulses with bass
            let beatJump = beatIntensity * 3.0
            let orbitSpeed = 1.5 + midLevel * 3.0
            let basePos = SIMD3<Float>(
                sin(gTime * orbitSpeed) * (2.0 + bassLevel * 2.0) + beatJump * sin(gTime * 8.0),
                1.0 + trebleLevel * 2.0 + beatIntensity * 1.5,
                cos(gTime * orbitSpeed) * (2.0 + bassLevel * 2.0) + beatJump * cos(gTime * 8.0)
            )
            spotLightPosition = basePos
            lightIntensity = 0.3 + bassLevel * 1.5 + beatIntensity * 0.5
        case .animated:
            let pathT = gTime + 0.03
            let path = SIMD3<Float>(
                -0.78 + 3.0 * sin(2.14 * pathT),
                0.05 + 2.5 * sin(0.942 * pathT + 1.3),
                0.05 + 3.5 * cos(3.594 * pathT)
            )
            let offset = SIMD3<Float>(
                sin(gTime * 18.4),
                cos(gTime * 17.98),
                sin(gTime * 22.53)
            ) * 0.2
            spotLightPosition = path + offset
            lightIntensity = 0.9 + sin(gTime * 1.5) * 0.15
        }

        // === Vibrance/softness blend (hoisted from per-pixel
        // computeBlendedLighting in Shaders.metal) ===
        // Current system: vibrance drives sun direction + intensity; classic
        // system: fixed direction/diffuse. lightingSoftness blends between.
        let clampedSoftness = min(max(lightingSoftness, 0), 1)
        let sunDirNew = Self.sunDirSoft + (Self.sunDirSharp - Self.sunDirSoft) * vibrance
        let intensityScaleNew: Float = 0.7 + (1.2 - 0.7) * vibrance
        let sunDir = sunDirNew + (Self.sunDirSoft - sunDirNew) * clampedSoftness
        let sunDiffuseScale: Float = 0.15 + (0.2 - 0.15) * clampedSoftness
        let intensityScale = intensityScaleNew + (1.0 - intensityScaleNew) * clampedSoftness
        let specPower: Float = 20.0 + (110.0 - 20.0) * (1.0 - clampedSoftness)

        return PrecomputedLighting(
            spotLightPosition: spotLightPosition,
            lightIntensity: lightIntensity * intensityScale,
            sunDir: sunDir,
            sunDiffuseScale: sunDiffuseScale,
            specPower: specPower,
            _padLighting: .zero
        )
    }

    /// Precompute audio aggregates (avoids repeated max/weighted sums on GPU).
    static func makePrecomputedAudio(from settings: RenderSettingsSnapshot) -> PrecomputedAudio {
        let bass = settings.bassLevel
        let mid = settings.midLevel
        let treble = settings.trebleLevel
        let beat = settings.beatIntensity
        let maxBand = max(bass, max(mid, treble))
        let weighted = bass * 0.6 + mid * 0.3 + treble * 0.1

        return PrecomputedAudio(
            bands: SIMD4<Float>(bass, mid, treble, beat),
            energy: SIMD2<Float>(maxBand, weighted),
            pad: .zero
        )
    }

    /// Precompute fog helpers (inverse intensity avoids divides on GPU).
    static func makePrecomputedFog(from settings: RenderSettingsSnapshot) -> PrecomputedFog {
        let fogIntensity = settings.fogEnabled ? settings.fogIntensity : 0.0
        let invFog = fogIntensity > 1e-6 ? 1.0 / fogIntensity : 0.0
        return PrecomputedFog(
            fog: SIMD4<Float>(fogIntensity, invFog, 0.0, 0.0),
            color: SIMD4<Float>(settings.fogColor.x, settings.fogColor.y, settings.fogColor.z, 0.0)
        )
    }
}
