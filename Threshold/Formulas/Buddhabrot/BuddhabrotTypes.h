//
//  BuddhabrotTypes.h
//  Threshold
//
//  Shared types between Metal shaders and Swift for the 3D Buddhabrot volume renderer.
//  Phase 1: Async compute accumulates orbit density into a 3D atomic buffer.
//  Phase 2: Per-frame normalization into a 3D float texture + stereo volume ray march.
//

#ifndef BuddhabrotTypes_h
#define BuddhabrotTypes_h

#include <simd/simd.h>

// NS_ENUM and EnumBackingType may already be defined by ShaderTypes.h
// Only define them if not already present.
#ifndef ShaderTypes_h
#ifdef __METAL_VERSION__
#define NS_ENUM(_type, _name) enum _name : _type _name; enum _name : _type
typedef metal::int32_t EnumBackingType;
#else
#import <Foundation/Foundation.h>
typedef NSInteger EnumBackingType;
#endif
#endif

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - Volume Grid Constants
// ═══════════════════════════════════════════════════════════════════════════════

// Default volume resolution (Nx × Ny × Nz). 256^3 = 16M voxels × 4B = 64 MB density buffer.
// 128^3 = 2M voxels × 4B = 8 MB — better for Vision Pro thermals.
#define BBROT_DEFAULT_RESOLUTION 128

// Maximum orbit length (local buffer per thread for storing trajectory points)
#define BBROT_MAX_ORBIT_LENGTH 256

// World-space bounding cube half-extent: volume maps to [-EXTENT, +EXTENT]^3
#define BBROT_WORLD_EXTENT 2.0f

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - Orbit Accumulation Uniforms
// ═══════════════════════════════════════════════════════════════════════════════

/// Parameters for the orbit accumulation compute kernel (Phase 1).
/// Each dispatch processes a batch of random seeds c, iterates the fractal,
/// and atomically deposits escaped orbit points into the density buffer.
typedef struct {
    uint32_t resolution;          // Volume grid size per axis (Nx = Ny = Nz)
    uint32_t maxIterations;       // Maximum fractal iterations before giving up
    uint32_t minIterations;       // Minimum escape iteration for this color band
    uint32_t batchSize;           // Number of random seeds per dispatch
    uint32_t seedOffset;          // Offset into global seed sequence (incremented per dispatch)
    float    escapeRadius;        // Bailout radius squared (typically 4.0 or higher)
    float    worldExtent;         // Half-size of the bounding cube in world space
    
    // Mandelbulb parameters
    float    power;               // Mandelbulb power (classic = 8)
    float    bailoutRadius;       // Bailout radius (not squared)
    
    uint32_t pad[3];              // Pad to 16-byte alignment
} BuddhabrotAccumulationUniforms;

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - Normalization Uniforms
// ═══════════════════════════════════════════════════════════════════════════════

/// Parameters for the density → float texture normalization kernel.
/// Reads raw uint32 density buffer, applies log scaling and gamma,
/// writes to a 3D R16Float or R32Float texture.
typedef struct {
    uint32_t resolution;          // Volume grid size per axis
    float    densityScale;        // Multiplier before log (adjusts brightness)
    float    gamma;               // Gamma curve exponent (e.g., 0.4 for Buddhabrot look)
    float    logBase;             // fast::log(1 + density * scale) normalization
    uint32_t maxDensity;          // Current maximum density value (for adaptive normalization)
    float    pad[3];              // Alignment
} BuddhabrotNormalizationUniforms;

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - Volume Ray March Uniforms (Per-Eye)
// ═══════════════════════════════════════════════════════════════════════════════

/// Parameters for the stereo volume ray march fragment shader (Phase 2).
/// One instance per eye, packed into a UniformsArray-style struct.
typedef struct {
    matrix_float4x4 viewMatrix;           // Eye view matrix (world → eye)
    matrix_float4x4 projectionMatrix;     // Eye projection matrix
    matrix_float4x4 inverseViewMatrix;    // Eye → world
    matrix_float4x4 inverseProjectionMatrix; // Clip → eye
    
    // Volume transform
    matrix_float4x4 volumeWorldMatrix;    // Volume model → world transform
    matrix_float4x4 inverseVolumeWorldMatrix; // World → volume model
    
    // Volume bounds in model space: [-extent, +extent]^3
    vector_float3 volumeMin;              // = (-extent, -extent, -extent)
    float          worldExtent;           // Half-size of bounding cube
    vector_float3 volumeMax;              // = (+extent, +extent, +extent)
    float          stepSize;              // Ray march step size (extent * 2 / numSteps)
    
    // Transfer function
    vector_float3 colorLow;              // Color for low density (e.g., deep blue)
    float          densityScale;          // Overall density multiplier
    vector_float3 colorMid;              // Color for medium density
    float          alphaScale;            // Opacity multiplier
    vector_float3 colorHigh;             // Color for high density (e.g., white/gold)
    float          gamma;                 // Transfer function gamma
    
    // Rendering quality
    uint32_t maxSteps;                    // Max ray march steps (64–128)
    float    earlyExitAlpha;              // Alpha threshold for early exit (e.g., 0.95)
    float    time;                        // Animation time (for rotation, etc.)
    float    pad;
} BuddhabrotRayMarchUniforms;

/// Per-frame stereo pair of ray march uniforms.
typedef struct {
    BuddhabrotRayMarchUniforms uniforms[2]; // [0] = left eye, [1] = right eye
} BuddhabrotRayMarchUniformsArray;

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - 3D Gaussian Splat Types
// ═══════════════════════════════════════════════════════════════════════════════

