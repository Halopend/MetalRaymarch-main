//
//  BoxSphereFolder.h
//  Threshold
//
//  Distance estimator for abs-fold + sphere inversion IFS.
//  Compact box fold → sphere fold → scale loop with tunable range.
//
//  params[0-2]=Offset.xyz, [3]=BoxFold, [4]=MinR2, [5]=MaxR2,
//  [6]=Scale, [7]=ShapeR, [8]=ColorOfs, [9]=ColorScale
//
//  Original GLSL:
//    vec4 q = vec4(p - 1.0, 1);
//    for(int i = 0; i < 5; i++) {
//        q.xyz = abs(q.xyz + 1.0) - 1.0;
//        q /= clamp(dot(q.xyz, q.xyz), 0.25, 1.0);
//        q *= 1.15;
//    }
//    return (length(q.zy) - 1.2)/q.w;
//
//  Requires: FractalFormulaCommon.h
//

#ifndef DE_BoxSphereFolder_h
#define DE_BoxSphereFolder_h

// ---------------------------------------------------------------------------
// Full orbit-tracking version (coloring + normals)
// ---------------------------------------------------------------------------
FORCE_INLINE float DE_BoxSphereFolder(float3 pos, FormulaParams fp, float3x3 rot,
                                      int iterations, int colorIterations,
                                      thread OrbitData& orbit) {
    float3 offset = float3(fp.params[0], fp.params[1], fp.params[2]);
    float boxFold = fp.params[3];
    float minR2   = fp.params[4];
    float maxR2   = fp.params[5];
    float scale   = fp.params[6];
    float shapeR  = fp.params[7];
    bool hasRotation = hasRot1Precomputed(fp);

    float3 p = pos - offset;
    float w = 1.0f;

    float trap = 1e20f;
    int trapIter = 0;
    float3 trapPos = pos;
    int trapIterations = min(max(colorIterations, 0), iterations);

    int i = 0;
    for (; i < iterations; ++i) {
        if (hasRotation) p = rot * p;

        // Box fold: abs(p + boxFold) - boxFold
        p = abs(p + boxFold) - boxFold;

        // Sphere fold: divide by clamped dot product
        float r2 = dot(p, p);
        float k = 1.0f / clamp(r2, minR2, maxR2);
        p *= k;
        w *= k;

        // Scale
        p *= scale;
        w *= scale;

        // Orbit trap
        if (i < trapIterations) {
            float r2Trap = dot(p, p);
            if (r2Trap < trap) {
                trap = r2Trap;
                trapIter = i;
                trapPos = p;
            }
        }
    }

    // DE: cylindrical cross-section using zy plane
    float de = (length(p.zy) - shapeR) / max(abs(w), 1e-6f);

    orbit.trap = trap;
    orbit.trapIteration = trapIter;
    orbit.trapPosition = trapPos;
    orbit.finalP = p;
    orbit.iterationsUsed = i;

    return de;
}

// ---------------------------------------------------------------------------
// Lean distance-only (shadows, normals via finite differences)
// ---------------------------------------------------------------------------
FORCE_INLINE float DE_BoxSphereFolder_Dist(float3 pos, FormulaParams fp, float3x3 rot, int iterations) {
    float3 offset = float3(fp.params[0], fp.params[1], fp.params[2]);
    float boxFold = fp.params[3];
    float minR2   = fp.params[4];
    float maxR2   = fp.params[5];
    float scale   = fp.params[6];
    float shapeR  = fp.params[7];
    bool hasRotation = hasRot1Precomputed(fp);

    float3 p = pos - offset;
    float w = 1.0f;

    if (hasRotation) {
        for (int i = 0; i < iterations; ++i) {
            p = rot * p;
            p = abs(p + boxFold) - boxFold;
            float r2 = dot(p, p);
            float k = 1.0f / clamp(r2, minR2, maxR2);
            p *= k;
            w *= k;
            p *= scale;
            w *= scale;
        }
    } else {
        for (int i = 0; i < iterations; ++i) {
            p = abs(p + boxFold) - boxFold;
            float r2 = dot(p, p);
            float k = 1.0f / clamp(r2, minR2, maxR2);
            p *= k;
            w *= k;
            p *= scale;
            w *= scale;
        }
    }

    return (length(p.zy) - shapeR) / max(abs(w), 1e-6f);
}

#endif /* DE_BoxSphereFolder_h */
