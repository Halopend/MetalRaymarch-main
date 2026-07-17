//
//  Kleinian.h
//  Threshold
//
//  Distance estimator based on Knighty's Pseudo Kleinian fractal.
//  Box fold + sphere inversion with a cylindrical cross-section DE.
//
//  Reference license: GPLv3 (Mandelbulber reference implementation)
//  Authors: Theli-at (original hybrid); Knighty (standalone formulation)
//  Found: https://github.com/buddhi1980/mandelbulber2/blob/master/mandelbulber2/formula/definition/fractal_pseudo_kleinian.cpp
//
//  params[0-2]=Mins.xyz, [3]=SphFold, [4-6]=Maxs.xyz, [7]=CrossR,
//  params[8]=ColorOfs, [9]=ColorScale
//
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

    // float4 packing: q.xyz = position, q.w = accumulated scale — the sphere
    // fold's ×k hits all four lanes in one SIMD multiply.
    float4 q = float4(pos, 1.0f);

    float trap = 1e20f;
    int trapIter = 0;
    float3 trapPos = pos;
    int trapIterations = min(max(colorIterations, 0), iterations);

    int i = 0;
    if (hasRotation) {
        for (; i < iterations; ++i) {
            q.xyz = rot * q.xyz;

            // Box fold: 2 * clamp(p, mins, maxs) - p
            q.xyz = fma(clamp(q.xyz, mins, maxs), float3(2.0f), -q.xyz);

            // Sphere fold
            float r2 = dot(q.xyz, q.xyz);
            float k = max(sphFold / max(r2, 1e-6f), 1.0f);
            q *= k;

            // Orbit trap
            if (i < trapIterations) {
                float r2Trap = dot(q.xyz, q.xyz);
                if (r2Trap < trap) {
                    trap = r2Trap;
                    trapIter = i;
                    trapPos = q.xyz;
                }
            }
        }
    } else {
        for (; i < iterations; ++i) {
            q.xyz = fma(clamp(q.xyz, mins, maxs), float3(2.0f), -q.xyz);

            float r2 = dot(q.xyz, q.xyz);
            float k = max(sphFold / max(r2, 1e-6f), 1.0f);
            q *= k;

            if (i < trapIterations) {
                float r2Trap = dot(q.xyz, q.xyz);
                if (r2Trap < trap) {
                    trap = r2Trap;
                    trapIter = i;
                    trapPos = q.xyz;
                }
            }
        }
    }

    // Cylindrical cross-section DE
    float rxy = length(q.xy);
    float invScale = 1.0f / max(q.w, 1e-6f);
    float de = 0.7f * max(rxy - crossR, rxy * q.z / max(length(q.xyz), 1e-6f)) * invScale;

    orbit.trap = trap;
    orbit.trapIteration = trapIter;
    orbit.trapPosition = trapPos;
    orbit.finalP = q.xyz;
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

    float4 q = float4(pos, 1.0f);

    if (hasRotation) {
        for (int i = 0; i < iterations; ++i) {
            q.xyz = rot * q.xyz;
            q.xyz = fma(clamp(q.xyz, mins, maxs), float3(2.0f), -q.xyz);
            float r2 = dot(q.xyz, q.xyz);
            float k = max(sphFold / max(r2, 1e-6f), 1.0f);
            q *= k;
        }
    } else {
        for (int i = 0; i < iterations; ++i) {
            q.xyz = fma(clamp(q.xyz, mins, maxs), float3(2.0f), -q.xyz);
            float r2 = dot(q.xyz, q.xyz);
            float k = max(sphFold / max(r2, 1e-6f), 1.0f);
            q *= k;
        }
    }

    float rxy = length(q.xy);
    float invScale = 1.0f / max(q.w, 1e-6f);
    return 0.7f * max(rxy - crossR, rxy * q.z / max(length(q.xyz), 1e-6f)) * invScale;
}

#endif /* DE_Kleinian_h */
