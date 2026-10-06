// === PLANTED SPATIAL RADIAL MENU ===
// Instanced world-space cards are composited after the fractal resolve. The
// renderer supplies raw world→clip matrices, so menu placement is independent
// of the fractal model transform and remains fixed at its activation pose.
struct SpatialRadialGPUInstance {
    float4 centerAndKind;
    float4 rightAndHalfWidth;
    float4 upAndHalfHeight;
    float4 fillColor;
    float4 strokeColor;
    float4 labelUVRect;
};

struct SpatialRadialViewUniforms {
    float4x4 viewProjection[2];
};

struct SpatialRadialVertexOut {
    float4 position [[position]];
    float2 localPosition;
    float2 labelUV;
    float4 fillColor;
    float4 strokeColor;
    float kind;
};

vertex SpatialRadialVertexOut spatialRadialVertex(
    uint vertexID [[vertex_id]],
    uint instanceID [[instance_id]],
    ushort ampID [[amplification_id]],
    constant SpatialRadialViewUniforms& views [[buffer(0)]],
    device const SpatialRadialGPUInstance* instances [[buffer(1)]])
{
    constexpr float2 corners[6] = {
        float2(-1.0f, -1.0f), float2( 1.0f, -1.0f), float2(-1.0f,  1.0f),
        float2(-1.0f,  1.0f), float2( 1.0f, -1.0f), float2( 1.0f,  1.0f)
    };

    SpatialRadialGPUInstance instance = instances[instanceID];
    float2 corner = corners[vertexID];
    float3 worldPosition = instance.centerAndKind.xyz
        + instance.rightAndHalfWidth.xyz * (corner.x * instance.rightAndHalfWidth.w)
        + instance.upAndHalfHeight.xyz * (corner.y * instance.upAndHalfHeight.w);

    SpatialRadialVertexOut out;
    out.position = views.viewProjection[min(ushort(1), ampID)] * float4(worldPosition, 1.0f);
    out.localPosition = corner;
    float2 unitUV = float2(corner.x * 0.5f + 0.5f, 0.5f - corner.y * 0.5f);
    out.labelUV = mix(instance.labelUVRect.xy, instance.labelUVRect.zw, unitUV);
    out.fillColor = instance.fillColor;
    out.strokeColor = instance.strokeColor;
    out.kind = instance.centerAndKind.w;
    return out;
}

fragment float4 spatialRadialFragment(
    SpatialRadialVertexOut in [[stage_in]],
    texture2d<float> labelAtlas [[texture(0)]])
{
    constexpr sampler labelSampler(filter::linear, address::clamp_to_edge);
    float2 p = in.localPosition;
    float coverage = 0.0f;
    float border = 0.0f;
    float label = 0.0f;

    if (in.kind < 0.5f) {
        // Rounded navigation card.
        constexpr float radius = 0.18f;
        float2 q = abs(p) - float2(0.82f, 0.68f);
        float distance = length(max(q, 0.0f)) + min(max(q.x, q.y), 0.0f) - radius;
        float width = max(fwidth(distance), 0.012f);
        coverage = 1.0f - smoothstep(-width, width, distance);
        border = (1.0f - smoothstep(0.0f, width * 2.5f, abs(distance))) * coverage;
        label = labelAtlas.sample(labelSampler, in.labelUV).a * coverage;
    } else if (in.kind < 1.5f) {
        // Radial depth guide.
        float distance = abs(length(p) - 0.94f);
        float width = max(fwidth(distance), 0.012f);
        coverage = 1.0f - smoothstep(0.018f, 0.018f + width * 2.0f, distance);
    } else {
        // Hub and direct-hand cursor.
        float distance = length(p) - 0.88f;
        float width = max(fwidth(distance), 0.012f);
        coverage = 1.0f - smoothstep(-width, width, distance);
        border = (1.0f - smoothstep(0.0f, width * 2.5f, abs(distance))) * coverage;
    }

    float alpha = max(
        in.fillColor.a * coverage,
        max(in.strokeColor.a * border, label)
    );
    if (alpha < 0.004f) {
        discard_fragment();
    }

    float3 color = in.fillColor.rgb;
    color = mix(color, in.strokeColor.rgb, saturate(border * in.strokeColor.a));
    color = mix(color, float3(1.0f), saturate(label));
    return float4(color, alpha);
}
