//
//  Shaders.metal
//
// === DEPTH BUFFER NOTES (CRITICAL FOR REPROJECTION/ASW) ===
// visionOS projection outputs z/w in [0, 1] range directly.
// Depth encoding: output.depth = clipPos.z / clipPos.w (no transformation needed)
// Far plane (no hit): output.depth = 1e-7 (tiny value = far away for compositor)
// clearDepth in render passes: 1.0
//
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

// Half-precision Map iteration - 2x throughput on Apple Silicon
// Numerically stable for coarse marching and shadow rays where
// the hit threshold is >0.02 (well within half's ~3 decimal digits)
#define MAP_ITERATION_HALF(p, p0, foldingLimit, scale, sphereRadiusSq, invSphereRadiusSq) \
    p.xyz = fma(clamp(p.xyz, -foldingLimit, foldingLimit), half3(2.0h), -p.xyz); \
    { half r2 = dot(p.xyz, p.xyz); \
      half t = clamp(1.0h / max(r2, sphereRadiusSq), 1.0h, invSphereRadiusSq); \
      p *= t; } \
    p = fma(p, scale, p0)

// Sphere-projection variants: identical to the basic/half iterations, but after
// the sphere fold each point is radially blended toward a fixed-radius sphere.
// This reproduces the "Accidental Sphere Projection" look (see
// Formulas/MandelboxSphereProjection) as an optional layer on the standard
// Mandelbox fast path. The blend/radius come from FractalParams so the decision
// is hoisted OUTSIDE the loop by the caller — the no-projection path is byte-for
// -byte identical to before (zero cost when the option is off).
#define MAP_ITERATION_PROJ(p, p0, foldingLimit, params, invSphereRadiusSq, projBlend, projRadius) \
    p.xyz = fma(clamp(p.xyz, -foldingLimit, foldingLimit), float3(2.0), -p.xyz); \
    { float r2 = dot(p.xyz, p.xyz); \
      float t = clamp(1.0f / max(r2, params.sphereRadiusSq), 1.0f, invSphereRadiusSq); \
      p *= t; } \
    p.xyz = mix(p.xyz, mapProjectToSphere(p.xyz, projRadius), projBlend); \
    p = fma(p, params.scale, p0)

#define MAP_ITERATION_HALF_PROJ(p, p0, foldingLimit, scale, sphereRadiusSq, invSphereRadiusSq, projBlend, projRadius) \
    p.xyz = fma(clamp(p.xyz, -foldingLimit, foldingLimit), half3(2.0h), -p.xyz); \
    { half r2 = dot(p.xyz, p.xyz); \
      half t = clamp(1.0h / max(r2, sphereRadiusSq), 1.0h, invSphereRadiusSq); \
      p *= t; } \
    p.xyz = mix(p.xyz, half3(mapProjectToSphere(float3(p.xyz), projRadius)), half(projBlend)); \
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

// Quality mode - enables aggressive optimizations for lower quality settings
constant int FC_QUALITY_MODE [[function_constant(4)]]; // 0=high, 1=medium, 2=low

// Debug mode - can be compiled out entirely in release builds
constant bool FC_DEBUG_HIERARCHICAL [[function_constant(5)]];

// Max ray marching steps - controls main raymarch loop unrolling
// This is the second most critical loop after Map()
constant int FC_MAX_RAY_STEPS [[function_constant(6)]];

// Devirtualize fractal type dispatch to eliminate unused formulas
constant int FC_FRACTAL_TYPE [[function_constant(7)]];

// Neon color mode toggle - eliminates neon orbit trap computation when disabled
// (neon mode requires extra orbit tracking in ColourWithScheme)
constant bool FC_NEON_MODE_ENABLED [[function_constant(8)]];

// Color iterations - when defined, enables loop unrolling in ColourWithScheme
constant int FC_COLOR_ITERATIONS [[function_constant(9)]];

// Shadow sharing toggle - allows per-pixel shadows when disabled
constant bool FC_SHARE_SHADOWS [[function_constant(10)]];

// Shadow enable toggle - eliminates entire shadow computation when disabled
constant bool FC_SHADOWS_ENABLED [[function_constant(11)]];

// Mandelbulb power - when baked in, the compiler dead-code-eliminates all wrong
// branches in fastPowR and constant-folds power multiplications in the inner loop.
constant int FC_MANDELBULB_POWER [[function_constant(12)]];

// Temporal-depth march warm-start (visionOS fragment path). When unset (Mac,
// screenshot, quad-shared pipelines) the prev-depth texture argument and the
// warm-start code are compiled out entirely.
constant bool FC_WARM_START [[function_constant(13)]];
constant bool FC_WARM_START_ON = is_function_constant_defined(FC_WARM_START) ? FC_WARM_START : false;

// Coherent-packet experiment toggle (adaptiveHierarchical8x8 only). When baked
// false (the default settings state), the warm-start probe, the shadow
// normal-coherence gate, and the layer-of-acceptance debug overlay are all
// dead-code-eliminated. Unset (generic/shared pipelines) falls back to the
// runtime uniform so cache-miss fallbacks stay correct.
constant bool FC_COHERENT_PACKET [[function_constant(14)]];

// Include the fractal formula library (non-Mandelbox DE functions + dispatch)
// Must be after metal_stdlib, ShaderTypes.h, and function constants so that
// formula headers can reference FC_* constants (e.g. FC_MANDELBULB_POWER).
#include "../Formulas/FractalFormulas.h"

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

constant float kPowEpsilon = 1e-6f;
constant half kPowEpsilonHalf = 1e-4h;

// === NAMED CONSTANTS FOR OPTIMIZATION ===
// Raymarching thresholds
constant float kRayMissThreshold = 900.0f;      // Distance indicating ray miss
#define kMaxRayDistanceDefault 12.0f  // Fallback trace distance (macro to silence unused-variable warning)

    // Shading constants (tuned for softer, less harsh lighting)
    constant float kSpecularPower = 50.0f;          // Specular highlight power
    constant float kSpecularIntensity = 2.0f;       // Specular intensity multiplier
    constant float kAttenPower = 1.5f;              // Light attenuation power

// Quality threshold
constant float kMinQualityForShadows = 0.25f;   // Skip shadows below this quality

// Always-on inner glow tint (per-step accumulation contribution).
// Kept cool to avoid muddy yellow shifts when post glow is enabled.
constant half3 kGlowColor = half3(0.07h, 0.11h, 0.20h);

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

// Apply fog based on distance using CPU-precomputed scalars to avoid divides/branches
// fog.fog.x = intensity, fog.fog.y = 1 / intensity (0 when disabled)
FORCE_INLINE half3 applyFog(half3 col, float distance, PrecomputedFog fog) {
    float fogIntensity = fog.fog.x;
    if (fogIntensity <= 0.0001f) { return col; }
    // exp(-distance * fogIntensity * 2.0 + 1.5) = exp(1.5) * exp(-distance * fogIntensity * 2.0)
    // Precomputed: exp(1.5) ≈ 4.4817
    float exponent = fma(distance, -fogIntensity * 2.0f, 1.5f);
    half fogFactor = half(saturate(exp(exponent)));
    return mix(half3(fog.color.xyz), col, fogFactor);
}

// Apply glow contribution from ray steps
FORCE_INLINE half3 applyGlow(half3 col, half glow) {
    return col + glow * glow * kGlowColor;
}

// Clamp color before post-processing
FORCE_INLINE half3 clampColor(half3 col) {
    return clamp(col, half3(0.0h), half3(2.0h));
}

FORCE_INLINE half quantizeCelLight(half value, ColorSchemeParams scheme) {
    if (scheme.cellShadingEnabled == 0) { return value; }
    half levels = half(max(scheme.cellShadingLevels, 2.0f));
    return floor(saturate(value) * levels) / max(levels - 1.0h, 1.0h);
}

FORCE_INLINE float3 sphericalInvertPoint(float3 point, float radius) {
    float radiusSq = radius * radius;
    float distSq = max(dot(point, point), 1e-4f);
    return point * (radiusSq / distSq);
}

// Radially project a folded point onto a sphere of the given radius. Used by the
// optional sphere-projection iteration macros (post-sphere-fold). Mirrors
// projectToSphere() in Formulas/MandelboxSphereProjection.h (named distinctly to
// avoid clashing with that header's definition).
FORCE_INLINE float3 mapProjectToSphere(float3 p, float radius) {
    float len = length(p);
    if (len <= 1e-6f) { return float3(radius, 0.0f, 0.0f); }
    return p * (radius / len);
}

FORCE_INLINE void applySphericalInversionRay(thread float3 &origin, thread float3 &direction, int mode, float radius) {
    if (mode == 0) { return; }
    float safeRadius = max(radius, 0.2f);
    float3 rayTarget = origin + direction * safeRadius;
    float3 invertedOrigin = sphericalInvertPoint(origin, safeRadius);
    float3 invertedTarget = sphericalInvertPoint(rayTarget, safeRadius);
    float3 invertedDirection = invertedTarget - invertedOrigin;
    if (dot(invertedDirection, invertedDirection) > 1e-8f) {
        origin = invertedOrigin;
        direction = normalize(invertedDirection);
    }
}

// === LIGHTING BLEND: Classic (soft) ↔ Current (vibrance-driven sharp) ===
// The vibrance/softness sun blend is frame-uniform, so it is evaluated once
// per frame on the CPU (RenderPrecompute.makePrecomputedLighting — its
// sunDirSoft/sunDirSharp constants MUST mirror the ones above) and arrives
// in uniforms.precomputedLighting as sunDir / sunDiffuseScale /
// lightIntensity (pre-scaled) / specPower.

// === BOUNDING SPHERE EARLY EXIT ===
// Returns -1 if ray misses sphere, otherwise the distance to start marching.
// This is a "skip empty space before the volume" optimization, so:
//   - Origin outside, ray hits sphere → near-entry distance.
//   - Origin INSIDE the sphere (zoomed in) → 0: there is no empty space to
//     skip, so we must start at the camera. Returning the far intersection
//     here would skip all geometry between the camera and the back wall,
//     punching a growing hole in the center as you zoom in.
inline float rayIntersectBoundingSphere(float3 ro, float3 rd, float3 center, float radius) {
    float3 oc = ro - center;
    float c = dot(oc, oc) - radius * radius;
    if (c < 0.0) return 0.0;  // Origin inside sphere — start marching immediately
    float b = dot(oc, rd);
    float discriminant = b * b - c;
    if (discriminant < 0.0) return -1.0;  // Miss
    float t = -b - sqrt(discriminant);  // Near intersection
    return (t > 0.0) ? t : -1.0;  // Behind the camera → treat as miss
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
    float3 bubbleCenter;
    float bubbleRadius;
    int bubbleEnabled;
    float bubbleShape;      // 0 = sphere, 1 = cube, intermediate = morph
    int bubbleFadeEnabled;  // Enable smooth fade transition
    float bubbleFadeWidth;  // Width of fade region beyond inner radius
    float bubbleStrength;   // Temporal fade (0=off, 1=fully active)
    float sphereProjBlend;  // 0 = off; >0 blends post-fold radial sphere projection (Mandelbox path)
    float sphereProjRadius; // Target radius for the post-fold sphere projection
};

FORCE_INLINE float safetyBubbleCubeDistance(float3 p, float bubbleRadius) {
    float3 d = abs(p) - float3(bubbleRadius);
    return length(max(d, 0.0)) + min(max(d.x, max(d.y, d.z)), 0.0);
}

FORCE_INLINE float safetyBubbleTetrahedralDistance(float3 p, float bubbleRadius) {
    constexpr float invSqrt3 = 0.5773502691896258f;
    // Keep axis extent aligned with bubbleRadius, matching sphere/cube behavior.
    float faceOffset = bubbleRadius * invSqrt3;
    float d1 = dot(p, float3( invSqrt3,  invSqrt3,  invSqrt3));
    float d2 = dot(p, float3( invSqrt3, -invSqrt3, -invSqrt3));
    float d3 = dot(p, float3(-invSqrt3,  invSqrt3, -invSqrt3));
    float d4 = dot(p, float3(-invSqrt3, -invSqrt3,  invSqrt3));
    return max(max(d1, d2), max(d3, d4)) - faceOffset;
}

FORCE_INLINE float safetyBubbleNegativeCubeDistance(float3 p, float bubbleRadius) {
    constexpr float exponent = 0.65f;
    float3 q = abs(p) / max(bubbleRadius, 1e-4f);
    float superDistance = pow(pow(q.x, exponent) + pow(q.y, exponent) + pow(q.z, exponent), 1.0f / exponent);
    return (superDistance - 1.0f) * bubbleRadius;
}

FORCE_INLINE float safetyBubbleOctahedronDistance(float3 p, float bubbleRadius) {
    float3 q = abs(p);
    return (q.x + q.y + q.z - bubbleRadius) * 0.5773502691896258f;
}

FORCE_INLINE float safetyBubbleIcosahedronDistance(float3 p, float bubbleRadius) {
    constexpr float phi = 1.618033988749895f;
    constexpr float invPhiLen = 0.5257311121191336f;
    constexpr float invTriLen = 0.5773502691896258f;
    constexpr float axisScale = 0.85065080835204f;
    float3 q = abs(p);
    // Icosahedron: 20 planes (8 from (1,1,1), 12 from golden-ratio families).
    float d1 = dot(q, float3(1.0f, 1.0f, 1.0f) * invTriLen);
    float d2 = dot(q, float3(0.0f, 1.0f, phi) * invPhiLen);
    float d3 = dot(q, float3(1.0f, phi, 0.0f) * invPhiLen);
    float d4 = dot(q, float3(phi, 0.0f, 1.0f) * invPhiLen);
    return max(max(d1, d2), max(d3, d4)) - bubbleRadius * axisScale;
}

FORCE_INLINE float safetyBubbleDodecahedronDistance(float3 p, float bubbleRadius) {
    constexpr float phi = 1.618033988749895f;
    constexpr float invPhiLen = 0.5257311121191336f;
    constexpr float axisScale = 0.85065080835204f;
    float3 q = abs(p);
    // Dodecahedron: 12 planes from icosahedral normal families.
    float d1 = dot(q, float3(phi, 1.0f, 0.0f) * invPhiLen);
    float d2 = dot(q, float3(1.0f, 0.0f, phi) * invPhiLen);
    float d3 = dot(q, float3(0.0f, phi, 1.0f) * invPhiLen);
    return max(d1, max(d2, d3)) - bubbleRadius * axisScale;
}

// === SAFETY BUBBLE DISTANCE FUNCTION ===
// Uses the legacy sphere/cube morph for values in 0...1 and discrete solids above that.
// The bubble stays axis-aligned and only translates with the viewer position.
FORCE_INLINE float safetyBubbleDistance(float3 pos, float3 bubbleCenter, float bubbleRadius, float bubbleShape) {
    float3 p = pos - bubbleCenter;
    
    // Sphere distance (signed, negative inside)
    float sphereDist = length(p) - bubbleRadius;
    
    // Axis-aligned cube distance (Chebyshev distance - max of absolute components)
    // No rotation - cube stays aligned with world axes for stable visual reference
    float cubeDist = safetyBubbleCubeDistance(p, bubbleRadius);
    
    if (bubbleShape <= 1.0f) {
        return mix(sphereDist, cubeDist, clamp(bubbleShape, 0.0f, 1.0f));
    }

    int discreteShape = int(clamp(bubbleShape + 0.5f, 2.0f, 6.0f));
    switch (discreteShape) {
        case 2:
            return safetyBubbleTetrahedralDistance(p, bubbleRadius);
        case 3:
            return safetyBubbleNegativeCubeDistance(p, bubbleRadius);
        case 4:
            return safetyBubbleOctahedronDistance(p, bubbleRadius);
        case 5:
            return safetyBubbleIcosahedronDistance(p, bubbleRadius);
        case 6:
            return safetyBubbleDodecahedronDistance(p, bubbleRadius);
        default:
            return cubeDist;
    }
}

