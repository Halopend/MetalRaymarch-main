//
//  MandalayBox.h
//  Threshold
//
//  Distance estimator for the Mandalay Box fractal.
//  params[0]=Scale, [1]=MinRad2, [2]=DoBoxFold(bool), [3-5]=fo, [6-8]=g,
//  [9]=Serial(bool), [10]=Julia(bool), [11-13]=JuliaC
//
//  Requires: FractalFormulaCommon.h
//

#ifndef DE_MandalayBox_h
#define DE_MandalayBox_h

FORCE_INLINE float DE_MandalayBox(float3 pos, FormulaParams fp, float3x3 rot,
                                  int iterations, int colorIterations,
                                 thread OrbitData& orbit) {
    float scale   = fp.params[0];
    float minR2   = fp.params[1];
    bool doBox    = fp.params[2] > 0.5f;
    float3 fo     = float3(fp.params[3], fp.params[4], fp.params[5]);
    float3 g      = float3(fp.params[6], fp.params[7], fp.params[8]);
    bool serial   = fp.params[9] > 0.5f;
    bool julia    = fp.params[10] > 0.5f;
    float3 juliaC = float3(fp.params[11], fp.params[12], fp.params[13]);

    float3 z = pos;
    float3 c = julia ? juliaC : pos;
    float dr = 1.0f;
    float trap = 1e20f;
    int trapIter = 0;
    float3 trapPos = z;
    int i = 0;

    for (; i < iterations; ++i) {
        // Optional box fold
        if (doBox) {
            z = clamp(z, -fo, fo) * 2.0f - z;
        }

        // ABS fold with offset
        z = abs(z + g) - g;

        // Sphere fold
        float r2 = dot(z, z);
        float k;
        if (serial) {
            k = max(1.0f / max(r2, minR2), 1.0f);
        } else {
            k = r2 < minR2 ? (1.0f / minR2) : (r2 < 1.0f ? (1.0f / r2) : 1.0f);
        }
        z *= k * scale;
        dr = dr * abs(k * scale) + 1.0f;

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
    return (r - abs(scale - 1.0f)) / dr;
}

// Lean distance-only: no orbit tracking, no struct writes.
FORCE_INLINE float DE_MandalayBox_Dist(float3 pos, FormulaParams fp, float3x3 rot, int iterations) {
    float scale   = fp.params[0];
    float minR2   = fp.params[1];
    bool doBox    = fp.params[2] > 0.5f;
    float3 fo     = float3(fp.params[3], fp.params[4], fp.params[5]);
    float3 g      = float3(fp.params[6], fp.params[7], fp.params[8]);
    bool serial   = fp.params[9] > 0.5f;
    bool julia    = fp.params[10] > 0.5f;
    float3 juliaC = float3(fp.params[11], fp.params[12], fp.params[13]);

    float3 z = pos;
    float3 c = julia ? juliaC : pos;
    float dr = 1.0f;

    for (int i = 0; i < iterations; ++i) {
        if (doBox) {
            z = clamp(z, -fo, fo) * 2.0f - z;
        }
        z = abs(z + g) - g;

        float r2 = dot(z, z);
        float k;
        if (serial) {
            k = max(1.0f / max(r2, minR2), 1.0f);
        } else {
            k = r2 < minR2 ? (1.0f / minR2) : (r2 < 1.0f ? (1.0f / r2) : 1.0f);
        }
        z *= k * scale;
        dr = dr * abs(k * scale) + 1.0f;

        z += c;
        z = rot * z;
    }

    return (fast::length(z) - abs(scale - 1.0f)) / dr;
}

#endif /* DE_MandalayBox_h */
