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
// MARK: - Buffer Indices
// ═══════════════════════════════════════════════════════════════════════════════

typedef NS_ENUM(EnumBackingType, BuddhabrotBufferIndex) {
    BuddhabrotBufferIndexUniforms      = 0,
    BuddhabrotBufferIndexDensity       = 1,
    BuddhabrotBufferIndexDensityR      = 1, // RGB mode: short escapes (red channel)
    BuddhabrotBufferIndexDensityG      = 2, // RGB mode: medium escapes (green channel)
    BuddhabrotBufferIndexDensityB      = 3, // RGB mode: long escapes (blue channel)
};

typedef NS_ENUM(EnumBackingType, BuddhabrotTextureIndex) {
    BuddhabrotTextureIndexVolume       = 0, // 3D float texture (normalized density)
    BuddhabrotTextureIndexVolumeRGB    = 1, // Optional: 3D RGBA float texture (3-band color)
};

#endif /* BuddhabrotTypes_h */
