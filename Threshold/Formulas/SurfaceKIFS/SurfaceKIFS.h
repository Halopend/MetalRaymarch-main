//
//  SurfaceKIFS.h
//  Threshold
//
//  Distance estimator for the Surface KIFS fractal.
//  params[0]=Scale, [1-3]=Fold, [4-6]=Julia, [7-9]=RotVector, [10]=RotAngle
//  Note: RotVector/RotAngle are consumed on Swift side to build rotMatrix1
//
//  Requires: FractalFormulaCommon.h
//

#ifndef DE_SurfaceKIFS_h
#define DE_SurfaceKIFS_h

FORCE_INLINE float DE_SurfaceKIFS(float3 pos, FormulaParams fp, float3x3 rot,
                                  int iterations, int colorIterations,
                                 thread OrbitData& orbit) {
    float scale  = fp.params[0];
    float3 fold  = float3(fp.params[1], fp.params[2], fp.params[3]);
    float3 julia = float3(fp.params[4], fp.params[5], fp.params[6]);

    float3 z = pos;
    float dr = 1.0f;
    float trap = 1e20f;
    int trapIter = 0;
    float3 trapPos = z;
    int i = 0;

    for (; i < iterations; ++i) {
        // Abs folds + custom fold offsets
        z = abs(z) - fold;

        // Sort-based fold (surface symmetry)
        if (z.x < z.y) z.xy = z.yx;
        if (z.x < z.z) z.xz = z.zx;
        if (z.y < z.z) z.yz = z.zy;

        // Apply rotation
        z = rot * z;

        z = z * scale + julia;
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
FORCE_INLINE float DE_SurfaceKIFS_Dist(float3 pos, FormulaParams fp, float3x3 rot, int iterations) {
    float scale  = fp.params[0];
    float3 fold  = float3(fp.params[1], fp.params[2], fp.params[3]);
    float3 julia = float3(fp.params[4], fp.params[5], fp.params[6]);

    float3 z = pos;
    float dr = 1.0f;

    for (int i = 0; i < iterations; ++i) {
        z = abs(z) - fold;

        if (z.x < z.y) z.xy = z.yx;
        if (z.x < z.z) z.xz = z.zx;
        if (z.y < z.z) z.yz = z.zy;

        z = rot * z;
        z = z * scale + julia;
        dr = dr * abs(scale) + 1.0f;
    }

    return (fast::length(z) - 1.0f) / dr;
}

#endif /* DE_SurfaceKIFS_h */
