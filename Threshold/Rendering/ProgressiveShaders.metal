//
//  ProgressiveShaders.metal
//  Threshold
//
//  Diagnostic kernels to profile SPECIFIC parts of the rendering pipeline.
//  Goal: Find exactly where time is being spent in YOUR code.
//
//  Profiling Strategy:
//  1. Run each kernel variant on same scene
//  2. Compare times to isolate bottlenecks:
//     - SDF only (no shading)
//     - SDF + normals (6 extra SDF calls)
//     - Full shading
//     - Different iteration counts
//

#include <metal_stdlib>
#include <simd/simd.h>
#import "ShaderTypes.h"

using namespace metal;

// ============================================================================
// DIAGNOSTIC UNIFORMS
// ============================================================================

struct DiagnosticUniforms {
    // Matrices
    float4x4 projectionMatrix;
    float4x4 viewMatrix;
    float4x4 inverseViewMatrix;
    float4x4 inverseProjectionMatrix;
    
    // Resolution
    float2 resolution;
    
    // Fractal parameters (matching your main shader)
    float time;
    float minDistance;        // minRadius² for sphere fold
    float fractalScale;
    float foldingLimit;
    float sphereRadius;
    int fractalIterations;
    int maxRaySteps;
    
    // Diagnostic controls
    int diagnosticMode;       // Which component to test
    int forceIterations;      // Override iterations (0 = use fractalIterations)
    int forceRaySteps;        // Override ray steps (0 = use maxRaySteps)
};

// Diagnostic modes
constant int DIAG_SDF_ONLY = 0;           // Just raymarch, count steps
constant int DIAG_SDF_PLUS_NORMAL = 1;    // Raymarch + 6-point normal
constant int DIAG_FULL_SHADE = 2;         // Raymarch + normal + lighting
constant int DIAG_ITERATION_COST = 3;     // Time SDF at fixed position, varying iterations
constant int DIAG_NORMAL_COST = 4;        // Time normal calculation only
constant int DIAG_MAP_ONLY = 5;           // Single Map() call per pixel (baseline)

// ============================================================================
// YOUR EXACT SDF IMPLEMENTATION (copied from Shaders.metal)
// ============================================================================

// Mandelbox SDF matching your main shader exactly
inline float mandelboxSDF_exact(
    float3 pos,
    float scale,
    float foldingLimit,
    float sphereRadius,
    float minDistance,  // minRadius²
    int iterations
) {
    float4 p = float4(pos, 1.0);
    float4 p0 = p;
    
    float sphereRadiusSq = sphereRadius * sphereRadius;
    float invSphereRadiusSq = 1.0 / sphereRadiusSq;
    
    // This matches your MAP_ITERATION_BASIC macro exactly
    for (int i = 0; i < iterations; i++) {
        // Box fold
        p.xyz = clamp(p.xyz, -foldingLimit, foldingLimit) * 2.0 - p.xyz;
        
        // Sphere fold  
        float r2 = dot(p.xyz, p.xyz);
        float t = clamp(1.0 / max(r2, sphereRadiusSq), 1.0, invSphereRadiusSq);
        p *= t;
        
        // Scale and offset
        p = p * scale + p0;
    }
    
    // Distance estimate (matching your FractalParams calculation)
    float absScale = abs(scale);
    float absScalem1 = absScale - 1.0;
    float absScalePow = pow(absScale, float(1 - iterations));
    
    return (length(p.xyz) - absScalem1) / p.w - absScalePow;
}

// Normal via central differences (YOUR exact 6-point gradient)
inline float3 computeNormal_exact(
    float3 pos,
    float scale,
    float foldingLimit,
    float sphereRadius,
    float minDistance,
    int iterations
) {
    float eps = 0.001;
    
    // 6 SDF evaluations for gradient
    float dx = mandelboxSDF_exact(pos + float3(eps, 0, 0), scale, foldingLimit, sphereRadius, minDistance, iterations) -
               mandelboxSDF_exact(pos - float3(eps, 0, 0), scale, foldingLimit, sphereRadius, minDistance, iterations);
    float dy = mandelboxSDF_exact(pos + float3(0, eps, 0), scale, foldingLimit, sphereRadius, minDistance, iterations) -
               mandelboxSDF_exact(pos - float3(0, eps, 0), scale, foldingLimit, sphereRadius, minDistance, iterations);
    float dz = mandelboxSDF_exact(pos + float3(0, 0, eps), scale, foldingLimit, sphereRadius, minDistance, iterations) -
               mandelboxSDF_exact(pos - float3(0, 0, eps), scale, foldingLimit, sphereRadius, minDistance, iterations);
    
    return normalize(float3(dx, dy, dz));
}

