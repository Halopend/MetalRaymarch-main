//
//  NavierStrokesShaders.metal
//  Threshold
//
//  2D Navier-Stokes fluid simulation used as a screen-space post-processing
//  layer ("Navier Strokes"). Classic Jos Stam "stable fluids" split into
//  independent compute kernels so the host can order/bypass passes:
//
//      splat (velocity/ink) → advect → curl → vorticity confinement →
//      divergence → pressure (Jacobi × N) → gradient subtract →
//      advect ink → composite
//
//  State is ping-ponged by the host (NavierStrokesRenderer): velocity (rg16F),
//  ink/dye (rgba16F), pressure (r16F) pairs plus single divergence and curl
//  scratch targets. Fields live at a reduced sim resolution and are sampled
//  bilinearly by the full-resolution composite pass, which is the only pass
//  that touches the composed scene image.
//
//  Units: velocity is stored in UV units per second, so advection offsets are
//  resolution-independent and the composite can reuse the field directly.
//  Identity contract: the composite's `appliedAmount == 0` is an exact copy of
//  the source, enforced in the kernel — the host never dispatches the layer at
//  all below the activation epsilon.
//
//  All targets use `texture2d_array` so the same kernels serve the visionOS
//  stereo drawables (per-eye slice in `gid.z`) and the Mac/iOS single slice.
//

#include <metal_stdlib>
#include <simd/simd.h>
#import "ShaderTypes.h"

using namespace metal;

namespace {

constexpr sampler fieldSampler(mag_filter::linear,
                               min_filter::linear,
                               address::clamp_to_edge);

/// Sample a 2D array field with clamped edges (sim boundary condition).
inline float2 sampleVelocity(texture2d_array<float, access::sample> tex,
                             float2 uv,
                             uint eye) {
    return tex.sample(fieldSampler, uv, eye).xy;
}

/// Per-frame exponential decay. `dissipation` is tuned so 0 keeps momentum and
/// ~1.0 halves the field roughly every second at 60 fps.
inline float dissipationFactor(float dt, float dissipation) {
    return 1.0f / (1.0f + max(dt * dissipation, 0.0f));
}

} // namespace

// ═════════════════════════════════════════════════════════════════════════════
// MARK: - Splats (impulse injection)
// ═════════════════════════════════════════════════════════════════════════════

/// Inject up to kMaxStrokesSplats Gaussian impulses in one dispatch. The same
/// kernel serves velocity splats (mode 0: adds the shared `velocity` impulse
/// inside each Gaussian) and ink splats (mode 1: blends `color` into the
/// target), selected by the host binding the matching ping-pong pair and
/// filling `color.a` (velocity batches carry color.a == 0).
kernel void strokesSplat(
    uint3 gid [[thread_position_in_grid]],
    constant NavierStrokesSplatParams& params [[buffer(0)]],
    texture2d_array<float, access::read> source [[texture(0)]],
    texture2d_array<float, access::write> destination [[texture(1)]])
{
    if (gid.x >= source.get_width() || gid.y >= source.get_height()) return;
    const uint eye = gid.z;
    const float2 simSize = float2(source.get_width(), source.get_height());
    const float2 uv = (float2(gid.xy) + 0.5f) / simSize;

    float4 result = source.read(uint2(gid.xy), eye);
    for (int i = 0; i < kMaxStrokesSplats; ++i) {
        const float strength = params.splats[i].w;
        if (strength <= 0.0f) continue;   // unused batch slots
        float2 offset = (uv - params.splats[i].xy) * float2(params.aspect, 1.0);
        float falloff = exp(-dot(offset, offset) / max(params.splats[i].z, 1e-6f));
        if (falloff <= 1e-4f) continue;
        if (params.color.a > 0.0f) {
            // Ink splat: lift the injected tint with the falloff as density.
            result.rgb += params.color.rgb * (params.color.a * falloff);
            result.a = min(result.a + falloff * params.color.a, 1.5f);
        } else {
            // Velocity splat: .xy impulse, rgb/.a untouched.
            result.xy += params.velocity * (strength * falloff);
        }
    }
    destination.write(result, uint2(gid.xy), eye);
}

// ═════════════════════════════════════════════════════════════════════════════
// MARK: - Stable fluids passes
// ═════════════════════════════════════════════════════════════════════════════