// === SAFETY BUBBLE CSG APPLICATION ===
// Applies safety bubble as CSG subtraction with optional smooth fade.
// Hard mode:  d = max(d, -bubbleDist)  — sharp edge at bubble boundary
// Faded mode: smooth polynomial max for gradual geometry transition
//   Inner radius: geometry fully carved out (safe zone)
//   Outer radius (inner + fadeWidth): geometry fully visible
//   Between: smooth blend using polynomial smooth-max
FORCE_INLINE float applySafetyBubble(float d, float3 pos, FractalParams params) {
    const bool bubbleEnabled = is_function_constant_defined(FC_SAFETY_BUBBLE_ENABLED)
        ? FC_SAFETY_BUBBLE_ENABLED : (params.bubbleEnabled != 0);
    if (!bubbleEnabled) return d;
    // Temporal fade: skip work when strength is near zero
    if (params.bubbleStrength < 0.001f) return d;

    float bubbleDist = safetyBubbleDistance(pos, params.bubbleCenter, params.bubbleRadius, params.bubbleShape);

    float dBubbled;
    if (params.bubbleFadeEnabled != 0 && params.bubbleFadeWidth > 0.001f) {
        // Smooth polynomial max: smax(d, -bubbleDist, k)
        // k = fadeWidth controls transition zone width
        float a = d;
        float b = -bubbleDist;
        float k = params.bubbleFadeWidth;
        float h = saturate(0.5f + 0.5f * (b - a) / k);
        dBubbled = mix(a, b, h) + k * h * (1.0f - h);
    } else {
        // Hard edge: standard CSG subtraction
        dBubbled = max(d, -bubbleDist);
    }
    // OPTIMIZATION: When strength is at full (blend slider = 100%), skip the temporal
    // blend entirely. Since bubbleStrength comes from a uniform buffer, ALL GPU threads
    // take the same branch — no divergence cost. Saves the mix in the hottest path
    // (Map is called 50-100+ times per pixel per eye at 90Hz).
    if (params.bubbleStrength >= 1.0f) return dBubbled;
    // Temporal blend: lerp between original and bubble-applied distance
    // When strength < 1, the bubble partially fades in via the configured fade strength
    return mix(d, dBubbled, params.bubbleStrength);
}

// OPTIMIZED: Use precomputed values from CPU to avoid per-pixel powr() and division
// This version is preferred when PrecomputedFractalParams is available in uniforms
FORCE_INLINE FractalParams makeFractalParamsFromPrecomputed(
    PrecomputedFractalParams precomputed,
    float minRad2Val,
    float3 bubbleCenter, float bubbleRadius, int bubbleEnabled, float bubbleShape,
    int bubbleFadeEnabled, float bubbleFadeWidth, float bubbleStrength,
    float sphereProjBlend = 0.0f, float sphereProjRadius = 1.0f)
{
    FractalParams params;
    // Use precomputed values (expensive powr() and divisions done on CPU)
    params.scale = precomputed.scale;
    params.absScalem1 = precomputed.absScalem1;
    params.absScalePow = precomputed.absScalePow;
    params.sphereRadiusSq = precomputed.sphereRadiusSq;
    params.bubbleCenter = bubbleCenter;
    params.bubbleRadius = bubbleRadius;
    params.bubbleEnabled = bubbleEnabled;
    params.bubbleShape = bubbleShape;
    params.bubbleFadeEnabled = bubbleFadeEnabled;
    params.bubbleFadeWidth = bubbleFadeWidth;
    params.bubbleStrength = bubbleStrength;
    params.sphereProjBlend = sphereProjBlend;
    params.sphereProjRadius = sphereProjRadius;
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

    if (params.sphereProjBlend > 0.0f) {
        for (int i = 0; i < loopCount; i++) {
            MAP_ITERATION_PROJ(p, p0, foldingLimit, params, invSphereRadiusSq, params.sphereProjBlend, params.sphereProjRadius);
        }
    } else {
        for (int i = 0; i < loopCount; i++) {
            MAP_ITERATION_BASIC(p, p0, foldingLimit, params, invSphereRadiusSq);
        }
    }
    
    // Final distance estimate
    float d = (length(p.xyz) - params.absScalem1) / p.w - params.absScalePow;
    
    // Safety bubble: carve out a shape around the camera to prevent clipping
    d = applySafetyBubble(d, pos, params);
    return d;
}
// =============================================================================
// GEOMETRY-ONLY DISTANCE ESTIMATOR (Inspired by GMT-fractals DE_Dist())
// =============================================================================
// Stripped-down Map variant for shadows, AO, and normal fallback paths.
// Removes ALL tracking: no trap, no trapIter, no trapPos, no Jacobian.
// Just pure box fold → sphere fold → scale, returning distance.
// This saves ~6 extra ops per iteration vs the full tracking variant.
FORCE_INLINE float MapDistOnly(float3 pos, FractalParams params, float foldingLimit, int iterations)
{
    float4 p = float4(pos, 1.0);
    float4 p0 = p;
    
    float invSphereRadiusSq = 1.0f / params.sphereRadiusSq;
    
    const int loopCount = is_function_constant_defined(FC_SHADOW_ITERATIONS) ? FC_SHADOW_ITERATIONS : iterations;
    
    if (params.sphereProjBlend > 0.0f) {
        for (int i = 0; i < loopCount; i++) {
            MAP_ITERATION_PROJ(p, p0, foldingLimit, params, invSphereRadiusSq, params.sphereProjBlend, params.sphereProjRadius);
        }
    } else {
        for (int i = 0; i < loopCount; i++) {
            MAP_ITERATION_BASIC(p, p0, foldingLimit, params, invSphereRadiusSq);
        }
    }
    
    float d = (length(p.xyz) - params.absScalem1) / p.w - params.absScalePow;
    
    // Safety bubble check (compile-time eliminated when disabled)
    d = applySafetyBubble(d, pos, params);
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
// Runs the fold iteration in half precision since this is only used in
// coarse passes where distance thresholds are large.

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
    // Coarse pass must mirror the fine Map's sphere projection, else the
    // over-relaxed marcher seeds startT from the un-projected (box) silhouette
    // and tunnels through the projected surface.
    bool useProj = params.sphereProjBlend > 0.0f;
    half hProjBlend = half(params.sphereProjBlend);
    half hProjRadius = half(params.sphereProjRadius);

    // Run floor(N) iterations
    if (useProj) {
        for (int i = 0; i < itersFloor; i++) {
            MAP_ITERATION_HALF_PROJ(p, p0, hFold, hScale, hSphRSq, hInvSphRSq, hProjBlend, hProjRadius);
        }
    } else {
        for (int i = 0; i < itersFloor; i++) {
            MAP_ITERATION_HALF(p, p0, hFold, hScale, hSphRSq, hInvSphRSq);
        }
    }
    
    // Distance after floor(N) iterations
    float dFloor = (length(float3(p.xyz)) - params.absScalem1) / float(p.w) - params.absScalePow;
    
    // If fractional part is negligible, skip the extra iteration
    if (frac < 0.01f) {
        dFloor = applySafetyBubble(dFloor, pos, params);
        return dFloor;
    }
    
    // Run one more iteration for ceil(N)
    if (useProj) {
        MAP_ITERATION_HALF_PROJ(p, p0, hFold, hScale, hSphRSq, hInvSphRSq, hProjBlend, hProjRadius);
    } else {
        MAP_ITERATION_HALF(p, p0, hFold, hScale, hSphRSq, hInvSphRSq);
    }
    float dCeil = (length(float3(p.xyz)) - params.absScalem1) / float(p.w) - params.absScalePow;
    
    // Smooth interpolation between floor and ceil distance estimates
    float d = mix(dFloor, dCeil, frac);
    
    d = applySafetyBubble(d, pos, params);
    return d;
}

// =============================================================================
// UNIFIED FRACTAL DISPATCH — routes to Mandelbox or formula DE
// =============================================================================
// The branching strategy is zero-overhead for Mandelbox:
//   fractalType == 0 compiles to a perfectly-predicted branch (Mandelbox fast path)
//   fractalType != 0 dispatches through FractalDE_Dispatch (Formulas/FractalFormulas.h)
// Safety bubble is now applied to ALL fractal types via applySafetyBubble().

FORCE_INLINE float MapUnified(float3 pos, FractalParams params, float foldingLimit,
                               int iterations, int fractalType, FormulaParams fp) {
    int type = is_function_constant_defined(FC_FRACTAL_TYPE) ? FC_FRACTAL_TYPE : fractalType;
    if (type == FractalTypeMandelbox) {
        return Map(pos, params, foldingLimit, iterations);  // bubble applied inside Map()
    }
    int loopCount = is_function_constant_defined(FC_FRACTAL_ITERATIONS) ? FC_FRACTAL_ITERATIONS : iterations;
    float d = FractalDE_Dispatch(pos, type, fp, loopCount);
    return applySafetyBubble(d, pos, params);
}

FORCE_INLINE float MapDistOnlyUnified(float3 pos, FractalParams params, float foldingLimit,
                                       int iterations, int fractalType, FormulaParams fp) {
    int type = is_function_constant_defined(FC_FRACTAL_TYPE) ? FC_FRACTAL_TYPE : fractalType;
    if (type == FractalTypeMandelbox) {
        return MapDistOnly(pos, params, foldingLimit, iterations);  // bubble applied inside
    }
    int loopCount = is_function_constant_defined(FC_SHADOW_ITERATIONS) ? FC_SHADOW_ITERATIONS : iterations;
    float d = FractalDE_Dispatch(pos, type, fp, loopCount);
    return applySafetyBubble(d, pos, params);
}

FORCE_INLINE float MapContinuousUnified(float3 pos, FractalParams params, float foldingLimit,
                                         float fractionalIterations, int fractalType, FormulaParams fp) {
    int type = is_function_constant_defined(FC_FRACTAL_TYPE) ? FC_FRACTAL_TYPE : fractalType;
    if (type == FractalTypeMandelbox) {
        return MapContinuous(pos, params, foldingLimit, fractionalIterations);  // bubble applied inside
    }
    // Formula DEs do not support Mandelbox-style fractional interpolation yet.
    // For Mandelbulb/MandelbulbJulia, rounding up keeps the coarse pass
    // conservative and avoids underestimating surface complexity near the front shell.
    bool isMB = (type == FractalTypeMandelbulb || type == FractalTypeMandelbulbJulia);
    int loopCount = max(isMB
                        ? int(ceil(fractionalIterations))
                        : int(fractionalIterations), 1);
    float d = FractalDE_Dispatch(pos, type, fp, loopCount);
    return applySafetyBubble(d, pos, params);
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
// Generates procedural neon colors from hue frequency/offset (no palette needed)
FORCE_INLINE half3 applyNeonColorScheme(half trapMin, half trapIter, half trapAngle, ColorSchemeParams scheme)
{
    half d = saturate(trapMin);
    half it = saturate(trapIter);
    
    // Brightness: sharp glow falloff from trap surface
    half glow = pow(1.0h - d, half(scheme.glowSharpness));
    
    // Generate neon colors procedurally from hue cycling
    half colorPhase = fract(it * half(scheme.hueFrequency) * 0.5h + half(scheme.hueOffset));
    
    // Convert hue phase to RGB via HSV (saturation=1, value=1)
    half hue = colorPhase * 6.0h;
    half x = 1.0h - abs(fmod(hue, 2.0h) - 1.0h);
    half3 baseColor;
    if (hue < 1.0h)      baseColor = half3(1.0h, x, 0.0h);
    else if (hue < 2.0h) baseColor = half3(x, 1.0h, 0.0h);
    else if (hue < 3.0h) baseColor = half3(0.0h, 1.0h, x);
    else if (hue < 4.0h) baseColor = half3(0.0h, x, 1.0h);
    else if (hue < 5.0h) baseColor = half3(x, 0.0h, 1.0h);
    else                  baseColor = half3(1.0h, 0.0h, x);
    
    // Optional soft banding - branchless multiply
    half bandActive = step(0.1h, half(scheme.bandFrequency));
    half band = sin(d * half(scheme.bandFrequency) * 3.14159h);
    half bandEffect = 1.0h - bandActive * 0.2h * (1.0h - band * band);
    
    // Saturation boost for neon effect
    half sat = pow(0.9h, half(scheme.saturationPower));
    
    // Final color: base color * glow * banding
    half3 rgb = baseColor * glow * bandEffect;
    
    // Boost saturation by pushing away from gray
    half luma = dot(rgb, half3(0.299h, 0.587h, 0.114h));
    rgb = mix(half3(luma), rgb, 1.0h + sat);
    
    return saturate(rgb);
}

// =============================================================================
// ADDITIONAL COLOR SCHEME FUNCTIONS
// =============================================================================

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
half3 ColourWithScheme(float3 pos, float quality, float minRad2Val, float fractalScale, float foldingLimit, float sphereRadius, int colorIters, ColorSchemeParams scheme, OrbitCache cache = {})
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
    if (scheme.gradientStopCount > 0) {
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
    
    // Fallback: no gradient stops available — return white
    return half3(1.0h);
}

// === MapWithOrbitCache ===
//
// Lean orbit tracking: Jacobian + trap values (normals + colors).
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

    // Sphere projection alters the fold result, so the analytic Jacobian below no
    // longer matches the (projected) distance field. When it's active we run a
    // projection-aware loop without Jacobian accumulation and flag the cache so
    // GetNormal falls back to finite differences over THIS now-projected map —
    // keeping normals/colors consistent with the rendered silhouette. The
    // no-projection path is byte-for-byte unchanged (same Jacobian, zero cost).
    bool useProj = params.sphereProjBlend > 0.0f;
    if (useProj) {
        float projBlend = params.sphereProjBlend;
        float projRadius = params.sphereProjRadius;
        for (int i = 0; i < loopCount; i++) {
            p.xyz = fma(clamp(p.xyz, -foldingLimit, foldingLimit), float3(2.0), -p.xyz);
            float r2 = dot(p.xyz, p.xyz);
            if (r2 < trap) { trap = r2; trapIter = i; trapPos = p.xyz; }
            float t = clamp(1.0f / max(r2, params.sphereRadiusSq), 1.0f, invSphereRadiusSq);
            p *= t;
            p.xyz = mix(p.xyz, mapProjectToSphere(p.xyz, projRadius), projBlend);
            p = fma(p, params.scale, p0);
        }
    } else {
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
    }

    float d = (length(p.xyz) - params.absScalem1) / p.w - params.absScalePow;

    d = applySafetyBubble(d, pos, params);

    cache.p = p;
    cache.trap = trap;
    cache.distance = d;
    cache.iterationsUsed = loopCount;
    cache.valid = true;
    cache.trapIteration = trapIter;
    cache.trapPosition = trapPos;
    cache.jacobian = J;
    cache.hasJacobian = !useProj;
    
    return d;
}

// Unified orbit-tracking dispatch: Mandelbox uses MapWithOrbitCache (with Jacobian),
// non-Mandelbox uses FractalDE_WithOrbit and populates the OrbitCache from OrbitData.
FORCE_INLINE float MapWithOrbitCacheUnified(float3 pos, FractalParams params, float foldingLimit,
                                             int iterations, int fractalType, FormulaParams fp,
                                             int colorIterations, thread OrbitCache& cache) {
    int type = is_function_constant_defined(FC_FRACTAL_TYPE) ? FC_FRACTAL_TYPE : fractalType;
    if (type == FractalTypeMandelbox) {
        return MapWithOrbitCache(pos, params, foldingLimit, iterations, cache);
    }
    
    // Non-Mandelbox: use formula orbit tracking
    OrbitData orbit;
    float d = FractalDE_WithOrbit(pos, type, fp, iterations, colorIterations, orbit);
    
    // Apply safety bubble to non-Mandelbox fractals
    d = applySafetyBubble(d, pos, params);
    
    // Populate OrbitCache from OrbitData for compatibility with coloring/normals
    cache.p = float4(orbit.finalP, 1.0f);
    cache.trap = orbit.trap;
    cache.distance = d;
    cache.iterationsUsed = orbit.iterationsUsed;
    cache.valid = true;
    cache.trapIteration = orbit.trapIteration;
    cache.trapPosition = orbit.trapPosition;
    // No analytic Jacobian for formula types — normals will use finite differences
    cache.jacobian = float3x3(1.0f);
    cache.hasJacobian = false;
    
    return d;
}

