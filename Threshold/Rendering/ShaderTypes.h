//
//  ShaderTypes.h
//

//
//  Header containing types and enum constants shared between Metal shaders and Swift/ObjC source
//
#ifndef ShaderTypes_h
#define ShaderTypes_h

#ifdef __METAL_VERSION__
#define NS_ENUM(_type, _name) enum _name : _type _name; enum _name : _type
typedef metal::int32_t EnumBackingType;
#elif defined(__OBJC__)
#include <Foundation/Foundation.h>
typedef NSInteger EnumBackingType;
#else
#include <stdint.h>
#ifndef NS_ENUM
    #define NS_ENUM(_type, _name) enum _name
#endif
typedef int32_t EnumBackingType;
#endif

#include <simd/simd.h>

typedef NS_ENUM(EnumBackingType, BufferIndex)
{
    BufferIndexMeshPositions = 0,
    BufferIndexMeshGenerics  = 1,
    BufferIndexUniforms      = 2
};

typedef NS_ENUM(EnumBackingType, VertexAttribute)
{
    VertexAttributePosition  = 0,
    VertexAttributeTexcoord  = 1,
};

typedef NS_ENUM(EnumBackingType, TextureIndex)
{
    TextureIndexColor    = 0,
    TextureIndexPrevDepth = 1   // Previous-frame depth for temporal march warm-start
};

// Function constant indices for shader specialization
// When defined, these become compile-time constants enabling automatic loop unrolling
// and dead code elimination by the Metal compiler.
typedef NS_ENUM(EnumBackingType, FunctionConstantIndex)
{
    FCIndexFractalIterations   = 0,  // int: Fractal iteration count (enables Map() loop auto-unrolling)
    FCIndexShadowIterations    = 1,  // int: Shadow iteration count
    FCIndexSafetyBubbleEnabled = 2,  // bool: Safety bubble feature toggle
    FCIndexQualityMode         = 4,  // int: 0=high, 1=medium, 2=low - controls feature degradation
    FCIndexDebugHierarchical   = 5,  // bool: Debug visualization toggle
    FCIndexMaxRaySteps         = 6,  // int: Max raymarch steps (enables loop optimization)
    FCIndexFractalType         = 7,  // int: Devirtualize FractalDE_Dispatch
    FCIndexNeonModeEnabled     = 8,  // bool: Toggle neon orbit traps
    FCIndexColorIterations     = 9,  // int: Loop unrolling for ColourWithScheme
    FCIndexShareShadows        = 10, // bool: Share shadows (set in shader)
    FCIndexShadowsEnabled      = 11, // bool: Toggle shadow computation
    FCIndexMandelbulbPower     = 12, // int: Bake Mandelbulb power for fastPowR optimization
    FCIndexWarmStart           = 13, // bool: Compile in temporal-depth march warm-start (visionOS fragment path)
};

// Fractal type selection
typedef NS_ENUM(EnumBackingType, FractalType)
{
    FractalTypeMandelbox         = 0,
    FractalTypeMandelbulb        = 1,
    FractalTypeMenger            = 2,
    FractalTypeMandelbulbJulia   = 5,
    FractalTypeQuaternionJulia   = 6,
    FractalTypeOctahedron        = 11,
    FractalTypeMengerSphere        = 14,
    FractalTypeTheliPseudoKleinian = 15,
    FractalTypeKleinian              = 17,
    FractalTypeBoxSphereFolder         = 20,
    FractalTypeMandelboxSphereProjection = 21,
    // Sentinel for runtime-compiled custom DE formulas (.threshfx).
    // The static dispatch in FractalFormulas.h returns far for this value;
    // custom rendering uses a separately-compiled MTLLibrary.
    FractalTypeCustom                  = 1000,
};

// === FORMULA PARAMETERS ===
// Generic parameter block for non-Mandelbox fractal formulas.
// 16 float slots + 2 rotation matrices, bridging Swift ↔ GPU.
enum {
    FormulaRotationFlagRot1NonIdentity = 1 << 0,
    FormulaRotationFlagRot2NonIdentity = 1 << 1,
};

