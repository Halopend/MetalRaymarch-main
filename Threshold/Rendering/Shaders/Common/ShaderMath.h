// --- Fractal Code Port ---
// Spatial Rendering optimizations for visionOS

constant float kPowEpsilon = 1e-6f;
constant half kPowEpsilonHalf = 1e-4h;

// === NAMED CONSTANTS FOR OPTIMIZATION ===
// Raymarching thresholds
constant float kRayMissThreshold = 900.0f;      // Distance indicating ray miss
#define kMaxRayDistanceDefault 12.0f  // Fallback trace distance (macro to silence unused-variable warning)

    // Shading constants (tuned for softer, less harsh lighting)
    constant float kSpecularPower = 50.0f;          // Specular highlight power
    constant float kSpecularIntensity = 2.0f;       // Specular intensity multiplier
    constant float kAttenPower = 1.5f;              // Light attenuation power

// Quality threshold
constant float kMinQualityForShadows = 0.25f;   // Skip shadows below this quality

// Always-on inner glow tint (per-step accumulation contribution).
// Kept cool to avoid muddy yellow shifts when post glow is enabled.
constant half3 kGlowColor = half3(0.07h, 0.11h, 0.20h);

// Inner ray-glow accumulation tuning (SceneWithCache / SceneWithCacheFromStart):
// near-miss DE values below this floor contribute glow; the accumulator is
// scaled down by kGlowAccumScale before being stored in SceneResult.
constant float kGlowNearMissFloor = 0.04f;
constant float kGlowAccumScale = 0.25f;

// =============================================================================
// SHARED HELPER FUNCTIONS - Eliminate duplicate code across shaders
// =============================================================================

// Spotlight direction and attenuation calculation
// Returns: .xyz = normalized direction to light, .w = attenuation factor
// OPTIMIZATION: Use rsqrt to combine normalize and length in one operation
FORCE_INLINE float4 computeSpotlight(float3 hitPos, float3 spotLightPosition) {
    float3 toLight = spotLightPosition - hitPos;
    float distSq = dot(toLight, toLight);
    float invDist = rsqrt(max(distSq, kPowEpsilon));  // 1/distance, hardware accelerated
    float dist = distSq * invDist;  // distance = distSq / sqrt(distSq) = sqrt(distSq)
    float atten = powr(max(dist, kPowEpsilon), kAttenPower);
    return float4(toLight * invDist, atten);  // toLight * invDist = normalize(toLight)
}

// Apply fog based on distance using CPU-precomputed scalars to avoid divides/branches
// fog.fog.x = intensity, fog.fog.y = 1 / intensity (0 when disabled)
FORCE_INLINE half3 applyFog(half3 col, float distance, PrecomputedFog fog) {
    float fogIntensity = fog.fog.x;
    if (fogIntensity <= 0.0001f) { return col; }
    // exp(-distance * fogIntensity * 2.0 + 1.5) = exp(1.5) * exp(-distance * fogIntensity * 2.0)
    // Precomputed: exp(1.5) ≈ 4.4817
    float exponent = fma(distance, -fogIntensity * 2.0f, 1.5f);
    half fogFactor = half(saturate(exp(exponent)));
    return mix(half3(fog.color.xyz), col, fogFactor);
}

// Apply glow contribution from ray steps
FORCE_INLINE half3 applyGlow(half3 col, half glow) {
    return col + glow * glow * kGlowColor;
}

// Per-step inner ray-glow accumulation, shared by SceneWithCache and
// SceneWithCacheFromStart. Glow builds up as the march grazes near-misses
// (small DE values just above the hit threshold) — see kGlowNearMissFloor.
FORCE_INLINE float accumulateGlow(float glow, float h, float glowIntensity) {
    return fma(saturate(kGlowNearMissFloor - h), glowIntensity, glow);
}

// Finalizes the glow accumulator into the SceneResult's stored (normalized) form.
FORCE_INLINE float finalizeGlow(float glow) {
    return saturate(glow * kGlowAccumScale);
}

