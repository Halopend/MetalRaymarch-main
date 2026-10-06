// Cached scene result - stores orbit state for reuse in normals/colors
struct SceneResult {
    float2 distGlow;    // .x = distance, .y = glow
    OrbitCache cache;   // Cached orbit state from final hit position
    int steps;          // Fine-march iterations taken to converge (benchmark metric)
    // === CONE-COVERAGE AA (CTSS-lite) ===
    // Set only on a grazed miss when coneCoverageAA is on: the ray missed but its
    // pixel footprint clipped a surface. edgeCoverage is that silhouette's coverage
    // of the pixel (0 = no edge), edgePos/edgeT the closest-approach sample the
    // caller shades and composites over the background. Defaults keep every other
    // SceneResult producer (warm-start, compute tile path) a no-op.
    float  edgeCoverage = 0.0f;
    float3 edgePos = float3(0.0f);
    float  edgeT = 0.0f;
};

// One step of relaxed sphere tracing (Keinert et al.). Returns true when the
// previous over-relaxed step overshot (consecutive unbounding spheres no
// longer overlap): stepLen turns negative to retreat inside the last safe
// sphere and omega drops to 1 for the rest of the ray. On a normal step,
// advances stepLen to h·omega. The caller must skip hit registration on a
// failed step — the sample sits past a possibly-skipped gap.
FORCE_INLINE bool relaxedStepUpdate(float h,
                                    thread float& omega,
                                    thread float& prevH,
                                    thread float& stepLen)
{
    bool sorFail = omega > 1.0f && (h + prevH) < stepLen;
    if (UNLIKELY(sorFail)) {
        stepLen -= omega * stepLen;
        omega = 1.0f;
    } else {
        stepLen = h * omega;
    }
    prevH = h;
    return sorFail;
}

// Per-type over-relaxation ceiling. Over-stepping is only provably safe when
// the DE is a true lower bound: box/sphere-fold estimators qualify, but the
// log-DE types (Mandelbulb / Julia variants) and the fudge-factored Kleinian
// family can locally OVERESTIMATE, where the overstep-failure test cannot
// fire and rays tunnel through thin features. Custom .threshfx DEs are
// arbitrary user code, so they keep the pre-detection 1.2 ceiling that
// existing shared scenes were authored against. With FC_FRACTAL_TYPE set the
// switch folds to a constant at pipeline-compile time.
FORCE_INLINE float relaxedOmegaCap(int type) {
    switch (type) {
    case FractalTypeMandelbox:
    case FractalTypeMenger:
    case FractalTypeOctahedron:
    case FractalTypeMengerSphere:
        // Box/fold DEs tolerate the most over-relaxation; the overstep-failure
        // retreat keeps it hit-safe, so the user's Over-Relaxation slider may push
        // the auto-ramp up to here (default ramp stops at 1.4).
        return 1.6f;
    case FractalTypeMandelbulb:
    case FractalTypeMandelbulbJulia:
    case FractalTypeBoxFoldMandelbulb:
    case FractalTypeQuaternionJulia:
        return 1.1f;
    default: // Kleinian family, custom formulas, future types
        return 1.2f;
    }
}

// === SMART ADVANCE (grazing-aware lead-ahead sphere tracing) ===
// Smart advance reads the gradient of the march itself — the change in the DE
// per unit advance, (h - prevH)/stepLen — to decide when to step further than
// plain sphere tracing would. That ratio is the directional derivative of the
// SDF along the ray: ~ -1 when the ray heads straight at the surface (the DE
// shrinks as fast as we move, so plain tracing is already optimal), ~0 when the
// ray skims almost parallel to the surface (the DE barely changes, so plain
// tracing creeps forward in many tiny steps), and >0 when the surface is
// receding. We "lead ahead" by raising the over-relaxation factor as the ray
// flattens out, escaping the slow grazing creep, while leaving head-on
// convergence untouched.
//
// Grazing ceiling for smart advance. It can push past the conservative head-on
// relaxedOmegaCap because it only over-relaxes where the surface is grazing or
// receding — but it scales WITH the per-type cap so log-DE / Kleinian / custom
// estimators (which can locally overestimate and defeat the overstep test) stay
// proportionally restrained. box→2.2, bulb→1.3, default→1.6.
FORCE_INLINE float smartOmegaCap(int type) {
    return 1.0f + (relaxedOmegaCap(type) - 1.0f) * 3.0f;
}

