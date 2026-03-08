import Foundation

extension Renderer {
    // MARK: - Shared Precomputation Helpers

    /// Precompute fractal parameters on CPU (eliminates per-pixel powr() and division on GPU)
    static func makePrecomputedFractal(from settings: RenderSettingsSnapshot) -> PrecomputedFractalParams {
        let minRad2 = settings.minDistance
        let fractalScale = settings.fractalScale
        let sphereRadius = settings.sphereRadius
        let iterations = settings.fractalIterations

        let invMinRad = 1.0 / minRad2
        var scale = SIMD4<Float>(repeating: fractalScale * invMinRad)
        scale.w = abs(scale.w)

        let absScalem1 = abs(fractalScale - 1.0)
        let absScalePow = pow(max(abs(fractalScale), 1e-6), Float(1 - iterations))
        let sphereRadiusSq = sphereRadius * sphereRadius
        let invSphereRadiusSq = 1.0 / sphereRadiusSq

        return PrecomputedFractalParams(
            scale: scale,
            absScalem1: absScalem1,
            absScalePow: absScalePow,
            invSphereRadiusSq: invSphereRadiusSq,
            sphereRadiusSq: sphereRadiusSq
        )
    }

    /// Precompute lighting parameters on CPU (eliminates per-pixel CameraPath trig on GPU)
    static func makePrecomputedLighting(time: Float, lightingMode: LightingMode, audioLevel: Float, bassLevel: Float = 0, midLevel: Float = 0, trebleLevel: Float = 0, beatIntensity: Float = 0) -> PrecomputedLighting {
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

        return PrecomputedLighting(
            spotLightPosition: spotLightPosition,
            lightIntensity: lightIntensity
        )
    }

    /// Precompute audio aggregates for shader use (avoids repeated max/weighted sums).
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
        let fogIntensity = settings.fogIntensity
        let invFog = fogIntensity > 1e-6 ? 1.0 / fogIntensity : 0.0
        return PrecomputedFog(
            fog: SIMD4<Float>(fogIntensity, invFog, 0.0, 0.0)
        )
    }

}
