//
//  QuaternionJulia.h
//  Threshold
//
//  Distance estimator for the Quaternion Julia set fractal.
//  params[0-3]=C(x,y,z,w), [4]=Threshold
//
//  Requires: FractalFormulaCommon.h
//

#ifndef DE_QuaternionJulia_h
#define DE_QuaternionJulia_h

FORCE_INLINE float DE_QuaternionJulia(float3 pos, FormulaParams fp, float3x3 rot,
                                      int iterations, int colorIterations,
                                     thread OrbitData& orbit) {
    float4 c = float4(fp.params[0], fp.params[1], fp.params[2], fp.params[3]);
    float threshold = fp.params[4];

    // q = quaternion (x,y,z,w), start at (pos, 0)
    float4 q = float4(pos, 0.0f);
    float4 dq = float4(1.0f, 0.0f, 0.0f, 0.0f);
    float trap = 1e20f;
    int trapIter = 0;
    float3 trapPos = pos;
    int i = 0;

    for (; i < iterations; ++i) {
        // dq = 2 * q * dq (quaternion multiplication for derivative)
        dq = 2.0f * float4(
            q.x*dq.x - q.y*dq.y - q.z*dq.z - q.w*dq.w,
            q.x*dq.y + q.y*dq.x + q.z*dq.w - q.w*dq.z,
            q.x*dq.z - q.y*dq.w + q.z*dq.x + q.w*dq.y,
            q.x*dq.w + q.y*dq.z - q.z*dq.y + q.w*dq.x
        );

        // q = q*q + c (quaternion squaring)
        q = float4(
            q.x*q.x - q.y*q.y - q.z*q.z - q.w*q.w,
            2.0f*q.x*q.y,
            2.0f*q.x*q.z,
            2.0f*q.x*q.w
        ) + c;

        float r2 = dot(q, q);
        UpdateTrapMinR2(trap, trapIter, trapPos, r2, i, colorIterations, q.xyz);

        if (r2 > threshold) break;
    }

    orbit.trap = trap;
    orbit.trapIteration = trapIter;
    orbit.trapPosition = trapPos;
    orbit.finalP = q.xyz;
    orbit.iterationsUsed = i;

    float r = fast::length(q);
    float dr = fast::length(dq);
    return 0.5f * r * fast::log(max(r, 1e-30f)) / max(dr, kEpsLen);
}

// Lean distance-only: no orbit tracking, no struct writes.
FORCE_INLINE float DE_QuaternionJulia_Dist(float3 pos, FormulaParams fp, float3x3 rot, int iterations) {
    float4 c = float4(fp.params[0], fp.params[1], fp.params[2], fp.params[3]);
    float threshold = fp.params[4];

    float4 q = float4(pos, 0.0f);
    float4 dq = float4(1.0f, 0.0f, 0.0f, 0.0f);

    for (int i = 0; i < iterations; ++i) {
        dq = 2.0f * float4(
            q.x*dq.x - q.y*dq.y - q.z*dq.z - q.w*dq.w,
            q.x*dq.y + q.y*dq.x + q.z*dq.w - q.w*dq.z,
            q.x*dq.z - q.y*dq.w + q.z*dq.x + q.w*dq.y,
            q.x*dq.w + q.y*dq.z - q.z*dq.y + q.w*dq.x
        );

        q = float4(
            q.x*q.x - q.y*q.y - q.z*q.z - q.w*q.w,
            2.0f*q.x*q.y,
            2.0f*q.x*q.z,
            2.0f*q.x*q.w
        ) + c;

        if (dot(q, q) > threshold) break;
    }

    float r = fast::length(q);
    return 0.5f * r * fast::log(max(r, 1e-30f)) / max(fast::length(dq), kEpsLen);
}

#endif /* DE_QuaternionJulia_h */
