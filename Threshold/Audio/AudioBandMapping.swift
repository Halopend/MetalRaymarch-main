import Foundation

/// One shared implementation of the band-level mapping the visionOS Renderer,
/// the Mac/iPad RaymarchRenderView, and the Music tab meters all apply
/// (tech debt #26: this shape was implemented ×3 and drifted — the Mac path
/// guarded non-finite features while the visionOS path and the meters did not).
///
/// The contract every consumer previously hand-rolled:
/// `clamp01(feature × sensitivity)`, zeroed when either input is non-finite.
/// `RenderSettings` sensitivity setters already clamp on set; the guard here
/// covers the feature side and the product overflow. Keeping it in one place
/// means the meters provably display the levels the renderer consumes.
enum AudioBandMapping {
    /// Scale one audio feature by its sensitivity, clamped to 0...1.
    /// Non-finite inputs (or a non-finite product) map to 0, never NaN —
    /// a NaN reaching `RenderSettings` band fields would poison the uniform
    /// buffer and break the frame on every platform.
    static func scaledLevel(_ feature: Float, sensitivity: Float) -> Float {
        guard feature.isFinite, sensitivity.isFinite else { return 0 }
        let product = feature * sensitivity
        guard product.isFinite else { return 0 }
        return min(1.0, max(0.0, product))
    }
}
