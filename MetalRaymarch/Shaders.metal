//
//  Shaders.metal
//
// === DEPTH BUFFER NOTES (CRITICAL FOR REPROJECTION/ASW) ===
// visionOS projection outputs z/w in [0, 1] range directly.
// Depth encoding: output.depth = clipPos.z / clipPos.w (no transformation needed)
// Far plane (no hit): output.depth = 1e-7 (tiny value = far away for compositor)
// clearDepth in render passes: 1.0
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

// === FUNCTION CONSTANTS ===
// These allow the Metal compiler to specialize shaders at pipeline creation time,
// eliminating branches and enabling dead code elimination for significant performance gains.
// The compiler can fully unroll loops with known bounds and remove unused code paths.
//
// Use is_function_constant_defined(FC_*) to check if a constant was provided at pipeline creation.

// Fractal iteration counts - controls loop unrolling in hot Map() function
constant int FC_FRACTAL_ITERATIONS [[function_constant(0)]];

// Shadow iteration counts (typically fractalIterations - 2)
constant int FC_SHADOW_ITERATIONS [[function_constant(1)]];

// Feature toggles - allows compiler to eliminate entire code paths
constant bool FC_SAFETY_BUBBLE_ENABLED [[function_constant(2)]];

constant bool FC_SHOW_HUD [[function_constant(3)]];

// Quality mode - enables aggressive optimizations for lower quality settings
constant int FC_QUALITY_MODE [[function_constant(4)]]; // 0=high, 1=medium, 2=low

// Debug mode - can be compiled out entirely in release builds
constant bool FC_DEBUG_HIERARCHICAL [[function_constant(5)]];

// Max ray marching steps - controls main raymarch loop unrolling
// This is the second most critical loop after Map()
constant int FC_MAX_RAY_STEPS [[function_constant(6)]];

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
constant float kPowEpsilon = 1e-6f;
constant half kPowEpsilonHalf = 1e-4h;

// === NAMED CONSTANTS FOR OPTIMIZATION ===
// Raymarching thresholds
constant float kRayMissThreshold = 900.0f;      // Distance indicating ray miss
constant float kMaxRayDistance = 12.0f;         // Standard max trace distance

// Shading constants
constant float kSpecularPower = 10.0f;          // Specular highlight power
constant float kSpecularIntensity = 2.0f;       // Specular intensity multiplier
constant float kAttenPower = 1.5f;              // Light attenuation power

// Quality thresholds
constant float kMinQualityForShadows = 0.25f;   // Skip shadows below this quality
constant float kMinQualityForNormals = 0.2f;    // Use cheap normals below this
constant float kMinQualityForSpecular = 0.7f;   // Skip specular below this
constant float kMinQualityForPostFX = 0.5f;     // Use simple gamma below this

// === ADAPTIVE HIERARCHICAL CONSTANTS ===
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

// visionOS projection outputs z/w in [0, 1] range directly.
// No transformation needed - just pass through for async timewarp/reprojection.
inline float encodeDepthFromClip(float4 clipPos) {
    return clipPos.z / clipPos.w;
}

// Interleaved Gradient Noise - temporally stable dithering for reprojection
// FORCE_INLINE: Called every pixel in raymarching
FORCE_INLINE float interleavedGradientNoise(float2 uv, float time) {
    float3 magic = float3(0.06711056, 0.00583715, 52.9829189);
    float noise = fract(magic.z * fract(dot(uv, magic.xy)));
    // Add small temporal variation to prevent static patterns
    return fract(fma(time, 0.1, noise));
}

struct FractalParams {
    float4 scale;
    float absScalem1;
    float absScalePow;
    float sphereRadiusSq;   // Squared sphere radius for sphere fold
    float minDistanceVal;
    float3 bubbleCenter;
    float bubbleRadius;
    int bubbleEnabled;
    float bubbleShape;      // 0 = sphere, 1 = cube, intermediate = morph
};

// === SAFETY BUBBLE DISTANCE FUNCTION ===
// Computes distance to safety bubble, morphing between sphere and axis-aligned cube
// Cube does NOT rotate with view - only translates (provides stable reference frame)
FORCE_INLINE float safetyBubbleDistance(float3 pos, float3 bubbleCenter, float bubbleRadius, float bubbleShape) {
    float3 p = pos - bubbleCenter;
    
    // Sphere distance (signed, negative inside)
    float sphereDist = length(p) - bubbleRadius;
    
    // Axis-aligned cube distance (Chebyshev distance - max of absolute components)
    // No rotation - cube stays aligned with world axes for stable visual reference
    float3 d = abs(p) - float3(bubbleRadius);
    float cubeDist = length(max(d, 0.0)) + min(max(d.x, max(d.y, d.z)), 0.0);
    
    // Smooth morph between sphere and cube based on bubbleShape parameter
    return mix(sphereDist, cubeDist, bubbleShape);
}

// OPTIMIZED: Use precomputed values from CPU to avoid per-pixel powr() and division
// This version is preferred when PrecomputedFractalParams is available in uniforms
FORCE_INLINE FractalParams makeFractalParamsFromPrecomputed(
    PrecomputedFractalParams precomputed,
    float minRad2Val,
    float3 bubbleCenter, float bubbleRadius, int bubbleEnabled, float bubbleShape)
{
    FractalParams params;
    // Use precomputed values (expensive powr() and divisions done on CPU)
    params.scale = precomputed.scale;
    params.absScalem1 = precomputed.absScalem1;
    params.absScalePow = precomputed.absScalePow;
    params.sphereRadiusSq = precomputed.sphereRadiusSq;
    params.minDistanceVal = minRad2Val;
    params.bubbleCenter = bubbleCenter;
    params.bubbleRadius = bubbleRadius;
    params.bubbleEnabled = bubbleEnabled;
    params.bubbleShape = bubbleShape;
    return params;
}

// Optimized branchless Map function - THE HOTTEST PATH IN THE ENTIRE SHADER
// Called potentially 50-100+ times per pixel (raymarch + shadows + normals)
// Every cycle here matters!
// 
// FUNCTION CONSTANT VERSION: When FC_FRACTAL_ITERATIONS is defined, the compiler
// can fully unroll the loop and optimize aggressively.
FORCE_INLINE float Map(float3 pos, FractalParams params, float foldingLimit, int iterations) 
{
    float4 p = float4(pos, 1.0);
    float4 p0 = p;
    
    float invSphereRadiusSq = 1.0f / params.sphereRadiusSq;

    const int loopCount = is_function_constant_defined(FC_FRACTAL_ITERATIONS) ? FC_FRACTAL_ITERATIONS : iterations;

    if (is_function_constant_defined(FC_FRACTAL_ITERATIONS)) {
        UNROLL_FULL
        for (int i = 0; i < loopCount; i++)
        {
            p.xyz = fma(clamp(p.xyz, -foldingLimit, foldingLimit), float3(2.0), -p.xyz);
            float r2 = dot(p.xyz, p.xyz);
            float t = clamp(1.0f / max(r2, params.sphereRadiusSq), 1.0f, invSphereRadiusSq);
            p *= t;
            p = fma(p, params.scale, p0);
        }
    } else {
        UNROLL_8
        for (int i = 0; i < loopCount; i++)
        {
            p.xyz = fma(clamp(p.xyz, -foldingLimit, foldingLimit), float3(2.0), -p.xyz);
            float r2 = dot(p.xyz, p.xyz);
            float t = clamp(1.0f / max(r2, params.sphereRadiusSq), 1.0f, invSphereRadiusSq);
            p *= t;
            p = fma(p, params.scale, p0);
        }
    }
    
    // Final distance estimate
    float d = (length(p.xyz) - params.absScalem1) / p.w - params.absScalePow;
    
    // Safety bubble: carve out a shape around the camera to prevent clipping
    // When is_function_constant_defined is false, this branch is evaluated at runtime
    // When true, the compiler eliminates the branch entirely
    const bool bubbleEnabled = is_function_constant_defined(FC_SAFETY_BUBBLE_ENABLED) ? FC_SAFETY_BUBBLE_ENABLED : (params.bubbleEnabled != 0);
    if (bubbleEnabled) {
        float bubbleDist = safetyBubbleDistance(pos, params.bubbleCenter, params.bubbleRadius, params.bubbleShape);
        d = max(d, -bubbleDist);
    }
    return d;
}

