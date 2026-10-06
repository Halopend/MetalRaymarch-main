// =============================================================================
// COLOR SCHEME FUNCTIONS (must be before color functions that use them)
// =============================================================================

// =============================================================================
// GRADIENT COLORING SYSTEM
// Samples a user-defined gradient from up to MAX_GRADIENT_STOPS color stops.
// Each stop packs color (xyz) + position (w) into a float4.
// =============================================================================

// Sample gradient at position t (0-1) using the stop array
// When loopSmooth is true, the gradient wraps seamlessly: after the last stop it blends
// back into the first stop, eliminating the hard cut when gradient cycles.
FORCE_INLINE half3 sampleGradient(float t, thread const float4 *stops, int stopCount, float smoothing, bool loopSmooth = false)
{
    if (stopCount <= 0) return half3(1.0h);
    if (stopCount == 1) return half3(stops[0].xyz);

    // Clamp t to valid range
    t = saturate(t);

    if (loopSmooth) {
        // Smooth looping: treat the gradient as a ring.
        // We remap stops so the virtual last stop (position=1.0) equals the first stop's color,
        // creating a seamless wrap without modifying the user's stop array.

        // Map t into the ring: each stop occupies a segment, plus one extra
        // wrap-around segment from the last stop back to the first.
        float firstPos = stops[0].w;
        float lastPos = stops[stopCount - 1].w;

        // Compute total span including wrap-around gap
        // The wrap segment goes from lastPos to (1.0 + firstPos) in unwrapped space
        float wrapGap = (1.0f - lastPos) + firstPos;

        // If t is in the wrap-around zone (after last stop or before first stop)
        if (t >= lastPos || t < firstPos) {
            // Distance into wrap zone from lastPos
            float d = (t >= lastPos) ? (t - lastPos) : (t + 1.0f - lastPos);
            float localT = (wrapGap > 0.0f) ? (d / wrapGap) : 0.0f;
            float smoothT = mix(localT, localT * localT * (3.0f - 2.0f * localT), smoothing);
            return mix(half3(stops[stopCount - 1].xyz), half3(stops[0].xyz), half(smoothT));
        }

        // Otherwise, find surrounding stops normally (between first and last)
        for (int i = 0; i < stopCount - 1; i++) {
            if (t >= stops[i].w && t <= stops[i + 1].w) {
                float range = stops[i + 1].w - stops[i].w;
                float localT = (range > 0.0f) ? (t - stops[i].w) / range : 0.0f;
                float smoothT = mix(localT, localT * localT * (3.0f - 2.0f * localT), smoothing);
                return mix(half3(stops[i].xyz), half3(stops[i + 1].xyz), half(smoothT));
            }
        }

        // Fallback: return last stop
        return half3(stops[stopCount - 1].xyz);
    }

    // Non-looping: original behavior
    // Find surrounding stops
    int lower = 0;
    int upper = stopCount - 1;

    for (int i = 0; i < stopCount - 1; i++) {
        if (t >= stops[i].w && t <= stops[i + 1].w) {
            lower = i;
            upper = i + 1;
            break;
        }
    }

    // Handle edge cases
    if (t <= stops[0].w) return half3(stops[0].xyz);
    if (t >= stops[stopCount - 1].w) return half3(stops[stopCount - 1].xyz);

    // Interpolate between surrounding stops
    float range = stops[upper].w - stops[lower].w;
    float localT = (range > 0.0f) ? (t - stops[lower].w) / range : 0.0f;

    // Apply smoothstep for smooth transitions when smoothing > 0
    float smoothT = mix(localT, localT * localT * (3.0f - 2.0f * localT), smoothing);

    return mix(half3(stops[lower].xyz), half3(stops[upper].xyz), half(smoothT));
}

