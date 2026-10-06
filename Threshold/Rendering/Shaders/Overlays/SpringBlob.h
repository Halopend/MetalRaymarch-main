// === SPRING BLOB NAVIGATION WIDGET ===
// Screen-space SDF overlay: two spheres connected by a stretchy band.
// Anchor sphere sits at springAnchorNDC; displaced sphere follows spring displacement.
// smin blends them into a single gooey metaball shape that stretches when pulled.

// Smooth minimum for metaball blending (polynomial, k controls blend radius)
FORCE_INLINE float smin(float a, float b, float k) {
    float h = saturate(0.5f + 0.5f * (b - a) / k);
    return mix(b, a, h) - k * h * (1.0f - h);
}

// 2D SDF for the spring blob widget.
// Returns signed distance to the metaball shape in NDC space.
// anchorNDC: rest position, displacementNDC: offset from anchor (from spring physics).
// restRadius: blob radius at rest, stretch: 0-1 normalized stretch amount.
FORCE_INLINE float springBlobSDF(float2 uv, float2 anchorNDC, float2 displacementNDC,
                                  float restRadius, float stretch, float time) {
    // Anchor sphere (fixed)
    float2 anchorPos = anchorNDC;
    float dAnchor = length(uv - anchorPos) - restRadius;

    // Displaced sphere (follows spring displacement)
    float2 displacedPos = anchorNDC + displacementNDC;
    // Displaced sphere shrinks slightly when stretched (mass conservation feel)
    float displacedRadius = restRadius * (1.0f - 0.3f * stretch);
    float dDisplaced = length(uv - displacedPos) - displacedRadius;

    // Blend radius increases with stretch for gooey connection
    float blendK = restRadius * (0.8f + 1.5f * stretch);
    float dBlend = smin(dAnchor, dDisplaced, blendK);

    // Band vibration: damped sine wave along the connection axis
    // Only applies when stretched and creates a subtle wobble on the connecting band
    if (stretch > 0.01f) {
        float2 axis = displacedPos - anchorPos;
        float axisLen = length(axis);
        if (axisLen > 0.001f) {
            float2 axisDir = axis / axisLen;
            float2 perp = float2(-axisDir.y, axisDir.x);
            float2 rel = uv - anchorPos;
            float along = dot(rel, axisDir) / axisLen; // 0 at anchor, 1 at displaced
            float across = dot(rel, perp);
            // Vibration: sine envelope peaks at midpoint, damps at endpoints
            float envelope = sin(along * M_PI_F) * stretch;
            float vibration = sin(along * 12.0f + time * 15.0f) * envelope * restRadius * 0.3f;
            // Shrink the distance slightly where the vibration wave passes
            float bandInfluence = smoothstep(restRadius * 3.0f, 0.0f, abs(across - vibration));
            dBlend -= bandInfluence * restRadius * 0.15f * stretch;
        }
    }

    return dBlend;
}

// Composite the spring blob widget onto the fractal color.
// Renders a translucent glassy blob with rim highlight.
FORCE_INLINE half3 compositeSpringBlob(half3 col, float2 uv, Uniforms uniforms) {
    if (uniforms.springVisible == 0) return col;

    float2 displacement2D = float2(uniforms.springDisplacementX, -uniforms.springDisplacementY);
    float stretch = saturate(uniforms.springStretch / 0.5f); // normalize to 0-1 (maxDisplacement = 0.5)

    float d = springBlobSDF(uv, uniforms.springAnchorNDC, displacement2D,
                            uniforms.springRestRadius, stretch, uniforms.time);

    // Blob fill: translucent with soft edge
    float fillAlpha = smoothstep(0.005f, -0.005f, d);
    // Rim highlight: bright edge
    float rimAlpha = smoothstep(0.008f, 0.002f, abs(d)) * 0.6f;

    // Direction indicator: subtle arrow/gradient showing pull direction
    float dirBrightness = 0.0f;
    if (stretch > 0.05f) {
        float2 displacedPos = uniforms.springAnchorNDC + displacement2D;
        float2 toDisplaced = normalize(displacedPos - uniforms.springAnchorNDC);
        float2 rel = uv - uniforms.springAnchorNDC;
        dirBrightness = saturate(dot(normalize(rel + 0.001f), toDisplaced)) * stretch * 0.3f;
    }

    // Color: cool translucent blue-white with stretch tinting toward warm
    half3 blobColor = mix(half3(0.6h, 0.75h, 1.0h), half3(1.0h, 0.7h, 0.4h), half(stretch));
    half3 rimColor = half3(0.9h, 0.95h, 1.0h);

    half3 result = col;
    result = mix(result, blobColor * (1.0h + half(dirBrightness)), half(fillAlpha * 0.35f));
    result += rimColor * half(rimAlpha);

    return result;
}