// =============================================================================
// COLOR SCHEME FUNCTIONS (must be before color functions that use them)
// =============================================================================

// Neon orbit trap coloring - uses scheme palette colors for distinct looks
// trapMin: distance to orbit trap (0 = close, 1 = far)
// trapIter: normalized iteration depth
// trapAngle: angle-based variation
FORCE_INLINE half3 applyNeonColorScheme(half trapMin, half trapIter, half trapAngle, ColorSchemeParams scheme)
{
    half d = saturate(trapMin);
    half it = saturate(trapIter);
    
    // Get scheme palette colors - these define the neon look
    half3 col1 = half3(scheme.color1);  // Primary neon color
    half3 col2 = half3(scheme.color2);  // Secondary neon color  
    half3 col3 = half3(scheme.color3);  // Tertiary neon color
    
    // Brightness: sharp glow falloff from trap surface
    half glow = pow(1.0h - d, half(scheme.glowSharpness));
    
    // Color mixing based on iteration depth (creates radial color zones)
    // Low hueFrequency = smooth gradients, high = more color variation
    half colorPhase = it * half(scheme.hueFrequency) * 0.5h;
    colorPhase = fract(colorPhase + half(scheme.hueOffset));
    
    // Blend between the 3 palette colors based on depth
    half3 baseColor;
    if (colorPhase < 0.33h) {
        baseColor = mix(col1, col2, colorPhase * 3.0h);
    } else if (colorPhase < 0.66h) {
        baseColor = mix(col2, col3, (colorPhase - 0.33h) * 3.0h);
    } else {
        baseColor = mix(col3, col1, (colorPhase - 0.66h) * 3.0h);
    }
    
    // Optional soft banding (controlled by bandFrequency, 0 = no bands)
    half bandEffect = 1.0h;
    if (scheme.bandFrequency > 0.1h) {
        half band = sin(d * half(scheme.bandFrequency) * 3.14159h);
        bandEffect = 0.8h + 0.2h * band * band;
    }
    
    // Saturation boost for neon effect
    half sat = pow(0.9h, half(scheme.saturationPower));
    
    // Final color: base palette color * glow * banding
    half3 rgb = baseColor * glow * bandEffect;
    
    // Boost saturation by pushing away from gray
    half luma = dot(rgb, half3(0.299h, 0.587h, 0.114h));
    rgb = mix(half3(luma), rgb, 1.0h + sat);
    
    return saturate(rgb);
}

// Mandelbox distance function wrapper (fractalType parameter unused, kept for API compatibility)
FORCE_INLINE float MapMandelbox(float3 pos, FractalParams params, float foldingLimit, int iterations, int fractalType) 
{
    return Map(pos, params, foldingLimit, iterations);
}

// =============================================================================
// ADDITIONAL COLOR SCHEME FUNCTIONS
// =============================================================================

// Apply color scheme to base color values (c.x = log-based, c.y = trap-based)
FORCE_INLINE half3 applyColorScheme(half2 c, float colorMix, ColorSchemeParams scheme)
{
    // Extract colors from scheme
    half3 col1 = half3(scheme.color1);
    half3 col2 = half3(scheme.color2);
    half3 col3 = half3(scheme.color3);
    
    // Primary color from palette blending
    half3 finalColor = mix(mix(col1, col2, c.y), col3, c.x);
    
    // Alternative color using mix factors
    half3 altFactors = half3(scheme.altMixFactors);
    half3 altColor = half3(c.x * altFactors.x, c.y * altFactors.y, altFactors.z + 0.3h * c.y);
    
    return mix(finalColor, altColor, half(colorMix));
}

// =============================================================================
// ORBIT CACHE SYSTEM - Dramatic reduction in redundant Map() calls
// =============================================================================
// 
// PROBLEM: For each pixel, we call Map() excessively:
//   - Raymarch: ~60-100 calls × 8-15 iterations = 480-1500 inner loops
//   - Normals: 4 calls × 8-15 iterations = 32-60 inner loops
//   - Colors: 1 call × 8-15 iterations = 8-15 inner loops  
//   - Shadows: 6+ calls × 6-12 iterations = 36-72 inner loops
//   TOTAL: ~600-1700 inner iteration loops PER PIXEL
//
// SOLUTION: Cache the final orbit state from raymarch and reuse for normals/colors
// This eliminates ~70% of redundant iteration loops by:
//   1. Storing orbit state (p, p0, dr) from final raymarch hit
//   2. Computing normals analytically from cached Jacobian approximation
//   3. Computing colors directly from cached orbit trap values
//
// EXTENDED CACHE: Now also stores fold information to eliminate redundant
// MapWithFoldInfo() calls in emissive pattern calculations.
//
// =============================================================================

// Cached orbit state from Mandelbox iteration
// Stores everything needed to compute normals, colors, AND emissive patterns
// without re-iterating the fractal
struct OrbitCache {
    // === BASIC ORBIT STATE ===
    float4 p;           // Final iterated position (xyz) and derivative scale (w)
    float3 p0;          // Original starting point (for re-seeding if needed)
    float trap;         // Minimum r² encountered (orbit trap for coloring)
    float distance;     // Computed distance estimate
    int iterationsUsed; // How many iterations were actually performed
    bool valid;         // Whether cache contains valid data
    
    // === EXTENDED: Trap iteration tracking for neon coloring ===
    int trapIteration;     // Which iteration had the minimum trap
    float3 trapPosition;   // Position at minimum trap (for angle-based coloring)
    
    // === EXTENDED: Fold info for emissive patterns ===
    int boxFolds;          // Number of box folds applied
    int sphereFolds;       // Number of sphere folds applied (inner/outer)
    float minRadius;       // Minimum radius reached during iteration
    float orbitTrapDist;   // Distance to nearest orbit trap point (axis distance)
};

// Create empty/invalid cache
FORCE_INLINE OrbitCache makeEmptyOrbitCache() {
    OrbitCache cache;
    cache.valid = false;
    cache.trap = 1.0f;
    cache.distance = kRayMissThreshold;
    cache.trapIteration = 0;
    cache.trapPosition = float3(0.0f);
    cache.boxFolds = 0;
    cache.sphereFolds = 0;
    cache.minRadius = 1e10f;
    cache.orbitTrapDist = 1e10f;
    return cache;
}

