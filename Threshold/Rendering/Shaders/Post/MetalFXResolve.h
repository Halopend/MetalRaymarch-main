// === Format Conversion Shaders for MetalFX ===
// Used to convert rgba16Float MetalFX output to drawable format (BGRA8Unorm_sRGB)
// Also handles aspect ratio correction when MetalFX uses physical-sized textures

struct FormatConversionParams {
    float aspectCorrection;  // physicalAspect / screenAspect (< 1.0 means horizontally squished)
    float rcasStrength;      // RCAS sharpening strength: 0.0 = off, 1.0 = max
    float pad0;
    float pad1;
};

// Full-screen triangle vertex shader - generates vertices procedurally
// Supports stereo via amplification_id for render_target_array_index
struct FormatConversionVertexOut {
    float4 position [[position]];
    float2 texCoord;
    uint eyeIndex;  // Pass eye index to fragment
};

vertex FormatConversionVertexOut formatConversionVertexStereo(uint vertexID [[vertex_id]],
                                                              ushort ampId [[amplification_id]]) {
    FormatConversionVertexOut out;

    // Generate full-screen triangle using oversized triangle technique
    float2 position;
    position.x = (vertexID == 1) ? 3.0 : -1.0;
    position.y = (vertexID == 2) ? 3.0 : -1.0;

    out.position = float4(position, 0.0, 1.0);

    // Convert clip space to UV coordinates
    out.texCoord.x = (position.x + 1.0) * 0.5;
    out.texCoord.y = (1.0 - position.y) * 0.5;  // Flip Y for Metal
    out.eyeIndex = ampId;

    return out;
}

// Stereo fragment shader — samples from the MetalFX upscaled output and applies
// RCAS (Robust Contrast Adaptive Sharpening) to recover detail softened by the
// spatial upscale. Uses 5-tap nearest reads; no bilinear blurring on top.
fragment float4 formatConversionFragmentStereo(FormatConversionVertexOut in [[stage_in]],
                                                texture2d_array<float> sourceTexture [[texture(0)]],
                                                constant FormatConversionParams& params [[buffer(0)]]) {
    float2 uv = in.texCoord;
    if (params.aspectCorrection != 1.0) {
        uv.x = 0.5 + (uv.x - 0.5) * params.aspectCorrection;
    }

    float2 rcpSize = 1.0 / float2(sourceTexture.get_width(), sourceTexture.get_height());

    float3 color;
    if (params.rcasStrength > 0.0) {
        color = rcasSharpen(sourceTexture, uv, rcpSize, in.eyeIndex, params.rcasStrength);
    } else {
        constexpr sampler s(filter::nearest, address::clamp_to_edge);
        color = sourceTexture.sample(s, uv, in.eyeIndex).rgb;
    }
    return float4(color, 1.0);
}

struct DepthOutput {
    float depth [[depth(any)]];
};

// Phase 2.7: Merged color + depth resolve. Outputs both attachments from a
// single fragment invocation so we don't pay the per-tile load/store and
// command-encoder overhead of two separate render passes.
struct ColorDepthOutput {
    float4 color [[color(0)]];
    float depth  [[depth(any)]];
};

fragment ColorDepthOutput formatConversionFragmentStereoMerged(FormatConversionVertexOut in [[stage_in]],
                                                                texture2d_array<float> sourceColor [[texture(0)]],
                                                                depth2d_array<float> sourceDepth  [[texture(1)]],
                                                                constant FormatConversionParams& params [[buffer(0)]]) {
    float2 uv = in.texCoord;
    if (params.aspectCorrection != 1.0) {
        uv.x = 0.5 + (uv.x - 0.5) * params.aspectCorrection;
    }

    ColorDepthOutput out;

    float2 rcpSize = 1.0 / float2(sourceColor.get_width(), sourceColor.get_height());
    float3 color;
    if (params.rcasStrength > 0.0) {
        color = rcasSharpen(sourceColor, uv, rcpSize, in.eyeIndex, params.rcasStrength);
    } else {
        constexpr sampler s(filter::nearest, address::clamp_to_edge);
        color = sourceColor.sample(s, uv, in.eyeIndex).rgb;
    }
    out.color = float4(color, 1.0);

    constexpr sampler depthSampler(mag_filter::nearest, min_filter::nearest,
                                    address::clamp_to_edge);
    out.depth = sourceDepth.sample(depthSampler, uv, in.eyeIndex);
    return out;
}

