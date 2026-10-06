FORCE_INLINE ColorInOut makeVertexOutput(Vertex in, constant Uniforms& uniforms) {
    constexpr float kProxyRadius = 100.0f;
    constexpr float kProxySafetyScale = 1.05f;

    ColorInOut out;

    // The proxy mesh is a radius-100 model-space ellipsoid. On deep zoom-out the
    // camera's model-space distance to the origin exceeds 100, the camera exits
    // the proxy, and the raymarch gets clipped to the sphere's silhouette.
    // Inflate the mesh so it always encloses camera + march horizon. modelPos is
    // only ever used as a point on the eye ray (rd = normalize(modelPos - cam)),
    // so uniform scaling never changes ray directions. Branch (not a blanket
    // multiply) so normal-zoom frames run the pre-existing arithmetic unchanged.
    float3 camModel = (uniforms.inverseModelViewMatrix * float4(0.0f, 0.0f, 0.0f, 1.0f)).xyz;
    float proxyInflate = (length(camModel) + uniforms.maxViewDistance) * (kProxySafetyScale / kProxyRadius);
    float3 proxyPos = in.position;
    if (proxyInflate > 1.0f) {
        proxyPos *= proxyInflate;
    }
    float4 position = float4(proxyPos, 1.0f);
    out.position = uniforms.projectionMatrix * uniforms.modelViewMatrix * position;
    out.texCoord = in.texCoord;
    out.modelPos = proxyPos;

    return out;
}

vertex ColorInOut vertexShader(Vertex in [[stage_in]],
                               ushort ampId [[amplification_id]],
                               constant UniformsArray& uniformsArray [[buffer(BufferIndexUniforms)]]) {
    return makeVertexOutput(in, uniformsArray.uniforms[ampId]);
}

// Screenshot vertex shader (no vertex amplification, uses view 0).
vertex ColorInOut screenshotVertexShader(Vertex in [[stage_in]],
                                         constant UniformsArray& uniformsArray [[buffer(BufferIndexUniforms)]]) {
    return makeVertexOutput(in, uniformsArray.uniforms[0]);
}
