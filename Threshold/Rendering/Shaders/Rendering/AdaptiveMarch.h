FORCE_INLINE SceneResult marchAdaptiveRay(AdaptiveRayContext ray,
    AdaptiveReprojectionResult reprojection, float tileStartT,
    constant TileUniforms& uniforms, FractalParams fractalParams) {
    float3 marchOrigin = ray.origin;
    float3 marchDir = ray.marchDirection;
    float2 pixelCenter = ray.pixelCenter;
    int lodIterations = ray.iterations;
    int maxSteps = ray.maxSteps;
    int fractalType = uniforms.fractalType;
    bool reprojectionValid = reprojection.valid;
    float reprojectedStartT = reprojection.startT;
    // === FINE RAYMARCH START SELECTION ===
    // CORRECTNESS: tileStartT is a TILE-SHARED start seeded from thread 0's single
    // coarse ray (the tile's top-left corner pixel). It is NOT conservative for the
    // other 63 lanes — an edge lane whose true near surface is closer than tileStartT
    // would have its fine march begin PAST that surface, skipping the near object so
    // the far surface/background bleeds through (the near/far tile-edge cutoffs). Only
    // a PER-PIXEL reprojected start is safe to warm-start from. So we default to the
    // near plane (0.0 → the SceneWithCache full march below, identical to the fragment
    // reference path that has no cutoff) and ONLY warm-start when this lane has its own
    // valid, predict-validated temporal reprojection.
    float fineStartT = 0.0f;
    if (reprojectionValid && reprojectedStartT > tileStartT) {
        // Per-pixel reprojected start — tight AND safe for this specific lane.
        fineStartT = reprojectedStartT;
    }

    // === TEMPORAL REPROJECTION FOR ALL FRACTAL TYPES ===
    // When fineStartT > 0.06 (from temporal reprojection or tile coarse pass),
    // SceneWithCacheFromStart begins near the known surface — typically ~5-10
    // steps instead of 30-60.  Previously only Mandelbox used this path;
    // all other formulas did a full march every frame, wasting temporal data.
    SceneResult sceneResult;
    if (fineStartT > 0.06f) {
        sceneResult = SceneWithCacheFromStart(marchOrigin, marchDir, fineStartT, pixelCenter, 1.0, maxSteps,
                                              uniforms.glowIntensity, uniforms.foldingLimit, fractalParams, lodIterations, uniforms.time, fractalType, uniforms.formulaParams, int(uniforms.colorIterations), uniforms.stepMultiplier, uniforms.smartAdvanceEnabled != 0, uniforms.marchEpsilonScale, uniforms.coneMarchScale, uniforms.distanceLODFalloff);
    } else {
        // Bound to Space: clip the march to the room's interval along this ray
        // (start raised to room entry, budget capped at room exit). Rays that
        // never cross the room volume skip the march entirely. A no-op while
        // boundToSpaceMode == 0.
        float marchStartT = -1.0f;
        float marchEndT = uniforms.maxViewDistance;
        if (!clampMarchToSpaceBounds(marchOrigin, marchDir, uniforms.modelToBoundSpaceMatrix,
                                     uniforms.boundSpaceSize, uniforms.boundToSpaceMode,
                                     marchStartT, marchEndT)) {
            sceneResult.distGlow = float2(kRayMissThreshold + 100.0, 0.0);
            sceneResult.cache = makeEmptyOrbitCache();
            sceneResult.steps = 0;
        } else {
            sceneResult = SceneWithCache(marchOrigin, marchDir, pixelCenter, 1.0, maxSteps,
                             uniforms.glowIntensity, uniforms.foldingLimit, fractalParams, lodIterations, uniforms.time, fractalType, uniforms.formulaParams, int(uniforms.colorIterations), boundingCullSphereRadius(uniforms.boundingSphereRadius, uniforms.boundingShapeType), uniforms.boundingShapeCenter, uniforms.stepMultiplier, marchEndT, uniforms.smartAdvanceEnabled != 0, uniforms.marchEpsilonScale, uniforms.coneMarchScale, uniforms.distanceLODFalloff, marchStartT);
        }
    }

    // Bound to Space: reclassify hits outside the room as misses. The clamped
    // full march can't produce them (beyond a single overshoot step), but the
    // temporal reprojection path above can. The 1cm tolerance keeps hits
    // sliced open right at a wall from speckling into misses. Written back
    // into sceneResult so every downstream read (didHit, depth) agrees.
    if (uniforms.boundToSpaceMode != 0 && sceneResult.distGlow.x < kRayMissThreshold) {
        float3 hitModel = marchOrigin + sceneResult.distGlow.x * marchDir;
        if (spaceBoundsDistance(hitModel, uniforms.modelToBoundSpaceMatrix,
                                uniforms.boundSpaceSize, uniforms.boundToSpaceMode) > 0.01f) {
            sceneResult.distGlow.x = kRayMissThreshold + 100.0f;
        }
    }

    // Bounding Shape: reclassify hits outside the selected shape as misses (hard
    // clip). The compute tile path has no per-hit edge fade like the fragment
    // path, so this reclassify IS the shape's silhouette on visionOS — without it
    // only the sphere-shaped ray-skip above was ever visible. The cull sphere is
    // inflated to enclose the shape, so real shape hits survive the march to here.
    if (uniforms.boundingSphereRadius > 0.0f && sceneResult.distGlow.x < kRayMissThreshold) {
        float3 hitModel = marchOrigin + sceneResult.distGlow.x * marchDir;
        float shapeDist = safetyBubbleDistance(hitModel, uniforms.boundingShapeCenter, uniforms.boundingSphereRadius, uniforms.boundingShapeType);
        if (shapeDist > 0.0f) {
            sceneResult.distGlow.x = kRayMissThreshold + 100.0f;
        }
    }

    return sceneResult;
}