// Compute the mapping value based on the selected color mapping mode
// Returns a value in 0-1 that indexes into the gradient
FORCE_INLINE float computeColorMapping(int mode, float trap, int trapIter, int totalIters,
                                        float3 trapPos, float3 hitPos, float distance,
                                        float3 normal, float gradientRepeat, float gradientOffset)
{
    float t = 0.0f;

    switch (mode) {
        case 0: // Orbit Trap (default - same as legacy)
            t = sqrt(saturate(trap));
            break;
        case 1: // Iterations - normalized iteration count
            t = float(trapIter) / float(max(totalIters, 1));
            break;
        case 2: // Z-Depth - distance from camera
            t = saturate(distance * 0.1f); // Normalize to reasonable range
            break;
        case 3: // Angle - polar angle of trap position
            t = atan2(trapPos.y, trapPos.x) * 0.15915494f + 0.5f; // Normalize to 0-1
            break;
        case 4: // Normal - surface normal direction
            t = saturate(normal.y * 0.5f + 0.5f); // Map normal.y from [-1,1] to [0,1]
            break;
        case 5: // Blended - mix of orbit trap + iteration
        {
            float trapT = sqrt(saturate(trap));
            float iterT = float(trapIter) / float(max(totalIters, 1));
            t = trapT * 0.6f + iterT * 0.4f;
            break;
        }
        default:
            t = sqrt(saturate(trap));
            break;
    }

    // Apply repeat and offset
    t = fract(t * gradientRepeat + gradientOffset);

    return t;
}

// Neon orbit trap coloring - uses scheme palette colors for distinct looks
// trapMin: distance to orbit trap (0 = close, 1 = far)
// trapIter: normalized iteration depth
// trapAngle: angle-based variation
// Generates procedural neon colors from hue frequency/offset (no palette needed)
FORCE_INLINE half3 applyNeonColorScheme(half trapMin, half trapIter, half trapAngle, ColorSchemeParams scheme)
{
    half d = saturate(trapMin);
    half it = saturate(trapIter);

    // Brightness: sharp glow falloff from trap surface
    half glow = pow(1.0h - d, half(scheme.glowSharpness));

    // Generate neon colors procedurally from hue cycling
    half colorPhase = fract(it * half(scheme.hueFrequency) * 0.5h + half(scheme.hueOffset));

    // Convert hue phase to RGB via HSV (saturation=1, value=1)
    half3 baseColor = hsv2rgb(colorPhase, 1.0h, 1.0h);

    // Optional soft banding - branchless multiply
    half bandActive = step(0.1h, half(scheme.bandFrequency));
    half band = sin(d * half(scheme.bandFrequency) * 3.14159h);
    half bandEffect = 1.0h - bandActive * 0.2h * (1.0h - band * band);

    // Saturation boost for neon effect
    half sat = pow(0.9h, half(scheme.saturationPower));

    // Final color: base color * glow * banding
    half3 rgb = baseColor * glow * bandEffect;

    // Boost saturation by pushing away from gray
    half luma = dot(rgb, half3(0.299h, 0.587h, 0.114h));
    rgb = mix(half3(luma), rgb, 1.0h + sat);

    return saturate(rgb);
}

// =============================================================================
// ADDITIONAL COLOR SCHEME FUNCTIONS
// =============================================================================

// =============================================================================
// ORBIT CACHE SYSTEM - Dramatic reduction in redundant Map() calls
// =============================================================================
//
// PROBLEM: For each pixel, we call Map() excessively:
//   - Raymarch: ~60-100 calls × 8-15 iterations = 480-1500 inner loops
//   - Normals: 4 calls × 8-15 iterations = 32-60 inner loops
//   - Colors: 1 call × 8-15 iterations = 8-15 inner loops
//   - Shadows: 6+ calls × 6-12 iterations = 36-72 inner loops
//   TOTAL: ~600-1700 inner iteration loops PER PIXEL
//
// SOLUTION: Cache the final orbit state from raymarch and reuse for normals/colors
// This eliminates ~70% of redundant iteration loops by:
//   1. Storing orbit state (p, p0, dr) from final raymarch hit
//   2. Computing normals analytically from cached Jacobian approximation
//   3. Computing colors directly from cached orbit trap values
//
//
// =============================================================================

// Cached orbit state from Mandelbox iteration
// Stores everything needed to compute normals and colors
// without re-iterating the fractal
struct OrbitCache {
    // === BASIC ORBIT STATE ===
    float4 p;           // Final iterated position (xyz) and derivative scale (w)
    float trap;         // Minimum r² encountered (orbit trap for coloring)
    float distance;     // Computed distance estimate
    int iterationsUsed; // How many iterations were actually performed
    bool valid;         // Whether cache contains valid data

