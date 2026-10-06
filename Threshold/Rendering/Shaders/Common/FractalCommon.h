struct FractalParams {
    float4 scale;
    float absScalem1;
    float absScalePow;
    float sphereRadiusSq;   // Squared sphere radius for sphere fold
    float3 bubbleCenter;
    float bubbleRadius;
    int bubbleEnabled;
    float bubbleShape;      // 0 = sphere, 1 = cube, intermediate = morph
    int bubbleFadeEnabled;  // Enable smooth fade transition
    float bubbleFadeWidth;  // Width of fade region beyond inner radius
    float bubbleStrength;   // Temporal fade (0=off, 1=fully active)
    float sphereProjBlend;  // 0 = off; >0 blends post-fold radial sphere projection (Mandelbox path)
    float sphereProjRadius; // Target radius for the post-fold sphere projection
    float spaceWarpStrength; // 0 = off; drives the custom space warp (built-in Twist or a loaded .threshfx warp)
    float spaceWarpParam1;   // generic warp params (meaning defined by the active warp); built-in Twist uses them as the origin point
    float spaceWarpParam2;
    float spaceWarpParam3;
    float3 spaceWarpAxis;    // built-in Twist rotation axis (orientation); normalized on use — used by the .threshfx custom-warp path only
    // Composable domain-transform stack (Transformations UI). The op array lives
    // ONCE in the constant Uniforms buffer; FractalParams carries only a constant
    // pointer to it + the active count, so the (per-step, by-value) FractalParams
    // stays small — the 8-op array never inflates the march's register footprint.
    // `spaceWarpOps` is dereferenced only when spaceWarpCount > 0 (so a null/garbage
    // pointer with count 0 is safe). count == 0 = stack off → identity.
    constant SpaceWarpOp* spaceWarpOps;
    int spaceWarpCount;
    // Environment Scrunch (scanned-room proximity field): params live ONCE in
    // the constant Uniforms buffer (pointer, like spaceWarpOps); the distance
    // grid is a separate buffer reached bindlessly via its GPU address. Both
    // null/disabled ⇒ identity. Dereferenced only behind the enabled guard.
    constant EnvScrunchParams* envScrunch;
    device const half* envGrid;
    // Hand Attraction (visionOS): per-hand interaction sphere + forearm
    // capsules. The block lives ONCE in the constant Uniforms buffer
    // (uniforms.handField); FractalParams carries only this pointer — the
    // flat copy was 168 B of by-value hot-path state (TECH_DEBT.md #8d).
    // nullptr or enabled == 0 ⇒ identity; dereferenced only behind that guard.
    constant HandFieldParams* handField;
};

// Size gate (TECH_DEBT.md #8d): FractalParams travels BY VALUE through the DE
// hot path, so growth directly inflates the march loop's register footprint —
// an embedded array once pushed it to 272 B and collapsed occupancy, and the
// 2026-07 hand/forearm flat fields pushed it to 320 B before moving behind
// `handField` (harness-verified byte-identical). Currently 160 B: DE scalars
// plus POINTERS for the space-warp stack, Environment Scrunch, and the hand
// field (their data lives once in constant/device memory — the indirection
// this rule demands). Do NOT bump this bound without a before/after harness
// measurement (PERF_PUSH.md protocol); prefer packing or pointer indirection.
static_assert(sizeof(FractalParams) <= 160,
              "FractalParams (by-value, hot path) grew — measure occupancy impact before raising this bound (TECH_DEBT.md #8d)");

// ── Per-type domain transforms ──────────────────────────────────────────────
// One function per warp kind so a generated (codegen) stack can call them
// directly — no runtime switch. Each handles strength internally (identity at
// strength 0). type/param semantics:
//   0 Twist · 1 Bend · 2 Mirror Fold · 3 Box Fold · 4 Sphere Fold
//   5 Spherical Inversion · 6 Kaleidoscope · 7 Ripple
FORCE_INLINE float3 warpAxisNorm(SpaceWarpOp op) {
    // Axis is pre-normalized on the CPU (cSpaceWarpStack), so this is a plain load.
    return float3(op.axisX, op.axisY, op.axisZ);
}
FORCE_INLINE float3 warpTwist(float3 p, SpaceWarpOp op) {       // 0
    float strength = op.strength; if (strength <= 0.0f) return p;
    float3 axis = warpAxisNorm(op);
    float angle = strength * dot(p, axis) * 1.5f;
    float c; float s = sincos(angle, c);   // one transcendental for both
    return p * c + cross(axis, p) * s + axis * dot(axis, p) * (1.0f - c);
}
// Max singular value of the twist Jacobian (exact). A twist by θ = k·(p·axis)
// is a shear-rotation: in the (r̂, φ̂, ẑ) frame JᵀJ = [[1,0,0],[0,ρ²,kρ²],[0,kρ²,1+k²ρ²]]
// with ρ = lever arm off the axis, k = 1.5·s, so
//   σmax = sqrt((2 + x² + x·sqrt(x² + 4)) / 2),  x = k·ρ.
// Returning 1.0 (the old "pure rotation" claim — true only ON the axis)
// under-divided the march by up to ~3× at r ≈ 2 → sliced/holed surfaces
// off-axis at the default strength.
FORCE_INLINE float warpTwistDEScale(float3 p, SpaceWarpOp op) {
    if (op.strength <= 0.0f) return 1.0f;
    float3 axis = warpAxisNorm(op);
    float lever = length(p - axis * dot(p, axis));
    float x = 1.5f * op.strength * lever;
    float x2 = x * x;
    return max(sqrt(0.5f * (2.0f + x2 + x * sqrt(x2 + 4.0f))), 1.0f);
}
FORCE_INLINE float3 warpBend(float3 p, SpaceWarpOp op) {        // 1
    float strength = op.strength; if (strength <= 0.0f) return p;
    float3 axis = warpAxisNorm(op);
    float along = dot(p, axis);
    float3 perp = p - along * axis;
    float angle = strength * length(perp) * 1.5f;
    float c; float s = sincos(angle, c);   // one transcendental for both
    float3 perpDir = (length(perp) > 1e-6f) ? normalize(perp) : float3(0.0f);
    return perp + axis * (along * c) + perpDir * (along * s);
}
// Max singular value of the bend Jacobian (exact). With a = along-axis
// coordinate, ρ = |perp|, k = 1.5·s, θ = k·ρ and x = a·k, the Jacobian in the
// local orthonormal frame (axis, e_φ, ψ) is block-diagonal:
//   A = [[cosθ, −x·sinθ], [sinθ, 1 + x·cosθ]] (axial/bend plane)
//   tangential stretch = |1 + x·sinc(θ)| (sinc = sin θ / θ, → x·0/0 = x at ρ→0)
// σmax = max(σ(A), |1 + x·sinc θ|). The old 1.0 under-divided the march the
// same way twist did.
FORCE_INLINE float warpBendDEScale(float3 p, SpaceWarpOp op) {
    if (op.strength <= 0.0f) return 1.0f;
    float3 axis = warpAxisNorm(op);
    float along = dot(p, axis);
    float perp = length(p - along * axis);
    float k = 1.5f * op.strength;
    float theta = k * perp;
    float c; float s = sincos(theta, c);   // matches warpBend's angle
    float x = along * k;
    // 2×2 block σmax: sqrt((T + sqrt(T² − 4·det²)) / 2)
    float trace = 2.0f + 2.0f * x * c + x * x;
    float det = c + x;
    float disc = max(trace * trace - 4.0f * det * det, 0.0f);
    float sigmaPlane = sqrt(0.5f * (trace + sqrt(disc)));
    // Tangential stretch: sin(θ)/θ → 1 as θ→0 (guard θ→0).
    float sinc = (theta > 1e-6f) ? (s / theta) : 1.0f;
    float sigmaTangent = abs(1.0f + x * sinc);
    return max(max(sigmaPlane, sigmaTangent), 1.0f);
}
FORCE_INLINE float3 warpMirror(float3 p, SpaceWarpOp op) {      // 2
    return mix(p, abs(p), clamp(op.strength, 0.0f, 1.0f));
}
// Hall-of-Mirrors per-axis fold: the CLASSIC two-parallel-mirrors tiling — space
// repeats into infinite IDENTICAL mirrored copies, each cell 2L wide. It's a triangle
// wave of period 4L: identity on [−L, L], and every neighbouring cell a same-size
// mirror image of the last (continuous at every wall). Slope is ±1 everywhere, so the
// fold is ISOMETRIC (no DE divisor needed).
FORCE_INLINE float hallMirrorAxis(float c, float L) {
    float period = 4.0f * L;
    float u = c + L;
    float m = u - period * floor(u / period);   // positive mod → [0, 4L)
    return L - fabs(m - 2.0f * L);
}
FORCE_INLINE float3 warpBoxFold(float3 p, SpaceWarpOp op) {     // 3
    float t = clamp(op.strength, 0.0f, 1.0f);
    float L = op.p1;   // precomputed max(L, 0.01)
    float3 folded;
    if (op.p2 > 0.5f) {
        // Hall of Mirrors: infinite identical mirrored copies, cells 2L wide.
        folded = float3(hallMirrorAxis(p.x, L), hallMirrorAxis(p.y, L), hallMirrorAxis(p.z, L));
    } else {
        folded = clamp(p, -L, L) * 2.0f - p;            // single Tglad box fold
    }
    return mix(p, folded, t);   // both branches are isometric → no DE divisor (default arm = 1)
}
FORCE_INLINE float3 warpSphereFold(float3 p, SpaceWarpOp op) {  // 4
    float t = clamp(op.strength, 0.0f, 1.0f);
    float r2 = dot(p, p);
    float minR2 = op.p1, maxR2 = op.p2;   // precomputed minR², maxR²
    float factor = 1.0f;
    if (r2 < minR2)      factor = maxR2 / minR2;
    else if (r2 < maxR2) factor = maxR2 / max(r2, 1e-6f);
    return mix(p, p * factor, t);
}
FORCE_INLINE float warpSphereFoldDEScale(float3 p, SpaceWarpOp op) {
    if (op.strength <= 0.0f) return 1.0f;
    float t = clamp(op.strength, 0.0f, 1.0f);
    float r2 = dot(p, p);
    float minR2 = op.p1, maxR2 = op.p2;   // precomputed minR², maxR²
    float factor = 1.0f;
    if (r2 < minR2)      factor = maxR2 / minR2;
    else if (r2 < maxR2) factor = maxR2 / max(r2, 1e-6f);
    return max(mix(1.0f, factor, t), 1e-3f);
}
FORCE_INLINE float3 warpInversion(float3 p, SpaceWarpOp op) {   // 5
    float t = clamp(op.strength, 0.0f, 1.0f);
    float r2 = max(dot(p, p), 1e-6f);
    float factor = clamp(op.p1 / r2, 0.05f, 20.0f);   // op.p1 = precomputed R²
    return mix(p, p * factor, t);
}
FORCE_INLINE float warpInversionDEScale(float3 p, SpaceWarpOp op) {
    if (op.strength <= 0.0f) return 1.0f;
    float t = clamp(op.strength, 0.0f, 1.0f);
    float r2 = max(dot(p, p), 1e-6f);
    float factor = clamp(op.p1 / r2, 0.05f, 20.0f);   // op.p1 = precomputed R²
    return max(mix(1.0f, factor, t), 1e-3f);
}
FORCE_INLINE float3 warpKaleido(float3 p, SpaceWarpOp op) {     // 6
    float t = clamp(op.strength, 0.0f, 1.0f);
    float seg = op.p1;   // precomputed π / max(round(segments), 2)
    float ang = atan2(p.z, p.x);
    float len = length(p.xz);
    float a = fmod(fabs(ang) + seg, 2.0f * seg) - seg;
    float ca; float sa = sincos(a, ca);   // one transcendental for both
    return mix(p, float3(ca * len, p.y, sa * len), t);
}
FORCE_INLINE float3 warpRipple(float3 p, SpaceWarpOp op) {      // 7
    float strength = op.strength; if (strength <= 0.0f) return p;
    float3 axis = warpAxisNorm(op);
    float freq = op.p1;   // precomputed max(freq, 0.01)
    return p + axis * (strength * sin(dot(p, axis) * freq));
}

