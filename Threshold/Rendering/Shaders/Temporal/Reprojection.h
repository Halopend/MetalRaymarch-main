// Convert a SCREEN-space UV (derived from clip space, e.g. temporal reprojection)
// to a PHYSICAL pixel coordinate for indexing depth textures stored in physical
// space. Mirror of reconstructModelPoint's decode: with a valid rate map the
// screen→physical relationship is the rate map; otherwise it is linear.
FORCE_INLINE float2 screenUVToPhysicalPixel(float2 screenUV, constant TileUniforms& uniforms,
                                            constant rasterization_rate_map_data& rateMapData) {
    if (uniforms.rateMapValid != 0) {
        rasterization_rate_map_decoder decoder(rateMapData);
        float2 screenPx = screenUV * uniforms.screenResolution;
        return decoder.map_screen_to_physical_coordinates(screenPx, uniforms.rateMapLayer);
    }
    return screenUV * uniforms.resolution;
}

// Project a model-space point into the previous frame and return its texture UV
// (Metal convention, Y flipped). Caller is responsible for bounds-checking.
FORCE_INLINE float2 reprojectToPrevUV(float3 worldPoint, constant TileUniforms& uniforms) {
    float4 prevClip = uniforms.previousViewProjMatrix * float4(worldPoint, 1.0);
    float2 prevNDC = prevClip.xy / prevClip.w;
    float2 prevUV = prevNDC * 0.5 + 0.5;
    prevUV.y = 1.0 - prevUV.y;
    return prevUV;
}

// Fold one previous-frame depth sample into a running (hit-count, nearest-depth)
// accumulator, ignoring miss/background samples.
FORCE_INLINE void accumulateDepthSample(float d, thread int& hitCount, thread float& minHitDepth) {
    if (d > 0.0f && d < kRayMissThreshold) {
        hitCount++;
        minHitDepth = min(minHitDepth, d);
    }
}
