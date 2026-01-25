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
    BufferIndexUniforms      = 2
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
    FCIndexShowHUD             = 3,  // bool: HUD overlay toggle
    FCIndexQualityMode         = 4,  // int: 0=high, 1=medium, 2=low - controls feature degradation
    FCIndexDebugHierarchical   = 5,  // bool: Debug visualization toggle
};

// Fractal type selection
typedef NS_ENUM(EnumBackingType, FractalType)
{
    FractalTypeMandelbox         = 0,
    FractalTypeTriforce          = 1,
    FractalTypeNegativeMandelbox = 2,  // Scale = -1.5 Mandelbox (organic, dense)
    FractalTypeOrbitDensity       = 3,  // 3D orbit-density variant (Buddhabrot-style)
};

// Color scheme selection (built-in presets)
typedef NS_ENUM(EnumBackingType, ColorSchemeType)
{
    ColorSchemeClassic           = 0,  // Original Mandelbox colors (red/gray/gold)
    ColorSchemeOcean             = 1,  // Deep blues and teals
    ColorSchemeFire              = 2,  // Warm oranges and reds
    ColorSchemeForest            = 3,  // Greens and browns
    ColorSchemeNebula            = 4,  // Purple/pink cosmic
    ColorSchemeMono              = 5,  // Grayscale with subtle tints
    ColorSchemeAurora            = 6,  // Northern lights (greens/blues/purples)
    ColorSchemeVolcanic          = 7,  // Dark with lava accents
    ColorSchemeNeonCyber         = 8,  // Neon cyberpunk (hot pink/cyan/purple)
    ColorSchemeNeonSunset        = 9,  // Neon sunset (orange/magenta/violet)
    ColorSchemeNeonMatrix        = 10, // Neon matrix (bright greens/black)
    ColorSchemeCount             = 11, // Number of schemes (for bounds checking)
};

// Color scheme parameters passed to shader
// Allows full customization of the fractal coloring
typedef struct
{
    // Primary color palette (3 colors for gradient mixing)
    vector_float3 color1;             // Primary color (trap-based)
    vector_float3 color2;             // Secondary color (trap-based)
    vector_float3 color3;             // Tertiary color (position-based)
    
    // Alternative palette for colorMix blending
    vector_float3 altColor1;          // Alternative palette base
    vector_float3 altMixFactors;      // Factors for alt color computation (x*c.x, y*c.y, z+w*c.y)
    
    // Post-processing adjustments
    float saturation;                 // Color saturation multiplier (default 1.5)
    float contrast;                   // Contrast adjustment (default 1.05)
    float gamma;                      // Gamma correction (default 0.5)
    float brightness;                 // Brightness offset (default 0.0)
    
    // Neon mode parameters (HSV-based orbit trap coloring)
    float neonIntensity;              // 0 = off, 1 = full neon mode
    float hueFrequency;               // Frequency of hue variation (default 3.0)
    float hueOffset;                  // Base hue offset (default 0.0)
    float bandFrequency;              // Distance band frequency for glow rings (default 8.0)
    float stripeFrequency;            // Iteration stripe frequency (default 6.0)
    float stripeStrength;             // Stripe intensity (default 0.4)
    float glowSharpness;              // How sharp the bright cores are (default 3.0)
    float saturationPower;            // Power for saturation curve, <1 flattens to 1.0 (default 0.4)
    
    // Dynamic animation parameters
    float animTime;                   // Current animation time (seconds)
    float hueCycleSpeed;              // Speed of hue rotation (0 = static, 0.1 = slow)
    float pulseSpeed;                 // Speed of brightness/saturation pulse (0 = static)
    float pulseAmount;                // Amount of pulse effect (0-1)
    float glowIntensity;              // Ray-step based glow intensity (0-1)
    float bloomStrength;              // Cheap bloom effect strength (0-1)
    
    // Animation/transition
    float transitionProgress;         // 0-1: blend from previous to current scheme
    int previousScheme;               // Previous scheme index for transitions
    int currentScheme;                // Current scheme index
    int _padding;                     // Alignment padding
} ColorSchemeParams;