// One step of smart-advance sphere tracing. Like relaxedStepUpdate (Keinert),
// but the over-relaxation factor is derived per step from the along-ray DE
// gradient instead of a fixed omega: it ramps from 1 (no boost, while clearly
// converging) up to maxOmega (full lead-ahead, while grazing or receding). The
// same overstep-failure test guards it — when the two unbounding spheres of
// radii prevH and h no longer overlap across the step we just took, geometry
// may hide in the gap, so we retreat to the far edge of the last provably-safe
// sphere and set the sticky `gaveUp` flag, dropping the ray to plain tracing for
// the rest of its life (prevents retreat/boost thrash). The caller must skip hit
// registration on a failed step. Returns true on an overstep failure.
FORCE_INLINE bool smartStepUpdate(float h,
                                  float maxOmega,
                                  thread bool& gaveUp,
                                  thread float& prevH,
                                  thread float& stepLen)
{
    // Unlike relaxedStepUpdate (which only tests when omega>1), smart advance
    // tests every step: the boost is adaptive per step and can exceed 1 from the
    // first grazing sample onward, so the overshoot guard must always be armed.
    bool sorFail = (!gaveUp) && (h + prevH) < stepLen;
    if (UNLIKELY(sorFail)) {
        // Retreat. stepLen here still holds the (overshooting) step we just took,
        // from t_prev to the current t. We reassign it to the SIGNED delta
        // (prevH - stepLen), which is negative, so the caller's `t += stepLen`
        // moves the ray back from t to t_prev + prevH — the far edge of the last
        // provably-safe sphere. Never advances forward on a fail.
        stepLen = prevH - stepLen;
        gaveUp = true;
    } else if (gaveUp || stepLen <= 1e-5f) {
        // Plain sphere tracing: after a retreat, and on the cold-start step
        // where prevH/stepLen aren't yet seeded (no valid gradient).
        stepLen = h;
    } else {
        // Along-ray DE gradient: ~ -1 head-on, ~0 grazing, >0 receding.
        float grad = (h - prevH) / stepLen;
        // Ramp 0→1 across grad ∈ [-0.5, 0]: no boost while clearly converging,
        // full lead-ahead once the surface stops rushing toward us.
        float graze = saturate((grad + 0.5f) * 2.0f);
        stepLen = h * mix(1.0f, maxOmega, graze);
    }
    prevH = h;
    return sorFail;
}

