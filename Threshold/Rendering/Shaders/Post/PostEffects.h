// Post effects with color scheme support and dynamic animation
// Consumes precomputed audio aggregates for lightweight audio-reactive modulation.
FORCE_INLINE half3 unpackRGB10(uint packed)
{
    float3 channels = float3(
        packed & 0x3FFu,
        (packed >> 10) & 0x3FFu,
        (packed >> 20) & 0x3FFu
    ) * (1.0f / 1023.0f);
    return half3(channels);
}

half3 PostEffectsWithScheme(half3 rgb, half2 xy, ColorSchemeParams scheme, PrecomputedAudio audio, half limitFlash = 0.0h, half rayGlow = 0.0h)
{
    // Pre-baked audio bands/energy (CPU computed) for reuse
    half bass = half(audio.bands.x);
    half mid = half(audio.bands.y);
    // treble (audio.bands.z) now feeds the hue spin rate on the CPU, not here.
    half beat = half(audio.bands.w);
    half audioEnergy = half(audio.energy.y);

    // === DYNAMIC HUE CYCLING (OPTIONAL EFFECT WITH INTENSITY CONTROL) ===
    // Only process if enabled - uses YIQ color space rotation
    // Intensity parameter allows blending rotated color back with original to prevent overpowering
    if (scheme.hueRotationEnabled) {
        // Phase is pre-integrated on the CPU (speed + treble boost baked into the rate),
        // so dragging the speed slider or a treble transient can't snap the hue here.
        float wrappedAngle = fmod(scheme.hueCyclePhase, 6.28318f);
        half hueAngle = half(wrappedAngle);
        half cosH = cos(hueAngle);
        half sinH = sin(hueAngle);

        // Convert RGB to YIQ
        half3 yiq;
        yiq.x = dot(rgb, half3(0.299h, 0.587h, 0.114h));
        yiq.y = dot(rgb, half3(0.596h, -0.274h, -0.322h));
        yiq.z = dot(rgb, half3(0.211h, -0.523h, 0.312h));

        // Rotate I and Q components
        half newY = fma(yiq.y, cosH, -yiq.z * sinH);
        half newZ = fma(yiq.y, sinH, yiq.z * cosH);

        // Convert back to RGB
        half3 rotated;
        rotated.r = fma(0.956h, newY, fma(0.621h, newZ, yiq.x));
        rotated.g = fma(-0.272h, newY, fma(-0.647h, newZ, yiq.x));
        rotated.b = fma(-1.106h, newY, fma(1.703h, newZ, yiq.x));
        rotated = saturate(rotated);

        // Blend rotated with original based on intensity
        rgb = mix(rgb, rotated, half(scheme.hueRotationIntensity));
    }

    // === PULSE EFFECT (OPTIONAL) ===
    // Rhythmic brightness and saturation variation
    half pulse = 1.0h;
    if (scheme.pulseEnabled) {
        // Phase pre-integrated on the CPU (∫ speed·dt) so changing pulse speed never snaps the wave.
        half pulseWave = 0.5h + 0.5h * sin(half(fmod(scheme.pulseCyclePhase, 6.28318f)));
        // Audio modulates pulse amplitude slightly (beat spikes it)
        half pulseAudio = 1.0h + audioEnergy * 0.35h + beat * 0.25h;
        pulse = 1.0h + half(scheme.pulseAmount) * (pulseWave - 0.5h) * pulseAudio;
    }

    // === SATURATION WITH PULSE ===
    half luma = dot(rgb, half3(0.2126h, 0.7152h, 0.0722h));
    half satMult = half(scheme.saturation) * pulse * (1.0h + bass * 0.35h);
    rgb = mix(half3(luma), rgb, satMult);

    // === BRIGHTNESS AND CONTRAST (ALWAYS APPLIED) ===
    rgb = fma(rgb - half3(0.5h), half3(scheme.contrast), half3(0.5h + scheme.brightness));

    // === GLOW EFFECT (OPTIONAL) ===
    // Build a smoother halo from rayGlow while preserving source hue.
    if (scheme.glowEnabled && scheme.glowIntensity > 0.001f) {
        half intensity = half(scheme.glowIntensity);
        half lumaNow = dot(rgb, half3(0.2126h, 0.7152h, 0.0722h));
        half3 huePreserve = rgb / max(lumaNow, 0.02h);
        half3 haloTint = mix(unpackRGB10(scheme.glowColorRGB10), saturate(huePreserve), 0.45h);
        half glowCore = smoothstep(0.06h, 0.30h, rayGlow);
        half glowTail = rayGlow * rayGlow;
        half glowAmount = (glowCore * (0.35h + 0.90h * intensity)) + (glowTail * (0.15h + 0.65h * intensity));
        rgb = rgb + haloTint * glowAmount;
    }

    // === BLOOM EFFECT (OPTIONAL) ===
    // Bright-pass bloom with soft knee, plus rayGlow assist so dark palettes still bloom.
    if (scheme.bloomEnabled && scheme.bloomStrength > 0.001f) {
        half strength = half(scheme.bloomStrength);
        half lumaNow = dot(rgb, half3(0.299h, 0.587h, 0.114h));
        half threshold = mix(0.52h, 0.22h, strength);
        half knee = 0.18h;
        half brightPass = smoothstep(threshold - knee, threshold + knee, lumaNow);
        half glowAssist = smoothstep(0.04h, 0.35h, rayGlow) * (0.25h + 0.95h * strength);
        half bloomAmount = brightPass * (0.18h + 1.25h * strength) + glowAssist;
        half3 bloomTint = mix(unpackRGB10(scheme.bloomColorRGB10), saturate(rgb + 0.08h), 0.35h);
        rgb = rgb + bloomTint * bloomAmount;
    }

    // === HIGHLIGHTS/EXPOSURE (skip when identity) ===
    if (abs(scheme.highlights) > 0.001f) {
        rgb *= half(1.0f + scheme.highlights);
    }

    // === VIBRANCE (skip when ~0) ===
    if (abs(scheme.vibrance) > 0.001f) {
        half maxChannel = max(rgb.r, max(rgb.g, rgb.b));
        half vibranceBoost = (1.0h - maxChannel) * half(scheme.vibrance) * (1.0h + mid * 0.25h);
        half luma2 = dot(rgb, half3(0.299h, 0.587h, 0.114h));
        rgb = mix(half3(luma2), rgb, 1.0h + vibranceBoost);
    }

    // === SHADOWS LIFT/CRUSH (skip when identity) ===
    if (abs(scheme.shadows) > 0.001f) {
        rgb = fma(half3(scheme.shadows), 1.0h - rgb, rgb);
    }

    // === MIDTONE S-CURVE (skip expensive powr when curve ≈ 0) ===
    // powr() is expensive on GPU — only compute when curve is actually active
    if (abs(scheme.colorCurve) > 0.001f) {
        half curve = half(scheme.colorCurve);
        half exponent = 1.0h / (1.0h + curve * 0.7h);
        half3 delta = rgb - 0.5h;
        rgb = fma(sign(delta), 0.5h * powr(abs(delta) * 2.0h, half3(exponent)), half3(0.5h));
    }

    // Simplified vignette. Strength 1 matches the historical fixed
    // response; 0 is identity, so the effect follows the same zero-is-off
    // convention as the rest of the post-process controls.
    if (scheme.vignetteStrength > 0.001f) {
        half2 q = xy * (1.0h - xy);
        half vignetteBase = max(16.0h * q.x * q.y, kPowEpsilonHalf);
        half vignette = 0.5h + 0.5h * powr(vignetteBase, 0.2h);
        rgb *= mix(1.0h, vignette, half(scheme.vignetteStrength));
    }

    // Limit flash effect - edge glow when parameter hits min/max. The limit
    // flash is deliberately subtle (scaled well below the beat flash): a faint
    // translucent edge cue, not a screen takeover.
    half beatFlash = scheme.beatFlashEnabled ? beat * half(scheme.beatFlashIntensity) : 0.0h;
    half combinedFlash = max(limitFlash * 0.35h, beatFlash);
    if (combinedFlash > 0.01h) {
        half2 edgeDist = abs(xy - 0.5h) * 2.0h;
        half edge = max(edgeDist.x, edgeDist.y);
        half edgeGlow = powr(edge, 2.0h) * combinedFlash;
        half3 flashColor = half3(1.0h, 0.4h, 0.1h);
        rgb = mix(rgb, flashColor, edgeGlow * 0.8h);
    }

    // === DISPLAY MAPPING (SDR body + EDR highlight energy) ===
    // Grading above ran in unbounded working range; only negatives are removed
    // here (NaN guard for powr). The old pipeline hard-clipped (`saturate`)
    // BEFORE the tonemap, which destroyed every glow/bloom/specular value above
    // 1.0 — the filmic shoulder never saw real HDR input.
    rgb = max(rgb, half3(0.0h));
    half peak = max(half(scheme.edrHeadroom), 1.0h);

    // SDR body in [0,1] — pixel-identical to the historical pipeline on SDR
    // displays (presets were authored against it): hard clip, optional ACES
    // blend. The one deliberate change: acesFilm now receives the UNCLAMPED
    // scene value, so tonemapStrength compresses real HDR range instead of
    // reshaping already-clipped pixels.
    half3 sdrClipped = min(rgb, half3(1.0h));
    half3 sdrBody = sdrClipped;
    if (scheme.tonemapStrength > 0.001f) {
        sdrBody = mix(sdrBody, acesFilm(rgb), half(scheme.tonemapStrength));
    }

    // Gamma from scheme (user-tunable artistic display curve) applies to the
    // SDR body exactly as before, keeping the artistic curve
    // display-independent.
    half3 graded = powr(max(sdrBody, half3(kPowEpsilonHalf)), half3(scheme.gamma));

    // EDR: energy above SDR white, soft-clipped into the display's headroom,
    // rides on top of the gamma-graded body. Continuous (zero at rgb == 1),
    // monotonic, and bounded so the result never exceeds `peak`. The max()
    // guards small headrooms, where the soft knee starts below SDR white.
    if (peak > 1.001h) {
        graded += max(softClipToPeak(rgb, peak) - sdrClipped, half3(0.0h));
    }
    return graded;
}

