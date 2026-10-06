// Adaptive 8x8 orchestration. Keep lane masking, shared-state publication, and
// all threadgroup barriers here; the inline phase helpers contain no barriers.
kernel void adaptiveHierarchical8x8(
    uint2 tileId [[threadgroup_position_in_grid]],
    uint2 localId [[thread_position_in_threadgroup]],
    uint localIndex [[thread_index_in_threadgroup]],
    constant TileUniforms& uniforms [[buffer(0)]],
    constant rasterization_rate_map_data& rateMapData [[buffer(1)]],
    texture2d_array<float, access::write> outputTexture [[texture(0)]],
    texture2d_array<float, access::read> prevDepthTexture [[texture(1)]],
    texture2d_array<float, access::write> curDepthTexture [[texture(2)]]
) {
    uint2 rawViewportPixelCoord = tileId * ADAPTIVE_TILE_SIZE + localId;
    uint2 viewportSize = uint2(uniforms.resolution);

    // The dispatch rounds up to whole 8x8 threadgroups. Edge groups therefore
    // contain lanes outside a non-multiple-of-8 viewport, but every lane still
    // has to reach every threadgroup barrier below. Returning only those lanes
    // is undefined Metal behavior and can hang the GPU. Keep them alive using a
    // clamped, read-safe coordinate, then mask their texture writes.
    if (viewportSize.x == 0 || viewportSize.y == 0) return; // group-uniform
    const bool laneInBounds = rawViewportPixelCoord.x < viewportSize.x
                           && rawViewportPixelCoord.y < viewportSize.y;
    uint2 viewportPixelCoord = min(rawViewportPixelCoord, viewportSize - uint2(1));

    uint2 viewportOrigin = uint2(uniforms.viewportOrigin);
    uint2 pixelCoord = viewportOrigin + viewportPixelCoord;

    AdaptiveRayContext ray = makeAdaptiveRay(tileId, viewportPixelCoord, viewportSize, uniforms, rateMapData);
    float2 pixelCenter = ray.pixelCenter;
    float3 cameraPos = ray.cameraPos;
    float3 rd = ray.direction;
    float3 marchOrigin = ray.origin;
    float3 marchDir = ray.marchDirection;
    int lodIterations = ray.iterations;
    int fractalType = uniforms.fractalType;

    // Use precomputed fractal params (powr() and divisions done on CPU)
    FractalParams fractalParams = makeAdaptiveFractalParams(uniforms, marchOrigin);

    const bool coherentPacketOn = is_function_constant_defined(FC_COHERENT_PACKET)
        ? FC_COHERENT_PACKET : (uniforms.coherentPacketEnabled != 0);
    AdaptiveReprojectionResult reprojection = evaluateAdaptiveReprojection(
        ray, viewportSize, viewportOrigin, uniforms, rateMapData, prevDepthTexture,
        fractalParams, coherentPacketOn);
    int packetLayer = reprojection.packetLayer;

    // === SHARED TILE STATE ===
    threadgroup float tileStartT;
    threadgroup int tileIsEmpty;       // 1 = entire tile missed, skip fine march
    threadgroup half tg_shaSpot;       // Shared spotlight shadow (1 eval per tile)
    threadgroup half tg_shaSun;        // Shared sun shadow (1 eval per tile)
    // Coherent-packet Stage 3: anchor's surface frame for normal-coherence gate.
    // NOTE: threadgroup vars cannot be reliably initialized in their declaration
    // in Metal — initialize from thread 0 then barrier so all lanes see the value.
    threadgroup float3 tg_anchorPos;
    threadgroup float3 tg_anchorNormal;
    threadgroup int tg_anchorHasHit;
    if (localIndex == 0) {
        tileStartT = 0.05f;
        tileIsEmpty = 0;
        tg_shaSpot = 0.0h;
        tg_shaSun = 0.0h;
        tg_anchorPos = float3(0.0f);
        tg_anchorNormal = float3(0.0f, 1.0f, 0.0f);
        tg_anchorHasHit = 0;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    // === COARSE PASS + EMPTY-SPACE EARLY EXIT ===
    // Thread 0 does a coarse raymarch to find approximate start distance.
    // If the coarse distance is far beyond the tile diagonal, the tile is empty
    // and all 64 threads skip the expensive fine march.
    //
    // OPTIMIZATION: When thread 0 has valid temporal reprojection, skip the
    // coarse pass entirely — we already know the surface is near reprojectedStartT.
    // This saves a 24-step SceneCoarse + 2 MapContinuous probes (~50 Map evals).
    if (localIndex == 0) {
        AdaptiveTileCullResult tile = evaluateAdaptiveTileBoundsAndStart(
            tileId, viewportSize, viewportOrigin, ray, reprojection, uniforms,
            rateMapData, prevDepthTexture);
        tileStartT = tile.startT;
        tileIsEmpty = tile.isEmpty;
    }

    threadgroup_barrier(mem_flags::mem_threadgroup);

    // === EMPTY-SPACE EARLY EXIT ===
    // If the coarse pass determined the tile is empty, write background and return.
    // Saves ALL 64 fine raymarches — huge win for tiles that miss.
    if (tileIsEmpty) {
        // Apply minimal fog/glow for background consistency
        half3 col = half3(0.0h);
        col = applyFog(col, kRayMissThreshold + 100.0, uniforms.precomputedFog);
        col = clampColor(col);
        half2 texCoord = half2(pixelCenter / uniforms.resolution);
        col = PostEffectsWithScheme(col, texCoord, uniforms.colorScheme, uniforms.precomputedAudio, half(uniforms.limitFlash), 0.0h);
        FloorCircleHit floorHit = evaluateFloorCircle(cameraPos, rd, kRayMissThreshold + 100.0f, uniforms.floorPlane, uniforms.floorCenterRadius);
        col = compositeFloorCircle(col, floorHit);
        float4 currentColor = encodeComputeOutput(col, uniforms.colorScheme);
        if (laneInBounds) {
            outputTexture.write(currentColor, pixelCoord, uniforms.eyeIndex);
            // Write miss depth so next frame knows this pixel was empty
            curDepthTexture.write(float4(kRayMissThreshold + 100.0, 0, 0, 0), pixelCoord, uniforms.eyeIndex);
        }
        return;
    }

    SceneResult sceneResult = marchAdaptiveRay(ray, reprojection, tileStartT, uniforms, fractalParams);

    float adjustedDist = sceneResult.distGlow.x;
    float glow = sceneResult.distGlow.y;
    OrbitCache hitCache = sceneResult.cache;
    half3 col = half3(0.0h);

    // Write current frame depth for next frame's temporal reprojection
    float depthToWrite = (adjustedDist < kRayMissThreshold) ? adjustedDist : (kRayMissThreshold + 100.0);
    if (laneInBounds) {
        curDepthTexture.write(float4(depthToWrite, 0, 0, 0), pixelCoord, uniforms.eyeIndex);
    }

    // === PER-LANE HIT STATE (computed for EVERY lane before the shared-shadow barrier) ===
    // Hit/miss is a per-pixel property of this lane's march. We must NOT branch on it
    // before the threadgroup_barrier below, or lanes whose ray missed would skip a
    // barrier the hit lanes execute — threadgroup_barrier under thread-divergent
    // control flow is Metal UB (GPU hang / corrupted threadgroup memory on every
    // tile that straddles a silhouette, which is most tiles).
    bool didHit = laneInBounds && (sceneResult.distGlow.x < kRayMissThreshold);

    // Surface point + normal. GetNormal is expensive, so only the hit lanes pay it;
    // miss lanes get harmless placeholders (their shading block never runs).
    float3 p = didHit ? (marchOrigin + adjustedDist * marchDir) : float3(0.0f);
    float3 nor = didHit
        ? GetNormal(p, adjustedDist, fractalParams, uniforms.foldingLimit, lodIterations, fractalType, uniforms.formulaParams, hitCache)
        : float3(0.0f, 1.0f, 0.0f);

    // Lighting basis (precomputed on CPU — frame-uniform) + this lane's spotlight.
    // computeSpotlight is cheap; computing it for miss lanes too keeps thread 0's
    // shared-shadow producer (below) able to read `spot` without a hit-test.
    float4 spotData = computeSpotlight(p, uniforms.precomputedLighting.spotLightPosition);
    float3 spot = spotData.xyz;
    float atten = spotData.w;
    float3 sunDir = uniforms.precomputedLighting.sunDir;

    // shareShadows is threadgroup-UNIFORM (function constant, or the frame-uniform
    // softness heuristic) — so the barrier it guards is reached by all-or-none.
    const bool shareShadows = is_function_constant_defined(FC_SHARE_SHADOWS)
        ? FC_SHARE_SHADOWS
        : (uniforms.lightingSoftness < 0.9f);
    int shadowIterations = ReducedSecondaryIterations(lodIterations, fractalType, true);

    // === SHARED-SHADOW PRODUCER (thread 0) + BARRIER — in UNIFORM control flow ===
    // Thread 0 computes ONE shadow for the whole 8x8 tile (shadow varies slowly over
    // a tile, so sharing is visually imperceptible and saves ~63 Shadow() evals).
    // It ALWAYS publishes a DEFINED value — a real shadow when its own ray hit, else
    // a lit sentinel with the anchor cleared — so the other 63 lanes never read
    // uninitialized threadgroup memory. (The old code wrote tg_* only inside thread
    // 0's per-lane hit branch, so any tile whose top-left pixel was background left
    // every other pixel reading garbage → black/banded blocks.)
    if (shareShadows) {
        if (localIndex == 0) {
            if (didHit) {
                half2 shadows = evaluateAdaptiveSharedShadow(didHit, p, spot, sunDir,
                    fractalParams, shadowIterations, uniforms);
                tg_shaSpot = shadows.x;
                tg_shaSun = shadows.y;
                // Publish anchor surface frame for the coherent-packet normal gate.
                tg_anchorPos = p;
                tg_anchorNormal = nor;
                tg_anchorHasHit = 1;
            } else {
                // Thread 0's ray missed: no representative surface to sample. Lit
                // sentinels + cleared anchor make the hit lanes fall back to their
                // own per-lane shadow below instead of inheriting a bogus broadcast.
                tg_shaSpot = 1.0h;
                tg_shaSun = 1.0h;
                tg_anchorHasHit = 0;
            }
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }

    // Per-lane shading contains no barrier; all lanes completed shadow publication.
    if (didHit) {
        col = shadeAdaptiveHit(p, nor, marchOrigin, marchDir, adjustedDist, hitCache,
            fractalParams, lodIterations, uniforms, spot, atten, shareShadows,
            coherentPacketOn, localIndex, tg_shaSpot, tg_shaSun, tg_anchorPos,
            tg_anchorNormal, tg_anchorHasHit, packetLayer);
    }

    // Apply fog, glow, and clamp using helper functions
    half glowH = half(glow);
    col = applyFog(col, adjustedDist, uniforms.precomputedFog);
    col = applyGlow(col, glowH);
    col = clampColor(col);

    // Apply PostEffects with color scheme support
    // (saturation, contrast, vignette, gamma from color scheme)
    // Compute approximate texCoord for vignette (0-1 range)
    half2 texCoord = half2(pixelCenter / uniforms.resolution);
    col = PostEffectsWithScheme(col, texCoord, uniforms.colorScheme, uniforms.precomputedAudio, half(uniforms.limitFlash), glowH);
    FloorCircleHit floorHit = evaluateFloorCircle(cameraPos, rd, adjustedDist, uniforms.floorPlane, uniforms.floorCenterRadius);
    col = compositeFloorCircle(col, floorHit);

    // Debug visualization
    // Use function constant to compile out debug code in release builds
    const bool debugHierarchical = is_function_constant_defined(FC_DEBUG_HIERARCHICAL) ? FC_DEBUG_HIERARCHICAL : (uniforms.debugHierarchical == 1);
    if (debugHierarchical) {
        // Show tile boundaries
        if (localId.x == 0 || localId.y == 0) {
            col = mix(col, half3(1.0h, 1.0h, 0.0h), 0.5h);
        }
    }

    float4 finalColor = encodeComputeOutput(col, uniforms.colorScheme);

    // === COHERENT-PACKET LAYER-OF-ACCEPTANCE OVERLAY (Stage 0) ===
    // Applied after shading so the tint is unambiguous. Engages whenever the
    // experimental toggle is on (independent of
    // the hierarchical-debug toggle) so it's always visible while testing.
    //   1 = magenta : warm-start probe HIT (skipped fine march, fastest path)
    //   2 = green   : warm-start probe accepted as tight startT (Lipschitz-safe)
    //   3 = red     : warm-start probe REJECTED -> fell back to coarse pass
    //   4 = cyan    : shadow-share fallback (per-pixel Shadow paid)
    //   0 = unset   : pixel followed legacy coarse-tile path (no tint)
    if (coherentPacketOn) {
        half3 layerTint = half3(0.0h);
        half tintMix = 0.0h;
        if (packetLayer == 1)      { layerTint = half3(1.0h, 0.0h, 1.0h); tintMix = 0.65h; }
        else if (packetLayer == 2) { layerTint = half3(0.0h, 1.0h, 0.0h); tintMix = 0.45h; }
        else if (packetLayer == 3) { layerTint = half3(1.0h, 0.0h, 0.0h); tintMix = 0.65h; }
        else if (packetLayer == 4) { layerTint = half3(0.0h, 1.0h, 1.0h); tintMix = 0.50h; }
        if (tintMix > 0.0h) {
            finalColor.rgb = mix(finalColor.rgb, float3(layerTint), float(tintMix));
        }
    }

    if (laneInBounds) {
        outputTexture.write(finalColor, pixelCoord, uniforms.eyeIndex);
    }
}