typedef struct
{
    float params[16];                  // Up to 16 formula-specific parameters
    matrix_float3x3 rotMatrix1;        // Primary rotation matrix
    matrix_float3x3 rotMatrix2;        // Secondary rotation matrix (IFS types)
    uint32_t rotationFlags;            // Bitmask of FormulaRotationFlag* (precomputed on CPU)
    uint32_t _formulaPad[3];           // Keep 16-byte alignment for uniform packing
} FormulaParams;

// Maximum gradient stops supported (matches GradientColorSystem.swift)
#define MAX_GRADIENT_STOPS 8

// Color scheme parameters passed to shader
// Allows full customization of the fractal coloring
typedef struct
{
    // Post-processing adjustments
    float saturation;                 // Color saturation multiplier (default 1.5)
    float contrast;                   // Contrast adjustment (default 1.05)
    float gamma;                      // Gamma correction (default 0.5)
    float brightness;                 // Brightness offset (default 0.0)
    float vibrance;                   // Saturation that protects highlights
    float colorCurve;                 // Midtone curve adjustment
    float shadows;                    // Shadow adjustment
    float highlights;                 // Highlight adjustment
    int cellShadingEnabled;           // 0 = smooth lighting, 1 = quantized diffuse bands
    float cellShadingLevels;          // Number of lighting bands (2-8)
    float cellEdgeStrength;           // Reserved for outline/rim strength
    float _cellPad;                   // Alignment padding
    
    // Neon mode parameters (HSV-based orbit trap coloring)
    float neonIntensity;              // 0 = off, 1 = full neon mode
    float hueFrequency;               // Frequency of hue variation (default 3.0)
    float hueOffset;                  // Base hue offset (default 0.0)
    float bandFrequency;              // Distance band frequency for glow rings (default 8.0)
    float glowSharpness;              // How sharp the bright cores are (default 3.0)
    float saturationPower;            // Power for saturation curve, <1 flattens to 1.0 (default 0.4)
    
    // === GRADIENT COLORING SYSTEM ===
    // Replaces fixed 3-color palettes with up to 8 user-defined gradient stops.
    // Each stop packs color (xyz) + position (w) into a float4.
    vector_float4 gradientStops[MAX_GRADIENT_STOPS]; // float4(r, g, b, position)
    int gradientStopCount;            // Number of active stops (0 = fall back to white)
    int colorMappingMode;             // 0=orbitTrap, 1=iterations, 2=zDepth, 3=angle, 4=normal, 5=blended
    float gradientRepeat;             // How many times gradient repeats (default 1.0)
    float gradientOffset;             // Shifts gradient start (0-1)
    float gradientSmoothing;          // 0 = sharp, 1 = smooth transitions (default 1.0)
    int gradientLoopSmooth;           // 0 = hard cut at edges, 1 = smooth wrap (last stop blends to first)
    float _gradPad[1];                // Alignment padding for gradient section
    
    // === MODULAR LIGHTING EFFECTS ===
    // Animation time (shared by all effects)
    float animTime;                   // Current animation time (seconds)
    
    // Hue Rotation Effect - rotates colors through YIQ space
    int hueRotationEnabled;           // 0 = off, 1 = on
    float hueCyclePhase;              // Pre-integrated rotation phase in radians (∫ speed·dt on CPU, treble boost baked in) — avoids phase snaps on speed/audio changes
    float hueRotationIntensity;       // Blend intensity (0-1), prevents overpowering

    // Pulse Effect - rhythmic brightness/saturation variation
    int pulseEnabled;                 // 0 = off, 1 = on
    float pulseCyclePhase;            // Pre-integrated pulse phase in radians (∫ speed·dt on CPU) — avoids phase snaps on speed changes
    float pulseAmount;                // Pulse intensity (0-1)
    
    // Glow Effect - ray-step based inner glow
    int glowEnabled;                  // 0 = off, 1 = on
    float glowIntensity;              // Glow brightness (0-1)
    
    // Bloom Effect - bright areas bleed
    int bloomEnabled;                 // 0 = off, 1 = on
    float bloomStrength;              // Bloom intensity (0-1)
    
    // Beat Flash Effect - music-driven edge glow
    int beatFlashEnabled;             // 0 = off, 1 = on
    float beatFlashIntensity;         // Flash strength (0-1), multiplied by beat level
    
    // Note: fog is handled entirely by PrecomputedFog — no per-pixel fog fields here.
    // fogEnabled/fogIntensity live in RenderSettings for CPU precomputation only.
} ColorSchemeParams;

