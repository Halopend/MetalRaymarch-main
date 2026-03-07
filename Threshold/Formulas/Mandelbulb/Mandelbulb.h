//
//  Mandelbulb.h
//  Threshold
//
//  Distance estimator for the Mandelbulb fractal.
//  params[0]=Power, [1]=Bailout, [2]=DerivBias (DE multiplier for resolution),
//  [3]=AlternateVer(bool),
//  [4]=PolarRotation, [5]=PolarRotation2, [8]=Julia(bool), [9-11]=JuliaC
//
//  Requires: FractalFormulaCommon.h
//

#ifndef DE_Mandelbulb_h
#define DE_Mandelbulb_h

FORCE_INLINE float DE_Mandelbulb(float3 pos, FormulaParams fp, float3x3 rot,
                                 int iterations, int colorIterations,
                                 thread OrbitData& orbit) {
    float power   = fp.params[0];
    float bailout = fp.params[1];
    float dBias   = max(fp.params[2], 0.01f);  // Clamp minimum for safety
    bool  alternate = fp.params[3] > 0.5f;
    float polarRot  = fp.params[4];
    float polarRot2 = fp.params[5];
    bool  julia     = fp.params[8] > 0.5f;
    float3 juliaC   = float3(fp.params[9], fp.params[10], fp.params[11]);

    float3 z = pos;
    float3 c = julia ? juliaC : pos;
    float dr = 1.0f;
    float r2 = dot(z, z);
    float r  = fast::sqrt(r2);

    float trap = 1e20f;
    int trapIter = 0;
    float3 trapPos = z;
    int i = 0;

    // Min-distance early exit: once r is tiny we're on/inside the surface.
    // Skipping remaining trig-heavy iterations saves significant ALU at deep zoom.
    const float minR2Exit = 1e-12f;

    for (; i < iterations && r2 < bailout * bailout && r2 > minR2Exit; ) {
        float log2r = fast::log2(max(r, 1e-30f));

        if (alternate) {
            // Alternate "triplex" approach
            float theta = fast::acos(clamp11(z.z / max(r, kEpsLen))) + polarRot;
            float phi   = fast::atan2(z.y, z.x);
            float rn    = fast::exp2(power * log2r);
            dr = rn * power * dr / max(r, kEpsLen) + 1.0f;
            
            float thetaP = theta * power;
            float sTheta = fast::sin(thetaP);
            float cTheta = fast::cos(thetaP);
            float phiP = phi * power;
            float sPhi = fast::sin(phiP);
            float cPhi = fast::cos(phiP);
            
            z = rn * float3(sTheta * cPhi,
                            sTheta * sPhi,
                            cTheta);
        } else {
            // Standard spherical coordinates
            // polarRot2 provides a secondary phase offset that can emulate
            // alternate-like framing without toggling AlternateVer.
            float theta = fast::asin(clamp11(z.z / max(r, kEpsLen))) + polarRot + polarRot2;
            float phi   = fast::atan2(z.y, z.x);
            float rn    = fast::exp2(power * log2r);
            dr = rn * power * dr / max(r, kEpsLen) + 1.0f;
            
            float thetaP = theta * power;
            float sTheta = fast::sin(thetaP);
            float cTheta = fast::cos(thetaP);
            float phiP = phi * power;
            float sPhi = fast::sin(phiP);
            float cPhi = fast::cos(phiP);
            
            z = rn * float3(cTheta * cPhi,
                            cTheta * sPhi,
                            sTheta);
        }

        z += c;
        z  = rot * z;

        r2 = dot(z, z);
        r  = fast::sqrt(r2);

        UpdateTrapMinR2(trap, trapIter, trapPos, r2, i, colorIterations, z);
        ++i;
    }

    orbit.trap = trap;
    orbit.trapIteration = trapIter;
    orbit.trapPosition = trapPos;
    orbit.finalP = z;
    orbit.iterationsUsed = i;

    // dBias acts as a DE multiplier: <1 = finer surface detail, >1 = coarser/faster.
    // The additive bias in the loop is fixed at 1.0 for numerical stability;
    // dBias scales the final result for user-controllable resolution.
    return dBias * 0.5f * r * fast::log2(max(r, 1e-30f)) / max(dr, kEpsLen) * kLn2;
}

// Lean distance-only: no orbit tracking, no struct writes.
FORCE_INLINE float DE_Mandelbulb_Dist(float3 pos, FormulaParams fp, float3x3 rot, int iterations) {
    float power   = fp.params[0];
    float bailout2 = fp.params[1] * fp.params[1];
    float dBias   = max(fp.params[2], 0.01f);  // Clamp minimum for safety
    bool  alternate = fp.params[3] > 0.5f;
    float polarRot  = fp.params[4];
    float polarRot2 = fp.params[5];
    bool  julia     = fp.params[8] > 0.5f;
    float3 juliaC   = float3(fp.params[9], fp.params[10], fp.params[11]);

    float3 z = pos;
    float3 c = julia ? juliaC : pos;
    float dr = 1.0f;
    float r2 = dot(z, z);
    float r  = fast::sqrt(r2);

    // Min-distance early exit: once r is tiny we're on/inside the surface.
    const float minR2Exit = 1e-12f;

    for (int i = 0; i < iterations && r2 < bailout2 && r2 > minR2Exit; ++i) {
        float log2r = fast::log2(max(r, 1e-30f));
        if (alternate) {
            float theta = fast::acos(clamp11(z.z / max(r, kEpsLen))) + polarRot;
            float phi   = fast::atan2(z.y, z.x);
            float rn    = fast::exp2(power * log2r);
            dr = rn * power * dr / max(r, kEpsLen) + 1.0f;
            float thetaP = theta * power;
            float sTheta = fast::sin(thetaP);
            float cTheta = fast::cos(thetaP);
            float phiP = phi * power;
            float sPhi = fast::sin(phiP);
            float cPhi = fast::cos(phiP);
            z = rn * float3(sTheta * cPhi,
                            sTheta * sPhi,
                            cTheta);
        } else {
            float theta = fast::asin(clamp11(z.z / max(r, kEpsLen))) + polarRot + polarRot2;
            float phi   = fast::atan2(z.y, z.x);
            float rn    = fast::exp2(power * log2r);
            dr = rn * power * dr / max(r, kEpsLen) + 1.0f;
            float thetaP = theta * power;
            float sTheta = fast::sin(thetaP);
            float cTheta = fast::cos(thetaP);
            float phiP = phi * power;
            float sPhi = fast::sin(phiP);
            float cPhi = fast::cos(phiP);
            z = rn * float3(cTheta * cPhi,
                            cTheta * sPhi,
                            sTheta);
        }
        z += c;
        z  = rot * z;
        r2 = dot(z, z);
        r  = fast::sqrt(r2);
    }

    // dBias as final DE multiplier for resolution control
    return dBias * 0.5f * r * fast::log2(max(r, 1e-30f)) / max(dr, kEpsLen) * kLn2;
}

#endif /* DE_Mandelbulb_h */
