//
//  BuddhabrotShaders.metal
//  Threshold
//
//  GPU kernels for real-time 3D Buddhabrot on Vision Pro.
//
//  License: N/A (method attribution; Threshold implementation)
//  Authors: Melinda Green (Buddhabrot orbit-density method); Daniel White and
//           Paul Nylander (Mandelbulb recurrence used by this 3D variant)
//  Found: https://superliminal.com/fractals/bbrot/
//         http://www.skytopia.com/project/fractal/mandelbulb.html
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
    
    // No intersection — discard so the compositor shows passthrough
    if (tRange.x > tRange.y || tRange.y < 0.0f) {
        discard_fragment();
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

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - Gaussian Splat: Pack Color Utility
// ═══════════════════════════════════════════════════════════════════════════════

/// Pack an RGB color + alpha into a single uint32 (R8G8B8A8).
inline uint pack_color(float3 color, float alpha) {
    uint r = uint(saturate(color.r) * 255.0f);
    uint g = uint(saturate(color.g) * 255.0f);
    uint b = uint(saturate(color.b) * 255.0f);
    uint a = uint(saturate(alpha) * 255.0f);
    return (r) | (g << 8u) | (b << 16u) | (a << 24u);
}

/// Unpack a uint32 (R8G8B8A8) into float4 color.
inline float4 unpack_color(uint packed) {
    float r = float(packed & 0xFFu) / 255.0f;
    float g = float((packed >> 8u) & 0xFFu) / 255.0f;
    float b = float((packed >> 16u) & 0xFFu) / 255.0f;
    float a = float((packed >> 24u) & 0xFFu) / 255.0f;
    return float4(r, g, b, a);
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - Gaussian Splat: Orbit → Splat Emission Compute Kernel
// ═══════════════════════════════════════════════════════════════════════════════
//
// Same orbit computation as buddhabrotAccumulate, but instead of depositing into
// a density grid, each escaped orbit point is appended to a ring buffer of
// BuddhabrotSplat structs. Color is determined at emit time via the transfer
// function, so the render pass only needs position + packed color.

kernel void buddhabrotEmitSplats(
    device BuddhabrotSplat      *splatBuffer    [[buffer(BuddhabrotBufferIndexSplats)]],
    device atomic_uint          *atomicCounter  [[buffer(BuddhabrotBufferIndexAtomicCounter)]],
    constant BuddhabrotEmitUniforms &params     [[buffer(BuddhabrotBufferIndexUniforms)]],
    uint                         tid            [[thread_position_in_grid]])
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

        if (dot(z, z) > bailoutSq) {
            escaped = true;
            escapeIter = i;
            break;
        }
    }

    if (!escaped) return;

    // Compute color from escape iteration via 3-color palette
    float t = saturate(float(escapeIter) / float(max(params.maxIterations, 1u)));
    float3 color;
    if (t < 0.5f) {
        color = mix(params.colorLow, params.colorMid, t * 2.0f);
    } else {
        color = mix(params.colorMid, params.colorHigh, (t - 0.5f) * 2.0f);
    }
    // Alpha scales with how deep the orbit went before escaping
    float alpha = saturate(t * 2.0f + 0.1f);
    uint packedColor = pack_color(color, alpha);

    // Append each orbit point as a splat with orbit tangent
    uint maxSplats = params.maxSplatCount;
    for (uint i = 0; i < orbitLength; i++) {
        uint idx = atomic_fetch_add_explicit(atomicCounter, 1u, memory_order_relaxed) % maxSplats;
        splatBuffer[idx].position = orbit[i];
        splatBuffer[idx].packedColor = packedColor;

        // Compute orbit tangent via finite difference
        float3 tangent;
        if (orbitLength <= 1) {
            tangent = float3(0.0f);
        } else if (i == 0) {
            tangent = orbit[1] - orbit[0];
        } else if (i == orbitLength - 1) {
            tangent = orbit[i] - orbit[i - 1];
        } else {
            tangent = (orbit[i + 1] - orbit[i - 1]) * 0.5f;
        }
        splatBuffer[idx].tangentX = tangent.x;
        splatBuffer[idx].tangentY = tangent.y;
        splatBuffer[idx].tangentZ = tangent.z;
    }
}

