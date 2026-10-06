// === FRACTAL DISTANCE CACHE (conservative distance-field grid) ===
// Nearest-voxel fetch of the baked conservative bound. NEAREST on purpose:
// each voxel's stored value is a proven empty-sphere radius for every point
// INSIDE that voxel; a trilinear blend with neighbouring voxels' values is not
// proven for this point, so filtering would break the conservativeness
// invariant. Out-of-grid returns 0 → the march falls back to the analytic DE.
constant float kDistCacheQuantizationStep = 1.0f / 64.0f;
// Conservative local variation bound applied from the voxel center to the
// actual query position.
constant float kDistCacheLipschitzSlack = 2.75f;

FORCE_INLINE uint distCacheDimension(constant DistanceCacheParams& dc)
{
    // The origin's otherwise-unused W lane carries the runtime dimension,
    // preserving the 16-byte vector slot and the shared Uniforms ABI size.
    return max(uint(round(dc.originModel.w)), 1u);
}

// Row-major indexing supports both the 128³ static tier and compact animation
// tiers selected through DistanceCacheParams.invCellModel.
FORCE_INLINE uint distCacheIndex(uint3 g, uint dimension)
{
    return (g.z * dimension + g.y) * dimension + g.x;
}

FORCE_INLINE float distCacheSample(float3 p, constant DistanceCacheParams& dc, device const uchar* grid)
{
    uint dimension = distCacheDimension(dc);
    float3 g = (p - dc.originModel.xyz) * dc.invCellModel;
    if (any(g < 0.0f) || any(g >= float(dimension))) return 0.0f;
    int3 gi = int3(g);
    float centerDistance =
        float(grid[distCacheIndex(uint3(gi), dimension)])
            * kDistCacheQuantizationStep;
    float3 cellOffset = g - (float3(gi) + 0.5f);
    float localDistance = length(cellOffset) / dc.invCellModel.x;
    return max(
        centerDistance - kDistCacheLipschitzSlack * localDistance,
        0.0f);
}
