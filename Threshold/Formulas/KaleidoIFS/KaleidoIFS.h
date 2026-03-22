//
//  KaleidoIFS.h
//  Threshold
//
//  Kaleidoscopic IFS fractal with plane reflections against cycling normal
//  vectors.  Produces intricate crystalline geometry with striking directional
//  coloring (the normalized fractal-space position is used as the orbit trap).
//
//  params[0] = Scale      (default 2.0, range 1.0–3.0)
//  params[1] = Offset     (default 1.0,  range 0.0–4.0)
//  params[2] = NormalW    (default 0.5,  range 0.0–1.0) — weight in fold normals
//
//  Inspired by:  https://www.shadertoy.com/view/...  (plane-reflect IFS)
//
//  Requires: FractalFormulaCommon.h
//

#ifndef DE_KaleidoIFS_h
#define DE_KaleidoIFS_h

// ---------------------------------------------------------------------------
// Full orbit-tracking version (coloring + normals)
// ---------------------------------------------------------------------------
FORCE_INLINE float DE_KaleidoIFS(float3 pos, FormulaParams fp, float3x3 rot,
                                 int iterations, int colorIterations,
                                 thread OrbitData& orbit) {
    float scale   = fp.params[0];  // default 2.0
    float offset  = fp.params[1];  // default 1.0
    float nw      = fp.params[2];  // default 0.5
    bool hasRotation = hasRot1Precomputed(fp);

    // Three reflection normals that cycle each iteration (normalized)
    float3 b0 = normalize(float3(nw, nw, 0.0f));   // (nw, nw, 0)
    float3 b1 = normalize(float3(0.0f, nw, nw));   // (0, nw, nw)
    float3 b2 = normalize(float3(nw, 0.0f, nw));   // (nw, 0, nw)

    float3 p = pos;
    float dr = 1.0f;  // accumulated scale for DE
    float trap = 1e20f;
    int trapIter = 0;
    float3 trapPos = pos;
    int i = 0;

    for (; i < iterations; ++i) {
        if (hasRotation) p = rot * p;

        // Three plane reflections (fold)
        p -= min(0.0f, dot(p, b0)) * b0 * 2.0f;
        p -= min(0.0f, dot(p, b1)) * b1 * 2.0f;
        p -= min(0.0f, dot(p, b2)) * b2 * 2.0f;

        // Scale and translate (offset scaled like Menger/Sierpinski)
        p = p * scale - offset * (scale - 1.0f);
        dr = dr * scale + 1.0f;

        // Orbit trap (use r² for coloring consistency with other formulas)
        float r2 = dot(p, p);
        UpdateTrapMinR2(trap, trapIter, trapPos, r2, i, colorIterations, p);
    }

    orbit.trap = trap;
    orbit.trapIteration = trapIter;
    orbit.trapPosition = trapPos;
    orbit.finalP = p;
    orbit.iterationsUsed = i;

    return (fast::length(p) - 1.0f) / dr;
}

// ---------------------------------------------------------------------------
// Lean distance-only (shadows, normals via finite differences)
// ---------------------------------------------------------------------------
FORCE_INLINE float DE_KaleidoIFS_Dist(float3 pos, FormulaParams fp, float3x3 rot, int iterations) {
    float scale   = fp.params[0];
    float offset  = fp.params[1];
    float nw      = fp.params[2];
    bool hasRotation = hasRot1Precomputed(fp);

    float3 b0 = normalize(float3(nw, nw, 0.0f));
    float3 b1 = normalize(float3(0.0f, nw, nw));
    float3 b2 = normalize(float3(nw, 0.0f, nw));

    float3 p = pos;
    float dr = 1.0f;

    for (int i = 0; i < iterations; ++i) {
        if (hasRotation) p = rot * p;

        p -= min(0.0f, dot(p, b0)) * b0 * 2.0f;
        p -= min(0.0f, dot(p, b1)) * b1 * 2.0f;
        p -= min(0.0f, dot(p, b2)) * b2 * 2.0f;

        p = p * scale - offset * (scale - 1.0f);
        dr = dr * scale + 1.0f;
    }

    return (fast::length(p) - 1.0f) / dr;
}

#endif /* DE_KaleidoIFS_h */