// === PRECOMPUTED FRACTAL PARAMETERS ===
// These are frame-uniform values computed once on CPU and shared by all pixels.
// This eliminates redundant per-pixel calculations like expensive powr() calls.
typedef struct
{
    vector_float4 scale;              // fractalScale / minDistance (xyz), abs(w)
    float absScalem1;                 // abs(fractalScale - 1.0)
    float absScalePow;                // powr(abs(fractalScale), 1 - iterations) - EXPENSIVE, precompute!
    float invSphereRadiusSq;          // 1.0 / (sphereRadius * sphereRadius)
    float sphereRadiusSq;             // sphereRadius * sphereRadius
} PrecomputedFractalParams;

// === PRECOMPUTED LIGHTING ===
// Spotlight position/intensity depend only on time + lighting mode, and the
// vibrance/softness sun blend depends only on frame-uniform settings.
// Computing any of these per-pixel wastes GPU cycles on identical results.
typedef struct
{
    vector_float3 spotLightPosition;  // Precomputed spotlight world position
    float lightIntensity;             // BLENDED intensity (mode base × vibrance/softness scale)
    vector_float3 sunDir;             // Blended sun direction (soft ↔ sharp by vibrance/softness)
    float sunDiffuseScale;            // Blended sun diffuse scale
    float specPower;                  // mix(20, 110, saturate(1 - lightingSoftness))
    vector_float2 _padLighting;       // Pad struct to a 16-byte multiple
} PrecomputedLighting;

// === PRECOMPUTED AUDIO ===
// Packs per-band audio energy plus aggregate meters for reuse across shaders.
typedef struct
{
    vector_float4 bands;   // x=bass, y=mid, z=treble, w=beat intensity
    vector_float2 energy;  // x=peak of bands, y=weighted energy (bass-heavy)
    vector_float2 pad;     // Alignment padding
} PrecomputedAudio;

// === PRECOMPUTED FOG ===
// Captures fog scalars that benefit from CPU-side precomputation.
typedef struct
{
    vector_float4 fog;   // x=intensity, y=1/intensity (0 if disabled), z/w=unused
    vector_float4 color; // xyz=fog tint, w=unused
} PrecomputedFog;

