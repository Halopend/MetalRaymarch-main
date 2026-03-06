//
//  PseudoKnightyan.h
//  Threshold
//
//  Distance estimator for the Pseudo-Knightyan fractal.
//  params[0-2]=CSize, [3]=Size, [4]=DEfactor, [5]=TwiddleRXY
//
//  OPTIMISATION NOTES (vs. original):
//    A. cos/sin of constant twiddle angle hoisted out of the loop
//       — saves 2 transcendental evaluations × iterations per call.
//    B. Redundant dot(z,z) replaced with k²·r² (twiddle + rot are
//       orthogonal → preserve squared magnitude).
//    C. _Dist variant is a standalone lean body: no orbit tracking,
//       no UpdateTrapMinR2, no OrbitData writes.
//
//  Requires: FractalFormulaCommon.h
//

#ifndef DE_PseudoKnightyan_h
#define DE_PseudoKnightyan_h

FORCE_INLINE float DE_PseudoKnightyan(float3 pos, FormulaParams fp, float3x3 rot,
                                      int iterations, int colorIterations,
                                     thread OrbitData& orbit) {
    float3 csize = float3(fp.params[0], fp.params[1], fp.params[2]);
    float size   = fp.params[3];
    float deFact = fp.params[4];

    // (A) Hoist trig — twiddle is loop-invariant
    float ct = fast::cos(fp.params[5]), st = fast::sin(fp.params[5]);

    float3 z = pos;
    float DEfactor = 1.0f;
    float trap = 1e20f;
    int trapIter = 0;
    float3 trapPos = z;
    int i = 0;

    for (; i < iterations; ++i) {
        // Box fold
        z = clamp(z, -csize, csize) * 2.0f - z;

        // Inversion
        float r2 = dot(z, z);
        float k = max(size / r2, 1.0f);
        z *= k;
        DEfactor *= k;

        // Twiddle rotation XY (ct/st are loop-invariant)
        z.xy = float2(ct * z.x - st * z.y, st * z.x + ct * z.y);

        z = rot * z;

        // (B) Orthogonal transforms preserve magnitude: |z|² = k²·r²
        UpdateTrapMinR2(trap, trapIter, trapPos, k * k * r2, i, colorIterations, z);
    }

    orbit.trap = trap;
    orbit.trapIteration = trapIter;
    orbit.trapPosition = trapPos;
    orbit.finalP = z;
    orbit.iterationsUsed = i;

    float r = fast::length(z);
    return deFact * (r - 0.5f) / DEfactor;
}

// (C) Lean distance-only variant — no orbit tracking overhead.
//     Used by raymarching, shadow, and normal-estimation call paths.
FORCE_INLINE float DE_PseudoKnightyan_Dist(float3 pos, FormulaParams fp, float3x3 rot, int iterations) {
    float3 csize = float3(fp.params[0], fp.params[1], fp.params[2]);
    float size   = fp.params[3];
    float deFact = fp.params[4];
    float ct = fast::cos(fp.params[5]), st = fast::sin(fp.params[5]);

    float3 z = pos;
    float DEfactor = 1.0f;

    for (int i = 0; i < iterations; ++i) {
        z = clamp(z, -csize, csize) * 2.0f - z;

        float r2 = dot(z, z);
        float k = max(size / r2, 1.0f);
        z *= k;
        DEfactor *= k;

        z.xy = float2(ct * z.x - st * z.y, st * z.x + ct * z.y);
        z = rot * z;
    }

    return deFact * (fast::length(z) - 0.5f) / DEfactor;
}

#endif /* DE_PseudoKnightyan_h */