/// Resets the atomic counter to zero. Dispatch with 1 thread.
kernel void buddhabrotClearSplatCounter(
    device atomic_uint *atomicCounter [[buffer(0)]],
    uint tid [[thread_position_in_grid]])
{
    if (tid == 0) {
        atomic_store_explicit(atomicCounter, 0u, memory_order_relaxed);
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - 3DGS: Depth Key Computation
// ═══════════════════════════════════════════════════════════════════════════════
//
// Converts each splat's world position to a sortable depth key (uint32).
// Uses left-eye view for sorting; the ordering is shared by both eyes.

/// Encode a float depth as a sortable uint32.
/// IEEE 754 floats sort correctly as uint32 when the sign bit is flipped.
/// For positive depths (which is all we have after negating z), this means
/// setting the MSB. For negative floats, all bits would be flipped — but
/// we clamp depth to positive, so we just flip the sign bit.
inline uint depth_to_sortable_uint(float depth) {
    uint bits = as_type<uint>(depth);
    // Flip sign bit so that positive floats sort in ascending order as uint32.
    // Larger uint = farther from camera.
    bits ^= 0x80000000u;
    return bits;
}

kernel void buddhabrotComputeDepthKeys(
    device const BuddhabrotSplat *splats        [[buffer(0)]],
    device RadixSortEntry        *sortEntries   [[buffer(1)]],
    constant DepthKeyUniforms    &params        [[buffer(2)]],
    uint                          tid           [[thread_position_in_grid]])
{
    if (tid >= params.activeSplatCount) return;

    float3 pos = splats[tid].position;
    float4 worldPos = params.volumeWorldMatrix * float4(pos, 1.0f);
    float4 viewPos = params.viewMatrix * worldPos;

    // Depth = -viewPos.z (positive values, larger = farther from camera)
    float depth = -viewPos.z;
    // Clamp to positive (anything behind the camera gets sorted to front)
    depth = max(depth, 0.0f);

    sortEntries[tid].key = depth_to_sortable_uint(depth);
    sortEntries[tid].value = tid;
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - GPU Radix Sort (8-bit radix, 256 bins, 4 passes for 32-bit keys)
// ═══════════════════════════════════════════════════════════════════════════════
//
// 3-kernel approach per pass:
//   1. radixHistogram    — each threadgroup builds a local 256-bin histogram
//   2. radixPrefixSum    — exclusive prefix sum across all threadgroup histograms
//   3. radixScatter      — scatter entries to sorted position using prefix sums
//
// After 4 passes (bits 0-7, 8-15, 16-23, 24-31), entries are sorted by key
// in ascending order = back-to-front depth.
//
// We flip the sort direction at render time by drawing instances in reverse
// order (instanceCount-1-instanceID) to get front-to-back for alpha compositing.
// Actually, we want back-to-front for correct alpha-over: we render far splats
// first so nearer ones composite on top. The ascending sort (by depth key where
// larger = farther) already gives us back-to-front order.
// Wait — for standard alpha-over compositing with premultiplied alpha, we
// accumulate front-to-back: out = out + (1-out.a) * src. But for simplicity
// and compatibility with hardware blending (which processes fragments in
// submission order), we sort BACK-TO-FRONT and use standard over:
//   dst' = src * alpha + dst * (1 - alpha)
// This is the classic painter's algorithm.
// Our ascending sort gives us indices [nearest, ..., farthest] so we
// should REVERSE the draw order: draw farthest first.
// Implementation: the render vertex shader accesses sorted indices as
//   sortedIndex = sortedEntries[activeSplatCount - 1 - instanceID].value
// to process in back-to-front order.

/// Kernel 1: Per-threadgroup histogram of the current 8-bit digit.
/// Each threadgroup processes a contiguous chunk of the input array.
/// Output: histogramBuffer[threadgroupIndex * 256 + digit] = count
kernel void radixHistogram(
    device const RadixSortEntry *entries      [[buffer(0)]],
    device uint                 *histogram    [[buffer(1)]],
    constant RadixSortUniforms  &params       [[buffer(2)]],
    uint                         tid          [[thread_position_in_grid]],
    uint                         tgId         [[threadgroup_position_in_grid]],
    uint                         localId      [[thread_position_in_threadgroup]])
{
    // Shared histogram within the threadgroup
    threadgroup uint localHist[RADIX_SORT_BIN_COUNT];

    // Initialize all 256 bins to zero — use a loop so partial threadgroups
    // (where threadcount < 256) still zero every element.
    for (uint i = localId; i < RADIX_SORT_BIN_COUNT; i += RADIX_SORT_THREADS_PER_GROUP) {
        localHist[i] = 0;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    // Each thread processes one element
    if (tid < params.activeSplatCount) {
        uint key = entries[tid].key;
        uint digit = (key >> params.bitOffset) & 0xFFu;
        atomic_fetch_add_explicit(
            (threadgroup atomic_uint *)&localHist[digit],
            1u,
            memory_order_relaxed
        );
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    // Write local histogram to global histogram buffer
    if (localId < RADIX_SORT_BIN_COUNT) {
        histogram[tgId * RADIX_SORT_BIN_COUNT + localId] = localHist[localId];
    }
}

/// Kernel 2: Global exclusive prefix sum across all threadgroup histograms.
/// Computes the global scatter offset for each (digit, threadgroup) pair.
/// Runs with a single threadgroup — serialized scan over all bins.
///
/// Layout: histogram[tgIdx * 256 + digit]
/// We want: for each digit d, prefix sum across all threadgroups.
/// Global offset for (tgIdx, digit) = sum of histogram[t * 256 + digit] for t < tgIdx
///                                    + sum of total counts for digits < d
///
/// We use a column-major scan: iterate digit 0..255, and within each digit
/// scan across threadgroups. This produces a globally sorted order where
/// all elements with digit 0 come first, then digit 1, etc.
kernel void radixPrefixSum(
    device uint                *histogram    [[buffer(0)]],
    constant RadixSortUniforms &params       [[buffer(1)]],
    uint                        tid          [[thread_position_in_grid]])
{
    // Single thread scans the entire histogram
    if (tid != 0) return;

    uint numTG = params.numThreadgroups;
    uint runningTotal = 0;

    for (uint digit = 0; digit < RADIX_SORT_BIN_COUNT; digit++) {
        for (uint tg = 0; tg < numTG; tg++) {
            uint idx = tg * RADIX_SORT_BIN_COUNT + digit;
            uint count = histogram[idx];
            histogram[idx] = runningTotal;
            runningTotal += count;
        }
    }
}

/// Kernel 3: Scatter entries to their sorted positions.
/// Each thread reads one entry, computes its digit, looks up its global offset
/// from the prefix-summed histogram, and writes to the output buffer.
/// Uses threadgroup atomics to handle multiple threads in the same threadgroup
/// that map to the same digit.
kernel void radixScatter(
    device const RadixSortEntry *entriesIn   [[buffer(0)]],
    device RadixSortEntry       *entriesOut  [[buffer(1)]],
    device uint                 *histogram   [[buffer(2)]],
    constant RadixSortUniforms  &params      [[buffer(3)]],
    uint                         tid         [[thread_position_in_grid]],
    uint                         tgId        [[threadgroup_position_in_grid]],
    uint                         localId     [[thread_position_in_threadgroup]])
{
    // Load global offsets for this threadgroup into shared memory.
    // Use a loop so partial threadgroups still load all 256 bins.
    threadgroup uint localOffsets[RADIX_SORT_BIN_COUNT];
    for (uint i = localId; i < RADIX_SORT_BIN_COUNT; i += RADIX_SORT_THREADS_PER_GROUP) {
        localOffsets[i] = histogram[tgId * RADIX_SORT_BIN_COUNT + i];
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    if (tid < params.activeSplatCount) {
        RadixSortEntry entry = entriesIn[tid];
        uint digit = (entry.key >> params.bitOffset) & 0xFFu;

        // Atomically increment the local offset to get this thread's unique position
        uint pos = atomic_fetch_add_explicit(
            (threadgroup atomic_uint *)&localOffsets[digit],
            1u,
            memory_order_relaxed
        );

        entriesOut[pos] = entry;
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - 3DGS: Instanced Rendering with Covariance Projection
// ═══════════════════════════════════════════════════════════════════════════════
//
// Proper 3D Gaussian Splatting: each splat has a 3D covariance matrix derived
// from the orbit tangent direction + global scale parameters. The vertex shader
// projects this to a 2D screen-space covariance via the Jacobian of the
// perspective projection, eigendecomposes the 2×2 matrix to get ellipse axes,
// and sizes the billboard quad to cover the 3σ bounding box.
//
// The fragment shader evaluates the 2D Gaussian in conic form and outputs
// premultiplied alpha for back-to-front alpha-over compositing.
//
// Sorted back-to-front by the GPU radix sort — instance 0 is the farthest splat.

struct BuddhabrotSplatVertexOut {
    float4 position [[position]];
    float4 color;
    float2 coordInSplat;             // Position within the splat quad in eigenspace
    float3 conic;                    // Inverse 2D covariance: (a, b, c) where M⁻¹ = [[a,b],[b,c]]
    float  splatOpacity;             // Per-splat opacity (from packed color alpha * global)
    uint   viewportIndex [[viewport_array_index]];
    uint   renderTargetIndex [[render_target_array_index]];
};

vertex BuddhabrotSplatVertexOut buddhabrotSplatVertex(
    uint                    vertexID   [[vertex_id]],
    uint                    instanceID [[instance_id]],
    ushort                  ampId      [[amplification_id]],
    constant BuddhabrotSplatRenderUniformsArray &uniformsArray [[buffer(0)]],
    device const RadixSortEntry   *sortedEntries  [[buffer(1)]],
    device const BuddhabrotSplat  *splats         [[buffer(2)]])
{
    BuddhabrotSplatRenderUniforms u = uniformsArray.uniforms[ampId];

    // Back-to-front: draw farthest first.
    // sortedEntries is in ascending key order (nearest first at index 0).
    // Reverse: farthest = activeSplatCount - 1 - instanceID
    uint sortedIdx = u.activeSplatCount - 1u - instanceID;
    uint splatIdx = sortedEntries[sortedIdx].value;
    BuddhabrotSplat splat = splats[splatIdx];

    // Quad corners: 2 triangles from 6 vertices
    float2 quadPositions[6] = {
        float2(-1.0f,  1.0f),
        float2(-1.0f, -1.0f),
        float2( 1.0f,  1.0f),
        float2( 1.0f,  1.0f),
        float2(-1.0f, -1.0f),
        float2( 1.0f, -1.0f)
    };
    float2 quadOffset = quadPositions[vertexID % 6];

    // --- 1. Transform splat to view space ---
    float4 worldPos = u.volumeWorldMatrix * float4(splat.position, 1.0f);
    float4 viewPos = u.viewMatrix * worldPos;
    float3 mean = viewPos.xyz;

    // Skip splats behind camera
    if (mean.z > -0.01f) {
        BuddhabrotSplatVertexOut out;
        out.position = float4(0.0f, 0.0f, -1.0f, 1.0f); // behind clip plane
        out.color = float4(0.0f);
        out.coordInSplat = float2(0.0f);
        out.conic = float3(1.0f, 0.0f, 1.0f);
        out.splatOpacity = 0.0f;
        out.viewportIndex = ampId;
        out.renderTargetIndex = ampId;
        return out;
    }

    // --- 2. Build 3D covariance from tangent + scale parameters ---
    float3 tangent = float3(splat.tangentX, splat.tangentY, splat.tangentZ);
    float tangentLen = length(tangent);

    // Build local coordinate frame from tangent
    float3 t, n1, n2;
    if (tangentLen > 1e-6f) {
        t = tangent / tangentLen;
    } else {
        t = float3(1.0f, 0.0f, 0.0f);
    }
    // Gram-Schmidt to get two perpendicular axes
    float3 up = abs(t.y) < 0.999f ? float3(0.0f, 1.0f, 0.0f) : float3(1.0f, 0.0f, 0.0f);
    n1 = normalize(cross(t, up));
    n2 = cross(t, n1);

    // Transform axes to view space (direction only)
    float3x3 MV = float3x3(
        (u.viewMatrix * u.volumeWorldMatrix * float4(t,  0.0f)).xyz,
        (u.viewMatrix * u.volumeWorldMatrix * float4(n1, 0.0f)).xyz,
        (u.viewMatrix * u.volumeWorldMatrix * float4(n2, 0.0f)).xyz
    );

    // Scale: tangent direction uses splatScaleAlongTangent, perpendicular uses splatScalePerp
    // Scale modulated by tangent length for natural orbit density variation
    float tScale = u.splatScaleAlongTangent * clamp(tangentLen * 0.5f + 0.5f, 0.2f, 3.0f);
    float pScale = u.splatScalePerp;
    float3 scales = float3(tScale, pScale, pScale);

    // Covariance Σ = R * S² * Rᵀ = (R*S) * (R*S)ᵀ = M * Mᵀ
    // where M = MV * diag(scales) — the columns of MV scaled
    float3x3 M = float3x3(
        MV[0] * scales.x,
        MV[1] * scales.y,
        MV[2] * scales.z
    );
    // 3D covariance in view space
    float3x3 Sigma = M * transpose(M);

    // --- 3. Project 3D covariance to 2D screen covariance ---
    // Jacobian of perspective projection at the splat's position:
    //   J = [[fx/z, 0, -fx*x/z²],
    //        [0, fy/z, -fy*y/z²]]
    // where fx, fy are focal lengths in pixels, derived from projection matrix
    float fx = u.projectionMatrix[0][0] * u.viewportWidth * 0.5f;
    float fy = u.projectionMatrix[1][1] * u.viewportHeight * 0.5f;

    float iz = 1.0f / mean.z;       // mean.z is negative, so iz is negative
    float iz2 = iz * iz;

    // 2D covariance = J * Σ * Jᵀ
    // Use the full 3×3 → 2×2 projection via the Jacobian
    // In Metal, float3x2 = 3 columns × 2 rows = 2×3 mathematical matrix
    float3x2 J = float3x2(
        float2(fx * iz,  0.0f),                           // column 0
        float2(0.0f,     fy * iz),                        // column 1
        float2(-fx * mean.x * iz2, -fy * mean.y * iz2)   // column 2
    );

    // Σ' = J * Σ * Jᵀ  (2×2 symmetric matrix)
    float3x2 JSigma = J * Sigma;           // float3x2 * float3x3 = float3x2
    float2x2 Sigma2D = JSigma * transpose(J); // float3x2 * float2x3 = float2x2

    // Add a small regularization term to prevent singular matrix
    Sigma2D[0][0] += 0.3f;
    Sigma2D[1][1] += 0.3f;

    // --- 4. Eigendecompose 2×2 symmetric matrix for ellipse axes ---
    float a = Sigma2D[0][0];
    float b = Sigma2D[0][1]; // = Sigma2D[1][0] since symmetric
    float d = Sigma2D[1][1];

    float trace = a + d;
    float det = a * d - b * b;
    // Prevent negative discriminant
    float disc = max(trace * trace * 0.25f - det, 0.0f);
    float sqrtDisc = sqrt(disc);

    float lambda1 = trace * 0.5f + sqrtDisc; // larger eigenvalue
    float lambda2 = max(trace * 0.5f - sqrtDisc, 0.01f); // smaller eigenvalue, clamped > 0

    // Eigenvectors of 2×2 symmetric matrix
    float2 v1;
    if (abs(b) > 1e-6f) {
        v1 = normalize(float2(lambda1 - d, b));
    } else {
        v1 = (a >= d) ? float2(1.0f, 0.0f) : float2(0.0f, 1.0f);
    }
    float2 v2 = float2(-v1.y, v1.x);

    // 3σ radius along each eigenvector (covers 99.7% of the Gaussian)
    float radius1 = 3.0f * sqrt(lambda1);
    float radius2 = 3.0f * sqrt(lambda2);

    // Clamp max screen-space radius to avoid huge quads
    float maxRadius = max(radius1, radius2);
    float clampScale = min(maxRadius, 1024.0f) / max(maxRadius, 1e-6f);
    radius1 *= clampScale;
    radius2 *= clampScale;

    // --- 5. Compute conic (inverse of 2D covariance) for fragment shader ---
    float invDet = 1.0f / max(det, 1e-6f);
    float3 conic = float3(d * invDet, -b * invDet, a * invDet);

    // --- 6. Position quad vertices ---
    // quadOffset is in [-1,1], scale by eigenvalue radii along eigenvector axes
    float2 screenOffset = v1 * (quadOffset.x * radius1) +
                          v2 * (quadOffset.y * radius2);

    // Project splat center to NDC
    float4 clipPos = u.projectionMatrix * viewPos;
    float2 ndcCenter = clipPos.xy / clipPos.w;

    // Convert pixel offset to NDC offset
    float2 ndcOffset = screenOffset * float2(2.0f / u.viewportWidth, 2.0f / u.viewportHeight);
    clipPos.xy = (ndcCenter + ndcOffset) * clipPos.w;

    // --- 7. Output ---
    float4 splatColor = unpack_color(splat.packedColor);

    BuddhabrotSplatVertexOut out;
    out.position = clipPos;
    out.color = float4(splatColor.rgb * u.brightnessScale, 1.0f);
    // coordInSplat: the actual pixel offset from splat center (for Gaussian eval)
    out.coordInSplat = screenOffset;
    out.conic = conic;
    out.splatOpacity = splatColor.a * u.opacity;
    out.viewportIndex = ampId;
    out.renderTargetIndex = ampId;
    return out;
}

struct BuddhabrotSplatFragmentOut {
    float4 color [[color(0)]];
};

fragment BuddhabrotSplatFragmentOut buddhabrotSplatFragment(
    BuddhabrotSplatVertexOut in [[stage_in]])
{
    // Evaluate 2D Gaussian using conic form (inverse covariance)
    float2 d = in.coordInSplat;
    float power = -0.5f * (in.conic.x * d.x * d.x +
                           2.0f * in.conic.y * d.x * d.y +
                           in.conic.z * d.y * d.y);

    // Discard fragments with negligible contribution
    if (power < -4.0f) discard_fragment(); // exp(-4) ≈ 0.018

    float gaussian = exp(power);
    float alpha = min(in.splatOpacity * gaussian, 0.99f);

    // Discard near-zero alpha
    if (alpha < 1.0f / 255.0f) discard_fragment();

    // Premultiplied alpha output for back-to-front compositing
    BuddhabrotSplatFragmentOut out;
    out.color = float4(in.color.rgb * alpha, alpha);
    return out;
}