// ── Radial / nested / self-similar family ───────────────────────────────────
// These operate on a LOWER-dimensional reduction of the point (its radius), so the
// "understanding" they carry is purely geometric: where the point sits in a circle,
// a shell, or a self-similar octave. p1/p2 are radii / spacing / scale-factor.
FORCE_INLINE float3 warpCircle(float3 p, SpaceWarpOp op) {      // 8 — sphere fold confined to XZ
    float t = clamp(op.strength, 0.0f, 1.0f);
    float2 xz = float2(p.x, p.z);
    float r2 = dot(xz, xz);
    float minR2 = op.p1, maxR2 = op.p2;   // precomputed minR², maxR²
    float factor = 1.0f;
    if (r2 < minR2)      factor = maxR2 / minR2;
    else if (r2 < maxR2) factor = maxR2 / max(r2, 1e-6f);
    return mix(p, float3(xz.x * factor, p.y, xz.y * factor), t);
}
FORCE_INLINE float warpCircleDEScale(float3 p, SpaceWarpOp op) {
    if (op.strength <= 0.0f) return 1.0f;
    float t = clamp(op.strength, 0.0f, 1.0f);
    float2 xz = float2(p.x, p.z);
    float r2 = dot(xz, xz);
    float minR2 = op.p1, maxR2 = op.p2;   // precomputed minR², maxR²
    float factor = 1.0f;
    if (r2 < minR2)      factor = maxR2 / minR2;
    else if (r2 < maxR2) factor = maxR2 / max(r2, 1e-6f);
    return max(mix(1.0f, factor, t), 1e-3f);
}
FORCE_INLINE float3 warpShells(float3 p, SpaceWarpOp op) {      // 9 — concentric radial repetition
    float t = clamp(op.strength, 0.0f, 1.0f);
    float d = op.p1;   // precomputed max(spacing, 0.1)
    float r = length(p);
    if (r < 1e-5f) return p;
    // Fold the radius to the nearest shell: a radial sawtooth in [0, d/2]. The
    // radial derivative is ±1 and the tangential factor is ≤1, so this is an
    // isometric fold (deScale = 1, handled by the default warpOpDEScale arm).
    float rNew = fabs(r - d * round(r / d));
    return mix(p, p * (rNew / r), t);
}
// Compact positive/negative radial regions at proportional sizes:
//   1 − 1/√2, φ⁻², φ⁻¹, and 1.
// Each region has a flat core with a smooth finite shoulder; unlike a sine
// ripple, space between shells is exactly untouched. Region half-width scales
// with its center, preserving the same shape across sizes. At the CPU-clamped
// width ≤ 0.12 the regions do not overlap. smoothstep across the outer half has
// maximum normalized slope 3, so the 1/3 displacement scale bounds radial and
// tangential stretch by 1 + strength.
FORCE_INLINE float3 warpCompressionShells(float3 p, SpaceWarpOp op) { // 19
    float strength = op.strength; if (strength <= 0.0f) return p;
    float r = length(p);
    if (r < 1e-5f) return p;

    constexpr float4 scales = float4(
        0.29289321881f,  // 1 − 1/√2
        0.38196601125f,  // φ⁻²
        0.61803398875f,  // φ⁻¹ — consecutive Fibonacci ratios converge here
        1.0f
    );
    constexpr float4 signs = float4(1.0f, -1.0f, 1.0f, -1.0f);
    float4 centers = op.p1 * scales;
    float4 halfWidths = op.p2 * centers;
    float4 x = abs(float4(r) - centers) / halfWidths;
    float4 regions = float4(1.0f) - smoothstep(float4(0.5f), float4(1.0f), x);
    float displacement = strength * dot(signs, halfWidths * regions) / 3.0f;
    float rNew = max(r + displacement, 1e-5f);
    return p * (rNew / r);
}
FORCE_INLINE float warpCompressionShellsDEScale(float3 p, SpaceWarpOp op) {
    (void)p;
    return op.strength > 0.0f ? 1.0f + op.strength : 1.0f;
}
FORCE_INLINE float3 warpScaleRepeat(float3 p, SpaceWarpOp op) { // 10 — log-radial Droste (growing scales)
    float t = clamp(op.strength, 0.0f, 1.0f);
    float logS = op.p1;   // precomputed log(max(scale, 1.1))
    float r = length(p);
    if (r < 1e-5f) return p;
    float octave = floor(log(r) / logS);
    float scale = exp(-octave * logS);   // map r into the base octave [1, s) (uniform scale within an octave)
    return mix(p, p * scale, t);
}
FORCE_INLINE float warpScaleRepeatDEScale(float3 p, SpaceWarpOp op) {
    if (op.strength <= 0.0f) return 1.0f;
    float t = clamp(op.strength, 0.0f, 1.0f);
    float logS = op.p1;   // precomputed log(max(scale, 1.1))
    float r = max(length(p), 1e-5f);
    float octave = floor(log(r) / logS);
    float scale = exp(-octave * logS);   // within an octave the map is a uniform scale → Lipschitz = scale
    return max(mix(1.0f, scale, t), 1e-3f);
}

// ── Reflection group (Coxeter) ──────────────────────────────────────────────
FORCE_INLINE float3 warpCoxeter(float3 p, SpaceWarpOp op) {    // 11 — [p,q] mirror group fold
    float t = clamp(op.strength, 0.0f, 1.0f);
    if (t <= 0.0f) return p;
    // Mirror normals precomputed on the CPU (cSpaceWarpStack): n0 fixed, n1/n2
    // packed. axisZ remains available as the user-authored vertical orientation.
    const float3 n0 = float3(1.0f, 0.0f, 0.0f);
    float3 n1 = float3(op.p1, op.p2, 0.0f);     // (−cos π/p, sin π/p, 0)
    float3 n2 = float3(0.0f, op.axisX, op.axisY);  // (0, −cos(π/q)/sin(π/p), √…)

    // Move the sample into the mirror arrangement's local orientation. Keep the
    // zero-angle path free of trigonometry for legacy Coxeter scenes and the fixed
    // Icosahedral Space Cut, whose packed angle is always zero.
    float sourceAngle = op.axisZ;
    float c = 1.0f;
    float s = 0.0f;
    float3 localP = p;
    if (fabs(sourceAngle) > 1e-6f) {
        s = sincos(sourceAngle, c);
        localP = float3(c * p.x - s * p.z, p.y, s * p.x + c * p.z);
    }

    // Fold into the fundamental Weyl chamber: reflect across any mirror the point is
    // behind, repeat to convergence. Reflections are isometries → deScale stays 1.
    float3 q = localP;
    for (int i = 0; i < 16; ++i) {
        bool folded = false;
        float d0 = dot(q, n0); if (d0 < 0.0f) { q -= 2.0f * d0 * n0; folded = true; }
        float d1 = dot(q, n1); if (d1 < 0.0f) { q -= 2.0f * d1 * n1; folded = true; }
        float d2 = dot(q, n2); if (d2 < 0.0f) { q -= 2.0f * d2 * n2; folded = true; }
        if (!folded) break;   // inside the fundamental domain
    }

    // Return the folded point to world orientation before applying the amount blend.
    if (fabs(sourceAngle) > 1e-6f) {
        q = float3(c * q.x + s * q.z, q.y, -s * q.x + c * q.z);
    }
    return mix(p, q, t);
}

// ── Plane fold (Mandelbulber kaleidoscopic IFS) ──────────────────────────────
// One conditional plane reflection — the kIFS inner fold: reflect p across the
// plane {dot(p,n)=d} ONLY when it sits behind the plane (dot < d). n is the unit
// normal (a VECTOR the user aims, precomputed on CPU); d = op.p1 (signed distance);
// strength = Mandelbulber's per-plane INTENSITY (0..1 blend; 1 = a true reflection
// → isometric, deScale 1). Matches kaleidoscopic_ifs.cl:
//   length = dot(z, direction); if (length < distance) z -= direction*2*(length-distance)*intensity;
// Stack several (each a mirror plane) to build the kaleidoscopic / Sierpinski set.
FORCE_INLINE float3 warpPlaneFold(float3 p, SpaceWarpOp op) {  // 12
    float intensity = clamp(op.strength, 0.0f, 1.0f);
    if (intensity <= 0.0f) return p;
    float3 n = warpAxisNorm(op);   // unit plane normal
    float d = op.p1;               // signed plane distance from origin
    float len = dot(p, n);
    if (len < d) {
        p -= n * (2.0f * (len - d) * intensity);
    }
    return p;
}

// ── Menger fold (abs + descending sort) ──────────────────────────────────────
// Fold into the positive octant, then sort the components so the largest is on X.
// abs() and the coordinate swaps are both isometries (|slope|=1, permutation) →
// deScale stays 1. This is the Mandelbulber `transf_abs_sym3` / Menger-sponge prep:
// stacked with a Scale + Offset it builds the sponge's octahedral self-similarity.
FORCE_INLINE float3 warpMengerFold(float3 p, SpaceWarpOp op) {  // 13
    float t = clamp(op.strength, 0.0f, 1.0f);
    float3 a = abs(p);
    if (a.x < a.y) a.xy = a.yx;
    if (a.x < a.z) a.xz = a.zx;
    if (a.y < a.z) a.yz = a.zy;
    return mix(p, a, t);
}
// ── Tiling (domain repeat) ───────────────────────────────────────────────────
// Wrap space into an infinite lattice of identical cells of edge `size` centred on
// the origin: p -= size·round(p/size). A translation per cell → isometric (the
// `round` term is piecewise-constant, contributes 0 to the derivative), deScale 1.
FORCE_INLINE float3 warpTiling(float3 p, SpaceWarpOp op) {      // 14
    float t = clamp(op.strength, 0.0f, 1.0f);
    float s = op.p1;   // precomputed max(size, 0.05)
    float3 q = p - s * round(p / s);
    return mix(p, q, t);
}
// ── Uniform scale (IFS glue) ─────────────────────────────────────────────────
// Straight uniform scale of the domain by `strength` (the master slider IS the
// factor here — no 0..1 blend). |∇ f(p·s)| = s, so the DE must be divided by s to
// stay Lipschitz-1: warpScaleDEScale returns exactly s. Between two folds this is
// the classic fold→scale IFS step that grows Sierpinski / Menger structure.
FORCE_INLINE float3 warpScale(float3 p, SpaceWarpOp op) {       // 15
    return p * op.strength;   // strength = scale factor (not clamped to 0..1)
}
FORCE_INLINE float warpScaleDEScale(float3 p, SpaceWarpOp op) {
    return max(abs(op.strength), 1e-3f);
}
// ── Offset fold (abs about an off-origin centre) ─────────────────────────────
// p ↦ |p + c|: a mirror fold whose crease is shifted by the offset vector c (the
// Axis/Offset sliders, used RAW — not normalized). Breaks the origin-symmetry of
// Mirror Fold, giving asymmetric Mandelbox-like structure. Fold+translate → the
// blended map is Lipschitz ≤ 1, so deScale 1 (default arm).
FORCE_INLINE float3 warpOffsetFold(float3 p, SpaceWarpOp op) {  // 16
    float t = clamp(op.strength, 0.0f, 1.0f);
    float3 c = float3(op.axisX, op.axisY, op.axisZ);   // raw offset (not normalized)
    return mix(p, abs(p + c), t);
}

