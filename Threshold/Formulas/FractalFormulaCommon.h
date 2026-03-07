//
//  FractalFormulaCommon.h
//  Threshold
//
//  Shared constants, helpers, and types used by all fractal distance estimator
//  formula headers.  Included once by FractalFormulas.h before any individual
//  formula file.
//
//  Requires: metal_stdlib, ShaderTypes.h (FormulaParams, FractalType enum),
//            FORCE_INLINE macro (defined in Shaders.metal)
//

#ifndef FractalFormulaCommon_h
#define FractalFormulaCommon_h

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------
constant float kEpsLen   = 1e-16f;
constant float kEpsAcos  = 1e-8f;
constant float kLn2      = 0.6931471805599453f;
constant float kLog2_10  = 3.32192809488736234787f; // fast::log2(10)

inline bool hasRot1Precomputed(FormulaParams fp) {
    return (fp.rotationFlags & FormulaRotationFlagRot1NonIdentity) != 0u;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
inline float3x3 rotationMatrix3(float3 v, float angleDeg) {
    float angle = angleDeg * M_PI_F / 180.0f;
    float c = fast::cos(angle), s = fast::sin(angle);
    float t = 1.0f - c;
    v = fast::normalize(v);
    return float3x3(
        float3(t*v.x*v.x + c,      t*v.x*v.y - s*v.z,  t*v.x*v.z + s*v.y),
        float3(t*v.x*v.y + s*v.z,  t*v.y*v.y + c,      t*v.y*v.z - s*v.x),
        float3(t*v.x*v.z - s*v.y,  t*v.y*v.z + s*v.x,  t*v.z*v.z + c)
    );
}

inline float clamp11(float x) { return clamp(x, -1.0f, 1.0f); }

inline bool isIdentityRotation3(float3x3 m) {
    // Fast path: most presets keep formula rotations exactly identity.
    if (m[0].x == 1.0f && m[0].y == 0.0f && m[0].z == 0.0f &&
        m[1].x == 0.0f && m[1].y == 1.0f && m[1].z == 0.0f &&
        m[2].x == 0.0f && m[2].y == 0.0f && m[2].z == 1.0f) {
        return true;
    }

    const float eps = 1e-6f;
    return all(abs(m[0] - float3(1.0f, 0.0f, 0.0f)) <= eps) &&
           all(abs(m[1] - float3(0.0f, 1.0f, 0.0f)) <= eps) &&
           all(abs(m[2] - float3(0.0f, 0.0f, 1.0f)) <= eps);
}

// Fast r^power for compile-time-known integer powers (Mandelbulb hot path).
// Integer cases use repeated squaring (1-4 muls) vs ~30-cycle exp2*log2 pair.
FORCE_INLINE float fastPowR(float r, float power) {
    if (power == 2.0f)  { return r * r; }
    if (power == 3.0f)  { return r * r * r; }
    if (power == 4.0f)  { float r2 = r * r; return r2 * r2; }
    if (power == 5.0f)  { float r2 = r * r; return r2 * r2 * r; }
    if (power == 6.0f)  { float r2 = r * r; return r2 * r2 * r2; }
    if (power == 8.0f)  { float r2 = r * r; float r4 = r2 * r2; return r4 * r4; }
    if (power == 10.0f) { float r2 = r * r; float r4 = r2 * r2; return r4 * r4 * r2; }
    if (power == 12.0f) { float r2 = r * r; float r4 = r2 * r2; return r4 * r4 * r4; }
    if (power == 16.0f) { float r2 = r * r; float r4 = r2 * r2; float r8 = r4 * r4; return r8 * r8; }
    // Fallback for fractional / unusual powers
    return powr(max(r, 1e-10f), power);
}

// Safe power: pow(a, b) for a >= 0
inline float safePow(float a, float b) {
    return fast::exp2(b * fast::log2(max(a, 1e-30f)));
}
// Signed power: sign(s) * |s|^e
inline float signedPow(float s, float e) {
    return sign(s) * fast::exp2(e * fast::log2(max(abs(s), 1e-30f)));
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

#endif /* FractalFormulaCommon_h */
