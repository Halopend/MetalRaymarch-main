FORCE_INLINE float3 reconstructModelPoint(float2 pixelCoord, constant TileUniforms& uniforms,
                                          constant rasterization_rate_map_data& rateMapData) {
    float2 ndc;
    if (uniforms.rateMapValid != 0) {
        rasterization_rate_map_decoder decoder(rateMapData);
        float2 screenCoord = decoder.map_physical_to_screen_coordinates(pixelCoord, uniforms.rateMapLayer);
        ndc = (screenCoord / uniforms.screenResolution) * 2.0 - 1.0;
    } else {
        ndc = (pixelCoord / uniforms.resolution) * 2.0 - 1.0;
    }
    ndc.y = -ndc.y;
    float4 clipPos = float4(ndc.x, ndc.y, 0.0, 1.0);
    float4 viewPoint4 = uniforms.invProjMatrix * clipPos;
    float viewPointW = abs(viewPoint4.w) > 1e-6f
        ? viewPoint4.w
        : (viewPoint4.w >= 0.0f ? 1e-6f : -1e-6f);
    float3 viewPoint = viewPoint4.xyz / viewPointW;
    return (uniforms.invViewMatrix * float4(viewPoint, 1.0)).xyz;
}