// ── Mandelbox recurrence step ────────────────────────────────────────────────
// Unlike an ordinary domain warp, this op needs the ORIGINAL stack input p0:
//   z' = scale * sphereFold(boxFold(z)) + p0
// Repeating the op therefore reconstructs the actual Mandelbox recurrence instead
// of merely applying its three component transforms once. p1 = fold limit,
// p2 = min radius squared, fixed radius squared = 1, strength = signed scale.
FORCE_INLINE float mandelboxStepSphereScale(float3 folded, SpaceWarpOp op) {
    float r2 = dot(folded, folded);
    if (r2 < op.p2) return 1.0f / max(op.p2, 1e-6f);
    if (r2 < 1.0f) return 1.0f / max(r2, 1e-6f);
    return 1.0f;
}
FORCE_INLINE float3 warpMandelboxStep(float3 p, float3 p0, SpaceWarpOp op) { // 17
    float3 folded = fma(clamp(p, -op.p1, op.p1), float3(2.0f), -p);
    float sphereScale = mandelboxStepSphereScale(folded, op);
    return fma(folded, sphereScale * op.strength, p0);
}
// Mandelbox derivative recurrence is affine, not purely multiplicative. originDE
// is 1 for a legacy standalone step and the captured group-input derivative when
// the step is iterated inside a repeat group.
FORCE_INLINE float warpMandelboxDEUpdate(float3 p, float currentDE, float originDE, SpaceWarpOp op) {
    float3 folded = fma(clamp(p, -op.p1, op.p1), float3(2.0f), -p);
    float localScale = abs(op.strength) * mandelboxStepSphereScale(folded, op);
    return fma(currentDE, localScale, originDE);
}

// Runtime dispatch (default path): a coherent switch over op.type. Unknown
// discriminators FAIL CLOSED to identity: they previously fell into the twist
// arm, so a newer build's stack rendered an unplanned Twist on an older install.
FORCE_INLINE float3 applyWarpOp(float3 p, float3 stackOrigin, SpaceWarpOp op) {
    switch (op.type) {
        default: return p;
        case 0: return warpTwist(p, op);
        case 1: return warpBend(p, op);
        case 2: return warpMirror(p, op);
        case 3: return warpBoxFold(p, op);
        case 4: return warpSphereFold(p, op);
        case 5: return warpInversion(p, op);
        case 6: return warpKaleido(p, op);
        case 7: return warpRipple(p, op);
        case 8: return warpCircle(p, op);
        case 9: return warpShells(p, op);
        case 10: return warpScaleRepeat(p, op);
        case 11: return warpCoxeter(p, op);
        case 12: return warpPlaneFold(p, op);
        case 13: return warpMengerFold(p, op);
        case 14: return warpTiling(p, op);
        case 15: return warpScale(p, op);
        case 16: return warpOffsetFold(p, op);
        case 17: return warpMandelboxStep(p, stackOrigin, op);
        case 18: return warpCoxeter(p, op);
        case 19: return warpCompressionShells(p, op);
    }
}
// Conservative DE divisor for one op (radial / scaling warps stretch distance;
// twist/bend shears stretch it too — see warpTwistDEScale/warpBendDEScale).
FORCE_INLINE float warpOpDEScale(float3 p, SpaceWarpOp op) {
    switch (op.type) {
        case 0:  return warpTwistDEScale(p, op);
        case 1:  return warpBendDEScale(p, op);
        case 4:  return warpSphereFoldDEScale(p, op);
        case 5:  return warpInversionDEScale(p, op);
        case 8:  return warpCircleDEScale(p, op);
        case 10: return warpScaleRepeatDEScale(p, op);
        case 15: return warpScaleDEScale(p, op);
        case 19: return warpCompressionShellsDEScale(p, op);
        default: return 1.0f;
    }
}
// Update the accumulated DE divisor. Most transforms are multiplicative; the
// Mandelbox recurrence has the standard derivative +1 term and is special-cased.
FORCE_INLINE float warpOpDEUpdate(float3 p, float currentDE, float originDE, SpaceWarpOp op) {
    if (op.type == 17) return warpMandelboxDEUpdate(p, currentDE, originDE, op);
    return currentDE * warpOpDEScale(p, op);
}

// Warped sample point + its combined DE divisor. Declared here (above the codegen
// marker) so the injected codegen stack can return it too.
struct SpaceTransform { float3 point; float deScale; };

// Explicit kind allows known group sequences to bypass runtime dispatch entirely.
FORCE_INLINE SpaceTransform transformRadialWarpOp(SpaceTransform input,
                                                  SpaceWarpOp op, int kind) {
    float3 p = input.point;
    SpaceTransform r = input;
    float t = clamp(op.strength, 0.0f, 1.0f);
    float radius2 = kind == 8 ? dot(p.xz, p.xz) : dot(p, p);
    float factor = 1.0f;
    if (kind == 5) {
        factor = clamp(op.p1 / max(radius2, 1e-6f), 0.05f, 20.0f);
    } else if (radius2 < op.p1) {
        factor = op.p2 / op.p1;
    } else if (radius2 < op.p2) {
        factor = op.p2 / max(radius2, 1e-6f);
    }
    float3 folded = kind == 8
        ? float3(p.x * factor, p.y, p.z * factor) : p * factor;
    r.point = mix(p, folded, t);
    if (op.strength > 0.0f)
        r.deScale *= max(mix(1.0f, factor, t), 1e-3f);
    return r;
}

// Combined evaluation contract: consume the incoming point/divisor and return
// both outputs. Scratch values belong only to this sample and operation; never
// carry geometry caches across arbitrary transforms. New operations can retain
// the legacy pair of functions through the default adapter below, then opt into
// a fused implementation when they have shared work worth eliminating.
FORCE_INLINE SpaceTransform transformWarpOp(SpaceTransform input,
                                            float3 origin, float originDE,
                                            SpaceWarpOp op) {
    float3 p = input.point;
    SpaceTransform r = input;
    switch (op.type) {
        case 0:
            r.deScale *= warpTwistDEScale(p, op);
            r.point = warpTwist(p, op);
            return r;
        case 1:
            r.deScale *= warpBendDEScale(p, op);
            r.point = warpBend(p, op);
            return r;
        case 2: r.point = warpMirror(p, op); return r;
        case 3: r.point = warpBoxFold(p, op); return r;
        case 6: r.point = warpKaleido(p, op); return r;
        case 7: r.point = warpRipple(p, op); return r;
        case 9: r.point = warpShells(p, op); return r;
        case 10:
            r.deScale *= warpScaleRepeatDEScale(p, op);
            r.point = warpScaleRepeat(p, op);
            return r;
        case 11: case 18: r.point = warpCoxeter(p, op); return r;
        case 12: r.point = warpPlaneFold(p, op); return r;
        case 13: r.point = warpMengerFold(p, op); return r;
        case 14: r.point = warpTiling(p, op); return r;
        case 15:
            r.deScale *= warpScaleDEScale(p, op);
            r.point = warpScale(p, op);
            return r;
        case 16: r.point = warpOffsetFold(p, op); return r;
        case 19:
            r.deScale *= warpCompressionShellsDEScale(p, op);
            r.point = warpCompressionShells(p, op);
            return r;
        case 4: case 5: case 8:
            return transformRadialWarpOp(input, op, op.type);
        case 17: { // Affine derivative recurrence must preserve origin feedback.
            float3 folded = fma(clamp(p, -op.p1, op.p1), float3(2.0f), -p);
            float factor = mandelboxStepSphereScale(folded, op);
            r.point = fma(folded, factor * op.strength, origin);
            r.deScale = fma(input.deScale, abs(op.strength) * factor, originDE);
            return r;
        }
        default:
            r.deScale = warpOpDEUpdate(p, input.deScale, originDE, op);
            r.point = applyWarpOp(p, origin, op);
            return r;
    }
}

// The deconstructed Mandelbox is the overwhelmingly common repeated group. Keep
// its three editable uniform ops, but execute their fixed type sequence directly:
// one coherent group branch and no inner-loop switches. This preserves live child
// parameters while avoiding 2 dynamic dispatches per child, per distance sample.
FORCE_INLINE bool isBoxSphereScaleGroup(constant SpaceWarpOp* ops,
                                        int start, int groupLength) {
    return groupLength == 3
        && ops[start].type == 3
        && ops[start + 1].type == 4
        && ops[start + 2].type == 15;
}

FORCE_INLINE float3 applyBoxSphereScaleGroupFast(float3 point, float3 origin,
                                                  constant SpaceWarpOp* ops,
                                                  int start, int passes,
                                                  bool addOriginFeedback) {
    SpaceWarpOp boxOp = ops[start];
    SpaceWarpOp sphereOp = ops[start + 1];
    SpaceWarpOp scaleOp = ops[start + 2];
    for (int pass = 0; pass < passes; ++pass) {
        point = warpBoxFold(point, boxOp);
        point = warpSphereFold(point, sphereOp);
        point = warpScale(point, scaleOp);
        if (addOriginFeedback) point += origin;
    }
    return point;
}

FORCE_INLINE SpaceTransform transformBoxSphereScaleGroupFast(
    float3 point, float deScale, float3 origin, float originDE,
    constant SpaceWarpOp* ops, int start, int passes,
    bool addOriginFeedback
) {
    SpaceTransform r;
    r.point = point;
    r.deScale = deScale;
    SpaceWarpOp boxOp = ops[start];
    SpaceWarpOp sphereOp = ops[start + 1];
    SpaceWarpOp scaleOp = ops[start + 2];
    float scaleStretch = warpScaleDEScale(point, scaleOp);
    for (int pass = 0; pass < passes; ++pass) {
        r.point = warpBoxFold(r.point, boxOp);
        r = transformRadialWarpOp(r, sphereOp, 4);
        r.deScale *= scaleStretch;
        r.point = warpScale(r.point, scaleOp);
        if (addOriginFeedback) {
            r.point += origin;
            r.deScale += originDE;
        }
    }
    return r;
}

