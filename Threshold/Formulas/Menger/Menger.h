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
    const float absScale = abs(scale);
    const float3 offset = float3(fp.params[1], fp.params[2], fp.params[3]);
    // Loop-invariant: hoisted out of the iteration.
    const float3 offsetScaled = offset * (scale - 1.0f);
    const float3 negOffsetScaled = -offsetScaled;
    const float halfOffsetZn = -0.5f * offsetScaled.z;

    float3 z = pos;
    float dr = 1.0f;
    float trap = 1e20f;
    int trapIter = 0;
    float3 trapPos = z;
    int i = 0;

    for (; i < iterations; ++i) {
        z = abs(z);
        // Branchless descending sort (x=max, y=mid, z=min) — same result as
        // the classic swap chain, no select chains on the critical path.
        float sum = z.x + z.y + z.z;
        float mx = max(max(z.x, z.y), z.z);
        float mn = min(min(z.x, z.y), z.z);
        z = float3(mx, sum - mx - mn, mn);

        z = fma(z, scale, negOffsetScaled);
        if (z.z < halfOffsetZn) {
            z.z += offsetScaled.z;
        }

        z = rot * z;
        dr = fma(dr, absScale, 1.0f);

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
    const float absScale = abs(scale);
    const float3 offset = float3(fp.params[1], fp.params[2], fp.params[3]);
    const float3 offsetScaled = offset * (scale - 1.0f);
    const float3 negOffsetScaled = -offsetScaled;
    const float halfOffsetZn = -0.5f * offsetScaled.z;

    float3 z = pos;
    float dr = 1.0f;

    for (int i = 0; i < iterations; ++i) {
        z = abs(z);
        float sum = z.x + z.y + z.z;
        float mx = max(max(z.x, z.y), z.z);
        float mn = min(min(z.x, z.y), z.z);
        z = float3(mx, sum - mx - mn, mn);

        z = fma(z, scale, negOffsetScaled);
        if (z.z < halfOffsetZn) {
            z.z += offsetScaled.z;
        }

        z = rot * z;
        dr = fma(dr, absScale, 1.0f);
    }

    return (length(z) - 1.0f) / dr;
}

#endif /* DE_Menger_h */
