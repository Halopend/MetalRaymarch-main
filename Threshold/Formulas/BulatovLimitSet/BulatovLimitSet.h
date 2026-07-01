//
//  BulatovLimitSet.h
//  Threshold
//
//  Limit set of a hyperbolic reflection group, after Vladimir Bulatov's
//  "Limit Set of 4D Hyperbolic Reflection Group" (bulatov.org, Dec 2012).
//
//  A sample point is repeatedly REFLECTED in a small set of generator spheres
//  and planes (the "fundamental domain") until it lands inside the domain; the
//  accumulated conformal-inversion scale gives the distance estimate. This is
//  the same reflection-group machinery as our Coxeter space-warp (`warpCoxeter`)
//  — fold a point into a fundamental domain across mirror planes — but with
//  SPHERE generators (inversions) added to the planes. Those inversions are what
//  turn a finite polyhedral fold into an infinite fractal limit set (the points
//  of accumulation of the group action).
//
//  The default generators reproduce Bulatov's octahedral-symmetry example:
//  a cube-corner sphere, an octahedron-face sphere, and three mirror planes
//  ((1,0,0), (0,-1,1), (-1,1,0)) — with an optional bounding "outside" sphere.
//
//  params[0]=SizeCube  [1]=SizeOcta [2]=RCube   [3]=ROcta
//  params[4]=AngleCube [5]=AngleOcta [6]=Scale  [7]=ROutside
//  params[8]=MaxReflections [9]=DistanceFactor
//  params[10]=GeneratorMask  (bit0 cube-corner sphere, 1 octa sphere,
//             2 mirror X, 3 mirror YZ, 4 mirror XY, 5 outside sphere)
//
//  Requires: FractalFormulaCommon.h
//

#ifndef DE_BulatovLimitSet_h
#define DE_BulatovLimitSet_h

// One generator of the fundamental domain: a sphere (type 0) or plane (type 1).
struct BulatovGen {
    int   type;   // 0 = sphere, 1 = plane
    float3 c;     // sphere centre, or (normalized) plane normal
    float d;      // sphere radius (sign carries the inside/outside test), or plane offset
};

// Fused membership-test + reflection: test whether v lies on the "wrong" side of a
// generator and, if so, reflect it in one shot — reusing the squared distance so a
// sphere is never measured twice (the old split test/reflect pair computed |v-c|²
// once to decide and again to invert). Returns true iff a reflection happened.
//   sphere → conformal inversion: v ↦ c + (r²/|v-c|²)(v-c)   (scale ×= r²/|v-c|²)
//   plane  → mirror reflection across the plane (isometry, scale unchanged)
// Membership: inversion sphere (d<0) folds points INSIDE it; bounding sphere (d>0)
// folds points OUTSIDE it; a plane folds points behind it (dot(v,n) < offset). For a
// unit plane normal, that membership value dot(v,n)-offset is exactly the reflection
// coefficient, so the plane branch computes it only once.
FORCE_INLINE bool bulatovStep(BulatovGen s, thread float3& v, thread float& scale) {
    if (s.type == 0) {                                  // sphere
        float3 d = v - s.c;
        float len2 = dot(d, d);
        float r2   = s.d * s.d;
        bool reflect = (s.d < 0.0f) ? (len2 < r2) : (len2 > r2);
        if (!reflect) return false;
        float factor = r2 / max(len2, 1e-12f);
        v = d * factor + s.c;
        scale *= factor;
        return true;
    }
    // plane: s.c is a unit normal, so dot(v,c) - d == dot(v - c*d, c)
    float vn = dot(v, s.c) - s.d;
    if (vn >= 0.0f) return false;
    v -= 2.0f * s.c * vn;
    return true;
}

