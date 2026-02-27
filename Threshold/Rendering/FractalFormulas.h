//
//  FractalFormulas.h
//  Threshold
//
//  14 non-Mandelbox distance estimator (DE) functions + dispatch tables.
//  Included by Shaders.metal after metal_stdlib and ShaderTypes.h.
//  Each formula has:
//    DE_XXX(..., thread OrbitData& orbit) — full orbit-tracking version
//    DE_XXX_Dist(...)                     — distance-only (no orbit)
//
//  Dispatch:
//    FractalDE_Dispatch(pos, fractalType, fp, iterations) → distance only
//    FractalDE_WithOrbit(pos, fractalType, fp, iterations, colorIterations, orbit) → + orbit
//
//  Requires: metal_stdlib, ShaderTypes.h (FormulaParams, FractalType enum),
//            FORCE_INLINE macro (defined in Shaders.metal)
//

#ifndef FractalFormulas_h
#define FractalFormulas_h

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------
constant float kEpsLen   = 1e-16f;
constant float kEpsAcos  = 1e-8f;
constant float kLn2      = 0.6931471805599453f;
constant float kLog2_10  = 3.32192809488736234787f; // log2(10)

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
inline float3x3 rotationMatrix3(float3 v, float angleDeg) {
    float angle = angleDeg * M_PI_F / 180.0f;
    float c = cos(angle), s = sin(angle);
    float t = 1.0f - c;
    v = normalize(v);
    return float3x3(
        float3(t*v.x*v.x + c,      t*v.x*v.y - s*v.z,  t*v.x*v.z + s*v.y),
        float3(t*v.x*v.y + s*v.z,  t*v.y*v.y + c,      t*v.y*v.z - s*v.x),
        float3(t*v.x*v.z - s*v.y,  t*v.y*v.z + s*v.x,  t*v.z*v.z + c)
    );
}

inline float clamp11(float x) { return clamp(x, -1.0f, 1.0f); }

// Safe power: pow(a, b) for a >= 0
inline float safePow(float a, float b) {
    return exp2(b * log2(max(a, 1e-30f)));
}
// Signed power: sign(s) * |s|^e
inline float signedPow(float s, float e) {
    return sign(s) * exp2(e * log2(max(abs(s), 1e-30f)));
}

// ---------------------------------------------------------------------------
// Orbit tracking helper — updates minimum-r² trap and metadata
// ---------------------------------------------------------------------------
inline void UpdateTrapMinR2(thread float& trap, thread int& trapIter, thread float3& trapPos,
                            float r2, int i, int colorIterations, float3 p) {
    if (i < colorIterations && r2 < trap) {
        trap = r2;
        trapIter = i;
        trapPos = p;
    }
}

// ---------------------------------------------------------------------------
// OrbitData — returned by full-orbit DE functions
// ---------------------------------------------------------------------------
struct OrbitData {
    float trap;           // minimum r² trap
    int   trapIteration;  // iteration index of minimum trap
    float3 trapPosition;  // position at minimum trap
    float3 finalP;        // final iterated position
    int   iterationsUsed; // number of iterations performed
};

// ============================================================================
// 1. MANDELBULB
// ============================================================================
// params[0]=Power, [1]=Bailout, [2]=DerivBias, [3]=AlternateVer(bool),
// [4]=PolarRotation, [8]=Julia(bool), [9-11]=JuliaC
FORCE_INLINE float DE_Mandelbulb(float3 pos, FormulaParams fp, float3x3 rot,
                                 int iterations, int colorIterations,
                                 thread OrbitData& orbit) {
    float power   = fp.params[0];
    float bailout = fp.params[1];
    float dBias   = fp.params[2];
    bool  alternate = fp.params[3] > 0.5f;
    float polarRot  = fp.params[4];
    bool  julia     = fp.params[8] > 0.5f;
    float3 juliaC   = float3(fp.params[9], fp.params[10], fp.params[11]);

    float3 z = pos;
    float3 c = julia ? juliaC : pos;
    float dr = 1.0f;
    float r2 = dot(z, z);
    float r  = sqrt(r2);

    float trap = 1e20f;
    int trapIter = 0;
    float3 trapPos = z;
    int i = 0;

    for (; i < iterations && r2 < bailout * bailout; ) {
        float log2r = log2(max(r, 1e-30f));

        if (alternate) {
            // Alternate "triplex" approach
            float theta = acos(clamp11(z.z / max(r, kEpsLen))) + polarRot;
            float phi   = atan2(z.y, z.x);
            float rn    = exp2(power * log2r);
            dr = rn * power * dr / max(r, kEpsLen) + dBias;
            
            float thetaP = theta * power;
            float sTheta = sin(thetaP);
            float cTheta = cos(thetaP);
            float phiP = phi * power;
            float sPhi = sin(phiP);
            float cPhi = cos(phiP);
            
            z = rn * float3(sTheta * cPhi,
                            sTheta * sPhi,
                            cTheta);
        } else {
            // Standard spherical coordinates
            float theta = asin(clamp11(z.z / max(r, kEpsLen))) + polarRot;
            float phi   = atan2(z.y, z.x);
            float rn    = exp2(power * log2r);
            dr = rn * power * dr / max(r, kEpsLen) + dBias;
            
            float thetaP = theta * power;
            float sTheta = sin(thetaP);
            float cTheta = cos(thetaP);
            float phiP = phi * power;
            float sPhi = sin(phiP);
            float cPhi = cos(phiP);
            
            z = rn * float3(cTheta * cPhi,
                            cTheta * sPhi,
                            sTheta);
        }

        z += c;
        z  = rot * z;

        r2 = dot(z, z);
        r  = sqrt(r2);

        UpdateTrapMinR2(trap, trapIter, trapPos, r2, i, colorIterations, z);
        ++i;
    }

    orbit.trap = trap;
    orbit.trapIteration = trapIter;
    orbit.trapPosition = trapPos;
    orbit.finalP = z;
    orbit.iterationsUsed = i;

    return 0.5f * r * log2(max(r, 1e-30f)) / max(dr, kEpsLen) * kLn2;
}

