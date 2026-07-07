//
//  Menger.h
//  Threshold
//
//  Distance estimator for the Menger Sponge fractal.
//  params[0]=Scale, [1-3]=Offset
//  Classic Menger sponge — numerically identical to ReferenceDEs.menger
//  (plus the app's per-iteration rotation, applied after the fold).
//
//  Requires: FractalFormulaCommon.h
//

#ifndef DE_Menger_h
#define DE_Menger_h

FORCE_INLINE float DE_Menger(float3 pos, FormulaParams fp, float3x3 rot,
                             int iterations, int colorIterations,
                            thread OrbitData& orbit) {
    const float scale = fp.params[0];
    const float3 offset = float3(fp.params[1], fp.params[2], fp.params[3]);

    float3 z = pos;
    float dr = 1.0f;
    float trap = 1e20f;
    int trapIter = 0;
    float3 trapPos = z;
    int i = 0;

    for (; i < iterations; ++i) {
        z = abs(z);
        if (z.x < z.y) { float t = z.x; z.x = z.y; z.y = t; }
        if (z.x < z.z) { float t = z.x; z.x = z.z; z.z = t; }
        if (z.y < z.z) { float t = z.y; z.y = z.z; z.z = t; }

        float3 offsetScaled = offset * (scale - 1.0f);
        z = z * scale - offsetScaled;
        if (z.z < -0.5f * offsetScaled.z) {
            z.z += offsetScaled.z;
        }

        z = rot * z;
        dr = dr * abs(scale) + 1.0f;

        float r2 = dot(z, z);
        UpdateTrapMinR2(trap, trapIter, trapPos, r2, i, colorIterations, z);
    }

    orbit.trap = trap;
    orbit.trapIteration = trapIter;
    orbit.trapPosition = trapPos;
    orbit.finalP = z;
    orbit.iterationsUsed = i;

    return (length(z) - 1.0f) / dr;
}

// Lean distance-only: no orbit tracking, no struct writes.
FORCE_INLINE float DE_Menger_Dist(float3 pos, FormulaParams fp, float3x3 rot, int iterations) {
    const float scale = fp.params[0];
    const float3 offset = float3(fp.params[1], fp.params[2], fp.params[3]);

    float3 z = pos;
    float dr = 1.0f;

    for (int i = 0; i < iterations; ++i) {
        z = abs(z);
        if (z.x < z.y) { float t = z.x; z.x = z.y; z.y = t; }
        if (z.x < z.z) { float t = z.x; z.x = z.z; z.z = t; }
        if (z.y < z.z) { float t = z.y; z.y = z.z; z.z = t; }

        float3 offsetScaled = offset * (scale - 1.0f);
        z = z * scale - offsetScaled;
        if (z.z < -0.5f * offsetScaled.z) {
            z.z += offsetScaled.z;
        }

        z = rot * z;
        dr = dr * abs(scale) + 1.0f;
    }

    return (length(z) - 1.0f) / dr;
}

#endif /* DE_Menger_h */
