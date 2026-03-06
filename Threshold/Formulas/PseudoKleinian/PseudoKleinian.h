//
//  PseudoKleinian.h
//  Threshold
//
//  Distance estimator for the Pseudo-Kleinian fractal.
//  params[0]=Size, [1-3]=CSize, [4-6]=C, [7]=DEoffset, [8-10]=Offset
//
//  Requires: FractalFormulaCommon.h
//

#ifndef DE_PseudoKleinian_h
#define DE_PseudoKleinian_h

FORCE_INLINE float DE_PseudoKleinian(float3 pos, FormulaParams fp, float3x3 rot,
                                     int iterations, int colorIterations,
                                    thread OrbitData& orbit) {
    float size    = fp.params[0];
    float3 csize  = float3(fp.params[1], fp.params[2], fp.params[3]);
    float3 c      = float3(fp.params[4], fp.params[5], fp.params[6]);
    float deOff   = fp.params[7];
    float3 offset = float3(fp.params[8], fp.params[9], fp.params[10]);

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

        z += c;
        z = rot * z;

        // Conditional offset
        if (z.y < z.x) z.xy = z.yx;
        z += offset;
        if (z.y < z.x) z.xy = z.yx;

        UpdateTrapMinR2(trap, trapIter, trapPos, dot(z,z), i, colorIterations, z);
    }

    orbit.trap = trap;
    orbit.trapIteration = trapIter;
    orbit.trapPosition = trapPos;
    orbit.finalP = z;
    orbit.iterationsUsed = i;

    float r = fast::length(z);
    return (r - deOff) / DEfactor;
}

// Lean distance-only: no orbit tracking, no struct writes.
FORCE_INLINE float DE_PseudoKleinian_Dist(float3 pos, FormulaParams fp, float3x3 rot, int iterations) {
    float size    = fp.params[0];
    float3 csize  = float3(fp.params[1], fp.params[2], fp.params[3]);
    float3 c      = float3(fp.params[4], fp.params[5], fp.params[6]);
    float deOff   = fp.params[7];
    float3 offset = float3(fp.params[8], fp.params[9], fp.params[10]);

    float3 z = pos;
    float DEfactor = 1.0f;

    for (int i = 0; i < iterations; ++i) {
        z = clamp(z, -csize, csize) * 2.0f - z;

        float r2 = dot(z, z);
        float k = max(size / r2, 1.0f);
        z *= k;
        DEfactor *= k;

        z += c;
        z = rot * z;

        if (z.y < z.x) z.xy = z.yx;
        z += offset;
        if (z.y < z.x) z.xy = z.yx;
    }

    return (fast::length(z) - deOff) / DEfactor;
}

#endif /* DE_PseudoKleinian_h */
