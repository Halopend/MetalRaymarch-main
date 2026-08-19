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

#ifndef __METAL_VERSION__
#ifdef __cplusplus
extern "C" {
#endif
int ThresholdLLVMProfileIsInstrumented(void);
int ThresholdLLVMProfileWriteFile(void);
#ifdef __cplusplus
}
#endif
#endif

typedef NS_ENUM(EnumBackingType, BufferIndex)
{
    BufferIndexMeshPositions = 0,
    BufferIndexMeshGenerics  = 1,
    BufferIndexUniforms      = 2,
    BufferIndexBenchCounters = 3,  // device atomic_uint[2] = {stepSum, hitCount} for the benchmark iteration counter
    BufferIndexPostFilters   = 4   // constant PostFilterStack; kept out of the hot Uniforms / TileUniforms ABI
};

typedef NS_ENUM(EnumBackingType, VertexAttribute)
{
    VertexAttributePosition  = 0,
    VertexAttributeTexcoord  = 1,
};

typedef NS_ENUM(EnumBackingType, TextureIndex)
{
    TextureIndexColor    = 0,
    TextureIndexPrevDepth = 1,  // Previous-frame depth for temporal march warm-start
    TextureIndexCoarseWarmStart = 2  // Conservative cone coarse-prepass warmT (LOWER BOUND on entry distance per 8x8 block)
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
    // index 14 = FC_COHERENT_PACKET (compute kernel only; see Shaders.metal)
    FCIndexCoarseWarmStart     = 15, // bool: Compile in the conservative cone coarse-prepass warm-start (fragment path + cone kernel). Index 14 is taken by FC_COHERENT_PACKET, so this uses the next free slot.
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
    FractalTypeBoxFoldMandelbulb     = 18,
    // NOTE: 20 was the removed `boxSphereFolder` type (see FractalModelType
    // back-compat decode). Do not reuse it.
    // NOTE: 21 is reserved — the legacy `mandelboxSphereProjection` type folded
    // into base Mandelbox + the Space-tab Sphere Projection control (see
    // FractalModelType back-compat decode). Do not reuse it.
    // NOTE: 22 was the removed `bulatovLimitSet` type (see FractalModelType
    // back-compat decode). Do not reuse it.
    // Analytic seed selected by the Transformations primitive menu. This is
    // statically compiled so selecting a trusted primitive never invokes the
    // runtime Metal compiler on memory-constrained iPad hardware.
    FractalTypeConstructionPrimitive = 23,
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

// Independent values for an imported lighting `.threshfx`. Lighting effects
// deliberately do not reuse FormulaParams: a lighting control must never alter
// geometry, invalidate a fractal specialization, or collide with a space warp.
// Metadata (names/ranges/defaults) stays in EmbeddedFormula.params; only these
// live scalar values cross the per-frame Swift -> Metal boundary.
typedef struct
{
    float values[16];
} CustomLightingParams;

// === ORDERED OUTPUT-FILTER STACK ===
// A compact, scene-owned list of post filters. Pixel-local operations can be
// evaluated in registers; the single sampled edge operation splits the list
// into local prefix/suffix ranges so texture-backed paths preserve authored
// order without allocating one intermediate texture per local filter.
#define kMaxPostFilterOps 8
typedef struct
{
    int type;
    float amount;
    float param1;
    float param2;
    float param3;
    uint32_t colorRGB10;
    uint32_t _pad0;
    uint32_t _pad1;
} PostFilterOp;
typedef struct
{
    PostFilterOp ops[kMaxPostFilterOps];
    int count;
    int _pad0;
    int _pad1;
    int _pad2;
} PostFilterStack;

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
    float aoStrength;                 // Ambient-occlusion blend (0 = old flat hemisphere ambient, default; 1 = full SDF AO march)
    float tonemapStrength;            // Filmic (ACES) tonemap blend (0 = old plain clamp, default; 1 = full filmic curve)
    float vignetteStrength;           // Output vignette blend (0 = off; 1 = historical look)
    
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
    uint32_t edgeColorRGB10;          // Edge outline tint; reuses the gradient section's former alignment pad
    
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

    // Screen-space edge detector
    int edgeDetectionEnabled;         // 0 = off, 1 = on
    float edgeDetectionStrength;      // Outline blend amount (0-1)
    float edgeDetectionThreshold;     // Luminance gradient threshold
    float edgeDetectionSoftness;       // Threshold transition width
    int edgeDetectionWindowRadius;     // Sliding-window radius: 1...3
    
    // Beat Flash Effect - music-driven edge glow
    int beatFlashEnabled;             // 0 = off, 1 = on
    float beatFlashIntensity;         // Flash strength (0-1), multiplied by beat level

    // Display peak this frame in SDR-white units (display state, not artistic:
    // the renderer stamps it per frame from the screen's EDR headroom). 1 = SDR
    // display or SDR-pinned target (benchmark captures); >1 = grading may send
    // highlight energy above SDR white up to this value. The shader clamps to
    // >= 1, so a zero-initialized struct behaves as SDR.
    float edrHeadroom;
    // RGB10 colors occupy ColorSchemeParams' former 8-byte trailing alignment
    // pad, keeping Uniforms and TileUniforms within their existing 2 KB budget.
    uint32_t glowColorRGB10;
    uint32_t bloomColorRGB10;

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

// === COMPOSABLE DOMAIN-TRANSFORM STACK ===
// A user-ordered list of domain warps applied to the sample point before the
// fractal DE (Twist / Bend / folds / inversion / kaleidoscope / ripple). The
// stack is FRAME-UNIFORM, so the GPU loop + per-op switch are wavefront-coherent.
// An empty stack (count == 0) early-outs to identity. Scalars are packed (no
// vector_float3) to keep the array's Swift<->Metal layout tuple-free & 4-aligned.
#define kMaxSpaceWarpOps 8
#define kMaxSpaceWarpGroupIterations 16
#define kSpaceWarpGroupLengthMask 0xff
#define kSpaceWarpGroupIterationShift 8
#define kSpaceWarpGroupIterationMask 0xff
#define kSpaceWarpGroupMandelboxFeedback (1 << 16)
typedef struct
{
    // p1/p2/axis are GPU-READY (precomputed by cSpaceWarpStack each frame so the
    // per-step Metal warp fns never redo normalize / log / π÷N / squares / clamps).
    int   type;       // SpaceWarpKind raw; 0...20 (20 = 3-D Voronoi distortion field)
    float strength;   // per-op amount (folds treat as 0..1 blend; Twist/Bend/Ripple as magnitude). 0 = this op is a no-op.
    float p1;         // PRECOMPUTED: boxFold L · sphere/circle minR² · inversion R² · kaleido seg(π/N) · ripple freq · shell/base spacing · scaleRepeat log(scale) · Voronoi density
    float p2;         // PRECOMPUTED: sphere/circle maxR² · Voronoi jitter
    float axisX;      // PRE-NORMALIZED axis (Twist/Bend/Ripple); raw offset for Voronoi
    float axisY;
    float axisZ;      // Coxeter: user-authored vertical source angle (radians)
    // First op in a repeat group: low 8 bits = contiguous group length, next
    // 8 bits = pass count, and bit 16 enables Mandelbox `+ original point`
    // feedback after each complete pass. Zero means an ordinary one-pass op.
    // This occupies the former padding slot, preserving the 32-byte ABI stride.
    int   groupControl;
} SpaceWarpOp;
typedef struct
{
    SpaceWarpOp ops[kMaxSpaceWarpOps];
    int count;        // number of active ops (0 = stack off → identity)
    int _pad0; int _pad1; int _pad2;  // 16-byte tail alignment
} SpaceWarpStack;

// === SCENE-LEVEL SDF OBJECTS ===
// Independently placed primitives unioned with the active fractal. Records live
// directly in the frame-uniform block: eight objects cost 256 bytes but avoid a
// second mutable bindless allocation and keep all render paths in lockstep.
#define kMaxScenePrimitives 8
#define BENCHY_SDF_DIM 96
typedef struct
{
    vector_float4 positionScale;  // xyz = model-space position, w = uniform scale
    vector_float4 dimensionsKind; // xyz = kind-specific dimensions, w = stable selector
} ScenePrimitiveGPU;

// === ENVIRONMENT SCRUNCH (scanned-room proximity field) ===
// The scanned surroundings (visionOS scene-reconstruction mesh) are baked on
// the CPU into a band-limited unsigned distance grid in WORLD meters. Desktop
// pipelines compile this field out entirely. The DE samples it and applies a mixed
// positive/negative field — a smooth-union "hug" shell at a small standoff
// above real surfaces plus a smooth-subtraction clearance at the surface
// itself — so the fractal scrunches/bulges around the room and its objects
// (the hand-attraction model applied to the environment).
#define ENV_SCRUNCH_DIM 64   // grid resolution per axis (half floats, DIM^3)
typedef struct
{
    int enabled;              // 0 = off (grid is never dereferenced)
    float strength;           // 0..1 blend toward the scrunched field
    float bandModel;          // engage band around surfaces, model units
    float softModel;          // smooth-blend k, model units
    float hugModel;           // bulge-shell standoff above surfaces, model units
    float carveModel;         // clearance kept empty around surfaces, model units
    float metersToModel;      // world meters → model units distance scale
    int mode;                 // 0 = Scrunch (bulge around surfaces), 1 = Shell (render only within band of surfaces)
    matrix_float4x4 modelToGrid; // model space → grid texel coords (0..DIM)
    uint64_t gridAddress;     // MTLBuffer.gpuAddress of half[DIM^3] distances (meters); 0 = none
    // === CONTAINMENT (clip to the scanned room box) ===
    // The grid is UNSIGNED distance, so any surface-keyed effect mirrors on both
    // sides of a wall → an "outside shell"/doubling. Clipping the fractal to the
    // scanned surfaces' AABB (in grid coords, so `modelToGrid` handles rotation)
    // restores a sign and cuts the mirror. 0 = off, 1 = hard clip, 2 = soft blend.
    int containMode;
    float containFeatherModel;  // soft-blend feather half-width, model units (mode 2)
    // The bake's far-distance clamp converted to MODEL units. envScrunchSample
    // returns this for out-of-grid points ("far from every scanned surface"),
    // so Shell mode cuts space beyond the grid instead of skinning its
    // boundary. Carried here (from EnvironmentSDFGrid.clampFar at build time)
    // so the shader and the bake can never drift (TECH_DEBT.md #19).
    float farClampModel;
    vector_float3 containMinGrid; // room AABB min, grid texel coords
    vector_float3 containMaxGrid; // room AABB max, grid texel coords
    vector_float3 cellModel;      // model units per grid cell, per axis (metric box SDF)
    // Headset/camera position in model space. Shell mode uses this to keep the
    // shell on the viewer-visible side of scanned surfaces instead of the
    // mirrored "outside" side of the unsigned distance field.
    vector_float3 viewerModel;

    // Scene object union. Benchy instances share one immutable signed-distance
    // volume; analytic objects use dimensionsKind directly.
    ScenePrimitiveGPU scenePrimitives[kMaxScenePrimitives];
    int scenePrimitiveCount;
    int _scenePrimitivePad0;
    uint64_t benchySDFAddress; // half[BENCHY_SDF_DIM^3], canonical local units
} EnvScrunchParams;

// === FRACTAL DISTANCE CACHE (conservative distance-field grid) ===
// The fractal DE itself baked into a low-res MODEL-space grid of PROVABLY
// CONSERVATIVE lower bounds: each voxel stores
//     max(DE(voxelCenter) − slack·halfDiagonal, 0)
// so the stored value is a valid empty-sphere radius for ANY point inside the
// voxel (valid while the local Lipschitz constant ≤ slack). The march samples
// it (nearest voxel — trilinear would break conservativeness) and, while the
// cached bound exceeds nearBandModel, steps by the bound WITHOUT evaluating
// the analytic DE at all; near the surface (or outside the grid, where the
// sample reads 0) it falls back to the exact DE, so hits are unchanged.
// Baked on the GPU (distanceCacheBake kernel) in the same command buffer that
// renders, only when a DE-shaping parameter actually changed — so the cache is
// never stale and static frames pay nothing. Model space makes it ZOOM-
// INVARIANT: camera motion and detail-scale zoom never dirty it.
// CPU-side gating (see FractalDistanceCache.swift): enabled only for stable,
// unprojected Mandelboxes without distance-reducing hands, env scrunch, or
// distance-LOD. Safety-bubble subtraction is compatible because it can only
// increase the canonical distance.
#define DIST_CACHE_DIM 128   // grid resolution per axis (uint8 fixed-point, DIM^3)
typedef struct
{
    int enabled;             // 0 = off (grid is never dereferenced)
    float nearBandModel;     // cached bound below this → fall back to the analytic DE (model units)
    uint64_t gridAddress;    // MTLBuffer.gpuAddress of half[DIM^3] bounds (model units); 0 = none
    vector_float4 originModel;   // xyz = grid min corner; w = runtime grid dimension
    vector_float3 invCellModel;  // 1 / cell size, per axis (model units)
} DistanceCacheParams;

// Hand Attraction + forearm capsules, grouped so the block lives ONCE in the
// constant Uniforms/TileUniforms buffer and FractalParams (by-value through
// the DE hot path) carries only a `constant HandFieldParams*` — the same
// pointer indirection as SpaceWarpOp/EnvScrunchParams (TECH_DEBT.md #8d: the
// flat copy of these fields was 168 B of the 320 B FractalParams).
// Hand active flags ride in the position .w lanes (1 = tracked / 0) to avoid
// float3+int padding waste.
typedef struct
{
    int enabled;              // master on/off (0/1)
    float radius;             // per-hand influence radius, model units
    float strength;           // signed: >0 = Attract (pull toward), <0 = Repel
    int pocketEnabled;        // Attract-only: carve a small pocket at the hand
    vector_float4 shape;      // x = ball size (×radius), y = blend softness (×ball), z = pocket size (×ball), w = pocket softness (×pocket)
    vector_float4 leftHand;   // xyz = palm (model space), w = 1 tracked / 0
    vector_float4 rightHand;  // xyz = palm (model space), w = 1 tracked / 0
    vector_float4 leftForearmA;  // xyz = wrist (model space), w = 1 tracked / 0
    vector_float4 leftForearmB;  // xyz = elbow (model space), w = capsule radius (model units; 0 = forearms off)
    vector_float4 rightForearmA;
    vector_float4 rightForearmB;
} HandFieldParams;

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
    // Infinite zoom: 1/max(effectiveScale,1). Scales the raymarch hit-threshold
    // floor down as you zoom in so fine detail keeps resolving (1.0 at base zoom
    // → byte-identical). See the RenderSettings infinite-zoom driver.
    float marchEpsilonScale;
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

    // Hand Attraction (visionOS only): a per-hand interaction sphere that pulls
    // the fractal surface toward each tracked palm — inverse of the safety
    // bubble's push-away carve. Positions are MODEL-space (same transform the
    // march runs in), computed on CPU each frame from the ARKit hand anchors.
    // Hand Attraction + forearms, nested so FractalParams can point at the
    // block instead of copying it (TECH_DEBT.md #8d).
    HandFieldParams handField;

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
    vector_float3 spaceWarpAxis;    // Built-in Twist rotation axis (orientation); normalized on GPU. Origin = spaceWarpParam1/2/3
    SpaceWarpStack spaceWarpStack;  // Composable domain-transform stack (Transformations UI). count==0 = off.
    // === GMT-FRACTALS INSPIRED OPTIMIZATIONS ===
    float stepMultiplier;    // Ray step over-relaxation factor (0.5-1.5, default 1.0)
    float boundingSphereRadius; // Bounding sphere for early ray rejection (0 = disabled)
    int smartAdvanceEnabled; // 1 = grazing-aware lead-ahead sphere tracing (reads the along-ray DE gradient to step further through grazing/receding regions)
    float coneMarchScale;    // Cone marching: per-distance growth of the march hit threshold (= projected pixel footprint × stop margin). 0 = off
    int coneCoverageAAEnabled; // 1 = CTSS-lite silhouette AA: composite near-miss edges over background by cone-footprint coverage (fragment path). 0 = off
    int shadowsEnabled;      // 0 = skip the per-pixel shadow marches (flat, cheaper lighting); 1 = full soft shadows
    float distanceLODFalloff;// Distance iteration LOD: fractal iterations dropped per unit ray distance. 0 = off
    int benchCollectSteps;   // 1 = accumulate per-ray march step counts into BufferIndexBenchCounters (benchmark only)

    // === CONSERVATIVE CONE COARSE-PREPASS WARM-START ===
    // Raw per-pixel lateral footprint at depth 1: 2·tan(fovY/2)/viewportHeight
    // (= coneMarchScale WITHOUT the LOD-widening s·coneMarchMaxPixels factor).
    // Used by the cone kernel to bound the 8x8 block footprint; the fragment path
    // also carries it so it can be read alongside the coarse texture if needed.
    float pixelFootprintPerDist;
    // Conservative UPPER BOUND on physical→screen magnification under foveation.
    // Over-bounding only shortens the warm-start skip (always safe). 1.0 = none.
    float coarseRateMagMax;

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
    CustomLightingParams customLightingParams; // Independent imported-lighting values
    
    // === PRECOMPUTED VALUES (frame-uniform, computed on CPU) ===
    PrecomputedFractalParams precomputedFractal;  // Eliminates per-pixel powr() and division
    PrecomputedLighting precomputedLighting;      // Eliminates per-pixel CameraPath() and trig
    PrecomputedAudio precomputedAudio;            // Aggregated audio energy
    PrecomputedFog precomputedFog;                // Fog helpers
    ColorSchemeParams colorScheme;  // Color scheme parameters for palette control

    // Benchmark-only shading-ablation selector (0 in normal use; >=10 activates
    // fragmentMain's benchAblate dissection branches — set by the Mac headless
    // benchmark harness via THRESHOLD_BENCHMARK_ABLATE).
    uint32_t benchAblate;

    // 1 = miss rays write alpha 0 (premultiplied) so the compositor shows
    // passthrough instead of the black background — Partial immersion on
    // visionOS. Glow/fog on miss pixels stays in RGB, which composites
    // additively over passthrough under premultiplied alpha. 0 everywhere else.
    int passthroughBackground;

    // Bounding-edge treatment; only meaningful while boundingSphereRadius > 0.
    // 0 = off (hard clip). 1 = Ghost Fade: fades RGB (and alpha, when
    // passthroughBackground is set) over the outer ~third of the sphere —
    // translucent near the boundary. 2 = Inner Shadow: fades RGB only over a
    // band whose width is boundingShadowDepth, staying fully opaque.
    int boundingFogEnabled;
    // Inner Shadow band width, as a fraction of boundingSphereRadius (0-1).
    // Only used while boundingFogEnabled == 2.
    float boundingShadowDepth;
    // Bounding Shape family/preset — same encoding as safetyBubbleShape:
    // 0...1 = sphere/cube morph, 2...6 = discrete platonic solids (see
    // SafetyBubbleShapePreset). Feeds safetyBubbleDistance() directly.
    float boundingShapeType;

    // === BOUND TO SPACE (sensed/manual rectangular-room clip) ===
    // `modelToBoundSpaceMatrix` maps march/model coordinates into a centered,
    // gravity-aligned room coordinate system. This lets the room be translated
    // and yaw-rotated independently of the AR session origin. Open faces extend
    // to infinity. 0 = off, 1 = Match Space (closed box),
    // 2 = Ceiling Open (walls + floor), 3 = Walls Open (floor + ceiling only).
    int boundToSpaceMode;
    vector_float3 boundSpaceSize;       // full room size, meters (w, h, d)
    // Room-derived ambient: 0 = off, 1 = full. Scales a contact-occlusion term
    // computed from proximity/facing to the room's closed faces, so surfaces
    // near the bounded room's walls/floor/ceiling read as ambiently shadowed
    // by the room. Only meaningful while boundToSpaceMode != 0.
    float boundAmbientStrength;
    matrix_float4x4 modelToBoundSpaceMatrix; // march/model space → centered room meters

    EnvScrunchParams envScrunch;        // scanned-environment scrunch field (grid via bindless address)

    // Conservative fractal distance cache (grid via bindless address).
    // Mac fragment path only for now; zero/disabled elsewhere.
    DistanceCacheParams distCache;

    // Model-space center of the Bounding Shape clip test (default 0). The Linear
    // Rail translates the whole model (camera+fractal+shape) via the model
    // matrix; this cancels the rail's translation for the shape ONLY, pinning the
    // shape in place so content slides through it. Zero when the rail is off.
    vector_float3 boundingShapeCenter;
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
    // Hand Attraction + forearms, nested so FractalParams can point at the
    // block instead of copying it (TECH_DEBT.md #8d).
    HandFieldParams handField;
    float foldingLimit;
    float glowIntensity;
    float colorMix;
    int fractalIterations;
    int colorIterations;
    int maxRaySteps;
    float maxViewDistance;
    // Infinite zoom: 1/max(effectiveScale,1). Scales the raymarch hit-threshold
    // floor down as you zoom in so fine detail keeps resolving (1.0 at base zoom).
    float marchEpsilonScale;
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
    vector_float3 spaceWarpAxis;    // Built-in Twist rotation axis (orientation); normalized on GPU. Origin = spaceWarpParam1/2/3
    SpaceWarpStack spaceWarpStack;  // Composable domain-transform stack (Transformations UI). count==0 = off.
    // === GMT-FRACTALS INSPIRED OPTIMIZATIONS ===
    float stepMultiplier;        // Ray step over-relaxation factor (0.5-1.5, default 1.0)
    float boundingSphereRadius;  // Bounding sphere for early ray rejection (0 = disabled)
    int smartAdvanceEnabled;     // 1 = grazing-aware lead-ahead sphere tracing (reads the along-ray DE gradient to step further through grazing/receding regions)
    float coneMarchScale;        // Cone marching: per-distance growth of the march hit threshold (= projected pixel footprint × stop margin). 0 = off
    int coneCoverageAAEnabled;   // 1 = CTSS-lite silhouette AA (fragment path only; unused on the compute tile path). 0 = off
    int shadowsEnabled;          // 0 = skip the per-pixel shadow marches (flat, cheaper lighting); 1 = full soft shadows
    float distanceLODFalloff;    // Distance iteration LOD: fractal iterations dropped per unit ray distance. 0 = off
    // === CONSERVATIVE CONE COARSE-PREPASS WARM-START ===
    // Raw per-pixel lateral footprint at depth 1 (no LOD widening); see Uniforms.
    float pixelFootprintPerDist;
    // Conservative UPPER BOUND on physical→screen magnification under foveation (>=1).
    float coarseRateMagMax;
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
    CustomLightingParams customLightingParams; // Independent imported-lighting values
    
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

    // === FOVEATION RATE-MAP DECODE (visionOS adaptive compute path only) ===
    // When foveation is enabled the compositor treats the drawable color texture
    // as variable-density PHYSICAL space and un-foveates it through a
    // rasterization rate map before display. The fragment path gets this for free
    // via the rasterizer; the compute kernel writes physical pixels directly, so
    // it must reconstruct rays in SCREEN (logical) space by decoding
    // physical→screen through the rate map (see reconstructModelPoint). These
    // fields drive that decode. rateMapValid == 0 keeps the legacy linear path,
    // which is correct when foveation is off or no usable rate map exists.
    vector_float2 screenResolution;  // rateMap.screenSize: logical viewport size for NDC normalization
    int rateMapValid;                // 1 = rateMapData (buffer 1) is a valid rate map to decode
    uint32_t rateMapLayer;           // rate-map layer for this eye (layered: eyeIndex; dedicated: 0)

    // === BOUND TO SPACE (sensed/manual rectangular-room clip) — see Uniforms ===
    int boundToSpaceMode;               // 0 = off, 1 = Match Space, 2 = Ceiling Open, 3 = Walls Open
    vector_float3 boundSpaceSize;       // full room size, meters (w, h, d)
    float boundAmbientStrength;         // room-derived ambient occlusion, 0 = off (see Uniforms)
    matrix_float4x4 modelToBoundSpaceMatrix; // march/model space → centered room meters

    EnvScrunchParams envScrunch;        // scanned-environment scrunch field (grid via bindless address)
    // Bounding Shape family/preset — same encoding as Uniforms.boundingShapeType /
    // safetyBubbleShape (0...1 sphere→cube morph, 2...6 platonic solids). The
    // compute tile path has no per-hit edge fade, so it HARD-clips hits outside
    // this shape (see the reclassify in adaptiveHierarchical8x8). Only meaningful
    // while boundingSphereRadius > 0.
    float boundingShapeType;
    // Model-space center of the Bounding Shape clip test (default 0). Mirrors
    // Uniforms.boundingShapeCenter — pins the shape while the Linear Rail slides
    // content past it. Zero when the rail is off.
    vector_float3 boundingShapeCenter;
} TileUniforms;

