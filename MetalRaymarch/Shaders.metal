//
//  Shaders.metal
//
// Debug flag for depth visualization (set to 1 to enable)
#define DEBUG_DEPTH_VISUALIZATION 0


// File for Metal kernel and shader functions
#include <metal_stdlib>
#include <simd/simd.h>

// Including header shared between this Metal shader code and Swift/C code executing Metal API commands
#import "ShaderTypes.h"

using namespace metal;

typedef struct
{
    float3 position [[attribute(VertexAttributePosition)]];
    float2 texCoord [[attribute(VertexAttributeTexcoord)]];
} Vertex;

typedef struct
{
    float4 color [[color(0)]];
    float depth [[depth(any)]]; // Output clip-space depth for async timewarp
} FragmentOutput;  

typedef struct
{
    float4 position [[position]];
    float2 texCoord;
    float3 modelPos;
} ColorInOut;

vertex ColorInOut vertexShader(Vertex in [[stage_in]],
                               ushort ampId [[amplification_id]],
                               constant UniformsArray & uniformsArray [[ buffer(BufferIndexUniforms) ]])
{
    ColorInOut out;

    Uniforms uniforms = uniformsArray.uniforms[ampId];
    
    float4 position = float4(in.position, 1);
    out.position = uniforms.projectionMatrix * uniforms.modelViewMatrix * position;
    out.texCoord = in.texCoord;
    out.modelPos = in.position;
    
    return out;
}

// --- Fractal Code Port ---
// Spatial Rendering optimizations for visionOS

constant float3 sunDir = float3(0.3235, 0.0924, 0.2773); // normalized(0.35, 0.1, 0.3)
constant float3 sunColour = float3(1.0, 0.95, 0.8);
constant float kPowEpsilon = 1e-6f;
constant half kPowEpsilonHalf = 1e-4h;

// === ADAPTIVE HIERARCHICAL CONSTANTS ===
constant float BOUNDING_SPHERE_RADIUS = 3.5f;  // Skip rays outside this
constant float ADAPTIVE_FAR_THRESHOLD = 50.0f;   // Use 8x8 tiles beyond this distance
constant float ADAPTIVE_MED_THRESHOLD = 15.0f;   // Use 4x4 tiles beyond this
constant float ADAPTIVE_NEAR_THRESHOLD = 4.0f;   // Use 2x2 tiles beyond this

// === BOUNDING SPHERE EARLY EXIT ===
// Returns -1 if ray misses sphere, otherwise returns entry distance
inline float rayIntersectBoundingSphere(float3 ro, float3 rd, float3 center, float radius) {
    float3 oc = ro - center;
    float b = dot(oc, rd);
    float c = dot(oc, oc) - radius * radius;
    float discriminant = b * b - c;
    if (discriminant < 0.0) return -1.0;  // Miss
    float sqrtD = sqrt(discriminant);
    float t = -b - sqrtD;  // Near intersection
    return (t > 0.0) ? t : max(-b + sqrtD, 0.0);  // Far intersection if inside
}

// === ADAPTIVE LEVEL SELECTION ===
// Returns: 0 = 8x8 (far), 1 = 4x4 (medium), 2 = 2x2 (near), 3 = per-pixel (surface)
inline int selectAdaptiveLevel(float coarseT) {
    if (coarseT > ADAPTIVE_FAR_THRESHOLD || coarseT < 0.0) return 0;  // 8x8
    if (coarseT > ADAPTIVE_MED_THRESHOLD) return 1;  // 4x4
    if (coarseT > ADAPTIVE_NEAR_THRESHOLD) return 2;  // 2x2
    return 3;  // Per-pixel for surface detail
}

// Blue noise approximation for temporal stability (better than white noise for reprojection)
float blueNoise(float2 uv, float time) {
    // Interleaved gradient noise - more temporally stable than random
    float3 magic = float3(0.06711056, 0.00583715, 52.9829189);
    float noise = fract(magic.z * fract(dot(uv, magic.xy)));
    // Add small temporal variation to prevent static patterns
    return fract(noise + time * 0.1);
}
constant float SCALE = 2.8;

float hash(float n) { return fract(sin(n) * 753.5453123); }

float noise(float3 x) {
    float3 p = floor(x);
    float3 f = fract(x);
    f = f * f * (3.0 - 2.0 * f);
    float n = p.x + p.y * 157.0 + 113.0 * p.z;
    return mix(mix(mix(hash(n +   0.0), hash(n +   1.0), f.x),
                   mix(hash(n + 157.0), hash(n + 158.0), f.x), f.y),
               mix(mix(hash(n + 113.0), hash(n + 114.0), f.x),
                   mix(hash(n + 270.0), hash(n + 271.0), f.x), f.y), f.z);
}

float GetSky(float3 pos)
{
    pos *= 2.3;
    float t = noise(pos);
    return t;
}

struct FractalParams {
    float4 scale;
    float absScalem1;
    float absScalePow;
    float minRadius2;
};

inline FractalParams makeFractalParams(float minRad2Val, float fractalScale, float sphereRadius, int iterations) {
    FractalParams params;
    params.scale = float4(fractalScale) / minRad2Val;
    params.scale.w = abs(params.scale.w);
    params.absScalem1 = abs(fractalScale - 1.0);
    params.absScalePow = powr(max(abs(fractalScale), kPowEpsilon), float(1 - iterations));
    params.minRadius2 = sphereRadius * sphereRadius;
    return params;
}

// Optimized branchless Map function
float Map(float3 pos, FractalParams params, float foldingLimit, int iterations) 
{
    float4 p = float4(pos, 1.0);
    float4 p0 = p;

    for (int i = 0; i < iterations; i++)
    {
        // Box fold (optimized)
        p.xyz = clamp(p.xyz, -foldingLimit, foldingLimit) * 2.0 - p.xyz;

        // Branchless sphere fold - much faster on GPU
        float r2 = dot(p.xyz, p.xyz);
        float t = clamp(1.0 / max(r2, params.minRadius2), 1.0, 1.0/params.minRadius2);
        p *= t;

        p = p * params.scale + p0;
    }
    return (length(p.xyz) - params.absScalem1) / p.w - params.absScalePow;
}

// Optimized colour function using half precision
half3 Colour(float3 pos, float sphereR, float gTime, float quality, float minRad2Val, float fractalScale, float colorMix, float foldingLimit, float sphereRadius, int colorIters) 
{
    float4 scale = float4(fractalScale) / minRad2Val;
    scale.w = abs(scale.w);
    float minRadius2 = sphereRadius * sphereRadius;

    float3 p = pos;
    float3 p0 = p;
    float trap = 1.0;
    
    int steps = max(int(float(colorIters) * quality), 2);
    for (int i = 0; i < steps; i++)
    {
        p = clamp(p, -foldingLimit, foldingLimit) * 2.0 - p;
        float r2 = dot(p, p);
        p *= clamp(1.0 / max(r2, minRadius2), 1.0, 1.0/minRadius2);
        p = p * scale.xyz + p0;
        trap = min(trap, r2);
    }
    
    half2 c = saturate(half2(0.3333h * log(half(dot(p,p))) - 1.0h, sqrt(half(trap))));
    
    // Half precision colors
    half3 col1 = half3(0.8h, 0.0h, 0.0h);
    half3 col2 = half3(0.4h, 0.4h, 0.5h);
    half3 col3 = half3(0.5h, 0.3h, 0.0h);
    
    half3 finalColor = mix(mix(col1, col2, c.y), col3, c.x);
    half3 altColor = half3(c.x, c.y, 0.5h + 0.3h * c.y);
    return mix(finalColor, altColor, half(colorMix));
}

