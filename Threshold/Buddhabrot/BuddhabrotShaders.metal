//
//  BuddhabrotShaders.metal
//  Threshold
//
//  GPU kernels for real-time 3D Buddhabrot on Vision Pro.
//
//  Architecture:
//    Phase 1 (async compute): Orbit accumulation into a linear uint32 density buffer
//                             using atomic_fetch_add. No texture atomics needed.
//    Phase 2 (per-frame):     Normalize density → 3D float texture, then
//                             stereo volume ray march for immersive passthrough.
//
//  The density buffer is indexed as: idx = z * Ny * Nx + y * Nx + x
//  World space maps [-extent, +extent]^3 → [0, resolution)^3 voxel indices.
//

#include <metal_stdlib>
#include <metal_atomic>
#include <simd/simd.h>
#import "BuddhabrotTypes.h"

using namespace metal;

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - Utility Functions
// ═══════════════════════════════════════════════════════════════════════════════

/// Hash function for generating pseudo-random seeds from thread ID + batch offset.
/// Based on PCG-style bit mixing for good distribution.
inline uint pcg_hash(uint input) {
    uint state = input * 747796405u + 2891336453u;
    uint word  = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}

/// Convert a uint hash to a float in [0, 1).
inline float hash_to_float(uint h) {
    return float(h) / float(0xFFFFFFFFu);
}

/// Generate a random float3 in [-extent, +extent]^3 from a seed.
inline float3 random_point_in_cube(uint seed, float extent) {
    float x = hash_to_float(pcg_hash(seed))       * 2.0f * extent - extent;
    float y = hash_to_float(pcg_hash(seed + 1u))   * 2.0f * extent - extent;
    float z = hash_to_float(pcg_hash(seed + 2u))   * 2.0f * extent - extent;
    return float3(x, y, z);
}

/// Map a world-space position to a voxel index.
/// Returns -1 if out of bounds.
inline int3 world_to_voxel(float3 pos, float extent, uint resolution) {
    float3 normalized = (pos + extent) / (2.0f * extent); // [0, 1]
    int3 voxel = int3(normalized * float(resolution));
    // Clamp to valid range
    if (any(voxel < 0) || any(voxel >= int3(resolution)))
        return int3(-1);
    return voxel;
}