// Iterate reflections until the point sits inside the fundamental domain, then
// turn the accumulated inversion scale into a distance estimate. Returns the DE
// and reports the folded point + reflection count for coloring.
FORCE_INLINE float bulatovFold(float3 pos, FormulaParams fp,
                               thread float3& outP, thread int& reflectionsUsed) {
    const float pi = 3.1415926f;
    float sc        = fp.params[0];
    float so        = fp.params[1];
    float rc        = fp.params[2];
    float ro        = fp.params[3];
    float angleCube = fp.params[4];
    float angleOcta = fp.params[5];
    float scale     = fp.params[6];
    float rOutside  = fp.params[7];
    int   maxCount  = clamp((int)(fp.params[8] + 0.5f), 0, 256);
    float distanceFactor = fp.params[9];
    int   mask      = (int)(fp.params[10] + 0.5f);

    // Pre-normalized mirror normals (normalize(0,-1,1) and normalize(-1,1,0)) as
    // compile-time constants — no runtime rsqrt per DE call.
    const float invSqrt2 = 0.70710678118654752f;

    // Sphere radii that make the intersection angle exactly π/n (Bulatov eq.). Only
    // evaluate the transcendentals when the matching sphere generator is enabled.
    if ((mask & 1) && angleCube >= 2.0f) rc = 2.0f * sc / sqrt(2.0f * (1.0f + cos(pi / angleCube)));
    if ((mask & 2) && angleOcta >= 2.0f) ro = so * 1.41421356237f / sqrt(2.0f * (1.0f + cos(pi / angleOcta)));

    sc *= scale; so *= scale; rc *= scale; ro *= scale;

    // Build the fundamental domain (up to 6 generators) from the toggle mask.
    BulatovGen gens[6];
    int n = 0;
    if (mask & 1)  gens[n++] = BulatovGen{ 0, float3(sc, sc, sc), -rc };
    if (mask & 2)  gens[n++] = BulatovGen{ 0, float3(0.0f, 0.0f, so), -ro };
    if (mask & 4)  gens[n++] = BulatovGen{ 1, float3(1.0f, 0.0f, 0.0f), 0.0f };
    if (mask & 8)  gens[n++] = BulatovGen{ 1, float3(0.0f, -invSqrt2, invSqrt2), 0.0f };
    if (mask & 16) gens[n++] = BulatovGen{ 1, float3(-invSqrt2, invSqrt2, 0.0f), 0.0f };
    if (mask & 32) gens[n++] = BulatovGen{ 0, float3(0.0f), rOutside * scale };

    float3 p = pos;
    float  s = 1.0f;
    int    used = 0;
    int    count = maxCount;
    while (count > 0) {
        bool found = false;
        for (int i = 0; i < n; ++i) {
            if (bulatovStep(gens[i], p, s)) found = true;
        }
        if (!found) break;          // settled inside the fundamental domain
        ++used;
        --count;
    }

    // One more conformal step to normalize points at infinity, then DE = factor / scale.
    s *= 2.0f / (1.0f + dot(p, p));
    outP = p;
    reflectionsUsed = used;
    return distanceFactor / max(s, 1e-9f);
}

// ---------------------------------------------------------------------------
// Full orbit-tracking version (coloring + normals)
// ---------------------------------------------------------------------------
FORCE_INLINE float DE_BulatovLimitSet(float3 pos, FormulaParams fp, float3x3 rot,
                                      int iterations, int colorIterations,
                                      thread OrbitData& orbit) {
    float3 p = rot * pos;                 // identity unless the user rotates the set
    float3 finalP;
    int used;
    float de = bulatovFold(p, fp, finalP, used);

    orbit.trap = dot(finalP, finalP);     // radial trap of the folded point
    orbit.trapIteration = used;
    orbit.trapPosition = finalP;
    orbit.finalP = finalP;
    orbit.iterationsUsed = used;
    return de;
}

// ---------------------------------------------------------------------------
// Lean distance-only (shadows, normals via finite differences)
// ---------------------------------------------------------------------------
FORCE_INLINE float DE_BulatovLimitSet_Dist(float3 pos, FormulaParams fp, float3x3 rot, int iterations) {
    float3 p = rot * pos;
    float3 finalP;
    int used;
    // NOTE (measured 2026-07-01): do NOT cap the reflection loop by `iterations`
    // here for secondary rays — the fold's `if (!found) break` early-out already
    // terminates well below the cap, so it saved only ~4% while visibly changing
    // shading (~13% of pixels). The cost is per-call fixed work, not loop length.
    return bulatovFold(p, fp, finalP, used);
}

#endif /* DE_BulatovLimitSet_h */