// Fast normal using forward differences (3 Map calls instead of 4)
float3 GetNormal(float3 pos, float distance, FractalParams params, float foldingLimit, int iterations)
{
    float e = distance * 0.001;
    float d = Map(pos, params, foldingLimit, iterations);
    return normalize(float3(
        Map(pos + float3(e,0,0), params, foldingLimit, iterations) - d,
        Map(pos + float3(0,e,0), params, foldingLimit, iterations) - d,
        Map(pos + float3(0,0,e), params, foldingLimit, iterations) - d
    ));
}

// Reduced binary subdivision (4 iterations instead of 6)
float BinarySubdivision(float3 rO, float3 rD, float2 t, FractalParams params, float foldingLimit, int iterations)
{
    float halfwayT;
    for (int i = 0; i < 4; i++)
    {
        halfwayT = (t.x + t.y) * 0.5;
        float d = Map(rO + halfwayT*rD, params, foldingLimit, iterations); 
        t = mix(float2(t.x, halfwayT), float2(halfwayT, t.y), step(0.0005, d));
    }
    return halfwayT;
}

// === SUPER-COARSE RAYMARCH (for 8x8 tiles) ===
// Very fast approximate raymarch - 12 steps with aggressive stepping
// Used for initial distance estimation in large tiles
float SceneSuperCoarse(float3 rO, float3 rD, float startT, float foldingLimit, FractalParams params, int iterations)
{
    float t = max(startT, 0.05);
    
    // Very few steps with 1.5x over-relaxation for speed
    for(int j = 0; j < 12; j++)
    {
        float3 p = rO + t * rD;
        float h = Map(p, params, foldingLimit, iterations);
        
        // Loose threshold - we just need approximate distance
        if(h < 0.1) return t;
        
        if (t > 80.0) return 1000.0;  // Limit search range
        
        // Aggressive over-relaxation: step 1.5x the SDF value
        t += h * 1.5;
    }
    
    return 1000.0;
}

// === COARSE RAYMARCH ===
// Fast approximate raymarch for hierarchical rendering
// Uses fewer iterations but standard stepping to find approximate hit distance
float SceneCoarse(float3 rO, float3 rD, float foldingLimit, FractalParams params, int iterations)
{
    float t = 0.05;
    
    // More steps with standard stepping for reliability
    for(int j = 0; j < 24; j++)
    {
        float3 p = rO + t * rD;
        float h = Map(p, params, foldingLimit, iterations);
        
        // Tighter threshold to get closer before handing off
        if(h < 0.02) return t;
        
        if (t > 12.0) return 1000.0;
        
        // Standard sphere tracing - no overstepping
        t += h;
    }
    
    return 1000.0;
}

// === FINE RAYMARCH FROM STARTING POINT ===
// Refines from a known starting distance (from coarse pass or neighbor)
float2 SceneFromStart(float3 rO, float3 rD, float startT, float2 fragCoord, float quality, int maxStepsParam, float glowIntensity, float foldingLimit, FractalParams params, int iterations, float time)
{
    float dither = blueNoise(fragCoord, time) * 0.01;
    
    // Back up further from the starting point to ensure we don't miss the surface
    float t = max(0.01, startT - 0.3) + dither;
    
    float glow = 0.0;
    // More steps for reliability
    int maxSteps = max(int(float(maxStepsParam) * quality * 0.5), 8);
    
    for(int j = 0; j < maxSteps; j++)
    {
        float threshold = 0.0005 + t * 0.0006;
        
        float3 p = rO + t * rD;
        float h = Map(p, params, foldingLimit, iterations);
        
        if(h < threshold)
        {
            return float2(t, saturate(glow * 0.25));
        }
        
        if (t > startT + 2.0) break; // Don't search too far past expected hit
        
        glow += saturate(0.04 - h) * glowIntensity;
        
        // Standard sphere tracing
        t += h;
    }
    
    return float2(1000.0, saturate(glow * 0.25));
}

// Standard sphere tracing - reliable, no aggressive optimizations
float2 Scene(float3 rO, float3 rD, float2 fragCoord, float quality, int maxStepsParam, float glowIntensity, float foldingLimit, FractalParams params, int iterations, float time)
{
    // Use temporally stable blue noise dithering for reprojection
    float dither = blueNoise(fragCoord, time) * 0.015;
    float t = 0.05 + dither;
    
    float glow = 0.0;
    int maxSteps = max(int(float(maxStepsParam) * quality), 4);
    
    for(int j = 0; j < maxSteps; j++)
    {
        // Distance-adaptive threshold (standard approach)
        float threshold = 0.0005 + t * 0.0008 + (1.0 - quality) * 0.003;
        
        float3 p = rO + t * rD;
        float h = Map(p, params, foldingLimit, iterations);
        
        // Hit detection
        if(h < threshold)
        {
            return float2(t, saturate(glow * 0.25));
        }
        
        if (t > 12.0) break;
        
        // Accumulate glow
        glow += saturate(0.04 - h) * glowIntensity;
        
        // Standard sphere tracing: step by the SDF value
        // This is guaranteed safe for a valid SDF
        t += h;
    }
    
    return float2(1000.0, saturate(glow * 0.25));
}

// Simplified post effects using half precision
half3 PostEffects(half3 rgb, half2 xy)
{
    // Combined contrast/saturation/brightness in fewer ops
    half luma = dot(rgb, half3(0.2126h, 0.7152h, 0.0722h));
    rgb = mix(half3(luma), rgb, 1.5h) * 1.5h; // saturation + brightness
    rgb = mix(half3(0.5h), rgb, 1.08h);       // contrast
    
    // Simplified vignette
    half2 q = xy * (1.0h - xy);
    half vignetteBase = max(16.0h * q.x * q.y, kPowEpsilonHalf);
    rgb *= 0.5h + 0.5h * powr(vignetteBase, 0.2h);
    
    // Gamma
    return powr(max(rgb, half3(kPowEpsilonHalf)), half3(0.47h));
}

// Ultra-fast shadow with over-relaxation
float Shadow(float3 ro, float3 rd, float quality, float foldingLimit, FractalParams params, int iterations)
{
    // Skip shadows in extreme periphery
    if (quality < 0.25) return 0.65;
    
    float res = 1.0;
    float t = 0.08;
    float prevH = 1e10;
    
    // Very few steps with aggressive over-relaxation
    int steps = int(quality * 2.0) + 1; // 1-3 steps
    
    for (int i = 0; i < steps; i++)
    {
        float h = Map(ro + rd * t, params, foldingLimit, iterations);
        
        // Soft shadow calculation
        res = min(res, 10.0 * h / t);
        
        // Early exit if definitely in shadow
        if (res < 0.02) return 0.0;
        
        // Over-relaxation: step more aggressively when safe
        float relax = step(prevH * 0.8, h);
        float step = mix(h, h * 1.5, relax);
        t += max(step, 0.15);
        prevH = h;
        
        // Don't trace too far for shadows
        if (t > 4.0) break;
    }
    
    return saturate(res);
}