// Lean distance-only: no orbit tracking, no struct writes.
FORCE_INLINE float DE_Mandelbulb_Dist(float3 pos, FormulaParams fp, float3x3 rot, int iterations) {
    float power   = fp.params[0];
    float bailout2 = fp.params[1] * fp.params[1];
    float dBias   = fp.params[2];
    bool  alternate = fp.params[3] > 0.5f;
    float polarRot  = fp.params[4];
    bool  julia     = fp.params[8] > 0.5f;
    float3 juliaC   = float3(fp.params[9], fp.params[10], fp.params[11]);

    float3 z = pos;
    float3 c = julia ? juliaC : pos;
    float dr = 1.0f;
    float r2 = dot(z, z);
    float r  = sqrt(r2);

    for (int i = 0; i < iterations && r2 < bailout2; ++i) {
        float log2r = log2(max(r, 1e-30f));
        if (alternate) {
            float theta = acos(clamp11(z.z / max(r, kEpsLen))) + polarRot;
            float phi   = atan2(z.y, z.x);
            float rn    = exp2(power * log2r);
            dr = rn * power * dr / max(r, kEpsLen) + dBias;
            float thetaP = theta * power;
            float sTheta = sin(thetaP);
            float cTheta = cos(thetaP);
            float phiP = phi * power;
            float sPhi = sin(phiP);
            float cPhi = cos(phiP);
            z = rn * float3(sTheta * cPhi,
                            sTheta * sPhi,
                            cTheta);
        } else {
            float theta = asin(clamp11(z.z / max(r, kEpsLen))) + polarRot;
            float phi   = atan2(z.y, z.x);
            float rn    = exp2(power * log2r);
            dr = rn * power * dr / max(r, kEpsLen) + dBias;
            float thetaP = theta * power;
            float sTheta = sin(thetaP);
            float cTheta = cos(thetaP);
            float phiP = phi * power;
            float sPhi = sin(phiP);
            float cPhi = cos(phiP);
            z = rn * float3(cTheta * cPhi,
                            cTheta * sPhi,
                            sTheta);
        }
        z += c;
        z  = rot * z;
        r2 = dot(z, z);
        r  = sqrt(r2);
    }

    return 0.5f * r * log2(max(r, 1e-30f)) / max(dr, kEpsLen) * kLn2;
}

// ============================================================================
// 2. MENGER SPONGE
// ============================================================================
// params[0]=Scale, [1-3]=Offset
FORCE_INLINE float DE_Menger(float3 pos, FormulaParams fp, float3x3 rot,
                             int iterations, int colorIterations,
                            thread OrbitData& orbit) {
    float scale  = fp.params[0];
    float3 offset = float3(fp.params[1], fp.params[2], fp.params[3]);

    float3 z = pos;
    float dr = 1.0f;
    float trap = 1e20f;
    int trapIter = 0;
    float3 trapPos = z;
    int i = 0;

    for (; i < iterations; ++i) {
        // Fold into positive octant
        z = abs(z);
        // Sort components so z.x >= z.y >= z.z
        float sum = z.x + z.y + z.z;
        float min_xy = min(z.x, z.y);
        float max_xy = max(z.x, z.y);
        float min_z = min(min_xy, z.z);
        float max_z = max(max_xy, z.z);
        z.x = max_z;
        z.z = min_z;
        z.y = sum - (max_z + min_z);

        float3 offsetScaled = offset * (scale - 1.0f);
        z = z * scale - offsetScaled;
        
        float foldZ = -0.5f * offsetScaled.z;
        z.z += (z.z < foldZ) ? offsetScaled.z : 0.0f;

        z = rot * z;
        dr = dr * abs(scale) + 1.0f;

        float r2 = dot(z, z);
        UpdateTrapMinR2(trap, trapIter, trapPos, r2, i, colorIterations, z);
    }

    orbit.trap = trap;
    orbit.trapIteration = trapIter;
    orbit.trapPosition = trapPos;
    orbit.finalP = z;
    orbit.iterationsUsed = i;

    float r = length(z);
    return (r - 1.0f) / dr;
}

// Lean distance-only: no orbit tracking, no struct writes.
FORCE_INLINE float DE_Menger_Dist(float3 pos, FormulaParams fp, float3x3 rot, int iterations) {
    float scale  = fp.params[0];
    float3 offset = float3(fp.params[1], fp.params[2], fp.params[3]);
    float3 offsetScaled = offset * (scale - 1.0f);
    float halfOffsetZn = -0.5f * offsetScaled.z;

    float3 z = pos;
    float dr = 1.0f;

    for (int i = 0; i < iterations; ++i) {
        z = abs(z);
        float sum = z.x + z.y + z.z;
        float min_xy = min(z.x, z.y);
        float max_xy = max(z.x, z.y);
        float min_z = min(min_xy, z.z);
        float max_z = max(max_xy, z.z);
        z.x = max_z;
        z.z = min_z;
        z.y = sum - (max_z + min_z);

        z = z * scale - offsetScaled;
        z.z += (z.z < halfOffsetZn) ? offsetScaled.z : 0.0f;

        z = rot * z;
        dr = dr * abs(scale) + 1.0f;
    }

    return (length(z) - 1.0f) / dr;
}

// ============================================================================
// 3. SIERPINSKI TETRAHEDRON
// ============================================================================
// params[0]=Scale, [1-3]=Offset
FORCE_INLINE float DE_Sierpinski(float3 pos, FormulaParams fp, float3x3 rot,
                                 int iterations, int colorIterations,
                                 thread OrbitData& orbit) {
    float scale  = fp.params[0];
    float3 offset = float3(fp.params[1], fp.params[2], fp.params[3]);

    float3 z = pos;
    float dr = 1.0f;
    float trap = 1e20f;
    int trapIter = 0;
    float3 trapPos = z;
    int i = 0;

    for (; i < iterations; ++i) {
        // Tetrahedral folds
        if (z.x + z.y < 0.0f) z.xy = -z.yx;
        if (z.x + z.z < 0.0f) z.xz = -z.zx;
        if (z.y + z.z < 0.0f) z.yz = -z.zy;

        z = z * scale - offset * (scale - 1.0f);
        z = rot * z;
        dr = dr * scale + 1.0f;

        float r2 = dot(z, z);
        UpdateTrapMinR2(trap, trapIter, trapPos, r2, i, colorIterations, z);
    }

    orbit.trap = trap;
    orbit.trapIteration = trapIter;
    orbit.trapPosition = trapPos;
    orbit.finalP = z;
    orbit.iterationsUsed = i;

    float r = length(z);
    return (r - 1.0f) / dr;
}

