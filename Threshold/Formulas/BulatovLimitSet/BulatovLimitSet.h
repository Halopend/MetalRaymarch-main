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

// Reflect v in a generator, folding the accumulated inversion scale.
//   sphere → conformal inversion: v ↦ c + (r²/|v-c|²)(v-c)   (scale ×= r²/|v-c|²)
//   plane  → mirror reflection across the plane (isometry, scale unchanged)
FORCE_INLINE void bulatovReflect(BulatovGen s, thread float3& v, thread float& scale) {
    if (s.type == 0) {                                  // sphere inversion
        float3 d = v - s.c;
        float len2 = max(dot(d, d), 1e-12f);
        float factor = (s.d * s.d) / len2;
        v = d * factor + s.c;
        scale *= factor;
    } else {                                            // plane reflection
        float vn = dot(v - s.c * s.d, s.c);
        v -= 2.0f * s.c * vn;
    }
}

// Signed membership test: < 0 means "needs reflecting" — i.e. the point is inside
// an inversion sphere (negative stored radius), outside a bounding sphere
// (positive radius), or behind a mirror plane.
FORCE_INLINE float bulatovDistance(BulatovGen s, float3 v) {
    if (s.type == 0) {
        float3 d = v - s.c;
        float dd = dot(d, d) - s.d * s.d;
        return (s.d < 0.0f) ? dd : -dd;
    }
    return dot(v, s.c) - s.d;
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

    // Sphere radii that make the intersection angle exactly π/n (Bulatov eq.).
    if (angleCube >= 2.0f) rc = 2.0f * sc / sqrt(2.0f * (1.0f + cos(pi / angleCube)));
    if (angleOcta >= 2.0f) ro = so * sqrt(2.0f) / sqrt(2.0f * (1.0f + cos(pi / angleOcta)));

    sc *= scale; so *= scale; rc *= scale; ro *= scale;

    // Build the fundamental domain (up to 6 generators) from the toggle mask.
    BulatovGen gens[6];
    int n = 0;
    if (mask & 1)  gens[n++] = BulatovGen{ 0, float3(sc, sc, sc), -rc };
    if (mask & 2)  gens[n++] = BulatovGen{ 0, float3(0.0f, 0.0f, so), -ro };
    if (mask & 4)  gens[n++] = BulatovGen{ 1, float3(1.0f, 0.0f, 0.0f), 0.0f };
    if (mask & 8)  gens[n++] = BulatovGen{ 1, normalize(float3(0.0f, -1.0f, 1.0f)), 0.0f };
    if (mask & 16) gens[n++] = BulatovGen{ 1, normalize(float3(-1.0f, 1.0f, 0.0f)), 0.0f };
    if (mask & 32) gens[n++] = BulatovGen{ 0, float3(0.0f), rOutside * scale };

    float3 p = pos;
    float  s = 1.0f;
    int    used = 0;
    int    count = maxCount;
    while (count > 0) {
        bool found = false;
        for (int i = 0; i < n; ++i) {
            if (bulatovDistance(gens[i], p) < 0.0f) {
                bulatovReflect(gens[i], p, s);
                found = true;
            }
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
    return bulatovFold(p, fp, finalP, used);
}

#endif /* DE_BulatovLimitSet_h */
