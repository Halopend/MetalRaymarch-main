//
//  Renderer.swift
//  MetalProject
//
//  Created by MU on 18/11/24.
//

@preconcurrency import CompositorServices
@preconcurrency import Metal
import MetalKit
import simd
import ARKit
import QuartzCore
import Synchronization

// Debug logging toggle - set to false for release builds
let RENDERER_DEBUG = false

actor Renderer {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    /// Wall-clock anchor for ambient time-motion (light-orbit drift, dither, spring
    /// vibration). Replaces the removed AppClock; mirrors the Mac/iOS path's
    /// `CACurrentMediaTime`-based elapsed clock in RaymarchRenderView so visionOS
    /// animates identically.
    let renderStartTime: CFTimeInterval = CACurrentMediaTime()
    var dynamicUniformBuffer: MTLBuffer
    var pipelineState: MTLRenderPipelineState
    var depthState: MTLDepthStencilState

    // === UNIFIED PIPELINE CACHE ===
    // All specialized pipelines stored in a single cache with consistent key format.
    // Key format: "FI{iterations}_RS{raySteps}_N{0|1}_Q{0|1|2}"
    // This allows preset pipelines and quality preset pipelines to be looked up uniformly.
    //
    // Pipeline specialization strategy:
    // - Quality presets (iter6-iter16): Compiled with neon=false for speed
    // - Saved presets: Fully specialized with all known function constants
    // - On-demand: Built lazily when requested config not found in cache
    
    /// Unified pipeline cache - all specialized pipelines keyed by function constant signature
    var pipelineCache: [String: MTLRenderPipelineState] = [:]

    /// Cache keys currently being built asynchronously by `enqueueBackgroundPipelineBuild`.
    /// Used to suppress duplicate background builds while a cache miss is being served
    /// by a quality-preset fallback on-frame. Actor-isolated — only touched from the
    /// Renderer actor.
    var pendingPipelineBuildKeys: Set<String> = []
    var pendingComputePipelineBuildKeys: Set<String> = []
    var renderPipelineBuildRetryStates: [String: PipelineBuildRetryState] = [:]
    var computePipelineBuildRetryStates: [String: PipelineBuildRetryState] = [:]

    /// Compute pipeline cache - specialized compute kernels keyed by "FI{n}_RS{n}"
    /// Mirrors the render pipeline cache but for the adaptive hierarchical compute path.
    /// Each entry has Map()/Shadow loops fully unrolled for that iteration count.
    var computePipelineCache: [String: MTLComputePipelineState] = [:]
    /// Track last compute pipeline key to avoid log spam
    var lastComputePipelineKey: String = ""
    
    // === COMPUTE PIPELINE SELECTION FAST-PATH ===
    var lastComputeFT: Int32 = -1
    var lastComputeFI: Int = -1
    var lastComputeRS: Int = -1
    var lastComputePower: Int32?
    var lastComputeCustomHash: String?
    var lastComputeBubble: Bool?
    var lastComputePacket: Bool?
    var lastComputeSpaceWarp: Bool?
    var lastComputeEnvScrunch: Bool?
    var lastComputeHandField: Bool?
    var lastSelectedComputePipeline: MTLComputePipelineState?

    // === UI UPDATE COORDINATION ===
    /// Coordinates UI updates without blocking MainActor during heavy rendering
    private(set) var uiUpdateCoordinator: UIUpdateCoordinator?

    /// Coordinates parameter smoothing and animation updates without blocking MainActor
    private(set) var parameterUpdateCoordinator: ParameterUpdateCoordinator?

    // Cached constant matrices (computed once, reused every frame)
    let cachedRotationMatrix: matrix_float4x4

    // Smoothed render distance persists across frames and is folded into the
    // explicit frame preparation returned by updateGameState().
    var smoothedMaxViewDistance: Float = RenderSettings.maxViewDistance
    
    // Tile-based compute pipelines (adaptive 8x8 hierarchical cascade)
    var adaptiveHierarchicalPipeline8x8: MTLComputePipelineState?  // Adaptive 3-level cascade
    var edgeDetectionPipeline: MTLComputePipelineState?
    var tileUniformBuffer: MTLBuffer?

    // Per-frame/per-eye foveation rate-map parameter buffers for the adaptive
    // compute path. CPU copies are not covered by Metal hazard tracking, so the
    // buffers must follow the same in-flight ring as the uniform buffers.
    // The kernel decodes physical→screen coordinates from these so it stops
    // distorting under foveation / renderQuality. `rateMapDummyBuffer` keeps the
    // kernel's buffer(1) argument bound when no usable rate map exists.
    private var rateMapParamBuffers: [MTLBuffer?] = Array(
        repeating: nil,
        count: maxBuffersInFlight * 2
    )
    private var rateMapDummyBuffer: MTLBuffer?
    private var loggedFoveationDecodeOnce = false

    // Dedicated compute output texture (has .shaderWrite flag that drawable textures lack)
    var computeOutputTexture: MTLTexture?
    var edgeOutputTexture: MTLTexture?
    private var hasLoggedComputeMemoryFallback = false
    /// A recoverable command-buffer failure on the adaptive kernel disables that
    /// path for the rest of this renderer session. Repeating a known GPU fault on
    /// every frame can escalate into a device reset or compositor termination.
    var adaptiveComputeSuppressedAfterGPUFailure = false
    private var hasLoggedAdaptiveComputeGPUFailure = false

    // ═══════════════════════════════════════════════════════════════════════════
    // TEMPORAL REPROJECTION STATE
    // Double-buffered depth textures store ray-t per pixel for reuse next frame.
    // Previous frame's depth + MVP lets us skip ~90% of fine raymarching steps
    // for pixels that didn't move much between frames.
    // ═══════════════════════════════════════════════════════════════════════════
    private var temporalDepthTextures: [MTLTexture?] = [nil, nil]  // ping-pong
    private var temporalDepthIndex: Int = 0                         // which is "current write"

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSERVATIVE CONE COARSE-PREPASS WARM-START (fragment path, opt-in)
    // A low-res compute pass (coneCoarsePrepass8x8) marches one cone per 8x8 block
    // and writes a provable LOWER BOUND on the nearest-surface entry distance into
    // this r32Float array texture (physical/8 sized, one layer per eye). The
    // fragment shader raises its full-march start t to that bound. Defaults OFF —
    // when off the pass is never dispatched, the fragment FC stays undefined, and a
    // 1x1 dummy keeps the texture slot bound so validation never faults.
    // ═══════════════════════════════════════════════════════════════════════════
    private var coarseStartTexture: MTLTexture?
    var coneCoarsePrepassPipeline: MTLComputePipelineState?
    private var coarseStartDummyTexture: MTLTexture?
    // Lazily-built, separately-cached cone-enabled fragment pipelines (FC_COARSE_
    // WARM_START=true). Keyed by the same exact signature selectPipeline uses, so a
    // variant is built per (iterations, raySteps, fractalType, …) the first time
    // the user turns the toggle on for that config. Keeps the main pipeline cache
    // (always FC off) byte-identical.
    var coarseWarmStartPipelineCache: [String: MTLRenderPipelineState] = [:]
    var previousViewProjMatrices: [matrix_float4x4] = [matrix_identity_float4x4, matrix_identity_float4x4]  // per eye
    private var temporalFrameCount: Int = 0                         // 0 = first frame, no reprojection
    // Compute depth has a separate texture lifecycle from MetalFX fragment
    // depth, so scene compatibility must be tracked independently.
    var computeWarmStartGate = WarmStartGate()


    // ═══════════════════════════════════════════════════════════════════════════
    // TEMPORAL DEPTH WARM-START (fragment path)
    // The fragment raymarch reprojects last frame's MetalFX depth to start each
    // ray just in front of the previously-hit surface (narrow window, reduced
    // step budget, full-march fallback on miss). These track whether last
    // frame's depth is trustworthy for that.
    // ═══════════════════════════════════════════════════════════════════════════
    // Single owner of warm-start validity (see WarmStartGate in
    // RendererCoreTypes.swift): paths that don't write fragment depth call
    // invalidate(), the MetalFX path records the geometry key on success, and
    // the per-frame uniform patch asks allowsWarmStart(). Continuous geometry
    // params are compared with a per-frame tolerance so smooth-damp and audio
    // morphs don't permanently disable the optimization.
    var warmStartGate = WarmStartGate()
    // Bound on the direct (non-MetalFX) path where pipelines still declare the
    // prev-depth argument; never sampled there (warmStartEnabled == 0).
    var warmStartDummyDepthTexture: MTLTexture?

    // Custom-formula self-heal bookkeeping (see scheduleCustomLibrarySelfHeal
    // in RendererCustomShader.swift): set while a recovery activation is in
    // flight, with a minimum spacing between attempts so a formula that fails
    // to compile can't hot-loop the compiler.
    var customLibrarySelfHealInFlight = false
    var lastCustomLibrarySelfHealAttempt: TimeInterval = 0

    // MRU list of custom-formula hashes whose specialized pipelines stay
    // cached (see retainCustomShaderPipelines). Front = most recent.
    var recentCustomFormulaHashes: [String] = []
    
    // Cached view amplification mappings — avoids per-frame array allocation
    var cachedViewMappings: [MTLVertexAmplificationViewMapping] = []
    var cachedViewMappingsCount: Int = 0
    
    // Screenshot capture
    var screenshotTexture: MTLTexture?
    var screenshotPipeline: MTLRenderPipelineState?
    var screenshotDepthTexture: MTLTexture?
    var screenshotUniformBuffer: MTLBuffer?
    /// Grid referenced by the uniforms in the most recently submitted ring
    /// slot. Screenshot capture copies those uniforms and must retain this
    /// exact resource rather than whichever grid has since been published.
    var lastSubmittedEnvironmentGrid: EnvironmentSDFGrid?
    var pendingScreenshotContinuation: CheckedContinuation<Data?, Never>?
    var shouldCaptureScreenshot: Bool = false
    
    // Pipeline profiling trigger
    nonisolated(unsafe) var shouldRunProfiler: Bool = false

    let inFlightSemaphore = DispatchSemaphore(value: maxBuffersInFlight)

    var uniformBufferOffset = 0

    var uniformBufferIndex = 0

    /// Per-in-flight counter buffers (2 × UInt32 = {stepSum, hitCount}) bound at
    /// BufferIndexBenchCounters for the benchmark iteration counter. One per slot
    /// so a frame's GPU writes never collide with the next frame's CPU zero.
    var benchCounterBuffers: [MTLBuffer] = []

    var uniforms: UnsafeMutablePointer<UniformsArray>

    let rasterSampleCount: Int = 1
    let mtlVertexDescriptor: MTLVertexDescriptor  // Stored for pipeline building
    var hasLoggedFoveationAvailability = false
    var hasLoggedWorldTrackingWarning = false
    var hasLoggedDeviceAnchorInfo = false
    var hasLoggedMissingDeviceAnchor = false

#if canImport(MetalFX)
    var metalFXManager: MetalFXManager?
    var metalFXFence: MTLFence?

    var hasLoggedMetalFXFallback = false
    var hasLoggedMetalFXLayout = false
    var hasLoggedMetalFXResolve = false
    var hasLoggedMetalFXBlitSizeMismatch = false
    var hasLoggedMetalFXClamp = false
    var metalFXColorResolvePipeline: MTLRenderPipelineState?
    var metalFXDepthResolvePipeline: MTLRenderPipelineState?
    // Phase 2.7: Merged color+depth resolve in a single render encoder.
    var metalFXMergedResolvePipeline: MTLRenderPipelineState?
#endif

    // === RESIDENCY SET (visionOS 2.0+) ===
    // Pre-validates GPU resource residency to reduce per-frame validation overhead
    var residencySet: MTLResidencySet?

    // Device pose smoothing removed — use raw device anchor from drawable for async timewarp
    
    // FPS tracking
    var lastPresentationTime: LayerRenderer.Clock.Instant?
    var smoothedFPS: Double = 0

    // FPS-holding governor: lowers the applied compositor Render Quality when the
    // frame rate sags and recovers toward the user's slider (the ceiling) when it
    // has headroom. Driven once per frame from `smoothedFPS`.
    var adaptiveRenderQuality = AdaptiveRenderQualityController()

    // Last render-quality target pushed to layerRenderer.renderQuality. The
    // compositor smooths transitions, so we only re-set it when the target
    // actually changes (re-setting every frame would restart the ramp).
    var lastAppliedRenderQuality: Float = -1
    // Change-detection for the in-headset render diagnostics readout so we only
    // hop to MainActor when something the user can see has actually changed.
    var lastPublishedDiagnosticsKey: String = ""

    // One-shot log guard for visionOS 26+ queryDrawables() candidate sizes.
    var hasLoggedDrawableQualityOptions: Bool = false

    // Progressive-immersion portal pass (visionOS 26+): app-owned stencil
    // texture the compositor's drawable render context draws its portal mask
    // into. Memoryless (clear → dontCare, consumed within the pass); rebuilt
    // when the drawable geometry changes. See encodeDrawableRenderContextPass.
    var portalStencilTexture: MTLTexture?
    var hasLoggedProgressivePortal: Bool = false

    var lastHandTrackingUpdateTime: TimeInterval = 0  // Throttle hand UI updates
    var lastHandDiagnosticsPublishTime: TimeInterval = 0
    // Hand Attraction: last-known palm positions, written synchronously in
    // updateHandTracking (Renderer actor) and read back the same frame in
    // updateGameState — no actor hop needed since GestureProcessor's state
    // of this data is @MainActor-isolated and would require one.
    var lastLeftHandPalmPosition: SIMD3<Float> = .zero
    var lastLeftHandTrackedForAttraction: Bool = false
    var lastRightHandPalmPosition: SIMD3<Float> = .zero
    var lastRightHandTrackedForAttraction: Bool = false
    // Forearm capsule endpoints (world space) for the Hand Attraction forearm
    // extension — wrist + elbow per arm, captured alongside the palms.
    var lastLeftForearmWrist: SIMD3<Float> = .zero
    var lastLeftForearmElbow: SIMD3<Float> = .zero
    var lastLeftForearmTracked: Bool = false
    var lastRightForearmWrist: SIMD3<Float> = .zero
    var lastRightForearmElbow: SIMD3<Float> = .zero
    var lastRightForearmTracked: Bool = false
    // Hand-tracking dispatch coordination between the render loop (Renderer actor)
    // and the serial off-main GestureProcessor. A single Mutex
    // replaces the previous pair of `nonisolated(unsafe)` flags: the render loop
    // is synchronous, but `finishHandTrackingDispatch()` runs off-actor from a
    // Task continuation, so we need real synchronization on the state they share
    // (in-flight flag + accumulated delta).
    struct HandTrackingDispatchState {
        var inFlight: Bool = false
        var pendingDelta: Float = 0
    }
    let handTrackingDispatchState = Mutex(HandTrackingDispatchState())
    var hasLoggedHandTrackingNil: Bool = false          // One-shot guard for nil provider log
    var lastHandTrackingStateLogTime: TimeInterval = 0  // Throttle non-running state logs
    var cachedDeltaTime: Float = 1.0 / 90.0  // Cached for use in updateGameState
    var lastPerfLogTime: TimeInterval = 0
    let perfLogFrameMsThreshold: Double = 30.0  // ~33 FPS
    private var lastFPSConsoleLogTime: TimeInterval = 0  // For periodic FPS console logging

    // Shared music-reactive engine. Owns all per-target oscillator/envelope state,
    // damped source levels, the triplet-gain cache, and the reusable operation
    // buffer. The same engine type backs the macOS render path so the
    // response-curve / LFO / dispatch math lives in exactly one place.
    private let musicReactiveEngine = MusicReactiveEngine()

    // Lifetime is bounded to init/deinit; the task body still hops back onto the actor.
    nonisolated(unsafe) private var setupTask: Task<Void, Never>?
    // Track detached background builds so they can be cancelled during teardown.
    // `internal` (not `fileprivate`) because the Renderer is split across extension
    // files under Rendering/Core/ that mutate these task maps.
    nonisolated(unsafe) var backgroundRenderPipelineBuildTasks: [String: Task<Void, Never>] = [:]
    nonisolated(unsafe) var backgroundComputePipelineBuildTasks: [String: Task<Void, Never>] = [:]
    // At most one hand-tracking dispatch task is in flight due to handTrackingDispatchState.
    nonisolated(unsafe) var handTrackingDispatchTask: Task<Void, Never>?

    /// Cross-launch cache of compiled compute pipeline binaries. Optional: nil if
    /// Application Support is unavailable, in which case every launch recompiles.
    let pipelineArchive: PipelineBinaryArchive?
    /// Cross-launch cache of compiled *render* pipeline binaries (separate file so
    /// compute/render invalidate independently). Same additive, try?-guarded model.
    let renderPipelineArchive: PipelineBinaryArchive?
    /// Coalesces archive serialization after bursts of lazy compute-pipeline
    /// builds — rescheduled on each build, fires once the burst settles.
    nonisolated(unsafe) var archiveSerializeTask: Task<Void, Never>?

    var smoothedScale: Float = 1.0
    
    var lastImmersiveSpaceState: AppModel.ImmersiveSpaceState?

    var mesh: MTKMesh
    
    // Cached mesh vertex layout — avoids per-frame enumeration + type-casting of MDLVertexBufferLayout
    struct CachedMeshBinding {
        let bufferIndex: Int
        let buffer: MTLBuffer
        let offset: Int
    }
    var cachedMeshBindings: [CachedMeshBinding] = []

    let arSession: ARKitSession
    let worldTracking: WorldTrackingProvider
    var handTracking: HandTrackingProvider?

    // === PLANTED SPATIAL RADIAL MENU ===
    // Navigation is the same canonical hierarchy consumed by the Mac host.
    // Only the renderer and direct-hand reducer are visionOS-specific.
    let spatialRadialHierarchy: NavigationHierarchy
    var spatialRadialInteraction = SpatialRadialInteractionState()
    var latestSpatialHandPose: HandPoseSnapshot?
    var pendingSpatialActivationPose: HandPoseSnapshot?
    var pendingSpatialActivationHand: SpatialRadialHand?
    var spatialHandTrackingIsRunning = false
    var lastSpatialHandTrackingLossTime: TimeInterval = -.infinity
    var spatialRadialPresentationGeneration: UInt64 = 0
    var latestDevicePosition = SIMD3<Float>.zero
    var hasValidDevicePose = false
    var spatialRadialPipeline: MTLRenderPipelineState?
    var spatialRadialDepthState: MTLDepthStencilState?
    var spatialRadialInstanceBuffer: MTLBuffer?
    var spatialRadialLabelAtlas: SpatialRadialLabelAtlas?

    // === ENVIRONMENT UNDERSTANDING ===
    // Room tracking supplies a current-room mesh whose oriented rectangular fit
    // drives Bound to Space. Scene reconstruction remains the denser source for
    // Environment Scrunch and provides a lower-confidence bounds fallback until
    // Room Tracking identifies the current room.
    var roomTracking: RoomTrackingProvider?
    // The scanned surroundings as world-space triangle soup per mesh anchor.
    // The anchorUpdates stream task writes the cache and flags it dirty; a
    // throttled bake task periodically folds all anchors into a fresh
    // EnvironmentSDFGrid and publishes it. updateGameState reads the published
    // grid each frame, so Mutexes bridge the contexts.
    var sceneReconstruction: SceneReconstructionProvider?
    let environmentMeshes = Mutex<[UUID: [SIMD3<Float>]]>([:])  // world tri soup (v0,v1,v2 triples)
    let environmentMeshesDirty = Mutex<Bool>(false)
    let environmentSDF = Mutex<EnvironmentSDFGrid?>(nil)
    struct TrackedRoomBoundsState: Sendable {
        var anchorID: UUID
        var bounds: EnvironmentRoomBounds
    }
    let trackedRoomBounds = Mutex<TrackedRoomBoundsState?>(nil)
    let meshRoomBounds = Mutex<EnvironmentRoomBounds?>(nil)
    nonisolated(unsafe) var roomUpdatesTask: Task<Void, Never>?
    nonisolated(unsafe) var meshUpdatesTask: Task<Void, Never>?
    nonisolated(unsafe) var envBakeTask: Task<Void, Never>?
    let layerRenderer: LayerRenderer
    let appModel: AppModel

    init?(
        _ layerRenderer: LayerRenderer,
        appModel: AppModel,
        spatialRadialHierarchy: NavigationHierarchy
    ) {
        self.layerRenderer = layerRenderer
        self.device = layerRenderer.device
        guard let queue = self.device.makeCommandQueue() else {
            if RENDERER_DEBUG { print("❌ Failed to create command queue") }
            return nil
        }
        self.commandQueue = queue
        self.appModel = appModel
        self.spatialRadialHierarchy = spatialRadialHierarchy
        
        // Initialize UI update coordinator to prevent UI blocking during heavy rendering
        self.uiUpdateCoordinator = UIUpdateCoordinator(appModel: appModel)

        // Initialize parameter update coordinator to batch smoothing/animation updates
        self.parameterUpdateCoordinator = ParameterUpdateCoordinator(appModel: appModel)

        // Pre-compute constant rotation matrix (never changes)
        self.cachedRotationMatrix = matrix4x4_rotation(radians: -.pi/2, axis: [0, 1, 0])

        let device = self.device

        // Cross-launch pipeline-binary caches. Built before the startup batches
        // below so those first PSOs are captured + reused next launch. Separate
        // files for the compute (raymarch) and render (raster) paths.
        self.pipelineArchive = PipelineBinaryArchive(device: device, purpose: "compute")
        self.renderPipelineArchive = PipelineBinaryArchive(device: device, purpose: "render")

        let uniformBufferSize = alignedUniformsSize * maxBuffersInFlight

        guard let uniformBuffer = self.device.makeBuffer(length: uniformBufferSize,
                                                          options: [MTLResourceOptions.storageModeShared]) else {
            if RENDERER_DEBUG { print("❌ Failed to create uniform buffer") }
            return nil
        }
        self.dynamicUniformBuffer = uniformBuffer

        self.dynamicUniformBuffer.label = "UniformBuffer"

        self.benchCounterBuffers = (0..<maxBuffersInFlight).compactMap { slot in
            let b = device.makeBuffer(length: MemoryLayout<UInt32>.stride * 2,
                                      options: [MTLResourceOptions.storageModeShared])
            b?.label = "BenchCounters[\(slot)]"
            return b
        }

        uniforms = UnsafeMutableRawPointer(dynamicUniformBuffer.contents()).bindMemory(to:UniformsArray.self, capacity:1)

        let mtlVertexDescriptor = Renderer.buildMetalVertexDescriptor()
        self.mtlVertexDescriptor = mtlVertexDescriptor

        do {
            pipelineState = try Renderer.buildRenderPipelineWithDevice(device: device,
                                                                       layerRenderer: layerRenderer,
                                                                       rasterSampleCount: rasterSampleCount,
                                                                       mtlVertexDescriptor: mtlVertexDescriptor,
                                                                       archive: self.renderPipelineArchive)
        } catch {
            if RENDERER_DEBUG { print("❌ Unable to compile render pipeline state: \(error)") }
            return nil
        }

        #if canImport(MetalFX)
        do {
            let postProcessVertexDescriptor = MTLVertexDescriptor()
            metalFXColorResolvePipeline = try Renderer.buildRenderPipelineWithDevice(
                device: device,
                layerRenderer: layerRenderer,
                rasterSampleCount: rasterSampleCount,
                mtlVertexDescriptor: postProcessVertexDescriptor,
                depthFormat: .invalid,
                vertexFunctionName: "formatConversionVertexStereo",
                fragmentFunctionName: "formatConversionFragmentStereo",
                archive: self.renderPipelineArchive
            )
            metalFXDepthResolvePipeline = try Renderer.buildRenderPipelineWithDevice(
                device: device,
                layerRenderer: layerRenderer,
                rasterSampleCount: rasterSampleCount,
                mtlVertexDescriptor: postProcessVertexDescriptor,
                colorFormat: .invalid,
                vertexFunctionName: "formatConversionVertexStereo",
                fragmentFunctionName: "depthUpscaleFragmentStereo",
                archive: self.renderPipelineArchive
            )
            // Phase 2.7: Merged single-encoder resolve. Optional — if it fails to
            // build (e.g. driver mismatch) we fall back to the two-encoder path.
            metalFXMergedResolvePipeline = try? Renderer.buildRenderPipelineWithDevice(
                device: device,
                layerRenderer: layerRenderer,
                rasterSampleCount: rasterSampleCount,
                mtlVertexDescriptor: postProcessVertexDescriptor,
                vertexFunctionName: "formatConversionVertexStereo",
                fragmentFunctionName: "formatConversionFragmentStereoMerged",
                archive: self.renderPipelineArchive
            )
            if RENDERER_DEBUG { print("✓ MetalFX resolve pipelines ready (color=bgra8Unorm_srgb/depth=invalid, depth=invalid/depth=depth32Float, merged=\(metalFXMergedResolvePipeline != nil ? "ok" : "unavailable"))") }
        } catch {
            if RENDERER_DEBUG { print("⚠️ MetalFX resolve pipeline failed: \(error)") }
            metalFXColorResolvePipeline = nil
            metalFXDepthResolvePipeline = nil
            metalFXMergedResolvePipeline = nil
        }

        // Phase 1.2: Create the MetalFX fragment→scaler fence eagerly so the
        // first MetalFX-active frame doesn't depend on lazy init order. The
        // fence cost is negligible and reuse is safe across frames.
        metalFXFence = device.makeFence()
        metalFXFence?.label = "MetalFX Fragment→Scaler"

        #endif

        // 1×1 placeholder for the warm-start prev-depth argument on frames where
        // MetalFX is inactive (never sampled: warmStartEnabled stays 0).
        let dummyDepthDesc = MTLTextureDescriptor()
        dummyDepthDesc.textureType = .type2DArray
        dummyDepthDesc.pixelFormat = .depth32Float
        dummyDepthDesc.width = 1
        dummyDepthDesc.height = 1
        dummyDepthDesc.arrayLength = 2
        dummyDepthDesc.storageMode = .private
        dummyDepthDesc.usage = [.shaderRead, .renderTarget]
        warmStartDummyDepthTexture = device.makeTexture(descriptor: dummyDepthDesc)
        warmStartDummyDepthTexture?.label = "WarmStart Dummy Depth"

        // Quality-preset specializations are optional accelerators. Building
        // all of them here can spend seconds in the driver before the compositor
        // receives a first frame; the selectors build requested exact configs
        // lazily off-actor while these generic pipelines render immediately.

        let depthStateDescriptor = MTLDepthStencilDescriptor()
        depthStateDescriptor.depthCompareFunction = MTLCompareFunction.less
        depthStateDescriptor.isDepthWriteEnabled = true
        guard let depthState = device.makeDepthStencilState(descriptor: depthStateDescriptor) else {
            if RENDERER_DEBUG { print("❌ Failed to create depth stencil state") }
            return nil
        }
        self.depthState = depthState

        do {
            mesh = try Renderer.buildMesh(device: device, mtlVertexDescriptor: mtlVertexDescriptor)
        } catch {
            if RENDERER_DEBUG { print("❌ Unable to build MetalKit Mesh: \(error)") }
            return nil
        }

        // Pre-compute mesh vertex layout bindings (avoids per-frame enumeration + type-cast)
        for (index, element) in mesh.vertexDescriptor.layouts.enumerated() {
            guard let layout = element as? MDLVertexBufferLayout, layout.stride != 0 else { continue }
            let buf = mesh.vertexBuffers[index]
            cachedMeshBindings.append(CachedMeshBinding(bufferIndex: index, buffer: buf.buffer, offset: buf.offset))
        }

        // Build tile-based compute pipelines with function constants for maximum optimization
        do {
            guard let library = Renderer.bundledDefaultLibrary(device: device) else {
                if RENDERER_DEBUG { print("⚠️ Failed to load default Metal library; compute path disabled") }
                adaptiveHierarchicalPipeline8x8 = nil
                throw RendererError.metalLibraryUnavailable
            }
            
            // Build a GENERIC fallback pipeline (no function constants baked in).
            // The shader reads iterations/steps from uniforms at runtime, so this
            // always matches precomputed absScalePow. Used only when exact-match
            // lookup and on-demand build both fail.
            // NOTE: Must use makeFunction(name:constantValues:) with EMPTY constants
            // because the kernel declares function constants — Metal refuses plain
            // makeFunction(name:). Empty MTLFunctionConstantValues leaves all FCs
            // undefined, so is_function_constant_defined() returns false in the shader.
            let emptyConstants = MTLFunctionConstantValues()
            if let kernel8x8 = try? library.makeFunction(name: "adaptiveHierarchical8x8", constantValues: emptyConstants) {
                let genericDesc = MTLComputePipelineDescriptor()
                genericDesc.computeFunction = kernel8x8
                genericDesc.label = "Compute_adaptiveHierarchical8x8_generic"
                if let archive = self.pipelineArchive {
                    adaptiveHierarchicalPipeline8x8 = try archive.makeComputePipeline(device: device,
                                                                                     descriptor: genericDesc)
                } else {
                    adaptiveHierarchicalPipeline8x8 = try device.makeComputePipelineState(descriptor: genericDesc,
                                                                                          options: [],
                                                                                          reflection: nil)
                }
            }
            if RENDERER_DEBUG { print("✓ Built generic compute fallback; preset specializations deferred until after first frame") }

            // Conservative cone coarse-prepass kernel. A single generic pipeline
            // (empty constants — reads iterations/type from TileUniforms at
            // runtime) is sufficient for Increment 1; it's only ever dispatched
            // when the opt-in toggle is on AND the fractal is box/fold + un-warped.
            if let coneKernel = try? library.makeFunction(name: "coneCoarsePrepass8x8", constantValues: emptyConstants) {
                let coneDesc = MTLComputePipelineDescriptor()
                coneDesc.computeFunction = coneKernel
                coneDesc.label = "Compute_coneCoarsePrepass8x8_generic"
                if let archive = self.pipelineArchive {
                    coneCoarsePrepassPipeline = try? archive.makeComputePipeline(device: device, descriptor: coneDesc)
                } else {
                    coneCoarsePrepassPipeline = try? device.makeComputePipelineState(descriptor: coneDesc, options: [], reflection: nil)
                }
                if RENDERER_DEBUG { print("✓ Cone coarse-prepass pipeline ready: \(coneCoarsePrepassPipeline != nil)") }
            }

            if let edgeKernel = try? library.makeFunction(name: "edgeDetectSlidingWindow", constantValues: emptyConstants) {
                let edgeDesc = MTLComputePipelineDescriptor()
                edgeDesc.computeFunction = edgeKernel
                edgeDesc.label = "Compute_edgeDetectSlidingWindow"
                if let archive = self.pipelineArchive {
                    edgeDetectionPipeline = try? archive.makeComputePipeline(device: device, descriptor: edgeDesc)
                } else {
                    edgeDetectionPipeline = try? device.makeComputePipelineState(descriptor: edgeDesc, options: [], reflection: nil)
                }
                if RENDERER_DEBUG { print("✓ Sliding-window edge detector pipeline ready: \(edgeDetectionPipeline != nil)") }
            }

            // Uniform buffer for tile compute (one per eye, per in-flight
            // frame). Reusing a single two-eye block lets the CPU overwrite
            // bindless grid addresses while an older GPU frame still reads it.
            let tileUniformSize = MemoryLayout<TileUniforms>.stride * 2 * maxBuffersInFlight
            tileUniformBuffer = device.makeBuffer(length: tileUniformSize, options: .storageModeShared)
            tileUniformBuffer?.label = "TileUniforms"
            
            if RENDERER_DEBUG { print("✓ Tile-based compute pipeline ready (adaptive 8x8)") }
        } catch {
            if RENDERER_DEBUG { print("⚠️ Failed to create tile compute pipelines: \(error)") }
            adaptiveHierarchicalPipeline8x8 = nil
        }
        
        worldTracking = WorldTrackingProvider()
        handTracking = HandTrackingProvider()
        roomTracking = RoomTrackingProvider.isSupported
            ? RoomTrackingProvider()
            : nil
        sceneReconstruction = SceneReconstructionProvider.isSupported
            ? SceneReconstructionProvider()
            : nil
        arSession = ARKitSession()
        
        // Nonessential setup is deliberately started only after the first frame
        // has been committed. Scheduling it here can let this task win the actor
        // executor immediately after init and delay the compositor's first frame.
    }

    /// Starts nonessential renderer warm-up after CompositorServices has received
    /// its first submitted frame. This is actor-isolated and idempotent because
    /// every render path (including the GPU-stall fallback) reports submission.
    private func startPostFirstFrameSetupIfNeeded() {
        guard setupTask == nil else { return }

        setupTask = Task { [weak self] in
            guard let self else { return }

            // Setup screenshot capture pipeline
            await self.setupScreenshotCapture()
            guard !Task.isCancelled else { return }

            // === RESIDENCY SET ===
            // Pre-validate resource residency for reduced per-frame overhead
            await self.setupResidencySet()
            guard !Task.isCancelled else { return }

            // Preset variants are built lazily by the preparation handler. A
            // full saved-preset sweep here still runs synchronously on this
            // actor after the first frame and can starve subsequent compositor
            // frames long enough for a Release launch to be terminated.

            // Persist any pipeline binaries compiled during startup (compute +
            // render) so the next cold launch can reuse them. Off-actor and low
            // priority so serialization never blocks a frame.
            let computeArchive = self.pipelineArchive
            let renderArchive = self.renderPipelineArchive
            Task.detached(priority: .background) {
                computeArchive?.serializeIfDirty()
                renderArchive?.serializeIfDirty()
            }

            await MainActor.run {
                self.appModel.rendererStartupWarmupComplete = true
            }
        }
    }

    deinit {
        setupTask?.cancel()
        archiveSerializeTask?.cancel()
        handTrackingDispatchTask?.cancel()
        roomUpdatesTask?.cancel()
        meshUpdatesTask?.cancel()
        envBakeTask?.cancel()
        for task in backgroundRenderPipelineBuildTasks.values {
            task.cancel()
        }
        for task in backgroundComputePipelineBuildTasks.values {
            task.cancel()
        }
        backgroundRenderPipelineBuildTasks.removeAll(keepingCapacity: false)
        backgroundComputePipelineBuildTasks.removeAll(keepingCapacity: false)
    }
    
    @MainActor
    static func startRenderLoop(_ layerRenderer: LayerRenderer, appModel: AppModel) {
        let renderLoopID = appModel.beginRenderLoopRegistration()
        let spatialRadialHierarchy = NavigationHierarchy.application(
            availability: .resolve(
                profile: appModel.platformProfile,
                allowsCustomScenes: AppModel.allowCustomScenes,
                includesGestureEditing: true
            )
        )
        let renderLoopTask = Task(
            executorPreference: RendererTaskExecutor.shared
        ) { [appModel, layerRenderer, spatialRadialHierarchy] in
            guard let renderer = Renderer(
                layerRenderer,
                appModel: appModel,
                spatialRadialHierarchy: spatialRadialHierarchy
            ) else {
                await MainActor.run {
                    guard appModel.activeRenderLoopID == renderLoopID else {
                        return
                    }
                    appModel.immersiveSpaceState = .closed
                    appModel.clearRendererHandlers(renderLoopID: renderLoopID)
                }
                return
            }
            
            // Renderer construction performs synchronous driver work. A newer
            // compositor registration may replace this one while that happens,
            // so stale tasks must not overwrite the new renderer's handlers.
            let installedHandlers = await MainActor.run { () -> Bool in
                guard appModel.activeRenderLoopID == renderLoopID,
                      !Task.isCancelled else {
                    return false
                }

                // Setup screenshot capture handler
                appModel.captureScreenshotHandler = {
                    await renderer.captureScreenshot()
                }
                
                // Setup pipeline preparation handler. Queue specialization
                // off-actor so an on-demand Metal compile can never starve the
                // serial executor that also submits compositor frames.
                appModel.preparePipelineHandler = { preset in
                    _ = await renderer.getPipeline(forPreset: preset)
                    await renderer.prewarmComputePipeline(forPreset: preset)
                }
                
                // Setup pipeline preparation for specific iteration/ray step values
                // Called when sliders change to pre-compile the needed pipeline
                appModel.preparePipelineForValuesHandler = { iterations, raySteps in
                    // Build the render PSO detached, awaiting it without holding
                    // the renderer actor's serial executor.
                    _ = await renderer.getPipeline(
                        forIterations: iterations,
                        raySteps: raySteps
                    )
                    // Pre-build matching compute pipeline so tileSize=8 path is ready
                    _ = await renderer.selectComputePipeline(fractalIterations: iterations, maxRaySteps: raySteps)
                }
                
                // Setup pipeline profiler handler
                appModel.triggerProfilerHandler = {
                    renderer.triggerProfiler()
                }

                // Setup force-recompile handler (debug "Force Recompile" button).
                appModel.forceShaderRecompileHandler = {
                    await renderer.forceRecompileShaders()
                }

                // Setup custom-shader (.threshfx) activation handler. Also carries
                // the composable transform-stack codegen (read from RenderSettings)
                // so a built-in fractal + stack compiles a specialized library.
                appModel.activateEmbeddedFormulaHandler = { [renderSettings = appModel.renderSettings] formula in
                    try await renderer.activateEmbeddedFormula(
                        formula,
                        warpStackSource: renderSettings.warpStackCodegenSource,
                        warpStackSignature: renderSettings.warpStackCodegenSignature)
                }

                // The spatial menu renders inside this compositor layer. Its
                // presentation closure captures the latest tracked palm once;
                // later samples move only the cursor through the planted frame.
                appModel.presentSpatialMenuHandler = {
                    [weak appModel = appModel, weak renderer] nodeID in
                    guard let appModel, let renderer else { return }
                    let generation = appModel.beginSpatialMenuPresentationRequest()
                    appModel.setSpatialMenuVisible(true)
                    guard appModel.isSpatialMenuVisible else {
                        Task { [weak renderer] in
                            await renderer?.dismissSpatialRadialMenu(
                                generation: generation
                            )
                        }
                        return
                    }

                    Task { [weak appModel, weak renderer] in
                        guard let renderer else { return }
                        let result = await renderer.presentSpatialRadialMenu(
                            focusing: nodeID,
                            generation: generation
                        )
                        guard result == .unavailable else { return }
                        await MainActor.run {
                            guard let appModel,
                                  appModel.isCurrentSpatialMenuPresentationRequest(generation)
                            else { return }
                            appModel.setSpatialMenuVisible(false)
                            appModel.revealMenuWindowForSpatialNavigation()
                        }
                    }
                }
                appModel.dismissSpatialMenuHandler = {
                    [weak appModel = appModel, weak renderer] in
                    guard let appModel else { return }
                    let generation = appModel.beginSpatialMenuPresentationRequest()
                    appModel.setSpatialMenuVisible(false)
                    Task { [weak renderer] in
                        await renderer?.dismissSpatialRadialMenu(
                            generation: generation
                        )
                    }
                }
                return true
            }
            guard installedHandlers, !Task.isCancelled else { return }

            // If an embedded formula was already registered (e.g. opening a
            // custom .threshscene/.threshfx from Finder, which opens the
            // immersive space with `activeEmbeddedFormula` already set), activate
            // it so the renderer compiles the custom MTLLibrary instead of
            // rendering fog/sky only.
            //
            // CRITICAL: this must NOT be awaited before `renderLoop()`. A fresh
            // custom-shader compile takes ~0.5-5s, and on visionOS the compositor
            // kills the app (no Swift trace) if the first frame doesn't arrive
            // shortly after the immersive space opens. Awaiting the compile here
            // delayed first-frame past that deadline — which is exactly why every
            // custom scene opened externally crashed EXCEPT the active/default one
            // (a `libraryCache` hit that returns instantly). Activate
            // concurrently instead: the render loop starts immediately and
            // submits frames (the frame path renders a safe fallback and
            // `scheduleCustomLibrarySelfHeal` swaps the custom DE in once the
            // library is ready). The compile itself is also off-thread now
            // (CustomShaderCompiler.library uses the async makeLibrary API).
            let pendingFormula = await MainActor.run { appModel.activeEmbeddedFormula }
            if let pending = pendingFormula, !pending.isBundledConstructionPrimitive {
                customSceneDiagnostic("🔬 [CSDiag] Handler ready — scheduling deferred activation for '\(pending.name)' hash=\(pending.shortHash) (concurrent; does NOT block first frame)")
                Task {
                    do {
                        try await renderer.activateEmbeddedFormula(pending)
                    } catch {
                        customSceneDiagnostic("🔬 [CSDiag] ❌ Deferred activation failed: \(error)")
                    }
                }
            }

            guard !Task.isCancelled else {
                await MainActor.run {
                    appModel.clearRendererHandlers(renderLoopID: renderLoopID)
                }
                return
            }
            
            // Authorization and ARKit provider startup can take long enough for
            // CompositorServices to kill a non-debug launch that has not produced
            // its first frame yet. Start them concurrently and render immediately;
            // renderFrame uses the documented nil device-anchor path (identity
            // pose, no late reprojection) until world tracking becomes available.
            let arSessionStartupTask = Task {
                await renderer.startARSession()
            }
            defer { arSessionStartupTask.cancel() }

            await renderer.renderLoop()

            await MainActor.run {
                appModel.clearRendererHandlers(renderLoopID: renderLoopID)
            }
        }

        appModel.setActiveRenderLoopTask(renderLoopTask, id: renderLoopID)
    }
    
    static func buildMetalVertexDescriptor() -> MTLVertexDescriptor {
        // Create a Metal vertex descriptor specifying how vertices will by laid out for input into our render
        //   pipeline and how we'll layout our Model IO vertices

        let mtlVertexDescriptor = MTLVertexDescriptor()

        mtlVertexDescriptor.attributes[VertexAttribute.position.rawValue].format = MTLVertexFormat.float3
        mtlVertexDescriptor.attributes[VertexAttribute.position.rawValue].offset = 0
        mtlVertexDescriptor.attributes[VertexAttribute.position.rawValue].bufferIndex = BufferIndex.meshPositions.rawValue

        mtlVertexDescriptor.attributes[VertexAttribute.texcoord.rawValue].format = MTLVertexFormat.float2
        mtlVertexDescriptor.attributes[VertexAttribute.texcoord.rawValue].offset = 0
        mtlVertexDescriptor.attributes[VertexAttribute.texcoord.rawValue].bufferIndex = BufferIndex.meshGenerics.rawValue

        mtlVertexDescriptor.layouts[BufferIndex.meshPositions.rawValue].stride = 12
        mtlVertexDescriptor.layouts[BufferIndex.meshPositions.rawValue].stepRate = 1
        mtlVertexDescriptor.layouts[BufferIndex.meshPositions.rawValue].stepFunction = MTLVertexStepFunction.perVertex

        mtlVertexDescriptor.layouts[BufferIndex.meshGenerics.rawValue].stride = 8
        mtlVertexDescriptor.layouts[BufferIndex.meshGenerics.rawValue].stepRate = 1
        mtlVertexDescriptor.layouts[BufferIndex.meshGenerics.rawValue].stepFunction = MTLVertexStepFunction.perVertex

        return mtlVertexDescriptor
    }

    // Pipeline cache telemetry (debug-only logging in selection paths)
    var renderPipelineCacheHits: Int = 0
    var renderPipelineCacheMisses: Int = 0
    var computePipelineCacheHits: Int = 0
    var computePipelineCacheMisses: Int = 0
    var lastPipelineTelemetryLogTime: TimeInterval = 0
    var lastPipelineMissHistogramLogTime: TimeInterval = 0
    var renderPipelineMissKeyCounts: [String: Int] = [:]
    var computePipelineMissKeyCounts: [String: Int] = [:]
    var renderPipelineSelectionCounts: [String: Int] = [:]
    var computePipelineSelectionCounts: [String: Int] = [:]
    
    // Track last logged pipeline to avoid spam
    var lastLoggedPipelineKey: String = ""
    
    // === PIPELINE SELECTION FAST-PATH CACHE ===
    // Avoids per-frame String interpolation + Dictionary lookup when parameters haven't changed.
    // selectPipeline() is called every frame; caching the last result short-circuits the common case.
    var lastSelectIter: Int = -1
    var lastSelectRS: Int = -1
    var lastSelectNeon: Bool = false
    var lastSelectColorIterations: Int32 = -1
    var lastSelectFT: Int32 = -1
    var lastSelectPower: Int32?
    var lastSelectCustomHash: String?
    var lastSelectBubble: Bool?
    var lastSelectSpaceWarp: Bool?
    var lastSelectEnvScrunch: Bool?
    var lastSelectHandField: Bool?
    var lastSelectedPipeline: MTLRenderPipelineState?
    var lastSelectedIsSpecialized: Bool = false
    
    static func buildMesh(device: MTLDevice,
                          mtlVertexDescriptor: MTLVertexDescriptor) throws -> MTKMesh {
        /// Create and condition mesh data to feed into a pipeline using the given vertex descriptor

        let metalAllocator = MTKMeshBufferAllocator(device: device)

        let mdlMesh = MDLMesh.newEllipsoid(withRadii: .init(repeating: 100),
                                           radialSegments: 64,
                                           verticalSegments: 32,
                                           geometryType: .triangles,
                                           inwardNormals: false,
                                           hemisphere: false,
                                           allocator: metalAllocator)

        let mdlVertexDescriptor = MTKModelIOVertexDescriptorFromMetal(mtlVertexDescriptor)

        guard let attributes = mdlVertexDescriptor.attributes as? [MDLVertexAttribute] else {
            throw RendererError.badVertexDescriptor
        }
        attributes[VertexAttribute.position.rawValue].name = MDLVertexAttributePosition
        attributes[VertexAttribute.texcoord.rawValue].name = MDLVertexAttributeTextureCoordinate

        mdlMesh.vertexDescriptor = mdlVertexDescriptor

        return try MTKMesh(mesh:mdlMesh, device:device)
    }

    func renderFrame() {
        /// Per frame updates hare

        var frameBreakdown = FramePhaseBreakdown()

        guard let frame = layerRenderer.queryNextFrame() else {
            // The async render loop yields before each iteration; return here
            // instead of blocking the Renderer actor when the compositor has no
            // frame ready yet.
            return
        }

        // Brackets the whole frame (every return path below) as one Instruments
        // signpost interval; see RenderSignposts.swift.
        let frameTraceState = RenderTrace.begin("Frame")
        defer { RenderTrace.end("Frame", frameTraceState) }

        frame.startUpdate()

        // Perform frame independent work

        frame.endUpdate()

        // Drive the compositor's runtime render quality before querying the
        // drawable, so the drawable is sized for the requested quality. This is the
        // visionOS-native (and foveation-aware) resolution control — see
        // applyRenderQualityIfNeeded. The user's Render Quality slider is the
        // ceiling; the adaptive governor lowers the applied value to hold FPS and
        // recovers toward the ceiling when there's headroom (no-op when disabled).
        // smoothedFPS is the prior frame's value here (updated later this frame),
        // which is exactly the signal we want for this frame's decision.
        let renderQualityCeiling = appModel.renderSettings.renderQuality
        let effectiveRenderQuality = adaptiveRenderQuality.update(
            smoothedFPS: smoothedFPS,
            ceiling: renderQualityCeiling,
            // A high/ultra-quality scene lifts the floor so the governor keeps it
            // sharp under load instead of downscaling it to the global minimum.
            sceneFloor: appModel.renderSettings.sceneRenderQualityFloor,
            now: CACurrentMediaTime(),
            enabled: appModel.renderSettings.adaptiveRenderQualityEnabled
        )
        applyRenderQualityIfNeeded(renderQuality: effectiveRenderQuality)

        guard let timing = frame.predictTiming() else {
            return
        }
        let clockWaitStart = CACurrentMediaTime()
        let clockWaitTraceState = RenderTrace.begin("Clock Wait")
        LayerRenderer.Clock().wait(until: timing.optimalInputTime)
        RenderTrace.end("Clock Wait", clockWaitTraceState)
        frameBreakdown.clockWaitMs = (CACurrentMediaTime() - clockWaitStart) * 1000.0

        let presentationTime = timing.presentationTime
        let time = LayerRenderer.Clock.Instant.epoch.duration(to: presentationTime).timeInterval
        let deviceAnchor = worldTracking.state == .running
            ? worldTracking.queryDeviceAnchor(atTimestamp: time)
            : nil
        if let deviceAnchor, deviceAnchor.isTracked {
            let transform = deviceAnchor.originFromAnchorTransform
            latestDevicePosition = SIMD3<Float>(
                transform.columns.3.x,
                transform.columns.3.y,
                transform.columns.3.z
            )
            hasValidDevicePose = true
        } else {
            hasValidDevicePose = false
        }
        if deviceAnchor == nil, !hasLoggedMissingDeviceAnchor {
            hasLoggedMissingDeviceAnchor = true
            print("⚠️ Device anchor unavailable; rendering with identity pose until world tracking is ready")
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            if RENDERER_DEBUG { print("⚠️ Failed to create command buffer; skipping frame") }
            return
        }
        // Traces this command buffer's commit→completion latency regardless of
        // which of the frame's several `commandBuffer.commit()` call sites ends
        // up firing.
        RenderTrace.traceGPU("GPU Frame", commandBuffer: commandBuffer)

        // Use residency set to ensure all resources stay GPU-resident during this frame
        if #available(visionOS 2.0, iOS 18.0, macOS 15.0, *) {
            if let set = residencySet {
                commandBuffer.useResidencySet(set)
            }
        }

        // Query drawable using the appropriate API for the OS version
        // visionOS 26+ uses queryDrawables() which supports renderQuality and fovea
        let drawable: LayerRenderer.Drawable
        if #available(visionOS 26.0, *) {
            let drawables = frame.queryDrawables()
            guard let selectedDrawable = selectDrawable(from: drawables) else {
                // CompositorServices documents a zero-count result as a cancelled,
                // invalid frame. Do not call start/endSubmission (or access the
                // frame in any other way) after this point.
                return
            }
            drawable = selectedDrawable
        } else {
            guard let legacyDrawable = frame.queryDrawable() else {
                // Nil means the layer is paused or invalidated. Discard the frame;
                // beginning a submission on it is a compositor client violation.
                return
            }
            drawable = legacyDrawable
        }

        // Publish the actual drawable resolution + quality to the control window
        // so the user can confirm native render resolution in-headset.
        publishRenderDiagnostics(drawable: drawable)

        // Wait for a buffer to become available. With maxBuffersInFlight=2, the
        // cheap CPU encode of frame N+1 overlaps the GPU render of N, so encode
        // time is hidden behind GPU work — a throughput win whenever we're
        // GPU-bound (the steady state on Vision Pro, where we run below 45 FPS
        // and never approach the compositor's vsync cadence). The cost is ~1
        // frame of extra latency, which CompositorServices hides by reprojecting
        // at present time from the device anchor. Going to 1 buffer would lower
        // latency but serialize encode with GPU work, reducing throughput — net
        // worse while GPU-bound. (Earlier comments framed this as "preventing a
        // 45 FPS vsync lock"; that's a misnomer — there is no 45 FPS lock to hit
        // when we're already below it.)
        // Timeout at 100ms (~10 FPS floor) to detect GPU stalls instead of hanging forever.
        let inFlightWaitStart = CACurrentMediaTime()
        let inFlightWaitTraceState = RenderTrace.begin("InFlight Wait")
        let waitResult = inFlightSemaphore.wait(timeout: .now() + .milliseconds(100))
        RenderTrace.end("InFlight Wait", inFlightWaitTraceState)
        frameBreakdown.inFlightWaitMs = (CACurrentMediaTime() - inFlightWaitStart) * 1000.0
        if waitResult == .timedOut {
            // GPU is severely behind — present an empty frame to satisfy CompositorServices,
            // then skip rendering to avoid accumulating latency.
            RenderTrace.event("GPU Stall", "inFlightSemaphore timed out (100ms)")
            if RENDERER_DEBUG { print("⚠️ GPU stall detected: inFlightSemaphore timed out (100ms)") }
            drawable.deviceAnchor = deviceAnchor
            frame.startSubmission()
            defer { frame.endSubmission() }
            if drawableRenderContextRequired {
                encodeDrawableRenderContextPass(commandBuffer: commandBuffer, drawable: drawable)
            }
            drawable.encodePresent(commandBuffer: commandBuffer)
            commandBuffer.commit()
            startPostFirstFrameSetupIfNeeded()
            return
        }

        var shouldSignalInFlightSemaphore = true
        defer {
            if shouldSignalInFlightSemaphore {
                inFlightSemaphore.signal()
            }
        }

        // CPU work timing excludes the explicit clock wait + in-flight wait.
        let cpuEncodeStart = CACurrentMediaTime()

        drawable.deviceAnchor = deviceAnchor

        // Calculate deltaTime (clamped only on the fast side for FPS tracking; pose smoothing removed)
        let rawDelta = lastPresentationTime.map { $0.duration(to: presentationTime).timeInterval } ?? (1.0 / 90.0)
        let deltaTime = max(1.0 / 240.0, rawDelta)  // Allow slow frames to surface instead of capping at 30 FPS
        cachedDeltaTime = Float(deltaTime)  // Cache for use in updateGameState and other methods

        // FPS tracking using frame-rate independent exponential decay (Freya Holmér technique)
        // factor = 1 - e^(-speed * dt), speed=10 gives ~63% convergence in 100ms
        let settings = appModel.renderSettings  // Capture settings early for use in Task closure
        if deltaTime > 0 {
            let instantFPS = 1.0 / deltaTime
            let fpsSmoothFactor = 1.0 - exp(-10.0 * deltaTime)  // speed=10 for responsive but smooth FPS display
            let updatedFPS = smoothedFPS + (instantFPS - smoothedFPS) * fpsSmoothFactor
            smoothedFPS = updatedFPS
            
            // === UI UPDATE COORDINATION ===
            // Use UIUpdateCoordinator to prevent UI blocking during heavy fractal rendering.
            uiUpdateCoordinator?.scheduleUIUpdate(fps: updatedFPS, currentTime: time)
            
            // Periodic FPS console logging (every 2 seconds)
            if RENDERER_DEBUG && time - lastFPSConsoleLogTime > 2.0 {
                lastFPSConsoleLogTime = time
                print("[FPS] \(String(format: "%.1f", updatedFPS)) fps | frame time: \(String(format: "%.2f", deltaTime * 1000))ms")
            }
            
        }
        lastPresentationTime = presentationTime

        let semaphore = inFlightSemaphore
        commandBuffer.addCompletedHandler { (_ commandBuffer)-> Swift.Void in
            semaphore.signal()
        }

        self.updateDynamicBufferState()
        // Update hand tracking and process gestures
        let handTrackingStart = CACurrentMediaTime()
        self.updateHandTracking(atTime: time)
        frameBreakdown.handTrackingMs = (CACurrentMediaTime() - handTrackingStart) * 1000.0

        // Update scene animation playback on MainActor
        // Batched with audio frame updates into a single MainActor dispatch to reduce overhead
        let animDelta = TimeInterval(cachedDeltaTime)
        
        let settingsUpdateStart = CACurrentMediaTime()
        settings.interpolateToTargets(deltaTime: cachedDeltaTime)
        settings.updateLimitFlash(deltaTime: cachedDeltaTime)
        settings.updateColorSchemeTransition(deltaTime: cachedDeltaTime,
                                             mixedImmersionActive: appModel.immersionStyleForRenderer == .mixed)
        frameBreakdown.settingsUpdateMs = (CACurrentMediaTime() - settingsUpdateStart) * 1000.0
        
        // === AUDIO PIPELINE ===
        // Renderers consume one coherent hub snapshot. Source discovery,
        // permission/lifecycle, fallback policy, and feature mixing all live
        // behind AudioHub rather than being reimplemented per render path.
        let backgroundCpuStart = CACurrentMediaTime()
        let isAudioMode = settings.lightingMode == .audioReactive || settings.lightingMode == .visualizer || settings.fractalAudioReactiveEnabled
        let audioSnapshot = appModel.audioHub.latestSnapshot()
        let shouldUpdateAnimation = settings.isAnimationPlaying
        
        // === PARAMETER UPDATE COORDINATION ===
        // Use ParameterUpdateCoordinator to batch animation/audio updates
        // Prevents per-frame MainActor blocking that causes UI lag during heavy rendering
        parameterUpdateCoordinator?.scheduleParameterUpdates(
            shouldUpdateAnimation: shouldUpdateAnimation,
            shouldUpdateAudio: isAudioMode,
            deltaTime: animDelta,
            currentTime: time
        )
        
        if isAudioMode {
            let hasEnabledFingerInputMapping = settings.musicReactiveMappings.contains {
                $0.isEnabled && $0.source.isFingerInput
            }

            // Sensitivity multipliers from user settings
            let bassSens = settings.bassSensitivity
            let midSens = settings.midSensitivity
            let trebleSens = settings.trebleSensitivity
            let beatSens = settings.beatSensitivity
            let features = audioSnapshot.mixed

            let useFingerInput = hasEnabledFingerInputMapping
            let processMusicReactive = settings.fractalAudioReactiveEnabled
                && (audioSnapshot.isActive || useFingerInput)

            // An inactive snapshot is `.empty` with all-zero features (the
            // mixer never pairs isActive == false with live values), so the
            // scaled levels are already zero without an explicit gate.
            let bassLevel = min(1.0, max(0.0, features.bass * bassSens))
            let midLevel = min(1.0, max(0.0, features.mid * midSens))
            let trebleLevel = min(1.0, max(0.0, features.treble * trebleSens))
            let beatLevel = min(1.0, max(0.0, features.onset * beatSens))
            let overallLevel = min(1.0, max(0.0, features.overall))
            settings.bassLevel = bassLevel
            settings.midLevel = midLevel
            settings.trebleLevel = trebleLevel
            settings.beatIntensity = beatLevel
            settings.audioLevel = overallLevel

            let sanitizePinch: (Float) -> Float = {
                min(1.0, max(0.0, $0))
            }
            let leftHandPinch = latestSpatialHandPose?.leftHand
            let rightHandPinch = latestSpatialHandPose?.rightHand

            // Music drives fractal geometry AND effects (Fractal Forge-inspired).
            // The aggregation above produced the per-band levels; the shared engine
            // applies damping, response curves, the LFO overlay, and dispatch.
            if processMusicReactive {
                let bandLevels = BandLevels(
                    bass: bassLevel,
                    mid: midLevel,
                    treble: trebleLevel,
                    beat: beatLevel,
                    overall: overallLevel,
                    leftIndexPinch: sanitizePinch(leftHandPinch?.indexPinch ?? 0),
                    leftMiddlePinch: sanitizePinch(leftHandPinch?.middlePinch ?? 0),
                    leftRingPinch: sanitizePinch(leftHandPinch?.ringPinch ?? 0),
                    rightIndexPinch: sanitizePinch(rightHandPinch?.indexPinch ?? 0),
                    rightMiddlePinch: sanitizePinch(rightHandPinch?.middlePinch ?? 0),
                    rightRingPinch: sanitizePinch(rightHandPinch?.ringPinch ?? 0)
                )
                musicReactiveEngine.process(bandLevels: bandLevels,
                                            settings: settings,
                                            deltaTime: cachedDeltaTime,
                                            pipeline: appModel.parameterPipeline)
            } else {
                musicReactiveEngine.reset(settings: settings, pipeline: appModel.parameterPipeline)
            }
        } else {
            musicReactiveEngine.reset(settings: settings, pipeline: appModel.parameterPipeline)
        }
        frameBreakdown.backgroundCpuMs = (CACurrentMediaTime() - backgroundCpuStart) * 1000.0

        let snapshotStart = CACurrentMediaTime()
        let settingsSnapshot = settings.snapshot()
        frameBreakdown.snapshotMs = (CACurrentMediaTime() - snapshotStart) * 1000.0
        
        let updateGameStateStart = CACurrentMediaTime()
        let updateGameStateTraceState = RenderTrace.begin("Update Game State")
        let framePreparation = self.updateGameState(drawable: drawable, settingsSnapshot: settingsSnapshot)
        lastSubmittedEnvironmentGrid = framePreparation.environmentGrid
        // `EnvScrunchParams.gridAddress` is a bindless pointer, so Metal cannot
        // infer its owner from an ordinary buffer binding. Hold the frame's exact
        // grid snapshot until GPU completion in addition to declaring it on each
        // encoder below. This is intentionally the same object used to build the
        // address in updateGameState.
        if let environmentGrid = framePreparation.environmentGrid {
            commandBuffer.addCompletedHandler { _ in
                withExtendedLifetime(environmentGrid) {}
            }
        }
        RenderTrace.end("Update Game State", updateGameStateTraceState)
        frameBreakdown.updateGameStateMs = (CACurrentMediaTime() - updateGameStateStart) * 1000.0

        // Begin submission only once CPU updates are complete.
        // Every path from here MUST call drawable.encodePresent() before endSubmission() fires.
        frame.startSubmission()
        defer { frame.endSubmission() }

        let renderEncodeStart = CACurrentMediaTime()
        let renderEncodeTraceState = RenderTrace.begin("Render Encode")
        defer { RenderTrace.end("Render Encode", renderEncodeTraceState) }

        // Once the layer is configured with a render-context stencil format
        // (visionOS 26+), the compositor REQUIRES the drawable render-context
        // pass before EVERY present, in every immersion style — presenting
        // without it aborts with "need to use drawable render context when
        // supporting progressive style". So the pass runs per-frame whenever
        // configured (see the encodeDrawableRenderContextPass calls before
        // each encodePresent below). The transparent background additionally
        // needs fragmentMain's miss-alpha, which the compute path doesn't
        // have — force the fragment path while it's active.
        let renderContextRequired = drawableRenderContextRequired
        var framePath = selectFramePath(settingsSnapshot: settingsSnapshot)
        if passthroughBackgroundActive { framePath = .fragment }

        // The two offscreen paths each own several full-resolution stereo
        // textures. Keep only the active family's resources alive; retaining both
        // across a path switch creates a large transient working-set spike just as
        // the compositor is also resizing its drawable pool.
        switch framePath {
        case .adaptiveCompute:
            #if canImport(MetalFX)
            metalFXManager = nil
            #endif
            warmStartGate.invalidate()
        case .fragment:
            releaseAdaptiveComputeAuxiliaryTextures()
        }
        let useAdaptiveCompute: Bool

        if case .adaptiveCompute = framePath {
            useAdaptiveCompute = true
            // Use compute-based rendering for 8x8 adaptive hierarchical
            let computeRendered = renderWithAdaptiveCompute(
                commandBuffer: commandBuffer,
                drawable: drawable,
                settingsSnapshot: settingsSnapshot,
                framePreparation: framePreparation
            )
            
            if computeRendered {
                // Adaptive-compute frames don't write fragment depth — next
                // fragment frame must not warm-start from stale history.
                warmStartGate.invalidate()
                encodeSpatialRadialMenuPass(
                    commandBuffer: commandBuffer,
                    drawable: drawable,
                    preserveSceneDepth: false
                )
                if renderContextRequired {
                    encodeDrawableRenderContextPass(commandBuffer: commandBuffer, drawable: drawable)
                }
                drawable.encodePresent(commandBuffer: commandBuffer)
                observeAdaptiveComputeCompletion(commandBuffer)
                shouldSignalInFlightSemaphore = false
                commandBuffer.commit()
                startPostFirstFrameSetupIfNeeded()
                return  // Skip fragment-based rendering
            }
        } else {
            useAdaptiveCompute = false
        }

        // Reaching the fragment path means compute depth was not written this
        // frame. Do not reuse it after a path switch: its depth and the stored
        // previous-view-projection matrix would describe different frames.
        computeWarmStartGate.invalidate()

        // ═══════════════════════════════════════════════════════════════════════
        // FRAGMENT RENDER PATH (with optional MetalFX spatial upscale)
        //
        // When resolutionScale < 1.0 AND MetalFX is available, render the fragment
        // pass into MetalFX's private low-res input texture, then spatially
        // upscale into the drawable. MetalFX on visionOS supports spatial
        // upscaling only (temporal is unsupported), so this is the only MetalFX
        // codepath we need. The adaptive-compute path intentionally skips MetalFX
        // — it has its own quality controls (compute tile cascade).
        // ═══════════════════════════════════════════════════════════════════════
        let fragmentPassPlan = prepareFragmentPassPlan(
            drawable: drawable,
            settingsSnapshot: settingsSnapshot,
            framePath: framePath
        )

        // === TEMPORAL DEPTH WARM-START: patch per-frame uniforms ===
        // The MetalFX input size is only known once the pass plan exists, so the
        // warm-start fields are patched here (same pattern as the TAA jitter).
        #if canImport(MetalFX)
        if let bundle = fragmentPassPlan.metalFXBundle {
            let res = SIMD2<Float>(Float(bundle.inputWidth), Float(bundle.inputHeight))
            // WarmStartGate compares the snapshot against the geometry key
            // recorded when the depth history was written: discrete changes
            // (fractal type, iterations, inversion) are hard cuts, continuous
            // params get a small per-frame tolerance — the 0.9×/−0.3 start
            // margin and full-march fallback absorb bounded one-frame morphs,
            // so gestures and music reactivity keep the warm start alive.
            let warmStartOK: Int32 = (bundle.manager.depthHistoryValid
                && warmStartGate.allowsWarmStart(for: settingsSnapshot)) ? 1 : 0
            // `uniforms` is already rebound to the current ring slot by
            // updateDynamicBufferState(). Indexing it by uniformBufferIndex a
            // second time walks beyond that slot (and, in later slots, beyond
            // the allocation), which is especially prone to crash in Release.
            uniforms[0].uniforms.0.renderResolution = res
            uniforms[0].uniforms.1.renderResolution = res
            uniforms[0].uniforms.0.warmStartEnabled = warmStartOK
            uniforms[0].uniforms.1.warmStartEnabled = warmStartOK
        }
        #endif

        // ═══════════════════════════════════════════════════════════════════════
        // CONSERVATIVE CONE COARSE-PREPASS WARM-START (opt-in, default OFF)
        // ═══════════════════════════════════════════════════════════════════════
        // Gate: feature toggle ON, fractal is box/fold family, and the domain is
        // UN-WARPED. Only then is the analytic lower-bound cone trusted. When false,
        // the cone pass is never dispatched, a 1×1 dummy keeps the fragment texture
        // slot bound, and the fragment pipeline keeps FC_COARSE_WARM_START undefined
        // → the consumer code is dead-code-eliminated (byte-identical to before).
        let coneAllowed = settingsSnapshot.coarsePrepassWarmStartEnabled
            && isBoxFoldFamily(settingsSnapshot.fractalType)
            && settingsSnapshot.sphericalInversionMode.rawValue == 0
            && !(settingsSnapshot.sphereProjectionEnabled && settingsSnapshot.sphereProjectionBlend > 0)
            && settingsSnapshot.spaceWarpStrength <= 0
            // Environment Scrunch can add a hug shell to the base DE, so the
            // analytic box/fold lower bound no longer proves that space is empty.
            && !settingsSnapshot.envScrunchEnabled
            // Stack warp ops (twist/ripple/kaleido, repeat-group recurrence) void
            // the Lipschitz-1 lower-bound proof the same way. The kernel guards
            // this independently and writes cold sentinels; checking the packed
            // stack here just skips dispatching that guaranteed no-op pass.
            && settingsSnapshot.spaceWarpStack.count == 0

        // Render-target dimensions the fragment pass writes into (MetalFX input, or
        // the drawable color texture for the direct path).
        var fragmentRenderWidth = drawable.colorTextures[0].width
        var fragmentRenderHeight = drawable.colorTextures[0].height
        #if canImport(MetalFX)
        if let bundle = fragmentPassPlan.metalFXBundle {
            fragmentRenderWidth = bundle.inputWidth
            fragmentRenderHeight = bundle.inputHeight
        }
        #endif

        var coneCoarseTexture: MTLTexture? = nil
        if coneAllowed {
            coneCoarseTexture = ensureCoarseStartTexture(
                renderWidth: fragmentRenderWidth,
                renderHeight: fragmentRenderHeight,
                viewCount: drawable.views.count
            )
            if let coarseTex = coneCoarseTexture {
                encodeConeCoarsePrepass(
                    commandBuffer: commandBuffer,
                    coarseTex: coarseTex,
                    drawable: drawable,
                    settingsSnapshot: settingsSnapshot,
                    framePreparation: framePreparation,
                    renderWidth: fragmentRenderWidth,
                    renderHeight: fragmentRenderHeight,
                    viewports: fragmentPassPlan.viewports
                )
            }
        }
        // When the cone pass didn't run (or texture alloc failed), fall back to the
        // dummy so the fragment slot is always populated.
        let coneActive = coneAllowed && coneCoarseTexture != nil

        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: fragmentPassPlan.renderPassDescriptor) else {
            if RENDERER_DEBUG { print("⚠️ Failed to create render encoder; skipping frame") }
            encodeSpatialRadialMenuPass(
                commandBuffer: commandBuffer,
                drawable: drawable,
                preserveSceneDepth: false
            )
            if renderContextRequired {
                encodeDrawableRenderContextPass(commandBuffer: commandBuffer, drawable: drawable)
            }
            drawable.encodePresent(commandBuffer: commandBuffer)
            shouldSignalInFlightSemaphore = false
            commandBuffer.commit()
            startPostFirstFrameSetupIfNeeded()
            return
        }
        // Environment Scrunch grid is reached bindlessly (GPU address in the
        // uniforms) — make it resident for the fragment march.
        if let envGrid = framePreparation.environmentGrid {
            renderEncoder.useResource(envGrid.buffer, usage: .read, stages: .fragment)
        }

        renderEncoder.label = "Primary Render Encoder"

        renderEncoder.pushDebugGroup("Draw Box")

        renderEncoder.setCullMode(.front)

        renderEncoder.setFrontFacing(.counterClockwise)

        // Get current iteration count for specialized pipeline selection
        let currentIterations = settingsSnapshot.fractalIterations
        let currentRaySteps = settingsSnapshot.maxRaySteps
        
        // Detect neon mode from colorSchemeParams.neonIntensity
        let isNeonMode = settingsSnapshot.colorSchemeParams.neonIntensity > 0
        
        // Use specialized pipeline with fixed iteration count
        // This enables Map() loop auto-unrolling via function constants
        let baseSelectedPipeline = selectPipeline(
            forIterations: currentIterations,
            raySteps: currentRaySteps,
            neonMode: isNeonMode,
            request: RenderPipelineRequest(
                fractalType: settingsSnapshot.fractalType,
                formulaParams: settingsSnapshot.formulaParams,
                colorIterations: settingsSnapshot.colorIterations
            )
        )
        // When the cone pass ran this frame, swap in a fragment pipeline variant
        // that bakes FC_COARSE_WARM_START=true (so the min-over-2x2 read + warm
        // start seed are compiled in). Falls back to the base pipeline if the
        // cone-enabled variant can't be built — the cone texture is still bound but
        // never sampled (FC undefined), so behavior is identical to off.
        var selectedPipeline = baseSelectedPipeline
        if coneActive {
            if let conePipeline = selectCoarseWarmStartPipeline(
                forIterations: currentIterations,
                raySteps: currentRaySteps,
                neonMode: isNeonMode,
                request: RenderPipelineRequest(
                    fractalType: settingsSnapshot.fractalType,
                    formulaParams: settingsSnapshot.formulaParams,
                    colorIterations: settingsSnapshot.colorIterations
                )
            ) {
                selectedPipeline = conePipeline
            }
        }
        renderEncoder.setRenderPipelineState(selectedPipeline)

        renderEncoder.setDepthStencilState(depthState)

        renderEncoder.setVertexBuffer(dynamicUniformBuffer, offset:uniformBufferOffset, index: BufferIndex.uniforms.rawValue)
        
        // Also bind uniforms buffer for fragment shader since it now needs access to uniforms
        renderEncoder.setFragmentBuffer(dynamicUniformBuffer, offset:uniformBufferOffset, index: BufferIndex.uniforms.rawValue)

        // Benchmark iteration counter (BufferIndexBenchCounters). Always bound —
        // the fragmentShader pipeline declares the buffer; it's only zeroed (and
        // later read) while a sweep is collecting. The selected buffer is read in
        // the completion handler once the GPU has finished writing this slot.
        // (Live dashboard step profiling is wired through the Mac path only; the
        // visionOS compute kernel isn't step-instrumented yet.)
        let benchCollecting = BenchmarkManager.shared.collectIterations
        let benchBuf: MTLBuffer? = benchCounterBuffers.isEmpty
            ? nil : benchCounterBuffers[uniformBufferIndex % benchCounterBuffers.count]
        if let benchBuf {
            if benchCollecting { memset(benchBuf.contents(), 0, MemoryLayout<UInt32>.stride * 2) }
            renderEncoder.setFragmentBuffer(benchBuf, offset: 0, index: BufferIndex.benchCounters.rawValue)
        }
        // Retain the Metal buffer through GPU completion. Avoid carrying a raw
        // pointer across the @Sendable completion callback; deriving it only after
        // completion also makes the resource lifetime explicit to Swift's checker.
        let completedBenchBuffer: MTLBuffer? = benchCollecting ? benchBuf : nil

        // Previous-frame depth for the temporal march warm-start. Pipelines built
        // via buildRenderPipelineWithDevice declare this argument (FC_WARM_START);
        // when MetalFX is inactive the dummy satisfies validation and is never
        // sampled (warmStartEnabled == 0).
        #if canImport(MetalFX)
        let warmStartDepth = fragmentPassPlan.metalFXBundle?.manager.previousDepthTexture ?? warmStartDummyDepthTexture
        #else
        let warmStartDepth = warmStartDummyDepthTexture
        #endif
        if let warmStartDepth {
            renderEncoder.setFragmentTexture(warmStartDepth, index: FragmentTextureIndex.prevDepth.rawValue)
        }

        // Conservative cone coarse-prepass warmT. When the cone-enabled pipeline is
        // active the fragment shader declares this argument (FC_COARSE_WARM_START)
        // and reads it; otherwise a 1×1 dummy keeps the slot populated and the
        // argument is compiled out, so it's never sampled (mirrors the warm-start
        // dummy depth pattern).
        let coarseBound: MTLTexture? = coneActive
            ? coneCoarseTexture
            : ensureCoarseStartDummyTexture(viewCount: drawable.views.count)
        if let coarseBound {
            renderEncoder.setFragmentTexture(coarseBound, index: FragmentTextureIndex.coarseWarmStart.rawValue)
        }

        let viewports = fragmentPassPlan.viewports
        renderEncoder.setViewports(viewports)
        applyVertexAmplificationIfNeeded(to: renderEncoder, viewCount: viewports.count)

        for binding in cachedMeshBindings {
            renderEncoder.setVertexBuffer(binding.buffer, offset: binding.offset, index: binding.bufferIndex)
        }

        for submesh in mesh.submeshes {
            renderEncoder.drawIndexedPrimitives(type: submesh.primitiveType,
                                                indexCount: submesh.indexCount,
                                                indexType: submesh.indexType,
                                                indexBuffer: submesh.indexBuffer.buffer,
                                                indexBufferOffset: submesh.indexBuffer.offset)
        }

        renderEncoder.popDebugGroup()

        // If MetalFX is active, signal the fence after the fragment stage so the
        // spatial scaler waits for our writes into the input/depth textures
        // before it reads them. Metal's automatic hazard tracking would handle
        // this for tracked private textures in the same command buffer, but the
        // explicit fence makes the dependency unambiguous across devices/OS
        // versions and matches how MTLFXSpatialScaler is documented to be used.
        #if canImport(MetalFX)
        if fragmentPassPlan.metalFXBundle != nil, let fence = metalFXFence {
            renderEncoder.updateFence(fence, after: .fragment)
        }
        #endif

        renderEncoder.endEncoding()

        finishFragmentPass(
            commandBuffer: commandBuffer,
            drawable: drawable,
            fragmentPassPlan: fragmentPassPlan,
            framePreparation: framePreparation,
            settingsSnapshot: settingsSnapshot
        )
        encodeSpatialRadialMenuPass(
            commandBuffer: commandBuffer,
            drawable: drawable,
            preserveSceneDepth: true
        )
        
        frameBreakdown.renderPathEncodeMs = (CACurrentMediaTime() - renderEncodeStart) * 1000.0

        let cpuEncodeMs = (CACurrentMediaTime() - cpuEncodeStart) * 1000.0
        let frameTimeSeconds = Double(cachedDeltaTime)
        let logTime = time
        let viewCount = drawable.views.count
        let drawableWidth = drawable.colorTextures[0].width
        let drawableHeight = drawable.colorTextures[0].height
        let frameBreakdownSnapshot = frameBreakdown
        commandBuffer.addCompletedHandler { [weak self, completedBenchBuffer] cb in
            let gpuMs: Double?
            if cb.gpuEndTime > cb.gpuStartTime {
                gpuMs = (cb.gpuEndTime - cb.gpuStartTime) * 1000.0
            } else {
                gpuMs = nil
            }
            // Average march iterations to converge over this frame's hit rays.
            var iterationsAvg: Double? = nil
            if let completedBenchBuffer {
                let p = completedBenchBuffer.contents().bindMemory(to: UInt32.self, capacity: 2)
                let hitCount = p[1]
                if hitCount > 0 { iterationsAvg = Double(p[0]) / Double(hitCount) }
            }
            guard let self else { return }
            Task {
                await self.recordFramePerf(
                    nowTime: logTime,
                    frameTimeSeconds: frameTimeSeconds,
                    cpuEncodeMs: cpuEncodeMs,
                    gpuMs: gpuMs,
                    iterationsAvg: iterationsAvg,
                    frameBreakdown: frameBreakdownSnapshot,
                    settingsSnapshot: settingsSnapshot,
                    useAdaptiveCompute: useAdaptiveCompute,
                    viewCount: viewCount,
                    drawableWidth: drawableWidth,
                    drawableHeight: drawableHeight
                )
            }
        }

        if renderContextRequired {
            encodeDrawableRenderContextPass(commandBuffer: commandBuffer, drawable: drawable)
        }

        drawable.encodePresent(commandBuffer: commandBuffer)

        shouldSignalInFlightSemaphore = false
        commandBuffer.commit()
        startPostFirstFrameSetupIfNeeded()
    }

    // MARK: - Adaptive 8x8 Hierarchical Compute Rendering
    
    /// Dispatches the adaptive 8x8 hierarchical compute kernel for high-performance raymarching
    /// This uses a 3-level cascade: super-coarse (1 thread) → coarse (4 threads) → fine (64 threads)
    /// Expected speedup: 3-8x compared to per-pixel raymarching
    private func encodeAdaptiveCompute(
        commandBuffer: MTLCommandBuffer,
        outputTexture: MTLTexture,
        drawable: LayerRenderer.Drawable,
        viewIndex: Int,
        settingsSnapshot: RenderSettingsSnapshot,
        framePreparation: RendererFramePreparation,
        pipeline: MTLComputePipelineState? = nil,
        prevDepthTexture: MTLTexture,
        curDepthTexture: MTLTexture,
        uniformBuffer: MTLBuffer,
        bufferContents: UnsafeMutableRawPointer
    ) -> SIMD2<Int>? {
        guard let pipeline = pipeline ?? adaptiveHierarchicalPipeline8x8 else {
            if RENDERER_DEBUG { print("⚠️ Adaptive compute pipeline not available") }
            return nil
        }
        let eyePreparation = framePreparation.perEye[viewIndex]
        let modelView = eyePreparation.modelView
        let inverseModelView = eyePreparation.inverseModelView
        let projection = eyePreparation.projection
        
        // Current frame's full model-view-projection (for temporal reprojection)
        let currentViewProj = projection * modelView
        
        // Get camera position from inverse model-view matrix (in model space)
        let cameraPos = SIMD3<Float>(inverseModelView.columns.3.x, inverseModelView.columns.3.y, inverseModelView.columns.3.z)
        
        // Get color scheme parameters
        let colorSchemeParams = settingsSnapshot.colorSchemeParams
        
        // Mixed immersion: cap the comfort bubble (see RendererGameState).
        let mixedBubbleCapActive = appModel.immersionStyleForRenderer == .mixed && settingsSnapshot.safetyBubbleMixedAutoShrink
        let bubbleRadiusMeters = mixedBubbleCapActive
            ? min(settingsSnapshot.safetyBubbleRadius, settingsSnapshot.safetyBubbleMixedRadius)
            : settingsSnapshot.safetyBubbleRadius
        let scaleCorrectedBubbleRadius = bubbleRadiusMeters / max(framePreparation.effectiveScale, 0.001)
        let scaleCorrectedFadeWidth = settingsSnapshot.safetyBubbleFadeWidth / max(framePreparation.effectiveScale, 0.001)

        // Match fragment path projection mapping by using the actual per-eye
        // viewport (origin + size), not the full texture dimensions.
        let viewport = drawable.views[viewIndex].textureMap.viewport
        let viewportOriginX = max(0, Int(viewport.originX.rounded(.down)))
        let viewportOriginY = max(0, Int(viewport.originY.rounded(.down)))
        let maxViewportWidth = max(1, outputTexture.width - viewportOriginX)
        let maxViewportHeight = max(1, outputTexture.height - viewportOriginY)
        let viewportWidth = min(max(1, Int(viewport.width.rounded(.up))), maxViewportWidth)
        let viewportHeight = min(max(1, Int(viewport.height.rounded(.up))), maxViewportHeight)

        // === Foveation rate-map decode setup ===
        // With foveation on, the drawable color texture is variable-density
        // physical space the compositor un-foveates via a rasterization rate map.
        // The compute kernel writes physical pixels, so it must decode
        // physical→screen to reconstruct rays (see reconstructModelPoint). Fall
        // back to the legacy linear path when no usable rate map exists
        // (Simulator, foveation off, or a physical-size mismatch).
        let rateMaps = drawable.rasterizationRateMaps
        var rateMapValid = false
        var rateMapLayer = 0
        var screenResolution = SIMD2<Float>(Float(viewportWidth), Float(viewportHeight))
        var selectedRateMap: MTLRasterizationRateMap? = nil
        if !rateMaps.isEmpty {
            // Layered drawable: a single map services every eye via its layer.
            // Dedicated drawable: one map per eye (layer 0).
            let perEye = rateMaps.count == drawable.views.count
            let map = perEye ? rateMaps[viewIndex] : rateMaps[0]
            let layer = perEye ? 0 : viewIndex
            let phys = map.physicalSize(layer: layer)
            // The compute output texture is allocated at full native physical size,
            // but the rate map's physical region SHRINKS as renderQuality drops. The
            // old gate required phys == tex exactly, so it was only satisfied at MAX
            // quality — every quality below fell to the distorted linear path. Accept
            // any map whose physical writes FIT the texture on both axes (Apple: the
            // render target must be "at least as large as the physical size"); we then
            // render in that physical region (see renderWidth/Height below).
            if phys.width <= outputTexture.width && phys.height <= outputTexture.height {
                selectedRateMap = map
                rateMapLayer = layer
                rateMapValid = true
                screenResolution = SIMD2<Float>(Float(map.screenSize.width), Float(map.screenSize.height))
            }
            // One-time diagnostic (fires regardless of RENDERER_DEBUG): the compute
            // path's foveation distortion is pinned by the relationship between the
            // physical texture, the rate map's screen size, and the per-eye viewport
            // (origin + size). Logged once per launch so it can be read off-device.
            if !loggedFoveationDecodeOnce {
                loggedFoveationDecodeOnce = true
                print("🔬 Foveation decode eye\(viewIndex): maps=\(rateMaps.count) perEye=\(perEye) layer=\(layer) " +
                      "physical=\(phys.width)x\(phys.height) screen=\(map.screenSize.width)x\(map.screenSize.height) " +
                      "output=\(outputTexture.width)x\(outputTexture.height) " +
                      "viewportOrigin=\(viewportOriginX),\(viewportOriginY) viewport=\(viewportWidth)x\(viewportHeight) " +
                      "rawVP=\(viewport.width)x\(viewport.height)@\(viewport.originX),\(viewport.originY) valid=\(rateMapValid)")
            }
        }

        // Parameter buffer bound at buffer(1). The kernel only builds a decoder
        // from it when rateMapValid == 1; otherwise a small dummy keeps the
        // argument bound so the dispatch never faults on an unbound buffer.
        var rateMapParamBuffer: MTLBuffer?
        if let map = selectedRateMap {
            let need = map.parameterDataSizeAndAlign.size
            let rateMapBufferIndex = uniformBufferIndex * 2 + viewIndex
            if rateMapParamBuffers[rateMapBufferIndex] == nil || rateMapParamBuffers[rateMapBufferIndex]!.length < need {
                rateMapParamBuffers[rateMapBufferIndex] = device.makeBuffer(length: max(need, 16), options: .storageModeShared)
                rateMapParamBuffers[rateMapBufferIndex]?.label = "RateMapParams slot\(uniformBufferIndex) eye\(viewIndex)"
            }
            if let buf = rateMapParamBuffers[rateMapBufferIndex] {
                map.copyParameterData(buffer: buf, offset: 0)
                rateMapParamBuffer = buf
            }
        }
        if rateMapParamBuffer == nil {
            rateMapValid = false  // allocation failed or no map → stay linear
            if rateMapDummyBuffer == nil {
                rateMapDummyBuffer = device.makeBuffer(length: 256, options: .storageModeShared)
                rateMapDummyBuffer?.label = "RateMapParams (dummy)"
            }
            rateMapParamBuffer = rateMapDummyBuffer
        }

        // Render in the rate map's PHYSICAL space when a usable map exists: the
        // dispatch grid and uniforms.resolution must match `phys`, not the full
        // texture, so the kernel writes exactly the foveated region the compositor
        // un-foveates. (Keeping the legacy texture-sized dispatch is what squished the
        // image + produced the black probe-tiles below MAX quality.) Origin is left
        // as the existing per-eye viewportOrigin — the MAX path already renders
        // correctly with it; only the SIZE was wrong. Without a rate map (Simulator /
        // foveation off) we keep the legacy clamped screen-viewport size.
        var renderWidth = viewportWidth
        var renderHeight = viewportHeight
        if rateMapValid, let map = selectedRateMap {
            let phys = map.physicalSize(layer: rateMapLayer)
            renderWidth = max(1, min(phys.width - viewportOriginX, outputTexture.width - viewportOriginX))
            renderHeight = max(1, min(phys.height - viewportOriginY, outputTexture.height - viewportOriginY))
        }

        // Break up the large TileUniforms initializer to help the type-checker
        let tileResolution = SIMD2<Float>(Float(renderWidth), Float(renderHeight))
        let tileViewportOrigin = SIMD2<Float>(Float(viewportOriginX), Float(viewportOriginY))
        let tileSafetyBubbleEnabled: Int32 = (settingsSnapshot.fractalType == .mandelbulb) ? 0 : (settingsSnapshot.safetyBubbleEnabled ? 1 : 0)
        let tileSafetyBubbleFadeEnabled: Int32 = settingsSnapshot.safetyBubbleFadeEnabled ? 1 : 0
        let tileSafetyBubbleStrength: Float = (settingsSnapshot.fractalType == .mandelbulb) ? 0.0 : settingsSnapshot.safetyBubbleStrength
        let tileMarchEpsilonScale: Float = (1.0 / max(framePreparation.effectiveScale, 1.0)) * max(1.0, 0.15 / max(framePreparation.effectiveScale, 1e-4))
        let tileSphereProjectionBlend: Float = settingsSnapshot.sphereProjectionEnabled ? settingsSnapshot.sphereProjectionBlend : 0
        let tileSmartAdvanceEnabled: Int32 = settingsSnapshot.smartAdvanceEnabled ? 1 : 0
        let tileRenderHeight = Float(renderHeight)
        let tileConeMarchScale: Float = RenderPrecompute.coneMarchScale(strength: settingsSnapshot.coneMarchStrength, projection: projection, viewportHeight: tileRenderHeight)
        let tileShadowsEnabled: Int32 = settingsSnapshot.shadowsEnabled ? 1 : 0
        let tileDistanceLODFalloff: Float = settingsSnapshot.distanceLODStrength * 0.5 * min(1.0, framePreparation.effectiveScale / 0.15)
        let tilePixelFootprintPerDist: Float = RenderPrecompute.pixelFootprintPerDist(projection: projection, viewportHeight: tileRenderHeight)
        let tileBlendFactor: Float = settingsSnapshot.isGeometryGestureActive ? 1.0 : (settingsSnapshot.geometryState == .stable ? 0.1 : 0.5)
        let tileSpringStretch: Float = simd_length(settingsSnapshot.springDisplacement)
        let tileSpringVisible: Int32 = (settingsSnapshot.springActive || tileSpringStretch > 0.001) ? 1 : 0
        let tileTemporalReprojectionEnabled: Int32 = (temporalFrameCount > 0
            && settingsSnapshot.computeTemporalReprojectionEnabled
            && computeWarmStartGate.allowsWarmStart(for: settingsSnapshot)) ? 1 : 0
        let tileRateMapValid: Int32 = rateMapValid ? 1 : 0
        let tileDebugHierarchical: UInt32 = settingsSnapshot.debugHierarchical ? 1 : 0

        var tileUniforms = TileUniforms(
            invViewMatrix: inverseModelView,
            invProjMatrix: projection.inverse,
            cameraPos: cameraPos,
            time: framePreparation.frameTime,
            resolution: tileResolution,
            viewportOrigin: tileViewportOrigin,
            minDistance: settingsSnapshot.minDistance,
            fractalScale: settingsSnapshot.fractalScale,
            sphereRadius: settingsSnapshot.sphereRadius,
            safetyBubbleRadius: scaleCorrectedBubbleRadius,
            safetyBubbleEnabled: tileSafetyBubbleEnabled,
            safetyBubbleShape: settingsSnapshot.safetyBubbleShape,
            safetyBubbleFadeEnabled: tileSafetyBubbleFadeEnabled,
            safetyBubbleFadeWidth: scaleCorrectedFadeWidth,
            safetyBubbleStrength: tileSafetyBubbleStrength,
            handField: framePreparation.handAttraction.asHandFieldParams,
            foldingLimit: settingsSnapshot.foldingLimit,
            glowIntensity: framePreparation.animatedGlow,
            colorMix: framePreparation.animatedColorMix,
            fractalIterations: Int32(settingsSnapshot.fractalIterations),
            colorIterations: Int32(settingsSnapshot.colorIterations),
            maxRaySteps: Int32(settingsSnapshot.maxRaySteps),
            maxViewDistance: framePreparation.maxViewDistance,
            marchEpsilonScale: tileMarchEpsilonScale,
            eyeIndex: UInt32(viewIndex),
            debugHierarchical: tileDebugHierarchical,
            limitFlash: settingsSnapshot.limitFlash,
            fractalType: settingsSnapshot.fractalType.rawValue,
            lightingSoftness: settingsSnapshot.lightingSoftness,
            sphericalInversionMode: settingsSnapshot.sphericalInversionMode.rawValue,
            sphericalInversionRadius: settingsSnapshot.sphericalInversionRadius,
            sphereProjectionBlend: tileSphereProjectionBlend,
            sphereProjectionRadius: settingsSnapshot.sphereProjectionRadius,
            spaceWarpStrength: settingsSnapshot.spaceWarpStrength,
            spaceWarpParam1: settingsSnapshot.spaceWarpParam1,
            spaceWarpParam2: settingsSnapshot.spaceWarpParam2,
            spaceWarpParam3: settingsSnapshot.spaceWarpParam3,
            spaceWarpAxis: settingsSnapshot.spaceWarpAxis,
            spaceWarpStack: settingsSnapshot.spaceWarpStack,
            stepMultiplier: settingsSnapshot.stepMultiplier,
            boundingSphereRadius: settingsSnapshot.estimatedBoundingSphereRadius,
            smartAdvanceEnabled: tileSmartAdvanceEnabled,
            coneMarchScale: tileConeMarchScale,
            coneCoverageAAEnabled: settingsSnapshot.coneCoverageAAEnabled ? 1 : 0,
            shadowsEnabled: tileShadowsEnabled,
            distanceLODFalloff: tileDistanceLODFalloff,
            pixelFootprintPerDist: tilePixelFootprintPerDist,
            coarseRateMagMax: 1.0,
            blendFactor: tileBlendFactor,
            springDisplacementX: settingsSnapshot.springDisplacement.x,
            springDisplacementY: settingsSnapshot.springDisplacement.y,
            springDisplacementZ: settingsSnapshot.springDisplacement.z,
            springStretch: tileSpringStretch,
            springAnchorNDC: SIMD2<Float>(0.7, -0.7),
            springVisible: tileSpringVisible,
            springRestRadius: 0.06,
            jitterOffset: .zero,
            temporalReprojectionEnabled: tileTemporalReprojectionEnabled,
            coherentPacketEnabled: settingsSnapshot.coherentPacketEnabled ? 1 : 0,
            foveationStrength: settingsSnapshot.foveationStrength,
            floorPlane: framePreparation.perEye[viewIndex].floorPlane,
            floorCenterRadius: framePreparation.perEye[viewIndex].floorCenterRadius,
            formulaParams: settingsSnapshot.formulaParams,
            currentViewProjMatrix: currentViewProj,
            previousViewProjMatrix: previousViewProjMatrices[viewIndex],
            currentInvViewProjMatrix: currentViewProj.inverse,
            precomputedFractal: framePreparation.precomputedFractal,
            precomputedLighting: framePreparation.precomputedLighting,
            precomputedAudio: framePreparation.precomputedAudio,
            precomputedFog: framePreparation.precomputedFog,
            colorScheme: colorSchemeParams,
            screenResolution: screenResolution,
            rateMapValid: tileRateMapValid,
            rateMapLayer: UInt32(rateMapLayer),
            boundToSpaceMode: settingsSnapshot.resolvedBoundToSpaceMode,
            boundSpaceSize: framePreparation.boundSpaceSize,
            boundAmbientStrength: settingsSnapshot.boundAmbientStrength,
            modelToBoundSpaceMatrix: framePreparation.boundSpaceWorldToLocalMatrix * framePreparation.modelMatrix,
            envScrunch: framePreparation.envScrunch,
            boundingShapeType: settingsSnapshot.boundingShapeType,
            // Pin the Bounding Shape while the Linear Rail slides content through
            // it (0 when the rail is off).
            boundingShapeCenter: settingsSnapshot.boundingShapeCenterModel(modelMatrix: framePreparation.modelMatrix)
        )

        // Copy uniforms to buffer (pointer cached by caller across both eyes)
        let uniformOffset = MemoryLayout<TileUniforms>.stride
            * (uniformBufferIndex * 2 + viewIndex)
        memcpy(bufferContents.advanced(by: uniformOffset), &tileUniforms, MemoryLayout<TileUniforms>.size)
        
        // Create compute encoder
        guard let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
            if RENDERER_DEBUG { print("⚠️ Failed to create compute encoder") }
            return nil
        }
        
        computeEncoder.label = viewIndex == 0 ? "Adaptive Compute - Eye 0" : "Adaptive Compute - Eye 1"
        computeEncoder.setComputePipelineState(pipeline)
        // Environment Scrunch grid is reached bindlessly (GPU address in the
        // uniforms), so it needs explicit residency on every encoder that
        // marches the DE.
        if let envGrid = framePreparation.environmentGrid {
            computeEncoder.useResource(envGrid.buffer, usage: .read)
        }
        computeEncoder.setBuffer(uniformBuffer, offset: uniformOffset, index: 0)
        if let rateMapParamBuffer {
            computeEncoder.setBuffer(rateMapParamBuffer, offset: 0, index: 1)
            computeEncoder.useResource(rateMapParamBuffer, usage: .read)
        }
        computeEncoder.setTexture(outputTexture, index: 0)
        
        // Temporal reprojection depth textures
        computeEncoder.setTexture(prevDepthTexture, index: 1)
        computeEncoder.setTexture(curDepthTexture, index: 2)
        
        // Store current VP for next frame's reprojection
        previousViewProjMatrices[viewIndex] = currentViewProj
        
        // Dispatch 8x8 threadgroups
        let tileSize = 8
        let threadgroupSize = MTLSize(width: tileSize, height: tileSize, depth: 1)
        let threadgroupsPerGrid = MTLSize(
            width: (renderWidth + tileSize - 1) / tileSize,
            height: (renderHeight + tileSize - 1) / tileSize,
            depth: 1
        )
        
        computeEncoder.dispatchThreadgroups(threadgroupsPerGrid, threadsPerThreadgroup: threadgroupSize)
        computeEncoder.endEncoding()
        return SIMD2(renderWidth, renderHeight)
    }
    
    /// Creates or resizes the compute output texture to match drawable dimensions
    private func ensureComputeOutputTexture(for drawable: LayerRenderer.Drawable) -> MTLTexture? {
        let width = drawable.colorTextures[0].width
        let height = drawable.colorTextures[0].height
        let viewCount = drawable.views.count
        
        // Check if existing texture matches
        if let existing = computeOutputTexture,
           existing.width == width,
           existing.height == height,
           existing.arrayLength == viewCount {
            return existing
        }
        
        // Create new texture with .shaderWrite flag
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type2DArray
        descriptor.pixelFormat = drawable.colorTextures[0].pixelFormat
        descriptor.width = width
        descriptor.height = height
        descriptor.arrayLength = viewCount
        descriptor.storageMode = .private
        descriptor.usage = [.shaderWrite, .shaderRead]  // Key: has shaderWrite!
        
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            if RENDERER_DEBUG { print("⚠️ Failed to create compute output texture") }
            return nil
        }
        texture.label = "Adaptive Compute Output"
        
        computeOutputTexture = texture

        // Residency update deferred to renderWithAdaptiveCompute() for batching
        
        if RENDERER_DEBUG { print("📐 Created compute output texture: \(width)×\(height) × \(viewCount) layers") }
        return texture
    }

    private func ensureEdgeOutputTexture(for drawable: LayerRenderer.Drawable) -> MTLTexture? {
        let source = drawable.colorTextures[0]
        let viewCount = drawable.views.count
        if let existing = edgeOutputTexture,
           existing.width == source.width,
           existing.height == source.height,
           existing.arrayLength == viewCount { return existing }

        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type2DArray
        descriptor.pixelFormat = source.pixelFormat
        descriptor.width = source.width
        descriptor.height = source.height
        descriptor.arrayLength = viewCount
        descriptor.storageMode = .private
        descriptor.usage = [.shaderRead, .shaderWrite]
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.label = "Sliding Window Edge Output"
        edgeOutputTexture = texture
        return texture
    }

    private func estimatedAdaptiveComputeAuxiliaryBytes(
        for drawable: LayerRenderer.Drawable,
        edgeEnabled: Bool
    ) -> Int {
        let width = drawable.colorTextures[0].width
        let height = drawable.colorTextures[0].height
        let viewCount = max(1, drawable.views.count)
        let pixelCount = width * height * viewCount

        // Adaptive compute needs one shader-writable color target plus two r32Float
        // depth-history textures. Edge treatment adds a second color target. At
        // high compositor renderQuality these auxiliary textures can push the
        // process over the headset's working set. Common drawable color and r32
        // depth formats here are 4 bytes/pixel.
        return pixelCount * (4 + 4 + 4 + (edgeEnabled ? 4 : 0))
    }

    private func canAllocateAdaptiveComputeAuxiliaryTextures(
        for drawable: LayerRenderer.Drawable,
        edgeEnabled: Bool
    ) -> Bool {
        let estimatedBytes = estimatedAdaptiveComputeAuxiliaryBytes(
            for: drawable,
            edgeEnabled: edgeEnabled
        )
        let budgetBytes = 160 * 1024 * 1024
        if estimatedBytes <= budgetBytes { return true }

        if !hasLoggedComputeMemoryFallback {
            hasLoggedComputeMemoryFallback = true
            let mb = Double(estimatedBytes) / (1024.0 * 1024.0)
            let budgetMB = Double(budgetBytes) / (1024.0 * 1024.0)
            print("⚠️ Adaptive compute disabled for this drawable: auxiliary textures would use \(Int(mb.rounded())) MB (budget \(Int(budgetMB)) MB). Falling back to fragment rendering.")
        }
        return false
    }

    /// Drops every drawable-sized allocation owned by the adaptive compute path.
    /// Metal command buffers retain resources they reference, so an older in-flight
    /// frame remains valid while the renderer stops retaining the inactive pool.
    private func releaseAdaptiveComputeAuxiliaryTextures() {
        guard computeOutputTexture != nil || edgeOutputTexture != nil ||
              temporalDepthTextures[0] != nil || temporalDepthTextures[1] != nil else {
            return
        }
        computeOutputTexture = nil
        edgeOutputTexture = nil
        temporalDepthTextures = [nil, nil]
        temporalDepthIndex = 0
        temporalFrameCount = 0
        computeWarmStartGate.invalidate()
    }

    /// A command-buffer error is recoverable only if we stop resubmitting the
    /// faulting adaptive kernel. The fragment path remains available as the safe
    /// fallback for the rest of the immersive-session lifetime.
    private func observeAdaptiveComputeCompletion(_ commandBuffer: MTLCommandBuffer) {
        commandBuffer.addCompletedHandler { [weak self] completed in
            guard completed.status == .error else { return }
            let message = completed.error?.localizedDescription ?? "unknown Metal error"
            guard let self else { return }
            Task { await self.suppressAdaptiveComputeAfterGPUFailure(message) }
        }
    }

    private func suppressAdaptiveComputeAfterGPUFailure(_ message: String) {
        adaptiveComputeSuppressedAfterGPUFailure = true
        releaseAdaptiveComputeAuxiliaryTextures()
        if !hasLoggedAdaptiveComputeGPUFailure {
            hasLoggedAdaptiveComputeGPUFailure = true
            print("⚠️ Adaptive compute GPU failure: \(message). Using fragment rendering for the rest of this immersive session.")
        }
    }
    
    /// Creates or resizes the double-buffered temporal depth textures for reprojection.
    /// Returns (previousRead, currentWrite) texture pair.
    private func ensureTemporalDepthTextures(for drawable: LayerRenderer.Drawable) -> (read: MTLTexture, write: MTLTexture)? {
        let width = drawable.colorTextures[0].width
        let height = drawable.colorTextures[0].height
        let viewCount = drawable.views.count
        
        // Check if existing textures match
        if let tex0 = temporalDepthTextures[0],
           let _ = temporalDepthTextures[1],
           tex0.width == width,
           tex0.height == height,
           tex0.arrayLength == viewCount {
            // Ping-pong: current write index, read from the other
            let readIdx = 1 - temporalDepthIndex
            return (read: temporalDepthTextures[readIdx]!, write: temporalDepthTextures[temporalDepthIndex]!)
        }
        
        // Create new depth textures (r32Float — stores ray-t distance per pixel)
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type2DArray
        descriptor.pixelFormat = .r32Float
        descriptor.width = width
        descriptor.height = height
        descriptor.arrayLength = viewCount
        descriptor.storageMode = .private
        descriptor.usage = [.shaderWrite, .shaderRead]
        
        guard let tex0 = device.makeTexture(descriptor: descriptor),
              let tex1 = device.makeTexture(descriptor: descriptor) else {
            if RENDERER_DEBUG { print("⚠️ Failed to create temporal depth textures") }
            return nil
        }
        tex0.label = "Temporal Depth 0"
        tex1.label = "Temporal Depth 1"
        
        temporalDepthTextures = [tex0, tex1]
        temporalDepthIndex = 0
        temporalFrameCount = 0  // Reset — first frame has no valid previous data
        computeWarmStartGate.invalidate()
        
        // Residency update deferred to renderWithAdaptiveCompute() for batching
        
        if RENDERER_DEBUG { print("📐 Created temporal depth textures: \(width)×\(height) × \(viewCount) layers") }
        return (read: tex0, write: tex0)  // First frame: read=write (will be marked invalid)
    }

    /// Creates or resizes the coarse warm-start texture (conservative cone
    /// coarse-prepass). Sized to the FOVEATED PHYSICAL render-target size / 8
    /// (width = ceil(renderWidth/8), height = ceil(renderHeight/8)) so its texels
    /// line up 1:1 with the fragment shader's floor(fragCoord/8). r32Float, one
    /// layer per eye, .private with shaderWrite|shaderRead — cloned from
    /// ensureTemporalDepthTextures.
    private func ensureCoarseStartTexture(renderWidth: Int, renderHeight: Int, viewCount: Int) -> MTLTexture? {
        let cw = max(1, (renderWidth + 7) / 8)
        let ch = max(1, (renderHeight + 7) / 8)

        if let existing = coarseStartTexture,
           existing.width == cw,
           existing.height == ch,
           existing.arrayLength == viewCount {
            return existing
        }

        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type2DArray
        descriptor.pixelFormat = .r32Float
        descriptor.width = cw
        descriptor.height = ch
        descriptor.arrayLength = viewCount
        descriptor.storageMode = .private
        descriptor.usage = [.shaderWrite, .shaderRead]

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            if RENDERER_DEBUG { print("⚠️ Failed to create coarse warm-start texture") }
            return nil
        }
        texture.label = "Cone Coarse Warm-Start"
        coarseStartTexture = texture
        if RENDERER_DEBUG { print("📐 Created coarse warm-start texture: \(cw)×\(ch) × \(viewCount) layers") }
        return texture
    }

    /// 1×1 r32Float array dummy bound to the fragment coarse-texture slot when the
    /// cone pass is disabled, so the slot is always populated (mirrors the
    /// warm-start dummy depth pattern). Never sampled (FC_COARSE_WARM_START off).
    private func ensureCoarseStartDummyTexture(viewCount: Int) -> MTLTexture? {
        if let existing = coarseStartDummyTexture, existing.arrayLength == viewCount {
            return existing
        }
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type2DArray
        descriptor.pixelFormat = .r32Float
        descriptor.width = 1
        descriptor.height = 1
        descriptor.arrayLength = max(1, viewCount)
        descriptor.storageMode = .private
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.label = "Cone Coarse Warm-Start (dummy)"
        coarseStartDummyTexture = texture
        return texture
    }

    /// True only for the box/fold fractal family whose analytic DE is a
    /// conservative (Lipschitz-1) lower bound, so the cone-bounding warm start is
    /// provably safe. Matches coneSafetyForFamily in Shaders.metal.
    func isBoxFoldFamily(_ type: FractalModelType) -> Bool {
        switch type {
        case .mandelbox, .menger, .octahedron, .mengerSphere:
            return true
        default:
            return false
        }
    }

    /// Copies compute output texture to drawable using blit encoder
    private func blitComputeOutputToDrawable(
        commandBuffer: MTLCommandBuffer,
        drawable: LayerRenderer.Drawable,
        useEdgeOutput: Bool
    ) {
        let sourceTexture = (useEdgeOutput && edgeDetectionPipeline != nil && edgeOutputTexture != nil)
            ? edgeOutputTexture : computeOutputTexture
        guard let sourceTexture else { return }
        guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else { return }
        blitEncoder.label = "Copy Compute Output to Drawable"
        
        let viewCount = drawable.views.count
        for eye in 0..<viewCount {
            let destinationTexture: MTLTexture
            let destinationSlice: Int
            
            if drawable.colorTextures.count > eye {
                // Dedicated layout - separate texture per eye
                destinationTexture = drawable.colorTextures[eye]
                destinationSlice = 0
            } else {
                // Layered layout - single 2D array texture
                destinationTexture = drawable.colorTextures[0]
                destinationSlice = eye
            }

            // Copy only the foveated physical region the compositor un-foveates
            // ([0,phys)). The kernel only writes that region; pixels beyond it are
            // unwritten and never read, so copying the full texture just ships garbage
            // and wastes ~2.6× blit bandwidth at low quality. Fall back to the full
            // texture when no rate map applies (Simulator / foveation off).
            var copyWidth = min(sourceTexture.width, destinationTexture.width)
            var copyHeight = min(sourceTexture.height, destinationTexture.height)
            let rateMaps = drawable.rasterizationRateMaps
            if !rateMaps.isEmpty {
                let perEye = rateMaps.count == viewCount
                let map = perEye ? rateMaps[eye] : rateMaps[0]
                let layer = perEye ? 0 : eye
                let phys = map.physicalSize(layer: layer)
                copyWidth = min(copyWidth, phys.width)
                copyHeight = min(copyHeight, phys.height)
            }
            
            blitEncoder.copy(
                from: sourceTexture,
                sourceSlice: eye,
                sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(width: copyWidth, height: copyHeight, depth: 1),
                to: destinationTexture,
                destinationSlice: destinationSlice,
                destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
            )
        }
        
        blitEncoder.endEncoding()
    }

    private func encodeEdgeDetection(
        commandBuffer: MTLCommandBuffer,
        sourceTexture: MTLTexture,
        destinationTexture: MTLTexture,
        viewIndex: Int,
        renderWidth: Int,
        renderHeight: Int,
        uniformBuffer: MTLBuffer
    ) -> Bool {
        guard let pipeline = edgeDetectionPipeline,
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return false }
        encoder.label = "Sliding Window Edge Detector Eye \(viewIndex)"
        encoder.setComputePipelineState(pipeline)
        let uniformOffset = MemoryLayout<TileUniforms>.stride
            * (uniformBufferIndex * 2 + viewIndex)
        encoder.setBuffer(uniformBuffer, offset: uniformOffset, index: 0)
        encoder.setTexture(sourceTexture, index: 0)
        encoder.setTexture(destinationTexture, index: 1)
        let w = max(1, min(renderWidth, sourceTexture.width))
        let h = max(1, min(renderHeight, sourceTexture.height))
        let tw = max(1, pipeline.threadExecutionWidth)
        let th = max(1, pipeline.maxTotalThreadsPerThreadgroup / tw)
        encoder.dispatchThreads(
            MTLSize(width: w, height: h, depth: 1),
            threadsPerThreadgroup: MTLSize(width: min(tw, w), height: min(th, h), depth: 1)
        )
        encoder.endEncoding()
        return true
    }

    // MARK: - Conservative Cone Coarse-Prepass Warm-Start

    /// Encodes the cone coarse-prepass for every eye on `commandBuffer`, writing a
    /// conservative warmT (provable LOWER BOUND on the nearest-surface entry
    /// distance) into `coarseTex` (sized to renderWidth/8 × renderHeight/8). The
    /// fragment pass that follows on the same command buffer reads it; Metal's
    /// automatic hazard tracking provides the read-after-write barrier (the texture
    /// is .private and tracked). Caller must have verified `coneAllowed`.
    ///
    /// `renderWidth/renderHeight` are the fragment pass's render-target dimensions
    /// (MetalFX input size, or the drawable size). `viewports` are the per-eye
    /// viewports the fragment pass uses (origin 0 under MetalFX; drawable viewport
    /// origins on the direct path) — the cone reconstructs rays in the SAME space.
    private func encodeConeCoarsePrepass(
        commandBuffer: MTLCommandBuffer,
        coarseTex: MTLTexture,
        drawable: LayerRenderer.Drawable,
        settingsSnapshot: RenderSettingsSnapshot,
        framePreparation: RendererFramePreparation,
        renderWidth: Int,
        renderHeight: Int,
        viewports: [MTLViewport]
    ) {
        guard let pipeline = coneCoarsePrepassPipeline else { return }
        guard let uniformBuffer = tileUniformBuffer else { return }
        let bufferContents = uniformBuffer.contents()

        guard let computeEncoder = commandBuffer.makeComputeCommandEncoder() else { return }
        computeEncoder.label = "Cone Coarse-Prepass"
        computeEncoder.setComputePipelineState(pipeline)
        if let envGrid = framePreparation.environmentGrid {
            computeEncoder.useResource(envGrid.buffer, usage: .read)
        }

        // Dispatch over the FULL render target / 8 (so coarse texels line up with
        // the fragment's floor(fragCoord/8)). One thread per coarse texel.
        let coarseW = max(1, (renderWidth + 7) / 8)
        let coarseH = max(1, (renderHeight + 7) / 8)
        let tg = MTLSize(width: 16, height: 16, depth: 1)
        let grid = MTLSize(
            width: (coarseW + tg.width - 1) / tg.width,
            height: (coarseH + tg.height - 1) / tg.height,
            depth: 1
        )

        let viewCount = drawable.views.count
        for viewIndex in 0..<viewCount {
            let eyePreparation = framePreparation.perEye[viewIndex]
            let modelView = eyePreparation.modelView
            let inverseModelView = eyePreparation.inverseModelView
            let projection = eyePreparation.projection
            let cameraPos = SIMD3<Float>(inverseModelView.columns.3.x, inverseModelView.columns.3.y, inverseModelView.columns.3.z)

            // Per-eye viewport (origin + size) the fragment pass renders into.
            let vp = viewIndex < viewports.count ? viewports[viewIndex] : (drawable.views[viewIndex].textureMap.viewport)
            let viewportOriginX = max(0, Int(vp.originX.rounded(.down)))
            let viewportOriginY = max(0, Int(vp.originY.rounded(.down)))
            let viewportW = max(1, Int(vp.width.rounded(.up)))
            let viewportH = max(1, Int(vp.height.rounded(.up)))

            // Foveation rate-map decode setup (mirror encodeAdaptiveCompute). With a
            // valid map the fragment geometry is in physical space and decoded
            // through the rate map; the cone must decode the same way. We bound the
            // physical→screen magnification conservatively (over-bounding only
            // shortens the skip, which is always safe).
            let rateMaps = drawable.rasterizationRateMaps
            var rateMapValid = false
            var rateMapLayer = 0
            var screenResolution = SIMD2<Float>(Float(viewportW), Float(viewportH))
            var selectedRateMap: MTLRasterizationRateMap? = nil
            if !rateMaps.isEmpty {
                let perEye = rateMaps.count == viewCount
                let map = perEye ? rateMaps[viewIndex] : rateMaps[0]
                let layer = perEye ? 0 : viewIndex
                let phys = map.physicalSize(layer: layer)
                if phys.width <= renderWidth && phys.height <= renderHeight {
                    selectedRateMap = map
                    rateMapLayer = layer
                    rateMapValid = true
                    screenResolution = SIMD2<Float>(Float(map.screenSize.width), Float(map.screenSize.height))
                }
            }
            var rateMapParamBuffer: MTLBuffer?
            if let map = selectedRateMap {
                let need = map.parameterDataSizeAndAlign.size
                let rateMapBufferIndex = uniformBufferIndex * 2 + viewIndex
                if rateMapParamBuffers[rateMapBufferIndex] == nil || rateMapParamBuffers[rateMapBufferIndex]!.length < need {
                    rateMapParamBuffers[rateMapBufferIndex] = device.makeBuffer(length: max(need, 16), options: .storageModeShared)
                    rateMapParamBuffers[rateMapBufferIndex]?.label = "RateMapParams(cone) slot\(uniformBufferIndex) eye\(viewIndex)"
                }
                if let buf = rateMapParamBuffers[rateMapBufferIndex] {
                    map.copyParameterData(buffer: buf, offset: 0)
                    rateMapParamBuffer = buf
                }
            }
            if rateMapParamBuffer == nil {
                rateMapValid = false
                if rateMapDummyBuffer == nil {
                    rateMapDummyBuffer = device.makeBuffer(length: 256, options: .storageModeShared)
                    rateMapDummyBuffer?.label = "RateMapParams (dummy)"
                }
                rateMapParamBuffer = rateMapDummyBuffer
            }

            // Over-bound on physical→screen magnification under foveation. 4.0 is a
            // safe upper bound for the gaze-tracked rate map's peripheral
            // compression; 1.0 (no magnification) when no map applies. Over-bounding
            // only shortens the warm-start skip — never unsafe.
            let coarseRateMagMax: Float = rateMapValid ? 4.0 : 1.0

            // Mixed immersion: cap the comfort bubble (see RendererGameState).
            let mixedBubbleCapActive = appModel.immersionStyleForRenderer == .mixed && settingsSnapshot.safetyBubbleMixedAutoShrink
            let bubbleRadiusMeters = mixedBubbleCapActive
                ? min(settingsSnapshot.safetyBubbleRadius, settingsSnapshot.safetyBubbleMixedRadius)
                : settingsSnapshot.safetyBubbleRadius
            let scaleCorrectedBubbleRadius = bubbleRadiusMeters / max(framePreparation.effectiveScale, 0.001)
            let scaleCorrectedFadeWidth = settingsSnapshot.safetyBubbleFadeWidth / max(framePreparation.effectiveScale, 0.001)

            var tileUniforms = TileUniforms(
                invViewMatrix: inverseModelView,
                invProjMatrix: projection.inverse,
                cameraPos: cameraPos,
                time: framePreparation.frameTime,
                resolution: SIMD2<Float>(Float(viewportW), Float(viewportH)),
                viewportOrigin: SIMD2<Float>(Float(viewportOriginX), Float(viewportOriginY)),
                minDistance: settingsSnapshot.minDistance,
                fractalScale: settingsSnapshot.fractalScale,
                sphereRadius: settingsSnapshot.sphereRadius,
                safetyBubbleRadius: scaleCorrectedBubbleRadius,
                safetyBubbleEnabled: (settingsSnapshot.fractalType == .mandelbulb) ? 0 : (settingsSnapshot.safetyBubbleEnabled ? 1 : 0),
                safetyBubbleShape: settingsSnapshot.safetyBubbleShape,
                safetyBubbleFadeEnabled: settingsSnapshot.safetyBubbleFadeEnabled ? 1 : 0,
                safetyBubbleFadeWidth: scaleCorrectedFadeWidth,
                safetyBubbleStrength: (settingsSnapshot.fractalType == .mandelbulb) ? 0.0 : settingsSnapshot.safetyBubbleStrength,
                handField: framePreparation.handAttraction.asHandFieldParams,
                foldingLimit: settingsSnapshot.foldingLimit,
                glowIntensity: framePreparation.animatedGlow,
                colorMix: framePreparation.animatedColorMix,
                fractalIterations: Int32(settingsSnapshot.fractalIterations),
                colorIterations: Int32(settingsSnapshot.colorIterations),
                maxRaySteps: Int32(settingsSnapshot.maxRaySteps),
                maxViewDistance: framePreparation.maxViewDistance,
                // Zoom-in tighten × zoom-out loosen (see the fragment-path site).
                marchEpsilonScale: (1.0 / max(framePreparation.effectiveScale, 1.0))
                    * max(1.0, 0.15 / max(framePreparation.effectiveScale, 1e-4)),
                eyeIndex: UInt32(viewIndex),
                debugHierarchical: 0,
                limitFlash: settingsSnapshot.limitFlash,
                fractalType: settingsSnapshot.fractalType.rawValue,
                lightingSoftness: settingsSnapshot.lightingSoftness,
                sphericalInversionMode: settingsSnapshot.sphericalInversionMode.rawValue,
                sphericalInversionRadius: settingsSnapshot.sphericalInversionRadius,
                sphereProjectionBlend: settingsSnapshot.sphereProjectionEnabled ? settingsSnapshot.sphereProjectionBlend : 0,
                sphereProjectionRadius: settingsSnapshot.sphereProjectionRadius,
                spaceWarpStrength: settingsSnapshot.spaceWarpStrength,
                spaceWarpParam1: settingsSnapshot.spaceWarpParam1,
                spaceWarpParam2: settingsSnapshot.spaceWarpParam2,
                spaceWarpParam3: settingsSnapshot.spaceWarpParam3,
                spaceWarpAxis: settingsSnapshot.spaceWarpAxis,
                spaceWarpStack: settingsSnapshot.spaceWarpStack,
                stepMultiplier: settingsSnapshot.stepMultiplier,
                boundingSphereRadius: settingsSnapshot.estimatedBoundingSphereRadius,
                smartAdvanceEnabled: settingsSnapshot.smartAdvanceEnabled ? 1 : 0,
                coneMarchScale: RenderPrecompute.coneMarchScale(
                    strength: settingsSnapshot.coneMarchStrength,
                    projection: projection,
                    viewportHeight: Float(viewportH)),
                coneCoverageAAEnabled: settingsSnapshot.coneCoverageAAEnabled ? 1 : 0,
                shadowsEnabled: settingsSnapshot.shadowsEnabled ? 1 : 0,
                distanceLODFalloff: settingsSnapshot.distanceLODStrength * 0.5
                    * min(1.0, framePreparation.effectiveScale / 0.15),
                pixelFootprintPerDist: RenderPrecompute.pixelFootprintPerDist(
                    projection: projection,
                    viewportHeight: Float(viewportH)),
                coarseRateMagMax: coarseRateMagMax,
                blendFactor: 1.0,
                springDisplacementX: 0,
                springDisplacementY: 0,
                springDisplacementZ: 0,
                springStretch: 0,
                springAnchorNDC: SIMD2<Float>(0.7, -0.7),
                springVisible: 0,
                springRestRadius: 0.06,
                jitterOffset: .zero,
                temporalReprojectionEnabled: 0,
                coherentPacketEnabled: 0,
                foveationStrength: settingsSnapshot.foveationStrength,
                floorPlane: framePreparation.perEye[viewIndex].floorPlane,
                floorCenterRadius: framePreparation.perEye[viewIndex].floorCenterRadius,
                formulaParams: settingsSnapshot.formulaParams,
                currentViewProjMatrix: projection * modelView,
                previousViewProjMatrix: previousViewProjMatrices[viewIndex],
                currentInvViewProjMatrix: (projection * modelView).inverse,
                precomputedFractal: framePreparation.precomputedFractal,
                precomputedLighting: framePreparation.precomputedLighting,
                precomputedAudio: framePreparation.precomputedAudio,
                precomputedFog: framePreparation.precomputedFog,
                colorScheme: settingsSnapshot.colorSchemeParams,
                screenResolution: screenResolution,
                rateMapValid: rateMapValid ? 1 : 0,
                rateMapLayer: UInt32(rateMapLayer),
                boundToSpaceMode: settingsSnapshot.resolvedBoundToSpaceMode,
                boundSpaceSize: framePreparation.boundSpaceSize,
                boundAmbientStrength: settingsSnapshot.boundAmbientStrength,
                modelToBoundSpaceMatrix: framePreparation.boundSpaceWorldToLocalMatrix * framePreparation.modelMatrix,
                envScrunch: framePreparation.envScrunch,
                boundingShapeType: settingsSnapshot.boundingShapeType,
                // Pin the Bounding Shape while the Linear Rail slides content
                // through it (0 when the rail is off).
                boundingShapeCenter: settingsSnapshot.boundingShapeCenterModel(modelMatrix: framePreparation.modelMatrix)
            )

            let uniformOffset = MemoryLayout<TileUniforms>.stride
                * (uniformBufferIndex * 2 + viewIndex)
            memcpy(bufferContents.advanced(by: uniformOffset), &tileUniforms, MemoryLayout<TileUniforms>.size)

            computeEncoder.setBuffer(uniformBuffer, offset: uniformOffset, index: 0)
            if let rateMapParamBuffer {
                computeEncoder.setBuffer(rateMapParamBuffer, offset: 0, index: 1)
                computeEncoder.useResource(rateMapParamBuffer, usage: .read)
            }
            computeEncoder.setTexture(coarseTex, index: 0)
            computeEncoder.dispatchThreadgroups(grid, threadsPerThreadgroup: tg)
        }

        computeEncoder.endEncoding()
    }

    /// Renders using the adaptive 8x8 compute pipeline instead of fragment shaders
    /// Returns true if compute rendering was used
    private func renderWithAdaptiveCompute(
        commandBuffer: MTLCommandBuffer,
        drawable: LayerRenderer.Drawable,
        settingsSnapshot: RenderSettingsSnapshot,
        framePreparation: RendererFramePreparation
    ) -> Bool {
        // Select the best compute pipeline for current iteration/ray step settings
        let fi = settingsSnapshot.fractalIterations
        let rs = settingsSnapshot.maxRaySteps
        let computePipeline = selectComputePipeline(
            fractalIterations: fi,
            maxRaySteps: rs,
            request: ComputePipelineRequest(
                fractalType: settingsSnapshot.fractalType,
                formulaParams: settingsSnapshot.formulaParams
            )
        )
        
        guard computePipeline != nil else {
            releaseAdaptiveComputeAuxiliaryTextures()
            return false
        }
        guard let uniformBuffer = tileUniformBuffer else {
            releaseAdaptiveComputeAuxiliaryTextures()
            return false
        }
        let bufferContents = uniformBuffer.contents()

        let edgeEnabled = settingsSnapshot.colorSchemeParams.edgeDetectionEnabled != 0
        if !edgeEnabled {
            // Edge output is another full-size stereo color target. Do not keep it
            // resident after the effect is turned off.
            edgeOutputTexture = nil
        }
        guard canAllocateAdaptiveComputeAuxiliaryTextures(
            for: drawable,
            edgeEnabled: edgeEnabled
        ) else {
            releaseAdaptiveComputeAuxiliaryTextures()
            return false
        }
        
        guard let outputTexture = ensureComputeOutputTexture(for: drawable) else {
            releaseAdaptiveComputeAuxiliaryTextures()
            return false
        }

        let edgeTexture = edgeEnabled ? ensureEdgeOutputTexture(for: drawable) : nil
        
        // Set up temporal reprojection depth textures (ping-pong)
        guard let depthPair = ensureTemporalDepthTextures(for: drawable) else {
            if RENDERER_DEBUG { print("⚠️ Temporal textures unavailable; falling back to fragment rendering") }
            releaseAdaptiveComputeAuxiliaryTextures()
            return false
        }
        
        // Render each eye. Propagate encoder creation failures so the caller can
        // use the fragment path instead of presenting stale intermediate data.
        var edgeAppliedToEveryView = edgeEnabled && edgeTexture != nil
        for viewIndex in 0..<drawable.views.count {
            guard let renderExtent = encodeAdaptiveCompute(
                commandBuffer: commandBuffer,
                outputTexture: outputTexture,
                drawable: drawable,
                viewIndex: viewIndex,
                settingsSnapshot: settingsSnapshot,
                framePreparation: framePreparation,
                pipeline: computePipeline,
                prevDepthTexture: depthPair.read,
                curDepthTexture: depthPair.write,
                uniformBuffer: uniformBuffer,
                bufferContents: bufferContents
            ) else {
                releaseAdaptiveComputeAuxiliaryTextures()
                return false
            }
            if edgeAppliedToEveryView, let edgeTexture {
                let encoded = encodeEdgeDetection(
                    commandBuffer: commandBuffer,
                    sourceTexture: outputTexture,
                    destinationTexture: edgeTexture,
                    viewIndex: viewIndex,
                    // Only process the foveated physical region written by the
                    // raymarch kernel. Running this at the backing texture's native
                    // extent erased much of the governor's low-quality GPU saving.
                    renderWidth: renderExtent.x,
                    renderHeight: renderExtent.y,
                    uniformBuffer: uniformBuffer
                )
                edgeAppliedToEveryView = edgeAppliedToEveryView && encoded
            }
        }
        
        // Advance temporal state for next frame
        temporalDepthIndex = 1 - temporalDepthIndex  // Swap ping-pong
        temporalFrameCount += 1
        computeWarmStartGate.recordDepthWritten(settingsSnapshot)
        
        // Blit compute output to drawable for presentation
        blitComputeOutputToDrawable(
            commandBuffer: commandBuffer,
            drawable: drawable,
            useEdgeOutput: edgeAppliedToEveryView
        )
        
        return true
    }
    
    // ═══════════════════════════════════════════════════════════════════════════
    // PIPELINE COMPONENT PROFILER
    // Tests each part of the rendering pipeline to find bottlenecks
    // ═══════════════════════════════════════════════════════════════════════════
    
    /// Uniform layout for diagnostic kernel
    private struct DiagnosticUniformsLayout {
        var projectionMatrix: matrix_float4x4
        var viewMatrix: matrix_float4x4
        var inverseViewMatrix: matrix_float4x4
        var inverseProjectionMatrix: matrix_float4x4
        var resolution: SIMD2<Float>
        var time: Float
        var minDistance: Float
        var fractalScale: Float
        var foldingLimit: Float
        var sphereRadius: Float
        var fractalIterations: Int32
        var maxRaySteps: Int32
        var diagnosticMode: Int32
        var forceIterations: Int32
        var forceRaySteps: Int32
    }
    
    /// Trigger the pipeline profiler to run on next frame
    nonisolated func triggerProfiler() {
        shouldRunProfiler = true
    }
    
    /// Profile each component of your rendering pipeline.
    /// Runs GPU work on a background queue to avoid blocking the render thread.
    func profilePipelineComponents() {
        let settingsSnapshot = appModel.renderSettings.snapshot()
        let device = self.device
        let commandQueue = self.commandQueue
        
                guard let library = Renderer.bundledDefaultLibrary(device: device),
              let diagnosticFunc = library.makeFunction(name: "diagnosticKernel"),
              let diagnosticPipeline = try? device.makeComputePipelineState(function: diagnosticFunc) else {
            print("⚠️ Could not create diagnostic pipeline")
            return
        }
        
        guard let uniformBuffer = device.makeBuffer(length: 512, options: .storageModeShared) else {
            return
        }
        
        let testSize = 512
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: testSize, height: testSize,
            mipmapped: false
        )
        desc.usage = [.shaderWrite]
        desc.storageMode = .private
        
        guard let testTexture = device.makeTexture(descriptor: desc) else {
            return
        }
        
        let currentIters = settingsSnapshot.fractalIterations
        let currentSteps = settingsSnapshot.maxRaySteps
        let currentScale = settingsSnapshot.fractalScale
        let currentFold = settingsSnapshot.foldingLimit
        let currentSphere = settingsSnapshot.sphereRadius
        let currentMinDist = settingsSnapshot.minDistance
        
        // Run GPU profiler work on a background queue to avoid blocking the render thread.
        // All captured values are Sendable (value types, MTL objects).
        Task.detached(priority: .utility) {
            print("\n╔═══════════════════════════════════════════════════════════════╗")
            print("║        PIPELINE COMPONENT PROFILER                            ║")
            print("╠═══════════════════════════════════════════════════════════════╣")
            print("║  Iterations: \(currentIters), Steps: \(currentSteps), Scale: \(String(format: "%.2f", currentScale)), Fold: \(String(format: "%.2f", currentFold))  ║")
            print("╠═══════════════════════════════════════════════════════════════╣")
            
            let threadsPerGroup = MTLSize(width: 16, height: 16, depth: 1)
            let threadgroups = MTLSize(
                width: (testSize + 15) / 16,
                height: (testSize + 15) / 16,
                depth: 1
            )
            
            let modes: [(String, Int32)] = [
                ("Single Map() call (baseline)", 5),
                ("SDF raymarch only (no shading)", 0),
                ("SDF + 6-point normal", 1),
                ("Full shade (SDF + normal + light)", 2),
                ("100x Map() at fixed pos (iter cost)", 3),
                ("50x normal calc (normal cost)", 4),
            ]
            
            for (name, mode) in modes {
                var uniforms = DiagnosticUniformsLayout(
                    projectionMatrix: matrix_identity_float4x4,
                    viewMatrix: matrix_identity_float4x4,
                    inverseViewMatrix: matrix_identity_float4x4,
                    inverseProjectionMatrix: matrix_identity_float4x4,
                    resolution: SIMD2<Float>(Float(testSize), Float(testSize)),
                    time: 0,
                    minDistance: currentMinDist,
                    fractalScale: currentScale,
                    foldingLimit: currentFold,
                    sphereRadius: currentSphere,
                    fractalIterations: Int32(currentIters),
                    maxRaySteps: Int32(currentSteps),
                    diagnosticMode: mode,
                    forceIterations: 0,
                    forceRaySteps: 0
                )
                memcpy(uniformBuffer.contents(), &uniforms, MemoryLayout<DiagnosticUniformsLayout>.size)
                
                guard let cmdBuffer = commandQueue.makeCommandBuffer(),
                      let encoder = cmdBuffer.makeComputeCommandEncoder() else { continue }
                
                encoder.setComputePipelineState(diagnosticPipeline)
                encoder.setTexture(testTexture, index: 0)
                encoder.setBuffer(uniformBuffer, offset: 0, index: 0)
                encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerGroup)
                encoder.endEncoding()
                
                let startTime = CACurrentMediaTime()
                cmdBuffer.commit()
                await cmdBuffer.completed()
                let elapsed = (CACurrentMediaTime() - startTime) * 1000.0
                
                print("║  \(name.padding(toLength: 40, withPad: " ", startingAt: 0)) \(String(format: "%6.2f", elapsed))ms ║")
            }
            
            print("╚═══════════════════════════════════════════════════════════════╝\n")
        }
    }

}
