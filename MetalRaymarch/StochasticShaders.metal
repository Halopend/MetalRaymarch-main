//
//  StochasticShaders.metal
//  MetalRaymarch
//
//  Stochastic rendering pipeline for progressive refinement of complex scenes.
//  When real-time rendering isn't achievable, this accumulates multiple jittered
//  samples over time to produce a high-quality converged image.
//
//  Architecture:
//  1. StochasticRaymarch: Renders with per-pixel sub-pixel jitter, outputs to accumulation buffer
//  2. AccumulateBlend: Blends new sample with running average (1/N weighting)
//  3. ResolveToScreen: Copies accumulated result to final drawable
//
//  Usage:
//  - Frame 0: Clear accumulation buffer, render first sample
//  - Frame 1-N: Render with different jitter, blend with weight 1/(frameCount+1)
//  - Scene change: Reset to frame 0
//

#include <metal_stdlib>
#include <simd/simd.h>
#import "ShaderTypes.h"

using namespace metal;

// ============================================================================
// STOCHASTIC UNIFORMS
// ============================================================================

struct StochasticUniforms {
    // Standard uniforms (same as main shader)
    float4x4 projectionMatrix;
    float4x4 modelViewMatrix;
    float4x4 inverseModelViewMatrix;
    float4x4 inverseProjectionMatrix;
    float4x4 viewMatrix;
    float4x4 inverseViewMatrix;
    float time;
    float minDistance;
    float fractalScale;
    int fractalIterations;
    int maxRaySteps;
    float foldingLimit;
    float sphereRadius;
    float safetyBubbleRadius;
    int safetyBubbleEnabled;
    
    // Stochastic-specific
    int frameCount;           // Current accumulation frame (0 = first sample)
    int maxFrames;            // Maximum frames to accumulate
    float2 jitterOffset;      // Pre-computed sub-pixel jitter for this frame
    float blendWeight;        // 1.0 / (frameCount + 1) for running average
    
    // Precomputed fractal params
    PrecomputedFractalParams precomputedFractal;
    PrecomputedLighting precomputedLighting;
    ColorSchemeParams colorScheme;
};

// ============================================================================
// PSEUDO-RANDOM NUMBER GENERATION
// ============================================================================

// High-quality hash for stochastic sampling (PCG-based)
inline uint pcg_hash(uint input) {
    uint state = input * 747796405u + 2891336453u;
    uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}

// Generate [0,1) float from seed
inline float rand_float(uint seed) {
    return float(pcg_hash(seed)) / float(0xFFFFFFFFu);
}

// Generate 2D jitter in [-0.5, 0.5] range for sub-pixel sampling
inline float2 get_pixel_jitter(uint2 pixel_coord, uint frame_index) {
    // Combine pixel position and frame for unique seed per pixel per frame
    uint seed = pixel_coord.x + pixel_coord.y * 65536u + frame_index * 16777216u;
    float jx = rand_float(seed) - 0.5;
    float jy = rand_float(seed + 1u) - 0.5;
    return float2(jx, jy);
}

// Halton sequence for low-discrepancy sampling (better convergence than pure random)
inline float halton(uint index, uint base) {
    float f = 1.0;
    float r = 0.0;
    uint i = index;
    while (i > 0u) {
        f = f / float(base);
        r = r + f * float(i % base);
        i = i / base;
    }
    return r;
}

// 2D Halton jitter (bases 2 and 3 for good distribution)
inline float2 get_halton_jitter(uint frame_index) {
    return float2(
        halton(frame_index + 1u, 2u) - 0.5,
        halton(frame_index + 1u, 3u) - 0.5
    );
}

// ============================================================================
// SIMPLIFIED MANDELBOX SDF (for stochastic shader)
// ============================================================================

// Box fold operation
inline float3 boxFold(float3 z, float foldingLimit) {
    return clamp(z, -foldingLimit, foldingLimit) * 2.0 - z;
}