    // === EXTENDED: Trap iteration tracking for neon coloring ===
    int trapIteration;     // Which iteration had the minimum trap
    float3 trapPosition;   // Position at minimum trap (for angle-based coloring)

    // === ANALYTIC JACOBIAN for normal computation ===
    // Accumulated derivative of the Mandelbox iteration w.r.t. input position.
    // Avoids 3 extra Map() calls for finite-difference normals.
    float3x3 jacobian;     // dF/dp0 accumulated through iteration chain rule
    bool hasJacobian;      // Whether jacobian was computed
};

// Create empty/invalid cache
FORCE_INLINE OrbitCache makeEmptyOrbitCache() {
    OrbitCache cache;
    cache.valid = false;
    cache.trap = 1.0f;
    cache.distance = kRayMissThreshold;
    cache.trapIteration = 0;
    cache.trapPosition = float3(0.0f);
    cache.jacobian = float3x3(1.0f);
    cache.hasJacobian = false;
    return cache;
}

// Unified colour function - uses cached orbit data when available, otherwise iterates
// Supports all color modes including neon
half3 ColourWithScheme(float3 pos, float quality, float minRad2Val, float fractalScale, float foldingLimit, float sphereRadius, int colorIters, ColorSchemeParams scheme, OrbitCache cache = {})
{
    float4 p;
    float trap;
    int trapIter;
    float3 trapPos;
    int steps;

    // Use function constant when defined for compile-time loop unrolling
    // This allows the compiler to specialize the loop when colorIterations is known
    const int baseColorIters = is_function_constant_defined(FC_COLOR_ITERATIONS)
        ? FC_COLOR_ITERATIONS
        : colorIters;

    if (cache.valid) {
        // Use cached orbit state
        p = cache.p;
        trap = cache.trap;
        trapIter = cache.trapIteration;
        trapPos = cache.trapPosition;
        steps = cache.iterationsUsed;
    } else {
        // Compute orbit state
        float4 scale = float4(fractalScale) / minRad2Val;
        scale.w = abs(scale.w);
        float sphereRadiusSq = sphereRadius * sphereRadius;

        p = float4(pos, 1.0);
        float4 p0 = p;
        trap = 1.0;
        float minTrap = 1.0;
        trapIter = 0;
        trapPos = pos;

        // Scale by quality (runtime), but base is specialized per pipeline when FC is defined
        steps = max(int(float(baseColorIters) * quality), 2);
        for (int i = 0; i < steps; i++)
        {
            p.xyz = clamp(p.xyz, -foldingLimit, foldingLimit) * 2.0 - p.xyz;
            float r2 = dot(p.xyz, p.xyz);
            p.xyz *= clamp(1.0 / max(r2, sphereRadiusSq), 1.0, 1.0/sphereRadiusSq);
            p.xyz = p.xyz * scale.xyz + p0.xyz;

            // Track orbit trap with iteration and position
            if (r2 < minTrap) {
                minTrap = r2;
                trapIter = i;
                trapPos = p.xyz;
            }
            trap = min(trap, r2);
        }
    }

    // === NEON MODE CHECK ===
    // Use function constant when defined to eliminate neon code path entirely
    const bool neonEnabled = is_function_constant_defined(FC_NEON_MODE_ENABLED)
        ? FC_NEON_MODE_ENABLED
        : (scheme.neonIntensity > 0.01f);

    // === GRADIENT COLORING SYSTEM ===
    if (scheme.gradientStopCount > 0) {
        // Compute the gradient mapping value based on the selected mode
        // Note: normal is approximated from trap position for this path
        float3 approxNormal = normalize(trapPos);
        float mappingT = computeColorMapping(
            scheme.colorMappingMode,
            trap, trapIter, steps,
            trapPos, pos, 0.0f,
            approxNormal,
            scheme.gradientRepeat,
            scheme.gradientOffset
        );

        half3 gradColor = sampleGradient(mappingT, scheme.gradientStops, scheme.gradientStopCount, scheme.gradientSmoothing, scheme.gradientLoopSmooth != 0);

        // If neon mode is also active, blend gradient with neon
        if (neonEnabled && scheme.neonIntensity > 0.01f) {
            half trapMin = half(sqrt(trap));
            half trapIterNorm = half(float(trapIter) / float(steps));
            half trapAngle = half(atan2(trapPos.y, trapPos.x) * 0.15915494f + 0.5f);
            half3 neonColor = applyNeonColorScheme(trapMin, trapIterNorm, trapAngle, scheme);
            return mix(gradColor, neonColor, half(scheme.neonIntensity));
        }

        return gradColor;
    }

    // Fallback: no gradient stops available — return white
    return half3(1.0h);
}