FORCE_INLINE int ReducedSecondaryIterations(int iterations, int fractalType, bool forShadow = false)
{
    int type = is_function_constant_defined(FC_FRACTAL_TYPE) ? FC_FRACTAL_TYPE : fractalType;
    if (type == FractalTypeMandelbulb || type == FractalTypeMandelbulbJulia) {
        return max(forShadow ? ((iterations + 2) / 3) : ((iterations + 1) / 3), 2);
    }
    return max((iterations * 2) / 5, 3);
}

FORCE_INLINE float3 ApproximateMandelbulbNormal(float3 pos, float distance, FractalParams params,
                                                float foldingLimit, int iterations, FormulaParams fp,
                                                float cachedDistance, OrbitCache cache)
{
    float3 escapeDir = cache.p.xyz;
    float escapeLen2 = dot(escapeDir, escapeDir);
    if (escapeLen2 <= 1e-8f) {
        escapeDir = pos;
        escapeLen2 = dot(escapeDir, escapeDir);
    }

    float3 baseNormal = (escapeLen2 > 1e-8f)
        ? escapeDir * rsqrt(escapeLen2)
        : float3(0.0f, 1.0f, 0.0f);

    float3 upAxis = (abs(baseNormal.y) < 0.92f) ? float3(0.0f, 1.0f, 0.0f) : float3(1.0f, 0.0f, 0.0f);
    float3 tangentX = cross(upAxis, baseNormal);
    tangentX *= rsqrt(dot(tangentX, tangentX) + kPowEpsilon);
    float3 tangentY = cross(baseNormal, tangentX);

    int normalIters = ReducedSecondaryIterations(iterations, FractalTypeMandelbulb, false);
    float e = max(distance * 0.00075f, 0.00012f);
    float invE = 1.0f / max(e, kPowEpsilon);

    float dX = MapUnified(pos + tangentX * e, params, foldingLimit, normalIters, FractalTypeMandelbulb, fp);
    float dY = MapUnified(pos + tangentY * e, params, foldingLimit, normalIters, FractalTypeMandelbulb, fp);

    float3 gradient = baseNormal;
    gradient += tangentX * ((dX - cachedDistance) * invE * 0.35f);
    gradient += tangentY * ((dY - cachedDistance) * invE * 0.35f);
    return gradient * rsqrt(dot(gradient, gradient) + kPowEpsilon);
}

// Compute normal using cached orbit state
// Three paths, in priority order:
//   1. Analytic Jacobian (cache.hasJacobian) — ZERO extra Map() calls
//      Normal = normalize(J^T * normalize(p.xyz))
//      where J = dF/dp0 accumulated during MapWithOrbitCache iteration
//   2. Cached center distance — 3 extra Map() calls with reduced iterations
//   3. Standard finite differences — 4 Map() calls with full iterations
FORCE_INLINE float3 GetNormal(float3 pos, float distance, FractalParams params, float foldingLimit, int iterations, int fractalType, FormulaParams fp = {}, OrbitCache cache = {})
{
    int type = is_function_constant_defined(FC_FRACTAL_TYPE) ? FC_FRACTAL_TYPE : fractalType;

    if (cache.hasJacobian && type == FractalTypeMandelbox) {
        // === ANALYTIC JACOBIAN PATH — no extra Map() calls ===
        float3 pDir = cache.p.xyz * rsqrt(dot(cache.p.xyz, cache.p.xyz) + kPowEpsilon);
        float3 gradient = float3(
            dot(cache.jacobian[0], pDir),
            dot(cache.jacobian[1], pDir),
            dot(cache.jacobian[2], pDir)
        );
        return gradient * rsqrt(dot(gradient, gradient) + kPowEpsilon);
    } else if ((type == FractalTypeMandelbulb || type == FractalTypeMandelbulbJulia) && cache.valid) {
        // Mandelbulb-specific fast path: use cached escape direction as the base
        // normal and refine it with only two tangent-space DE probes.
        return ApproximateMandelbulbNormal(pos, distance, params, foldingLimit, iterations, fp, cache.distance, cache);
    } else if (cache.valid && type == FractalTypeMandelbox) {
        // Fallback: use cached center distance, reduced iterations
        int normalIters = ReducedSecondaryIterations(iterations, type, false);
        float e = max(distance * 0.0005f, 0.0001f);
        float d0 = cache.distance;
        
        OrbitCache dummy;
        float dx = MapWithOrbitCache(pos + float3(e, 0, 0), params, foldingLimit, normalIters, dummy);
        float dy = MapWithOrbitCache(pos + float3(0, e, 0), params, foldingLimit, normalIters, dummy);
        float dz = MapWithOrbitCache(pos + float3(0, 0, e), params, foldingLimit, normalIters, dummy);
        
        float3 gradient = float3(dx - d0, dy - d0, dz - d0);
        return gradient * rsqrt(dot(gradient, gradient) + kPowEpsilon);
    } else if (type != FractalTypeMandelbox && cache.valid) {
        // Non-Mandelbox with cached center distance: 3 lean _Dist calls
        // with reduced iterations (40% of full).  The cache already holds
        // the center DE from the hit evaluation — reuse it.
        int normalIters = ReducedSecondaryIterations(iterations, type, false);
        float e = max(distance * 0.0005f, 0.0001f);
        float d0 = cache.distance;
        float3 gradient = float3(
            FractalDE_Dispatch(pos + float3(e,0,0), type, fp, normalIters) - d0,
            FractalDE_Dispatch(pos + float3(0,e,0), type, fp, normalIters) - d0,
            FractalDE_Dispatch(pos + float3(0,0,e), type, fp, normalIters) - d0
        );
        return gradient * rsqrt(dot(gradient, gradient) + kPowEpsilon);
    } else {
        // Fallback: 4 Map calls with full iterations
        float e = distance * 0.001;
        float d = MapUnified(pos, params, foldingLimit, iterations, type, fp);
        float3 gradient = float3(
            MapUnified(pos + float3(e,0,0), params, foldingLimit, iterations, type, fp) - d,
            MapUnified(pos + float3(0,e,0), params, foldingLimit, iterations, type, fp) - d,
            MapUnified(pos + float3(0,0,e), params, foldingLimit, iterations, type, fp) - d
        );
        return gradient * rsqrt(dot(gradient, gradient) + kPowEpsilon);
    }
}

// Near-range coarse raymarch (24 steps, max 12 units)
// Compiler unrolls based on FC_FRACTAL_ITERATIONS when defined
FORCE_INLINE float SceneCoarse(float3 rO, float3 rD, float foldingLimit, FractalParams params, int iterations, int fractalType = 0, FormulaParams fp = {}, float maxRayDistance = kMaxRayDistanceDefault)
{
    int type = is_function_constant_defined(FC_FRACTAL_TYPE) ? FC_FRACTAL_TYPE : fractalType;
    bool isMandelbulb = (type == FractalTypeMandelbulb || type == FractalTypeMandelbulbJulia);

    // Mandelbulb DE returns much smaller values near the surface; start closer
    // and use a finer hit threshold to avoid overshooting the thin front face.
    float t = isMandelbulb ? 0.005f : 0.05f;
    float hitThreshold = isMandelbulb ? 0.005f : 0.02f;
    int maxCoarseSteps = isMandelbulb ? 28 : 24;
    
    // Use MapContinuous with 0.6× iterations for smooth fractional DE.
    // This preserves thin features better than integer iterations/2 because
    // the continuous interpolation avoids the discontinuity that causes
    // the coarse pass to "jump over" fine structures.
    // The 0.6× factor balances speed (fewer iterations) vs. accuracy.
    float coarseIters = float(iterations) * 0.6f;
    
    for(int j = 0; j < maxCoarseSteps && t <= maxRayDistance; j++)
    {
        float3 p = fma(rD, float3(t), rO);
        float h = MapContinuousUnified(p, params, foldingLimit, coarseIters, fractalType, fp);
        
        if(UNLIKELY(h < hitThreshold)) return t;
        
        t += h;
    }
    
    return kRayMissThreshold + 100.0f;
}

// Cached scene result - stores orbit state for reuse in normals/colors
struct SceneResult {
    float2 distGlow;    // .x = distance, .y = glow
    OrbitCache cache;   // Cached orbit state from final hit position
};

// One step of relaxed sphere tracing (Keinert et al.). Returns true when the
// previous over-relaxed step overshot (consecutive unbounding spheres no
// longer overlap): stepLen turns negative to retreat inside the last safe
// sphere and omega drops to 1 for the rest of the ray. On a normal step,
// advances stepLen to h·omega. The caller must skip hit registration on a
// failed step — the sample sits past a possibly-skipped gap.
FORCE_INLINE bool relaxedStepUpdate(float h,
                                    thread float& omega,
                                    thread float& prevH,
                                    thread float& stepLen)
{
    bool sorFail = omega > 1.0f && (h + prevH) < stepLen;
    if (UNLIKELY(sorFail)) {
        stepLen -= omega * stepLen;
        omega = 1.0f;
    } else {
        stepLen = h * omega;
    }
    prevH = h;
    return sorFail;
}

// Per-type over-relaxation ceiling. Over-stepping is only provably safe when
// the DE is a true lower bound: box/sphere-fold estimators qualify, but the
// log-DE types (Mandelbulb / Julia variants) and the fudge-factored Kleinian
// family can locally OVERESTIMATE, where the overstep-failure test cannot
// fire and rays tunnel through thin features. Custom .threshfx DEs are
// arbitrary user code, so they keep the pre-detection 1.2 ceiling that
// existing shared scenes were authored against. With FC_FRACTAL_TYPE set the
// switch folds to a constant at pipeline-compile time.
FORCE_INLINE float relaxedOmegaCap(int type) {
    switch (type) {
    case FractalTypeMandelbox:
    case FractalTypeMenger:
    case FractalTypeOctahedron:
    case FractalTypeMengerSphere:
    case FractalTypeBoxSphereFolder:
    case FractalTypeMandelboxSphereProjection:
        return 1.4f;
    case FractalTypeMandelbulb:
    case FractalTypeMandelbulbJulia:
    case FractalTypeQuaternionJulia:
        return 1.1f;
    default: // Kleinian family, custom formulas, future types
        return 1.2f;
    }
}

// Raymarch that caches orbit state on hit for reuse in normals/colors
FORCE_INLINE SceneResult SceneWithCache(float3 rO, float3 rD, float2 fragCoord, float quality, int maxStepsParam, float glowIntensity, float foldingLimit, FractalParams params, int iterations, float time, int fractalType = 0, FormulaParams fp = {}, int colorIterations = 0, float boundingSphereRadius = 0.0, float stepMultiplier = 1.0, float maxRayDistance = kMaxRayDistanceDefault)
{
    SceneResult result;
    result.cache = makeEmptyOrbitCache();
    int type = is_function_constant_defined(FC_FRACTAL_TYPE) ? FC_FRACTAL_TYPE : fractalType;
    
    float dither = interleavedGradientNoise(fragCoord, time) * 0.015;
    // Mandelbulb DE returns much smaller values near the surface compared to
    // box-fold fractals.  Start closer to the camera and use a finer hit
    // threshold so thin surface detail is not clipped.
    bool isMandelbulb = (type == FractalTypeMandelbulb || type == FractalTypeMandelbulbJulia);
    float t = (isMandelbulb ? 0.005 : 0.05) + dither;
    
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

    // === RELAXED SPHERE TRACING (Keinert et al., "Enhanced Sphere Tracing") ===
    // Take omega× over-relaxed steps; relaxedStepUpdate() retreats inside the
    // last safe sphere when consecutive unbounding spheres stop overlapping.
    // The ceiling is per fractal type — see relaxedOmegaCap() for why log-DE
    // and Kleinian/custom estimators must stay closer to 1.
    float omega = clamp(stepMultiplier, 1.0f, relaxedOmegaCap(type));
    float prevH = 0.0;
    float stepLen = 0.0;

    for(int j = 0; j < maxSteps; j++)
    {
        // Mandelbulb needs ~4x finer threshold (its DE returns much smaller values).
        float threshold = isMandelbulb
            ? fma(t, 0.0002f, 0.00012f) + (1.0f - quality) * 0.001f
            : fma(t, 0.0008f, 0.0005f)  + (1.0f - quality) * 0.003f;

        float3 p = fma(rD, float3(t), rO);
        // Use unified dispatch for the march loop (no Jacobian overhead)
        float h = MapUnified(p, params, foldingLimit, iterations, type, fp);

        bool sorFail = relaxedStepUpdate(h, omega, prevH, stepLen);

        if(UNLIKELY(h < threshold) && !sorFail)
        {
            // Re-iterate with full orbit cache + Jacobian for normals/colors.
            OrbitCache hitCache;
            MapWithOrbitCacheUnified(p, params, foldingLimit, iterations, type, fp, colorIterations, hitCache);
            result.cache = hitCache;
            result.distGlow = float2(t, saturate(glow * 0.25));
            return result;
        }

        if (UNLIKELY(t > maxRayDistance)) break;

        glow = fma(saturate(0.04 - h), glowIntensity, glow);
        t += stepLen;
    }

    result.distGlow = float2(kRayMissThreshold + 100.0, saturate(glow * 0.25));
    return result;
}

// Raymarch with cache that starts from a known distance (for hierarchical acceleration)
FORCE_INLINE SceneResult SceneWithCacheFromStart(float3 rO, float3 rD, float startT, float2 fragCoord, float quality, int maxStepsParam, float glowIntensity, float foldingLimit, FractalParams params, int iterations, float time, int fractalType = 0, FormulaParams fp = {}, int colorIterations = 0, float stepMultiplier = 1.0)
{
    SceneResult result;
    result.cache = makeEmptyOrbitCache();
    int type = is_function_constant_defined(FC_FRACTAL_TYPE) ? FC_FRACTAL_TYPE : fractalType;
    
    float dither = interleavedGradientNoise(fragCoord, time) * 0.01;
    bool isMandelbulb = (type == FractalTypeMandelbulb || type == FractalTypeMandelbulbJulia);
    float t = max(isMandelbulb ? 0.002 : 0.01, startT - 0.3) + dither;
    
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

    // Relaxed sphere tracing with overstep-failure detection; per-type ceiling
    // (see relaxedOmegaCap for why log-DE/Kleinian/custom stay closer to 1).
    float omega = clamp(stepMultiplier, 1.0f, relaxedOmegaCap(type));
    float prevH = 0.0;
    float stepLen = 0.0;

    for(int j = 0; j < maxSteps; j++)
    {
        float threshold = isMandelbulb
            ? fma(t, 0.00015f, 0.00012f)
            : fma(t, 0.0006f, 0.0005f);
        float3 p = fma(rD, float3(t), rO);
        // Use unified dispatch for the march loop (no Jacobian overhead)
        float h = MapUnified(p, params, foldingLimit, iterations, type, fp);

        bool sorFail = relaxedStepUpdate(h, omega, prevH, stepLen);

        if(UNLIKELY(h < threshold) && !sorFail)
        {
            // Re-iterate with full orbit cache for normals/colors.
            OrbitCache hitCache;
            MapWithOrbitCacheUnified(p, params, foldingLimit, iterations, type, fp, colorIterations, hitCache);
            result.cache = hitCache;
            result.distGlow = float2(t, saturate(glow * 0.25));
            return result;
        }

        if (UNLIKELY(t > endT)) break;

        glow = fma(saturate(0.04 - h), glowIntensity, glow);
        t += stepLen;
    }
    
    result.distGlow = float2(kRayMissThreshold + 100.0, saturate(glow * 0.25));
    return result;
}

