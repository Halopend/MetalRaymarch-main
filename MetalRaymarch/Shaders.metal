//
//  Shaders.metal
//

// File for Metal kernel and shader functions

#include <metal_stdlib>
#include <simd/simd.h>

// Including header shared between this Metal shader code and Swift/C code executing Metal API commands
#import "ShaderTypes.h"

using namespace metal;

typedef struct
{
    float3 position [[attribute(VertexAttributePosition)]];
    float2 texCoord [[attribute(VertexAttributeTexcoord)]];
} Vertex;

typedef struct
{
    float4 color [[color(0)]];
    float depth [[depth(any)]];
} FragmentOutput;

typedef struct
{
    float4 position [[position]];
    float2 texCoord;
    float time;
    float3 modelPos;
    float4 ndcPosition;
    float minDistance;
    float2 foveaCenter;
    float fractalScale;
    int fractalIterations;
    int maxRaySteps;
    float foveationIntensity;
    float colorMix;
    float glowIntensity;
    float foldingLimit;
    float sphereRadius;
    float colorIterations;
} ColorInOut;

vertex ColorInOut vertexShader(Vertex in [[stage_in]],
                               ushort ampId [[amplification_id]],
                               constant UniformsArray & uniformsArray [[ buffer(BufferIndexUniforms) ]])
{
    ColorInOut out;

    Uniforms uniforms = uniformsArray.uniforms[ampId];
    
    float4 position = float4(in.position, 1);
    out.position = uniforms.projectionMatrix * uniforms.modelViewMatrix * position;
    out.ndcPosition = out.position; // Store for depth calculation
    
    out.texCoord = in.texCoord;
    out.time = uniforms.time;
    out.modelPos = in.position;
    out.minDistance = uniforms.minDistance;
    out.foveaCenter = uniforms.foveaCenter;
    out.fractalScale = uniforms.fractalScale;
    out.fractalIterations = uniforms.fractalIterations;
    out.maxRaySteps = uniforms.maxRaySteps;
    out.foveationIntensity = uniforms.foveationIntensity;
    out.colorMix = uniforms.colorMix;
    out.glowIntensity = uniforms.glowIntensity;
    out.foldingLimit = uniforms.foldingLimit;
    out.sphereRadius = uniforms.sphereRadius;
    out.colorIterations = uniforms.colorIterations;
    
    return out;
}

// --- Fractal Code Port ---
// Spatial Rendering optimizations for visionOS

constant float3 sunDir = float3(0.3235, 0.0924, 0.2773); // normalized(0.35, 0.1, 0.3)
constant float3 sunColour = float3(1.0, 0.95, 0.8);

// Blue noise approximation for temporal stability (better than white noise for reprojection)
float blueNoise(float2 uv, float time) {
    // Interleaved gradient noise - more temporally stable than random
    float3 magic = float3(0.06711056, 0.00583715, 52.9829189);
    float noise = fract(magic.z * fract(dot(uv, magic.xy)));
    // Add small temporal variation to prevent static patterns
    return fract(noise + time * 0.1);
}
constant float SCALE = 2.8;

float hash(float n) { return fract(sin(n) * 753.5453123); }

float noise(float3 x) {
    float3 p = floor(x);
    float3 f = fract(x);
    f = f * f * (3.0 - 2.0 * f);
    float n = p.x + p.y * 157.0 + 113.0 * p.z;
    return mix(mix(mix(hash(n +   0.0), hash(n +   1.0), f.x),
                   mix(hash(n + 157.0), hash(n + 158.0), f.x), f.y),
               mix(mix(hash(n + 113.0), hash(n + 114.0), f.x),
                   mix(hash(n + 270.0), hash(n + 271.0), f.x), f.y), f.z);
}

float GetSky(float3 pos)
{
    pos *= 2.3;
    float t = noise(pos);
    return t;
}

// Optimized branchless Map function
float Map(float3 pos, float minRad2Val, float fractalScale, float foldingLimit, float sphereRadius, int iterations) 
{
    float minRad2 = minRad2Val;
    float4 scale = float4(fractalScale) / minRad2;
    scale.w = abs(scale.w);
    float absScalem1 = abs(fractalScale - 1.0);
    float AbsScaleRaisedTo1mIters = pow(abs(fractalScale), float(1-iterations));
    
    float minRadius2 = sphereRadius * sphereRadius;

    float4 p = float4(pos, 1.0);
    float4 p0 = p;

    for (int i = 0; i < iterations; i++)
    {
        // Box fold (optimized)
        p.xyz = clamp(p.xyz, -foldingLimit, foldingLimit) * 2.0 - p.xyz;

        // Branchless sphere fold - much faster on GPU
        float r2 = dot(p.xyz, p.xyz);
        float t = clamp(1.0 / max(r2, minRadius2), 1.0, 1.0/minRadius2);
        p *= t;

        p = p * scale + p0;
    }
    return (length(p.xyz) - absScalem1) / p.w - AbsScaleRaisedTo1mIters;
}