// === MapWithOrbitCache ===
//
// Lean orbit tracking: Jacobian + trap values (normals + colors).
FORCE_INLINE float MapWithOrbitCache(float3 pos, FractalParams params, float foldingLimit,
                                     int iterations, thread OrbitCache& cache,
                                     bool applyWorldFields = true)
{
    float4 p = float4(pos, 1.0);
    float4 p0 = p;

    float invSphereRadiusSq = 1.0f / params.sphereRadiusSq;
    float trap = 1.0f;
    int trapIter = 0;
    float3 trapPos = pos;

    // Analytic Jacobian for zero-cost normals
    float3x3 J = float3x3(1.0f);

    const int loopCount = is_function_constant_defined(FC_FRACTAL_ITERATIONS) ? FC_FRACTAL_ITERATIONS : iterations;

    // Sphere projection alters the fold result, so the analytic Jacobian below no
    // longer matches the (projected) distance field. When it's active we run a
    // projection-aware loop without Jacobian accumulation and flag the cache so
    // GetNormal falls back to finite differences over THIS now-projected map —
    // keeping normals/colors consistent with the rendered silhouette. The
    // no-projection path is byte-for-byte unchanged (same Jacobian, zero cost).
    bool useProj = FC_SPHERE_PROJECTION_ON && params.sphereProjBlend > 0.0f;
    if (useProj) {
        float projBlend = params.sphereProjBlend;
        float projRadius = params.sphereProjRadius;
        for (int i = 0; i < loopCount; i++) {
            p.xyz = fma(clamp(p.xyz, -foldingLimit, foldingLimit), float3(2.0), -p.xyz);
            float r2 = dot(p.xyz, p.xyz);
            if (r2 < trap) { trap = r2; trapIter = i; trapPos = p.xyz; }
            float t = clamp(1.0f / max(r2, params.sphereRadiusSq), 1.0f, invSphereRadiusSq);
            p *= t;
            p.xyz = mix(p.xyz, mapProjectToSphere(p.xyz, projRadius), projBlend);
            p = fma(p, params.scale, p0);
        }
    } else {
        for (int i = 0; i < loopCount; i++) {
            // --- Box fold with Jacobian ---
            float3 pOld = p.xyz;
            p.xyz = fma(clamp(p.xyz, -foldingLimit, foldingLimit), float3(2.0), -p.xyz);

            float3 boxDiag = select(float3(-1.0f), float3(1.0f),
                                   abs(pOld.xyz) < float3(foldingLimit));
            J[0] *= boxDiag;
            J[1] *= boxDiag;
            J[2] *= boxDiag;

            // --- Sphere fold with Jacobian ---
            float r2 = dot(p.xyz, p.xyz);
            if (r2 < trap) { trap = r2; trapIter = i; trapPos = p.xyz; }

            float t = clamp(1.0f / max(r2, params.sphereRadiusSq), 1.0f, invSphereRadiusSq);

            J *= t;
            p *= t;

            // --- Scale + translate with Jacobian ---
            float s = params.scale.x;
            p = fma(p, params.scale, p0);
            J = s * J;
            J[0][0] += 1.0f;
            J[1][1] += 1.0f;
            J[2][2] += 1.0f;
        }
    }

    float d = (length(p.xyz) - params.absScalem1) / p.w - params.absScalePow;

    if (applyWorldFields) {
        d = applySafetyBubble(d, pos, params);
        d = applyHandAttraction(d, pos, params);
    }

    cache.p = p;
    cache.trap = trap;
    cache.distance = d;
    cache.iterationsUsed = loopCount;
    cache.valid = true;
    cache.trapIteration = trapIter;
    cache.trapPosition = trapPos;
    cache.jacobian = J;
    cache.hasJacobian = !useProj;

    return d;
}