// Unified colour function - uses cached orbit data when available, otherwise iterates
// Supports all color modes including neon
half3 ColourWithScheme(float3 pos, float sphereR, float gTime, float quality, float minRad2Val, float fractalScale, float colorMix, float foldingLimit, float sphereRadius, int colorIters, ColorSchemeParams scheme, OrbitCache cache = {}) 
{
    float4 p;
    float trap;
    int trapIter;
    float3 trapPos;
    int steps;
    
    if (cache.valid) {
        // Use cached orbit state
        p = cache.p;
        trap = cache.trap;
        trapIter = cache.trapIteration;
        trapPos = cache.trapPosition;
        steps = cache.iterationsUsed;
    } else {
        // Compute orbit state
        float4 scale = float4(fractalScale) / minRad2Val;
        scale.w = abs(scale.w);
        float sphereRadiusSq = sphereRadius * sphereRadius;

        p = float4(pos, 1.0);
        float4 p0 = p;
        trap = 1.0;
        float minTrap = 1.0;
        trapIter = 0;
        trapPos = pos;
        
        steps = max(int(float(colorIters) * quality), 2);
        for (int i = 0; i < steps; i++)
        {
            p.xyz = clamp(p.xyz, -foldingLimit, foldingLimit) * 2.0 - p.xyz;
            float r2 = dot(p.xyz, p.xyz);
            p.xyz *= clamp(1.0 / max(r2, sphereRadiusSq), 1.0, 1.0/sphereRadiusSq);
            p.xyz = p.xyz * scale.xyz + p0.xyz;
            
            // Track orbit trap with iteration and position
            if (r2 < minTrap) {
                minTrap = r2;
                trapIter = i;
                trapPos = p.xyz;
            }
            trap = min(trap, r2);
        }
    }
    
    // Check if neon mode is active
    if (scheme.neonIntensity > 0.01f) {
        // Compute neon orbit trap metrics
        half trapMin = half(sqrt(trap));
        half trapIterNorm = half(float(trapIter) / float(steps));
        half trapAngle = half(atan2(trapPos.y, trapPos.x) * 0.15915494f + 0.5f); // Normalized to 0-1
        
        half3 neonColor = applyNeonColorScheme(trapMin, trapIterNorm, trapAngle, scheme);
        
        // If neonIntensity < 1, blend with standard coloring
        if (scheme.neonIntensity < 0.99f) {
            half2 c = saturate(half2(0.3333h * log(half(dot(p.xyz,p.xyz))) - 1.0h, sqrt(half(trap))));
            half3 standardColor = applyColorScheme(c, colorMix, scheme);
            return mix(standardColor, neonColor, half(scheme.neonIntensity));
        }
        return neonColor;
    }
    
    half2 c = saturate(half2(0.3333h * log(half(dot(p.xyz,p.xyz))) - 1.0h, sqrt(half(trap))));
    return applyColorScheme(c, colorMix, scheme);
}

// Map function that outputs orbit cache for reuse
// This is the KEY optimization - we iterate once and cache everything needed
// Now also tracks fold info and trap iteration for coloring/emissive patterns
FORCE_INLINE float MapWithOrbitCache(float3 pos, FractalParams params, float foldingLimit, int iterations, thread OrbitCache& cache)
{
    float4 p = float4(pos, 1.0);
    float4 p0 = p;
    
    float invSphereRadiusSq = 1.0f / params.sphereRadiusSq;
    float trap = 1.0f;
    
    // Extended tracking
    int trapIter = 0;
    float3 trapPos = pos;
    int boxFolds = 0;
    int sphereFolds = 0;
    float minRadius = 1e10f;
    float orbitTrapDist = 1e10f;
    
    const int loopCount = is_function_constant_defined(FC_FRACTAL_ITERATIONS) ? FC_FRACTAL_ITERATIONS : iterations;
    
    if (is_function_constant_defined(FC_FRACTAL_ITERATIONS)) {
        UNROLL_FULL
        for (int i = 0; i < loopCount; i++) {
            // Box fold - track if folding occurred
            float3 pOld = p.xyz;
            p.xyz = fma(clamp(p.xyz, -foldingLimit, foldingLimit), float3(2.0), -p.xyz);
            if (any(p.xyz != pOld)) boxFolds++;
            
            float r2 = dot(p.xyz, p.xyz);
            float r = sqrt(r2);
            minRadius = min(minRadius, r);
            
            // Orbit trap - distance to nearest axis
            float axisTrap = min(min(abs(p.x), abs(p.y)), abs(p.z));
            orbitTrapDist = min(orbitTrapDist, axisTrap);
            
            // Track iteration with minimum trap
            if (r2 < trap) {
                trap = r2;
                trapIter = i;
                trapPos = p.xyz;
            }
            
            // Sphere fold
            float t = clamp(1.0f / max(r2, params.sphereRadiusSq), 1.0f, invSphereRadiusSq);
            if (t > 1.0f) sphereFolds++;  // Sphere fold occurred
            p *= t;
            p = fma(p, params.scale, p0);
        }
    } else {
        UNROLL_8
        for (int i = 0; i < loopCount; i++) {
            // Box fold - track if folding occurred
            float3 pOld = p.xyz;
            p.xyz = fma(clamp(p.xyz, -foldingLimit, foldingLimit), float3(2.0), -p.xyz);
            if (any(p.xyz != pOld)) boxFolds++;
            
            float r2 = dot(p.xyz, p.xyz);
            float r = sqrt(r2);
            minRadius = min(minRadius, r);
            
            // Orbit trap - distance to nearest axis
            float axisTrap = min(min(abs(p.x), abs(p.y)), abs(p.z));
            orbitTrapDist = min(orbitTrapDist, axisTrap);
            
            // Track iteration with minimum trap
            if (r2 < trap) {
                trap = r2;
                trapIter = i;
                trapPos = p.xyz;
            }
            
            // Sphere fold
            float t = clamp(1.0f / max(r2, params.sphereRadiusSq), 1.0f, invSphereRadiusSq);
            if (t > 1.0f) sphereFolds++;  // Sphere fold occurred
            p *= t;
            p = fma(p, params.scale, p0);
        }
    }
    
    float d = (length(p.xyz) - params.absScalem1) / p.w - params.absScalePow;
    
    // Safety bubble
    const bool bubbleEnabled = is_function_constant_defined(FC_SAFETY_BUBBLE_ENABLED) ? FC_SAFETY_BUBBLE_ENABLED : (params.bubbleEnabled != 0);
    if (bubbleEnabled) {
        float bubbleDist = safetyBubbleDistance(pos, params.bubbleCenter, params.bubbleRadius, params.bubbleShape);
        d = max(d, -bubbleDist);
    }
    
    // Store full orbit state in cache for reuse
    cache.p = p;
    cache.p0 = pos;
    cache.trap = trap;
    cache.distance = d;
    cache.iterationsUsed = loopCount;
    cache.valid = true;
    
    // Extended fields
    cache.trapIteration = trapIter;
    cache.trapPosition = trapPos;
    cache.boxFolds = boxFolds;
    cache.sphereFolds = sphereFolds;
    cache.minRadius = minRadius;
    cache.orbitTrapDist = orbitTrapDist;
    
    return d;
}

