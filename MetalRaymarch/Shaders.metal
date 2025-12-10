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

constant float3 sunDir = float3(0.3235, 0.0924, 0.2773); // normalized(0.35, 0.1, 0.3)
constant float3 sunColour = float3(1.0, 0.95, 0.8);
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
    half trap = 1.0h;
    
    int steps = max(int(float(colorIters) * quality), 2);
    for (int i = 0; i < steps; i++)
    {
        p = clamp(p, -foldingLimit, foldingLimit) * 2.0 - p;
        float r2 = dot(p, p);
        p *= clamp(1.0 / max(r2, minRadius2), 1.0, 1.0/minRadius2);
        p = p * scale.xyz + p0;
        trap = min(trap, half(r2));
    }
    
    half2 c = saturate(half2(0.3333h * log(half(dot(p,p))) - 1.0h, sqrt(trap)));
    
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

float2 Scene(float3 rO, float3 rD, float2 fragCoord, float quality, float minRad2Val, int maxStepsParam, float fractalScale, float glowIntensity, float foldingLimit, float sphereRadius, int iterations)
{
    // Faster hash for dithering
    float t = 0.05 + 0.02 * fract(sin(dot(fragCoord, float2(12.9898, 78.233))) * 43758.5453);
    
    float oldT = 0.0;
    float glow = 0.0;
    float2 dist = float2(0.0);
    
    int maxSteps = max(int(float(maxStepsParam) * quality), 6);
    float threshold = 0.001 + (1.0 - quality) * 0.004;
    
    // Adaptive step multiplier for faster convergence
    float stepMult = 1.0 + (1.0 - quality) * 0.5;

    for(int j = 0; j < maxSteps; j++)
    {
        float3 p = rO + t * rD;
        float h = Map(p, minRad2Val, fractalScale, foldingLimit, sphereRadius, iterations);
        
        if(h < threshold)
        {
            dist = float2(oldT, t);
            // Skip binary subdivision in low quality mode
            if (quality > 0.5) {
                t = BinarySubdivision(rO, rD, dist, minRad2Val, fractalScale, foldingLimit, sphereRadius, iterations);
            }
            return float2(t, saturate(glow * 0.25));
        }
        
        // Early out for far rays
        if (t > 10.0) break;
        
        glow += saturate(0.05 - h) * glowIntensity;
        oldT = t;
        // Adaptive stepping: larger steps when far from surface
        t += h * stepMult + t * 0.002;
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

// Ultra-fast shadow approximation
float Shadow(float3 ro, float3 rd, float quality, float minRad2Val, float fractalScale, float foldingLimit, float sphereRadius, int iterations)
{
    // Skip shadows entirely in low quality peripheral vision
    if (quality < 0.3) return 0.7;
    
    float res = 1.0;
    float t = 0.1;
    
    // Adaptive steps: 1-3 based on quality
    int steps = int(2.0 * quality) + 1;
    
    for (int i = 0; i < steps; i++)
    {
        float h = Map(ro + rd * t, minRad2Val, fractalScale, foldingLimit, sphereRadius, max(iterations - 2, 3));
        res = min(res, 8.0 * h / t);
        t += max(h, 0.1); // Minimum step to prevent slow convergence
        if (res < 0.01) break; // Early out when in shadow
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
    
    float3 cameraPos = CameraPath(gTime);
    float3 rd = normalize(in.modelPos);
    float2 fragCoord = in.texCoord * 1000.0;
    
    // Foveation quality calculation
    float2 foveaCenter = in.foveaCenter;
    if (foveaCenter.x == 0.0 && foveaCenter.y == 0.0) {
        foveaCenter = float2(0.5, 0.5);
    }
    float distFromFovea = length(in.texCoord - foveaCenter);
    float edgeAtten = smoothstep(0.05, 0.3, distFromFovea);
    float quality = mix(1.0, 0.1, edgeAtten * in.foveationIntensity);
    
    // LOD: Reduce fractal iterations in periphery
    int lodIterations = max(int(float(in.fractalIterations) * (0.5 + 0.5 * quality)), 3);
    
    float2 ret = Scene(cameraPos, rd, fragCoord, quality, in.minDistance, in.maxRaySteps, in.fractalScale, in.glowIntensity, in.foldingLimit, in.sphereRadius, lodIterations);
    
    // Use half precision for color accumulation
    half3 col = half3(0.0h);
    
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
    
    // Post effects only in center (skip in periphery for performance)
    if (quality > 0.5) {
        col = PostEffects(col, half2(in.texCoord));
    } else {
        // Simple gamma only
        col = pow(saturate(col), half3(0.47h));
    }

    output.color = float4(float3(col), 1.0);
    output.depth = in.position.z;
    
    return output;
}