// Lean distance-only: no orbit tracking, no struct writes.
FORCE_INLINE float DE_Sierpinski_Dist(float3 pos, FormulaParams fp, float3x3 rot, int iterations) {
    float scale  = fp.params[0];
    float3 offset = float3(fp.params[1], fp.params[2], fp.params[3]);
    float3 offsetScaled = offset * (scale - 1.0f);

    float3 z = pos;
    float dr = 1.0f;

    for (int i = 0; i < iterations; ++i) {
        if (z.x + z.y < 0.0f) z.xy = -z.yx;
        if (z.x + z.z < 0.0f) z.xz = -z.zx;
        if (z.y + z.z < 0.0f) z.yz = -z.zy;

        z = z * scale - offsetScaled;
        z = rot * z;
        dr = dr * scale + 1.0f;
    }

    return (length(z) - 1.0f) / dr;
}

// ============================================================================
// 4. DODECAHEDRON IFS
// ============================================================================
// params[0]=Scale, [1]=Phi, [2]=Log10Bailout
FORCE_INLINE float DE_Dodecahedron(float3 pos, FormulaParams fp, float3x3 rot,
                                   int iterations, int colorIterations,
                                  thread OrbitData& orbit) {
    float scale   = fp.params[0];
    float phi     = fp.params[1];
    float bailout = exp2(fp.params[2] * kLog2_10); // 10^Log10Bailout

    // Golden ratio vectors for dodecahedral symmetry
    float3 n1 = normalize(float3(-1.0f, phi, 1.0f/phi));
    float3 n2 = normalize(float3(1.0f/phi, -1.0f, phi));
    float3 n3 = normalize(float3(phi, 1.0f/phi, -1.0f));

    float3 z = pos;
    float dr = 1.0f;
    float trap = 1e20f;
    int trapIter = 0;
    float3 trapPos = z;
    int i = 0;

    for (; i < iterations; ++i) {
        // Mirror folds across dodecahedral planes
        z -= 2.0f * min(0.0f, dot(z, n1)) * n1;
        z -= 2.0f * min(0.0f, dot(z, n2)) * n2;
        z -= 2.0f * min(0.0f, dot(z, n3)) * n3;

        z = z * scale - float3(1.0f) * (scale - 1.0f);
        z = rot * z;
        dr = dr * abs(scale) + 1.0f;

        float r2 = dot(z, z);
        UpdateTrapMinR2(trap, trapIter, trapPos, r2, i, colorIterations, z);
        if (r2 > bailout) break;
    }

    orbit.trap = trap;
    orbit.trapIteration = trapIter;
    orbit.trapPosition = trapPos;
    orbit.finalP = z;
    orbit.iterationsUsed = i;

    float r = length(z);
    return (r - 1.0f) / dr;
}

// Lean distance-only: no orbit tracking, no struct writes.
FORCE_INLINE float DE_Dodecahedron_Dist(float3 pos, FormulaParams fp, float3x3 rot, int iterations) {
    float scale   = fp.params[0];
    float phi     = fp.params[1];
    float bailout = exp2(fp.params[2] * kLog2_10);

    float3 n1 = normalize(float3(-1.0f, phi, 1.0f/phi));
    float3 n2 = normalize(float3(1.0f/phi, -1.0f, phi));
    float3 n3 = normalize(float3(phi, 1.0f/phi, -1.0f));

    float3 z = pos;
    float dr = 1.0f;

    for (int i = 0; i < iterations; ++i) {
        z -= 2.0f * min(0.0f, dot(z, n1)) * n1;
        z -= 2.0f * min(0.0f, dot(z, n2)) * n2;
        z -= 2.0f * min(0.0f, dot(z, n3)) * n3;

        z = z * scale - float3(1.0f) * (scale - 1.0f);
        z = rot * z;
        dr = dr * abs(scale) + 1.0f;

        if (dot(z, z) > bailout) break;
    }

    return (length(z) - 1.0f) / dr;
}

// ============================================================================
// 5. PSEUDO-KLEINIAN
// ============================================================================
// params[0]=Size, [1-3]=CSize, [4-6]=C, [7]=DEoffset, [8-10]=Offset
FORCE_INLINE float DE_PseudoKleinian(float3 pos, FormulaParams fp, float3x3 rot,
                                     int iterations, int colorIterations,
                                    thread OrbitData& orbit) {
    float size    = fp.params[0];
    float3 csize  = float3(fp.params[1], fp.params[2], fp.params[3]);
    float3 c      = float3(fp.params[4], fp.params[5], fp.params[6]);
    float deOff   = fp.params[7];
    float3 offset = float3(fp.params[8], fp.params[9], fp.params[10]);

    float3 z = pos;
    float DEfactor = 1.0f;
    float trap = 1e20f;
    int trapIter = 0;
    float3 trapPos = z;
    int i = 0;

    for (; i < iterations; ++i) {
        // Box fold
        z = clamp(z, -csize, csize) * 2.0f - z;

        // Inversion
        float r2 = dot(z, z);
        float k = max(size / r2, 1.0f);
        z *= k;
        DEfactor *= k;

        z += c;
        z = rot * z;

        // Conditional offset
        if (z.y < z.x) z.xy = z.yx;
        z += offset;
        if (z.y < z.x) z.xy = z.yx;

        UpdateTrapMinR2(trap, trapIter, trapPos, dot(z,z), i, colorIterations, z);
    }

    orbit.trap = trap;
    orbit.trapIteration = trapIter;
    orbit.trapPosition = trapPos;
    orbit.finalP = z;
    orbit.iterationsUsed = i;

    float r = length(z);
    return (r - deOff) / DEfactor;
}