// Unified orbit-tracking dispatch: Mandelbox uses MapWithOrbitCache (with Jacobian),
// non-Mandelbox uses FractalDE_WithOrbit and populates the OrbitCache from OrbitData.
FORCE_INLINE float MapWithOrbitCacheUnified(float3 pos, FractalParams params, float foldingLimit,
                                             int iterations, int fractalType, FormulaParams fp,
                                             int colorIterations, thread OrbitCache& cache) {
    int type = is_function_constant_defined(FC_FRACTAL_TYPE) ? FC_FRACTAL_TYPE : fractalType;
    // Space transforms applied uniformly; the orbit trap (coloring) and the cached
    // center distance (used by GetNormal) are evaluated in the same warped space
    // as the marching DE. No-op when off.
    SpaceTransform w = applySpaceTransforms(pos, type, params);
    if (type == FractalTypeMandelbox) {
        float d = MapWithOrbitCache(
            w.point, params, foldingLimit, iterations, cache, false) / w.deScale;
        d = applySafetyBubble(d, pos, params);
        d = applyHandAttraction(d, pos, params);
        if (params.spaceWarpStrength > 0.0f || params.spaceWarpCount > 0
            || worldFieldsMayAlterDistance(pos, params)) {
            // The analytic Jacobian in `cache` is now in warped space — invalidate
            // it so GetNormal uses the (correct) warped finite-difference path.
            // The world-fields check is position-aware: this Map is only called
            // at hit points, and GetNormal re-evaluates the same predicate at
            // the same pos, so the two gates always agree.
            cache.hasJacobian = false;
        }
        // The base evaluator cached its raw, pre-scale distance. Downstream
        // normal probes must compare against the final composed model-space DE.
        cache.distance = d;
        return d;
    }

    // Non-Mandelbox: use formula orbit tracking.
    OrbitData orbit;
    float d = FractalDE_WithOrbit(w.point, type, fp, iterations, colorIterations, orbit) / w.deScale;

    // Apply safety bubble to non-Mandelbox fractals
    d = applySafetyBubble(d, pos, params);
    d = applyHandAttraction(d, pos, params);

    // Populate OrbitCache from OrbitData for compatibility with coloring/normals
    cache.p = float4(orbit.finalP, 1.0f);
    cache.trap = orbit.trap;
    cache.distance = d;
    cache.iterationsUsed = orbit.iterationsUsed;
    cache.valid = true;
    cache.trapIteration = orbit.trapIteration;
    cache.trapPosition = orbit.trapPosition;
    // No analytic Jacobian for formula types — normals will use finite differences
    cache.jacobian = float3x3(1.0f);
    cache.hasJacobian = false;

    return d;
}

FORCE_INLINE int ReducedSecondaryIterations(int iterations, int fractalType, bool forShadow = false)
{
    int type = is_function_constant_defined(FC_FRACTAL_TYPE) ? FC_FRACTAL_TYPE : fractalType;
    if (type == FractalTypeMandelbulb || type == FractalTypeMandelbulbJulia ||
        type == FractalTypeBoxFoldMandelbulb) {
        return max(forShadow ? ((iterations + 2) / 3) : ((iterations + 1) / 3), 2);
    }
    return max((iterations * 2) / 5, 3);
}

