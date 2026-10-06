FORCE_INLINE AdaptiveTileCullResult evaluateAdaptiveTileBoundsAndStart(
    uint2 tileId, uint2 viewportSize, uint2 viewportOrigin, AdaptiveRayContext ray,
    AdaptiveReprojectionResult reprojection, constant TileUniforms& uniforms,
    constant rasterization_rate_map_data& rateMapData,
    texture2d_array<float, access::read> prevDepthTexture) {
    float tileStartT = 0.05f;
    int tileIsEmpty = 0;
    float3 marchOrigin = ray.origin;
    float3 marchDir = ray.marchDirection;
    int lodIterations = ray.iterations;
    int fractalType = uniforms.fractalType;
    bool reprojectionValid = reprojection.valid;
    float reprojectedStartT = reprojection.startT;
    // === BOUNDING SPHERE / BOUND TO SPACE TILE EARLY-EXIT ===
    // Before coarse raymarching, test rays at the tile center + 4 corners
    // against the bounding volumes. Only declare empty if ALL 5 rays miss.
    // Single-center probing dropped 8x8 tiles whenever a thin off-axis
    // feature crossed only the corner of the tile. A probe ray is dead when
    // it misses ANY enabled volume — visible fractal must sit inside both
    // the bounding shape and the Bound to Space room.
    if (uniforms.boundingSphereRadius > 0.0 || uniforms.boundToSpaceMode != 0) {
        // Probe geometric tile boundaries (0...8), not last-pixel centers.
            // Keep the full tile footprint for the existing bounding-volume policy.
            const float2 bsOffsets[5] = {
            float2(ADAPTIVE_TILE_SIZE * 0.5f, ADAPTIVE_TILE_SIZE * 0.5f),
            float2(0.0f, 0.0f),
            float2(float(ADAPTIVE_TILE_SIZE), 0.0f),
            float2(0.0f, float(ADAPTIVE_TILE_SIZE)),
            float2(float(ADAPTIVE_TILE_SIZE), float(ADAPTIVE_TILE_SIZE))
        };
        int bsMissCount = 0;
        for (int i = 0; i < 5; ++i) {
            float2 px = float2(tileId * ADAPTIVE_TILE_SIZE) + bsOffsets[i];
            float3 bsModelPoint = reconstructModelPoint(px, uniforms, rateMapData);
            float3 bsRd = normalize(bsModelPoint - marchOrigin);
            bool rayDead = false;
            if (uniforms.boundingSphereRadius > 0.0) {
                float cullR = boundingCullSphereRadius(uniforms.boundingSphereRadius, uniforms.boundingShapeType);
                float bsT = rayIntersectBoundingSphere(marchOrigin, bsRd, uniforms.boundingShapeCenter, cullR);
                rayDead = (bsT < 0.0);
            }
            if (!rayDead && uniforms.boundToSpaceMode != 0) {
                float probeStartT = 0.0f, probeEndT = uniforms.maxViewDistance;
                rayDead = !clampMarchToSpaceBounds(marchOrigin, bsRd, uniforms.modelToBoundSpaceMatrix,
                                                   uniforms.boundSpaceSize, uniforms.boundToSpaceMode,
                                                   probeStartT, probeEndT);
            }
            if (rayDead) bsMissCount++;
        }
        if (bsMissCount >= 5) {
            tileIsEmpty = 1;
            tileStartT = 0.05;
        }
    }

    if (!tileIsEmpty) {
        bool seededFromSuperTileHistory = false;
        bool seededFromTileHistory = false;

        // 32x32 supertile seed:
        // Build a parent-grid hint from previous-frame depths so child 8x8 tiles
        // can skip coarse marching when temporal history is coherent.
        if (uniforms.temporalReprojectionEnabled != 0 && uniforms.blendFactor < 0.6f) {
            uint2 superTileId = tileId / ADAPTIVE_SUPERTILE_TILE_COUNT;
            uint2 superTileBase = viewportOrigin + superTileId * ADAPTIVE_SUPERTILE_SIZE;
            uint2 superTileEnd = min(superTileBase + uint2(ADAPTIVE_SUPERTILE_SIZE - 1), viewportOrigin + viewportSize - 1);
            uint2 superTileCenterPx = min(superTileBase + uint2(ADAPTIVE_SUPERTILE_SIZE / 2), viewportOrigin + viewportSize - 1);

            int superHistoryHits = 0;
            float superMinHitDepth = kRayMissThreshold + 100.0f;

            accumulateDepthSample(prevDepthTexture.read(superTileCenterPx, uniforms.eyeIndex).x, superHistoryHits, superMinHitDepth);
            accumulateDepthSample(prevDepthTexture.read(superTileBase, uniforms.eyeIndex).x, superHistoryHits, superMinHitDepth);
            accumulateDepthSample(prevDepthTexture.read(uint2(superTileEnd.x, superTileBase.y), uniforms.eyeIndex).x, superHistoryHits, superMinHitDepth);
            accumulateDepthSample(prevDepthTexture.read(uint2(superTileBase.x, superTileEnd.y), uniforms.eyeIndex).x, superHistoryHits, superMinHitDepth);
            accumulateDepthSample(prevDepthTexture.read(superTileEnd, uniforms.eyeIndex).x, superHistoryHits, superMinHitDepth);
            accumulateDepthSample(prevDepthTexture.read(uint2(superTileCenterPx.x, superTileBase.y), uniforms.eyeIndex).x, superHistoryHits, superMinHitDepth);
            accumulateDepthSample(prevDepthTexture.read(uint2(superTileCenterPx.x, superTileEnd.y), uniforms.eyeIndex).x, superHistoryHits, superMinHitDepth);
            accumulateDepthSample(prevDepthTexture.read(uint2(superTileBase.x, superTileCenterPx.y), uniforms.eyeIndex).x, superHistoryHits, superMinHitDepth);
            accumulateDepthSample(prevDepthTexture.read(uint2(superTileEnd.x, superTileCenterPx.y), uniforms.eyeIndex).x, superHistoryHits, superMinHitDepth);

            // 9-sample super-tile seed: tighten threshold + backoff to avoid
            // skipping closer geometry across 32x32 depth discontinuities.
            if (superHistoryHits >= 5) {
                tileStartT = max(0.05f, superMinHitDepth * 0.6f);
                seededFromSuperTileHistory = true;
            }
        }

        // Tile-level temporal neighborhood seed:
        // sample center + 4 corners from previous-frame depth and use the
        // nearest hit as a conservative start distance for the whole 8x8 tile.
        // This reuses both frame-to-frame and nearby-pixel information.
        if (uniforms.temporalReprojectionEnabled != 0 && uniforms.blendFactor < 0.6f) {
            uint2 tileBase = viewportOrigin + tileId * ADAPTIVE_TILE_SIZE;
            uint2 tileEnd = min(tileBase + uint2(ADAPTIVE_TILE_SIZE - 1), viewportOrigin + viewportSize - 1);
            uint2 tileCenterPx = min(tileBase + uint2(ADAPTIVE_TILE_SIZE / 2), viewportOrigin + viewportSize - 1);

            int tileHistoryHits = 0;
            float tileMinHitDepth = kRayMissThreshold + 100.0f;

            accumulateDepthSample(prevDepthTexture.read(tileCenterPx, uniforms.eyeIndex).x, tileHistoryHits, tileMinHitDepth);
            accumulateDepthSample(prevDepthTexture.read(tileBase, uniforms.eyeIndex).x, tileHistoryHits, tileMinHitDepth);
            accumulateDepthSample(prevDepthTexture.read(uint2(tileEnd.x, tileBase.y), uniforms.eyeIndex).x, tileHistoryHits, tileMinHitDepth);
            accumulateDepthSample(prevDepthTexture.read(uint2(tileBase.x, tileEnd.y), uniforms.eyeIndex).x, tileHistoryHits, tileMinHitDepth);
            accumulateDepthSample(prevDepthTexture.read(tileEnd, uniforms.eyeIndex).x, tileHistoryHits, tileMinHitDepth);

            // Require multiple agreeing history samples to avoid stale-start artifacts.
            // 3-of-5 (was 2-of-5) + tighter 0.6 backoff (was 0.8) prevents 8x8
            // silhouette artifacts where 2 corners hit far depth and the rest
            // miss closer surface.
            if (tileHistoryHits >= 3) {
                tileStartT = max(0.05f, tileMinHitDepth * 0.6f);
                seededFromTileHistory = true;
            }
        }

        // Build a model-space ray for an arbitrary viewport-pixel coord.
        // Used for multi-corner probing in the bounding-sphere test, the
        // empty-tile test, and (when reprojection is valid) for a conservative
        // coarse march at the tile center.
        float coarseTCenter = kRayMissThreshold + 1.0f;
        bool ranCoarseMarch = false;

        if (!seededFromTileHistory && !seededFromSuperTileHistory) {
            FractalParams coarseParams = makeAdaptiveFractalParams(uniforms, marchOrigin);
            coarseTCenter = SceneCoarse(marchOrigin, marchDir, uniforms.foldingLimit, coarseParams, lodIterations, fractalType, uniforms.formulaParams, uniforms.maxViewDistance, uniforms.marchEpsilonScale);
            ranCoarseMarch = true;

            if (coarseTCenter >= kRayMissThreshold) {
                // EMPTY-TILE SKIP DISABLED (was the "black square holes"). The old
                // 5-point probe sampled 4 corners + a point mislabeled "center" that
                // was actually at (0.5,0.5) — so all 5 probes CLUSTERED at the corners
                // and the tile centre + every edge-midpoint were unprobed. A thin
                // feature clipping a tile edge/interior between probes was missed by all
                // 5 → cornerEmpty==5 → the whole 8x8 tile was painted background (a
                // solid black square at the silhouette). No cheap finite probe set is
                // safe for thin fractal features, and the skip's perf benefit is
                // unmeasured — so march EVERY tile: start the fine march at the near
                // plane. Pixels that miss render background; pixels on the clipped
                // feature render correctly. (A correct empty-skip would need a true
                // conservative bound, e.g. the bounding-sphere path, not a point probe.)
                tileStartT = 0.05;
            } else {
                tileStartT = coarseTCenter;
            }
        }

        if (reprojectionValid) {
            // Temporal reprojection is valid for thread 0 — surface exists near
            // this depth FOR THE CENTER PIXEL. But other threads in the tile may
            // have no valid reprojection (silhouettes/disocclusions). To avoid
            // skipping closer geometry on those edges, use the MORE CONSERVATIVE
            // (closer) of the reprojected start and the coarse-march result.
            float reprojSeed = max(0.05f, reprojectedStartT * 0.85f);
            if (ranCoarseMarch && coarseTCenter < kRayMissThreshold) {
                tileStartT = min(reprojSeed, coarseTCenter);
            } else {
                tileStartT = reprojSeed;
            }
        }
    } // end if (!tileIsEmpty)
    return {tileStartT, tileIsEmpty};
}