/// Semi-Lagrangian advection of the velocity field by itself.
kernel void strokesAdvectVelocity(
    uint3 gid [[thread_position_in_grid]],
    constant NavierStrokesSimParams& params [[buffer(0)]],
    texture2d_array<float, access::sample> velocityIn [[texture(0)]],
    texture2d_array<float, access::write> velocityOut [[texture(1)]])
{
    if (gid.x >= velocityIn.get_width() || gid.y >= velocityIn.get_height()) return;
    const uint eye = gid.z;
    const float2 simSize = float2(velocityIn.get_width(), velocityIn.get_height());
    float2 uv = (float2(gid.xy) + 0.5f) / simSize;

    // Backtrace: where did this parcel come from one dt ago? (Velocity is
    // stored in uv/s, so the offset is plain uv.)
    float2 back = uv - params.dt * sampleVelocity(velocityIn, uv, eye);
    float2 clamped = clamp(back, 0.5f * params.texelSize, 1.0f - 0.5f * params.texelSize);
    float2 advected = sampleVelocity(velocityIn, clamped, eye)
        * dissipationFactor(params.dt, params.velocityDissipation);
    velocityOut.write(float4(advected, 0.0f, 1.0f), uint2(gid.xy), eye);
}

/// Curl (scalar ∂v_y/∂x − ∂v_x/∂y) of the velocity field.
kernel void strokesCurl(
    uint3 gid [[thread_position_in_grid]],
    constant NavierStrokesSimParams& params [[buffer(0)]],
    texture2d_array<float, access::sample> velocity [[texture(0)]],
    texture2d_array<float, access::write> curlOut [[texture(1)]])
{
    if (gid.x >= velocity.get_width() || gid.y >= velocity.get_height()) return;
    const uint eye = gid.z;
    const float2 simSize = float2(velocity.get_width(), velocity.get_height());
    float2 uv = (float2(gid.xy) + 0.5f) / simSize;
    float2 texel = params.texelSize;

    float2 left = sampleVelocity(velocity, uv - float2(texel.x, 0.0f), eye);
    float2 right = sampleVelocity(velocity, uv + float2(texel.x, 0.0f), eye);
    float2 bottom = sampleVelocity(velocity, uv - float2(0.0f, texel.y), eye);
    float2 top = sampleVelocity(velocity, uv + float2(0.0f, texel.y), eye);

    float curl = (right.y - left.y) * 0.5f - (top.x - bottom.x) * 0.5f;
    curlOut.write(float4(curl, 0.0f, 0.0f, 1.0f), uint2(gid.xy), eye);
}

/// Vorticity confinement: re-inject the curl the projection lost, keeping the
/// swirls alive. Reads the ORIGINAL velocity and writes a ping-pong copy.
kernel void strokesVorticity(
    uint3 gid [[thread_position_in_grid]],
    constant NavierStrokesSimParams& params [[buffer(0)]],
    texture2d_array<float, access::sample> velocityIn [[texture(0)]],
    texture2d_array<float, access::sample> curlTex [[texture(1)]],
    texture2d_array<float, access::write> velocityOut [[texture(2)]])
{
    if (gid.x >= velocityIn.get_width() || gid.y >= velocityIn.get_height()) return;
    const uint eye = gid.z;
    const float2 simSize = float2(velocityIn.get_width(), velocityIn.get_height());
    float2 uv = (float2(gid.xy) + 0.5f) / simSize;
    float2 texel = params.texelSize;

    float left = curlTex.sample(fieldSampler, uv - float2(texel.x, 0.0f), eye).x;
    float right = curlTex.sample(fieldSampler, uv + float2(texel.x, 0.0f), eye).x;
    float bottom = curlTex.sample(fieldSampler, uv - float2(0.0f, texel.y), eye).x;
    float top = curlTex.sample(fieldSampler, uv + float2(0.0f, texel.y), eye).x;
    float center = curlTex.sample(fieldSampler, uv, eye).x;

    // Gradient of |curl| (numerically safe normalizer) — the confinement force
    // pushes velocity toward the vortices. N = ∇|ω| / |∇|ω||, F = ε·(N × ω).
    float2 grad = float2(abs(right) - abs(left), abs(top) - abs(bottom)) * 0.5f;
    float gradLength = length(grad) + 1e-5f;
    float2 force = (grad / gradLength) * center * params.curl;
    float2 velocity = sampleVelocity(velocityIn, uv, eye) + force * params.dt;
    velocityOut.write(float4(velocity, 0.0f, 1.0f), uint2(gid.xy), eye);
}