// Lean distance-only: no orbit tracking, no struct writes.
FORCE_INLINE float DE_PseudoKleinian_Dist(float3 pos, FormulaParams fp, float3x3 rot, int iterations) {
    float size    = fp.params[0];
    float3 csize  = float3(fp.params[1], fp.params[2], fp.params[3]);
    float3 c      = float3(fp.params[4], fp.params[5], fp.params[6]);
    float deOff   = fp.params[7];
    float3 offset = float3(fp.params[8], fp.params[9], fp.params[10]);

    float3 z = pos;
    float DEfactor = 1.0f;

    for (int i = 0; i < iterations; ++i) {
        z = clamp(z, -csize, csize) * 2.0f - z;

        float r2 = dot(z, z);
        float k = max(size / r2, 1.0f);
        z *= k;
        DEfactor *= k;

        z += c;
        z = rot * z;

        if (z.y < z.x) z.xy = z.yx;
        z += offset;
        if (z.y < z.x) z.xy = z.yx;
    }

    return (length(z) - deOff) / DEfactor;
}

// ============================================================================
// 6. QUATERNION JULIA
// ============================================================================
// params[0-3]=C(x,y,z,w), [4]=Threshold
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

    float r = length(q);
    float dr = length(dq);
    return 0.5f * r * log(max(r, 1e-30f)) / max(dr, kEpsLen);
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

    float r = length(q);
    return 0.5f * r * log(max(r, 1e-30f)) / max(length(dq), kEpsLen);
}

// ============================================================================
// 7. AMAZING SURFACE
// ============================================================================
// params[0]=Scale, [1]=MinRad2, [2]=FoldType(int), [3-4]=FoldValues,
// [5-7]=PreTranslation, [8]=Julia(bool), [9-11]=JuliaC
FORCE_INLINE float DE_AmazingSurface(float3 pos, FormulaParams fp, float3x3 rot,
                                     int iterations, int colorIterations,
                                    thread OrbitData& orbit) {
    float scale  = fp.params[0];
    float minR2  = fp.params[1];
    int foldType = int(fp.params[2]);
    float2 foldV = float2(fp.params[3], fp.params[4]);
    float3 pre   = float3(fp.params[5], fp.params[6], fp.params[7]);
    bool julia    = fp.params[8] > 0.5f;
    float3 juliaC = float3(fp.params[9], fp.params[10], fp.params[11]);

    float3 z = pos + pre;
    float3 c = julia ? juliaC : pos;
    float dr = 1.0f;

    float trap = 1e20f;
    int trapIter = 0;
    float3 trapPos = z;
    int i = 0;

    for (; i < iterations; ++i) {
        // Fold
        if (foldType == 0) {
            z = abs(z + foldV.x) - abs(z - foldV.x) - z;
        } else if (foldType == 1) {
            z.xy = abs(z.xy + foldV) - abs(z.xy - foldV) - z.xy;
        } else {
            z = abs(z);
        }

        // Sphere fold (Mandelbox-style)
        float r2 = dot(z, z);
        float k = max(scale / max(r2, minR2), 1.0f);
        z *= k;
        dr = dr * abs(k) + 1.0f;

        z += c;
        z = rot * z;

        UpdateTrapMinR2(trap, trapIter, trapPos, dot(z,z), i, colorIterations, z);
    }

    orbit.trap = trap;
    orbit.trapIteration = trapIter;
    orbit.trapPosition = trapPos;
    orbit.finalP = z;
    orbit.iterationsUsed = i;

    float r = length(z);
    return (r - abs(scale - 1.0f)) / dr - 1e-6f;
}

// Lean distance-only: no orbit tracking, no struct writes.
FORCE_INLINE float DE_AmazingSurface_Dist(float3 pos, FormulaParams fp, float3x3 rot, int iterations) {
    float scale  = fp.params[0];
    float minR2  = fp.params[1];
    int foldType = int(fp.params[2]);
    float2 foldV = float2(fp.params[3], fp.params[4]);
    float3 pre   = float3(fp.params[5], fp.params[6], fp.params[7]);
    bool julia    = fp.params[8] > 0.5f;
    float3 juliaC = float3(fp.params[9], fp.params[10], fp.params[11]);

    float3 z = pos + pre;
    float3 c = julia ? juliaC : pos;
    float dr = 1.0f;

    for (int i = 0; i < iterations; ++i) {
        if (foldType == 0) {
            z = abs(z + foldV.x) - abs(z - foldV.x) - z;
        } else if (foldType == 1) {
            z.xy = abs(z.xy + foldV) - abs(z.xy - foldV) - z.xy;
        } else {
            z = abs(z);
        }

        float r2 = dot(z, z);
        float k = max(scale / max(r2, minR2), 1.0f);
        z *= k;
        dr = dr * abs(k) + 1.0f;

        z += c;
        z = rot * z;
    }

    return (length(z) - abs(scale - 1.0f)) / dr - 1e-6f;
}

// ============================================================================
// 8. PSEUDO-KNIGHTYAN
// ============================================================================
// params[0-2]=CSize, [3]=Size, [4]=DEfactor, [5]=TwiddleRXY
//
// OPTIMISATION NOTES (vs. original):
//   A. cos/sin of constant twiddle angle hoisted out of the loop
//      — saves 2 transcendental evaluations × iterations per call.
//   B. Redundant dot(z,z) replaced with k²·r² (twiddle + rot are
//      orthogonal → preserve squared magnitude).
//   C. _Dist variant is a standalone lean body: no orbit tracking,
//      no UpdateTrapMinR2, no OrbitData writes.  This benefits every
//      distance-only call path (raymarching, shadows, normals).

