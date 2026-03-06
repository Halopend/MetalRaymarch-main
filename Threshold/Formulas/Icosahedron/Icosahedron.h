//
//  Icosahedron.h
//  Threshold
//
//  Distance estimator for the Icosahedron IFS fractal.
//  params[0]=Scale, [1]=Phi, [2-4]=Offset
//
//  Requires: FractalFormulaCommon.h
//

#ifndef DE_Icosahedron_h
#define DE_Icosahedron_h

FORCE_INLINE float DE_Icosahedron(float3 pos, FormulaParams fp, float3x3 rot,
                                  int iterations, int colorIterations,
                                 thread OrbitData& orbit) {
    float scale  = fp.params[0];
    float phi    = fp.params[1];
    float3 offset = float3(fp.params[2], fp.params[3], fp.params[4]);

    // Five-fold symmetry planes using golden ratio
    float3 n1 = fast::normalize(float3(-1.0f, phi, 1.0f/phi));
    float3 n2 = fast::normalize(float3(1.0f/phi, -1.0f, phi));
    float3 n3 = fast::normalize(float3(phi, 1.0f/phi, -1.0f));
    float3 n4 = fast::normalize(float3(-1.0f, -phi, 1.0f/phi));
    float3 n5 = fast::normalize(float3(1.0f/phi, 1.0f, phi));

    float3 z = pos;
    float dr = 1.0f;
    float trap = 1e20f;
    int trapIter = 0;
    float3 trapPos = z;
    int i = 0;

    for (; i < iterations; ++i) {
        // Five mirror folds for icosahedral symmetry
        z -= 2.0f * min(0.0f, dot(z, n1)) * n1;
        z -= 2.0f * min(0.0f, dot(z, n2)) * n2;
        z -= 2.0f * min(0.0f, dot(z, n3)) * n3;
        z -= 2.0f * min(0.0f, dot(z, n4)) * n4;
        z -= 2.0f * min(0.0f, dot(z, n5)) * n5;

        z = z * scale - offset * (scale - 1.0f);
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
FORCE_INLINE float DE_Icosahedron_Dist(float3 pos, FormulaParams fp, float3x3 rot, int iterations) {
    float scale  = fp.params[0];
    float phi    = fp.params[1];
    float3 offset = float3(fp.params[2], fp.params[3], fp.params[4]);
    float3 offsetScaled = offset * (scale - 1.0f);

    float3 n1 = fast::normalize(float3(-1.0f, phi, 1.0f/phi));
    float3 n2 = fast::normalize(float3(1.0f/phi, -1.0f, phi));
    float3 n3 = fast::normalize(float3(phi, 1.0f/phi, -1.0f));
    float3 n4 = fast::normalize(float3(-1.0f, -phi, 1.0f/phi));
    float3 n5 = fast::normalize(float3(1.0f/phi, 1.0f, phi));

    float3 z = pos;
    float dr = 1.0f;

    for (int i = 0; i < iterations; ++i) {
        z -= 2.0f * min(0.0f, dot(z, n1)) * n1;
        z -= 2.0f * min(0.0f, dot(z, n2)) * n2;
        z -= 2.0f * min(0.0f, dot(z, n3)) * n3;
        z -= 2.0f * min(0.0f, dot(z, n4)) * n4;
        z -= 2.0f * min(0.0f, dot(z, n5)) * n5;

        z = z * scale - offsetScaled;
        z = rot * z;
        dr = dr * abs(scale) + 1.0f;
    }

    return (fast::length(z) - 1.0f) / dr;
}

#endif /* DE_Icosahedron_h */