// === TILE-BASED RAYMARCHING (4x4 pixel groups) ===
// One DE raymarch per tile, per-pixel normals for smooth shading
// Reduces DE overhead by ~16x while maintaining surface detail

#define TILE_SIZE 4

// Shared tile data structure for threadgroup communication
struct TileHitData {
    float hitDistance;      // Distance along center ray
    float3 hitPoint;        // World-space hit position (center)
    float glow;             // Glow accumulation
    bool didHit;            // Whether the tile hit geometry
};

// Compute the ray direction for a given pixel in clip/NDC space
// This requires the inverse projection matrix
float3 computeRayDirection(float2 pixelCoord, float2 resolution, float4x4 invProjMatrix, float4x4 invViewMatrix) {
    // Convert pixel to NDC (-1 to 1)
    float2 ndc = (pixelCoord / resolution) * 2.0 - 1.0;
    ndc.y = -ndc.y; // Flip Y for Metal
    
    // Unproject to view space (at z = -1)
    float4 viewPos = invProjMatrix * float4(ndc, -1.0, 1.0);
    viewPos /= viewPos.w;
    
    // Transform to world space and normalize
    float3 worldDir = (invViewMatrix * float4(viewPos.xyz, 0.0)).xyz;
    return normalize(worldDir);
}

// Per-pixel normal calculation - fast tetrahedron method
float3 GetNormalFast(float3 pos, float distance, FractalParams params, float foldingLimit, int iterations)
{
    float e = max(distance * 0.0005, 0.0001);
    
    // Tetrahedron technique - 4 samples instead of 6
    float2 h = float2(1.0, -1.0) * e;
    return normalize(
        h.xyy * Map(pos + h.xyy, params, foldingLimit, iterations) +
        h.yyx * Map(pos + h.yyx, params, foldingLimit, iterations) +
        h.yxy * Map(pos + h.yxy, params, foldingLimit, iterations) +
        h.xxx * Map(pos + h.xxx, params, foldingLimit, iterations)
    );
}

// Forward declaration needed by compute kernels
float3 CameraPath(float t);

// CameraPath implementation (also used by compute kernels)
float3 CameraPath(float t)
{
    float3 p = float3(-.78 + 3. * sin(2.14*t),.05+2.5 * sin(.942*t+1.3),.05 + 3.5 * cos(3.594*t) );
    return p;
}

// === HIERARCHICAL TILE-BASED COMPUTE KERNEL ===
// Two-level approach for 4x4 tiles:
// 1. Thread (1,1) does COARSE raymarch to find approximate starting point
// 2. All 16 threads do FINE raymarch from that starting point
// Results in ~10-20x fewer total DE evaluations
// TileUniforms is defined in ShaderTypes.h for Swift/Metal interop

kernel void tileRaymarchKernel(
    uint2 tileId [[threadgroup_position_in_grid]],
    uint2 localId [[thread_position_in_threadgroup]],
    uint localIndex [[thread_index_in_threadgroup]],
    constant TileUniforms& uniforms [[buffer(0)]],
    texture2d_array<float, access::write> outputTexture [[texture(0)]]
) {
    // Calculate pixel coordinates for this thread
    uint2 pixelCoord = tileId * TILE_SIZE + localId;
    
    // Early exit if outside texture bounds
    if (pixelCoord.x >= uint(uniforms.resolution.x) || pixelCoord.y >= uint(uniforms.resolution.y)) {
        return;
    }
    
    // --- Threadgroup shared memory ---
    threadgroup float sharedCoarseT;
    threadgroup float3 sharedCenterRayDir;
    threadgroup FractalParams sharedFractalParams;
    threadgroup FractalParams sharedShadowParams;
    threadgroup float3 sharedCameraPos;
    threadgroup float4x4 sharedInvProjMatrix;
    threadgroup float4x4 sharedInvViewMatrix;
    threadgroup float3 sharedRayDirs[16];

    int lodIterations = max(uniforms.fractalIterations, 2);

    // Leader thread precomputes shared data
    if (localId.x == 1 && localId.y == 1) {
        sharedFractalParams = makeFractalParams(uniforms.minDistance, uniforms.fractalScale, uniforms.sphereRadius, lodIterations);
        int shadowIterations = max(lodIterations - 2, 2);
        sharedShadowParams = makeFractalParams(uniforms.minDistance, uniforms.fractalScale, uniforms.sphereRadius, shadowIterations);
        sharedCameraPos = uniforms.cameraPos;
        sharedInvProjMatrix = uniforms.invProjMatrix;
        sharedInvViewMatrix = uniforms.invViewMatrix;
        // Precompute ray directions for all 16 threads in the tile
        for (uint i = 0; i < 16; ++i) {
            uint2 lid = uint2(i % 4, i / 4);
            uint2 pc = tileId * TILE_SIZE + lid;
            float2 pixelCenter = float2(pc) + 0.5;
            float2 ndc = (pixelCenter / uniforms.resolution) * 2.0 - 1.0;
            ndc.y = -ndc.y;
            float4 viewPos = uniforms.invProjMatrix * float4(ndc, -1.0, 1.0);
            viewPos /= viewPos.w;
            sharedRayDirs[i] = normalize((uniforms.invViewMatrix * float4(viewPos.xyz, 0.0)).xyz);
        }
    }

    // Synchronize - all threads get the shared data
    threadgroup_barrier(mem_flags::mem_threadgroup);

    FractalParams fractalParams = sharedFractalParams;
    FractalParams shadowParams = sharedShadowParams;
    float3 cameraPos = sharedCameraPos;
    float4x4 invProjMatrix = sharedInvProjMatrix;
    float4x4 invViewMatrix = sharedInvViewMatrix;
    float3 rd = sharedRayDirs[localId.y * 4 + localId.x];

    // === LEVEL 1: COARSE RAYMARCH (leader thread only) ===
    if (localId.x == 1 && localId.y == 1) {
        sharedCenterRayDir = rd;
        sharedCoarseT = SceneCoarse(cameraPos, rd, uniforms.foldingLimit, fractalParams, lodIterations);
    }

    threadgroup_barrier(mem_flags::mem_threadgroup);

    float coarseT = sharedCoarseT;
    float3 centerRayDir = sharedCenterRayDir;
    
    // === LEVEL 2: FINE RAYMARCH (all threads, from starting point) ===
    half3 col = half3(0.0h);
    float gTime = uniforms.time * 0.01 + 15.00;
    float adjustedDist = 1000.0;
    float glow = 0.0;
    
    if (coarseT < 900.0) {
        // Adjust starting distance for this pixel's ray direction
        float rayDot = max(dot(rd, centerRayDir), 0.9);
        float myStartT = coarseT * rayDot;
        
        // Fine raymarch from the starting point
        float2 tileCenter = float2(pixelCoord) + 0.5;
        float2 ret = SceneFromStart(uniforms.cameraPos, rd, myStartT, tileCenter, 1.0, uniforms.maxRaySteps, 
                                    uniforms.glowIntensity, uniforms.foldingLimit, fractalParams, lodIterations, uniforms.time);
        
        adjustedDist = ret.x;
        glow = ret.y;
        
        if (ret.x < 900.0) {
            // Calculate per-pixel hit point
            float3 p = uniforms.cameraPos + adjustedDist * rd;
            
            // Per-pixel normal for smooth shading
            float3 nor = GetNormalFast(p, adjustedDist, fractalParams, uniforms.foldingLimit, lodIterations);
            
            // Lighting
            float3 spotLight = CameraPath(gTime + 0.03) + float3(sin(gTime*18.4), cos(gTime*17.98), sin(gTime * 22.53)) * 0.2;
            float3 spot = spotLight - p;
            float atten = length(spot);
            spot /= atten;
            
            // Simplified shadows
            int shadowIterations = max(lodIterations - 2, 2);
            FractalParams shadowParams = makeFractalParams(uniforms.minDistance, uniforms.fractalScale, uniforms.sphereRadius, shadowIterations);
            
            half shaSpot = half(Shadow(p, spot, 0.7, uniforms.foldingLimit, shadowParams, shadowIterations));
            half shaSun = half(Shadow(p, sunDir, 0.7, uniforms.foldingLimit, shadowParams, shadowIterations));
            
            float attenPow = powr(max(atten, kPowEpsilon), 1.5);
            half bri = half(max(dot(spot, nor), 0.0) / attenPow * 0.25);
            half briSun = half(max(dot(sunDir, nor), 0.0) * 0.2);
            
            col = Colour(p, adjustedDist, gTime, 0.8, uniforms.minDistance, uniforms.fractalScale, 
                        uniforms.colorMix, uniforms.foldingLimit, uniforms.sphereRadius, 
                        max(int(uniforms.colorIterations * 0.8), 2));
            col = (col * bri * shaSpot) + (col * briSun * shaSun);
            
            // Specular
            float3 ref = reflect(rd, nor);
            float specSpot = powr(max(max(dot(spot, ref), 0.0), kPowEpsilon), 10.0) * 2.0;
            float specSun = powr(max(max(dot(sunDir, ref), 0.0), kPowEpsilon), 10.0) * 2.0;
            col += half3(specSpot) * shaSpot * bri;
            col += half3(specSun) * shaSun * briSun;
            
            // Fog
            half fogFactor = half(saturate(exp(-adjustedDist + 1.5)));
            col = mix(half3(0.02h, 0.03h, 0.04h), col, fogFactor);
        }
    }
    
    // Add glow
    half glowH = half(glow);
    col += glowH * glowH * half3(0.02h, 0.04h, 0.1h);
    
    col = clamp(col, half3(0.0h), half3(2.0h));
    col = powr(max(saturate(col), half3(kPowEpsilonHalf)), half3(0.47h));
    
    // Debug visualization: show hierarchical status
    // Green tint = coarse pass found hit (hierarchical worked)
    // Red tint = coarse missed, background/sky
    if (uniforms.debugHierarchical == 1) {
        if (coarseT < 900.0) {
            col = mix(col, half3(0.0h, 1.0h, 0.0h), 0.3h);  // Green = hierarchical hit
        } else {
            col = mix(col, half3(1.0h, 0.0h, 0.0h), 0.3h);  // Red = coarse miss
        }
    }
    
    // Write output
    outputTexture.write(float4(float3(col), 1.0), pixelCoord, uniforms.eyeIndex);
}

