// === macOS temporal-upscaling motion vectors (Stage B) ===
// Separate Mac-only pass that reconstructs each pixel's world position from the
// raymarch's offscreen depth (clipPos.z/clipPos.w, standard 0..1) and reprojects
// it through the previous frame's view-projection to produce a screen-space
// motion vector for MTLFXTemporalScaler. Deliberately avoids touching the shared
// `Uniforms`/`fragmentMain` — the matrices arrive in a dedicated small buffer.
//
// `currentInvViewProj` is the inverse of the JITTERED current view-projection
// (matching the jittered depth), so the recovered world point is exact. Motion
// is then computed from the UN-jittered current/previous view-projections so the
// vector carries pure geometric motion (MetalFX handles jitter separately).
struct MacMotionParams {
    float4x4 currentInvViewProj;        // inverse(jittered P*MV) — depth → world
    float4x4 currentViewProjNoJitter;   // un-jittered current P*MV
    float4x4 previousViewProjNoJitter;  // un-jittered previous P*MV
};

fragment float2 macMotionFragment(MacBlitVertexOut in [[stage_in]],
                                  depth2d<float> depthTex [[texture(0)]],
                                  constant MacMotionParams& params [[buffer(0)]]) {
    constexpr sampler depthSampler(mag_filter::nearest, min_filter::nearest,
                                   address::clamp_to_edge);
    float depth = depthTex.sample(depthSampler, in.texCoord);

    // Standard-depth Mac/iPad misses sit at the far plane. Avoid reconstructing
    // exactly at infinity. But ZERO motion is wrong: under camera rotation the
    // sky/fog visibly slides across the screen, and telling MetalFX "this
    // pixel didn't move" makes it blend history from the wrong direction —
    // smeared, ghosted silhouettes against the background. Reproject a far
    // point along this pixel's view ray instead (clamp depth toward the far
    // plane) so rotation tracks the background and history stays sharp.
    // (Same policy as ThresholdKit's march_offscreen aux path: a miss uses
    // the far point along the ray.)
    // The shader writes misses at exactly 1 - 1e-6. A broad 0.9999 cutoff also
    // classified valid distant geometry (roughly 83+ world units) as sky.
    // Keep the test close to the explicit sentinel; visible geometry is capped
    // below the projection far plane by the renderer.
    if (depth > (1.0f - 1.5e-6f)) {
        depth = 0.9999;
    }

    // texCoord (origin top-left) → NDC.
    float2 ndc = float2(in.texCoord.x * 2.0 - 1.0, 1.0 - in.texCoord.y * 2.0);
    float4 worldH = params.currentInvViewProj * float4(ndc, depth, 1.0);
    float3 world = worldH.xyz / worldH.w;

    float4 curC = params.currentViewProjNoJitter * float4(world, 1.0);
    float4 prevC = params.previousViewProjNoJitter * float4(world, 1.0);
    float2 curN = curC.xy / curC.w;
    float2 prevN = prevC.xy / prevC.w;

    // NDC delta → UV delta (0..1). MetalFX `motionVectorScale` multiplies by the
    // input pixel dimensions to recover pixels. Y is flipped for texture space.
    // MetalFX expects a vector from the current pixel to where that pixel lived
    // in the previous color frame. current - previous points the wrong way and
    // turns camera motion into temporal smearing/edge breakup.
    float2 motionNDC = prevN - curN;
    return float2(motionNDC.x * 0.5, -motionNDC.y * 0.5);
}