typedef struct
{
    matrix_float4x4 projectionMatrix;
    matrix_float4x4 modelViewMatrix;
    matrix_float4x4 inverseModelViewMatrix;
    // === TEMPORAL DEPTH WARM-START (fragment path) ===
    matrix_float4x4 previousViewProjMatrix;     // Prev frame projection*modelView (model space → prev clip)
    matrix_float4x4 previousInvViewProjMatrix;  // Inverse of the above (prev clip → model space)
    float time;
    float minDistance;
    float fractalScale;
    int fractalIterations;
    int maxRaySteps;
    float maxViewDistance;
    float colorMix;
    float glowIntensity;
    float foldingLimit;      // Box folding limit (default 1.0)
    float sphereRadius;      // Sphere folding radius (default 0.5)
    float safetyBubbleRadius; // Safety bubble radius (meters)
    int safetyBubbleEnabled;  // Enable safety bubble (0/1)
    float safetyBubbleShape;  // 0 = sphere, 1 = cube, intermediate = morph (no rotation)
    int safetyBubbleFadeEnabled;  // Enable smooth fade transition (0/1)
    float safetyBubbleFadeWidth;  // Width of fade region beyond inner radius
    float safetyBubbleStrength;   // Temporal fade strength (0=off, 1=fully active)
    float colorIterations;   // How many iterations contribute to color
    float limitFlash;        // Edge flash when gesture hits limit (0-1)
    int activeGesture;       // Currently active gesture (0=none, 1=index, 2=middle, 3=ring, 4=pinky)
    int warmStartEnabled;    // 1 = previous-frame depth texture is valid for march warm-start
    int fractalType;         // 0=Mandelbox, 1-14=formula types (see FractalType enum)
    float lightingSoftness;  // 0 = current vibrance-driven sharp lighting, 1 = classic soft lighting
    int sphericalInversionMode; // 0=off, 1=outward-in ray inversion
    float sphericalInversionRadius; // Radius for spherical inversion mode
    float sphereProjectionBlend;    // 0 = off; >0 blends a post-fold radial sphere projection (Mandelbox fast path)
    float sphereProjectionRadius;   // Target radius for the post-fold sphere projection
    float spaceWarpStrength;        // 0 = off; drives the custom space warp (built-in Twist or a loaded .threshfx warp)
    float spaceWarpParam1;          // generic warp params (meaning defined by the active warp)
    float spaceWarpParam2;
    float spaceWarpParam3;
    // === GMT-FRACTALS INSPIRED OPTIMIZATIONS ===
    float stepMultiplier;    // Ray step over-relaxation factor (0.5-1.5, default 1.0)
    float boundingSphereRadius; // Bounding sphere for early ray rejection (0 = disabled)
    int smartAdvanceEnabled; // 1 = grazing-aware lead-ahead sphere tracing (reads the along-ray DE gradient to step further through grazing/receding regions)

    // === SPRING BLOB NAVIGATION WIDGET ===
    float springDisplacementX;        // Spring displacement X (NDC-ish space)
    float springDisplacementY;        // Spring displacement Y
    float springDisplacementZ;        // Spring displacement Z
    float springStretch;              // 0 = rest, 1 = fully stretched
    vector_float2 springAnchorNDC;    // Screen-space anchor position (NDC: -1 to 1)
    int springVisible;                // 0 = hidden, 1 = visible
    float springRestRadius;           // Blob rest radius in NDC units
    
    vector_float2 jitterOffset; // Sub-pixel jitter in pixels (±0.5 range)
    vector_float2 renderResolution; // Render-target size in pixels (warm-start UV); also pads to 16 bytes
    vector_float4 floorPlane; // xyz = model-space normal, w = plane constant
    vector_float4 floorCenterRadius; // xyz = model-space center, w = radius in model units
    
    FormulaParams formulaParams;  // Generic formula parameters (non-Mandelbox)
    
    // === PRECOMPUTED VALUES (frame-uniform, computed on CPU) ===
    PrecomputedFractalParams precomputedFractal;  // Eliminates per-pixel powr() and division
    PrecomputedLighting precomputedLighting;      // Eliminates per-pixel CameraPath() and trig
    PrecomputedAudio precomputedAudio;            // Aggregated audio energy
    PrecomputedFog precomputedFog;                // Fog helpers
    ColorSchemeParams colorScheme;  // Color scheme parameters for palette control
} Uniforms;

typedef struct
{
    Uniforms uniforms[2];
} UniformsArray;

