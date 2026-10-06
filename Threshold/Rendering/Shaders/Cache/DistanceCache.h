// Cache policy: retain canonical parameters and transform metadata, exclude
// camera-dependent bubble, environment scrunch, and hand fields. Bake evaluates
// Map with world fields disabled; validation also exercises transformed reuse.
FORCE_INLINE FractalParams makeDistanceCacheFractalParams(constant Uniforms& uniforms) {
    return makeFractalParamsFromPrecomputed(
        uniforms.precomputedFractal,
        uniforms.minDistance,
        /*bubble (excluded from the bake)*/ float3(0.0f), 0.0f, 0, 0.0f, 0, 0.0f, 0.0f,
        uniforms.sphereProjectionBlend, uniforms.sphereProjectionRadius,
        uniforms.spaceWarpStrength, uniforms.spaceWarpParam1,
        uniforms.spaceWarpParam2, uniforms.spaceWarpParam3,
        uniforms.spaceWarpAxis,
        uniforms.spaceWarpStack.ops, uniforms.spaceWarpStack.count,
        /*envScrunch (excluded)*/ nullptr,
        /*handField (excluded)*/ nullptr);
}

// === FRACTAL DISTANCE CACHE BAKE ===
// Bakes the fractal DE into the conservative distance grid (see
// DistanceCacheParams in ShaderTypes.h). One thread per voxel: evaluate the
// SAME canonical unprojected Mandelbox Map the march uses (full iteration count,
// domain-transform stack excluded) at the
// voxel center and store
//     max(DE − kDistCacheLipschitzSlack·halfDiagonal, 0)
// — a lower bound on the DE anywhere inside the voxel while the local
// Lipschitz constant stays ≤ the slack. Camera-dependent DE terms are excluded
// here. Safety-bubble subtraction only increases the canonical DE, so this
// lower bound remains conservative after composition. Distance-reducing hands,
// environment scrunch, and scene-object unions remain CPU-gated. Dispatched in
// the frame's own command buffer before the render pass, only on DE-parameter
// change — never stale.
kernel void distanceCacheBake(device uchar* outGrid [[buffer(0)]],
                              constant Uniforms& uniforms [[buffer(BufferIndexUniforms)]],
                              constant uint& zOffset [[buffer(BufferIndexDistanceCacheZOffset)]],
                              uint3 localTid [[thread_position_in_grid]])
{
    uint3 tid = uint3(localTid.xy, localTid.z + zOffset);
    constant DistanceCacheParams& dc = uniforms.distCache;
    uint dimension = distCacheDimension(dc);
    if (any(tid >= uint3(dimension))) return;
    float3 cell = 1.0f / dc.invCellModel;
    float3 p = dc.originModel.xyz + (float3(tid) + 0.5f) * cell;

    FractalParams params = makeDistanceCacheFractalParams(uniforms);

    float d = Map(p, params, uniforms.foldingLimit,
                  max(int(uniforms.fractalIterations), 2),
                  /*world fields excluded*/ false);
    // Store the center DE rounded down. Lookup subtracts the Lipschitz margin
    // for its actual within-cell offset, so quantization remains conservative.
    float quantized = clamp(
        floor(max(d, 0.0f) / kDistCacheQuantizationStep),
        0.0f, 255.0f);
    outGrid[distCacheIndex(tid, dimension)] = uchar(quantized);
}

// Debug/validation companion (THRESHOLD_DIST_CACHE_DEBUG=1): per-voxel, probe
// deterministic canonical points plus model-space points passed through the
// live domain-transform stack. Count any stored/transformed bound exceeding
// the matching analytic DE. Writes out[0] = violation count, out[1] = max
// excess as float bits, out[2] = nonzero canonical voxel count. A nonzero
// violation count means the cache must not ship for this configuration.
kernel void distanceCacheValidate(device const uchar* grid [[buffer(0)]],
                                  device atomic_uint* out [[buffer(1)]],
                                  constant Uniforms& uniforms [[buffer(BufferIndexUniforms)]],
                                  uint3 tid [[thread_position_in_grid]])
{
    constant DistanceCacheParams& dc = uniforms.distCache;
    uint dimension = distCacheDimension(dc);
    if (any(tid >= uint3(dimension))) return;
    float centerDistance = float(grid[distCacheIndex(tid, dimension)])
        * kDistCacheQuantizationStep;

    float3 cell = 1.0f / dc.invCellModel;
    FractalParams params = makeDistanceCacheFractalParams(uniforms);

    if (centerDistance > 0.0f) {
        atomic_fetch_add_explicit(&out[2], 1u, memory_order_relaxed);
        // 8 deterministic canonical probes: voxel corners-ish, jittered inward.
        for (uint i = 0; i < 8; i++) {
            float3 f = float3(float(i & 1u), float((i >> 1) & 1u), float((i >> 2) & 1u));
            float3 p = dc.originModel.xyz + (float3(tid) + mix(float3(0.05f), float3(0.95f), f)) * cell;
            float d = Map(p, params, uniforms.foldingLimit,
                          max(int(uniforms.fractalIterations), 2),
                          /*world fields excluded*/ false);
            float probeBound = distCacheSample(p, dc, grid);
            if (probeBound <= 0.0f) continue;
            if (probeBound > d + 1e-4f) {
                atomic_fetch_add_explicit(&out[0], 1u, memory_order_relaxed);
                atomic_fetch_max_explicit(
                    &out[1], as_type<uint>(probeBound - d), memory_order_relaxed);
            }
        }
    }

    // Validate post-transform reuse independently of which canonical voxel this
    // model-space cell maps into. This is the exact lookup performed by the hot
    // march path, including its conservative Jacobian divisor.
    for (uint i = 0; i < 8; i++) {
        float3 f = float3(float(i & 1u), float((i >> 1) & 1u), float((i >> 2) & 1u));
        float3 p = dc.originModel.xyz + (float3(tid) + mix(float3(0.05f), float3(0.95f), f)) * cell;
        SpaceTransform transformed = applySpaceTransforms(p, FractalTypeMandelbox, params);
        float transformedBound = distCacheSample(
            transformed.point, dc, grid
        ) / max(transformed.deScale, 1e-6f);
        if (transformedBound <= 0.0f) continue;

        float analytic = MapUnified(
            p, params, uniforms.foldingLimit,
            max(int(uniforms.fractalIterations), 2),
            FractalTypeMandelbox, uniforms.formulaParams);
        if (transformedBound > analytic + 1e-4f) {
            atomic_fetch_add_explicit(&out[3], 1u, memory_order_relaxed);
            atomic_fetch_max_explicit(
                &out[4],
                as_type<uint>(transformedBound - analytic),
                memory_order_relaxed);
        }
    }
}