// === HIERARCHICAL 2x2 TILE KERNEL ===
// Same hierarchical approach but with 2x2 tiles for higher quality
kernel void tileRaymarchKernel2x2(
    uint2 tileId [[threadgroup_position_in_grid]],
    uint2 localId [[thread_position_in_threadgroup]],
    uint localIndex [[thread_index_in_threadgroup]],
    constant TileUniforms& uniforms [[buffer(0)]],
    texture2d_array<float, access::write> outputTexture [[texture(0)]]
) {
    const uint TILE_SIZE_2 = 2;
    
    uint2 pixelCoord = tileId * TILE_SIZE_2 + localId;
    
    if (pixelCoord.x >= uint(uniforms.resolution.x) || pixelCoord.y >= uint(uniforms.resolution.y)) {
        return;
    }
    
    threadgroup float sharedCoarseT;
    threadgroup float3 sharedCenterRayDir;
    
    int lodIterations = max(uniforms.fractalIterations, 2);
    FractalParams fractalParams = makeFractalParams(uniforms.minDistance, uniforms.fractalScale, uniforms.sphereRadius, lodIterations);
    
    float2 pixelCenter = float2(pixelCoord) + 0.5;
    float2 ndc = (pixelCenter / uniforms.resolution) * 2.0 - 1.0;
    ndc.y = -ndc.y;
    
    float4 viewPos = uniforms.invProjMatrix * float4(ndc, -1.0, 1.0);
    viewPos /= viewPos.w;
    float3 rd = normalize((uniforms.invViewMatrix * float4(viewPos.xyz, 0.0)).xyz);
    
    // === LEVEL 1: COARSE RAYMARCH (leader thread only) ===
    if (localIndex == 0) {
        sharedCenterRayDir = rd;
        sharedCoarseT = SceneCoarse(uniforms.cameraPos, rd, uniforms.foldingLimit, fractalParams, lodIterations);
    }
    
    threadgroup_barrier(mem_flags::mem_threadgroup);
    
    float coarseT = sharedCoarseT;
    float3 centerRayDir = sharedCenterRayDir;
    
    // === LEVEL 2: FINE RAYMARCH (all threads) ===
    half3 col = half3(0.0h);
    float gTime = uniforms.time * 0.01 + 15.00;
    float adjustedDist = 1000.0;
    float glow = 0.0;
    
    if (coarseT < 900.0) {
        float rayDot = max(dot(rd, centerRayDir), 0.9);
        float myStartT = coarseT * rayDot;
        
        float2 ret = SceneFromStart(uniforms.cameraPos, rd, myStartT, pixelCenter, 1.0, uniforms.maxRaySteps,
                                    uniforms.glowIntensity, uniforms.foldingLimit, fractalParams, lodIterations, uniforms.time);
        
        adjustedDist = ret.x;
        glow = ret.y;
        
        if (ret.x < 900.0) {
            float3 p = uniforms.cameraPos + adjustedDist * rd;
            float3 nor = GetNormalFast(p, adjustedDist, fractalParams, uniforms.foldingLimit, lodIterations);
            
            float3 spotLight = CameraPath(gTime + 0.03) + float3(sin(gTime*18.4), cos(gTime*17.98), sin(gTime * 22.53)) * 0.2;
            float3 spot = spotLight - p;
            float atten = length(spot);
            spot /= atten;
            
            int shadowIterations = max(lodIterations - 2, 2);
            FractalParams shadowParams = makeFractalParams(uniforms.minDistance, uniforms.fractalScale, uniforms.sphereRadius, shadowIterations);
            
            half shaSpot = half(Shadow(p, spot, 0.8, uniforms.foldingLimit, shadowParams, shadowIterations));
            half shaSun = half(Shadow(p, sunDir, 0.8, uniforms.foldingLimit, shadowParams, shadowIterations));
            
            float attenPow = powr(max(atten, kPowEpsilon), 1.5);
            half bri = half(max(dot(spot, nor), 0.0) / attenPow * 0.25);
            half briSun = half(max(dot(sunDir, nor), 0.0) * 0.2);
            
            col = Colour(p, adjustedDist, gTime, 1.0, uniforms.minDistance, uniforms.fractalScale, 
                        uniforms.colorMix, uniforms.foldingLimit, uniforms.sphereRadius, uniforms.colorIterations);
            col = (col * bri * shaSpot) + (col * briSun * shaSun);
            
            float3 ref = reflect(rd, nor);
            float specSpot = powr(max(max(dot(spot, ref), 0.0), kPowEpsilon), 10.0) * 2.0;
            float specSun = powr(max(max(dot(sunDir, ref), 0.0), kPowEpsilon), 10.0) * 2.0;
            col += half3(specSpot) * shaSpot * bri;
            col += half3(specSun) * shaSun * briSun;
            
            half fogFactor = half(saturate(exp(-adjustedDist + 1.5)));
            col = mix(half3(0.02h, 0.03h, 0.04h), col, fogFactor);
        }
    }
    
    half glowH = half(glow);
    col += glowH * glowH * half3(0.02h, 0.04h, 0.1h);
    col = clamp(col, half3(0.0h), half3(2.0h));
    col = powr(max(saturate(col), half3(kPowEpsilonHalf)), half3(0.47h));
    
    // Debug visualization for 2x2 kernel
    if (uniforms.debugHierarchical == 1) {
        if (coarseT < 900.0) {
            col = mix(col, half3(0.0h, 1.0h, 0.0h), 0.3h);  // Green = hierarchical hit
        } else {
            col = mix(col, half3(1.0h, 0.0h, 0.0h), 0.3h);  // Red = coarse miss
        }
    }
    
    outputTexture.write(float4(float3(col), 1.0), pixelCoord, uniforms.eyeIndex);
}

