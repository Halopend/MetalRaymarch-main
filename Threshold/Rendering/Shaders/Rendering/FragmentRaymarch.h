// Shared fragment body for Mandelbox rendering

inline FragmentOutput fragmentMain(ColorInOut in,
                                   constant Uniforms& uniforms,
                                   float2 fragCoord,
                                   float time,
                                   device atomic_uint* benchCounters = nullptr,
                                   bool reversedDepth = true)
{
    FragmentOutput output;

    float3 cameraPos = (uniforms.inverseModelViewMatrix * float4(0,0,0,1)).xyz;
    float3 rd = normalize(in.modelPos - cameraPos);

    // === Get fractal type and parameters ===
    int fractalType = uniforms.fractalType;
    float quality = 1.0;
    int lodIterations = max(int(uniforms.fractalIterations), 2);
    int maxSteps = uniforms.maxRaySteps;

    float3 marchOrigin = cameraPos;
    float3 marchDir = rd;
    applySphericalInversionRay(marchOrigin, marchDir, uniforms.sphericalInversionMode, uniforms.sphericalInversionRadius);

    // Use precomputed fractal params (powr() and divisions done on CPU)
    FractalParams fractalParams = makeFractalParamsFromPrecomputed(
        uniforms.precomputedFractal,
        uniforms.minDistance,
        marchOrigin, uniforms.safetyBubbleRadius, uniforms.safetyBubbleEnabled, uniforms.safetyBubbleShape, uniforms.safetyBubbleFadeEnabled, uniforms.safetyBubbleFadeWidth, uniforms.safetyBubbleStrength, uniforms.sphereProjectionBlend, uniforms.sphereProjectionRadius, uniforms.spaceWarpStrength, uniforms.spaceWarpParam1, uniforms.spaceWarpParam2, uniforms.spaceWarpParam3, uniforms.spaceWarpAxis, uniforms.spaceWarpStack.ops, uniforms.spaceWarpStack.count,
        &uniforms.envScrunch,
        &uniforms.handField);

    half3 col = half3(0.0h);
    float2 ret;
    OrbitCache hitCache = makeEmptyOrbitCache();
    // Bounding Fog: 1 = untouched; falls toward 0 as the hit point approaches
    // the bounding-shape boundary (soft fade instead of the hard sphere clip).
    half boundFade = 1.0h;

    SceneResult sceneResult;
    {
        // Bound to Space: clip the march to the room's interval along this ray
        // (start raised to room entry, budget capped at room exit). Rays that
        // never cross the room volume skip the march entirely. A no-op while
        // boundToSpaceMode == 0.
        float marchStartT = -1.0f;
        float marchEndT = uniforms.maxViewDistance;
        if (!clampMarchToSpaceBounds(marchOrigin, marchDir, uniforms.modelToBoundSpaceMatrix,
                                     uniforms.boundSpaceSize, uniforms.boundToSpaceMode,
                                     marchStartT, marchEndT)) {
            sceneResult.distGlow = float2(kRayMissThreshold + 100.0, 0.0);
            sceneResult.cache = makeEmptyOrbitCache();
            sceneResult.steps = 0;
        } else {
            sceneResult = SceneWithCache(marchOrigin, marchDir, fragCoord, quality, maxSteps, uniforms.glowIntensity, uniforms.foldingLimit, fractalParams, lodIterations, time, fractalType, uniforms.formulaParams, int(uniforms.colorIterations), boundingCullSphereRadius(uniforms.boundingSphereRadius, uniforms.boundingShapeType), uniforms.boundingShapeCenter, uniforms.stepMultiplier, marchEndT, uniforms.smartAdvanceEnabled != 0, uniforms.marchEpsilonScale, uniforms.coneMarchScale, uniforms.distanceLODFalloff, marchStartT, uniforms.coneCoverageAAEnabled, uniforms.pixelFootprintPerDist, &uniforms.distCache, uniforms.benchAblate == 99 ? benchCounters : nullptr);
        }
    }
    ret = sceneResult.distGlow;
    hitCache = sceneResult.cache;

    // Bound to Space: reclassify hits outside the room as misses. The clamped
    // march can overshoot a boundary by a step. The 1cm tolerance keeps hits
    // sliced open right at a wall from speckling into misses.
    if (uniforms.boundToSpaceMode != 0 && ret.x < kRayMissThreshold) {
        float3 hitModel = marchOrigin + ret.x * marchDir;
        if (spaceBoundsDistance(hitModel, uniforms.modelToBoundSpaceMatrix,
                                uniforms.boundSpaceSize, uniforms.boundToSpaceMode) > 0.01f) {
            ret.x = kRayMissThreshold + 100.0;
        }
    }

    // Benchmark: accumulate fine-march iterations for converged (hit) rays so the
    // CPU can read back an average steps-to-converge. No-op unless a sweep armed
    // the counter (benchCollectSteps) and bound the buffer.
    if (uniforms.benchCollectSteps != 0 && benchCounters != nullptr && ret.x < kRayMissThreshold) {
        atomic_fetch_add_explicit(&benchCounters[0], (uint)max(sceneResult.steps, 0), memory_order_relaxed);
        atomic_fetch_add_explicit(&benchCounters[1], 1u, memory_order_relaxed);
    }

    // Cone-coverage AA: a ray that missed but whose footprint grazed a surface
    // shades the recorded edge sample and composites it over the background by its
    // coverage (see the fog step below). edgeAA is frame-uniform-gated so it stays
    // coherent; sceneResult.edgeCoverage is 0 unless the feature actually ran.
    bool edgeAA = (uniforms.coneCoverageAAEnabled != 0) && (ret.x >= kRayMissThreshold)
                  && (sceneResult.edgeCoverage > 0.0f);
    float hitDist = edgeAA ? sceneResult.edgeT : ret.x;

    if (ret.x < kRayMissThreshold || edgeAA)
    {
        // Compute hit position and clip-space depth once (used for depth output and debug visualization)
        float3 p = edgeAA ? sceneResult.edgePos : (marchOrigin + ret.x * marchDir);
        float4 clipPos = uniforms.projectionMatrix * uniforms.modelViewMatrix * float4(p, 1.0);
        float depth = encodeDepthFromClip(clipPos);
        output.depth = depth;

        // Benchmark-only shading ablation for perf dissection. The harness sets
        // uniforms.debugHierarchical >= 10 via THRESHOLD_BENCHMARK_ABLATE; it is
        // 0 in normal use and the branch is frame-uniform (no divergence):
        //   10 = flat hits (skip normals + shadows + colour + shade)
        //   11 = skip ColourWithScheme    12 = skip Shadow marches
        //   13 = skip GetNormal (view-facing fake normal)
        const uint benchAblate = uniforms.benchAblate >= 10 ? uniforms.benchAblate : 0;
        if (benchAblate == 10) {
            col = half3(0.6h, 0.6h, 0.6h);
        } else {
        float3 nor = (benchAblate == 13) ? -marchDir
                   : GetNormal(p, hitDist, fractalParams, uniforms.foldingLimit, lodIterations, fractalType, uniforms.formulaParams, hitCache);

        {
            // Use precomputed spotlight position and intensity from CPU
            float4 spotData = computeSpotlight(p, uniforms.precomputedLighting.spotLightPosition);
            float3 spot = spotData.xyz;
            float atten = spotData.w;

            // Blended lighting (precomputed on CPU — frame-uniform)
            float3 sunDir = uniforms.precomputedLighting.sunDir;
            float sunDiffuseScale = uniforms.precomputedLighting.sunDiffuseScale;
            float lightIntensity = uniforms.precomputedLighting.lightIntensity;

            int shadowIterations = ReducedSecondaryIterations(lodIterations, fractalType, true);
            // Shadow params still need per-pixel bubble center, but use precomputed fractal values
            FractalParams shadowParams = makeFractalParamsFromPrecomputed(
                uniforms.precomputedFractal,
                uniforms.minDistance,
                marchOrigin, uniforms.safetyBubbleRadius, uniforms.safetyBubbleEnabled, uniforms.safetyBubbleShape, uniforms.safetyBubbleFadeEnabled, uniforms.safetyBubbleFadeWidth, uniforms.safetyBubbleStrength, uniforms.sphereProjectionBlend, uniforms.sphereProjectionRadius, uniforms.spaceWarpStrength, uniforms.spaceWarpParam1, uniforms.spaceWarpParam2, uniforms.spaceWarpParam3, uniforms.spaceWarpAxis, uniforms.spaceWarpStack.ops, uniforms.spaceWarpStack.count, &uniforms.envScrunch, &uniforms.handField);

            // Shadow marches are skipped when their result is multiplied by an
            // EXACT zero in ShadeSurface: shaSpot only ever scales terms
            // proportional to bri = quantizeCelLight(max(dot(spot,nor),0)/attenPow
            // * 0.25 * lightIntensity) and shaSun to briSun =
            // quantizeCelLight(max(dot(sunDir,nor),0) * sunDiffuseScale), and
            // quantizeCelLight(0) == 0 in both cel modes — so dot(L,n) <= 0 (or a
            // zero light scale) makes the marched value unreachable and the skip
            // is byte-identical, not an approximation. Terminator regions are
            // spatially coherent, so whole waves drop the 2×3-step march.
            bool needSpotShadow = needsLightShadow(spot, nor, uniforms.precomputedLighting.lightIntensity);
            bool needSunShadow = needsLightShadow(sunDir, nor, uniforms.precomputedLighting.sunDiffuseScale);
            half shaSpot = (benchAblate == 12 || !needSpotShadow) ? half(1.0h) : half(Shadow(p, spot, quality, uniforms.foldingLimit, shadowParams, shadowIterations, fractalType, uniforms.formulaParams, uniforms.shadowsEnabled != 0));
            half shaSun = (benchAblate == 12 || !needSunShadow) ? half(1.0h) : half(Shadow(p, sunDir, quality, uniforms.foldingLimit, shadowParams, shadowIterations, fractalType, uniforms.formulaParams, uniforms.shadowsEnabled != 0));

            col = (benchAblate == 11) ? half3(0.6h, 0.6h, 0.6h)
                : ColourWithScheme(p, quality, uniforms.minDistance, uniforms.fractalScale, uniforms.foldingLimit, uniforms.sphereRadius, max(int(uniforms.colorIterations * quality), 2), uniforms.colorScheme, hitCache);

            float3 V = -marchDir;
            half roomAmb = 1.0h;
            if (uniforms.boundToSpaceMode != 0 && uniforms.boundAmbientStrength > 0.001f) {
                roomAmb = roomAmbientOcclusion(p, nor, uniforms.modelToBoundSpaceMatrix,
                                               uniforms.boundSpaceSize,
                                               uniforms.boundToSpaceMode, uniforms.boundAmbientStrength);
            }
            col = ShadeSurface(p, nor, V, spot, atten, sunDir, sunDiffuseScale, lightIntensity,
                                uniforms.precomputedLighting.specPower, shaSpot, shaSun, col,
                                uniforms.colorScheme, fractalParams, uniforms.foldingLimit,
                                lodIterations, fractalType, uniforms.formulaParams, roomAmb);
        }
        // Depth already written at start of this block via clipPos
        }

        // Bounding: clip/fade hits against the selected Bounding Shape (sphere,
        // cube, or a platonic solid — same shape family as the Safety Bubble,
        // reusing its distance function). shapeDist is 0 at the shape's surface,
        // negative inside, positive outside.
        // Mode 0 (Off) hard-clips at the surface. Mode 1 (Ghost Fade) keeps the
        // original fixed outer-third band — translucent, composited via outAlpha
        // below. Mode 2 (Inner Shadow) uses an adjustable band
        // (boundingShadowDepth) and stays opaque.
        if (uniforms.boundingSphereRadius > 0.0f) {
            float shapeDist = safetyBubbleDistance(p, uniforms.boundingShapeCenter, uniforms.boundingSphereRadius, uniforms.boundingShapeType);
            if (uniforms.boundingFogEnabled == 2) {
                float depth = clamp(uniforms.boundingShadowDepth, 0.02f, 0.95f);
                boundFade = half(1.0f - smoothstep(-uniforms.boundingSphereRadius * depth, 0.0f, shapeDist));
            } else if (uniforms.boundingFogEnabled == 1) {
                boundFade = half(1.0f - smoothstep(-uniforms.boundingSphereRadius * 0.35f, 0.0f, shapeDist));
            } else {
                boundFade = shapeDist > 0.0f ? 0.0h : 1.0h;
            }
        }

        // Bound to Space: same edge treatment against the room's walls, in
        // WORLD meters (bands: Ghost Fade 0.35 m, Inner Shadow depth × 2 m).
        // The march is already clipped to the room, so this only softens the
        // slice at the boundary; composes with the shape fade via min().
        if (uniforms.boundToSpaceMode != 0) {
            float spaceDist = spaceBoundsDistance(p, uniforms.modelToBoundSpaceMatrix,
                                                  uniforms.boundSpaceSize, uniforms.boundToSpaceMode);
            half spaceFade;
            if (uniforms.boundingFogEnabled == 2) {
                float depth = clamp(uniforms.boundingShadowDepth, 0.02f, 0.95f);
                spaceFade = half(1.0f - smoothstep(-2.0f * depth, 0.0f, spaceDist));
            } else if (uniforms.boundingFogEnabled == 1) {
                spaceFade = half(1.0f - smoothstep(-0.35f, 0.0f, spaceDist));
            } else {
                spaceFade = spaceDist > 0.0f ? 0.0h : 1.0h;
            }
            boundFade = min(boundFade, spaceFade);
        }
    }
    else
    {
        // A miss must use the active projection's far convention. Keep a small
        // epsilon from the clear value so the `.less` depth test still stores
        // Mac/iPad background color and depth.
        output.depth = reversedDepth ? 1e-7f : (1.0f - 1e-6f);
    }

    // Apply fog, glow, and clamp using helper functions
    half glow = half(ret.y);
    if (edgeAA) {
        // Cone-coverage AA composite: the shaded edge surface (fogged at its own
        // depth) over the background sky (fog at infinity), weighted by coverage.
        // Blending already-fogged colors keeps a distant edge correctly hazed
        // while the uncovered fraction stays pure sky. The plain fog below is
        // skipped for this pixel (edgeAA rays keep ret.x at the miss distance).
        half3 surfCol = applyFog(col, sceneResult.edgeT, uniforms.precomputedFog);
        half3 skyCol  = applyFog(half3(0.0h), kRayMissThreshold, uniforms.precomputedFog);
        col = mix(skyCol, surfCol, half(sceneResult.edgeCoverage));
    } else {
        col = applyFog(col, ret.x, uniforms.precomputedFog);
    }
    col = applyGlow(col, glow);
    col = clampColor(col);

    col = PostEffectsWithScheme(col, half2(in.texCoord), uniforms.colorScheme, uniforms.precomputedAudio, half(uniforms.limitFlash), glow);

    // Bounding Fog: applied before the floor circle / spring blob composite so
    // those overlays stay at full strength. Fades to black in Full immersion;
    // combined with the alpha fade below it fades to passthrough in
    // Partial/Mixed.
    col *= boundFade;

    FloorCircleHit floorHit = evaluateFloorCircle(cameraPos, rd, ret.x, uniforms.floorPlane, uniforms.floorCenterRadius);
    col = compositeFloorCircle(col, floorHit);
    if (floorHit.alpha > 0.0f) {
        float3 floorPoint = cameraPos + rd * floorHit.distance;
        float4 floorClipPos = uniforms.projectionMatrix * uniforms.modelViewMatrix * float4(floorPoint, 1.0);
        output.depth = encodeDepthFromClip(floorClipPos);
    }

    // Spring blob navigation widget (screen-space overlay)
    // texCoord is [0,1] — convert to NDC [-1, 1] for SDF
    float2 blobUV = in.texCoord * 2.0f - 1.0f;
    col = compositeSpringBlob(col, blobUV, uniforms);

    // Final-color edge post effect. Mac/iPad MetalFX frames patch this flag off
    // and apply the same operation after upscale in macBlitFragment, keeping a
    // one-input-pixel outline from expanding into a blocky output line. Placing
    // the native version here keeps ordering consistent across both paths.
    if (uniforms.colorScheme.edgeDetectionEnabled != 0) {
        half luma = dot(col, half3(0.2126h, 0.7152h, 0.0722h));
        half gradient = length(half2(dfdx(luma), dfdy(luma)));
        half threshold = half(uniforms.colorScheme.edgeDetectionThreshold);
        half softness = max(half(uniforms.colorScheme.edgeDetectionSoftness), 0.001h);
        half edge = smoothstep(threshold, threshold + softness, gradient);
        col = mix(col, half3(0.0h), edge * half(uniforms.colorScheme.edgeDetectionStrength));
    }

    // Partial immersion (visionOS): miss rays go transparent so the compositor
    // shows passthrough instead of the black background. RGB keeps the fog/glow
    // contribution — under premultiplied alpha it composites additively over
    // passthrough, preserving the glow halo around the fractal. Floor-circle
    // pixels count as hits.
    float outAlpha = 1.0f;
    if (uniforms.passthroughBackground != 0) {
        if (edgeAA && floorHit.alpha <= 0.0f) {
            // Silhouette edge over passthrough: present at its coverage.
            outAlpha = float(sceneResult.edgeCoverage);
        } else if (ret.x >= kRayMissThreshold && floorHit.alpha <= 0.0f) {
            outAlpha = 0.0f;
        } else {
            // Ghost Fade: hits near the boundary fade to transparent (boundFade
            // is 1 when the fog mode is off/Inner Shadow or the ray missed).
            // Inner Shadow stays opaque — it only darkens RGB above.
            outAlpha = (uniforms.boundingFogEnabled == 2) ? 1.0f : float(boundFade);
        }
    }
    output.color = float4(float3(col), outAlpha);
    return output;
}
