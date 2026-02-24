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

// === LOOP UNROLLING STRATEGY ===
// Metal's compiler automatically unrolls loops when bounds are compile-time constants.
// With function constants (FC_*), the compiler specializes each pipeline variant
// and makes optimal unrolling decisions per iteration count. We avoid hardcoded
// unroll hints to let the compiler choose based on:
//   - Register pressure at each iteration count
//   - Loop body complexity
//   - Target GPU architecture
// This gives better results than one-size-fits-all unroll factors.

// === LOOP BODY MACROS ===
// Inline the iteration body for Map functions. Enables the compiler to see
// the full loop body for optimization regardless of loop structure.

// Basic Map iteration (no tracking) - used by Map()
#define MAP_ITERATION_BASIC(p, p0, foldingLimit, params, invSphereRadiusSq) \
    p.xyz = fma(clamp(p.xyz, -foldingLimit, foldingLimit), float3(2.0), -p.xyz); \
    { float r2 = dot(p.xyz, p.xyz); \
      float t = clamp(1.0f / max(r2, params.sphereRadiusSq), 1.0f, invSphereRadiusSq); \
      p *= t; } \
    p = fma(p, params.scale, p0)

// Extended Map iteration with orbit cache tracking - used by MapWithOrbitCache()
// OPTIMIZATION: Use rsqrt (hardware-accelerated) instead of sqrt for minRadius
#define MAP_ITERATION_WITH_CACHE(p, p0, foldingLimit, params, invSphereRadiusSq, i, trap, trapIter, trapPos, boxFolds, sphereFolds, minRadius, orbitTrapDist) \
    { float3 pOld = p.xyz; \
      p.xyz = fma(clamp(p.xyz, -foldingLimit, foldingLimit), float3(2.0), -p.xyz); \
      if (any(p.xyz != pOld)) boxFolds++; } \
    { float r2 = dot(p.xyz, p.xyz); \
      minRadius = min(minRadius, r2); /* Store r2, convert to r later with single sqrt */ \
      float axisTrap = min(min(abs(p.x), abs(p.y)), abs(p.z)); \
      orbitTrapDist = min(orbitTrapDist, axisTrap); \
      if (r2 < trap) { trap = r2; trapIter = i; trapPos = p.xyz; } \
      float t = clamp(1.0f / max(r2, params.sphereRadiusSq), 1.0f, invSphereRadiusSq); \
      if (t > 1.0f) sphereFolds++; \
      p *= t; } \
    p = fma(p, params.scale, p0)

// Half-precision Map iteration - 2x throughput on Apple Silicon
// Numerically stable for coarse marching and shadow rays where
// the hit threshold is >0.02 (well within half's ~3 decimal digits)
#define MAP_ITERATION_HALF(p, p0, foldingLimit, scale, sphereRadiusSq, invSphereRadiusSq) \
    p.xyz = fma(clamp(p.xyz, -foldingLimit, foldingLimit), half3(2.0h), -p.xyz); \
    { half r2 = dot(p.xyz, p.xyz); \
      half t = clamp(1.0h / max(r2, sphereRadiusSq), 1.0h, invSphereRadiusSq); \
      p *= t; } \
    p = fma(p, scale, p0)


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

// (Function constant index 7 reserved — emissive was removed)

// Neon color mode toggle - eliminates neon orbit trap computation when disabled
// (neon mode requires extra orbit tracking in ColourWithScheme)
constant bool FC_NEON_MODE_ENABLED [[function_constant(8)]];

// Color iterations - when defined, enables loop unrolling in ColourWithScheme
constant int FC_COLOR_ITERATIONS [[function_constant(9)]];

// Shadow sharing toggle - allows per-pixel shadows when disabled
constant bool FC_SHARE_SHADOWS [[function_constant(10)]];

// Shadow enable toggle - eliminates entire shadow computation when disabled
constant bool FC_SHADOWS_ENABLED [[function_constant(11)]];

// Visualizer overlay toggle - enables audio-reactive visual overlay
constant bool FC_VISUALIZER_ENABLED [[function_constant(12)]];

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

// Soft lighting: original un-normalized sunDir (length ~0.44)
// The shorter vector naturally softens shadows (shorter march range), diffuse
// (smaller dot product range), and specular (0.44^10 ≈ 0 vs 1.0^10 = 1).
constant float3 sunDirSoft  = float3(0.3235, 0.0924, 0.2773);
// Sharp lighting: normalized sunDir — crisper shadows, stronger specular
constant float3 sunDirSharp = float3(0.7420, 0.2119, 0.6360);

constant float kPowEpsilon = 1e-6f;
constant half kPowEpsilonHalf = 1e-4h;

// === NAMED CONSTANTS FOR OPTIMIZATION ===
// Raymarching thresholds
constant float kRayMissThreshold = 900.0f;      // Distance indicating ray miss
constant float kMaxRayDistance = 12.0f;         // Standard max trace distance

// Shading constants (tuned for softer, less harsh lighting)
constant float kSpecularPower = 10.0f;          // Specular highlight power
constant float kSpecularIntensity = 1.2f;       // Specular intensity multiplier (reduced from 2.0 for softer look)
constant float kAttenPower = 1.2f;              // Light attenuation power (reduced from 1.5 for smoother falloff)

// Quality thresholds
constant float kMinQualityForShadows = 0.25f;   // Skip shadows below this quality
constant float kMinQualityForNormals = 0.2f;    // Use cheap normals below this
constant float kMinQualityForSpecular = 0.7f;   // Skip specular below this
constant float kMinQualityForPostFX = 0.5f;     // Use simple gamma below this

// === ADAPTIVE HIERARCHICAL CONSTANTS ===
constant float ADAPTIVE_FAR_THRESHOLD = 50.0f;   // Use 8x8 tiles beyond this distance
constant float ADAPTIVE_MED_THRESHOLD = 15.0f;   // Use 4x4 tiles beyond this
constant float ADAPTIVE_NEAR_THRESHOLD = 4.0f;   // Use 2x2 tiles beyond this

// === FOG COLOR ===
constant half3 kFogColor = half3(0.01h, 0.015h, 0.02h);
constant half3 kGlowColor = half3(0.02h, 0.04h, 0.1h);

// =============================================================================
// SHARED HELPER FUNCTIONS - Eliminate duplicate code across shaders
// =============================================================================

// Spotlight direction and attenuation calculation
// Returns: .xyz = normalized direction to light, .w = attenuation factor
// OPTIMIZATION: Use rsqrt to combine normalize and length in one operation
FORCE_INLINE float4 computeSpotlight(float3 hitPos, float3 spotLightPosition) {
    float3 toLight = spotLightPosition - hitPos;
    float distSq = dot(toLight, toLight);
    float invDist = rsqrt(max(distSq, kPowEpsilon));  // 1/distance, hardware accelerated
    float dist = distSq * invDist;  // distance = distSq / sqrt(distSq) = sqrt(distSq)
    float atten = powr(max(dist, kPowEpsilon), kAttenPower);
    return float4(toLight * invDist, atten);  // toLight * invDist = normalize(toLight)
}

// Apply fog based on distance
// fogIntensity: 0 = no fog (returns 1), 1 = full fog (returns ~0)
// OPTIMIZATION: Use fma and precompute constants
FORCE_INLINE half3 applyFog(half3 col, float distance, float fogIntensity) {
    // exp(-distance * fogIntensity * 2.0 + 1.5) = exp(1.5) * exp(-distance * fogIntensity * 2.0)
    // Precomputed: exp(1.5) ≈ 4.4817
    float exponent = fma(distance, -fogIntensity * 2.0f, 1.5f);
    half fogFactor = half(saturate(exp(exponent)));
    return mix(kFogColor, col, fogFactor);
}

// Apply glow contribution from ray steps
FORCE_INLINE half3 applyGlow(half3 col, half glow) {
    return col + glow * glow * kGlowColor;
}

// Clamp color before post-processing
FORCE_INLINE half3 clampColor(half3 col) {
    return clamp(col, half3(0.0h), half3(2.0h));
}

// === LIGHTING BLEND: Classic (soft) ↔ Current (vibrance-driven sharp) ===
// lightingSoftness: 0 = current vibrance-driven system, 1 = classic fixed lighting
// This allows smooth blending between the old lighting look and the new one.
struct LightingParams {
    float3 sunDir;
    float sunDiffuseScale;
    float lightIntensity;
};

