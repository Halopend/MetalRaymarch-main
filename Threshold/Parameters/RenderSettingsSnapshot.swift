import Foundation
import simd

// RenderSettings uses os_unfair_lock for minimal lock overhead
// This is the fastest synchronization primitive on Apple platforms
// NSLock has ~2-3x more overhead due to Objective-C dispatch
struct RenderSettingsSnapshot {
    let minDistance: Float
    let scale: Float
    let position: SIMD3<Float>
    let scenePrimitives: [ScenePrimitive]
    // World-space translation the Linear Rail animation added on top of the base
    // position this frame (position already includes it). Kept separately so the
    // Bounding Shape can be pinned in place while the rail slides content past it
    // — see boundingShapeCenterModel(modelMatrix:). Zero when the rail is off.
    let linearRailWorldOffset: SIMD3<Float>
    let fractalScale: Float
    let fractalIterations: Int
    let maxRaySteps: Int
    let colorMix: Float
    let lightingPlay: Bool
    let lightingMode: LightingMode
    let sphericalInversionMode: SphericalInversionMode
    let sphericalInversionRadius: Float
    let sphereProjectionEnabled: Bool
    let sphereProjectionBlend: Float
    let sphereProjectionRadius: Float
    let deIterationMismatch: Float
    let spaceWarpStrength: Float
    let spaceWarpParam1: Float
    let spaceWarpParam2: Float
    let spaceWarpParam3: Float
    let spaceWarpAxis: SIMD3<Float>
    let spaceWarpStack: SpaceWarpStack
    let platformRadius: Float
    let platformEnabled: Bool
    let audioLevel: Float
    let bassLevel: Float
    let midLevel: Float
    let trebleLevel: Float
    let beatIntensity: Float
    let foldingLimit: Float
    let sphereRadius: Float
    let colorIterations: Float
    let resolutionScale: Float
    let fractalType: FractalModelType
    let formulaParams: FormulaParams
    let customLightingParams: CustomLightingParams
    let tileSize: Int
    let debugHierarchical: Bool
    let coherentPacketEnabled: Bool
    let computeTemporalReprojectionEnabled: Bool
    let coarsePrepassWarmStartEnabled: Bool
    let foveationStrength: Float
    let smartAdvanceEnabled: Bool
    let coneMarchStrength: Float
    let coneCoverageAAEnabled: Bool
    let distanceLODStrength: Float
    let shadowsEnabled: Bool
    let boundingSphereSkipEnabled: Bool
    let boundingShapeRadius: Float
    let boundingShapeFogMode: Int
    let boundingShapeShadowDepth: Float
    let boundingShapeType: Float
    let boundToSpaceEnabled: Bool
    let boundToSpaceMode: Int              // 0 = Match Space, 1 = Ceiling Open, 2 = Walls Open
    let boundSpaceSize: SIMD3<Float>       // fallback room size, real meters (w, h, d)
    let boundAmbientStrength: Float        // room-derived ambient occlusion, 0 = off
    let envScrunchEnabled: Bool
    let envScrunchMode: Int                // 0 = Scrunch (bulge), 1 = Shell (only near surfaces)
    let envScrunchStrength: Float          // 0-1 blend toward the scrunched field
    let envScrunchReach: Float             // engage band around surfaces, meters
    let envScrunchContain: Int             // 0 = off, 1 = hard clip to scanned room box, 2 = soft blend
    let envScrunchContainFeather: Float    // soft-blend feather half-width, meters (mode 2)
    let zoomFogCompensationEnabled: Bool
    let limitFlash: Float
    let activeGestureIndex: Int
    let safetyBubbleEnabled: Bool
    let safetyBubbleRadius: Float
    let safetyBubbleShape: Float
    let safetyBubbleFadeEnabled: Bool
    let safetyBubbleFadeWidth: Float
    let safetyBubbleStrength: Float
    let safetyBubbleMixedAutoShrink: Bool
    let safetyBubbleMixedRadius: Float
    let handAttractionEnabled: Bool
    let handAttractionRadius: Float
    let handAttractionStrength: Float
    let handAttractionPocketEnabled: Bool
    let handAttractionBallScale: Float
    let handAttractionSoftness: Float
    let handAttractionPocketSize: Float
    let handAttractionPocketSoftness: Float
    let handAttractionProjectionDistance: Float
    let handAttractionForearmEnabled: Bool
    let handAttractionForearmRadius: Float
    let colorSchemeParams: ColorSchemeParams
    let lightingSoftness: Float
    
