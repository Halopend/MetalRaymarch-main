//
//  SphereSponge.h
//  Threshold
//
//  Distance estimator for the Sphere Sponge fractal.
//  params[0]=Scale, [1]=BubbleSize
//
//  Requires: FractalFormulaCommon.h
//

#ifndef DE_SphereSponge_h
#define DE_SphereSponge_h

FORCE_INLINE float DE_SphereSponge(float3 pos, FormulaParams fp, float3x3 rot,
                                   int iterations, int colorIterations,
                                  thread OrbitData& orbit) {
    float scale  = fp.params[0];
    float bubble = fp.params[1];

    float3 z = pos;
    float dr = 1.0f;
    float trap = 1e20f;
    int trapIter = 0;
    float3 trapPos = z;
    int i = 0;

    for (; i < iterations; ++i) {
        // Fold into fundamental domain
        z = abs(z);
        if (z.x < z.y) z.xy = z.yx;
        if (z.x < z.z) z.xz = z.zx;
        if (z.y < z.z) z.yz = z.zy;

        z = z * scale;
        dr = dr * scale;

        // Translate
        z -= float3(bubble, bubble, bubble) * (scale - 1.0f);

        // Sphere inversion
        float r2 = dot(z, z);
        if (r2 < 1.0f) {
            z /= r2;
            dr /= r2;
        }

        z = rot * z;

        UpdateTrapMinR2(trap, trapIter, trapPos, dot(z,z), i, colorIterations, z);
    }

    orbit.trap = trap;
    orbit.trapIteration = trapIter;
    orbit.trapPosition = trapPos;
    orbit.finalP = z;
    orbit.iterationsUsed = i;

    float r = fast::length(z);
    return (r - 1.0f) / dr;
}

// Lean distance-only: no orbit tracking, no struct writes.
FORCE_INLINE float DE_SphereSponge_Dist(float3 pos, FormulaParams fp, float3x3 rot, int iterations) {
    float scale  = fp.params[0];
    float bubble = fp.params[1];
    float3 bubbleOffset = float3(bubble) * (scale - 1.0f);

    float3 z = pos;
    float dr = 1.0f;

    for (int i = 0; i < iterations; ++i) {
        z = abs(z);
        if (z.x < z.y) z.xy = z.yx;
        if (z.x < z.z) z.xz = z.zx;
        if (z.y < z.z) z.yz = z.zy;

        z = z * scale - bubbleOffset;
        dr = dr * scale;

        float r2 = dot(z, z);
        if (r2 < 1.0f) {
            z /= r2;
            dr /= r2;
        }

        z = rot * z;
    }

    return (fast::length(z) - 1.0f) / dr;
}

#endif /* DE_SphereSponge_h */