FORCE_INLINE float3 ApproximateMandelbulbNormal(float3 pos, float distance, FractalParams params,
                                                float foldingLimit, int iterations, FormulaParams fp,
                                                float cachedDistance, OrbitCache cache)
{
    float3 escapeDir = cache.p.xyz;
    float escapeLen2 = dot(escapeDir, escapeDir);
    if (escapeLen2 <= 1e-8f) {
        escapeDir = pos;
        escapeLen2 = dot(escapeDir, escapeDir);
    }

    float3 baseNormal = (escapeLen2 > 1e-8f)
        ? escapeDir * rsqrt(escapeLen2)
        : float3(0.0f, 1.0f, 0.0f);

    float3 upAxis = (abs(baseNormal.y) < 0.92f) ? float3(0.0f, 1.0f, 0.0f) : float3(1.0f, 0.0f, 0.0f);
    float3 tangentX = cross(upAxis, baseNormal);
    tangentX *= rsqrt(dot(tangentX, tangentX) + kPowEpsilon);
    float3 tangentY = cross(baseNormal, tangentX);

    int normalIters = ReducedSecondaryIterations(iterations, FractalTypeMandelbulb, false);
    float e = max(distance * 0.00075f, 0.00012f);
    float invE = 1.0f / max(e, kPowEpsilon);

    float dX = MapUnified(pos + tangentX * e, params, foldingLimit, normalIters, FractalTypeMandelbulb, fp);
    float dY = MapUnified(pos + tangentY * e, params, foldingLimit, normalIters, FractalTypeMandelbulb, fp);

    float3 gradient = baseNormal;
    gradient += tangentX * ((dX - cachedDistance) * invE * 0.35f);
    gradient += tangentY * ((dY - cachedDistance) * invE * 0.35f);
    return gradient * rsqrt(dot(gradient, gradient) + kPowEpsilon);
}

