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
#else
#import <Foundation/Foundation.h>
typedef NSInteger EnumBackingType;
#endif

#include <simd/simd.h>

typedef NS_ENUM(EnumBackingType, BufferIndex)
{
    BufferIndexMeshPositions = 0,
    BufferIndexMeshGenerics  = 1,
    BufferIndexUniforms      = 2,
    BufferIndexFurHands      = 3,
    BufferIndexGSTHierarchy  = 4
};

typedef NS_ENUM(EnumBackingType, VertexAttribute)
{
    VertexAttributePosition  = 0,
    VertexAttributeTexcoord  = 1,
};

typedef NS_ENUM(EnumBackingType, TextureIndex)
{
    TextureIndexColor    = 0,
    TextureIndexGSTLevel0 = 1,
    TextureIndexGSTLevel1 = 2,
    TextureIndexGSTLevel2 = 3,
    TextureIndexGSTLevel3 = 4,
};

typedef struct
{
    matrix_float4x4 projectionMatrix;
    matrix_float4x4 modelViewMatrix;
    matrix_float4x4 inverseModelViewMatrix;
    matrix_float4x4 inverseProjectionMatrix;
    matrix_float4x4 viewMatrix;           // Pure view matrix (no model transform)
    matrix_float4x4 inverseViewMatrix;    // For world-space ray origin
    float time;
    float minDistance;
    vector_float2 foveaCenter;
    float fractalScale;
    int fractalIterations;
    int maxRaySteps;
    float foveationIntensity;
    float colorMix;
    float glowIntensity;
    float foldingLimit;      // Box folding limit (default 1.0)
    float sphereRadius;      // Sphere folding radius (default 0.5)
    float safetyBubbleRadius; // Safety bubble radius (meters)
    int safetyBubbleEnabled;  // Enable safety bubble (0/1)
    float colorIterations;   // How many iterations contribute to color
    int useHierarchical;     // 1 = hierarchical coarse/fine, 0 = standard
    float limitFlash;        // Edge flash when gesture hits limit (0-1)
    int showHUD;             // Show in-world HUD overlay (0/1)
    int activeGesture;       // Currently active gesture (0=none, 1=index, 2=middle, 3=ring)
    int useGST;              // Use Grid Sphere Tracing (0/1)
    // Refining parameters (Polychronakis 2024 / Keinert 2014)
    float relaxFactor;       // Over-relaxation multiplier (default 1.6)
    float relaxBacktrack;    // Backtrack factor when overshooting (default 0.7)
    float sdfScaleCoarse;    // SDF scaling for coarse pass (default 1.3)
    float sdfScaleSuperCoarse; // SDF scaling for super-coarse pass (default 1.5)
    float earlyTermRatio;    // Early termination convergence ratio (default 0.3)
    int earlyTermCount;      // Steps before early termination (default 3)
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
    vector_float2 resolution;
    float minDistance;
    float fractalScale;
    float sphereRadius;
    float safetyBubbleRadius; // Safety bubble radius (meters)
    int safetyBubbleEnabled;  // Enable safety bubble (0/1)
    float foldingLimit;
    float glowIntensity;
    float colorMix;
    int fractalIterations;
    int colorIterations;
    int maxRaySteps;
    uint32_t eyeIndex;
    uint32_t debugHierarchical;  // 1 = show debug tint (green=hit, red=miss)
    float limitFlash;            // Edge flash when gesture hits limit (0-1)
    // Refining parameters (Polychronakis 2024 / Keinert 2014)
    float relaxFactor;           // Over-relaxation multiplier (default 1.6)
    float relaxBacktrack;        // Backtrack factor when overshooting (default 0.7)
    float sdfScaleCoarse;        // SDF scaling for coarse pass (default 1.3)
    float sdfScaleSuperCoarse;   // SDF scaling for super-coarse pass (default 1.5)
    float earlyTermRatio;        // Early termination convergence ratio (default 0.3)
    int earlyTermCount;          // Steps before early termination (default 3)
} TileUniforms;

// =============================================================================
// GRID SPHERE TRACING DATA STRUCTURES
// =============================================================================
// Precomputed SDF hierarchy for efficient ray marching

#define GST_MAX_LEVELS 5
#define GST_BASE_RESOLUTION 64  // Level 0 resolution (64^3)

typedef struct
{
    vector_int3 resolution;     // (nx, ny, nz) for this level
    float voxelSize;            // World-space size of one voxel edge
    float voxelDiagonal;        // sqrt(3) * voxelSize (precomputed)
    float scale;                // 2.5 * voxelDiagonal (for decode)
} SDFGridLevel;

typedef struct
{
    int numLevels;              // Typically 4-5
    SDFGridLevel levels[GST_MAX_LEVELS];
    vector_float3 gridOrigin;   // World-space origin of level 0
    float gridExtent;           // World-space extent of entire grid
    int isBuilt;                // 1 if grid is ready for use
} SDFHierarchy;

// Uniforms for SDF grid compute shader
// Explicit padding to ensure Swift/Metal layout match
typedef struct
{
    int levelIndex;             // offset 0
    int pad1;                   // offset 4
    int pad2;                   // offset 8
    int pad3;                   // offset 12
    
    vector_int3 resolution;     // offset 16 (16-byte aligned)
    
    float voxelSize;            // offset 32 (size 4)
    float pad4;                 // offset 36
    float pad5;                 // offset 40
    float pad6;                 // offset 44
    
    vector_float3 gridOrigin;   // offset 48 (16-byte aligned)
    
    // Fractal parameters for sceneSDF
    float minDistance;          // offset 64
    float fractalScale;         // offset 68
    float sphereRadius;         // offset 72
    float foldingLimit;         // offset 76
    
    int fractalIterations;      // offset 80
    int pad7;                   // offset 84
    int pad8;                   // offset 88
    int pad9;                   // offset 92
} SDFGridBuildUniforms;

// Hand joint data for fur rendering
// 26 joints per hand (ARKit HandSkeleton)
#define HAND_JOINT_COUNT 26

typedef struct
{
    vector_float3 position;
    float radius;              // Joint sphere radius for SDF
} FurHandJoint;

typedef struct
{
    FurHandJoint joints[HAND_JOINT_COUNT];
    int isTracked;             // 0 = not tracked, 1 = tracked
    float furDensity;          // Fur strand density (0.5 - 2.0)
    float furLength;           // Fur strand length in meters (0.005 - 0.02)
    float furNoiseScale;       // Noise frequency for fur variation
} FurHandData;

typedef struct
{
    FurHandData leftHand;
    FurHandData rightHand;
    float time;
    int showFurHands;          // 0 = hidden, 1 = show fur hands
} FurHandUniforms;

#endif /* ShaderTypes_h */