// Sphere fold operation  
inline void sphereFold(thread float3 &z, thread float &dz, float minRadius2, float fixedRadius2) {
    float r2 = dot(z, z);
    if (r2 < minRadius2) {
        float temp = fixedRadius2 / minRadius2;
        z *= temp;
        dz *= temp;
    } else if (r2 < fixedRadius2) {
        float temp = fixedRadius2 / r2;
        z *= temp;
        dz *= temp;
    }
}

// Mandelbox distance estimator
inline float mandelboxDE(float3 pos, 
                         float fractalScale,
                         float foldingLimit,
                         float sphereRadius,
                         float minDistance,
                         int iterations) {
    float3 z = pos;
    float dr = 1.0;
    
    float minRadius2 = minDistance;
    float fixedRadius2 = sphereRadius * sphereRadius;
    
    for (int i = 0; i < iterations; i++) {
        z = boxFold(z, foldingLimit);
        sphereFold(z, dr, minRadius2, fixedRadius2);
        z = fractalScale * z + pos;
        dr = dr * abs(fractalScale) + 1.0;
    }
    
    return length(z) / abs(dr);
}

// ============================================================================
// RAY GENERATION WITH JITTER
// ============================================================================

inline float3 getRayDirection(float2 uv, 
                              float2 jitter,
                              float2 resolution,
                              float4x4 inverseProjection,
                              float4x4 inverseView) {
    // Apply sub-pixel jitter (in pixel units, then normalized)
    float2 jitteredUV = uv + jitter / resolution;
    
    // Convert to clip space [-1, 1]
    float2 clip = jitteredUV * 2.0 - 1.0;
    
    // Unproject to view space
    float4 viewSpace = inverseProjection * float4(clip, 1.0, 1.0);
    viewSpace.xyz /= viewSpace.w;
    
    // Transform to world space
    float3 worldDir = normalize((inverseView * float4(viewSpace.xyz, 0.0)).xyz);
    
    return worldDir;
}

// ============================================================================
// STOCHASTIC RAYMARCH KERNEL
// ============================================================================

