// Shader library assembly. Header modules deliberately compile as one Metal
// translation unit so static builds and runtime custom formulas share entry points.
// Keep the formula include marker here: CustomShaderCompiler inserts user formulas
// between the configuration/ABI preamble and the rendering implementation.
#include "Shaders/Common/ShaderConfig.h"

// Must follow function constants: formula headers reference FC_* declarations.
#include "../Formulas/FractalFormulas.h"

#include "Shaders/Common/ShaderIO.h"
#include "Shaders/Rendering/VertexShaders.h"
#include "Shaders/Common/ShaderMath.h"
#include "Shaders/Common/FractalCommon.h"
#include "Shaders/Common/Color.h"
#include "Shaders/Rendering/CoarseRaymarch.h"
#include "Shaders/Cache/DistanceCacheLookup.h"
#include "Shaders/Rendering/SceneRaymarch.h"
#include "Shaders/Post/PostEffects.h"
#include "Shaders/Rendering/Lighting.h"
#include "Shaders/Common/RayReconstruction.h"
#include "Shaders/Temporal/Reprojection.h"
#include "Shaders/Post/ComputeOutput.h"
#include "Shaders/Common/AdaptiveTypes.h"
#include "Shaders/Rendering/AdaptiveRay.h"
#include "Shaders/Temporal/AdaptiveReprojection.h"
#include "Shaders/Rendering/AdaptiveTile.h"
#include "Shaders/Rendering/AdaptiveMarch.h"
#include "Shaders/Rendering/AdaptiveShading.h"
#include "Shaders/Rendering/AdaptiveRaymarch.h"
#include "Shaders/Overlays/SpringBlob.h"
#include "Shaders/Rendering/FragmentRaymarch.h"
#include "Shaders/Post/EdgeDetection.h"
#include "Shaders/Rendering/FragmentShaders.h"
#include "Shaders/Post/RCAS.h"
#include "Shaders/Post/MetalFXResolve.h"
#include "Shaders/Temporal/MotionVectors.h"
#include "Shaders/Cache/DistanceCache.h"
#include "Shaders/Overlays/SpatialRadialMenu.h"