// Clamp color before post-processing. The ceiling is the grading pipeline's
// HDR working range: wide enough that sun specular, glow, and bloom keep real
// highlight energy for the EDR display mapping in PostEffectsWithScheme, while
// still containing inf/NaN blowups well inside half-float range.
FORCE_INLINE half3 clampColor(half3 col) {
    return clamp(col, half3(0.0h), half3(8.0h));
}

// Narkowicz ACES filmic tonemap fit. Compresses HDR-range values (bloom/glow
// can exceed 1.0 before this point) into SDR range with a filmic shoulder,
// applied BEFORE the user-tunable gamma/display-curve step in
// PostEffectsWithScheme — gamma remains a separate artistic control, this is
// purely the HDR-compression stage. Input is deliberately UNCLAMPED so energy
// above 1.0 rides the shoulder instead of being pre-flattened.
FORCE_INLINE half3 acesFilm(half3 x) {
    const half a = 2.51h, b = 0.03h, c = 2.43h, d = 0.59h, e = 0.14h;
    return saturate((x * (a * x + b)) / (x * (c * x + d) + e));
}

// Soft-clip into [0, peak]: identity below the knee (0.8·peak), then a rational
// shoulder that approaches `peak` asymptotically. C1-continuous at the knee, so
// in-range colors are untouched and out-of-range energy compresses instead of
// banding at a hard clip. Used by the EDR display mapping (peak = the screen's
// current headroom in SDR-white units).
FORCE_INLINE half3 softClipToPeak(half3 x, half peak) {
    half knee = 0.8h * peak;
    half range = peak - knee;
    half3 over = max(x - knee, half3(0.0h));
    return min(x, half3(knee)) + range * over / (range + over);
}

FORCE_INLINE half quantizeCelLight(half value, ColorSchemeParams scheme) {
    if (scheme.cellShadingEnabled == 0) { return value; }
    half levels = half(max(scheme.cellShadingLevels, 2.0f));
    return floor(saturate(value) * levels) / max(levels - 1.0h, 1.0h);
}

// Standard HSV (h in turns [0,1), s,v in [0,1]) -> RGB conversion.
// Used by applyNeonColorScheme (and any other procedural-hue coloring) instead
// of hand-rolled branch chains.
FORCE_INLINE half3 hsv2rgb(half h, half s, half v) {
    half hue = fract(h) * 6.0h;
    half x = 1.0h - abs(fmod(hue, 2.0h) - 1.0h);
    half3 baseColor;
    if (hue < 1.0h)      baseColor = half3(1.0h, x, 0.0h);
    else if (hue < 2.0h) baseColor = half3(x, 1.0h, 0.0h);
    else if (hue < 3.0h) baseColor = half3(0.0h, 1.0h, x);
    else if (hue < 4.0h) baseColor = half3(0.0h, x, 1.0h);
    else if (hue < 5.0h) baseColor = half3(x, 0.0h, 1.0h);
    else                  baseColor = half3(1.0h, 0.0h, x);
    return mix(half3(1.0h), baseColor, s) * v;
}

FORCE_INLINE float3 sphericalInvertPoint(float3 point, float radius) {
    float radiusSq = radius * radius;
    float distSq = max(dot(point, point), 1e-4f);
    return point * (radiusSq / distSq);
}

// Radially project a folded point onto a sphere of the given radius. Used by the
// optional sphere-projection iteration macros (post-sphere-fold). This is the
// canonical projection used by the Space-tab "Sphere Projection" control on the
// base Mandelbox fast path.
FORCE_INLINE float3 mapProjectToSphere(float3 p, float radius) {
    float len = length(p);
    if (len <= 1e-6f) { return float3(radius, 0.0f, 0.0f); }
    return p * (radius / len);
}

