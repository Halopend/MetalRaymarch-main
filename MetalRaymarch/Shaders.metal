//
//  Shaders.metal
//
// Debug flag for depth visualization (set to 1 to enable)
#define DEBUG_DEPTH_VISUALIZATION 0

// === COMPILER OPTIMIZATION HINTS ===
// Force aggressive inlining for hot path functions
#define FORCE_INLINE __attribute__((always_inline))
// Hint that a branch is likely/unlikely (helps branch predictor)
#define LIKELY(x)   __builtin_expect(!!(x), 1)
#define UNLIKELY(x) __builtin_expect(!!(x), 0)
// Unroll loops completely when iteration count is known
#define UNROLL_FULL _Pragma("unroll")
// Partial unroll for larger loops
#define UNROLL_4 _Pragma("unroll(4)")
#define UNROLL_8 _Pragma("unroll(8)")
// Disable unrolling for variable-count loops to reduce register pressure
#define NO_UNROLL _Pragma("nounroll")


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

// Screenshot vertex shader (no vertex amplification, uses view 0)
vertex ColorInOut screenshotVertexShader(Vertex in [[stage_in]],
                                         constant UniformsArray & uniformsArray [[ buffer(BufferIndexUniforms) ]])
{
    ColorInOut out;

    // Use first view's uniforms for screenshot
    Uniforms uniforms = uniformsArray.uniforms[0];
    
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

// === NAMED CONSTANTS FOR OPTIMIZATION ===
// Raymarching thresholds
constant float kRayMissThreshold = 900.0f;      // Distance indicating ray miss
constant float kMaxRayDistance = 12.0f;         // Standard max trace distance
constant float kCoarseMaxDistance = 80.0f;      // Super-coarse max distance
constant float kFogStartDistance = 1.5f;        // Fog exponential start

// Shading constants
constant half kGamma = 0.47h;                   // Output gamma correction
constant half kSaturation = 1.5h;               // Color saturation multiplier
constant half kContrast = 1.08h;                // Contrast adjustment
constant float kSpecularPower = 10.0f;          // Specular highlight power
constant float kSpecularIntensity = 2.0f;       // Specular intensity multiplier
constant float kAttenPower = 1.5f;              // Light attenuation power

// Quality thresholds
constant float kMinQualityForShadows = 0.25f;   // Skip shadows below this quality
constant float kMinQualityForNormals = 0.2f;    // Use cheap normals below this
constant float kMinQualityForSpecular = 0.7f;   // Skip specular below this
constant float kMinQualityForPostFX = 0.5f;     // Use simple gamma below this

// === ADAPTIVE HIERARCHICAL CONSTANTS ===
constant float BOUNDING_SPHERE_RADIUS = 3.5f;  // Skip rays outside this
constant float ADAPTIVE_FAR_THRESHOLD = 50.0f;   // Use 8x8 tiles beyond this distance
constant float ADAPTIVE_MED_THRESHOLD = 15.0f;   // Use 4x4 tiles beyond this
constant float ADAPTIVE_NEAR_THRESHOLD = 4.0f;   // Use 2x2 tiles beyond this

// === REFINING PARAMETERS STRUCT ===
// Passed from Swift uniforms for runtime tuning of sphere tracing optimization
struct RefiningParams {
    float relaxFactor;           // Over-relaxation multiplier (1.0-2.0)
    float relaxBacktrack;        // Backtrack factor when overshooting (0.3-1.0)
    float sdfScaleCoarse;        // SDF scaling for coarse pass (1.0-2.0)
    float sdfScaleSuperCoarse;   // SDF scaling for super-coarse pass (1.0-2.5)
    float earlyTermRatio;        // Early termination convergence ratio (0.1-0.6)
    int earlyTermCount;          // Steps before early termination (1-6)
};

// === ENHANCED OVER-RELAXATION DEFAULTS ===
// Based on "Skipping Spheres" paper and relaxed sphere tracing research
// These are fallback defaults - actual values come from uniforms for runtime tuning
// Over-relaxation factor: 1.6-2.0 is safe for most SDFs with backtracking
constant float DEFAULT_RELAX_FACTOR = 1.6f;             // Over-relaxation multiplier
constant float DEFAULT_RELAX_BACKTRACK = 0.7f;          // Backtrack factor when overshooting

// === SDF SCALING & EARLY RAY TERMINATION DEFAULTS (Polychronakis 2024) ===
// SDF scaling allows larger steps in coarse passes while maintaining correctness
// Early termination detects slow convergence and terminates before wasting steps
constant float DEFAULT_SDF_SCALE_COARSE = 1.3f;         // Scale factor for coarse SDF (Lipschitz-safe)
constant float DEFAULT_SDF_SCALE_SUPER_COARSE = 1.5f;   // More aggressive for super-coarse
constant float DEFAULT_EARLY_TERM_RATIO = 0.3f;         // Terminate if d_n/d_{n-1} < this for N steps
constant int DEFAULT_EARLY_TERM_COUNT = 3;              // Number of slow convergence steps before termination

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
// FORCE_INLINE: Called every pixel in Scene()
FORCE_INLINE float blueNoise(float2 uv, float time) {
    // Interleaved gradient noise - more temporally stable than random
    // Note: constexpr not available in Metal, but compiler will optimize this literal
    float3 magic = float3(0.06711056, 0.00583715, 52.9829189);
    float noise = fract(magic.z * fract(dot(uv, magic.xy)));
    // Add small temporal variation to prevent static patterns
    return fract(fma(time, 0.1, noise));
}
constant float SCALE = 2.8;

// Fast integer-based hash (faster than sin-based on GPU)
// FORCE_INLINE ensures no function call overhead in tight loops
FORCE_INLINE float hash(float n) { 
    // Reinterpret float bits as uint - zero cost
    uint u = as_type<uint>(n);
    // XOR-shift hash - all single-cycle ops on GPU
    u = (u ^ 61u) ^ (u >> 16u);
    u = u + (u << 3u);
    u = u ^ (u >> 4u);
    u = u * 0x27d4eb2du;
    u = u ^ (u >> 15u);
    // Convert back to normalized float
    return float(u) * (1.0f / 4294967296.0f);
}

// Original sin-based hash for compatibility (some noise functions may depend on exact distribution)
FORCE_INLINE float hashSin(float n) { return fract(sin(n) * 753.5453123); }

// 3D value noise - optimized for GPU coherent access
// Using MAD (multiply-add) chains that map to single GPU instructions
FORCE_INLINE float noise(float3 x) {
    float3 p = floor(x);
    float3 f = fract(x);
    // Smooth interpolation (cubic Hermite) - avoids derivative discontinuities
    f = f * f * fma(f, float3(-2.0), float3(3.0));  // fma = fused multiply-add
    
    // Compute base index once, reuse
    float n = fma(p.z, 113.0, fma(p.y, 157.0, p.x));
    
    // Prefetch all 8 corner hashes - GPU can parallelize these
    float h000 = hash(n);
    float h100 = hash(n + 1.0);
    float h010 = hash(n + 157.0);
    float h110 = hash(n + 158.0);
    float h001 = hash(n + 113.0);
    float h101 = hash(n + 114.0);
    float h011 = hash(n + 270.0);
    float h111 = hash(n + 271.0);
    
    // Trilinear interpolation using mix chains
    return mix(mix(mix(h000, h100, f.x),
                   mix(h010, h110, f.x), f.y),
               mix(mix(h001, h101, f.x),
                   mix(h011, h111, f.x), f.y), f.z);
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
    float3 bubbleCenter;
    float bubbleRadius;
    int bubbleEnabled;
};

// FORCE_INLINE: This is called per-pixel, must not have call overhead
FORCE_INLINE FractalParams makeFractalParams(float minRad2Val, float fractalScale, float sphereRadius, int iterations,
                                              float3 bubbleCenter, float bubbleRadius, int bubbleEnabled) {
    FractalParams params;
    // Compute scale once, store in register-friendly float4
    float invMinRad = 1.0f / minRad2Val;
    params.scale = float4(fractalScale * invMinRad);
    params.scale.w = abs(params.scale.w);
    params.absScalem1 = abs(fractalScale - 1.0);
    params.absScalePow = powr(max(abs(fractalScale), kPowEpsilon), float(1 - iterations));
    params.minRadius2 = sphereRadius * sphereRadius;
    params.bubbleCenter = bubbleCenter;
    params.bubbleRadius = bubbleRadius;
    params.bubbleEnabled = bubbleEnabled;
    return params;
}

// Optimized branchless Map function - THE HOTTEST PATH IN THE ENTIRE SHADER
// Called potentially 50-100+ times per pixel (raymarch + shadows + normals)
// Every cycle here matters!
FORCE_INLINE float Map(float3 pos, FractalParams params, float foldingLimit, int iterations) 
{
    float4 p = float4(pos, 1.0);
    float4 p0 = p;
    
    // Pre-compute reciprocal for sphere fold (division is expensive)
    float invMinRadius2 = 1.0f / params.minRadius2;

    // Manual unroll hint for known small iteration counts (2-8 typical)
    // The compiler will unroll if iterations is constexpr-like
    UNROLL_8
    for (int i = 0; i < iterations; i++)
    {
        // Box fold: clamp and reflect
        // Using fma where beneficial for single-instruction execution
        p.xyz = fma(clamp(p.xyz, -foldingLimit, foldingLimit), float3(2.0), -p.xyz);

        // Branchless sphere fold using clamp
        // r2 = dot product, single instruction on GPU
        float r2 = dot(p.xyz, p.xyz);
        // Sphere fold scale factor - clamped reciprocal
        float t = clamp(1.0f / max(r2, params.minRadius2), 1.0f, invMinRadius2);
        p *= t;

        // Scale and translate - use fma for xyz, regular mul for w
        p = fma(p, params.scale, p0);
    }
    
    // Final distance estimate
    float d = (length(p.xyz) - params.absScalem1) / p.w - params.absScalePow;
    
    // Safety bubble: carve out a sphere around the camera to prevent clipping
    if (params.bubbleEnabled != 0) {
        float3 toBubble = pos - params.bubbleCenter;
        float bubbleDist = length(toBubble) - params.bubbleRadius;
        d = max(d, -bubbleDist);
    }
    return d;
}

// === HALF PRECISION MAP FOR APPLE SILICON ===
// Apple GPUs have dedicated half-precision ALUs running at 2x throughput
// Use for coarse distance estimation where full precision isn't needed
half MapHalf(half3 pos, FractalParams params, half foldingLimit, int iterations) 
{
    half4 p = half4(pos, 1.0h);
    half4 p0 = p;
    half4 scaleH = half4(params.scale);
    half minRadius2H = half(params.minRadius2);
    half invMinRadius2H = 1.0h / minRadius2H;

    // Unroll small iteration counts for better instruction scheduling
    [[unroll]]
    for (int i = 0; i < iterations; i++)
    {
        // Box fold
        p.xyz = clamp(p.xyz, -foldingLimit, foldingLimit) * 2.0h - p.xyz;

        // Branchless sphere fold
        half r2 = dot(p.xyz, p.xyz);
        half t = clamp(1.0h / max(r2, minRadius2H), 1.0h, invMinRadius2H);
        p *= t;

        p = p * scaleH + p0;
    }
    return (length(p.xyz) - half(params.absScalem1)) / p.w - half(params.absScalePow);
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

// Fast normal using forward differences (3 Map calls instead of 4 with central diff)
// This is called for every hit pixel - force inline to avoid call stack overhead
FORCE_INLINE float3 GetNormal(float3 pos, float distance, FractalParams params, float foldingLimit, int iterations)
{
    // Epsilon scales with distance to maintain relative precision
    float e = distance * 0.001;
    float d = Map(pos, params, foldingLimit, iterations);
    // Forward difference gradient - 3 Map calls
    // GPU can potentially parallelize these since they're independent
    float3 gradient = float3(
        Map(pos + float3(e,0,0), params, foldingLimit, iterations) - d,
        Map(pos + float3(0,e,0), params, foldingLimit, iterations) - d,
        Map(pos + float3(0,0,e), params, foldingLimit, iterations) - d
    );
    // Fast normalize - rsqrt is single instruction on GPU
    return gradient * rsqrt(dot(gradient, gradient) + kPowEpsilon);
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

// === SUPER-COARSE RAYMARCH WITH SDF SCALING (for 8x8 tiles) ===
// Based on "SDF Scaling & Early Ray Termination" (Polychronakis 2024)
// Uses SDF scaling to allow even larger steps while maintaining Lipschitz safety
// Combined with half precision for 2x throughput on Apple Silicon
FORCE_INLINE float SceneSuperCoarse(float3 rO, float3 rD, float startT, float foldingLimit, FractalParams params, int iterations, RefiningParams refining)
{
    float t = max(startT, 0.05);
    half foldingLimitH = half(foldingLimit);
    
    // SDF scaling factor (Polychronakis 2024) - from runtime uniforms
    half sdfScale = half(refining.sdfScaleSuperCoarse);
    
    // Fixed 12 steps - unroll completely for maximum speed
    UNROLL_FULL
    for(int j = 0; j < 12; j++)
    {
        float3 p = fma(rD, float3(t), rO);
        // Use half precision Map for coarse pass
        half h = MapHalf(half3(p), params, foldingLimitH, iterations);
        
        // Apply SDF scaling - allows larger steps
        half scaledH = h * sdfScale;
        
        // Loose threshold - we just need approximate distance
        if(UNLIKELY(h < 0.1h)) return t;
        
        if (UNLIKELY(t > kCoarseMaxDistance)) return kRayMissThreshold + 100.0;
        
        // Step by scaled SDF value with additional over-relaxation
        t = fma(float(scaledH), 1.5, t);
    }
    
    return kRayMissThreshold + 100.0;
}

// === COARSE RAYMARCH WITH SDF SCALING ===
// Based on "SDF Scaling & Early Ray Termination" (Polychronakis 2024)
// Uses SDF scaling for faster convergence in hierarchical rendering
// Combined with half precision for 2x throughput on Apple Silicon
FORCE_INLINE float SceneCoarse(float3 rO, float3 rD, float foldingLimit, FractalParams params, int iterations, RefiningParams refining)
{
    float t = 0.05;
    half foldingLimitH = half(foldingLimit);
    half prevH = half(1e10);
    
    // SDF scaling factor (Polychronakis 2024) - from runtime uniforms
    half sdfScale = half(refining.sdfScaleCoarse);
    
    // Early termination thresholds - from runtime uniforms
    half earlyTermRatio = half(refining.earlyTermRatio);
    int earlyTermCount = refining.earlyTermCount;
    
    // Early termination counter
    int slowCount = 0;
    
    // Fixed 24 steps - can unroll partially
    UNROLL_8
    for(int j = 0; j < 24; j++)
    {
        float3 p = fma(rD, float3(t), rO);
        // Use half precision Map for coarse pass
        half h = MapHalf(half3(p), params, foldingLimitH, iterations);
        
        // LIKELY: Coarse pass finds hits most of the time
        if(UNLIKELY(h < 0.02h)) return t;
        
        if (UNLIKELY(t > kMaxRayDistance)) return kRayMissThreshold + 100.0;
        
        // Early ray termination check (Polychronakis 2024) - using runtime thresholds
        half ratio = h / max(prevH, half(0.0001));
        if (ratio < earlyTermRatio && h < 0.3h) {
            slowCount++;
            if (slowCount >= earlyTermCount) {
                return t;  // Terminate early on slow convergence
            }
        } else {
            slowCount = 0;
        }
        
        // Apply SDF scaling
        half scaledH = h * sdfScale;
        
        // Over-relaxation with backtracking
        half step;
        if (h > prevH * 1.2h) {
            // Overstep - backtrack slightly
            t -= float(prevH) * 0.3;
            step = h;  // Use unscaled for recovery
            slowCount = 0;
        } else {
            step = scaledH * 1.3h;  // Scaled + over-relaxation
        }
        
        t += float(step);
        prevH = h;
    }
    
    return kRayMissThreshold + 100.0;
}

// === FINE RAYMARCH FROM STARTING POINT ===
// Refines from a known starting distance (from coarse pass or neighbor)
FORCE_INLINE float2 SceneFromStart(float3 rO, float3 rD, float startT, float2 fragCoord, float quality, int maxStepsParam, float glowIntensity, float foldingLimit, FractalParams params, int iterations, float time)
{
    float dither = blueNoise(fragCoord, time) * 0.01;
    
    // Back up further from the starting point to ensure we don't miss the surface
    float t = max(0.01, startT - 0.3) + dither;
    
    float glow = 0.0;
    // More steps for reliability
    int maxSteps = max(int(float(maxStepsParam) * quality * 0.5), 8);
    float endT = startT + 2.0;  // Pre-compute end threshold
    
    NO_UNROLL
    for(int j = 0; j < maxSteps; j++)
    {
        float threshold = fma(t, 0.0006, 0.0005);
        
        float3 p = fma(rD, float3(t), rO);
        float h = Map(p, params, foldingLimit, iterations);
        
        if(UNLIKELY(h < threshold))
        {
            return float2(t, saturate(glow * 0.25));
        }
        
        if (UNLIKELY(t > endT)) break;
        
        glow = fma(saturate(0.04 - h), glowIntensity, glow);
        t += h;
    }
    
    return float2(kRayMissThreshold + 100.0, saturate(glow * 0.25));
}

// === ENHANCED SPHERE TRACING WITH EARLY RAY TERMINATION ===
// Based on "Enhanced Sphere Tracing" (Keinert 2014) and 
// "SDF Scaling & Early Ray Termination" (Polychronakis 2024)
// Combines over-relaxation, backtracking, and convergence-based early termination
// This is the main raymarch loop - optimize for typical case (many steps, eventual hit)
float2 Scene(float3 rO, float3 rD, float2 fragCoord, float quality, int maxStepsParam, float glowIntensity, float foldingLimit, FractalParams params, int iterations, float time, RefiningParams refining)
{
    // Use temporally stable blue noise dithering for reprojection
    float dither = blueNoise(fragCoord, time) * 0.015;
    float t = 0.05 + dither;
    
    float glow = 0.0;
    int maxSteps = max(int(float(maxStepsParam) * quality), 4);
    
    // Over-relaxation state (Keinert 2014) - from runtime uniforms
    float prevH = 1e10;
    float omega = refining.relaxFactor;  // Start with aggressive over-relaxation
    float relaxBacktrack = refining.relaxBacktrack;
    
    // Early ray termination thresholds - from runtime uniforms
    float earlyTermRatio = refining.earlyTermRatio;
    int earlyTermCount = refining.earlyTermCount;
    
    // Early ray termination state (Polychronakis 2024)
    // Track consecutive slow convergence steps
    int slowConvergenceCount = 0;
    
    // NO_UNROLL: Variable iteration count, unrolling would bloat code
    NO_UNROLL
    for(int j = 0; j < maxSteps; j++)
    {
        // Distance-adaptive threshold (standard approach)
        float threshold = fma(t, 0.0008, 0.0005) + (1.0 - quality) * 0.003;
        
        float3 p = fma(rD, float3(t), rO);  // p = rO + t * rD using fma
        float h = Map(p, params, foldingLimit, iterations);
        
        // LIKELY: Most rays eventually hit the fractal
        if(UNLIKELY(h < threshold))
        {
            return float2(t, saturate(glow * 0.25));
        }
        
        // UNLIKELY: Early exit is rare with bounded fractal
        if (UNLIKELY(t > kMaxRayDistance)) break;
        
        // Accumulate glow - saturate is free on GPU
        glow = fma(saturate(0.04 - h), glowIntensity, glow);
        
        // === EARLY RAY TERMINATION (Polychronakis 2024) ===
        // Detect slow convergence: if we're making tiny progress relative to distance,
        // we're likely approaching a complex surface area - terminate early
        float convergenceRatio = h / max(prevH, 0.0001f);
        if (convergenceRatio < earlyTermRatio && h < 0.5) {
            slowConvergenceCount++;
            if (slowConvergenceCount >= earlyTermCount) {
                // Slow convergence detected - terminate and use current position
                // This saves many wasted steps in complex fractal regions
                return float2(t, saturate(glow * 0.25));
            }
        } else {
            slowConvergenceCount = 0;  // Reset counter on good progress
        }
        
        // === ENHANCED OVER-RELAXATION WITH BACKTRACKING (Keinert 2014) ===
        // If we overstepped (h increased significantly), backtrack and reduce omega
        float step;
        if (h > prevH * 1.1 && omega > 1.0) {
            // Overstep detected - backtrack and use conservative stepping
            t -= prevH * (omega - 1.0) * relaxBacktrack;
            omega = 1.0;  // Fall back to standard sphere tracing
            step = h;
            slowConvergenceCount = 0;  // Reset on backtrack
        } else {
            // Safe to use over-relaxation
            step = h * omega;
            
            // Adaptive omega: reduce near surfaces for precision
            if (h < 0.1) {
                omega = max(1.0f, omega * 0.95f);
            }
        }
        
        t += step;
        prevH = h;
    }
    
    return float2(kRayMissThreshold + 100.0, saturate(glow * 0.25));
}

// =============================================================================
// GRID SPHERE TRACING (GST) - High Performance SDF Ray Marching
// =============================================================================
// Uses precomputed SDF grid hierarchy for faster convergence
// Reference: "Grid Sphere Tracing" (JCGT paper methodology)

// === GRID SAMPLING ===
// Sample SDF from a 3D texture at a specific level
// Input: worldPos in model space, gridLevel parameters
// Output: world-space distance estimate
FORCE_INLINE float sampleSDFAtLevel(float3 worldPos, float3 gridOrigin, 
                                     texture3d<float, access::sample> sdfTexture,
                                     float voxelSize, float3 resolution, float scale) {
    // Convert to grid coordinates (voxel units)
    float3 gridCoord = (worldPos - gridOrigin) / voxelSize;
    // Convert to normalized texture coordinates [0,1]
    float3 texCoord = gridCoord / resolution;
    
    // Clamp to valid texture bounds - use wider range for debugging
    texCoord = clamp(texCoord, float3(0.0), float3(1.0));
    
    // Sample with trilinear interpolation
    constexpr sampler sdfSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    float vNorm = sdfTexture.sample(sdfSampler, texCoord).r;  // snorm8 stored as float [-1,1]
    
    // Decode to world-space distance: d = v_norm * scale
    float decodedSDF = vNorm * scale;
    return decodedSDF;
}

// === LEVEL SELECTION ===
// Choose appropriate grid level based on SDF magnitude
// Coarser levels when far from surface, finer when close
FORCE_INLINE int selectGridLevel(float3 pos, float3 gridOrigin,
                                  constant SDFHierarchy& hierarchy,
                                  texture3d<float, access::sample> level0,
                                  texture3d<float, access::sample> level1,
                                  texture3d<float, access::sample> level2,
                                  texture3d<float, access::sample> level3) {
    // Start from coarsest, check if we can use it
    for (int L = hierarchy.numLevels - 1; L >= 0; --L) {
        constant SDFGridLevel& lvl = hierarchy.levels[L];
        float3 res = float3(lvl.resolution);
        
        float sdf;
        switch(L) {
            case 0: sdf = sampleSDFAtLevel(pos, gridOrigin, level0, lvl.voxelSize, res, lvl.scale); break;
            case 1: sdf = sampleSDFAtLevel(pos, gridOrigin, level1, lvl.voxelSize, res, lvl.scale); break;
            case 2: sdf = sampleSDFAtLevel(pos, gridOrigin, level2, lvl.voxelSize, res, lvl.scale); break;
            case 3: sdf = sampleSDFAtLevel(pos, gridOrigin, level3, lvl.voxelSize, res, lvl.scale); break;
            default: sdf = sampleSDFAtLevel(pos, gridOrigin, level0, lvl.voxelSize, res, lvl.scale); break;
        }
        
        // If SDF is large enough, this level is safe to use
        if (abs(sdf) > 4.0 * lvl.voxelDiagonal) {
            return L;
        }
    }
    return 0;  // Default to finest level
}

// === GRID SPHERE TRACING MAIN LOOP ===
// Uses precomputed SDF hierarchy for faster convergence
struct GSTHit {
    bool hit;
    float t;
    float glow;
};

// =============================================================================
// CUBIC POLYNOMIAL VOXEL INTERSECTION
// =============================================================================
// Based on: Söderlund, Evans, Akenine-Möller (2022)
// "Path Tracing of Signed Distance Function Grids" (JCGT)
// Uses 37 FMA operations for ray-trilinear surface intersection

// Evaluate cubic polynomial: c3*t³ + c2*t² + c1*t + c0
FORCE_INLINE float evalCubic(float c0, float c1, float c2, float c3, float t) {
    // Horner's method: ((c3*t + c2)*t + c1)*t + c0
    return fma(fma(fma(c3, t, c2), t, c1), t, c0);
}

// Evaluate cubic derivative: 3*c3*t² + 2*c2*t + c1
FORCE_INLINE float evalCubicDerivative(float c1, float c2, float c3, float t) {
    return fma(fma(3.0f * c3, t, 2.0f * c2), t, c1);
}

// Compute k0-k7 constants from 8 corner SDF values (Equation 3 from paper)
// The trilinear interpolation f(x,y,z) expands to:
// f = z*(k4 + k5*x + k6*y + k7*xy) - (k0 + k1*x + k2*y + k3*xy) = 0
FORCE_INLINE void computeTrilinearConstants(
    float s000, float s001, float s010, float s011,
    float s100, float s101, float s110, float s111,
    thread float& k0, thread float& k1, thread float& k2, thread float& k3,
    thread float& k4, thread float& k5, thread float& k6, thread float& k7)
{
    // Precompute intermediate value
    float a = s101 - s001;
    
    // Base coefficients from corner s000
    k0 = s000;
    k1 = s100 - s000;
    k2 = s010 - s000;
    k3 = s110 - s010 - k1;
    
    // Z-dependent coefficients  
    k4 = k0 - s001;
    k5 = k1 - a;
    k6 = k2 - (s011 - s001);
    k7 = k3 - (s111 - s011 - a);
}

// Compute cubic coefficients for ray-surface intersection (Equations 6-7 from paper)
// Total: 37 FMA operations (optimized from 161 in earlier papers)
FORCE_INLINE void computeCubicCoefficients(
    float3 rayOrigin, float3 rayDir,
    float k0, float k1, float k2, float k3,
    float k4, float k5, float k6, float k7,
    thread float& c0, thread float& c1, thread float& c2, thread float& c3)
{
    // Intermediate terms (Equation 7)
    float m0 = rayOrigin.x * rayOrigin.y;
    float m1 = rayDir.x * rayDir.y;
    float m2 = fma(rayOrigin.x, rayDir.y, rayOrigin.y * rayDir.x);
    float m3 = fma(k5, rayOrigin.z, -k1);
    float m4 = fma(k6, rayOrigin.z, -k2);
    float m5 = fma(k7, rayOrigin.z, -k3);
    
    // Cubic coefficients (Equation 6)
    // c0 = (k4*oz - k0) + ox*m3 + oy*m4 + m0*m5
    c0 = fma(k4, rayOrigin.z, -k0) + fma(rayOrigin.x, m3, fma(rayOrigin.y, m4, m0 * m5));
    
    // c1 = dx*m3 + dy*m4 + m2*m5 + dz*(k4 + k5*ox + k6*oy + k7*m0)
    float inner1 = k4 + fma(k5, rayOrigin.x, fma(k6, rayOrigin.y, k7 * m0));
    c1 = fma(rayDir.x, m3, fma(rayDir.y, m4, fma(m2, m5, rayDir.z * inner1)));
    
    // c2 = m1*m5 + dz*(k5*dx + k6*dy + k7*m2)
    float inner2 = fma(k5, rayDir.x, fma(k6, rayDir.y, k7 * m2));
    c2 = fma(m1, m5, rayDir.z * inner2);
    
    // c3 = k7*m1*dz
    c3 = k7 * m1 * rayDir.z;
}

// Newton-Raphson refinement with convergence check
// Returns refined root or -1 if no valid root found
FORCE_INLINE float newtonRaphsonRefine(float c0, float c1, float c2, float c3, 
                                        float t_init, float t_min, float t_max) {
    float t = t_init;
    const int maxIterations = 8;  // Paper uses up to 50, but 8 is usually sufficient
    const float epsilon = 1e-5f;
    
    UNROLL_8
    for (int i = 0; i < maxIterations; ++i) {
        float gt = evalCubic(c0, c1, c2, c3, t);
        
        // Check for convergence
        if (abs(gt) < epsilon) {
            return (t >= t_min && t <= t_max) ? t : -1.0f;
        }
        
        float gt_deriv = evalCubicDerivative(c1, c2, c3, t);
        
        // Avoid division by near-zero derivative
        if (abs(gt_deriv) < 1e-10f) {
            break;
        }
        
        float t_new = t - gt / gt_deriv;
        
        // Check for convergence in t
        if (abs(t_new - t) < epsilon) {
            return (t_new >= t_min && t_new <= t_max) ? t_new : -1.0f;
        }
        
        t = t_new;
        
        // Clamp to valid interval to prevent divergence
        t = clamp(t, t_min, t_max);
    }
    
    return (t >= t_min && t <= t_max && abs(evalCubic(c0, c1, c2, c3, t)) < 0.01f) ? t : -1.0f;
}

// Marmitt et al. root finding via derivative interval splitting
// Finds the smallest positive root of the cubic in [0, t_far]
FORCE_INLINE float findCubicRootMarmitt(float c0, float c1, float c2, float c3, float t_far) {
    // Handle degenerate cases
    if (abs(c3) < 1e-10f) {
        // Quadratic or simpler - solve directly
        if (abs(c2) < 1e-10f) {
            // Linear: c1*t + c0 = 0
            if (abs(c1) < 1e-10f) return -1.0f;
            float t = -c0 / c1;
            return (t >= 0.0f && t <= t_far) ? t : -1.0f;
        }
        // Quadratic: c2*t² + c1*t + c0 = 0
        float disc = c1 * c1 - 4.0f * c2 * c0;
        if (disc < 0.0f) return -1.0f;
        float sqrtDisc = sqrt(disc);
        float inv2c2 = 0.5f / c2;
        float t1 = (-c1 - sqrtDisc) * inv2c2;
        float t2 = (-c1 + sqrtDisc) * inv2c2;
        if (t1 >= 0.0f && t1 <= t_far) return t1;
        if (t2 >= 0.0f && t2 <= t_far) return t2;
        return -1.0f;
    }
    
    // Solve derivative quadratic: 3*c3*t² + 2*c2*t + c1 = 0
    // This gives us the critical points to split the interval
    float a_deriv = 3.0f * c3;
    float b_deriv = 2.0f * c2;
    float c_deriv = c1;
    
    float discriminant = b_deriv * b_deriv - 4.0f * a_deriv * c_deriv;
    
    // Build interval list: [0, crit1, crit2, t_far]
    float intervals[4] = { 0.0f, t_far, t_far, t_far };
    int numIntervals = 1;  // At least one interval [0, t_far]
    
    if (discriminant >= 0.0f) {
        float sqrtDisc = sqrt(discriminant);
        float inv2a = 0.5f / a_deriv;
        float crit1 = (-b_deriv - sqrtDisc) * inv2a;
        float crit2 = (-b_deriv + sqrtDisc) * inv2a;
        
        // Sort critical points and filter to [0, t_far]
        if (crit1 > crit2) {
            float tmp = crit1;
            crit1 = crit2;
            crit2 = tmp;
        }
        
        if (crit1 > 0.0f && crit1 < t_far) {
            intervals[1] = crit1;
            numIntervals++;
        }
        if (crit2 > 0.0f && crit2 < t_far && crit2 > crit1 + 1e-6f) {
            intervals[numIntervals] = crit2;
            numIntervals++;
        }
        intervals[numIntervals] = t_far;
    }
    
    // Check each interval for sign change (Intermediate Value Theorem)
    for (int i = 0; i < numIntervals; ++i) {
        float t_start = intervals[i];
        float t_end = intervals[i + 1];
        
        if (t_start >= t_end - 1e-8f) continue;
        
        float g_start = evalCubic(c0, c1, c2, c3, t_start);
        float g_end = evalCubic(c0, c1, c2, c3, t_end);
        
        // Root exists if sign changes
        if (g_start * g_end <= 0.0f) {
            // Linear interpolation for initial guess (regula falsi)
            float denom = g_end - g_start;
            float t_guess;
            if (abs(denom) > 1e-10f) {
                t_guess = (g_end * t_start - g_start * t_end) / denom;
            } else {
                t_guess = (t_start + t_end) * 0.5f;
            }
            t_guess = clamp(t_guess, t_start, t_end);
            
            // Refine with Newton-Raphson
            float root = newtonRaphsonRefine(c0, c1, c2, c3, t_guess, t_start, t_end);
            if (root >= 0.0f) {
                return root;
            }
            
            // Fallback: bisection if Newton failed
            for (int j = 0; j < 10; ++j) {
                float t_mid = (t_start + t_end) * 0.5f;
                float g_mid = evalCubic(c0, c1, c2, c3, t_mid);
                if (abs(g_mid) < 1e-5f) return t_mid;
                if (g_start * g_mid <= 0.0f) {
                    t_end = t_mid;
                    g_end = g_mid;
                } else {
                    t_start = t_mid;
                    g_start = g_mid;
                }
            }
            return (t_start + t_end) * 0.5f;
        }
    }
    
    return -1.0f;  // No root found
}

// Evaluate trilinear interpolation at a point in [0,1]³
FORCE_INLINE float evalTrilinear(float3 p,
    float s000, float s001, float s010, float s011,
    float s100, float s101, float s110, float s111)
{
    // Bilinear on z=0 face
    float s00 = mix(s000, s100, p.x);
    float s01 = mix(s010, s110, p.x);
    float s0 = mix(s00, s01, p.y);
    
    // Bilinear on z=1 face
    float s10 = mix(s001, s101, p.x);
    float s11 = mix(s011, s111, p.x);
    float s1 = mix(s10, s11, p.y);
    
    // Linear between faces
    return mix(s0, s1, p.z);
}

// Main voxel intersection using cubic polynomial solver
// Returns t >= 0 if hit, -1 if miss
// rayOrigin and rayDir are in LOCAL voxel coordinates [0,1]³
FORCE_INLINE float cubicVoxelIntersect(
    float3 localOrigin, float3 rayDir, float t_far,
    float s000, float s001, float s010, float s011,
    float s100, float s101, float s110, float s111)
{
    // Compute trilinear constants (k0..k7)
    float k0, k1, k2, k3, k4, k5, k6, k7;
    computeTrilinearConstants(s000, s001, s010, s011, s100, s101, s110, s111,
                              k0, k1, k2, k3, k4, k5, k6, k7);
    
    // Compute cubic coefficients (c0..c3) - 37 FMA ops
    float c0, c1, c2, c3;
    computeCubicCoefficients(localOrigin, rayDir, k0, k1, k2, k3, k4, k5, k6, k7,
                             c0, c1, c2, c3);
    
    // Find root using Marmitt + Newton-Raphson method
    return findCubicRootMarmitt(c0, c1, c2, c3, t_far);
}

// Full voxel intersection with world-space inputs
// Handles coordinate transformation and corner sampling
FORCE_INLINE float voxelIntersectionWorld(
    float3 rayOrigin, float3 rayDir,
    float3 voxelOrigin, float voxelSize,
    texture3d<float, access::sample> sdfTexture,
    float3 gridOrigin, float3 gridResolution, float scale)
{
    // Transform ray origin to voxel-local coordinates [0,1]³
    float3 localOrigin = (rayOrigin - voxelOrigin) / voxelSize;
    
    // Compute ray-AABB intersection to get t_far (exit from voxel)
    float3 invDir = 1.0f / select(rayDir, float3(1e-8f), abs(rayDir) < float3(1e-8f));
    float3 t0 = (float3(0.0f) - localOrigin) * invDir;
    float3 t1 = (float3(1.0f) - localOrigin) * invDir;
    float3 tMin = min(t0, t1);
    float3 tMax = max(t0, t1);
    float t_near = max(max(tMin.x, tMin.y), tMin.z);
    float t_far = min(min(tMax.x, tMax.y), tMax.z);
    
    // No valid intersection with voxel AABB
    if (t_far < 0.0f || t_near > t_far) return -1.0f;
    
    // Sample 8 corners of the voxel from the SDF texture
    constexpr sampler sdfSampler(coord::normalized, address::clamp_to_edge, filter::nearest);
    
    float3 voxelTexCoord = (voxelOrigin - gridOrigin) / voxelSize / gridResolution;
    float3 texelOffset = float3(1.0f) / gridResolution;
    
    // Read corner SDF values (normalized [-1,1] range)
    float s000 = sdfTexture.sample(sdfSampler, voxelTexCoord).r * scale;
    float s100 = sdfTexture.sample(sdfSampler, voxelTexCoord + float3(texelOffset.x, 0, 0)).r * scale;
    float s010 = sdfTexture.sample(sdfSampler, voxelTexCoord + float3(0, texelOffset.y, 0)).r * scale;
    float s110 = sdfTexture.sample(sdfSampler, voxelTexCoord + float3(texelOffset.x, texelOffset.y, 0)).r * scale;
    float s001 = sdfTexture.sample(sdfSampler, voxelTexCoord + float3(0, 0, texelOffset.z)).r * scale;
    float s101 = sdfTexture.sample(sdfSampler, voxelTexCoord + float3(texelOffset.x, 0, texelOffset.z)).r * scale;
    float s011 = sdfTexture.sample(sdfSampler, voxelTexCoord + float3(0, texelOffset.y, texelOffset.z)).r * scale;
    float s111 = sdfTexture.sample(sdfSampler, voxelTexCoord + texelOffset).r * scale;
    
    // Adjust t_far to be in voxel-local units
    t_far = max(t_far, 0.01f);
    
    // Run cubic solver
    float t_local = cubicVoxelIntersect(localOrigin, rayDir, t_far,
                                         s000, s001, s010, s011,
                                         s100, s101, s110, s111);
    
    // Convert local t back to world-space distance
    if (t_local >= 0.0f) {
        return t_local * voxelSize;
    }
    return -1.0f;
}

// =============================================================================
// ANALYTIC GRADIENT FOR NORMALS (Equations 9-11 from paper)
// =============================================================================
// Computes gradient of trilinear field analytically (no finite differences)

FORCE_INLINE float3 computeTrilinearGradient(
    float3 p,  // Position in [0,1]³ local voxel coords
    float s000, float s001, float s010, float s011,
    float s100, float s101, float s110, float s111)
{
    // Partial derivative with respect to x (Equation 9)
    float dx = (1.0f - p.y) * (1.0f - p.z) * (s100 - s000)
             + p.y * (1.0f - p.z) * (s110 - s010)
             + (1.0f - p.y) * p.z * (s101 - s001)
             + p.y * p.z * (s111 - s011);
    
    // Partial derivative with respect to y (Equation 10)
    float dy = (1.0f - p.x) * (1.0f - p.z) * (s010 - s000)
             + p.x * (1.0f - p.z) * (s110 - s100)
             + (1.0f - p.x) * p.z * (s011 - s001)
             + p.x * p.z * (s111 - s101);
    
    // Partial derivative with respect to z (Equation 11)
    float dz = (1.0f - p.x) * (1.0f - p.y) * (s001 - s000)
             + p.x * (1.0f - p.y) * (s101 - s100)
             + (1.0f - p.x) * p.y * (s011 - s010)
             + p.x * p.y * (s111 - s110);
    
    return float3(dx, dy, dz);
}

// Compute normal at hit point using analytic gradient
FORCE_INLINE float3 computeNormalAnalytic(
    float3 hitPoint,  // World-space hit position
    float3 voxelOrigin, float voxelSize,
    texture3d<float, access::sample> sdfTexture,
    float3 gridOrigin, float3 gridResolution, float scale)
{
    // Convert to local voxel coordinates
    float3 localPos = (hitPoint - voxelOrigin) / voxelSize;
    localPos = clamp(localPos, float3(0.001f), float3(0.999f));  // Avoid edge artifacts
    
    // Sample 8 corners
    constexpr sampler sdfSampler(coord::normalized, address::clamp_to_edge, filter::nearest);
    
    float3 voxelTexCoord = (voxelOrigin - gridOrigin) / voxelSize / gridResolution;
    float3 texelOffset = float3(1.0f) / gridResolution;
    
    float s000 = sdfTexture.sample(sdfSampler, voxelTexCoord).r * scale;
    float s100 = sdfTexture.sample(sdfSampler, voxelTexCoord + float3(texelOffset.x, 0, 0)).r * scale;
    float s010 = sdfTexture.sample(sdfSampler, voxelTexCoord + float3(0, texelOffset.y, 0)).r * scale;
    float s110 = sdfTexture.sample(sdfSampler, voxelTexCoord + float3(texelOffset.x, texelOffset.y, 0)).r * scale;
    float s001 = sdfTexture.sample(sdfSampler, voxelTexCoord + float3(0, 0, texelOffset.z)).r * scale;
    float s101 = sdfTexture.sample(sdfSampler, voxelTexCoord + float3(texelOffset.x, 0, texelOffset.z)).r * scale;
    float s011 = sdfTexture.sample(sdfSampler, voxelTexCoord + float3(0, texelOffset.y, texelOffset.z)).r * scale;
    float s111 = sdfTexture.sample(sdfSampler, voxelTexCoord + texelOffset).r * scale;
    
    // Compute analytic gradient
    float3 gradient = computeTrilinearGradient(localPos, s000, s001, s010, s011,
                                                s100, s101, s110, s111);
    
    // Normalize (gradient is in local coords, but direction is preserved)
    float len = length(gradient);
    if (len < 1e-6f) {
        return float3(0.0f, 1.0f, 0.0f);  // Fallback
    }
    return gradient / len;
}

// Simplified GST with multi-level support and CUBIC VOXEL INTERSECTION
// Uses analytic cubic polynomial solver for precise surface intersection
GSTHit gridSphereTraceRay(float3 rayOrigin, float3 rayDir,
                           constant SDFHierarchy& hierarchy,
                           texture3d<float, access::sample> level0,
                           texture3d<float, access::sample> level1,
                           texture3d<float, access::sample> level2,
                           texture3d<float, access::sample> level3,
                           float tMax, float glowIntensity) {
    GSTHit result;
    result.hit = false;
    result.t = 0.0;
    result.glow = 0.0;
    
    float t = 0.01;  // Start slightly away from origin
    float prevSDF = 1000.0f;  // Track previous SDF for sign change detection
    float prevT = t;
    
    float3 gridOrigin = hierarchy.gridOrigin;
    float3 gridExtent = float3(hierarchy.gridExtent);
    float3 gridMax = gridOrigin + gridExtent;
    
    // Get finest level info for voxel intersection
    constant SDFGridLevel& finestLvl = hierarchy.levels[0];
    float3 finestRes = float3(finestLvl.resolution);
    float voxelSize = finestLvl.voxelSize;
    
    // Safe inverse direction (avoid division by zero)
    float3 invDir = 1.0 / max(abs(rayDir), float3(1e-8)) * sign(rayDir + float3(1e-8));
    
    NO_UNROLL
    for (int iter = 0; iter < 256; ++iter) {
        float3 pos = rayOrigin + t * rayDir;
        
        // Check if we're still inside the grid bounds
        if (any(pos < gridOrigin) || any(pos > gridMax)) {
            // Outside grid - try to intersect the grid bounding box
            float3 t0 = (gridOrigin - pos) * invDir;
            float3 t1 = (gridMax - pos) * invDir;
            float3 tmin = min(t0, t1);
            float3 tmax = max(t0, t1);
            float tEntry = max(max(tmin.x, tmin.y), tmin.z);
            
            if (tEntry > 0.0 && tEntry < tMax - t) {
                // Jump to grid boundary
                t += tEntry + 0.001;
                prevSDF = 1000.0f;  // Reset prev SDF when re-entering grid
                prevT = t;
                continue;
            } else {
                // Ray doesn't intersect grid - miss
                break;
            }
        }
        
        // Find appropriate level and sample SDF
        // Start from coarsest level (largest safe steps) and work down
        float sdf = 0.0;
        for (int L = min(hierarchy.numLevels - 1, 3); L >= 0; --L) {
            constant SDFGridLevel& lvl = hierarchy.levels[L];
            float3 res = float3(lvl.resolution);
            
            float sdfL;
            switch(L) {
                case 0: sdfL = sampleSDFAtLevel(pos, gridOrigin, level0, lvl.voxelSize, res, lvl.scale); break;
                case 1: sdfL = sampleSDFAtLevel(pos, gridOrigin, level1, lvl.voxelSize, res, lvl.scale); break;
                case 2: sdfL = sampleSDFAtLevel(pos, gridOrigin, level2, lvl.voxelSize, res, lvl.scale); break;
                case 3: sdfL = sampleSDFAtLevel(pos, gridOrigin, level3, lvl.voxelSize, res, lvl.scale); break;
                default: sdfL = sampleSDFAtLevel(pos, gridOrigin, level0, lvl.voxelSize, res, lvl.scale); break;
            }
            
            // If we're far enough from surface, this level is safe to use
            // Use threshold of 2.5 * voxelDiagonal for conservative level selection
            if (abs(sdfL) > 2.5 * lvl.voxelDiagonal || L == 0) {
                sdf = sdfL;
                break;
            }
        }
        
        // Accumulate glow
        result.glow = fma(saturate(0.04 - abs(sdf)), glowIntensity, result.glow);
        
        // =================================================================
        // CUBIC POLYNOMIAL VOXEL INTERSECTION
        // =================================================================
        // Detect surface crossing (sign change) or close approach
        float hitThreshold = voxelSize * 0.5;  // Use voxel-based threshold
        
        if ((prevSDF > 0.0f && sdf <= 0.0f) || (sdf < hitThreshold && sdf < prevSDF)) {
            // Surface crossing detected - use cubic solver for precise intersection
            
            // Find the voxel containing the crossing point
            // Use position between prevT and t
            float3 crossingPos = rayOrigin + (prevT + t) * 0.5f * rayDir;
            
            // Compute voxel grid coordinates (floor to get voxel origin)
            float3 voxelGridCoord = floor((crossingPos - gridOrigin) / voxelSize);
            voxelGridCoord = clamp(voxelGridCoord, float3(0.0f), finestRes - float3(1.0f));
            float3 voxelOrigin = voxelGridCoord * voxelSize + gridOrigin;
            
            // Sample 8 corners of the voxel for cubic solver
            constexpr sampler sdfSampler(coord::normalized, address::clamp_to_edge, filter::nearest);
            float3 voxelTexCoord = (voxelGridCoord + float3(0.5f)) / finestRes;
            float3 texelOffset = float3(1.0f) / finestRes;
            
            // Decode using finest level scale
            float scale = finestLvl.scale;
            
            float s000 = level0.sample(sdfSampler, voxelTexCoord).r * scale;
            float s100 = level0.sample(sdfSampler, voxelTexCoord + float3(texelOffset.x, 0, 0)).r * scale;
            float s010 = level0.sample(sdfSampler, voxelTexCoord + float3(0, texelOffset.y, 0)).r * scale;
            float s110 = level0.sample(sdfSampler, voxelTexCoord + float3(texelOffset.x, texelOffset.y, 0)).r * scale;
            float s001 = level0.sample(sdfSampler, voxelTexCoord + float3(0, 0, texelOffset.z)).r * scale;
            float s101 = level0.sample(sdfSampler, voxelTexCoord + float3(texelOffset.x, 0, texelOffset.z)).r * scale;
            float s011 = level0.sample(sdfSampler, voxelTexCoord + float3(0, texelOffset.y, texelOffset.z)).r * scale;
            float s111 = level0.sample(sdfSampler, voxelTexCoord + texelOffset).r * scale;
            
            // Transform ray to voxel-local coordinates [0,1]³
            // Start from prevT to search forward
            float3 localRayOrigin = (rayOrigin + prevT * rayDir - voxelOrigin) / voxelSize;
            
            // Compute how far the ray can travel within this voxel
            float3 localInvDir = 1.0f / select(rayDir, float3(1e-8f), abs(rayDir) < float3(1e-8f));
            float3 t0_local = (float3(0.0f) - localRayOrigin) * localInvDir;
            float3 t1_local = (float3(1.0f) - localRayOrigin) * localInvDir;
            float3 tMax_local = max(t0_local, t1_local);
            float t_far_local = min(min(tMax_local.x, tMax_local.y), tMax_local.z);
            t_far_local = max(t_far_local, 0.01f);
            
            // Run cubic polynomial solver
            float t_hit_local = cubicVoxelIntersect(localRayOrigin, rayDir, t_far_local,
                                                     s000, s001, s010, s011,
                                                     s100, s101, s110, s111);
            
            if (t_hit_local >= 0.0f) {
                // Convert local hit distance to world units
                float t_hit_world = prevT + t_hit_local * voxelSize;
                
                // Validate hit is reasonable
                if (t_hit_world > 0.0f && t_hit_world < tMax) {
                    result.hit = true;
                    result.t = t_hit_world;
                    result.glow = saturate(result.glow * 0.25);
                    return result;
                }
            }
            
            // Cubic solver didn't find valid root - fallback to current position
            if (sdf <= 0.0f) {
                result.hit = true;
                result.t = t;
                result.glow = saturate(result.glow * 0.25);
                return result;
            }
        }
        
        // Step forward by SDF distance (sphere tracing)
        // Use 0.95 multiplier - safe but not overly conservative
        float minStep = voxelSize * 0.05;  // Smaller minimum step
        float stepSize = max(sdf * 0.95, minStep);
        
        prevSDF = sdf;
        prevT = t;
        t += stepSize;
        
        // Exit if we've gone too far
        if (t > tMax) break;
    }
    
    result.glow = saturate(result.glow * 0.25);
    return result;
}

// === GRID NORMAL COMPUTATION ===
// Uses analytic trilinear gradient for smooth normals (Equations 9-11 from paper)
// Falls back to finite difference if voxel lookup fails
FORCE_INLINE float3 computeNormalFromGrid(float3 worldPos, 
                                           constant SDFHierarchy& hierarchy,
                                           texture3d<float, access::sample> level0) {
    constant SDFGridLevel& lvl = hierarchy.levels[0];
    float3 gridOrigin = hierarchy.gridOrigin;
    float3 res = float3(lvl.resolution);
    float voxelSize = lvl.voxelSize;
    float scale = lvl.scale;
    
    // Find the voxel containing this position
    float3 voxelGridCoord = floor((worldPos - gridOrigin) / voxelSize);
    voxelGridCoord = clamp(voxelGridCoord, float3(0.0f), res - float3(1.0f));
    float3 voxelOrigin = voxelGridCoord * voxelSize + gridOrigin;
    
    // Compute local position within voxel [0,1]³
    float3 localPos = (worldPos - voxelOrigin) / voxelSize;
    localPos = clamp(localPos, float3(0.001f), float3(0.999f));  // Avoid edge artifacts
    
    // Sample 8 corners of the voxel
    constexpr sampler sdfSampler(coord::normalized, address::clamp_to_edge, filter::nearest);
    float3 voxelTexCoord = (voxelGridCoord + float3(0.5f)) / res;
    float3 texelOffset = float3(1.0f) / res;
    
    float s000 = level0.sample(sdfSampler, voxelTexCoord).r * scale;
    float s100 = level0.sample(sdfSampler, voxelTexCoord + float3(texelOffset.x, 0, 0)).r * scale;
    float s010 = level0.sample(sdfSampler, voxelTexCoord + float3(0, texelOffset.y, 0)).r * scale;
    float s110 = level0.sample(sdfSampler, voxelTexCoord + float3(texelOffset.x, texelOffset.y, 0)).r * scale;
    float s001 = level0.sample(sdfSampler, voxelTexCoord + float3(0, 0, texelOffset.z)).r * scale;
    float s101 = level0.sample(sdfSampler, voxelTexCoord + float3(texelOffset.x, 0, texelOffset.z)).r * scale;
    float s011 = level0.sample(sdfSampler, voxelTexCoord + float3(0, texelOffset.y, texelOffset.z)).r * scale;
    float s111 = level0.sample(sdfSampler, voxelTexCoord + texelOffset).r * scale;
    
    // Compute analytic gradient using trilinear interpolation derivatives
    float3 gradient = computeTrilinearGradient(localPos, s000, s001, s010, s011,
                                                s100, s101, s110, s111);
    
    // Normalize
    float len = length(gradient);
    if (len < 1e-6f) {
        // Fallback to finite difference if analytic gradient is degenerate
        float eps = voxelSize * 0.5f;
        float dx = sampleSDFAtLevel(worldPos + float3(eps,0,0), gridOrigin, level0, voxelSize, res, scale)
                 - sampleSDFAtLevel(worldPos - float3(eps,0,0), gridOrigin, level0, voxelSize, res, scale);
        float dy = sampleSDFAtLevel(worldPos + float3(0,eps,0), gridOrigin, level0, voxelSize, res, scale)
                 - sampleSDFAtLevel(worldPos - float3(0,eps,0), gridOrigin, level0, voxelSize, res, scale);
        float dz = sampleSDFAtLevel(worldPos + float3(0,0,eps), gridOrigin, level0, voxelSize, res, scale)
                 - sampleSDFAtLevel(worldPos - float3(0,0,eps), gridOrigin, level0, voxelSize, res, scale);
        
        float3 n = float3(dx, dy, dz);
        float nLen = length(n);
        if (nLen < 1e-6f) {
            return float3(0.0f, 1.0f, 0.0f);  // Ultimate fallback
        }
        return n / nLen;
    }
    
    return gradient / len;
}

// === ALTERNATIVE: Scene with optional GST fallback ===
// When GST grid is not available, falls back to analytic SDF
float2 SceneWithGST(float3 rO, float3 rD, float2 fragCoord, float quality, int maxStepsParam, 
                    float glowIntensity, float foldingLimit, FractalParams params, int iterations, 
                    float time, bool useGST, constant SDFHierarchy& hierarchy,
                    texture3d<float, access::sample> level0,
                    texture3d<float, access::sample> level1,
                    texture3d<float, access::sample> level2,
                    texture3d<float, access::sample> level3) {
    if (useGST && hierarchy.isBuilt != 0) {
        GSTHit hit = gridSphereTraceRay(rO, rD, hierarchy, level0, level1, level2, level3,
                                        kMaxRayDistance, glowIntensity);
        if (hit.hit) {
            return float2(hit.t, hit.glow);
        }
        return float2(kRayMissThreshold + 100.0, hit.glow);
    }
    
    // Fallback to standard analytic sphere tracing
    return Scene(rO, rD, fragCoord, quality, maxStepsParam, glowIntensity, foldingLimit, params, iterations, time);
}

// =============================================================================
// SDF GRID BUILDING COMPUTE KERNELS
// =============================================================================

// Build level 0 (finest) from analytic SDF
kernel void buildSDFGridLevel0(
    uint3 gid [[thread_position_in_grid]],
    constant SDFGridBuildUniforms& uniforms [[buffer(0)]],
    texture3d<float, access::write> outputSDF [[texture(0)]]
) {
    if (gid.x >= uint(uniforms.resolution.x) ||
        gid.y >= uint(uniforms.resolution.y) ||
        gid.z >= uint(uniforms.resolution.z)) {
        return;
    }
    
    // Compute world-space position for this voxel center
    float3 worldPos = uniforms.gridOrigin + (float3(gid) + 0.5) * uniforms.voxelSize;
    
    // Create fractal params for sceneSDF (no bubble for grid building - we want the actual SDF)
    FractalParams params = makeFractalParams(uniforms.minDistance, uniforms.fractalScale, 
                                              uniforms.sphereRadius, uniforms.fractalIterations,
                                              float3(0.0), 0.0, 0);
    
    // Evaluate analytic SDF (your existing Map function)
    float sdf = Map(worldPos, params, uniforms.foldingLimit, uniforms.fractalIterations);
    
    // Encode to normalized [-1, 1] range
    // d = v_norm * (scale * voxelDiagonal) => v_norm = d / (scale * voxelDiagonal)
    // Scale of 4.0 balances precision near surface with range in empty space
    float voxelDiag = sqrt(3.0) * uniforms.voxelSize;
    float scale = 4.0 * voxelDiag;
    float vNorm = clamp(sdf / scale, -1.0, 1.0);
    
    // Write to 3D texture (R channel, snorm8 will be converted from float)
    outputSDF.write(float4(vNorm, 0.0, 0.0, 1.0), gid);
}

// Build coarser levels using MIN downsampling (conservative for sphere tracing)
// We take the minimum SDF value to ensure we never overstep thin features
kernel void buildSDFGridCoarseLevel(
    uint3 gid [[thread_position_in_grid]],
    constant SDFGridBuildUniforms& uniforms [[buffer(0)]],
    texture3d<float, access::read> finerLevel [[texture(0)]],
    texture3d<float, access::write> outputSDF [[texture(1)]]
) {
    if (gid.x >= uint(uniforms.resolution.x) ||
        gid.y >= uint(uniforms.resolution.y) ||
        gid.z >= uint(uniforms.resolution.z)) {
        return;
    }
    
    // Read 2x2x2 block from finer level and take minimum
    // This ensures conservative stepping - we never step past a surface
    uint3 baseCoord = gid * 2;
    
    float minVal = 1.0;  // Start with max possible normalized value
    
    for (uint dz = 0; dz < 2; ++dz) {
        for (uint dy = 0; dy < 2; ++dy) {
            for (uint dx = 0; dx < 2; ++dx) {
                float child = finerLevel.read(baseCoord + uint3(dx, dy, dz)).r;
                minVal = min(minVal, child);
            }
        }
    }
    
    // Write minimum value - conservative for sphere tracing
    outputSDF.write(float4(minVal, 0.0, 0.0, 1.0), gid);
}

// =============================================================================

// Simplified post effects using half precision
half3 PostEffects(half3 rgb, half2 xy, half limitFlash = 0.0h)
{
    // Combined contrast/saturation/brightness in fewer ops
    half luma = dot(rgb, half3(0.2126h, 0.7152h, 0.0722h));
    rgb = mix(half3(luma), rgb, 1.5h) * 1.5h; // saturation + brightness
    rgb = mix(half3(0.5h), rgb, 1.08h);       // contrast
    
    // Simplified vignette
    half2 q = xy * (1.0h - xy);
    half vignetteBase = max(16.0h * q.x * q.y, kPowEpsilonHalf);
    rgb *= 0.5h + 0.5h * powr(vignetteBase, 0.2h);
    
    // Limit flash effect - bright edge glow when parameter hits min/max
    if (limitFlash > 0.01h) {
        // Edge distance (0 at center, 1 at edge)
        half2 edgeDist = abs(xy - 0.5h) * 2.0h;
        half edge = max(edgeDist.x, edgeDist.y);
        
        // Glow strongest at edges, using smooth falloff
        half edgeGlow = powr(edge, 2.0h) * limitFlash;
        
        // Orange/red warning color
        half3 flashColor = half3(1.0h, 0.4h, 0.1h);
        rgb = mix(rgb, flashColor, edgeGlow * 0.8h);
    }
    
    // Gamma
    return powr(max(rgb, half3(kPowEpsilonHalf)), half3(kGamma));
}

// =============================================================================
// HUD RENDERING - Simple bar display for parameters
// =============================================================================

// Draw a horizontal bar showing parameter value within range
float hudBar(float2 uv, float2 pos, float2 size, float fillAmount) {
    float2 localUV = (uv - pos) / size;
    if (localUV.x < 0.0 || localUV.x > 1.0 || localUV.y < 0.0 || localUV.y > 1.0) return 0.0;
    
    // Border (2% edge)
    float border = (localUV.x < 0.02 || localUV.x > 0.98 || localUV.y < 0.08 || localUV.y > 0.92) ? 0.6 : 0.0;
    
    // Fill bar
    float fill = (localUV.x > 0.02 && localUV.x < fillAmount * 0.96 + 0.02 && localUV.y > 0.08 && localUV.y < 0.92) ? 1.0 : 0.0;
    
    return max(border, fill);
}

// Render HUD overlay showing current Mandelbox parameter values
half3 renderHUD(half3 baseColor, float2 uv, int activeGesture,
                float minDist, float foldLimit, float sphereRad) {
    // HUD in bottom-left corner
    float2 hudPos = float2(0.02, 0.02);
    float hudWidth = 0.2;
    float hudHeight = 0.15;
    
    float2 hudUV = (uv - hudPos) / float2(hudWidth, hudHeight);
    
    // Only render in HUD area
    if (hudUV.x < 0.0 || hudUV.x > 1.0 || hudUV.y < 0.0 || hudUV.y > 1.0) {
        return baseColor;
    }
    
    half3 hudColor = half3(0.0h);
    float alpha = 0.0;
    
    // Semi-transparent background
    float bg = 0.25;
    
    // Mandelbox: minDistance (0.001-5), foldingLimit (0.1-10), sphereRadius (0.01-2)
    float fill1 = clamp(minDist / 5.0, 0.0, 1.0);
    float fill2 = clamp(foldLimit / 10.0, 0.0, 1.0);
    float fill3 = clamp(sphereRad / 2.0, 0.0, 1.0);
    
    float bar1 = hudBar(hudUV, float2(0.05, 0.68), float2(0.9, 0.22), fill1);
    float bar2 = hudBar(hudUV, float2(0.05, 0.39), float2(0.9, 0.22), fill2);
    float bar3 = hudBar(hudUV, float2(0.05, 0.10), float2(0.9, 0.22), fill3);
    
    // Colors: index=cyan, middle=yellow, ring=magenta
    // Highlight active gesture
    float h1 = (activeGesture == 1) ? 1.5 : 1.0;
    float h2 = (activeGesture == 2) ? 1.5 : 1.0;
    float h3 = (activeGesture == 3) ? 1.5 : 1.0;
    
    hudColor += half3(0.0h, 1.0h, 1.0h) * half(bar1 * h1);   // Cyan - minDistance
    hudColor += half3(1.0h, 1.0h, 0.0h) * half(bar2 * h2);   // Yellow - foldingLimit
    hudColor += half3(1.0h, 0.0h, 1.0h) * half(bar3 * h3);   // Magenta - sphereRadius
    
    alpha = max(max(bar1, bar2), bar3);
    
    // Blend: background + bars
    alpha = max(alpha, bg);
    return mix(baseColor, hudColor + half3(0.05h), half(alpha * 0.85));
}

// =============================================================================

// === OPTIMIZED SHADOW WITH HALF PRECISION ===
// Uses half precision for intermediate calculations on Apple Silicon
// Apple GPUs have 2x throughput for half precision operations
// FORCE_INLINE: Called twice per lit pixel (spot + sun)
FORCE_INLINE float Shadow(float3 ro, float3 rd, float quality, float foldingLimit, FractalParams params, int iterations)
{
    // Skip shadows in extreme periphery - early out
    if (UNLIKELY(quality < kMinQualityForShadows)) return 0.65;
    
    half res = 1.0h;
    float t = 0.08;
    half prevH = half(1e10);
    
    // Very few steps for shadows - unroll completely
    int steps = int(fma(quality, 3.0, 1.0)); // 1-4 steps
    
    // Precompute half precision folding limit
    half foldingLimitH = half(foldingLimit);
    
    UNROLL_4
    for (int i = 0; i < 4; i++)
    {
        if (i >= steps) break;
        
        float3 p = fma(rd, float3(t), ro);
        
        // Use half precision Map for shadow rays (precision less critical)
        half h = MapHalf(half3(p), params, foldingLimitH, iterations);
        
        // Soft shadow calculation with improved penumbra
        half shadowK = 10.0h;
        res = min(res, shadowK * h / half(t));
        
        // UNLIKELY: Most shadow rays don't hit
        if (UNLIKELY(res < 0.02h)) return 0.0;
        
        // Enhanced over-relaxation for shadows (can be more aggressive)
        half relax = step(prevH * 0.7h, h);
        half stepSize = mix(h, h * 1.8h, relax);
        t += max(float(stepSize), 0.12f);
        prevH = h;
        
        // UNLIKELY: Shadows don't trace far
        if (UNLIKELY(t > 4.0)) break;
    }
    
    return float(saturate(res));
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

// Per-pixel normal calculation - fast tetrahedron method (4 samples, better accuracy)
// FORCE_INLINE critical - called for every lit pixel
FORCE_INLINE float3 GetNormalFast(float3 pos, float distance, FractalParams params, float foldingLimit, int iterations)
{
    float e = max(distance * 0.0005, 0.0001);
    
    // Tetrahedron technique - 4 samples gives better gradient estimate
    // The h vectors form a tetrahedron, giving unbiased gradient
    float2 h = float2(1.0, -1.0) * e;
    float3 gradient = 
        h.xyy * Map(pos + h.xyy, params, foldingLimit, iterations) +
        h.yyx * Map(pos + h.yyx, params, foldingLimit, iterations) +
        h.yxy * Map(pos + h.yxy, params, foldingLimit, iterations) +
        h.xxx * Map(pos + h.xxx, params, foldingLimit, iterations);
    
    // rsqrt is faster than normalize on GPU (single instruction vs sqrt+div)
    return gradient * rsqrt(dot(gradient, gradient) + kPowEpsilon);
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
    threadgroup float sharedCoarseT = kRayMissThreshold + 100.0;
    threadgroup float3 sharedCenterRayDir = float3(0.0);
    threadgroup FractalParams sharedFractalParams;
    threadgroup FractalParams sharedShadowParams;
    threadgroup float3 sharedCameraPos = float3(0.0);
    threadgroup float4x4 sharedInvProjMatrix;
    threadgroup float4x4 sharedInvViewMatrix;
    threadgroup float3 sharedRayDirs[16];

    int lodIterations = max(uniforms.fractalIterations, 2);

    // Leader thread precomputes shared data
    if (localId.x == 1 && localId.y == 1) {
        sharedFractalParams = makeFractalParams(uniforms.minDistance, uniforms.fractalScale, uniforms.sphereRadius, lodIterations,
                                                 uniforms.cameraPos, uniforms.safetyBubbleRadius, uniforms.safetyBubbleEnabled);
        int shadowIterations = max(lodIterations - 2, 2);
        sharedShadowParams = makeFractalParams(uniforms.minDistance, uniforms.fractalScale, uniforms.sphereRadius, shadowIterations,
                                                uniforms.cameraPos, uniforms.safetyBubbleRadius, uniforms.safetyBubbleEnabled);
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
    // Note: invProjMatrix/invViewMatrix precomputed into sharedRayDirs by leader
    float3 rd = sharedRayDirs[localId.y * 4 + localId.x];

    // Build RefiningParams from uniforms for runtime tuning
    RefiningParams refining;
    refining.relaxFactor = uniforms.relaxFactor;
    refining.relaxBacktrack = uniforms.relaxBacktrack;
    refining.sdfScaleCoarse = uniforms.sdfScaleCoarse;
    refining.sdfScaleSuperCoarse = uniforms.sdfScaleSuperCoarse;
    refining.earlyTermRatio = uniforms.earlyTermRatio;
    refining.earlyTermCount = uniforms.earlyTermCount;
    
    // === LEVEL 1: COARSE RAYMARCH (leader thread only) ===
    if (localId.x == 1 && localId.y == 1) {
        sharedCenterRayDir = rd;
        sharedCoarseT = SceneCoarse(cameraPos, rd, uniforms.foldingLimit, fractalParams, lodIterations, refining);
    }

    threadgroup_barrier(mem_flags::mem_threadgroup);

    float coarseT = sharedCoarseT;
    float3 centerRayDir = sharedCenterRayDir;
    
    // === LEVEL 2: FINE RAYMARCH (all threads, from starting point) ===
    half3 col = half3(0.0h);
    float gTime = uniforms.time * 0.01 + 15.00;
    float adjustedDist = 1000.0;
    float glow = 0.0;
    
    if (coarseT < kRayMissThreshold) {
        // Adjust starting distance for this pixel's ray direction
        float rayDot = max(dot(rd, centerRayDir), 0.9);
        float myStartT = coarseT * rayDot;
        
        // Fine raymarch from the starting point
        float2 tileCenter = float2(pixelCoord) + 0.5;
        float2 ret = SceneFromStart(uniforms.cameraPos, rd, myStartT, tileCenter, 1.0, uniforms.maxRaySteps, 
                                    uniforms.glowIntensity, uniforms.foldingLimit, fractalParams, lodIterations, uniforms.time);
        
        adjustedDist = ret.x;
        glow = ret.y;
        
        if (ret.x < kRayMissThreshold) {
            // Calculate per-pixel hit point
            float3 p = uniforms.cameraPos + adjustedDist * rd;
            
            // Per-pixel normal for smooth shading
            float3 nor = GetNormalFast(p, adjustedDist, fractalParams, uniforms.foldingLimit, lodIterations);
            
            // Lighting
            float3 spotLight = CameraPath(gTime + 0.03) + float3(sin(gTime*18.4), cos(gTime*17.98), sin(gTime * 22.53)) * 0.2;
            float3 spot = spotLight - p;
            float atten = length(spot);
            spot /= atten;
            
            // Use pre-computed shadow params from leader thread (avoid redundant creation)
            half shaSpot = half(Shadow(p, spot, 0.7, uniforms.foldingLimit, shadowParams, shadowParams.absScalem1 > 0 ? lodIterations - 2 : 2));
            half shaSun = half(Shadow(p, sunDir, 0.7, uniforms.foldingLimit, shadowParams, shadowParams.absScalem1 > 0 ? lodIterations - 2 : 2));
            
            float attenPow = powr(max(atten, kPowEpsilon), kAttenPower);
            half bri = half(max(dot(spot, nor), 0.0) / attenPow * 0.25);
            half briSun = half(max(dot(sunDir, nor), 0.0) * 0.2);
            
            col = Colour(p, adjustedDist, gTime, 0.8, uniforms.minDistance, uniforms.fractalScale, 
                        uniforms.colorMix, uniforms.foldingLimit, uniforms.sphereRadius, 
                        max(int(uniforms.colorIterations * 0.8), 2));
            col = (col * bri * shaSpot) + (col * briSun * shaSun);
            
            // Specular
            float3 ref = reflect(rd, nor);
            float specSpot = powr(max(max(dot(spot, ref), 0.0), kPowEpsilon), kSpecularPower) * kSpecularIntensity;
            float specSun = powr(max(max(dot(sunDir, ref), 0.0), kPowEpsilon), kSpecularPower) * kSpecularIntensity;
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
    col = powr(max(saturate(col), half3(kPowEpsilonHalf)), half3(kGamma));
    
    // Debug visualization: show hierarchical status
    // Green tint = coarse pass found hit (hierarchical worked)
    // Red tint = coarse missed, background/sky
    if (uniforms.debugHierarchical == 1) {
        if (coarseT < kRayMissThreshold) {
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
    
    threadgroup float sharedCoarseT = kRayMissThreshold + 100.0;
    threadgroup float3 sharedCenterRayDir = float3(0.0);
    
    int lodIterations = max(uniforms.fractalIterations, 2);
    FractalParams fractalParams = makeFractalParams(uniforms.minDistance, uniforms.fractalScale, uniforms.sphereRadius, lodIterations,
                                                     uniforms.cameraPos, uniforms.safetyBubbleRadius, uniforms.safetyBubbleEnabled);
    
    float2 pixelCenter = float2(pixelCoord) + 0.5;
    float2 ndc = (pixelCenter / uniforms.resolution) * 2.0 - 1.0;
    ndc.y = -ndc.y;
    
    float4 viewPos = uniforms.invProjMatrix * float4(ndc, -1.0, 1.0);
    viewPos /= viewPos.w;
    float3 rd = normalize((uniforms.invViewMatrix * float4(viewPos.xyz, 0.0)).xyz);
    
    // Build RefiningParams from uniforms for runtime tuning
    RefiningParams refining;
    refining.relaxFactor = uniforms.relaxFactor;
    refining.relaxBacktrack = uniforms.relaxBacktrack;
    refining.sdfScaleCoarse = uniforms.sdfScaleCoarse;
    refining.sdfScaleSuperCoarse = uniforms.sdfScaleSuperCoarse;
    refining.earlyTermRatio = uniforms.earlyTermRatio;
    refining.earlyTermCount = uniforms.earlyTermCount;
    
    // === LEVEL 1: COARSE RAYMARCH (leader thread only) ===
    if (localIndex == 0) {
        sharedCenterRayDir = rd;
        sharedCoarseT = SceneCoarse(uniforms.cameraPos, rd, uniforms.foldingLimit, fractalParams, lodIterations, refining);
    }
    
    threadgroup_barrier(mem_flags::mem_threadgroup);
    
    float coarseT = sharedCoarseT;
    float3 centerRayDir = sharedCenterRayDir;
    
    // === LEVEL 2: FINE RAYMARCH (all threads) ===
    half3 col = half3(0.0h);
    float gTime = uniforms.time * 0.01 + 15.00;
    float adjustedDist = 1000.0;
    float glow = 0.0;
    
    if (coarseT < kRayMissThreshold) {
        float rayDot = max(dot(rd, centerRayDir), 0.9);
        float myStartT = coarseT * rayDot;
        
        float2 ret = SceneFromStart(uniforms.cameraPos, rd, myStartT, pixelCenter, 1.0, uniforms.maxRaySteps,
                                    uniforms.glowIntensity, uniforms.foldingLimit, fractalParams, lodIterations, uniforms.time);
        
        adjustedDist = ret.x;
        glow = ret.y;
        
        if (ret.x < kRayMissThreshold) {
            float3 p = uniforms.cameraPos + adjustedDist * rd;
            float3 nor = GetNormalFast(p, adjustedDist, fractalParams, uniforms.foldingLimit, lodIterations);
            
            float3 spotLight = CameraPath(gTime + 0.03) + float3(sin(gTime*18.4), cos(gTime*17.98), sin(gTime * 22.53)) * 0.2;
            float3 spot = spotLight - p;
            float atten = length(spot);
            spot /= atten;
            
            int shadowIterations = max(lodIterations - 2, 2);
            FractalParams shadowParams = makeFractalParams(uniforms.minDistance, uniforms.fractalScale, uniforms.sphereRadius, shadowIterations,
                                                            uniforms.cameraPos, uniforms.safetyBubbleRadius, uniforms.safetyBubbleEnabled);
            
            half shaSpot = half(Shadow(p, spot, 0.8, uniforms.foldingLimit, shadowParams, shadowIterations));
            half shaSun = half(Shadow(p, sunDir, 0.8, uniforms.foldingLimit, shadowParams, shadowIterations));
            
            float attenPow = powr(max(atten, kPowEpsilon), kAttenPower);
            half bri = half(max(dot(spot, nor), 0.0) / attenPow * 0.25);
            half briSun = half(max(dot(sunDir, nor), 0.0) * 0.2);
            
            col = Colour(p, adjustedDist, gTime, 1.0, uniforms.minDistance, uniforms.fractalScale, 
                        uniforms.colorMix, uniforms.foldingLimit, uniforms.sphereRadius, uniforms.colorIterations);
            col = (col * bri * shaSpot) + (col * briSun * shaSun);
            
            float3 ref = reflect(rd, nor);
            float specSpot = powr(max(max(dot(spot, ref), 0.0), kPowEpsilon), kSpecularPower) * kSpecularIntensity;
            float specSun = powr(max(max(dot(sunDir, ref), 0.0), kPowEpsilon), kSpecularPower) * kSpecularIntensity;
            col += half3(specSpot) * shaSpot * bri;
            col += half3(specSun) * shaSun * briSun;
            
            half fogFactor = half(saturate(exp(-adjustedDist + 1.5)));
            col = mix(half3(0.02h, 0.03h, 0.04h), col, fogFactor);
        }
    }
    
    half glowH = half(glow);
    col += glowH * glowH * half3(0.02h, 0.04h, 0.1h);
    col = clamp(col, half3(0.0h), half3(2.0h));
    col = powr(max(saturate(col), half3(kPowEpsilonHalf)), half3(kGamma));
    
    // Debug visualization for 2x2 kernel
    if (uniforms.debugHierarchical == 1) {
        if (coarseT < kRayMissThreshold) {
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
    const uint ADAPTIVE_TILE_SIZE = 8;
    uint2 pixelCoord = tileId * ADAPTIVE_TILE_SIZE + localId;
    
    if (pixelCoord.x >= uint(uniforms.resolution.x) || pixelCoord.y >= uint(uniforms.resolution.y)) {
        return;
    }
    
    // Compute ray direction in MODEL SPACE (matching fragment shader exactly)
    // Fragment shader does: rd = normalize(in.modelPos - cameraPos)
    // where modelPos comes from vertex positions and cameraPos is (invModelView * (0,0,0,1)).xyz
    //
    // For compute, we need to:
    // 1. Unproject pixel to clip space
    // 2. Transform through inverse projection to get view-space point
    // 3. Transform through inverse model-view to get model-space point
    // 4. Compute direction from camera to that point (both in model space)
    
    float2 pixelCenter = float2(pixelCoord) + 0.5;
    float2 ndc = (pixelCenter / uniforms.resolution) * 2.0 - 1.0;
    ndc.y = -ndc.y;
    
    // Unproject to view space - use z = -1 (view-space convention: -Z is forward)
    // This matches how the vertex shader projects positions and ensures consistency
    // with wide FOV projections
    float4 clipPos = float4(ndc.x, ndc.y, 0.0, 1.0);  // Near plane in clip space
    float4 viewPos = uniforms.invProjMatrix * clipPos;
    // For perspective projection, we need the direction, not normalized position
    // viewPos.w will be 1 after inverse projection of a point at z=0
    float3 viewDir = normalize(viewPos.xyz);
    
    // Transform direction to model space (inverse model-view matrix)
    // Use w=0 for direction transformation (no translation)
    float3 rd = normalize((uniforms.invViewMatrix * float4(viewDir, 0.0)).xyz);
    
    // Camera position in model space (same as fragment shader)
    float3 cameraPos = uniforms.cameraPos;
    
    int lodIterations = max(uniforms.fractalIterations, 2);
    FractalParams fractalParams = makeFractalParams(uniforms.minDistance, uniforms.fractalScale, uniforms.sphereRadius, lodIterations,
                                                     cameraPos, uniforms.safetyBubbleRadius, uniforms.safetyBubbleEnabled);
    
    float gTime = uniforms.time * 0.01 + 15.00;
    
    // Build RefiningParams from uniforms for runtime tuning
    RefiningParams refining;
    refining.relaxFactor = uniforms.relaxFactor;
    refining.relaxBacktrack = uniforms.relaxBacktrack;
    refining.sdfScaleCoarse = uniforms.sdfScaleCoarse;
    refining.sdfScaleSuperCoarse = uniforms.sdfScaleSuperCoarse;
    refining.earlyTermRatio = uniforms.earlyTermRatio;
    refining.earlyTermCount = uniforms.earlyTermCount;
    
    // Use the SAME Scene() function as fragment shader for correctness
    float2 ret = Scene(cameraPos, rd, pixelCenter, 1.0, uniforms.maxRaySteps, 
                       uniforms.glowIntensity, uniforms.foldingLimit, fractalParams, lodIterations, uniforms.time, refining);
    
    float adjustedDist = ret.x;
    float glow = ret.y;
    half3 col = half3(0.0h);
    
    if (ret.x < kRayMissThreshold) {
        float3 p = cameraPos + adjustedDist * rd;
        float3 nor = GetNormalFast(p, adjustedDist, fractalParams, uniforms.foldingLimit, lodIterations);
        
        // Lighting (same as fragment shader)
        float3 spotLight = CameraPath(gTime + 0.03) + float3(sin(gTime*18.4), cos(gTime*17.98), sin(gTime * 22.53)) * 0.2;
        float3 spot = spotLight - p;
        float atten = length(spot);
        spot /= atten;
        
        int shadowIterations = max(lodIterations - 2, 2);
        FractalParams shadowParams = makeFractalParams(uniforms.minDistance, uniforms.fractalScale, uniforms.sphereRadius, shadowIterations,
                                                        cameraPos, uniforms.safetyBubbleRadius, uniforms.safetyBubbleEnabled);
        
        half shaSpot = half(Shadow(p, spot, 0.8, uniforms.foldingLimit, shadowParams, shadowIterations));
        half shaSun = half(Shadow(p, sunDir, 0.8, uniforms.foldingLimit, shadowParams, shadowIterations));
        
        float attenPow = powr(max(atten, kPowEpsilon), kAttenPower);
        half bri = half(max(dot(spot, nor), 0.0) / attenPow * 0.25);
        half briSun = half(max(dot(sunDir, nor), 0.0) * 0.2);
        
        col = Colour(p, adjustedDist, gTime, 1.0, uniforms.minDistance, uniforms.fractalScale, 
                    uniforms.colorMix, uniforms.foldingLimit, uniforms.sphereRadius, uniforms.colorIterations);
        col = (col * bri * shaSpot) + (col * briSun * shaSun);
        
        // Specular
        float3 ref = reflect(rd, nor);
        float specSpot = powr(max(max(dot(spot, ref), 0.0), kPowEpsilon), kSpecularPower) * kSpecularIntensity;
        float specSun = powr(max(max(dot(sunDir, ref), 0.0), kPowEpsilon), kSpecularPower) * kSpecularIntensity;
        col += half3(specSpot) * shaSpot * bri;
        col += half3(specSun) * shaSun * briSun;
    }
    
    // Fog (applied regardless of hit, same as fragment shader)
    half fogFactor = half(saturate(exp(-adjustedDist + 1.5)));
    col = mix(half3(0.02h, 0.03h, 0.04h), col, fogFactor);
    
    // Add glow
    half glowH = half(glow);
    col += glowH * glowH * half3(0.02h, 0.04h, 0.1h);
    col = clamp(col, half3(0.0h), half3(2.0h));
    
    // Apply PostEffects to match fragment shader exactly
    // (saturation, contrast, vignette, gamma)
    // Compute approximate texCoord for vignette (0-1 range)
    half2 texCoord = half2(pixelCenter / uniforms.resolution);
    col = PostEffects(col, texCoord, half(uniforms.limitFlash));
    
    // Debug visualization
    if (uniforms.debugHierarchical == 1) {
        // Show tile boundaries
        if (localId.x == 0 || localId.y == 0) {
            col = mix(col, half3(1.0h, 1.0h, 0.0h), 0.5h);
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

// =============================================================================
// SOPHISTICATED FUR HAND RENDERING
// =============================================================================
// Strand-based raymarching with Kajiya-Kay anisotropic shading model
// Features: Volumetric density, proper hair lighting, self-shadowing, color variation

// SDF for a single hand bone (capsule between two joints)
// FORCE_INLINE: Called 20+ times per sdHandSkeleton call
FORCE_INLINE float sdCapsule(float3 p, float3 a, float3 b, float r) {
    float3 pa = p - a;
    float3 ba = b - a;
    // Optimized: precompute reciprocal of dot(ba,ba) would help if ba is constant
    float h = saturate(dot(pa, ba) / dot(ba, ba));  // saturate = clamp(x,0,1), free on GPU
    return length(fma(ba, float3(-h), pa)) - r;  // pa - ba*h using fma
}

// SDF for entire hand skeleton (union of capsules)
float sdHandSkeleton(float3 p, constant FurHandData& hand) {
    if (hand.isTracked == 0) return 1000.0;
    
    float d = 1000.0;
    float3 wrist = hand.joints[0].position;
    float wristR = hand.joints[0].radius;
    
    // Thumb chain
    d = min(d, sdCapsule(p, hand.joints[1].position, hand.joints[2].position, hand.joints[1].radius * 1.2));
    d = min(d, sdCapsule(p, hand.joints[2].position, hand.joints[3].position, hand.joints[2].radius * 1.1));
    d = min(d, sdCapsule(p, hand.joints[3].position, hand.joints[4].position, hand.joints[3].radius));
    
    // Index finger
    d = min(d, sdCapsule(p, wrist, hand.joints[5].position, wristR * 0.8));
    d = min(d, sdCapsule(p, hand.joints[5].position, hand.joints[6].position, hand.joints[5].radius));
    d = min(d, sdCapsule(p, hand.joints[6].position, hand.joints[7].position, hand.joints[6].radius));
    d = min(d, sdCapsule(p, hand.joints[7].position, hand.joints[8].position, hand.joints[7].radius * 0.9));
    
    // Middle finger
    d = min(d, sdCapsule(p, wrist, hand.joints[9].position, wristR * 0.8));
    d = min(d, sdCapsule(p, hand.joints[9].position, hand.joints[10].position, hand.joints[9].radius));
    d = min(d, sdCapsule(p, hand.joints[10].position, hand.joints[11].position, hand.joints[10].radius));
    d = min(d, sdCapsule(p, hand.joints[11].position, hand.joints[12].position, hand.joints[11].radius * 0.9));
    
    // Ring finger
    d = min(d, sdCapsule(p, wrist, hand.joints[13].position, wristR * 0.7));
    d = min(d, sdCapsule(p, hand.joints[13].position, hand.joints[14].position, hand.joints[13].radius));
    d = min(d, sdCapsule(p, hand.joints[14].position, hand.joints[15].position, hand.joints[14].radius));
    d = min(d, sdCapsule(p, hand.joints[15].position, hand.joints[16].position, hand.joints[15].radius * 0.9));
    
    // Little finger
    d = min(d, sdCapsule(p, wrist, hand.joints[17].position, wristR * 0.6));
    d = min(d, sdCapsule(p, hand.joints[17].position, hand.joints[18].position, hand.joints[17].radius * 0.9));
    d = min(d, sdCapsule(p, hand.joints[18].position, hand.joints[19].position, hand.joints[18].radius * 0.9));
    d = min(d, sdCapsule(p, hand.joints[19].position, hand.joints[20].position, hand.joints[19].radius * 0.85));
    
    // Palm mesh
    d = min(d, sdCapsule(p, hand.joints[5].position, hand.joints[9].position, wristR * 0.5));
    d = min(d, sdCapsule(p, hand.joints[9].position, hand.joints[13].position, wristR * 0.5));
    d = min(d, sdCapsule(p, hand.joints[13].position, hand.joints[17].position, wristR * 0.45));
    
    return d;
}

// Get surface normal of hand skeleton (with safety for degenerate cases)
float3 getHandNormal(float3 p, constant FurHandData& hand) {
    float e = 0.0005;
    float3 grad = float3(
        sdHandSkeleton(p + float3(e,0,0), hand) - sdHandSkeleton(p - float3(e,0,0), hand),
        sdHandSkeleton(p + float3(0,e,0), hand) - sdHandSkeleton(p - float3(0,e,0), hand),
        sdHandSkeleton(p + float3(0,0,e), hand) - sdHandSkeleton(p - float3(0,0,e), hand)
    );
    float len = length(grad);
    // Safety check to prevent division by zero
    if (len < 0.00001) return float3(0.0, 1.0, 0.0);
    return grad / len;
}

// High-quality 3D noise with derivatives for strand variation
float furNoise3D(float3 p) {
    float3 i = floor(p);
    float3 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float n = i.x + i.y * 157.0 + 113.0 * i.z;
    return mix(mix(mix(hash(n), hash(n + 1.0), f.x),
                   mix(hash(n + 157.0), hash(n + 158.0), f.x), f.y),
               mix(mix(hash(n + 113.0), hash(n + 114.0), f.x),
                   mix(hash(n + 270.0), hash(n + 271.0), f.x), f.y), f.z);
}

// Fractional Brownian Motion for natural variation
float furFBM(float3 p, int octaves) {
    float value = 0.0;
    float amplitude = 0.5;
    float frequency = 1.0;
    for (int i = 0; i < octaves; i++) {
        value += amplitude * furNoise3D(p * frequency);
        amplitude *= 0.5;
        frequency *= 2.0;
    }
    return value;
}

// === KAJIYA-KAY ANISOTROPIC HAIR SHADING ===
// Physically-based model for hair/fur rendering

// Kajiya-Kay diffuse term
float kajiyaDiffuse(float3 tangent, float3 lightDir) {
    float TdotL = dot(tangent, lightDir);
    return sqrt(max(0.0, 1.0 - TdotL * TdotL));
}

// Kajiya-Kay specular term with shifted tangent
float kajiyaSpecular(float3 tangent, float3 lightDir, float3 viewDir, float shift, float exponent) {
    float3 T = normalize(tangent + shift * normalize(cross(tangent, viewDir)));
    float TdotL = dot(T, lightDir);
    float TdotV = dot(T, viewDir);
    float sinTL = sqrt(max(0.0, 1.0 - TdotL * TdotL));
    float sinTV = sqrt(max(0.0, 1.0 - TdotV * TdotV));
    return pow(max(0.0, TdotL * TdotV + sinTL * sinTV), exponent);
}

// Marschner-inspired dual specular highlights
float3 dualSpecular(float3 tangent, float3 lightDir, float3 viewDir, float3 baseColor) {
    // Primary specular (R) - shifted towards root
    float spec1 = kajiyaSpecular(tangent, lightDir, viewDir, -0.1, 80.0);
    float3 specColor1 = float3(1.0, 0.98, 0.95);  // Slightly warm white
    
    // Secondary specular (TRT) - shifted towards tip, colored by hair
    float spec2 = kajiyaSpecular(tangent, lightDir, viewDir, 0.1, 25.0);
    float3 specColor2 = baseColor * 1.5;  // Tinted by hair color
    
    return spec1 * specColor1 * 0.4 + spec2 * specColor2 * 0.3;
}

// === VOLUMETRIC FUR DENSITY FIELD ===
// Creates a density field with strand-like structures

struct FurDensityResult {
    float density;      // Volumetric density at point
    float3 tangent;     // Local strand direction for anisotropic shading
    float3 color;       // Base fur color at this point
    float clumpId;      // For color variation per clump
};

FurDensityResult sampleFurDensity(float3 p, float3 surfaceNormal, float distToSurface, 
                                   float furLength, float noiseScale, float time) {
    FurDensityResult result;
    result.density = 0.0;
    result.tangent = surfaceNormal;
    result.color = float3(0.5);
    result.clumpId = 0.0;
    
    // Fur only exists within fur length from surface
    if (distToSurface < 0.0 || distToSurface > furLength) return result;
    
    // Normalized height in fur (0 = root, 1 = tip)
    float h = distToSurface / furLength;
    
    // === STRAND STRUCTURE ===
    // Create strand pattern using high-frequency noise
    float3 strandCoord = p * noiseScale * 15.0;
    
    // Clumping - strands group together
    float3 clumpCoord = p * noiseScale * 3.0;
    float clumpNoise = furFBM(clumpCoord, 3);
    result.clumpId = floor(clumpNoise * 8.0) / 8.0;
    
    // Individual strand pattern
    float strandPattern = furNoise3D(strandCoord);
    strandPattern = smoothstep(0.35, 0.65, strandPattern);
    
    // Strand frequency increases with clumping
    float clumpDensity = smoothstep(0.3, 0.7, clumpNoise);
    strandPattern = mix(strandPattern, 1.0, clumpDensity * 0.5);
    
    // === DENSITY FALLOFF ===
    // Density decreases from root to tip (tapered strands)
    float heightFalloff = 1.0 - pow(h, 1.5);
    
    // Random strand length variation
    float lengthVar = furNoise3D(p * noiseScale * 5.0 + 100.0);
    float maxHeight = 0.6 + lengthVar * 0.4;
    if (h > maxHeight) {
        heightFalloff *= smoothstep(1.0, maxHeight, h);
    }
    
    // Final density
    result.density = strandPattern * heightFalloff * clumpDensity;
    result.density = smoothstep(0.1, 0.5, result.density);
    
    // === STRAND TANGENT (for anisotropic shading) ===
    // Strands grow outward with slight curl/wave
    float3 baseDir = surfaceNormal;
    
    // Add curl variation
    float curlPhase = furNoise3D(p * noiseScale * 8.0 + 50.0) * 6.28;
    float curlAmount = h * 0.3;  // More curl at tips
    float3 curlOffset = float3(
        sin(curlPhase) * curlAmount,
        0.0,
        cos(curlPhase) * curlAmount
    );
    
    // Add gravity bend
    float3 gravityBend = float3(0.0, -1.0, 0.0) * h * h * 0.2;
    
    // Add time-based sway
    float swayPhase = time * 1.5 + furNoise3D(p * 2.0) * 3.0;
    float3 sway = float3(sin(swayPhase), 0.0, cos(swayPhase * 0.7)) * h * 0.05;
    
    result.tangent = normalize(baseDir + curlOffset + gravityBend + sway);
    
    // === FUR COLOR ===
    // Rich color variation based on position and clump
    float colorVar1 = furNoise3D(p * noiseScale * 2.0);
    float colorVar2 = furNoise3D(p * noiseScale * 6.0 + 200.0);
    
    // Base colors - warm orange/brown fur
    float3 rootColor = mix(
        float3(0.65, 0.35, 0.15),   // Dark brown
        float3(0.85, 0.55, 0.25),   // Golden brown
        colorVar1
    );
    float3 tipColor = mix(
        float3(0.95, 0.75, 0.45),   // Light golden
        float3(0.55, 0.30, 0.12),   // Dark tips
        colorVar2
    );
    
    // Blend from root to tip
    result.color = mix(rootColor, tipColor, pow(h, 0.7));
    
    // Add highlight strands
    float highlightMask = smoothstep(0.85, 0.95, furNoise3D(p * noiseScale * 12.0));
    result.color = mix(result.color, float3(1.0, 0.9, 0.7), highlightMask * 0.3);
    
    return result;
}

// === VOLUMETRIC FUR RAYMARCHING ===
struct FurHandResult {
    float t;           // Hit distance
    float3 color;      // Accumulated color
    float alpha;       // Accumulated opacity
    float3 normal;     // Surface normal for depth
    bool hit;          // Did we hit anything?
};

// Self-shadowing for fur (simplified)
float furShadow(float3 p, float3 lightDir, float distToSurface, float furLength,
                constant FurHandData& hand, float noiseScale, float time) {
    float shadow = 1.0;
    float stepSize = furLength * 0.15;
    
    float3 normal = getHandNormal(p, hand);
    
    for (int i = 0; i < 6; i++) {
        float3 sp = p + lightDir * stepSize * float(i + 1);
        float d = sdHandSkeleton(sp, hand);
        
        if (d < furLength && d > 0.0) {
            FurDensityResult density = sampleFurDensity(sp, normal, d, furLength, noiseScale, time);
            shadow *= 1.0 - density.density * 0.15;
        }
    }
    
    return max(shadow, 0.3);
}

FurHandResult raymarchFurHands(float3 ro, float3 rd, constant FurHandUniforms& furUniforms) {
    FurHandResult result;
    result.hit = false;
    result.t = 1000.0;
    result.color = float3(0.0);
    result.alpha = 0.0;
    result.normal = float3(0.0, 1.0, 0.0);
    
    if (furUniforms.showFurHands == 0) return result;
    
    // Safety: check if at least one hand is tracked
    bool leftTracked = furUniforms.leftHand.isTracked != 0;
    bool rightTracked = furUniforms.rightHand.isTracked != 0;
    if (!leftTracked && !rightTracked) return result;
    
    float furLength = furUniforms.leftHand.furLength;
    float noiseScale = furUniforms.leftHand.furNoiseScale;
    float time = furUniforms.time;
    
    // Safety: validate fur parameters
    if (furLength < 0.001 || furLength > 0.1) furLength = 0.012;
    if (noiseScale < 1.0 || noiseScale > 200.0) noiseScale = 80.0;
    
    // Light setup
    float3 lightDir = normalize(float3(0.5, 0.8, 0.3));
    float3 lightColor = float3(1.0, 0.95, 0.9) * 1.5;
    float3 ambientColor = float3(0.15, 0.18, 0.25);
    
    // Find entry point into fur volume
    float t = 0.01;
    float tMax = 2.0;  // Reduced max distance for performance
    
    // First, find where we enter the fur bounding volume
    for (int i = 0; i < 32; i++) {  // Reduced iterations
        float3 p = ro + rd * t;
        float dLeft = leftTracked ? sdHandSkeleton(p, furUniforms.leftHand) : 1000.0;
        float dRight = rightTracked ? sdHandSkeleton(p, furUniforms.rightHand) : 1000.0;
        float d = min(dLeft, dRight);
        
        if (d < furLength * 1.2) break;  // Enter fur volume
        
        t += max(d * 0.9, 0.001);  // Safety: ensure forward progress
        if (t > tMax) return result;
    }
    
    // Volumetric integration through fur
    float3 accumColor = float3(0.0);
    float accumAlpha = 0.0;
    float stepSize = furLength * 0.12;  // Slightly larger steps for performance
    float firstHitT = -1.0;
    float3 firstHitNormal = float3(0.0);
    
    for (int i = 0; i < 48 && accumAlpha < 0.95; i++) {  // Reduced iterations
        float3 p = ro + rd * t;
        
        // Check both hands (only if tracked)
        float dLeft = leftTracked ? sdHandSkeleton(p, furUniforms.leftHand) : 1000.0;
        float dRight = rightTracked ? sdHandSkeleton(p, furUniforms.rightHand) : 1000.0;
        bool isLeft = dLeft < dRight;
        float d = min(dLeft, dRight);
        constant FurHandData& activeHand = isLeft ? furUniforms.leftHand : furUniforms.rightHand;
        
        // Outside fur volume - skip ahead
        if (d > furLength * 1.5) {
            t += d * 0.8;
            if (t > tMax) break;
            continue;
        }
        
        // Inside hand surface - we hit the skin
        if (d < 0.001) {
            if (firstHitT < 0.0) {
                firstHitT = t;
                firstHitNormal = getHandNormal(p, activeHand);
            }
            
            // Skin color underneath fur
            float3 skinColor = float3(0.4, 0.25, 0.18);
            float skinAlpha = 1.0 - accumAlpha;
            accumColor += skinColor * skinAlpha * 0.5;
            accumAlpha = 1.0;
            break;
        }
        
        // Sample fur density
        float3 normal = getHandNormal(p, activeHand);
        FurDensityResult fur = sampleFurDensity(p, normal, d, furLength, noiseScale, time);
        
        if (fur.density > 0.01) {
            if (firstHitT < 0.0) {
                firstHitT = t;
                firstHitNormal = normal;
            }
            
            // === KAJIYA-KAY SHADING ===
            float diffuse = kajiyaDiffuse(fur.tangent, lightDir);
            float3 specular = dualSpecular(fur.tangent, lightDir, -rd, fur.color);
            
            // Self-shadowing
            float shadow = furShadow(p, lightDir, d, furLength, activeHand, noiseScale, time);
            
            // Rim lighting (backlit fur glow)
            float rim = pow(1.0 - saturate(dot(normal, -rd)), 3.0);
            float backlit = saturate(dot(-rd, lightDir));
            float3 rimColor = fur.color * rim * backlit * 0.6;
            
            // Ambient occlusion approximation
            float ao = mix(0.5, 1.0, d / furLength);
            
            // Combine lighting
            float3 litColor = fur.color * diffuse * lightColor * shadow;
            litColor += specular * shadow;
            litColor += fur.color * ambientColor * ao;
            litColor += rimColor;
            
            // Accumulate with front-to-back compositing
            float sampleAlpha = fur.density * stepSize * 15.0;
            sampleAlpha = min(sampleAlpha, 1.0 - accumAlpha);
            
            accumColor += litColor * sampleAlpha;
            accumAlpha += sampleAlpha;
        }
        
        t += stepSize;
        if (t > tMax) break;
    }
    
    if (accumAlpha > 0.01) {
        result.hit = true;
        result.t = firstHitT > 0.0 ? firstHitT : t;
        result.color = accumColor;
        result.alpha = accumAlpha;
        result.normal = firstHitNormal;
    }
    
    return result;
}

// Shade fur result (mostly done in raymarch, this handles final compositing)
half3 shadeFurHands(FurHandResult furResult, float3 rd, float3 lightDir, float3 lightColor) {
    if (!furResult.hit) return half3(0.0);
    return half3(furResult.color);
}

// =============================================================================

// === SHARED LIGHTING COMPUTATION ===
// Consolidates common lighting code to improve i-cache locality and reduce duplication
struct LightingParams {
    float3 position;        // Hit position
    float3 normal;          // Surface normal
    float3 rd;              // Ray direction
    float distance;         // Hit distance
    float gTime;            // Animation time
    float quality;          // Quality level (0-1)
    FractalParams fractalParams;
    FractalParams shadowParams;
    float foldingLimit;
    int shadowIterations;
};

struct LightingResult {
    half3 color;            // Final lit color
    half shaSpot;           // Spot shadow
    half shaSun;            // Sun shadow
};

inline LightingResult computeLighting(LightingParams lp, Uniforms uniforms) {
    LightingResult result;
    
    float3 spotLight = CameraPath(lp.gTime + 0.03) + float3(sin(lp.gTime*18.4), cos(lp.gTime*17.98), sin(lp.gTime * 22.53)) * 0.2;
    float3 spot = spotLight - lp.position;
    float atten = length(spot);
    spot /= atten;
    
    result.shaSpot = half(Shadow(lp.position, spot, lp.quality, lp.foldingLimit, lp.shadowParams, lp.shadowIterations));
    result.shaSun = half(Shadow(lp.position, sunDir, lp.quality, lp.foldingLimit, lp.shadowParams, lp.shadowIterations));
    
    float attenPow = powr(max(atten, kPowEpsilon), kAttenPower);
    half bri = half(max(dot(spot, lp.normal), 0.0) / attenPow * 0.25);
    half briSun = half(max(dot(sunDir, lp.normal), 0.0) * 0.2);
    
    result.color = Colour(lp.position, lp.distance, lp.gTime, lp.quality, uniforms.minDistance, uniforms.fractalScale, 
                         uniforms.colorMix, uniforms.foldingLimit, uniforms.sphereRadius, 
                         max(int(uniforms.colorIterations * lp.quality), 2));
    result.color = (result.color * bri * result.shaSpot) + (result.color * briSun * result.shaSun);
    
    // Specular
    if (lp.quality > kMinQualityForSpecular) {
        float3 ref = reflect(lp.rd, lp.normal);
        float specSpot = powr(max(max(dot(spot, ref), 0.0), kPowEpsilon), kSpecularPower) * kSpecularIntensity;
        float specSun = powr(max(max(dot(sunDir, ref), 0.0), kPowEpsilon), kSpecularPower) * kSpecularIntensity;
        result.color += half3(specSpot) * result.shaSpot * bri;
        result.color += half3(specSun) * result.shaSun * briSun;
    }
    
    return result;
}

// Shared fragment body to avoid duplication and improve i-cache locality
// GST version with optional grid textures
inline FragmentOutput fragmentMainGST(ColorInOut in,
                                   Uniforms uniforms,
                                   float2 fragCoord,
                                   float time,
                                   bool useGST,
                                   constant SDFHierarchy& hierarchy,
                                   texture3d<float, access::sample> gstLevel0,
                                   texture3d<float, access::sample> gstLevel1,
                                   texture3d<float, access::sample> gstLevel2,
                                   texture3d<float, access::sample> gstLevel3)
{
    FragmentOutput output;
    
    float gTime = time * 0.01 + 15.00;
    float3 cameraPos = (uniforms.inverseModelViewMatrix * float4(0,0,0,1)).xyz;
    float3 rd = normalize(in.modelPos - cameraPos);
    
    // === Mandelbox Scene ===
    float quality = 1.0;
    int lodIterations = max(int(uniforms.fractalIterations), 2);
    FractalParams fractalParams = makeFractalParams(uniforms.minDistance, uniforms.fractalScale, uniforms.sphereRadius, lodIterations,
                                                     cameraPos, uniforms.safetyBubbleRadius, uniforms.safetyBubbleEnabled);

    // Build RefiningParams from uniforms for runtime tuning
    RefiningParams refining;
    refining.relaxFactor = uniforms.relaxFactor;
    refining.relaxBacktrack = uniforms.relaxBacktrack;
    refining.sdfScaleCoarse = uniforms.sdfScaleCoarse;
    refining.sdfScaleSuperCoarse = uniforms.sdfScaleSuperCoarse;
    refining.earlyTermRatio = uniforms.earlyTermRatio;
    refining.earlyTermCount = uniforms.earlyTermCount;

    float2 ret;
    bool usedGST = false;  // Track if GST was actually used
    
    // Use Grid Sphere Tracing if enabled and grid is built
    if (useGST && hierarchy.isBuilt != 0) {
        usedGST = true;
        
        GSTHit gstHit = gridSphereTraceRay(cameraPos, rd, hierarchy, 
                                           gstLevel0, gstLevel1, gstLevel2, gstLevel3,
                                           kMaxRayDistance, uniforms.glowIntensity);
        
        // DEBUG: Visualize GST state with colors
        // Comment this block out once GST is working
        if (false) {
            float3 gridMin = hierarchy.gridOrigin;
            float3 gridMax = gridMin + float3(hierarchy.gridExtent);
            
            // Sample BOTH raw texture value AND decoded SDF at camera
            constant SDFGridLevel& lvl = hierarchy.levels[0];
            float3 res = float3(lvl.resolution);
            
            // Get raw texture value
            float3 gridCoord = (cameraPos - gridMin) / lvl.voxelSize;
            float3 texCoord = gridCoord / res;
            texCoord = clamp(texCoord, float3(0.0), float3(1.0));
            constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
            float rawVNorm = gstLevel0.sample(s, texCoord).r;
            
            // Get decoded SDF value
            float decodedSDF = sampleSDFAtLevel(cameraPos, gridMin, gstLevel0, lvl.voxelSize, res, lvl.scale);
            
            // Check if camera is inside grid
            bool camInGrid = all(cameraPos >= gridMin) && all(cameraPos <= gridMax);
            
            // PRIMARY: Show decoded SDF distance (this is what ray marching uses)
            if (!camInGrid) {
                // MAGENTA = camera outside grid
                output.color = float4(0.5, 0.0, 0.5, 1.0);
            } else if (decodedSDF < 0.0) {
                // YELLOW = inside surface (negative SDF)
                output.color = float4(1.0, 1.0, 0.0, 1.0);
            } else if (decodedSDF < 0.1) {
                // RED = very close to surface (< 0.1)
                float brightness = decodedSDF * 10.0;  // 0.0-1.0
                output.color = float4(brightness, 0.0, 0.0, 1.0);
            } else if (decodedSDF < 1.0) {
                // ORANGE-YELLOW = close (0.1 - 1.0)
                float brightness = (decodedSDF - 0.1) / 0.9;
                output.color = float4(1.0, brightness * 0.5, 0.0, 1.0);
            } else if (decodedSDF < 3.0) {
                // GREEN = normal range (1.0 - 3.0)
                float brightness = (decodedSDF - 1.0) / 2.0;
                output.color = float4(0.0, brightness, 0.0, 1.0);
            } else {
                // BLUE = far away (> 3.0)
                float brightness = saturate((decodedSDF - 3.0) / 5.0);
                output.color = float4(0.0, 0.0, brightness, 1.0);
            }
            
            // CORNER: Show raw texture value in top-left
            if (fragCoord.x < 150.0 && fragCoord.y < 150.0) {
                // Show gradient: -1 (blue) to 0 (black) to +1 (white)
                if (rawVNorm < 0.0) {
                    output.color = float4(0.0, 0.0, -rawVNorm, 1.0);  // Blue for negative
                } else {
                    output.color = float4(rawVNorm, rawVNorm, rawVNorm, 1.0);  // White for positive
                }
            }
            
            output.depth = 1e-7;
            return output;
        }
        // END DEBUG
        
        if (gstHit.hit) {
            ret = float2(gstHit.t, gstHit.glow);
        } else {
            ret = float2(kRayMissThreshold + 100.0, gstHit.glow);
        }
    } else {
        // Fallback to standard analytic sphere tracing with RefiningParams
        ret = Scene(cameraPos, rd, fragCoord, quality, uniforms.maxRaySteps, uniforms.glowIntensity, uniforms.foldingLimit, fractalParams, lodIterations, time, refining);
    }
    
    half3 col = half3(0.0h);

    if (ret.x < kRayMissThreshold)
    {
        float3 p = cameraPos + ret.x * rd;
        float4 clipPos = uniforms.projectionMatrix * uniforms.modelViewMatrix * float4(p, 1.0);
        output.depth = clipPos.z / clipPos.w;

        // Debug: visualize depth as grayscale
        if (DEBUG_DEPTH_VISUALIZATION) {
            float depthGray = saturate(output.depth);
            output.color = float4(depthGray, depthGray, depthGray, 1.0);
            return output;
        }
    }
    else
    {
        output.depth = 1e-7;

        if (DEBUG_DEPTH_VISUALIZATION) {
            output.color = float4(0.0, 0.0, 0.0, 1.0);
            return output;
        }
    }

    if (ret.x < kRayMissThreshold)
    {
        float3 p = cameraPos + ret.x * rd;

        float3 nor;
        if (usedGST && hierarchy.isBuilt != 0) {
            // Use ANALYTIC normal even with GST for correct lighting
            // Grid-based normals are often too coarse/wrong for good shading
            if (quality > kMinQualityForNormals) {
                nor = GetNormal(p, ret.x, fractalParams, uniforms.foldingLimit, lodIterations);
            } else {
                nor = computeNormalFromGrid(p, hierarchy, gstLevel0);
            }
        } else if (quality > kMinQualityForNormals) {
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
            FractalParams shadowParams = makeFractalParams(uniforms.minDistance, uniforms.fractalScale, uniforms.sphereRadius, shadowIterations,
                                                            cameraPos, uniforms.safetyBubbleRadius, uniforms.safetyBubbleEnabled);

            half shaSpot = half(Shadow(p, spot, quality, uniforms.foldingLimit, shadowParams, shadowIterations));
            half shaSun = half(Shadow(p, sunDir, quality, uniforms.foldingLimit, shadowParams, shadowIterations));

            float attenPow = powr(max(atten, kPowEpsilon), kAttenPower);
            half bri = half(max(dot(spot, nor), 0.0) / attenPow * 0.25);
            half briSun = half(max(dot(sunDir, nor), 0.0) * 0.2);

            col = Colour(p, ret.x, gTime, quality, uniforms.minDistance, uniforms.fractalScale, uniforms.colorMix, uniforms.foldingLimit, uniforms.sphereRadius, max(int(uniforms.colorIterations * quality), 2));
            col = (col * bri * shaSpot) + (col * briSun * shaSun);

            if (quality > kMinQualityForSpecular) {
                float3 ref = reflect(rd, nor);
                float specSpot = powr(max(max(dot(spot, ref), 0.0), kPowEpsilon), kSpecularPower) * kSpecularIntensity;
                float specSun = powr(max(max(dot(sunDir, ref), 0.0), kPowEpsilon), kSpecularPower) * kSpecularIntensity;
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

    if (quality > kMinQualityForPostFX) {
        col = PostEffects(col, half2(in.texCoord), half(uniforms.limitFlash));
    } else {
        col = powr(max(saturate(col), half3(kPowEpsilonHalf)), half3(kGamma));
    }

    // Render HUD overlay if enabled
    if (uniforms.showHUD != 0) {
        col = renderHUD(col, float2(in.texCoord), uniforms.activeGesture,
                        uniforms.minDistance, uniforms.foldingLimit, uniforms.sphereRadius);
    }

    output.color = float4(float3(col), 1.0);
    return output;
}

fragment FragmentOutput fragmentShader(ColorInOut in [[stage_in]],
                               constant UniformsArray & uniformsArray [[buffer(BufferIndexUniforms)]],
                               constant FurHandUniforms & furHandUniforms [[buffer(BufferIndexFurHands)]],
                               constant SDFHierarchy & gstHierarchy [[buffer(BufferIndexGSTHierarchy)]],
                               ushort ampId [[amplification_id]],
                               texture2d<half> cubeMap [[texture(TextureIndexColor)]],
                               texture3d<float, access::sample> gstLevel0 [[texture(TextureIndexGSTLevel0)]],
                               texture3d<float, access::sample> gstLevel1 [[texture(TextureIndexGSTLevel1)]],
                               texture3d<float, access::sample> gstLevel2 [[texture(TextureIndexGSTLevel2)]],
                               texture3d<float, access::sample> gstLevel3 [[texture(TextureIndexGSTLevel3)]])
{
    Uniforms uniforms = uniformsArray.uniforms[ampId];
    float2 fragCoord = in.position.xy;
    
    // Get camera and ray direction in MODEL SPACE for fractal
    float3 cameraPos = (uniforms.inverseModelViewMatrix * float4(0,0,0,1)).xyz;
    float3 rd = normalize(in.modelPos - cameraPos);
    
    // Get camera and ray direction in WORLD SPACE for fur hands
    // Hands are tracked in world space (device-anchored coordinates)
    // Camera position in world space: inverse(viewMatrix) * (0,0,0,1)
    float3 worldCameraPos = (uniforms.inverseViewMatrix * float4(0,0,0,1)).xyz;
    // Transform mesh position to world space: inverse(viewMatrix) * modelViewMatrix * localPos
    float4 viewSpacePos = uniforms.modelViewMatrix * float4(in.modelPos, 1.0);
    float3 worldPos = (uniforms.inverseViewMatrix * viewSpacePos).xyz;
    float3 worldRd = normalize(worldPos - worldCameraPos);
    
    // First check fur hands in WORLD SPACE
    FurHandResult furResult = raymarchFurHands(worldCameraPos, worldRd, furHandUniforms);
    
    // Get fractal result - use GST if enabled
    bool useGST = (uniforms.useGST != 0) && (gstHierarchy.isBuilt != 0);
    FragmentOutput fractalOutput = fragmentMainGST(in, uniforms, fragCoord, uniforms.time,
                                                   useGST, gstHierarchy,
                                                   gstLevel0, gstLevel1, gstLevel2, gstLevel3);
    
    // Composite volumetric fur hands over fractal with alpha blending
    if (furResult.hit && furResult.alpha > 0.01) {
        float fractalDepth = fractalOutput.depth;
        
        // Compute fur hand depth in WORLD SPACE then project
        float3 furHitPos = worldCameraPos + furResult.t * worldRd;
        float4 furClipPos = uniforms.projectionMatrix * uniforms.viewMatrix * float4(furHitPos, 1.0);
        float furDepth = furClipPos.z / furClipPos.w;
        
        // If fur is closer or overlapping, blend it
        if (furResult.t < 900.0 && (fractalDepth < 0.001 || furDepth > fractalDepth)) {
            // Shade fur hands (color already computed in volumetric raymarch)
            float3 lightDir = normalize(float3(0.5, 0.8, 0.3));
            float3 lightColor = float3(1.0, 0.95, 0.9);
            half3 furColor = shadeFurHands(furResult, worldRd, lightDir, lightColor);
            
            // Alpha blend fur over fractal for volumetric transparency
            float alpha = furResult.alpha;
            float3 blendedColor = float3(furColor) * alpha + fractalOutput.color.rgb * (1.0 - alpha);
            fractalOutput.color = float4(blendedColor, 1.0);
            
            // Use fur depth if mostly opaque
            if (alpha > 0.5) {
                fractalOutput.depth = furDepth;
            }
        }
    }
    
    return fractalOutput;
}

// === HIERARCHICAL QUAD-SHARED RAYMARCHING ===
// Two-level approach:
// 1. Lane 0 does COARSE raymarch (few steps) to find approximate distance
// 2. All lanes do FINE raymarch from that starting point (far fewer steps needed)
// Combined with per-pixel normals for smooth shading
// ~8-16x reduction in total DE evaluations

fragment FragmentOutput fragmentShaderQuadShared(ColorInOut in [[stage_in]],
                               constant UniformsArray & uniformsArray [[buffer(BufferIndexUniforms)]],
                               constant FurHandUniforms & furHandUniforms [[buffer(BufferIndexFurHands)]],
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
    
    // World-space ray for fur hands
    float3 worldCameraPos = (uniforms.inverseViewMatrix * float4(0,0,0,1)).xyz;
    float4 viewSpacePos = uniforms.modelViewMatrix * float4(in.modelPos, 1.0);
    float3 worldPos = (uniforms.inverseViewMatrix * viewSpacePos).xyz;
    float3 worldRd = normalize(worldPos - worldCameraPos);
    
    // Check fur hands in world space
    FurHandResult furResult = raymarchFurHands(worldCameraPos, worldRd, furHandUniforms);
    
    int lodIterations = max(int(uniforms.fractalIterations), 2);
    FractalParams fractalParams = makeFractalParams(uniforms.minDistance, uniforms.fractalScale, uniforms.sphereRadius, lodIterations,
                                                     cameraPos, uniforms.safetyBubbleRadius, uniforms.safetyBubbleEnabled);
    
    // Build RefiningParams from uniforms for runtime tuning
    RefiningParams refining;
    refining.relaxFactor = uniforms.relaxFactor;
    refining.relaxBacktrack = uniforms.relaxBacktrack;
    refining.sdfScaleCoarse = uniforms.sdfScaleCoarse;
    refining.sdfScaleSuperCoarse = uniforms.sdfScaleSuperCoarse;
    refining.earlyTermRatio = uniforms.earlyTermRatio;
    refining.earlyTermCount = uniforms.earlyTermCount;
    
    // === STANDARD RAYMARCH (every pixel) ===
    // The hierarchical coarse/fine approach doesn't help due to SIMD lockstep execution
    float2 ret = Scene(cameraPos, rd, fragCoord, 1.0, uniforms.maxRaySteps, uniforms.glowIntensity, uniforms.foldingLimit, fractalParams, lodIterations, time, refining);
    float adjustedDist = ret.x;
    float glow = ret.y;
    
    half3 col = half3(0.0h);
    
    if (ret.x < kRayMissThreshold)
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
        FractalParams shadowParams = makeFractalParams(uniforms.minDistance, uniforms.fractalScale, uniforms.sphereRadius, shadowIterations,
                                                        cameraPos, uniforms.safetyBubbleRadius, uniforms.safetyBubbleEnabled);
        
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
        float attenPow = powr(max(atten, kPowEpsilon), kAttenPower);
        half bri = half(max(dot(spot, nor), 0.0) / attenPow * 0.25);
        half briSun = half(max(dot(sunDir, nor), 0.0) * 0.2);
        
        col = Colour(p, adjustedDist, gTime, 1.0, uniforms.minDistance, uniforms.fractalScale, uniforms.colorMix, uniforms.foldingLimit, uniforms.sphereRadius, max(int(uniforms.colorIterations), 2));
        col = (col * bri * shaSpot) + (col * briSun * shaSun);
        
        // Specular
        float3 ref = reflect(rd, nor);
        float specSpot = powr(max(max(dot(spot, ref), 0.0), kPowEpsilon), kSpecularPower) * kSpecularIntensity;
        float specSun = powr(max(max(dot(sunDir, ref), 0.0), kPowEpsilon), kSpecularPower) * kSpecularIntensity;
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
    
    col = PostEffects(col, half2(in.texCoord), half(uniforms.limitFlash));
    
    output.color = float4(float3(col), 1.0);
    
    // Composite volumetric fur hands with alpha blending (world space)
    if (furResult.hit && furResult.alpha > 0.01 && furResult.t < adjustedDist) {
        float3 furHitPos = worldCameraPos + furResult.t * worldRd;
        float4 furClipPos = uniforms.projectionMatrix * uniforms.viewMatrix * float4(furHitPos, 1.0);
        float furDepth = furClipPos.z / furClipPos.w;
        
        float3 lightDir = normalize(float3(0.5, 0.8, 0.3));
        float3 lightColor = float3(1.0, 0.95, 0.9);
        half3 furColor = shadeFurHands(furResult, worldRd, lightDir, lightColor);
        
        // Alpha blend fur over fractal
        float alpha = furResult.alpha;
        float3 blendedColor = float3(furColor) * alpha + output.color.rgb * (1.0 - alpha);
        output.color = float4(blendedColor, 1.0);
        
        // Use fur depth if mostly opaque
        if (alpha > 0.5) {
            output.depth = furDepth;
        }
    }
    
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