struct FloorCircleHit {
    float alpha;
    float distance;
};

FORCE_INLINE FloorCircleHit evaluateFloorCircle(float3 rayOrigin,
                                                float3 rayDirection,
                                                float sceneDistance,
                                                float4 floorPlane,
                                                float4 floorCenterRadius) {
    FloorCircleHit hit;
    hit.alpha = 0.0f;
    hit.distance = kRayMissThreshold + 100.0f;

    float radius = floorCenterRadius.w;
    if (radius <= 0.001f) return hit;

    float3 planeNormal = normalize(floorPlane.xyz);
    float denominator = dot(planeNormal, rayDirection);
    if (abs(denominator) < 1e-4f) return hit;

    float floorDistance = -(dot(planeNormal, rayOrigin) + floorPlane.w) / denominator;
    float maxVisibleDistance = sceneDistance < kRayMissThreshold ? sceneDistance : kRayMissThreshold;
    if (floorDistance <= 0.02f || floorDistance >= maxVisibleDistance) return hit;

    float3 floorPoint = rayOrigin + rayDirection * floorDistance;
    float3 radialVector = floorPoint - floorCenterRadius.xyz;
    radialVector -= planeNormal * dot(radialVector, planeNormal);
    float radialDistance = length(radialVector);
    float edgeWidth = max(radius * 0.04f, 0.055f);
    float glassFalloff = 1.0f - smoothstep(radius - edgeWidth, radius, radialDistance);
    float thicknessBand = 1.0f - smoothstep(edgeWidth * 0.35f, edgeWidth * 2.4f, abs(radialDistance - radius));
    float innerCaustic = 0.5f + 0.5f * sin((radialDistance / max(radius, 0.001f)) * 24.0f);
    float fill = glassFalloff * (0.18f + innerCaustic * 0.05f);
    float rim = thicknessBand * 0.44f;

    hit.alpha = saturate(fill + rim);
    hit.distance = floorDistance;
    return hit;
}

FORCE_INLINE half3 compositeFloorCircle(half3 color, FloorCircleHit hit) {
    if (hit.alpha <= 0.0f) return color;

    half floorAlpha = half(saturate(hit.alpha));
    half luminance = dot(color, half3(0.2126h, 0.7152h, 0.0722h));
    half3 refractedFractal = mix(color, half3(luminance), 0.18h);
    half3 glassTint = half3(0.58h, 0.86h, 1.0h);
    half3 glassColor = mix(refractedFractal, glassTint, 0.38h);
    half3 highlight = half3(1.0h, 1.0h, 1.0h) * floorAlpha * 0.16h;
    return mix(color, glassColor + highlight, floorAlpha);
}

// =============================================================================
