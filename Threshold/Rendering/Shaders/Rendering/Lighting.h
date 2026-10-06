// Soft shadow with over-relaxation
// OPTIMIZATION: Combined exit conditions to reduce branches
// GMT-FRACTALS TECHNIQUE: FC_SHADOWS_ENABLED allows compile-time elimination of
// entire shadow computation. When disabled, returns a flat ambient shadow value
// (0.35) — zero Map() evaluations, zero ALU cost.
// Also uses MapDistOnly instead of the full distance estimator — removes all
// fold/trap tracking from shadow rays, saving ~6 ops per iteration per step.
FORCE_INLINE float Shadow(float3 ro, float3 rd, float quality, float foldingLimit, FractalParams params, int iterations, int fractalType = 0, FormulaParams fp = {}, bool shadowsEnabledRuntime = true)
{
    // === COMPILE-TIME SHADOW ELIMINATION (GMT-fractals technique) ===
    // When FC_SHADOWS_ENABLED is defined as false, the compiler eliminates
    // the entire shadow march — zero Map evaluations, zero GPU cost.
    // This is the single biggest perf win during interaction/movement.
    // The runtime flag (Performance-tab "Shadows" toggle) gates the same path
    // frame-uniformly, so disabling shadows returns the flat ambient floor here.
    const bool shadowsEnabled = is_function_constant_defined(FC_SHADOWS_ENABLED) ? FC_SHADOWS_ENABLED : true;
    if (!shadowsEnabled || !shadowsEnabledRuntime) return 0.35f;

    const int qualityMode = is_function_constant_defined(FC_QUALITY_MODE) ? FC_QUALITY_MODE : 0;
    // Return higher minimum for softer shadows (0.35 = more fill light in shadows)
    if (qualityMode >= 2) return 0.35f;
    if (UNLIKELY(quality < kMinQualityForShadows)) return 0.35f;

    float res = 1.0f;
    float t = 0.08f;
    float prevH = 1e10f;

    // When FC_SHADOW_ITERATIONS is defined, steps becomes compile-time constant
    // Compiler unrolls optimally for each quality preset (2-3 steps)
    // OPTIMIZATION: Medium quality uses 2 steps (was 2-3), reduces shadow Map evals by ~33%
    const int steps = is_function_constant_defined(FC_SHADOW_ITERATIONS) ?
        (qualityMode >= 1 ? 2 : 3) :
        int(fma(quality, 2.0f, 1.0f));

    // OPTIMIZATION: Reduce shadow march range for medium quality.
    // Shadows beyond ~2.5 units have minimal visual impact and waste iterations.
    const float shadowRange = (qualityMode >= 1) ? 2.5f : 4.0f;

    for (int i = 0; i < steps && t <= shadowRange && res >= 0.02f; i++)
    {
        float3 p = fma(rd, float3(t), ro);
        // GEOMETRY-ONLY DE (GMT-fractals technique): MapDistOnly strips all
        // fold tracking, orbit traps, and Jacobian from shadow rays.
        // Shadow rays only need distance — the ~6 extra ops per iteration
        // the full distance estimator spends on tracking are pure waste here.
        float h = MapDistOnlyUnified(p, params, foldingLimit, iterations, fractalType, fp);

        // Use rcp for division by t (faster on many GPUs)
        res = min(res, 10.0f * h * (1.0f / t));

        float relax = step(prevH * 0.8f, h);
        float stepDist = mix(h, h * 1.5f, relax);
        t += max(stepDist, 0.15f);
        prevH = h;
    }

    // Clamp to minimum 0.2 for ambient fill - prevents harsh black shadows
    return max(saturate(res), 0.2f);
}

// === Cheap SDF ambient occlusion (iq-style 5-tap march along the normal) ===
// Replaces the old flat "0.15 + hemisphere*0.1" fake-ambient magnitude with a
// real occlusion estimate from the geometry-only DE (same cheap function
// Shadow() uses — no fold/trap/Jacobian tracking). Gated by FC_QUALITY_MODE
// the same way Shadow() gates itself, so low-quality tiers skip the march
// entirely and fall back to a flat (unoccluded) value.
FORCE_INLINE float computeAO(float3 hitPos, float3 nor, FractalParams params, float foldingLimit,
                              int iterations, int fractalType, FormulaParams fp)
{
    const int qualityMode = is_function_constant_defined(FC_QUALITY_MODE) ? FC_QUALITY_MODE : 0;
    if (qualityMode >= 2) return 1.0f;

    float ao = 1.0f;
    float sca = 1.0f;
    for (int i = 0; i < 5; i++) {
        float h = 0.01f + 0.02f * float(i * i);
        float3 p = hitPos + nor * h;
        float d = MapDistOnlyUnified(p, params, foldingLimit, iterations, fractalType, fp);
        ao -= (h - d) * sca;
        sca *= 0.7f;
    }
    // `ao` ends as the visibility term (1 − occlusion): each tap subtracts the
    // (h − d) excess, so open surfaces stay near 1 and creases drop toward 0.
    // Return it directly — the previous `1.0 - ao` re-inverted the term and
    // lit creases while blacking out open surfaces.
    return clamp(ao, 0.0f, 1.0f);
}

