import Foundation

extension Renderer {
    // MARK: - Shared Precomputation Helpers
    //
    // The actual math lives in the cross-platform `RenderPrecompute` namespace so
    // the visionOS and macOS/iOS renderers share one source of truth. These thin
    // wrappers preserve the `Self.makePrecomputed*` call sites used by
    // `RendererGameState`.

    static func makePrecomputedFractal(from settings: RenderSettingsSnapshot) -> PrecomputedFractalParams {
        RenderPrecompute.makePrecomputedFractal(from: settings)
    }

    static func makePrecomputedLighting(time: Float, lightingMode: LightingMode, audioLevel: Float, bassLevel: Float = 0, midLevel: Float = 0, trebleLevel: Float = 0, beatIntensity: Float = 0) -> PrecomputedLighting {
        RenderPrecompute.makePrecomputedLighting(time: time,
                                                 lightingMode: lightingMode,
                                                 audioLevel: audioLevel,
                                                 bassLevel: bassLevel,
                                                 midLevel: midLevel,
                                                 trebleLevel: trebleLevel,
                                                 beatIntensity: beatIntensity)
    }

    static func makePrecomputedAudio(from settings: RenderSettingsSnapshot) -> PrecomputedAudio {
        RenderPrecompute.makePrecomputedAudio(from: settings)
    }

    static func makePrecomputedFog(from settings: RenderSettingsSnapshot) -> PrecomputedFog {
        RenderPrecompute.makePrecomputedFog(from: settings)
    }
}
