//
//  Renderer.swift
//  MetalProject
//
//  Created by MU on 18/11/24.
//

@preconcurrency import CompositorServices
import Metal
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
    var dynamicUniformBuffer: MTLBuffer
    var pipelineState: MTLRenderPipelineState
    var quadSharedPipelineState: MTLRenderPipelineState?  // Quad-shared raymarch (2x2 sharing)
    var depthState: MTLDepthStencilState
    
    // === UNIFIED PIPELINE CACHE ===
    // All specialized pipelines stored in a single cache with consistent key format.
    // Key format: "FI{iterations}_RS{raySteps}_N{0|1}_Q{0|1|2}[_QS]"
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
    var tileUniformBuffer: MTLBuffer?
    
    // Dedicated compute output texture (has .shaderWrite flag that drawable textures lack)
    var computeOutputTexture: MTLTexture?
    var computeOutputSize: SIMD2<Int> = .zero
    
    // ═══════════════════════════════════════════════════════════════════════════
    // TEMPORAL REPROJECTION STATE
    // Double-buffered depth textures store ray-t per pixel for reuse next frame.
    // Previous frame's depth + MVP lets us skip ~90% of fine raymarching steps
    // for pixels that didn't move much between frames.
    // ═══════════════════════════════════════════════════════════════════════════
    private var temporalDepthTextures: [MTLTexture?] = [nil, nil]  // ping-pong
    private var temporalDepthIndex: Int = 0                         // which is "current write"
    var previousViewProjMatrices: [matrix_float4x4] = [matrix_identity_float4x4, matrix_identity_float4x4]  // per eye
    private var temporalFrameCount: Int = 0                         // 0 = first frame, no reprojection
    private var temporalDepthSize: SIMD2<Int> = .zero

    // ═══════════════════════════════════════════════════════════════════════════
    // CUSTOM TAA (Temporal Anti-Aliasing)
    // MTLFXTemporalScaler is unavailable on visionOS; this provides equivalent
    // quality by accumulating sub-pixel jittered samples across frames using a
    // hand-rolled neighbourhood-variance-clamped exponential blend.
    // Engages automatically whenever MetalFX spatial upscaling is active.
    // ═══════════════════════════════════════════════════════════════════════════
    var taaManager: VisionOSTAAManager?
    // Halton sequence index for sub-pixel jitter (advanced each frame).
    var taaHaltonIndex: UInt32 = 0
    // Current frame's jitter in input-pixel units, baked into the fragment uniforms.
    var taaCurrentJitter: SIMD2<Float> = .zero

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
    var pendingScreenshotContinuation: CheckedContinuation<Data?, Never>?
    var shouldCaptureScreenshot: Bool = false
    
    // Pipeline profiling trigger
    nonisolated(unsafe) var shouldRunProfiler: Bool = false

    // === BUDDHABROT VOLUME RENDERER ===
    // Lazy-initialized when the user switches to Buddhabrot mode.
    // Owns density buffers, 3D volume texture, and stereo ray march pipeline.
    var buddhabrotRenderer: BuddhabrotRenderer?

    let inFlightSemaphore = DispatchSemaphore(value: maxBuffersInFlight)

    var uniformBufferOffset = 0

    var uniformBufferIndex = 0

    var uniforms: UnsafeMutablePointer<UniformsArray>

    let rasterSampleCount: Int = 1
    let mtlVertexDescriptor: MTLVertexDescriptor  // Stored for pipeline building
    var hasLoggedFoveationAvailability = false
    var hasLoggedWorldTrackingWarning = false
    var hasLoggedDeviceAnchorInfo = false

