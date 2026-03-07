//
//  TheliPseudoKleinian.h
//  Threshold
//
//  Distance estimator for the Theli-AT Style Pseudo Kleinian Hybrid fractal.
//  Scale-1 Julia-box style fold + embedded Menger-like base shape.
//  params[0]=Size, [1-3]=CSize, [4-6]=C,
//  params[7]=DEoffset, [8-10]=Offset,
//  params[11]=MnIterations, [12]=MnScale, [13-15]=MnOffset
//
//  Optimized to match Mandelbox patterns:
//    • float4 packing: position (.xyz) + accumulated derivative (.w) in one
//      SIMD register — sphere fold ×k and offset +c collapse into a single
//      fma(p, float4(k), pOff) instead of three separate ops.
//    • fma box fold: fma(clamp(...), 2.0, -p.xyz) instead of 2.0*clamp – p.xyz.
//    • Merged trap / non-trap loops: hasRotation and trapIterations are uniform
//      (identical across every thread in a simdgroup), so branches on them are
//      zero-cost on Apple Silicon.  Halves loop duplication from 4 → 2.
//
//  Requires: FractalFormulaCommon.h
//

#ifndef DE_TheliPseudoKleinian_h
#define DE_TheliPseudoKleinian_h

#ifdef __METAL_VERSION__

FORCE_INLINE float DE_TheliHybridMengerShape(float3 z, int mnIterations, float mnScale, float3 mnOffset) {
    const float kOneThird = 1.0f / 3.0f;
    float invScalePow = 1.0f;
    float invAbsMnScale = 1.0f / max(abs(mnScale), 1e-4f);
    float zFold = kOneThird * mnOffset.z;
    float3 mnBias = fma(-mnScale, mnOffset, mnOffset);

    // Initial fold
    z = abs(z);
    float sum0 = z.x + z.y + z.z;
    float minXY0 = min(z.x, z.y);
    float maxXY0 = max(z.x, z.y);
    float minZ0 = min(minXY0, z.z);
    float maxZ0 = max(maxXY0, z.z);
    z.x = maxZ0;
    z.z = minZ0;
    z.y = sum0 - (maxZ0 + minZ0);
    z.z = kOneThird + abs(z.z - kOneThird);

    int n = 0;
    for (; n < mnIterations && dot(z, z) < 100.0f; ++n) {
        z = fma(mnScale, z, mnBias);

        z = abs(z);
        float sum = z.x + z.y + z.z;
        float minXY = min(z.x, z.y);
        float maxXY = max(z.x, z.y);
        float minZ = min(minXY, z.z);
        float maxZ = max(maxXY, z.z);
        z.x = maxZ;
        z.z = minZ;
        z.y = sum - (maxZ + minZ);
        z.z = zFold + abs(z.z - zFold);

        // Equivalent to abs(mnScale)^(-n), accumulated without log/exp in safePow.
        invScalePow *= invAbsMnScale;
    }

    return (z.x - mnOffset.x) * invScalePow;
}