kernel void stochasticRaymarchKernel(
    texture2d<float, access::write> outputTexture [[texture(0)]],
    texture2d<float, access::read> accumulationTexture [[texture(1)]],
    constant StochasticUniforms &uniforms [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    // Bounds check
    if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) {
        return;
    }
    
    float2 resolution = float2(outputTexture.get_width(), outputTexture.get_height());
    float2 uv = (float2(gid) + 0.5) / resolution;
    
    // ═══════════════════════════════════════════════════════════════════════════
    // FOVEATED PRIORITY ACCUMULATION
    // Accumulate from center outward: foveal region first, then expand.
    // This mimics how the eye works - sharp center, blurry periphery.
    // Frame 0-3: progressive radius expansion (25%, 50%, 75%, 100%)
    // ═══════════════════════════════════════════════════════════════════════════
    float2 centerOffset = uv - float2(0.5);
    // Elliptical distance (account for typical VR aspect ratio ~1.0)
    float fovealDist = length(centerOffset);
    
    // Progressive radius: starts at 0.25, grows to 1.0 over first 4 frames
    // After frame 4, all pixels render every frame for full accumulation
    float currentRadius = min(1.0, 0.25 + float(uniforms.frameCount) * 0.25);
    
    // Skip this pixel if outside current accumulation radius (early frames only)
    if (uniforms.frameCount < 4 && fovealDist > currentRadius * 0.7) {
        // Outside current radius - copy previous value (or black if frame 0)
        if (uniforms.frameCount > 0) {
            float4 prevColor = accumulationTexture.read(gid);
            outputTexture.write(prevColor, gid);
        } else {
            outputTexture.write(float4(0.0, 0.0, 0.0, 1.0), gid);
        }
        return;
    }
    
    // Get jitter for this pixel and frame
    // Use Halton sequence for better convergence, add per-pixel variation
    float2 baseJitter = get_halton_jitter(uint(uniforms.frameCount));
    float2 pixelVariation = get_pixel_jitter(gid, uint(uniforms.frameCount)) * 0.25; // Small per-pixel variation
    float2 jitter = baseJitter + pixelVariation;
    
    // Generate ray with jitter
    float3 rayOrigin = uniforms.inverseViewMatrix.columns[3].xyz;
    float3 rayDir = getRayDirection(uv, jitter, resolution, 
                                     uniforms.inverseProjectionMatrix, 
                                     uniforms.inverseViewMatrix);
    
    // Raymarch parameters
    float totalDistance = 0.0;
    float3 currentPos = rayOrigin;
    float minDist = 1e10;
    int hitSteps = 0;
    bool hit = false;
    
    float maxDistance = 50.0;
    float hitThreshold = 0.0001;
    
    // Main raymarch loop
    for (int i = 0; i < uniforms.maxRaySteps; i++) {
        currentPos = rayOrigin + rayDir * totalDistance;
        
        float dist = mandelboxDE(currentPos,
                                  uniforms.fractalScale,
                                  uniforms.foldingLimit,
                                  uniforms.sphereRadius,
                                  uniforms.minDistance,
                                  uniforms.fractalIterations);
        
        minDist = min(minDist, dist);
        
        if (dist < hitThreshold) {
            hit = true;
            hitSteps = i;
            break;
        }
        
        if (totalDistance > maxDistance) {
            break;
        }
        
        totalDistance += dist * 0.9; // Slight under-step for stability
        hitSteps = i;
    }
    
    // Simple coloring based on iteration depth and distance
    float3 color;
    if (hit) {
        // Compute simple normal via gradient
        float eps = 0.001;
        float3 n = normalize(float3(
            mandelboxDE(currentPos + float3(eps, 0, 0), uniforms.fractalScale, uniforms.foldingLimit, uniforms.sphereRadius, uniforms.minDistance, uniforms.fractalIterations) -
            mandelboxDE(currentPos - float3(eps, 0, 0), uniforms.fractalScale, uniforms.foldingLimit, uniforms.sphereRadius, uniforms.minDistance, uniforms.fractalIterations),
            mandelboxDE(currentPos + float3(0, eps, 0), uniforms.fractalScale, uniforms.foldingLimit, uniforms.sphereRadius, uniforms.minDistance, uniforms.fractalIterations) -
            mandelboxDE(currentPos - float3(0, eps, 0), uniforms.fractalScale, uniforms.foldingLimit, uniforms.sphereRadius, uniforms.minDistance, uniforms.fractalIterations),
            mandelboxDE(currentPos + float3(0, 0, eps), uniforms.fractalScale, uniforms.foldingLimit, uniforms.sphereRadius, uniforms.minDistance, uniforms.fractalIterations) -
            mandelboxDE(currentPos - float3(0, 0, eps), uniforms.fractalScale, uniforms.foldingLimit, uniforms.sphereRadius, uniforms.minDistance, uniforms.fractalIterations)
        ));
        
        // Basic diffuse lighting
        float3 lightDir = normalize(float3(1.0, 1.0, 0.5));
        float diffuse = max(dot(n, lightDir), 0.0);
        float ambient = 0.2;
        
        // Color based on position and iteration
        float3 baseColor = 0.5 + 0.5 * cos(float3(0.0, 2.0, 4.0) + currentPos.x * 2.0);
        color = baseColor * (ambient + diffuse * 0.8);
        
        // AO approximation from step count
        float ao = 1.0 - float(hitSteps) / float(uniforms.maxRaySteps);
        color *= ao;
    } else {
        // Background - subtle gradient
        color = mix(float3(0.02, 0.02, 0.05), float3(0.1, 0.08, 0.15), uv.y);
        
        // Glow from near-misses
        float glow = exp(-minDist * 10.0) * 0.5;
        color += float3(0.3, 0.2, 0.4) * glow;
    }
    
    // Accumulation blending
    float4 newSample = float4(color, 1.0);
    
    if (uniforms.frameCount == 0) {
        // First frame - just write the sample
        outputTexture.write(newSample, gid);
    } else {
        // Blend with accumulated result using running average
        float4 accumulated = accumulationTexture.read(gid);
        float weight = uniforms.blendWeight; // 1.0 / (frameCount + 1)
        float4 blended = mix(accumulated, newSample, weight);
        outputTexture.write(blended, gid);
    }
}

