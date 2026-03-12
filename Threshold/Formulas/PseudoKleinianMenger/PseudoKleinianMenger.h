//
//  PseudoKleinianMenger.h
//  Threshold
//
//  Pseudo Kleinian hybrid with rotated Menger inner fold.
//  Ported from Fragmentarium "05-PseudoKleinianMenger_03.frag" (Knighty).
//
//  Parameter mapping (FormulaParams.params[0..15]):
//    [0]  Size          Sphere-inversion radius        (default 1.46218)
//    [1]  CSize.x       Clamp box X                    (default 1.0)
//    [2]  CSize.y       Clamp box Y                    (default 1.0)
//    [3]  CSize.z       Clamp box Z                    (default 1.0)
//    [4]  C.x           Constant offset X              (default -0.11024)
//    [5]  C.y           Constant offset Y              (default 0.0)
//    [6]  C.z           Constant offset Z              (default 0.0)
//    [7]  Offset.x      Menger offset X                (default 1.26088)
//    [8]  Offset.y      Menger offset Y                (default 1.52172)
//    [9]  Offset.z      Menger offset Z                (default -0.69564)
//    [10] iScale        Inner Menger scale             (default 4.0)
//    [11] v1            Min scale factor k             (default 1.0)
//    [12] v3            Extra scale addend (÷10)       (default 1.0)
//    [13] w1.x          Subtraction factor X           (default 0.85484)
//    [14] w1.y          Subtraction factor Y           (default 1.0)
//    [15] w1.z          Subtraction factor Z           (default 0.80646)
//
//  Hardcoded from the Default preset:
//    MI2=16, v2=(2,2,2), DEoffset=0, iIterations=3, Bailout=100,
//    iSize=0.5, plnormal=(1,0,0), iOffset=(0.850651,0.525731,0)
//
//  rotMatrix1 → combined Menger rotation (M = rot2 * rot1)
//

#ifndef PseudoKleinianMenger_h
#define PseudoKleinianMenger_h

#include "../FractalFormulaCommon.h"

// ---------------------------------------------------------------------------
// Inner Menger fold (icosahedral folds + scale + rotate)
// ---------------------------------------------------------------------------
FORCE_INLINE float PKM_Menger(float3 z, float iScale, float3 iOffset,
                               float bailout, float iSize, float3 plnormal,
                               int iIterations, float3x3 rotM) {
    float s = 1.0f;
    for (int i = 0; i < iIterations && dot(z, z) < bailout; i++) {
        // Dodecahedral folds (sort axes)
        z = abs(z);
        if (z.x < z.y) { float t = z.x; z.x = z.y; z.y = t; }
        if (z.x < z.z) { float t = z.x; z.x = z.z; z.z = t; }
        if (z.y < z.z) { float t = z.y; z.y = z.z; z.z = t; }

        z = iScale * z - iOffset * (iScale - 1.0f);
        if (z.z < -0.5f * iOffset.z * (iScale - 1.0f))
            z.z += iOffset.z * (iScale - 1.0f);

        // Rotate then rescale
        z = rotM * z;
        s /= iScale;
    }
    // Distance to plane through (iSize, 0, 0) with normal plnormal
    return abs(s * dot(z - float3(iSize, 0.0f, 0.0f), normalize(plnormal)));
}