// Symmetry-based movement state for fractal navigation
// Used to animate along paths that follow fractal symmetry planes
typedef struct
{
    vector_float3 currentDirection;    // Current movement direction (normalized)
    vector_float3 targetDirection;     // Target symmetry-aligned direction
    vector_float3 primaryAxis;         // Primary symmetry axis at current position
    vector_float3 secondaryAxis;       // Secondary symmetry axis
    vector_float3 tertiaryAxis;        // Tertiary symmetry axis
    float blendProgress;               // 0-1: progress blending to target direction
    float blendDuration;               // Seconds to complete direction change
    float timeSinceLastUpdate;         // Time since symmetry was recalculated
    float updateInterval;              // Seconds between symmetry recalculations
    float symmetryStrength;            // 0-1: how symmetric current region is
    uint32_t foldMask;                 // Bitmask of active folds (for debugging/viz)
    float movementSpeed;               // World units per second
    int preferredAxisIndex;            // 0=primary, 1=secondary, 2=tertiary, -1=auto
} SymmetryMovementState;

// Default initialization for SymmetryMovementState
#ifndef __METAL_VERSION__
static inline SymmetryMovementState SymmetryMovementStateDefault(void) {
    SymmetryMovementState state;
    state.currentDirection = (vector_float3){0.0f, 0.0f, 1.0f};
    state.targetDirection = (vector_float3){0.0f, 0.0f, 1.0f};
    state.primaryAxis = (vector_float3){1.0f, 0.0f, 0.0f};
    state.secondaryAxis = (vector_float3){0.0f, 1.0f, 0.0f};
    state.tertiaryAxis = (vector_float3){0.0f, 0.0f, 1.0f};
    state.blendProgress = 1.0f;
    state.blendDuration = 0.5f;
    state.timeSinceLastUpdate = 0.0f;
    state.updateInterval = 0.5f;
    state.symmetryStrength = 0.5f;
    state.foldMask = 0;
    state.movementSpeed = 0.3f;
    state.preferredAxisIndex = -1;  // Auto-select
    return state;
}
#endif

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
    float safetyBubbleShape;  // 0 = sphere, 1 = cube, intermediate = morph (no rotation)
    float colorIterations;   // How many iterations contribute to color
    int useHierarchical;     // 1 = hierarchical coarse/fine, 0 = standard
    float limitFlash;        // Edge flash when gesture hits limit (0-1)
    int showHUD;             // Show in-world HUD overlay (0/1)
    int activeGesture;       // Currently active gesture (0=none, 1=index, 2=middle, 3=ring, 4=pinky)
    int fractalType;         // 0=Mandelbox, 1=Triforce, 2=Negative Mandelbox, 3=Orbit Density
    int lightingMode;        // 0=static, 1=animated, 2=audio-reactive
    float audioLevel;        // Audio level for reactive lighting (0-1)
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
    vector_float2 resolution;
    float minDistance;
    float fractalScale;
    float sphereRadius;
    float safetyBubbleRadius; // Safety bubble radius (meters)
    int safetyBubbleEnabled;  // Enable safety bubble (0/1)
    float safetyBubbleShape;  // 0 = sphere, 1 = cube, intermediate = morph (no rotation)
    float foldingLimit;
    float glowIntensity;
    float colorMix;
    int fractalIterations;
    int colorIterations;
    int maxRaySteps;
    uint32_t eyeIndex;
    uint32_t debugHierarchical;  // 1 = show debug tint (green=hit, red=miss)
    float limitFlash;            // Edge flash when gesture hits limit (0-1)
    int fractalType;             // 0=Mandelbox, 1=Triforce, 2=Negative Mandelbox, 3=Orbit Density
    int lightingMode;            // 0=static, 1=animated, 2=audio-reactive
    float audioLevel;            // Audio level for reactive lighting (0-1)
    ColorSchemeParams colorScheme;  // Color scheme parameters for palette control
} TileUniforms;

#endif /* ShaderTypes_h */