// === SPACE MODULE: cross-fractal sphere projection (domain warp) ============
// Mandelbox applies sphere projection per-fold inside Map(). For every other
// fractal we generalize it as a SPACE-DOMAIN warp applied to the sample point
// before the formula DE is evaluated (in the non-Mandelbox dispatch branch).
//
//   f(p) = p * ((1-b) + b * R / |p|)
//
// i.e. blend the point radially toward a sphere of radius R. b in [0, 0.98].
// Identity when blend <= 0, so existing scenes are unaffected.
FORCE_INLINE float3 applySphereProjectionDomain(float3 p, float blend, float radius) {
    if (blend <= 0.0f) { return p; }
    float r = length(p);
    if (r <= 1e-5f) { return p; }
    float b = clamp(blend, 0.0f, 0.98f);
    float s = (1.0f - b) + b * radius / r;
    return p * s;
}

// Conservative distance-estimator divisor for the warp above: the maximum
// singular value of f's Jacobian (the tangential stretch s(r)). Dividing the
// warped-space distance by this keeps the raymarch from overstepping the
// surface. Returns 1 when projection is off so the math is a pure no-op.
FORCE_INLINE float sphereProjectionDEScale(float3 p, float blend, float radius) {
    if (blend <= 0.0f) { return 1.0f; }
    float r = length(p);
    if (r <= 1e-5f) { return 1.0f; }
    float b = clamp(blend, 0.0f, 0.98f);
    return max((1.0f - b) + b * radius / r, 1e-3f);
}

// === SPACE MODULE: custom space warp seam (built-in Twist + loadable override) ==
// A second composable space-domain transform applied at the dispatch boundary,
// AFTER sphere projection. The ABI is two pure functions:
//   customSpaceWarp(p, strength, param1, param2, param3)        -> warped point
//   customSpaceWarpDEScale(p, strength, param1, param2, param3) -> max-singular-value
// Both MUST be identity / 1.0 when strength<=0 so the feature is dead-code
// eliminated when off. A loaded .threshfx space-warp effect REPLACES the marker
// below with `#define THRESHOLD_CUSTOM_SPACE_WARP` + its own definitions, so the
// built-in defaults here are skipped.
// __CUSTOM_SPACE_WARP__
#ifndef THRESHOLD_CUSTOM_SPACE_WARP
// Default built-in warp: a "Twist" about a configurable axis through a
// configurable origin. The twist angle is proportional to the distance along
// the axis × strength. Isometric only ON the axis — the Jacobian's max
// singular value grows with the lever arm off the axis (see the exact form
// below); returning 1.0 under-divided the march off-axis.
// param1/2/3 carry the origin point; the axis arrives via FractalParams.
FORCE_INLINE float3 customSpaceWarp(float3 p, float strength, float param1, float param2, float param3) {
    if (strength <= 0.0f) { return p; }
    float angle = strength * p.y * 1.5f;
    float c = cos(angle), s = sin(angle);
    return float3(c * p.x - s * p.z, p.y, s * p.x + c * p.z);
}
FORCE_INLINE float customSpaceWarpDEScale(float3 p, float strength, float param1, float param2, float param3) {
    if (strength <= 0.0f) { return 1.0f; }
    // Exact twist σmax for the fixed Y axis: lever arm ρ = |(x, z)|.
    float lever = sqrt(p.x * p.x + p.z * p.z);
    float x = 1.5f * strength * lever;
    float x2 = x * x;
    return max(sqrt(0.5f * (2.0f + x2 + x * sqrt(x2 + 4.0f))), 1.0f);
}
#endif

FORCE_INLINE void applySphericalInversionRay(thread float3 &origin, thread float3 &direction, int mode, float radius) {
    if (mode == 0) { return; }
    float safeRadius = max(radius, 0.2f);
    float3 rayTarget = origin + direction * safeRadius;
    float3 invertedOrigin = sphericalInvertPoint(origin, safeRadius);
    float3 invertedTarget = sphericalInvertPoint(rayTarget, safeRadius);
    float3 invertedDirection = invertedTarget - invertedOrigin;
    if (dot(invertedDirection, invertedDirection) > 1e-8f) {
        origin = invertedOrigin;
        direction = normalize(invertedDirection);
    }
}