FORCE_INLINE float DE_PseudoKnightyan(float3 pos, FormulaParams fp, float3x3 rot,
                                      int iterations, int colorIterations,
                                     thread OrbitData& orbit) {
    float3 csize = float3(fp.params[0], fp.params[1], fp.params[2]);
    float size   = fp.params[3];
    float deFact = fp.params[4];

    // (A) Hoist trig — twiddle is loop-invariant
    float ct = cos(fp.params[5]), st = sin(fp.params[5]);

    float3 z = pos;
    float DEfactor = 1.0f;
    float trap = 1e20f;
    int trapIter = 0;
    float3 trapPos = z;
    int i = 0;

    for (; i < iterations; ++i) {
        // Box fold
        z = clamp(z, -csize, csize) * 2.0f - z;

        // Inversion
        float r2 = dot(z, z);
        float k = max(size / r2, 1.0f);
        z *= k;
        DEfactor *= k;

        // Twiddle rotation XY (ct/st are loop-invariant)
        z.xy = float2(ct * z.x - st * z.y, st * z.x + ct * z.y);

        z = rot * z;

        // (B) Orthogonal transforms preserve magnitude: |z|² = k²·r²
        UpdateTrapMinR2(trap, trapIter, trapPos, k * k * r2, i, colorIterations, z);
    }

    orbit.trap = trap;
    orbit.trapIteration = trapIter;
    orbit.trapPosition = trapPos;
    orbit.finalP = z;
    orbit.iterationsUsed = i;

    float r = length(z);
    return deFact * (r - 0.5f) / DEfactor;
}

// (C) Lean distance-only variant — no orbit tracking overhead.
//     Used by raymarching, shadow, and normal-estimation call paths.
FORCE_INLINE float DE_PseudoKnightyan_Dist(float3 pos, FormulaParams fp, float3x3 rot, int iterations) {
    float3 csize = float3(fp.params[0], fp.params[1], fp.params[2]);
    float size   = fp.params[3];
    float deFact = fp.params[4];
    float ct = cos(fp.params[5]), st = sin(fp.params[5]);

    float3 z = pos;
    float DEfactor = 1.0f;

    for (int i = 0; i < iterations; ++i) {
        z = clamp(z, -csize, csize) * 2.0f - z;

        float r2 = dot(z, z);
        float k = max(size / r2, 1.0f);
        z *= k;
        DEfactor *= k;

        z.xy = float2(ct * z.x - st * z.y, st * z.x + ct * z.y);
        z = rot * z;
    }

    return deFact * (length(z) - 0.5f) / DEfactor;
}

// ============================================================================
// 9. MANDALAY BOX
// ============================================================================
// params[0]=Scale, [1]=MinRad2, [2]=DoBoxFold(bool), [3-5]=fo, [6-8]=g,
// [9]=Serial(bool), [10]=Julia(bool), [11-13]=JuliaC
FORCE_INLINE float DE_MandalayBox(float3 pos, FormulaParams fp, float3x3 rot,
                                  int iterations, int colorIterations,
                                 thread OrbitData& orbit) {
    float scale   = fp.params[0];
    float minR2   = fp.params[1];
    bool doBox    = fp.params[2] > 0.5f;
    float3 fo     = float3(fp.params[3], fp.params[4], fp.params[5]);
    float3 g      = float3(fp.params[6], fp.params[7], fp.params[8]);
    bool serial   = fp.params[9] > 0.5f;
    bool julia    = fp.params[10] > 0.5f;
    float3 juliaC = float3(fp.params[11], fp.params[12], fp.params[13]);

    float3 z = pos;
    float3 c = julia ? juliaC : pos;
    float dr = 1.0f;
    float trap = 1e20f;
    int trapIter = 0;
    float3 trapPos = z;
    int i = 0;

    for (; i < iterations; ++i) {
        // Optional box fold
        if (doBox) {
            z = clamp(z, -fo, fo) * 2.0f - z;
        }

        // ABS fold with offset
        z = abs(z + g) - g;

        // Sphere fold
        float r2 = dot(z, z);
        float k;
        if (serial) {
            k = max(1.0f / max(r2, minR2), 1.0f);
        } else {
            k = r2 < minR2 ? (1.0f / minR2) : (r2 < 1.0f ? (1.0f / r2) : 1.0f);
        }
        z *= k * scale;
        dr = dr * abs(k * scale) + 1.0f;

        z += c;
        z = rot * z;

        UpdateTrapMinR2(trap, trapIter, trapPos, dot(z,z), i, colorIterations, z);
    }

    orbit.trap = trap;
    orbit.trapIteration = trapIter;
    orbit.trapPosition = trapPos;
    orbit.finalP = z;
    orbit.iterationsUsed = i;

    float r = length(z);
    return (r - abs(scale - 1.0f)) / dr;
}

// Lean distance-only: no orbit tracking, no struct writes.
FORCE_INLINE float DE_MandalayBox_Dist(float3 pos, FormulaParams fp, float3x3 rot, int iterations) {
    float scale   = fp.params[0];
    float minR2   = fp.params[1];
    bool doBox    = fp.params[2] > 0.5f;
    float3 fo     = float3(fp.params[3], fp.params[4], fp.params[5]);
    float3 g      = float3(fp.params[6], fp.params[7], fp.params[8]);
    bool serial   = fp.params[9] > 0.5f;
    bool julia    = fp.params[10] > 0.5f;
    float3 juliaC = float3(fp.params[11], fp.params[12], fp.params[13]);

    float3 z = pos;
    float3 c = julia ? juliaC : pos;
    float dr = 1.0f;

    for (int i = 0; i < iterations; ++i) {
        if (doBox) {
            z = clamp(z, -fo, fo) * 2.0f - z;
        }
        z = abs(z + g) - g;

        float r2 = dot(z, z);
        float k;
        if (serial) {
            k = max(1.0f / max(r2, minR2), 1.0f);
        } else {
            k = r2 < minR2 ? (1.0f / minR2) : (r2 < 1.0f ? (1.0f / r2) : 1.0f);
        }
        z *= k * scale;
        dr = dr * abs(k * scale) + 1.0f;

        z += c;
        z = rot * z;
    }

    return (length(z) - abs(scale - 1.0f)) / dr;
}

