FORCE_INLINE AdaptiveReprojectionResult evaluateAdaptiveReprojection(
    AdaptiveRayContext ray, uint2 viewportSize, uint2 viewportOrigin,
    constant TileUniforms& uniforms, constant rasterization_rate_map_data& rateMapData,
    texture2d_array<float, access::read> prevDepthTexture, FractalParams fractalParams,
    bool coherentPacketOn) {
    float3 cameraPos = ray.cameraPos;
    float3 rd = ray.direction;
    float3 marchOrigin = ray.origin;
    float3 marchDir = ray.marchDirection;
    int lodIterations = ray.iterations;
    int fractalType = uniforms.fractalType;
    // === TEMPORAL REPROJECTION: PER-PIXEL ===
    // Reproject this pixel to previous frame, sample previous depth,
    // and use it as startT to skip most of the fine raymarch.
    float reprojectedStartT = 0.0;
    float reprojectedDepth = -1.0;
    bool reprojectionValid = false;

    if (uniforms.temporalReprojectionEnabled) {
        // 1. Current pixel → model-space point at unit depth along ray
        //    We reconstruct a model-space point from the current pixel's ray,
        //    then project it through previousViewProjMatrix to find where
        //    it appeared last frame.
        //
        //    Strategy: project cameraPos + rd * testDepth into previous frame's
        //    clip space, look up previous depth at that UV, then use as startT.
        //    Since we don't know the depth yet, we use the previous frame's depth
        //    at the reprojected UV as the starting guess.

        // 2. Reconstruct previous-frame UV from current pixel:
        //    Take the current ray direction, build a model-space point at
        //    a reference depth (e.g., 1.0), project through prevVP to get
        //    previous UV. This is approximate but works well for small motions.
        float3 refPoint = cameraPos + rd * 1.0;
        float2 prevUV = reprojectToPrevUV(refPoint, uniforms);  // Metal texture convention (Y flipped)

        // 3. Check if the reprojected UV is within bounds
        if (prevUV.x >= 0.0 && prevUV.x <= 1.0 && prevUV.y >= 0.0 && prevUV.y <= 1.0) {
            // Sample previous depth at the reprojected location. prevUV is in
            // SCREEN space; the depth texture is in PHYSICAL space, so decode.
            uint2 prevPixel = uint2(screenUVToPhysicalPixel(prevUV, uniforms, rateMapData));
            prevPixel = clamp(prevPixel, uint2(0), viewportSize - 1);
            prevPixel += viewportOrigin;
            float prevDepth = prevDepthTexture.read(prevPixel, uniforms.eyeIndex).x;

            if (prevDepth > 0.0 && prevDepth < kRayMissThreshold) {
                // 4. Iterative refinement: reproject with the sampled depth
                //    to get a more accurate UV, then re-sample.
                float3 betterPoint = cameraPos + rd * prevDepth;
                float2 betterUV = reprojectToPrevUV(betterPoint, uniforms);

                if (betterUV.x >= 0.0 && betterUV.x <= 1.0 && betterUV.y >= 0.0 && betterUV.y <= 1.0) {
                    uint2 betterPixel = uint2(screenUVToPhysicalPixel(betterUV, uniforms, rateMapData));
                    betterPixel = clamp(betterPixel, uint2(0), viewportSize - 1);
                    betterPixel += viewportOrigin;
                    float refinedDepth = prevDepthTexture.read(betterPixel, uniforms.eyeIndex).x;

                    if (refinedDepth > 0.0 && refinedDepth < kRayMissThreshold) {
                        prevDepth = refinedDepth;
                    }
                }

                // 5. Apply safety margin — back up 10% to avoid starting past the surface.
                //    This ensures we never miss geometry that moved slightly closer.
                reprojectedDepth = prevDepth;
                reprojectedStartT = prevDepth * 0.9;
                reprojectionValid = true;
            }
        }
    }

    // === PER-PIXEL WARM-START SAFETY PROBE ===
    // The legacy `prevDepth * 0.9` heuristic assumes DE monotonicity along the ray.
    // Fractal DEs (Mandelbulb / Mandelbox) are LOCALLY non-monotone: they decrease
    // into a fold then increase past it, so a fixed 10% backoff happily steps past
    // disocclusion-exposed surfaces.
    //
    // Replacement: a single MapUnified evaluation at the predicted t. Three outcomes:
    //   • h < hitThreshold    → surface confirmed; restart just before it so the
    //                            fine march terminates in a few refinement steps.
    //   • h > backoffMargin   → safely outside; tighten startT to (t - h), which
    //                            is GUARANTEED conservative by Lipschitz-1.
    //   • otherwise            → reject reprojection; fall back to coarse pass.
    //
    // Cost: 1 DE eval per temporally warm-started pixel. Saves the entire coarse
    // search and potentially the entire fine march. Failure is silent: we use the
    // full near-plane march. Validation is independent of the optional coherent-
    // packet shadow/debug experiment so every temporal start takes this path.
    //
    // packetLayer is a per-pixel debug tag for the layer-of-acceptance overlay:
    //   0 = unset / fell through to coarse-tile path
    //   1 = coherent-packet warm-start ACCEPTED as immediate hit (best case)
    //   2 = coherent-packet warm-start ACCEPTED as tight startT
    //   3 = coherent-packet warm-start REJECTED (probe found no surface near prediction)
    int packetLayer = 0;
    if (reprojectionValid) {
        float t_pred = reprojectedDepth;
        bool packetIsMandelbulb = (fractalType == FractalTypeMandelbulb ||
                                   fractalType == FractalTypeMandelbulbJulia ||
                                   fractalType == FractalTypeBoxFoldMandelbulb);
        // Hit threshold mirrors the fine-march acceptance gate so a probe-hit is
        // bit-for-bit consistent with what SceneWithCacheFromStart would accept.
        float probeHitThreshold = packetIsMandelbulb
            ? fma(t_pred, 0.0002f, 0.00012f)
            : fma(t_pred, 0.0008f, 0.0005f);
        // Backoff margin: distance below which we DON'T trust (t - h) as a safe
        // start (we may be inside a fold). Tuned conservatively per fractal.
        float probeBackoffMargin = packetIsMandelbulb ? 0.004f : 0.012f;

        float3 probeP = marchOrigin + marchDir * t_pred;
        float h_probe = MapUnified(probeP, fractalParams, uniforms.foldingLimit, lodIterations, fractalType, uniforms.formulaParams);

        if (h_probe < probeHitThreshold) {
            // Surface confirmed at the predicted depth. Don't skip the fine march
            // entirely — if we did, glow accumulation would be 0 here while neighbor
            // pixels (green/red layers) accumulate real proximity-glow during their
            // fine march, producing a visible seam. Instead, start the fine march
            // just behind the probe so it terminates in ~1-3 steps and shading is
            // bit-identical to the legacy path.
            //
            // Backoff distance: max(probeHitThreshold * 6, 0.5% of t_pred) keeps the
            // restart safely outside the hit band even with non-monotone DEs.
            // BUT SceneWithCacheFromStart only searches a FIXED [start, start + 2]
            // window (see its `endT`), and this kernel has no full-march fallback on
            // a warm-start miss (unlike fragmentMain's `needFullMarch`). A backoff
            // > 2 therefore starts the window entirely BEHIND the surface the probe
            // just confirmed -> guaranteed miss -> background, and because that miss
            // writes miss depth, the next frame reprojects from a miss, runs the
            // full march, and the frame after flips back: a 2-frame hit/miss flicker
            // plus repeated full-range marches. 0.5% of t_pred exceeds 2 only past
            // t_pred ≈ 400, which is reachable ONLY for the Kleinian family
            // (RendererGameState lifts its horizon cap to 420, and to 880 zoomed
            // out; every other family caps at 80, where the backoff is ≤ 0.4). Clamp
            // so the confirmed surface is always inside the restart window.
            float restartBackoff = min(max(probeHitThreshold * 6.0f, t_pred * 0.005f), 1.0f);
            reprojectedStartT = max(0.05f, t_pred - restartBackoff);
            if (coherentPacketOn) packetLayer = 1;
        } else if (h_probe > probeBackoffMargin) {
            // Safely outside surface. (t - h) is Lipschitz-conservative.
            reprojectedStartT = max(0.05f, t_pred - h_probe);
            if (coherentPacketOn) packetLayer = 2;
        } else {
            // Inside the unsafe band — could be a fold. Reject; let coarse pass run.
            reprojectionValid = false;
            reprojectedStartT = 0.0;
            if (coherentPacketOn) packetLayer = 3;
        }
    }

    return {reprojectedStartT, reprojectedDepth, reprojectionValid, packetLayer};
}