// ── Composable domain-transform STACK ───────────────────────────────────────
// Apply the user-ordered stack to the sample point before the fractal DE.
//
// `spaceWarpStackTransform` is the HOT entry: it sweeps the op chain ONCE, carrying
// the point and its accumulated DE divisor together (forward-mode dual). The march
// path uses only this. `spaceWarpStackApply` / `spaceWarpStackDEScale` are the
// point-only / divisor-only forms the normal probes still need.
//
// PERFORMANCE: these have two forms:
//   • Default (here): a runtime loop + coherent switch. Always correct; renders
//     any stack from the uniforms. Used by the bundled library and as the
//     while-compiling fallback.
//   • Codegen (injected at `// __SPACEWARP_STACK_CODEGEN__` by CustomShaderCompiler
//     when the stack is non-empty): the loop is UNROLLED and each op is dispatched
//     to its warp function at COMPILE time (no loop, no switch). Param VALUES still
//     come from the uniforms, so slider tweaks never recompile — only structural
//     changes (count/order/types) do. `#define THRESHOLD_CODEGEN_SPACEWARP_STACK`
//     in the injected block suppresses these defaults.
// __SPACEWARP_STACK_CODEGEN__
#ifndef THRESHOLD_CODEGEN_SPACEWARP_STACK
FORCE_INLINE float3 spaceWarpStackApply(float3 p, FractalParams params) {
    float3 stackOrigin = p;
    int n = min(params.spaceWarpCount, kMaxSpaceWarpOps);
    for (int i = 0; i < n; ) {
        SpaceWarpOp first = params.spaceWarpOps[i];
        int groupLength = first.groupControl & kSpaceWarpGroupLengthMask;
        int iterations = min(
            (first.groupControl >> kSpaceWarpGroupIterationShift) & kSpaceWarpGroupIterationMask,
            kMaxSpaceWarpGroupIterations);
        bool addOriginFeedback =
            (first.groupControl & kSpaceWarpGroupMandelboxFeedback) != 0;
        if (groupLength > 0 && iterations > 0) {
            groupLength = min(groupLength, n - i);
            float3 groupOrigin = p;
            if (isBoxSphereScaleGroup(params.spaceWarpOps, i, groupLength)) {
                p = applyBoxSphereScaleGroupFast(
                    p, groupOrigin, params.spaceWarpOps, i, iterations,
                    addOriginFeedback);
            } else {
                for (int iteration = 0; iteration < iterations; ++iteration) {
                    for (int j = 0; j < groupLength; ++j) {
                        p = applyWarpOp(p, groupOrigin, params.spaceWarpOps[i + j]);
                    }
                    if (addOriginFeedback) p += groupOrigin;
                }
            }
            i += groupLength;
        } else {
            p = applyWarpOp(p, stackOrigin, first);
            ++i;
        }
    }
    return p;
}
FORCE_INLINE float spaceWarpStackDEScale(float3 p, FractalParams params) {
    float scale = 1.0f;
    float3 stackOrigin = p;
    float3 pt = p;
    int n = min(params.spaceWarpCount, kMaxSpaceWarpOps);
    for (int i = 0; i < n; ) {
        SpaceWarpOp first = params.spaceWarpOps[i];
        int groupLength = first.groupControl & kSpaceWarpGroupLengthMask;
        int iterations = min(
            (first.groupControl >> kSpaceWarpGroupIterationShift) & kSpaceWarpGroupIterationMask,
            kMaxSpaceWarpGroupIterations);
        bool addOriginFeedback =
            (first.groupControl & kSpaceWarpGroupMandelboxFeedback) != 0;
        if (groupLength > 0 && iterations > 0) {
            groupLength = min(groupLength, n - i);
            float3 groupOrigin = pt;
            float groupOriginScale = scale;
            if (isBoxSphereScaleGroup(params.spaceWarpOps, i, groupLength)) {
                SpaceTransform fast = transformBoxSphereScaleGroupFast(
                    pt, scale, groupOrigin, groupOriginScale,
                    params.spaceWarpOps, i, iterations, addOriginFeedback);
                pt = fast.point;
                scale = fast.deScale;
            } else {
                for (int iteration = 0; iteration < iterations; ++iteration) {
                    for (int j = 0; j < groupLength; ++j) {
                        SpaceWarpOp op = params.spaceWarpOps[i + j];
                        SpaceTransform sample = { pt, scale };
                        sample = transformWarpOp(sample, groupOrigin, groupOriginScale, op);
                        pt = sample.point;
                        scale = sample.deScale;
                    }
                    if (addOriginFeedback) {
                        pt += groupOrigin;
                        scale += groupOriginScale;
                    }
                }
            }
            i += groupLength;
        } else {
            SpaceTransform sample = { pt, scale };
            sample = transformWarpOp(sample, stackOrigin, 1.0f, first);
            pt = sample.point;
            scale = sample.deScale;
            ++i;
        }
    }
    return scale;
}
// Fused sweep: ONE walk of the op chain producing the warped point AND the DE
// divisor in lockstep — replaces a separate DEScale-walk + point-walk (which ran
// applyWarpOp over the whole chain twice per DE evaluation).
FORCE_INLINE SpaceTransform spaceWarpStackTransform(float3 p, FractalParams params) {
    SpaceTransform r;
    r.point = p;
    r.deScale = 1.0f;
    float3 stackOrigin = p;
    int n = min(params.spaceWarpCount, kMaxSpaceWarpOps);
    for (int i = 0; i < n; ) {
        SpaceWarpOp first = params.spaceWarpOps[i];
        int groupLength = first.groupControl & kSpaceWarpGroupLengthMask;
        int iterations = min(
            (first.groupControl >> kSpaceWarpGroupIterationShift) & kSpaceWarpGroupIterationMask,
            kMaxSpaceWarpGroupIterations);
        bool addOriginFeedback =
            (first.groupControl & kSpaceWarpGroupMandelboxFeedback) != 0;
        if (groupLength > 0 && iterations > 0) {
            groupLength = min(groupLength, n - i);
            float3 groupOrigin = r.point;
            float groupOriginScale = r.deScale;
            if (isBoxSphereScaleGroup(params.spaceWarpOps, i, groupLength)) {
                r = transformBoxSphereScaleGroupFast(
                    r.point, r.deScale, groupOrigin, groupOriginScale,
                    params.spaceWarpOps, i, iterations, addOriginFeedback);
            } else {
                for (int iteration = 0; iteration < iterations; ++iteration) {
                    for (int j = 0; j < groupLength; ++j) {
                        SpaceWarpOp op = params.spaceWarpOps[i + j];
                        r = transformWarpOp(r, groupOrigin, groupOriginScale, op);
                    }
                    if (addOriginFeedback) {
                        r.point += groupOrigin;
                        r.deScale += groupOriginScale;
                    }
                }
            }
            i += groupLength;
        } else {
            r = transformWarpOp(r, stackOrigin, 1.0f, first);
            ++i;
        }
    }
    return r;
}
#endif

// A loaded .threshfx warp overrides the whole built-in path via
// THRESHOLD_CUSTOM_SPACE_WARP, exactly as before.
FORCE_INLINE float3 applySpaceWarp(float3 p, FractalParams params) {
    if (!FC_HAS_SPACEWARP_ON) { return p; }   // no-transform variant: seam compiled out
#ifdef THRESHOLD_CUSTOM_SPACE_WARP
    float strength = params.spaceWarpStrength;
    if (strength <= 0.0f) { return p; }
    return customSpaceWarp(p, strength, params.spaceWarpParam1, params.spaceWarpParam2, params.spaceWarpParam3);
#else
    return spaceWarpStackApply(p, params);
#endif
}
FORCE_INLINE float applySpaceWarpDEScale(float3 p, FractalParams params) {
    if (!FC_HAS_SPACEWARP_ON) { return 1.0f; }   // no-transform variant: DE divisor is a compile-time 1
#ifdef THRESHOLD_CUSTOM_SPACE_WARP
    return customSpaceWarpDEScale(p, params.spaceWarpStrength, params.spaceWarpParam1, params.spaceWarpParam2, params.spaceWarpParam3);
#else
    return spaceWarpStackDEScale(p, params);
#endif
}
// Fused point + DE-divisor for the hot march path. The built-in stack does it in a
// single sweep. Custom sources may opt into a combined hook; old files retain
// their two-function ABI without requiring metadata or source rewriting.
FORCE_INLINE SpaceTransform applySpaceWarpTransform(float3 p, FractalParams params) {
    if (!FC_HAS_SPACEWARP_ON) {   // no-transform variant: identity point, unit divisor
        SpaceTransform r; r.point = p; r.deScale = 1.0f; return r;
    }
#ifdef THRESHOLD_CUSTOM_SPACE_WARP
    SpaceTransform r;
    r.point = p;
    r.deScale = 1.0f;
    float strength = params.spaceWarpStrength;
    if (strength <= 0.0f) { return r; }
#ifdef THRESHOLD_CUSTOM_SPACE_WARP_COMBINED
    r.point = customSpaceWarpCombined(p, strength, params.spaceWarpParam1,
                                     params.spaceWarpParam2, params.spaceWarpParam3,
                                     r.deScale);
#else
    r.deScale = customSpaceWarpDEScale(p, strength, params.spaceWarpParam1, params.spaceWarpParam2, params.spaceWarpParam3);
    r.point   = customSpaceWarp(p, strength, params.spaceWarpParam1, params.spaceWarpParam2, params.spaceWarpParam3);
#endif
    return r;
#else
    return spaceWarpStackTransform(p, params);
#endif
}

FORCE_INLINE float safetyBubbleCubeDistance(float3 p, float bubbleRadius) {
    float3 d = abs(p) - float3(bubbleRadius);
    return length(max(d, 0.0)) + min(max(d.x, max(d.y, d.z)), 0.0);
}

FORCE_INLINE float safetyBubbleTetrahedralDistance(float3 p, float bubbleRadius) {
    constexpr float invSqrt3 = 0.5773502691896258f;
    // Keep axis extent aligned with bubbleRadius, matching sphere/cube behavior.
    float faceOffset = bubbleRadius * invSqrt3;
    float d1 = dot(p, float3( invSqrt3,  invSqrt3,  invSqrt3));
    float d2 = dot(p, float3( invSqrt3, -invSqrt3, -invSqrt3));
    float d3 = dot(p, float3(-invSqrt3,  invSqrt3, -invSqrt3));
    float d4 = dot(p, float3(-invSqrt3, -invSqrt3,  invSqrt3));
    return max(max(d1, d2), max(d3, d4)) - faceOffset;
}

FORCE_INLINE float safetyBubbleNegativeCubeDistance(float3 p, float bubbleRadius) {
    constexpr float exponent = 0.65f;
    float3 q = abs(p) / max(bubbleRadius, 1e-4f);
    float superDistance = pow(pow(q.x, exponent) + pow(q.y, exponent) + pow(q.z, exponent), 1.0f / exponent);
    return (superDistance - 1.0f) * bubbleRadius;
}

FORCE_INLINE float safetyBubbleOctahedronDistance(float3 p, float bubbleRadius) {
    float3 q = abs(p);
    return (q.x + q.y + q.z - bubbleRadius) * 0.5773502691896258f;
}

FORCE_INLINE float safetyBubbleIcosahedronDistance(float3 p, float bubbleRadius) {
    constexpr float phi = 1.618033988749895f;
    constexpr float invPhiLen = 0.5257311121191336f;
    constexpr float invTriLen = 0.5773502691896258f;
    constexpr float axisScale = 0.85065080835204f;
    float3 q = abs(p);
    // Icosahedron: 20 planes (8 from (1,1,1), 12 from golden-ratio families).
    float d1 = dot(q, float3(1.0f, 1.0f, 1.0f) * invTriLen);
    float d2 = dot(q, float3(0.0f, 1.0f, phi) * invPhiLen);
    float d3 = dot(q, float3(1.0f, phi, 0.0f) * invPhiLen);
    float d4 = dot(q, float3(phi, 0.0f, 1.0f) * invPhiLen);
    return max(max(d1, d2), max(d3, d4)) - bubbleRadius * axisScale;
}

