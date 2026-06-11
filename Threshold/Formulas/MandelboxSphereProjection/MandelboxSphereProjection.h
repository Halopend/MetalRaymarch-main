//
//  MandelboxSphereProjection.h
//  Threshold
//
//  Mandelbox variant with explicit radial projection after sphere fold.
//  Inspired by the "Accidental Sphere Projection" behavior from the legacy
//  shader map path around commit f50fe1f9. Formula variant credited to halopend.
//
//  params[0]=MinDistance, [1]=FoldingLimit, [2]=SphereRadius,
//  [3]=Scale, [4]=ProjectionBlend, [5]=ProjectionRadius
//

#ifndef DE_MandelboxSphereProjection_h
#define DE_MandelboxSphereProjection_h

FORCE_INLINE float3 projectToSphere(float3 p, float radius) {
    float len = length(p);
    if (len <= 1e-6f) {
        return float3(radius, 0.0f, 0.0f);
    }
    return p * (radius / len);
}

// ---------------------------------------------------------------------------
// Full orbit-tracking version (coloring + normals)
// ---------------------------------------------------------------------------
FORCE_INLINE float DE_MandelboxSphereProjection(float3 pos, FormulaParams fp, float3x3 rot,
                                                int iterations, int colorIterations,
                                                thread OrbitData& orbit) {
    float minDistance = fp.params[0];
    if (abs(minDistance) < 1e-6f) {
        minDistance = (minDistance < 0.0f) ? -1e-6f : 1e-6f;
    }

    float foldingLimit = fp.params[1];
    float sphereRadius = max(abs(fp.params[2]), 1e-6f);
    float scale = fp.params[3];
    float projectionBlend = clamp(fp.params[4], 0.0f, 1.0f);
    float projectionRadius = max(fp.params[5], 1e-6f);
    bool hasRotation = hasRot1Precomputed(fp);

    float sphereRadiusSq = sphereRadius * sphereRadius;
    float invSphereRadiusSq = 1.0f / sphereRadiusSq;

    float4 scale4 = float4(scale, scale, scale, abs(scale)) / minDistance;
    float absScalem1 = abs(scale - 1.0f);
    float absScalePow = powr(max(abs(scale), 1e-6f), float(1 - iterations));

    float4 p = float4(pos, 1.0f);
    float4 p0 = p;

    float trap = 1e20f;
    int trapIter = 0;
    float3 trapPos = pos;
    int trapIterations = min(max(colorIterations, 0), iterations);

    int i = 0;
    for (; i < iterations; ++i) {
        if (hasRotation) {
            p.xyz = rot * p.xyz;
        }

        p.xyz = fma(clamp(p.xyz, -foldingLimit, foldingLimit), float3(2.0f), -p.xyz);

        float r2 = dot(p.xyz, p.xyz);
        float t = clamp(1.0f / max(r2, sphereRadiusSq), 1.0f, invSphereRadiusSq);
        p *= t;

        if (projectionBlend > 0.0f) {
            float3 projected = projectToSphere(p.xyz, projectionRadius);
            p.xyz = mix(p.xyz, projected, projectionBlend);
        }

        p = fma(p, scale4, p0);

        if (i < trapIterations) {
            float trapR2 = dot(p.xyz, p.xyz);
            if (trapR2 < trap) {
                trap = trapR2;
                trapIter = i;
                trapPos = p.xyz;
            }
        }
    }

    float de = (length(p.xyz) - absScalem1) / max(abs(p.w), 1e-6f) - absScalePow;

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
FORCE_INLINE float DE_MandelboxSphereProjection_Dist(float3 pos, FormulaParams fp,
                                                     float3x3 rot, int iterations) {
    float minDistance = fp.params[0];
    if (abs(minDistance) < 1e-6f) {
        minDistance = (minDistance < 0.0f) ? -1e-6f : 1e-6f;
    }

    float foldingLimit = fp.params[1];
    float sphereRadius = max(abs(fp.params[2]), 1e-6f);
    float scale = fp.params[3];
    float projectionBlend = clamp(fp.params[4], 0.0f, 1.0f);
    float projectionRadius = max(fp.params[5], 1e-6f);
    bool hasRotation = hasRot1Precomputed(fp);

    float sphereRadiusSq = sphereRadius * sphereRadius;
    float invSphereRadiusSq = 1.0f / sphereRadiusSq;

    float4 scale4 = float4(scale, scale, scale, abs(scale)) / minDistance;
    float absScalem1 = abs(scale - 1.0f);
    float absScalePow = powr(max(abs(scale), 1e-6f), float(1 - iterations));

    float4 p = float4(pos, 1.0f);
    float4 p0 = p;

    for (int i = 0; i < iterations; ++i) {
        if (hasRotation) {
            p.xyz = rot * p.xyz;
        }

        p.xyz = fma(clamp(p.xyz, -foldingLimit, foldingLimit), float3(2.0f), -p.xyz);

        float r2 = dot(p.xyz, p.xyz);
        float t = clamp(1.0f / max(r2, sphereRadiusSq), 1.0f, invSphereRadiusSq);
        p *= t;

        if (projectionBlend > 0.0f) {
            float3 projected = projectToSphere(p.xyz, projectionRadius);
            p.xyz = mix(p.xyz, projected, projectionBlend);
        }

        p = fma(p, scale4, p0);
    }

    return (length(p.xyz) - absScalem1) / max(abs(p.w), 1e-6f) - absScalePow;
}

#endif /* DE_MandelboxSphereProjection_h */
