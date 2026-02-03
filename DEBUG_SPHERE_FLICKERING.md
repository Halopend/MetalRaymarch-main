# Debugging the Sphere Flickering Issue

## Problem Summary
After commit `e3b6d66fe0e22cf8d70224296612cc4cf95d6d41`, the fractal renders as a sphere that flickers between sphere and regular rendering. The fractal still responds to iteration changes but mostly shows sphere rendering.

## Root Cause Analysis
The issue is caused by a **dual-iteration system**:

1. **Compile-time `FC_FRACTAL_ITERATIONS`** (Function Constant) - Used in the actual distance field calculation in `Map()` function
2. **Runtime `uniforms.fractalIterations`** - Passed from Swift but only used for shadow/normal calculations, NOT the main fractal

When these get out of sync, you see:
- **Sphere rendering**: When `FC_FRACTAL_ITERATIONS` is very low (0-3), the fractal folds don't execute enough and the distance field degenerates to `d ≈ length(pos) - constant` which IS a sphere equation
- **Flickering**: When pipelines switch between different `FC_FRACTAL_ITERATIONS` values across frames

## Debug Logging Added

Run the app and watch the Xcode console for these log messages:

### 1. Pipeline Selection (Every Frame)
```
🎯 [PIPELINE SELECT] Iterations=10, RaySteps=64, Quality=0, Key=FI10_RS64_E0_N0_Q0
```
- **What it means**: Shows what iteration count is being requested and the cache key
- **Watch for**: Iteration count changing between frames (causes flickering)

### 2. Pipeline Cache Hit/Miss
```
✅ [PIPELINE CACHE HIT] Using pipeline: FI10_RS64_E0_N0_Q0
```
or
```
⚠️ [PIPELINE FALLBACK] Using quality-preset fallback: FI10_RS64_E0_N0_Q0 (requested: FI10_RS64_E1_N0_Q0)
```
or
```
🚨 [PIPELINE ULTIMATE FALLBACK] Using generic pipeline! FI=10 RS=64 - NO FUNCTION CONSTANTS!
```
- **What it means**: 
  - Cache hit = using specialized pipeline with function constants
  - Fallback = using a different pipeline (may have wrong iteration count)
  - Ultimate fallback = **NO function constants** (this would cause sphere rendering!)
- **Watch for**: Ultimate fallback messages or switching between different pipelines

### 3. Function Constants Being Set
```
🔧 [FUNCTION CONSTANT] Setting FC_FRACTAL_ITERATIONS = 10
```
- **What it means**: This is the ACTUAL iteration count that will be compiled into the shader
- **Watch for**: This value being different from the runtime iterations

### 4. Uniforms Population
```
📊 [UNIFORMS] fractalIterations=10, bubbleEnabled=true, bubbleRadius=2.5, bubbleShape=0.0
```
- **What it means**: Runtime values being sent to GPU each frame
- **Watch for**: 
  - `fractalIterations` different from `FC_FRACTAL_ITERATIONS`
  - Large `bubbleRadius` with `bubbleEnabled=true` (bubble could dominate and show sphere)

### 5. On-Demand Pipeline Building
```
🔨 [BUILD ON-DEMAND] Building pipeline FI10_RS64_E0_N0_Q0 with FC_FRACTAL_ITERATIONS=10
   ↳ Config: FI=10, shadow=8, raySteps=64, emissive=false, neon=false
```
- **What it means**: A new pipeline is being created because it wasn't in cache
- **Watch for**: These being created during rendering (causes frame hitches)

## How to Analyze the Output

### Scenario 1: Consistent Sphere Rendering
If you see:
```
🎯 [PIPELINE SELECT] Iterations=10, RaySteps=64, Quality=0, Key=FI10_RS64_E0_N0_Q0
🚨 [PIPELINE ULTIMATE FALLBACK] Using generic pipeline! FI=10 RS=64 - NO FUNCTION CONSTANTS!
📊 [UNIFORMS] fractalIterations=10, bubbleEnabled=false, ...
```