FORCE_INLINE float safetyBubbleDodecahedronDistance(float3 p, float bubbleRadius) {
    constexpr float phi = 1.618033988749895f;
    constexpr float invPhiLen = 0.5257311121191336f;
    constexpr float axisScale = 0.85065080835204f;
    float3 q = abs(p);
    // Dodecahedron: 12 planes from icosahedral normal families.
    float d1 = dot(q, float3(phi, 1.0f, 0.0f) * invPhiLen);
    float d2 = dot(q, float3(1.0f, 0.0f, phi) * invPhiLen);
    float d3 = dot(q, float3(0.0f, phi, 1.0f) * invPhiLen);
    return max(d1, max(d2, d3)) - bubbleRadius * axisScale;
}

// === SAFETY BUBBLE DISTANCE FUNCTION ===
// Uses the legacy sphere/cube morph for values in 0...1 and discrete solids above that.
// The bubble stays axis-aligned and only translates with the viewer position.
FORCE_INLINE float safetyBubbleDistance(float3 pos, float3 bubbleCenter, float bubbleRadius, float bubbleShape) {
    float3 p = pos - bubbleCenter;

    // Sphere distance (signed, negative inside)
    float sphereDist = length(p) - bubbleRadius;

    // Axis-aligned cube distance (Chebyshev distance - max of absolute components)
    // No rotation - cube stays aligned with world axes for stable visual reference
    float cubeDist = safetyBubbleCubeDistance(p, bubbleRadius);

    if (bubbleShape <= 1.0f) {
        return mix(sphereDist, cubeDist, clamp(bubbleShape, 0.0f, 1.0f));
    }

    int discreteShape = int(clamp(bubbleShape + 0.5f, 2.0f, 6.0f));
    switch (discreteShape) {
        case 2:
            return safetyBubbleTetrahedralDistance(p, bubbleRadius);
        case 3:
            return safetyBubbleNegativeCubeDistance(p, bubbleRadius);
        case 4:
            return safetyBubbleOctahedronDistance(p, bubbleRadius);
        case 5:
            return safetyBubbleIcosahedronDistance(p, bubbleRadius);
        case 6:
            return safetyBubbleDodecahedronDistance(p, bubbleRadius);
        default:
            return cubeDist;
    }
}

// The Bounding ray-skip / tile cull uses a cheap enclosing SPHERE. For any
// non-sphere Bounding shape (the sphere→cube morph, or a platonic solid) the
// shape circumscribes a LARGER sphere than its `radius` param — a cube's corners
// reach radius·√3 — so a same-radius cull sphere clips inside the shape and masks
// it, making every shape read as a sphere. Inflate the cull sphere to safely
// enclose every supported shape (√3 ≈ 1.73 is the worst case; 1.8 adds margin);
// the shape SDF (boundFade) then defines the actual silhouette. Pure sphere
// (shapeType 0) is left exact so its tight cull still culls maximum background.
FORCE_INLINE float boundingCullSphereRadius(float radius, float shapeType) {
    return (shapeType <= 0.001f) ? radius : radius * 1.8f;
}

// === SCENE-LEVEL SDF UNION ===
// Canonical 3DBenchy volume bounds after converting the supplied STL from
// millimetres/Z-up into Threshold's model units/Y-up. A thin positive padding
// shell keeps trilinear samples well-defined around the mesh.
constant float3 kBenchySDFMin = float3(-1.08f, -0.08f, -0.60f);
constant float3 kBenchySDFMax = float3( 1.08f,  1.68f,  0.60f);

FORCE_INLINE float sampleBenchySDF(float3 p, device const half* grid) {
    if (grid == nullptr) return kRayMissThreshold;
    const float dim = float(BENCHY_SDF_DIM);
    float3 cell = (kBenchySDFMax - kBenchySDFMin) / dim;
    float3 g = (p - kBenchySDFMin) / cell - 0.5f;
    float3 clampedG = clamp(g, float3(0.0f), float3(dim - 1.0f));
    int3 i0 = min(int3(floor(clampedG)), int3(BENCHY_SDF_DIM - 2));
    float3 f = clampedG - float3(i0);
    int base = (i0.z * BENCHY_SDF_DIM + i0.y) * BENCHY_SDF_DIM + i0.x;
    const int sy = BENCHY_SDF_DIM;
    const int sz = BENCHY_SDF_DIM * BENCHY_SDF_DIM;
    float c000 = float(grid[base]);
    float c100 = float(grid[base + 1]);
    float c010 = float(grid[base + sy]);
    float c110 = float(grid[base + sy + 1]);
    float c001 = float(grid[base + sz]);
    float c101 = float(grid[base + sz + 1]);
    float c011 = float(grid[base + sz + sy]);
    float c111 = float(grid[base + sz + sy + 1]);
    float sampled = mix(
        mix(mix(c000, c100, f.x), mix(c010, c110, f.x), f.y),
        mix(mix(c001, c101, f.x), mix(c011, c111, f.x), f.y),
        f.z
    );
    // Continue the field monotonically outside the baked box instead of
    // clamping to its border value (which would create a false outer shell).
    return sampled + length((g - clampedG) * cell);
}

FORCE_INLINE float scenePrimitiveLocalDistance(
    float3 p,
    int kind,
    float3 dimensions,
    device const half* benchyGrid
) {
    float primary = max(dimensions.x, 0.001f);
    float secondary = max(dimensions.y, 0.001f);
    if (kind == 0) return length(p) - primary;
    if (kind == 1) {
        float3 q = abs(p) - max(dimensions, float3(0.001f));
        return length(max(q, 0.0f)) + min(max(q.x, max(q.y, q.z)), 0.0f);
    }
    if (kind == 2) {
        return length(float2(length(p.xz) - primary, p.y)) - secondary;
    }
    if (kind == 3) {
        return (abs(p.x) + abs(p.y) + abs(p.z) - primary) * 0.57735026919f;
    }
    if (kind == 4) {
        p.y -= clamp(p.y, -primary, primary);
        return length(p) - secondary;
    }
    if (kind == 5) {
        float2 q = abs(float2(length(p.xz), p.y)) - float2(secondary, primary);
        return min(max(q.x, q.y), 0.0f) + length(max(q, 0.0f));
    }
    if (kind == 6) {
        float2 q = float2(length(p.xz), p.y);
        float2 k1 = float2(0.0f, primary);
        float2 k2 = float2(-secondary, 2.0f * primary);
        float2 ca = float2(q.x - min(q.x, q.y < 0.0f ? secondary : 0.0f),
                           abs(q.y) - primary);
        float2 cb = q - k1
                  + k2 * clamp(dot(k1 - q, k2) / dot(k2, k2), 0.0f, 1.0f);
        float signValue = (cb.x < 0.0f && ca.y < 0.0f) ? -1.0f : 1.0f;
        return signValue * sqrt(min(dot(ca, ca), dot(cb, cb)));
    }
    if (kind == 7) {
        float3 q = abs(p);
        float side = max(q.x * 0.86602540378f + q.z * 0.5f, q.z) - secondary;
        return max(q.y - primary, side);
    }
    if (kind == 8) return DE_ConstructionPyramid_Dist(p, primary, secondary);
    if (kind == 9) return DE_ConstructionTetrahedron_Dist(p, primary);
    if (kind == 10) return DE_ConstructionIcosahedron_Dist(p, primary);
    if (kind == 11) return DE_ConstructionDodecahedron_Dist(p, primary);
    if (kind == 12) return sampleBenchySDF(p, benchyGrid);
    return kRayMissThreshold;
}

FORCE_INLINE float scenePrimitivesDistance(float3 pos, FractalParams params) {
    constant EnvScrunchParams* fields = params.envScrunch;
    if (fields == nullptr || fields->scenePrimitiveCount <= 0) {
        return kRayMissThreshold;
    }
    device const half* benchyGrid = fields->benchySDFAddress != 0
        ? reinterpret_cast<device const half*>(fields->benchySDFAddress)
        : nullptr;
    float distance = kRayMissThreshold;
    int count = min(fields->scenePrimitiveCount, kMaxScenePrimitives);
    for (int index = 0; index < count; ++index) {
        ScenePrimitiveGPU object = fields->scenePrimitives[index];
        float scale = max(object.positionScale.w, 0.01f);
        float3 local = (pos - object.positionScale.xyz) / scale;
        int kind = int(round(object.dimensionsKind.w));
        float objectDistance = scenePrimitiveLocalDistance(
            local,
            kind,
            object.dimensionsKind.xyz,
            benchyGrid
        ) * scale;
        distance = min(distance, objectDistance);
    }
    return distance;
}

FORCE_INLINE float applyScenePrimitives(float d, float3 pos, FractalParams params) {
    return min(d, scenePrimitivesDistance(pos, params));
}

// === SAFETY BUBBLE CSG APPLICATION ===
// Applies safety bubble as CSG subtraction with optional smooth fade.
// Hard mode:  d = max(d, -bubbleDist)  — sharp edge at bubble boundary
// Faded mode: smooth polynomial max for gradual geometry transition
//   Inner radius: geometry fully carved out (safe zone)
//   Outer radius (inner + fadeWidth): geometry fully visible
//   Between: smooth blend using polynomial smooth-max
FORCE_INLINE float applySafetyBubble(float d, float3 pos, FractalParams params) {
    d = applyScenePrimitives(d, pos, params);
    const bool bubbleEnabled = is_function_constant_defined(FC_SAFETY_BUBBLE_ENABLED)
        ? FC_SAFETY_BUBBLE_ENABLED : (params.bubbleEnabled != 0);
    if (!bubbleEnabled) return d;
    // Temporal fade: skip work when strength is near zero
    if (params.bubbleStrength < 0.001f) return d;

    float bubbleDist = safetyBubbleDistance(pos, params.bubbleCenter, params.bubbleRadius, params.bubbleShape);

    float dBubbled;
    if (params.bubbleFadeEnabled != 0 && params.bubbleFadeWidth > 0.001f) {
        // Smooth polynomial max: smax(d, -bubbleDist, k)
        // k = fadeWidth controls transition zone width
        float a = d;
        float b = -bubbleDist;
        float k = params.bubbleFadeWidth;
        float h = saturate(0.5f + 0.5f * (b - a) / k);
        dBubbled = mix(a, b, h) + k * h * (1.0f - h);
    } else {
        // Hard edge: standard CSG subtraction
        dBubbled = max(d, -bubbleDist);
    }
    // OPTIMIZATION: When strength is at full (blend slider = 100%), skip the temporal
    // blend entirely. Since bubbleStrength comes from a uniform buffer, ALL GPU threads
    // take the same branch — no divergence cost. Saves the mix in the hottest path
    // (Map is called 50-100+ times per pixel per eye at 90Hz).
    if (params.bubbleStrength >= 1.0f) return dBubbled;
    // Temporal blend: lerp between original and bubble-applied distance
    // When strength < 1, the bubble partially fades in via the configured fade strength
    return mix(d, dBubbled, params.bubbleStrength);
}