// Optimized colour function using half precision
half3 Colour(float3 pos, float sphereR, float gTime, float quality, float minRad2Val, float fractalScale, float colorMix, float foldingLimit, float sphereRadius, int colorIters) 
{
    float4 scale = float4(fractalScale) / minRad2Val;
    scale.w = abs(scale.w);
    float minRadius2 = sphereRadius * sphereRadius;

    float3 p = pos;
    float3 p0 = p;
    float trap = 1.0;
    
    int steps = max(int(float(colorIters) * quality), 2);
    for (int i = 0; i < steps; i++)
    {
        p = clamp(p, -foldingLimit, foldingLimit) * 2.0 - p;
        float r2 = dot(p, p);
        p *= clamp(1.0 / max(r2, minRadius2), 1.0, 1.0/minRadius2);
        p = p * scale.xyz + p0;
        trap = min(trap, r2);
    }
    
    half2 c = saturate(half2(0.3333h * log(half(dot(p,p))) - 1.0h, sqrt(half(trap))));
    
    // Half precision colors
    half3 col1 = half3(0.8h, 0.0h, 0.0h);
    half3 col2 = half3(0.4h, 0.4h, 0.5h);
    half3 col3 = half3(0.5h, 0.3h, 0.0h);
    
    half3 finalColor = mix(mix(col1, col2, c.y), col3, c.x);
    half3 altColor = half3(c.x, c.y, 0.5h + 0.3h * c.y);
    return mix(finalColor, altColor, half(colorMix));
}

// Fast normal using forward differences (3 Map calls instead of 4)
float3 GetNormal(float3 pos, float distance, float minRad2Val, float fractalScale, float foldingLimit, float sphereRadius, int iterations)
{
    float e = distance * 0.001;
    float d = Map(pos, minRad2Val, fractalScale, foldingLimit, sphereRadius, iterations);
    return normalize(float3(
        Map(pos + float3(e,0,0), minRad2Val, fractalScale, foldingLimit, sphereRadius, iterations) - d,
        Map(pos + float3(0,e,0), minRad2Val, fractalScale, foldingLimit, sphereRadius, iterations) - d,
        Map(pos + float3(0,0,e), minRad2Val, fractalScale, foldingLimit, sphereRadius, iterations) - d
    ));
}

// Reduced binary subdivision (4 iterations instead of 6)
float BinarySubdivision(float3 rO, float3 rD, float2 t, float minRad2Val, float fractalScale, float foldingLimit, float sphereRadius, int iterations)
{
    float halfwayT;
    for (int i = 0; i < 4; i++)
    {
        halfwayT = (t.x + t.y) * 0.5;
        float d = Map(rO + halfwayT*rD, minRad2Val, fractalScale, foldingLimit, sphereRadius, iterations); 
        t = mix(float2(t.x, halfwayT), float2(halfwayT, t.y), step(0.0005, d));
    }
    return halfwayT;
}

