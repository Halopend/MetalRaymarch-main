// ─────────────────────────────────────────────────────────────────────────────
// RCAS — Robust Contrast Adaptive Sharpening (AMD FSR 1.0)
// Applied inline during the MetalFX resolve pass to recover detail lost in the
// spatial upscale. 5-tap cross, noise-adaptive negative lobe, neighbourhood-
// clamped to prevent haloing. Zero extra render passes — runs in the existing
// resolve fragment shader.
// ─────────────────────────────────────────────────────────────────────────────
static inline float3 rcasSharpen(
    texture2d_array<float> tex,
    float2 uv,
    float2 rcpSize,   // 1.0 / float2(tex.width, tex.height)
    uint   eye,
    float  strength   // 0.0 = off, 1.0 = max adaptive sharpening
) {
    constexpr sampler s(filter::nearest, address::clamp_to_edge);

    // 5-tap cross neighbourhood.
    // Pre-clamp the off-centre taps to the texel-centre interior so the sampler
    // never has to hardware-clamp an out-of-range coordinate. This sidesteps a
    // Metal driver bug (FB172520325 / 177318505, notably Apple-family-10 GPUs)
    // where a clamp-to-edge read can return ZERO instead of the edge texel — here
    // that would feed black into the anti-ring clamp and leave a dark fringe on
    // the outermost pixel row/column. With nearest filtering, clamping to the
    // texel-centre range is identical to working clamp-to-edge on healthy GPUs.
    float2 lo = rcpSize * 0.5;
    float2 hi = 1.0 - lo;
    float3 b = tex.sample(s, clamp(uv + float2( 0.0,       -rcpSize.y), lo, hi), eye).rgb;
    float3 d = tex.sample(s, clamp(uv + float2(-rcpSize.x,  0.0      ), lo, hi), eye).rgb;
    float3 e = tex.sample(s, uv,                                                 eye).rgb;
    float3 f = tex.sample(s, clamp(uv + float2( rcpSize.x,  0.0      ), lo, hi), eye).rgb;
    float3 h = tex.sample(s, clamp(uv + float2( 0.0,        rcpSize.y), lo, hi), eye).rgb;

    // Luma weights — perceptual (2G + R + B unnormalised, consistent with FSR)
    const float3 kLuma = float3(0.5, 1.0, 0.5);
    float bL = dot(b, kLuma), dL = dot(d, kLuma), eL = dot(e, kLuma);
    float fL = dot(f, kLuma), hL = dot(h, kLuma);

    // Neighbourhood min/max for anti-ringing clamp
    float3 mn4 = min(min(b, d), min(f, h));
    float3 mx4 = max(max(b, d), max(f, h));

    // Noise suppression: reduce sharpening in near-flat or high-frequency regions
    float maxL = max(max(bL, dL), max(fL, hL));
    float minL = min(min(bL, dL), min(fL, hL));
    float nz   = abs(0.25 * (bL + dL + fL + hL) - eL) / max(maxL - minL, 1.0 / 255.0);
    float ns   = saturate(1.0 - nz);  // 1 = smooth region (sharpen more), 0 = noisy (back off)

    // Negative lobe weight, max -0.125 to prevent overshoot / ringing
    float w = max(-0.125, -0.125 * strength * ns);

    // 5-tap sharp: centre positive, neighbours negative
    float3 result = (b + d + f + h) * w + e * (1.0 + 4.0 * (-w));

    // Clamp to neighbourhood to prevent haloing
    return clamp(result, min(mn4, e), max(mx4, e));
}