// Raymarch that caches orbit state on hit for reuse in normals/colors
FORCE_INLINE SceneResult SceneWithCache(float3 rO, float3 rD, float2 fragCoord, float quality, int maxStepsParam, float glowIntensity, float foldingLimit, FractalParams params, int iterations, float time, int fractalType = 0, FormulaParams fp = {}, int colorIterations = 0, float boundingSphereRadius = 0.0, float3 boundingCenter = float3(0.0), float stepMultiplier = 1.0, float maxRayDistance = kMaxRayDistanceDefault, bool smartAdvance = false, float epsilonScale = 1.0f, float coneMarchScale = 0.0f, float distanceLODFalloff = 0.0f, float warmStartT = -1.0f, int coneCoverageAA = 0, float pixelFootprintPerDist = 0.0f, constant DistanceCacheParams* distCache = nullptr, device atomic_uint* distCacheCounters = nullptr)
{
    SceneResult result;
    result.cache = makeEmptyOrbitCache();
    result.steps = 0;
    int type = is_function_constant_defined(FC_FRACTAL_TYPE) ? FC_FRACTAL_TYPE : fractalType;

    // Fractal distance cache: resolve the bindless grid pointer once. The
    // enable decision is frame-uniform (CPU-gated), so the per-step branch
    // below stays wavefront-coherent. nullptr ⇒ feature fully compiled around.
    device const uchar* dcGrid = (distCache != nullptr && distCache->enabled != 0 && distCache->gridAddress != 0)
        ? reinterpret_cast<device const uchar*>(distCache->gridAddress) : nullptr;
    // Atlas traversal is a one-way coarse phase. Once a ray reaches a cell
    // without a useful conservative bound, stay on the analytic DE instead of
    // paying a cache lookup on every subsequent near-surface step.
    bool distCacheAvailable =
        dcGrid != nullptr && type == FractalTypeMandelbox;
    bool distCacheActive = distCacheAvailable;

    float dither = interleavedGradientNoise(fragCoord, time) * 0.015;
    // Mandelbulb DE returns much smaller values near the surface compared to
    // box-fold fractals.  Start closer to the camera and use a finer hit
    // threshold so thin surface detail is not clipped.
    bool isMandelbulb = (type == FractalTypeMandelbulb || type == FractalTypeMandelbulbJulia ||
                         type == FractalTypeBoxFoldMandelbulb);
    float t = (isMandelbulb ? 0.005 : 0.05) + dither;

    // === CONSERVATIVE CONE COARSE-PREPASS WARM-START ===
    // warmStartT is a provable LOWER BOUND on the entry distance of the nearest
    // surface for this ray (the cone kernel only ever advanced through cones that
    // stayed strictly inside empty space, then backed off a full footprint). We
    // ONLY raise the start — never lower it, never shorten the budget, never touch
    // maxRayDistance or the epsilon — so the march still finds exactly what it
    // would have found, just starting past provably-empty space. Negative = cold.
    if (warmStartT > t) t = warmStartT;

    // === BOUNDING SPHERE PRE-TEST (GMT-fractals technique) ===
    // Skip empty space before the fractal's bounding volume.
    // When boundingSphereRadius > 0, ray-sphere intersect jumps t to the
    // sphere entry point, saving dozens of wasted Map() evaluations in void.
    if (boundingSphereRadius > 0.0) {
        float sphereT = rayIntersectBoundingSphere(rO, rD, boundingCenter, boundingSphereRadius);
        if (sphereT < 0.0) {
            // Ray misses bounding sphere entirely — no fractal geometry possible
            result.distGlow = float2(kRayMissThreshold + 100.0, 0.0);
            return result;
        }
        t = max(t, sphereT);
    }

    float glow = 0.0;

    // When FC_MAX_RAY_STEPS is defined, baseMaxSteps is compile-time constant
    // and compiler can make optimal unrolling decisions per quality preset
    const int baseMaxSteps = is_function_constant_defined(FC_MAX_RAY_STEPS) ? FC_MAX_RAY_STEPS : maxStepsParam;
    int maxSteps = max(int(float(baseMaxSteps) * quality), 4);

    // === RELAXED SPHERE TRACING (Keinert et al., "Enhanced Sphere Tracing") ===
    // Take omega× over-relaxed steps; relaxedStepUpdate() retreats inside the
    // last safe sphere when consecutive unbounding spheres stop overlapping.
    // The ceiling is per fractal type — see relaxedOmegaCap() for why log-DE
    // and Kleinian/custom estimators must stay closer to 1.
    //
    // When smartAdvance is set (a frame-uniform toggle) the march instead reads
    // the along-ray DE gradient each step and leads ahead through grazing/
    // receding regions — see smartStepUpdate(). The branch is uniform across the
    // dispatch so it stays coherent and near-free.
    float omega = clamp(stepMultiplier, 1.0f, relaxedOmegaCap(type));
    // Only meaningful (and only computed) on the smart-advance path.
    float smartCap = smartAdvance ? smartOmegaCap(type) : 1.0f;
    bool gaveUp = false;
    float prevH = 0.0;
    float stepLen = 0.0;

    // CTSS-lite cone-coverage AA: track the closest lateral approach of the
    // surface, measured as the DE value normalized by this ray's pixel footprint
    // radius (coneR = pixelFootprintPerDist·t). A ray that never crosses the tight
    // threshold but whose minConeRatio drops below 1 grazed a surface inside its
    // pixel — a silhouette edge we anti-alias below. All no-ops when coneCoverageAA
    // is 0 (the branch is frame-uniform, so it stays coherent and near-free).
    float minConeRatio = 1e9f;
    float3 edgeP = float3(0.0f);
    float edgeTLocal = 0.0f;

    for(int j = 0; j < maxSteps; j++)
    {
        // Mandelbulb needs ~4x finer threshold (its DE returns much smaller values).
        // The fixed additive floor is scaled by epsilonScale (=1/effectiveScale) so it
        // shrinks with the marched region on deep zoom — without it the floor dominates
        // once the hit distance falls below ~0.6 and fine detail stops resolving.
        float threshold = isMandelbulb
            ? fma(t, 0.0002f, 0.00012f * epsilonScale) + (1.0f - quality) * 0.001f
            : fma(t, 0.0008f, 0.0005f * epsilonScale)  + (1.0f - quality) * 0.003f;
        // Cone marching: accept once the DE is within this ray's projected pixel
        // footprint. coneMarchScale is 0 when off (a no-op floor).
        threshold = max(threshold, coneMarchScale * t);

        float3 p = fma(rD, float3(t), rO);
        // Use unified dispatch for the march loop (no Jacobian overhead)
        // Distance iteration LOD: faraway samples drop fractal iterations (their
        // detail is sub-pixel). effIter == iterations when off (distanceLODFalloff 0).
        int effIter = (distanceLODFalloff > 0.0f) ? max(2, iterations - int(t * distanceLODFalloff)) : iterations;
        // A seed lookup only amortizes when it replaces a sufficiently expensive
        // analytic step. Calibrate the default at 0.8 model units for the
        // 24-iteration path and become progressively more selective for cheaper
        // formulas. A positive host near-band remains an explicit override.
        float cacheAcceptBand = threshold;
        if (distCacheAvailable) {
            float amortizedBand =
                0.8f * (24.0f / float(max(effIter, 1)));
            float configuredBand = distCache->nearBandModel > 0.0f
                ? distCache->nearBandModel
                : amortizedBand;
            cacheAcceptBand = max(configuredBand, threshold);
        }
        // Fractal distance cache: while the baked conservative bound is
        // comfortably above the near band, it IS a valid empty-sphere radius —
        // step by it and skip the analytic DE entirely. Near the surface (or
        // outside the grid, where the sample reads 0) run the exact DE, so the
        // hit test below only ever sees analytic values (nearBand >> threshold).
        // An underestimated h is still a valid unbounding-sphere radius, so the
        // relaxed/smart step logic below stays overshoot-safe unchanged.
        float h;
        float cachedBound = 0.0f;
        bool cacheInGrid = false;
        bool cacheNearGrid = false;
        if (distCacheActive) {
            if (distCacheCounters != nullptr) {
                atomic_fetch_add_explicit(&distCacheCounters[2], 1u, memory_order_relaxed);
            }
            // The atlas stores the CANONICAL, unwarped Mandelbox. Apply the
            // current domain-transform stack to the query point after the fact,
            // exactly as MapUnified does, and divide by its conservative
            // Jacobian stretch. Translation/rotation/model scale already live
            // outside model-space marching and likewise never enter the atlas.
            SpaceTransform atlasTransform = applySpaceTransforms(p, type, params);
            if (distCacheCounters != nullptr) {
                float3 transformedPositive = max(atlasTransform.point, 0.0f);
                float3 transformedNegative = max(-atlasTransform.point, 0.0f);
                atomic_fetch_max_explicit(
                    &distCacheCounters[5], as_type<uint>(transformedPositive.x),
                    memory_order_relaxed);
                atomic_fetch_max_explicit(
                    &distCacheCounters[6], as_type<uint>(transformedNegative.x),
                    memory_order_relaxed);
                atomic_fetch_max_explicit(
                    &distCacheCounters[7], as_type<uint>(transformedPositive.y),
                    memory_order_relaxed);
                atomic_fetch_max_explicit(
                    &distCacheCounters[8], as_type<uint>(transformedNegative.y),
                    memory_order_relaxed);
                atomic_fetch_max_explicit(
                    &distCacheCounters[9], as_type<uint>(transformedPositive.z),
                    memory_order_relaxed);
                atomic_fetch_max_explicit(
                    &distCacheCounters[10], as_type<uint>(transformedNegative.z),
                    memory_order_relaxed);
            }
            float3 cacheCoord =
                (atlasTransform.point - distCache->originModel.xyz) * distCache->invCellModel;
            float cacheDimension = float(distCacheDimension(*distCache));
            cacheInGrid = all(cacheCoord >= 0.0f) &&
                all(cacheCoord < cacheDimension);
            // Keep probing just outside the volume so a camera that starts near
            // a face does not permanently disarm the atlas before entering it.
            // Keep a four-model-unit guard around spatially focused pages.
            // Expressing it in cells makes the guard independent of tier
            // resolution and page extent.
            float guardCells = 4.0f * distCache->invCellModel.x;
            cacheNearGrid = all(cacheCoord >= -guardCells) &&
                all(cacheCoord < cacheDimension + guardCells);
            if (distCacheCounters != nullptr) {
                if (cacheInGrid) {
                    atomic_fetch_add_explicit(
                        &distCacheCounters[3], 1u, memory_order_relaxed);
                }
            }
            cachedBound = distCacheSample(
                atlasTransform.point, *distCache, dcGrid
            ) / max(atlasTransform.deScale, 1e-6f);
        }
        // A lower bound is safe to march by whenever it is above the current
        // hit threshold. At or below that threshold, evaluate the analytic DE
        // so a small lower bound cannot be mistaken for an actual surface hit.
        if (distCacheActive && cachedBound > cacheAcceptBand) {
            if (distCacheCounters != nullptr) {
                atomic_fetch_add_explicit(&distCacheCounters[4], 1u, memory_order_relaxed);
            }
            h = cachedBound;
        } else {
            h = MapUnified(p, params, foldingLimit, effIter, type, fp);
            // Re-arm only after the analytic DE makes a genuinely coarse move.
            // Near the surface, small exact steps keep the atlas off and avoid
            // repeated zero-bound lookups.
            if (distCacheAvailable) {
                float rearmBand = max(
                    cacheAcceptBand,
                    1.0f / distCache->invCellModel.x);
                distCacheActive = h > rearmBand ||
                    (!cacheInGrid && cacheNearGrid);
            } else {
                distCacheActive = false;
            }
        }

        bool sorFail = smartAdvance
            ? smartStepUpdate(h, smartCap, gaveUp, prevH, stepLen)
            : relaxedStepUpdate(h, omega, prevH, stepLen);

        if(UNLIKELY(h < threshold) && !sorFail)
        {
            // Re-iterate with full orbit cache + Jacobian for normals/colors.
            OrbitCache hitCache;
            MapWithOrbitCacheUnified(p, params, foldingLimit, effIter, type, fp, colorIterations, hitCache);
            result.cache = hitCache;
            result.distGlow = float2(t, finalizeGlow(glow));
            result.steps = j;
            return result;
        }

        // Cone-coverage AA: remember the tightest normalized approach on a valid
        // (non-overshoot) step. Skipped entirely when the feature is off.
        if (coneCoverageAA != 0 && !sorFail)
        {
            float coneR = pixelFootprintPerDist * t;
            float ratio = (coneR > 1e-6f) ? (h / coneR) : 1e9f;
            if (ratio < minConeRatio) { minConeRatio = ratio; edgeP = p; edgeTLocal = t; }
        }

        if (UNLIKELY(t > maxRayDistance)) break;

        glow = accumulateGlow(glow, h, glowIntensity);
        t += stepLen;
    }

    // Cone-coverage AA: the march missed, but if its footprint grazed a surface
    // (minConeRatio < 1) record a silhouette edge sample for the caller to shade
    // and composite over the background. Coverage ramps 1 (surface nearly filled
    // the pixel) → 0 (surface just touched the footprint edge). One extra orbit-
    // cache eval, paid only by grazed-miss pixels.
    if (coneCoverageAA != 0 && minConeRatio < 1.0f)
    {
        float cov = 1.0f - smoothstep(0.0f, 1.0f, minConeRatio);
        if (cov > (1.0f / 255.0f))
        {
            int edgeIter = (distanceLODFalloff > 0.0f)
                ? max(2, iterations - int(edgeTLocal * distanceLODFalloff)) : iterations;
            OrbitCache edgeCache;
            MapWithOrbitCacheUnified(edgeP, params, foldingLimit, edgeIter, type, fp, colorIterations, edgeCache);
            result.cache = edgeCache;
            result.edgeCoverage = cov;
            result.edgePos = edgeP;
            result.edgeT = edgeTLocal;
        }
    }

    result.distGlow = float2(kRayMissThreshold + 100.0, finalizeGlow(glow));
    return result;
}

