FORCE_INLINE float edgeLumaAt(texture2d_array<float, access::read> texture,
                              int2 q,
                              uint eye)
{
    int x = clamp(q.x, 0, int(texture.get_width()) - 1);
    int y = clamp(q.y, 0, int(texture.get_height()) - 1);
    float3 c = texture.read(uint2(x, y), eye).rgb;
    return dot(c, float3(0.2126f, 0.7152f, 0.0722f));
}

// Sliding-window luminance edge pass for the adaptive compute renderer.
// The window radius is user-controlled (1...3). We read completed color from
// one texture and write into a separate texture so there is no read/write race.
kernel void edgeDetectSlidingWindow(
    uint3 gid [[thread_position_in_grid]],
    constant TileUniforms& uniforms [[buffer(0)]],
    texture2d_array<float, access::read> sourceTexture [[texture(0)]],
    texture2d_array<float, access::write> destinationTexture [[texture(1)]])
{
    uint2 viewportPixel = gid.xy;
    uint2 viewportSize = uint2(uniforms.resolution);
    if (viewportPixel.x >= viewportSize.x || viewportPixel.y >= viewportSize.y) return;

    uint2 p = uint2(uniforms.viewportOrigin) + viewportPixel;
    uint eye = uniforms.eyeIndex;
    int radius = max(1, min(3, uniforms.colorScheme.edgeDetectionWindowRadius));

    float gx = 0.0f;
    float gy = 0.0f;
    float sampleCount = 0.0f;
    for (int offset = -3; offset <= 3; ++offset) {
        if (abs(offset) > radius) continue;
        gx += edgeLumaAt(sourceTexture, int2(p) + int2(radius, offset), eye) - edgeLumaAt(sourceTexture, int2(p) - int2(radius, offset), eye);
        gy += edgeLumaAt(sourceTexture, int2(p) + int2(offset, radius), eye) - edgeLumaAt(sourceTexture, int2(p) - int2(offset, radius), eye);
        sampleCount += 2.0f;
    }
    float gradient = length(float2(gx, gy)) / max(sampleCount, 1.0f);
    float threshold = uniforms.colorScheme.edgeDetectionThreshold;
    float softness = max(uniforms.colorScheme.edgeDetectionSoftness, 0.001f);
    float edge = smoothstep(threshold, threshold + softness, gradient);
    float4 sourceSample = sourceTexture.read(p, eye);
    float3 source = sourceSample.rgb;
    float3 result = mix(source, float3(0.0f), edge * uniforms.colorScheme.edgeDetectionStrength);
    destinationTexture.write(float4(result, sourceSample.a), p, eye);
}
