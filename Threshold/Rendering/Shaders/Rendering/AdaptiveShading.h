// Called by lane 0 only. Publication and the following barrier stay in the kernel.
FORCE_INLINE half2 evaluateAdaptiveSharedShadow(bool didHit, float3 p, float3 spot,
    float3 sunDir, FractalParams params, int shadowIterations,
    constant TileUniforms& uniforms) {
    if (!didHit) return half2(1.0h);
    return half2(
        half(Shadow(p, spot, 0.8, uniforms.foldingLimit, params, shadowIterations,
                    uniforms.fractalType, uniforms.formulaParams, uniforms.shadowsEnabled != 0)),
        half(Shadow(p, sunDir, 0.8, uniforms.foldingLimit, params, shadowIterations,
                    uniforms.fractalType, uniforms.formulaParams, uniforms.shadowsEnabled != 0)));
}

FORCE_INLINE half3 shadeAdaptiveHit(float3 p, float3 nor, float3 marchOrigin,
    float3 marchDir, float adjustedDist, OrbitCache hitCache, FractalParams fractalParams,
    int lodIterations, constant TileUniforms& uniforms, float3 spot, float atten,
    bool shareShadows, bool coherentPacketOn, uint localIndex, half sharedSpot,
    half sharedSun, float3 anchorPos, float3 anchorNormal, int anchorHasHit,
    thread int& packetLayer) {
    half3 col;
    int fractalType = uniforms.fractalType;
    float3 sunDir = uniforms.precomputedLighting.sunDir;
    float sunDiffuseScale = uniforms.precomputedLighting.sunDiffuseScale;
    float lightIntensity = uniforms.precomputedLighting.lightIntensity;
    int shadowIterations = ReducedSecondaryIterations(lodIterations, fractalType, true);
    half shaSpot = 1.0h;
    half shaSun = 1.0h;
    if (shareShadows && anchorHasHit != 0) {
        // Accept thread 0's broadcast shadow for the tile.
        shaSpot = sharedSpot;
        shaSun = sharedSun;

        // === COHERENT-PACKET SHADOW NORMAL-COHERENCE GATE (Stage 3) ===
        // Lanes accept the broadcast ONLY if their (n_i, p_i) is locally coherent
        // with the anchor; otherwise they fall back to a per-pixel Shadow() call,
        // avoiding blocky terminator banding where normals flip between adjacent
        // pixels. Coherent regions keep the full sharing speedup.
        if (coherentPacketOn && localIndex != 0) {
            float normalDot = dot(nor, anchorNormal);
            float dpDist = length(p - anchorPos);
            // Tile diagonal at unit depth ≈ 8 * 1.41 / min(res). Use adjustedDist
            // as a screen-space-ish coherence radius cap.
            float coherenceRadius = max(0.02f, adjustedDist * 0.02f);
            bool normalsCoherent = normalDot > 0.95f && dpDist < coherenceRadius;
            if (!normalsCoherent) {
                FractalParams shadowParamsLocal = makeAdaptiveFractalParams(uniforms, marchOrigin);
                shaSpot = needsLightShadow(spot, nor, lightIntensity)
                    ? half(Shadow(p, spot, 0.8, uniforms.foldingLimit, shadowParamsLocal, shadowIterations, fractalType, uniforms.formulaParams, uniforms.shadowsEnabled != 0)) : 1.0h;
                shaSun = needsLightShadow(sunDir, nor, sunDiffuseScale)
                    ? half(Shadow(p, sunDir, 0.8, uniforms.foldingLimit, shadowParamsLocal, shadowIterations, fractalType, uniforms.formulaParams, uniforms.shadowsEnabled != 0)) : 1.0h;
                // Tag debug overlay layer for shadow fallback (only when not already tagged by warm-start).
                if (packetLayer == 0) packetLayer = 4;
            }
        }
    } else {
        // Shadows not shared (soft lighting), OR this tile's thread 0 missed →
        // pay the per-lane Shadow so silhouette tiles aren't flatly lit.
        FractalParams shadowParams = makeAdaptiveFractalParams(uniforms, marchOrigin);
        shaSpot = needsLightShadow(spot, nor, lightIntensity)
                    ? half(Shadow(p, spot, 0.8, uniforms.foldingLimit, shadowParams, shadowIterations, fractalType, uniforms.formulaParams, uniforms.shadowsEnabled != 0)) : 1.0h;
        shaSun = needsLightShadow(sunDir, nor, sunDiffuseScale)
                    ? half(Shadow(p, sunDir, 0.8, uniforms.foldingLimit, shadowParams, shadowIterations, fractalType, uniforms.formulaParams, uniforms.shadowsEnabled != 0)) : 1.0h;
    }

    col = ColourWithScheme(p, 1.0, uniforms.minDistance, uniforms.fractalScale,
                uniforms.foldingLimit, uniforms.sphereRadius, int(uniforms.colorIterations), uniforms.colorScheme, hitCache);

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
    return col;
}