// === ADAPTIVE HIERARCHICAL 8x8 TILE KERNEL ===
// Three-level cascade: super-coarse (1 thread) → coarse (4 threads) → fine (64 threads)
// Dramatically reduces total Map() evaluations while maintaining quality
// Expected speedup: 3-8x depending on scene composition
kernel void adaptiveHierarchical8x8(
    uint2 tileId [[threadgroup_position_in_grid]],
    uint2 localId [[thread_position_in_threadgroup]],
    uint localIndex [[thread_index_in_threadgroup]],
    constant TileUniforms& uniforms [[buffer(0)]],
    texture2d_array<float, access::write> outputTexture [[texture(0)]]
) {
    const uint ADAPTIVE_TILE_SIZE = 8;  // 8x8 adaptive hierarchical tile
    uint2 pixelCoord = tileId * ADAPTIVE_TILE_SIZE + localId;
    
    if (pixelCoord.x >= uint(uniforms.resolution.x) || pixelCoord.y >= uint(uniforms.resolution.y)) {
        return;
    }
    
    // Shared memory for hierarchical cascade
    threadgroup float sharedSuperCoarseT;           // Level 0: one distance for entire 8x8
    threadgroup float sharedCoarseT[4];             // Level 1: one distance per 4x4 quadrant
    threadgroup float3 sharedCenterRayDir;          // For ray coherence adjustment
    threadgroup int sharedAdaptiveLevel;            // Which hierarchy level to use
    threadgroup float sharedBoundingT;              // Bounding sphere entry distance
    threadgroup FractalParams sharedFractalParams;
    threadgroup float3 sharedCameraPos;
    threadgroup float4x4 sharedInvProjMatrix;
    threadgroup float4x4 sharedInvViewMatrix;
    
    // Compute ray direction for this pixel
    float2 pixelCenter = float2(pixelCoord) + 0.5;
    float2 ndc = (pixelCenter / uniforms.resolution) * 2.0 - 1.0;
    ndc.y = -ndc.y;
    float4 viewPos = uniforms.invProjMatrix * float4(ndc, -1.0, 1.0);
    viewPos /= viewPos.w;
    float3 rd = normalize((uniforms.invViewMatrix * float4(viewPos.xyz, 0.0)).xyz);
    
    int lodIterations = max(uniforms.fractalIterations, 2);
    FractalParams fractalParams = makeFractalParams(uniforms.minDistance, uniforms.fractalScale, uniforms.sphereRadius, lodIterations);
    
    // Thread 0: Load shared data and do level 0 (super-coarse) pass
    if (localIndex == 0) {
        sharedFractalParams = fractalParams;
        sharedCameraPos = uniforms.cameraPos;
        sharedInvProjMatrix = uniforms.invProjMatrix;
        sharedInvViewMatrix = uniforms.invViewMatrix;
        
        // Compute center ray for 8x8 tile
        float2 centerPixel = float2(tileId * ADAPTIVE_TILE_SIZE) + 4.0;
        float2 centerNdc = (centerPixel / uniforms.resolution) * 2.0 - 1.0;
        centerNdc.y = -centerNdc.y;
        float4 centerViewPos = uniforms.invProjMatrix * float4(centerNdc, -1.0, 1.0);
        centerViewPos /= centerViewPos.w;
        float3 centerRd = normalize((uniforms.invViewMatrix * float4(centerViewPos.xyz, 0.0)).xyz);
        sharedCenterRayDir = centerRd;
        
        // Bounding sphere check - skip entire tile if it misses
        float boundingT = rayIntersectBoundingSphere(uniforms.cameraPos, centerRd, float3(0), BOUNDING_SPHERE_RADIUS);
        sharedBoundingT = boundingT;
        
        if (boundingT < 0.0) {
            // Tile misses bounding sphere entirely
            sharedSuperCoarseT = 1000.0;
            sharedAdaptiveLevel = 0;
        } else {
            // Super-coarse raymarch from bounding sphere entry
            float superCoarseT = SceneSuperCoarse(uniforms.cameraPos, centerRd, boundingT, 
                                                   uniforms.foldingLimit, fractalParams, lodIterations);
            sharedSuperCoarseT = superCoarseT;
            sharedAdaptiveLevel = selectAdaptiveLevel(superCoarseT);
        }
    }
    
    threadgroup_barrier(mem_flags::mem_threadgroup);
    
    float superCoarseT = sharedSuperCoarseT;
    int adaptiveLevel = sharedAdaptiveLevel;
    float3 centerRayDir = sharedCenterRayDir;
    
    // Early exit for tiles that clearly miss
    if (superCoarseT >= 900.0 && adaptiveLevel == 0) {
        // Sky - write background and exit
        half3 col = half3(0.02h, 0.03h, 0.04h);
        
        // Debug: red tint for missed tiles
        if (uniforms.debugHierarchical == 1) {
            col = mix(col, half3(1.0h, 0.0h, 0.0h), 0.3h);
        }
        
        outputTexture.write(float4(float3(col), 1.0), pixelCoord, uniforms.eyeIndex);
        return;
    }
    
    // Level 1: Coarse pass (4 threads for 4 quadrants)
    // Each thread handles one 4x4 sub-tile
    if (adaptiveLevel >= 1 && localIndex < 4) {
        uint quadrantX = localIndex % 2;
        uint quadrantY = localIndex / 2;
        
        // Center of 4x4 quadrant
        float2 quadrantCenter = float2(tileId * ADAPTIVE_TILE_SIZE) + float2(quadrantX * 4 + 2, quadrantY * 4 + 2);
        float2 quadrantNdc = (quadrantCenter / uniforms.resolution) * 2.0 - 1.0;
        quadrantNdc.y = -quadrantNdc.y;
        float4 quadrantViewPos = sharedInvProjMatrix * float4(quadrantNdc, -1.0, 1.0);
        quadrantViewPos /= quadrantViewPos.w;
        float3 quadrantRd = normalize((sharedInvViewMatrix * float4(quadrantViewPos.xyz, 0.0)).xyz);
        
        // Start from super-coarse distance, adjusted for ray direction difference
        float rayDot = max(dot(quadrantRd, centerRayDir), 0.95);
        (void)rayDot;  // Used only in potential future optimization
        
        float coarseT = SceneCoarse(sharedCameraPos, quadrantRd, uniforms.foldingLimit, sharedFractalParams, lodIterations);
        sharedCoarseT[localIndex] = coarseT;
    }
    
    threadgroup_barrier(mem_flags::mem_threadgroup);
    
    // Determine which quadrant this pixel belongs to
    uint myQuadrantX = (localId.x >= 4) ? 1 : 0;
    uint myQuadrantY = (localId.y >= 4) ? 1 : 0;
    uint myQuadrant = myQuadrantY * 2 + myQuadrantX;
    
    // Get starting distance based on adaptive level
    float startT;
    if (adaptiveLevel == 0) {
        startT = superCoarseT;
    } else {
        startT = sharedCoarseT[myQuadrant];
    }
    
    // Adjust for ray coherence
    float rayDot = max(dot(rd, centerRayDir), 0.9);
    float myStartT = max(startT * rayDot - 0.2, 0.01);
    
    // === LEVEL 2/3: Fine raymarch (all 64 threads) ===
    half3 col = half3(0.0h);
    float gTime = uniforms.time * 0.01 + 15.00;
    float adjustedDist = 1000.0;
    float glow = 0.0;
    
    if (startT < 900.0) {
        // Fine raymarch from hierarchical starting point
        float2 ret = SceneFromStart(uniforms.cameraPos, rd, myStartT, pixelCenter, 1.0, uniforms.maxRaySteps,
                                    uniforms.glowIntensity, uniforms.foldingLimit, fractalParams, lodIterations, uniforms.time);
        
        adjustedDist = ret.x;
        glow = ret.y;
        
        if (ret.x < 900.0) {
            float3 p = uniforms.cameraPos + adjustedDist * rd;
            float3 nor = GetNormalFast(p, adjustedDist, fractalParams, uniforms.foldingLimit, lodIterations);
            
            // Lighting
            float3 spotLight = CameraPath(gTime + 0.03) + float3(sin(gTime*18.4), cos(gTime*17.98), sin(gTime * 22.53)) * 0.2;
            float3 spot = spotLight - p;
            float atten = length(spot);
            spot /= atten;
            
            int shadowIterations = max(lodIterations - 2, 2);
            FractalParams shadowParams = makeFractalParams(uniforms.minDistance, uniforms.fractalScale, uniforms.sphereRadius, shadowIterations);
            
            half shaSpot = half(Shadow(p, spot, 0.8, uniforms.foldingLimit, shadowParams, shadowIterations));
            half shaSun = half(Shadow(p, sunDir, 0.8, uniforms.foldingLimit, shadowParams, shadowIterations));
            
            float attenPow = powr(max(atten, kPowEpsilon), 1.5);
            half bri = half(max(dot(spot, nor), 0.0) / attenPow * 0.25);
            half briSun = half(max(dot(sunDir, nor), 0.0) * 0.2);
            
            col = Colour(p, adjustedDist, gTime, 1.0, uniforms.minDistance, uniforms.fractalScale, 
                        uniforms.colorMix, uniforms.foldingLimit, uniforms.sphereRadius, uniforms.colorIterations);
            col = (col * bri * shaSpot) + (col * briSun * shaSun);
            
            // Specular
            float3 ref = reflect(rd, nor);
            float specSpot = powr(max(max(dot(spot, ref), 0.0), kPowEpsilon), 10.0) * 2.0;
            float specSun = powr(max(max(dot(sunDir, ref), 0.0), kPowEpsilon), 10.0) * 2.0;
            col += half3(specSpot) * shaSpot * bri;
            col += half3(specSun) * shaSun * briSun;
            
            // Fog
            half fogFactor = half(saturate(exp(-adjustedDist + 1.5)));
            col = mix(half3(0.02h, 0.03h, 0.04h), col, fogFactor);
        }
    }
    
    // Add glow
    half glowH = half(glow);
    col += glowH * glowH * half3(0.02h, 0.04h, 0.1h);
    col = clamp(col, half3(0.0h), half3(2.0h));
    col = powr(max(saturate(col), half3(kPowEpsilonHalf)), half3(0.47h));
    
    // Debug visualization for adaptive kernel
    if (uniforms.debugHierarchical == 1) {
        if (adaptiveLevel == 0) {
            col = mix(col, half3(0.0h, 0.0h, 1.0h), 0.25h);  // Blue = 8x8 (super-coarse only)
        } else if (adaptiveLevel == 1) {
            col = mix(col, half3(0.0h, 1.0h, 1.0h), 0.25h);  // Cyan = 4x4 (coarse)
        } else if (adaptiveLevel == 2) {
            col = mix(col, half3(0.0h, 1.0h, 0.0h), 0.25h);  // Green = 2x2 (fine)
        } else {
            col = mix(col, half3(1.0h, 1.0h, 0.0h), 0.25h);  // Yellow = per-pixel
        }
    }
    
    outputTexture.write(float4(float3(col), 1.0), pixelCoord, uniforms.eyeIndex);
}

