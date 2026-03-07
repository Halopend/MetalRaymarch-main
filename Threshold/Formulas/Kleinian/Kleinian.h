//
//  Kleinian.h
//  Threshold
//
//  Distance estimator for knighty's Pseudo Kleinian fractal.
//  Box fold + sphere inversion with a cylindrical cross-section DE.
//
//  params[0-2]=Mins.xyz, [3]=SphFold, [4-6]=Maxs.xyz, [7]=CrossR,
//  params[8]=ColorOfs, [9]=ColorScale
//
//  Ported from Shadertoy (knighty / Music by Trisomie21 "Kleinian")
//
//  Optimizations:
//    • float4 packing: p.xyz = position, p.w = accumulated scale
//    • fma box fold: fma(clamp(...), 2.0, -p.xyz)
//    • Merged orbit / non-orbit loops with uniform branch
//
//  Requires: FractalFormulaCommon.h
//

#ifndef DE_Kleinian_h
#define DE_Kleinian_h

// ---------------------------------------------------------------------------
// Full orbit-tracking version (coloring + normals)
// ---------------------------------------------------------------------------
FORCE_INLINE float DE_Kleinian(float3 pos, FormulaParams fp, float3x3 rot,
                               int iterations, int colorIterations,
                               thread OrbitData& orbit) {
    float3 mins   = float3(fp.params[0], fp.params[1], fp.params[2]);
    float sphFold = fp.params[3];
    float3 maxs   = float3(fp.params[4], fp.params[5], fp.params[6]);
    float crossR  = fp.params[7];
    bool hasRotation = hasRot1Precomputed(fp);

    float3 p = pos;
    float scale = 1.0f;

    float trap = 1e20f;
    int trapIter = 0;
    float3 trapPos = pos;
    int trapIterations = min(max(colorIterations, 0), iterations);

    int i = 0;
    if (hasRotation) {
        for (; i < iterations; ++i) {
            p = rot * p;

            // Box fold: 2 * clamp(p, mins, maxs) - p
            p = fma(clamp(p, mins, maxs), float3(2.0f), -p);

            // Sphere fold
            float r2 = dot(p, p);
            float k = max(sphFold / max(r2, 1e-6f), 1.0f);
            p *= k;
            scale *= k;

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
    } else {
        for (; i < iterations; ++i) {
            p = fma(clamp(p, mins, maxs), float3(2.0f), -p);

            float r2 = dot(p, p);
            float k = max(sphFold / max(r2, 1e-6f), 1.0f);
            p *= k;
            scale *= k;

            if (i < trapIterations) {
                float r2Trap = dot(p, p);
                if (r2Trap < trap) {
                    trap = r2Trap;
                    trapIter = i;
                    trapPos = p;
                }
            }
        }
    }

    // Cylindrical cross-section DE
    float rxy = length(p.xy);
    float invScale = 1.0f / max(scale, 1e-6f);
    float de = 0.7f * max(rxy - crossR, rxy * p.z / max(length(p), 1e-6f)) * invScale;

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
FORCE_INLINE float DE_Kleinian_Dist(float3 pos, FormulaParams fp, float3x3 rot, int iterations) {
    float3 mins   = float3(fp.params[0], fp.params[1], fp.params[2]);
    float sphFold = fp.params[3];
    float3 maxs   = float3(fp.params[4], fp.params[5], fp.params[6]);
    float crossR  = fp.params[7];
    bool hasRotation = hasRot1Precomputed(fp);

    float3 p = pos;
    float scale = 1.0f;

    if (hasRotation) {
        for (int i = 0; i < iterations; ++i) {
            p = rot * p;
            p = fma(clamp(p, mins, maxs), float3(2.0f), -p);
            float r2 = dot(p, p);
            float k = max(sphFold / max(r2, 1e-6f), 1.0f);
            p *= k;
            scale *= k;
        }
    } else {
        for (int i = 0; i < iterations; ++i) {
            p = fma(clamp(p, mins, maxs), float3(2.0f), -p);
            float r2 = dot(p, p);
            float k = max(sphFold / max(r2, 1e-6f), 1.0f);
            p *= k;
            scale *= k;
        }
    }

    float rxy = length(p.xy);
    float invScale = 1.0f / max(scale, 1e-6f);
    return 0.7f * max(rxy - crossR, rxy * p.z / max(length(p), 1e-6f)) * invScale;
}

#endif /* DE_Kleinian_h */