// === LIGHTING BLEND: Classic (soft) ↔ Current (vibrance-driven sharp) ===
// The vibrance/softness sun blend is frame-uniform, so it is evaluated once
// per frame on the CPU (RenderPrecompute.makePrecomputedLighting — its
// sunDirSoft/sunDirSharp constants MUST mirror the ones above) and arrives
// in uniforms.precomputedLighting as sunDir / sunDiffuseScale /
// lightIntensity (pre-scaled) / specPower.

// === BOUNDING SPHERE EARLY EXIT ===
// Returns -1 if ray misses sphere, otherwise the distance to start marching.
// This is a "skip empty space before the volume" optimization, so:
//   - Origin outside, ray hits sphere → near-entry distance.
//   - Origin INSIDE the sphere (zoomed in) → 0: there is no empty space to
//     skip, so we must start at the camera. Returning the far intersection
//     here would skip all geometry between the camera and the back wall,
//     punching a growing hole in the center as you zoom in.
inline float rayIntersectBoundingSphere(float3 ro, float3 rd, float3 center, float radius) {
    float3 oc = ro - center;
    float c = dot(oc, oc) - radius * radius;
    if (c < 0.0) return 0.0;  // Origin inside sphere — start marching immediately
    float b = dot(oc, rd);
    float discriminant = b * b - c;
    if (discriminant < 0.0) return -1.0;  // Miss
    float t = -b - sqrt(discriminant);  // Near intersection
    return (t > 0.0) ? t : -1.0;  // Behind the camera → treat as miss
}

// === BOUND TO SPACE (sensed/manual rectangular-room clip) ===
// Positions arrive in a centered, gravity-aligned room coordinate system via
// modelToBoundSpaceMatrix. The room may therefore be translated and yaw-rotated
// relative to the AR session origin. Mode picks which faces bound the volume
// (open faces extend to infinity): 1 = Match Space (closed box), 2 = Ceiling
// Open (walls + floor), 3 = Walls Open (floor + ceiling slab only).

inline void spaceBoundsForMode(float3 size, int mode, thread float3& lo, thread float3& hi) {
    const float kOpen = 1e8f;
    lo = -0.5f * size;
    hi =  0.5f * size;
    if (mode == 2) hi.y = kOpen;
    if (mode == 3) { lo.xz = float2(-kOpen); hi.xz = float2(kOpen); }
}

// Signed Chebyshev-style distance to the room volume (negative inside) — same
// convention as safetyBubbleCubeDistance; drives the bounding-edge fade.
inline float spaceBoundsDistance(float3 posModel, float4x4 modelToBoundSpace,
                                 float3 size, int mode) {
    float3 posRoom = (modelToBoundSpace * float4(posModel, 1.0f)).xyz;
    float3 lo, hi;
    spaceBoundsForMode(size, mode, lo, hi);
    float3 d = max(lo - posRoom, posRoom - hi);
    return max(d.x, max(d.y, d.z));
}

