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

/// Dedicated render thread using a persistent Thread object with high priority.
/// This avoids thread hopping and preemption that causes micro-stutters with DispatchQueue.
final class RendererTaskExecutor: TaskExecutor, @unchecked Sendable {
    // pendingJobs is protected by lock - safe for Sendable
    private var pendingJobs: [UnownedJob] = []
    private var pendingJobsHead: Int = 0
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var isRunning = true
    private var renderThread: Thread?
    private let pendingJobsCompactionThreshold = 64
    
    init() {
        // Create a persistent high-priority thread for rendering
        let executor = self
        renderThread = Thread { [weak executor] in
            // Set thread priority to maximum for real-time rendering
            Thread.current.qualityOfService = .userInteractive
            Thread.current.threadPriority = 1.0
            Thread.current.name = "RenderThread"
            
            while executor?.isRunning ?? false {
                // Wait for work
                executor?.semaphore.wait()
                
                // Process all pending jobs
                while let job = executor?.dequeueJob() {
                    job.runSynchronously(on: executor!.asUnownedSerialExecutor())
                }
            }
        }
        renderThread?.qualityOfService = .userInteractive
        renderThread?.start()
    }
    
    private func dequeueJob() -> UnownedJob? {
        lock.lock()
        defer { lock.unlock() }
        guard pendingJobsHead < pendingJobs.count else {
            pendingJobs.removeAll(keepingCapacity: true)
            pendingJobsHead = 0
            return nil
        }

        let job = pendingJobs[pendingJobsHead]
        pendingJobsHead += 1
        if pendingJobsHead >= pendingJobsCompactionThreshold && pendingJobsHead >= pendingJobs.count / 2 {
            pendingJobs.removeFirst(pendingJobsHead)
            pendingJobsHead = 0
        }
        return job
    }

    func enqueue(_ job: UnownedJob) {
        lock.lock()
        pendingJobs.append(job)
        lock.unlock()
        semaphore.signal()
    }

    func asUnownedSerialExecutor() -> UnownedTaskExecutor {
        return UnownedTaskExecutor(ordinary: self)
    }

    static var shared: RendererTaskExecutor = RendererTaskExecutor()
}

