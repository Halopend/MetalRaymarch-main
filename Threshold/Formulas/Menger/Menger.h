//
//  Menger.h
//  Threshold
//
//  Distance estimator for the Menger Sponge fractal.
//  params[0]=Scale, [1-3]=Offset
//
//  Requires: FractalFormulaCommon.h
//

#ifndef DE_Menger_h
#define DE_Menger_h

FORCE_INLINE float DE_Menger(float3 pos, FormulaParams fp, float3x3 rot,
                             int iterations, int colorIterations,
                            thread OrbitData& orbit) {
    float scale  = fp.params[0];
    float3 offset = float3(fp.params[1], fp.params[2], fp.params[3]);

    float3 z = pos;
    float dr = 1.0f;
    float trap = 1e20f;
    int trapIter = 0;
    float3 trapPos = z;
    int i = 0;

    for (; i < iterations; ++i) {
        // Fold into positive octant
        z = abs(z);
        // Sort components so z.x >= z.y >= z.z
        float sum = z.x + z.y + z.z;
        float min_xy = min(z.x, z.y);
        float max_xy = max(z.x, z.y);
        float min_z = min(min_xy, z.z);
        float max_z = max(max_xy, z.z);
        z.x = max_z;
        z.z = min_z;
        z.y = sum - (max_z + min_z);

        float3 offsetScaled = offset * (scale - 1.0f);
        z = z * scale - offsetScaled;
        
        float foldZ = -0.5f * offsetScaled.z;
        z.z += (z.z < foldZ) ? offsetScaled.z : 0.0f;

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

    float r = fast::length(z);
    return (r - 1.0f) / dr;
}

// Lean distance-only: no orbit tracking, no struct writes.
FORCE_INLINE float DE_Menger_Dist(float3 pos, FormulaParams fp, float3x3 rot, int iterations) {
    float scale  = fp.params[0];
    float3 offset = float3(fp.params[1], fp.params[2], fp.params[3]);
    float3 offsetScaled = offset * (scale - 1.0f);
    float halfOffsetZn = -0.5f * offsetScaled.z;

    float3 z = pos;
    float dr = 1.0f;

    for (int i = 0; i < iterations; ++i) {
        z = abs(z);
        float sum = z.x + z.y + z.z;
        float min_xy = min(z.x, z.y);
        float max_xy = max(z.x, z.y);
        float min_z = min(min_xy, z.z);
        float max_z = max(max_xy, z.z);
        z.x = max_z;
        z.z = min_z;
        z.y = sum - (max_z + min_z);

        z = z * scale - offsetScaled;
        z.z += (z.z < halfOffsetZn) ? offsetScaled.z : 0.0f;

        z = rot * z;
        dr = dr * abs(scale) + 1.0f;
    }

    return (fast::length(z) - 1.0f) / dr;
}

#endif /* DE_Menger_h */