/// Divergence of the velocity field (compressibility error to be projected out).
kernel void strokesDivergence(
    uint3 gid [[thread_position_in_grid]],
    constant NavierStrokesSimParams& params [[buffer(0)]],
    texture2d_array<float, access::sample> velocity [[texture(0)]],
    texture2d_array<float, access::write> divergenceOut [[texture(1)]])
{
    if (gid.x >= velocity.get_width() || gid.y >= velocity.get_height()) return;
    const uint eye = gid.z;
    const float2 simSize = float2(velocity.get_width(), velocity.get_height());
    float2 uv = (float2(gid.xy) + 0.5f) / simSize;

    float2 right = sampleVelocity(velocity, uv + float2(params.texelSize.x, 0.0f), eye);
    float2 left = sampleVelocity(velocity, uv - float2(params.texelSize.x, 0.0f), eye);
    float2 top = sampleVelocity(velocity, uv + float2(0.0f, params.texelSize.y), eye);
    float2 bottom = sampleVelocity(velocity, uv - float2(0.0f, params.texelSize.y), eye);

    float divergence = 0.5f * (right.x - left.x + top.y - bottom.y);
    divergenceOut.write(float4(divergence, 0.0f, 0.0f, 1.0f), uint2(gid.xy), eye);
}

/// One Jacobi sweep of the pressure Poisson equation
/// (∇²p = divergence). Host dispatches `pressureIterations` of these.
kernel void strokesPressureJacobi(
    uint3 gid [[thread_position_in_grid]],
    constant NavierStrokesSimParams& params [[buffer(0)]],
    texture2d_array<float, access::read> divergence [[texture(0)]],
    texture2d_array<float, access::sample> pressureIn [[texture(1)]],
    texture2d_array<float, access::write> pressureOut [[texture(2)]])
{
    if (gid.x >= divergence.get_width() || gid.y >= divergence.get_height()) return;
    const uint eye = gid.z;
    const float2 simSize = float2(divergence.get_width(), divergence.get_height());
    float2 uv = (float2(gid.xy) + 0.5f) / simSize;
    const float alpha = -1.0f;   // −ρ⁻¹, unit density, dx = 1
    const float beta = 4.0f;     // 2·(1/texel²)·(texel²) = 4 neighbors

    float left = pressureIn.sample(fieldSampler, uv - float2(params.texelSize.x, 0.0f), eye).x;
    float right = pressureIn.sample(fieldSampler, uv + float2(params.texelSize.x, 0.0f), eye).x;
    float bottom = pressureIn.sample(fieldSampler, uv - float2(0.0f, params.texelSize.y), eye).x;
    float top = pressureIn.sample(fieldSampler, uv + float2(0.0f, params.texelSize.y), eye).x;
    float center = divergence.read(uint2(gid.xy), eye).x;

    float pressure = (left + right + bottom + top + alpha * center) / beta;
    pressureOut.write(float4(pressure, 0.0f, 0.0f, 1.0f), uint2(gid.xy), eye);
}

/// Subtract the pressure gradient from the velocity — the projection that makes
/// the field (approximately) incompressible.
kernel void strokesGradientSubtract(
    uint3 gid [[thread_position_in_grid]],
    constant NavierStrokesSimParams& params [[buffer(0)]],
    texture2d_array<float, access::sample> pressure [[texture(0)]],
    texture2d_array<float, access::sample> velocityIn [[texture(1)]],
    texture2d_array<float, access::write> velocityOut [[texture(2)]])
{
    if (gid.x >= velocityIn.get_width() || gid.y >= velocityIn.get_height()) return;
    const uint eye = gid.z;
    const float2 simSize = float2(velocityIn.get_width(), velocityIn.get_height());
    float2 uv = (float2(gid.xy) + 0.5f) / simSize;

    float left = pressure.sample(fieldSampler, uv - float2(params.texelSize.x, 0.0f), eye).x;
    float right = pressure.sample(fieldSampler, uv + float2(params.texelSize.x, 0.0f), eye).x;
    float bottom = pressure.sample(fieldSampler, uv - float2(0.0f, params.texelSize.y), eye).x;
    float top = pressure.sample(fieldSampler, uv + float2(0.0f, params.texelSize.y), eye).x;

    float2 gradient = float2(right - left, top - bottom) * 0.5f;
    float2 velocity = sampleVelocity(velocityIn, uv, eye) - gradient;
    velocityOut.write(float4(velocity, 0.0f, 1.0f), uint2(gid.xy), eye);
}

