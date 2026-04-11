#include <metal_stdlib>
using namespace metal;

fragment float4 testFragment(float2 uv [[stage_in]]) {
    float t = uv.x;
    for(int i=0; i<10; ++i) {
        float h = 1.0;
        float h_min = quad_min(h); // IS THIS LEGAL IN A LOOP WITH EARLY EXIT?
        if (t < 0.5) return float4(1);
        t += h_min;
    }
    return float4(t);
}