// ============================================================================
// DIAGNOSTIC KERNEL: Profiles different parts of your pipeline
// ============================================================================

kernel void diagnosticKernel(
    texture2d<float, access::write> outputTexture [[texture(0)]],
    constant DiagnosticUniforms &uniforms [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= uint(uniforms.resolution.x) || gid.y >= uint(uniforms.resolution.y)) {
        return;
    }
    
    // Generate ray (matching your compute shader)
    float2 uv = (float2(gid) + 0.5) / uniforms.resolution;
    float2 ndc = uv * 2.0 - 1.0;
    ndc.y = -ndc.y;
    
    float4 clipPos = float4(ndc, 0.0, 1.0);
    float4 viewPos = uniforms.inverseProjectionMatrix * clipPos;
    float3 viewDir = normalize(viewPos.xyz);
    float3 rd = normalize((uniforms.inverseViewMatrix * float4(viewDir, 0.0)).xyz);
    float3 ro = uniforms.inverseViewMatrix.columns[3].xyz;
    
    // Get iteration/step counts (allow override for testing)
    int iters = uniforms.forceIterations > 0 ? uniforms.forceIterations : uniforms.fractalIterations;
    int steps = uniforms.forceRaySteps > 0 ? uniforms.forceRaySteps : uniforms.maxRaySteps;
    
    float3 color = float3(0);
    
    // ═══════════════════════════════════════════════════════════════════════════
    // DIAGNOSTIC MODE 0: SDF ONLY
    // Just raymarch, no shading - measures pure SDF + loop cost
    // ═══════════════════════════════════════════════════════════════════════════
    if (uniforms.diagnosticMode == DIAG_SDF_ONLY) {
        float t = 0.0;
        int hitSteps = 0;
        bool hit = false;
        
        for (int i = 0; i < steps; i++) {
            float3 p = ro + t * rd;
            float d = mandelboxSDF_exact(p, uniforms.fractalScale, uniforms.foldingLimit,
                                          uniforms.sphereRadius, uniforms.minDistance, iters);
            hitSteps = i;
            
            if (d < 0.0001) {
                hit = true;
                break;
            }
            if (t > 50.0) break;
            t += d * 0.9;
        }
        
        // Encode: R = hit?, G = normalized step count, B = normalized distance
        color.r = hit ? 1.0 : 0.0;
        color.g = float(hitSteps) / float(steps);
        color.b = saturate(t / 50.0);
    }
    
    // ═══════════════════════════════════════════════════════════════════════════
    // DIAGNOSTIC MODE 1: SDF + NORMAL
    // Raymarch + 6-point normal calculation - measures normal cost
    // ═══════════════════════════════════════════════════════════════════════════
    else if (uniforms.diagnosticMode == DIAG_SDF_PLUS_NORMAL) {
        float t = 0.0;
        float3 hitPos;
        bool hit = false;
        
        for (int i = 0; i < steps; i++) {
            float3 p = ro + t * rd;
            float d = mandelboxSDF_exact(p, uniforms.fractalScale, uniforms.foldingLimit,
                                          uniforms.sphereRadius, uniforms.minDistance, iters);
            
            if (d < 0.0001) {
                hitPos = p;
                hit = true;
                break;
            }
            if (t > 50.0) break;
            t += d * 0.9;
        }
        
        if (hit) {
            // This adds 6 more SDF evaluations
            float3 n = computeNormal_exact(hitPos, uniforms.fractalScale, uniforms.foldingLimit,
                                            uniforms.sphereRadius, uniforms.minDistance, iters);
            color = n * 0.5 + 0.5;  // Visualize normal
        }
    }
    
    // ═══════════════════════════════════════════════════════════════════════════
    // DIAGNOSTIC MODE 2: FULL SHADE  
    // Raymarch + normal + basic lighting - approximate full cost
    // ═══════════════════════════════════════════════════════════════════════════
    else if (uniforms.diagnosticMode == DIAG_FULL_SHADE) {
        float t = 0.0;
        float3 hitPos;
        bool hit = false;
        
        for (int i = 0; i < steps; i++) {
            float3 p = ro + t * rd;
            float d = mandelboxSDF_exact(p, uniforms.fractalScale, uniforms.foldingLimit,
                                          uniforms.sphereRadius, uniforms.minDistance, iters);
            
            if (d < 0.0001) {
                hitPos = p;
                hit = true;
                break;
            }
            if (t > 50.0) break;
            t += d * 0.9;
        }
        
        if (hit) {
            float3 n = computeNormal_exact(hitPos, uniforms.fractalScale, uniforms.foldingLimit,
                                            uniforms.sphereRadius, uniforms.minDistance, iters);
            
            // Basic diffuse lighting
            float3 lightDir = normalize(float3(1.0, 1.0, 0.5));
            float diffuse = max(dot(n, lightDir), 0.0);
            float ambient = 0.15;
            
            // Position-based color (like your ColourWithScheme simplified)
            float3 baseColor = 0.5 + 0.5 * cos(float3(0.0, 2.0, 4.0) + hitPos.x * 2.0);
            color = baseColor * (ambient + diffuse * 0.85);
            
            // Distance fog
            float fog = exp(-t * 0.05);
            color = mix(float3(0.02, 0.02, 0.05), color, fog);
        } else {
            color = float3(0.02);
        }
    }
    
    // ═══════════════════════════════════════════════════════════════════════════
    // DIAGNOSTIC MODE 3: ITERATION COST
    // Fixed position, measure SDF at varying iteration counts
    // ═══════════════════════════════════════════════════════════════════════════
    else if (uniforms.diagnosticMode == DIAG_ITERATION_COST) {
        // Use a fixed test position inside the fractal
        float3 testPos = ro + rd * 2.0;  // 2 units into scene
        
        // Run SDF multiple times to get measurable time
        float result = 0.0;
        for (int rep = 0; rep < 100; rep++) {
            result += mandelboxSDF_exact(testPos + float3(float(rep) * 0.0001), 
                                          uniforms.fractalScale, uniforms.foldingLimit,
                                          uniforms.sphereRadius, uniforms.minDistance, iters);
        }
        
        // Encode result to prevent optimization
        color = float3(fract(result * 0.01));
    }
    
    // ═══════════════════════════════════════════════════════════════════════════
    // DIAGNOSTIC MODE 4: NORMAL COST ONLY
    // Assume hit at fixed distance, measure just normal calculation
    // ═══════════════════════════════════════════════════════════════════════════
    else if (uniforms.diagnosticMode == DIAG_NORMAL_COST) {
        float3 testPos = ro + rd * 2.0;
        
        // Run normal calc multiple times
        float3 accumNormal = float3(0);
        for (int rep = 0; rep < 50; rep++) {
            accumNormal += computeNormal_exact(testPos + float3(float(rep) * 0.0001),
                                                uniforms.fractalScale, uniforms.foldingLimit,
                                                uniforms.sphereRadius, uniforms.minDistance, iters);
        }
        
        color = normalize(accumNormal) * 0.5 + 0.5;
    }
    
    // ═══════════════════════════════════════════════════════════════════════════
    // DIAGNOSTIC MODE 5: SINGLE MAP CALL (baseline)
    // One SDF evaluation per pixel - minimum possible work
    // ═══════════════════════════════════════════════════════════════════════════
    else if (uniforms.diagnosticMode == DIAG_MAP_ONLY) {
        float3 testPos = ro + rd * 2.0;
        float d = mandelboxSDF_exact(testPos, uniforms.fractalScale, uniforms.foldingLimit,
                                      uniforms.sphereRadius, uniforms.minDistance, iters);
        color = float3(saturate(d * 10.0));
    }
    
    outputTexture.write(float4(color, 1.0), gid);
}