// Room-derived ambient occlusion for Bound to Space. Treats the room's closed
// faces as blockers of the ambient hemisphere: a surface close to a wall AND
// facing it loses ambient light there (contact shadow from the room), while
// surfaces in the open room center are unaffected. Open faces (Ceiling Open /
// Walls Open push bounds to ±1e8 m) contribute nothing because proximity is 0.
// Returns a multiplier for the ambient term, 1 = unoccluded.
inline half roomAmbientOcclusion(float3 posModel, float3 norModel,
                                 float4x4 modelToBoundSpace,
                                 float3 size, int mode, float strength) {
    if (mode == 0 || strength <= 0.001f) return 1.0h;
    float3 posRoom = (modelToBoundSpace * float4(posModel, 1.0f)).xyz;
    float3 norRoom = normalize((modelToBoundSpace * float4(norModel, 0.0f)).xyz);
    float3 lo, hi;
    spaceBoundsForMode(size, mode, lo, hi);

    const float kBand = 1.0f;   // meters of falloff from each face
    // Per-face: outward face normal and distance from the hit to that face.
    const float3 faceN[6] = {
        float3(-1, 0, 0), float3(1, 0, 0),
        float3(0, -1, 0), float3(0, 1, 0),
        float3(0, 0, -1), float3(0, 0, 1)
    };
    const float faceD[6] = {
        posRoom.x - lo.x, hi.x - posRoom.x,
        posRoom.y - lo.y, hi.y - posRoom.y,
        posRoom.z - lo.z, hi.z - posRoom.z
    };

    float occ = 0.0f;
    for (int i = 0; i < 6; i++) {
        float prox = 1.0f - saturate(faceD[i] / kBand);
        if (prox <= 0.0f) continue;
        // Fraction of the ambient hemisphere the face blocks: 1 when the
        // surface faces the wall head-on, 0 when it faces away.
        float facing = saturate(dot(norRoom, faceN[i]) * 0.5f + 0.5f);
        occ += prox * prox * facing;
    }
    // Cap so a corner (3 near faces) can't drive ambient fully black.
    return half(1.0f - saturate(strength) * min(occ, 0.85f));
}

// Clips [t0, t1] against one slab. Division-free-guard for axis-parallel rays:
// those either stay inside the slab forever or never enter it.
inline bool spaceSlabClip(float o, float d, float lo, float hi, thread float& t0, thread float& t1) {
    if (fabs(d) < 1e-8f) return o >= lo && o <= hi;
    float ta = (lo - o) / d;
    float tb = (hi - o) / d;
    t0 = max(t0, min(ta, tb));
    t1 = min(t1, max(ta, tb));
    return true;
}

// Clamps a MODEL-space march interval [startT, endT] to the Bound to Space
// room. The room lives in real meters, so the ray is transformed through
// modelToBoundSpace and the resulting interval is converted back to model
// units (uniform scale => t_room = t_model * |modelToBoundSpace * rD|). Returns
// false when the ray never crosses the room volume — the march can be skipped.
inline bool clampMarchToSpaceBounds(float3 rO, float3 rD,
                                    float4x4 modelToBoundSpace, float3 spaceSize, int mode,
                                    thread float& startT, thread float& endT) {
    if (mode == 0) return true;
    float3 roomO = (modelToBoundSpace * float4(rO, 1.0f)).xyz;
    float3 roomD = (modelToBoundSpace * float4(rD, 0.0f)).xyz;
    float dirScale = length(roomD);
    if (dirScale < 1e-12f) return true;
    roomD /= dirScale;

    float3 lo, hi;
    spaceBoundsForMode(spaceSize, mode, lo, hi);
    float t0 = 0.0f, t1 = 1e8f;
    if (!spaceSlabClip(roomO.x, roomD.x, lo.x, hi.x, t0, t1) ||
        !spaceSlabClip(roomO.y, roomD.y, lo.y, hi.y, t0, t1) ||
        !spaceSlabClip(roomO.z, roomD.z, lo.z, hi.z, t0, t1)) return false;
    if (t1 <= t0) return false;

    startT = max(startT, t0 / dirScale);
    endT = min(endT, t1 / dirScale);
    return endT > startT;
}

// visionOS projection outputs z/w in [0, 1] range directly.
// No transformation needed - just pass through for async timewarp/reprojection.
inline float encodeDepthFromClip(float4 clipPos) {
    return clipPos.z / clipPos.w;
}

// Interleaved Gradient Noise - temporally stable dithering for reprojection
// FORCE_INLINE: Called every pixel in raymarching
// OPTIMIZATION: Precomputed magic constant for time offset
FORCE_INLINE float interleavedGradientNoise(float2 uv, float time) {
    // Combined constants: dot(uv, magic.xy) + time * 0.1
    float noise = fract(52.9829189f * fract(dot(uv, float2(0.06711056f, 0.00583715f))));
    return fract(fma(time, 0.1f, noise));
}