**Diagnosis**: The app is falling back to generic pipeline with NO function constants. The `Map()` function is likely using a default low value for iterations, causing sphere rendering.

**Solution**: Pre-build the pipeline for these settings or investigate why the cache lookup is failing.

### Scenario 2: Flickering Between Sphere and Fractal
If you see alternating:
```
Frame N:
🎯 [PIPELINE SELECT] Iterations=10, ...
✅ [PIPELINE CACHE HIT] Using pipeline: FI10_RS64_E0_N0_Q0

Frame N+1:
🎯 [PIPELINE SELECT] Iterations=2, ...  ← CHANGED!
✅ [PIPELINE CACHE HIT] Using pipeline: FI2_RS64_E0_N0_Q0

Frame N+2:
🎯 [PIPELINE SELECT] Iterations=10, ...  ← BACK!
```

**Diagnosis**: The `settingsSnapshot.fractalIterations` value is changing between frames, causing pipeline switching.

**Solution**: Investigate why the settings are unstable. Check for race conditions in `RenderSettings` updates.

### Scenario 3: Mismatch Between Runtime and Compile-Time Iterations
If you see:
```
🎯 [PIPELINE SELECT] Iterations=10, ...
🔧 [FUNCTION CONSTANT] Setting FC_FRACTAL_ITERATIONS = 2  ← MISMATCH!
📊 [UNIFORMS] fractalIterations=10, ...
```

**Diagnosis**: The pipeline is using `FC_FRACTAL_ITERATIONS=2` but runtime says `fractalIterations=10`. The fractal will render as a sphere (2 iterations is too low) but shadows/normals will use 10 iterations.

**Solution**: Ensure pipeline cache keys match the actual function constants being used.

### Scenario 4: Safety Bubble Causing Sphere
If you see:
```
📊 [UNIFORMS] fractalIterations=10, bubbleEnabled=true, bubbleRadius=50.0, bubbleShape=0.0
```

**Diagnosis**: The safety bubble has a huge radius (50.0) and is dominating the distance field, showing as a sphere.

**Solution**: Reduce `bubbleRadius` or disable `safetyBubbleEnabled`.

## Next Steps After Gathering Logs

1. **Run the app** in Xcode with console visible
2. **Watch for the patterns** described above
3. **Copy relevant logs** showing the issue
4. **Share the logs** to determine which scenario is occurring

## Potential Fixes

### Fix 1: Make Map() Use Runtime Iterations
Modify `Map()` in Shaders.metal to respect the runtime `iterations` parameter instead of only using `FC_FRACTAL_ITERATIONS`:

```metal
FORCE_INLINE float Map(float3 pos, FractalParams params, float foldingLimit, int iterations) 
{
    float4 p = float4(pos, 1.0);
    float4 p0 = p;
    float invSphereRadiusSq = 1.0f / params.sphereRadiusSq;

    // Use runtime iterations instead of function constant
    for (int i = 0; i < iterations; i++) {
        MAP_ITERATION_BASIC(p, p0, foldingLimit, params, invSphereRadiusSq);
    }
    
    // ... rest of function
}
```

**Tradeoff**: Loses loop unrolling optimization, may be slower.

### Fix 2: Always Keep Runtime and Compile-Time in Sync
Ensure that when a pipeline is selected, it ALWAYS has the correct `FC_FRACTAL_ITERATIONS` matching the runtime value, and never falls back to generic pipeline.

**Tradeoff**: More pipelines to cache, potential memory usage.

### Fix 3: Add a "Sphere Mode" Feature Toggle
If you like the sphere effect, add it as an intentional feature:
- Low iterations (1-3) = Sphere mode
- High iterations (8+) = Full fractal

**Tradeoff**: Changes the effect from a bug to a feature.