// Enhanced sphere tracing with over-relaxation (no binary subdivision needed)
// Optimized for visionOS spatial rendering with temporal stability
float2 Scene(float3 rO, float3 rD, float2 fragCoord, float quality, float minRad2Val, int maxStepsParam, float fractalScale, float glowIntensity, float foldingLimit, float sphereRadius, int iterations, float time)
{
    // Use temporally stable blue noise dithering for reprojection
    // This reduces shimmer/crawling artifacts during head movement
    float dither = blueNoise(fragCoord, time) * 0.015;
    float t = 0.05 + dither;
    
    float glow = 0.0;
    int maxSteps = max(int(float(maxStepsParam) * quality), 4);
    
    // Previous distance for over-relaxation
    float prevH = 1e10;
    float omega = 1.2; // Over-relaxation factor (1.0 = standard, >1 = aggressive)
    
    // Distance-adaptive threshold: allows coarser hits when far away
    // This is perceptually invisible but saves many iterations
    
    for(int j = 0; j < maxSteps; j++)
    {
        // Adaptive threshold grows with distance (imperceptible at distance)
        float threshold = 0.0005 + t * 0.0008 + (1.0 - quality) * 0.003;
        
        float3 p = rO + t * rD;
        float h = Map(p, minRad2Val, fractalScale, foldingLimit, sphereRadius, iterations);
        
        // Hit detection
        if(h < threshold)
        {
            // No binary subdivision needed - we're close enough
            // The adaptive threshold ensures we don't overshoot significantly
            return float2(t, saturate(glow * 0.25));
        }
        
        // Early termination for rays going to infinity
        if (t > 12.0) break;
        
        // Accumulate glow from near-misses
        glow += saturate(0.04 - h) * glowIntensity;
        
        // === Enhanced Sphere Tracing with Over-Relaxation ===
        // Key insight: If we're moving away from surfaces (h > prevH),
        // we can safely step MORE than the SDF value suggests.
        // If approaching (h < prevH), be more conservative.
        
        float stepSize;
        if (h > prevH * 0.9) {
            // Moving away or constant - use over-relaxation
            // Can step up to omega * h safely (omega > 1)
            stepSize = h * omega;
        } else {
            // Approaching surface - be conservative to avoid overshoot
            // But still use some relaxation based on rate of approach
            float approachRate = prevH / (prevH - h + 0.001);
            stepSize = h * min(approachRate * 0.5, 1.2);
        }
        
        // Minimum step to prevent getting stuck, maximum to prevent huge jumps
        stepSize = clamp(stepSize, 0.001, 2.0);
        
        // Distance-proportional step bonus (safe because SDF scales with distance)
        stepSize += t * 0.001;
        
        prevH = h;
        t += stepSize;
    }
    
    return float2(1000.0, saturate(glow * 0.25));
}

// Simplified post effects using half precision
half3 PostEffects(half3 rgb, half2 xy)
{
    // Combined contrast/saturation/brightness in fewer ops
    half luma = dot(rgb, half3(0.2126h, 0.7152h, 0.0722h));
    rgb = mix(half3(luma), rgb, 1.5h) * 1.5h; // saturation + brightness
    rgb = mix(half3(0.5h), rgb, 1.08h);       // contrast
    
    // Simplified vignette
    half2 q = xy * (1.0h - xy);
    rgb *= 0.5h + 0.5h * pow(16.0h * q.x * q.y, 0.2h);
    
    // Gamma
    return pow(rgb, half3(0.47h));
}

// Ultra-fast shadow with over-relaxation
float Shadow(float3 ro, float3 rd, float quality, float minRad2Val, float fractalScale, float foldingLimit, float sphereRadius, int iterations)
{
    // Skip shadows in extreme periphery
    if (quality < 0.25) return 0.65;
    
    float res = 1.0;
    float t = 0.08;
    float prevH = 1e10;
    
    // Very few steps with aggressive over-relaxation
    int steps = int(quality * 2.0) + 1; // 1-3 steps
    int reducedIters = max(iterations - 2, 2);
    
    for (int i = 0; i < steps; i++)
    {
        float h = Map(ro + rd * t, minRad2Val, fractalScale, foldingLimit, sphereRadius, reducedIters);
        
        // Soft shadow calculation
        res = min(res, 10.0 * h / t);
        
        // Early exit if definitely in shadow
        if (res < 0.02) return 0.0;
        
        // Over-relaxation: step more aggressively when safe
        float step = (h > prevH * 0.8) ? h * 1.5 : h;
        t += max(step, 0.15);
        prevH = h;
        
        // Don't trace too far for shadows
        if (t > 4.0) break;
    }
    
    return saturate(res);
}

float3 CameraPath( float t )
{
    float3 p = float3(-.78 + 3. * sin(2.14*t),.05+2.5 * sin(.942*t+1.3),.05 + 3.5 * cos(3.594*t) );
    return p;
} 

float3 LightSource(float3 spotLight, float3 dir, float dis)
{
    float g = 0.0;
    if (length(spotLight) < dis)
    {
        float a = max(dot(normalize(spotLight), dir), 0.0);
        g = pow(a, 500.0);
        g +=  pow(a, 5000.0)*.2;
    }
   
    return float3(.6) * g;
}