#if canImport(MetalFX)
    var metalFXManager: MetalFXManager?
    var metalFXFence: MTLFence?
    var lastMetalFXInputSize: SIMD2<Int> = .zero
    var lastMetalFXOutputSize: SIMD2<Int> = .zero
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

    // One-shot log guard for visionOS 26+ queryDrawables() candidate sizes.
    var hasLoggedDrawableQualityOptions: Bool = false

    private var lastFPSUpdateTime: TimeInterval = 0
    var lastHandTrackingUpdateTime: TimeInterval = 0  // Throttle hand UI updates
    // Hand-tracking dispatch coordination between the render loop (Renderer actor)
    // and the per-frame @MainActor Task that processes gestures. A single Mutex
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
    let layerRenderer: LayerRenderer
    let appModel: AppModel

    init?(_ layerRenderer: LayerRenderer, appModel: AppModel) {
        self.layerRenderer = layerRenderer
        self.device = layerRenderer.device
        guard let queue = self.device.makeCommandQueue() else {
            if RENDERER_DEBUG { print("❌ Failed to create command queue") }
            return nil
        }
        self.commandQueue = queue
        self.appModel = appModel
        
        // Initialize UI update coordinator to prevent UI blocking during heavy rendering
        self.uiUpdateCoordinator = UIUpdateCoordinator(appModel: appModel)

        // Initialize parameter update coordinator to batch smoothing/animation updates
        self.parameterUpdateCoordinator = ParameterUpdateCoordinator(appModel: appModel)

        // Pre-compute constant rotation matrix (never changes)
        self.cachedRotationMatrix = matrix4x4_rotation(radians: -.pi/2, axis: [0, 1, 0])

        let device = self.device

        let uniformBufferSize = alignedUniformsSize * maxBuffersInFlight

        guard let uniformBuffer = self.device.makeBuffer(length: uniformBufferSize,
                                                          options: [MTLResourceOptions.storageModeShared]) else {
            if RENDERER_DEBUG { print("❌ Failed to create uniform buffer") }
            return nil
        }
        self.dynamicUniformBuffer = uniformBuffer

        self.dynamicUniformBuffer.label = "UniformBuffer"

        uniforms = UnsafeMutableRawPointer(dynamicUniformBuffer.contents()).bindMemory(to:UniformsArray.self, capacity:1)

        let mtlVertexDescriptor = Renderer.buildMetalVertexDescriptor()
        self.mtlVertexDescriptor = mtlVertexDescriptor

        do {
            pipelineState = try Renderer.buildRenderPipelineWithDevice(device: device,
                                                                       layerRenderer: layerRenderer,
                                                                       rasterSampleCount: rasterSampleCount,
                                                                       mtlVertexDescriptor: mtlVertexDescriptor)
        } catch {
            if RENDERER_DEBUG { print("❌ Unable to compile render pipeline state: \(error)") }
            return nil
        }
        
        // Build quad-shared pipeline (uses SIMD quad operations for 2x2 pixel grouping)
        do {
            quadSharedPipelineState = try Renderer.buildRenderPipelineWithDevice(device: device,
                                                                                 layerRenderer: layerRenderer,
                                                                                 rasterSampleCount: rasterSampleCount,
                                                                                 mtlVertexDescriptor: mtlVertexDescriptor,
                                                                                 vertexFunctionName: "vertexShader",
                                                                                 fragmentFunctionName: "fragmentShaderQuadShared")
            if RENDERER_DEBUG { print("✓ Quad-shared pipeline ready (2x2 SIMD grouping)") }
        } catch {
            if RENDERER_DEBUG { print("⚠️ Quad-shared pipeline failed: \(error)") }
            quadSharedPipelineState = nil
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
                fragmentFunctionName: "formatConversionFragmentStereo"
            )
            metalFXDepthResolvePipeline = try Renderer.buildRenderPipelineWithDevice(
                device: device,
                layerRenderer: layerRenderer,
                rasterSampleCount: rasterSampleCount,
                mtlVertexDescriptor: postProcessVertexDescriptor,
                colorFormat: .invalid,
                vertexFunctionName: "formatConversionVertexStereo",
                fragmentFunctionName: "depthUpscaleFragmentStereo"
            )
            // Phase 2.7: Merged single-encoder resolve. Optional — if it fails to
            // build (e.g. driver mismatch) we fall back to the two-encoder path.
            metalFXMergedResolvePipeline = try? Renderer.buildRenderPipelineWithDevice(
                device: device,
                layerRenderer: layerRenderer,
                rasterSampleCount: rasterSampleCount,
                mtlVertexDescriptor: postProcessVertexDescriptor,
                vertexFunctionName: "formatConversionVertexStereo",
                fragmentFunctionName: "formatConversionFragmentStereoMerged"
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

        // Custom TAA — initialise best-effort; nil means TAA is skipped this session.
        taaManager = try? VisionOSTAAManager(device: device)
        if RENDERER_DEBUG { print(taaManager != nil ? "✓ TAA manager ready" : "⚠️ TAA unavailable (taaResolve kernel not found)") }
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

        // === BUILD SPECIALIZED PIPELINES FOR QUALITY PRESETS ===
        // Key optimization: Map() inner loop (50-100+ calls per pixel) can be fully unrolled
        // when FC_FRACTAL_ITERATIONS is defined as a compile-time constant.
        // Note: The outer raymarch loop does NOT unroll due to runtime quality scaling.
        //
        // Quality presets compile out neon for maximum performance.
        // For features like neon, use saved presets which build fully-specialized pipelines.
        
        let qualityPresets = QualityPreset.allCases
        
        var pipelineCount = 0
        if RENDERER_DEBUG { print("Building specialized pipelines for \(qualityPresets.count) quality presets...") }
        
        for preset in qualityPresets {
            let iterCount = preset.fractalIterations
            let raySteps = preset.raySteps
            let config = FunctionConstantConfig.forQualityPreset(preset)
            let constants = config.toMTLConstants()
            
            // Build unified cache key (quality presets have E=0, N=0)
            let qualityMode: Int = iterCount <= 7 ? 2 : (iterCount <= 9 ? 1 : 0)
            let colorIterations = config.colorIterations ?? Int32(iterCount)
            let unifiedKey = "FI\(iterCount)_RS\(raySteps)_N0_Q\(qualityMode)_CI\(colorIterations)"
            
            // Standard pipeline
            if let pipeline = try? Renderer.buildRenderPipelineWithDevice(
                device: device,
                layerRenderer: layerRenderer,
                rasterSampleCount: rasterSampleCount,
                mtlVertexDescriptor: mtlVertexDescriptor,
                functionConstants: constants
            ) {
                pipelineCache[unifiedKey] = pipeline
                pipelineCount += 1
                if RENDERER_DEBUG { print("  ✓ \(preset.rawValue): FI=\(iterCount), RS=\(raySteps) [\(unifiedKey)]") }
            }
            
            // Quad-shared pipeline
            if let pipeline = try? Renderer.buildRenderPipelineWithDevice(
                device: device,
                layerRenderer: layerRenderer,
                rasterSampleCount: rasterSampleCount,
                mtlVertexDescriptor: mtlVertexDescriptor,
                fragmentFunctionName: "fragmentShaderQuadShared",
                functionConstants: constants
            ) {
                pipelineCache[unifiedKey + "_QS"] = pipeline
            }
        }
        if RENDERER_DEBUG { print("✓ Built \(pipelineCount) specialized pipelines (\(pipelineCache.count) total with quad-shared)") }

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
            
            // === COMPUTE PIPELINE CACHE ===
            // Build specialized compute pipelines for each quality preset.
            // Each pipeline bakes FC_FRACTAL_ITERATIONS / FC_SHADOW_ITERATIONS / FC_MAX_RAY_STEPS
            // so the Map() inner loop is fully unrolled per iteration count.
            if RENDERER_DEBUG { print("Building specialized compute pipelines for \(QualityPreset.allCases.count) quality presets...") }
            var computeBuilt = 0
            for preset in QualityPreset.allCases {
                let fi = Int32(preset.fractalIterations)
                let rs = Int32(preset.raySteps)
                let si = Int32(max(preset.fractalIterations - 2, 2))
                let key = "FI\(fi)_RS\(rs)"
                
                if let pipeline = Renderer.buildComputePipeline(device: device, library: library, kernelName: "adaptiveHierarchical8x8",
                                                       fractalIterations: fi, shadowIterations: si, maxRaySteps: rs) {
                    computePipelineCache[key] = pipeline
                    computeBuilt += 1
                    if RENDERER_DEBUG { print("  ✓ Compute \(preset.rawValue): FI=\(fi), RS=\(rs) [\(key)]") }
                }
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
                adaptiveHierarchicalPipeline8x8 = try device.makeComputePipelineState(function: kernel8x8)
            }
            if RENDERER_DEBUG { print("✓ Built \(computeBuilt) specialized compute pipelines + 1 generic fallback") }
            
            // Uniform buffer for tile compute (one per eye)
            let tileUniformSize = MemoryLayout<TileUniforms>.stride * 2
            tileUniformBuffer = device.makeBuffer(length: tileUniformSize, options: .storageModeShared)
            tileUniformBuffer?.label = "TileUniforms"
            
            if RENDERER_DEBUG { print("✓ Tile-based compute pipeline ready (adaptive 8x8)") }
        } catch {
            if RENDERER_DEBUG { print("⚠️ Failed to create tile compute pipelines: \(error)") }
            adaptiveHierarchicalPipeline8x8 = nil
        }
        
        worldTracking = WorldTrackingProvider()
        handTracking = HandTrackingProvider()
        arSession = ARKitSession()
        
        // Defer actor-isolated setup to after init completes
        // These methods access actor-isolated properties and must run on this actor
        setupTask = Task { [weak self] in
            guard let self else { return }

            // Setup screenshot capture pipeline
            await self.setupScreenshotCapture()
            guard !Task.isCancelled else { return }

            // === RESIDENCY SET ===
            // Pre-validate resource residency for reduced per-frame overhead
            await self.setupResidencySet()
            guard !Task.isCancelled else { return }

            // === PRESET PIPELINE PRECOMPILATION ===
            // Build specialized pipelines for saved presets to avoid hitches when loading
            await self.precompilePresetPipelines()
            guard !Task.isCancelled else { return }

            await MainActor.run {
                self.appModel.rendererStartupWarmupComplete = true
            }
        }
    }

    deinit {
        setupTask?.cancel()
        handTrackingDispatchTask?.cancel()
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
        let renderLoopTask = Task(executorPreference: RendererTaskExecutor.shared) {
            guard let renderer = Renderer(layerRenderer, appModel: appModel) else {
                await MainActor.run {
                    appModel.immersiveSpaceState = .closed
                    appModel.clearRendererHandlers(renderLoopID: renderLoopID)
                }
                return
            }
            
            // Setup screenshot capture handler
            await MainActor.run {
                appModel.captureScreenshotHandler = {
                    await renderer.captureScreenshot()
                }
                
                // Setup pipeline preparation handler
                // Called before loading a preset to ensure the specialized pipeline is ready
                appModel.preparePipelineHandler = { preset in
                    // Build both standard and quad-shared variants
                    _ = await renderer.getPipeline(forPreset: preset, useQuadShared: false)
                    _ = await renderer.getPipeline(forPreset: preset, useQuadShared: true)
                    await renderer.prewarmComputePipeline(forPreset: preset)
                }
                
                // Setup pipeline preparation for specific iteration/ray step values
                // Called when sliders change to pre-compile the needed pipeline
                appModel.preparePipelineForValuesHandler = { iterations, raySteps in
                    // Pre-build render pipelines
                    _ = await renderer.getPipeline(forIterations: iterations, raySteps: raySteps, useQuadShared: false)
                    _ = await renderer.getPipeline(forIterations: iterations, raySteps: raySteps, useQuadShared: true)
                    // Pre-build matching compute pipeline so tileSize=8 path is ready
                    _ = await renderer.selectComputePipeline(fractalIterations: iterations, maxRaySteps: raySteps)
                }
                
                // Setup pipeline profiler handler
                appModel.triggerProfilerHandler = {
                    renderer.triggerProfiler()
                }

                // Setup custom-shader (.threshfx) activation handler.
                appModel.activateEmbeddedFormulaHandler = { formula in
                    try await renderer.activateEmbeddedFormula(formula)
                }
            }

            // If an embedded formula was already registered (e.g. via
            // __lastState__ restore that ran before the handler was
            // installed), activate it now so the renderer compiles the
            // custom MTLLibrary instead of falling back to the default
            // pipeline and rendering fog/sky only.
            let pendingFormula = await MainActor.run { appModel.activeEmbeddedFormula }
            if let pending = pendingFormula {
                customSceneDiagnostic("🔬 [CSDiag] Handler ready — running deferred activation for '\(pending.name)' hash=\(pending.shortHash)")
                do {
                    try await renderer.activateEmbeddedFormula(pending)
                } catch {
                    customSceneDiagnostic("🔬 [CSDiag] ❌ Deferred activation failed: \(error)")
                }
            }

            guard !Task.isCancelled else {
                await MainActor.run {
                    appModel.clearRendererHandlers(renderLoopID: renderLoopID)
                }
                return
            }
            
            await renderer.startARSession()

            guard !Task.isCancelled else {
                await MainActor.run {
                    appModel.clearRendererHandlers(renderLoopID: renderLoopID)
                }
                return
            }

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

    /// Cached Metal library for static pipeline builds — avoids redundant `makeDefaultLibrary()` calls.
    nonisolated(unsafe) static var _cachedLibrary: MTLLibrary?

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
    var lastSelectQS: Bool = false
    var lastSelectNeon: Bool = false
    var lastSelectColorIterations: Int32 = -1
    var lastSelectFT: Int32 = -1
    var lastSelectPower: Int32?
    var lastSelectCustomHash: String?
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

        frame.startUpdate()

        // Perform frame independent work

        frame.endUpdate()

        guard let timing = frame.predictTiming() else { return }
        let clockWaitStart = CACurrentMediaTime()
        LayerRenderer.Clock().wait(until: timing.optimalInputTime)
        frameBreakdown.clockWaitMs = (CACurrentMediaTime() - clockWaitStart) * 1000.0

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            if RENDERER_DEBUG { print("⚠️ Failed to create command buffer; skipping frame") }
            return
        }
        
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
            guard let selectedDrawable = selectDrawable(from: drawables) else { return }
            drawable = selectedDrawable
        } else {
            guard let legacyDrawable = frame.queryDrawable() else { return }
            drawable = legacyDrawable
        }

        // Wait for a buffer to become available. With maxBuffersInFlight=2,
        // this allows CPU/GPU pipelining while preventing frame accumulation.
        // The 2-buffer setup prevents the 45fps vsync lock that occurred with 1 buffer.
        // Timeout at 100ms (~10 FPS floor) to detect GPU stalls instead of hanging forever.
        let inFlightWaitStart = CACurrentMediaTime()
        let waitResult = inFlightSemaphore.wait(timeout: .now() + .milliseconds(100))
        frameBreakdown.inFlightWaitMs = (CACurrentMediaTime() - inFlightWaitStart) * 1000.0
        if waitResult == .timedOut {
            // GPU is severely behind — present an empty frame to satisfy CompositorServices,
            // then skip rendering to avoid accumulating latency.
            if RENDERER_DEBUG { print("⚠️ GPU stall detected: inFlightSemaphore timed out (100ms)") }
            frame.startSubmission()
            defer { frame.endSubmission() }
            drawable.encodePresent(commandBuffer: commandBuffer)
            commandBuffer.commit()
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

        let presentationTime = drawable.frameTiming.presentationTime
        let time = LayerRenderer.Clock.Instant.epoch.duration(to: presentationTime).timeInterval
        
        // Only query device anchor if world tracking is actually running
        let deviceAnchor: DeviceAnchor?
        if worldTracking.state == .running {
            deviceAnchor = worldTracking.queryDeviceAnchor(atTimestamp: time)
        } else {
            deviceAnchor = nil
        }

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
            // Also piggybacks device head height for posture detection (world-space Y, ~2 Hz).
            let headY = deviceAnchor.map { Float($0.originFromAnchorTransform.columns.3.y) }
            uiUpdateCoordinator?.scheduleUIUpdate(fps: updatedFPS, headHeightMeters: headY, currentTime: time)
            
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
        settings.updateColorSchemeTransition(deltaTime: cachedDeltaTime)
        frameBreakdown.settingsUpdateMs = (CACurrentMediaTime() - settingsUpdateStart) * 1000.0
        
        // === AUDIO PIPELINE ===
        // Auto-detect active sources: use mic FFT, Spotify beat sync, and/or
        // Apple Music BPM-based synthesis — blend whatever is available.
        let backgroundCpuStart = CACurrentMediaTime()
        let isAudioMode = settings.lightingMode == .audioReactive || settings.lightingMode == .visualizer || settings.fractalAudioReactiveEnabled
        let hasActiveAudioSources = appModel.audioAnalyzer.isCapturing || appModel.appleMusicManager.isActive
        let shouldUpdateAnimation = settings.isAnimationPlaying
        
        // === PARAMETER UPDATE COORDINATION ===
        // Use ParameterUpdateCoordinator to batch animation/audio updates
        // Prevents per-frame MainActor blocking that causes UI lag during heavy rendering
        parameterUpdateCoordinator?.scheduleParameterUpdates(
            shouldUpdateAnimation: shouldUpdateAnimation,
            shouldUpdateAudio: isAudioMode && hasActiveAudioSources,
            deltaTime: animDelta,
            currentTime: time
        )
        
        if isAudioMode {
            let mic = appModel.audioAnalyzer
            let appleMusicManager = appModel.appleMusicManager
            // Auto-detect: use whatever sources are currently active
            let micActive = mic.isCapturing
            let appleMusicActive = appleMusicManager.isActive
            
            // Sensitivity multipliers from user settings
            let bassSens = settings.bassSensitivity
            let midSens = settings.midSensitivity
            let trebleSens = settings.trebleSensitivity
            let beatSens = settings.beatSensitivity

            // Collect active source levels, then blend proportionally
            var totalBass: Float = 0, totalMid: Float = 0, totalTreble: Float = 0
            var totalBeat: Float = 0, totalLevel: Float = 0
            var sourceCount: Float = 0

            if micActive {
                totalBass += mic.bassLevel
                totalMid += mic.midLevel
                totalTreble += mic.trebleLevel
                totalBeat = max(totalBeat, mic.peakLevel * 0.7)
                totalLevel += mic.level
                sourceCount += 1
            }
            if appleMusicActive {
                totalBass += appleMusicManager.bassLevel
                totalMid += appleMusicManager.midLevel
                totalTreble += appleMusicManager.trebleLevel
                totalBeat = max(totalBeat, appleMusicManager.beatIntensity)
                totalLevel += appleMusicManager.overallLevel
                sourceCount += 1
            }

            if sourceCount > 0 {
                let inv = 1.0 / sourceCount
                // Audio state writes: these feed PrecomputedAudio (CPU-side aggregate),
                // NOT per-pixel shader values. They stay as direct RenderSettings writes
                // because they aren't scalar parameters eligible for layer-stack dispatch.
                settings.bassLevel = min(1.0, totalBass * inv * bassSens)
                settings.midLevel = min(1.0, totalMid * inv * midSens)
                settings.trebleLevel = min(1.0, totalTreble * inv * trebleSens)
                settings.beatIntensity = min(1.0, totalBeat * beatSens)
                settings.audioLevel = totalLevel * inv
            }

            // Music drives fractal geometry AND effects (Fractal Forge-inspired).
            // The aggregation above produced the per-band levels; the shared engine
            // applies damping, response curves, the LFO overlay, and dispatch.
            if settings.fractalAudioReactiveEnabled {
                let bandLevels = BandLevels(bass: settings.bassLevel,
                                            mid: settings.midLevel,
                                            treble: settings.trebleLevel,
                                            beat: settings.beatIntensity,
                                            overall: settings.audioLevel)
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
        let framePreparation = self.updateGameState(drawable: drawable, settingsSnapshot: settingsSnapshot)
        frameBreakdown.updateGameStateMs = (CACurrentMediaTime() - updateGameStateStart) * 1000.0

        // TAA: Advance the Halton sub-pixel jitter each frame and bake it into the
        // fragment-shader uniforms so each frame's render is offset by a different
        // fraction of a pixel. TAA accumulates these across frames for free SSAA.
        #if canImport(MetalFX)
        if taaManager != nil, settingsSnapshot.resolutionScale < 0.999 {
            taaHaltonIndex = taaHaltonIndex &+ 1
            let jx = Self.halton(taaHaltonIndex, base: 2) - 0.5
            let jy = Self.halton(taaHaltonIndex, base: 3) - 0.5
            taaCurrentJitter = SIMD2<Float>(jx, jy)
            // Patch jitterOffset in the already-written uniforms (UnsafeMutablePointer<UniformsArray>).
            uniforms[uniformBufferIndex].uniforms.0.jitterOffset = taaCurrentJitter
            uniforms[uniformBufferIndex].uniforms.1.jitterOffset = taaCurrentJitter
            // Reset TAA history whenever geometry is unstable (parameter changes, gestures).
            if settingsSnapshot.geometryState != .stable || settingsSnapshot.isGeometryGestureActive {
                taaManager?.requestReset()
            }
        } else {
            taaCurrentJitter = .zero
        }
        #endif

        // Begin submission only once CPU updates are complete.
        // Every path from here MUST call drawable.encodePresent() before endSubmission() fires.
        frame.startSubmission()
        defer { frame.endSubmission() }

        let renderEncodeStart = CACurrentMediaTime()

        // ═══════════════════════════════════════════════════════════════════════
        // BUDDHABROT VOLUME RENDER PATH
        // When in Buddhabrot mode, skip fractal raymarching entirely and instead
        // run the 3D volume accumulation + render pipeline.
        // ═══════════════════════════════════════════════════════════════════════
        if appModel.runtimeViewModeForRenderer == .buddhabrot {
            // Lazy-init the Buddhabrot renderer on first use
            if buddhabrotRenderer == nil {
                buddhabrotRenderer = BuddhabrotRenderer(
                    device: device,
                    layerRenderer: layerRenderer,
                    settings: appModel.buddhabrotSettings
                )
            }
            
            if let bbrot = buddhabrotRenderer {
                let bbrotTime = framePreparation.frameTime
                let rendered = bbrot.renderFrame(
                    commandBuffer: commandBuffer,
                    drawable: drawable,
                    time: bbrotTime,
                    settingsSnapshot: settingsSnapshot
                )
                
                if rendered {
                    // Buddhabrot frames don't write fragment depth — next
                    // fragment frame must not warm-start from stale history.
                    warmStartGate.invalidate()
                    drawable.encodePresent(commandBuffer: commandBuffer)
                    shouldSignalInFlightSemaphore = false
                    commandBuffer.commit()
                    return
                }
            }
            // Fall through to normal rendering if Buddhabrot failed
        }

        let framePath = selectFramePath(settingsSnapshot: settingsSnapshot)
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
                drawable.encodePresent(commandBuffer: commandBuffer)
                shouldSignalInFlightSemaphore = false
                commandBuffer.commit()
                return  // Skip fragment-based rendering
            }
        } else {
            useAdaptiveCompute = false
        }

        // ═══════════════════════════════════════════════════════════════════════
        // FRAGMENT RENDER PATH (with optional MetalFX spatial upscale)
        //
        // When resolutionScale < 1.0 AND MetalFX is available, render the fragment
        // pass into MetalFX's private low-res input texture, then spatially
        // upscale into the drawable. MetalFX on visionOS supports spatial
        // upscaling only (temporal is unsupported), so this is the only MetalFX
        // codepath we need. Adaptive-compute and Buddhabrot paths intentionally
        // skip MetalFX — they either have their own quality controls (compute
        // tile cascade) or don't benefit from spatial upscaling of a volume
        // integration result (Buddhabrot).
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
            uniforms[uniformBufferIndex].uniforms.0.renderResolution = res
            uniforms[uniformBufferIndex].uniforms.1.renderResolution = res
            uniforms[uniformBufferIndex].uniforms.0.warmStartEnabled = warmStartOK
            uniforms[uniformBufferIndex].uniforms.1.warmStartEnabled = warmStartOK
        }
        #endif

        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: fragmentPassPlan.renderPassDescriptor) else {
            if RENDERER_DEBUG { print("⚠️ Failed to create render encoder; skipping frame") }
            drawable.encodePresent(commandBuffer: commandBuffer)
            shouldSignalInFlightSemaphore = false
            commandBuffer.commit()
            return
        }

        renderEncoder.label = "Primary Render Encoder"

        renderEncoder.pushDebugGroup("Draw Box")

        renderEncoder.setCullMode(.front)

        renderEncoder.setFrontFacing(.counterClockwise)

        // Select pipeline based on deterministic frame path selection
        let useQuadShared: Bool
        switch framePath {
        case .adaptiveCompute:
            useQuadShared = false
        case .fragment(let quad):
            useQuadShared = quad
        }
        
        // Get current iteration count for specialized pipeline selection
        let currentIterations = settingsSnapshot.fractalIterations
        let currentRaySteps = settingsSnapshot.maxRaySteps
        
        // Detect neon mode from colorSchemeParams.neonIntensity
        let isNeonMode = settingsSnapshot.colorSchemeParams.neonIntensity > 0
        
        // Use specialized pipeline with fixed iteration count
        // This enables Map() loop auto-unrolling via function constants
        let selectedPipeline = selectPipeline(
            forIterations: currentIterations,
            raySteps: currentRaySteps,
            useQuadShared: useQuadShared,
            neonMode: isNeonMode,
            request: RenderPipelineRequest(
                fractalType: settingsSnapshot.fractalType,
                formulaParams: settingsSnapshot.formulaParams,
                colorIterations: settingsSnapshot.colorIterations
            )
        )
        renderEncoder.setRenderPipelineState(selectedPipeline)

        renderEncoder.setDepthStencilState(depthState)

        renderEncoder.setVertexBuffer(dynamicUniformBuffer, offset:uniformBufferOffset, index: BufferIndex.uniforms.rawValue)
        
        // Also bind uniforms buffer for fragment shader since it now needs access to uniforms
        renderEncoder.setFragmentBuffer(dynamicUniformBuffer, offset:uniformBufferOffset, index: BufferIndex.uniforms.rawValue)

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
        
        frameBreakdown.renderPathEncodeMs = (CACurrentMediaTime() - renderEncodeStart) * 1000.0

        let cpuEncodeMs = (CACurrentMediaTime() - cpuEncodeStart) * 1000.0
        let frameTimeSeconds = Double(cachedDeltaTime)
        let logTime = time
        let viewCount = drawable.views.count
        let drawableWidth = drawable.colorTextures[0].width
        let drawableHeight = drawable.colorTextures[0].height
        let frameBreakdownSnapshot = frameBreakdown
        commandBuffer.addCompletedHandler { [weak self] cb in
            let gpuMs: Double?
            if cb.gpuEndTime > cb.gpuStartTime {
                gpuMs = (cb.gpuEndTime - cb.gpuStartTime) * 1000.0
            } else {
                gpuMs = nil
            }
            guard let self else { return }
            Task {
                await self.recordFramePerf(
                    nowTime: logTime,
                    frameTimeSeconds: frameTimeSeconds,
                    cpuEncodeMs: cpuEncodeMs,
                    gpuMs: gpuMs,
                    frameBreakdown: frameBreakdownSnapshot,
                    settingsSnapshot: settingsSnapshot,
                    useAdaptiveCompute: useAdaptiveCompute,
                    viewCount: viewCount,
                    drawableWidth: drawableWidth,
                    drawableHeight: drawableHeight
                )
            }
        }

        drawable.encodePresent(commandBuffer: commandBuffer)

        shouldSignalInFlightSemaphore = false
        commandBuffer.commit()
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
    ) {
        guard let pipeline = pipeline ?? adaptiveHierarchicalPipeline8x8 else {
            if RENDERER_DEBUG { print("⚠️ Adaptive compute pipeline not available") }
            return
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
        
        let scaleCorrectedBubbleRadius = settingsSnapshot.safetyBubbleRadius / max(framePreparation.effectiveScale, 0.001)
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
        
        var tileUniforms = TileUniforms(
            invViewMatrix: inverseModelView,  // Use inverse MODEL-VIEW, not just inverse view!
            invProjMatrix: projection.inverse,
            cameraPos: cameraPos,
            time: framePreparation.frameTime,
            resolution: SIMD2<Float>(Float(viewportWidth), Float(viewportHeight)),
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
            foldingLimit: settingsSnapshot.foldingLimit,
            glowIntensity: framePreparation.animatedGlow,
            colorMix: framePreparation.animatedColorMix,
            fractalIterations: Int32(settingsSnapshot.fractalIterations),
            colorIterations: Int32(settingsSnapshot.colorIterations),
            maxRaySteps: Int32(settingsSnapshot.maxRaySteps),
            maxViewDistance: framePreparation.maxViewDistance,
            eyeIndex: UInt32(viewIndex),
            debugHierarchical: settingsSnapshot.debugHierarchical ? 1 : 0,
            limitFlash: settingsSnapshot.limitFlash,
            fractalType: settingsSnapshot.fractalType.rawValue,
            lightingSoftness: settingsSnapshot.lightingSoftness,
            sphericalInversionMode: settingsSnapshot.sphericalInversionMode.rawValue,
            sphericalInversionRadius: settingsSnapshot.sphericalInversionRadius,
            // === GMT-FRACTALS OPTIMIZATIONS ===
            stepMultiplier: settingsSnapshot.stepMultiplier,
            boundingSphereRadius: 0.0,  // Disabled: Mandelbox extent varies with minDistance/scale; needs dynamic radius
            blendFactor: settingsSnapshot.isGeometryGestureActive ? 1.0 : (settingsSnapshot.geometryState == .stable ? 0.1 : 0.5),
            springDisplacementX: settingsSnapshot.springDisplacement.x,
            springDisplacementY: settingsSnapshot.springDisplacement.y,
            springDisplacementZ: settingsSnapshot.springDisplacement.z,
            springStretch: simd_length(settingsSnapshot.springDisplacement),
            springAnchorNDC: SIMD2<Float>(0.7, -0.7),  // Bottom-right corner in NDC
            springVisible: (settingsSnapshot.springActive || simd_length(settingsSnapshot.springDisplacement) > 0.001) ? 1 : 0,
            springRestRadius: 0.06,
            jitterOffset: .zero,
            temporalReprojectionEnabled: temporalFrameCount > 0 ? 1 : 0,
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
            colorScheme: colorSchemeParams
        )
        
        // Copy uniforms to buffer (pointer cached by caller across both eyes)
        let uniformOffset = MemoryLayout<TileUniforms>.stride * viewIndex
        memcpy(bufferContents.advanced(by: uniformOffset), &tileUniforms, MemoryLayout<TileUniforms>.size)
        
        // Create compute encoder
        guard let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
            if RENDERER_DEBUG { print("⚠️ Failed to create compute encoder") }
            return
        }
        
        computeEncoder.label = viewIndex == 0 ? "Adaptive Compute - Eye 0" : "Adaptive Compute - Eye 1"
        computeEncoder.setComputePipelineState(pipeline)
        computeEncoder.setBuffer(uniformBuffer, offset: uniformOffset, index: 0)
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
            width: (viewportWidth + tileSize - 1) / tileSize,
            height: (viewportHeight + tileSize - 1) / tileSize,
            depth: 1
        )
        
        computeEncoder.dispatchThreadgroups(threadgroupsPerGrid, threadsPerThreadgroup: threadgroupSize)
        computeEncoder.endEncoding()
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
        computeOutputSize = SIMD2(width, height)
        
        // Residency update deferred to renderWithAdaptiveCompute() for batching
        
        if RENDERER_DEBUG { print("📐 Created compute output texture: \(width)×\(height) × \(viewCount) layers") }
        return texture
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
        temporalDepthSize = SIMD2(width, height)
        temporalFrameCount = 0  // Reset — first frame has no valid previous data
        
        // Residency update deferred to renderWithAdaptiveCompute() for batching
        
        if RENDERER_DEBUG { print("📐 Created temporal depth textures: \(width)×\(height) × \(viewCount) layers") }
        return (read: tex0, write: tex0)  // First frame: read=write (will be marked invalid)
    }

    /// Copies compute output texture to drawable using blit encoder
    private func blitComputeOutputToDrawable(
        commandBuffer: MTLCommandBuffer,
        drawable: LayerRenderer.Drawable
    ) {
        guard let sourceTexture = computeOutputTexture else { return }
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

            // Safety: Metal validation asserts if we copy outside destination.
            let copyWidth = min(sourceTexture.width, destinationTexture.width)
            let copyHeight = min(sourceTexture.height, destinationTexture.height)
            
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
        
        guard computePipeline != nil else { return false }
        guard let uniformBuffer = tileUniformBuffer else { return false }
        let bufferContents = uniformBuffer.contents()
        
        // Track textures created this frame for batched residency update
        let prevComputeOutput = computeOutputTexture
        let prevDepth0 = temporalDepthTextures[0]
        
        guard let outputTexture = ensureComputeOutputTexture(for: drawable) else {
            return false
        }
        
        // Set up temporal reprojection depth textures (ping-pong)
        guard let depthPair = ensureTemporalDepthTextures(for: drawable) else {
            if RENDERER_DEBUG { print("⚠️ Temporal textures unavailable; falling back to fragment rendering") }
            return false
        }
        
        // Batch residency set updates for any newly created textures (single commit)
        var newTextures: [MTLTexture] = []
        if computeOutputTexture !== prevComputeOutput { newTextures.append(outputTexture) }
        if temporalDepthTextures[0] !== prevDepth0 {
            newTextures.append(contentsOf: temporalDepthTextures.compactMap { $0 })
        }
        if !newTextures.isEmpty { updateResidencySetForComputeTextures(newTextures) }
        
        // Render each eye
        for viewIndex in 0..<drawable.views.count {
            encodeAdaptiveCompute(
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
            )
        }
        
        // Advance temporal state for next frame
        temporalDepthIndex = 1 - temporalDepthIndex  // Swap ping-pong
        temporalFrameCount += 1
        
        // Blit compute output to drawable for presentation
        blitComputeOutputToDrawable(commandBuffer: commandBuffer, drawable: drawable)
        
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

    // Radical-inverse Halton low-discrepancy sequence for sub-pixel TAA jitter.
    // Shared by both the compute path (RaymarchRenderView) and this renderer.
    static func halton(_ index: UInt32, base: UInt32) -> Float {
        var result: Float = 0
        var fraction: Float = 1
        var i = index
        while i > 0 {
            fraction /= Float(base)
            result += fraction * Float(i % base)
            i /= base
        }
        return result
    }
}