actor Renderer {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    var dynamicUniformBuffer: MTLBuffer
    var pipelineState: MTLRenderPipelineState
    var quadSharedPipelineState: MTLRenderPipelineState?  // Quad-shared raymarch (2x2 sharing)
    var depthState: MTLDepthStencilState
    var cubeMap: MTLTexture
    
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
    var lastComputeFI: Int = -1
    var lastComputeRS: Int = -1
    var lastSelectedComputePipeline: MTLComputePipelineState?
    
    /// Cached default Metal library — avoids device.makeDefaultLibrary() on every compute cache miss
    var cachedDefaultLibrary: MTLLibrary?
    
    // Cached constant matrices (computed once, reused every frame)
    let cachedRotationMatrix: matrix_float4x4
    
    // === FRAME-LEVEL CACHED VALUES ===
    // Computed once in updateGameState(), reused in encodeAdaptiveCompute() per eye.
    // Eliminates redundant makePrecomputedFractal/Lighting + model matrix computation.
    var cachedFrameTime: Float = 0
    var cachedPrecomputedFractal: PrecomputedFractalParams = PrecomputedFractalParams()
    var cachedPrecomputedLighting: PrecomputedLighting = PrecomputedLighting()
    var cachedModelMatrix: matrix_float4x4 = matrix_identity_float4x4
    
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
    
    // ═══════════════════════════════════════════════════════════════════════════
    // PROGRESSIVE RENDERING PIPELINES
    // Experiments with different threadgroup sizes for optimal GPU utilization
    // ═══════════════════════════════════════════════════════════════════════════
    private var progressiveDepthPipeline: MTLComputePipelineState?
    private var progressiveColorPipeline: MTLComputePipelineState?
    private var progressive8x4Pipeline: MTLComputePipelineState?   // 32 threads = 1 SIMD group
    private var progressive4x8Pipeline: MTLComputePipelineState?   // 32 threads, different layout
    private var progressiveBenchmarkPipeline: MTLComputePipelineState?
    private var progressiveUniformBuffer: MTLBuffer?
    private var progressiveDepthTexture: MTLTexture?
    private var progressivePreviousFrame: MTLTexture?
    private var progressiveOutputTexture: MTLTexture?
    private var progressiveTextureSize: SIMD2<Int> = .zero
    private var progressiveFrameIndex: Int = 0
    
    // Screenshot capture
    var screenshotTexture: MTLTexture?
    var screenshotPipeline: MTLRenderPipelineState?
    var screenshotDepthTexture: MTLTexture?
    var pendingScreenshotContinuation: CheckedContinuation<Data?, Never>?
    var shouldCaptureScreenshot: Bool = false
    
    // Pipeline profiling trigger
    nonisolated(unsafe) var shouldRunProfiler: Bool = false

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
    var cachedDeltaTime: Float = 1.0 / 90.0  // Cached for use in updateGameState
    var lastPerfLogTime: TimeInterval = 0
    let perfLogFrameMsThreshold: Double = 30.0  // ~33 FPS
    private var lastFPSConsoleLogTime: TimeInterval = 0  // For periodic FPS console logging

    // Music-reactive fractal anchors (prevent parameter drift)
    private var musicFractalAnchorValid: Bool = false
    private var musicAnchorFractalScale: Float = 2.8
    private var musicAnchorFoldingLimit: Float = 1.0
    private var musicAnchorSphereRadius: Float = 0.5
    private var musicAnchorColorMix: Float = 0.5
    
    // Fractal Forge-inspired extended anchors for effects
    private var musicAnchorGlowIntensity: Float = 0.3
    private var musicAnchorGlowWasEnabled: Bool = false
    private var musicAnchorFogIntensity: Float = 0.32
    private var musicAnchorFogWasEnabled: Bool = true
    private var musicAnchorBloomStrength: Float = 0.2
    private var musicAnchorBloomWasEnabled: Bool = false
    private var musicAnchorHueSpeed: Float = 0.1
    private var musicAnchorHueWasEnabled: Bool = false
    private var musicAnchorSaturation: Float = 1.0
    private var musicAnchorIterations: Int = 9

    var smoothedPosition: SIMD3<Float> = .zero
    var smoothedScale: Float = 1.0
    
    var lastImmersiveSpaceState: AppModel.ImmersiveSpaceState?


    var mesh: MTKMesh

    let arSession: ARKitSession
    let worldTracking: WorldTrackingProvider
    var handTracking: HandTrackingProvider?
    let layerRenderer: LayerRenderer
    let appModel: AppModel

    init(_ layerRenderer: LayerRenderer, appModel: AppModel) {
        self.layerRenderer = layerRenderer
        self.device = layerRenderer.device
        guard let queue = self.device.makeCommandQueue() else {
            fatalError("Failed to create command queue")
        }
        self.commandQueue = queue
        self.appModel = appModel
        
        // Pre-compute constant rotation matrix (never changes)
        self.cachedRotationMatrix = matrix4x4_rotation(radians: -.pi/2, axis: [0, 1, 0])

        let device = self.device

        let uniformBufferSize = alignedUniformsSize * maxBuffersInFlight

        guard let uniformBuffer = self.device.makeBuffer(length: uniformBufferSize,
                                                          options: [MTLResourceOptions.storageModeShared]) else {
            fatalError("Failed to create uniform buffer")
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
            fatalError("Unable to compile render pipeline state.  Error info: \(error)")
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
        self.depthState = device.makeDepthStencilState(descriptor:depthStateDescriptor)!

        do {
            mesh = try Renderer.buildMesh(device: device, mtlVertexDescriptor: mtlVertexDescriptor)
        } catch {
            fatalError("Unable to build MetalKit Mesh. Error info: \(error)")
        }

        do {
            cubeMap = try Renderer.loadTexture(device: device, textureName: "CubeMap")
        } catch {
            fatalError("Unable to load texture. Error info: \(error)")
        }
        
        // Build tile-based compute pipelines with function constants for maximum optimization
        do {
            let library = device.makeDefaultLibrary()!
            
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
            
            // Progressive uniform buffer (for diagnostic kernels)
            progressiveUniformBuffer = device.makeBuffer(length: 512, options: .storageModeShared)
            progressiveUniformBuffer?.label = "ProgressiveUniforms"
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
            let renderer = Renderer(layerRenderer, appModel: appModel)
            
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

    /// Cached Metal library to avoid redundant `makeDefaultLibrary()` calls during pipeline builds.
    /// Thread-safe for our usage: all pipeline builds happen on the same thread (init) or are serialized.
    nonisolated(unsafe) static var _cachedLibrary: MTLLibrary?
    
    // Track last logged pipeline to avoid spam
    var lastLoggedPipelineKey: String = ""
    
    // === PIPELINE SELECTION FAST-PATH CACHE ===
    // Avoids per-frame String interpolation + Dictionary lookup when parameters haven't changed.
    // selectPipeline() is called every frame; caching the last result short-circuits the common case.
    var lastSelectIter: Int = -1
    var lastSelectRS: Int = -1
    var lastSelectQS: Bool = false
    var lastSelectNeon: Bool = false
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

    static func loadTexture(device: MTLDevice,
                            textureName: String) throws -> MTLTexture {
        /// Load texture data with optimal parameters for sampling

        let textureLoader = MTKTextureLoader(device: device)

        let textureLoaderOptions = [
            MTKTextureLoader.Option.textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
            MTKTextureLoader.Option.textureStorageMode: NSNumber(value: MTLStorageMode.`private`.rawValue)
        ]

        return try textureLoader.newTexture(name: textureName,
                                            scaleFactor: 1.0,
                                            bundle: nil,
                                            options: textureLoaderOptions)
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
            fatalError("Failed to create command buffer")
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
        _ = inFlightSemaphore.wait(timeout: DispatchTime.distantFuture)

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
            
            // Throttle UI updates to 2Hz (every 0.5s) to reduce SwiftUI observation invalidation.
            // appModel.fps is @Observable and triggers layout re-evaluation of all views reading it.
            // 2Hz is frequent enough for visual FPS display while halving MainActor layout work.
            if time - lastFPSUpdateTime > 0.5 {
                lastFPSUpdateTime = time
                Task { @MainActor in
                    appModel.fps = updatedFPS
                    // Sample analytics ~4Hz (matches FPS update rate)
                    let qualityPreset = QualityPreset.detect(
                        fractalIterations: settings.fractalIterations,
                        raySteps: settings.maxRaySteps
                    )?.rawValue ?? "custom"
                    UsageAnalytics.shared.sample(
                        settings: settings,
                        fps: updatedFPS,
                        currentQuality: qualityPreset
                    )
                }
            }
            
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
        
        // Single consolidated MainActor dispatch per frame for animation + audio updates.
        // Previously this was 2-3 separate Task dispatches, each adding MainActor run loop overhead.
        if isAudioMode {
            Task { @MainActor in
                self.appModel.animationManager?.update(deltaTime: animDelta)
                self.appModel.spotifyManager.updateFrame()
                self.appModel.appleMusicManager.updateFrame()
            }
        } else {
            Task { @MainActor in
                self.appModel.animationManager?.update(deltaTime: animDelta)
            }
        }
        
        if isAudioMode {
            let mic = appModel.audioAnalyzer
            let spotifyManager = appModel.spotifyManager
            let appleMusicManager = appModel.appleMusicManager
            // Auto-detect: use whatever sources are currently active
            let micActive = mic.isCapturing
            let spotifyActive = spotifyManager.beatSyncActive
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
            if spotifyActive {
                totalBass += spotifyManager.bassLevel
                totalMid += spotifyManager.midLevel
                totalTreble += spotifyManager.trebleLevel
                totalBeat = max(totalBeat, spotifyManager.beatIntensity)
                totalLevel += spotifyManager.overallLevel
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
                settings.bassLevel = min(1.0, totalBass * inv * bassSens)
                settings.midLevel = min(1.0, totalMid * inv * midSens)
                settings.trebleLevel = min(1.0, totalTreble * inv * trebleSens)
                settings.beatIntensity = min(1.0, totalBeat * beatSens)
                settings.audioLevel = totalLevel * inv
            }

            // Music drives fractal geometry AND effects (Fractal Forge-inspired)
            if settings.fractalAudioReactiveEnabled {
                if !musicFractalAnchorValid {
                    // Capture geometry anchors
                    musicAnchorFractalScale = settings.fractalScale
                    musicAnchorFoldingLimit = settings.foldingLimit
                    musicAnchorSphereRadius = settings.sphereRadius
                    musicAnchorColorMix = settings.colorMix
                    
                    // Capture effect anchors (save original values + enabled state)
                    musicAnchorGlowIntensity = settings.glowEffect.intensity
                    musicAnchorGlowWasEnabled = settings.glowEffect.enabled
                    musicAnchorFogIntensity = settings.fogEffect.intensity
                    musicAnchorFogWasEnabled = settings.fogEffect.enabled
                    musicAnchorBloomStrength = settings.bloomEffect.strength
                    musicAnchorBloomWasEnabled = settings.bloomEffect.enabled
                    musicAnchorHueSpeed = settings.hueRotationEffect.speed
                    musicAnchorHueWasEnabled = settings.hueRotationEffect.enabled
                    musicAnchorSaturation = settings.colorSchemeSaturation
                    musicAnchorIterations = settings.fractalIterations
                    
                    musicFractalAnchorValid = true
                }

                let bass = settings.bassLevel
                let mid = settings.midLevel
                let treble = settings.trebleLevel
                let beat = settings.beatIntensity
                let amount = settings.fractalAudioAmount
                let beatPunch = settings.fractalBeatPunch
                
                // Composite drives for different modulation types
                let bandDrive = bass * 0.55 + mid * 0.30 + treble * 0.15
                let drive = min(1.0, bandDrive * (0.9 * amount) + beat * (0.1 + 0.6 * beatPunch))

                // ── Geometry modulation (existing) ──────────────────────────
                if settings.fractalAudioAffectsScale {
                    // Bass + beat expand/contract fractal scale
                    settings.fractalScale = max(1.6, min(5.2, musicAnchorFractalScale + (drive - 0.35) * (0.15 + 0.8 * amount)))
                }
                if settings.fractalAudioAffectsFolding {
                    // Bass drives box fold, beats punch it
                    settings.foldingLimit = max(0.7, min(1.7, musicAnchorFoldingLimit + (bass - 0.4) * (0.08 + 0.24 * amount) + beat * (0.03 + 0.12 * beatPunch)))
                }
                if settings.fractalAudioAffectsRadius {
                    // Mids modulate sphere radius, beats add punch
                    settings.sphereRadius = max(0.03, min(1.2, musicAnchorSphereRadius + mid * (0.05 + 0.20 * amount) + beat * (0.01 + 0.08 * beatPunch)))
                }
                if settings.fractalAudioAffectsColorMix {
                    // Overall drive shifts color palette blend
                    settings.colorMix = max(0.0, min(1.0, musicAnchorColorMix * (1.0 - 0.4 * amount) + drive * (0.2 + 0.6 * amount)))
                }
                
                // ── Effect modulation (Fractal Forge–inspired) ─────────────
                
                // GLOW ← RMS energy + kick pulses (additive brightness)
                if settings.fractalAudioAffectsGlow {
                    let glowDrive = bass * 0.5 + beat * 0.4 + mid * 0.1
                    let baseGlow = musicAnchorGlowWasEnabled ? musicAnchorGlowIntensity : 0.25
                    let glowVal = baseGlow + glowDrive * (0.2 + 0.5 * amount)
                    settings.audioModulateGlowIntensity(glowVal)
                }
                
                // FOG ← INVERSELY mapped to energy (quiet=fog, loud=clear)
                if settings.fractalAudioAffectsFog {
                    let energyLevel = bass * 0.4 + mid * 0.3 + beat * 0.3
                    let baseFog = musicAnchorFogWasEnabled ? musicAnchorFogIntensity : 0.30
                    // High energy → fog fades away; quiet → fog thickens
                    let fogVal = baseFog * (1.0 - energyLevel * (0.4 + 0.5 * amount))
                    settings.audioModulateFogIntensity(max(0.02, fogVal))
                }
                
                // BLOOM ← beat bloom with fast attack (kick-triggered flash)
                if settings.fractalAudioAffectsBloom {
                    let bloomDrive = beat * 0.6 + bass * 0.4
                    let baseBloom = musicAnchorBloomWasEnabled ? musicAnchorBloomStrength : 0.15
                    let bloomVal = baseBloom + bloomDrive * (0.15 + 0.4 * amount * beatPunch)
                    settings.audioModulateBloomStrength(bloomVal)
                }
                
                // HUE SPEED ← treble + mid (high frequency accelerates color cycling)
                if settings.fractalAudioAffectsHueSpeed {
                    let hueDrive = treble * 0.6 + mid * 0.3 + beat * 0.1
                    let baseHue = musicAnchorHueWasEnabled ? musicAnchorHueSpeed : 0.04
                    let hueVal = baseHue + hueDrive * (0.08 + 0.25 * amount)
                    settings.audioModulateHueSpeed(hueVal)
                }
                
                // SATURATION ← tonal/harmonic energy (richer colors on harmonic content)
                if settings.fractalAudioAffectsSaturation {
                    let satDrive = mid * 0.5 + treble * 0.3 + bass * 0.2
                    let baseSat = musicAnchorSaturation
                    // Gently boost saturation on strong tonal content
                    let satVal = baseSat + satDrive * (0.2 + 0.6 * amount)
                    settings.audioModulateSaturation(satVal)
                }
                
                // ITERATIONS ← mid energy adds detail on transients (⚠️ performance)
                if settings.fractalAudioAffectsIterations {
                    let iterDrive = mid * 0.6 + treble * 0.4
                    let extra = Int(iterDrive * amount * 3.0)  // +0 to +3 max
                    settings.fractalIterations = min(musicAnchorIterations + 3, musicAnchorIterations + extra)
                }
                
            } else {
                musicFractalAnchorValid = false
            }
        } else {
            musicFractalAnchorValid = false
        }
        let settingsSnapshot = settings.snapshot()
        
        self.updateGameState(drawable: drawable, settingsSnapshot: settingsSnapshot)

        // Check if using adaptive 8x8 compute pipeline
        let tileSize = settingsSnapshot.tileSize
        let useAdaptiveCompute = (tileSize == 8) && adaptiveHierarchicalPipeline8x8 != nil
        
        if useAdaptiveCompute {
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
        }
        
        // Fall back to fragment-based rendering
        let renderPassDescriptor = MTLRenderPassDescriptor()
        configureDirectRenderTargets(renderPassDescriptor: renderPassDescriptor, drawable: drawable)

        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            fatalError("Failed to create render encoder")
        }

        renderEncoder.label = "Primary Render Encoder"

        renderEncoder.pushDebugGroup("Draw Box")

        renderEncoder.setCullMode(.front)

        renderEncoder.setFrontFacing(.counterClockwise)

        // Select pipeline based on tile size
        // tileSize: 0 = standard per-pixel, 2 = quad-shared (2x2 SIMD), 8 = compute-based (handled above)
        let useQuadShared = (tileSize == 2)
        
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

        renderEncoder.setFragmentTexture(cubeMap, index: TextureIndex.color.rawValue)

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
        prevDepthTexture: MTLTexture? = nil,
        curDepthTexture: MTLTexture? = nil
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
        let frameTime = cachedFrameTime
        
        var tileUniforms = TileUniforms(
            invViewMatrix: inverseModelView,  // Use inverse MODEL-VIEW, not just inverse view!
            invProjMatrix: projection.inverse,
            cameraPos: cameraPos,
            time: frameTime,
            resolution: SIMD2<Float>(Float(outputTexture.width), Float(outputTexture.height)),
            minDistance: settingsSnapshot.minDistance,
            fractalScale: settingsSnapshot.fractalScale,
            sphereRadius: settingsSnapshot.sphereRadius,
            safetyBubbleRadius: settingsSnapshot.safetyBubbleRadius,
            safetyBubbleEnabled: settingsSnapshot.safetyBubbleEnabled ? 1 : 0,
            safetyBubbleShape: settingsSnapshot.safetyBubbleShape,
            foldingLimit: settingsSnapshot.foldingLimit,
            glowIntensity: settingsSnapshot.colorSchemeParams.glowIntensity,
            colorMix: settingsSnapshot.colorMix,
            fractalIterations: Int32(settingsSnapshot.fractalIterations),
            colorIterations: Int32(settingsSnapshot.colorIterations),
            maxRaySteps: Int32(settingsSnapshot.maxRaySteps),
            eyeIndex: UInt32(viewIndex),
            debugHierarchical: settingsSnapshot.debugHierarchical ? 1 : 0,
            limitFlash: settingsSnapshot.limitFlash,
            fractalType: settingsSnapshot.fractalType.rawValue,
            lightingMode: settingsSnapshot.lightingMode.rawValue,
            audioLevel: settingsSnapshot.audioLevel,
            bassLevel: settingsSnapshot.bassLevel,
            midLevel: settingsSnapshot.midLevel,
            trebleLevel: settingsSnapshot.trebleLevel,
            beatIntensity: settingsSnapshot.beatIntensity,
            visualizerMode: settingsSnapshot.visualizerMode,
            visualizerIntensity: settingsSnapshot.visualizerIntensity,
            fogIntensity: settingsSnapshot.colorSchemeParams.fogIntensity,
            lightingSoftness: settingsSnapshot.lightingSoftness,
            maxViewDistance: RenderSettings.maxViewDistance,
            logDepthScale: RenderSettings.logDepthScale,
            depthMissValue: RenderSettings.depthMissValue,
            // === GMT-FRACTALS OPTIMIZATIONS ===
            stepMultiplier: settingsSnapshot.stepMultiplier,
            boundingSphereRadius: 0.0,  // Disabled: Mandelbox extent varies with minDistance/scale; needs dynamic radius
            blendFactor: settingsSnapshot.isGeometryGestureActive ? 1.0 : (settingsSnapshot.geometryState == .stable ? 0.1 : 0.5),
            pad_gmt: 0.0,
            currentViewProjMatrix: currentViewProj,
            previousViewProjMatrix: previousViewProjMatrices[viewIndex],
            currentInvViewProjMatrix: currentViewProj.inverse,
            temporalReprojectionEnabled: (temporalFrameCount > 0 && prevDepthTexture != nil) ? 1 : 0,
            pad_temporal: (0, 0, 0),
            precomputedFractal: computePrecomputedFractal,
            precomputedLighting: computePrecomputedLighting,
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
        if let prevDepth = prevDepthTexture {
            computeEncoder.setTexture(prevDepth, index: 1)
        }
        if let curDepth = curDepthTexture {
            computeEncoder.setTexture(curDepth, index: 2)
        }
        
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
        let depthPair = ensureTemporalDepthTextures(for: drawable)
        
        // Render each eye
        for viewIndex in 0..<drawable.views.count {
            encodeAdaptiveCompute(
                commandBuffer: commandBuffer,
                outputTexture: outputTexture,
                drawable: drawable,
                viewIndex: viewIndex,
                settingsSnapshot: settingsSnapshot,
                pipeline: computePipeline,
                prevDepthTexture: depthPair?.read,
                curDepthTexture: depthPair?.write
            )
        }
        
        // Advance temporal state for next frame
        if depthPair != nil {
            temporalDepthIndex = 1 - temporalDepthIndex  // Swap ping-pong
            temporalFrameCount += 1
        }
        
        // Blit compute output to drawable for presentation
        blitComputeOutputToDrawable(commandBuffer: commandBuffer, drawable: drawable)
        
        return true
    }
    
    // ═══════════════════════════════════════════════════════════════════════════
    // PROGRESSIVE RENDERING WITH THREADGROUP EXPERIMENTS
    // Tests different threadgroup sizes to find optimal configuration
    // ═══════════════════════════════════════════════════════════════════════════
    
    /// Uniform layout for progressive shaders
    private struct ProgressiveUniformsLayout {
        var projectionMatrix: matrix_float4x4
        var viewMatrix: matrix_float4x4
        var inverseViewMatrix: matrix_float4x4
        var inverseProjectionMatrix: matrix_float4x4
        var resolution: SIMD2<Float>
        var tileOffset: SIMD2<UInt32>
        var tileSize: SIMD2<UInt32>
        var time: Float
        var minDistance: Float
        var fractalScale: Float
        var foldingLimit: Float
        var sphereRadius: Float
        var fractalIterations: Int32
        var maxRaySteps: Int32
        var frameIndex: Int32
        var totalTiles: Int32
        var currentTileIndex: Int32
        var blendWeight: Float
        var qualityMode: Int32
        var useDepthFromPrevious: Int32
    }
    
    /// Ensures progressive rendering textures exist and are correct size
    private func ensureProgressiveTextures(for drawable: LayerRenderer.Drawable, format: MTLPixelFormat) -> Bool {
        let width = drawable.colorTextures[0].width
        let height = drawable.colorTextures[0].height
        let requiredSize = SIMD2(width, height)
        
        if progressiveTextureSize == requiredSize &&
           progressiveDepthTexture != nil &&
           progressivePreviousFrame != nil &&
           progressiveOutputTexture != nil {
            return true
        }
        
        // Create depth texture (R32Float for distance values)
        let depthDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r32Float,
            width: width, height: height,
            mipmapped: false
        )
        depthDesc.usage = [.shaderRead, .shaderWrite]
        depthDesc.storageMode = .private
        progressiveDepthTexture = device.makeTexture(descriptor: depthDesc)
        progressiveDepthTexture?.label = "Progressive Depth"
        
        // Create previous frame texture (for temporal blending)
        let colorDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format,
            width: width, height: height,
            mipmapped: false
        )
        colorDesc.usage = [.shaderRead, .shaderWrite]
        colorDesc.storageMode = .private
        progressivePreviousFrame = device.makeTexture(descriptor: colorDesc)
        progressivePreviousFrame?.label = "Progressive Previous"
        
        // Create output texture
        progressiveOutputTexture = device.makeTexture(descriptor: colorDesc)
        progressiveOutputTexture?.label = "Progressive Output"
        
        progressiveTextureSize = requiredSize
        progressiveFrameIndex = 0
        
        print("📊 Progressive textures created: \(width)×\(height)")
        return progressiveDepthTexture != nil && progressivePreviousFrame != nil && progressiveOutputTexture != nil
    }
    
    /// Renders using progressive pipeline with configurable threadgroup size
    /// - Parameter threadgroupMode: 0 = 8x4 (32 threads), 1 = 4x8 (32 threads), 2 = 16x16 (256 threads for comparison)
    /// - Returns: true if rendering was performed
    private func renderWithProgressivePipeline(
        commandBuffer: MTLCommandBuffer,
        drawable: LayerRenderer.Drawable,
        settingsSnapshot: RenderSettingsSnapshot,
        threadgroupMode: Int = 0
    ) -> Bool {
        // Select pipeline based on mode
        let pipeline: MTLComputePipelineState?
        let threadsPerGroup: MTLSize
        
        switch threadgroupMode {
        case 0:
            pipeline = progressive8x4Pipeline
            threadsPerGroup = MTLSize(width: 8, height: 4, depth: 1)  // 32 threads = 1 SIMD
        case 1:
            pipeline = progressive4x8Pipeline
            threadsPerGroup = MTLSize(width: 4, height: 8, depth: 1)  // 32 threads = 1 SIMD
        default:
            pipeline = progressive8x4Pipeline
            threadsPerGroup = MTLSize(width: 8, height: 4, depth: 1)
        }
        
        guard let computePipeline = pipeline,
              let uniformBuffer = progressiveUniformBuffer else {
            return false
        }
        
        let drawableFormat = drawable.colorTextures[0].pixelFormat
        guard ensureProgressiveTextures(for: drawable, format: drawableFormat) else {
            return false
        }
        
        guard let outputTex = progressiveOutputTexture,
              let prevFrame = progressivePreviousFrame else {
            return false
        }
        
        let width = outputTex.width
        let height = outputTex.height
        
        // Render each eye
        for viewIndex in 0..<drawable.views.count {
            let view = drawable.views[viewIndex]
            
            // Get view matrices
            let deviceTransform = drawable.deviceAnchor?.originFromAnchorTransform ?? matrix_identity_float4x4
            let viewMatrix = (deviceTransform * view.transform).inverse
            let projection = drawable.computeProjection(viewIndex: viewIndex)
            
            // Fill uniforms
            var uniforms = ProgressiveUniformsLayout(
                projectionMatrix: projection,
                viewMatrix: viewMatrix,
                inverseViewMatrix: viewMatrix.inverse,
                inverseProjectionMatrix: projection.inverse,
                resolution: SIMD2<Float>(Float(width), Float(height)),
                tileOffset: SIMD2<UInt32>(0, 0),
                tileSize: SIMD2<UInt32>(UInt32(width), UInt32(height)),
                time: Float(appModel.clock.time),
                minDistance: settingsSnapshot.minDistance,
                fractalScale: settingsSnapshot.fractalScale,
                foldingLimit: settingsSnapshot.foldingLimit,
                sphereRadius: settingsSnapshot.sphereRadius,
                fractalIterations: Int32(settingsSnapshot.fractalIterations),
                maxRaySteps: Int32(settingsSnapshot.maxRaySteps),
                frameIndex: Int32(progressiveFrameIndex),
                totalTiles: 1,
                currentTileIndex: 0,
                blendWeight: progressiveFrameIndex == 0 ? 1.0 : 0.1,  // More weight to new frames initially
                qualityMode: 0,
                useDepthFromPrevious: progressiveFrameIndex > 0 ? 1 : 0
            )
            
            memcpy(uniformBuffer.contents(), &uniforms, MemoryLayout<ProgressiveUniformsLayout>.size)
            
            // Dispatch compute
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else { continue }
            encoder.label = "Progressive \(threadgroupMode == 0 ? "8x4" : "4x8") Eye \(viewIndex)"
            encoder.setComputePipelineState(computePipeline)
            encoder.setTexture(outputTex, index: 0)
            encoder.setTexture(prevFrame, index: 1)
            encoder.setBuffer(uniformBuffer, offset: 0, index: 0)
            
            let threadgroups = MTLSize(
                width: (width + threadsPerGroup.width - 1) / threadsPerGroup.width,
                height: (height + threadsPerGroup.height - 1) / threadsPerGroup.height,
                depth: 1
            )
            
            encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerGroup)
            encoder.endEncoding()
            
            // Blit to drawable
            guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else { continue }
            blitEncoder.label = "Progressive Blit Eye \(viewIndex)"
            
            let destTexture: MTLTexture
            if drawable.colorTextures.count > viewIndex {
                destTexture = drawable.colorTextures[viewIndex]
            } else {
                destTexture = drawable.colorTextures[0]
            }
            
            let destSlice = drawable.colorTextures.count > viewIndex ? 0 : viewIndex
            blitEncoder.copy(
                from: outputTex,
                sourceSlice: 0,
                sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(width: width, height: height, depth: 1),
                to: destTexture,
                destinationSlice: destSlice,
                destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
            )
            
            // Copy output to previous frame for next iteration
            blitEncoder.copy(from: outputTex, to: prevFrame)
            blitEncoder.endEncoding()
        }
        
        progressiveFrameIndex += 1
        
        // Log occasionally
        if progressiveFrameIndex == 1 || progressiveFrameIndex % 60 == 0 {
            let modeName = threadgroupMode == 0 ? "8×4 (32 threads)" : "4×8 (32 threads)"
            print("📊 Progressive render frame \(progressiveFrameIndex) using \(modeName)")
        }
        
        return true
    }
    
    /// Benchmarks different threadgroup configurations
    /// Call this periodically to profile performance
    func benchmarkThreadgroupSizes() async {
        guard let pipeline = progressiveBenchmarkPipeline,
              let uniformBuffer = progressiveUniformBuffer else {
            print("⚠️ Benchmark pipeline not available")
            return
        }
        
        // Create test texture
        let testSize = 1024
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: testSize, height: testSize,
            mipmapped: false
        )
        desc.usage = [.shaderWrite]
        desc.storageMode = .private
        
        guard let testTexture = device.makeTexture(descriptor: desc) else {
            print("⚠️ Could not create benchmark texture")
            return
        }
        
        // Test configurations
        let configs: [(String, MTLSize)] = [
            ("4×4 (16)", MTLSize(width: 4, height: 4, depth: 1)),
            ("8×4 (32)", MTLSize(width: 8, height: 4, depth: 1)),
            ("4×8 (32)", MTLSize(width: 4, height: 8, depth: 1)),
            ("8×8 (64)", MTLSize(width: 8, height: 8, depth: 1)),
            ("16×8 (128)", MTLSize(width: 16, height: 8, depth: 1)),
            ("16×16 (256)", MTLSize(width: 16, height: 16, depth: 1)),
            ("32×8 (256)", MTLSize(width: 32, height: 8, depth: 1)),
        ]
        
        print("\n═══════════════════════════════════════════════════")
        print("📊 THREADGROUP SIZE BENCHMARK")
        print("   Texture: \(testSize)×\(testSize), Pipeline maxThreads: \(pipeline.maxTotalThreadsPerThreadgroup)")
        print("═══════════════════════════════════════════════════")
        
        for (name, threadSize) in configs {
            // Skip if exceeds pipeline limits
            let totalThreads = threadSize.width * threadSize.height
            if totalThreads > pipeline.maxTotalThreadsPerThreadgroup {
                print("   \(name): SKIPPED (exceeds \(pipeline.maxTotalThreadsPerThreadgroup) max)")
                continue
            }
            
            guard let cmdBuffer = commandQueue.makeCommandBuffer() else { continue }
            
            // Fill uniforms with test values
            var uniforms = ProgressiveUniformsLayout(
                projectionMatrix: matrix_identity_float4x4,
                viewMatrix: matrix_identity_float4x4,
                inverseViewMatrix: matrix_identity_float4x4,
                inverseProjectionMatrix: matrix_identity_float4x4,
                resolution: SIMD2<Float>(Float(testSize), Float(testSize)),
                tileOffset: .zero,
                tileSize: SIMD2<UInt32>(UInt32(testSize), UInt32(testSize)),
                time: 0,
                minDistance: 0.5,
                fractalScale: 2.5,
                foldingLimit: 1.0,
                sphereRadius: 0.5,
                fractalIterations: 6,
                maxRaySteps: 48,
                frameIndex: 0,
                totalTiles: 1,
                currentTileIndex: 0,
                blendWeight: 1.0,
                qualityMode: 0,
                useDepthFromPrevious: 0
            )
            memcpy(uniformBuffer.contents(), &uniforms, MemoryLayout<ProgressiveUniformsLayout>.size)
            
            guard let encoder = cmdBuffer.makeComputeCommandEncoder() else { continue }
            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(testTexture, index: 0)
            encoder.setBuffer(uniformBuffer, offset: 0, index: 0)
            
            let threadgroups = MTLSize(
                width: (testSize + threadSize.width - 1) / threadSize.width,
                height: (testSize + threadSize.height - 1) / threadSize.height,
                depth: 1
            )
            
            encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadSize)
            encoder.endEncoding()
            
            let startTime = CACurrentMediaTime()
            cmdBuffer.commit()
            await cmdBuffer.completed()
            let elapsed = (CACurrentMediaTime() - startTime) * 1000.0
            
            print("   \(name): \(String(format: "%.2f", elapsed))ms")
        }
        
        print("═══════════════════════════════════════════════════\n")
    }
    
    // ═══════════════════════════════════════════════════════════════════════════
    // PIPELINE COMPONENT PROFILER
    // Tests each part of YOUR rendering pipeline to find bottlenecks
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
        print("📊 Pipeline profiler queued...")
    }
    
    /// Profile each component of your rendering pipeline
    /// Call this to find where time is actually being spent
    func profilePipelineComponents() {
        // Capture settings snapshot synchronously
        let settingsSnapshot = appModel.renderSettings.snapshot()
        
        // Create diagnostic pipeline
        guard let library = device.makeDefaultLibrary(),
              let diagnosticFunc = library.makeFunction(name: "diagnosticKernel"),
              let diagnosticPipeline = try? device.makeComputePipelineState(function: diagnosticFunc) else {
            print("⚠️ Could not create diagnostic pipeline")
            return
        }
        
        guard let uniformBuffer = device.makeBuffer(length: 512, options: .storageModeShared) else {
            return
        }
        
        // Test at a reasonable size
        let testSize = 512
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: testSize, height: testSize,
            mipmapped: false
        )
        desc.usage = [.shaderWrite]
        desc.storageMode = .private
        
        guard let testTexture = device.makeTexture(descriptor: desc) else {
            print("⚠️ Could not create test texture")
            return
        }
        
        // Capture current settings
        let currentIters = settingsSnapshot.fractalIterations
        let currentSteps = settingsSnapshot.maxRaySteps
        let currentScale = settingsSnapshot.fractalScale
        let currentFold = settingsSnapshot.foldingLimit
        let currentSphere = settingsSnapshot.sphereRadius
        let currentMinDist = settingsSnapshot.minDistance
        
        print("\n╔═══════════════════════════════════════════════════════════════╗")
        print("║        PIPELINE COMPONENT PROFILER                            ║")
        print("╠═══════════════════════════════════════════════════════════════╣")
        print("║  Current settings:                                            ║")
        print("║    Iterations: \(currentIters), Ray Steps: \(currentSteps)                          ║")
        print("║    Scale: \(String(format: "%.2f", currentScale)), Fold: \(String(format: "%.2f", currentFold)), Sphere: \(String(format: "%.2f", currentSphere))                  ║")
        print("╠═══════════════════════════════════════════════════════════════╣")
        
        let threadsPerGroup = MTLSize(width: 16, height: 16, depth: 1)
        let threadgroups = MTLSize(
            width: (testSize + 15) / 16,
            height: (testSize + 15) / 16,
            depth: 1
        )
        
        // Test each diagnostic mode
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
        
        print("╠═══════════════════════════════════════════════════════════════╣")
        print("║  ITERATION SCALING (fixed ray steps = \(currentSteps)):                    ║")
        print("╠═══════════════════════════════════════════════════════════════╣")
        
        // Test iteration scaling
        for iters in [2, 4, 6, 8, 10, 12] {
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
                diagnosticMode: 0,  // SDF only mode
                forceIterations: Int32(iters),
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
            
            print("║    \(iters) iterations:                                      \(String(format: "%6.2f", elapsed))ms ║")
        }
        
        print("╠═══════════════════════════════════════════════════════════════╣")
        print("║  RAY STEP SCALING (fixed iterations = \(currentIters)):                   ║")
        print("╠═══════════════════════════════════════════════════════════════╣")
        
        // Test ray step scaling  
        for steps in [16, 32, 48, 64, 96, 128] {
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
                diagnosticMode: 0,  // SDF only mode
                forceIterations: 0,
                forceRaySteps: Int32(steps)
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
            
            print("║    \(steps) ray steps:                                      \(String(format: "%6.2f", elapsed))ms ║")
        }
        
        print("╚═══════════════════════════════════════════════════════════════╝\n")
    }
}