// === HAND ATTRACTION CSG APPLICATION ===
// A per-hand interaction sphere at each tracked palm, with a SIGNED strength:
//   strength > 0 (Attract) — smooth UNION of a small blob into the surface
//     (polynomial smooth-min), so geometry near the hand reaches out to meet it.
//   strength < 0 (Repel)   — smooth SUBTRACTION of the same blob (polynomial
//     smooth-max, same shape as the Safety Bubble's fade), so geometry recoils
//     from the hand instead.
// handAttractionRadius sets both the blob's own size and the smooth blend
// width, so a bigger radius reads as a wider, gentler effect; |strength|
// scales how far that blend reaches (0 = no effect, 1 = full-width blend).
// When pocketEnabled is set alongside Attract, an additional small repel
// carve is applied right at the hand — the surrounding surface still pulls
// toward the hand, but a pocket is hollowed out where the hand actually is.
FORCE_INLINE float applyHandAttractionOne(float d, float3 pos, float3 handPos, float radius, float strength, int pocketEnabled, float4 shape) {
    // Cheap reject (iquilezles.org/maths/hiddenintersections-style discriminant
    // check, reduced to a squared-distance compare since we only need hit/miss,
    // not the entry point): the smooth blend below always resolves to `d` once
    // pos is well beyond the ball/pocket's combined reach, so skip the sqrt and
    // saturate/mix math for the common case of a march step nowhere near a hand.
    // shape.x<=1, shape.y<=2, shape.z<=1.5, shape.w<=1.5 (HandAttractionConfig
    // clamps) cap the worst-case reach at ~3.75x radius; 4x leaves margin.
    float distSq = dot(pos - handPos, pos - handPos);
    float cullReach = radius * 4.0f;
    if (distSq > cullReach * cullReach) return d;

    float dist = sqrt(distSq);
    // shape.x — ball size as a fraction of the influence radius.
    float ballRadius = max(radius * shape.x, 1e-3f);
    // |strength| scales the DEPTH of the effect: how much of the ball actually
    // engages the surface. Light strengths make a shallow bump/dent instead of
    // a full-radius hard carve — a blend-style transition.
    float effectRadius = ballRadius * saturate(fabs(strength));
    float blobDist = dist - effectRadius;
    // shape.y — blend softness, decoupled from strength so the transition
    // width is independently tunable.
    float k = max(ballRadius * shape.y, 1e-4f);

    float result;
    if (strength >= 0.0f) {
        // Attract: smooth union pulls surface toward the hand.
        float h = saturate(0.5f + 0.5f * (blobDist - d) / k);
        result = mix(blobDist, d, h) - k * h * (1.0f - h);

        if (pocketEnabled != 0) {
            // Pocket: carve a hollow right at the hand (smooth-max subtraction)
            // so it still reads as a place for the hand to sit even while the
            // wider surface reaches for it. Pocket size is NOT scaled by
            // strength — it's a physical hollow for the hand.
            float pocketRadius = max(ballRadius * shape.z, 1e-3f);
            float pocketDist = dist - pocketRadius;
            float pk = max(pocketRadius * shape.w, 1e-4f);
            float a = result;
            float b = -pocketDist;
            float ph = saturate(0.5f + 0.5f * (b - a) / pk);
            result = mix(a, b, ph) + pk * ph * (1.0f - ph);
        }
    } else {
        // Repel: smooth subtraction pushes surface away from the hand.
        float a = d;
        float b = -blobDist;
        float h = saturate(0.5f + 0.5f * (b - a) / k);
        result = mix(a, b, h) + k * h * (1.0f - h);
    }
    return result;
}

// Forearm capsule: always CARVES empty space along the wrist→elbow segment
// (smooth-max subtraction), regardless of the hand ball's signed strength.
// The point of the forearm is limb visibility: the compositor draws the real
// passthrough arm only where the submitted scene depth is farther than the
// limb, so the capsule keeps geometry from ever sitting in front of the arm.
// A.w = tracked flag, B.w = capsule radius; softness shares the hand ball's
// blend control (shape.y).
FORCE_INLINE float applyForearmOne(float d, float3 pos, float4 A, float4 B, float softness) {
    float radius = B.w;
    float3 pa = pos - A.xyz;
    float3 ba = B.xyz - A.xyz;
    float t = saturate(dot(pa, ba) / max(dot(ba, ba), 1e-6f));
    float3 closest = pa - ba * t;
    float k = max(radius * softness, 1e-4f);
    // Cheap reject, same reasoning as applyHandAttractionOne: beyond the
    // capsule's blend reach (radius + softness width) the smooth subtraction
    // always resolves to `d` — skip the sqrt + saturate/mix math. t/closest
    // are sqrt-free, so this check is nearly free even when it doesn't fire.
    float cullReach = (radius + k) * 1.5f;
    float distSq = dot(closest, closest);
    if (distSq > cullReach * cullReach) return d;

    float dist = sqrt(distSq);
    float capDist = dist - radius;
    float a = d;
    float b = -capDist;
    float h = saturate(0.5f + 0.5f * (b - a) / k);
    return mix(a, b, h) + k * h * (1.0f - h);
}

// === ENVIRONMENT SCRUNCH (scanned-room proximity field) ===
// Trilinear sample of the CPU-baked band-limited unsigned distance grid
// (world meters, ENV_SCRUNCH_DIM^3 halfs). `pos` is MODEL space; the params
// carry a fused model→grid matrix and the meters→model distance scale.
// Outside the grid (or beyond its clamp) returns bandModel, i.e. "no effect".
FORCE_INLINE float envScrunchSample(float3 pos, constant EnvScrunchParams& es, device const half* grid) {
    float3 g = (es.modelToGrid * float4(pos, 1.0f)).xyz;
    const float DIMf = float(ENV_SCRUNCH_DIM);
    // Outside the grid = far from every scanned surface: return the bake's
    // far clamp (carried in the params from EnvironmentSDFGrid.clampFar, so
    // the two can't drift — TECH_DEBT.md #19), NOT the band, so Shell mode
    // cuts space beyond the grid instead of skinning its boundary. Scrunch
    // mode treats anything >= band the same, unaffected.
    // `i0 + 1` remains valid until g reaches the outermost center + 1 cell
    // (DIM - 0.5). The old DIM - 1.5 check discarded an entire valid
    // interpolation slab on each positive grid edge.
    if (any(g < float3(0.5f)) || any(g >= float3(DIMf - 0.5f))) return es.farClampModel;
    float3 gf = g - 0.5f;
    int3 i0 = int3(floor(gf));
    float3 f = gf - float3(i0);
    int base = (i0.z * ENV_SCRUNCH_DIM + i0.y) * ENV_SCRUNCH_DIM + i0.x;
    const int sy = ENV_SCRUNCH_DIM;
    const int sz = ENV_SCRUNCH_DIM * ENV_SCRUNCH_DIM;
    float c000 = float(grid[base]);
    float c100 = float(grid[base + 1]);
    float c010 = float(grid[base + sy]);
    float c110 = float(grid[base + sy + 1]);
    float c001 = float(grid[base + sz]);
    float c101 = float(grid[base + sz + 1]);
    float c011 = float(grid[base + sz + sy]);
    float c111 = float(grid[base + sz + sy + 1]);
    float e = mix(mix(mix(c000, c100, f.x), mix(c010, c110, f.x), f.y),
                  mix(mix(c001, c101, f.x), mix(c011, c111, f.x), f.y), f.z);
    return e * es.metersToModel;
}

// Signed box SDF (model units) of the scanned-room containment AABB. Evaluated
// in grid space so `modelToGrid` folds in the model→world rotation for free;
// per-axis `cellModel` converts grid-cell steps to model units, so the distance
// stays metric despite anisotropic cells. Positive outside the room, negative in.
FORCE_INLINE float envContainBox(float3 pos, constant EnvScrunchParams& es) {
    float3 g = (es.modelToGrid * float4(pos, 1.0f)).xyz;
    float3 c = 0.5f * (es.containMinGrid + es.containMaxGrid);
    float3 hExt = max(0.5f * (es.containMaxGrid - es.containMinGrid), float3(0.0f));
    float3 q = (abs(g - c) - hExt) * es.cellModel;
    return length(max(q, float3(0.0f))) + min(max(q.x, max(q.y, q.z)), 0.0f);
}

FORCE_INLINE float3 envScrunchGradient(float3 pos, constant EnvScrunchParams& es, device const half* grid) {
    float h = max(min(es.cellModel.x, min(es.cellModel.y, es.cellModel.z)), 1e-3f);
    float dx = envScrunchSample(pos + float3(h, 0, 0), es, grid)
             - envScrunchSample(pos - float3(h, 0, 0), es, grid);
    float dy = envScrunchSample(pos + float3(0, h, 0), es, grid)
             - envScrunchSample(pos - float3(0, h, 0), es, grid);
    float dz = envScrunchSample(pos + float3(0, 0, h), es, grid)
             - envScrunchSample(pos - float3(0, 0, h), es, grid);
    float3 g = float3(dx, dy, dz);
    float len2 = dot(g, g);
    return (len2 > 1e-8f) ? g * rsqrt(len2) : float3(0.0f, 1.0f, 0.0f);
}

// Environment Scrunch: pulls the fractal into a shell that hugs the scanned
// real-world surfaces (smooth union at a small standoff above them) while
// keeping the surfaces themselves clear (smooth subtraction inside the
// clearance) — a mixed positive/negative field, so the fractal scrunches and
// bulges around the room and its objects instead of punching windows through
// them. Same strength-blended, not-strictly-Lipschitz approach as the hand
// ball; the march epsilon margins absorb it. Optional containment then clips the
// result to the scanned room's AABB — the grid is UNSIGNED so the hug/shell
// mirrors beyond real walls (an "outside shell"/doubling); the box restores a
// sign and cuts it. Single return so containment covers the scrunch early-outs
// too (a point OUTSIDE the room, far from any wall, must still be clipped).
FORCE_INLINE float applyEnvScrunch(float d, float3 pos, FractalParams params) {
    if (!FC_HAS_ENVSCRUNCH_ON) { return d; }   // no-scrunch variant: tail compiled out
    constant EnvScrunchParams* es = params.envScrunch;
    if (es == nullptr || es->enabled == 0 || params.envGrid == nullptr) return d;
    float e = envScrunchSample(pos, *es, params.envGrid);
    float k = max(es->softModel, 1e-4f);
    float out = d;

    if (es->mode == 1) {
        // SHELL: the fractal exists ONLY within the reach band of real
        // surfaces, and only on the viewer-visible side of those surfaces.
        // The room scan is unsigned, so the raw band appears on both sides of
        // a wall. Use the local distance-gradient to estimate the nearest
        // surface and keep the side shared with the headset/camera.
        float3 grad = envScrunchGradient(pos, *es, params.envGrid);
        float viewerSide = dot(grad, es->viewerModel - pos) + e;
        float sideCut = -viewerSide;                // > 0 on the hidden/back side
        float bandCut = e - es->bandModel;          // > 0 outside the shell band
        float ch = saturate(0.5f + 0.5f * (sideCut - bandCut) / k);
        float cut = mix(bandCut, sideCut, ch) + k * ch * (1.0f - ch); // smax
        float h = saturate(0.5f + 0.5f * (cut - d) / k);
        float sc = mix(d, cut, h) + k * h * (1.0f - h);   // smax(d, cut)
        float b = es->carveModel - e;
        float ph = saturate(0.5f + 0.5f * (b - sc) / k);
        sc = mix(sc, b, ph) + k * ph * (1.0f - ph);       // smax(sc, carve)
        out = mix(d, sc, saturate(es->strength));
    } else if (e < es->bandModel) {
        // SCRUNCH: bulge toward surfaces within the band (else `out` stays d).
        // Hug shell at hugModel above the real surface (smooth union).
        float hug = e - es->hugModel;
        float h = saturate(0.5f + 0.5f * (hug - d) / k);
        float sc = mix(hug, d, h) - k * h * (1.0f - h);
        // Clearance carve so the real surface (passthrough) stays visible.
        float b = es->carveModel - e;
        float ph = saturate(0.5f + 0.5f * (b - sc) / k);
        sc = mix(sc, b, ph) + k * ph * (1.0f - ph);
        float w = saturate(es->strength) * (1.0f - smoothstep(0.0f, es->bandModel, e));
        out = mix(d, sc, w);
    }

    // Containment: smax(out, box) — hard intersection (mode 1, k→0) or a soft
    // feathered boundary (mode 2, k = containFeatherModel). Removing geometry
    // only ever increases the true nearest-surface distance, so this stays a
    // valid conservative bound for the coarse warm-start pass.
    if (es->containMode != 0) {
        float box = envContainBox(pos, *es);
        float k2 = (es->containMode == 2) ? max(es->containFeatherModel, 1e-4f) : 1e-4f;
        float hc = saturate(0.5f + 0.5f * (box - out) / k2);
        out = mix(out, box, hc) + k2 * hc * (1.0f - hc);
    }
    return out;
}

