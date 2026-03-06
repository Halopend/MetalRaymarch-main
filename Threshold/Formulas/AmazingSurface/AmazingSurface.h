//
//  AmazingSurface.h
//  Threshold
//
//  Distance estimator for the Amazing Surface / Mandelbox variant fractal.
//  params[0]=Scale, [1]=MinRad2, [2]=FoldType(int), [3-4]=FoldValues,
//  [5-7]=PreTranslation, [8]=Julia(bool), [9-11]=JuliaC
//
//  Requires: FractalFormulaCommon.h
//

#ifndef DE_AmazingSurface_h
#define DE_AmazingSurface_h

FORCE_INLINE float DE_AmazingSurface(float3 pos, FormulaParams fp, float3x3 rot,
                                     int iterations, int colorIterations,
                                    thread OrbitData& orbit) {
    float scale  = fp.params[0];
    float minR2  = fp.params[1];
    int foldType = int(fp.params[2]);
    float2 foldV = float2(fp.params[3], fp.params[4]);
    float3 pre   = float3(fp.params[5], fp.params[6], fp.params[7]);
    bool julia    = fp.params[8] > 0.5f;
    float3 juliaC = float3(fp.params[9], fp.params[10], fp.params[11]);

    float3 z = pos + pre;
    float3 c = julia ? juliaC : pos;
    float dr = 1.0f;

    float trap = 1e20f;
    int trapIter = 0;
    float3 trapPos = z;
    int i = 0;

    for (; i < iterations; ++i) {
        // Fold
        if (foldType == 0) {
            z = abs(z + foldV.x) - abs(z - foldV.x) - z;
        } else if (foldType == 1) {
            z.xy = abs(z.xy + foldV) - abs(z.xy - foldV) - z.xy;
        } else {
            z = abs(z);
        }

        // Sphere fold (Mandelbox-style)
        float r2 = dot(z, z);
        float k = max(scale / max(r2, minR2), 1.0f);
        z *= k;
        dr = dr * abs(k) + 1.0f;

        z += c;
        z = rot * z;

        UpdateTrapMinR2(trap, trapIter, trapPos, dot(z,z), i, colorIterations, z);
    }

    orbit.trap = trap;
    orbit.trapIteration = trapIter;
    orbit.trapPosition = trapPos;
    orbit.finalP = z;
    orbit.iterationsUsed = i;

    float r = fast::length(z);
    return (r - abs(scale - 1.0f)) / dr - 1e-6f;
}

// Lean distance-only: no orbit tracking, no struct writes.
FORCE_INLINE float DE_AmazingSurface_Dist(float3 pos, FormulaParams fp, float3x3 rot, int iterations) {
    float scale  = fp.params[0];
    float minR2  = fp.params[1];
    int foldType = int(fp.params[2]);
    float2 foldV = float2(fp.params[3], fp.params[4]);
    float3 pre   = float3(fp.params[5], fp.params[6], fp.params[7]);
    bool julia    = fp.params[8] > 0.5f;
    float3 juliaC = float3(fp.params[9], fp.params[10], fp.params[11]);

    float3 z = pos + pre;
    float3 c = julia ? juliaC : pos;
    float dr = 1.0f;

    for (int i = 0; i < iterations; ++i) {
        if (foldType == 0) {
            z = abs(z + foldV.x) - abs(z - foldV.x) - z;
        } else if (foldType == 1) {
            z.xy = abs(z.xy + foldV) - abs(z.xy - foldV) - z.xy;
        } else {
            z = abs(z);
        }

        float r2 = dot(z, z);
        float k = max(scale / max(r2, minR2), 1.0f);
        z *= k;
        dr = dr * abs(k) + 1.0f;

        z += c;
        z = rot * z;
    }

    return (fast::length(z) - abs(scale - 1.0f)) / dr - 1e-6f;
}

#endif /* DE_AmazingSurface_h */