// ============================================================================
// 10. SPHERE SPONGE
// ============================================================================
// params[0]=Scale, [1]=BubbleSize
FORCE_INLINE float DE_SphereSponge(float3 pos, FormulaParams fp, float3x3 rot,
                                   int iterations, int colorIterations,
                                  thread OrbitData& orbit) {
    float scale  = fp.params[0];
    float bubble = fp.params[1];

    float3 z = pos;
    float dr = 1.0f;
    float trap = 1e20f;
    int trapIter = 0;
    float3 trapPos = z;
    int i = 0;

    for (; i < iterations; ++i) {
        // Fold into fundamental domain
        z = abs(z);
        if (z.x < z.y) z.xy = z.yx;
        if (z.x < z.z) z.xz = z.zx;
        if (z.y < z.z) z.yz = z.zy;

        z = z * scale;
        dr = dr * scale;

        // Translate
        z -= float3(bubble, bubble, bubble) * (scale - 1.0f);

        // Sphere inversion
        float r2 = dot(z, z);
        if (r2 < 1.0f) {
            z /= r2;
            dr /= r2;
        }

        z = rot * z;

        UpdateTrapMinR2(trap, trapIter, trapPos, dot(z,z), i, colorIterations, z);
    }

    orbit.trap = trap;
    orbit.trapIteration = trapIter;
    orbit.trapPosition = trapPos;
    orbit.finalP = z;
    orbit.iterationsUsed = i;

    float r = length(z);
    return (r - 1.0f) / dr;
}

// Lean distance-only: no orbit tracking, no struct writes.
FORCE_INLINE float DE_SphereSponge_Dist(float3 pos, FormulaParams fp, float3x3 rot, int iterations) {
    float scale  = fp.params[0];
    float bubble = fp.params[1];
    float3 bubbleOffset = float3(bubble) * (scale - 1.0f);

    float3 z = pos;
    float dr = 1.0f;

    for (int i = 0; i < iterations; ++i) {
        z = abs(z);
        if (z.x < z.y) z.xy = z.yx;
        if (z.x < z.z) z.xz = z.zx;
        if (z.y < z.z) z.yz = z.zy;

        z = z * scale - bubbleOffset;
        dr = dr * scale;

        float r2 = dot(z, z);
        if (r2 < 1.0f) {
            z /= r2;
            dr /= r2;
        }

        z = rot * z;
    }

    return (length(z) - 1.0f) / dr;
}

// ============================================================================
// 11. OCTAHEDRON IFS
// ============================================================================
// params[0]=Scale, [1-3]=Offset
FORCE_INLINE float DE_Octahedron(float3 pos, FormulaParams fp, float3x3 rot,
                                 int iterations, int colorIterations,
                                thread OrbitData& orbit) {
    float scale  = fp.params[0];
    float3 offset = float3(fp.params[1], fp.params[2], fp.params[3]);

    float3 z = pos;
    float dr = 1.0f;
    float trap = 1e20f;
    int trapIter = 0;
    float3 trapPos = z;
    int i = 0;

    for (; i < iterations; ++i) {
        // Octahedral folds (abs + sort = octahedral symmetry)
        z = abs(z);
        if (z.x - z.y < 0.0f) z.xy = z.yx;
        if (z.x - z.z < 0.0f) z.xz = z.zx;
        if (z.y - z.z < 0.0f) z.yz = z.zy;

        z = z * scale - offset * (scale - 1.0f);
        z = rot * z;
        dr = dr * scale + 1.0f;

        float r2 = dot(z, z);
        UpdateTrapMinR2(trap, trapIter, trapPos, r2, i, colorIterations, z);
    }

    orbit.trap = trap;
    orbit.trapIteration = trapIter;
    orbit.trapPosition = trapPos;
    orbit.finalP = z;
    orbit.iterationsUsed = i;

    float r = length(z);
    return (r - 1.0f) / dr;
}

// Lean distance-only: no orbit tracking, no struct writes.
FORCE_INLINE float DE_Octahedron_Dist(float3 pos, FormulaParams fp, float3x3 rot, int iterations) {
    float scale  = fp.params[0];
    float3 offset = float3(fp.params[1], fp.params[2], fp.params[3]);
    float3 offsetScaled = offset * (scale - 1.0f);

    float3 z = pos;
    float dr = 1.0f;

    for (int i = 0; i < iterations; ++i) {
        z = abs(z);
        if (z.x - z.y < 0.0f) z.xy = z.yx;
        if (z.x - z.z < 0.0f) z.xz = z.zx;
        if (z.y - z.z < 0.0f) z.yz = z.zy;

        z = z * scale - offsetScaled;
        z = rot * z;
        dr = dr * scale + 1.0f;
    }

    return (length(z) - 1.0f) / dr;
}

// ============================================================================
// 12. ICOSAHEDRON IFS
// ============================================================================
// params[0]=Scale, [1]=Phi, [2-4]=Offset
FORCE_INLINE float DE_Icosahedron(float3 pos, FormulaParams fp, float3x3 rot,
                                  int iterations, int colorIterations,
                                 thread OrbitData& orbit) {
    float scale  = fp.params[0];
    float phi    = fp.params[1];
    float3 offset = float3(fp.params[2], fp.params[3], fp.params[4]);

    // Five-fold symmetry planes using golden ratio
    float3 n1 = normalize(float3(-1.0f, phi, 1.0f/phi));
    float3 n2 = normalize(float3(1.0f/phi, -1.0f, phi));
    float3 n3 = normalize(float3(phi, 1.0f/phi, -1.0f));
    float3 n4 = normalize(float3(-1.0f, -phi, 1.0f/phi));
    float3 n5 = normalize(float3(1.0f/phi, 1.0f, phi));

    float3 z = pos;
    float dr = 1.0f;
    float trap = 1e20f;
    int trapIter = 0;
    float3 trapPos = z;
    int i = 0;

    for (; i < iterations; ++i) {
        // Five mirror folds for icosahedral symmetry
        z -= 2.0f * min(0.0f, dot(z, n1)) * n1;
        z -= 2.0f * min(0.0f, dot(z, n2)) * n2;
        z -= 2.0f * min(0.0f, dot(z, n3)) * n3;
        z -= 2.0f * min(0.0f, dot(z, n4)) * n4;
        z -= 2.0f * min(0.0f, dot(z, n5)) * n5;

        z = z * scale - offset * (scale - 1.0f);
        z = rot * z;
        dr = dr * abs(scale) + 1.0f;

        float r2 = dot(z, z);
        UpdateTrapMinR2(trap, trapIter, trapPos, r2, i, colorIterations, z);
    }

    orbit.trap = trap;
    orbit.trapIteration = trapIter;
    orbit.trapPosition = trapPos;
    orbit.finalP = z;
    orbit.iterationsUsed = i;

    float r = length(z);
    return (r - 1.0f) / dr;
}