// ---------------------------------------------------------------------------
// Full orbit-tracking version (coloring + normals)
// ---------------------------------------------------------------------------
FORCE_INLINE float DE_TheliPseudoKleinian(float3 pos, FormulaParams fp, float3x3 rot,
                                          int iterations, int colorIterations,
                                          thread OrbitData& orbit) {
    float size = max(fp.params[0], 0.0f);
    float3 cSize = max(float3(fp.params[1], fp.params[2], fp.params[3]), float3(1e-4f));
    float3 negCSize = -cSize;
    float3 c = float3(fp.params[4], fp.params[5], fp.params[6]);
    float deOffset = fp.params[7];
    float3 offset = float3(fp.params[8], fp.params[9], fp.params[10]);
    int mnIterations = clamp(int(fp.params[11]), 0, 20);
    float mnScale = fp.params[12];
    float3 mnOffset = float3(fp.params[13], fp.params[14], fp.params[15]);
    bool hasRotation = hasRot1Precomputed(fp);

    // float4 packing: p.xyz = position, p.w = accumulated deFactor
    float4 p = float4(pos, 1.0f);
    // Offset: c applies to xyz; 0 leaves p.w (deFactor) untouched in fma
    float4 pOff = float4(c, 0.0f);

    float trap = 1e20f;
    int trapIter = 0;
    float3 trapPos = pos;
    int i = 0;
    int trapIterations = min(max(colorIterations, 0), iterations);

    float3 ap = abs(p.xyz);
    float r2Inf = max(ap.x, max(ap.y, ap.z));

    // hasRotation is uniform (same for all threads) — branch is zero-cost.
    // trapIterations is also uniform — the inner `if (i < trapIterations)` is
    // resolved identically across the entire simdgroup (no divergence).
    if (hasRotation) {
        for (; i < iterations && r2Inf < 60.0f; ++i) {
            p.xyz = rot * p.xyz;
            // Box fold: fma(clamp, 2, -p) instead of 2*clamp - p
            p.xyz = fma(clamp(p.xyz, negCSize, cSize), float3(2.0f), -p.xyz);

            float r2 = dot(p.xyz, p.xyz);
            float k = max(size / max(r2, 1e-6f), 1.0f);
            // Sphere fold (×k) + offset (+c) in one fma.
            // p.xyz = p.xyz*k + c,  p.w = p.w*k + 0 = p.w*k (deFactor)
            p = fma(p, float4(k), pOff);

            ap = abs(p.xyz);
            r2Inf = max(ap.x, max(ap.y, ap.z));

            // Orbit trap (uniform branch — zero-cost on GPU)
            if (i < trapIterations) {
                float r2Trap = dot(p.xyz, p.xyz);
                if (r2Trap < trap) {
                    trap = r2Trap;
                    trapIter = i;
                    trapPos = p.xyz;
                }
            }
        }
    } else {
        for (; i < iterations && r2Inf < 60.0f; ++i) {
            p.xyz = fma(clamp(p.xyz, negCSize, cSize), float3(2.0f), -p.xyz);

            float r2 = dot(p.xyz, p.xyz);
            float k = max(size / max(r2, 1e-6f), 1.0f);
            p = fma(p, float4(k), pOff);

            ap = abs(p.xyz);
            r2Inf = max(ap.x, max(ap.y, ap.z));

            if (i < trapIterations) {
                float r2Trap = dot(p.xyz, p.xyz);
                if (r2Trap < trap) {
                    trap = r2Trap;
                    trapIter = i;
                    trapPos = p.xyz;
                }
            }
        }
    }

    float baseShape = DE_TheliHybridMengerShape(p.xyz - offset, mnIterations, mnScale, mnOffset);
    float invDeFactor = 0.5f / max(p.w, 1e-6f);
    float de = abs(baseShape * invDeFactor - deOffset);

    orbit.trap = trap;
    orbit.trapIteration = trapIter;
    orbit.trapPosition = trapPos;
    orbit.finalP = p.xyz;
    orbit.iterationsUsed = i;

    return de;
}

// ---------------------------------------------------------------------------
// Lean distance-only (shadows, normals via finite differences)
// ---------------------------------------------------------------------------
FORCE_INLINE float DE_TheliPseudoKleinian_Dist(float3 pos, FormulaParams fp, float3x3 rot, int iterations) {
    float size = max(fp.params[0], 0.0f);
    float3 cSize = max(float3(fp.params[1], fp.params[2], fp.params[3]), float3(1e-4f));
    float3 negCSize = -cSize;
    float3 c = float3(fp.params[4], fp.params[5], fp.params[6]);
    float deOffset = fp.params[7];
    float3 offset = float3(fp.params[8], fp.params[9], fp.params[10]);
    int mnIterations = clamp(int(fp.params[11]), 0, 20);
    float mnScale = fp.params[12];
    float3 mnOffset = float3(fp.params[13], fp.params[14], fp.params[15]);
    bool hasRotation = hasRot1Precomputed(fp);

    float4 p = float4(pos, 1.0f);
    float4 pOff = float4(c, 0.0f);

    float3 ap = abs(p.xyz);
    float r2Inf = max(ap.x, max(ap.y, ap.z));

    if (hasRotation) {
        for (int i = 0; i < iterations && r2Inf < 60.0f; ++i) {
            p.xyz = rot * p.xyz;
            p.xyz = fma(clamp(p.xyz, negCSize, cSize), float3(2.0f), -p.xyz);
            float r2 = dot(p.xyz, p.xyz);
            float k = max(size / max(r2, 1e-6f), 1.0f);
            p = fma(p, float4(k), pOff);
            ap = abs(p.xyz);
            r2Inf = max(ap.x, max(ap.y, ap.z));
        }
    } else {
        for (int i = 0; i < iterations && r2Inf < 60.0f; ++i) {
            p.xyz = fma(clamp(p.xyz, negCSize, cSize), float3(2.0f), -p.xyz);
            float r2 = dot(p.xyz, p.xyz);
            float k = max(size / max(r2, 1e-6f), 1.0f);
            p = fma(p, float4(k), pOff);
            ap = abs(p.xyz);
            r2Inf = max(ap.x, max(ap.y, ap.z));
        }
    }

    float baseShape = DE_TheliHybridMengerShape(p.xyz - offset, mnIterations, mnScale, mnOffset);
    float invDeFactor = 0.5f / max(p.w, 1e-6f);
    return abs(baseShape * invDeFactor - deOffset);
}

#endif // __METAL_VERSION__

#endif /* DE_TheliPseudoKleinian_h */