/// Semi-Lagrangian advection of the ink field by the (projected) velocity.
kernel void strokesAdvectDye(
    uint3 gid [[thread_position_in_grid]],
    constant NavierStrokesSimParams& params [[buffer(0)]],
    texture2d_array<float, access::sample> dyeIn [[texture(0)]],
    texture2d_array<float, access::sample> velocity [[texture(1)]],
    texture2d_array<float, access::write> dyeOut [[texture(2)]])
{
    if (gid.x >= dyeIn.get_width() || gid.y >= dyeIn.get_height()) return;
    const uint eye = gid.z;
    const float2 simSize = float2(dyeIn.get_width(), dyeIn.get_height());
    float2 uv = (float2(gid.xy) + 0.5f) / simSize;

    float2 back = uv - params.dt * sampleVelocity(velocity, uv, eye);
    float2 clamped = clamp(back, 0.5f * params.texelSize, 1.0f - 0.5f * params.texelSize);
    float4 advected = dyeIn.sample(fieldSampler, clamped, eye);
    advected *= dissipationFactor(params.dt, params.dyeDissipation);
    dyeOut.write(advected, uint2(gid.xy), eye);
}

// ═════════════════════════════════════════════════════════════════════════════
// MARK: - Composite (full output resolution)
// ═════════════════════════════════════════════════════════════════════════════

/// Final composite: drags the composed scene image along the fluid's velocity
/// field and lays advected ink over it, blended by `appliedAmount`. One thread
/// per OUTPUT pixel — the sim fields are sampled bilinearly. `renderWidth/
/// renderHeight` bound the dispatch to the physical/viewport region the
/// upstream path actually wrote (same convention as the edge detector).
kernel void strokesComposite(
    uint3 gid [[thread_position_in_grid]],
    constant NavierStrokesCompositeParams& params [[buffer(0)]],
    texture2d_array<float, access::sample> source [[texture(0)]],
    texture2d_array<float, access::sample> velocity [[texture(1)]],
    texture2d_array<float, access::sample> dye [[texture(2)]],
    texture2d_array<float, access::write> output [[texture(3)]])
{
    if (gid.x >= source.get_width() || gid.y >= source.get_height()) return;
    const uint eye = gid.z;
    const float2 outSize = float2(source.get_width(), source.get_height());
    float2 uv = (float2(gid.xy) + 0.5f) / outSize;

    float4 src = source.read(uint2(gid.xy), eye);

    // The host clamps the dispatch to the physical/viewport region; nothing
    // beyond it is written (the visionOS compositor never reads it).
    float2 flow = velocity.sample(fieldSampler, uv, eye).xy;
    float4 ink = dye.sample(fieldSampler, uv, eye);

    // Drag the image along the flow (semi-Lagrangian "smear"), sampled
    // bilinearly so strokes glide smoothly over the output grid.
    float2 smear = flow * params.displacement;
    float2 smearUV = clamp(uv - smear, float2(0.0f), float2(1.0f));
    float3 dragged = source.sample(fieldSampler, smearUV, eye).rgb;

    // Advected ink lifts the smeared image with the fluid's own color.
    float3 stroked = dragged + ink.rgb * ink.a * params.inkGain * params.inkTint;

    // appliedAmount == 0 (host-gated) is an exact source copy — the guaranteed
    // identity bypass of the layer.
    float3 blended = mix(src.rgb, max(stroked, float3(0.0f)), saturate(params.appliedAmount));
    output.write(float4(blended, src.a), uint2(gid.xy), eye);
}

// ═════════════════════════════════════════════════════════════════════════════
// MARK: - Fragment composites (drawing the drawable directly)
// ═════════════════════════════════════════════════════════════════════════════
// The Mac/iOS paths draw the final image straight into the CAMetalDrawable
// (plain 2D source). Types are local to this file — Metal translation units do
// not share definitions with Shaders.metal.

struct NavierStrokesVertexOut {
    float4 position [[position]];
    float2 texCoord;
};

struct NavierStrokesStereoVertexOut {
    float4 position [[position]];
    float2 texCoord;
    uint eyeIndex;  // from vertex amplification (per-eye slice)
};

