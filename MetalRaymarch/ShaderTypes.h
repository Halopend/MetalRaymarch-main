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
    BufferIndexFurHands      = 3
};

typedef NS_ENUM(EnumBackingType, VertexAttribute)
{
    VertexAttributePosition  = 0,
    VertexAttributeTexcoord  = 1,
};

typedef NS_ENUM(EnumBackingType, TextureIndex)
{
    TextureIndexColor    = 0
};

// Function constant indices for shader specialization
// These allow compile-time optimization by eliminating branches and enabling loop unrolling
typedef NS_ENUM(EnumBackingType, FunctionConstantIndex)
{
    FCIndexFractalIterations   = 0,  // int: Fractal iteration count for Map() loop unrolling
    FCIndexShadowIterations    = 1,  // int: Shadow iteration count
    FCIndexSafetyBubbleEnabled = 2,  // bool: Safety bubble feature toggle
    FCIndexShowFurHands        = 3,  // bool: Fur hands feature toggle
    FCIndexShowHUD             = 4,  // bool: HUD overlay toggle
    FCIndexQualityMode         = 5,  // int: 0=high, 1=medium, 2=low - controls feature degradation
    FCIndexDebugHierarchical   = 6,  // bool: Debug visualization toggle
};

typedef struct
{
    matrix_float4x4 projectionMatrix;
    matrix_float4x4 modelViewMatrix;
    matrix_float4x4 inverseModelViewMatrix;
    matrix_float4x4 inverseProjectionMatrix;
    matrix_float4x4 viewMatrix;           // Pure view matrix (no model transform)
    matrix_float4x4 inverseViewMatrix;    // For world-space ray origin
    // Temporal reprojection: previous frame matrices
    matrix_float4x4 prevProjectionMatrix;
    matrix_float4x4 prevModelViewMatrix;
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
    int useTemporalReprojection;  // 1 = use previous frame hit distance, 0 = standard
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
    // Temporal reprojection matrices
    matrix_float4x4 prevViewMatrix;
    matrix_float4x4 prevProjMatrix;
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
    int useTemporalReprojection; // 1 = use previous frame hit distance
} TileUniforms;

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