    // Fog for CPU precomputation (not sent to GPU in ColorSchemeParams)
    let fogEnabled: Bool
    let fogIntensity: Float
    let fogColor: SIMD3<Float>
    
    // Two-point grab world rotation + detail scale
    let worldRotation: simd_quatf
    let detailScale: Float

    // ═══════════════════════════════════════════════════════════════════════════
    // GEOMETRY STABILITY STATE
    // When geometry parameters settle, enables the stable-geometry heuristics
    // ═══════════════════════════════════════════════════════════════════════════
    let geometryState: GeometryState
    let isGeometryGestureActive: Bool

    // ═══════════════════════════════════════════════════════════════════════════
    // GMT-FRACTALS OPTIMIZATIONS
    // Step over-relaxation factor for raymarch convergence acceleration
    // ═══════════════════════════════════════════════════════════════════════════
    let stepMultiplier: Float

    // Spring blob navigation
    let springDisplacement: SIMD3<Float>
    let springActive: Bool
    let leftHandedMode: Bool
}

extension RenderSettingsSnapshot {
    /// Route only explicit 8x8 mode through the hierarchical compute path.
    var prefersAdaptiveComputePath: Bool {
        tileSize == 8
    }

    /// Bounding shape (sphere, model space) used by the march. 0 disables it.
    /// When enabled, rays that miss the sphere skip the march — bounding the
    /// visible fractal to the shape. The radius is user-set (Bounding Shape
    /// control); the 6.0 default is generous for box/bulb families, tighter
    /// values deliberately clip the fractal (e.g. for Mixed-immersion scenes).
    var estimatedBoundingSphereRadius: Float {
        boundingSphereSkipEnabled ? boundingShapeRadius : 0.0
    }

    /// Model-space center for the Bounding Shape's clip test. The shape is a
    /// fixed "vitrine": the Linear Rail translates the whole model (camera +
    /// fractal + shape all move together via the model matrix), so to keep the
    /// shape visually anchored while only the CONTENT drifts, we shift the clip
    /// center by the rail's translation expressed in model space. Cancels exactly
    /// the rail's world offset (direction transform through the model matrix
    /// inverse = (1/scale)·Rᵀ·offset), leaving the shape where it sat before the
    /// rail moved. Returns .zero when the rail is off → byte-identical to before.
    func boundingShapeCenterModel(modelMatrix: matrix_float4x4) -> SIMD3<Float> {
        let o = linearRailWorldOffset
        if o == .zero { return .zero }
        let v = modelMatrix.inverse * SIMD4<Float>(o.x, o.y, o.z, 0)
        return SIMD3<Float>(-v.x, -v.y, -v.z)
    }

    /// Shader-facing Bound to Space mode: 0 = off; otherwise the user mode
    /// shifted up by one (1 = Match Space, 2 = Ceiling Open, 3 = Walls Open).
    var resolvedBoundToSpaceMode: Int32 {
        boundToSpaceEnabled ? Int32(boundToSpaceMode + 1) : 0
    }