/// Full-screen oversized triangle (the standard technique used by the
/// renderer's other post passes).
vertex NavierStrokesVertexOut navierCompositeVertex(uint vertexID [[vertex_id]]) {
    NavierStrokesVertexOut out;
    float2 position;
    position.x = (vertexID == 1) ? 3.0 : -1.0;
    position.y = (vertexID == 2) ? 3.0 : -1.0;
    out.position = float4(position, 0.0, 1.0);
    out.texCoord.x = (position.x + 1.0) * 0.5;
    out.texCoord.y = (1.0 - position.y) * 0.5;  // Flip Y for Metal
    return out;
}

/// Stereo variant: one draw call rasterizes both eyes via vertex amplification
/// and carries the amplification id as the array slice to sample.
vertex NavierStrokesStereoVertexOut navierCompositeVertexStereo(
    uint vertexID [[vertex_id]],
    ushort ampId [[amplification_id]]) {
    NavierStrokesStereoVertexOut out;
    float2 position;
    position.x = (vertexID == 1) ? 3.0 : -1.0;
    position.y = (vertexID == 2) ? 3.0 : -1.0;
    out.position = float4(position, 0.0, 1.0);
    out.texCoord.x = (position.x + 1.0) * 0.5;
    out.texCoord.y = (1.0 - position.y) * 0.5;  // Flip Y for Metal
    out.eyeIndex = ampId;
    return out;
}

/// Same composite as `strokesComposite`, as a fragment pass so the Mac/iOS
/// render path can write the drawable directly (single eye; the source is a
/// plain 2D texture while the sim fields stay 2D arrays with one slice).
fragment float4 navierCompositeFragment(
    NavierStrokesVertexOut in [[stage_in]],
    texture2d<float> source [[texture(0)]],
    texture2d_array<float, access::sample> velocity [[texture(1)]],
    texture2d_array<float, access::sample> dye [[texture(2)]],
    constant NavierStrokesCompositeParams& params [[buffer(0)]])
{
    constexpr sampler linearSampler(mag_filter::linear,
                                    min_filter::linear,
                                    address::clamp_to_edge);
    float4 src = source.sample(linearSampler, in.texCoord);

    float2 flow = velocity.sample(fieldSampler, in.texCoord, 0).xy;
    float4 ink = dye.sample(fieldSampler, in.texCoord, 0);

    float2 smear = flow * params.displacement;
    float2 smearUV = clamp(in.texCoord - smear, float2(0.0f), float2(1.0f));
    float3 dragged = source.sample(linearSampler, smearUV).rgb;

    float3 stroked = dragged + ink.rgb * ink.a * params.inkGain * params.inkTint;
    float3 blended = mix(src.rgb, max(stroked, float3(0.0f)), saturate(params.appliedAmount));
    return float4(blended, src.a);
}

/// visionOS stereo variant of the fragment composite: renders the drawable's
/// 2D-array layout with vertex amplification so each eye composites from its
/// own slice. Reserved for render paths that composite into a drawable without
/// an intermediate blit.
fragment float4 navierCompositeFragmentStereo(
    NavierStrokesStereoVertexOut in [[stage_in]],
    texture2d_array<float, access::sample> source [[texture(0)]],
    texture2d_array<float, access::sample> velocity [[texture(1)]],
    texture2d_array<float, access::sample> dye [[texture(2)]],
    constant NavierStrokesCompositeParams& params [[buffer(0)]])
{
    constexpr sampler linearSampler(mag_filter::linear,
                                    min_filter::linear,
                                    address::clamp_to_edge);
    float4 src = source.sample(linearSampler, in.texCoord, in.eyeIndex);

    float2 flow = velocity.sample(fieldSampler, in.texCoord, in.eyeIndex).xy;
    float4 ink = dye.sample(fieldSampler, in.texCoord, in.eyeIndex);

    float2 smear = flow * params.displacement;
    float2 smearUV = clamp(in.texCoord - smear, float2(0.0f), float2(1.0f));
    float3 dragged = source.sample(linearSampler, smearUV, in.eyeIndex).rgb;

    float3 stroked = dragged + ink.rgb * ink.a * params.inkGain * params.inkTint;
    float3 blended = mix(src.rgb, max(stroked, float3(0.0f)), saturate(params.appliedAmount));
    return float4(blended, src.a);
}