// CameraPath is defined earlier in this file (before compute kernels)

float3 LightSource(float3 spotLight, float3 dir, float dis)
{
    float g = 0.0;
    if (length(spotLight) < dis)
    {
        float a = max(dot(normalize(spotLight), dir), 0.0);
        float safeA = max(a, kPowEpsilon);
        g = powr(safeA, 500.0);
        g +=  powr(safeA, 5000.0)*.2;
    }
   
    return float3(.6) * g;
}

float3 uvToDir(float2 uv) // uv: -1..1
{
    float2 uvRad = float2(uv.x * M_PI_F, uv.y * M_PI_F / 2); // -pi..pi, -pi/2..pi/2
    float2 xz = float2(sin(uvRad.x), cos(uvRad.x));
    return float3(xz.x * cos(uvRad.y), sin(uvRad.y), xz.y * cos(uvRad.y));
}

// Shared fragment body to avoid duplication and improve i-cache locality
inline FragmentOutput fragmentMain(ColorInOut in,
                                   Uniforms uniforms,
                                   float2 fragCoord,
                                   float time)
{
    FragmentOutput output;
    
    float gTime = time * 0.01 + 15.00;
    float3 cameraPos = (uniforms.inverseModelViewMatrix * float4(0,0,0,1)).xyz;
    float3 rd = normalize(in.modelPos - cameraPos);
    
    // NOTE: Disable shader-side foveation/LOD. The current heuristic uses mesh UVs
    // (`in.texCoord`), which are not screen-space and can behave incorrectly.
    float quality = 1.0;
    int lodIterations = max(int(uniforms.fractalIterations), 2);
    FractalParams fractalParams = makeFractalParams(uniforms.minDistance, uniforms.fractalScale, uniforms.sphereRadius, lodIterations);

    float2 ret = Scene(cameraPos, rd, fragCoord, quality, uniforms.maxRaySteps, uniforms.glowIntensity, uniforms.foldingLimit, fractalParams, lodIterations, time);
    half3 col = half3(0.0h);

    if (ret.x < 900.0)
    {
        float3 p = cameraPos + ret.x * rd;
        float4 clipPos = uniforms.projectionMatrix * uniforms.modelViewMatrix * float4(p, 1.0);
        output.depth = clipPos.z / clipPos.w;

        // Debug: visualize depth as grayscale
        if (DEBUG_DEPTH_VISUALIZATION) {
            float depthGray = saturate(output.depth); // Clamp depth to [0, 1]
            output.color = float4(depthGray, depthGray, depthGray, 1.0);
            return output;
        }
    }
    else
    {
        output.depth = 1e-7;

        if (DEBUG_DEPTH_VISUALIZATION) {
            output.color = float4(0.0, 0.0, 0.0, 1.0); // Black for far plane
            return output;
        }
    }

    if (ret.x < 900.0)
    {
        float3 p = cameraPos + ret.x * rd;

        float3 nor;
        if (quality > 0.2) {
            nor = GetNormal(p, ret.x, fractalParams, uniforms.foldingLimit, lodIterations);
        } else {
            nor = normalize(p - cameraPos);
        }

        if (quality > 0.4) {
            float3 spotLight = CameraPath(gTime + .03) + float3(sin(gTime*18.4), cos(gTime*17.98), sin(gTime * 22.53)) * 0.2;
            float3 spot = spotLight - p;
            float atten = length(spot);
            spot /= atten;

            int shadowIterations = max(lodIterations - 2, 2);
            FractalParams shadowParams = makeFractalParams(uniforms.minDistance, uniforms.fractalScale, uniforms.sphereRadius, shadowIterations);

            half shaSpot = half(Shadow(p, spot, quality, uniforms.foldingLimit, shadowParams, shadowIterations));
            half shaSun = half(Shadow(p, sunDir, quality, uniforms.foldingLimit, shadowParams, shadowIterations));

            float attenPow = powr(max(atten, kPowEpsilon), 1.5);
            half bri = half(max(dot(spot, nor), 0.0) / attenPow * 0.25);
            half briSun = half(max(dot(sunDir, nor), 0.0) * 0.2);

            col = Colour(p, ret.x, gTime, quality, uniforms.minDistance, uniforms.fractalScale, uniforms.colorMix, uniforms.foldingLimit, uniforms.sphereRadius, max(int(uniforms.colorIterations * quality), 2));
            col = (col * bri * shaSpot) + (col * briSun * shaSun);

            if (quality > 0.7) {
                float3 ref = reflect(rd, nor);
                float specSpot = powr(max(max(dot(spot, ref), 0.0), kPowEpsilon), 10.0) * 2.0;
                float specSun = powr(max(max(dot(sunDir, ref), 0.0), kPowEpsilon), 10.0) * 2.0;
                col += half3(specSpot) * shaSpot * bri;
                col += half3(specSun) * shaSun * briSun;
            }
        } else {
            half diffuse = half(max(dot(nor, sunDir), 0.0) * 0.5 + 0.3);
            col = Colour(p, ret.x, gTime, quality, uniforms.minDistance, uniforms.fractalScale, uniforms.colorMix, uniforms.foldingLimit, uniforms.sphereRadius, 2) * diffuse;
        }

        // Compute clip-space depth and write it out for async timewarp
        float4 clipPos = uniforms.projectionMatrix * uniforms.modelViewMatrix * float4(p, 1.0);
        output.depth = clipPos.z / clipPos.w;
    }
    else
    {
        // Far plane / no hit: use tiny depth so compositor treats this as far away
        output.depth = 1e-7;
    }

    half fogFactor = half(saturate(exp(-ret.x + 1.5)));
    col = mix(half3(0.02h, 0.03h, 0.04h), col, fogFactor);

    half glow = half(ret.y);
    col += glow * glow * half3(0.02h, 0.04h, 0.1h);

    col = clamp(col, half3(0.0h), half3(2.0h));

    if (quality > 0.5) {
        col = PostEffects(col, half2(in.texCoord));
    } else {
        col = powr(max(saturate(col), half3(kPowEpsilonHalf)), half3(0.47h));
    }

    output.color = float4(float3(col), 1.0);
    return output;
}