// ---------------------------------------------------------------------------
// Outer PK iteration → calls Menger at the end  (with orbit tracking)
// ---------------------------------------------------------------------------
FORCE_INLINE float DE_PseudoKleinianMenger(float3 pos, FormulaParams fp,
                                            float3x3 rotMatrix,
                                            int iterations, int colorIterations,
                                            thread OrbitData& orbit) {
    float3 p = pos;

    // Unpack tunable params
    const float  Size   = fp.params[0];
    const float3 CSize  = float3(fp.params[1], fp.params[2], fp.params[3]);
    const float3 C      = float3(fp.params[4], fp.params[5], fp.params[6]);
    const float3 Offset = float3(fp.params[7], fp.params[8], fp.params[9]);
    const float  iScale = fp.params[10];
    const float  v1     = fp.params[11];
    const float  v3     = fp.params[12];
    const float3 w1     = float3(fp.params[13], fp.params[14], fp.params[15]);

    // Hardcoded constants from the Default preset
    const float  MI2         = 16.0f;
    const float3 v2          = float3(2.0f, 2.0f, 2.0f);
    const float  DEoffset    = 0.0f;
    const int    iIterations = 3;
    const float  Bailout     = 100.0f;
    const float  iSize       = 0.5f;
    const float3 plnormal    = float3(1.0f, 0.0f, 0.0f);
    const float3 iOffset     = float3(0.850651f, 0.525731f, 0.0f);

    float DEfactor = 1.0f;
    float trap     = 1e20f;
    int   trapIt   = 0;
    float3 trapPos = p;
    int   it       = 0;

    for (int i = 0; i < iterations; i++) {
        // Inf-norm bailout (USE_INF_NORM path from original)
        float3 ap = abs(p);
        float infN = max(ap.x, max(ap.y, ap.z));
        if (infN >= MI2) break;

        p = v2 * clamp(p, -CSize, CSize) - p * w1;

        float r2 = dot(p, p);
        float k  = max(Size / max(r2, 1e-6f), v1);
        float kk = k + (v3 * 0.1f);
        p       *= kk;
        DEfactor *= kk;

        p += C;
        it++;

        // Orbit tracking — inf-norm after offset
        if (i < colorIterations) {
            float m = dot(p, p);
            if (m < trap) {
                trap   = m;
                trapIt = i;
                trapPos = p;
            }
        }
    }

    float dist = abs(0.5f * PKM_Menger(p - Offset, iScale, iOffset,
                                        Bailout, iSize, plnormal,
                                        iIterations, rotMatrix)
                     / max(abs(DEfactor), 1e-6f) - DEoffset);

    orbit.trap          = trap;
    orbit.trapIteration = trapIt;
    orbit.trapPosition  = trapPos;
    orbit.finalP        = p;
    orbit.iterationsUsed = it;

    return dist;
}

// ---------------------------------------------------------------------------
// Distance-only version (no orbit tracking)
// ---------------------------------------------------------------------------
FORCE_INLINE float DE_PseudoKleinianMenger_Dist(float3 pos, FormulaParams fp,
                                                  float3x3 rotMatrix,
                                                  int iterations) {
    float3 p = pos;

    const float  Size   = fp.params[0];
    const float3 CSize  = float3(fp.params[1], fp.params[2], fp.params[3]);
    const float3 C      = float3(fp.params[4], fp.params[5], fp.params[6]);
    const float3 Offset = float3(fp.params[7], fp.params[8], fp.params[9]);
    const float  iScale = fp.params[10];
    const float  v1     = fp.params[11];
    const float  v3     = fp.params[12];
    const float3 w1     = float3(fp.params[13], fp.params[14], fp.params[15]);

    const float  MI2         = 16.0f;
    const float3 v2          = float3(2.0f, 2.0f, 2.0f);
    const float  DEoffset    = 0.0f;
    const int    iIterations = 3;
    const float  Bailout     = 100.0f;
    const float  iSize       = 0.5f;
    const float3 plnormal    = float3(1.0f, 0.0f, 0.0f);
    const float3 iOffset     = float3(0.850651f, 0.525731f, 0.0f);

    float DEfactor = 1.0f;

    for (int i = 0; i < iterations; i++) {
        float3 ap = abs(p);
        float infN = max(ap.x, max(ap.y, ap.z));
        if (infN >= MI2) break;

        p = v2 * clamp(p, -CSize, CSize) - p * w1;

        float r2 = dot(p, p);
        float k  = max(Size / max(r2, 1e-6f), v1);
        float kk = k + (v3 * 0.1f);
        p       *= kk;
        DEfactor *= kk;

        p += C;
    }

    return abs(0.5f * PKM_Menger(p - Offset, iScale, iOffset,
                                  Bailout, iSize, plnormal,
                                  iIterations, rotMatrix)
               / max(abs(DEfactor), 1e-6f) - DEoffset);
}

#endif /* PseudoKleinianMenger_h */