// Compute normal using cached orbit state + small perturbations
// Unified normal calculation - uses cached center distance when available
// For Mandelbox with valid cache: uses cache.distance + reduced iterations
// Otherwise: standard forward differences with full iterations
FORCE_INLINE float3 GetNormal(float3 pos, float distance, FractalParams params, float foldingLimit, int iterations, int fractalType, OrbitCache cache = {})
{
    if (cache.valid && fractalType == 0) {
        // Optimized path: use cached center distance, reduced iterations
        int normalIters = max((iterations * 2) / 5, 3);
        float e = max(distance * 0.0005f, 0.0001f);
        float d0 = cache.distance;
        
        OrbitCache dummy;
        float dx = MapWithOrbitCache(pos + float3(e, 0, 0), params, foldingLimit, normalIters, dummy);
        float dy = MapWithOrbitCache(pos + float3(0, e, 0), params, foldingLimit, normalIters, dummy);
        float dz = MapWithOrbitCache(pos + float3(0, 0, e), params, foldingLimit, normalIters, dummy);
        
        float3 gradient = float3(dx - d0, dy - d0, dz - d0);
        return gradient * rsqrt(dot(gradient, gradient) + kPowEpsilon);
    } else {
        // Standard path: 4 Map calls with full iterations
        float e = distance * 0.001;
        float d = MapMandelbox(pos, params, foldingLimit, iterations, fractalType);
        float3 gradient = float3(
            MapMandelbox(pos + float3(e,0,0), params, foldingLimit, iterations, fractalType) - d,
            MapMandelbox(pos + float3(0,e,0), params, foldingLimit, iterations, fractalType) - d,
            MapMandelbox(pos + float3(0,0,e), params, foldingLimit, iterations, fractalType) - d
        );
        return gradient * rsqrt(dot(gradient, gradient) + kPowEpsilon);
    }
}

// Far-range coarse raymarch (12 steps, max 80 units) - REMOVED (unused)
// Near-range coarse raymarch (24 steps, max 12 units)
FORCE_INLINE float SceneCoarse(float3 rO, float3 rD, float foldingLimit, FractalParams params, int iterations)
{
    float t = 0.05;
    
    UNROLL_8
    for(int j = 0; j < 24; j++)
    {
        float3 p = fma(rD, float3(t), rO);
        float h = Map(p, params, foldingLimit, iterations);
        
        if(UNLIKELY(h < 0.02)) return t;
        if (UNLIKELY(t > kMaxRayDistance)) return kRayMissThreshold + 100.0;
        
        t += h;
    }
    
    return kRayMissThreshold + 100.0;
}

// Cached scene result - stores orbit state for reuse in normals/colors
struct SceneResult {
    float2 distGlow;    // .x = distance, .y = glow
    OrbitCache cache;   // Cached orbit state from final hit position
};

// Raymarch that caches orbit state on hit for reuse in normals/colors
FORCE_INLINE SceneResult SceneWithCache(float3 rO, float3 rD, float2 fragCoord, float quality, int maxStepsParam, float glowIntensity, float foldingLimit, FractalParams params, int iterations, float time, int fractalType = 0)
{
    SceneResult result;
    result.cache = makeEmptyOrbitCache();
    
    float dither = interleavedGradientNoise(fragCoord, time) * 0.015;
    float t = 0.05 + dither;
    
    float glow = 0.0;
    
    const int baseMaxSteps = is_function_constant_defined(FC_MAX_RAY_STEPS) ? FC_MAX_RAY_STEPS : maxStepsParam;
    int maxSteps = max(int(float(baseMaxSteps) * quality), 4);
    
    NO_UNROLL
    for(int j = 0; j < maxSteps; j++)
    {
        float threshold = fma(t, 0.0008, 0.0005) + (1.0 - quality) * 0.003;
        
        float3 p = fma(rD, float3(t), rO);
        float h = MapMandelbox(p, params, foldingLimit, iterations, fractalType);
        
        if(UNLIKELY(h < threshold))
        {
            OrbitCache hitCache;
            MapWithOrbitCache(p, params, foldingLimit, iterations, hitCache);
            result.cache = hitCache;
            result.distGlow = float2(t, saturate(glow * 0.25));
            return result;
        }
        
        if (UNLIKELY(t > kMaxRayDistance)) break;
        
        glow = fma(saturate(0.04 - h), glowIntensity, glow);
        t += h;
    }
    
    result.distGlow = float2(kRayMissThreshold + 100.0, saturate(glow * 0.25));
    return result;
}

// Raymarch with cache that starts from a known distance (for hierarchical acceleration)
FORCE_INLINE SceneResult SceneWithCacheFromStart(float3 rO, float3 rD, float startT, float2 fragCoord, float quality, int maxStepsParam, float glowIntensity, float foldingLimit, FractalParams params, int iterations, float time, int fractalType = 0)
{
    SceneResult result;
    result.cache = makeEmptyOrbitCache();
    
    float dither = interleavedGradientNoise(fragCoord, time) * 0.01;
    float t = max(0.01, startT - 0.3) + dither;
    
    float glow = 0.0;
    const int baseMaxSteps = is_function_constant_defined(FC_MAX_RAY_STEPS) ? FC_MAX_RAY_STEPS : maxStepsParam;
    int maxSteps = max(int(float(baseMaxSteps) * quality * 0.5), 8);
    float endT = startT + 2.0;
    
    NO_UNROLL
    for(int j = 0; j < maxSteps; j++)
    {
        float threshold = fma(t, 0.0006, 0.0005);
        float3 p = fma(rD, float3(t), rO);
        float h = MapMandelbox(p, params, foldingLimit, iterations, fractalType);
        
        if(UNLIKELY(h < threshold))
        {
            OrbitCache hitCache;
            MapWithOrbitCache(p, params, foldingLimit, iterations, hitCache);
            result.cache = hitCache;
            result.distGlow = float2(t, saturate(glow * 0.25));
            return result;
        }
        
        if (UNLIKELY(t > endT)) break;
        
        glow = fma(saturate(0.04 - h), glowIntensity, glow);
        t += h;
    }
    
    result.distGlow = float2(kRayMissThreshold + 100.0, saturate(glow * 0.25));
    return result;
}

// =============================================================================