// Composes BOTH proximity fields: the scanned-environment scrunch first, then
// the hand field sculpting on top (hands are the nearest-to-user priority).
// Every DE tail calls this, so all fractal types and Map variants get both.
FORCE_INLINE float applyHandAttraction(float d, float3 pos, FractalParams params) {
    d = applyEnvScrunch(d, pos, params);
    if (!FC_HAS_HANDFIELD_ON) { return d; }   // no-hands variant: tail compiled out
    // Hand block lives behind a constant pointer (TECH_DEBT.md #8d) — nullptr
    // or disabled is the common case and returns before any field loads.
    constant HandFieldParams* hf = params.handField;
    if (hf == nullptr || hf->enabled == 0) return d;
    // The hand ball needs a non-zero signed strength; the forearm carve below
    // is strength-independent (it exists for limb visibility, not sculpting).
    const bool ballActive = fabs(hf->strength) >= 0.001f;
    if (ballActive && hf->leftHand.w > 0.5f) {
        d = applyHandAttractionOne(d, pos, hf->leftHand.xyz, hf->radius, hf->strength, hf->pocketEnabled, hf->shape);
    }
    if (ballActive && hf->rightHand.w > 0.5f) {
        d = applyHandAttractionOne(d, pos, hf->rightHand.xyz, hf->radius, hf->strength, hf->pocketEnabled, hf->shape);
    }
    if (hf->leftForearmA.w > 0.5f && hf->leftForearmB.w > 0.0f) {
        d = applyForearmOne(d, pos, hf->leftForearmA, hf->leftForearmB, hf->shape.y);
    }
    if (hf->rightForearmA.w > 0.5f && hf->rightForearmB.w > 0.0f) {
        d = applyForearmOne(d, pos, hf->rightForearmA, hf->rightForearmB, hf->shape.y);
    }
    return d;
}

// The Mandelbox analytic Jacobian describes only its raw fractal DE. Any active
// model/world-space CSG field changes the final gradient and therefore requires
// the finite-difference normal path.
//
// The safety-bubble term is POSITION-AWARE. applySafetyBubble's smooth-max
// weight h = saturate(0.5 + 0.5*(-bubbleDist - d)/k) saturates to 0 whenever
// bubbleDist + d >= k (hard mode is the k→0 case), and then dBubbled == d
// bit-exactly — including through the temporal mix, since mix(d, d, s) == d.
// So outside a thin shell hugging the bubble wall the composed field IS the
// raw fractal field and the analytic/2-probe fast normal paths stay exact.
// The bubble is camera-centered and ON by default on visionOS (comfort), so
// gating on "enabled" alone would force 2-4 full DE probes onto every hit
// pixel per eye per frame even with the bubble meters away from the surface.
//
// Margin: the identity condition must hold at the finite-difference PROBE
// points, not just the hit point, and the hit itself sits at d ≈ 0 (it may
// penetrate by up to the march hit threshold, ~0.02·epsilonScale). Probes
// reach e ≤ 0.001·hitT, and hits near the band have hitT ≤ ~1.8·radius + band
// (camera-centered bubble, max radius 2.5) → e ≤ ~5e-3. Most bubble shapes
// are Lipschitz-1 in this pseudo-distance, but the Negative Cube
// superellipsoid's gradient spikes near the coordinate planes (worst drop
// ≈ 12·e over a probe step). 0.15 covers penetration + probe reach for every
// shape with headroom; the only cost of generosity is a slightly wider
// finite-difference shell around the wall, where FD is cheap relative to the
// carved-wall pixels that genuinely need it.
constant float kSafetyBubbleNormalBandMargin = 0.15f;

FORCE_INLINE bool worldFieldsMayAlterDistance(float3 pos, FractalParams params) {
    const bool bubbleEnabled = is_function_constant_defined(FC_SAFETY_BUBBLE_ENABLED)
        ? FC_SAFETY_BUBBLE_ENABLED : (params.bubbleEnabled != 0);
    bool bubbleActive = bubbleEnabled && params.bubbleStrength >= 0.001f;
    if (bubbleActive) {
        // Same predicate applySafetyBubble saturates on: outside
        // band(+margin) the CSG compose is a bit-exact identity.
        float band = ((params.bubbleFadeEnabled != 0) ? params.bubbleFadeWidth : 0.0f)
                   + kSafetyBubbleNormalBandMargin;
        bubbleActive = safetyBubbleDistance(pos, params.bubbleCenter,
                                            params.bubbleRadius, params.bubbleShape) < band;
    }
    bool environmentEnabled = FC_HAS_ENVSCRUNCH_ON
        && params.envScrunch != nullptr
        && params.envScrunch->enabled != 0
        && params.envGrid != nullptr;
    bool scenePrimitiveActive = params.envScrunch != nullptr
        && params.envScrunch->scenePrimitiveCount > 0
        && scenePrimitivesDistance(pos, params) < kSafetyBubbleNormalBandMargin;
    bool handEnabled = FC_HAS_HANDFIELD_ON
        && params.handField != nullptr
        && params.handField->enabled != 0;
    return bubbleActive || environmentEnabled || scenePrimitiveActive || handEnabled;
}

// OPTIMIZED: Use precomputed values from CPU to avoid per-pixel powr() and division
// This version is preferred when PrecomputedFractalParams is available in uniforms
FORCE_INLINE FractalParams makeFractalParamsFromPrecomputed(
    PrecomputedFractalParams precomputed,
    float minRad2Val,
    float3 bubbleCenter, float bubbleRadius, int bubbleEnabled, float bubbleShape,
    int bubbleFadeEnabled, float bubbleFadeWidth, float bubbleStrength,
    float sphereProjBlend = 0.0f, float sphereProjRadius = 1.0f,
    float spaceWarpStrength = 0.0f, float spaceWarpParam1 = 0.0f,
    float spaceWarpParam2 = 0.0f, float spaceWarpParam3 = 0.0f,
    float3 spaceWarpAxis = float3(0.0f, 1.0f, 0.0f),
    constant SpaceWarpOp* spaceWarpOps = nullptr, int spaceWarpCount = 0,
    constant EnvScrunchParams* envScrunch = nullptr,
    constant HandFieldParams* handField = nullptr)
{
    FractalParams params;
    // Use precomputed values (expensive powr() and divisions done on CPU)
    params.scale = precomputed.scale;
    params.absScalem1 = precomputed.absScalem1;
    params.absScalePow = precomputed.absScalePow;
    params.sphereRadiusSq = precomputed.sphereRadiusSq;
    params.bubbleCenter = bubbleCenter;
    params.bubbleRadius = bubbleRadius;
    params.bubbleEnabled = bubbleEnabled;
    params.bubbleShape = bubbleShape;
    params.bubbleFadeEnabled = bubbleFadeEnabled;
    params.bubbleFadeWidth = bubbleFadeWidth;
    params.bubbleStrength = bubbleStrength;
    params.envScrunch = envScrunch;
    params.envGrid = (envScrunch != nullptr && envScrunch->gridAddress != 0)
        ? reinterpret_cast<device const half*>(envScrunch->gridAddress) : nullptr;
    // No copy: retain the constant-buffer pointer (same rule as spaceWarpOps).
    params.handField = handField;
    params.sphereProjBlend = sphereProjBlend;
    params.sphereProjRadius = sphereProjRadius;
    params.spaceWarpStrength = spaceWarpStrength;
    params.spaceWarpParam1 = spaceWarpParam1;
    params.spaceWarpParam2 = spaceWarpParam2;
    params.spaceWarpParam3 = spaceWarpParam3;
    params.spaceWarpAxis = spaceWarpAxis;
    // No copy: just retain the constant-buffer pointer + count. The ops stay in the
    // Uniforms constant buffer; nothing is duplicated into the per-step FractalParams.
    params.spaceWarpOps = spaceWarpOps;
    params.spaceWarpCount = min(spaceWarpCount, kMaxSpaceWarpOps);
    return params;
}

