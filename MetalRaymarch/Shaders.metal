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

// Optimized colour function
float3 Colour(float3 pos, float sphereR, float gTime, float quality, float minRad2Val, float fractalScale, float colorMix, float foldingLimit, float sphereRadius, int colorIters) 
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
        // Branchless sphere fold
        p *= clamp(1.0 / max(r2, minRadius2), 1.0, 1.0/minRadius2);
        p = p * scale.xyz + p0;
        trap = min(trap, r2);
    }
    
    float2 c = saturate(float2(0.3333 * log(dot(p,p)) - 1.0, sqrt(trap)));
    
    // Simplified color calculation
    float3 col1 = float3(.8, .0, 0.);
    float3 col2 = float3(.4, .4, 0.5);
    float3 col3 = float3(.5, 0.3, 0.0);
    
    float3 finalColor = mix(mix(col1, col2, c.y), col3, c.x);
    float3 altColor = float3(c.x, c.y, 0.5 + 0.3*c.y);
    return mix(finalColor, altColor, colorMix);
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

// Simplified post effects for performance
float3 PostEffects(float3 rgb, float2 xy)
{
    // Combined contrast/saturation/brightness in fewer ops
    float luma = dot(rgb, float3(0.2126, 0.7152, 0.0722));
    rgb = mix(float3(luma), rgb, 1.5) * 1.5; // saturation + brightness
    rgb = mix(float3(0.5), rgb, 1.08);       // contrast
    
    // Simplified vignette
    float2 q = xy * (1.0 - xy);
    rgb *= 0.5 + 0.5 * pow(16.0 * q.x * q.y, 0.2);
    
    // Gamma
    return pow(rgb, float3(0.47));
}

float Shadow(float3 ro, float3 rd, float quality, float minRad2Val, float fractalScale, float foldingLimit, float sphereRadius, int iterations)
{
    float res = 1.0;
    float t = 0.05;
    float h;
    
    int steps = int(4.0 * quality);
    if (steps < 2) steps = 2;
    
    for (int i = 0; i < steps; i++)
    {
        h = Map( ro + rd*t, minRad2Val, fractalScale, foldingLimit, sphereRadius, iterations );
        res = min(6.0*h / t, res);
        t += h;
    }
    return max(res, 0.0);
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
    
    float gTime = in.time * 0.01 + 15.00; // Adjusted time scale
    
    float3 cameraPos = CameraPath(gTime);
    // Optimization: Use interpolated model position for direction instead of expensive trig
    float3 rd = normalize(in.modelPos);
    
    // We don't have fragCoord in pixels, but we have texCoord.
    // Scene uses fragCoord for dithering. We can use texCoord * 1000 or something.
    float2 fragCoord = in.texCoord * 1000.0; 
    
    float3 spotLight = CameraPath(gTime + .03) + float3(sin(gTime*18.4), cos(gTime*17.98), sin(gTime * 22.53))*.2;
    float3 col = float3(0.0);
    
    // Calculate quality based on distance from fovea center with adjustable intensity
    float2 foveaCenter = in.foveaCenter;
    if (foveaCenter.x == 0.0 && foveaCenter.y == 0.0) {
        foveaCenter = float2(0.5, 0.5);
    }
    float distFromFovea = length(in.texCoord - foveaCenter);
    float edgeAtten = smoothstep(0.05, 0.25, distFromFovea);
    float quality = mix(1.0, 0.15, edgeAtten * in.foveationIntensity);
    
    float2 ret = Scene(cameraPos, rd, fragCoord, quality, in.minDistance, in.maxRaySteps, in.fractalScale, in.glowIntensity, in.foldingLimit, in.sphereRadius, in.fractalIterations);
    
    if (ret.x < 900.0)
    {
        float3 p = cameraPos + ret.x*rd; 
        float3 nor = GetNormal(p, ret.x, in.minDistance, in.fractalScale, in.foldingLimit, in.sphereRadius, in.fractalIterations);
        
        float3 spot = spotLight - p;
        float atten = length(spot);

        spot /= atten;
        float shaSpot = Shadow(p, spot, quality, in.minDistance, in.fractalScale, in.foldingLimit, in.sphereRadius, in.fractalIterations);
        float shaSun = Shadow(p, sunDir, quality, in.minDistance, in.fractalScale, in.foldingLimit, in.sphereRadius, in.fractalIterations);
        
        float bri = max(dot(spot, nor), 0.0) / pow(atten, 1.5) * .25;
        float briSun = max(dot(sunDir, nor), 0.0) * .2;
        
        col = Colour(p, ret.x, gTime, quality, in.minDistance, in.fractalScale, in.colorMix, in.foldingLimit, in.sphereRadius, int(in.colorIterations));
        col = (col * bri * shaSpot) + (col * briSun * shaSun);
        
        float3 ref = reflect(rd, nor);
        col += pow(max(dot(spot,  ref), 0.0), 10.0) * 2.0 * shaSpot * bri;
        col += pow(max(dot(sunDir, ref), 0.0), 10.0) * 2.0 * shaSun * briSun;
    }
    
    float fogFactor = min(exp(-ret.x+1.5), 1.0);
    float3 sky = float3(0.0);
    if (fogFactor < 0.99) {
        sky = float3(0.03, .04, .05) * GetSky(rd);
    }
    
    col = mix(sky, col, fogFactor);
    col += float3(pow(abs(ret.y), 2.)) * float3(.02, .04, .1);

    col += LightSource(spotLight-cameraPos, rd, ret.x);
    
    col = PostEffects(col, in.texCoord);    

    output.color = float4(col, 1.0);
    
    // Use the rasterized depth from the proxy geometry (in.position.z)
    // This is already in correct NDC space for visionOS reprojection
    // visionOS uses reverse-Z: 1.0 = near, 0.0 = far
    output.depth = in.position.z;
    
    return output;
}