// === Shared lighting-assembly helper ===
// Factors out the diffuse+specular+ambient math that was duplicated nearly
// verbatim between the visionOS adaptiveHierarchical8x8 compute kernel and the
// Mac fragmentMain fragment shader. Both call sites already share the heavier
// helpers (computeSpotlight/Shadow/ColourWithScheme/applyFog/applyGlow/
// PostEffectsWithScheme) — this collects only the per-pixel dot-product
// assembly: diffuse spot+sun terms, real-AO-driven ambient, and the
// Schlick-fresnel specular contribution. Shadow computation (including
// visionOS's tile-shared-shadow optimization) stays at each call site; this
// function only consumes the resulting shadow scalars.
// A shadow factor only affects lighting when its diffuse contribution is nonzero.
// Use per-lane normals; a tile anchor's normal cannot decide for its neighbors.
FORCE_INLINE bool needsLightShadow(float3 lightDirection, float3 normal, float intensity)
{
    return dot(lightDirection, normal) > 0.0f && intensity != 0.0f;
}

FORCE_INLINE half3 ShadeSurface(float3 hitPos, float3 nor, float3 viewDir,
                                 float3 spot, float atten, float3 sunDir,
                                 float sunDiffuseScale, float lightIntensity, float specPower,
                                 half shaSpot, half shaSun, half3 baseColor,
                                 ColorSchemeParams colorScheme,
                                 FractalParams params, float foldingLimit,
                                 int iterations, int fractalType, FormulaParams fp,
                                 half roomAmbientOcc = 1.0h)
{
    float attenPow = powr(max(atten, kPowEpsilon), kAttenPower);
    half bri = quantizeCelLight(half(max(dot(spot, nor), 0.0) / attenPow * 0.25 * lightIntensity), colorScheme);
    half briSun = quantizeCelLight(half(max(dot(sunDir, nor), 0.0) * sunDiffuseScale), colorScheme);

    // Real ambient occlusion (optional, blended in by colorScheme.aoStrength).
    // At aoStrength == 0 this is byte-identical to the old flat hemisphere
    // ambient (the default, so existing scenes/presets render unchanged).
    // Hemisphere sky/ground tint is kept as a directional COLOR modulator;
    // the occlusion MAGNITUDE comes from the AO march, blended in to taste.
    half hemisphereAO = half(nor.y * 0.5 + 0.5); // sky/ground ambient tint
    half flatAmbient = 0.15h + hemisphereAO * 0.1h;
    half ambient = flatAmbient;
    if (colorScheme.aoStrength > 0.001f) {
        float aoTerm = computeAO(hitPos, nor, params, foldingLimit, iterations, fractalType, fp);
        ambient = mix(flatAmbient, flatAmbient * half(aoTerm), half(colorScheme.aoStrength));
    }
    // Bound to Space room ambient: contact occlusion from the bounded room's
    // walls/floor/ceiling (1 when off — see roomAmbientOcclusion).
    ambient *= roomAmbientOcc;

    half3 col = (baseColor * bri * shaSpot) + (baseColor * briSun * shaSun) + (baseColor * ambient);

    if (colorScheme.cellShadingEnabled == 0) {
        float NoV = saturate(dot(nor, viewDir));
        float fresnel = fma(1.0f - 0.04f, powr(max(1.0f - NoV, 0.0f), 5.0f), 0.04f);
        float3 Hspot = normalize(spot + viewDir);
        float3 Hsun = normalize(sunDir + viewDir);
        float specSpot = powr(max(dot(nor, Hspot), kPowEpsilon), specPower) * kSpecularIntensity * fresnel;
        float specSun = powr(max(dot(nor, Hsun), kPowEpsilon), specPower) * kSpecularIntensity * fresnel;
        col += half3(specSpot) * shaSpot * bri;
        col += half3(specSun) * shaSun * briSun;
    }

    return col;
}

// === Temporal-reprojection shared helpers (extracted from adaptiveHierarchical8x8) ===
// These centralize three patterns that were previously duplicated across the
// kernel's reprojection, tile-seed, and empty-tile probes. Each is a pure
// function whose float-op sequence is identical to the inlined originals, so
// results are bit-for-bit unchanged.

// Unproject a PHYSICAL drawable pixel to a model-space point on the near ray.
// Mirrors the fragment-shader unprojection exactly, including the asymmetric
// per-eye frustum w-guard used on visionOS.
//
// Under foveation the compositor interprets the drawable color texture as
// variable-density physical space and un-foveates it via a rasterization rate
// map. This kernel writes physical pixels, so a naive linear `pixelCoord /
// resolution` unproject (which assumes physical == screen) is pre-distorted by
// the compositor's inverse rate map — the warp that scales with renderQuality.
// When a valid rate map is bound we decode the physical coordinate to logical/
// screen space first, exactly matching the rasterizer-driven fragment path.