    /// Shader-facing Environment Scrunch block: the toggle + knobs from this
    /// snapshot fused with the caller's live grid (world-anchored distance
    /// field) and the frame's model→world transform. Address 0 or the toggle
    /// off → default (enabled 0, never dereferenced). Distances are converted
    /// to MODEL units here so the DE needs no per-sample unit math beyond one
    /// multiply; hug/carve/soft are fixed world-scale constants chosen to sit
    /// comfortably above the grid's cell size.
    func makeEnvScrunchParams(modelToWorld: matrix_float4x4,
                              viewerWorld: SIMD3<Float>,
                              gridOrigin: SIMD3<Float>,
                              gridCell: SIMD3<Float>,
                              gridAddress: UInt64,
                              surfaceMinWorld: SIMD3<Float>,
                              surfaceMaxWorld: SIMD3<Float>,
                              farClampMeters: Float) -> EnvScrunchParams {
        var p = EnvScrunchParams()
        guard envScrunchEnabled, gridAddress != 0,
              gridCell.x > 0, gridCell.y > 0, gridCell.z > 0 else { return p }
        // Uniform-scale assumption (same as Bound to Space): model→world
        // distance scale = length of any basis column.
        let sx = modelToWorld.columns.0
        let scale = simd_length(SIMD3<Float>(sx.x, sx.y, sx.z))
        guard scale > 1e-6 else { return p }
        let metersToModel = 1.0 / scale
        p.enabled = 1
        p.mode = Int32(envScrunchMode)
        p.strength = envScrunchStrength
        p.bandModel = envScrunchReach * metersToModel
        p.softModel = 0.12 * metersToModel   // blend k, meters
        p.hugModel = 0.15 * metersToModel    // bulge-shell standoff, meters
        p.carveModel = 0.08 * metersToModel  // clearance kept empty, meters
        p.metersToModel = metersToModel
        let viewerModel4 = modelToWorld.inverse * SIMD4<Float>(viewerWorld.x, viewerWorld.y, viewerWorld.z, 1.0)
        p.viewerModel = SIMD3<Float>(viewerModel4.x, viewerModel4.y, viewerModel4.z)
        // Bake far-clamp in model units — the shader's out-of-grid return.
        // Passed in from EnvironmentSDFGrid.clampFar by the callers so the
        // shader and the bake can never drift (TECH_DEBT.md #19).
        p.farClampModel = farClampMeters * metersToModel
        // model → grid texels: scale(1/cell) ∘ translate(-origin) ∘ modelToWorld
        var toGrid = matrix_identity_float4x4
        toGrid.columns.0.x = 1.0 / gridCell.x
        toGrid.columns.1.y = 1.0 / gridCell.y
        toGrid.columns.2.z = 1.0 / gridCell.z
        toGrid.columns.3 = SIMD4<Float>(-gridOrigin.x / gridCell.x,
                                        -gridOrigin.y / gridCell.y,
                                        -gridOrigin.z / gridCell.z, 1.0)
        p.modelToGrid = toGrid * modelToWorld
        p.gridAddress = gridAddress
        // Shell-mode gradients need the real voxel step even when containment
        // is off or the scan has not established a full 3-D envelope yet.
        p.cellModel = gridCell * metersToModel
        // Containment box: scanned surface AABB → grid texel coords (so the same
        // modelToGrid transform handles rotation). Scene reconstruction often
        // arrives as one floor/wall plane first. When two axes are established,
        // use the grid extent for the one unconstrained axis so containment can
        // become useful immediately without collapsing the fractal to a plane.
        // A line/point scan remains too underconstrained and stays off.
        let dimF = Float(ENV_SCRUNCH_DIM)
        let zero = SIMD3<Float>(repeating: 0)
        let dimV = SIMD3<Float>(repeating: dimF)
        var cmin = simd_clamp((surfaceMinWorld - gridOrigin) / gridCell, zero, dimV)
        var cmax = simd_clamp((surfaceMaxWorld - gridOrigin) / gridCell, zero, dimV)
        let extent = cmax - cmin
        // Treat sub-voxel thickness as reconstruction noise, not a resolved
        // room dimension. Real AR floor/wall meshes are rarely mathematically
        // flat, so an epsilon-scale test turns them into razor-thin clip boxes.
        let resolvedAxisThreshold: Float = 1.0
        let xResolved = extent.x > resolvedAxisThreshold
        let yResolved = extent.y > resolvedAxisThreshold
        let zResolved = extent.z > resolvedAxisThreshold
        let resolvedAxisCount = (xResolved ? 1 : 0)
            + (yResolved ? 1 : 0)
            + (zResolved ? 1 : 0)
        if resolvedAxisCount >= 2 {
            if !xResolved { cmin.x = 0; cmax.x = dimF }
            if !yResolved { cmin.y = 0; cmax.y = dimF }
            if !zResolved { cmin.z = 0; cmax.z = dimF }
        }
        if envScrunchContain > 0, resolvedAxisCount >= 2 {
            p.containMode = Int32(envScrunchContain)
            p.containFeatherModel = envScrunchContainFeather * metersToModel
            p.containMinGrid = cmin
            p.containMaxGrid = cmax
        }
        return p
    }
}
