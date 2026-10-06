// sRGB encode for compute kernel output.
// Fragment shaders writing to bgra8Unorm_srgb attachments get hardware linear→sRGB
// encoding for free. Compute kernel writes bypass that hardware stage, so we apply
// the IEC 61966-2-1 piecewise function manually before writing.
FORCE_INLINE float3 linearToSRGB(float3 c) {
    c = saturate(c);
    float3 lo = c * 12.92;
    float3 hi = powr(c, float3(1.0 / 2.4)) * 1.055 - 0.055;
    return select(hi, lo, c < 0.0031308);
}

// Encode a shaded color for the compute kernel's drawable write.
// 8-bit sRGB targets need the manual transfer above; float (EDR) targets take
// LINEAR light directly — encoding there would double-apply the transfer AND
// saturate away the >1 highlight energy the display mapping just produced.
// `edrHeadroom > 1` is exact for "the compositor layer is rgba16Float" on the
// visionOS adaptive-compute path: Renderer stamps the headroom from the same
// layer color format that selects the drawable pixel format (see
// Renderer.displayEDRHeadroom / ContentStageConfiguration).
FORCE_INLINE float4 encodeComputeOutput(half3 col, constant ColorSchemeParams& scheme) {
    float3 c = float3(col);
    return float4(scheme.edrHeadroom > 1.001f ? max(c, 0.0f) : linearToSRGB(c), 1.0);
}