// Lean distance-only: no orbit tracking, no struct writes.
FORCE_INLINE float DE_Icosahedron_Dist(float3 pos, FormulaParams fp, float3x3 rot, int iterations) {
    float scale  = fp.params[0];
    float phi    = fp.params[1];
    float3 offset = float3(fp.params[2], fp.params[3], fp.params[4]);
    float3 offsetScaled = offset * (scale - 1.0f);

    float3 n1 = normalize(float3(-1.0f, phi, 1.0f/phi));
    float3 n2 = normalize(float3(1.0f/phi, -1.0f, phi));
    float3 n3 = normalize(float3(phi, 1.0f/phi, -1.0f));
    float3 n4 = normalize(float3(-1.0f, -phi, 1.0f/phi));
    float3 n5 = normalize(float3(1.0f/phi, 1.0f, phi));

    float3 z = pos;
    float dr = 1.0f;

    for (int i = 0; i < iterations; ++i) {
        z -= 2.0f * min(0.0f, dot(z, n1)) * n1;
        z -= 2.0f * min(0.0f, dot(z, n2)) * n2;
        z -= 2.0f * min(0.0f, dot(z, n3)) * n3;
        z -= 2.0f * min(0.0f, dot(z, n4)) * n4;
        z -= 2.0f * min(0.0f, dot(z, n5)) * n5;

        z = z * scale - offsetScaled;
        z = rot * z;
        dr = dr * abs(scale) + 1.0f;
    }

    return (length(z) - 1.0f) / dr;
}

// ============================================================================
// 13. SURFACE KIFS
// ============================================================================
// params[0]=Scale, [1-3]=Fold, [4-6]=Julia, [7-9]=RotVector, [10]=RotAngle
// Note: RotVector/RotAngle are consumed on Swift side to build rotMatrix1
FORCE_INLINE float DE_SurfaceKIFS(float3 pos, FormulaParams fp, float3x3 rot,
                                  int iterations, int colorIterations,
                                 thread OrbitData& orbit) {
    float scale  = fp.params[0];
    float3 fold  = float3(fp.params[1], fp.params[2], fp.params[3]);
    float3 julia = float3(fp.params[4], fp.params[5], fp.params[6]);

    float3 z = pos;
    float dr = 1.0f;
    float trap = 1e20f;
    int trapIter = 0;
    float3 trapPos = z;
    int i = 0;

    for (; i < iterations; ++i) {
        // Abs folds + custom fold offsets
        z = abs(z) - fold;

        // Sort-based fold (surface symmetry)
        if (z.x < z.y) z.xy = z.yx;
        if (z.x < z.z) z.xz = z.zx;
        if (z.y < z.z) z.yz = z.zy;

        // Apply rotation
        z = rot * z;

        z = z * scale + julia;
        dr = dr * abs(scale) + 1.0f;

        float r2 = dot(z, z);
        UpdateTrapMinR2(trap, trapIter, trapPos, r2, i, colorIterations, z);
    }

    orbit.trap = trap;
    orbit.trapIteration = trapIter;
    orbit.trapPosition = trapPos;
    orbit.finalP = z;
    orbit.iterationsUsed = i;

    float r = length(z);
    return (r - 1.0f) / dr;
}

// Lean distance-only: no orbit tracking, no struct writes.
FORCE_INLINE float DE_SurfaceKIFS_Dist(float3 pos, FormulaParams fp, float3x3 rot, int iterations) {
    float scale  = fp.params[0];
    float3 fold  = float3(fp.params[1], fp.params[2], fp.params[3]);
    float3 julia = float3(fp.params[4], fp.params[5], fp.params[6]);

    float3 z = pos;
    float dr = 1.0f;

    for (int i = 0; i < iterations; ++i) {
        z = abs(z) - fold;

        if (z.x < z.y) z.xy = z.yx;
        if (z.x < z.z) z.xz = z.zx;
        if (z.y < z.z) z.yz = z.zy;

        z = rot * z;
        z = z * scale + julia;
        dr = dr * abs(scale) + 1.0f;
    }

    return (length(z) - 1.0f) / dr;
}

// ============================================================================
// 14. MENGER SPHERE
// ============================================================================
// params[0]=Scale, [1-3]=Offset, [4]=Spherify(bool)
FORCE_INLINE float DE_MengerSphere(float3 pos, FormulaParams fp, float3x3 rot,
                                   int iterations, int colorIterations,
                                  thread OrbitData& orbit) {
    float scale  = fp.params[0];
    float3 offset = float3(fp.params[1], fp.params[2], fp.params[3]);
    bool spherify = fp.params[4] > 0.5f;

    float3 z = pos;
    float dr = 1.0f;
    float trap = 1e20f;
    int trapIter = 0;
    float3 trapPos = z;
    int i = 0;

    for (; i < iterations; ++i) {
        z = abs(z);
        if (z.x < z.y) z.xy = z.yx;
        if (z.x < z.z) z.xz = z.zx;
        if (z.y < z.z) z.yz = z.zy;

        z = z * scale - offset * (scale - 1.0f);
        if (z.z < -0.5f * offset.z * (scale - 1.0f))
            z.z += offset.z * (scale - 1.0f);

        // Optional sphere mapping
        if (spherify) {
            float r2 = dot(z, z);
            if (r2 < 1.0f) {
                z /= r2;
                dr /= r2;
            }
        }

        z = rot * z;
        dr = dr * abs(scale) + 1.0f;

        float r2 = dot(z, z);
        UpdateTrapMinR2(trap, trapIter, trapPos, r2, i, colorIterations, z);
    }

    orbit.trap = trap;
    orbit.trapIteration = trapIter;
    orbit.trapPosition = trapPos;
    orbit.finalP = z;
    orbit.iterationsUsed = i;

    float r = length(z);
    return (r - 1.0f) / dr;
}