float3 uvToDir(float2 uv) // uv: -1..1
{
    float2 uvRad = float2(uv.x * M_PI_F, uv.y * M_PI_F / 2); // -pi..pi, -pi/2..pi/2
    float2 xz = float2(sin(uvRad.x), cos(uvRad.x));
    return float3(xz.x * cos(uvRad.y), sin(uvRad.y), xz.y * cos(uvRad.y));
}

fragment FragmentOutput fragmentShader(ColorInOut in [[stage_in]],
                               constant UniformsArray & uniformsArray [[buffer(BufferIndexUniforms)]],
                               ushort ampId [[amplification_id]],
                               texture2d<half> cubeMap [[texture(TextureIndexColor)]])
{
    FragmentOutput output;
    
    float gTime = in.time * 0.01 + 15.00;
    
    Uniforms uniforms = uniformsArray.uniforms[ampId];
    float3 cameraPos = (uniforms.inverseModelViewMatrix * float4(0,0,0,1)).xyz;
    float3 rd = normalize(in.modelPos - cameraPos);
    
    // Use screen position for stable dithering pattern
    float2 fragCoord = in.position.xy;
    
    // === Foveation ===
    // System rasterization rate maps handle pixel density (gaze-tracked)
    // Shader-side: only reduce iterations at extreme edges for perf
    float distFromCenter = length(in.texCoord - float2(0.5, 0.5));
    
    // Minimal shader foveation - system rate maps do the heavy lifting
    // Only affects very edges (50%+ from center), very gentle falloff
    float edgeAtten = smoothstep(0.5, 0.8, distFromCenter);
    float quality = mix(1.0, 0.7, edgeAtten * in.foveationIntensity);
    
    // LOD: Reduce fractal iterations in periphery
    int lodIterations = max(int(float(in.fractalIterations) * (0.4 + 0.6 * quality)), 2);
    
    // Pass time for temporally stable dithering
    float2 ret = Scene(cameraPos, rd, fragCoord, quality, in.minDistance, in.maxRaySteps, in.fractalScale, in.glowIntensity, in.foldingLimit, in.sphereRadius, lodIterations, in.time);
    
    // Use half precision for color accumulation
    half3 col = half3(0.0h);
    
    // === Depth for Spatial Reprojection ===
    // For visionOS ASW (Asynchronous SpaceWarp), we need accurate depth
    // Use raymarched distance converted to view-space depth
    float convergenceDepth = ret.x;
    
    if (ret.x < 900.0)
    {
        float3 p = cameraPos + ret.x * rd;
        
        // Skip normal calculation in extreme periphery - use cheap approximation
        float3 nor;
        if (quality > 0.2) {
            nor = GetNormal(p, ret.x, in.minDistance, in.fractalScale, in.foldingLimit, in.sphereRadius, lodIterations);
        } else {
            // Cheap normal approximation for periphery
            nor = normalize(p - cameraPos);
        }
        
        // Simplified lighting for periphery
        if (quality > 0.4) {
            // Full lighting calculation
            float3 spotLight = CameraPath(gTime + .03) + float3(sin(gTime*18.4), cos(gTime*17.98), sin(gTime * 22.53)) * 0.2;
            float3 spot = spotLight - p;
            float atten = length(spot);
            spot /= atten;
            
            half shaSpot = half(Shadow(p, spot, quality, in.minDistance, in.fractalScale, in.foldingLimit, in.sphereRadius, lodIterations));
            half shaSun = half(Shadow(p, sunDir, quality, in.minDistance, in.fractalScale, in.foldingLimit, in.sphereRadius, lodIterations));
            
            half bri = half(max(dot(spot, nor), 0.0) / pow(atten, 1.5) * 0.25);
            half briSun = half(max(dot(sunDir, nor), 0.0) * 0.2);
            
            col = Colour(p, ret.x, gTime, quality, in.minDistance, in.fractalScale, in.colorMix, in.foldingLimit, in.sphereRadius, max(int(in.colorIterations * quality), 2));
            col = (col * bri * shaSpot) + (col * briSun * shaSun);
            
            // Specular only in high quality
            if (quality > 0.7) {
                float3 ref = reflect(rd, nor);
                col += half3(pow(max(dot(spot, ref), 0.0), 10.0) * 2.0) * shaSpot * bri;
                col += half3(pow(max(dot(sunDir, ref), 0.0), 10.0) * 2.0) * shaSun * briSun;
            }
        } else {
            // Simplified diffuse-only lighting for periphery
            half diffuse = half(max(dot(nor, sunDir), 0.0) * 0.5 + 0.3);
            col = Colour(p, ret.x, gTime, quality, in.minDistance, in.fractalScale, in.colorMix, in.foldingLimit, in.sphereRadius, 2) * diffuse;
        }
    }
    
    // Simplified fog (half precision)
    half fogFactor = half(saturate(exp(-ret.x + 1.5)));
    col = mix(half3(0.02h, 0.03h, 0.04h), col, fogFactor);
    
    // Glow (half precision)
    half glow = half(ret.y);
    col += glow * glow * half3(0.02h, 0.04h, 0.1h);
    
    // === Temporal Anti-Aliasing Preparation ===
    // Subtle noise reduction for smoother reprojection
    // Clamp extreme values that cause shimmer during head movement
    col = clamp(col, half3(0.0h), half3(2.0h));
    
    // Post effects only in center (skip in periphery for performance)
    if (quality > 0.5) {
        col = PostEffects(col, half2(in.texCoord));
    } else {
        // Simple gamma only for periphery - faster and less prone to artifacts
        col = pow(saturate(col), half3(0.47h));
    }

    // === Output for visionOS Spatial Rendering ===
    // Color with premultiplied alpha for proper compositing
    output.color = float4(float3(col), 1.0);
    
    // Depth: Use rasterized depth from proxy geometry
    // This provides stable depth for visionOS reprojection/ASW
    // The proxy cube gives us correct world-space depth even though
    // the raymarched content is in a different coordinate space
    output.depth = in.position.z;
    
    return output;
}