// Optimized branchless Map function - THE HOTTEST PATH IN THE ENTIRE SHADER
// Called potentially 50-100+ times per pixel (raymarch + shadows + normals)
// Every cycle here matters!
//
// When FC_FRACTAL_ITERATIONS is defined (via function constants), loopCount becomes
// a compile-time constant and the Metal compiler automatically fully unrolls the loop.
// No pragma hints needed - the compiler is smart enough to optimize constant-bound loops.
FORCE_INLINE float Map(float3 pos, FractalParams params, float foldingLimit, int iterations,
                       bool applyWorldFields = true)
{
    float4 p = float4(pos, 1.0);
    float4 p0 = p;

    float invSphereRadiusSq = 1.0f / params.sphereRadiusSq;

    // When FC_FRACTAL_ITERATIONS is defined, this becomes a compile-time constant
    // and the compiler will automatically unroll the loop.
    const int loopCount = is_function_constant_defined(FC_FRACTAL_ITERATIONS) ? FC_FRACTAL_ITERATIONS : iterations;

    if (FC_SPHERE_PROJECTION_ON && params.sphereProjBlend > 0.0f) {
        for (int i = 0; i < loopCount; i++) {
            MAP_ITERATION_PROJ(p, p0, foldingLimit, params, invSphereRadiusSq, params.sphereProjBlend, params.sphereProjRadius);
        }
    } else {
        for (int i = 0; i < loopCount; i++) {
            MAP_ITERATION_BASIC(p, p0, foldingLimit, params, invSphereRadiusSq);
        }
    }

    // Final distance estimate
    float d = (length(p.xyz) - params.absScalem1) / p.w - params.absScalePow;

    if (applyWorldFields) {
        // Camera/environment fields live in model space, outside any fractal
        // domain warp. Unified callers pass false and compose them afterward.
        d = applySafetyBubble(d, pos, params);
        d = applyHandAttraction(d, pos, params);
    }
    return d;
}
// =============================================================================
// GEOMETRY-ONLY DISTANCE ESTIMATOR (Inspired by GMT-fractals DE_Dist())
// =============================================================================
// Stripped-down Map variant for shadows, AO, and normal fallback paths.
// Removes ALL tracking: no trap, no trapIter, no trapPos, no Jacobian.
// Just pure box fold → sphere fold → scale, returning distance.
// This saves ~6 extra ops per iteration vs the full tracking variant.
FORCE_INLINE float MapDistOnly(float3 pos, FractalParams params, float foldingLimit, int iterations,
                               bool applyWorldFields = true)
{
    float4 p = float4(pos, 1.0);
    float4 p0 = p;

    float invSphereRadiusSq = 1.0f / params.sphereRadiusSq;

    const int loopCount = is_function_constant_defined(FC_SHADOW_ITERATIONS) ? FC_SHADOW_ITERATIONS : iterations;

    if (FC_SPHERE_PROJECTION_ON && params.sphereProjBlend > 0.0f) {
        for (int i = 0; i < loopCount; i++) {
            MAP_ITERATION_PROJ(p, p0, foldingLimit, params, invSphereRadiusSq, params.sphereProjBlend, params.sphereProjRadius);
        }
    } else {
        for (int i = 0; i < loopCount; i++) {
            MAP_ITERATION_BASIC(p, p0, foldingLimit, params, invSphereRadiusSq);
        }
    }

    float d = (length(p.xyz) - params.absScalem1) / p.w - params.absScalePow;

    if (applyWorldFields) {
        d = applySafetyBubble(d, pos, params);
        d = applyHandAttraction(d, pos, params);
    }
    return d;
}

// =============================================================================
// CONTINUOUS (FRACTIONAL) ITERATION MAP
// =============================================================================
//
// The standard Map() takes integer iterations. When the coarse pass uses
// iterations/2, it jumps from e.g. 10→5, creating a different distance field
// that can miss thin features. MapContinuous() smoothly interpolates:
//
//   d(N_frac) = lerp(d_floor, d_ceil, fract(N_frac))
//
// where d_floor is the distance after floor(N_frac) iterations and d_ceil
// is the distance after one more iteration. This produces a smooth distance
// field with no discontinuities — thin features are never "jumped over."
//
// The extra cost is just ONE additional iteration body (box fold + sphere fold)
// per call, but the coarse pass can now use 0.6× iterations instead of 0.5×
// with better accuracy, meaning fewer total ray steps to converge.
//
// Runs the fold iteration in half precision since this is only used in
// coarse passes where distance thresholds are large.

FORCE_INLINE float MapContinuous(float3 pos, FractalParams params, float foldingLimit,
                                 float fractionalIterations, bool applyWorldFields = true)
{
    int itersFloor = int(fractionalIterations);
    float frac = fractionalIterations - float(itersFloor);
    itersFloor = max(itersFloor, 1);

    half4 p = half4(half3(pos), 1.0h);
    half4 p0 = p;

    half hFold = half(foldingLimit);
    half4 hScale = half4(params.scale);
    half hSphRSq = half(params.sphereRadiusSq);
    half hInvSphRSq = 1.0h / hSphRSq;
    // Coarse pass must mirror the fine Map's sphere projection, else the
    // over-relaxed marcher seeds startT from the un-projected (box) silhouette
    // and tunnels through the projected surface.
    bool useProj = FC_SPHERE_PROJECTION_ON && params.sphereProjBlend > 0.0f;
    half hProjBlend = half(params.sphereProjBlend);
    half hProjRadius = half(params.sphereProjRadius);

    // Run floor(N) iterations
    if (useProj) {
        for (int i = 0; i < itersFloor; i++) {
            MAP_ITERATION_HALF_PROJ(p, p0, hFold, hScale, hSphRSq, hInvSphRSq, hProjBlend, hProjRadius);
        }
    } else {
        for (int i = 0; i < itersFloor; i++) {
            MAP_ITERATION_HALF(p, p0, hFold, hScale, hSphRSq, hInvSphRSq);
        }
    }

    // Distance after floor(N) iterations
    float dFloor = (length(float3(p.xyz)) - params.absScalem1) / float(p.w) - params.absScalePow;

    // If fractional part is negligible, skip the extra iteration
    if (frac < 0.01f) {
        if (applyWorldFields) {
            dFloor = applySafetyBubble(dFloor, pos, params);
            dFloor = applyHandAttraction(dFloor, pos, params);
        }
        return dFloor;
    }

    // Run one more iteration for ceil(N)
    if (useProj) {
        MAP_ITERATION_HALF_PROJ(p, p0, hFold, hScale, hSphRSq, hInvSphRSq, hProjBlend, hProjRadius);
    } else {
        MAP_ITERATION_HALF(p, p0, hFold, hScale, hSphRSq, hInvSphRSq);
    }
    float dCeil = (length(float3(p.xyz)) - params.absScalem1) / float(p.w) - params.absScalePow;

    // Smooth interpolation between floor and ceil distance estimates
    float d = mix(dFloor, dCeil, frac);

    if (applyWorldFields) {
        d = applySafetyBubble(d, pos, params);
        d = applyHandAttraction(d, pos, params);
    }
    return d;
}

// =============================================================================
// UNIFIED FRACTAL DISPATCH — routes to Mandelbox or formula DE
// =============================================================================
// The branching strategy is zero-overhead for Mandelbox:
//   fractalType == 0 compiles to a perfectly-predicted branch (Mandelbox fast path)
//   fractalType != 0 dispatches through FractalDE_Dispatch (Formulas/FractalFormulas.h)
// Safety bubble is now applied to ALL fractal types via applySafetyBubble().

// Space-domain transforms applied to the sample point BEFORE the DE, uniformly
// for every fractal — so the fractal-type branch below only selects the DE
// evaluator (Map vs FractalDE_Dispatch), never the warp. `deScale` is the
// combined DE divisor (max Jacobian stretch) that keeps the raymarch valid.
// No-op (returns pos, deScale = 1) when nothing is active.
//
// Sphere projection stays cross-fractal-only because Mandelbox has its OWN
// native per-fold projection inside Map(); the custom space warp is universal.
// (SpaceTransform is declared above, near the warp-stack functions.)

// Fused sphere projection: the domain map and its DE divisor shared ALL their math
// (length, clamp, the scale s) — compute s once and return both, instead of the
// two-call applySphereProjectionDomain()+sphereProjectionDEScale().
FORCE_INLINE SpaceTransform sphereProjectionTransform(float3 p, float blend, float radius) {
    SpaceTransform r;
    r.point = p;
    r.deScale = 1.0f;
    if (blend <= 0.0f) { return r; }
    float len = length(p);
    if (len <= 1e-5f) { return r; }
    float b = clamp(blend, 0.0f, 0.98f);
    float s = (1.0f - b) + b * radius / len;
    r.point   = p * s;
    r.deScale = max(s, 1e-3f);
    return r;
}

FORCE_INLINE SpaceTransform applySpaceTransforms(float3 pos, int type, FractalParams params) {
    SpaceTransform r;
    r.point = pos;
    r.deScale = 1.0f;
    if (type != FractalTypeMandelbox) {
        // One fused sphere-projection eval (point + DE divisor) instead of two calls.
        if (FC_SPHERE_PROJECTION_ON) {
            SpaceTransform sp = sphereProjectionTransform(pos, params.sphereProjBlend, params.sphereProjRadius);
            r.deScale *= sp.deScale;
            r.point    = sp.point;
        }
    }
    // ONE fused warp sweep (point + DE divisor together) instead of a divisor-walk
    // followed by an identical point-walk — halves applyWarpOp on the hot path.
    SpaceTransform warp = applySpaceWarpTransform(r.point, params);
    r.deScale *= warp.deScale;
    r.point    = warp.point;
    return r;
}

FORCE_INLINE float MapUnified(float3 pos, FractalParams params, float foldingLimit,
                               int iterations, int fractalType, FormulaParams fp) {
    int type = is_function_constant_defined(FC_FRACTAL_TYPE) ? FC_FRACTAL_TYPE : fractalType;
    SpaceTransform w = applySpaceTransforms(pos, type, params);
    if (type == FractalTypeMandelbox) {
        float d = Map(w.point, params, foldingLimit, iterations, false) / w.deScale;
        d = applySafetyBubble(d, pos, params);
        return applyHandAttraction(d, pos, params);
    }
    int loopCount = is_function_constant_defined(FC_FRACTAL_ITERATIONS) ? FC_FRACTAL_ITERATIONS : iterations;
    float d = FractalDE_Dispatch(w.point, type, fp, loopCount) / w.deScale;
    d = applySafetyBubble(d, pos, params);
    return applyHandAttraction(d, pos, params);
}

FORCE_INLINE float MapDistOnlyUnified(float3 pos, FractalParams params, float foldingLimit,
                                       int iterations, int fractalType, FormulaParams fp) {
    int type = is_function_constant_defined(FC_FRACTAL_TYPE) ? FC_FRACTAL_TYPE : fractalType;
    SpaceTransform w = applySpaceTransforms(pos, type, params);
    if (type == FractalTypeMandelbox) {
        float d = MapDistOnly(w.point, params, foldingLimit, iterations, false) / w.deScale;
        d = applySafetyBubble(d, pos, params);
        return applyHandAttraction(d, pos, params);
    }
    int loopCount = is_function_constant_defined(FC_SHADOW_ITERATIONS) ? FC_SHADOW_ITERATIONS : iterations;
    float d = FractalDE_Dispatch(w.point, type, fp, loopCount) / w.deScale;
    d = applySafetyBubble(d, pos, params);
    return applyHandAttraction(d, pos, params);
}

FORCE_INLINE float MapContinuousUnified(float3 pos, FractalParams params, float foldingLimit,
                                         float fractionalIterations, int fractalType, FormulaParams fp) {
    int type = is_function_constant_defined(FC_FRACTAL_TYPE) ? FC_FRACTAL_TYPE : fractalType;
    SpaceTransform w = applySpaceTransforms(pos, type, params);
    if (type == FractalTypeMandelbox) {
        float d = MapContinuous(w.point, params, foldingLimit, fractionalIterations, false) / w.deScale;
        d = applySafetyBubble(d, pos, params);
        return applyHandAttraction(d, pos, params);
    }
    // Formula DEs do not support Mandelbox-style fractional interpolation yet.
    // For Mandelbulb/MandelbulbJulia, rounding up keeps the coarse pass
    // conservative and avoids underestimating surface complexity near the front shell.
    bool isMB = (type == FractalTypeMandelbulb || type == FractalTypeMandelbulbJulia ||
                 type == FractalTypeBoxFoldMandelbulb);
    int loopCount = max(isMB
                        ? int(ceil(fractionalIterations))
                        : int(fractionalIterations), 1);
    float d = FractalDE_Dispatch(w.point, type, fp, loopCount) / w.deScale;
    d = applySafetyBubble(d, pos, params);
    return applyHandAttraction(d, pos, params);
}
