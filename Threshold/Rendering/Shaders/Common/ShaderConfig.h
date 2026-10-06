//
//  Shaders.metal
//
// === DEPTH BUFFER NOTES (CRITICAL FOR REPROJECTION/ASW) ===
// Depth encoding is projection-native z/w in [0, 1]. visionOS uses reverse-Z
// (far ~= 0), while the Mac/iPad projection and MetalFX temporal scaler use
// standard depth (far ~= 1). fragmentShader and fragmentShaderMono therefore
// pass their own miss-depth convention into the shared fragment body.
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

// License: N/A (method attribution; no external code license asserted here)
// Author: Tom Lowe
// Found: https://sites.google.com/site/mandelbox/what-is-a-mandelbox

// Basic Map iteration (no tracking) - used by Map()
#define MAP_ITERATION_BASIC(p, p0, foldingLimit, params, invSphereRadiusSq) \
    p.xyz = fma(clamp(p.xyz, -foldingLimit, foldingLimit), float3(2.0), -p.xyz); \
    { float r2 = dot(p.xyz, p.xyz); \
      float t = clamp(1.0f / max(r2, params.sphereRadiusSq), 1.0f, invSphereRadiusSq); \
      p *= t; } \
    p = fma(p, params.scale, p0)

// Half-precision Map iteration; throughput depends on device and workload.
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
// This reproduces the "Accidental Sphere Projection" look (the Space-tab "Sphere
// Projection" control; formerly a dedicated sphere-projected Mandelbox type) as
// an optional layer on the standard Mandelbox fast path. The blend/radius come
// from FractalParams so the decision
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
#import "../../ShaderTypes.h"

using namespace metal;

// === FUNCTION CONSTANTS ===
// These allow the Metal compiler to specialize shaders at pipeline creation time,
// eliminating branches and enabling dead code elimination for significant performance gains.
// The compiler can fully unroll loops with known bounds and remove unused code paths.
//
// Use is_function_constant_defined(FC_*) to check if a constant was provided at pipeline creation.

// Fractal iteration counts - controls loop unrolling in hot Map() function
constant int FC_FRACTAL_ITERATIONS [[function_constant(FCIndexFractalIterations)]];

// Shadow iteration counts (typically fractalIterations - 2)
constant int FC_SHADOW_ITERATIONS [[function_constant(FCIndexShadowIterations)]];

// Feature toggles - allows compiler to eliminate entire code paths
constant bool FC_SAFETY_BUBBLE_ENABLED [[function_constant(FCIndexSafetyBubbleEnabled)]];

// Quality mode - enables aggressive optimizations for lower quality settings
constant int FC_QUALITY_MODE [[function_constant(FCIndexQualityMode)]]; // 0=high, 1=medium, 2=low

// Debug mode - can be compiled out entirely in release builds
constant bool FC_DEBUG_HIERARCHICAL [[function_constant(FCIndexDebugHierarchical)]];

// Max ray marching steps - controls main raymarch loop unrolling
// This is the second most critical loop after Map()
constant int FC_MAX_RAY_STEPS [[function_constant(FCIndexMaxRaySteps)]];

// Devirtualize fractal type dispatch to eliminate unused formulas
constant int FC_FRACTAL_TYPE [[function_constant(FCIndexFractalType)]];

// Neon color mode toggle - eliminates neon orbit trap computation when disabled
// (neon mode requires extra orbit tracking in ColourWithScheme)
constant bool FC_NEON_MODE_ENABLED [[function_constant(FCIndexNeonModeEnabled)]];

// Color iterations - when defined, enables loop unrolling in ColourWithScheme
constant int FC_COLOR_ITERATIONS [[function_constant(FCIndexColorIterations)]];

// Shadow sharing toggle - allows per-pixel shadows when disabled
constant bool FC_SHARE_SHADOWS [[function_constant(FCIndexShareShadows)]];