fragment FragmentOutput fragmentShader(ColorInOut in [[stage_in]],
                               constant UniformsArray & uniformsArray [[buffer(BufferIndexUniforms)]],
                               ushort ampId [[amplification_id]],
                               texture2d<half> cubeMap [[texture(TextureIndexColor)]])
{
    Uniforms uniforms = uniformsArray.uniforms[ampId];
    float2 fragCoord = in.position.xy;
    return fragmentMain(in, uniforms, fragCoord, uniforms.time);
}

// === HIERARCHICAL QUAD-SHARED RAYMARCHING ===
// Two-level approach:
// 1. Lane 0 does COARSE raymarch (few steps) to find approximate distance
// 2. All lanes do FINE raymarch from that starting point (far fewer steps needed)
// Combined with per-pixel normals for smooth shading
// ~8-16x reduction in total DE evaluations

fragment FragmentOutput fragmentShaderQuadShared(ColorInOut in [[stage_in]],
                               constant UniformsArray & uniformsArray [[buffer(BufferIndexUniforms)]],
                               ushort ampId [[amplification_id]],
                               texture2d<half> cubeMap [[texture(TextureIndexColor)]],
                               uint quadLaneId [[thread_index_in_quadgroup]])
{
    FragmentOutput output;
    Uniforms uniforms = uniformsArray.uniforms[ampId];
    float2 fragCoord = in.position.xy;
    float time = uniforms.time;
    
    float gTime = time * 0.01 + 15.00;
    float3 cameraPos = (uniforms.inverseModelViewMatrix * float4(0,0,0,1)).xyz;
    float3 rd = normalize(in.modelPos - cameraPos);
    
    int lodIterations = max(int(uniforms.fractalIterations), 2);
    FractalParams fractalParams = makeFractalParams(uniforms.minDistance, uniforms.fractalScale, uniforms.sphereRadius, lodIterations);
    
    // === STANDARD RAYMARCH (every pixel) ===
    // The hierarchical coarse/fine approach doesn't help due to SIMD lockstep execution
    float2 ret = Scene(cameraPos, rd, fragCoord, 1.0, uniforms.maxRaySteps, uniforms.glowIntensity, uniforms.foldingLimit, fractalParams, lodIterations, time);
    float adjustedDist = ret.x;
    float glow = ret.y;
    
    half3 col = half3(0.0h);
    
    if (ret.x < 900.0)
    {
        float3 p = cameraPos + adjustedDist * rd;
        
        // Per-pixel normal (needed for quality)
        float3 nor = GetNormalFast(p, adjustedDist, fractalParams, uniforms.foldingLimit, lodIterations);
        
        // === QUAD-SHARED SHADOWS ===
        // Shadows are expensive (many SDF evaluations) but vary slowly across a 2x2 quad
        // Leader computes shadows, broadcasts to all 4 pixels
        half shaSpot = 1.0h;
        half shaSun = 1.0h;
        
        int shadowIterations = max(lodIterations - 2, 2);
        FractalParams shadowParams = makeFractalParams(uniforms.minDistance, uniforms.fractalScale, uniforms.sphereRadius, shadowIterations);
        
        float3 spotLight = CameraPath(gTime + .03) + float3(sin(gTime*18.4), cos(gTime*17.98), sin(gTime * 22.53)) * 0.2;
        float3 spot = spotLight - p;
        float atten = length(spot);
        spot /= atten;
        
        if (quadLaneId == 0) {
            // Only leader computes shadows - expensive!
            shaSpot = half(Shadow(p, spot, 0.8, uniforms.foldingLimit, shadowParams, shadowIterations));
            shaSun = half(Shadow(p, sunDir, 0.8, uniforms.foldingLimit, shadowParams, shadowIterations));
        }
        
        // Broadcast shadow values to all 4 pixels in quad
        shaSpot = quad_broadcast(shaSpot, 0);
        shaSun = quad_broadcast(shaSun, 0);
        
        // Per-pixel lighting with shared shadows
        float attenPow = powr(max(atten, kPowEpsilon), 1.5);
        half bri = half(max(dot(spot, nor), 0.0) / attenPow * 0.25);
        half briSun = half(max(dot(sunDir, nor), 0.0) * 0.2);
        
        col = Colour(p, adjustedDist, gTime, 1.0, uniforms.minDistance, uniforms.fractalScale, uniforms.colorMix, uniforms.foldingLimit, uniforms.sphereRadius, max(int(uniforms.colorIterations), 2));
        col = (col * bri * shaSpot) + (col * briSun * shaSun);
        
        // Specular
        float3 ref = reflect(rd, nor);
        float specSpot = powr(max(max(dot(spot, ref), 0.0), kPowEpsilon), 10.0) * 2.0;
        float specSun = powr(max(max(dot(sunDir, ref), 0.0), kPowEpsilon), 10.0) * 2.0;
        col += half3(specSpot) * shaSpot * bri;
        col += half3(specSun) * shaSun * briSun;

        // Compute clip-space depth and write it out for async timewarp
        float4 clipPos = uniforms.projectionMatrix * uniforms.modelViewMatrix * float4(p, 1.0);
        output.depth = clipPos.z / clipPos.w;
    }
    else
    {
        output.depth = 1e-7;
    }
    
    half fogFactor = half(saturate(exp(-adjustedDist + 1.5)));
    col = mix(half3(0.02h, 0.03h, 0.04h), col, fogFactor);
    
    half glowH = half(glow);
    col += glowH * glowH * half3(0.02h, 0.04h, 0.1h);
    
    col = clamp(col, half3(0.0h), half3(2.0h));
    
    col = PostEffects(col, half2(in.texCoord));
    
    output.color = float4(float3(col), 1.0);
    return output;
}