/// Flatten a 3D voxel index to a linear buffer index.
inline uint voxel_to_index(int3 voxel, uint resolution) {
    return uint(voxel.z) * resolution * resolution + uint(voxel.y) * resolution + uint(voxel.x);
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - Mandelbulb Iteration (3D "lifted" fractal for Buddhabrot orbits)
// ═══════════════════════════════════════════════════════════════════════════════

/// Mandelbulb iteration: z_{n+1} = z_n^power + c
/// Returns the new z value after one iteration.
/// Uses spherical coordinates for the power operation.
inline float3 mandelbulb_iterate(float3 z, float3 c, float power) {
    float r = length(z);
    if (r < 1e-10f) return c; // Avoid division by zero
    
    float theta = acos(clamp(z.z / r, -1.0f, 1.0f));
    float phi   = atan2(z.y, z.x);
    
    float rn = powr(r, power);
    float newTheta = theta * power;
    float newPhi   = phi * power;
    
    float sinTheta = sin(newTheta);
    float3 zn = rn * float3(
        sinTheta * cos(newPhi),
        sinTheta * sin(newPhi),
        cos(newTheta)
    );
    
    return zn + c;
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - Phase 1: Orbit Accumulation Compute Kernel
// ═══════════════════════════════════════════════════════════════════════════════
//
// Each thread = one random seed c.
// 1. Iterate Mandelbulb up to maxIter, storing orbit points in threadgroup memory.
// 2. If the orbit escapes, walk the stored points and atomic_add to the density buffer.
// 3. If it doesn't escape (bounded orbit), skip — Buddhabrot only counts escaping orbits.
//
// Dispatch in moderate-sized grids repeatedly; throttle when frame time spikes.
// Use MTLCommandBufferPriorityLow on visionOS to keep thermals happy.

kernel void buddhabrotAccumulate(
    device atomic_uint     *densityBuffer  [[buffer(BuddhabrotBufferIndexDensity)]],
    constant BuddhabrotAccumulationUniforms &params [[buffer(BuddhabrotBufferIndexUniforms)]],
    uint                    tid            [[thread_position_in_grid]])
{
    // Guard against over-dispatch
    if (tid >= params.batchSize) return;
    
    // Generate a unique seed for this thread + batch
    uint seed = pcg_hash(tid + params.seedOffset * 65537u);
    
    // Random starting point c in the bounding cube
    float3 c = random_point_in_cube(seed, params.worldExtent);
    
    // Store orbit trajectory in a local array (thread-private, stack memory)
    float3 orbit[BBROT_MAX_ORBIT_LENGTH];
    
    float3 z = float3(0.0f);
    uint orbitLength = 0;
    bool escaped = false;
    float bailoutSq = params.bailoutRadius * params.bailoutRadius;
    
    // Iterate the Mandelbulb
    for (uint i = 0; i < params.maxIterations && orbitLength < BBROT_MAX_ORBIT_LENGTH; i++) {
        z = mandelbulb_iterate(z, c, params.power);
        
        // Store this orbit point
        orbit[orbitLength] = z;
        orbitLength++;
        
        // Check escape
        float r2 = dot(z, z);
        if (r2 > bailoutSq) {
            escaped = true;
            // Only count orbits that escaped within our iteration band
            if (i >= params.minIterations) {
                escaped = true;
            } else {
                escaped = false; // Escaped too quickly for this band
            }
            break;
        }
    }
    
    // If the orbit escaped (within our iteration band), deposit all orbit points
    if (escaped) {
        uint res = params.resolution;
        float ext = params.worldExtent;
        
        for (uint i = 0; i < orbitLength; i++) {
            int3 voxel = world_to_voxel(orbit[i], ext, res);
            if (voxel.x >= 0) { // Valid voxel (not out of bounds)
                uint idx = voxel_to_index(voxel, res);
                atomic_fetch_add_explicit(&densityBuffer[idx], 1u, memory_order_relaxed);
            }
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - Phase 1 (RGB): 3-Band Orbit Accumulation
// ═══════════════════════════════════════════════════════════════════════════════
//
// Optional: accumulate into 3 separate buffers for short/medium/long escape orbits.
// This produces Nebulabrot-style coloring when combined in the transfer function.

kernel void buddhabrotAccumulateRGB(
    device atomic_uint     *densityR       [[buffer(BuddhabrotBufferIndexDensityR)]],
    device atomic_uint     *densityG       [[buffer(BuddhabrotBufferIndexDensityG)]],
    device atomic_uint     *densityB       [[buffer(BuddhabrotBufferIndexDensityB)]],
    constant BuddhabrotAccumulationUniforms &params [[buffer(BuddhabrotBufferIndexUniforms)]],
    uint                    tid            [[thread_position_in_grid]])
{
    if (tid >= params.batchSize) return;
    
    uint seed = pcg_hash(tid + params.seedOffset * 65537u);
    float3 c = random_point_in_cube(seed, params.worldExtent);
    
    float3 orbit[BBROT_MAX_ORBIT_LENGTH];
    float3 z = float3(0.0f);
    uint orbitLength = 0;
    bool escaped = false;
    uint escapeIter = 0;
    float bailoutSq = params.bailoutRadius * params.bailoutRadius;
    
    for (uint i = 0; i < params.maxIterations && orbitLength < BBROT_MAX_ORBIT_LENGTH; i++) {
        z = mandelbulb_iterate(z, c, params.power);
        orbit[orbitLength] = z;
        orbitLength++;
        
        float r2 = dot(z, z);
        if (r2 > bailoutSq) {
            escaped = true;
            escapeIter = i;
            break;
        }
    }
    
    if (escaped) {
        uint res = params.resolution;
        float ext = params.worldExtent;
        
        // Determine which band this orbit belongs to based on escape iteration
        // Short: 1–20, Medium: 21–100, Long: 101+
        // These bands are classic Buddhabrot RGB ranges
        device atomic_uint *targetBuffer;
        if (escapeIter < 20u) {
            targetBuffer = densityR; // Short (red) — hot, fast escapes
        } else if (escapeIter < 100u) {
            targetBuffer = densityG; // Medium (green) — warm, moderate escapes
        } else {
            targetBuffer = densityB; // Long (blue) — cool, slow escapes
        }
        
        for (uint i = 0; i < orbitLength; i++) {
            int3 voxel = world_to_voxel(orbit[i], ext, res);
            if (voxel.x >= 0) {
                uint idx = voxel_to_index(voxel, res);
                atomic_fetch_add_explicit(&targetBuffer[idx], 1u, memory_order_relaxed);
            }
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - Phase 2a: Density Normalization Compute Kernel
// ═══════════════════════════════════════════════════════════════════════════════
//
// Reads the raw uint32 density buffer, applies log-scaling + gamma correction,
// and writes normalized [0,1] values into a 3D R16Float texture.
// Run this every few frames (not every frame) to save GPU cycles.

kernel void buddhabrotNormalize(
    device uint            *densityBuffer  [[buffer(BuddhabrotBufferIndexDensity)]],
    texture3d<float, access::write> volume [[texture(BuddhabrotTextureIndexVolume)]],
    constant BuddhabrotNormalizationUniforms &params [[buffer(BuddhabrotBufferIndexUniforms)]],
    uint3                   gid            [[thread_position_in_grid]])
{
    uint res = params.resolution;
    if (any(gid >= uint3(res))) return;
    
    uint idx = gid.z * res * res + gid.y * res + gid.x;
    uint rawDensity = densityBuffer[idx];
    
    // Log-scale normalization: log(1 + density * scale) / log(1 + maxDensity * scale)
    float d = float(rawDensity);
    float maxD = float(max(params.maxDensity, 1u));
    float scale = params.densityScale;
    
    float normalized = log(1.0f + d * scale) / log(1.0f + maxD * scale);
    
    // Apply gamma curve (< 1 brightens low-density regions, classic Buddhabrot look)
    normalized = powr(saturate(normalized), params.gamma);
    
    volume.write(float4(normalized, 0.0f, 0.0f, 0.0f), gid);
}

/// RGB variant: normalizes 3 density buffers into a single RGBA 3D texture.
kernel void buddhabrotNormalizeRGB(
    device uint            *densityR       [[buffer(BuddhabrotBufferIndexDensityR)]],
    device uint            *densityG       [[buffer(BuddhabrotBufferIndexDensityG)]],
    device uint            *densityB       [[buffer(BuddhabrotBufferIndexDensityB)]],
    texture3d<float, access::write> volume [[texture(BuddhabrotTextureIndexVolume)]],
    constant BuddhabrotNormalizationUniforms &params [[buffer(BuddhabrotBufferIndexUniforms)]],
    uint3                   gid            [[thread_position_in_grid]])
{
    uint res = params.resolution;
    if (any(gid >= uint3(res))) return;
    
    uint idx = gid.z * res * res + gid.y * res + gid.x;
    float maxD = float(max(params.maxDensity, 1u));
    float scale = params.densityScale;
    float denom = log(1.0f + maxD * scale);
    
    float r = powr(saturate(log(1.0f + float(densityR[idx]) * scale) / denom), params.gamma);
    float g = powr(saturate(log(1.0f + float(densityG[idx]) * scale) / denom), params.gamma);
    float b = powr(saturate(log(1.0f + float(densityB[idx]) * scale) / denom), params.gamma);
    
    volume.write(float4(r, g, b, max(r, max(g, b))), gid);
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - Phase 2b: Volume Ray March (Stereo, Fragment Shader)
// ═══════════════════════════════════════════════════════════════════════════════
//
// Full-screen quad fragment shader that ray-marches the normalized 3D density texture.
// Supports stereo via vertex amplification (one draw call, amplification_id selects eye).
// Uses front-to-back alpha compositing with early exit when alpha saturates.

struct BuddhabrotVertexOut {
    float4 position [[position]];
    float2 texCoord;
    uint   viewIndex [[flat]];                            // Eye index for uniform selection (not interpolated)
    uint   viewportIndex [[viewport_array_index]];        // Routes to correct eye viewport
    uint   renderTargetIndex [[render_target_array_index]]; // Routes to correct eye texture layer
};

vertex BuddhabrotVertexOut buddhabrotVertex(
    uint                    vertexID   [[vertex_id]],
    ushort                  ampId      [[amplification_id]],
    constant BuddhabrotRayMarchUniformsArray &uniformsArray [[buffer(0)]])
{
    // Full-screen triangle (3 vertices, no vertex buffer needed)
    float2 positions[3] = {
        float2(-1.0, -1.0),
        float2( 3.0, -1.0),
        float2(-1.0,  3.0)
    };
    float2 texCoords[3] = {
        float2(0.0, 1.0),
        float2(2.0, 1.0),
        float2(0.0, -1.0)
    };
    
    BuddhabrotVertexOut out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    out.texCoord = texCoords[vertexID];
    out.viewIndex = ampId;
    // Base index 0; vertex amplification mapping offsets route to correct eye
    out.viewportIndex = 0;
    out.renderTargetIndex = 0;
    return out;
}

/// Intersect a ray with an axis-aligned bounding box.
/// Returns (tNear, tFar). If tNear > tFar, no intersection.
inline float2 intersect_aabb(float3 origin, float3 invDir, float3 boxMin, float3 boxMax) {
    float3 t0 = (boxMin - origin) * invDir;
    float3 t1 = (boxMax - origin) * invDir;
    float3 tmin = min(t0, t1);
    float3 tmax = max(t0, t1);
    float tNear = max(tmin.x, max(tmin.y, tmin.z));
    float tFar  = min(tmax.x, min(tmax.y, tmax.z));
    return float2(tNear, tFar);
}

/// 3-color palette interpolation based on density value.
inline float3 transfer_function(float density, float3 colorLow, float3 colorMid, float3 colorHigh, float gamma) {
    float d = powr(saturate(density), gamma);
    if (d < 0.5f) {
        return mix(colorLow, colorMid, d * 2.0f);
    } else {
        return mix(colorMid, colorHigh, (d - 0.5f) * 2.0f);
    }
}

struct BuddhabrotFragmentOut {
    float4 color [[color(0)]];
    float  depth [[depth(any)]];
};

fragment BuddhabrotFragmentOut buddhabrotFragment(
    BuddhabrotVertexOut         in           [[stage_in]],
    texture3d<float>            volumeTex    [[texture(0)]],
    constant BuddhabrotRayMarchUniformsArray &uniformsArray [[buffer(0)]])
{
    constexpr sampler volumeSampler(filter::linear, address::clamp_to_zero);
    
    BuddhabrotRayMarchUniforms u = uniformsArray.uniforms[in.viewIndex];
    
    // Reconstruct ray in world space from screen UV
    float2 ndc = in.texCoord * 2.0f - 1.0f;
    ndc.y = -ndc.y; // Flip Y for Metal's clip space convention
    
    // visionOS uses reverse-Z: near plane = z=1, far plane = z=0.
    // Unprojecting z=0 gives a point at infinity (degenerate).
    // Instead, derive the camera position from the inverse view matrix
    // and the ray direction from a near-plane unproject.
    float3 camPos = float3(u.inverseViewMatrix[3][0],
                           u.inverseViewMatrix[3][1],
                           u.inverseViewMatrix[3][2]);
    
    // Unproject a point on the near plane (z=1 in reverse-Z) to get ray direction
    float4 clipNear = float4(ndc, 1.0f, 1.0f);
    float4 eyeNear  = u.inverseProjectionMatrix * clipNear;
    eyeNear.xyz /= eyeNear.w;
    float3 worldNear = (u.inverseViewMatrix * float4(eyeNear.xyz, 1.0f)).xyz;
    
    float3 rayOrigin = camPos;
    float3 rayDir    = normalize(worldNear - camPos);
    
    // Transform ray into volume local space
    float3 localOrigin = (u.inverseVolumeWorldMatrix * float4(rayOrigin, 1.0f)).xyz;
    float3 localDir    = normalize((u.inverseVolumeWorldMatrix * float4(rayDir, 0.0f)).xyz);
    
    // Intersect ray with the volume bounding box
    float3 invDir = 1.0f / (localDir + float3(1e-10f)); // Avoid division by zero
    float2 tRange = intersect_aabb(localOrigin, invDir, u.volumeMin, u.volumeMax);
    
    BuddhabrotFragmentOut out;
    
    // No intersection — fully transparent
    if (tRange.x > tRange.y || tRange.y < 0.0f) {
        out.color = float4(0.0f);
        out.depth = 1e-7f; // Far plane for compositor
        return out;
    }
    
    // Clamp near to 0 (don't start behind camera)
    float tStart = max(tRange.x, 0.0f);
    float tEnd   = tRange.y;
    
    // Volume dimensions for UV mapping
    float3 volumeSize = u.volumeMax - u.volumeMin;
    
    // Front-to-back compositing
    float3 accumColor = float3(0.0f);
    float  accumAlpha = 0.0f;
    float  firstHitT  = tEnd; // Track first significant hit for depth
    
    float t = tStart;
    float dt = u.stepSize;
    uint maxSteps = u.maxSteps;
    
    for (uint step = 0; step < maxSteps && t < tEnd; step++) {
        float3 pos = localOrigin + localDir * t;
        
        // Map position to [0, 1] UV for texture sampling
        float3 uvw = (pos - u.volumeMin) / volumeSize;
        
        // Sample the 3D density texture (trilinear filtered)
        float4 sample = volumeTex.sample(volumeSampler, uvw);
        float density = sample.r;
        
        if (density > 0.001f) {
            // Apply transfer function
            float3 sampleColor;
            float  sampleAlpha;
            
            if (sample.g > 0.0f || sample.b > 0.0f) {
                // RGB mode — use channels directly as color
                sampleColor = sample.rgb * u.densityScale;
                sampleAlpha = sample.a * u.alphaScale * dt;
            } else {
                // Single-channel mode — apply palette transfer function
                sampleColor = transfer_function(density, u.colorLow, u.colorMid, u.colorHigh, u.gamma);
                sampleAlpha = density * u.alphaScale * dt;
            }
            
            sampleAlpha = saturate(sampleAlpha);
            
            // Front-to-back compositing
            accumColor += (1.0f - accumAlpha) * sampleAlpha * sampleColor;
            accumAlpha += (1.0f - accumAlpha) * sampleAlpha;
            
            // Track first hit for depth buffer
            if (accumAlpha > 0.01f && firstHitT >= tEnd) {
                firstHitT = t;
            }
            
            // Early exit when alpha saturates
            if (accumAlpha > u.earlyExitAlpha) {
                break;
            }
        }
        
        t += dt;
    }
    
    // Premultiplied alpha output (compatible with compositor blending)
    out.color = float4(accumColor, accumAlpha);
    
    // Write depth for async timewarp / compositor reprojection
    if (firstHitT < tEnd) {
        // Convert local-space hit to clip-space depth
        float3 worldHit = (u.volumeWorldMatrix * float4(localOrigin + localDir * firstHitT, 1.0f)).xyz;
        float4 clipPos = u.projectionMatrix * u.viewMatrix * float4(worldHit, 1.0f);
        out.depth = clipPos.z / clipPos.w;
    } else {
        out.depth = 1e-7f; // Far plane
    }
    
    return out;
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - Utility: Clear Density Buffer
// ═══════════════════════════════════════════════════════════════════════════════

/// Clears the density buffer to zero. Dispatch with enough threads to cover
/// resolution^3 voxels. Useful when changing parameters or resetting accumulation.
kernel void buddhabrotClearDensity(
    device uint *densityBuffer [[buffer(0)]],
    constant uint &bufferSize  [[buffer(1)]],
    uint tid                   [[thread_position_in_grid]])
{
    if (tid < bufferSize) {
        densityBuffer[tid] = 0;
    }
}