// Shadow enable toggle - eliminates entire shadow computation when disabled
constant bool FC_SHADOWS_ENABLED [[function_constant(FCIndexShadowsEnabled)]];

// Mandelbulb power - when baked in, the compiler dead-code-eliminates all wrong
// branches in fastPowR and constant-folds power multiplications in the inner loop.
constant int FC_MANDELBULB_POWER [[function_constant(FCIndexMandelbulbPower)]];

// Retired fragment warm-start function-constant slot. Reserved for compatibility
// with older pipeline callers; no fragment history consumer remains.
constant bool FC_WARM_START [[function_constant(FCIndexWarmStart)]];

// Coherent-packet experiment toggle (adaptiveHierarchical8x8 only). When baked
// false (the default settings state), the warm-start probe, the shadow
// normal-coherence gate, and the layer-of-acceptance debug overlay are all
// dead-code-eliminated. Unset (generic/shared pipelines) falls back to the
// runtime uniform so cache-miss fallbacks stay correct.
constant bool FC_COHERENT_PACKET [[function_constant(FCIndexCoherentPacket)]];

// Retired cone prepass slot; preserve numeric function-constant compatibility.
constant bool FC_COARSE_WARM_START [[function_constant(FCIndexCoarseWarmStart)]];

// Sphere-projection presence gate. Undefined pipelines retain the runtime blend
// check; exact scene pipelines bake false for the common unprojected case so the
// projection loop and its extra normalization/mix work disappear from the DE.
constant bool FC_SPHERE_PROJECTION_ENABLED [[function_constant(FCIndexSphereProjection)]];
constant bool FC_SPHERE_PROJECTION_ON = is_function_constant_defined(FC_SPHERE_PROJECTION_ENABLED)
    ? FC_SPHERE_PROJECTION_ENABLED : true;

// Space-warp (Transformations) presence gate (index 3 was free). When baked FALSE
// on a scene that has NO transforms (empty stack, no custom warp), the whole
// space-warp seam — the applyWarpOp switch, the per-op loop, the SpaceWarpOp array
// reads, and the DE-divisor threading (deScale collapses to a compile-time 1.0) —
// is dead-code-eliminated from the hot DE path, freeing registers / raising
// occupancy for the common no-transform case. DEFAULTS TRUE when unset (generic
// fallback, visionOS, screenshot, custom-warp pipelines), so those paths run the
// full stack exactly as before — only the Mac specialized `_SW0` variant bakes it
// off, and only for scenes provably without any warp.
constant bool FC_HAS_SPACEWARP [[function_constant(FCIndexHasSpaceWarp)]];
constant bool FC_HAS_SPACEWARP_ON = is_function_constant_defined(FC_HAS_SPACEWARP) ? FC_HAS_SPACEWARP : true;

// Compiles out the Environment Scrunch DE-tail (grid sample + containment) when
// the device-local toggle is off. Same DEFAULTS-TRUE-when-unset contract as
// FC_HAS_SPACEWARP: generic/fallback pipelines keep the full path; specialized
// pipelines bake it off. The scrunch tail runs in every DE evaluation, so even
// runtime-disabled it costs march-loop registers (measured ~12% GPU on Mac).
constant bool FC_HAS_ENVSCRUNCH [[function_constant(FCIndexHasEnvScrunch)]];
constant bool FC_HAS_ENVSCRUNCH_ON = is_function_constant_defined(FC_HAS_ENVSCRUNCH) ? FC_HAS_ENVSCRUNCH : true;

// Compiles out the hand-field sculpting tail (hand balls + forearm carves).
// macOS has no hand tracking and always bakes this off; visionOS keys it off
// the Hands toggle. Same defaults-true contract (measured ~20% GPU on Mac).
constant bool FC_HAS_HANDFIELD [[function_constant(FCIndexHasHandField)]];
constant bool FC_HAS_HANDFIELD_ON = is_function_constant_defined(FC_HAS_HANDFIELD) ? FC_HAS_HANDFIELD : true;
