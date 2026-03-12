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
    var lastSelectedComputePipeline: MTLComputePipelineState?
    
    // === UI UPDATE COORDINATION ===
    /// Coordinates UI updates without blocking MainActor during heavy rendering
    private(set) var uiUpdateCoordinator: UIUpdateCoordinator?

    /// Coordinates parameter smoothing and animation updates without blocking MainActor
    private(set) var parameterUpdateCoordinator: ParameterUpdateCoordinator?

    // Cached default Metal library — avoids device.makeDefaultLibrary() on every compute cache miss
    var cachedDefaultLibrary: MTLLibrary?
    
    // Cached constant matrices (computed once, reused every frame)
    let cachedRotationMatrix: matrix_float4x4
    
    // === FRAME-LEVEL CACHED VALUES ===
    // Computed once in updateGameState(), reused in encodeAdaptiveCompute() per eye.
    // Eliminates redundant makePrecomputedFractal/Lighting + model matrix computation.
    var cachedFrameTime: Float = 0
    var cachedPrecomputedFractal: PrecomputedFractalParams = PrecomputedFractalParams()
    var cachedPrecomputedLighting: PrecomputedLighting = PrecomputedLighting()
    var cachedPrecomputedAudio: PrecomputedAudio = PrecomputedAudio()
    var cachedPrecomputedFog: PrecomputedFog = PrecomputedFog()
    var cachedModelMatrix: matrix_float4x4 = matrix_identity_float4x4
    var cachedMaxViewDistance: Float = RenderSettings.maxViewDistance
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
    private var previousViewProjMatrices: [matrix_float4x4] = [matrix_identity_float4x4, matrix_identity_float4x4]  // per eye
    private var temporalFrameCount: Int = 0                         // 0 = first frame, no reprojection
    private var temporalDepthSize: SIMD2<Int> = .zero
    private var temporalColorTextures: [MTLTexture?] = [nil, nil]   // ping-pong color history
    private var temporalColorSize: SIMD2<Int> = .zero
    
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
#endif

    // === DYNAMIC RENDER QUALITY (WWDC25 Session 294) ===
    // Adjusts LayerRenderer.renderQuality based on FPS performance
    var dynamicRenderQualityManager: Any?  // Type-erased for @available
    var hasLoggedDynamicQualityStatus = false
    
    // === RESIDENCY SET (visionOS 2.0+) ===
    // Pre-validates GPU resource residency to reduce per-frame validation overhead
    var residencySet: MTLResidencySet?

    // Device pose smoothing removed — use raw device anchor from drawable for async timewarp
    
    // FPS tracking
    var lastPresentationTime: LayerRenderer.Clock.Instant?
    var smoothedFPS: Double = 0
    private var lastFPSUpdateTime: TimeInterval = 0
    var lastHandTrackingUpdateTime: TimeInterval = 0  // Throttle hand UI updates
    // IMPORTANT: These must be nonisolated(unsafe) because finishHandTrackingDispatch()
    // needs to reset the flag from a non-actor-isolated Task. The render loop is a
    // synchronous `while true` that never yields the actor, so an actor-isolated
    // finishHandTrackingDispatch() can never execute — the flag stays stuck at `true`
    // and all gesture updates are permanently dropped after the first frame.
    nonisolated(unsafe) var isHandTrackingDispatchInFlight: Bool = false
    nonisolated(unsafe) var pendingHandTrackingDelta: Float = 0
    var hasLoggedHandTrackingNil: Bool = false          // One-shot guard for nil provider log
    var lastHandTrackingStateLogTime: TimeInterval = 0  // Throttle non-running state logs
    var cachedDeltaTime: Float = 1.0 / 90.0  // Cached for use in updateGameState
    var lastPerfLogTime: TimeInterval = 0
    let perfLogFrameMsThreshold: Double = 30.0  // ~33 FPS
    private var lastFPSConsoleLogTime: TimeInterval = 0  // For periodic FPS console logging

    // Music-reactive fractal anchors (prevent parameter drift)
    private var musicFractalAnchorValid: Bool = false
    private var musicAnchorByTarget: [MusicReactiveTarget: Float] = [:]
    private var musicLFOPhaseByTarget: [MusicReactiveTarget: Float] = [:]

    private var parameterOperationFrameIndex: UInt64 = 0
    private let parameterOperationDispatcher = ParameterOperationDispatcher()

    var smoothedScale: Float = 1.0
    
    var lastImmersiveSpaceState: AppModel.ImmersiveSpaceState?


    var mesh: MTKMesh

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
            let unifiedKey = "FI\(iterCount)_RS\(raySteps)_N0_Q\(qualityMode)"
            
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

        // Build tile-based compute pipelines with function constants for maximum optimization
        do {
            guard let library = device.makeDefaultLibrary() else {
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
        Task {
            // Setup screenshot capture pipeline
            await self.setupScreenshotCapture()
            
            // === DYNAMIC RENDER QUALITY (WWDC25 Session 294) ===
            // Initialize dynamic quality manager if available on this OS version
            await self.setupDynamicRenderQuality()
            
            // === RESIDENCY SET ===
            // Pre-validate resource residency for reduced per-frame overhead
            await self.setupResidencySet()
            
            // === PRESET PIPELINE PRECOMPILATION ===
            // Build specialized pipelines for saved presets to avoid hitches when loading
            await self.precompilePresetPipelines()
        }
    }
    
    @MainActor
    static func startRenderLoop(_ layerRenderer: LayerRenderer, appModel: AppModel) {
        Task(executorPreference: RendererTaskExecutor.shared) {
            guard let renderer = Renderer(layerRenderer, appModel: appModel) else {
                await MainActor.run {
                    appModel.immersiveSpaceState = .closed
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
            }
            
            await renderer.startARSession()
            await renderer.renderLoop()
        }
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
    
    // Track last logged pipeline to avoid spam
    var lastLoggedPipelineKey: String = ""
    
    // === PIPELINE SELECTION FAST-PATH CACHE ===
    // Avoids per-frame String interpolation + Dictionary lookup when parameters haven't changed.
    // selectPipeline() is called every frame; caching the last result short-circuits the common case.
    var lastSelectIter: Int = -1
    var lastSelectRS: Int = -1
    var lastSelectQS: Bool = false
    var lastSelectNeon: Bool = false
    var lastSelectFT: Int32 = -1
    var lastSelectPower: Int32?
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

        let cpuEncodeStart = CACurrentMediaTime()

        guard let frame = layerRenderer.queryNextFrame() else { return }

        frame.startUpdate()

        // Perform frame independent work

        frame.endUpdate()

        guard let timing = frame.predictTiming() else { return }
        LayerRenderer.Clock().wait(until: timing.optimalInputTime)

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
            guard let firstDrawable = drawables.first else { return }
            drawable = firstDrawable
        } else {
            guard let legacyDrawable = frame.queryDrawable() else { return }
            drawable = legacyDrawable
        }

        // Wait for a buffer to become available. With maxBuffersInFlight=2,
        // this allows CPU/GPU pipelining while preventing frame accumulation.
        // The 2-buffer setup prevents the 45fps vsync lock that occurred with 1 buffer.
        // Timeout at 100ms (~10 FPS floor) to detect GPU stalls instead of hanging forever.
        let waitResult = inFlightSemaphore.wait(timeout: .now() + .milliseconds(100))
        if waitResult == .timedOut {
            // GPU is severely behind — skip this frame to avoid accumulating latency
            if RENDERER_DEBUG { print("⚠️ GPU stall detected: inFlightSemaphore timed out (100ms)") }
            return
        }

        frame.startSubmission()

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
            // Use UIUpdateCoordinator to prevent UI blocking during heavy fractal rendering
            // Decouples FPS updates from MainActor to maintain UI responsiveness
            uiUpdateCoordinator?.scheduleUIUpdate(fps: updatedFPS, currentTime: time)
            
            // Periodic FPS console logging (every 2 seconds)
            if RENDERER_DEBUG && time - lastFPSConsoleLogTime > 2.0 {
                lastFPSConsoleLogTime = time
                print("[FPS] \(String(format: "%.1f", updatedFPS)) fps | frame time: \(String(format: "%.2f", deltaTime * 1000))ms")
            }
            
            // === DYNAMIC RENDER QUALITY UPDATE ===
            // Adjust LayerRenderer.renderQuality based on FPS performance
            updateDynamicRenderQuality(fps: updatedFPS, deltaTime: deltaTime)
        }
        lastPresentationTime = presentationTime

        let semaphore = inFlightSemaphore
        commandBuffer.addCompletedHandler { (_ commandBuffer)-> Swift.Void in
            semaphore.signal()
        }

        self.updateDynamicBufferState()
        // Update hand tracking and process gestures
        self.updateHandTracking(atTime: time)

        // Update scene animation playback on MainActor
        // Batched with audio frame updates into a single MainActor dispatch to reduce overhead
        let animDelta = TimeInterval(cachedDeltaTime)
        
        settings.interpolateToTargets(deltaTime: cachedDeltaTime)
        settings.updateLimitFlash(deltaTime: cachedDeltaTime)
        settings.updateColorSchemeTransition(deltaTime: cachedDeltaTime)
        
        // === AUDIO PIPELINE ===
        // Auto-detect active sources: use mic FFT, Spotify beat sync, and/or
        // Apple Music BPM-based synthesis — blend whatever is available.
        let isAudioMode = settings.lightingMode == .audioReactive || settings.lightingMode == .visualizer || settings.fractalAudioReactiveEnabled
        let hasActiveAudioSources = appModel.audioAnalyzer.isCapturing || appModel.appleMusicManager.isActive
        let shouldUpdateAnimation = settings.isAnimationPlaying
        let fractalType = settings.fractalType
        
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

            // Music drives fractal geometry AND effects (Fractal Forge-inspired)
            if settings.fractalAudioReactiveEnabled {
                if !musicFractalAnchorValid {
                    let anchorFP = settings.formulaParams
                    let activeFractalType = settings.fractalType
                    musicAnchorByTarget[.fractalScale] = settings.targetFractalScale
                    musicAnchorByTarget[.colorMix] = settings.colorMix
                    musicAnchorByTarget[.glow] = settings.glowEffect.intensity
                    musicAnchorByTarget[.fog] = settings.fogEffect.intensity
                    musicAnchorByTarget[.bloom] = settings.bloomEffect.strength
                    musicAnchorByTarget[.hueSpeed] = settings.hueRotationEffect.speed
                    musicAnchorByTarget[.saturation] = settings.colorSchemeSaturation
                    musicAnchorByTarget[.iterations] = Float(settings.fractalIterations)
                    let floatParams = MusicReactiveTarget.floatFormulaParams(for: activeFractalType)
                    for target in [MusicReactiveTarget.formulaParam0, .formulaParam1, .formulaParam2, .formulaParam3] {
                        if let slot = target.formulaParamSlot, slot < floatParams.count {
                            musicAnchorByTarget[target] = FormulaCatalog.getParam(anchorFP, index: floatParams[slot].index)
                        }
                    }
                    musicFractalAnchorValid = true
                }

                let bass = settings.bassLevel
                let mid = settings.midLevel
                let treble = settings.trebleLevel
                let beat = settings.beatIntensity
                let globalAmount = settings.fractalAudioAmount
                let beatPunch = settings.fractalBeatPunch

                // Composite drive (default source behavior)
                let bandDrive = bass * 0.55 + mid * 0.30 + treble * 0.15
                let drive = min(1.0, bandDrive * 0.9 + beat * (0.1 + 0.6 * beatPunch))

                let dt = cachedDeltaTime

                var audioOperations: [ParameterOperation] = []

                let activeFractalType = settings.fractalType
                let mappings = settings.musicReactiveMappings
                for mapping in mappings where mapping.isEnabled {
                    // ── 1. Select audio source level (0-1) ──
                    let sourceValue: Float
                    switch mapping.source {
                    case .composite: sourceValue = drive
                    case .bass: sourceValue = bass
                    case .mid: sourceValue = mid
                    case .treble: sourceValue = treble
                    case .beat: sourceValue = beat
                    case .overall: sourceValue = settings.audioLevel
                    }

                    // ── 2. Scale audio level by intensity ──
                    let absAmount = abs(mapping.amount)
                    let scaled = min(1.0, max(0.0, sourceValue * absAmount * globalAmount))
                    let normalized = mapping.amount >= 0 ? scaled : (1.0 - scaled)

                    // ── 3. Compute final target value based on mode ──
                    let rawTargetValue: Float
                    switch mapping.mode {
                    case .absolute:
                        // Music sets the value directly within the user-defined min/max range
                        let minValue = min(mapping.rangeMin, mapping.rangeMax)
                        let maxValue = max(mapping.rangeMin, mapping.rangeMax)
                        let rangeSpan = maxValue - minValue

                        var lfoOffset: Float = 0
                        if mapping.lfo.enabled {
                            var phase = musicLFOPhaseByTarget[mapping.target] ?? 0
                            phase += mapping.lfo.frequency * dt
                            phase = phase - floor(phase)
                            musicLFOPhaseByTarget[mapping.target] = phase
                            lfoOffset = mapping.lfo.shape.evaluate(phase: phase) * mapping.lfo.amplitude * rangeSpan
                        }

                        rawTargetValue = minValue + rangeSpan * normalized + lfoOffset

                    case .relative:
                        // Music adds a deviation around the CURRENT base value
                        // (set by sliders, gestures, animations). The layer stack
                        // adds the music offset on top of the live UI/gesture value,
                        // so we only need to produce the pure delta here.
                        let allowed = mapping.target.allowedRange(for: activeFractalType)
                        let allowedSpan = allowed.upperBound - allowed.lowerBound
                        let maxDeviation = allowedSpan * 0.15 * absAmount * globalAmount

                        var lfoOffset: Float = 0
                        if mapping.lfo.enabled {
                            var phase = musicLFOPhaseByTarget[mapping.target] ?? 0
                            phase += mapping.lfo.frequency * dt
                            phase = phase - floor(phase)
                            musicLFOPhaseByTarget[mapping.target] = phase
                            lfoOffset = mapping.lfo.shape.evaluate(phase: phase) * mapping.lfo.amplitude * maxDeviation
                        }

                        let sign: Float = mapping.amount >= 0 ? 1.0 : -1.0
                        let delta = sourceValue * maxDeviation * sign
                        rawTargetValue = delta + lfoOffset
                    }

                    // ── 5. Dispatch to parameter system (LayerStack handles smoothing) ──
                    guard let targetID = mapping.target.parameterTargetID(for: activeFractalType) else { continue }
                    // In absolute mode, convert the raw target to an offset from the
                    // captured anchor so the layer stack's additive music layer
                    // produces the correct final value.
                    // In relative mode, rawTargetValue is already a pure delta that
                    // the layer stack adds on top of the live UI/gesture base value.
                    let offset: Float
                    if mapping.mode == .absolute {
                        let anchor = musicAnchorByTarget[mapping.target] ?? rawTargetValue
                        offset = rawTargetValue - anchor
                    } else {
                        offset = rawTargetValue
                    }
                    audioOperations.append(
                        ParameterOperation(
                            targetID: targetID,
                            source: .audio,
                            value: offset,
                            frameIndex: parameterOperationFrameIndex,
                            smoothingTime: max(0.02, mapping.smoothingWindow)
                        )
                    )
                }

                if !audioOperations.isEmpty {
                    parameterOperationDispatcher.dispatch(audioOperations, settings: settings)
                    parameterOperationFrameIndex &+= 1
                }
                
            } else {
                if musicFractalAnchorValid {
                    parameterOperationDispatcher.clearMusicLayers(settings: settings)
                }
                musicFractalAnchorValid = false
                musicAnchorByTarget.removeAll()
                musicLFOPhaseByTarget.removeAll()
            }
        } else {
            if musicFractalAnchorValid {
                parameterOperationDispatcher.clearMusicLayers(settings: settings)
            }
            musicFractalAnchorValid = false
            musicAnchorByTarget.removeAll()
            musicLFOPhaseByTarget.removeAll()
        }
        let settingsSnapshot = settings.snapshot()
        
        self.updateGameState(drawable: drawable, settingsSnapshot: settingsSnapshot)

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
                let bbrotTime = cachedFrameTime
                let rendered = bbrot.renderFrame(
                    commandBuffer: commandBuffer,
                    drawable: drawable,
                    time: bbrotTime,
                    settingsSnapshot: settingsSnapshot
                )
                
                if rendered {
                    drawable.encodePresent(commandBuffer: commandBuffer)
                    commandBuffer.commit()
                    frame.endSubmission()
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
                settingsSnapshot: settingsSnapshot
            )
            
            if computeRendered {
                drawable.encodePresent(commandBuffer: commandBuffer)
                commandBuffer.commit()
                frame.endSubmission()
                return  // Skip fragment-based rendering
            }
        } else {
            useAdaptiveCompute = false
        }
        
        // Fall back to fragment-based rendering
        let renderPassDescriptor = MTLRenderPassDescriptor()
        configureDirectRenderTargets(renderPassDescriptor: renderPassDescriptor, drawable: drawable)

        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            if RENDERER_DEBUG { print("⚠️ Failed to create render encoder; skipping frame") }
            drawable.encodePresent(commandBuffer: commandBuffer)
            commandBuffer.commit()
            frame.endSubmission()
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
            neonMode: isNeonMode
        )
        renderEncoder.setRenderPipelineState(selectedPipeline)

        renderEncoder.setDepthStencilState(depthState)

        renderEncoder.setVertexBuffer(dynamicUniformBuffer, offset:uniformBufferOffset, index: BufferIndex.uniforms.rawValue)
        
        // Also bind uniforms buffer for fragment shader since it now needs access to uniforms
        renderEncoder.setFragmentBuffer(dynamicUniformBuffer, offset:uniformBufferOffset, index: BufferIndex.uniforms.rawValue)

        let viewports: [MTLViewport] = drawable.views.map { $0.textureMap.viewport }
        renderEncoder.setViewports(viewports)

        if drawable.views.count > 1 {
            var viewMappings = (0..<drawable.views.count).map {
                MTLVertexAmplificationViewMapping(viewportArrayIndexOffset: UInt32($0),
                                                  renderTargetArrayIndexOffset: UInt32($0))
            }
            renderEncoder.setVertexAmplificationCount(viewports.count, viewMappings: &viewMappings)
        }

        for (index, element) in mesh.vertexDescriptor.layouts.enumerated() {
            guard let layout = element as? MDLVertexBufferLayout else {
                return
            }

            if layout.stride != 0 {
                let buffer = mesh.vertexBuffers[index]
                renderEncoder.setVertexBuffer(buffer.buffer, offset:buffer.offset, index: index)
            }
        }

        for submesh in mesh.submeshes {
            renderEncoder.drawIndexedPrimitives(type: submesh.primitiveType,
                                                indexCount: submesh.indexCount,
                                                indexType: submesh.indexType,
                                                indexBuffer: submesh.indexBuffer.buffer,
                                                indexBufferOffset: submesh.indexBuffer.offset)
        }

        renderEncoder.popDebugGroup()

        renderEncoder.endEncoding()
        
        let cpuEncodeMs = (CACurrentMediaTime() - cpuEncodeStart) * 1000.0
        let frameTimeSeconds = Double(cachedDeltaTime)
        let logTime = time
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
                    settingsSnapshot: settingsSnapshot,
                    useAdaptiveCompute: useAdaptiveCompute,
                    viewCount: drawable.views.count
                )
            }
        }

        drawable.encodePresent(commandBuffer: commandBuffer)

        commandBuffer.commit()

        frame.endSubmission()
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
        pipeline: MTLComputePipelineState? = nil,
        prevDepthTexture: MTLTexture,
        curDepthTexture: MTLTexture,
        prevColorTexture: MTLTexture,
        curColorTexture: MTLTexture
    ) {
        guard let pipeline = pipeline ?? adaptiveHierarchicalPipeline8x8,
              let uniformBuffer = tileUniformBuffer else {
            if RENDERER_DEBUG { print("⚠️ Adaptive compute pipeline not available") }
            return
        }
        let view = drawable.views[viewIndex]
        
        // Build model matrix — reuse cached value from updateGameState() instead of recomputing
        let modelMatrix = cachedModelMatrix
        
        // Build view matrix (same as fragment shader)
        let deviceTransform = drawable.deviceAnchor?.originFromAnchorTransform ?? matrix_identity_float4x4
        let viewMatrix = (deviceTransform * view.transform).inverse
        let projection = drawable.computeProjection(viewIndex: viewIndex)
        
        // Model-view matrix and its inverse (THIS WAS MISSING!)
        let modelView = viewMatrix * modelMatrix
        let inverseModelView = modelView.inverse
        
        // Current frame's full model-view-projection (for temporal reprojection)
        let currentViewProj = projection * modelView
        
        // Get camera position from inverse model-view matrix (in model space)
        let cameraPos = SIMD3<Float>(inverseModelView.columns.3.x, inverseModelView.columns.3.y, inverseModelView.columns.3.z)
        
        // Get color scheme parameters
        let colorSchemeParams = settingsSnapshot.colorSchemeParams
        
        // === REUSE PRECOMPUTED VALUES from updateGameState() ===
        // These are frame-uniform (identical for both eyes), computed once per frame.
        let computePrecomputedFractal = cachedPrecomputedFractal
        let computePrecomputedLighting = cachedPrecomputedLighting
        let computePrecomputedAudio = cachedPrecomputedAudio
        let computePrecomputedFog = cachedPrecomputedFog
        let frameTime = cachedFrameTime
        let effectiveScale = smoothedScale * settingsSnapshot.detailScale
        let scaleCorrectedBubbleRadius = settingsSnapshot.safetyBubbleRadius / max(effectiveScale, 0.001)
        let scaleCorrectedFadeWidth = settingsSnapshot.safetyBubbleFadeWidth / max(effectiveScale, 0.001)
        
        var tileUniforms = TileUniforms(
            invViewMatrix: inverseModelView,  // Use inverse MODEL-VIEW, not just inverse view!
            invProjMatrix: projection.inverse,
            cameraPos: cameraPos,
            time: frameTime,
            resolution: SIMD2<Float>(Float(outputTexture.width), Float(outputTexture.height)),
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
            glowIntensity: settingsSnapshot.colorSchemeParams.glowIntensity,
            colorMix: settingsSnapshot.colorMix,
            fractalIterations: Int32(settingsSnapshot.fractalIterations),
            colorIterations: Int32(settingsSnapshot.colorIterations),
            maxRaySteps: Int32(settingsSnapshot.maxRaySteps),
            maxViewDistance: cachedMaxViewDistance,
            eyeIndex: UInt32(viewIndex),
            debugHierarchical: settingsSnapshot.debugHierarchical ? 1 : 0,
            limitFlash: settingsSnapshot.limitFlash,
            fractalType: settingsSnapshot.fractalType.rawValue,
            lightingSoftness: settingsSnapshot.lightingSoftness,
            // === GMT-FRACTALS OPTIMIZATIONS ===
            stepMultiplier: settingsSnapshot.stepMultiplier,
            boundingSphereRadius: 0.0,  // Disabled: Mandelbox extent varies with minDistance/scale; needs dynamic radius
            blendFactor: settingsSnapshot.isGeometryGestureActive ? 1.0 : (settingsSnapshot.geometryState == .stable ? 0.1 : 0.5),
            jitterOffset: .zero,
            accumulationFrame: 0,
            temporalReprojectionEnabled: temporalFrameCount > 0 ? 1 : 0,
            _pad_tile: (0, 0),
            formulaParams: settingsSnapshot.formulaParams,
            currentViewProjMatrix: currentViewProj,
            previousViewProjMatrix: previousViewProjMatrices[viewIndex],
            currentInvViewProjMatrix: currentViewProj.inverse,
            precomputedFractal: computePrecomputedFractal,
            precomputedLighting: computePrecomputedLighting,
            precomputedAudio: computePrecomputedAudio,
            precomputedFog: computePrecomputedFog,
            colorScheme: colorSchemeParams
        )
        
        // Copy uniforms to buffer
        let uniformOffset = MemoryLayout<TileUniforms>.stride * viewIndex
        memcpy(uniformBuffer.contents().advanced(by: uniformOffset), &tileUniforms, MemoryLayout<TileUniforms>.size)
        
        // Create compute encoder
        guard let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
            if RENDERER_DEBUG { print("⚠️ Failed to create compute encoder") }
            return
        }
        
        computeEncoder.label = "Adaptive 8x8 Hierarchical Raymarch - Eye \(viewIndex)"
        computeEncoder.setComputePipelineState(pipeline)
        computeEncoder.setBuffer(uniformBuffer, offset: uniformOffset, index: 0)
        computeEncoder.setTexture(outputTexture, index: 0)
        
        // Temporal reprojection depth textures
        computeEncoder.setTexture(prevDepthTexture, index: 1)
        computeEncoder.setTexture(curDepthTexture, index: 2)
        computeEncoder.setTexture(prevColorTexture, index: 3)
        computeEncoder.setTexture(curColorTexture, index: 4)
        
        // Store current VP for next frame's reprojection
        previousViewProjMatrices[viewIndex] = currentViewProj
        
        // Dispatch 8x8 threadgroups
        let tileSize = 8
        let threadgroupSize = MTLSize(width: tileSize, height: tileSize, depth: 1)
        let threadgroupsPerGrid = MTLSize(
            width: (outputTexture.width + tileSize - 1) / tileSize,
            height: (outputTexture.height + tileSize - 1) / tileSize,
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
        
        // Add to residency set for GPU memory pre-validation
        updateResidencySetForComputeTexture(texture)
        
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
        
        // Add to residency set
        updateResidencySetForComputeTexture(tex0)
        updateResidencySetForComputeTexture(tex1)
        
        if RENDERER_DEBUG { print("📐 Created temporal depth textures: \(width)×\(height) × \(viewCount) layers") }
        return (read: tex0, write: tex0)  // First frame: read=write (will be marked invalid)
    }

    /// Creates or resizes the double-buffered temporal color textures for accumulation.
    /// Returns (previousRead, currentWrite) texture pair.
    private func ensureTemporalColorTextures(for drawable: LayerRenderer.Drawable) -> (read: MTLTexture, write: MTLTexture)? {
        let width = drawable.colorTextures[0].width
        let height = drawable.colorTextures[0].height
        let viewCount = drawable.views.count
        let pixelFormat = drawable.colorTextures[0].pixelFormat

        if let tex0 = temporalColorTextures[0],
           let _ = temporalColorTextures[1],
           tex0.width == width,
           tex0.height == height,
           tex0.arrayLength == viewCount,
           tex0.pixelFormat == pixelFormat {
            let readIdx = 1 - temporalDepthIndex
            return (read: temporalColorTextures[readIdx]!, write: temporalColorTextures[temporalDepthIndex]!)
        }

        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type2DArray
        descriptor.pixelFormat = pixelFormat
        descriptor.width = width
        descriptor.height = height
        descriptor.arrayLength = viewCount
        descriptor.storageMode = .private
        descriptor.usage = [.shaderWrite, .shaderRead]

        guard let tex0 = device.makeTexture(descriptor: descriptor),
              let tex1 = device.makeTexture(descriptor: descriptor) else {
            if RENDERER_DEBUG { print("⚠️ Failed to create temporal color textures") }
            return nil
        }
        tex0.label = "Temporal Color 0"
        tex1.label = "Temporal Color 1"

        temporalColorTextures = [tex0, tex1]
        temporalColorSize = SIMD2(width, height)

        updateResidencySetForComputeTexture(tex0)
        updateResidencySetForComputeTexture(tex1)

        if RENDERER_DEBUG { print("📐 Created temporal color textures: \(width)×\(height) × \(viewCount) layers") }
        return (read: tex0, write: tex0)  // First frame: no valid previous history
    }
    
    /// Copies compute output texture to drawable using blit encoder
    private func blitComputeOutputToDrawable(
        commandBuffer: MTLCommandBuffer,
        drawable: LayerRenderer.Drawable
    ) {
        guard let sourceTexture = computeOutputTexture else { return }
        guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else { return }
        blitEncoder.label = "Copy Compute Output to Drawable"
        
        for eye in 0..<drawable.views.count {
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
            
            blitEncoder.copy(
                from: sourceTexture,
                sourceSlice: eye,
                sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(width: sourceTexture.width, height: sourceTexture.height, depth: 1),
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
        settingsSnapshot: RenderSettingsSnapshot
    ) -> Bool {
        // Select the best compute pipeline for current iteration/ray step settings
        let fi = settingsSnapshot.fractalIterations
        let rs = settingsSnapshot.maxRaySteps
        let computePipeline = selectComputePipeline(fractalIterations: fi, maxRaySteps: rs)
        
        guard computePipeline != nil else { return false }
        
        guard let outputTexture = ensureComputeOutputTexture(for: drawable) else {
            return false
        }
        
                // Set up temporal reprojection depth textures (ping-pong)
                guard let depthPair = ensureTemporalDepthTextures(for: drawable),
                            let colorPair = ensureTemporalColorTextures(for: drawable) else {
                        if RENDERER_DEBUG { print("⚠️ Temporal textures unavailable; falling back to fragment rendering") }
                        return false
                }
        
        // Render each eye
        for viewIndex in 0..<drawable.views.count {
            encodeAdaptiveCompute(
                commandBuffer: commandBuffer,
                outputTexture: outputTexture,
                drawable: drawable,
                viewIndex: viewIndex,
                settingsSnapshot: settingsSnapshot,
                pipeline: computePipeline,
                prevDepthTexture: depthPair.read,
                curDepthTexture: depthPair.write,
                prevColorTexture: colorPair.read,
                curColorTexture: colorPair.write
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
    
    /// Profile each component of your rendering pipeline
    func profilePipelineComponents() {
        let settingsSnapshot = appModel.renderSettings.snapshot()
        
        guard let library = device.makeDefaultLibrary(),
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
            cmdBuffer.waitUntilCompleted()
            let elapsed = (CACurrentMediaTime() - startTime) * 1000.0
            
            print("║  \(name.padding(toLength: 40, withPad: " ", startingAt: 0)) \(String(format: "%6.2f", elapsed))ms ║")
        }
        
        print("╚═══════════════════════════════════════════════════════════════╝\n")
    }
}