// MetalFX path: render each eye in a separate pass, selecting the eye explicitly.
vertex ColorInOut vertexShaderEyeIndex(Vertex in [[stage_in]],
                                       constant UniformsArray & uniformsArray [[ buffer(BufferIndexUniforms) ]],
                                       constant uint & eyeIndex [[ buffer(BufferIndexEyeIndex) ]])
{
    ColorInOut out;

    Uniforms uniforms = uniformsArray.uniforms[eyeIndex];
    float4 position = float4(in.position, 1);
    out.position = uniforms.projectionMatrix * uniforms.modelViewMatrix * position;
    out.ndcPosition = out.position;

    out.texCoord = in.texCoord;
    out.time = uniforms.time;
    out.modelPos = in.position;
    out.minDistance = uniforms.minDistance;
    out.foveaCenter = uniforms.foveaCenter;
    out.fractalScale = uniforms.fractalScale;
    out.fractalIterations = uniforms.fractalIterations;
    out.maxRaySteps = uniforms.maxRaySteps;
    out.foveationIntensity = uniforms.foveationIntensity;
    out.colorMix = uniforms.colorMix;
    out.glowIntensity = uniforms.glowIntensity;
    out.foldingLimit = uniforms.foldingLimit;
    out.sphereRadius = uniforms.sphereRadius;
    out.colorIterations = uniforms.colorIterations;

    return out;
}