// Lean distance-only: no orbit tracking, no struct writes.
FORCE_INLINE float DE_MengerSphere_Dist(float3 pos, FormulaParams fp, float3x3 rot, int iterations) {
    float scale  = fp.params[0];
    float3 offset = float3(fp.params[1], fp.params[2], fp.params[3]);
    bool spherify = fp.params[4] > 0.5f;
    float3 offsetScaled = offset * (scale - 1.0f);
    float halfOffsetZn = -0.5f * offsetScaled.z;

    float3 z = pos;
    float dr = 1.0f;

    for (int i = 0; i < iterations; ++i) {
        z = abs(z);
        if (z.x < z.y) z.xy = z.yx;
        if (z.x < z.z) z.xz = z.zx;
        if (z.y < z.z) z.yz = z.zy;

        z = z * scale - offsetScaled;
        if (z.z < halfOffsetZn)
            z.z += offsetScaled.z;

        if (spherify) {
            float r2 = dot(z, z);
            if (r2 < 1.0f) {
                z /= r2;
                dr /= r2;
            }
        }

        z = rot * z;
        dr = dr * abs(scale) + 1.0f;
    }

    return (length(z) - 1.0f) / dr;
}

// ============================================================================
// DISPATCH — distance only
// ============================================================================
FORCE_INLINE float FractalDE_Dispatch(float3 pos, int fractalType, FormulaParams fp, int iterations) {
    switch (fractalType) {
        case FractalTypeMandelbulb:
            return DE_Mandelbulb_Dist(pos, fp, fp.rotMatrix1, iterations);
        case FractalTypeMenger:
            return DE_Menger_Dist(pos, fp, fp.rotMatrix1, iterations);
        case FractalTypeSierpinski:
            return DE_Sierpinski_Dist(pos, fp, fp.rotMatrix1, iterations);
        case FractalTypeDodecahedron:
            return DE_Dodecahedron_Dist(pos, fp, fp.rotMatrix1, iterations);
        case FractalTypePseudoKleinian:
            return DE_PseudoKleinian_Dist(pos, fp, fp.rotMatrix1, iterations);
        case FractalTypeQuaternionJulia:
            return DE_QuaternionJulia_Dist(pos, fp, fp.rotMatrix1, iterations);
        case FractalTypeAmazingSurface:
            return DE_AmazingSurface_Dist(pos, fp, fp.rotMatrix1, iterations);
        case FractalTypePseudoKnightyan:
            return DE_PseudoKnightyan_Dist(pos, fp, fp.rotMatrix1, iterations);
        case FractalTypeMandalayBox:
            return DE_MandalayBox_Dist(pos, fp, fp.rotMatrix1, iterations);
        case FractalTypeSphereSponge:
            return DE_SphereSponge_Dist(pos, fp, fp.rotMatrix1, iterations);
        case FractalTypeOctahedron:
            return DE_Octahedron_Dist(pos, fp, fp.rotMatrix1, iterations);
        case FractalTypeIcosahedron:
            return DE_Icosahedron_Dist(pos, fp, fp.rotMatrix1, iterations);
        case FractalTypeSurfaceKIFS:
            return DE_SurfaceKIFS_Dist(pos, fp, fp.rotMatrix1, iterations);
        case FractalTypeMengerSphere:
            return DE_MengerSphere_Dist(pos, fp, fp.rotMatrix1, iterations);
        default:
            return 1e10f; // Unknown type — far away
    }
}

// ============================================================================
// DISPATCH — with orbit tracking
// ============================================================================
FORCE_INLINE float FractalDE_WithOrbit(float3 pos, int fractalType, FormulaParams fp,
                                       int iterations, int colorIterations,
                                      thread OrbitData& orbit) {
    switch (fractalType) {
        case FractalTypeMandelbulb:
            return DE_Mandelbulb(pos, fp, fp.rotMatrix1, iterations, colorIterations, orbit);
        case FractalTypeMenger:
            return DE_Menger(pos, fp, fp.rotMatrix1, iterations, colorIterations, orbit);
        case FractalTypeSierpinski:
            return DE_Sierpinski(pos, fp, fp.rotMatrix1, iterations, colorIterations, orbit);
        case FractalTypeDodecahedron:
            return DE_Dodecahedron(pos, fp, fp.rotMatrix1, iterations, colorIterations, orbit);
        case FractalTypePseudoKleinian:
            return DE_PseudoKleinian(pos, fp, fp.rotMatrix1, iterations, colorIterations, orbit);
        case FractalTypeQuaternionJulia:
            return DE_QuaternionJulia(pos, fp, fp.rotMatrix1, iterations, colorIterations, orbit);
        case FractalTypeAmazingSurface:
            return DE_AmazingSurface(pos, fp, fp.rotMatrix1, iterations, colorIterations, orbit);
        case FractalTypePseudoKnightyan:
            return DE_PseudoKnightyan(pos, fp, fp.rotMatrix1, iterations, colorIterations, orbit);
        case FractalTypeMandalayBox:
            return DE_MandalayBox(pos, fp, fp.rotMatrix1, iterations, colorIterations, orbit);
        case FractalTypeSphereSponge:
            return DE_SphereSponge(pos, fp, fp.rotMatrix1, iterations, colorIterations, orbit);
        case FractalTypeOctahedron:
            return DE_Octahedron(pos, fp, fp.rotMatrix1, iterations, colorIterations, orbit);
        case FractalTypeIcosahedron:
            return DE_Icosahedron(pos, fp, fp.rotMatrix1, iterations, colorIterations, orbit);
        case FractalTypeSurfaceKIFS:
            return DE_SurfaceKIFS(pos, fp, fp.rotMatrix1, iterations, colorIterations, orbit);
        case FractalTypeMengerSphere:
            return DE_MengerSphere(pos, fp, fp.rotMatrix1, iterations, colorIterations, orbit);
        default:
            orbit.trap = 1e20f;
            orbit.trapIteration = 0;
            orbit.trapPosition = pos;
            orbit.finalP = pos;
            orbit.iterationsUsed = 0;
            return 1e10f;
    }
}

#endif /* FractalFormulas_h */
