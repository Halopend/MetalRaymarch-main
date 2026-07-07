//
//  Octahedron.h
//  Threshold
//
//  Distance estimator for the Octahedron IFS fractal.
//  params[0]=Scale, [1-3]=Offset
//
//  Requires: FractalFormulaCommon.h
//

#ifndef DE_Octahedron_h
#define DE_Octahedron_h

FORCE_INLINE float DE_Octahedron(float3 pos, FormulaParams fp, float3x3 rot,
                                 int iterations, int colorIterations,
                                thread OrbitData& orbit) {
    float scale  = fp.params[0];
    float3 offset = float3(fp.params[1], fp.params[2], fp.params[3]);
    // Loop-invariant: hoisted out of the iteration.
    float3 negOffsetScaled = -(offset * (scale - 1.0f));

    float3 z = pos;
    float dr = 1.0f;
    float trap = 1e20f;
    int trapIter = 0;
    float3 trapPos = z;
    int i = 0;

    for (; i < iterations; ++i) {
        // Octahedral folds (abs + branchless descending sort = octahedral symmetry)
        z = abs(z);
        float sum = z.x + z.y + z.z;
        float mx = max(max(z.x, z.y), z.z);
        float mn = min(min(z.x, z.y), z.z);
        z = float3(mx, sum - mx - mn, mn);

        z = fma(z, scale, negOffsetScaled);
        z = rot * z;
        dr = fma(dr, scale, 1.0f);

        float r2 = dot(z, z);
        UpdateTrapMinR2(trap, trapIter, trapPos, r2, i, colorIterations, z);
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
FORCE_INLINE float DE_Octahedron_Dist(float3 pos, FormulaParams fp, float3x3 rot, int iterations) {
    float scale  = fp.params[0];
    float3 offset = float3(fp.params[1], fp.params[2], fp.params[3]);
    float3 negOffsetScaled = -(offset * (scale - 1.0f));

    float3 z = pos;
    float dr = 1.0f;

    for (int i = 0; i < iterations; ++i) {
        z = abs(z);
        float sum = z.x + z.y + z.z;
        float mx = max(max(z.x, z.y), z.z);
        float mn = min(min(z.x, z.y), z.z);
        z = float3(mx, sum - mx - mn, mn);

        z = fma(z, scale, negOffsetScaled);
        z = rot * z;
        dr = fma(dr, scale, 1.0f);
    }

    return (fast::length(z) - 1.0f) / dr;
}

#endif /* DE_Octahedron_h */