// Stereo depth resolve fragment shader.
// Preserve low-res depth discontinuities instead of averaging foreground and
// background depths. Blended depth edges make compositor reprojection treat
// projected surfaces as flatter than the color stereo pair suggests.
fragment DepthOutput depthUpscaleFragmentStereo(FormatConversionVertexOut in [[stage_in]],
                                                 depth2d_array<float> sourceTexture [[texture(0)]],
                                                 constant FormatConversionParams& params [[buffer(0)]]) {
    constexpr sampler textureSampler(mag_filter::nearest, min_filter::nearest,
                                      address::clamp_to_edge);

    DepthOutput out;
    float2 uv = in.texCoord;
    if (params.aspectCorrection != 1.0) {
        uv.x = 0.5 + (uv.x - 0.5) * params.aspectCorrection;
    }
    out.depth = sourceTexture.sample(textureSampler, uv, in.eyeIndex);
    return out;
}

// === macOS single-view blit (MetalFX upscaled output → drawable) ===
// The Mac renderer upscales into an offscreen bgra8Unorm_srgb texture, then
// copies it to the drawable with this full-screen-triangle pass. Single-view
// (no amplification), 2D source — distinct from the stereo array variants above.
struct MacBlitVertexOut {
    float4 position [[position]];
    float2 texCoord;
};

vertex MacBlitVertexOut macBlitVertex(uint vertexID [[vertex_id]]) {
    MacBlitVertexOut out;
    float2 p;
    p.x = (vertexID == 1) ? 3.0 : -1.0;
    p.y = (vertexID == 2) ? 3.0 : -1.0;
    out.position = float4(p, 0.0, 1.0);
    out.texCoord = float2((p.x + 1.0) * 0.5, (1.0 - p.y) * 0.5);
    return out;
}

struct MacBlitParams {
    // x = enabled window radius (0 means off), y = strength,
    // z = threshold, w = softness.
    float4 edge;
    // x = enabled, y = blend amount, z = kernel dimension, w = reserved.
    float4 convolution;
    // Row-major coefficients, padded to 28 values for a stable ABI.
    float4 convolutionWeights[7];
};

inline float macConvolutionWeight(constant MacBlitParams& params, int index) {
    return params.convolutionWeights[index / 4][index % 4];
}

fragment float4 macBlitFragment(MacBlitVertexOut in [[stage_in]],
                                texture2d<float> source [[texture(0)]],
                                constant MacBlitParams& params [[buffer(0)]]) {
    constexpr sampler s(mag_filter::nearest, min_filter::nearest, address::clamp_to_edge);
    float3 color = source.sample(s, in.texCoord).rgb;

    if (params.convolution.x > 0.0f) {
        int size = clamp(int(params.convolution.z), 1, 5);
        int radius = (size - 1) / 2;
        float2 texel = 1.0f / float2(source.get_width(), source.get_height());
        float3 filtered = float3(0.0f);
        for (int y = -2; y <= 2; ++y) {
            for (int x = -2; x <= 2; ++x) {
                if (abs(x) > radius || abs(y) > radius) continue;
                int index = (y + radius) * size + (x + radius);
                filtered += source.sample(s, in.texCoord + float2(x, y) * texel).rgb
                    * macConvolutionWeight(params, index);
            }
        }
        color = mix(color, max(filtered, float3(0.0f)), params.convolution.y);
    }

    if (params.edge.x > 0.0f) {
        const float3 lumaWeights = float3(0.2126f, 0.7152f, 0.0722f);
        float gradient;
        if (params.edge.x < 1.5f) {
            // Default radius: quad derivatives reuse the one center fetch, so
            // post-upscale edge enhancement adds no texture samples or pass.
            float luma = dot(color, lumaWeights);
            gradient = length(float2(dfdx(luma), dfdy(luma)));
        } else {
            // Wider user-selected windows opt into four taps. The common radius
            // 1 path above remains the performant one-fetch implementation.
            float2 offset = params.edge.x
                / float2(source.get_width(), source.get_height());
            float left = dot(source.sample(s, in.texCoord - float2(offset.x, 0.0f)).rgb, lumaWeights);
            float right = dot(source.sample(s, in.texCoord + float2(offset.x, 0.0f)).rgb, lumaWeights);
            float top = dot(source.sample(s, in.texCoord - float2(0.0f, offset.y)).rgb, lumaWeights);
            float bottom = dot(source.sample(s, in.texCoord + float2(0.0f, offset.y)).rgb, lumaWeights);
            gradient = 0.5f * length(float2(right - left, bottom - top));
        }
        float softness = max(params.edge.w, 0.001f);
        float outline = smoothstep(params.edge.z, params.edge.z + softness, gradient);
        color = mix(color, float3(0.0f), outline * params.edge.y);
    }

    return float4(color, 1.0);
}