fragment FragmentOutput fragmentShaderEyeIndex(ColorInOut in [[stage_in]],
                                               constant UniformsArray & uniformsArray [[buffer(BufferIndexUniforms)]],
                                               constant uint & eyeIndex [[ buffer(BufferIndexEyeIndex) ]],
                                               texture2d<half> cubeMap [[texture(TextureIndexColor)]])
{
    FragmentOutput output;

    float gTime = in.time * 0.01 + 15.00;

    Uniforms uniforms = uniformsArray.uniforms[eyeIndex];
    float3 cameraPos = (uniforms.inverseModelViewMatrix * float4(0,0,0,1)).xyz;
    float3 rd = normalize(in.modelPos - cameraPos);

    float2 fragCoord = in.position.xy;

    float distFromCenter = length(in.texCoord - float2(0.5, 0.5));
    float edgeAtten = smoothstep(0.5, 0.8, distFromCenter);
    float quality = mix(1.0, 0.7, edgeAtten * in.foveationIntensity);
    int lodIterations = max(int(float(in.fractalIterations) * (0.4 + 0.6 * quality)), 2);

    float2 ret = Scene(cameraPos, rd, fragCoord, quality, in.minDistance, in.maxRaySteps, in.fractalScale, in.glowIntensity, in.foldingLimit, in.sphereRadius, lodIterations, in.time);
    half3 col = half3(0.0h);

    if (ret.x < 900.0)
    {
        float3 p = cameraPos + ret.x * rd;

        float3 nor;
        if (quality > 0.2) {
            nor = GetNormal(p, ret.x, in.minDistance, in.fractalScale, in.foldingLimit, in.sphereRadius, lodIterations);
        } else {
            nor = normalize(p - cameraPos);
        }

        if (quality > 0.4) {
            float3 spotLight = CameraPath(gTime + .03) + float3(sin(gTime*18.4), cos(gTime*17.98), sin(gTime * 22.53)) * 0.2;
            float3 spot = spotLight - p;
            float atten = length(spot);
            spot /= atten;

            half shaSpot = half(Shadow(p, spot, quality, in.minDistance, in.fractalScale, in.foldingLimit, in.sphereRadius, lodIterations));
            half shaSun = half(Shadow(p, sunDir, quality, in.minDistance, in.fractalScale, in.foldingLimit, in.sphereRadius, lodIterations));

            half bri = half(max(dot(spot, nor), 0.0) / pow(atten, 1.5) * 0.25);
            half briSun = half(max(dot(sunDir, nor), 0.0) * 0.2);

            col = Colour(p, ret.x, gTime, quality, in.minDistance, in.fractalScale, in.colorMix, in.foldingLimit, in.sphereRadius, max(int(in.colorIterations * quality), 2));
            col = (col * bri * shaSpot) + (col * briSun * shaSun);

            if (quality > 0.7) {
                float3 ref = reflect(rd, nor);
                col += half3(pow(max(dot(spot, ref), 0.0), 10.0) * 2.0) * shaSpot * bri;
                col += half3(pow(max(dot(sunDir, ref), 0.0), 10.0) * 2.0) * shaSun * briSun;
            }
        } else {
            half diffuse = half(max(dot(nor, sunDir), 0.0) * 0.5 + 0.3);
            col = Colour(p, ret.x, gTime, quality, in.minDistance, in.fractalScale, in.colorMix, in.foldingLimit, in.sphereRadius, 2) * diffuse;
        }
    }

    half fogFactor = half(saturate(exp(-ret.x + 1.5)));
    col = mix(half3(0.02h, 0.03h, 0.04h), col, fogFactor);

    half glow = half(ret.y);
    col += glow * glow * half3(0.02h, 0.04h, 0.1h);

    col = clamp(col, half3(0.0h), half3(2.0h));

    if (quality > 0.5) {
        col = PostEffects(col, half2(in.texCoord));
    } else {
        col = pow(saturate(col), half3(0.47h));
    }

    output.color = float4(float3(col), 1.0);
    output.depth = in.position.z;
    return output;
}

// === Format Conversion Shaders for MetalFX ===
// Used to convert rgba16Float MetalFX output to drawable format (BGRA8Unorm_sRGB)

struct FormatConversionVertex {
    float4 position [[position]];
    float2 texCoord;
};

// Full-screen triangle vertex shader - generates vertices procedurally
vertex FormatConversionVertex formatConversionVertex(uint vertexID [[vertex_id]]) {
    FormatConversionVertex out;
    
    // Generate full-screen triangle using oversized triangle technique
    float2 position;
    position.x = (vertexID == 1) ? 3.0 : -1.0;
    position.y = (vertexID == 2) ? 3.0 : -1.0;
    
    out.position = float4(position, 0.0, 1.0);
    
    // Convert clip space to UV coordinates
    out.texCoord.x = (position.x + 1.0) * 0.5;
    out.texCoord.y = (1.0 - position.y) * 0.5;  // Flip Y for Metal
    
    return out;
}

// Simple passthrough fragment shader with format conversion
// Uses nearest filtering since MetalFX output matches drawable size exactly
fragment float4 formatConversionFragment(FormatConversionVertex in [[stage_in]],
                                          texture2d<float> sourceTexture [[texture(0)]]) {
    constexpr sampler textureSampler(mag_filter::nearest, min_filter::nearest, 
                                      address::clamp_to_edge);
    
    float4 color = sourceTexture.sample(textureSampler, in.texCoord);
    
    // Ensure alpha is 1 for proper visionOS compositing
    return float4(color.rgb, 1.0);
}

struct DepthOutput {
    float depth [[depth(any)]];
};

// Fragment shader for depth upscaling
fragment DepthOutput depthUpscaleFragment(FormatConversionVertex in [[stage_in]],
                                          depth2d<float> sourceTexture [[texture(0)]]) {
    constexpr sampler textureSampler(mag_filter::nearest, min_filter::nearest, 
                                      address::clamp_to_edge);
    
    DepthOutput out;
    out.depth = sourceTexture.sample(textureSampler, in.texCoord);
    return out;
}