// Include Buddhabrot types so they're visible through the bridging header
#include "../Formulas/Buddhabrot/BuddhabrotTypes.h"

#ifdef __METAL_VERSION__
// Size gates (TECH_DEBT.md #8d): these structs live in the constant address
// space (not by-value), so the concern is growth awareness + keeping the
// Swift/Metal layout in lockstep — growing one is fine, but must be a
// conscious act. If you added a field on purpose, bump the bound in the same
// commit. EmbeddedMetalSources.swift is regenerated automatically. The by-value
// FractalParams gate lives next to its definition in Shaders.metal.
// 2026-07-04: +48 B in both — EnvScrunchParams gained the containment box
// (containMode/Feather + 3× grid-space float3), 112 → 160 B.
// 2026-07-05: Uniforms +48 B — DistanceCacheParams (fractal distance cache,
// Mac fragment path), 1936 → 1984. TileUniforms unchanged.
// 2026-07-06: both +16 B — boundingShapeCenter (vector_float3) so the Linear
// Rail moves content INSIDE a pinned Bounding Shape instead of dragging the
// shape along, 1984 → 2048 bound.
// 2026-07-26: both +272 B — eight fixed scene-SDF records + shared Benchy
// volume address. The hot FractalParams struct is unchanged; records remain
// behind its existing EnvScrunchParams pointer.
// 2026-08-05: both +64 B — an independent 16-float custom-lighting bank. It
// cannot alias FormulaParams because lighting and geometry compose at runtime.
static_assert(sizeof(Uniforms) <= 2400,
              "Uniforms grew — bump this bound consciously (TECH_DEBT.md #8d)");
static_assert(sizeof(TileUniforms) <= 2400,
              "TileUniforms grew — bump this bound consciously (TECH_DEBT.md #8d)");
static_assert(sizeof(FormulaParams) <= 176,
              "FormulaParams grew — bump this bound consciously (TECH_DEBT.md #8d)");
static_assert(sizeof(CustomLightingParams) == 64,
              "CustomLightingParams must remain a compact 16-float ABI");
static_assert(sizeof(PostFilterOp) == 32,
              "PostFilterOp must remain a compact 32-byte C ABI");
static_assert(sizeof(PostFilterStack) == 272,
              "PostFilterStack must remain eight 32-byte ops plus a 16-byte tail");
#endif

#endif /* ShaderTypes_h */