// Tile-based compute shader uniforms
// Used for 4x4 pixel tile processing (1 DE per tile, 16 normal calcs)
typedef struct
{
    matrix_float4x4 invViewMatrix;
    matrix_float4x4 invProjMatrix;
    vector_float3 cameraPos;
    float time;
    vector_float2 resolution;      // Per-eye viewport size in pixels
    vector_float2 viewportOrigin;  // Per-eye viewport origin in texture pixels
    float minDistance;
    float fractalScale;
    float sphereRadius;
    float safetyBubbleRadius; // Safety bubble radius (meters)
    int safetyBubbleEnabled;  // Enable safety bubble (0/1)
    float safetyBubbleShape;  // 0 = sphere, 1 = cube, intermediate = morph (no rotation)
    int safetyBubbleFadeEnabled;  // Enable smooth fade transition (0/1)
    float safetyBubbleFadeWidth;  // Width of fade region beyond inner radius
    float safetyBubbleStrength;   // Temporal fade strength (0=off, 1=fully active)
    float foldingLimit;
    float glowIntensity;
    float colorMix;
    int fractalIterations;
    int colorIterations;
    int maxRaySteps;
    float maxViewDistance;
    uint32_t eyeIndex;
    uint32_t debugHierarchical;  // 1 = overlay a yellow tile-boundary grid
    float limitFlash;            // Edge flash when gesture hits limit (0-1)
    int fractalType;             // 0=Mandelbox, 1-14=formula types (see FractalType enum)
    float lightingSoftness;      // 0 = current vibrance-driven sharp lighting, 1 = classic soft lighting
    int sphericalInversionMode;  // 0=off, 1=outward-in ray inversion
    float sphericalInversionRadius; // Radius for spherical inversion mode
    float sphereProjectionBlend;    // 0 = off; >0 blends a post-fold radial sphere projection (Mandelbox fast path)
    float sphereProjectionRadius;   // Target radius for the post-fold sphere projection
    float spaceWarpStrength;        // 0 = off; drives the custom space warp (built-in Twist or a loaded .threshfx warp)
    float spaceWarpParam1;          // generic warp params (meaning defined by the active warp)
    float spaceWarpParam2;
    float spaceWarpParam3;
    // === GMT-FRACTALS INSPIRED OPTIMIZATIONS ===
    float stepMultiplier;        // Ray step over-relaxation factor (0.5-1.5, default 1.0)
    float boundingSphereRadius;  // Bounding sphere for early ray rejection (0 = disabled)
    int smartAdvanceEnabled;     // 1 = grazing-aware lead-ahead sphere tracing (reads the along-ray DE gradient to step further through grazing/receding regions)
    float blendFactor;           // Temporal reuse factor: 1.0 = moving, lower = stable enough to trust depth history
    // === SPRING BLOB NAVIGATION WIDGET ===
    // Packed as scalars to avoid float3 alignment issues between Swift and Metal
    float springDisplacementX;        // Spring displacement X (NDC-ish space)
    float springDisplacementY;        // Spring displacement Y
    float springDisplacementZ;        // Spring displacement Z
    float springStretch;              // 0 = rest, 1 = fully stretched
    vector_float2 springAnchorNDC;    // Screen-space anchor position (NDC: -1 to 1)
    int springVisible;                // 0 = hidden, 1 = visible
    float springRestRadius;           // Blob rest radius in NDC units
    // === GMT-FRACTALS: HALTON JITTER FOR TEMPORAL AA ===
    vector_float2 jitterOffset;  // Sub-pixel jitter in pixels (±0.5 range)
    int temporalReprojectionEnabled;         // 0 = off (first frame / parameter change), 1 = on
    // === COHERENT-PACKET EXPERIMENTAL PATH (Stages 0-3 prototype) ===
    // 0 = legacy adaptiveHierarchical8x8 path (prevDepth*0.9 warm-start, unconditional
    // shared shadows). 1 = predict-validate-fallback: single-DE-eval safety probe per
    // pixel, normal-coherence-gated shadow share, layer-of-acceptance debug overlay.
    int coherentPacketEnabled;
    // === FOVEATED RAYMARCH ===
    // 0 = uniform full-quality march everywhere (default). >0 = peripheral 8x8
    // tiles march proportionally fewer ray steps, smoothly ramping from the
    // viewport center toward the edges. Occupies the former 16-byte alignment
    // pad, so struct layout is unchanged.
    float foveationStrength;
    vector_float4 floorPlane; // xyz = model-space normal, w = plane constant
    vector_float4 floorCenterRadius; // xyz = model-space center, w = radius in model units
    
    FormulaParams formulaParams;  // Generic formula parameters (non-Mandelbox)
    
    // === TEMPORAL REPROJECTION ===
    matrix_float4x4 currentViewProjMatrix;   // Current frame: modelView * projection (for depth write)
    matrix_float4x4 previousViewProjMatrix;  // Previous frame: modelView * projection (for reprojection)
    matrix_float4x4 currentInvViewProjMatrix; // Inverse of currentViewProjMatrix (pixel → model space)
    
    // === PRECOMPUTED VALUES (frame-uniform, computed on CPU) ===
    PrecomputedFractalParams precomputedFractal;  // Eliminates per-pixel powr() and division
    PrecomputedLighting precomputedLighting;      // Eliminates per-pixel CameraPath() and trig
    PrecomputedAudio precomputedAudio;            // Aggregated audio energy
    PrecomputedFog precomputedFog;                // Fog helpers
    ColorSchemeParams colorScheme;  // Color scheme parameters for palette control
} TileUniforms;

// Include Buddhabrot types so they're visible through the bridging header
#include "../Formulas/Buddhabrot/BuddhabrotTypes.h"

#endif /* ShaderTypes_h */
