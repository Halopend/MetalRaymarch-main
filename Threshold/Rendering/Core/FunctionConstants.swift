// Function constant indices - must match the indices in Shaders.metal
// (and the FCIndex* values in ShaderTypes.h). These allow compile-time shader
// specialization for better performance.
//
// Deliberately dependency-free (no CompositorServices/Metal imports) so the
// synchronized Threshold group compiles it into every app target: the visionOS
// Renderer, the Mac/iOS RaymarchRenderView specialization path
// (ViewportSpecializedPipelineCache), and anything else that sets function
// constants. Keeping one enum is what prevents a drifted index from silently
// baking the wrong feature toggle into a specialized pipeline (TECH_DEBT #21).
enum FunctionConstantIndex: Int {
    case fractalIterations = 0
    case shadowIterations = 1
    case safetyBubbleEnabled = 2
    case hasSpaceWarp = 3  // Compiles out the entire space-warp seam when a scene has no transforms (FC_HAS_SPACEWARP)
    case qualityMode = 4
    case debugHierarchical = 5
    case maxRaySteps = 6  // Base max ray steps (actual count scaled by quality at runtime)
    case fractalType = 7  // Devirtualizes FractalDE_Dispatch
    case neonModeEnabled = 8  // Eliminates neon orbit trap computation when false
    case colorIterations = 9  // Enables loop unrolling in ColourWithScheme
    // index 10 = FC_SHARE_SHADOWS (set in shader only)
    case shadowsEnabled = 11  // GMT-fractals: compile-out entire shadow computation
    case mandelbulbPower = 12  // Bakes integer power for fastPowR dead-code elimination
    case warmStart = 13  // Compiles in the temporal-depth march warm-start (FC_WARM_START)
    case coherentPacketEnabled = 14  // Compiles out the coherent-packet experiment when false (compute kernel)
    case coarseWarmStart = 15  // Compiles in the conservative cone coarse-prepass warm-start (FC_COARSE_WARM_START). Index 14 is taken, so this uses index 15.
    case hasEnvScrunch = 16  // Compiles out the Environment Scrunch DE-tail (grid sample + containment) when the device-local toggle is off (FC_HAS_ENVSCRUNCH)
    case sphereProjectionEnabled = 17  // Compiles out per-fold sphere projection for the common unprojected DE path
    case hasHandField = 18   // Compiles out the hand-field DE-tail (hand balls + forearm carves); macOS has no hand tracking and always bakes it off (FC_HAS_HANDFIELD). Index 17 is taken by sphereProjectionEnabled.
}