// Raymarch with cache that starts from a known distance (for hierarchical acceleration)
FORCE_INLINE SceneResult SceneWithCacheFromStart(float3 rO, float3 rD, float startT, float2 fragCoord, float quality, int maxStepsParam, float glowIntensity, float foldingLimit, FractalParams params, int iterations, float time, int fractalType = 0, FormulaParams fp = {}, int colorIterations = 0, float stepMultiplier = 1.0, bool smartAdvance = false, float epsilonScale = 1.0f, float coneMarchScale = 0.0f, float distanceLODFalloff = 0.0f)
{
    SceneResult result;
    result.cache = makeEmptyOrbitCache();
    result.steps = 0;
    int type = is_function_constant_defined(FC_FRACTAL_TYPE) ? FC_FRACTAL_TYPE : fractalType;

    float dither = interleavedGradientNoise(fragCoord, time) * 0.01;
    bool isMandelbulb = (type == FractalTypeMandelbulb || type == FractalTypeMandelbulbJulia ||
                         type == FractalTypeBoxFoldMandelbulb);
    float t = max(isMandelbulb ? 0.002 : 0.01, startT - 0.3) + dither;

    float glow = 0.0;
    // Compiler specializes per FC_MAX_RAY_STEPS value
    const int baseMaxSteps = is_function_constant_defined(FC_MAX_RAY_STEPS) ? FC_MAX_RAY_STEPS : maxStepsParam;

    // OPTIMIZATION: When startT comes from temporal reprojection, we're already
    // within ~0.3 units of the surface. The search window is only 2.3 units wide,
    // so we need far fewer steps than the full half-budget. Scale steps by how
    // tight the start is relative to full-range marching.
    // - startT < 1.0 (near camera): likely coarse start, use full half-budget
    // - startT > 1.0 (temporal reproj): tight window, use reduced budget (0.25×)
    float stepScale = (startT > 1.0f) ? 0.25f : 0.5f;
    int maxSteps = max(int(float(baseMaxSteps) * quality * stepScale), 8);
    float endT = startT + 2.0;

    // Relaxed sphere tracing with overstep-failure detection; per-type ceiling
    // (see relaxedOmegaCap for why log-DE/Kleinian/custom stay closer to 1).
    // smartAdvance swaps in the grazing-aware lead-ahead variant (smartStepUpdate).
    float omega = clamp(stepMultiplier, 1.0f, relaxedOmegaCap(type));
    // Only meaningful (and only computed) on the smart-advance path.
    float smartCap = smartAdvance ? smartOmegaCap(type) : 1.0f;
    bool gaveUp = false;
    float prevH = 0.0;
    float stepLen = 0.0;

    for(int j = 0; j < maxSteps; j++)
    {
        // Additive floor scaled by epsilonScale (=1/effectiveScale) so detail keeps
        // resolving on deep zoom (1.0 at base → unchanged).
        float threshold = isMandelbulb
            ? fma(t, 0.00015f, 0.00012f * epsilonScale)
            : fma(t, 0.0006f, 0.0005f * epsilonScale);
        // Cone marching: accept once the DE is within this ray's projected pixel
        // footprint. coneMarchScale is 0 when off (a no-op floor).
        threshold = max(threshold, coneMarchScale * t);
        float3 p = fma(rD, float3(t), rO);
        // Use unified dispatch for the march loop (no Jacobian overhead)
        // Distance iteration LOD: faraway samples drop fractal iterations (their
        // detail is sub-pixel). effIter == iterations when off (distanceLODFalloff 0).
        int effIter = (distanceLODFalloff > 0.0f) ? max(2, iterations - int(t * distanceLODFalloff)) : iterations;
        float h = MapUnified(p, params, foldingLimit, effIter, type, fp);

        bool sorFail = smartAdvance
            ? smartStepUpdate(h, smartCap, gaveUp, prevH, stepLen)
            : relaxedStepUpdate(h, omega, prevH, stepLen);

        if(UNLIKELY(h < threshold) && !sorFail)
        {
            // Re-iterate with full orbit cache for normals/colors.
            OrbitCache hitCache;
            MapWithOrbitCacheUnified(p, params, foldingLimit, effIter, type, fp, colorIterations, hitCache);
            result.cache = hitCache;
            result.distGlow = float2(t, finalizeGlow(glow));
            result.steps = j;
            return result;
        }

        if (UNLIKELY(t > endT)) break;

        glow = accumulateGlow(glow, h, glowIntensity);
        t += stepLen;
    }

    result.distGlow = float2(kRayMissThreshold + 100.0, finalizeGlow(glow));
    return result;
}
