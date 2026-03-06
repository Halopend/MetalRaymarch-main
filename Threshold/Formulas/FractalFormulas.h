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

// ---------------------------------------------------------------------------
// Common constants, helpers, OrbitData
// ---------------------------------------------------------------------------
#include "FractalFormulaCommon.h"

// ---------------------------------------------------------------------------
// Individual fractal formula headers (one per formula)
// ---------------------------------------------------------------------------
#include "Mandelbulb/Mandelbulb.h"
#include "Menger/Menger.h"
#include "Sierpinski/Sierpinski.h"
#include "Dodecahedron/Dodecahedron.h"
#include "PseudoKleinian/PseudoKleinian.h"
#include "QuaternionJulia/QuaternionJulia.h"
#include "AmazingSurface/AmazingSurface.h"
#include "PseudoKnightyan/PseudoKnightyan.h"
#include "MandalayBox/MandalayBox.h"
#include "SphereSponge/SphereSponge.h"
#include "Octahedron/Octahedron.h"
#include "Icosahedron/Icosahedron.h"
#include "SurfaceKIFS/SurfaceKIFS.h"
#include "MengerSphere/MengerSphere.h"
#include "TheliPseudoKleinian/TheliPseudoKleinian.h"

// ============================================================================
// DISPATCH — distance only
// ============================================================================
FORCE_INLINE float FractalDE_Dispatch(float3 pos, int fractalType, FormulaParams fp, int iterations) {
    switch (fractalType) {
        case FractalTypeMandelbulb:
            return DE_Mandelbulb_Dist(pos, fp, fp.rotMatrix1, iterations);
        case FractalTypeMenger:
            return DE_Menger_Dist(pos, fp, fp.rotMatrix1, iterations);
        case FractalTypeSierpinski:
            return DE_Sierpinski_Dist(pos, fp, fp.rotMatrix1, iterations);
        case FractalTypeDodecahedron:
            return DE_Dodecahedron_Dist(pos, fp, fp.rotMatrix1, iterations);
        case FractalTypePseudoKleinian:
            return DE_PseudoKleinian_Dist(pos, fp, fp.rotMatrix1, iterations);
        case FractalTypeQuaternionJulia:
            return DE_QuaternionJulia_Dist(pos, fp, fp.rotMatrix1, iterations);
        case FractalTypeAmazingSurface:
            return DE_AmazingSurface_Dist(pos, fp, fp.rotMatrix1, iterations);
        case FractalTypePseudoKnightyan:
            return DE_PseudoKnightyan_Dist(pos, fp, fp.rotMatrix1, iterations);
        case FractalTypeMandalayBox:
            return DE_MandalayBox_Dist(pos, fp, fp.rotMatrix1, iterations);
        case FractalTypeSphereSponge:
            return DE_SphereSponge_Dist(pos, fp, fp.rotMatrix1, iterations);
        case FractalTypeOctahedron:
            return DE_Octahedron_Dist(pos, fp, fp.rotMatrix1, iterations);
        case FractalTypeIcosahedron:
            return DE_Icosahedron_Dist(pos, fp, fp.rotMatrix1, iterations);
        case FractalTypeSurfaceKIFS:
            return DE_SurfaceKIFS_Dist(pos, fp, fp.rotMatrix1, iterations);
        case FractalTypeMengerSphere:
            return DE_MengerSphere_Dist(pos, fp, fp.rotMatrix1, iterations);
        case FractalTypeTheliPseudoKleinian:
            return DE_TheliPseudoKleinian_Dist(pos, fp, fp.rotMatrix1, iterations);
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
            return DE_Mandelbulb(pos, fp, fp.rotMatrix1, iterations, colorIterations, orbit);
        case FractalTypeMenger:
            return DE_Menger(pos, fp, fp.rotMatrix1, iterations, colorIterations, orbit);
        case FractalTypeSierpinski:
            return DE_Sierpinski(pos, fp, fp.rotMatrix1, iterations, colorIterations, orbit);
        case FractalTypeDodecahedron:
            return DE_Dodecahedron(pos, fp, fp.rotMatrix1, iterations, colorIterations, orbit);
        case FractalTypePseudoKleinian:
            return DE_PseudoKleinian(pos, fp, fp.rotMatrix1, iterations, colorIterations, orbit);
        case FractalTypeQuaternionJulia:
            return DE_QuaternionJulia(pos, fp, fp.rotMatrix1, iterations, colorIterations, orbit);
        case FractalTypeAmazingSurface:
            return DE_AmazingSurface(pos, fp, fp.rotMatrix1, iterations, colorIterations, orbit);
        case FractalTypePseudoKnightyan:
            return DE_PseudoKnightyan(pos, fp, fp.rotMatrix1, iterations, colorIterations, orbit);
        case FractalTypeMandalayBox:
            return DE_MandalayBox(pos, fp, fp.rotMatrix1, iterations, colorIterations, orbit);
        case FractalTypeSphereSponge:
            return DE_SphereSponge(pos, fp, fp.rotMatrix1, iterations, colorIterations, orbit);
        case FractalTypeOctahedron:
            return DE_Octahedron(pos, fp, fp.rotMatrix1, iterations, colorIterations, orbit);
        case FractalTypeIcosahedron:
            return DE_Icosahedron(pos, fp, fp.rotMatrix1, iterations, colorIterations, orbit);
        case FractalTypeSurfaceKIFS:
            return DE_SurfaceKIFS(pos, fp, fp.rotMatrix1, iterations, colorIterations, orbit);
        case FractalTypeMengerSphere:
            return DE_MengerSphere(pos, fp, fp.rotMatrix1, iterations, colorIterations, orbit);
        case FractalTypeTheliPseudoKleinian:
            return DE_TheliPseudoKleinian(pos, fp, fp.rotMatrix1, iterations, colorIterations, orbit);
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