// === Format Conversion Shaders for MetalFX ===
// Used to convert rgba16Float MetalFX output to drawable format (BGRA8Unorm_sRGB)
// Also handles aspect ratio correction when MetalFX uses physical-sized textures

struct FormatConversionParams {
    float aspectCorrection;  // physicalAspect / screenAspect (< 1.0 means horizontally squished)
};

struct FormatConversionVertex {
    float4 position [[position]];
    float2 texCoord;
};

// Full-screen triangle vertex shader - generates vertices procedurally
// Supports stereo via amplification_id for render_target_array_index
struct FormatConversionVertexOut {
    float4 position [[position]];
    float2 texCoord;
    uint eyeIndex;  // Pass eye index to fragment
};

vertex FormatConversionVertexOut formatConversionVertexStereo(uint vertexID [[vertex_id]],
                                                              ushort ampId [[amplification_id]]) {
    FormatConversionVertexOut out;
    
    // Generate full-screen triangle using oversized triangle technique
    float2 position;
    position.x = (vertexID == 1) ? 3.0 : -1.0;
    position.y = (vertexID == 2) ? 3.0 : -1.0;
    
    out.position = float4(position, 0.0, 1.0);
    
    // Convert clip space to UV coordinates
    out.texCoord.x = (position.x + 1.0) * 0.5;
    out.texCoord.y = (1.0 - position.y) * 0.5;  // Flip Y for Metal
    out.eyeIndex = ampId;
    
    return out;
}

// Non-stereo version for backward compatibility
vertex FormatConversionVertex formatConversionVertex(uint vertexID [[vertex_id]]) {
    FormatConversionVertex out;
    
    // Generate full-screen triangle using oversized triangle technique
    float2 position;
    position.x = (vertexID == 1) ? 3.0 : -1.0;
    position.y = (vertexID == 2) ? 3.0 : -1.0;
    
    out.position = float4(position, 0.0, 1.0);
    
    // Convert clip space to UV coordinates
    out.texCoord.x = (position.x + 1.0) * 0.5;
    out.texCoord.y = (1.0 - position.y) * 0.5;  // Flip Y for Metal
    
    return out;
}

// Stereo fragment shader - samples from correct array slice based on eye index
fragment float4 formatConversionFragmentStereo(FormatConversionVertexOut in [[stage_in]],
                                                texture2d_array<float> sourceTexture [[texture(0)]],
                                                constant FormatConversionParams& params [[buffer(0)]]) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear, 
                                      address::clamp_to_edge);
    
    // Sample using normalized UVs - works correctly regardless of source texture resolution
    // aspectCorrection is 1.0 when source has correct screen aspect
    float2 uv = in.texCoord;
    if (params.aspectCorrection != 1.0) {
        uv.x = 0.5 + (uv.x - 0.5) * params.aspectCorrection;
    }
    
    float4 color = sourceTexture.sample(textureSampler, uv, in.eyeIndex);
    return float4(color.rgb, 1.0);
}

// Non-stereo fragment shader for backward compatibility
fragment float4 formatConversionFragment(FormatConversionVertex in [[stage_in]],
                                          texture2d<float> sourceTexture [[texture(0)]]) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear, 
                                      address::clamp_to_edge);
    
    float4 color = sourceTexture.sample(textureSampler, in.texCoord);
    return float4(color.rgb, 1.0);
}

struct DepthOutput {
    float depth [[depth(any)]];
};

// Stereo depth upscale fragment shader
fragment DepthOutput depthUpscaleFragmentStereo(FormatConversionVertexOut in [[stage_in]],
                                                 depth2d_array<float> sourceTexture [[texture(0)]]) {
    constexpr sampler textureSampler(mag_filter::nearest, min_filter::nearest, 
                                      address::clamp_to_edge);
    
    DepthOutput out;
    out.depth = sourceTexture.sample(textureSampler, in.texCoord, in.eyeIndex);
    return out;
}

// Non-stereo depth upscale for backward compatibility
fragment DepthOutput depthUpscaleFragment(FormatConversionVertex in [[stage_in]],
                                          depth2d<float> sourceTexture [[texture(0)]]) {
    constexpr sampler textureSampler(mag_filter::nearest, min_filter::nearest, 
                                      address::clamp_to_edge);
    
    DepthOutput out;
    out.depth = sourceTexture.sample(textureSampler, in.texCoord);
    return out;
}