FORCE_INLINE LightingParams computeBlendedLighting(float vibrance, float lightingSoftness, float baseLightIntensity) {
    LightingParams params;
    
    // Current system: vibrance drives sun direction and intensity
    float3 sunDirNew = mix(sunDirSoft, sunDirSharp, vibrance);
    float sunDiffuseNew = 0.15f;        // Slightly lower than classic for sharper look when vibrant
    float intensityScaleNew = mix(0.5f, 1.2f, vibrance);
    
    // Classic system: fixed sun direction, fixed diffuse, no intensity scaling
    float3 sunDirClassic = sunDirSoft;  // Original un-normalized direction
    float sunDiffuseClassic = 0.2f;     // Original fixed value
    float intensityScaleClassic = 1.0f; // No scaling in classic mode
    
    // Blend between current and classic based on softness for smooth transitions
    params.sunDir = mix(sunDirNew, sunDirClassic, lightingSoftness);
    params.sunDiffuseScale = mix(sunDiffuseNew, sunDiffuseClassic, lightingSoftness);
    params.lightIntensity = baseLightIntensity * mix(intensityScaleNew, intensityScaleClassic, lightingSoftness);
    
    return params;
}

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
// OPTIMIZATION: Precomputed magic constant for time offset
FORCE_INLINE float interleavedGradientNoise(float2 uv, float time) {
    // Combined constants: dot(uv, magic.xy) + time * 0.1
    float noise = fract(52.9829189f * fract(dot(uv, float2(0.06711056f, 0.00583715f))));
    return fract(fma(time, 0.1f, noise));
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
// When FC_FRACTAL_ITERATIONS is defined (via function constants), loopCount becomes
// a compile-time constant and the Metal compiler automatically fully unrolls the loop.
// No pragma hints needed - the compiler is smart enough to optimize constant-bound loops.
FORCE_INLINE float Map(float3 pos, FractalParams params, float foldingLimit, int iterations) 
{
    float4 p = float4(pos, 1.0);
    float4 p0 = p;
    
    float invSphereRadiusSq = 1.0f / params.sphereRadiusSq;

    // When FC_FRACTAL_ITERATIONS is defined, this becomes a compile-time constant
    // and the compiler will automatically unroll the loop.
    const int loopCount = is_function_constant_defined(FC_FRACTAL_ITERATIONS) ? FC_FRACTAL_ITERATIONS : iterations;

    for (int i = 0; i < loopCount; i++) {
        MAP_ITERATION_BASIC(p, p0, foldingLimit, params, invSphereRadiusSq);
    }
    
    // Final distance estimate
    float d = (length(p.xyz) - params.absScalem1) / p.w - params.absScalePow;
    
    // Safety bubble: carve out a shape around the camera to prevent clipping
    const bool bubbleEnabled = is_function_constant_defined(FC_SAFETY_BUBBLE_ENABLED) ? FC_SAFETY_BUBBLE_ENABLED : (params.bubbleEnabled != 0);
    if (bubbleEnabled) {
        float bubbleDist = safetyBubbleDistance(pos, params.bubbleCenter, params.bubbleRadius, params.bubbleShape);
        d = max(d, -bubbleDist);
    }
    return d;
}

// Half-precision Map — 2× ALU throughput on Apple Silicon.
// Use for coarse ray marching and shadow rays where hit threshold is large.
// ~3 digits of precision is sufficient for d > 0.01 thresholds.
FORCE_INLINE float MapHalf(float3 pos, FractalParams params, float foldingLimit, int iterations)
{
    half4 p = half4(half3(pos), 1.0h);
    half4 p0 = p;
    
    half hFold = half(foldingLimit);
    half4 hScale = half4(params.scale);
    half hSphRSq = half(params.sphereRadiusSq);
    half hInvSphRSq = 1.0h / hSphRSq;
    
    const int loopCount = is_function_constant_defined(FC_FRACTAL_ITERATIONS) ? FC_FRACTAL_ITERATIONS : iterations;
    
    for (int i = 0; i < loopCount; i++) {
        MAP_ITERATION_HALF(p, p0, hFold, hScale, hSphRSq, hInvSphRSq);
    }
    
    // Final distance estimate in float for precision
    float d = (length(float3(p.xyz)) - params.absScalem1) / float(p.w) - params.absScalePow;
    
    const bool bubbleEnabled = is_function_constant_defined(FC_SAFETY_BUBBLE_ENABLED) ? FC_SAFETY_BUBBLE_ENABLED : (params.bubbleEnabled != 0);
    if (bubbleEnabled) {
        float bubbleDist = safetyBubbleDistance(pos, params.bubbleCenter, params.bubbleRadius, params.bubbleShape);
        d = max(d, -bubbleDist);
    }
    return d;
}

// =============================================================================
// GEOMETRY-ONLY DISTANCE ESTIMATOR (Inspired by GMT-fractals DE_Dist())
// =============================================================================
// Stripped-down Map variant for shadows, AO, and normal fallback paths.
// Removes ALL tracking: no trap, no trapIter, no trapPos, no boxFolds,
// no sphereFolds, no minRadius, no orbitTrapDist, no Jacobian.
// Just pure box fold → sphere fold → scale, returning distance.
// This saves ~6 extra ops per iteration vs MAP_ITERATION_WITH_CACHE.
FORCE_INLINE float MapDistOnly(float3 pos, FractalParams params, float foldingLimit, int iterations)
{
    float4 p = float4(pos, 1.0);
    float4 p0 = p;
    
    float invSphereRadiusSq = 1.0f / params.sphereRadiusSq;
    
    const int loopCount = is_function_constant_defined(FC_SHADOW_ITERATIONS) ? FC_SHADOW_ITERATIONS : iterations;
    
    for (int i = 0; i < loopCount; i++) {
        MAP_ITERATION_BASIC(p, p0, foldingLimit, params, invSphereRadiusSq);
    }
    
    float d = (length(p.xyz) - params.absScalem1) / p.w - params.absScalePow;
    
    // Safety bubble check (compile-time eliminated when disabled)
    const bool bubbleEnabled = is_function_constant_defined(FC_SAFETY_BUBBLE_ENABLED) ? FC_SAFETY_BUBBLE_ENABLED : (params.bubbleEnabled != 0);
    if (bubbleEnabled) {
        float bubbleDist = safetyBubbleDistance(pos, params.bubbleCenter, params.bubbleRadius, params.bubbleShape);
        d = max(d, -bubbleDist);
    }
    return d;
}

// =============================================================================
// CONTINUOUS (FRACTIONAL) ITERATION MAP
// =============================================================================
//
// The standard Map() takes integer iterations. When the coarse pass uses
// iterations/2, it jumps from e.g. 10→5, creating a different distance field
// that can miss thin features. MapContinuous() smoothly interpolates:
//
//   d(N_frac) = lerp(d_floor, d_ceil, fract(N_frac))
//
// where d_floor is the distance after floor(N_frac) iterations and d_ceil
// is the distance after one more iteration. This produces a smooth distance
// field with no discontinuities — thin features are never "jumped over."
//
// The extra cost is just ONE additional iteration body (box fold + sphere fold)
// per call, but the coarse pass can now use 0.6× iterations instead of 0.5×
// with better accuracy, meaning fewer total ray steps to converge.
//
// Uses half precision for the inner loop (same as MapHalf) since this is
// only used in coarse passes where thresholds are large.

FORCE_INLINE float MapContinuous(float3 pos, FractalParams params, float foldingLimit, float fractionalIterations)
{
    int itersFloor = int(fractionalIterations);
    float frac = fractionalIterations - float(itersFloor);
    itersFloor = max(itersFloor, 1);
    
    half4 p = half4(half3(pos), 1.0h);
    half4 p0 = p;
    
    half hFold = half(foldingLimit);
    half4 hScale = half4(params.scale);
    half hSphRSq = half(params.sphereRadiusSq);
    half hInvSphRSq = 1.0h / hSphRSq;
    
    // Run floor(N) iterations
    for (int i = 0; i < itersFloor; i++) {
        MAP_ITERATION_HALF(p, p0, hFold, hScale, hSphRSq, hInvSphRSq);
    }
    
    // Distance after floor(N) iterations
    float dFloor = (length(float3(p.xyz)) - params.absScalem1) / float(p.w) - params.absScalePow;
    
    // If fractional part is negligible, skip the extra iteration
    if (frac < 0.01f) {
        const bool bubbleEnabled = is_function_constant_defined(FC_SAFETY_BUBBLE_ENABLED) ? FC_SAFETY_BUBBLE_ENABLED : (params.bubbleEnabled != 0);
        if (bubbleEnabled) {
            float bubbleDist = safetyBubbleDistance(pos, params.bubbleCenter, params.bubbleRadius, params.bubbleShape);
            dFloor = max(dFloor, -bubbleDist);
        }
        return dFloor;
    }
    
    // Run one more iteration for ceil(N)
    MAP_ITERATION_HALF(p, p0, hFold, hScale, hSphRSq, hInvSphRSq);
    float dCeil = (length(float3(p.xyz)) - params.absScalem1) / float(p.w) - params.absScalePow;
    
    // Smooth interpolation between floor and ceil distance estimates
    float d = mix(dFloor, dCeil, frac);
    
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

// =============================================================================
// GRADIENT COLORING SYSTEM
// Samples a user-defined gradient from up to MAX_GRADIENT_STOPS color stops.
// Each stop packs color (xyz) + position (w) into a float4.
// =============================================================================

// Sample gradient at position t (0-1) using the stop array
// When loopSmooth is true, the gradient wraps seamlessly: after the last stop it blends
// back into the first stop, eliminating the hard cut when gradient cycles.
FORCE_INLINE half3 sampleGradient(float t, thread const float4 *stops, int stopCount, float smoothing, bool loopSmooth = false)
{
    if (stopCount <= 0) return half3(1.0h);
    if (stopCount == 1) return half3(stops[0].xyz);
    
    // Clamp t to valid range
    t = saturate(t);
    
    if (loopSmooth) {
        // Smooth looping: treat the gradient as a ring.
        // We remap stops so the virtual last stop (position=1.0) equals the first stop's color,
        // creating a seamless wrap without modifying the user's stop array.
        
        // Map t into the ring: each stop occupies a segment, plus one extra
        // wrap-around segment from the last stop back to the first.
        float firstPos = stops[0].w;
        float lastPos = stops[stopCount - 1].w;
        
        // Compute total span including wrap-around gap
        // The wrap segment goes from lastPos to (1.0 + firstPos) in unwrapped space
        float wrapGap = (1.0f - lastPos) + firstPos;
        
        // If t is in the wrap-around zone (after last stop or before first stop)
        if (t >= lastPos || t < firstPos) {
            // Distance into wrap zone from lastPos
            float d = (t >= lastPos) ? (t - lastPos) : (t + 1.0f - lastPos);
            float localT = (wrapGap > 0.0f) ? (d / wrapGap) : 0.0f;
            float smoothT = mix(localT, localT * localT * (3.0f - 2.0f * localT), smoothing);
            return mix(half3(stops[stopCount - 1].xyz), half3(stops[0].xyz), half(smoothT));
        }
        
        // Otherwise, find surrounding stops normally (between first and last)
        for (int i = 0; i < stopCount - 1; i++) {
            if (t >= stops[i].w && t <= stops[i + 1].w) {
                float range = stops[i + 1].w - stops[i].w;
                float localT = (range > 0.0f) ? (t - stops[i].w) / range : 0.0f;
                float smoothT = mix(localT, localT * localT * (3.0f - 2.0f * localT), smoothing);
                return mix(half3(stops[i].xyz), half3(stops[i + 1].xyz), half(smoothT));
            }
        }
        
        // Fallback: return last stop
        return half3(stops[stopCount - 1].xyz);
    }
    
    // Non-looping: original behavior
    // Find surrounding stops
    int lower = 0;
    int upper = stopCount - 1;
    
    for (int i = 0; i < stopCount - 1; i++) {
        if (t >= stops[i].w && t <= stops[i + 1].w) {
            lower = i;
            upper = i + 1;
            break;
        }
    }
    
    // Handle edge cases
    if (t <= stops[0].w) return half3(stops[0].xyz);
    if (t >= stops[stopCount - 1].w) return half3(stops[stopCount - 1].xyz);
    
    // Interpolate between surrounding stops
    float range = stops[upper].w - stops[lower].w;
    float localT = (range > 0.0f) ? (t - stops[lower].w) / range : 0.0f;
    
    // Apply smoothstep for smooth transitions when smoothing > 0
    float smoothT = mix(localT, localT * localT * (3.0f - 2.0f * localT), smoothing);
    
    return mix(half3(stops[lower].xyz), half3(stops[upper].xyz), half(smoothT));
}

// Compute the mapping value based on the selected color mapping mode
// Returns a value in 0-1 that indexes into the gradient
FORCE_INLINE float computeColorMapping(int mode, float trap, int trapIter, int totalIters,
                                        float3 trapPos, float3 hitPos, float distance,
                                        float3 normal, float gradientRepeat, float gradientOffset)
{
    float t = 0.0f;
    
    switch (mode) {
        case 0: // Orbit Trap (default - same as legacy)
            t = sqrt(saturate(trap));
            break;
        case 1: // Iterations - normalized iteration count
            t = float(trapIter) / float(max(totalIters, 1));
            break;
        case 2: // Z-Depth - distance from camera
            t = saturate(distance * 0.1f); // Normalize to reasonable range
            break;
        case 3: // Angle - polar angle of trap position
            t = atan2(trapPos.y, trapPos.x) * 0.15915494f + 0.5f; // Normalize to 0-1
            break;
        case 4: // Normal - surface normal direction
            t = saturate(normal.y * 0.5f + 0.5f); // Map normal.y from [-1,1] to [0,1]
            break;
        case 5: // Blended - mix of orbit trap + iteration
        {
            float trapT = sqrt(saturate(trap));
            float iterT = float(trapIter) / float(max(totalIters, 1));
            t = trapT * 0.6f + iterT * 0.4f;
            break;
        }
        default:
            t = sqrt(saturate(trap));
            break;
    }
    
    // Apply repeat and offset
    t = fract(t * gradientRepeat + gradientOffset);
    
    return t;
}

// Neon orbit trap coloring - uses scheme palette colors for distinct looks
// trapMin: distance to orbit trap (0 = close, 1 = far)
// trapIter: normalized iteration depth
// trapAngle: angle-based variation
// OPTIMIZATION: Branchless color blending using smoothstep transitions
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
    // BRANCHLESS: Use smoothstep blending instead of if/else cascade
    half colorPhase = fract(it * half(scheme.hueFrequency) * 0.5h + half(scheme.hueOffset));
    
    // Smooth transitions at phase boundaries (0.33, 0.66)
    // t1: 0->1 as phase goes 0->0.33, t2: 0->1 as phase goes 0.33->0.66, t3: 0->1 as phase goes 0.66->1
    half t1 = saturate(colorPhase * 3.0h);                    // Blend col1->col2
    half t2 = saturate((colorPhase - 0.33h) * 3.0h);          // Blend col2->col3
    half t3 = saturate((colorPhase - 0.66h) * 3.0h);          // Blend col3->col1
    
    // Combine blends: col1 -> col2 -> col3 -> col1
    half3 baseColor = mix(col1, col2, t1);           // Phase 0-0.33: col1->col2
    baseColor = mix(baseColor, col3, t2);            // Phase 0.33-0.66: blend toward col3
    baseColor = mix(baseColor, col1, t3);            // Phase 0.66-1: blend back toward col1
    
    // Optional soft banding - branchless multiply
    half bandActive = step(0.1h, half(scheme.bandFrequency));
    half band = sin(d * half(scheme.bandFrequency) * 3.14159h);
    half bandEffect = 1.0h - bandActive * 0.2h * (1.0h - band * band);
    
    // Saturation boost for neon effect
    half sat = pow(0.9h, half(scheme.saturationPower));
    
    // Final color: base palette color * glow * banding
    half3 rgb = baseColor * glow * bandEffect;
    
    // Boost saturation by pushing away from gray
    half luma = dot(rgb, half3(0.299h, 0.587h, 0.114h));
    rgb = mix(half3(luma), rgb, 1.0h + sat);
    
    return saturate(rgb);
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
//
// =============================================================================

// Cached orbit state from Mandelbox iteration
// Stores everything needed to compute normals and colors
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
    
    // === ANALYTIC JACOBIAN for normal computation ===
    // Accumulated derivative of the Mandelbox iteration w.r.t. input position.
    // Avoids 3 extra Map() calls for finite-difference normals.
    float3x3 jacobian;     // dF/dp0 accumulated through iteration chain rule
    bool hasJacobian;      // Whether jacobian was computed
};

// Create empty/invalid cache
FORCE_INLINE OrbitCache makeEmptyOrbitCache() {
    OrbitCache cache;
    cache.valid = false;
    cache.trap = 1.0f;
    cache.distance = kRayMissThreshold;
    cache.trapIteration = 0;
    cache.trapPosition = float3(0.0f);
    cache.jacobian = float3x3(1.0f);
    cache.hasJacobian = false;
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
    
    // Use function constant when defined for compile-time loop unrolling
    // This allows the compiler to specialize the loop when colorIterations is known
    const int baseColorIters = is_function_constant_defined(FC_COLOR_ITERATIONS) 
        ? FC_COLOR_ITERATIONS 
        : colorIters;
    
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
        
        // Scale by quality (runtime), but base is specialized per pipeline when FC is defined
        steps = max(int(float(baseColorIters) * quality), 2);
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
    
    // === NEON MODE CHECK ===
    // Use function constant when defined to eliminate neon code path entirely
    const bool neonEnabled = is_function_constant_defined(FC_NEON_MODE_ENABLED)
        ? FC_NEON_MODE_ENABLED
        : (scheme.neonIntensity > 0.01f);
    
    // === GRADIENT COLORING SYSTEM ===
    // When useGradientColoring is enabled, use the gradient stop array
    // instead of the legacy 3-color palette system.
    if (scheme.useGradientColoring && scheme.gradientStopCount > 0) {
        // Compute the gradient mapping value based on the selected mode
        // Note: normal is approximated from trap position for this path
        float3 approxNormal = normalize(trapPos);
        float mappingT = computeColorMapping(
            scheme.colorMappingMode,
            trap, trapIter, steps,
            trapPos, pos, 0.0f,
            approxNormal,
            scheme.gradientRepeat,
            scheme.gradientOffset
        );
        
        half3 gradColor = sampleGradient(mappingT, scheme.gradientStops, scheme.gradientStopCount, scheme.gradientSmoothing, scheme.gradientLoopSmooth != 0);
        
        // If neon mode is also active, blend gradient with neon
        if (neonEnabled && scheme.neonIntensity > 0.01f) {
            half trapMin = half(sqrt(trap));
            half trapIterNorm = half(float(trapIter) / float(steps));
            half trapAngle = half(atan2(trapPos.y, trapPos.x) * 0.15915494f + 0.5f);
            half3 neonColor = applyNeonColorScheme(trapMin, trapIterNorm, trapAngle, scheme);
            return mix(gradColor, neonColor, half(scheme.neonIntensity));
        }
        
        return gradColor;
    }
    
    // === LEGACY COLORING PATH ===
    if (neonEnabled && scheme.neonIntensity > 0.01f) {
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

// === MapWithOrbitCache ===
//
// Lean orbit tracking: Jacobian + trap values (normals + colors).
// (Fold tracking for emissive patterns has been removed.)
FORCE_INLINE float MapWithOrbitCache(float3 pos, FractalParams params, float foldingLimit, int iterations, thread OrbitCache& cache)
{
    float4 p = float4(pos, 1.0);
    float4 p0 = p;
    
    float invSphereRadiusSq = 1.0f / params.sphereRadiusSq;
    float trap = 1.0f;
    int trapIter = 0;
    float3 trapPos = pos;
    
    // Analytic Jacobian for zero-cost normals
    float3x3 J = float3x3(1.0f);
    
    const int loopCount = is_function_constant_defined(FC_FRACTAL_ITERATIONS) ? FC_FRACTAL_ITERATIONS : iterations;
    
    for (int i = 0; i < loopCount; i++) {
        // --- Box fold with Jacobian ---
        float3 pOld = p.xyz;
        p.xyz = fma(clamp(p.xyz, -foldingLimit, foldingLimit), float3(2.0), -p.xyz);
        
        float3 boxDiag = select(float3(-1.0f), float3(1.0f),
                               abs(pOld.xyz) < float3(foldingLimit));
        J[0] *= boxDiag;
        J[1] *= boxDiag;
        J[2] *= boxDiag;
        
        // --- Sphere fold with Jacobian ---
        float r2 = dot(p.xyz, p.xyz);
        if (r2 < trap) { trap = r2; trapIter = i; trapPos = p.xyz; }
        
        float t = clamp(1.0f / max(r2, params.sphereRadiusSq), 1.0f, invSphereRadiusSq);
        
        J *= t;
        p *= t;
        
        // --- Scale + translate with Jacobian ---
        float s = params.scale.x;
        p = fma(p, params.scale, p0);
        J = s * J;
        J[0][0] += 1.0f;
        J[1][1] += 1.0f;
        J[2][2] += 1.0f;
    }
    
    float d = (length(p.xyz) - params.absScalem1) / p.w - params.absScalePow;
    
    const bool bubbleEnabled = is_function_constant_defined(FC_SAFETY_BUBBLE_ENABLED) ? FC_SAFETY_BUBBLE_ENABLED : (params.bubbleEnabled != 0);
    if (bubbleEnabled) {
        float bubbleDist = safetyBubbleDistance(pos, params.bubbleCenter, params.bubbleRadius, params.bubbleShape);
        d = max(d, -bubbleDist);
    }
    
    cache.p = p;
    cache.p0 = pos;
    cache.trap = trap;
    cache.distance = d;
    cache.iterationsUsed = loopCount;
    cache.valid = true;
    cache.trapIteration = trapIter;
    cache.trapPosition = trapPos;
    cache.jacobian = J;
    cache.hasJacobian = true;
    
    return d;
}

// Compute normal using cached orbit state
// Three paths, in priority order:
//   1. Analytic Jacobian (cache.hasJacobian) — ZERO extra Map() calls
//      Normal = normalize(J^T * normalize(p.xyz))
//      where J = dF/dp0 accumulated during MapWithOrbitCache iteration
//   2. Cached center distance — 3 extra Map() calls with reduced iterations
//   3. Standard finite differences — 4 Map() calls with full iterations
FORCE_INLINE float3 GetNormal(float3 pos, float distance, FractalParams params, float foldingLimit, int iterations, int fractalType, OrbitCache cache = {})
{
    if (cache.hasJacobian && fractalType == 0) {
        // === ANALYTIC JACOBIAN PATH — no extra Map() calls ===
        // The gradient of the distance function d(p0) = f(F(p0)) where F is the
        // iterated Mandelbox map and f extracts the distance from final state.
        // By chain rule: grad(d) = J^T * grad_p(f) where J = dF/dp0.
        // For d = length(p.xyz)/p.w, grad_p(f) ≈ normalize(p.xyz) (dominant term).
        float3 pDir = cache.p.xyz * rsqrt(dot(cache.p.xyz, cache.p.xyz) + kPowEpsilon);
        
        // J^T * pDir  (transpose multiply)
        float3 gradient = float3(
            dot(cache.jacobian[0], pDir),
            dot(cache.jacobian[1], pDir),
            dot(cache.jacobian[2], pDir)
        );
        
        return gradient * rsqrt(dot(gradient, gradient) + kPowEpsilon);
    } else if (cache.valid && fractalType == 0) {
        // Fallback: use cached center distance, reduced iterations
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
        float d = Map(pos, params, foldingLimit, iterations);
        float3 gradient = float3(
            Map(pos + float3(e,0,0), params, foldingLimit, iterations) - d,
            Map(pos + float3(0,e,0), params, foldingLimit, iterations) - d,
            Map(pos + float3(0,0,e), params, foldingLimit, iterations) - d
        );
        return gradient * rsqrt(dot(gradient, gradient) + kPowEpsilon);
    }
}

// Far-range coarse raymarch (12 steps, max 80 units) - REMOVED (unused)
// Near-range coarse raymarch (24 steps, max 12 units)
// Compiler unrolls based on FC_FRACTAL_ITERATIONS when defined
FORCE_INLINE float SceneCoarse(float3 rO, float3 rD, float foldingLimit, FractalParams params, int iterations)
{
    float t = 0.05f;
    
    // Use MapContinuous with 0.6× iterations for smooth fractional DE.
    // This preserves thin features better than integer iterations/2 because
    // the continuous interpolation avoids the discontinuity that causes
    // the coarse pass to "jump over" fine structures.
    // The 0.6× factor balances speed (fewer iterations) vs. accuracy.
    float coarseIters = float(iterations) * 0.6f;
    
    for(int j = 0; j < 24 && t <= kMaxRayDistance; j++)
    {
        float3 p = fma(rD, float3(t), rO);
        float h = MapContinuous(p, params, foldingLimit, coarseIters);
        
        if(UNLIKELY(h < 0.02f)) return t;
        
        t += h;
    }
    
    return kRayMissThreshold + 100.0f;
}

// Cached scene result - stores orbit state for reuse in normals/colors
struct SceneResult {
    float2 distGlow;    // .x = distance, .y = glow
    OrbitCache cache;   // Cached orbit state from final hit position
};

// Raymarch that caches orbit state on hit for reuse in normals/colors
FORCE_INLINE SceneResult SceneWithCache(float3 rO, float3 rD, float2 fragCoord, float quality, int maxStepsParam, float glowIntensity, float foldingLimit, FractalParams params, int iterations, float time, int fractalType = 0, float boundingSphereRadius = 0.0, float stepMultiplier = 1.0)
{
    SceneResult result;
    result.cache = makeEmptyOrbitCache();
    
    float dither = interleavedGradientNoise(fragCoord, time) * 0.015;
    float t = 0.05 + dither;
    
    // === BOUNDING SPHERE PRE-TEST (GMT-fractals technique) ===
    // Skip empty space before the fractal's bounding volume.
    // When boundingSphereRadius > 0, ray-sphere intersect jumps t to the
    // sphere entry point, saving dozens of wasted Map() evaluations in void.
    if (boundingSphereRadius > 0.0) {
        float sphereT = rayIntersectBoundingSphere(rO, rD, float3(0.0), boundingSphereRadius);
        if (sphereT < 0.0) {
            // Ray misses bounding sphere entirely — no fractal geometry possible
            result.distGlow = float2(kRayMissThreshold + 100.0, 0.0);
            return result;
        }
        t = max(t, sphereT);
    }
    
    float glow = 0.0;
    
    // When FC_MAX_RAY_STEPS is defined, baseMaxSteps is compile-time constant
    // and compiler can make optimal unrolling decisions per quality preset
    const int baseMaxSteps = is_function_constant_defined(FC_MAX_RAY_STEPS) ? FC_MAX_RAY_STEPS : maxStepsParam;
    int maxSteps = max(int(float(baseMaxSteps) * quality), 4);
    
    for(int j = 0; j < maxSteps; j++)
    {
        float threshold = fma(t, 0.0008, 0.0005) + (1.0 - quality) * 0.003;
        
        float3 p = fma(rD, float3(t), rO);
        // Use Map() for the march loop (no Jacobian overhead)
        float h = Map(p, params, foldingLimit, iterations);
        
        if(UNLIKELY(h < threshold))
        {
            // Re-iterate with full orbit cache + Jacobian for normals/colors.
            // This is one redundant iteration set at the hit point, but far cheaper
            // than accumulating Jacobian on every step of the march loop.
            OrbitCache hitCache;
            MapWithOrbitCache(p, params, foldingLimit, iterations, hitCache);
            result.cache = hitCache;
            result.distGlow = float2(t, saturate(glow * 0.25));
            return result;
        }
        
        if (UNLIKELY(t > kMaxRayDistance)) break;
        
        glow = fma(saturate(0.04 - h), glowIntensity, glow);
        // STEP OVER-RELAXATION (GMT-fractals technique)
        // stepMultiplier > 1.0 takes larger steps, converging faster at the risk
        // of stepping through thin features. 1.2-1.5 is safe for Mandelbox;
        // CPU adjusts dynamically based on geometry state.
        t += h * stepMultiplier;
    }
    
    result.distGlow = float2(kRayMissThreshold + 100.0, saturate(glow * 0.25));
    return result;
}

// Raymarch with cache that starts from a known distance (for hierarchical acceleration)
FORCE_INLINE SceneResult SceneWithCacheFromStart(float3 rO, float3 rD, float startT, float2 fragCoord, float quality, int maxStepsParam, float glowIntensity, float foldingLimit, FractalParams params, int iterations, float time, int fractalType = 0, float stepMultiplier = 1.0)
{
    SceneResult result;
    result.cache = makeEmptyOrbitCache();
    
    float dither = interleavedGradientNoise(fragCoord, time) * 0.01;
    float t = max(0.01, startT - 0.3) + dither;
    
    float glow = 0.0;
    // Compiler specializes per FC_MAX_RAY_STEPS value
    const int baseMaxSteps = is_function_constant_defined(FC_MAX_RAY_STEPS) ? FC_MAX_RAY_STEPS : maxStepsParam;
    
    // OPTIMIZATION: When startT comes from temporal reprojection, we're already
    // within ~0.3 units of the surface. The search window is only 2.3 units wide,
    // so we need far fewer steps than the full half-budget. Scale steps by how
    // tight the start is relative to full-range marching.
    // - startT < 1.0 (near camera): likely coarse start, use full half-budget
    // - startT > 1.0 (temporal reproj): tight window, use reduced budget (0.25×)
    float stepScale = (startT > 1.0f) ? 0.25f : 0.5f;
    int maxSteps = max(int(float(baseMaxSteps) * quality * stepScale), 8);
    float endT = startT + 2.0;
    
    for(int j = 0; j < maxSteps; j++)
    {
        float threshold = fma(t, 0.0006, 0.0005);
        float3 p = fma(rD, float3(t), rO);
        // Use Map() for the march loop (no Jacobian overhead)
        float h = Map(p, params, foldingLimit, iterations);
        
        if(UNLIKELY(h < threshold))
        {
            // Re-iterate with full orbit cache + Jacobian for normals/colors.
            OrbitCache hitCache;
            MapWithOrbitCache(p, params, foldingLimit, iterations, hitCache);
            result.cache = hitCache;
            result.distGlow = float2(t, saturate(glow * 0.25));
            return result;
        }
        
        if (UNLIKELY(t > endT)) break;
        
        glow = fma(saturate(0.04 - h), glowIntensity, glow);
        // STEP OVER-RELAXATION (GMT-fractals technique)
        t += h * stepMultiplier;
    }
    
    result.distGlow = float2(kRayMissThreshold + 100.0, saturate(glow * 0.25));
    return result;
}

// =============================================================================

// Post effects with color scheme support and dynamic animation
// OPTIMIZATION: Now properly skips disabled effects using branches (cleaner than branchless)
half3 PostEffectsWithScheme(half3 rgb, half2 xy, ColorSchemeParams scheme, half limitFlash = 0.0h, half rayGlow = 0.0h)
{
    // === DYNAMIC HUE CYCLING (OPTIONAL EFFECT WITH INTENSITY CONTROL) ===
    // Only process if enabled - uses YIQ color space rotation
    // Intensity parameter allows blending rotated color back with original to prevent overpowering
    if (scheme.hueRotationEnabled) {
        float rawAngle = scheme.animTime * scheme.hueRotationSpeed * 6.28318f;
        float wrappedAngle = fmod(rawAngle, 6.28318f);
        half hueAngle = half(wrappedAngle);
        half cosH = cos(hueAngle);
        half sinH = sin(hueAngle);
        
        // Convert RGB to YIQ
        half3 yiq;
        yiq.x = dot(rgb, half3(0.299h, 0.587h, 0.114h));
        yiq.y = dot(rgb, half3(0.596h, -0.274h, -0.322h));
        yiq.z = dot(rgb, half3(0.211h, -0.523h, 0.312h));
        
        // Rotate I and Q components
        half newY = fma(yiq.y, cosH, -yiq.z * sinH);
        half newZ = fma(yiq.y, sinH, yiq.z * cosH);
        
        // Convert back to RGB
        half3 rotated;
        rotated.r = fma(0.956h, newY, fma(0.621h, newZ, yiq.x));
        rotated.g = fma(-0.272h, newY, fma(-0.647h, newZ, yiq.x));
        rotated.b = fma(-1.106h, newY, fma(1.703h, newZ, yiq.x));
        rotated = saturate(rotated);
        
        // Blend rotated with original based on intensity
        rgb = mix(rgb, rotated, half(scheme.hueRotationIntensity));
    }
    
    // === PULSE EFFECT (OPTIONAL) ===
    // Rhythmic brightness and saturation variation
    half pulse = 1.0h;
    if (scheme.pulseEnabled) {
        float rawPulseAngle = scheme.animTime * scheme.pulseSpeed * 6.28318f;
        half pulseWave = 0.5h + 0.5h * sin(half(fmod(rawPulseAngle, 6.28318f)));
        pulse = 1.0h + half(scheme.pulseAmount) * (pulseWave - 0.5h);
    }
    
    // === SATURATION WITH PULSE ===
    half luma = dot(rgb, half3(0.2126h, 0.7152h, 0.0722h));
    half satMult = half(scheme.saturation) * pulse;
    rgb = mix(half3(luma), rgb, satMult);
    
    // === BRIGHTNESS AND CONTRAST (ALWAYS APPLIED) ===
    rgb = fma(rgb - half3(0.5h), half3(scheme.contrast), half3(0.5h + scheme.brightness));
    
    // === GLOW EFFECT (OPTIONAL) ===
    if (scheme.glowEnabled) {
        half glowAmount = rayGlow * half(scheme.glowIntensity);
        if (glowAmount > 0.01h) {
            half3 glowColor = rgb * fma(glowAmount, 2.0h, 1.0h);
            rgb = mix(rgb, glowColor, glowAmount * 0.5h);
        }
    }
    
    // === BLOOM EFFECT (OPTIONAL) ===
    if (scheme.bloomEnabled) {
        half brightness = dot(rgb, half3(0.299h, 0.587h, 0.114h));
        half bloomAmount = max(0.0h, brightness - 0.7h) * half(scheme.bloomStrength);
        rgb = fma(half3(0.3h, 0.3h, 0.35h), half3(bloomAmount), rgb);
    }
    
    // === HIGHLIGHTS/EXPOSURE (skip when identity) ===
    if (abs(scheme.highlights) > 0.001f) {
        rgb *= half(1.0f + scheme.highlights);
    }
    
    // === VIBRANCE (skip when ~0) ===
    if (abs(scheme.vibrance) > 0.001f) {
        half maxChannel = max(rgb.r, max(rgb.g, rgb.b));
        half vibranceBoost = (1.0h - maxChannel) * half(scheme.vibrance);
        half luma2 = dot(rgb, half3(0.299h, 0.587h, 0.114h));
        rgb = mix(half3(luma2), rgb, 1.0h + vibranceBoost);
    }
    
    // === SHADOWS LIFT/CRUSH (skip when identity) ===
    if (abs(scheme.shadows) > 0.001f) {
        rgb = fma(half3(scheme.shadows), 1.0h - rgb, rgb);
    }
    
    // === MIDTONE S-CURVE (skip expensive powr when curve ≈ 0) ===
    // powr() is expensive on GPU — only compute when curve is actually active
    if (abs(scheme.colorCurve) > 0.001f) {
        half curve = half(scheme.colorCurve);
        half exponent = 1.0h / (1.0h + curve * 0.7h);
        half3 delta = rgb - 0.5h;
        rgb = fma(sign(delta), 0.5h * powr(abs(delta) * 2.0h, half3(exponent)), half3(0.5h));
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
// OPTIMIZATION: Use step() instead of branches for GPU-friendly code
float hudBar(float2 uv, float2 pos, float2 size, float fillAmount) {
    float2 localUV = (uv - pos) / size;
    
    // Early exit check using step (branchless)
    float inBounds = step(0.0f, localUV.x) * step(localUV.x, 1.0f) * 
                     step(0.0f, localUV.y) * step(localUV.y, 1.0f);
    if (inBounds < 0.5f) return 0.0f;
    
    // Border (2% edge) - use branchless comparisons
    float borderL = step(localUV.x, 0.02f);
    float borderR = step(0.98f, localUV.x);
    float borderB = step(localUV.y, 0.08f);
    float borderT = step(0.92f, localUV.y);
    float border = max(max(borderL, borderR), max(borderB, borderT)) * 0.6f;
    
    // Fill bar - branchless
    float fillX = step(0.02f, localUV.x) * step(localUV.x, fma(fillAmount, 0.96f, 0.02f));
    float fillY = step(0.08f, localUV.y) * step(localUV.y, 0.92f);
    float fill = fillX * fillY;
    
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
// DEBUG SPHERE - Visualizes hand spread distance during two-hand gestures
// Renders a colored sphere in screen space that grows with hand separation
// =============================================================================

half3 renderDebugSphere(half3 baseColor, float2 uv, int activeGesture, float gestureSpread) {
    // Debug sphere disabled - function kept for API compatibility
    return baseColor;
}

// =============================================================================

// Soft shadow with over-relaxation
// OPTIMIZATION: Combined exit conditions to reduce branches
// GMT-FRACTALS TECHNIQUE: FC_SHADOWS_ENABLED allows compile-time elimination of
// entire shadow computation. When disabled, returns a flat ambient shadow value
// (0.35) — zero Map() evaluations, zero ALU cost.
// Also uses MapDistOnly instead of MapHalf — removes all fold/trap tracking
// from shadow rays, saving ~6 ops per iteration per shadow step.
FORCE_INLINE float Shadow(float3 ro, float3 rd, float quality, float foldingLimit, FractalParams params, int iterations, int fractalType = 0)
{
    // === COMPILE-TIME SHADOW ELIMINATION (GMT-fractals technique) ===
    // When FC_SHADOWS_ENABLED is defined as false, the compiler eliminates
    // the entire shadow march — zero Map evaluations, zero GPU cost.
    // This is the single biggest perf win during interaction/movement.
    const bool shadowsEnabled = is_function_constant_defined(FC_SHADOWS_ENABLED) ? FC_SHADOWS_ENABLED : true;
    if (!shadowsEnabled) return 0.35f;
    
    const int qualityMode = is_function_constant_defined(FC_QUALITY_MODE) ? FC_QUALITY_MODE : 0;
    // Return higher minimum for softer shadows (0.35 = more fill light in shadows)
    if (qualityMode >= 2) return 0.35f;
    if (UNLIKELY(quality < kMinQualityForShadows)) return 0.35f;
    
    float res = 1.0f;
    float t = 0.08f;
    float prevH = 1e10f;
    
    // When FC_SHADOW_ITERATIONS is defined, steps becomes compile-time constant
    // Compiler unrolls optimally for each quality preset (2-3 steps)
    // OPTIMIZATION: Medium quality uses 2 steps (was 2-3), reduces shadow Map evals by ~33%
    const int steps = is_function_constant_defined(FC_SHADOW_ITERATIONS) ? 
        (qualityMode >= 1 ? 2 : 3) : 
        int(fma(quality, 2.0f, 1.0f));
    
    // OPTIMIZATION: Reduce shadow march range for medium quality.
    // Shadows beyond ~2.5 units have minimal visual impact and waste iterations.
    const float shadowRange = (qualityMode >= 1) ? 2.5f : 4.0f;
    
    for (int i = 0; i < steps && t <= shadowRange && res >= 0.02f; i++)
    {
        float3 p = fma(rd, float3(t), ro);
        // GEOMETRY-ONLY DE (GMT-fractals technique): MapDistOnly strips all
        // fold tracking, orbit traps, and Jacobian from shadow rays.
        // Shadow rays only need distance — the ~6 extra ops per iteration
        // in Map/MapHalf for tracking are pure waste here.
        float h = MapDistOnly(p, params, foldingLimit, iterations);
        
        // Use rcp for division by t (faster on many GPUs)
        res = min(res, 10.0f * h * (1.0f / t));
        
        float relax = step(prevH * 0.8f, h);
        float stepDist = mix(h, h * 1.5f, relax);
        t += max(stepDist, 0.15f);
        prevH = h;
    }
    
    // Clamp to minimum 0.2 for ambient fill - prevents harsh black shadows
    return max(saturate(res), 0.2f);
}

// === TILE-BASED RAYMARCHING (4x4 pixel groups) ===
// One DE raymarch per tile, per-pixel normals for smooth shading
// Reduces DE overhead by ~16x while maintaining surface detail

#define TILE_SIZE 4

// =============================================================================
// EMISSIVE GLOW CALCULATION
// Computes self-illumination based on cached fold state and patterns
// Falls back to live fold sampling when enabled for richer detail
// =============================================================================

// Track fold information during SDF evaluation for emissive calculation
struct FoldInfo {
    int boxFolds;
    int sphereFolds;
    float minRadius;
    float orbitTrap;
};

// Evaluate SDF with fold tracking (reintroduces legacy emissive feel)
FORCE_INLINE float MapWithFoldInfo(float3 pos, FractalParams params, float foldingLimit, int iterations, int fractalType, thread FoldInfo& foldInfo) {
    foldInfo.boxFolds = 0;
    foldInfo.sphereFolds = 0;
    foldInfo.minRadius = 1e10;
    foldInfo.orbitTrap = 1e10;
    
    float3 z = pos;
    float dr = 1.0;
    float scale = params.scale.x;
    float minRad2 = params.minDistanceVal; // reuse existing minimum distance parameter
    float fixedRad2 = params.sphereRadiusSq;
    float invSphereRadiusSq = 1.0f / params.sphereRadiusSq;
    
    for (int i = 0; i < iterations; i++) {
        float3 zOld = z;
        z = clamp(z, -foldingLimit, foldingLimit) * 2.0 - z;
        if (any(z != zOld)) foldInfo.boxFolds++;
        
        float r2 = dot(z, z);
        foldInfo.minRadius = min(foldInfo.minRadius, sqrt(r2));
        float trap = min(min(abs(z.x), abs(z.y)), abs(z.z));
        foldInfo.orbitTrap = min(foldInfo.orbitTrap, trap);
        
        if (r2 < minRad2) {
            float temp = fixedRad2 / max(minRad2, kPowEpsilon);
            z *= temp;
            dr *= temp;
            foldInfo.sphereFolds++;
        } else if (r2 < fixedRad2) {
            float temp = clamp(1.0f / max(r2, kPowEpsilon), 1.0f, invSphereRadiusSq);
            z *= temp;
            dr *= temp;
            foldInfo.sphereFolds++;
        }
        
        z = scale * z + pos;
        dr = dr * abs(scale) + 1.0;
    }
    
    return length(z) / abs(dr) - 0.001;
}

// Compute emissive glow - prefers cache but refreshes fold data when needed
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
    FractalParams params,
    int fractalType,
    OrbitCache cache
) {
    if (intensity <= 0.0) return half3(0.0h);
    
    // Start with cached fold info when available
    int boxFolds = cache.valid ? cache.boxFolds : 0;
    int sphereFolds = cache.valid ? cache.sphereFolds : 0;
    float minRadius = cache.valid ? cache.minRadius : 1e10;
    float orbitTrapDist = cache.valid ? cache.orbitTrapDist : 1e10;
    
    // When cache is missing or emissive patterns need richer detail, refresh via MapWithFoldInfo
    // Only refresh when intensity is significant to avoid noise from unnecessary re-computation
    bool refreshFoldInfo = !cache.valid || intensity > 0.5;
    if (refreshFoldInfo) {
        FoldInfo info;
        MapWithFoldInfo(pos, params, foldingLimit, min(iterations, 8), fractalType, info);
        boxFolds = info.boxFolds;
        sphereFolds = info.sphereFolds;
        minRadius = info.minRadius;
        orbitTrapDist = info.orbitTrap;
    }
    
    float emission = 0.0;
    
    if (pattern == 0) {
        float foldRatio = float(boxFolds + sphereFolds) / float(iterations * 2);
        emission = smoothstep(threshold, 1.0, foldRatio);
    }
    else if (pattern == 1) {
        float depthFactor = 1.0 - saturate(minRadius / (foldingLimit * 2.0));
        emission = smoothstep(threshold, 1.0, depthFactor);
    }
    else if (pattern == 2) {
        float3 freq = float3(5.0, 7.0, 6.0);
        float veins = sin(pos.x * freq.x) * sin(pos.y * freq.y) * sin(pos.z * freq.z);
        veins = veins * 0.5 + 0.5;
        float trap = 1.0 - saturate(orbitTrapDist * 2.0);
        emission = smoothstep(threshold, 1.0, veins * 0.5 + trap * 0.5);
    }
    else if (pattern == 3) {
        float cellId = float(boxFolds * 3 + sphereFolds * 7) + floor(orbitTrapDist * 4.0);
        float phase = cellId * 0.7;
        float pulse = sin(gTime * speed * 3.0 + phase);
        pulse = pulse * 0.5 + 0.5;
        float depthBoost = 1.0 - saturate(minRadius / (foldingLimit * 1.5));
        float cellMask = step(threshold, fract(cellId * 0.1234));
        emission = pulse * depthBoost * cellMask;
    }
    else if (pattern == 4) {
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
    texture2d_array<float, access::write> outputTexture [[texture(0)]],
    texture2d_array<float, access::read> prevDepthTexture [[texture(1)]],
    texture2d_array<float, access::write> curDepthTexture [[texture(2)]]
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
    
    // === TEMPORAL REPROJECTION: PER-PIXEL ===
    // Reproject this pixel to previous frame, sample previous depth,
    // and use it as startT to skip most of the fine raymarch.
    // For ~95% of pixels (static or slow-moving), this converts a
    // ~288 inner-loop fine march into a ~30 inner-loop refinement.
    float reprojectedStartT = 0.0;
    bool reprojectionValid = false;
    
    if (uniforms.temporalReprojectionEnabled) {
        // 1. Current pixel → model-space point at unit depth along ray
        //    We reconstruct a model-space point from the current pixel's ray,
        //    then project it through previousViewProjMatrix to find where
        //    it appeared last frame.
        //
        //    Strategy: project cameraPos + rd * testDepth into previous frame's
        //    clip space, look up previous depth at that UV, then use as startT.
        //    Since we don't know the depth yet, we use the previous frame's depth
        //    at the reprojected UV as the starting guess.
        
        // 2. Reconstruct previous-frame UV from current pixel:
        //    Take the current ray direction, build a model-space point at
        //    a reference depth (e.g., 1.0), project through prevVP to get
        //    previous UV. This is approximate but works well for small motions.
        float3 refPoint = cameraPos + rd * 1.0;
        float4 prevClip = uniforms.previousViewProjMatrix * float4(refPoint, 1.0);
        float2 prevNDC = prevClip.xy / prevClip.w;
        float2 prevUV = prevNDC * 0.5 + 0.5;
        prevUV.y = 1.0 - prevUV.y;  // Flip Y (Metal texture convention)
        
        // 3. Check if the reprojected UV is within bounds
        if (prevUV.x >= 0.0 && prevUV.x <= 1.0 && prevUV.y >= 0.0 && prevUV.y <= 1.0) {
            // Sample previous depth at the reprojected location
            uint2 prevPixel = uint2(prevUV * uniforms.resolution);
            prevPixel = clamp(prevPixel, uint2(0), uint2(uniforms.resolution) - 1);
            float prevDepth = prevDepthTexture.read(prevPixel, uniforms.eyeIndex).x;
            
            if (prevDepth > 0.0 && prevDepth < kRayMissThreshold) {
                // 4. Iterative refinement: reproject with the sampled depth
                //    to get a more accurate UV, then re-sample.
                float3 betterPoint = cameraPos + rd * prevDepth;
                float4 betterClip = uniforms.previousViewProjMatrix * float4(betterPoint, 1.0);
                float2 betterNDC = betterClip.xy / betterClip.w;
                float2 betterUV = betterNDC * 0.5 + 0.5;
                betterUV.y = 1.0 - betterUV.y;
                
                if (betterUV.x >= 0.0 && betterUV.x <= 1.0 && betterUV.y >= 0.0 && betterUV.y <= 1.0) {
                    uint2 betterPixel = uint2(betterUV * uniforms.resolution);
                    betterPixel = clamp(betterPixel, uint2(0), uint2(uniforms.resolution) - 1);
                    float refinedDepth = prevDepthTexture.read(betterPixel, uniforms.eyeIndex).x;
                    
                    if (refinedDepth > 0.0 && refinedDepth < kRayMissThreshold) {
                        prevDepth = refinedDepth;
                    }
                }
                
                // 5. Apply safety margin — back up 10% to avoid starting past the surface.
                //    This ensures we never miss geometry that moved slightly closer.
                reprojectedStartT = prevDepth * 0.9;
                reprojectionValid = true;
            }
        }
    }
    
    // === SHARED TILE STATE ===
    threadgroup float tileStartT = 0.05f;
    threadgroup int tileIsEmpty = 0;       // 1 = entire tile missed, skip fine march
    threadgroup half tg_shaSpot = 0.0h;    // Shared spotlight shadow (1 eval per tile)
    threadgroup half tg_shaSun = 0.0h;     // Shared sun shadow (1 eval per tile)

    // === COARSE PASS + EMPTY-SPACE EARLY EXIT ===
    // Thread 0 does a coarse raymarch to find approximate start distance.
    // If the coarse distance is far beyond the tile diagonal, the tile is empty
    // and all 64 threads skip the expensive fine march.
    //
    // OPTIMIZATION: When thread 0 has valid temporal reprojection, skip the
    // coarse pass entirely — we already know the surface is near reprojectedStartT.
    // This saves a 24-step SceneCoarse + 2 MapContinuous probes (~50 Map evals).
    tileIsEmpty = 0;
    if (localIndex == 0) {
        tileIsEmpty = 0;
        
        // === BOUNDING SPHERE TILE EARLY-EXIT (GMT-fractals technique) ===
        // Before coarse raymarching, test the tile-center ray against the bounding sphere.
        // If the bounding sphere is enabled and the center ray misses it, the entire
        // 8x8 tile is guaranteed empty — skip coarse march + probes entirely.
        if (uniforms.boundingSphereRadius > 0.0) {
            float2 tileCenter = float2(tileId * ADAPTIVE_TILE_SIZE) + float2(ADAPTIVE_TILE_SIZE * 0.5);
            float2 tileCenterNDC = (tileCenter / uniforms.resolution) * 2.0 - 1.0;
            tileCenterNDC.y = -tileCenterNDC.y;
            float4 tcClip = float4(tileCenterNDC.x, tileCenterNDC.y, 0.0, 1.0);
            float4 tcView = uniforms.invProjMatrix * tcClip;
            float3 tcRd = normalize((uniforms.invViewMatrix * float4(normalize(tcView.xyz), 0.0)).xyz);
            float bsT = rayIntersectBoundingSphere(marchOrigin, tcRd, float3(0.0), uniforms.boundingSphereRadius);
            if (bsT < 0.0) {
                tileIsEmpty = 1;
                tileStartT = 0.05;
            }
        }
        
        if (!tileIsEmpty) {
        if (reprojectionValid) {
            // Temporal reprojection is valid for thread 0 — surface definitely exists
            // near this depth. Use reprojected depth as tile start, skip coarse+probes.
            tileStartT = max(0.05f, reprojectedStartT * 0.85f);
        } else if (fractalType == 0) {
            FractalParams coarseParams = makeFractalParamsFromPrecomputed(
                uniforms.precomputedFractal,
                uniforms.minDistance,
                marchOrigin, uniforms.safetyBubbleRadius, uniforms.safetyBubbleEnabled, uniforms.safetyBubbleShape);
            float coarseT = SceneCoarse(marchOrigin, marchDir, uniforms.foldingLimit, coarseParams, lodIterations);
            
            if (coarseT >= kRayMissThreshold) {
                // Coarse pass missed — check center of tile for empty-space skip.
                float2 tileCenter = float2(tileId * ADAPTIVE_TILE_SIZE) + float2(ADAPTIVE_TILE_SIZE * 0.5);
                float2 tileCenterNDC = (tileCenter / uniforms.resolution) * 2.0 - 1.0;
                tileCenterNDC.y = -tileCenterNDC.y;
                float4 tcClip = float4(tileCenterNDC.x, tileCenterNDC.y, 0.0, 1.0);
                float4 tcView = uniforms.invProjMatrix * tcClip;
                float3 tcRd = normalize((uniforms.invViewMatrix * float4(normalize(tcView.xyz), 0.0)).xyz);
                
                float probeIters = float(lodIterations) * 0.6;
                float3 probe1 = marchOrigin + tcRd * 2.0;
                float3 probe2 = marchOrigin + tcRd * 6.0;
                float d1 = MapContinuous(probe1, fractalParams, uniforms.foldingLimit, probeIters);
                float d2 = MapContinuous(probe2, fractalParams, uniforms.foldingLimit, probeIters);
                
                float tileAngularSize1 = ADAPTIVE_TILE_SIZE / min(uniforms.resolution.x, uniforms.resolution.y) * 2.0 * 2.0;
                float tileAngularSize2 = ADAPTIVE_TILE_SIZE / min(uniforms.resolution.x, uniforms.resolution.y) * 2.0 * 6.0;
                
                if (d1 > tileAngularSize1 && d2 > tileAngularSize2) {
                    tileIsEmpty = 1;
                }
                tileStartT = 0.05;
            } else {
                tileStartT = coarseT;
            }
        } else {
            tileStartT = 0.05;
            tileIsEmpty = 0;
        }
        } // end if (!tileIsEmpty)
    }

    threadgroup_barrier(mem_flags::mem_threadgroup);
    
    // === EMPTY-SPACE EARLY EXIT ===
    // If the coarse pass determined the tile is empty, write background and return.
    // Saves ALL 64 fine raymarches — huge win for tiles that miss.
    if (tileIsEmpty) {
        // Apply minimal fog/glow for background consistency
        half3 col = half3(0.0h);
        col = applyFog(col, kRayMissThreshold + 100.0, uniforms.fogIntensity);
        col = clampColor(col);
        half2 texCoord = half2(pixelCenter / uniforms.resolution);
        col = PostEffectsWithScheme(col, texCoord, uniforms.colorScheme, half(uniforms.limitFlash), 0.0h);
        outputTexture.write(float4(float3(col), 1.0), pixelCoord, uniforms.eyeIndex);
        // Write miss depth so next frame knows this pixel was empty
        curDepthTexture.write(float4(kRayMissThreshold + 100.0, 0, 0, 0), pixelCoord, uniforms.eyeIndex);
        return;
    }

    // === FINE RAYMARCH WITH TEMPORAL REPROJECTION ===
    // Use the best available startT:
    // - reprojectedStartT from previous frame depth (95% of pixels when camera moves slowly)
    // - tileStartT from coarse pass (fallback for disocclusion/first frame)
    // The temporal start is per-pixel while tileStartT is per-tile, so temporal
    // is strictly better when valid — it places startT within ~10% of the surface.
    float fineStartT = tileStartT;
    if (reprojectionValid && reprojectedStartT > tileStartT) {
        // Temporal reprojection gives us a much tighter start — often within
        // a few steps of the surface. Use it when it's ahead of the coarse result.
        fineStartT = reprojectedStartT;
    }

    SceneResult sceneResult;
    if (fractalType == 0) {
        sceneResult = SceneWithCacheFromStart(marchOrigin, marchDir, fineStartT, pixelCenter, 1.0, maxSteps,
                                              uniforms.glowIntensity, uniforms.foldingLimit, fractalParams, lodIterations, uniforms.time, fractalType, uniforms.stepMultiplier);
    } else {
        sceneResult = SceneWithCache(marchOrigin, marchDir, pixelCenter, 1.0, maxSteps,
                                     uniforms.glowIntensity, uniforms.foldingLimit, fractalParams, lodIterations, uniforms.time, fractalType, uniforms.boundingSphereRadius, uniforms.stepMultiplier);
    }
    
    float adjustedDist = sceneResult.distGlow.x;
    float glow = sceneResult.distGlow.y;
    OrbitCache hitCache = sceneResult.cache;
    half3 col = half3(0.0h);
    
    // Write current frame depth for next frame's temporal reprojection
    float depthToWrite = (adjustedDist < kRayMissThreshold) ? adjustedDist : (kRayMissThreshold + 100.0);
    curDepthTexture.write(float4(depthToWrite, 0, 0, 0), pixelCoord, uniforms.eyeIndex);
    
    if (sceneResult.distGlow.x < kRayMissThreshold) {
        float3 p = marchOrigin + adjustedDist * marchDir;
        
        // GetNormal now uses analytic Jacobian from cache — zero extra Map() calls!
        float3 nor = GetNormal(p, adjustedDist, fractalParams, uniforms.foldingLimit, lodIterations, fractalType, hitCache);
        
        // Use precomputed lighting from CPU with helper function
        float4 spotData = computeSpotlight(p, uniforms.precomputedLighting.spotLightPosition);
        float3 spot = spotData.xyz;
        float atten = spotData.w;
        
        // Blended lighting: classic soft ↔ vibrance-driven sharp
        LightingParams lp = computeBlendedLighting(
            uniforms.colorScheme.vibrance, uniforms.lightingSoftness,
            uniforms.precomputedLighting.lightIntensity);
        float3 sunDir = lp.sunDir;
        float sunDiffuseScale = lp.sunDiffuseScale;
        float lightIntensity = lp.lightIntensity;
        
        const bool shareShadows = is_function_constant_defined(FC_SHARE_SHADOWS)
            ? FC_SHARE_SHADOWS
            : (uniforms.lightingSoftness < 0.9f);
        int shadowIterations = max(lodIterations - 2, 2);
        half shaSpot = 1.0h;
        half shaSun = 1.0h;
        if (shareShadows) {
            // Only thread 0 computes shadows, then broadcasts to all 64 threads
            // via threadgroup memory. Shadow varies slowly over 8x8 pixel tiles,
            // so sharing is visually imperceptible. Saves 63 Shadow() evaluations
            // per tile (~2600+ fewer fractal iteration loops per tile).
            if (localIndex == 0) {
                FractalParams shadowParams = makeFractalParamsFromPrecomputed(
                    uniforms.precomputedFractal,
                    uniforms.minDistance,
                    marchOrigin, uniforms.safetyBubbleRadius, uniforms.safetyBubbleEnabled, uniforms.safetyBubbleShape);
                
                tg_shaSpot = half(Shadow(p, spot, 0.8, uniforms.foldingLimit, shadowParams, shadowIterations, fractalType));
                tg_shaSun = half(Shadow(p, sunDir, 0.8, uniforms.foldingLimit, shadowParams, shadowIterations, fractalType));
            }
            threadgroup_barrier(mem_flags::mem_threadgroup);
            shaSpot = tg_shaSpot;
            shaSun = tg_shaSun;
        } else {
            FractalParams shadowParams = makeFractalParamsFromPrecomputed(
                uniforms.precomputedFractal,
                uniforms.minDistance,
                marchOrigin, uniforms.safetyBubbleRadius, uniforms.safetyBubbleEnabled, uniforms.safetyBubbleShape);
            shaSpot = half(Shadow(p, spot, 0.8, uniforms.foldingLimit, shadowParams, shadowIterations, fractalType));
            shaSun = half(Shadow(p, sunDir, 0.8, uniforms.foldingLimit, shadowParams, shadowIterations, fractalType));
        }
        
        float attenPow = powr(max(atten, kPowEpsilon), kAttenPower);
        half bri = half(max(dot(spot, nor), 0.0) / attenPow * 0.25 * lightIntensity);
        half briSun = half(max(dot(sunDir, nor), 0.0) * sunDiffuseScale);
        
        col = ColourWithScheme(p, adjustedDist, gTime, 1.0, uniforms.minDistance, uniforms.fractalScale, 
                    uniforms.colorMix, uniforms.foldingLimit, uniforms.sphereRadius, int(uniforms.colorIterations), uniforms.colorScheme, hitCache);
        
        // Add ambient term (0.15) to prevent pure black in shadows + hemisphere ambient
        half hemisphereAO = half(nor.y * 0.5 + 0.5); // Simple sky/ground ambient
        half ambient = 0.15h + hemisphereAO * 0.1h;
        col = (col * bri * shaSpot) + (col * briSun * shaSun) + (col * ambient);
        
        // Specular
        float3 ref = reflect(marchDir, nor);
        float specSpot = powr(max(max(dot(spot, ref), 0.0), kPowEpsilon), kSpecularPower) * kSpecularIntensity * lightIntensity;
        float specSun = powr(max(max(dot(sunDir, ref), 0.0), kPowEpsilon), kSpecularPower) * kSpecularIntensity;
        col += half3(specSpot) * shaSpot * bri;
        col += half3(specSun) * shaSun * briSun;
    }
    
    // Apply fog, glow, and clamp using helper functions
    half glowH = half(glow);
    col = applyFog(col, adjustedDist, uniforms.fogIntensity);
    col = applyGlow(col, glowH);
    col = clampColor(col);
    
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
    
    SceneResult sceneResult = SceneWithCache(marchOrigin, marchDir, fragCoord, quality, maxSteps, uniforms.glowIntensity, uniforms.foldingLimit, fractalParams, lodIterations, time, fractalType, uniforms.boundingSphereRadius, uniforms.stepMultiplier);
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
            float4 spotData = computeSpotlight(p, uniforms.precomputedLighting.spotLightPosition);
            float3 spot = spotData.xyz;
            float atten = spotData.w;
            
            // Blended lighting: classic soft ↔ vibrance-driven sharp
            LightingParams lp = computeBlendedLighting(
                uniforms.colorScheme.vibrance, uniforms.lightingSoftness,
                uniforms.precomputedLighting.lightIntensity);
            float3 sunDir = lp.sunDir;
            float sunDiffuseScale = lp.sunDiffuseScale;
            float lightIntensity = lp.lightIntensity;

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
            half briSun = half(max(dot(sunDir, nor), 0.0) * sunDiffuseScale);

            col = ColourWithScheme(p, ret.x, gTime, quality, uniforms.minDistance, uniforms.fractalScale, uniforms.colorMix, uniforms.foldingLimit, uniforms.sphereRadius, max(int(uniforms.colorIterations * quality), 2), uniforms.colorScheme, hitCache);
            
            // Add ambient term to prevent harsh shadows
            half hemisphereAO = half(nor.y * 0.5 + 0.5);
            half ambient = 0.15h + hemisphereAO * 0.1h;
            col = (col * bri * shaSpot) + (col * briSun * shaSun) + (col * ambient);

            if (quality > kMinQualityForSpecular) {
                float3 ref = reflect(marchDir, nor);
                float specSpot = powr(max(max(dot(spot, ref), 0.0), kPowEpsilon), kSpecularPower) * kSpecularIntensity * lightIntensity;
                float specSun = powr(max(max(dot(sunDir, ref), 0.0), kPowEpsilon), kSpecularPower) * kSpecularIntensity;
                col += half3(specSpot) * shaSpot * bri;
                col += half3(specSun) * shaSun * briSun;
            }
            
            // Emissive glow (self-illumination based on cached fold patterns)
            // Use function constant when defined to eliminate this code path entirely
            const bool emissiveEnabled = is_function_constant_defined(FC_EMISSIVE_ENABLED) 
                ? FC_EMISSIVE_ENABLED 
                : (uniforms.emissiveEnabled != 0);
            if (emissiveEnabled) {
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
                    fractalParams,
                    fractalType,
                    hitCache
                );
                col += emissive;
            }
        } else {
            // Blended lighting for low-quality path
            LightingParams lp = computeBlendedLighting(
                uniforms.colorScheme.vibrance, uniforms.lightingSoftness, 1.0f);
            float3 sunDir = lp.sunDir;
            float sunDiffuseScale = lp.sunDiffuseScale;
            // Classic low-quality used: dot * 0.5 + 0.3
            // Current uses: dot * sunDiffuseScale * 2.5 + 0.3
            float diffuseMultiplier = mix(sunDiffuseScale * 2.5f, 0.5f, uniforms.lightingSoftness);
            half diffuse = half(max(dot(nor, sunDir), 0.0) * diffuseMultiplier + 0.3);
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

    // Apply fog, glow, and clamp using helper functions
    half glow = half(ret.y);
    col = applyFog(col, ret.x, uniforms.fogIntensity);
    col = applyGlow(col, glow);
    col = clampColor(col);

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
        // Debug sphere visualization for active gestures
        col = renderDebugSphere(col, float2(in.texCoord), uniforms.activeGesture, uniforms.gestureSpread);
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

    // === QUAD-SHARED COARSE PASS: Leader finds approximate start distance ===
    // Lane 0 does a cheap coarse raymarch, then broadcasts the result.
    // All 4 lanes then do a shorter fine march from that starting point,
    // significantly reducing total Map() evaluations.
    float coarseStartT = 0.05;
    if (fractalType == 0) {
        float leaderCoarseT = 0.05;
        if (quadLaneId == 0) {
            leaderCoarseT = SceneCoarse(marchOrigin, marchDir, uniforms.foldingLimit, fractalParams, lodIterations);
        }
        coarseStartT = quad_broadcast(leaderCoarseT, 0);
    }
    
    SceneResult sceneResult;
    if (coarseStartT < kRayMissThreshold) {
        // Coarse pass found something — start fine march from nearby
        sceneResult = SceneWithCacheFromStart(marchOrigin, marchDir, coarseStartT, fragCoord, 1.0, maxSteps, uniforms.glowIntensity, uniforms.foldingLimit, fractalParams, lodIterations, time, fractalType, uniforms.stepMultiplier);
    } else {
        // Coarse pass missed — full march needed
        sceneResult = SceneWithCache(marchOrigin, marchDir, fragCoord, 1.0, maxSteps, uniforms.glowIntensity, uniforms.foldingLimit, fractalParams, lodIterations, time, fractalType, uniforms.boundingSphereRadius, uniforms.stepMultiplier);
    }
    float2 ret = sceneResult.distGlow;
    OrbitCache hitCache = sceneResult.cache;
    
    float adjustedDist = ret.x;
    float glow = ret.y;
    
    half3 col = half3(0.0h);
    
    if (ret.x < kRayMissThreshold)
    {
        float3 p = marchOrigin + adjustedDist * marchDir;
        
        float3 nor = GetNormal(p, adjustedDist, fractalParams, uniforms.foldingLimit, lodIterations, fractalType, hitCache);
        
        // Quad-shared shadows with optional per-pixel fallback
        const bool shareShadows = is_function_constant_defined(FC_SHARE_SHADOWS)
            ? FC_SHARE_SHADOWS
            : (uniforms.lightingSoftness < 0.9f);
        half shaSpot = 1.0h;
        half shaSun = 1.0h;
        
        int shadowIterations = max(lodIterations - 2, 2);
        FractalParams shadowParams = makeFractalParamsFromPrecomputed(
            uniforms.precomputedFractal,
            uniforms.minDistance,
            marchOrigin, uniforms.safetyBubbleRadius, uniforms.safetyBubbleEnabled, uniforms.safetyBubbleShape);
        
        // Use precomputed lighting from CPU with helper function
        float4 spotData = computeSpotlight(p, uniforms.precomputedLighting.spotLightPosition);
        float3 spot = spotData.xyz;
        float atten = spotData.w;
        
        // Blended lighting: classic soft ↔ vibrance-driven sharp
        LightingParams lp = computeBlendedLighting(
            uniforms.colorScheme.vibrance, uniforms.lightingSoftness,
            uniforms.precomputedLighting.lightIntensity);
        float3 sunDir = lp.sunDir;
        float sunDiffuseScale = lp.sunDiffuseScale;
        float lightIntensity = lp.lightIntensity;
        
        if (shareShadows) {
            if (quadLaneId == 0) {
                shaSpot = half(Shadow(p, spot, 0.8, uniforms.foldingLimit, shadowParams, shadowIterations, fractalType));
                shaSun = half(Shadow(p, sunDir, 0.8, uniforms.foldingLimit, shadowParams, shadowIterations, fractalType));
            }
            shaSpot = quad_broadcast(shaSpot, 0);
            shaSun = quad_broadcast(shaSun, 0);
        } else {
            shaSpot = half(Shadow(p, spot, 0.8, uniforms.foldingLimit, shadowParams, shadowIterations, fractalType));
            shaSun = half(Shadow(p, sunDir, 0.8, uniforms.foldingLimit, shadowParams, shadowIterations, fractalType));
        }
        
        // Per-pixel lighting with shared shadows
        float attenPow = powr(max(atten, kPowEpsilon), kAttenPower);
        half bri = half(max(dot(spot, nor), 0.0) / attenPow * 0.25 * lightIntensity);
        half briSun = half(max(dot(sunDir, nor), 0.0) * sunDiffuseScale);
        
        col = ColourWithScheme(p, adjustedDist, gTime, 1.0, uniforms.minDistance, uniforms.fractalScale, uniforms.colorMix, uniforms.foldingLimit, uniforms.sphereRadius, max(int(uniforms.colorIterations), 2), uniforms.colorScheme, hitCache);
        
        // Add ambient term to prevent harsh shadows
        half hemisphereAO = half(nor.y * 0.5 + 0.5);
        half ambient = 0.15h + hemisphereAO * 0.1h;
        col = (col * bri * shaSpot) + (col * briSun * shaSun) + (col * ambient);
        
        // Specular
        float3 ref = reflect(marchDir, nor);
        float specSpot = powr(max(max(dot(spot, ref), 0.0), kPowEpsilon), kSpecularPower) * kSpecularIntensity * lightIntensity;
        float specSun = powr(max(max(dot(sunDir, ref), 0.0), kPowEpsilon), kSpecularPower) * kSpecularIntensity;
        col += half3(specSpot) * shaSpot * bri;
        col += half3(specSun) * shaSun * briSun;
        
        // Emissive glow (self-illumination based on cached fold patterns)
        // Use function constant when defined to eliminate this code path entirely
        const bool emissiveEnabled = is_function_constant_defined(FC_EMISSIVE_ENABLED) 
            ? FC_EMISSIVE_ENABLED 
            : (uniforms.emissiveEnabled != 0);
        if (emissiveEnabled) {
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
                fractalParams,
                fractalType,
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
    
    // Apply fog, glow, and clamp using helper functions
    half glowH = half(glow);
    col = applyFog(col, adjustedDist, uniforms.fogIntensity);
    col = applyGlow(col, glowH);
    col = clampColor(col);
    
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
