//
//  Dodecahedron.h
//  Threshold
//
//  Distance estimator for the Dodecahedron IFS fractal.
//  params[0]=Scale, [1]=Phi, [2]=Log10Bailout
//
//  Requires: FractalFormulaCommon.h
//

#ifndef DE_Dodecahedron_h
#define DE_Dodecahedron_h

FORCE_INLINE float DE_Dodecahedron(float3 pos, FormulaParams fp, float3x3 rot,
                                   int iterations, int colorIterations,
                                  thread OrbitData& orbit) {
    float scale   = fp.params[0];
    float phi     = fp.params[1];
    float bailout = fast::exp2(fp.params[2] * kLog2_10); // 10^Log10Bailout

    // Golden ratio vectors for dodecahedral symmetry
    float3 n1 = fast::normalize(float3(-1.0f, phi, 1.0f/phi));
    float3 n2 = fast::normalize(float3(1.0f/phi, -1.0f, phi));
    float3 n3 = fast::normalize(float3(phi, 1.0f/phi, -1.0f));

    float3 z = pos;
    float dr = 1.0f;
    float trap = 1e20f;
    int trapIter = 0;
    float3 trapPos = z;
    int i = 0;

    for (; i < iterations; ++i) {
        // Mirror folds across dodecahedral planes
        z -= 2.0f * min(0.0f, dot(z, n1)) * n1;
        z -= 2.0f * min(0.0f, dot(z, n2)) * n2;
        z -= 2.0f * min(0.0f, dot(z, n3)) * n3;

        z = z * scale - float3(1.0f) * (scale - 1.0f);
        z = rot * z;
        dr = dr * abs(scale) + 1.0f;

        float r2 = dot(z, z);
        UpdateTrapMinR2(trap, trapIter, trapPos, r2, i, colorIterations, z);
        if (r2 > bailout) break;
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
FORCE_INLINE float DE_Dodecahedron_Dist(float3 pos, FormulaParams fp, float3x3 rot, int iterations) {
    float scale   = fp.params[0];
    float phi     = fp.params[1];
    float bailout = fast::exp2(fp.params[2] * kLog2_10);

    float3 n1 = fast::normalize(float3(-1.0f, phi, 1.0f/phi));
    float3 n2 = fast::normalize(float3(1.0f/phi, -1.0f, phi));
    float3 n3 = fast::normalize(float3(phi, 1.0f/phi, -1.0f));

    float3 z = pos;
    float dr = 1.0f;

    for (int i = 0; i < iterations; ++i) {
        z -= 2.0f * min(0.0f, dot(z, n1)) * n1;
        z -= 2.0f * min(0.0f, dot(z, n2)) * n2;
        z -= 2.0f * min(0.0f, dot(z, n3)) * n3;

        z = z * scale - float3(1.0f) * (scale - 1.0f);
        z = rot * z;
        dr = dr * abs(scale) + 1.0f;

        if (dot(z, z) > bailout) break;
    }

    return (fast::length(z) - 1.0f) / dr;
}

#endif /* DE_Dodecahedron_h */
