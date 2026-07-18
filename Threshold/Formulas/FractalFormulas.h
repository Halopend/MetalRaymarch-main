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
FORCE_INLINE float DE_ConstructionPyramid_Dist(float3 p, float height,
                                                float baseHalfWidth) {
    float baseScale = 2.0f * max(baseHalfWidth, 0.001f);
    float h = max(height, 0.001f) / baseScale;
    float3 x = p / baseScale;
    // The canonical pyramid has its base at y=0 and apex at y=h. Shift it so
    // the selected primitive remains centered like every other solid here.
    x.y += 0.5f * h;
    x.xz = abs(x.xz);
    if (x.z > x.x) { float swapValue = x.x; x.x = x.z; x.z = swapValue; }
    x.xz -= float2(0.5f);

    float m2 = h * h + 0.25f;
    float3 q = float3(x.z, h * x.y - 0.5f * x.x, h * x.x + 0.5f * x.y);
    float s = max(-q.x, 0.0f);
    float t = clamp((q.y - 0.5f * x.z) / (m2 + 0.25f), 0.0f, 1.0f);
    float a = m2 * (q.x + s) * (q.x + s) + q.y * q.y;
    float b = m2 * (q.x + 0.5f * t) * (q.x + 0.5f * t)
            + (q.y - m2 * t) * (q.y - m2 * t);
    float d2 = min(q.y, -q.x * m2 - q.y * 0.5f) > 0.0f ? 0.0f : min(a, b);
    float d = sqrt((d2 + q.z * q.z) / m2) * sign(max(q.z, -x.y));
    return d * baseScale;
}

// These three plane-based distances deliberately match safetyBubbleDistance()
// so a Bounding shape promoted to a construction seed keeps the same silhouette
// and radius convention.
FORCE_INLINE float DE_ConstructionTetrahedron_Dist(float3 p, float radius) {
    constexpr float invSqrt3 = 0.5773502691896258f;
    float faceOffset = radius * invSqrt3;
    float d1 = dot(p, float3( invSqrt3,  invSqrt3,  invSqrt3));
    float d2 = dot(p, float3( invSqrt3, -invSqrt3, -invSqrt3));
    float d3 = dot(p, float3(-invSqrt3,  invSqrt3, -invSqrt3));
    float d4 = dot(p, float3(-invSqrt3, -invSqrt3,  invSqrt3));
    return max(max(d1, d2), max(d3, d4)) - faceOffset;
}

FORCE_INLINE float DE_ConstructionIcosahedron_Dist(float3 p, float radius) {
    constexpr float phi = 1.618033988749895f;
    constexpr float invPhiLen = 0.5257311121191336f;
    constexpr float invTriLen = 0.5773502691896258f;
    constexpr float axisScale = 0.85065080835204f;
    float3 q = abs(p);
    float d1 = dot(q, float3(1.0f, 1.0f, 1.0f) * invTriLen);
    float d2 = dot(q, float3(0.0f, 1.0f, phi) * invPhiLen);
    float d3 = dot(q, float3(1.0f, phi, 0.0f) * invPhiLen);
    float d4 = dot(q, float3(phi, 0.0f, 1.0f) * invPhiLen);
    return max(max(d1, d2), max(d3, d4)) - radius * axisScale;
}

FORCE_INLINE float DE_ConstructionDodecahedron_Dist(float3 p, float radius) {
    constexpr float phi = 1.618033988749895f;
    constexpr float invPhiLen = 0.5257311121191336f;
    constexpr float axisScale = 0.85065080835204f;
    float3 q = abs(p);
    float d1 = dot(q, float3(phi, 1.0f, 0.0f) * invPhiLen);
    float d2 = dot(q, float3(1.0f, 0.0f, phi) * invPhiLen);
    float d3 = dot(q, float3(0.0f, phi, 1.0f) * invPhiLen);
    return max(d1, max(d2, d3)) - radius * axisScale;
}

FORCE_INLINE float DE_ConstructionPrimitive_Dist(float3 pos, FormulaParams fp,
                                                  float3x3 rot, int iterations) {
    (void)iterations;
    float3 p = hasRot1Precomputed(fp) ? (rot * pos) : pos;
    int kind = clamp(int(round(fp.params[0])), 0, 12);
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
    if (kind == 5) { // vertical capsule
        p.y -= clamp(p.y, -primary, primary);
        return length(p) - max(secondary, 0.001f);
    }
    if (kind == 6) { // capped cylinder
        float2 d = abs(float2(length(p.xz), p.y))
                 - float2(max(secondary, 0.001f), primary);
        return min(max(d.x, d.y), 0.0f) + length(max(d, 0.0f));
    }
    if (kind == 7) { // centered capped cone
        float radius = max(secondary, 0.001f);
        float2 q = float2(length(p.xz), p.y);
        float2 k1 = float2(0.0f, primary);
        float2 k2 = float2(-radius, 2.0f * primary);
        float2 ca = float2(q.x - min(q.x, q.y < 0.0f ? radius : 0.0f),
                           abs(q.y) - primary);
        float2 cb = q - k1 + k2 * clamp(dot(k1 - q, k2) / dot(k2, k2), 0.0f, 1.0f);
        float signValue = (cb.x < 0.0f && ca.y < 0.0f) ? -1.0f : 1.0f;
        return signValue * sqrt(min(dot(ca, ca), dot(cb, cb)));
    }
    if (kind == 8) { // hexagonal prism
        float3 q = abs(p);
        float side = max(q.x * 0.86602540378f + q.z * 0.5f, q.z)
                   - max(secondary, 0.001f);
        return max(q.y - primary, side);
    }
    if (kind == 9) { // centered square pyramid
        return DE_ConstructionPyramid_Dist(p, primary, secondary);
    }
    if (kind == 10) { // tetrahedron, Bounding-compatible radius
        return DE_ConstructionTetrahedron_Dist(p, primary);
    }
    if (kind == 11) { // icosahedron, Bounding-compatible radius
        return DE_ConstructionIcosahedron_Dist(p, primary);
    }
    if (kind == 12) { // dodecahedron, Bounding-compatible radius
        return DE_ConstructionDodecahedron_Dist(p, primary);
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