// ============================================================================
// ACCUMULATION COPY KERNEL
// Copy current output to accumulation buffer for next frame
// ============================================================================

kernel void copyToAccumulationKernel(
    texture2d<float, access::read> sourceTexture [[texture(0)]],
    texture2d<float, access::write> accumulationTexture [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= sourceTexture.get_width() || gid.y >= sourceTexture.get_height()) {
        return;
    }
    
    float4 color = sourceTexture.read(gid);
    accumulationTexture.write(color, gid);
}

// ============================================================================
// RESOLVE TO DRAWABLE
// Apply final tone mapping and copy to drawable texture
// ============================================================================

kernel void resolveStochasticKernel(
    texture2d<float, access::read> accumulationTexture [[texture(0)]],
    texture2d<float, access::write> outputTexture [[texture(1)]],
    constant int &frameCount [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) {
        return;
    }
    
    float4 accumulated = accumulationTexture.read(gid);
    float3 color = accumulated.rgb;
    
    // Simple tone mapping (Reinhard)
    color = color / (1.0 + color);
    
    // Gamma correction
    color = pow(color, float3(1.0 / 2.2));
    
    // Show accumulation progress indicator in corner
    float2 resolution = float2(outputTexture.get_width(), outputTexture.get_height());
    float2 uv = float2(gid) / resolution;
    
    // Progress bar at bottom
    if (uv.y > 0.98) {
        float progress = float(frameCount + 1) / 64.0; // Assume 64 max frames
        if (uv.x < progress) {
            color = mix(color, float3(0.2, 0.8, 0.3), 0.7); // Green progress
        }
    }
    
    outputTexture.write(float4(color, 1.0), gid);
}

// ============================================================================
// CLEAR ACCUMULATION BUFFER
// ============================================================================

kernel void clearAccumulationKernel(
    texture2d<float, access::write> accumulationTexture [[texture(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= accumulationTexture.get_width() || gid.y >= accumulationTexture.get_height()) {
        return;
    }
    
    accumulationTexture.write(float4(0.0, 0.0, 0.0, 0.0), gid);
}

// ============================================================================
// VARIANCE ESTIMATION (for adaptive sampling)
// Tracks pixel variance to focus samples where needed
// ============================================================================

kernel void computeVarianceKernel(
    texture2d<float, access::read> currentFrame [[texture(0)]],
    texture2d<float, access::read> accumulationTexture [[texture(1)]],
    texture2d<float, access::read_write> varianceTexture [[texture(2)]],
    constant int &frameCount [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= currentFrame.get_width() || gid.y >= currentFrame.get_height()) {
        return;
    }
    
    if (frameCount < 2) {
        varianceTexture.write(float4(1.0), gid); // High variance initially
        return;
    }
    
    float4 current = currentFrame.read(gid);
    float4 accumulated = accumulationTexture.read(gid);
    
    // Compute luminance difference as variance proxy
    float lumCurrent = dot(current.rgb, float3(0.299, 0.587, 0.114));
    float lumAccum = dot(accumulated.rgb, float3(0.299, 0.587, 0.114));
    float variance = abs(lumCurrent - lumAccum);
    
    // Decay variance over frames
    float prevVariance = varianceTexture.read(gid).r;
    float blendedVariance = mix(prevVariance, variance, 0.3);
    
    varianceTexture.write(float4(blendedVariance, 0.0, 0.0, 1.0), gid);
}