// Maximum splat buffer capacity. 512K is balanced for visionOS thermals.
// Must be power-of-2 for radix sort.
#define BBROT_DEFAULT_MAX_SPLATS 524288

// Radix sort constants
#define RADIX_SORT_BITS_PER_PASS 8
#define RADIX_SORT_BIN_COUNT 256
#define RADIX_SORT_THREADS_PER_GROUP 256

/// A single Gaussian splat: position + packed color + orbit tangent. 32 bytes total.
/// Written by the emit compute kernel, read by the splat render vertex shader.
/// Note: vector_float3 is 16-byte aligned (16 bytes including padding), so the tangent
/// fields occupy the alignment padding that was previously wasted — zero extra memory.
typedef struct {
    vector_float3 position;       // World-space orbit point (16 bytes with alignment)
    uint32_t      packedColor;    // R8G8B8A8 — color from transfer function + opacity (4 bytes)
    float         tangentX;       // Orbit tangent direction x (4 bytes)
    float         tangentY;       // Orbit tangent direction y (4 bytes)
    float         tangentZ;       // Orbit tangent direction z (4 bytes)
} BuddhabrotSplat;

/// Parameters for the splat emission compute kernel.
/// Same orbit computation as accumulation, but appends orbit points to a splat buffer
/// instead of depositing into a density grid.
typedef struct {
    uint32_t maxIterations;       // Maximum fractal iterations
    uint32_t batchSize;           // Number of random seeds per dispatch
    uint32_t seedOffset;          // Offset into global seed sequence
    float    escapeRadius;        // Bailout radius squared
    float    worldExtent;         // Half-size of the bounding cube
    float    power;               // Mandelbulb power
    float    bailoutRadius;       // Bailout radius (not squared)
    uint32_t maxSplatCount;       // Ring-buffer capacity

    // Transfer function colors (applied at emit time on GPU)
    vector_float3 colorLow;
    float         pad0;
    vector_float3 colorMid;
    float         pad1;
    vector_float3 colorHigh;
    float         pad2;
} BuddhabrotEmitUniforms;

/// A sort key entry: view-space depth key + original splat index. 8 bytes.
typedef struct {
    uint32_t key;                  // Depth encoded as sortable uint32 (larger = farther)
    uint32_t value;                // Index into splat buffer
} RadixSortEntry;

/// Uniforms for the depth-key computation kernel.
typedef struct {
    matrix_float4x4 viewMatrix;            // World → view (left eye)
    matrix_float4x4 volumeWorldMatrix;     // Volume model → world
    uint32_t activeSplatCount;
    float    pad[3];
} DepthKeyUniforms;

/// Uniforms for each radix sort pass.
typedef struct {
    uint32_t activeSplatCount;     // Number of elements to sort
    uint32_t bitOffset;            // Which 8-bit digit (0, 8, 16, 24)
    uint32_t numThreadgroups;      // Total threadgroups dispatched for histogram/scatter
    uint32_t pad;
} RadixSortUniforms;

/// Per-eye uniforms for 3D Gaussian splat rendering.
typedef struct {
    matrix_float4x4 viewMatrix;
    matrix_float4x4 projectionMatrix;
    matrix_float4x4 volumeWorldMatrix;     // Volume model → world

    float    splatScaleAlongTangent; // Scale along orbit tangent direction
    float    splatScalePerp;         // Scale perpendicular to orbit tangent
    float    opacity;                // Global opacity multiplier (0–1)
    uint32_t activeSplatCount;       // How many splats to draw
    float    time;                   // Animation time
    float    brightnessScale;        // Global brightness multiplier
    float    viewportWidth;          // Viewport width in pixels
    float    viewportHeight;         // Viewport height in pixels
} BuddhabrotSplatRenderUniforms;

/// Stereo pair of splat render uniforms.
typedef struct {
    BuddhabrotSplatRenderUniforms uniforms[2];
} BuddhabrotSplatRenderUniformsArray;

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - Buffer Indices
// ═══════════════════════════════════════════════════════════════════════════════

typedef NS_ENUM(EnumBackingType, BuddhabrotBufferIndex) {
    BuddhabrotBufferIndexUniforms      = 0,
    BuddhabrotBufferIndexDensity       = 1,
    BuddhabrotBufferIndexDensityR      = 1, // RGB mode: short escapes (red channel)
    BuddhabrotBufferIndexDensityG      = 2, // RGB mode: medium escapes (green channel)
    BuddhabrotBufferIndexDensityB      = 3, // RGB mode: long escapes (blue channel)
    BuddhabrotBufferIndexSplats        = 1, // Splat buffer (splat mode)
    BuddhabrotBufferIndexAtomicCounter = 2, // Atomic counter for splat append
    BuddhabrotBufferIndexSplatRenderUniforms = 0, // Per-eye splat render uniforms
    // Sort buffers for 3DGS
    BuddhabrotBufferIndexSortKeysIn    = 3, // RadixSortEntry input
    BuddhabrotBufferIndexSortKeysOut   = 4, // RadixSortEntry output (ping-pong)
    BuddhabrotBufferIndexHistogram     = 5, // Per-threadgroup histograms
    BuddhabrotBufferIndexSortUniforms  = 6, // RadixSortUniforms
    BuddhabrotBufferIndexSortedIndices = 1, // Sorted index buffer for render (reuses slot 1)
};

typedef NS_ENUM(EnumBackingType, BuddhabrotTextureIndex) {
    BuddhabrotTextureIndexVolume       = 0, // 3D float texture (normalized density)
    BuddhabrotTextureIndexVolumeRGB    = 1, // Optional: 3D RGBA float texture (3-band color)
};

#endif /* BuddhabrotTypes_h */
