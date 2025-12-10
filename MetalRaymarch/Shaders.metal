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
    float4 position [[position]];
    float2 texCoord;
    float time;
    float3 modelPos;
    float minDistance;
} ColorInOut;

vertex ColorInOut vertexShader(Vertex in [[stage_in]],
                               ushort ampId [[amplification_id]],
                               constant UniformsArray & uniformsArray [[ buffer(BufferIndexUniforms) ]])
{
    ColorInOut out;

    Uniforms uniforms = uniformsArray.uniforms[ampId];
    
    float4 position = float4(in.position, 1);
    out.position = uniforms.projectionMatrix * uniforms.modelViewMatrix * position;
    
    out.texCoord = in.texCoord;
    out.time = uniforms.time;
    out.modelPos = in.position;
    out.minDistance = uniforms.minDistance;
    
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

float Map(float3 pos, float minRad2Val) 
{
    float minRad2 = clamp(minRad2Val, 1.0e-9, 1.0);
    float4 scale = float4(SCALE, SCALE, SCALE, abs(SCALE)) / minRad2;
    float absScalem1 = abs(SCALE - 1.0);
    float AbsScaleRaisedTo1mIters = pow(abs(SCALE), float(1-10));

    float4 p = float4(pos,1);
    float4 p0 = p;

    for (int i = 0; i < 7; i++)
    {
        p.xyz = clamp(p.xyz, -1.0, 1.0) * 2.0 - p.xyz;

        float r2 = dot(p.xyz, p.xyz);
        p *= clamp(max(minRad2/r2, minRad2), 0.0, 1.0);

        p = p*scale + p0;
    }
    return ((length(p.xyz) - absScalem1) / p.w - AbsScaleRaisedTo1mIters);
}

float3 Colour(float3 pos, float sphereR, float gTime, float quality, float minRad2Val) 
{
    float minRad2 = clamp(minRad2Val, 1.0e-9, 1.0);
    float4 scale = float4(SCALE, SCALE, SCALE, abs(SCALE)) / minRad2;
    
    float3 surfaceColour1 = float3(.8, .0, 0.);
    float3 surfaceColour2 = float3(.4, .4, 0.5);
    float3 surfaceColour3 = float3(.5, 0.3, 0.00);

    float3 p = pos;
    float3 p0 = p;
    float trap = 1.0;
    
    int steps = int(5.0 * quality);
    if (steps < 3) steps = 3;
    for (int i = 0; i < steps; i++)
    {
        p = clamp(p, -1.0, 1.0) * 2.0 - p;
        float r2 = dot(p, p);
        p *= clamp(max(minRad2/r2, minRad2), 0.0, 1.0);

        p = p*scale.xyz + p0;
        trap = min(trap, r2);
    }
    
    float2 c = clamp(float2( 0.3333*log(dot(p,p))-1.0, sqrt(trap) ), 0.0, 1.0);

    float t = fmod(length(pos) - gTime*150., 16.0);
    surfaceColour1 = mix( surfaceColour1, float3(.4, 3.0, 5.), pow(smoothstep(0.0, .3, t) * smoothstep(0.6, .3, t), 10.0));
    return mix(mix(surfaceColour1, surfaceColour2, c.y), surfaceColour3, c.x);
}

float3 GetNormal(float3 pos, float distance, float minRad2Val)
{
    distance *= 0.001+.0001;
    float2 e = float2(1.0, -1.0) * distance;
    return normalize(
        e.xyy * Map(pos + e.xyy, minRad2Val) +
        e.yyx * Map(pos + e.yyx, minRad2Val) +
        e.yxy * Map(pos + e.yxy, minRad2Val) +
        e.xxx * Map(pos + e.xxx, minRad2Val)
    );
}

float BinarySubdivision(float3 rO, float3 rD, float2 t, float minRad2Val)
{
    float halfwayT;
  
    for (int i = 0; i < 6; i++)
    {
        halfwayT = dot(t, float2(.5));
        float d = Map(rO + halfwayT*rD, minRad2Val); 
        t = mix(float2(t.x, halfwayT), float2(halfwayT, t.y), step(0.0005, d));
    }

    return halfwayT;
}

float2 Scene(float3 rO, float3 rD, float2 fragCoord, float quality, float minRad2Val)
{
    // Dithering using hash instead of texture
    float t = .05 + 0.05 * hash(dot(fragCoord, float2(12.9898, 78.233)));
    
    float3 p = float3(0.0);
    float oldT = 0.0;
    bool hit = false;
    float glow = 0.0;
    float2 dist;
    
    int maxSteps = int(64.0 * quality);
    if (maxSteps < 12) maxSteps = 12;
    
    float threshold = 0.0008 + (1.0 - quality) * 0.0035;

    for( int j=0; j < maxSteps; j++ )
    {
        if (t > 12.0) break;
        p = rO + t*rD;
       
        float h = Map(p, minRad2Val);
        
        if(h < threshold)
        {
            dist = float2(oldT, t);
            hit = true;
            break;
        }
        glow += clamp(.05-h, 0.0, .4);
        oldT = t;
        t +=  h + t*0.001;
    }
    if (!hit)
        t = 1000.0;
    else       t = BinarySubdivision(rO, rD, dist, minRad2Val);
    return float2(t, clamp(glow*.25, 0.0, 1.0));
}

float3 PostEffects(float3 rgb, float2 xy)
{
    #define CONTRAST 1.08
    #define SATURATION 1.5
    #define BRIGHTNESS 1.5
    rgb = mix(float3(.5), mix(float3(dot(float3(.2125, .7154, .0721), rgb*BRIGHTNESS)), rgb*BRIGHTNESS, SATURATION), CONTRAST);
    
    rgb *= .5 + 0.5*pow(20.0*xy.x*xy.y*(1.0-xy.x)*(1.0-xy.y), 0.2);    

    rgb = pow(rgb, float3(0.47 ));
    return rgb;
}

float Shadow(float3 ro, float3 rd, float quality, float minRad2Val)
{
    float res = 1.0;
    float t = 0.05;
    float h;
    
    int steps = int(4.0 * quality);
    if (steps < 2) steps = 2;
    
    for (int i = 0; i < steps; i++)
    {
        h = Map( ro + rd*t, minRad2Val );
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

fragment float4 fragmentShader(ColorInOut in [[stage_in]],
                               texture2d<half> cubeMap [[texture(TextureIndexColor)]])
{
    float gTime = in.time * 0.01 + 15.00; // Adjusted time scale
    
    float3 cameraPos = CameraPath(gTime);
    // Optimization: Use interpolated model position for direction instead of expensive trig
    float3 rd = normalize(in.modelPos);
    
    // We don't have fragCoord in pixels, but we have texCoord.
    // Scene uses fragCoord for dithering. We can use texCoord * 1000 or something.
    float2 fragCoord = in.texCoord * 1000.0; 
    
    float3 spotLight = CameraPath(gTime + .03) + float3(sin(gTime*18.4), cos(gTime*17.98), sin(gTime * 22.53))*.2;
    float3 col = float3(0.0);
    
    // Calculate quality based on distance from center (0.5, 0.5)
    float distFromCenter = length(in.texCoord - 0.5);
    // Even more aggressive foveation: very small fovea, strong edge drop
    float edgeAtten = smoothstep(0.06, 0.28, distFromCenter);
    float quality = mix(1.0, 0.12, edgeAtten);
    
    float2 ret = Scene(cameraPos, rd, fragCoord, quality, in.minDistance);
    
    if (ret.x < 900.0)
    {
        float3 p = cameraPos + ret.x*rd; 
        float3 nor = GetNormal(p, ret.x, in.minDistance);
        
        float3 spot = spotLight - p;
        float atten = length(spot);

        spot /= atten;
        float shaSpot = Shadow(p, spot, quality, in.minDistance);
        float shaSun = Shadow(p, sunDir, quality, in.minDistance);
        
        float bri = max(dot(spot, nor), 0.0) / pow(atten, 1.5) * .25;
        float briSun = max(dot(sunDir, nor), 0.0) * .2;
        
        col = Colour(p, ret.x, gTime, quality, in.minDistance);
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

    return float4(col, 1.0);
}