// Post effects with color scheme support and dynamic animation
// Consumes precomputed audio aggregates for lightweight audio-reactive modulation.
half3 PostEffectsWithScheme(half3 rgb, half2 xy, ColorSchemeParams scheme, PrecomputedAudio audio, half limitFlash = 0.0h, half rayGlow = 0.0h)
{
    // Pre-baked audio bands/energy (CPU computed) for reuse
    half bass = half(audio.bands.x);
    half mid = half(audio.bands.y);
    // treble (audio.bands.z) now feeds the hue spin rate on the CPU, not here.
    half beat = half(audio.bands.w);
    half audioEnergy = half(audio.energy.y);

    // === DYNAMIC HUE CYCLING (OPTIONAL EFFECT WITH INTENSITY CONTROL) ===
    // Only process if enabled - uses YIQ color space rotation
    // Intensity parameter allows blending rotated color back with original to prevent overpowering
    if (scheme.hueRotationEnabled) {
        // Phase is pre-integrated on the CPU (speed + treble boost baked into the rate),
        // so dragging the speed slider or a treble transient can't snap the hue here.
        float wrappedAngle = fmod(scheme.hueCyclePhase, 6.28318f);
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
        // Phase pre-integrated on the CPU (∫ speed·dt) so changing pulse speed never snaps the wave.
        half pulseWave = 0.5h + 0.5h * sin(half(fmod(scheme.pulseCyclePhase, 6.28318f)));
        // Audio modulates pulse amplitude slightly (beat spikes it)
        half pulseAudio = 1.0h + audioEnergy * 0.35h + beat * 0.25h;
        pulse = 1.0h + half(scheme.pulseAmount) * (pulseWave - 0.5h) * pulseAudio;
    }
    
    // === SATURATION WITH PULSE ===
    half luma = dot(rgb, half3(0.2126h, 0.7152h, 0.0722h));
    half satMult = half(scheme.saturation) * pulse * (1.0h + bass * 0.35h);
    rgb = mix(half3(luma), rgb, satMult);
    
    // === BRIGHTNESS AND CONTRAST (ALWAYS APPLIED) ===
    rgb = fma(rgb - half3(0.5h), half3(scheme.contrast), half3(0.5h + scheme.brightness));
    
    // === GLOW EFFECT (OPTIONAL) ===
    // Build a smoother halo from rayGlow while preserving source hue.
    if (scheme.glowEnabled && scheme.glowIntensity > 0.001f) {
        half intensity = half(scheme.glowIntensity);
        half lumaNow = dot(rgb, half3(0.2126h, 0.7152h, 0.0722h));
        half3 huePreserve = rgb / max(lumaNow, 0.02h);
        half3 haloTint = mix(half3(0.95h, 0.97h, 1.0h), saturate(huePreserve), 0.45h);
        half glowCore = smoothstep(0.06h, 0.30h, rayGlow);
        half glowTail = rayGlow * rayGlow;
        half glowAmount = (glowCore * (0.35h + 0.90h * intensity)) + (glowTail * (0.15h + 0.65h * intensity));
        rgb = rgb + haloTint * glowAmount;
    }
    
    // === BLOOM EFFECT (OPTIONAL) ===
    // Bright-pass bloom with soft knee, plus rayGlow assist so dark palettes still bloom.
    if (scheme.bloomEnabled && scheme.bloomStrength > 0.001f) {
        half strength = half(scheme.bloomStrength);
        half lumaNow = dot(rgb, half3(0.299h, 0.587h, 0.114h));
        half threshold = mix(0.52h, 0.22h, strength);
        half knee = 0.18h;
        half brightPass = smoothstep(threshold - knee, threshold + knee, lumaNow);
        half glowAssist = smoothstep(0.04h, 0.35h, rayGlow) * (0.25h + 0.95h * strength);
        half bloomAmount = brightPass * (0.18h + 1.25h * strength) + glowAssist;
        half3 bloomTint = mix(half3(1.0h, 0.96h, 0.88h), saturate(rgb + 0.08h), 0.35h);
        rgb = rgb + bloomTint * bloomAmount;
    }
    
    // === HIGHLIGHTS/EXPOSURE (skip when identity) ===
    if (abs(scheme.highlights) > 0.001f) {
        rgb *= half(1.0f + scheme.highlights);
    }
    
    // === VIBRANCE (skip when ~0) ===
    if (abs(scheme.vibrance) > 0.001f) {
        half maxChannel = max(rgb.r, max(rgb.g, rgb.b));
        half vibranceBoost = (1.0h - maxChannel) * half(scheme.vibrance) * (1.0h + mid * 0.25h);
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
    half beatFlash = scheme.beatFlashEnabled ? beat * half(scheme.beatFlashIntensity) : 0.0h;
    half combinedFlash = max(limitFlash, beatFlash);
    if (combinedFlash > 0.01h) {
        half2 edgeDist = abs(xy - 0.5h) * 2.0h;
        half edge = max(edgeDist.x, edgeDist.y);
        half edgeGlow = powr(edge, 2.0h) * combinedFlash;
        half3 flashColor = half3(1.0h, 0.4h, 0.1h);
        rgb = mix(rgb, flashColor, edgeGlow * 0.8h);
    }
    
    // Clamp before gamma to avoid NaN from negative values
    rgb = saturate(rgb);
    
    // Gamma from scheme
    return powr(max(rgb, half3(kPowEpsilonHalf)), half3(scheme.gamma));
}

struct FloorCircleHit {
    float alpha;
    float distance;
};

FORCE_INLINE FloorCircleHit evaluateFloorCircle(float3 rayOrigin,
                                                float3 rayDirection,
                                                float sceneDistance,
                                                float4 floorPlane,
                                                float4 floorCenterRadius) {
    FloorCircleHit hit;
    hit.alpha = 0.0f;
    hit.distance = kRayMissThreshold + 100.0f;

    float radius = floorCenterRadius.w;
    if (radius <= 0.001f) return hit;

    float3 planeNormal = normalize(floorPlane.xyz);
    float denominator = dot(planeNormal, rayDirection);
    if (abs(denominator) < 1e-4f) return hit;

    float floorDistance = -(dot(planeNormal, rayOrigin) + floorPlane.w) / denominator;
    float maxVisibleDistance = sceneDistance < kRayMissThreshold ? sceneDistance : kRayMissThreshold;
    if (floorDistance <= 0.02f || floorDistance >= maxVisibleDistance) return hit;

    float3 floorPoint = rayOrigin + rayDirection * floorDistance;
    float3 radialVector = floorPoint - floorCenterRadius.xyz;
    radialVector -= planeNormal * dot(radialVector, planeNormal);
    float radialDistance = length(radialVector);
    float edgeWidth = max(radius * 0.04f, 0.055f);
    float glassFalloff = 1.0f - smoothstep(radius - edgeWidth, radius, radialDistance);
    float thicknessBand = 1.0f - smoothstep(edgeWidth * 0.35f, edgeWidth * 2.4f, abs(radialDistance - radius));
    float innerCaustic = 0.5f + 0.5f * sin((radialDistance / max(radius, 0.001f)) * 24.0f);
    float fill = glassFalloff * (0.18f + innerCaustic * 0.05f);
    float rim = thicknessBand * 0.44f;

    hit.alpha = saturate(fill + rim);
    hit.distance = floorDistance;
    return hit;
}

FORCE_INLINE half3 compositeFloorCircle(half3 color, FloorCircleHit hit) {
    if (hit.alpha <= 0.0f) return color;

    half floorAlpha = half(saturate(hit.alpha));
    half luminance = dot(color, half3(0.2126h, 0.7152h, 0.0722h));
    half3 refractedFractal = mix(color, half3(luminance), 0.18h);
    half3 glassTint = half3(0.58h, 0.86h, 1.0h);
    half3 glassColor = mix(refractedFractal, glassTint, 0.38h);
    half3 highlight = half3(1.0h, 1.0h, 1.0h) * floorAlpha * 0.16h;
    return mix(color, glassColor + highlight, floorAlpha);
}

// =============================================================================

// Soft shadow with over-relaxation
// OPTIMIZATION: Combined exit conditions to reduce branches
// GMT-FRACTALS TECHNIQUE: FC_SHADOWS_ENABLED allows compile-time elimination of
// entire shadow computation. When disabled, returns a flat ambient shadow value
// (0.35) — zero Map() evaluations, zero ALU cost.
// Also uses MapDistOnly instead of the full distance estimator — removes all
// fold/trap tracking from shadow rays, saving ~6 ops per iteration per step.
FORCE_INLINE float Shadow(float3 ro, float3 rd, float quality, float foldingLimit, FractalParams params, int iterations, int fractalType = 0, FormulaParams fp = {})
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
        // the full distance estimator spends on tracking are pure waste here.
        float h = MapDistOnlyUnified(p, params, foldingLimit, iterations, fractalType, fp);
        
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

// === Temporal-reprojection shared helpers (extracted from adaptiveHierarchical8x8) ===
// These centralize three patterns that were previously duplicated across the
// kernel's reprojection, tile-seed, and empty-tile probes. Each is a pure
// function whose float-op sequence is identical to the inlined originals, so
// results are bit-for-bit unchanged.

// Unproject a viewport-pixel coordinate to a model-space point on the near ray.
// Mirrors the fragment-shader unprojection exactly, including the asymmetric
// per-eye frustum w-guard used on visionOS.
FORCE_INLINE float3 reconstructModelPoint(float2 pixelCoord, constant TileUniforms& uniforms) {
    float2 ndc = (pixelCoord / uniforms.resolution) * 2.0 - 1.0;
    ndc.y = -ndc.y;
    float4 clipPos = float4(ndc.x, ndc.y, 0.0, 1.0);
    float4 viewPoint4 = uniforms.invProjMatrix * clipPos;
    float viewPointW = abs(viewPoint4.w) > 1e-6f
        ? viewPoint4.w
        : (viewPoint4.w >= 0.0f ? 1e-6f : -1e-6f);
    float3 viewPoint = viewPoint4.xyz / viewPointW;
    return (uniforms.invViewMatrix * float4(viewPoint, 1.0)).xyz;
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

// sRGB encode for compute kernel output.
// Fragment shaders writing to bgra8Unorm_srgb attachments get hardware linear→sRGB
// encoding for free. Compute kernel writes bypass that hardware stage, so we apply
// the IEC 61966-2-1 piecewise function manually before writing.
FORCE_INLINE float3 linearToSRGB(float3 c) {
    c = saturate(c);
    float3 lo = c * 12.92;
    float3 hi = powr(c, float3(1.0 / 2.4)) * 1.055 - 0.055;
    return select(hi, lo, c < 0.0031308);
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
    const uint ADAPTIVE_SUPERTILE_SIZE = 32;
    const uint ADAPTIVE_SUPERTILE_TILE_COUNT = ADAPTIVE_SUPERTILE_SIZE / ADAPTIVE_TILE_SIZE;
    uint2 viewportPixelCoord = tileId * ADAPTIVE_TILE_SIZE + localId;
    uint2 viewportSize = uint2(uniforms.resolution);
    
    if (viewportPixelCoord.x >= viewportSize.x || viewportPixelCoord.y >= viewportSize.y) {
        return;
    }

    uint2 viewportOrigin = uint2(uniforms.viewportOrigin);
    uint2 pixelCoord = viewportOrigin + viewportPixelCoord;
    
    // Compute ray direction in MODEL SPACE (matching fragment shader exactly)
    // Fragment shader does: rd = normalize(in.modelPos - cameraPos)
    // where modelPos comes from vertex positions and cameraPos is (invModelView * (0,0,0,1)).xyz
    //
    // For compute, we need to:
    // 1. Unproject pixel to clip space
    // 2. Transform through inverse projection to get view-space point
    // 3. Transform through inverse model-view to get model-space point
    // 4. Compute direction from camera to that point (both in model space)
    
    float2 pixelCenter = float2(viewportPixelCoord) + 0.5;
    
    // === GMT-FRACTALS PATTERN: Halton Sub-Pixel Jitter for Temporal AA ===
    pixelCenter += uniforms.jitterOffset;
    
    float3 cameraPos = uniforms.cameraPos;

    // Match the fragment path exactly for visionOS's asymmetric per-eye frusta.
    float3 modelPoint = reconstructModelPoint(pixelCenter, uniforms);
    float3 rd = normalize(modelPoint - cameraPos);
    
    int lodIterations = max(uniforms.fractalIterations, 2);
    int maxSteps = uniforms.maxRaySteps;
    int fractalType = uniforms.fractalType;

    // === FOVEATED RAYMARCH ===
    // Peripheral tiles get fewer ray steps. The factor is derived from the tile
    // CENTER, so all 64 threads in this threadgroup compute the same value with
    // no intra-tile divergence. Foveal region (r < kFovInner) stays full-quality;
    // beyond it the step budget ramps down to kFovMinFraction at the corners,
    // scaled by foveationStrength. Disabled (factor == 1) when strength == 0.
    if (uniforms.foveationStrength > 0.0f) {
        const float kFovInner = 0.35f;        // normalized radius that stays sharp
        const float kFovMinFraction = 0.5f;   // step budget at the far periphery
        float2 tileCenter = float2(tileId * ADAPTIVE_TILE_SIZE + ADAPTIVE_TILE_SIZE / 2);
        float2 halfRes = max(float2(viewportSize) * 0.5f, float2(1.0f));
        float r = min(length((tileCenter - halfRes) / halfRes), 1.0f);
        float ramp = smoothstep(kFovInner, 1.0f, r) * uniforms.foveationStrength;
        float factor = mix(1.0f, kFovMinFraction, ramp);
        maxSteps = max(int(float(maxSteps) * factor), 8);
    }

    float3 marchOrigin = cameraPos;
    float3 marchDir = rd;
    applySphericalInversionRay(marchOrigin, marchDir, uniforms.sphericalInversionMode, uniforms.sphericalInversionRadius);

    // Use precomputed fractal params (powr() and divisions done on CPU)
    FractalParams fractalParams = makeFractalParamsFromPrecomputed(
        uniforms.precomputedFractal,
        uniforms.minDistance,
        marchOrigin, uniforms.safetyBubbleRadius, uniforms.safetyBubbleEnabled, uniforms.safetyBubbleShape, uniforms.safetyBubbleFadeEnabled, uniforms.safetyBubbleFadeWidth, uniforms.safetyBubbleStrength, uniforms.sphereProjectionBlend, uniforms.sphereProjectionRadius);

    // === TEMPORAL REPROJECTION: PER-PIXEL ===
    // Reproject this pixel to previous frame, sample previous depth,
    // and use it as startT to skip most of the fine raymarch.
    // For ~95% of pixels (static or slow-moving), this converts a
    // ~288 inner-loop fine march into a ~30 inner-loop refinement.
    float reprojectedStartT = 0.0;
    float reprojectedDepth = -1.0;
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
        float2 prevUV = reprojectToPrevUV(refPoint, uniforms);  // Metal texture convention (Y flipped)
        
        // 3. Check if the reprojected UV is within bounds
        if (prevUV.x >= 0.0 && prevUV.x <= 1.0 && prevUV.y >= 0.0 && prevUV.y <= 1.0) {
            // Sample previous depth at the reprojected location
            uint2 prevPixel = uint2(prevUV * uniforms.resolution);
            prevPixel = clamp(prevPixel, uint2(0), viewportSize - 1);
            prevPixel += viewportOrigin;
            float prevDepth = prevDepthTexture.read(prevPixel, uniforms.eyeIndex).x;
            
            if (prevDepth > 0.0 && prevDepth < kRayMissThreshold) {
                // 4. Iterative refinement: reproject with the sampled depth
                //    to get a more accurate UV, then re-sample.
                float3 betterPoint = cameraPos + rd * prevDepth;
                float2 betterUV = reprojectToPrevUV(betterPoint, uniforms);
                
                if (betterUV.x >= 0.0 && betterUV.x <= 1.0 && betterUV.y >= 0.0 && betterUV.y <= 1.0) {
                    uint2 betterPixel = uint2(betterUV * uniforms.resolution);
                    betterPixel = clamp(betterPixel, uint2(0), viewportSize - 1);
                    betterPixel += viewportOrigin;
                    float refinedDepth = prevDepthTexture.read(betterPixel, uniforms.eyeIndex).x;
                    
                    if (refinedDepth > 0.0 && refinedDepth < kRayMissThreshold) {
                        prevDepth = refinedDepth;
                    }
                }
                
                // 5. Apply safety margin — back up 10% to avoid starting past the surface.
                //    This ensures we never miss geometry that moved slightly closer.
                reprojectedDepth = prevDepth;
                reprojectedStartT = prevDepth * 0.9;
                reprojectionValid = true;
            }
        }
    }

    // === COHERENT-PACKET WARM-START SAFETY PROBE (Stage 2) ===
    // The legacy `prevDepth * 0.9` heuristic assumes DE monotonicity along the ray.
    // Fractal DEs (Mandelbulb / Mandelbox) are LOCALLY non-monotone: they decrease
    // into a fold then increase past it, so a fixed 10% backoff happily steps past
    // disocclusion-exposed surfaces.
    //
    // Replacement: a single MapUnified evaluation at the predicted t. Three outcomes:
    //   • h < hitThreshold    → already on the surface; treat as confirmed hit
    //                            and skip the fine march entirely (fast path).
    //   • h > backoffMargin   → safely outside; tighten startT to (t - h), which
    //                            is GUARANTEED conservative by Lipschitz-1.
    //   • otherwise            → reject reprojection; fall back to coarse pass.
    //
    // Cost: 1 DE eval per pixel for warm-start. Saves the entire coarse search and
    // potentially the entire fine march. Failure is silent: we just use the legacy
    // tileStartT path.
    //
    // packetLayer is a per-pixel debug tag for the layer-of-acceptance overlay:
    //   0 = unset / fell through to coarse-tile path
    //   1 = coherent-packet warm-start ACCEPTED as immediate hit (best case)
    //   2 = coherent-packet warm-start ACCEPTED as tight startT
    //   3 = coherent-packet warm-start REJECTED (probe found no surface near prediction)
    int packetLayer = 0;
    const bool coherentPacketOn = is_function_constant_defined(FC_COHERENT_PACKET)
        ? FC_COHERENT_PACKET : (uniforms.coherentPacketEnabled != 0);
    if (coherentPacketOn && reprojectionValid) {
        float t_pred = reprojectedDepth;
        bool packetIsMandelbulb = (fractalType == FractalTypeMandelbulb || fractalType == FractalTypeMandelbulbJulia);
        // Hit threshold mirrors the fine-march acceptance gate so a probe-hit is
        // bit-for-bit consistent with what SceneWithCacheFromStart would accept.
        float probeHitThreshold = packetIsMandelbulb
            ? fma(t_pred, 0.0002f, 0.00012f)
            : fma(t_pred, 0.0008f, 0.0005f);
        // Backoff margin: distance below which we DON'T trust (t - h) as a safe
        // start (we may be inside a fold). Tuned conservatively per fractal.
        float probeBackoffMargin = packetIsMandelbulb ? 0.004f : 0.012f;

        float3 probeP = marchOrigin + marchDir * t_pred;
        float h_probe = MapUnified(probeP, fractalParams, uniforms.foldingLimit, lodIterations, fractalType, uniforms.formulaParams);

        if (h_probe < probeHitThreshold) {
            // Surface confirmed at the predicted depth. Don't skip the fine march
            // entirely — if we did, glow accumulation would be 0 here while neighbor
            // pixels (green/red layers) accumulate real proximity-glow during their
            // fine march, producing a visible seam. Instead, start the fine march
            // just behind the probe so it terminates in ~1-3 steps and shading is
            // bit-identical to the legacy path.
            //
            // Backoff distance: max(probeHitThreshold * 6, 0.5% of t_pred) keeps the
            // restart safely outside the hit band even with non-monotone DEs.
            float restartBackoff = max(probeHitThreshold * 6.0f, t_pred * 0.005f);
            reprojectedStartT = max(0.05f, t_pred - restartBackoff);
            packetLayer = 1;
        } else if (h_probe > probeBackoffMargin) {
            // Safely outside surface. (t - h) is Lipschitz-conservative.
            reprojectedStartT = max(0.05f, t_pred - h_probe);
            packetLayer = 2;
        } else {
            // Inside the unsafe band — could be a fold. Reject; let coarse pass run.
            reprojectionValid = false;
            reprojectedStartT = 0.0;
            packetLayer = 3;
        }
    }
    
    // === SHARED TILE STATE ===
    threadgroup float tileStartT = 0.05f;
    threadgroup int tileIsEmpty = 0;       // 1 = entire tile missed, skip fine march
    threadgroup half tg_shaSpot = 0.0h;    // Shared spotlight shadow (1 eval per tile)
    threadgroup half tg_shaSun = 0.0h;     // Shared sun shadow (1 eval per tile)
    // Coherent-packet Stage 3: anchor's surface frame for normal-coherence gate.
    // NOTE: threadgroup vars cannot be reliably initialized in their declaration
    // in Metal — initialize from thread 0 then barrier so all lanes see the value.
    threadgroup float3 tg_anchorPos;
    threadgroup float3 tg_anchorNormal;
    threadgroup int tg_anchorHasHit;
    if (localIndex == 0) {
        tg_anchorPos = float3(0.0f);
        tg_anchorNormal = float3(0.0f, 1.0f, 0.0f);
        tg_anchorHasHit = 0;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

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
        // Before coarse raymarching, test rays at the tile center + 4 corners
        // against the bounding sphere. Only declare empty if ALL 5 rays miss.
        // Single-center probing dropped 8x8 tiles whenever a thin off-axis
        // feature crossed only the corner of the tile.
        if (uniforms.boundingSphereRadius > 0.0) {
            const float2 bsOffsets[5] = {
                float2(ADAPTIVE_TILE_SIZE * 0.5f, ADAPTIVE_TILE_SIZE * 0.5f),
                float2(0.0f, 0.0f),
                float2(float(ADAPTIVE_TILE_SIZE), 0.0f),
                float2(0.0f, float(ADAPTIVE_TILE_SIZE)),
                float2(float(ADAPTIVE_TILE_SIZE), float(ADAPTIVE_TILE_SIZE))
            };
            int bsMissCount = 0;
            for (int i = 0; i < 5; ++i) {
                float2 px = float2(tileId * ADAPTIVE_TILE_SIZE) + bsOffsets[i];
                float3 bsModelPoint = reconstructModelPoint(px, uniforms);
                float3 bsRd = normalize(bsModelPoint - marchOrigin);
                float bsT = rayIntersectBoundingSphere(marchOrigin, bsRd, float3(0.0), uniforms.boundingSphereRadius);
                if (bsT < 0.0) bsMissCount++;
            }
            if (bsMissCount >= 5) {
                tileIsEmpty = 1;
                tileStartT = 0.05;
            }
        }
        
        if (!tileIsEmpty) {
        bool seededFromSuperTileHistory = false;
        bool seededFromTileHistory = false;

        // 32x32 supertile seed:
        // Build a parent-grid hint from previous-frame depths so child 8x8 tiles
        // can skip coarse marching when temporal history is coherent.
        if (uniforms.temporalReprojectionEnabled != 0 && uniforms.blendFactor < 0.6f) {
            uint2 superTileId = tileId / ADAPTIVE_SUPERTILE_TILE_COUNT;
            uint2 superTileBase = viewportOrigin + superTileId * ADAPTIVE_SUPERTILE_SIZE;
            uint2 superTileEnd = min(superTileBase + uint2(ADAPTIVE_SUPERTILE_SIZE - 1), viewportOrigin + viewportSize - 1);
            uint2 superTileCenterPx = min(superTileBase + uint2(ADAPTIVE_SUPERTILE_SIZE / 2), viewportOrigin + viewportSize - 1);

            int superHistoryHits = 0;
            float superMinHitDepth = kRayMissThreshold + 100.0f;

            accumulateDepthSample(prevDepthTexture.read(superTileCenterPx, uniforms.eyeIndex).x, superHistoryHits, superMinHitDepth);
            accumulateDepthSample(prevDepthTexture.read(superTileBase, uniforms.eyeIndex).x, superHistoryHits, superMinHitDepth);
            accumulateDepthSample(prevDepthTexture.read(uint2(superTileEnd.x, superTileBase.y), uniforms.eyeIndex).x, superHistoryHits, superMinHitDepth);
            accumulateDepthSample(prevDepthTexture.read(uint2(superTileBase.x, superTileEnd.y), uniforms.eyeIndex).x, superHistoryHits, superMinHitDepth);
            accumulateDepthSample(prevDepthTexture.read(superTileEnd, uniforms.eyeIndex).x, superHistoryHits, superMinHitDepth);
            accumulateDepthSample(prevDepthTexture.read(uint2(superTileCenterPx.x, superTileBase.y), uniforms.eyeIndex).x, superHistoryHits, superMinHitDepth);
            accumulateDepthSample(prevDepthTexture.read(uint2(superTileCenterPx.x, superTileEnd.y), uniforms.eyeIndex).x, superHistoryHits, superMinHitDepth);
            accumulateDepthSample(prevDepthTexture.read(uint2(superTileBase.x, superTileCenterPx.y), uniforms.eyeIndex).x, superHistoryHits, superMinHitDepth);
            accumulateDepthSample(prevDepthTexture.read(uint2(superTileEnd.x, superTileCenterPx.y), uniforms.eyeIndex).x, superHistoryHits, superMinHitDepth);

            // 9-sample super-tile seed: tighten threshold + backoff to avoid
            // skipping closer geometry across 32x32 depth discontinuities.
            if (superHistoryHits >= 5) {
                tileStartT = max(0.05f, superMinHitDepth * 0.6f);
                seededFromSuperTileHistory = true;
            }
        }

        // Tile-level temporal neighborhood seed:
        // sample center + 4 corners from previous-frame depth and use the
        // nearest hit as a conservative start distance for the whole 8x8 tile.
        // This reuses both frame-to-frame and nearby-pixel information.
        if (uniforms.temporalReprojectionEnabled != 0 && uniforms.blendFactor < 0.6f) {
            uint2 tileBase = viewportOrigin + tileId * ADAPTIVE_TILE_SIZE;
            uint2 tileEnd = min(tileBase + uint2(ADAPTIVE_TILE_SIZE - 1), viewportOrigin + viewportSize - 1);
            uint2 tileCenterPx = min(tileBase + uint2(ADAPTIVE_TILE_SIZE / 2), viewportOrigin + viewportSize - 1);

            int tileHistoryHits = 0;
            float tileMinHitDepth = kRayMissThreshold + 100.0f;

            accumulateDepthSample(prevDepthTexture.read(tileCenterPx, uniforms.eyeIndex).x, tileHistoryHits, tileMinHitDepth);
            accumulateDepthSample(prevDepthTexture.read(tileBase, uniforms.eyeIndex).x, tileHistoryHits, tileMinHitDepth);
            accumulateDepthSample(prevDepthTexture.read(uint2(tileEnd.x, tileBase.y), uniforms.eyeIndex).x, tileHistoryHits, tileMinHitDepth);
            accumulateDepthSample(prevDepthTexture.read(uint2(tileBase.x, tileEnd.y), uniforms.eyeIndex).x, tileHistoryHits, tileMinHitDepth);
            accumulateDepthSample(prevDepthTexture.read(tileEnd, uniforms.eyeIndex).x, tileHistoryHits, tileMinHitDepth);

            // Require multiple agreeing history samples to avoid stale-start artifacts.
            // 3-of-5 (was 2-of-5) + tighter 0.6 backoff (was 0.8) prevents 8x8
            // silhouette artifacts where 2 corners hit far depth and the rest
            // miss closer surface.
            if (tileHistoryHits >= 3) {
                tileStartT = max(0.05f, tileMinHitDepth * 0.6f);
                seededFromTileHistory = true;
            }
        }

        // Build a model-space ray for an arbitrary viewport-pixel coord.
        // Used for multi-corner probing in the bounding-sphere test, the
        // empty-tile test, and (when reprojection is valid) for a conservative
        // coarse march at the tile center.
        float coarseTCenter = kRayMissThreshold + 1.0f;
        bool ranCoarseMarch = false;

        if (!seededFromTileHistory && !seededFromSuperTileHistory) {
            FractalParams coarseParams = makeFractalParamsFromPrecomputed(
                uniforms.precomputedFractal,
                uniforms.minDistance,
                marchOrigin, uniforms.safetyBubbleRadius, uniforms.safetyBubbleEnabled, uniforms.safetyBubbleShape, uniforms.safetyBubbleFadeEnabled, uniforms.safetyBubbleFadeWidth, uniforms.safetyBubbleStrength, uniforms.sphereProjectionBlend, uniforms.sphereProjectionRadius);
            coarseTCenter = SceneCoarse(marchOrigin, marchDir, uniforms.foldingLimit, coarseParams, lodIterations, fractalType, uniforms.formulaParams, uniforms.maxViewDistance);
            ranCoarseMarch = true;

            if (coarseTCenter >= kRayMissThreshold) {
                // Coarse-center missed — probe FIVE rays (4 corners + center) to confirm
                // the tile is truly empty. Single-center probing was the source of
                // 8x8 dropouts on thin off-axis fractal features.
                const float2 cornerOffsets[5] = {
                    float2(0.5f, 0.5f),                                     // center
                    float2(0.0f, 0.0f),                                     // TL
                    float2(float(ADAPTIVE_TILE_SIZE), 0.0f),                // TR
                    float2(0.0f, float(ADAPTIVE_TILE_SIZE)),                // BL
                    float2(float(ADAPTIVE_TILE_SIZE), float(ADAPTIVE_TILE_SIZE)) // BR
                };
                float probeIters = float(lodIterations) * 0.6;
                float tileAngularSize1 = ADAPTIVE_TILE_SIZE / min(uniforms.resolution.x, uniforms.resolution.y) * 2.0 * 2.0;
                float tileAngularSize2 = ADAPTIVE_TILE_SIZE / min(uniforms.resolution.x, uniforms.resolution.y) * 2.0 * 6.0;
                int cornerEmpty = 0;
                for (int c = 0; c < 5; ++c) {
                    float2 cornerPx = float2(tileId * ADAPTIVE_TILE_SIZE) + cornerOffsets[c];
                    float3 cModelPoint = reconstructModelPoint(cornerPx, uniforms);
                    float3 cOrigin = uniforms.cameraPos;
                    float3 cRd = normalize(cModelPoint - cOrigin);
                    applySphericalInversionRay(cOrigin, cRd, uniforms.sphericalInversionMode, uniforms.sphericalInversionRadius);

                    float3 probe1 = cOrigin + cRd * 2.0;
                    float3 probe2 = cOrigin + cRd * 6.0;
                    float d1 = MapContinuousUnified(probe1, fractalParams, uniforms.foldingLimit, probeIters, fractalType, uniforms.formulaParams);
                    float d2 = MapContinuousUnified(probe2, fractalParams, uniforms.foldingLimit, probeIters, fractalType, uniforms.formulaParams);
                    if (d1 > tileAngularSize1 && d2 > tileAngularSize2) {
                        cornerEmpty++;
                    }
                }
                // Require ALL 5 probes to declare empty — conservative.
                if (cornerEmpty >= 5) {
                    tileIsEmpty = 1;
                }
                tileStartT = 0.05;
            } else {
                tileStartT = coarseTCenter;
            }
        }

        if (reprojectionValid) {
            // Temporal reprojection is valid for thread 0 — surface exists near
            // this depth FOR THE CENTER PIXEL. But other threads in the tile may
            // have no valid reprojection (silhouettes/disocclusions). To avoid
            // skipping closer geometry on those edges, use the MORE CONSERVATIVE
            // (closer) of the reprojected start and the coarse-march result.
            float reprojSeed = max(0.05f, reprojectedStartT * 0.85f);
            if (ranCoarseMarch && coarseTCenter < kRayMissThreshold) {
                tileStartT = min(reprojSeed, coarseTCenter);
            } else {
                tileStartT = reprojSeed;
            }
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
        col = applyFog(col, kRayMissThreshold + 100.0, uniforms.precomputedFog);
        col = clampColor(col);
        half2 texCoord = half2(pixelCenter / uniforms.resolution);
        col = PostEffectsWithScheme(col, texCoord, uniforms.colorScheme, uniforms.precomputedAudio, half(uniforms.limitFlash), 0.0h);
        FloorCircleHit floorHit = evaluateFloorCircle(cameraPos, rd, kRayMissThreshold + 100.0f, uniforms.floorPlane, uniforms.floorCenterRadius);
        col = compositeFloorCircle(col, floorHit);
        float4 currentColor = float4(linearToSRGB(float3(col)), 1.0);
        outputTexture.write(currentColor, pixelCoord, uniforms.eyeIndex);
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

    // === TEMPORAL REPROJECTION FOR ALL FRACTAL TYPES ===
    // When fineStartT > 0.06 (from temporal reprojection or tile coarse pass),
    // SceneWithCacheFromStart begins near the known surface — typically ~5-10
    // steps instead of 30-60.  Previously only Mandelbox used this path;
    // all other formulas did a full march every frame, wasting temporal data.
    SceneResult sceneResult;
    if (fineStartT > 0.06f) {
        sceneResult = SceneWithCacheFromStart(marchOrigin, marchDir, fineStartT, pixelCenter, 1.0, maxSteps,
                                              uniforms.glowIntensity, uniforms.foldingLimit, fractalParams, lodIterations, uniforms.time, fractalType, uniforms.formulaParams, int(uniforms.colorIterations), uniforms.stepMultiplier);
    } else {
        sceneResult = SceneWithCache(marchOrigin, marchDir, pixelCenter, 1.0, maxSteps,
                         uniforms.glowIntensity, uniforms.foldingLimit, fractalParams, lodIterations, uniforms.time, fractalType, uniforms.formulaParams, int(uniforms.colorIterations), uniforms.boundingSphereRadius, uniforms.stepMultiplier, uniforms.maxViewDistance);
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
        float3 nor = GetNormal(p, adjustedDist, fractalParams, uniforms.foldingLimit, lodIterations, fractalType, uniforms.formulaParams, hitCache);
        
        // Use precomputed lighting from CPU with helper function
        float4 spotData = computeSpotlight(p, uniforms.precomputedLighting.spotLightPosition);
        float3 spot = spotData.xyz;
        float atten = spotData.w;
        
        // Blended lighting (precomputed on CPU — frame-uniform)
        float3 sunDir = uniforms.precomputedLighting.sunDir;
        float sunDiffuseScale = uniforms.precomputedLighting.sunDiffuseScale;
        float lightIntensity = uniforms.precomputedLighting.lightIntensity;
        
        const bool shareShadows = is_function_constant_defined(FC_SHARE_SHADOWS)
            ? FC_SHARE_SHADOWS
            : (uniforms.lightingSoftness < 0.9f);
        int shadowIterations = ReducedSecondaryIterations(lodIterations, fractalType, true);
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
                    marchOrigin, uniforms.safetyBubbleRadius, uniforms.safetyBubbleEnabled, uniforms.safetyBubbleShape, uniforms.safetyBubbleFadeEnabled, uniforms.safetyBubbleFadeWidth, uniforms.safetyBubbleStrength, uniforms.sphereProjectionBlend, uniforms.sphereProjectionRadius);
                
                tg_shaSpot = half(Shadow(p, spot, 0.8, uniforms.foldingLimit, shadowParams, shadowIterations, fractalType, uniforms.formulaParams));
                tg_shaSun = half(Shadow(p, sunDir, 0.8, uniforms.foldingLimit, shadowParams, shadowIterations, fractalType, uniforms.formulaParams));
                // Publish anchor surface frame for the coherent-packet normal gate.
                tg_anchorPos = p;
                tg_anchorNormal = nor;
                tg_anchorHasHit = 1;
            }
            threadgroup_barrier(mem_flags::mem_threadgroup);
            shaSpot = tg_shaSpot;
            shaSun = tg_shaSun;

            // === COHERENT-PACKET SHADOW NORMAL-COHERENCE GATE (Stage 3) ===
            // The legacy share blindly broadcasts thread 0's shadow to all 63 other
            // pixels in the tile, which produces blocky terminator banding on the
            // crinkled fractal surface (normals can flip between adjacent pixels
            // even when depth is similar). Replacement: lanes accept the broadcast
            // ONLY if their (n_i, p_i) is locally coherent with the anchor; otherwise
            // they fall back to a per-pixel Shadow() call. Coherent regions still
            // get the full sharing speedup; silhouettes pay the per-pixel cost they
            // would have paid anyway under !shareShadows.
            if (coherentPacketOn && localIndex != 0 && tg_anchorHasHit != 0) {
                float normalDot = dot(nor, tg_anchorNormal);
                float dpDist = length(p - tg_anchorPos);
                // Tile diagonal at unit depth ≈ 8 * 1.41 / min(res). Use adjustedDist
                // as a screen-space-ish coherence radius cap.
                float coherenceRadius = max(0.02f, adjustedDist * 0.02f);
                bool normalsCoherent = normalDot > 0.95f && dpDist < coherenceRadius;
                if (!normalsCoherent) {
                    FractalParams shadowParamsLocal = makeFractalParamsFromPrecomputed(
                        uniforms.precomputedFractal,
                        uniforms.minDistance,
                        marchOrigin, uniforms.safetyBubbleRadius, uniforms.safetyBubbleEnabled, uniforms.safetyBubbleShape, uniforms.safetyBubbleFadeEnabled, uniforms.safetyBubbleFadeWidth, uniforms.safetyBubbleStrength, uniforms.sphereProjectionBlend, uniforms.sphereProjectionRadius);
                    shaSpot = half(Shadow(p, spot, 0.8, uniforms.foldingLimit, shadowParamsLocal, shadowIterations, fractalType, uniforms.formulaParams));
                    shaSun = half(Shadow(p, sunDir, 0.8, uniforms.foldingLimit, shadowParamsLocal, shadowIterations, fractalType, uniforms.formulaParams));
                    // Tag debug overlay layer for shadow fallback (only when not already tagged by warm-start).
                    if (packetLayer == 0) packetLayer = 4;
                }
            }
        } else {
            FractalParams shadowParams = makeFractalParamsFromPrecomputed(
                uniforms.precomputedFractal,
                uniforms.minDistance,
                marchOrigin, uniforms.safetyBubbleRadius, uniforms.safetyBubbleEnabled, uniforms.safetyBubbleShape, uniforms.safetyBubbleFadeEnabled, uniforms.safetyBubbleFadeWidth, uniforms.safetyBubbleStrength, uniforms.sphereProjectionBlend, uniforms.sphereProjectionRadius);
            shaSpot = half(Shadow(p, spot, 0.8, uniforms.foldingLimit, shadowParams, shadowIterations, fractalType, uniforms.formulaParams));
            shaSun = half(Shadow(p, sunDir, 0.8, uniforms.foldingLimit, shadowParams, shadowIterations, fractalType, uniforms.formulaParams));
        }
        
        float attenPow = powr(max(atten, kPowEpsilon), kAttenPower);
        half bri = quantizeCelLight(half(max(dot(spot, nor), 0.0) / attenPow * 0.25 * lightIntensity), uniforms.colorScheme);
        half briSun = quantizeCelLight(half(max(dot(sunDir, nor), 0.0) * sunDiffuseScale), uniforms.colorScheme);
        
        col = ColourWithScheme(p, 1.0, uniforms.minDistance, uniforms.fractalScale,
                    uniforms.foldingLimit, uniforms.sphereRadius, int(uniforms.colorIterations), uniforms.colorScheme, hitCache);
        
        // Add ambient term (0.15) to prevent pure black in shadows + hemisphere ambient
        half hemisphereAO = half(nor.y * 0.5 + 0.5); // Simple sky/ground ambient
        half ambient = 0.15h + hemisphereAO * 0.1h;
        col = (col * bri * shaSpot) + (col * briSun * shaSun) + (col * ambient);
        
        // Specular
        float3 V = -marchDir;
        float NoV = saturate(dot(nor, V));
        float fresnel = fma(1.0f - 0.04f, powr(max(1.0f - NoV, 0.0f), 5.0f), 0.04f);
        float specPower = uniforms.precomputedLighting.specPower;
        float3 Hspot = normalize(spot + V);
        float3 Hsun = normalize(sunDir + V);
        float specSpot = powr(max(dot(nor, Hspot), kPowEpsilon), specPower) * kSpecularIntensity * fresnel;
        float specSun = powr(max(dot(nor, Hsun), kPowEpsilon), specPower) * kSpecularIntensity * fresnel;
        if (uniforms.colorScheme.cellShadingEnabled == 0) {
            col += half3(specSpot) * shaSpot * bri;
            col += half3(specSun) * shaSun * briSun;
        }
    }
    
    // Apply fog, glow, and clamp using helper functions
    half glowH = half(glow);
    col = applyFog(col, adjustedDist, uniforms.precomputedFog);
    col = applyGlow(col, glowH);
    col = clampColor(col);
    
    // Apply PostEffects with color scheme support
    // (saturation, contrast, vignette, gamma from color scheme)
    // Compute approximate texCoord for vignette (0-1 range)
    half2 texCoord = half2(pixelCenter / uniforms.resolution);
    col = PostEffectsWithScheme(col, texCoord, uniforms.colorScheme, uniforms.precomputedAudio, half(uniforms.limitFlash), glowH);
    FloorCircleHit floorHit = evaluateFloorCircle(cameraPos, rd, adjustedDist, uniforms.floorPlane, uniforms.floorCenterRadius);
    col = compositeFloorCircle(col, floorHit);
    
    // Debug visualization
    // Use function constant to compile out debug code in release builds
    const bool debugHierarchical = is_function_constant_defined(FC_DEBUG_HIERARCHICAL) ? FC_DEBUG_HIERARCHICAL : (uniforms.debugHierarchical == 1);
    if (debugHierarchical) {
        // Show tile boundaries
        if (localId.x == 0 || localId.y == 0) {
            col = mix(col, half3(1.0h, 1.0h, 0.0h), 0.5h);
        }
    }
    
    float4 finalColor = float4(linearToSRGB(float3(col)), 1.0);

    // === COHERENT-PACKET LAYER-OF-ACCEPTANCE OVERLAY (Stage 0) ===
    // Applied after shading so the tint is unambiguous. Engages whenever the
    // experimental toggle is on (independent of
    // the hierarchical-debug toggle) so it's always visible while testing.
    //   1 = magenta : warm-start probe HIT (skipped fine march, fastest path)
    //   2 = green   : warm-start probe accepted as tight startT (Lipschitz-safe)
    //   3 = red     : warm-start probe REJECTED -> fell back to coarse pass
    //   4 = cyan    : shadow-share fallback (per-pixel Shadow paid)
    //   0 = unset   : pixel followed legacy coarse-tile path (no tint)
    if (coherentPacketOn) {
        half3 layerTint = half3(0.0h);
        half tintMix = 0.0h;
        if (packetLayer == 1)      { layerTint = half3(1.0h, 0.0h, 1.0h); tintMix = 0.65h; }
        else if (packetLayer == 2) { layerTint = half3(0.0h, 1.0h, 0.0h); tintMix = 0.45h; }
        else if (packetLayer == 3) { layerTint = half3(1.0h, 0.0h, 0.0h); tintMix = 0.65h; }
        else if (packetLayer == 4) { layerTint = half3(0.0h, 1.0h, 1.0h); tintMix = 0.50h; }
        if (tintMix > 0.0h) {
            finalColor.rgb = mix(finalColor.rgb, float3(layerTint), float(tintMix));
        }
    }

    outputTexture.write(finalColor, pixelCoord, uniforms.eyeIndex);
}

// === SPRING BLOB NAVIGATION WIDGET ===
// Screen-space SDF overlay: two spheres connected by a stretchy band.
// Anchor sphere sits at springAnchorNDC; displaced sphere follows spring displacement.
// smin blends them into a single gooey metaball shape that stretches when pulled.

// Smooth minimum for metaball blending (polynomial, k controls blend radius)
FORCE_INLINE float smin(float a, float b, float k) {
    float h = saturate(0.5f + 0.5f * (b - a) / k);
    return mix(b, a, h) - k * h * (1.0f - h);
}

// 2D SDF for the spring blob widget.
// Returns signed distance to the metaball shape in NDC space.
// anchorNDC: rest position, displacementNDC: offset from anchor (from spring physics).
// restRadius: blob radius at rest, stretch: 0-1 normalized stretch amount.
FORCE_INLINE float springBlobSDF(float2 uv, float2 anchorNDC, float2 displacementNDC,
                                  float restRadius, float stretch, float time) {
    // Anchor sphere (fixed)
    float2 anchorPos = anchorNDC;
    float dAnchor = length(uv - anchorPos) - restRadius;
    
    // Displaced sphere (follows spring displacement)
    float2 displacedPos = anchorNDC + displacementNDC;
    // Displaced sphere shrinks slightly when stretched (mass conservation feel)
    float displacedRadius = restRadius * (1.0f - 0.3f * stretch);
    float dDisplaced = length(uv - displacedPos) - displacedRadius;
    
    // Blend radius increases with stretch for gooey connection
    float blendK = restRadius * (0.8f + 1.5f * stretch);
    float dBlend = smin(dAnchor, dDisplaced, blendK);
    
    // Band vibration: damped sine wave along the connection axis
    // Only applies when stretched and creates a subtle wobble on the connecting band
    if (stretch > 0.01f) {
        float2 axis = displacedPos - anchorPos;
        float axisLen = length(axis);
        if (axisLen > 0.001f) {
            float2 axisDir = axis / axisLen;
            float2 perp = float2(-axisDir.y, axisDir.x);
            float2 rel = uv - anchorPos;
            float along = dot(rel, axisDir) / axisLen; // 0 at anchor, 1 at displaced
            float across = dot(rel, perp);
            // Vibration: sine envelope peaks at midpoint, damps at endpoints
            float envelope = sin(along * M_PI_F) * stretch;
            float vibration = sin(along * 12.0f + time * 15.0f) * envelope * restRadius * 0.3f;
            // Shrink the distance slightly where the vibration wave passes
            float bandInfluence = smoothstep(restRadius * 3.0f, 0.0f, abs(across - vibration));
            dBlend -= bandInfluence * restRadius * 0.15f * stretch;
        }
    }
    
    return dBlend;
}

// Composite the spring blob widget onto the fractal color.
// Renders a translucent glassy blob with rim highlight.
FORCE_INLINE half3 compositeSpringBlob(half3 col, float2 uv, Uniforms uniforms) {
    if (uniforms.springVisible == 0) return col;
    
    float2 displacement2D = float2(uniforms.springDisplacementX, -uniforms.springDisplacementY);
    float stretch = saturate(uniforms.springStretch / 0.5f); // normalize to 0-1 (maxDisplacement = 0.5)
    
    float d = springBlobSDF(uv, uniforms.springAnchorNDC, displacement2D,
                            uniforms.springRestRadius, stretch, uniforms.time);
    
    // Blob fill: translucent with soft edge
    float fillAlpha = smoothstep(0.005f, -0.005f, d);
    // Rim highlight: bright edge
    float rimAlpha = smoothstep(0.008f, 0.002f, abs(d)) * 0.6f;
    
    // Direction indicator: subtle arrow/gradient showing pull direction
    float dirBrightness = 0.0f;
    if (stretch > 0.05f) {
        float2 displacedPos = uniforms.springAnchorNDC + displacement2D;
        float2 toDisplaced = normalize(displacedPos - uniforms.springAnchorNDC);
        float2 rel = uv - uniforms.springAnchorNDC;
        dirBrightness = saturate(dot(normalize(rel + 0.001f), toDisplaced)) * stretch * 0.3f;
    }
    
    // Color: cool translucent blue-white with stretch tinting toward warm
    half3 blobColor = mix(half3(0.6h, 0.75h, 1.0h), half3(1.0h, 0.7h, 0.4h), half(stretch));
    half3 rimColor = half3(0.9h, 0.95h, 1.0h);
    
    half3 result = col;
    result = mix(result, blobColor * (1.0h + half(dirBrightness)), half(fillAlpha * 0.35f));
    result += rimColor * half(rimAlpha);
    
    return result;
}

// Shared fragment body for Mandelbox rendering

inline FragmentOutput fragmentMain(ColorInOut in,
                                   Uniforms uniforms,
                                   float2 fragCoord,
                                   float time,
                                   float warmStartT = -1.0f)
{
    FragmentOutput output;

    float3 cameraPos = (uniforms.inverseModelViewMatrix * float4(0,0,0,1)).xyz;
    float3 rd = normalize(in.modelPos - cameraPos);
    
    // === Get fractal type and parameters ===
    int fractalType = uniforms.fractalType;
    float quality = 1.0;
    int lodIterations = max(int(uniforms.fractalIterations), 2);
    int maxSteps = uniforms.maxRaySteps;

    float3 marchOrigin = cameraPos;
    float3 marchDir = rd;
    applySphericalInversionRay(marchOrigin, marchDir, uniforms.sphericalInversionMode, uniforms.sphericalInversionRadius);

    // Use precomputed fractal params (powr() and divisions done on CPU)
    FractalParams fractalParams = makeFractalParamsFromPrecomputed(
        uniforms.precomputedFractal,
        uniforms.minDistance,
        marchOrigin, uniforms.safetyBubbleRadius, uniforms.safetyBubbleEnabled, uniforms.safetyBubbleShape, uniforms.safetyBubbleFadeEnabled, uniforms.safetyBubbleFadeWidth, uniforms.safetyBubbleStrength, uniforms.sphereProjectionBlend, uniforms.sphereProjectionRadius);

    half3 col = half3(0.0h);
    float2 ret;
    OrbitCache hitCache = makeEmptyOrbitCache();

    // === TEMPORAL DEPTH WARM-START ===
    // When the caller reprojected a valid previous-frame hit distance, march a
    // narrow window around it with a reduced step budget (typically ~5-10 steps
    // instead of hundreds). On a window miss (disocclusion / stale history) we
    // fall back to the full march, so the warm start can never change WHAT is
    // hit — only how fast we find it.
    SceneResult sceneResult;
    bool needFullMarch = true;
    if (FC_WARM_START_ON && warmStartT > 0.0f) {
        sceneResult = SceneWithCacheFromStart(marchOrigin, marchDir, warmStartT, fragCoord, quality, maxSteps, uniforms.glowIntensity, uniforms.foldingLimit, fractalParams, lodIterations, time, fractalType, uniforms.formulaParams, int(uniforms.colorIterations), uniforms.stepMultiplier);
        needFullMarch = sceneResult.distGlow.x >= kRayMissThreshold;
    }
    if (needFullMarch) {
        sceneResult = SceneWithCache(marchOrigin, marchDir, fragCoord, quality, maxSteps, uniforms.glowIntensity, uniforms.foldingLimit, fractalParams, lodIterations, time, fractalType, uniforms.formulaParams, int(uniforms.colorIterations), uniforms.boundingSphereRadius, uniforms.stepMultiplier, uniforms.maxViewDistance);
    }
    ret = sceneResult.distGlow;
    hitCache = sceneResult.cache;

    if (ret.x < kRayMissThreshold)
    {
        // Compute hit position and clip-space depth once (used for depth output and debug visualization)
        float3 p = marchOrigin + ret.x * marchDir;
        float4 clipPos = uniforms.projectionMatrix * uniforms.modelViewMatrix * float4(p, 1.0);
        float depth = encodeDepthFromClip(clipPos);
        output.depth = depth;

        float3 nor = GetNormal(p, ret.x, fractalParams, uniforms.foldingLimit, lodIterations, fractalType, uniforms.formulaParams, hitCache);

        {
            // Use precomputed spotlight position and intensity from CPU
            float4 spotData = computeSpotlight(p, uniforms.precomputedLighting.spotLightPosition);
            float3 spot = spotData.xyz;
            float atten = spotData.w;
            
            // Blended lighting (precomputed on CPU — frame-uniform)
            float3 sunDir = uniforms.precomputedLighting.sunDir;
            float sunDiffuseScale = uniforms.precomputedLighting.sunDiffuseScale;
            float lightIntensity = uniforms.precomputedLighting.lightIntensity;

            int shadowIterations = ReducedSecondaryIterations(lodIterations, fractalType, true);
            // Shadow params still need per-pixel bubble center, but use precomputed fractal values
            FractalParams shadowParams = makeFractalParamsFromPrecomputed(
                uniforms.precomputedFractal,
                uniforms.minDistance,
                marchOrigin, uniforms.safetyBubbleRadius, uniforms.safetyBubbleEnabled, uniforms.safetyBubbleShape, uniforms.safetyBubbleFadeEnabled, uniforms.safetyBubbleFadeWidth, uniforms.safetyBubbleStrength, uniforms.sphereProjectionBlend, uniforms.sphereProjectionRadius);

            half shaSpot = half(Shadow(p, spot, quality, uniforms.foldingLimit, shadowParams, shadowIterations, fractalType, uniforms.formulaParams));
            half shaSun = half(Shadow(p, sunDir, quality, uniforms.foldingLimit, shadowParams, shadowIterations, fractalType, uniforms.formulaParams));

            float attenPow = powr(max(atten, kPowEpsilon), kAttenPower);
            half bri = quantizeCelLight(half(max(dot(spot, nor), 0.0) / attenPow * 0.25 * lightIntensity), uniforms.colorScheme);
            half briSun = quantizeCelLight(half(max(dot(sunDir, nor), 0.0) * sunDiffuseScale), uniforms.colorScheme);

            col = ColourWithScheme(p, quality, uniforms.minDistance, uniforms.fractalScale, uniforms.foldingLimit, uniforms.sphereRadius, max(int(uniforms.colorIterations * quality), 2), uniforms.colorScheme, hitCache);
            
            // Add ambient term to prevent harsh shadows
            half hemisphereAO = half(nor.y * 0.5 + 0.5);
            half ambient = 0.15h + hemisphereAO * 0.1h;
            col = (col * bri * shaSpot) + (col * briSun * shaSun) + (col * ambient);

            if (uniforms.colorScheme.cellShadingEnabled == 0) {
                float3 V = -marchDir;
                float NoV = saturate(dot(nor, V));
                float fresnel = fma(1.0f - 0.04f, powr(max(1.0f - NoV, 0.0f), 5.0f), 0.04f);
                float specPower = uniforms.precomputedLighting.specPower;
                float3 Hspot = normalize(spot + V);
                float3 Hsun = normalize(sunDir + V);
                float specSpot = powr(max(dot(nor, Hspot), kPowEpsilon), specPower) * kSpecularIntensity * fresnel;
                float specSun = powr(max(dot(nor, Hsun), kPowEpsilon), specPower) * kSpecularIntensity * fresnel;
                col += half3(specSpot) * shaSpot * bri;
                col += half3(specSun) * shaSun * briSun;
            }
            

        }
        // Depth already written at start of this block via clipPos
    }
    else
    {
        // No hit - far plane (tiny depth so compositor treats as far away)
        output.depth = 1e-7;
    }

    // Apply fog, glow, and clamp using helper functions
    half glow = half(ret.y);
    col = applyFog(col, ret.x, uniforms.precomputedFog);
    col = applyGlow(col, glow);
    col = clampColor(col);

    col = PostEffectsWithScheme(col, half2(in.texCoord), uniforms.colorScheme, uniforms.precomputedAudio, half(uniforms.limitFlash), glow);

    FloorCircleHit floorHit = evaluateFloorCircle(cameraPos, rd, ret.x, uniforms.floorPlane, uniforms.floorCenterRadius);
    col = compositeFloorCircle(col, floorHit);
    if (floorHit.alpha > 0.0f) {
        float3 floorPoint = cameraPos + rd * floorHit.distance;
        float4 floorClipPos = uniforms.projectionMatrix * uniforms.modelViewMatrix * float4(floorPoint, 1.0);
        output.depth = encodeDepthFromClip(floorClipPos);
    }

    // Spring blob navigation widget (screen-space overlay)
    // texCoord is [0,1] — convert to NDC [-1, 1] for SDF
    float2 blobUV = in.texCoord * 2.0f - 1.0f;
    col = compositeSpringBlob(col, blobUV, uniforms);

    output.color = float4(float3(col), 1.0);
    return output;
}

// Reproject this pixel's ray into the previous frame's depth buffer and return
// a conservative march start distance, or -1 when no valid history exists.
// Mirrors the warm-start scheme already proven in adaptiveHierarchical8x8:
// same-pixel probe → refine via reprojection → start at 0.9× the hit distance
// (SceneWithCacheFromStart additionally backs off another 0.3 units).
FORCE_INLINE float computeWarmStartT(
    float2 fragCoord,
    uint eyeIndex,
    constant Uniforms& uniforms,
    float3 marchOrigin,
    float3 marchDir,
    depth2d_array<float, access::sample> prevDepthTex)
{
    if (uniforms.warmStartEnabled == 0) return -1.0f;

    constexpr sampler warmSampler(filter::nearest, address::clamp_to_edge);
    // Miss pixels write ~1e-7 (far in reverse-Z); treat anything at or below
    // that as "no surface" history.
    constexpr float kValidDepthMin = 5e-7f;

    float2 uv = fragCoord / uniforms.renderResolution;
    float dSame = prevDepthTex.sample(warmSampler, uv, eyeIndex);
    if (dSame <= kValidDepthMin) return -1.0f;

    // Same-pixel probe: previous clip → model space point.
    float2 ndc0 = float2(fma(uv.x, 2.0f, -1.0f), -fma(uv.y, 2.0f, -1.0f));
    float4 m0 = uniforms.previousInvViewProjMatrix * float4(ndc0, dSame, 1.0f);
    if (abs(m0.w) <= 1e-6f) return -1.0f;
    float tGuess = dot(m0.xyz / m0.w - marchOrigin, marchDir);
    if (tGuess <= 0.0f) return -1.0f;

    // Refine: project the guess point on OUR ray into the previous frame and
    // read the depth where it actually landed.
    float3 probe = fma(marchDir, float3(tGuess), marchOrigin);
    float4 prevClip = uniforms.previousViewProjMatrix * float4(probe, 1.0f);
    if (prevClip.w <= 1e-5f) return -1.0f;
    float2 prevNDC = prevClip.xy / prevClip.w;
    float2 prevUV = float2(fma(prevNDC.x, 0.5f, 0.5f), fma(prevNDC.y, -0.5f, 0.5f));
    if (any(prevUV < 0.0f) || any(prevUV > 1.0f)) return -1.0f;

    float dRef = prevDepthTex.sample(warmSampler, prevUV, eyeIndex);
    if (dRef <= kValidDepthMin) return -1.0f;
    float4 m1 = uniforms.previousInvViewProjMatrix * float4(prevNDC, dRef, 1.0f);
    if (abs(m1.w) <= 1e-6f) return -1.0f;
    float tRef = dot(m1.xyz / m1.w - marchOrigin, marchDir);
    if (tRef <= 0.0f || tRef >= kRayMissThreshold) return -1.0f;

    return tRef * 0.9f;
}

fragment FragmentOutput fragmentShader(ColorInOut in [[stage_in]],
                               constant UniformsArray & uniformsArray [[buffer(BufferIndexUniforms)]],
                               ushort ampId [[amplification_id]],
                               depth2d_array<float, access::sample> prevDepthTex [[texture(TextureIndexPrevDepth), function_constant(FC_WARM_START_ON)]])
{
    constant Uniforms& uniforms = uniformsArray.uniforms[ampId];
    float2 fragCoord = in.position.xy;

    // === GMT-FRACTALS: Halton Sub-Pixel Jitter ===
    // Apply sub-pixel jitter for temporal AA when geometry is stable.
    // This shifts the ray slightly each frame, providing free supersampling
    // via the display's temporal integration at 90Hz.
    fragCoord += uniforms.jitterOffset;

    float warmStartT = -1.0f;
    if (FC_WARM_START_ON) {
        // Warm start only runs without spherical inversion (CPU gates the flag),
        // so the unwarped camera ray here matches fragmentMain's march ray.
        float3 cameraPos = (uniforms.inverseModelViewMatrix * float4(0,0,0,1)).xyz;
        float3 rd = normalize(in.modelPos - cameraPos);
        warmStartT = computeWarmStartT(fragCoord, ampId, uniforms, cameraPos, rd, prevDepthTex);
    }

    // Render fractal
    return fragmentMain(in, uniforms, fragCoord, uniforms.time, warmStartT);
}

fragment FragmentOutput fragmentShaderMono(ColorInOut in [[stage_in]],
                               constant UniformsArray & uniformsArray [[buffer(BufferIndexUniforms)]])
{
    Uniforms uniforms = uniformsArray.uniforms[0];
    float2 fragCoord = in.position.xy;

    fragCoord += uniforms.jitterOffset;

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
                               uint quadLaneId [[thread_index_in_quadgroup]])
{
    FragmentOutput output;
    Uniforms uniforms = uniformsArray.uniforms[ampId];
    float2 fragCoord = in.position.xy;
    
    // === GMT-FRACTALS: Halton Sub-Pixel Jitter for quad-shared path ===
    fragCoord += uniforms.jitterOffset;
    
    float time = uniforms.time;

    float3 cameraPos = (uniforms.inverseModelViewMatrix * float4(0,0,0,1)).xyz;
    float3 rd = normalize(in.modelPos - cameraPos);
    
    int fractalType = uniforms.fractalType;
    int lodIterations = max(int(uniforms.fractalIterations), 2);
    int maxSteps = uniforms.maxRaySteps;

    float3 marchOrigin = cameraPos;
    float3 marchDir = rd;
    applySphericalInversionRay(marchOrigin, marchDir, uniforms.sphericalInversionMode, uniforms.sphericalInversionRadius);

    // Use precomputed fractal params (powr() and divisions done on CPU)
    FractalParams fractalParams = makeFractalParamsFromPrecomputed(
        uniforms.precomputedFractal,
        uniforms.minDistance,
        marchOrigin, uniforms.safetyBubbleRadius, uniforms.safetyBubbleEnabled, uniforms.safetyBubbleShape, uniforms.safetyBubbleFadeEnabled, uniforms.safetyBubbleFadeWidth, uniforms.safetyBubbleStrength, uniforms.sphereProjectionBlend, uniforms.sphereProjectionRadius);

    // === QUAD-SHARED COARSE PASS: Leader finds approximate start distance ===
    // Lane 0 does a cheap coarse raymarch, then broadcasts the result.
    // All 4 lanes then do a shorter fine march from that starting point,
    // significantly reducing total Map() evaluations.
    float coarseStartT = 0.05;
    {
        float leaderCoarseT = 0.05;
        if (quadLaneId == 0) {
            leaderCoarseT = SceneCoarse(marchOrigin, marchDir, uniforms.foldingLimit, fractalParams, lodIterations, fractalType, uniforms.formulaParams, uniforms.maxViewDistance);
        }
        coarseStartT = quad_broadcast(leaderCoarseT, 0);
    }
    
    SceneResult sceneResult;
    if (coarseStartT < kRayMissThreshold) {
        // Coarse pass found something — start fine march from nearby
        sceneResult = SceneWithCacheFromStart(marchOrigin, marchDir, coarseStartT, fragCoord, 1.0, maxSteps, uniforms.glowIntensity, uniforms.foldingLimit, fractalParams, lodIterations, time, fractalType, uniforms.formulaParams, int(uniforms.colorIterations), uniforms.stepMultiplier);
    } else {
        // Coarse pass missed — full march needed
        sceneResult = SceneWithCache(marchOrigin, marchDir, fragCoord, 1.0, maxSteps, uniforms.glowIntensity, uniforms.foldingLimit, fractalParams, lodIterations, time, fractalType, uniforms.formulaParams, int(uniforms.colorIterations), uniforms.boundingSphereRadius, uniforms.stepMultiplier, uniforms.maxViewDistance);
    }
    float2 ret = sceneResult.distGlow;
    OrbitCache hitCache = sceneResult.cache;
    
    float adjustedDist = ret.x;
    float glow = ret.y;
    
    half3 col = half3(0.0h);
    
    if (ret.x < kRayMissThreshold)
    {
        float3 p = marchOrigin + adjustedDist * marchDir;
        
        float3 nor = GetNormal(p, adjustedDist, fractalParams, uniforms.foldingLimit, lodIterations, fractalType, uniforms.formulaParams, hitCache);
        
        // Quad-shared shadows with optional per-pixel fallback
        const bool shareShadows = is_function_constant_defined(FC_SHARE_SHADOWS)
            ? FC_SHARE_SHADOWS
            : (uniforms.lightingSoftness < 0.9f);
        half shaSpot = 1.0h;
        half shaSun = 1.0h;
        
        int shadowIterations = ReducedSecondaryIterations(lodIterations, fractalType, true);
        FractalParams shadowParams = makeFractalParamsFromPrecomputed(
            uniforms.precomputedFractal,
            uniforms.minDistance,
            marchOrigin, uniforms.safetyBubbleRadius, uniforms.safetyBubbleEnabled, uniforms.safetyBubbleShape, uniforms.safetyBubbleFadeEnabled, uniforms.safetyBubbleFadeWidth, uniforms.safetyBubbleStrength, uniforms.sphereProjectionBlend, uniforms.sphereProjectionRadius);
        
        // Use precomputed lighting from CPU with helper function
        float4 spotData = computeSpotlight(p, uniforms.precomputedLighting.spotLightPosition);
        float3 spot = spotData.xyz;
        float atten = spotData.w;
        
        // Blended lighting (precomputed on CPU — frame-uniform)
        float3 sunDir = uniforms.precomputedLighting.sunDir;
        float sunDiffuseScale = uniforms.precomputedLighting.sunDiffuseScale;
        float lightIntensity = uniforms.precomputedLighting.lightIntensity;

        if (shareShadows) {
            if (quadLaneId == 0) {
                shaSpot = half(Shadow(p, spot, 0.8, uniforms.foldingLimit, shadowParams, shadowIterations, fractalType, uniforms.formulaParams));
                shaSun = half(Shadow(p, sunDir, 0.8, uniforms.foldingLimit, shadowParams, shadowIterations, fractalType, uniforms.formulaParams));
            }
            shaSpot = quad_broadcast(shaSpot, 0);
            shaSun = quad_broadcast(shaSun, 0);
        } else {
            shaSpot = half(Shadow(p, spot, 0.8, uniforms.foldingLimit, shadowParams, shadowIterations, fractalType, uniforms.formulaParams));
            shaSun = half(Shadow(p, sunDir, 0.8, uniforms.foldingLimit, shadowParams, shadowIterations, fractalType, uniforms.formulaParams));
        }
        
        // Per-pixel lighting with shared shadows
        float attenPow = powr(max(atten, kPowEpsilon), kAttenPower);
        half bri = quantizeCelLight(half(max(dot(spot, nor), 0.0) / attenPow * 0.25 * lightIntensity), uniforms.colorScheme);
        half briSun = quantizeCelLight(half(max(dot(sunDir, nor), 0.0) * sunDiffuseScale), uniforms.colorScheme);
        
        col = ColourWithScheme(p, 1.0, uniforms.minDistance, uniforms.fractalScale, uniforms.foldingLimit, uniforms.sphereRadius, max(int(uniforms.colorIterations), 2), uniforms.colorScheme, hitCache);
        
        // Add ambient term to prevent harsh shadows
        half hemisphereAO = half(nor.y * 0.5 + 0.5);
        half ambient = 0.15h + hemisphereAO * 0.1h;
        col = (col * bri * shaSpot) + (col * briSun * shaSun) + (col * ambient);
        
        // Specular
        if (uniforms.colorScheme.cellShadingEnabled == 0) {
            float3 ref = reflect(marchDir, nor);
            float specSpot = powr(max(max(dot(spot, ref), 0.0), kPowEpsilon), kSpecularPower) * kSpecularIntensity * lightIntensity;
            float specSun = powr(max(max(dot(sunDir, ref), 0.0), kPowEpsilon), kSpecularPower) * kSpecularIntensity;
            col += half3(specSpot) * shaSpot * bri;
            col += half3(specSun) * shaSun * briSun;
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
    col = applyFog(col, adjustedDist, uniforms.precomputedFog);
    col = applyGlow(col, glowH);
    col = clampColor(col);
    
    col = PostEffectsWithScheme(col, half2(in.texCoord), uniforms.colorScheme, uniforms.precomputedAudio, half(uniforms.limitFlash), glowH);
    FloorCircleHit floorHit = evaluateFloorCircle(cameraPos, rd, adjustedDist, uniforms.floorPlane, uniforms.floorCenterRadius);
    col = compositeFloorCircle(col, floorHit);
    if (floorHit.alpha > 0.0f) {
        float3 floorPoint = cameraPos + rd * floorHit.distance;
        float4 floorClipPos = uniforms.projectionMatrix * uniforms.modelViewMatrix * float4(floorPoint, 1.0);
        output.depth = encodeDepthFromClip(floorClipPos);
    }
    
    // Spring blob navigation widget (screen-space overlay)
    float2 blobUV = in.texCoord * 2.0f - 1.0f;
    col = compositeSpringBlob(col, blobUV, uniforms);
    
    output.color = float4(float3(col), 1.0);
    
    return output;
}

// === Format Conversion Shaders for MetalFX ===
// Used to convert rgba16Float MetalFX output to drawable format (BGRA8Unorm_sRGB)
// Also handles aspect ratio correction when MetalFX uses physical-sized textures

struct FormatConversionParams {
    float aspectCorrection;  // physicalAspect / screenAspect (< 1.0 means horizontally squished)
    float rcasStrength;      // RCAS sharpening strength: 0.0 = off, 1.0 = max
    float pad0;
    float pad1;
};

// ─────────────────────────────────────────────────────────────────────────────
// RCAS — Robust Contrast Adaptive Sharpening (AMD FSR 1.0)
// Applied inline during the MetalFX resolve pass to recover detail lost in the
// spatial upscale. 5-tap cross, noise-adaptive negative lobe, neighbourhood-
// clamped to prevent haloing. Zero extra render passes — runs in the existing
// resolve fragment shader.
// ─────────────────────────────────────────────────────────────────────────────
static inline float3 rcasSharpen(
    texture2d_array<float> tex,
    float2 uv,
    float2 rcpSize,   // 1.0 / float2(tex.width, tex.height)
    uint   eye,
    float  strength   // 0.0 = off, 1.0 = max adaptive sharpening
) {
    constexpr sampler s(filter::nearest, address::clamp_to_edge);

    // 5-tap cross neighbourhood.
    // Pre-clamp the off-centre taps to the texel-centre interior so the sampler
    // never has to hardware-clamp an out-of-range coordinate. This sidesteps a
    // Metal driver bug (FB172520325 / 177318505, notably Apple-family-10 GPUs)
    // where a clamp-to-edge read can return ZERO instead of the edge texel — here
    // that would feed black into the anti-ring clamp and leave a dark fringe on
    // the outermost pixel row/column. With nearest filtering, clamping to the
    // texel-centre range is identical to working clamp-to-edge on healthy GPUs.
    float2 lo = rcpSize * 0.5;
    float2 hi = 1.0 - lo;
    float3 b = tex.sample(s, clamp(uv + float2( 0.0,       -rcpSize.y), lo, hi), eye).rgb;
    float3 d = tex.sample(s, clamp(uv + float2(-rcpSize.x,  0.0      ), lo, hi), eye).rgb;
    float3 e = tex.sample(s, uv,                                                 eye).rgb;
    float3 f = tex.sample(s, clamp(uv + float2( rcpSize.x,  0.0      ), lo, hi), eye).rgb;
    float3 h = tex.sample(s, clamp(uv + float2( 0.0,        rcpSize.y), lo, hi), eye).rgb;

    // Luma weights — perceptual (2G + R + B unnormalised, consistent with FSR)
    const float3 kLuma = float3(0.5, 1.0, 0.5);
    float bL = dot(b, kLuma), dL = dot(d, kLuma), eL = dot(e, kLuma);
    float fL = dot(f, kLuma), hL = dot(h, kLuma);

    // Neighbourhood min/max for anti-ringing clamp
    float3 mn4 = min(min(b, d), min(f, h));
    float3 mx4 = max(max(b, d), max(f, h));

    // Noise suppression: reduce sharpening in near-flat or high-frequency regions
    float maxL = max(max(bL, dL), max(fL, hL));
    float minL = min(min(bL, dL), min(fL, hL));
    float nz   = abs(0.25 * (bL + dL + fL + hL) - eL) / max(maxL - minL, 1.0 / 255.0);
    float ns   = saturate(1.0 - nz);  // 1 = smooth region (sharpen more), 0 = noisy (back off)

    // Negative lobe weight, max -0.125 to prevent overshoot / ringing
    float w = max(-0.125, -0.125 * strength * ns);

    // 5-tap sharp: centre positive, neighbours negative
    float3 result = (b + d + f + h) * w + e * (1.0 + 4.0 * (-w));

    // Clamp to neighbourhood to prevent haloing
    return clamp(result, min(mn4, e), max(mx4, e));
}

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

// Stereo fragment shader — samples from the MetalFX upscaled output and applies
// RCAS (Robust Contrast Adaptive Sharpening) to recover detail softened by the
// spatial upscale. Uses 5-tap nearest reads; no bilinear blurring on top.
fragment float4 formatConversionFragmentStereo(FormatConversionVertexOut in [[stage_in]],
                                                texture2d_array<float> sourceTexture [[texture(0)]],
                                                constant FormatConversionParams& params [[buffer(0)]]) {
    float2 uv = in.texCoord;
    if (params.aspectCorrection != 1.0) {
        uv.x = 0.5 + (uv.x - 0.5) * params.aspectCorrection;
    }

    float2 rcpSize = 1.0 / float2(sourceTexture.get_width(), sourceTexture.get_height());

    float3 color;
    if (params.rcasStrength > 0.0) {
        color = rcasSharpen(sourceTexture, uv, rcpSize, in.eyeIndex, params.rcasStrength);
    } else {
        constexpr sampler s(filter::nearest, address::clamp_to_edge);
        color = sourceTexture.sample(s, uv, in.eyeIndex).rgb;
    }
    return float4(color, 1.0);
}

struct DepthOutput {
    float depth [[depth(any)]];
};

// Phase 2.7: Merged color + depth resolve. Outputs both attachments from a
// single fragment invocation so we don't pay the per-tile load/store and
// command-encoder overhead of two separate render passes.
struct ColorDepthOutput {
    float4 color [[color(0)]];
    float depth  [[depth(any)]];
};

fragment ColorDepthOutput formatConversionFragmentStereoMerged(FormatConversionVertexOut in [[stage_in]],
                                                                texture2d_array<float> sourceColor [[texture(0)]],
                                                                depth2d_array<float> sourceDepth  [[texture(1)]],
                                                                constant FormatConversionParams& params [[buffer(0)]]) {
    float2 uv = in.texCoord;
    if (params.aspectCorrection != 1.0) {
        uv.x = 0.5 + (uv.x - 0.5) * params.aspectCorrection;
    }

    ColorDepthOutput out;

    float2 rcpSize = 1.0 / float2(sourceColor.get_width(), sourceColor.get_height());
    float3 color;
    if (params.rcasStrength > 0.0) {
        color = rcasSharpen(sourceColor, uv, rcpSize, in.eyeIndex, params.rcasStrength);
    } else {
        constexpr sampler s(filter::nearest, address::clamp_to_edge);
        color = sourceColor.sample(s, uv, in.eyeIndex).rgb;
    }
    out.color = float4(color, 1.0);

    constexpr sampler depthSampler(mag_filter::nearest, min_filter::nearest,
                                    address::clamp_to_edge);
    out.depth = sourceDepth.sample(depthSampler, uv, in.eyeIndex);
    return out;
}

// Stereo depth resolve fragment shader.
// Preserve low-res depth discontinuities instead of averaging foreground and
// background depths. Blended depth edges make compositor reprojection treat
// projected surfaces as flatter than the color stereo pair suggests.
fragment DepthOutput depthUpscaleFragmentStereo(FormatConversionVertexOut in [[stage_in]],
                                                 depth2d_array<float> sourceTexture [[texture(0)]],
                                                 constant FormatConversionParams& params [[buffer(0)]]) {
    constexpr sampler textureSampler(mag_filter::nearest, min_filter::nearest,
                                      address::clamp_to_edge);
    
    DepthOutput out;
    float2 uv = in.texCoord;
    if (params.aspectCorrection != 1.0) {
        uv.x = 0.5 + (uv.x - 0.5) * params.aspectCorrection;
    }
    out.depth = sourceTexture.sample(textureSampler, uv, in.eyeIndex);
    return out;
}

// === macOS single-view blit (MetalFX upscaled output → drawable) ===
// The Mac renderer upscales into an offscreen bgra8Unorm_srgb texture, then
// copies it to the drawable with this full-screen-triangle pass. Single-view
// (no amplification), 2D source — distinct from the stereo array variants above.
struct MacBlitVertexOut {
    float4 position [[position]];
    float2 texCoord;
};

vertex MacBlitVertexOut macBlitVertex(uint vertexID [[vertex_id]]) {
    MacBlitVertexOut out;
    float2 p;
    p.x = (vertexID == 1) ? 3.0 : -1.0;
    p.y = (vertexID == 2) ? 3.0 : -1.0;
    out.position = float4(p, 0.0, 1.0);
    out.texCoord = float2((p.x + 1.0) * 0.5, (1.0 - p.y) * 0.5);
    return out;
}

fragment float4 macBlitFragment(MacBlitVertexOut in [[stage_in]],
                                texture2d<float> source [[texture(0)]]) {
    constexpr sampler s(mag_filter::nearest, min_filter::nearest, address::clamp_to_edge);
    return float4(source.sample(s, in.texCoord).rgb, 1.0);
}

// === macOS temporal-upscaling motion vectors (Stage B) ===
// Separate Mac-only pass that reconstructs each pixel's world position from the
// raymarch's offscreen depth (clipPos.z/clipPos.w, standard 0..1) and reprojects
// it through the previous frame's view-projection to produce a screen-space
// motion vector for MTLFXTemporalScaler. Deliberately avoids touching the shared
// `Uniforms`/`fragmentMain` — the matrices arrive in a dedicated small buffer.
//
// `currentInvViewProj` is the inverse of the JITTERED current view-projection
// (matching the jittered depth), so the recovered world point is exact. Motion
// is then computed from the UN-jittered current/previous view-projections so the
// vector carries pure geometric motion (MetalFX handles jitter separately).
struct MacMotionParams {
    float4x4 currentInvViewProj;        // inverse(jittered P*MV) — depth → world
    float4x4 currentViewProjNoJitter;   // un-jittered current P*MV
    float4x4 previousViewProjNoJitter;  // un-jittered previous P*MV
};

fragment float2 macMotionFragment(MacBlitVertexOut in [[stage_in]],
                                  depth2d<float> depthTex [[texture(0)]],
                                  constant MacMotionParams& params [[buffer(0)]]) {
    constexpr sampler depthSampler(mag_filter::nearest, min_filter::nearest,
                                   address::clamp_to_edge);
    float depth = depthTex.sample(depthSampler, in.texCoord);

    // No-hit background writes a near-zero depth; reprojecting it yields garbage,
    // so treat it as static (zero motion → MetalFX keeps the history sample).
    if (depth < 1e-4) {
        return float2(0.0);
    }

    // texCoord (origin top-left) → NDC.
    float2 ndc = float2(in.texCoord.x * 2.0 - 1.0, 1.0 - in.texCoord.y * 2.0);
    float4 worldH = params.currentInvViewProj * float4(ndc, depth, 1.0);
    float3 world = worldH.xyz / worldH.w;

    float4 curC = params.currentViewProjNoJitter * float4(world, 1.0);
    float4 prevC = params.previousViewProjNoJitter * float4(world, 1.0);
    float2 curN = curC.xy / curC.w;
    float2 prevN = prevC.xy / prevC.w;

    // NDC delta → UV delta (0..1). MetalFX `motionVectorScale` multiplies by the
    // input pixel dimensions to recover pixels. Y is flipped for texture space.
    float2 motionNDC = curN - prevN;
    return float2(motionNDC.x * 0.5, -motionNDC.y * 0.5);
}
