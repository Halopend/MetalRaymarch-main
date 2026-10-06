fragment FragmentOutput fragmentShader(ColorInOut in [[stage_in]],
                               constant UniformsArray & uniformsArray [[buffer(BufferIndexUniforms)]],
                               device atomic_uint* benchCounters [[buffer(BufferIndexBenchCounters)]],
                               ushort ampId [[amplification_id]])
{
    constant Uniforms& uniforms = uniformsArray.uniforms[ampId];
    float2 fragCoord = in.position.xy;

    // === GMT-FRACTALS: Halton Sub-Pixel Jitter ===
    // Apply sub-pixel jitter for temporal AA when geometry is stable.
    // This shifts the ray slightly each frame, providing free supersampling
    // via the display's temporal integration at 90Hz.
    fragCoord += uniforms.jitterOffset;

    return fragmentMain(in, uniforms, fragCoord, uniforms.time, benchCounters, true);
}

fragment FragmentOutput fragmentShaderMono(ColorInOut in [[stage_in]],
                               constant UniformsArray & uniformsArray [[buffer(BufferIndexUniforms)]],
                               device atomic_uint* benchCounters [[buffer(BufferIndexBenchCounters)]])
{
    constant Uniforms& uniforms = uniformsArray.uniforms[0];
    float2 fragCoord = in.position.xy + uniforms.jitterOffset;
    return fragmentMain(in, uniforms, fragCoord, uniforms.time, benchCounters, false);
}
