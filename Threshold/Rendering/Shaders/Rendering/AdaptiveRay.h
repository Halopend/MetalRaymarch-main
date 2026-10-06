FORCE_INLINE AdaptiveRayContext makeAdaptiveRay(uint2 tileId, uint2 viewportPixelCoord,
                                                uint2 viewportSize, constant TileUniforms& uniforms,
                                                constant rasterization_rate_map_data& rateMapData) {
    // Compute ray direction in MODEL SPACE (matching fragment shader exactly)
    // Fragment shader does: rd = normalize(in.modelPos - cameraPos)
    // where modelPos comes from vertex positions and cameraPos is (invModelView * (0,0,0,1)).xyz
    //
    // For compute, we need to:
    // 1. Unproject pixel to clip space
    // 2. Transform through inverse projection to get view-space point
    // 3. Transform through inverse model-view to get model-space point
    // 4. Compute direction from camera to that point (both in model space)

    float2 pixelCenter = float2(viewportPixelCoord) + 0.5;

    // === GMT-FRACTALS PATTERN: Halton Sub-Pixel Jitter for Temporal AA ===
    pixelCenter += uniforms.jitterOffset;

    float3 cameraPos = uniforms.cameraPos;

    // Match the fragment path exactly for visionOS's asymmetric per-eye frusta.
    float3 modelPoint = reconstructModelPoint(pixelCenter, uniforms, rateMapData);
    float3 rd = normalize(modelPoint - cameraPos);

    int lodIterations = max(uniforms.fractalIterations, 2);
    int maxSteps = uniforms.maxRaySteps;

    // === FOVEATED RAYMARCH ===
    // Peripheral tiles get fewer ray steps. The factor is derived from the tile
    // CENTER, so all 64 threads in this threadgroup compute the same value with
    // no intra-tile divergence. Foveal region (r < kFovInner) stays full-quality;
    // beyond it the step budget ramps down to kFovMinFraction at the corners,
    // scaled by foveationStrength. Disabled (factor == 1) when strength == 0.
    if (uniforms.foveationStrength > 0.0f) {
        const float kFovInner = 0.35f;        // normalized radius that stays sharp
        const float kFovMinFraction = 0.5f;   // step budget at the far periphery
        float2 tileCenter = float2(tileId * ADAPTIVE_TILE_SIZE + ADAPTIVE_TILE_SIZE / 2);
        float2 halfRes = max(float2(viewportSize) * 0.5f, float2(1.0f));
        float r = min(length((tileCenter - halfRes) / halfRes), 1.0f);
        float ramp = smoothstep(kFovInner, 1.0f, r) * uniforms.foveationStrength;
        float factor = mix(1.0f, kFovMinFraction, ramp);
        maxSteps = max(int(float(maxSteps) * factor), 8);
    }

    float3 marchOrigin = cameraPos;
    float3 marchDir = rd;
    applySphericalInversionRay(marchOrigin, marchDir, uniforms.sphericalInversionMode, uniforms.sphericalInversionRadius);

    return {pixelCenter, cameraPos, rd, marchOrigin, marchDir, lodIterations, maxSteps};
}

// Adaptive DE policy: all live world fields share the transformed ray origin.
FORCE_INLINE FractalParams makeAdaptiveFractalParams(constant TileUniforms& uniforms,
                                                     float3 marchOrigin) {
    return makeFractalParamsFromPrecomputed(
        uniforms.precomputedFractal,
        uniforms.minDistance,
        marchOrigin, uniforms.safetyBubbleRadius, uniforms.safetyBubbleEnabled, uniforms.safetyBubbleShape, uniforms.safetyBubbleFadeEnabled, uniforms.safetyBubbleFadeWidth, uniforms.safetyBubbleStrength, uniforms.sphereProjectionBlend, uniforms.sphereProjectionRadius, uniforms.spaceWarpStrength, uniforms.spaceWarpParam1, uniforms.spaceWarpParam2, uniforms.spaceWarpParam3, uniforms.spaceWarpAxis, uniforms.spaceWarpStack.ops, uniforms.spaceWarpStack.count,
        &uniforms.envScrunch,
        &uniforms.handField);
}