// Post effects with color scheme support and dynamic animation
half3 PostEffectsWithScheme(half3 rgb, half2 xy, ColorSchemeParams scheme, half limitFlash = 0.0h, half rayGlow = 0.0h)
{
    // === DYNAMIC HUE CYCLING ===
    // Rotate hue over time for animated color shifts
    // Use full precision for time calculation to avoid quantization artifacts
    if (scheme.hueCycleSpeed > 0.001f) {
        // Keep angle calculation in float precision, wrap to [0, 2π] to prevent precision loss
        float rawAngle = scheme.animTime * scheme.hueCycleSpeed * 6.28318f;
        float wrappedAngle = fmod(rawAngle, 6.28318f);  // Wrap to avoid large values
        half hueAngle = half(wrappedAngle);
        half cosH = cos(hueAngle);
        half sinH = sin(hueAngle);
        // Simplified hue rotation (YIQ-like transform)
        half3 yiq;
        yiq.x = dot(rgb, half3(0.299h, 0.587h, 0.114h));  // Luma (Y)
        yiq.y = dot(rgb, half3(0.596h, -0.274h, -0.322h)); // I
        yiq.z = dot(rgb, half3(0.211h, -0.523h, 0.312h));  // Q
        // Rotate I and Q
        half newY = yiq.y * cosH - yiq.z * sinH;
        half newZ = yiq.y * sinH + yiq.z * cosH;
        // Convert back to RGB
        rgb.r = yiq.x + 0.956h * newY + 0.621h * newZ;
        rgb.g = yiq.x - 0.272h * newY - 0.647h * newZ;
        rgb.b = yiq.x - 1.106h * newY + 1.703h * newZ;
        rgb = saturate(rgb);
    }
    
    // === PULSE ANIMATION ===
    // Add breathing/pulsing effect to saturation
    half pulse = 1.0h;
    if (scheme.pulseSpeed > 0.001f && scheme.pulseAmount > 0.001f) {
        // Use float precision for time calculation, wrap to avoid precision loss
        float rawPulseAngle = scheme.animTime * scheme.pulseSpeed * 6.28318f;
        float wrappedPulseAngle = fmod(rawPulseAngle, 6.28318f);
        half pulseWave = 0.5h + 0.5h * sin(half(wrappedPulseAngle));
        pulse = 1.0h + half(scheme.pulseAmount) * (pulseWave - 0.5h);
    }
    
    // Saturation adjustment from scheme (with pulse)
    half luma = dot(rgb, half3(0.2126h, 0.7152h, 0.0722h));
    half satMult = half(scheme.saturation) * pulse;
    rgb = mix(half3(luma), rgb, satMult);
    
    // Brightness and contrast from scheme
    rgb += half(scheme.brightness);
    rgb = mix(half3(0.5h), rgb, half(scheme.contrast));
    
    // === RAY-STEP GLOW (cheap bloom approximation) ===
    // Points near the fractal (high ray steps) get a soft glow
    if (rayGlow > 0.01h && scheme.glowIntensity > 0.001f) {
        half glowAmount = rayGlow * half(scheme.glowIntensity);
        // Additive glow based on the brightest channel
        half3 glowColor = rgb * (1.0h + glowAmount * 2.0h);
        rgb = mix(rgb, glowColor, glowAmount * 0.5h);
    }
    
    // === BLOOM EFFECT (cheap screen-space approximation) ===
    if (scheme.bloomStrength > 0.001f) {
        // Bright areas bloom more - threshold based
        half brightness = dot(rgb, half3(0.299h, 0.587h, 0.114h));
        half bloomThreshold = 0.7h;
        half bloomAmount = max(0.0h, brightness - bloomThreshold) * half(scheme.bloomStrength);
        // Desaturate and brighten for bloom
        rgb += bloomAmount * half3(0.3h, 0.3h, 0.35h);
    }
    
    // === COLOR GRADING: HIGHLIGHTS (Exposure-like) ===
    // Apply before other grading - affects overall brightness
    if (abs(scheme.highlights) > 0.001f) {
        rgb *= half(1.0f + scheme.highlights);
    }
    
    // === COLOR GRADING: VIBRANCE (Smart Saturation) ===
    // Vibrance applies more saturation to less saturated colors
    if (scheme.vibrance > 0.001f) {
        half maxChannel = max(rgb.r, max(rgb.g, rgb.b));
        half vibranceBoost = (1.0h - maxChannel) * half(scheme.vibrance);
        half luma2 = dot(rgb, half3(0.299h, 0.587h, 0.114h));
        rgb = mix(half3(luma2), rgb, 1.0h + vibranceBoost);
    }
    
    // === COLOR GRADING: SHADOWS (Lift/Crush) ===
    // Positive values lift shadows, negative values crush them
    if (abs(scheme.shadows) > 0.001f) {
        rgb = rgb + half(scheme.shadows) * (1.0h - rgb);
    }
    
    // === COLOR GRADING: MIDTONE CURVE (S-Curve) ===
    // colorCurve > 0 increases midtone contrast, < 0 flattens it
    if (abs(scheme.colorCurve) > 0.001f) {
        half curve = half(scheme.colorCurve);
        half exponent = 1.0h / (1.0h + curve * 0.7h);
        half mid = 0.5h;
        half3 delta = rgb - mid;
        rgb = mid + sign(delta) * 0.5h * powr(abs(delta) * 2.0h, half3(exponent));
    }
    
    // Simplified vignette
    half2 q = xy * (1.0h - xy);
    half vignetteBase = max(16.0h * q.x * q.y, kPowEpsilonHalf);
    rgb *= 0.5h + 0.5h * powr(vignetteBase, 0.2h);
    
    // Limit flash effect - bright edge glow when parameter hits min/max
    if (limitFlash > 0.01h) {
        half2 edgeDist = abs(xy - 0.5h) * 2.0h;
        half edge = max(edgeDist.x, edgeDist.y);
        half edgeGlow = powr(edge, 2.0h) * limitFlash;
        half3 flashColor = half3(1.0h, 0.4h, 0.1h);
        rgb = mix(rgb, flashColor, edgeGlow * 0.8h);
    }
    
    // Clamp before gamma to avoid NaN from negative values
    rgb = saturate(rgb);
    
    // Gamma from scheme
    return powr(max(rgb, half3(kPowEpsilonHalf)), half3(scheme.gamma));
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

// Render HUD overlay showing current parameter values (Mandelbox only)
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

// Soft shadow with over-relaxation
FORCE_INLINE float Shadow(float3 ro, float3 rd, float quality, float foldingLimit, FractalParams params, int iterations, int fractalType = 0)
{
    const int qualityMode = is_function_constant_defined(FC_QUALITY_MODE) ? FC_QUALITY_MODE : 0;
    if (qualityMode >= 2) return 0.65;
    if (UNLIKELY(quality < kMinQualityForShadows)) return 0.65;
    
    float res = 1.0;
    float t = 0.08;
    float prevH = 1e10;
    
    const int steps = is_function_constant_defined(FC_SHADOW_ITERATIONS) ? 
        (qualityMode == 1 ? 2 : 3) : 
        int(fma(quality, 2.0, 1.0));
    
    UNROLL_4
    for (int i = 0; i < steps; i++)
    {
        float h = MapMandelbox(fma(rd, float3(t), ro), params, foldingLimit, iterations, fractalType);
        
        res = min(res, 10.0 * h / t);
        
        if (UNLIKELY(res < 0.02)) return 0.0;
        
        float relax = step(prevH * 0.8, h);
        float stepDist = mix(h, h * 1.5, relax);
        t += max(stepDist, 0.15);
        prevH = h;
        
        if (UNLIKELY(t > 4.0)) break;
    }
    
    return saturate(res);
}

// === TILE-BASED RAYMARCHING (4x4 pixel groups) ===
// One DE raymarch per tile, per-pixel normals for smooth shading
// Reduces DE overhead by ~16x while maintaining surface detail

#define TILE_SIZE 4

// =============================================================================
// EMISSIVE GLOW CALCULATION
// Computes self-illumination based on cached fold state and patterns
// Requires valid OrbitCache from raymarching hit
// =============================================================================

// Compute emissive glow - REQUIRES valid cache (always valid on hit)
FORCE_INLINE half3 computeEmissive(
    float3 pos,
    float3 normal,
    float gTime,
    int pattern,
    float intensity,
    float threshold,
    float3 emissiveColor,
    float speed,
    int iterations,
    float foldingLimit,
    OrbitCache cache
) {
    if (intensity <= 0.0 || !cache.valid) return half3(0.0h);
    
    // Use cached fold info from raymarching
    int boxFolds = cache.boxFolds;
    int sphereFolds = cache.sphereFolds;
    float minRadius = cache.minRadius;
    float orbitTrapDist = cache.orbitTrapDist;
    
    float emission = 0.0;
    
    if (pattern == 0) {
        // FOLDS: Glow based on fold count
        float foldRatio = float(boxFolds + sphereFolds) / float(iterations * 2);
        emission = smoothstep(threshold, 1.0, foldRatio);
    }
    else if (pattern == 1) {
        // DEPTH: Glow based on iteration depth (deep = glowy)
        float depthFactor = 1.0 - saturate(minRadius / (foldingLimit * 2.0));
        emission = smoothstep(threshold, 1.0, depthFactor);
    }
    else if (pattern == 2) {
        // POSITION: Sine-based veins/ridges pattern + orbit trap
        float3 freq = float3(5.0, 7.0, 6.0);
        float veins = sin(pos.x * freq.x) * sin(pos.y * freq.y) * sin(pos.z * freq.z);
        veins = veins * 0.5 + 0.5;
        float trap = 1.0 - saturate(orbitTrapDist * 2.0);
        emission = smoothstep(threshold, 1.0, veins * 0.5 + trap * 0.5);
    }
    else if (pattern == 3) {
        // PULSE: Fold-aware animated glow
        float cellId = float(boxFolds * 3 + sphereFolds * 7) + floor(orbitTrapDist * 4.0);
        float phase = cellId * 0.7;
        float pulse = sin(gTime * speed * 3.0 + phase);
        pulse = pulse * 0.5 + 0.5;
        float depthBoost = 1.0 - saturate(minRadius / (foldingLimit * 1.5));
        float cellMask = step(threshold, fract(cellId * 0.1234));
        emission = pulse * depthBoost * cellMask;
    }
    else if (pattern == 4) {
        // EDGES: Glow at sharp edges
        float3 tangent = normalize(cross(normal, float3(0, 1, 0) + float3(0.001)));
        float3 bitangent = cross(normal, tangent);
        float curvature = 1.0 - abs(dot(normal, normalize(normal + tangent * 0.1)));
        curvature += 1.0 - abs(dot(normal, normalize(normal + bitangent * 0.1)));
        float foldEdge = float(boxFolds) / float(iterations);
        emission = smoothstep(threshold, 1.0, curvature * 0.5 + foldEdge * 0.5);
    }
    
    return half3(emissiveColor) * half(emission * intensity);
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
    int maxSteps = uniforms.maxRaySteps;
    int fractalType = uniforms.fractalType;

    float3 marchOrigin = cameraPos;
    float3 marchDir = rd;

    // Use precomputed fractal params (powr() and divisions done on CPU)
    FractalParams fractalParams = makeFractalParamsFromPrecomputed(
        uniforms.precomputedFractal,
        uniforms.minDistance,
        marchOrigin, uniforms.safetyBubbleRadius, uniforms.safetyBubbleEnabled, uniforms.safetyBubbleShape);

    float gTime = uniforms.time * 0.01 + 15.00;
    
    threadgroup float tileStartT;

    if (localIndex == 0) {
        if (fractalType == 0) {
            int coarseIterations = max(lodIterations / 2, 2);
            // Coarse params with reduced iterations - still use precomputed base values
            FractalParams coarseParams = makeFractalParamsFromPrecomputed(
                uniforms.precomputedFractal,
                uniforms.minDistance,
                marchOrigin, uniforms.safetyBubbleRadius, uniforms.safetyBubbleEnabled, uniforms.safetyBubbleShape);
            float coarseT = SceneCoarse(marchOrigin, marchDir, uniforms.foldingLimit, coarseParams, coarseIterations);
            tileStartT = coarseT < kRayMissThreshold ? coarseT : 0.05;
        } else {
            tileStartT = 0.05;
        }
    }

    threadgroup_barrier(mem_flags::mem_threadgroup);

    SceneResult sceneResult;
    if (fractalType == 0) {
        sceneResult = SceneWithCacheFromStart(marchOrigin, marchDir, tileStartT, pixelCenter, 1.0, maxSteps,
                                              uniforms.glowIntensity, uniforms.foldingLimit, fractalParams, lodIterations, uniforms.time, fractalType);
    } else {
        sceneResult = SceneWithCache(marchOrigin, marchDir, pixelCenter, 1.0, maxSteps,
                                     uniforms.glowIntensity, uniforms.foldingLimit, fractalParams, lodIterations, uniforms.time, fractalType);
    }
    
    float adjustedDist = sceneResult.distGlow.x;
    float glow = sceneResult.distGlow.y;
    OrbitCache hitCache = sceneResult.cache;
    half3 col = half3(0.0h);
    
    if (sceneResult.distGlow.x < kRayMissThreshold) {
        float3 p = marchOrigin + adjustedDist * marchDir;
        
        float3 nor = GetNormal(p, adjustedDist, fractalParams, uniforms.foldingLimit, lodIterations, fractalType, hitCache);
        
        // Use precomputed lighting from CPU
        float3 spotLight = uniforms.precomputedLighting.spotLightPosition;
        float lightIntensity = uniforms.precomputedLighting.lightIntensity;
        float3 spot = spotLight - p;
        float atten = length(spot);
        spot /= atten;
        
        int shadowIterations = max(lodIterations - 2, 2);
        FractalParams shadowParams = makeFractalParamsFromPrecomputed(
            uniforms.precomputedFractal,
            uniforms.minDistance,
            marchOrigin, uniforms.safetyBubbleRadius, uniforms.safetyBubbleEnabled, uniforms.safetyBubbleShape);
        
        half shaSpot = half(Shadow(p, spot, 0.8, uniforms.foldingLimit, shadowParams, shadowIterations, fractalType));
        half shaSun = half(Shadow(p, sunDir, 0.8, uniforms.foldingLimit, shadowParams, shadowIterations, fractalType));
        
        float attenPow = powr(max(atten, kPowEpsilon), kAttenPower);
        half bri = half(max(dot(spot, nor), 0.0) / attenPow * 0.25 * lightIntensity);
        half briSun = half(max(dot(sunDir, nor), 0.0) * 0.2);
        
        col = ColourWithScheme(p, adjustedDist, gTime, 1.0, uniforms.minDistance, uniforms.fractalScale, 
                    uniforms.colorMix, uniforms.foldingLimit, uniforms.sphereRadius, int(uniforms.colorIterations), uniforms.colorScheme, hitCache);
        col = (col * bri * shaSpot) + (col * briSun * shaSun);
        
        // Specular
        float3 ref = reflect(marchDir, nor);
        float specSpot = powr(max(max(dot(spot, ref), 0.0), kPowEpsilon), kSpecularPower) * kSpecularIntensity * lightIntensity;
        float specSun = powr(max(max(dot(sunDir, ref), 0.0), kPowEpsilon), kSpecularPower) * kSpecularIntensity;
        col += half3(specSpot) * shaSpot * bri;
        col += half3(specSun) * shaSun * briSun;
    }
    
    // Fog (applied regardless of hit, same as fragment shader)
    // fogIntensity: 0 = no fog (fogFactor=1), 1 = full fog
    half fogFactor = half(saturate(exp(-adjustedDist * uniforms.fogIntensity * 2.0 + 1.5)));
    col = mix(half3(0.02h, 0.03h, 0.04h), col, fogFactor);
    
    // Add glow
    half glowH = half(glow);
    col += glowH * glowH * half3(0.02h, 0.04h, 0.1h);
    col = clamp(col, half3(0.0h), half3(2.0h));
    
    // Apply PostEffects with color scheme support
    // (saturation, contrast, vignette, gamma from color scheme)
    // Compute approximate texCoord for vignette (0-1 range)
    half2 texCoord = half2(pixelCenter / uniforms.resolution);
    col = PostEffectsWithScheme(col, texCoord, uniforms.colorScheme, half(uniforms.limitFlash), glowH);
    
    // Debug visualization
    // Use function constant to compile out debug code in release builds
    const bool debugHierarchical = is_function_constant_defined(FC_DEBUG_HIERARCHICAL) ? FC_DEBUG_HIERARCHICAL : (uniforms.debugHierarchical == 1);
    if (debugHierarchical) {
        // Show tile boundaries
        if (localId.x == 0 || localId.y == 0) {
            col = mix(col, half3(1.0h, 1.0h, 0.0h), 0.5h);
        }
    }
    
    outputTexture.write(float4(float3(col), 1.0), pixelCoord, uniforms.eyeIndex);
}

// Shared fragment body for Mandelbox rendering
inline FragmentOutput fragmentMain(ColorInOut in,
                                   Uniforms uniforms,
                                   float2 fragCoord,
                                   float time)
{
    FragmentOutput output;
    
    float gTime = time * 0.01 + 15.00;
    float3 cameraPos = (uniforms.inverseModelViewMatrix * float4(0,0,0,1)).xyz;
    float3 rd = normalize(in.modelPos - cameraPos);
    
    // === Get fractal type and parameters ===
    int fractalType = uniforms.fractalType;
    float quality = 1.0;
    int lodIterations = max(int(uniforms.fractalIterations), 2);
    int maxSteps = uniforms.maxRaySteps;

    float3 marchOrigin = cameraPos;
    float3 marchDir = rd;

    // Use precomputed fractal params (powr() and divisions done on CPU)
    FractalParams fractalParams = makeFractalParamsFromPrecomputed(
        uniforms.precomputedFractal,
        uniforms.minDistance,
        marchOrigin, uniforms.safetyBubbleRadius, uniforms.safetyBubbleEnabled, uniforms.safetyBubbleShape);

    half3 col = half3(0.0h);
    float2 ret;
    OrbitCache hitCache = makeEmptyOrbitCache();
    
    SceneResult sceneResult = SceneWithCache(marchOrigin, marchDir, fragCoord, quality, maxSteps, uniforms.glowIntensity, uniforms.foldingLimit, fractalParams, lodIterations, time, fractalType);
    ret = sceneResult.distGlow;
    hitCache = sceneResult.cache;

    if (ret.x < kRayMissThreshold)
    {
        // Compute hit position and clip-space depth once (used for depth output and debug visualization)
        float3 p = marchOrigin + ret.x * marchDir;
        float4 clipPos = uniforms.projectionMatrix * uniforms.modelViewMatrix * float4(p, 1.0);
        float depth = encodeDepthFromClip(clipPos);
        output.depth = depth;

        // Debug: visualize depth as grayscale (early return)
        if (DEBUG_DEPTH_VISUALIZATION) {
            float depthGray = saturate(depth);
            output.color = float4(depthGray, depthGray, depthGray, 1.0);
            return output;
        }

        float3 nor;
        if (quality > kMinQualityForNormals) {
            nor = GetNormal(p, ret.x, fractalParams, uniforms.foldingLimit, lodIterations, fractalType, hitCache);
        } else {
            nor = normalize(p - marchOrigin);
        }

        if (quality > 0.4) {
            // Use precomputed spotlight position and intensity from CPU
            float3 spotLight = uniforms.precomputedLighting.spotLightPosition;
            float lightIntensity = uniforms.precomputedLighting.lightIntensity;
            float3 spot = spotLight - p;
            float atten = length(spot);
            spot /= atten;

            int shadowIterations = max(lodIterations - 2, 2);
            // Shadow params still need per-pixel bubble center, but use precomputed fractal values
            FractalParams shadowParams = makeFractalParamsFromPrecomputed(
                uniforms.precomputedFractal,
                uniforms.minDistance,
                marchOrigin, uniforms.safetyBubbleRadius, uniforms.safetyBubbleEnabled, uniforms.safetyBubbleShape);

            half shaSpot = half(Shadow(p, spot, quality, uniforms.foldingLimit, shadowParams, shadowIterations, fractalType));
            half shaSun = half(Shadow(p, sunDir, quality, uniforms.foldingLimit, shadowParams, shadowIterations, fractalType));

            float attenPow = powr(max(atten, kPowEpsilon), kAttenPower);
            half bri = half(max(dot(spot, nor), 0.0) / attenPow * 0.25 * lightIntensity);
            half briSun = half(max(dot(sunDir, nor), 0.0) * 0.2);

            col = ColourWithScheme(p, ret.x, gTime, quality, uniforms.minDistance, uniforms.fractalScale, uniforms.colorMix, uniforms.foldingLimit, uniforms.sphereRadius, max(int(uniforms.colorIterations * quality), 2), uniforms.colorScheme, hitCache);
            col = (col * bri * shaSpot) + (col * briSun * shaSun);

            if (quality > kMinQualityForSpecular) {
                float3 ref = reflect(marchDir, nor);
                float specSpot = powr(max(max(dot(spot, ref), 0.0), kPowEpsilon), kSpecularPower) * kSpecularIntensity * lightIntensity;
                float specSun = powr(max(max(dot(sunDir, ref), 0.0), kPowEpsilon), kSpecularPower) * kSpecularIntensity;
                col += half3(specSpot) * shaSpot * bri;
                col += half3(specSun) * shaSun * briSun;
            }
            
            // Emissive glow (self-illumination based on cached fold patterns)
            if (uniforms.emissiveEnabled != 0) {
                half3 emissive = computeEmissive(
                    p,
                    nor,
                    gTime,
                    uniforms.emissivePattern,
                    uniforms.emissiveIntensity,
                    uniforms.emissiveThreshold,
                    uniforms.emissiveColor,
                    uniforms.emissiveSpeed,
                    lodIterations,
                    uniforms.foldingLimit,
                    hitCache
                );
                col += emissive;
            }
        } else {
            half diffuse = half(max(dot(nor, sunDir), 0.0) * 0.5 + 0.3);
            col = ColourWithScheme(p, ret.x, gTime, quality, uniforms.minDistance, uniforms.fractalScale, uniforms.colorMix, uniforms.foldingLimit, uniforms.sphereRadius, max(int(uniforms.colorIterations * quality), 2), uniforms.colorScheme, hitCache) * diffuse;
        }
        // Depth already written at start of this block via clipPos
    }
    else
    {
        // No hit - far plane (tiny depth so compositor treats as far away)
        output.depth = 1e-7;

        if (DEBUG_DEPTH_VISUALIZATION) {
            output.color = float4(0.0, 0.0, 0.0, 1.0);
            return output;
        }
    }

    // fogIntensity: 0 = no fog (fogFactor=1), 1 = full fog
    half fogFactor = half(saturate(exp(-ret.x * uniforms.fogIntensity * 2.0 + 1.5)));
    col = mix(half3(0.02h, 0.03h, 0.04h), col, fogFactor);

    half glow = half(ret.y);
    col += glow * glow * half3(0.02h, 0.04h, 0.1h);

    col = clamp(col, half3(0.0h), half3(2.0h));

    if (quality > kMinQualityForPostFX) {
        col = PostEffectsWithScheme(col, half2(in.texCoord), uniforms.colorScheme, half(uniforms.limitFlash), glow);
    } else {
        col = powr(max(saturate(col), half3(kPowEpsilonHalf)), half3(uniforms.colorScheme.gamma));
    }

    // Render HUD overlay if enabled
    // Use function constant when defined to eliminate this code path entirely
    const bool showHUD = is_function_constant_defined(FC_SHOW_HUD) ? FC_SHOW_HUD : (uniforms.showHUD != 0);
    if (showHUD) {
        col = renderHUD(col, float2(in.texCoord), uniforms.activeGesture,
                        uniforms.minDistance, uniforms.foldingLimit, uniforms.sphereRadius);
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
    
    // Render fractal
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
    
    int fractalType = uniforms.fractalType;
    int lodIterations = max(int(uniforms.fractalIterations), 2);
    int maxSteps = uniforms.maxRaySteps;

    float3 marchOrigin = cameraPos;
    float3 marchDir = rd;

    // Use precomputed fractal params (powr() and divisions done on CPU)
    FractalParams fractalParams = makeFractalParamsFromPrecomputed(
        uniforms.precomputedFractal,
        uniforms.minDistance,
        marchOrigin, uniforms.safetyBubbleRadius, uniforms.safetyBubbleEnabled, uniforms.safetyBubbleShape);

    SceneResult sceneResult = SceneWithCache(marchOrigin, marchDir, fragCoord, 1.0, maxSteps, uniforms.glowIntensity, uniforms.foldingLimit, fractalParams, lodIterations, time, fractalType);
    float2 ret = sceneResult.distGlow;
    OrbitCache hitCache = sceneResult.cache;
    
    float adjustedDist = ret.x;
    float glow = ret.y;
    
    half3 col = half3(0.0h);
    
    if (ret.x < kRayMissThreshold)
    {
        float3 p = marchOrigin + adjustedDist * marchDir;
        
        float3 nor = GetNormal(p, adjustedDist, fractalParams, uniforms.foldingLimit, lodIterations, fractalType, hitCache);
        
        // Quad-shared shadows: leader computes, broadcasts to all 4 pixels
        half shaSpot = 1.0h;
        half shaSun = 1.0h;
        
        int shadowIterations = max(lodIterations - 2, 2);
        FractalParams shadowParams = makeFractalParamsFromPrecomputed(
            uniforms.precomputedFractal,
            uniforms.minDistance,
            marchOrigin, uniforms.safetyBubbleRadius, uniforms.safetyBubbleEnabled, uniforms.safetyBubbleShape);
        
        // Use precomputed lighting from CPU
        float3 spotLight = uniforms.precomputedLighting.spotLightPosition;
        float lightIntensity = uniforms.precomputedLighting.lightIntensity;
        float3 spot = spotLight - p;
        float atten = length(spot);
        spot /= atten;
        
        if (quadLaneId == 0) {
            shaSpot = half(Shadow(p, spot, 0.8, uniforms.foldingLimit, shadowParams, shadowIterations, fractalType));
            shaSun = half(Shadow(p, sunDir, 0.8, uniforms.foldingLimit, shadowParams, shadowIterations, fractalType));
        }
        
        // Broadcast shadow values to all 4 pixels in quad
        shaSpot = quad_broadcast(shaSpot, 0);
        shaSun = quad_broadcast(shaSun, 0);
        
        // Per-pixel lighting with shared shadows
        float attenPow = powr(max(atten, kPowEpsilon), kAttenPower);
        half bri = half(max(dot(spot, nor), 0.0) / attenPow * 0.25 * lightIntensity);
        half briSun = half(max(dot(sunDir, nor), 0.0) * 0.2);
        
        col = ColourWithScheme(p, adjustedDist, gTime, 1.0, uniforms.minDistance, uniforms.fractalScale, uniforms.colorMix, uniforms.foldingLimit, uniforms.sphereRadius, max(int(uniforms.colorIterations), 2), uniforms.colorScheme, hitCache);
        col = (col * bri * shaSpot) + (col * briSun * shaSun);
        
        // Specular
        float3 ref = reflect(marchDir, nor);
        float specSpot = powr(max(max(dot(spot, ref), 0.0), kPowEpsilon), kSpecularPower) * kSpecularIntensity * lightIntensity;
        float specSun = powr(max(max(dot(sunDir, ref), 0.0), kPowEpsilon), kSpecularPower) * kSpecularIntensity;
        col += half3(specSpot) * shaSpot * bri;
        col += half3(specSun) * shaSun * briSun;
        
        // Emissive glow (self-illumination based on cached fold patterns)
        if (uniforms.emissiveEnabled != 0) {
            half3 emissive = computeEmissive(
                p,
                nor,
                gTime,
                uniforms.emissivePattern,
                uniforms.emissiveIntensity,
                uniforms.emissiveThreshold,
                uniforms.emissiveColor,
                uniforms.emissiveSpeed,
                lodIterations,
                uniforms.foldingLimit,
                hitCache
            );
            col += emissive;
        }

        // Compute clip-space depth and write it out for async timewarp
        float4 clipPos = uniforms.projectionMatrix * uniforms.modelViewMatrix * float4(p, 1.0);
        output.depth = encodeDepthFromClip(clipPos);
    }
    else
    {
        // No hit - far plane (tiny depth so compositor treats as far away)
        output.depth = 1e-7;
    }
    
    // fogIntensity: 0 = no fog (fogFactor=1), 1 = full fog
    half fogFactor = half(saturate(exp(-adjustedDist * uniforms.fogIntensity * 2.0 + 1.5)));
    col = mix(half3(0.02h, 0.03h, 0.04h), col, fogFactor);
    
    half glowH = half(glow);
    col += glowH * glowH * half3(0.02h, 0.04h, 0.1h);
    
    col = clamp(col, half3(0.0h), half3(2.0h));
    
    col = PostEffectsWithScheme(col, half2(in.texCoord), uniforms.colorScheme, half(uniforms.limitFlash), glowH);
    
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
// CRITICAL: Use nearest-neighbor filtering to preserve MetalFX's intelligent edge reconstruction!
// MetalFX spatial scaler already did sophisticated upscaling - bilinear would blur the result.
fragment float4 formatConversionFragmentStereo(FormatConversionVertexOut in [[stage_in]],
                                                texture2d_array<float> sourceTexture [[texture(0)]],
                                                constant FormatConversionParams& params [[buffer(0)]]) {
    // NEAREST filtering preserves MetalFX edge reconstruction
    // Bilinear here would undo all the intelligent upscaling work!
    constexpr sampler textureSampler(mag_filter::nearest, min_filter::nearest, 
                                      address::clamp_to_edge);
    
    // Sample using normalized UVs - works correctly regardless of source texture resolution
    // aspectCorrection handles physical vs screen aspect ratio difference
    float2 uv = in.texCoord;
    if (params.aspectCorrection != 1.0) {
        uv.x = 0.5 + (uv.x - 0.5) * params.aspectCorrection;
    }
    
    float4 color = sourceTexture.sample(textureSampler, uv, in.eyeIndex);
    return float4(color.rgb, 1.0);
}

// Non-stereo fragment shader for backward compatibility
// Use nearest-neighbor to preserve MetalFX edge reconstruction
fragment float4 formatConversionFragment(FormatConversionVertex in [[stage_in]],
                                          texture2d<float> sourceTexture [[texture(0)]]) {
    constexpr sampler textureSampler(mag_filter::nearest, min_filter::nearest, 
                                      address::clamp_to_edge);
    
    float4 color = sourceTexture.sample(textureSampler, in.texCoord);
    return float4(color.rgb, 1.0);
}

struct DepthOutput {
    float depth [[depth(any)]];
};

// Stereo depth upscale fragment shader
// Use BILINEAR filtering for depth to reduce shimmer during ASW reprojection.
// While nearest preserves exact depth discontinuities, bilinear provides
// smoother depth gradients that ASW can interpolate more accurately.
fragment DepthOutput depthUpscaleFragmentStereo(FormatConversionVertexOut in [[stage_in]],
                                                 depth2d_array<float> sourceTexture [[texture(0)]]) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear, 
                                      address::clamp_to_edge);
    
    DepthOutput out;
    out.depth = sourceTexture.sample(textureSampler, in.texCoord, in.eyeIndex);
    return out;
}

// Non-stereo depth upscale for backward compatibility
fragment DepthOutput depthUpscaleFragment(FormatConversionVertex in [[stage_in]],
                                          depth2d<float> sourceTexture [[texture(0)]]) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear, 
                                      address::clamp_to_edge);
    
    DepthOutput out;
    out.depth = sourceTexture.sample(textureSampler, in.texCoord);
    return out;
}