// Compute normal using cached orbit state
// Three paths, in priority order:
//   1. Analytic Jacobian (cache.hasJacobian) — ZERO extra Map() calls
//      Normal = normalize(J^T * normalize(p.xyz))
//      where J = dF/dp0 accumulated during MapWithOrbitCache iteration
//   2. Cached center distance — 3 extra Map() calls with reduced iterations
//   3. Standard finite differences — 4 Map() calls with full iterations
FORCE_INLINE float3 GetNormal(float3 pos, float distance, FractalParams params, float foldingLimit, int iterations, int fractalType, FormulaParams fp = {}, OrbitCache cache = {})
{
    int type = is_function_constant_defined(FC_FRACTAL_TYPE) ? FC_FRACTAL_TYPE : fractalType;
    const bool worldFieldsActive = worldFieldsMayAlterDistance(pos, params);

    if (cache.hasJacobian && type == FractalTypeMandelbox && !worldFieldsActive) {
        // === ANALYTIC JACOBIAN PATH — no extra Map() calls ===
        float3 pDir = cache.p.xyz * rsqrt(dot(cache.p.xyz, cache.p.xyz) + kPowEpsilon);
        float3 gradient = float3(
            dot(cache.jacobian[0], pDir),
            dot(cache.jacobian[1], pDir),
            dot(cache.jacobian[2], pDir)
        );
        return gradient * rsqrt(dot(gradient, gradient) + kPowEpsilon);
    } else if ((type == FractalTypeMandelbulb || type == FractalTypeMandelbulbJulia)
               && cache.valid && params.sphereProjBlend <= 0.0f
               && params.spaceWarpStrength <= 0.0f && params.spaceWarpCount <= 0
               && !worldFieldsActive) {
        // Mandelbulb-specific fast path: use cached escape direction as the base
        // normal and refine it with only two tangent-space DE probes. Skipped
        // when sphere projection is active so the warped finite-difference path
        // (below) produces correct normals on the projected surface.
        return ApproximateMandelbulbNormal(pos, distance, params, foldingLimit, iterations, fp, cache.distance, cache);
    } else if (cache.valid && type == FractalTypeMandelbox) {
        // Fallback: use cached center distance, reduced iterations.
        int normalIters = ReducedSecondaryIterations(iterations, type, false);
        float e = max(distance * 0.0005f, 0.0001f);
        // Probe the same final composed field as the primary march. In
        // particular, Environment Scrunch stays anchored in original model/world
        // space instead of being sampled at the warped Mandelbox coordinates.
        // Use the same reduced iteration count for center and probes. Comparing
        // reduced probes against the full-iteration cached center injects a
        // constant offset into every gradient component.
        float d0 = MapUnified(pos, params, foldingLimit, normalIters, type, fp);
        float dx = MapUnified(pos + float3(e, 0, 0), params, foldingLimit,
                              normalIters, type, fp);
        float dy = MapUnified(pos + float3(0, e, 0), params, foldingLimit,
                              normalIters, type, fp);
        float dz = MapUnified(pos + float3(0, 0, e), params, foldingLimit,
                              normalIters, type, fp);

        float3 gradient = float3(dx - d0, dy - d0, dz - d0);
        return gradient * rsqrt(dot(gradient, gradient) + kPowEpsilon);
    } else if (type != FractalTypeMandelbox && cache.valid) {
        // Non-Mandelbox with cached center distance: 3 lean _Dist calls
        // with reduced iterations (40% of full).  The cache already holds
        // the center DE from the hit evaluation — reuse it.
        int normalIters = ReducedSecondaryIterations(iterations, type, false);
        float e = max(distance * 0.0005f, 0.0001f);
        // Space module: warp the probe points (sphere projection then custom warp)
        // to match the marching DE. The cached center distance is post-scale;
        // recover the unscaled warped center (d0 × combined scale) so the
        // finite-difference gradient is consistent. Reduces to the original code
        // when both warps are off.
        float blend = params.sphereProjBlend;
        float prad = params.sphereProjRadius;
        if (worldFieldsActive) {
            // Environment, hand, and safety fields are composed outside the raw
            // formula DE. Probe MapUnified so normals follow their clipped or
            // generated surfaces instead of the underlying fractal alone.
            float d0 = MapUnified(pos, params, foldingLimit, normalIters, type, fp);
            float3 gradient = float3(
                MapUnified(pos + float3(e,0,0), params, foldingLimit, normalIters, type, fp) - d0,
                MapUnified(pos + float3(0,e,0), params, foldingLimit, normalIters, type, fp) - d0,
                MapUnified(pos + float3(0,0,e), params, foldingLimit, normalIters, type, fp) - d0
            );
            return gradient * rsqrt(dot(gradient, gradient) + kPowEpsilon);
        }
        float d0;
        if (type == FractalTypeCustom) {
            // Custom embedded DEs often run at low iteration counts (e.g. ported
            // Fragmentarium fractals) and may not have converged at `normalIters`.
            // Using the FULL-iteration cached center (cache.distance) as d0 while
            // the probes run at the reduced count injects a roughly
            // position-constant offset Δ = DE(reduced) − DE(full) into all three
            // finite-difference components equally, collapsing the normal toward a
            // constant direction → flat / "plastic" shading with no depth.
            // Evaluate the center at the SAME reduced count as the probes so Δ
            // cancels and the gradient reflects the true surface normal. (Built-in
            // formulas converge by `normalIters`, so they keep the cheaper cached
            // d0 path below — no behavior change and no extra DE eval for them.)
            d0 = FractalDE_Dispatch(applySpaceWarp(applySphereProjectionDomain(pos, blend, prad), params), type, fp, normalIters);
        } else {
            d0 = cache.distance * sphereProjectionDEScale(pos, blend, prad)
                 * applySpaceWarpDEScale(applySphereProjectionDomain(pos, blend, prad), params);
        }
        float3 gradient = float3(
            FractalDE_Dispatch(applySpaceWarp(applySphereProjectionDomain(pos + float3(e,0,0), blend, prad), params), type, fp, normalIters) - d0,
            FractalDE_Dispatch(applySpaceWarp(applySphereProjectionDomain(pos + float3(0,e,0), blend, prad), params), type, fp, normalIters) - d0,
            FractalDE_Dispatch(applySpaceWarp(applySphereProjectionDomain(pos + float3(0,0,e), blend, prad), params), type, fp, normalIters) - d0
        );
        return gradient * rsqrt(dot(gradient, gradient) + kPowEpsilon);
    } else {
        // Fallback: 4 Map calls with full iterations
        float e = distance * 0.001;
        float d = MapUnified(pos, params, foldingLimit, iterations, type, fp);
        float3 gradient = float3(
            MapUnified(pos + float3(e,0,0), params, foldingLimit, iterations, type, fp) - d,
            MapUnified(pos + float3(0,e,0), params, foldingLimit, iterations, type, fp) - d,
            MapUnified(pos + float3(0,0,e), params, foldingLimit, iterations, type, fp) - d
        );
        return gradient * rsqrt(dot(gradient, gradient) + kPowEpsilon);
    }
}
