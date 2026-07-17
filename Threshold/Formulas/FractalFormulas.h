//
//  FractalFormulas.h
//  Threshold
//
//  Master include for all fractal distance estimator (DE) functions + dispatch.
//  Each formula lives in its own header under Formulas/{Name}/{Name}.h.
//
//  Included by Shaders.metal after metal_stdlib and ShaderTypes.h.
//  Each formula has:
//    DE_XXX(..., thread OrbitData& orbit) — full orbit-tracking version
//    DE_XXX_Dist(...)                     — distance-only (no orbit)
//
//  Dispatch:
//    FractalDE_Dispatch(pos, fractalType, fp, iterations) → distance only
//    FractalDE_WithOrbit(pos, fractalType, fp, iterations, colorIterations, orbit) → + orbit
//
//  Requires: metal_stdlib, ShaderTypes.h (FormulaParams, FractalType enum),
//            FORCE_INLINE macro (defined in Shaders.metal)
//

#ifndef FractalFormulas_h
#define FractalFormulas_h

#ifndef FORCE_INLINE
#define FORCE_INLINE inline
#endif

// ---------------------------------------------------------------------------
// Common constants, helpers, OrbitData
// ---------------------------------------------------------------------------
#include "FractalFormulaCommon.h"

// ---------------------------------------------------------------------------
// Individual fractal formula headers (one per formula)
// ---------------------------------------------------------------------------
#include "Mandelbulb/Mandelbulb.h"
#include "Menger/Menger.h"
#include "QuaternionJulia/QuaternionJulia.h"
#include "Octahedron/Octahedron.h"
#include "MengerSphere/MengerSphere.h"
#include "TheliPseudoKleinian/TheliPseudoKleinian.h"
#include "Kleinian/Kleinian.h"
#include "BoxFoldMandelbulb/BoxFoldMandelbulb.h"

// ============================================================================
// DISPATCH — distance only
// ============================================================================
FORCE_INLINE float DE_ConstructionPrimitive_Dist(float3 pos, FormulaParams fp,
                                                  float3x3 rot, int iterations) {
    (void)iterations;
    float3 p = hasRot1Precomputed(fp) ? (rot * pos) : pos;
    int kind = clamp(int(round(fp.params[0])), 0, 4);
    float primary = max(fp.params[1], 0.001f);
    float secondary = max(fp.params[2], 0.0f);

    if (kind == 1) { // rounded box
        float radius = min(secondary, primary);
        float3 q = abs(p) - float3(primary - radius);
        return length(max(q, 0.0f)) + min(max(q.x, max(q.y, q.z)), 0.0f) - radius;
    }
    if (kind == 2) { // torus
        float2 q = float2(length(p.xz) - primary, p.y);
        return length(q) - max(secondary, 0.001f);
    }
    if (kind == 3) { // octahedron
        return (abs(p.x) + abs(p.y) + abs(p.z) - primary) * 0.57735026919f;
    }
    // Sphere and the larger Mandelbox terminal sphere share the same SDF.
    return length(p) - primary;
}

FORCE_INLINE float DE_ConstructionPrimitive(float3 pos, FormulaParams fp,
                                             float3x3 rot, int iterations,
                                             int colorIterations,
                                             thread OrbitData& orbit) {
    (void)colorIterations;
    float3 p = hasRot1Precomputed(fp) ? (rot * pos) : pos;
    float d = DE_ConstructionPrimitive_Dist(pos, fp, rot, iterations);
    orbit.trap = dot(p, p);
    orbit.trapIteration = 0;
    orbit.trapPosition = p;
    orbit.finalP = p;
    orbit.iterationsUsed = 1;
    return d;
}

FORCE_INLINE float FractalDE_Dispatch(float3 pos, int fractalType, FormulaParams fp, int iterations) {
    switch (fractalType) {
        case FractalTypeMandelbulb:
        case FractalTypeMandelbulbJulia:
            return DE_Mandelbulb_Dist(pos, fp, fp.rotMatrix1, iterations);
        case FractalTypeMenger:
            return DE_Menger_Dist(pos, fp, fp.rotMatrix1, iterations);
        case FractalTypeQuaternionJulia:
            return DE_QuaternionJulia_Dist(pos, fp, fp.rotMatrix1, iterations);
        case FractalTypeOctahedron:
            return DE_Octahedron_Dist(pos, fp, fp.rotMatrix1, iterations);
        case FractalTypeMengerSphere:
            return DE_MengerSphere_Dist(pos, fp, fp.rotMatrix1, iterations);
        case FractalTypeTheliPseudoKleinian:
            return DE_TheliPseudoKleinian_Dist(pos, fp, fp.rotMatrix1, iterations);
        case FractalTypeKleinian:
            return DE_Kleinian_Dist(pos, fp, fp.rotMatrix1, iterations);
        case FractalTypeBoxFoldMandelbulb:
            return DE_BoxFoldMandelbulb_Dist(pos, fp, fp.rotMatrix1, iterations);
        case FractalTypeConstructionPrimitive:
            return DE_ConstructionPrimitive_Dist(pos, fp, fp.rotMatrix1, iterations);
        // __CUSTOM_DISPATCH_DIST__
        default:
            return 1e10f; // Unknown type — far away
    }
}

// ============================================================================
// DISPATCH — with orbit tracking
// ============================================================================
FORCE_INLINE float FractalDE_WithOrbit(float3 pos, int fractalType, FormulaParams fp,
                                       int iterations, int colorIterations,
                                      thread OrbitData& orbit) {
    switch (fractalType) {
        case FractalTypeMandelbulb:
        case FractalTypeMandelbulbJulia:
            return DE_Mandelbulb(pos, fp, fp.rotMatrix1, iterations, colorIterations, orbit);
        case FractalTypeMenger:
            return DE_Menger(pos, fp, fp.rotMatrix1, iterations, colorIterations, orbit);
        case FractalTypeQuaternionJulia:
            return DE_QuaternionJulia(pos, fp, fp.rotMatrix1, iterations, colorIterations, orbit);
        case FractalTypeOctahedron:
            return DE_Octahedron(pos, fp, fp.rotMatrix1, iterations, colorIterations, orbit);
        case FractalTypeMengerSphere:
            return DE_MengerSphere(pos, fp, fp.rotMatrix1, iterations, colorIterations, orbit);
        case FractalTypeTheliPseudoKleinian:
            return DE_TheliPseudoKleinian(pos, fp, fp.rotMatrix1, iterations, colorIterations, orbit);
        case FractalTypeKleinian:
            return DE_Kleinian(pos, fp, fp.rotMatrix1, iterations, colorIterations, orbit);
        case FractalTypeBoxFoldMandelbulb:
            return DE_BoxFoldMandelbulb(pos, fp, fp.rotMatrix1, iterations, colorIterations, orbit);
        case FractalTypeConstructionPrimitive:
            return DE_ConstructionPrimitive(pos, fp, fp.rotMatrix1, iterations, colorIterations, orbit);
        // __CUSTOM_DISPATCH_ORBIT__
        default:
            orbit.trap = 1e20f;
            orbit.trapIteration = 0;
            orbit.trapPosition = pos;
            orbit.finalP = pos;
            orbit.iterationsUsed = 0;
            return 1e10f;
    }
}

#endif /* FractalFormulas_h */
