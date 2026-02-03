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

// The 256 byte aligned size of our uniform structure
let alignedUniformsSize = (MemoryLayout<UniformsArray>.size + 0xFF) & -0x100

// Double buffering for CPU/GPU pipelining.
// Allows CPU to prepare frame N+1 while GPU renders N.
// This prevents the 45fps vsync lock while minimizing latency.
let maxBuffersInFlight = 2

// Function constant indices - must match the indices in Shaders.metal
// These allow compile-time shader specialization for better performance
enum FunctionConstantIndex: Int {
    case fractalIterations = 0
    case shadowIterations = 1
    case safetyBubbleEnabled = 2
    case showHUD = 3
    case qualityMode = 4
    case debugHierarchical = 5
    case maxRaySteps = 6  // Base max ray steps (actual count scaled by quality at runtime)
    case emissiveEnabled = 7  // Eliminates emissive code path when false
    case neonModeEnabled = 8  // Eliminates neon orbit trap computation when false
    case colorIterations = 9  // Enables loop unrolling in ColourWithScheme
}

// Debug logging toggle - set to false for release builds
private let RENDERER_DEBUG = false

enum RendererError: Error {
    case badVertexDescriptor
}

extension LayerRenderer.Clock.Instant.Duration {
    var timeInterval: TimeInterval {
        let nanoseconds = TimeInterval(components.attoseconds / 1_000_000_000)
        return TimeInterval(components.seconds) + (nanoseconds / TimeInterval(NSEC_PER_SEC))
    }
}

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
    private typealias ImmersiveSpaceState = AppModel.ImmersiveSpaceState

    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    var dynamicUniformBuffer: MTLBuffer
    var pipelineState: MTLRenderPipelineState
    var quadSharedPipelineState: MTLRenderPipelineState?  // Quad-shared raymarch (2x2 sharing)
    var depthState: MTLDepthStencilState
    var cubeMap: MTLTexture
    
    // === UNIFIED PIPELINE CACHE ===
    // All specialized pipelines stored in a single cache with consistent key format.
    // Key format: "FI{iterations}_RS{raySteps}_E{0|1}_N{0|1}_Q{0|1|2}[_QS]"
    // This allows preset pipelines and quality preset pipelines to be looked up uniformly.
    //
    // Pipeline specialization strategy:
    // - Quality presets (iter6-iter16): Compiled with emissive=false, neon=false for speed
    // - Saved presets: Fully specialized with all known function constants
    // - On-demand: Built lazily when requested config not found in cache
    
    /// Unified pipeline cache - all specialized pipelines keyed by function constant signature
    private var pipelineCache: [String: MTLRenderPipelineState] = [:]
    
    // Cached constant matrices (computed once, reused every frame)
    private let cachedRotationMatrix: matrix_float4x4
    
    // Tile-based compute pipelines (adaptive 8x8 hierarchical cascade)
    var adaptiveHierarchicalPipeline8x8: MTLComputePipelineState?  // Adaptive 3-level cascade
    var tileUniformBuffer: MTLBuffer?
    
    // === STOCHASTIC RENDERING PIPELINES ===
    var stochasticRaymarchPipeline: MTLComputePipelineState?
    var stochasticCopyPipeline: MTLComputePipelineState?
    var stochasticResolvePipeline: MTLComputePipelineState?
    var stochasticClearPipeline: MTLComputePipelineState?
    var stochasticUniformBuffer: MTLBuffer?
    var stochasticAccumulationTextureL: MTLTexture?  // Left eye accumulation
    var stochasticAccumulationTextureR: MTLTexture?  // Right eye accumulation
    var stochasticOutputTexture: MTLTexture?         // Intermediate output
    
    // ═══════════════════════════════════════════════════════════════════════════
    // STABLE GEOMETRY RENDERING
    // When geometry parameters are stable, enables higher quality rendering.
    // NOTE: Temporal accumulation doesn't work well in VR due to head movement
    // invalidating previous samples. Instead, we use increased quality settings.
    // ═══════════════════════════════════════════════════════════════════════════
    private var stableGeometryAccumulationTextureL: MTLTexture?  // Left eye accumulation
    private var stableGeometryAccumulationTextureR: MTLTexture?  // Right eye accumulation
    private var stableGeometryOutputTexture: MTLTexture?         // Intermediate output
    private var stableGeometryTextureSize: SIMD2<Int> = .zero
    private var stableGeometryAccumulatedFrames: Int = 0         // Frames accumulated so far
    private var lastStableGeometryState: GeometryState = .dynamic
    private var hasLoggedStableGeometryMode = false
    // Head movement tracking - reset accumulation when head moves
    private var previousHeadPosition: SIMD3<Float> = .zero
    private var previousHeadRotation: simd_quatf = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    private let headMovementThreshold: Float = 0.001  // 1mm movement resets accumulation
    private let headRotationThreshold: Float = 0.001  // ~0.06 degrees rotation resets
    
    // Dedicated compute output texture (has .shaderWrite flag that drawable textures lack)
    var computeOutputTexture: MTLTexture?
    var computeOutputSize: SIMD2<Int> = .zero
    
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
    private var metalFXManager: MetalFXManager?
    private var metalFXFence: MTLFence?
    private var lastMetalFXInputSize: SIMD2<Int> = .zero
    private var lastMetalFXOutputSize: SIMD2<Int> = .zero
    private var hasLoggedMetalFXFallback = false
#endif

    // === DYNAMIC RENDER QUALITY (WWDC25 Session 294) ===
    // Adjusts LayerRenderer.renderQuality based on FPS performance
    private var dynamicRenderQualityManager: Any?  // Type-erased for @available
    private var hasLoggedDynamicQualityStatus = false
    
    // === RESIDENCY SET (visionOS 2.0+) ===
    // Pre-validates GPU resource residency to reduce per-frame validation overhead
    private var residencySet: MTLResidencySet?

    // Device pose smoothing removed — use raw device anchor from drawable for async timewarp
    
    // === STOCHASTIC RENDERING STATE ===
    // Tracks previous frame parameters to detect changes and reset accumulation
    private var lastStochasticPosition: SIMD3<Float> = .zero
    private var lastStochasticMinDistance: Float = 0
    private var lastStochasticFoldingLimit: Float = 0
    private var lastStochasticSphereRadius: Float = 0
    private var lastStochasticFractalScale: Float = 0
    private var stochasticAccumulationTexture: MTLTexture?
    private var hasLoggedStochasticMode = false

    // FPS tracking
    var lastPresentationTime: LayerRenderer.Clock.Instant?
    var smoothedFPS: Double = 0
    private var lastFPSUpdateTime: TimeInterval = 0
    private var lastHandTrackingUpdateTime: TimeInterval = 0  // Throttle hand UI updates
    private var cachedDeltaTime: Float = 1.0 / 90.0  // Cached for use in updateGameState
    private var lastPerfLogTime: TimeInterval = 0
    private let perfLogFrameMsThreshold: Double = 30.0  // ~33 FPS
    private var lastFPSConsoleLogTime: TimeInterval = 0  // For periodic FPS console logging

    var smoothedPosition: SIMD3<Float> = .zero
    var smoothedScale: Float = 1.0
    
    private var lastImmersiveSpaceState: ImmersiveSpaceState?


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
        // Quality presets compile out emissive/neon for maximum performance.
        // For features like emissive/neon, use saved presets which build fully-specialized pipelines.
        
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
            let unifiedKey = "FI\(iterCount)_RS\(raySteps)_E0_N0_Q\(qualityMode)"
            
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
        
        // Build special sphere mode pipeline (2 iterations for debug sphere effect)
        let sphereConfig = FunctionConstantConfig(
            fractalIterations: 2,
            shadowIterations: 0,
            safetyBubbleEnabled: nil,
            showHUD: nil,
            qualityMode: 2,
            debugHierarchical: nil,
            maxRaySteps: 32,
            emissiveEnabled: false,
            neonModeEnabled: false
        )
        let sphereConstants = sphereConfig.toMTLConstants()
        let sphereKey = "FI2_RS32_E0_N0_Q2"
        
        if let spherePipeline = try? Renderer.buildRenderPipelineWithDevice(
            device: device,
            layerRenderer: layerRenderer,
            rasterSampleCount: rasterSampleCount,
            mtlVertexDescriptor: mtlVertexDescriptor,
            functionConstants: sphereConstants
        ) {
            pipelineCache[sphereKey] = spherePipeline
            if RENDERER_DEBUG { print("✓ Built sphere mode pipeline: \(sphereKey)") }
        }
        
        if let sphereQuadPipeline = try? Renderer.buildRenderPipelineWithDevice(
            device: device,
            layerRenderer: layerRenderer,
            rasterSampleCount: rasterSampleCount,
            mtlVertexDescriptor: mtlVertexDescriptor,
            fragmentFunctionName: "fragmentShaderQuadShared",
            functionConstants: sphereConstants
        ) {
            pipelineCache[sphereKey + "_QS"] = sphereQuadPipeline
        }

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
            
            // Create specialized function constants for compute kernels
            // Known iteration count enables Map() loop auto-unrolling
            let computeConstants = MTLFunctionConstantValues()
            var fractalIters: Int32 = 6  // Default fractal iterations
            var shadowIters: Int32 = 4   // Default shadow iterations
            var maxRaySteps: Int32 = 32  // Default max ray steps
            var noSafetyBubble: Bool = false
            var noDebug: Bool = false
            var noHUD: Bool = false       // Compute doesn't need HUD
            var noEmissive: Bool = false  // Compile out emissive for compute
            var noNeon: Bool = false      // Compile out neon for compute
            computeConstants.setConstantValue(&fractalIters, type: .int, index: FunctionConstantIndex.fractalIterations.rawValue)
            computeConstants.setConstantValue(&shadowIters, type: .int, index: FunctionConstantIndex.shadowIterations.rawValue)
            computeConstants.setConstantValue(&maxRaySteps, type: .int, index: FunctionConstantIndex.maxRaySteps.rawValue)
            computeConstants.setConstantValue(&noSafetyBubble, type: .bool, index: FunctionConstantIndex.safetyBubbleEnabled.rawValue)
            computeConstants.setConstantValue(&noDebug, type: .bool, index: FunctionConstantIndex.debugHierarchical.rawValue)
            computeConstants.setConstantValue(&noHUD, type: .bool, index: FunctionConstantIndex.showHUD.rawValue)
            computeConstants.setConstantValue(&noEmissive, type: .bool, index: FunctionConstantIndex.emissiveEnabled.rawValue)
            computeConstants.setConstantValue(&noNeon, type: .bool, index: FunctionConstantIndex.neonModeEnabled.rawValue)
            
            // Adaptive 8x8 hierarchical kernel (3-level cascade, 3-8x speedup) - with function constants
            if let kernel8x8 = try? library.makeFunction(name: "adaptiveHierarchical8x8", constantValues: computeConstants) {
                adaptiveHierarchicalPipeline8x8 = try device.makeComputePipelineState(function: kernel8x8)
                if RENDERER_DEBUG { print("✓ Adaptive 8x8 hierarchical pipeline specialized with function constants") }
            } else if let kernel8x8 = library.makeFunction(name: "adaptiveHierarchical8x8") {
                adaptiveHierarchicalPipeline8x8 = try device.makeComputePipelineState(function: kernel8x8)
                if RENDERER_DEBUG { print("✓ Adaptive 8x8 hierarchical pipeline ready (3-level cascade)") }
            }
            
            // Uniform buffer for tile compute (one per eye)
            let tileUniformSize = MemoryLayout<TileUniforms>.stride * 2
            tileUniformBuffer = device.makeBuffer(length: tileUniformSize, options: .storageModeShared)
            tileUniformBuffer?.label = "TileUniforms"
            
            if RENDERER_DEBUG { print("✓ Tile-based compute pipeline ready (adaptive 8x8)") }
            
            // === STOCHASTIC RENDERING PIPELINES ===
            // Use function constants for JIT optimization - stochastic rendering benefits from
            // specialized iteration counts since it runs higher-quality settings
            if let stochasticRaymarchKernel = try? library.makeFunction(name: "stochasticRaymarchKernel", constantValues: computeConstants) {
                stochasticRaymarchPipeline = try device.makeComputePipelineState(function: stochasticRaymarchKernel)
                if RENDERER_DEBUG { print("✓ Stochastic raymarch pipeline specialized with function constants") }
            } else if let stochasticRaymarchKernel = library.makeFunction(name: "stochasticRaymarchKernel") {
                stochasticRaymarchPipeline = try device.makeComputePipelineState(function: stochasticRaymarchKernel)
            }
            if let stochasticCopyKernel = library.makeFunction(name: "copyToAccumulationKernel") {
                stochasticCopyPipeline = try device.makeComputePipelineState(function: stochasticCopyKernel)
            }
            if let stochasticResolveKernel = library.makeFunction(name: "resolveStochasticKernel") {
                stochasticResolvePipeline = try device.makeComputePipelineState(function: stochasticResolveKernel)
            }
            if let stochasticClearKernel = library.makeFunction(name: "clearAccumulationKernel") {
                stochasticClearPipeline = try device.makeComputePipelineState(function: stochasticClearKernel)
            }
            
            // Stochastic uniform buffer (large enough for StochasticUniforms)
            let stochasticUniformSize = 1024  // Generous size for StochasticUniforms
            stochasticUniformBuffer = device.makeBuffer(length: stochasticUniformSize, options: .storageModeShared)
            stochasticUniformBuffer?.label = "StochasticUniforms"
            
            if stochasticRaymarchPipeline != nil {
                print("✓ Stochastic rendering pipelines ready")
            }
            
            // === PROGRESSIVE RENDERING PIPELINES ===
            // Different threadgroup configurations for performance experimentation
            // Use function constants for JIT optimization where applicable
            if let depthKernel = try? library.makeFunction(name: "progressiveDepthPass", constantValues: computeConstants) {
                progressiveDepthPipeline = try device.makeComputePipelineState(function: depthKernel)
                if RENDERER_DEBUG { print("✓ Progressive depth pipeline specialized with function constants") }
            } else if let depthKernel = library.makeFunction(name: "progressiveDepthPass") {
                progressiveDepthPipeline = try device.makeComputePipelineState(function: depthKernel)
            }
            if let colorKernel = try? library.makeFunction(name: "progressiveColorPass", constantValues: computeConstants) {
                progressiveColorPipeline = try device.makeComputePipelineState(function: colorKernel)
                if RENDERER_DEBUG { print("✓ Progressive color pipeline specialized with function constants") }
            } else if let colorKernel = library.makeFunction(name: "progressiveColorPass") {
                progressiveColorPipeline = try device.makeComputePipelineState(function: colorKernel)
            }
            if let kernel8x4 = try? library.makeFunction(name: "progressiveSinglePass_8x4", constantValues: computeConstants) {
                progressive8x4Pipeline = try device.makeComputePipelineState(function: kernel8x4)
                if RENDERER_DEBUG { print("✓ Progressive 8x4 pipeline specialized with function constants") }
                // Log pipeline characteristics
                if let pipeline = progressive8x4Pipeline {
                    print("  maxTotalThreads=\(pipeline.maxTotalThreadsPerThreadgroup), executionWidth=\(pipeline.threadExecutionWidth)")
                }
            } else if let kernel8x4 = library.makeFunction(name: "progressiveSinglePass_8x4") {
                progressive8x4Pipeline = try device.makeComputePipelineState(function: kernel8x4)
                // Log pipeline characteristics
                if let pipeline = progressive8x4Pipeline {
                    print("✓ Progressive 8x4 pipeline: maxTotalThreads=\(pipeline.maxTotalThreadsPerThreadgroup), executionWidth=\(pipeline.threadExecutionWidth)")
                }
            }
            if let kernel4x8 = try? library.makeFunction(name: "progressiveSinglePass_4x8", constantValues: computeConstants) {
                progressive4x8Pipeline = try device.makeComputePipelineState(function: kernel4x8)
                if RENDERER_DEBUG { print("✓ Progressive 4x8 pipeline specialized with function constants") }
            } else if let kernel4x8 = library.makeFunction(name: "progressiveSinglePass_4x8") {
                progressive4x8Pipeline = try device.makeComputePipelineState(function: kernel4x8)
            }
            if let benchmarkKernel = try? library.makeFunction(name: "benchmarkKernel", constantValues: computeConstants) {
                progressiveBenchmarkPipeline = try device.makeComputePipelineState(function: benchmarkKernel)
                if RENDERER_DEBUG { print("✓ Progressive benchmark pipeline specialized with function constants") }
            } else if let benchmarkKernel = library.makeFunction(name: "benchmarkKernel") {
                progressiveBenchmarkPipeline = try device.makeComputePipelineState(function: benchmarkKernel)
            }
            
            // Progressive uniform buffer
            progressiveUniformBuffer = device.makeBuffer(length: 512, options: .storageModeShared)
            progressiveUniformBuffer?.label = "ProgressiveUniforms"
            
            if progressive8x4Pipeline != nil {
                print("✓ Progressive rendering pipelines ready (8x4, 4x8 variants)")
            }
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
    
    /// Setup residency set for GPU resource pre-validation
    private func setupResidencySet() {
        if #available(visionOS 2.0, iOS 18.0, macOS 15.0, *) {
            let descriptor = MTLResidencySetDescriptor()
            descriptor.label = "FractalResidencySet"
            // Initial capacity - will grow as needed
            descriptor.initialCapacity = 8
            
            do {
                residencySet = try device.makeResidencySet(descriptor: descriptor)
                
                // Add persistent resources
                residencySet?.addAllocation(dynamicUniformBuffer)
                residencySet?.addAllocation(cubeMap)
                
                if let tileBuffer = tileUniformBuffer {
                    residencySet?.addAllocation(tileBuffer)
                }
                
                // Commit the set (validates all resources)
                residencySet?.commit()
                
                // Request initial residency
                residencySet?.requestResidency()
                
                if RENDERER_DEBUG { print("✓ Residency set created with \(residencySet?.allocatedSize ?? 0) bytes") }
            } catch {
                if RENDERER_DEBUG { print("⚠️ Failed to create residency set: \(error)") }
                residencySet = nil
            }
        }
    }
    
    /// Update residency set when compute output texture changes
    private func updateResidencySetForComputeTexture(_ texture: MTLTexture) {
        if #available(visionOS 2.0, iOS 18.0, macOS 15.0, *) {
            guard let set = residencySet else { return }
            
            // Add the new texture allocation
            set.addAllocation(texture)
            
            // Re-commit and request residency
            set.commit()
            set.requestResidency()
        }
    }
    
    /// Setup dynamic render quality management (visionOS 26+)
    private func setupDynamicRenderQuality() {
        if #available(visionOS 26.0, *) {
            let settings = appModel.renderSettings
            let manager = DynamicRenderQualityManager(defaultQuality: settings.dynamicRenderQualityTarget)
            manager.minQuality = settings.dynamicRenderQualityMin
            manager.maxQuality = settings.dynamicRenderQualityMax
            manager.isEnabled = settings.dynamicRenderQualityEnabled
            manager.debugLogging = false  // Enable for debugging
            dynamicRenderQualityManager = manager
            
            if layerRenderer.configuration.isFoveationEnabled {
                if RENDERER_DEBUG {
                    print("✓ Dynamic render quality manager initialized (visionOS 26+)")
                    print("  Target: \(settings.dynamicRenderQualityTarget), Range: \(settings.dynamicRenderQualityMin)-\(settings.dynamicRenderQualityMax)")
                }
            } else {
                if RENDERER_DEBUG { print("ℹ️ Dynamic render quality: Foveation not enabled (quality adjustment disabled)") }
            }
        } else {
            if RENDERER_DEBUG { print("ℹ️ Dynamic render quality: Requires visionOS 26+") }
        }
    }
    
    /// Setup screenshot capture resources
    private func setupScreenshotCapture() {
        // Create a standard render pipeline for screenshot capture (no vertex amplification)
        // We'll render a single view at 512x512 for preset thumbnails
        let screenshotSize = 512
        
        // Create screenshot color texture
        let colorDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: screenshotSize,
            height: screenshotSize,
            mipmapped: false
        )
        colorDescriptor.usage = [.renderTarget, .shaderRead]
        colorDescriptor.storageMode = .shared  // Allows CPU read
        screenshotTexture = device.makeTexture(descriptor: colorDescriptor)
        screenshotTexture?.label = "Screenshot Color"
        
        // Create screenshot depth texture
        let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float,
            width: screenshotSize,
            height: screenshotSize,
            mipmapped: false
        )
        depthDescriptor.usage = [.renderTarget]
        depthDescriptor.storageMode = .private
        screenshotDepthTexture = device.makeTexture(descriptor: depthDescriptor)
        screenshotDepthTexture?.label = "Screenshot Depth"
        
        // Create render pipeline for screenshot (single view, no amplification)
        // Must use function constants because fragmentShader declares them
        do {
            let library = device.makeDefaultLibrary()!
            let vertexFunction = library.makeFunction(name: "screenshotVertexShader")
            // Use empty function constants - required once shader declares function constants
            let fragmentFunction = try library.makeFunction(name: "fragmentShader", constantValues: MTLFunctionConstantValues())
            
            let pipelineDescriptor = MTLRenderPipelineDescriptor()
            pipelineDescriptor.label = "Screenshot Pipeline"
            pipelineDescriptor.vertexFunction = vertexFunction
            pipelineDescriptor.fragmentFunction = fragmentFunction
            pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipelineDescriptor.depthAttachmentPixelFormat = .depth32Float
            
            let mtlVertexDescriptor = Renderer.buildMetalVertexDescriptor()
            pipelineDescriptor.vertexDescriptor = mtlVertexDescriptor
            
            screenshotPipeline = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
            if RENDERER_DEBUG { print("✓ Screenshot capture pipeline ready") }
        } catch {
            if RENDERER_DEBUG { print("⚠️ Failed to create screenshot pipeline: \(error)") }
        }
    }

    private func startARSession() async {
        // We only request head-tracking permission so we can keep the request minimal
        guard WorldTrackingProvider.isSupported else {
            if RENDERER_DEBUG { print("⚠️ World tracking is not supported on this device") }
            return
        }

        if RENDERER_DEBUG { print("ℹ️ Requesting only world sensing (for pose) plus hand tracking; no extra sensors requested.") }
        var authStatus = await arSession.queryAuthorization(for: [.worldSensing, .handTracking])
        if authStatus[.worldSensing] == .notDetermined || authStatus[.handTracking] == .notDetermined {
            if RENDERER_DEBUG { print("🔐 Requesting ARKit world-sensing + hand-tracking authorization") }
            authStatus = await arSession.requestAuthorization(for: [.worldSensing, .handTracking])
        }

        if authStatus[.worldSensing] != .allowed {
            if RENDERER_DEBUG {
                print("⚠️ World sensing not authorized. Status: \(String(describing: authStatus[.worldSensing]))")
                print("   Pose will be limited (rotation only)")
            }
        }

        if authStatus[.handTracking] != .allowed {
            if RENDERER_DEBUG { print("⚠️ Hand tracking not authorized. Status: \(String(describing: authStatus[.handTracking]))") }
        }
        
        do {
            var providers: [any DataProvider] = [worldTracking]
            if let ht = handTracking, authStatus[.handTracking] == .allowed {
                providers.append(ht)
            }
            try await arSession.run(providers)
            if RENDERER_DEBUG {
                print("✓ ARKit session started with world tracking and hand tracking")
                print("  World tracking state: \(worldTracking.state)")
            }
        } catch {
            if !hasLoggedWorldTrackingWarning {
                if RENDERER_DEBUG { print("⚠️ ARKit session failed: \(error)") }
                hasLoggedWorldTrackingWarning = true
            }
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
                    _ = await renderer.getPipeline(forIterations: iterations, raySteps: raySteps, useQuadShared: false)
                    _ = await renderer.getPipeline(forIterations: iterations, raySteps: raySteps, useQuadShared: true)
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
    
    /// Request a screenshot capture (async)
    func captureScreenshot() async -> Data? {
        return await withCheckedContinuation { continuation in
            self.pendingScreenshotContinuation = continuation
            self.shouldCaptureScreenshot = true
        }
    }
    
    /// Render and capture a screenshot to PNG data
    private func renderScreenshot() -> Data? {
        guard let screenshotTexture = screenshotTexture,
              let screenshotPipeline = screenshotPipeline,
              let screenshotDepthTexture = screenshotDepthTexture,
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            return nil
        }
        
        // Setup render pass for screenshot
        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = screenshotTexture
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0)
        
        renderPassDescriptor.depthAttachment.texture = screenshotDepthTexture
        renderPassDescriptor.depthAttachment.loadAction = .clear
        renderPassDescriptor.depthAttachment.storeAction = .dontCare
        renderPassDescriptor.depthAttachment.clearDepth = 1.0
        
        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return nil
        }
        
        renderEncoder.label = "Screenshot Render Encoder"
        renderEncoder.setCullMode(.front)
        renderEncoder.setFrontFacing(.counterClockwise)
        renderEncoder.setRenderPipelineState(screenshotPipeline)
        renderEncoder.setDepthStencilState(depthState)
        
        // Use current uniforms (view 0)
        renderEncoder.setVertexBuffer(dynamicUniformBuffer, offset: uniformBufferOffset, index: BufferIndex.uniforms.rawValue)
        renderEncoder.setFragmentBuffer(dynamicUniformBuffer, offset: uniformBufferOffset, index: BufferIndex.uniforms.rawValue)
        
        // Set viewport for screenshot size
        let viewport = MTLViewport(originX: 0, originY: 0, 
                                   width: Double(screenshotTexture.width), 
                                   height: Double(screenshotTexture.height),
                                   znear: 0, zfar: 1)
        renderEncoder.setViewport(viewport)
        
        // Bind mesh vertices
        for (index, element) in mesh.vertexDescriptor.layouts.enumerated() {
            guard let layout = element as? MDLVertexBufferLayout, layout.stride != 0 else { continue }
            let buffer = mesh.vertexBuffers[index]
            renderEncoder.setVertexBuffer(buffer.buffer, offset: buffer.offset, index: index)
        }
        
        // Bind textures
        renderEncoder.setFragmentTexture(cubeMap, index: TextureIndex.color.rawValue)
        
        // Draw
        for submesh in mesh.submeshes {
            renderEncoder.drawIndexedPrimitives(type: submesh.primitiveType,
                                                indexCount: submesh.indexCount,
                                                indexType: submesh.indexType,
                                                indexBuffer: submesh.indexBuffer.buffer,
                                                indexBufferOffset: submesh.indexBuffer.offset)
        }
        
        renderEncoder.endEncoding()
        
        // Synchronize for CPU read (needed on macOS only, not available on visionOS)
        #if os(macOS)
        if let blitEncoder = commandBuffer.makeBlitCommandEncoder() {
            blitEncoder.synchronize(resource: screenshotTexture)
            blitEncoder.endEncoding()
        }
        #endif
        
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        
        // Read texture data and convert to PNG
        return textureToImageData(screenshotTexture)
    }
    
    /// Convert a Metal texture to PNG image data
    private func textureToImageData(_ texture: MTLTexture) -> Data? {
        let width = texture.width
        let height = texture.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let totalBytes = bytesPerRow * height
        
        var pixelData = [UInt8](repeating: 0, count: totalBytes)
        
        texture.getBytes(&pixelData,
                        bytesPerRow: bytesPerRow,
                        from: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                                       size: MTLSize(width: width, height: height, depth: 1)),
                        mipmapLevel: 0)
        
        // Create CGImage from pixel data
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        
        guard let context = CGContext(data: &pixelData,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow,
                                      space: colorSpace,
                                      bitmapInfo: bitmapInfo.rawValue),
              let cgImage = context.makeImage() else {
            return nil
        }
        
        #if os(visionOS) || os(iOS)
        let image = UIImage(cgImage: cgImage)
        return image.pngData()
        #elseif os(macOS)
        let image = NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
        guard let tiffData = image.tiffRepresentation,
              let bitmapRep = NSBitmapImageRep(data: tiffData) else {
            return nil
        }
        return bitmapRep.representation(using: .png, properties: [:])
        #endif
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

    static func buildRenderPipelineWithDevice(device: MTLDevice,
                                              layerRenderer: LayerRenderer,
                                              rasterSampleCount: Int,
                                              mtlVertexDescriptor: MTLVertexDescriptor,
                                              colorFormat: MTLPixelFormat? = nil,
                                              vertexFunctionName: String = "vertexShader",
                                              fragmentFunctionName: String = "fragmentShader",
                                              usesVertexAmplification: Bool = true,
                                              functionConstants: MTLFunctionConstantValues? = nil) throws -> MTLRenderPipelineState {
        /// Build a render state pipeline object

        let library = device.makeDefaultLibrary()

        let vertexFunction = library?.makeFunction(name: vertexFunctionName)
        
        // IMPORTANT: Once a shader declares function constants, Metal requires using
        // makeFunction(name:constantValues:) even if no values are being set.
        // Always provide function constants (empty if nil) for fragment shaders that use them.
        let fragmentFunction: MTLFunction?
        let constants = functionConstants ?? MTLFunctionConstantValues()
        fragmentFunction = try library?.makeFunction(name: fragmentFunctionName, constantValues: constants)

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.label = functionConstants != nil ? "RenderPipeline_Specialized" : "RenderPipeline"
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.vertexDescriptor = mtlVertexDescriptor
        pipelineDescriptor.rasterSampleCount = rasterSampleCount

        pipelineDescriptor.colorAttachments[0].pixelFormat = colorFormat ?? layerRenderer.configuration.colorFormat
        pipelineDescriptor.depthAttachmentPixelFormat = layerRenderer.configuration.depthFormat

        pipelineDescriptor.maxVertexAmplificationCount = usesVertexAmplification ? layerRenderer.properties.viewCount : 1

        return try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
    }
    
    /// Function constant configuration for shader specialization
    struct FunctionConstantConfig {
        var fractalIterations: Int32?      // FC index 0
        var shadowIterations: Int32?       // FC index 1
        var safetyBubbleEnabled: Bool?     // FC index 2
        var showHUD: Bool?                 // FC index 3
        var qualityMode: Int32?            // FC index 4 (0=high, 1=medium, 2=low)
        var debugHierarchical: Bool?       // FC index 5
        var maxRaySteps: Int32?            // FC index 6 - max ray marching steps
        var emissiveEnabled: Bool?         // FC index 7 - eliminates emissive code path
        var neonModeEnabled: Bool?         // FC index 8 - eliminates neon orbit tracking
        var colorIterations: Int32?        // FC index 9 - enables loop unrolling in color
        
        /// Creates MTLFunctionConstantValues from this config
        func toMTLConstants() -> MTLFunctionConstantValues {
            let constants = MTLFunctionConstantValues()
            
            if var iterations = fractalIterations {
                print("🔧 [FUNCTION CONSTANT] Setting FC_FRACTAL_ITERATIONS = \(iterations)")
                constants.setConstantValue(&iterations, type: .int, index: FunctionConstantIndex.fractalIterations.rawValue)
            }
            if var shadowIters = shadowIterations {
                constants.setConstantValue(&shadowIters, type: .int, index: FunctionConstantIndex.shadowIterations.rawValue)
            }
            if var bubble = safetyBubbleEnabled {
                constants.setConstantValue(&bubble, type: .bool, index: FunctionConstantIndex.safetyBubbleEnabled.rawValue)
            }
            if var hud = showHUD {
                constants.setConstantValue(&hud, type: .bool, index: FunctionConstantIndex.showHUD.rawValue)
            }
            if var quality = qualityMode {
                constants.setConstantValue(&quality, type: .int, index: FunctionConstantIndex.qualityMode.rawValue)
            }
            if var debug = debugHierarchical {
                constants.setConstantValue(&debug, type: .bool, index: FunctionConstantIndex.debugHierarchical.rawValue)
            }
            if var raySteps = maxRaySteps {
                constants.setConstantValue(&raySteps, type: .int, index: FunctionConstantIndex.maxRaySteps.rawValue)
            }
            if var emissive = emissiveEnabled {
                constants.setConstantValue(&emissive, type: .bool, index: FunctionConstantIndex.emissiveEnabled.rawValue)
            }
            if var neon = neonModeEnabled {
                constants.setConstantValue(&neon, type: .bool, index: FunctionConstantIndex.neonModeEnabled.rawValue)
            }
            if var colorIters = colorIterations {
                constants.setConstantValue(&colorIters, type: .int, index: FunctionConstantIndex.colorIterations.rawValue)
            }
            
            return constants
        }
        
        /// Creates a config optimized for high performance (Low quality preset: FI=6, RI=32)
        /// All optional features compiled out for maximum speed.
        static var highPerformance: FunctionConstantConfig {
            return FunctionConstantConfig(
                fractalIterations: 6,
                shadowIterations: 4,
                safetyBubbleEnabled: false,
                showHUD: false,
                qualityMode: 2,  // Low quality
                debugHierarchical: false,
                maxRaySteps: 32,
                emissiveEnabled: false,  // Compile out emissive
                neonModeEnabled: false,  // Compile out neon
                colorIterations: 6       // Match fractal iterations
            )
        }
        
        /// Creates a config for high quality rendering (Ultra quality preset: FI=16, RI=128)
        /// All optional features available.
        static var highQuality: FunctionConstantConfig {
            return FunctionConstantConfig(
                fractalIterations: 16,
                shadowIterations: 14,
                safetyBubbleEnabled: true,
                showHUD: true,
                qualityMode: 0,  // High quality
                debugHierarchical: false,
                maxRaySteps: 128,
                emissiveEnabled: nil,    // Runtime (not specialized)
                neonModeEnabled: nil,    // Runtime (not specialized)
                colorIterations: 16      // Match fractal iterations
            )
        }
        
        /// Creates a config for each quality preset.
        /// These pipelines compile out emissive/neon code for maximum performance.
        /// For presets that need emissive/neon, use fromPreset() instead.
        static func forQualityPreset(_ preset: QualityPreset) -> FunctionConstantConfig {
            let qualityMode: Int32
            switch preset {
            case .low: qualityMode = 2     // 6 iterations - fast preview
            case .medium: qualityMode = 1  // 9 iterations - balanced
            case .high: qualityMode = 0    // 12 iterations - quality
            }
            return FunctionConstantConfig(
                fractalIterations: Int32(preset.fractalIterations),
                shadowIterations: Int32(max(preset.fractalIterations - 2, 2)),
                safetyBubbleEnabled: true,
                showHUD: false,              // Compile out HUD for these fast pipelines
                qualityMode: qualityMode,
                debugHierarchical: false,
                maxRaySteps: Int32(preset.raySteps),
                emissiveEnabled: false,      // Compile out emissive code path
                neonModeEnabled: false,      // Compile out neon orbit tracking
                colorIterations: nil         // Use runtime value for color flexibility
            )
        }
        
        /// Creates a fully-specialized config from a saved FractalPreset.
        /// This enables maximum shader optimization by providing all known constants.
        ///
        /// Example usage:
        /// ```swift
        /// let preset = presetManager.presets.first!
        /// let config = FunctionConstantConfig.fromPreset(preset)
        /// let pipeline = try Renderer.buildSpecializedPipeline(config: config, ...)
        /// ```
        static func fromPreset(_ preset: FractalPreset) -> FunctionConstantConfig {
            let fc = preset.deriveFunctionConstants()
            return FunctionConstantConfig(
                fractalIterations: fc.fractalIterations,
                shadowIterations: fc.shadowIterations,
                safetyBubbleEnabled: fc.safetyBubbleEnabled,
                showHUD: true,
                qualityMode: fc.qualityMode,
                debugHierarchical: false,
                maxRaySteps: fc.maxRaySteps,
                emissiveEnabled: fc.emissiveEnabled,
                neonModeEnabled: fc.neonModeEnabled,
                colorIterations: fc.colorIterations
            )
        }
    }
    
    // MARK: - Unified Pipeline Management
    
    /// Gets or builds a specialized pipeline for a given preset.
    /// Uses the unified pipelineCache to avoid redundant compilation.
    func getPipeline(forPreset preset: FractalPreset, useQuadShared: Bool = false) -> MTLRenderPipelineState {
        let cacheKey = preset.pipelineCacheKey + (useQuadShared ? "_QS" : "")
        
        // Check unified cache first
        if let cached = pipelineCache[cacheKey] {
            return cached
        }
        
        // Build new specialized pipeline
        let config = FunctionConstantConfig.fromPreset(preset)
        if RENDERER_DEBUG { print("🔧 [ShaderCompilation] Building NEW pipeline for: \(preset.name) [\(cacheKey)]") }
        
        do {
            let pipeline = try Renderer.buildSpecializedPipeline(
                device: device,
                layerRenderer: layerRenderer,
                rasterSampleCount: rasterSampleCount,
                mtlVertexDescriptor: mtlVertexDescriptor,
                config: config,
                fragmentFunctionName: useQuadShared ? "fragmentShaderQuadShared" : "fragmentShader"
            )
            pipelineCache[cacheKey] = pipeline  // Store in unified cache
            if RENDERER_DEBUG { print("✅ [ShaderCompilation] SUCCESS: Built pipeline [\(cacheKey)]") }
            return pipeline
        } catch {
            if RENDERER_DEBUG { print("❌ [ShaderCompilation] FAILED to build preset pipeline [\(cacheKey)]: \(error)") }
            return useQuadShared ? (quadSharedPipelineState ?? pipelineState) : pipelineState
        }
    }
    
    /// Gets or builds a specialized pipeline for specific iteration/ray step values.
    /// Call this when slider values change to pre-compile the needed pipeline.
    func getPipeline(forIterations iterations: Int, raySteps: Int, useQuadShared: Bool = false) -> MTLRenderPipelineState {
        // Build cache key matching the preset format
        let settingsSnapshot = appModel.renderSettings.snapshot()
        let colorScheme = appModel.renderSettings.colorScheme  // Read directly - not in snapshot
        let emissive = settingsSnapshot.emissiveEnabled ? 1 : 0
        let neon = colorScheme.rawValue >= 8 ? 1 : 0  // neonCyber, neonSunset, neonMatrix
        let qualityMode: Int32 = iterations <= 7 ? 2 : (iterations <= 9 ? 1 : 0)
        let cacheKey = "FI\(iterations)_RS\(raySteps)_E\(emissive)_N\(neon)_Q\(qualityMode)" + (useQuadShared ? "_QS" : "")
        
        // Check unified cache first
        if let cached = pipelineCache[cacheKey] {
            return cached
        }
        
        // Build new specialized pipeline
        let config = FunctionConstantConfig(
            fractalIterations: Int32(iterations),
            shadowIterations: Int32(max(iterations - 2, 2)),
            safetyBubbleEnabled: true,
            showHUD: true,
            qualityMode: qualityMode,
            debugHierarchical: false,
            maxRaySteps: Int32(raySteps),
            emissiveEnabled: settingsSnapshot.emissiveEnabled,
            neonModeEnabled: neon == 1,
            colorIterations: Int32(settingsSnapshot.colorIterations)  // Use actual color iterations, not fractal iterations
        )
        
        print("🔧 [ShaderCompilation] Building pipeline for FI=\(iterations) RS=\(raySteps)...")
        
        do {
            let pipeline = try Renderer.buildSpecializedPipeline(
                device: device,
                layerRenderer: layerRenderer,
                rasterSampleCount: rasterSampleCount,
                mtlVertexDescriptor: mtlVertexDescriptor,
                config: config,
                fragmentFunctionName: useQuadShared ? "fragmentShaderQuadShared" : "fragmentShader"
            )
            pipelineCache[cacheKey] = pipeline
            print("✅ [ShaderCompilation] Ready: FI=\(iterations) RS=\(raySteps)")
            return pipeline
        } catch {
            print("❌ [ShaderCompilation] FAILED for FI=\(iterations) RS=\(raySteps): \(error)")
            return useQuadShared ? (quadSharedPipelineState ?? pipelineState) : pipelineState
        }
    }
    
    /// Precompiles pipelines for a list of presets (e.g., on app launch).
    /// Call this during loading screen to avoid compilation hitches when switching presets.
    func precompilePipelines(forPresets presets: [FractalPreset]) {
        if RENDERER_DEBUG { print("Precompiling \(presets.count) preset pipelines...") }
        for preset in presets {
            _ = getPipeline(forPreset: preset, useQuadShared: false)
            _ = getPipeline(forPreset: preset, useQuadShared: true)
        }
        if RENDERER_DEBUG { print("✓ Preset pipeline precompilation complete") }
    }
    
    /// Precompiles pipelines for all saved presets on app launch.
    /// Runs asynchronously to avoid blocking the main thread.
    private func precompilePresetPipelines() async {
        // Access presets from AppModel on main actor
        let presets = await MainActor.run { 
            appModel.presetManager.presets
        }
        
        guard !presets.isEmpty else {
            if RENDERER_DEBUG { print("🔧 [ShaderCompilation] No saved presets to precompile") }
            return
        }
        
        // Build pipelines for unique configurations only
        var compiledKeys = Set<String>()
        var compiledCount = 0
        
        if RENDERER_DEBUG { print("🔧 [ShaderCompilation] Starting preset pipeline precompilation for \(presets.count) presets...") }
        
        for preset in presets {
            let key = preset.pipelineCacheKey
            guard !compiledKeys.contains(key) else {
                if RENDERER_DEBUG { print("  ⏭️  Skipping \(preset.name) - duplicate config [\(key)]") }
                continue  // Skip duplicate configurations
            }
            compiledKeys.insert(key)
            
            if RENDERER_DEBUG {
                let fc = preset.deriveFunctionConstants()
                print("  🔨 Compiling: \(preset.name)")
                print("      Key: \(key)")
                print("      FractalIters=\(fc.fractalIterations), RaySteps=\(fc.maxRaySteps), Shadow=\(fc.shadowIterations)")
                print("      Emissive=\(fc.emissiveEnabled), Neon=\(fc.neonModeEnabled), Quality=\(fc.qualityMode)")
            }
            
            // Build both standard and quad-shared variants
            _ = getPipeline(forPreset: preset, useQuadShared: false)
            _ = getPipeline(forPreset: preset, useQuadShared: true)
            compiledCount += 1
        }
        
        if RENDERER_DEBUG {
            print("✅ [ShaderCompilation] Precompiled \(compiledCount) unique preset pipelines (from \(presets.count) presets)")
            print("   Unified cache now contains \(pipelineCache.count) pipelines")
        }
    }
    
    // Track last logged pipeline to avoid spam
    private var lastLoggedPipelineKey: String = ""
    
    /// Select the best specialized pipeline for the current render settings.
    /// Uses the unified pipelineCache for all lookups - no separate cache tiers.
    ///
    /// Pipeline lookup order:
    /// 1. Exact match in unified cache (includes both quality presets and saved presets)
    /// 2. Fallback to generic pipeline
    ///
    /// On cache miss for a non-standard configuration, consider calling `ensurePipeline()`
    /// to build on-demand (though this may cause a frame hitch).
    func selectPipeline(forIterations iterations: Int, raySteps: Int, useQuadShared: Bool, 
                        emissiveEnabled: Bool = false, neonMode: Bool = false) -> MTLRenderPipelineState {
        // Build unified cache key
        let qualityMode: Int = iterations <= 7 ? 2 : (iterations <= 9 ? 1 : 0)
        let cacheKey = "FI\(iterations)_RS\(raySteps)_E\(emissiveEnabled ? 1 : 0)_N\(neonMode ? 1 : 0)_Q\(qualityMode)" + (useQuadShared ? "_QS" : "")
        
        // 1. Check unified cache (includes both quality presets and saved presets)
        if let pipeline = pipelineCache[cacheKey] {
            print("✅ [PIPELINE CACHE HIT] Using pipeline: \(cacheKey)")
            if RENDERER_DEBUG && lastLoggedPipelineKey != cacheKey {
                print("🎯 [Pipeline] Using cached pipeline: \(cacheKey)")
                lastLoggedPipelineKey = cacheKey
            }
            return pipeline
        }
        
        // 2. Try fallback to emissive=off/neon=off variant (quality preset)
        let fallbackKey = "FI\(iterations)_RS\(raySteps)_E0_N0_Q\(qualityMode)" + (useQuadShared ? "_QS" : "")
        if let pipeline = pipelineCache[fallbackKey] {
            print("⚠️ [PIPELINE FALLBACK] Using quality-preset fallback: \(fallbackKey) (requested: \(cacheKey))")
            if RENDERER_DEBUG && lastLoggedPipelineKey != fallbackKey {
                print("🎯 [Pipeline] Using quality-preset fallback: \(fallbackKey) (requested: E=\(emissiveEnabled ? 1 : 0) N=\(neonMode ? 1 : 0))")
                lastLoggedPipelineKey = fallbackKey
            }
            return pipeline
        }
        
        // 3. Ultimate fallback to generic pipeline
        print("🚨 [PIPELINE ULTIMATE FALLBACK] Using generic pipeline! FI=\(iterations) RS=\(raySteps) - NO FUNCTION CONSTANTS!")
        if RENDERER_DEBUG && lastLoggedPipelineKey != "fallback" {
            print("⚠️ [Pipeline] Using FALLBACK generic pipeline (no cache hit for FI=\(iterations) RS=\(raySteps))")
            lastLoggedPipelineKey = "fallback"
        }
        return useQuadShared ? (quadSharedPipelineState ?? pipelineState) : pipelineState
    }
    
    /// Ensures a pipeline exists for the given configuration.
    /// Builds on-demand if not found in cache. Call this when loading a preset
    /// to avoid frame hitches during rendering.
    func ensurePipeline(forIterations iterations: Int, raySteps: Int, useQuadShared: Bool,
                        emissiveEnabled: Bool, neonMode: Bool) {
        let qualityMode: Int = iterations <= 7 ? 2 : (iterations <= 9 ? 1 : 0)
        let cacheKey = "FI\(iterations)_RS\(raySteps)_E\(emissiveEnabled ? 1 : 0)_N\(neonMode ? 1 : 0)_Q\(qualityMode)" + (useQuadShared ? "_QS" : "")
        
        // Already cached
        if pipelineCache[cacheKey] != nil { return }
        
        // Build on-demand
        print("🔨 [BUILD ON-DEMAND] Building pipeline \(cacheKey) with FC_FRACTAL_ITERATIONS=\(iterations)")
        if RENDERER_DEBUG { print("🔧 [Pipeline] Building on-demand pipeline: \(cacheKey)") }
        
        let config = FunctionConstantConfig(
            fractalIterations: Int32(iterations),
            shadowIterations: Int32(max(iterations - 2, 2)),
            safetyBubbleEnabled: true,
            showHUD: false,
            qualityMode: Int32(qualityMode),
            debugHierarchical: false,
            maxRaySteps: Int32(raySteps),
            emissiveEnabled: emissiveEnabled,
            neonModeEnabled: neonMode,
            colorIterations: 8  // Color iterations are fixed for consistent coloring
        )
        print("   ↳ Config: FI=\(iterations), shadow=\(max(iterations - 2, 2)), raySteps=\(raySteps), emissive=\(emissiveEnabled), neon=\(neonMode)")
        
        do {
            let pipeline = try Renderer.buildSpecializedPipeline(
                device: device,
                layerRenderer: layerRenderer,
                rasterSampleCount: rasterSampleCount,
                mtlVertexDescriptor: mtlVertexDescriptor,
                config: config,
                fragmentFunctionName: useQuadShared ? "fragmentShaderQuadShared" : "fragmentShader"
            )
            pipelineCache[cacheKey] = pipeline
            if RENDERER_DEBUG { print("✅ [Pipeline] Built on-demand: \(cacheKey)") }
        } catch {
            if RENDERER_DEBUG { print("❌ [Pipeline] Failed to build on-demand: \(cacheKey): \(error)") }
        }
    }
    
    /// Returns the number of pipelines currently in the unified cache.
    var pipelineCacheCount: Int {
        return pipelineCache.count
    }
    
    /// Returns all cache keys currently in the unified pipeline cache.
    /// Useful for debugging which pipelines have been compiled.
    var pipelineCacheKeys: [String] {
        return Array(pipelineCache.keys).sorted()
    }
    
    /// Build a specialized pipeline with function constants for compile-time optimization
    static func buildSpecializedPipeline(device: MTLDevice,
                                         layerRenderer: LayerRenderer,
                                         rasterSampleCount: Int,
                                         mtlVertexDescriptor: MTLVertexDescriptor,
                                         config: FunctionConstantConfig,
                                         colorFormat: MTLPixelFormat? = nil,
                                         fragmentFunctionName: String = "fragmentShader") throws -> MTLRenderPipelineState {
        return try buildRenderPipelineWithDevice(
            device: device,
            layerRenderer: layerRenderer,
            rasterSampleCount: rasterSampleCount,
            mtlVertexDescriptor: mtlVertexDescriptor,
            colorFormat: colorFormat,
            fragmentFunctionName: fragmentFunctionName,
            functionConstants: config.toMTLConstants()
        )
    }

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

    private func updateDynamicBufferState() {
        /// Update the state of our uniform buffers before rendering
        /// OPTIMIZATION: Use bitwise AND for modulo when maxBuffersInFlight is power of 2
        uniformBufferIndex = (uniformBufferIndex + 1) & (maxBuffersInFlight - 1)  // Faster than modulo for power of 2
        uniformBufferOffset = alignedUniformsSize * uniformBufferIndex
        uniforms = UnsafeMutableRawPointer(dynamicUniformBuffer.contents() + uniformBufferOffset).bindMemory(to:UniformsArray.self, capacity:1)
    }
    
    /// Update hand tracking data and process gesture controls
    private func updateHandTracking(atTime time: TimeInterval) {
        guard let ht = handTracking else { return }
        
        // Only process if hand tracking is running
        guard ht.state == .running else { return }
        
        // Get hand anchors at the current time
        let anchors = ht.handAnchors(at: time)
        
        // Calculate deltaTime for this update
        let gestureUpdateDelta = Float(time - lastHandTrackingUpdateTime)
        
        // Process gestures EVERY FRAME for responsive controls (no throttle)
        lastHandTrackingUpdateTime = time
        
        // Process gestures via async dispatch to MainActor
        // GestureController writes to RenderSettings which is thread-safe
        if #available(visionOS 2.0, *) {
            Task { @MainActor in
                appModel.leftHandTracked = anchors.leftHand?.isTracked ?? false
                appModel.rightHandTracked = anchors.rightHand?.isTracked ?? false
                
                appModel.gestureController?.updateHands(
                    leftAnchor: anchors.leftHand,
                    rightAnchor: anchors.rightHand,
                    deltaTime: gestureUpdateDelta
                )
            }
        }
    }
    
    /// Update dynamic render quality based on FPS performance (visionOS 26+)
    /// This implements Apple's WWDC25 Session 294 dynamic render quality API,
    /// extended to also dynamically adjust shader parameters (iterations, ray steps).
    private func updateDynamicRenderQuality(fps: Double, deltaTime: TimeInterval) {
        if #available(visionOS 26.0, *) {
            guard let manager = dynamicRenderQualityManager as? DynamicRenderQualityManager else { return }
            
            let settings = appModel.renderSettings
            
            // Sync manager settings with RenderSettings (in case user changed them)
            manager.isEnabled = settings.dynamicRenderQualityEnabled
            manager.minQuality = settings.dynamicRenderQualityMin
            manager.maxQuality = settings.dynamicRenderQualityMax
            
            // Update the manager with current FPS - resolution scaling only applies if foveation is available
            let canUseResolutionScaling = layerRenderer.configuration.isFoveationEnabled
            manager.update(fps: fps, deltaTime: deltaTime, 
                          layerRenderer: layerRenderer, 
                          applyResolutionScaling: canUseResolutionScaling)
            
            // Sync current quality back to settings for UI display
            settings.currentRenderQuality = manager.currentQuality
            
            // === APPLY EFFECTIVE SHADER PARAMETERS ===
            // This is where the quality percentage actually affects rendering!
            // Scale iterations and ray steps based on current quality level.
            if manager.isEnabled {
                let effectiveIterations = manager.effectiveIterations(base: settings.baseFractalIterations)
                let effectiveRaySteps = manager.effectiveRaySteps(base: settings.baseMaxRaySteps)
                settings.fractalIterations = effectiveIterations
                settings.maxRaySteps = effectiveRaySteps
            }
            
            // Log status once
            if !hasLoggedDynamicQualityStatus && manager.isEnabled {
                hasLoggedDynamicQualityStatus = true
                let mode = canUseResolutionScaling ? "resolution + shader params" : "shader params only"
                if RENDERER_DEBUG { print("✓ Dynamic render quality active (\(mode)): adjusting based on FPS") }
            }
            
            // Optionally hint scene complexity when fractal parameters change significantly
            // This helps the manager anticipate quality needs
            let complexity = DynamicRenderQualityManager.estimateFractalComplexity(
                iterations: settings.baseFractalIterations,
                raySteps: settings.baseMaxRaySteps,
                tileSize: settings.tileSize
            )
            manager.hintSceneComplexity(complexity, layerRenderer: layerRenderer)
        }
    }

    private func updateGameState(drawable: LayerRenderer.Drawable, settingsSnapshot: RenderSettingsSnapshot) {
        /// Update any game state before rendering
        
        // Use already-smoothed position from settings (interpolated above)
        // Scale gets its own smoothing since it's not gesture-controlled
        let smoothSpeed: Float = 15.0
        let smoothFactor = 1.0 - exp(-smoothSpeed * cachedDeltaTime)
        smoothedPosition = settingsSnapshot.position  // Already smoothed by interpolateToTargets
        smoothedScale = smoothedScale + (settingsSnapshot.scale - smoothedScale) * smoothFactor
        
        // Use cached rotation matrix (constant, computed once in init)
        let translationMatrix = matrix4x4_translation(smoothedPosition.x, smoothedPosition.y, smoothedPosition.z)
        let scaleMatrix = matrix4x4_scale(smoothedScale, smoothedScale, smoothedScale)
        
        let modelMatrix = translationMatrix * cachedRotationMatrix * scaleMatrix
        
        // Use raw device anchor transform (no smoothing) to ensure compositor-predicted pose is used
        let deviceTransform = drawable.deviceAnchor?.originFromAnchorTransform ?? matrix_identity_float4x4
        
        // One-time logging of device anchor to verify position tracking is working
        if !hasLoggedDeviceAnchorInfo, let anchor = drawable.deviceAnchor {
            hasLoggedDeviceAnchorInfo = true
            let transform = anchor.originFromAnchorTransform
            let position = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
            if RENDERER_DEBUG {
                print("📍 Device anchor first frame:")
                print("   Position: (\(position.x), \(position.y), \(position.z))")
                print("   isTracked: \(anchor.isTracked)")
                // If position is exactly (0,0,0), world sensing permission may not be granted
                if position.x == 0 && position.y == 0 && position.z == 0 {
                    print("   ⚠️ Position is origin - world sensing may not be authorized!")
                }
            }
        }
        
        // === PRECOMPUTE FRAME-UNIFORM VALUES ===
        // These are computed once per frame on CPU, shared by all pixels
        // Eliminates expensive per-pixel calculations like powr() and CameraPath()
        
        func computePrecomputedFractal(settings: RenderSettingsSnapshot) -> PrecomputedFractalParams {
            let minRad2 = settings.minDistance
            let fractalScale = settings.fractalScale
            let sphereRadius = settings.sphereRadius
            let iterations = settings.fractalIterations
            
            let invMinRad = 1.0 / minRad2
            var scale = SIMD4<Float>(repeating: fractalScale * invMinRad)
            scale.w = abs(scale.w)
            
            let absScalem1 = abs(fractalScale - 1.0)
            // This is the expensive powr() call we're eliminating from the GPU
            let absScalePow = pow(max(abs(fractalScale), 1e-6), Float(1 - iterations))
            let sphereRadiusSq = sphereRadius * sphereRadius
            let invSphereRadiusSq = 1.0 / sphereRadiusSq
            
            return PrecomputedFractalParams(
                scale: scale,
                absScalem1: absScalem1,
                absScalePow: absScalePow,
                invSphereRadiusSq: invSphereRadiusSq,
                sphereRadiusSq: sphereRadiusSq
            )
        }
        
        func computePrecomputedLighting(time: Float, lightingMode: LightingMode, audioLevel: Float) -> PrecomputedLighting {
            let gTime = time * 0.01 + 15.00
            
            let spotLightPosition: SIMD3<Float>
            let lightIntensity: Float
            
            switch lightingMode {
            case .staticLight:
                spotLightPosition = SIMD3<Float>(2.0, 1.5, 2.0)
                lightIntensity = 1.0
            case .audioReactive:
                let basePos = SIMD3<Float>(1.5, 1.0, 1.5)
                let pulse = audioLevel * 2.0
                let audioOffset = SIMD3<Float>(
                    sin(gTime * 2.0) * pulse,
                    audioLevel * 1.5,
                    cos(gTime * 2.0) * pulse
                )
                spotLightPosition = basePos + audioOffset
                lightIntensity = 0.5 + audioLevel * 1.5
            case .animated:
                // CameraPath: float3(-.78 + 3. * sin(2.14*t),.05+2.5 * sin(.942*t+1.3),.05 + 3.5 * cos(3.594*t))
                let pathT = gTime + 0.03
                let path = SIMD3<Float>(
                    -0.78 + 3.0 * sin(2.14 * pathT),
                    0.05 + 2.5 * sin(0.942 * pathT + 1.3),
                    0.05 + 3.5 * cos(3.594 * pathT)
                )
                let offset = SIMD3<Float>(
                    sin(gTime * 18.4),
                    cos(gTime * 17.98),
                    sin(gTime * 22.53)
                ) * 0.2
                spotLightPosition = path + offset
                lightIntensity = 0.9 + sin(gTime * 1.5) * 0.15
            }
            
            return PrecomputedLighting(
                spotLightPosition: spotLightPosition,
                lightIntensity: lightIntensity
            )
        }
        
        // Compute once per frame
        let precomputedFractal = computePrecomputedFractal(settings: settingsSnapshot)
        let precomputedLighting = computePrecomputedLighting(
            time: Float(appModel.clock.time),
            lightingMode: settingsSnapshot.lightingMode,
            audioLevel: settingsSnapshot.audioLevel
        )

        func uniforms(forViewIndex viewIndex: Int) -> Uniforms {
            let view = drawable.views[viewIndex]
            let viewMatrix = (deviceTransform * view.transform).inverse
            let projection = drawable.computeProjection(viewIndex: viewIndex)
            let inverseProjection = projection.inverse
            
            let modelView = viewMatrix * modelMatrix
            let inverseModelView = modelView.inverse
            let inverseView = viewMatrix.inverse

            // Optional lighting play mode: gently modulate color and glow
            let baseColorMix = settingsSnapshot.colorMix
            let baseGlow = settingsSnapshot.glowIntensity
            let lightingWave = sin(Float(appModel.clock.time) * 1.2)
            let animatedColorMix = settingsSnapshot.lightingPlay ? min(max(baseColorMix + lightingWave * 0.08, 0.0), 1.0) : baseColorMix
            let animatedGlow = settingsSnapshot.lightingPlay ? min(max(baseGlow + max(0, lightingWave) * 0.25, 0.0), 2.0) : baseGlow
            
            let colorSchemeParams = settingsSnapshot.colorSchemeParams
            
            // Get fovea center from the view's texture map (normalized 0-1)
            // 🔍 DEBUG: Log uniforms being sent to GPU
            print("📊 [UNIFORMS] fractalIterations=\(settingsSnapshot.fractalIterations), bubbleEnabled=\(settingsSnapshot.safetyBubbleEnabled), bubbleRadius=\(settingsSnapshot.safetyBubbleRadius), bubbleShape=\(settingsSnapshot.safetyBubbleShape)")
            
            return Uniforms(projectionMatrix: projection,
                            modelViewMatrix: modelView,
                            inverseModelViewMatrix: inverseModelView,
                            inverseProjectionMatrix: inverseProjection,
                            viewMatrix: viewMatrix,
                            inverseViewMatrix: inverseView,
                            time: Float(appModel.clock.time),
                            minDistance: settingsSnapshot.minDistance,
                            fractalScale: settingsSnapshot.fractalScale,
                            fractalIterations: Int32(settingsSnapshot.fractalIterations),
                            maxRaySteps: Int32(settingsSnapshot.maxRaySteps),
                            colorMix: animatedColorMix,
                            glowIntensity: animatedGlow,
                            foldingLimit: settingsSnapshot.foldingLimit,
                            sphereRadius: settingsSnapshot.sphereRadius,
                            safetyBubbleRadius: settingsSnapshot.safetyBubbleRadius,
                            safetyBubbleEnabled: settingsSnapshot.safetyBubbleEnabled ? 1 : 0,
                            safetyBubbleShape: settingsSnapshot.safetyBubbleShape,
                            colorIterations: settingsSnapshot.colorIterations,
                            useHierarchical: settingsSnapshot.useHierarchical ? 1 : 0,
                            limitFlash: settingsSnapshot.limitFlash,
                            showHUD: settingsSnapshot.showHUD ? 1 : 0,
                            activeGesture: Int32(settingsSnapshot.activeGestureIndex),
                            gestureSpread: settingsSnapshot.gestureSpread,
                            fractalType: settingsSnapshot.fractalType.rawValue,
                            lightingMode: settingsSnapshot.lightingMode.rawValue,
                            audioLevel: settingsSnapshot.audioLevel,
                            emissiveEnabled: settingsSnapshot.emissiveEnabled ? 1 : 0,
                            emissivePattern: Int32(settingsSnapshot.emissivePattern),
                            emissiveIntensity: settingsSnapshot.emissiveIntensity,
                            emissiveThreshold: settingsSnapshot.emissiveThreshold,
                            emissiveColor: settingsSnapshot.emissiveColor,
                            emissiveSpeed: settingsSnapshot.emissiveSpeed,
                            fogIntensity: settingsSnapshot.fogIntensity,
                            maxViewDistance: RenderSettings.maxViewDistance,
                            logDepthScale: RenderSettings.logDepthScale,
                            depthMissValue: RenderSettings.depthMissValue,
                            // ═══════════════════════════════════════════════════════════════
                            // GEOMETRY STABILITY STATE
                            // ═══════════════════════════════════════════════════════════════
                            geometryState: Int32(settingsSnapshot.geometryState.rawValue),
                            geometryStableFrames: Int32(settingsSnapshot.geometryState == .stable ? appModel.renderSettings.geometryStableFrameCount : 0),
                            _padding1: 0.0,
                            _padding2: 0.0,
                            precomputedFractal: precomputedFractal,
                            precomputedLighting: precomputedLighting,
                            colorScheme: colorSchemeParams)
        }

        self.uniforms[0].uniforms.0 = uniforms(forViewIndex: 0)
        if drawable.views.count > 1 {
            self.uniforms[0].uniforms.1 = uniforms(forViewIndex: 1)
        }

//        rotation += 0.01
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
            
            // Throttle UI updates to 4Hz (every 0.25s) to prevent SwiftUI layout thrashing
            if time - lastFPSUpdateTime > 0.25 {
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

        // Update scene animation playback on MainActor (sets target values before interpolation)
        let animDelta = TimeInterval(cachedDeltaTime)
        Task { @MainActor in
            self.appModel.animationManager?.update(deltaTime: animDelta)
        }
        
        settings.interpolateToTargets(deltaTime: cachedDeltaTime)
        settings.updateLimitFlash(deltaTime: cachedDeltaTime)
        settings.updateColorSchemeTransition(deltaTime: cachedDeltaTime)
        if settings.lightingMode == .audioReactive && appModel.audioAnalyzer.isCapturing {
            let combinedLevel = appModel.audioAnalyzer.level * 0.6 + appModel.audioAnalyzer.bassLevel * 0.4
            settings.audioLevel = combinedLevel
        }
        
        let settingsSnapshot = settings.snapshot()
        
        // === STOCHASTIC RENDERING: Detect parameter changes and reset accumulation ===
        if settingsSnapshot.stochasticRenderingEnabled {
            // Log mode activation once
            if !hasLoggedStochasticMode {
                hasLoggedStochasticMode = true
                print("✊ STOCHASTIC MODE: Accumulating frames for higher quality at low FPS")
            }
            
            // Check if any scene parameters have changed significantly
            let positionChanged = simd_distance(settingsSnapshot.position, lastStochasticPosition) > 0.001
            let minDistChanged = abs(settingsSnapshot.minDistance - lastStochasticMinDistance) > 0.001
            let foldingChanged = abs(settingsSnapshot.foldingLimit - lastStochasticFoldingLimit) > 0.001
            let sphereChanged = abs(settingsSnapshot.sphereRadius - lastStochasticSphereRadius) > 0.001
            let scaleChanged = abs(settingsSnapshot.fractalScale - lastStochasticFractalScale) > 0.001
            
            if positionChanged || minDistChanged || foldingChanged || sphereChanged || scaleChanged {
                // Reset accumulation when scene changes
                settings.resetStochasticAccumulation()
                print("✊ STOCHASTIC: Parameters changed, resetting accumulation (frame 0)")
            } else {
                // Increment frame count
                let _ = settings.incrementStochasticFrame()
            }
            
            // Update tracking for next frame
            lastStochasticPosition = settingsSnapshot.position
            lastStochasticMinDistance = settingsSnapshot.minDistance
            lastStochasticFoldingLimit = settingsSnapshot.foldingLimit
            lastStochasticSphereRadius = settingsSnapshot.sphereRadius
            lastStochasticFractalScale = settingsSnapshot.fractalScale
        } else if hasLoggedStochasticMode {
            // Log mode deactivation
            hasLoggedStochasticMode = false
            print("✊ STOCHASTIC MODE: Disabled, returning to real-time rendering")
        }

        self.updateGameState(drawable: drawable, settingsSnapshot: settingsSnapshot)

        // === STOCHASTIC RENDERING PATH ===
        // When enabled, use progressive refinement instead of real-time rendering
        if settingsSnapshot.stochasticRenderingEnabled {
            let stochasticRendered = renderWithStochastic(
                commandBuffer: commandBuffer,
                drawable: drawable,
                settingsSnapshot: settingsSnapshot
            )
            
            if stochasticRendered {
                drawable.encodePresent(commandBuffer: commandBuffer)
                commandBuffer.commit()
                frame.endSubmission()
                return  // Skip standard rendering
            }
            // Fall through to standard rendering if stochastic failed
        }
        
        // ═══════════════════════════════════════════════════════════════════════════
        // STABLE GEOMETRY RENDERING PATH
        // When geometry is stable (not changing) AND head is stable, use temporal
        // accumulation. Automatically resets when geometry or head movement detected.
        // ═══════════════════════════════════════════════════════════════════════════
        let geometryState = settingsSnapshot.geometryState
        
        // Check for head movement (invalidates temporal accumulation)
        var headMoved = false
        if let deviceAnchor = drawable.deviceAnchor {
            let headTransform = deviceAnchor.originFromAnchorTransform
            let headPosition = SIMD3<Float>(headTransform.columns.3.x, headTransform.columns.3.y, headTransform.columns.3.z)
            let headRotation = simd_quatf(headTransform)
            
            let posDelta = simd_length(headPosition - previousHeadPosition)
            let rotDelta = abs(1.0 - abs(simd_dot(headRotation, previousHeadRotation)))
            
            if posDelta > headMovementThreshold || rotDelta > headRotationThreshold {
                headMoved = true
                if stableGeometryAccumulatedFrames > 0 {
                    // Head moved - reset accumulation
                    stableGeometryAccumulatedFrames = 0
                }
            }
            
            previousHeadPosition = headPosition
            previousHeadRotation = headRotation
        }
        
        // Detect geometry state transitions
        if geometryState != lastStableGeometryState {
            if geometryState == .stable {
                // Just became stable - reset accumulation to start fresh
                stableGeometryAccumulatedFrames = 0
                if !hasLoggedStableGeometryMode {
                    hasLoggedStableGeometryMode = true
                    print("🎯 STABLE GEOMETRY: Entering optimized render path (head-aware accumulation)")
                }
            } else if lastStableGeometryState == .stable {
                // Was stable, now dynamic/settling - reset accumulation
                stableGeometryAccumulatedFrames = 0
                if hasLoggedStableGeometryMode {
                    hasLoggedStableGeometryMode = false
                    print("🎯 STABLE GEOMETRY: Exiting optimized path (geometry changing)")
                }
            }
            lastStableGeometryState = geometryState
        }
        
        // Use stable geometry path when geometry is locked AND head is not moving
        // (Head movement resets accumulation above, so we only accumulate during stillness)
        if geometryState == .stable && !headMoved {
            let stableRendered = renderWithStableGeometry(
                commandBuffer: commandBuffer,
                drawable: drawable,
                settingsSnapshot: settingsSnapshot
            )
            
            if stableRendered {
                drawable.encodePresent(commandBuffer: commandBuffer)
                commandBuffer.commit()
                frame.endSubmission()
                return  // Skip standard rendering
            }
            // Fall through to standard rendering if stable geometry rendering failed
        }

        // Check if using adaptive 8x8 compute pipeline
        let tileSize = settingsSnapshot.tileSize
        // MetalFX spatial upscaling disabled - causes frame drops without quality benefit
        let wantsMetalFX = false
        let useAdaptiveCompute = (tileSize == 8) && adaptiveHierarchicalPipeline8x8 != nil && !wantsMetalFX
        
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
        var metalFXInputSize: SIMD2<Int>?
#if canImport(MetalFX)
        let systemMap = drawable.rasterizationRateMaps.first
        var metalFXContext: (manager: MetalFXManager, inputWidth: Int, inputHeight: Int)?
        if wantsMetalFX {
            metalFXContext = updateMetalFXManager(
                drawable: drawable,
                settingsSnapshot: settingsSnapshot,
                rasterizationRateMap: systemMap
            )
            if let context = metalFXContext {
                metalFXInputSize = SIMD2(context.inputWidth, context.inputHeight)
                configureMetalFXRenderTargets(
                    renderPassDescriptor: renderPassDescriptor,
                    metalFX: context.manager,
                    drawable: drawable,
                    rasterizationRateMap: systemMap
                )
            } else {
                configureDirectRenderTargets(renderPassDescriptor: renderPassDescriptor, drawable: drawable)
            }
        } else {
            configureDirectRenderTargets(renderPassDescriptor: renderPassDescriptor, drawable: drawable)
        }
#else
        configureDirectRenderTargets(renderPassDescriptor: renderPassDescriptor, drawable: drawable)
#endif

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
        // If sphere mode is enabled, force 2 iterations to create the sphere effect
        let baseIterations = settingsSnapshot.fractalIterations
        let currentIterations = appModel.sphereMode ? 2 : baseIterations
        let currentRaySteps = settingsSnapshot.maxRaySteps
        
        // Detect neon mode from colorSchemeParams.neonIntensity
        let isNeonMode = settingsSnapshot.colorSchemeParams.neonIntensity > 0
        let isEmissive = settingsSnapshot.emissiveEnabled
        
        // 🔍 DEBUG: Log iteration and pipeline selection
        let qualityMode: Int = currentIterations <= 7 ? 2 : (currentIterations <= 9 ? 1 : 0)
        let unifiedKey = "FI\(currentIterations)_RS\(currentRaySteps)_E\(isEmissive ? 1 : 0)_N\(isNeonMode ? 1 : 0)_Q\(qualityMode)" + (useQuadShared ? "_QS" : "")
        print("🎯 [PIPELINE SELECT] Iterations=\(currentIterations), RaySteps=\(currentRaySteps), Quality=\(qualityMode), SphereMode=\(appModel.sphereMode), Key=\(unifiedKey)")
        
        // Use specialized pipeline with fixed iteration count
        // This enables Map() loop auto-unrolling via function constants
        let selectedPipeline = selectPipeline(
            forIterations: currentIterations,
            raySteps: currentRaySteps,
            useQuadShared: useQuadShared,
            emissiveEnabled: isEmissive,
            neonMode: isNeonMode
        )
        renderEncoder.setRenderPipelineState(selectedPipeline)

        renderEncoder.setDepthStencilState(depthState)

        renderEncoder.setVertexBuffer(dynamicUniformBuffer, offset:uniformBufferOffset, index: BufferIndex.uniforms.rawValue)
        
        // Also bind uniforms buffer for fragment shader since it now needs access to uniforms
        renderEncoder.setFragmentBuffer(dynamicUniformBuffer, offset:uniformBufferOffset, index: BufferIndex.uniforms.rawValue)

        let viewports: [MTLViewport]
    #if canImport(MetalFX)
        if let context = metalFXContext {
            viewports = scaledViewports(for: drawable, targetWidth: context.inputWidth, targetHeight: context.inputHeight)
        } else {
            viewports = drawable.views.map { $0.textureMap.viewport }
        }
    #else
        viewports = drawable.views.map { $0.textureMap.viewport }
    #endif
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
        
    #if canImport(MetalFX)
        if let context = metalFXContext {
            try? context.manager.encodeSpatialUpscale(commandBuffer: commandBuffer, fence: nil)
            blitMetalFXOutputToDrawable(commandBuffer: commandBuffer, metalFX: context.manager, drawable: drawable)
        }
    #endif

        let cpuEncodeMs = (CACurrentMediaTime() - cpuEncodeStart) * 1000.0
        let frameTimeSeconds = Double(cachedDeltaTime)
        let logTime = time
        let capturedMetalFXInputSize = metalFXInputSize  // Capture for concurrent closure
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
                    wantsMetalFX: wantsMetalFX,
                    useAdaptiveCompute: useAdaptiveCompute,
                    metalFXInputSize: capturedMetalFXInputSize,
                    viewCount: drawable.views.count
                )
            }
        }

        drawable.encodePresent(commandBuffer: commandBuffer)

        commandBuffer.commit()

        frame.endSubmission()
    }
    
    private func configureDirectRenderTargets(renderPassDescriptor: MTLRenderPassDescriptor, drawable: LayerRenderer.Drawable) {
        renderPassDescriptor.colorAttachments[0].texture = drawable.colorTextures[0]
        renderPassDescriptor.depthAttachment.texture = drawable.depthTextures[0]

        renderPassDescriptor.colorAttachments[0].storeAction = .store
        renderPassDescriptor.depthAttachment.storeAction = .store

        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0)
        renderPassDescriptor.depthAttachment.loadAction = .clear
        renderPassDescriptor.depthAttachment.clearDepth = 1.0
        
        if let systemMap = drawable.rasterizationRateMaps.first {
            renderPassDescriptor.rasterizationRateMap = systemMap
            if RENDERER_DEBUG && !hasLoggedFoveationAvailability {
                print("✓ Using system gaze-tracked rasterization rate map")
                hasLoggedFoveationAvailability = true
            }
        } else {
            renderPassDescriptor.rasterizationRateMap = nil
        }
        if layerRenderer.configuration.layout == .layered {
            renderPassDescriptor.renderTargetArrayLength = drawable.views.count
        }
    }

    private func recordFramePerf(
        nowTime: TimeInterval,
        frameTimeSeconds: Double,
        cpuEncodeMs: Double,
        gpuMs: Double?,
        settingsSnapshot: RenderSettingsSnapshot,
        wantsMetalFX: Bool,
        useAdaptiveCompute: Bool,
        metalFXInputSize: SIMD2<Int>?,
        viewCount: Int
    ) {
        let frameMs = frameTimeSeconds * 1000.0

        // Log only when slow and throttled
        if frameMs < perfLogFrameMsThreshold { return }
        if nowTime - lastPerfLogTime < 0.5 { return }
        lastPerfLogTime = nowTime

        let gpuText = gpuMs.map { String(format: "%.2f", $0) } ?? "n/a"
        let metalFXText: String
        if wantsMetalFX, let size = metalFXInputSize {
            metalFXText = "on (input \(size.x)x\(size.y))"
        } else if wantsMetalFX {
            metalFXText = "on (input n/a)"
        } else {
            metalFXText = "off"
        }

        let pathText = useAdaptiveCompute ? "compute" : "fragment"
        let fps = frameTimeSeconds > 0 ? (1.0 / frameTimeSeconds) : 0
        if RENDERER_DEBUG { print("⚠️ Slow frame: ft=\(String(format: "%.2f", frameMs))ms fps=\(String(format: "%.1f", fps)) gpu=\(gpuText)ms cpu=\(String(format: "%.2f", cpuEncodeMs))ms path=\(pathText) MetalFX=\(metalFXText) tile=\(settingsSnapshot.tileSize) iters=\(settingsSnapshot.fractalIterations) steps=\(settingsSnapshot.maxRaySteps) views=\(viewCount)") }
    }

#if canImport(MetalFX)
    private func scaledViewports(for drawable: LayerRenderer.Drawable, targetWidth: Int, targetHeight: Int) -> [MTLViewport] {
        let outputWidth = max(1, drawable.colorTextures[0].width)
        let outputHeight = max(1, drawable.colorTextures[0].height)
        let scaleX = Double(targetWidth) / Double(outputWidth)
        let scaleY = Double(targetHeight) / Double(outputHeight)
        return drawable.views.map { view in
            let vp = view.textureMap.viewport
            return MTLViewport(
                originX: vp.originX * scaleX,
                originY: vp.originY * scaleY,
                width: vp.width * scaleX,
                height: vp.height * scaleY,
                znear: vp.znear,
                zfar: vp.zfar
            )
        }
    }

    private func configureMetalFXRenderTargets(
        renderPassDescriptor: MTLRenderPassDescriptor,
        metalFX: MetalFXManager,
        drawable: LayerRenderer.Drawable,
        rasterizationRateMap: MTLRasterizationRateMap?
    ) {
        guard let inputTexture = metalFX.inputTexture,
              let depthTexture = metalFX.depthTexture
        else {
            return
        }

        renderPassDescriptor.colorAttachments[0].texture = inputTexture
        renderPassDescriptor.depthAttachment.texture = depthTexture

        renderPassDescriptor.colorAttachments[0].storeAction = .store
        renderPassDescriptor.depthAttachment.storeAction = .store

        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0)
        renderPassDescriptor.depthAttachment.loadAction = .clear
        renderPassDescriptor.depthAttachment.clearDepth = 1.0

        if let map = rasterizationRateMap {
            let physical = map.physicalSize(layer: 0)
            if physical.width == inputTexture.width && physical.height == inputTexture.height {
                renderPassDescriptor.rasterizationRateMap = map
                if RENDERER_DEBUG && !hasLoggedFoveationAvailability {
                    print("✓ Using system gaze-tracked rasterization rate map (MetalFX input)")
                    hasLoggedFoveationAvailability = true
                }
            } else {
                renderPassDescriptor.rasterizationRateMap = nil
            }
        } else {
            renderPassDescriptor.rasterizationRateMap = nil
        }

        if layerRenderer.configuration.layout == .layered {
            renderPassDescriptor.renderTargetArrayLength = drawable.views.count
        }
    }

    private func blitMetalFXOutputToDrawable(
        commandBuffer: MTLCommandBuffer,
        metalFX: MetalFXManager,
        drawable: LayerRenderer.Drawable
    ) {
        guard let outputTexture = metalFX.outputTexture else { return }
        guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else { return }
        blitEncoder.label = "Copy MetalFX Output to Drawable"

        for eye in 0..<drawable.views.count {
            let destinationTexture: MTLTexture
            let destinationSlice: Int

            if drawable.colorTextures.count > eye {
                destinationTexture = drawable.colorTextures[eye]
                destinationSlice = 0
            } else {
                destinationTexture = drawable.colorTextures[0]
                destinationSlice = eye
            }

            blitEncoder.copy(
                from: outputTexture,
                sourceSlice: eye,
                sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(width: outputTexture.width, height: outputTexture.height, depth: 1),
                to: destinationTexture,
                destinationSlice: destinationSlice,
                destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
            )
        }

        if let depthTexture = metalFX.depthTexture {
            for eye in 0..<drawable.views.count {
                let destinationTexture: MTLTexture
                let destinationSlice: Int

                if drawable.depthTextures.count > eye {
                    destinationTexture = drawable.depthTextures[eye]
                    destinationSlice = 0
                } else {
                    destinationTexture = drawable.depthTextures[0]
                    destinationSlice = eye
                }

                blitEncoder.copy(
                    from: depthTexture,
                    sourceSlice: eye,
                    sourceLevel: 0,
                    sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                    sourceSize: MTLSize(width: depthTexture.width, height: depthTexture.height, depth: 1),
                    to: destinationTexture,
                    destinationSlice: destinationSlice,
                    destinationLevel: 0,
                    destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
                )
            }
        }

        blitEncoder.endEncoding()
    }

    private func updateMetalFXManager(
        drawable: LayerRenderer.Drawable,
        settingsSnapshot: RenderSettingsSnapshot,
        rasterizationRateMap: MTLRasterizationRateMap?
    ) -> (MetalFXManager, Int, Int)? {
        let outputWidth = drawable.colorTextures[0].width
        let outputHeight = drawable.colorTextures[0].height
        let viewCount = drawable.views.count

        var inputWidth = max(1, Int(Float(outputWidth) * settingsSnapshot.resolutionScale))
        var inputHeight = max(1, Int(Float(outputHeight) * settingsSnapshot.resolutionScale))

        // When using foveation with MetalFX, the input texture MUST be at least as large as
        // the rate map's physical size, otherwise Metal validation fails with:
        // "maximum physical rendering width must be <= minimum attachment width"
        if layerRenderer.configuration.isFoveationEnabled, let map = rasterizationRateMap {
            let physical = map.physicalSize(layer: 0)
            if physical.width > 0 && physical.height > 0 {
                // Ensure input is at least the physical size required by the rate map
                inputWidth = max(inputWidth, physical.width)
                inputHeight = max(inputHeight, physical.height)
            }
        }

        let config = MetalFXManager.Configuration(
            inputWidth: inputWidth,
            inputHeight: inputHeight,
            outputWidth: outputWidth,
            outputHeight: outputHeight,
            colorFormat: drawable.colorTextures[0].pixelFormat,
            depthFormat: drawable.depthTextures[0].pixelFormat,
            scale: settingsSnapshot.resolutionScale
        )

        do {
            if metalFXManager == nil {
                metalFXManager = try MetalFXManager(device: device, configuration: config, viewCount: viewCount)
            } else {
                try metalFXManager?.update(configuration: config, viewCount: viewCount)
            }
        } catch {
            if RENDERER_DEBUG && !hasLoggedMetalFXFallback {
                print("⚠️ MetalFX init/update failed: \(error). Falling back to direct rendering.")
                hasLoggedMetalFXFallback = true
            }
            metalFXManager = nil
            return nil
        }

        lastMetalFXInputSize = SIMD2(inputWidth, inputHeight)
        lastMetalFXOutputSize = SIMD2(outputWidth, outputHeight)

        if metalFXFence == nil {
            metalFXFence = device.makeFence()
        }

        guard let manager = metalFXManager else { return nil }
        return (manager, inputWidth, inputHeight)
    }
#endif
    
    // MARK: - Adaptive 8x8 Hierarchical Compute Rendering
    
    /// Dispatches the adaptive 8x8 hierarchical compute kernel for high-performance raymarching
    /// This uses a 3-level cascade: super-coarse (1 thread) → coarse (4 threads) → fine (64 threads)
    /// Expected speedup: 3-8x compared to per-pixel raymarching
    private func encodeAdaptiveCompute(
        commandBuffer: MTLCommandBuffer,
        outputTexture: MTLTexture,
        drawable: LayerRenderer.Drawable,
        viewIndex: Int,
        settingsSnapshot: RenderSettingsSnapshot
    ) {
        guard let pipeline = adaptiveHierarchicalPipeline8x8,
              let uniformBuffer = tileUniformBuffer else {
            if RENDERER_DEBUG { print("⚠️ Adaptive compute pipeline not available") }
            return
        }
        let view = drawable.views[viewIndex]
        
        // Build model matrix (must match fragment shader exactly!)
        let t: Float = 0.1
        let currentSmoothedPosition = smoothedPosition + (settingsSnapshot.position - smoothedPosition) * t
        let currentSmoothedScale = smoothedScale + (settingsSnapshot.scale - smoothedScale) * t
        
        let rotationMatrix = matrix4x4_rotation(radians: -.pi/2, axis: [0, 1, 0])
        let translationMatrix = matrix4x4_translation(currentSmoothedPosition.x, currentSmoothedPosition.y, currentSmoothedPosition.z)
        let scaleMatrix = matrix4x4_scale(currentSmoothedScale, currentSmoothedScale, currentSmoothedScale)
        let modelMatrix = translationMatrix * rotationMatrix * scaleMatrix
        
        // Build view matrix (same as fragment shader)
        let deviceTransform = drawable.deviceAnchor?.originFromAnchorTransform ?? matrix_identity_float4x4
        let viewMatrix = (deviceTransform * view.transform).inverse
        let projection = drawable.computeProjection(viewIndex: viewIndex)
        
        // Model-view matrix and its inverse (THIS WAS MISSING!)
        let modelView = viewMatrix * modelMatrix
        let inverseModelView = modelView.inverse
        
        // Get camera position from inverse model-view matrix (in model space)
        let cameraPos = SIMD3<Float>(inverseModelView.columns.3.x, inverseModelView.columns.3.y, inverseModelView.columns.3.z)
        
        // Get color scheme parameters
        let colorSchemeParams = settingsSnapshot.colorSchemeParams
        
        // === PRECOMPUTE FRAME-UNIFORM VALUES (same as fragment shader) ===
        let computePrecomputedFractal: PrecomputedFractalParams = {
            let minRad2 = settingsSnapshot.minDistance
            let fractalScale = settingsSnapshot.fractalScale
            let sphereRadius = settingsSnapshot.sphereRadius
            let iterations = settingsSnapshot.fractalIterations
            
            let invMinRad = 1.0 / minRad2
            var scale = SIMD4<Float>(repeating: fractalScale * invMinRad)
            scale.w = abs(scale.w)
            
            let absScalem1 = abs(fractalScale - 1.0)
            let absScalePow = pow(max(abs(fractalScale), 1e-6), Float(1 - iterations))
            let sphereRadiusSq = sphereRadius * sphereRadius
            let invSphereRadiusSq = 1.0 / sphereRadiusSq
            
            return PrecomputedFractalParams(
                scale: scale,
                absScalem1: absScalem1,
                absScalePow: absScalePow,
                invSphereRadiusSq: invSphereRadiusSq,
                sphereRadiusSq: sphereRadiusSq
            )
        }()
        
        let computePrecomputedLighting: PrecomputedLighting = {
            let time = Float(appModel.clock.time)
            let gTime = time * 0.01 + 15.00
            let lightingMode = settingsSnapshot.lightingMode
            let audioLevel = settingsSnapshot.audioLevel
            
            let spotLightPosition: SIMD3<Float>
            let lightIntensity: Float
            
            switch lightingMode {
            case .staticLight:
                spotLightPosition = SIMD3<Float>(2.0, 1.5, 2.0)
                lightIntensity = 1.0
            case .audioReactive:
                let basePos = SIMD3<Float>(1.5, 1.0, 1.5)
                let pulse = audioLevel * 2.0
                let audioOffset = SIMD3<Float>(
                    sin(gTime * 2.0) * pulse,
                    audioLevel * 1.5,
                    cos(gTime * 2.0) * pulse
                )
                spotLightPosition = basePos + audioOffset
                lightIntensity = 0.5 + audioLevel * 1.5
            case .animated:
                let pathT = gTime + 0.03
                let path = SIMD3<Float>(
                    -0.78 + 3.0 * sin(2.14 * pathT),
                    0.05 + 2.5 * sin(0.942 * pathT + 1.3),
                    0.05 + 3.5 * cos(3.594 * pathT)
                )
                let offset = SIMD3<Float>(
                    sin(gTime * 18.4),
                    cos(gTime * 17.98),
                    sin(gTime * 22.53)
                ) * 0.2
                spotLightPosition = path + offset
                lightIntensity = 0.9 + sin(gTime * 1.5) * 0.15
            }
            
            return PrecomputedLighting(
                spotLightPosition: spotLightPosition,
                lightIntensity: lightIntensity
            )
        }()
        
        var tileUniforms = TileUniforms(
            invViewMatrix: inverseModelView,  // Use inverse MODEL-VIEW, not just inverse view!
            invProjMatrix: projection.inverse,
            cameraPos: cameraPos,
            time: Float(appModel.clock.time),
            resolution: SIMD2<Float>(Float(outputTexture.width), Float(outputTexture.height)),
            minDistance: settingsSnapshot.minDistance,
            fractalScale: settingsSnapshot.fractalScale,
            sphereRadius: settingsSnapshot.sphereRadius,
            safetyBubbleRadius: settingsSnapshot.safetyBubbleRadius,
            safetyBubbleEnabled: settingsSnapshot.safetyBubbleEnabled ? 1 : 0,
            safetyBubbleShape: settingsSnapshot.safetyBubbleShape,
            foldingLimit: settingsSnapshot.foldingLimit,
            glowIntensity: settingsSnapshot.glowIntensity,
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
            emissiveEnabled: settingsSnapshot.emissiveEnabled ? 1 : 0,
            emissivePattern: Int32(settingsSnapshot.emissivePattern),
            emissiveIntensity: settingsSnapshot.emissiveIntensity,
            emissiveThreshold: settingsSnapshot.emissiveThreshold,
            emissiveColor: settingsSnapshot.emissiveColor,
            emissiveSpeed: settingsSnapshot.emissiveSpeed,
            fogIntensity: settingsSnapshot.fogIntensity,
            maxViewDistance: RenderSettings.maxViewDistance,
            logDepthScale: RenderSettings.logDepthScale,
            depthMissValue: RenderSettings.depthMissValue,
            // ═══════════════════════════════════════════════════════════════
            // GEOMETRY STABILITY STATE
            // ═══════════════════════════════════════════════════════════════
            geometryState: Int32(settingsSnapshot.geometryState.rawValue),
            geometryStableFrames: Int32(settingsSnapshot.geometryState == .stable ? appModel.renderSettings.geometryStableFrameCount : 0),
            _padding1: 0.0,
            _padding2: 0.0,
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
    
    // MARK: - Stochastic Rendering
    
    /// Ensures stochastic accumulation textures exist and match drawable size
    private func ensureStochasticTextures(for drawable: LayerRenderer.Drawable) -> Bool {
        let width = drawable.colorTextures[0].width
        let height = drawable.colorTextures[0].height
        
        // Check if existing textures match
        if let existing = stochasticAccumulationTextureL,
           existing.width == width,
           existing.height == height {
            return true
        }
        
        // Create accumulation textures (one per eye, 2D not array)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float,  // High precision for accumulation
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.storageMode = .private
        descriptor.usage = [.shaderWrite, .shaderRead]
        
        guard let accumL = device.makeTexture(descriptor: descriptor),
              let accumR = device.makeTexture(descriptor: descriptor),
              let output = device.makeTexture(descriptor: descriptor) else {
            print("⚠️ Failed to create stochastic textures")
            return false
        }
        
        accumL.label = "Stochastic Accumulation L"
        accumR.label = "Stochastic Accumulation R"
        output.label = "Stochastic Output"
        
        stochasticAccumulationTextureL = accumL
        stochasticAccumulationTextureR = accumR
        stochasticOutputTexture = output
        
        print("✊ Created stochastic textures: \(width)×\(height)")
        return true
    }
    
    /// Renders using stochastic progressive refinement
    /// Returns true if stochastic rendering was used
    private func renderWithStochastic(
        commandBuffer: MTLCommandBuffer,
        drawable: LayerRenderer.Drawable,
        settingsSnapshot: RenderSettingsSnapshot
    ) -> Bool {
        // Verify we have the pipelines
        guard let raymarchPipeline = stochasticRaymarchPipeline,
              let copyPipeline = stochasticCopyPipeline,
              let resolvePipeline = stochasticResolvePipeline,
              let clearPipeline = stochasticClearPipeline,
              let uniformBuffer = stochasticUniformBuffer else {
            return false
        }
        
        // Ensure textures exist
        guard ensureStochasticTextures(for: drawable) else {
            return false
        }
        
        guard let accumL = stochasticAccumulationTextureL,
              let accumR = stochasticAccumulationTextureR,
              let outputTex = stochasticOutputTexture else {
            return false
        }
        
        let frameCount = settingsSnapshot.stochasticFrameCount
        let maxFrames = settingsSnapshot.stochasticMaxFrames
        
        // Clear accumulation on first frame
        if frameCount == 0 {
            guard let clearEncoder = commandBuffer.makeComputeCommandEncoder() else { return false }
            clearEncoder.label = "Stochastic Clear"
            clearEncoder.setComputePipelineState(clearPipeline)
            
            let threadsPerGroup = MTLSize(width: 16, height: 16, depth: 1)
            let threadgroups = MTLSize(
                width: (accumL.width + 15) / 16,
                height: (accumL.height + 15) / 16,
                depth: 1
            )
            
            clearEncoder.setTexture(accumL, index: 0)
            clearEncoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerGroup)
            
            clearEncoder.setTexture(accumR, index: 0)
            clearEncoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerGroup)
            
            clearEncoder.endEncoding()
        }
        
        // Render each eye with stochastic raymarch
        for viewIndex in 0..<drawable.views.count {
            let view = drawable.views[viewIndex]
            let accumTexture = viewIndex == 0 ? accumL : accumR
            
            // Get view and projection matrices
            let deviceTransform = drawable.deviceAnchor?.originFromAnchorTransform ?? matrix_identity_float4x4
            let viewMatrix = (deviceTransform * view.transform).inverse
            let projection = drawable.computeProjection(viewIndex: viewIndex)
            
            // Fill uniform buffer with stochastic uniforms
            // Note: We're using a simplified struct layout that matches the shader
            struct StochasticUniformsLayout {
                var projectionMatrix: matrix_float4x4
                var modelViewMatrix: matrix_float4x4
                var inverseModelViewMatrix: matrix_float4x4
                var inverseProjectionMatrix: matrix_float4x4
                var viewMatrix: matrix_float4x4
                var inverseViewMatrix: matrix_float4x4
                var time: Float
                var minDistance: Float
                var fractalScale: Float
                var fractalIterations: Int32
                var maxRaySteps: Int32
                var foldingLimit: Float
                var sphereRadius: Float
                var safetyBubbleRadius: Float
                var safetyBubbleEnabled: Int32
                var frameCount: Int32
                var maxFrames: Int32
                var jitterOffsetX: Float
                var jitterOffsetY: Float
                var blendWeight: Float
            }
            
            // Model matrix (same as main renderer)
            let translationMatrix = matrix4x4_translation(smoothedPosition.x, smoothedPosition.y, smoothedPosition.z)
            let scaleMatrix = matrix4x4_scale(smoothedScale, smoothedScale, smoothedScale)
            let modelMatrix = translationMatrix * cachedRotationMatrix * scaleMatrix
            let modelView = viewMatrix * modelMatrix
            
            // Halton jitter for this frame
            func halton(_ index: Int, _ base: Int) -> Float {
                var f: Float = 1.0
                var r: Float = 0.0
                var i = index
                while i > 0 {
                    f = f / Float(base)
                    r = r + f * Float(i % base)
                    i = i / base
                }
                return r
            }
            let jitterX = halton(frameCount + 1, 2) - 0.5
            let jitterY = halton(frameCount + 1, 3) - 0.5
            
            var uniforms = StochasticUniformsLayout(
                projectionMatrix: projection,
                modelViewMatrix: modelView,
                inverseModelViewMatrix: modelView.inverse,
                inverseProjectionMatrix: projection.inverse,
                viewMatrix: viewMatrix,
                inverseViewMatrix: viewMatrix.inverse,
                time: Float(appModel.clock.time),
                minDistance: settingsSnapshot.minDistance,
                fractalScale: settingsSnapshot.fractalScale,
                fractalIterations: Int32(settingsSnapshot.fractalIterations),
                maxRaySteps: Int32(settingsSnapshot.maxRaySteps),
                foldingLimit: settingsSnapshot.foldingLimit,
                sphereRadius: settingsSnapshot.sphereRadius,
                safetyBubbleRadius: settingsSnapshot.safetyBubbleRadius,
                safetyBubbleEnabled: settingsSnapshot.safetyBubbleEnabled ? 1 : 0,
                frameCount: Int32(frameCount),
                maxFrames: Int32(maxFrames),
                jitterOffsetX: jitterX,
                jitterOffsetY: jitterY,
                blendWeight: 1.0 / Float(frameCount + 1)
            )
            
            memcpy(uniformBuffer.contents(), &uniforms, MemoryLayout<StochasticUniformsLayout>.size)
            
            // Raymarch pass
            guard let computeEncoder = commandBuffer.makeComputeCommandEncoder() else { continue }
            computeEncoder.label = "Stochastic Raymarch Eye \(viewIndex)"
            computeEncoder.setComputePipelineState(raymarchPipeline)
            
            computeEncoder.setTexture(outputTex, index: 0)
            computeEncoder.setTexture(accumTexture, index: 1)
            computeEncoder.setBuffer(uniformBuffer, offset: 0, index: 0)
            
            let threadsPerGroup = MTLSize(width: 16, height: 16, depth: 1)
            let threadgroups = MTLSize(
                width: (outputTex.width + 15) / 16,
                height: (outputTex.height + 15) / 16,
                depth: 1
            )
            computeEncoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerGroup)
            computeEncoder.endEncoding()
            
            // Copy output to accumulation for next frame
            guard let copyEncoder = commandBuffer.makeComputeCommandEncoder() else { continue }
            copyEncoder.label = "Stochastic Copy Eye \(viewIndex)"
            copyEncoder.setComputePipelineState(copyPipeline)
            copyEncoder.setTexture(outputTex, index: 0)
            copyEncoder.setTexture(accumTexture, index: 1)
            copyEncoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerGroup)
            copyEncoder.endEncoding()
            
            // Resolve to drawable
            guard let resolveEncoder = commandBuffer.makeComputeCommandEncoder() else { continue }
            resolveEncoder.label = "Stochastic Resolve Eye \(viewIndex)"
            resolveEncoder.setComputePipelineState(resolvePipeline)
            resolveEncoder.setTexture(accumTexture, index: 0)
            
            // Get destination texture for this eye
            let destTexture: MTLTexture
            if drawable.colorTextures.count > viewIndex {
                destTexture = drawable.colorTextures[viewIndex]
            } else {
                destTexture = drawable.colorTextures[0]
            }
            
            // We need to write to the drawable - create a temp writable texture and blit
            // For now, just copy from accumulation to a writable texture
            resolveEncoder.setTexture(outputTex, index: 1)
            var fc = Int32(frameCount)
            resolveEncoder.setBytes(&fc, length: MemoryLayout<Int32>.size, index: 0)
            resolveEncoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerGroup)
            resolveEncoder.endEncoding()
            
            // Blit resolved output to drawable
            guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else { continue }
            blitEncoder.label = "Stochastic Blit Eye \(viewIndex)"
            
            let destSlice = drawable.colorTextures.count > viewIndex ? 0 : viewIndex
            blitEncoder.copy(
                from: outputTex,
                sourceSlice: 0,
                sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(width: outputTex.width, height: outputTex.height, depth: 1),
                to: destTexture,
                destinationSlice: destSlice,
                destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
            )
            blitEncoder.endEncoding()
        }
        
        // Log progress periodically
        if frameCount % 16 == 0 {
            print("✊ STOCHASTIC: Frame \(frameCount + 1)/\(maxFrames) accumulated")
        }
        
        return true
    }
    
    // ═══════════════════════════════════════════════════════════════════════════
    // STABLE GEOMETRY RENDERING
    // Optimized render path when fractal geometry parameters are stable.
    // Uses temporal accumulation to progressively improve quality.
    // ═══════════════════════════════════════════════════════════════════════════
    
    /// Ensures stable geometry accumulation textures exist and match drawable size
    private func ensureStableGeometryTextures(for drawable: LayerRenderer.Drawable) -> Bool {
        let width = drawable.colorTextures[0].width
        let height = drawable.colorTextures[0].height
        let requiredSize = SIMD2<Int>(width, height)
        let drawableFormat = drawable.colorTextures[0].pixelFormat
        
        // Check if textures need recreation
        if stableGeometryTextureSize != requiredSize ||
           stableGeometryAccumulationTextureL == nil ||
           stableGeometryAccumulationTextureR == nil ||
           stableGeometryOutputTexture == nil {
            
            // Accumulation textures need high precision for accumulation math
            let accumDescriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float,  // High precision for accumulation
                width: width,
                height: height,
                mipmapped: false
            )
            accumDescriptor.usage = [.shaderRead, .shaderWrite]
            accumDescriptor.storageMode = .private
            
            stableGeometryAccumulationTextureL = device.makeTexture(descriptor: accumDescriptor)
            stableGeometryAccumulationTextureL?.label = "StableGeometry Accumulation L"
            
            stableGeometryAccumulationTextureR = device.makeTexture(descriptor: accumDescriptor)
            stableGeometryAccumulationTextureR?.label = "StableGeometry Accumulation R"
            
            // Output texture must match drawable format for blit compatibility
            let outputDescriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: drawableFormat,  // Match drawable format for blit
                width: width,
                height: height,
                mipmapped: false
            )
            outputDescriptor.usage = [.shaderRead, .shaderWrite]
            outputDescriptor.storageMode = .private
            
            stableGeometryOutputTexture = device.makeTexture(descriptor: outputDescriptor)
            stableGeometryOutputTexture?.label = "StableGeometry Output"
            
            stableGeometryTextureSize = requiredSize
            stableGeometryAccumulatedFrames = 0  // Reset accumulation on resize
            
            if RENDERER_DEBUG {
                print("🎯 STABLE GEOMETRY: Created textures \(width)x\(height), output format: \(drawableFormat.rawValue)")
            }
        }
        
        return stableGeometryAccumulationTextureL != nil &&
               stableGeometryAccumulationTextureR != nil &&
               stableGeometryOutputTexture != nil
    }
    
    /// Renders using stable geometry optimized path with temporal accumulation
    /// Returns true if stable geometry rendering was used
    private func renderWithStableGeometry(
        commandBuffer: MTLCommandBuffer,
        drawable: LayerRenderer.Drawable,
        settingsSnapshot: RenderSettingsSnapshot
    ) -> Bool {
        // For now, we'll use the stochastic pipeline infrastructure since it already
        // has temporal accumulation. Later we can create a dedicated optimized pipeline.
        
        // Ensure we have the stochastic pipelines to reuse
        guard let raymarchPipeline = stochasticRaymarchPipeline,
              let copyPipeline = stochasticCopyPipeline,
              let resolvePipeline = stochasticResolvePipeline,
              let clearPipeline = stochasticClearPipeline,
              let uniformBuffer = stochasticUniformBuffer else {
            // Fall back to standard rendering if pipelines not available
            return false
        }
        
        // Ensure stable geometry textures exist
        guard ensureStableGeometryTextures(for: drawable) else {
            return false
        }
        
        guard let accumL = stableGeometryAccumulationTextureL,
              let accumR = stableGeometryAccumulationTextureR,
              let outputTex = stableGeometryOutputTexture else {
            return false
        }
        
        let frameCount = stableGeometryAccumulatedFrames
        let maxFrames = 32  // Accumulate up to 32 frames for stable geometry
        
        // Clear accumulation on first frame
        if frameCount == 0 {
            guard let clearEncoder = commandBuffer.makeComputeCommandEncoder() else { return false }
            clearEncoder.label = "StableGeometry Clear"
            clearEncoder.setComputePipelineState(clearPipeline)
            
            let threadsPerGroup = MTLSize(width: 16, height: 16, depth: 1)
            let threadgroups = MTLSize(
                width: (accumL.width + 15) / 16,
                height: (accumL.height + 15) / 16,
                depth: 1
            )
            
            clearEncoder.setTexture(accumL, index: 0)
            clearEncoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerGroup)
            
            clearEncoder.setTexture(accumR, index: 0)
            clearEncoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerGroup)
            
            clearEncoder.endEncoding()
        }
        
        // Only accumulate up to maxFrames
        if frameCount >= maxFrames {
            // Just display the accumulated result without adding more samples
            for viewIndex in 0..<drawable.views.count {
                let accumTexture = viewIndex == 0 ? accumL : accumR
                
                // Resolve accumulated result to output
                guard let resolveEncoder = commandBuffer.makeComputeCommandEncoder() else { continue }
                resolveEncoder.label = "StableGeometry Resolve Eye \(viewIndex)"
                resolveEncoder.setComputePipelineState(resolvePipeline)
                resolveEncoder.setTexture(accumTexture, index: 0)
                resolveEncoder.setTexture(outputTex, index: 1)
                
                var fc = Int32(maxFrames - 1)
                resolveEncoder.setBytes(&fc, length: MemoryLayout<Int32>.size, index: 0)
                
                let threadsPerGroup = MTLSize(width: 16, height: 16, depth: 1)
                let threadgroups = MTLSize(
                    width: (outputTex.width + 15) / 16,
                    height: (outputTex.height + 15) / 16,
                    depth: 1
                )
                resolveEncoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerGroup)
                resolveEncoder.endEncoding()
                
                // Blit to drawable
                guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else { continue }
                blitEncoder.label = "StableGeometry Blit Eye \(viewIndex)"
                
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
                    sourceSize: MTLSize(width: outputTex.width, height: outputTex.height, depth: 1),
                    to: destTexture,
                    destinationSlice: destSlice,
                    destinationLevel: 0,
                    destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
                )
                blitEncoder.endEncoding()
            }
            return true
        }
        
        // Render each eye with temporal accumulation
        for viewIndex in 0..<drawable.views.count {
            let view = drawable.views[viewIndex]
            let accumTexture = viewIndex == 0 ? accumL : accumR
            
            // Get view and projection matrices
            let deviceTransform = drawable.deviceAnchor?.originFromAnchorTransform ?? matrix_identity_float4x4
            let viewMatrix = (deviceTransform * view.transform).inverse
            let projection = drawable.computeProjection(viewIndex: viewIndex)
            
            // Uniform layout matching stochastic shader
            struct StableGeometryUniformsLayout {
                var projectionMatrix: matrix_float4x4
                var modelViewMatrix: matrix_float4x4
                var inverseModelViewMatrix: matrix_float4x4
                var inverseProjectionMatrix: matrix_float4x4
                var viewMatrix: matrix_float4x4
                var inverseViewMatrix: matrix_float4x4
                var time: Float
                var minDistance: Float
                var fractalScale: Float
                var fractalIterations: Int32
                var maxRaySteps: Int32
                var foldingLimit: Float
                var sphereRadius: Float
                var safetyBubbleRadius: Float
                var safetyBubbleEnabled: Int32
                var frameCount: Int32
                var maxFrames: Int32
                var jitterOffsetX: Float
                var jitterOffsetY: Float
                var blendWeight: Float
            }
            
            // Model matrix
            let translationMatrix = matrix4x4_translation(smoothedPosition.x, smoothedPosition.y, smoothedPosition.z)
            let scaleMatrix = matrix4x4_scale(smoothedScale, smoothedScale, smoothedScale)
            let modelMatrix = translationMatrix * cachedRotationMatrix * scaleMatrix
            let modelView = viewMatrix * modelMatrix
            
            // Halton jitter for temporal anti-aliasing
            func halton(_ index: Int, _ base: Int) -> Float {
                var f: Float = 1.0
                var r: Float = 0.0
                var i = index
                while i > 0 {
                    f = f / Float(base)
                    r = r + f * Float(i % base)
                    i = i / base
                }
                return r
            }
            let jitterX = halton(frameCount + 1, 2) - 0.5
            let jitterY = halton(frameCount + 1, 3) - 0.5
            
            var uniforms = StableGeometryUniformsLayout(
                projectionMatrix: projection,
                modelViewMatrix: modelView,
                inverseModelViewMatrix: modelView.inverse,
                inverseProjectionMatrix: projection.inverse,
                viewMatrix: viewMatrix,
                inverseViewMatrix: viewMatrix.inverse,
                time: Float(appModel.clock.time),
                minDistance: settingsSnapshot.minDistance,
                fractalScale: settingsSnapshot.fractalScale,
                fractalIterations: Int32(settingsSnapshot.fractalIterations),
                maxRaySteps: Int32(settingsSnapshot.maxRaySteps),
                foldingLimit: settingsSnapshot.foldingLimit,
                sphereRadius: settingsSnapshot.sphereRadius,
                safetyBubbleRadius: settingsSnapshot.safetyBubbleRadius,
                safetyBubbleEnabled: settingsSnapshot.safetyBubbleEnabled ? 1 : 0,
                frameCount: Int32(frameCount),
                maxFrames: Int32(maxFrames),
                jitterOffsetX: jitterX,
                jitterOffsetY: jitterY,
                blendWeight: 1.0 / Float(frameCount + 1)
            )
            
            memcpy(uniformBuffer.contents(), &uniforms, MemoryLayout<StableGeometryUniformsLayout>.size)
            
            // Raymarch pass
            guard let computeEncoder = commandBuffer.makeComputeCommandEncoder() else { continue }
            computeEncoder.label = "StableGeometry Raymarch Eye \(viewIndex)"
            computeEncoder.setComputePipelineState(raymarchPipeline)
            
            computeEncoder.setTexture(outputTex, index: 0)
            computeEncoder.setTexture(accumTexture, index: 1)
            computeEncoder.setBuffer(uniformBuffer, offset: 0, index: 0)
            
            let threadsPerGroup = MTLSize(width: 16, height: 16, depth: 1)
            let threadgroups = MTLSize(
                width: (outputTex.width + 15) / 16,
                height: (outputTex.height + 15) / 16,
                depth: 1
            )
            computeEncoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerGroup)
            computeEncoder.endEncoding()
            
            // Copy output to accumulation for next frame
            guard let copyEncoder = commandBuffer.makeComputeCommandEncoder() else { continue }
            copyEncoder.label = "StableGeometry Copy Eye \(viewIndex)"
            copyEncoder.setComputePipelineState(copyPipeline)
            copyEncoder.setTexture(outputTex, index: 0)
            copyEncoder.setTexture(accumTexture, index: 1)
            copyEncoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerGroup)
            copyEncoder.endEncoding()
            
            // Resolve to drawable
            guard let resolveEncoder = commandBuffer.makeComputeCommandEncoder() else { continue }
            resolveEncoder.label = "StableGeometry Resolve Eye \(viewIndex)"
            resolveEncoder.setComputePipelineState(resolvePipeline)
            resolveEncoder.setTexture(accumTexture, index: 0)
            
            let destTexture: MTLTexture
            if drawable.colorTextures.count > viewIndex {
                destTexture = drawable.colorTextures[viewIndex]
            } else {
                destTexture = drawable.colorTextures[0]
            }
            
            resolveEncoder.setTexture(outputTex, index: 1)
            var fc = Int32(frameCount)
            resolveEncoder.setBytes(&fc, length: MemoryLayout<Int32>.size, index: 0)
            resolveEncoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerGroup)
            resolveEncoder.endEncoding()
            
            // Blit resolved output to drawable
            guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else { continue }
            blitEncoder.label = "StableGeometry Blit Eye \(viewIndex)"
            
            let destSlice = drawable.colorTextures.count > viewIndex ? 0 : viewIndex
            blitEncoder.copy(
                from: outputTex,
                sourceSlice: 0,
                sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(width: outputTex.width, height: outputTex.height, depth: 1),
                to: destTexture,
                destinationSlice: destSlice,
                destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
            )
            blitEncoder.endEncoding()
        }
        
        // Increment accumulated frame count
        stableGeometryAccumulatedFrames += 1
        
        // Log progress periodically
        if frameCount == 0 || (frameCount + 1) % 8 == 0 {
            print("🎯 STABLE GEOMETRY: Frame \(frameCount + 1)/\(maxFrames) accumulated")
        }
        
        return true
    }
    
    /// Renders using the adaptive 8x8 compute pipeline instead of fragment shaders
    /// Returns true if compute rendering was used
    private func renderWithAdaptiveCompute(
        commandBuffer: MTLCommandBuffer,
        drawable: LayerRenderer.Drawable,
        settingsSnapshot: RenderSettingsSnapshot
    ) -> Bool {
        guard adaptiveHierarchicalPipeline8x8 != nil else { return false }
        
        guard let outputTexture = ensureComputeOutputTexture(for: drawable) else {
            return false
        }
        
        // Render each eye
        for viewIndex in 0..<drawable.views.count {
            encodeAdaptiveCompute(
                commandBuffer: commandBuffer,
                outputTexture: outputTexture,
                drawable: drawable,
                viewIndex: viewIndex,
                settingsSnapshot: settingsSnapshot
            )
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
            cmdBuffer.waitUntilCompleted()
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


    func renderLoop() {
        while true {
            if !appModel.isAppActive {
                // Avoid submitting GPU work while backgrounded
                Thread.sleep(forTimeInterval: 0.05)
                continue
            }
            if layerRenderer.state == .invalidated {
                if RENDERER_DEBUG { print("Layer is invalidated") }
                updateImmersiveSpaceStateIfNeeded(.closed)
                return
            } else if layerRenderer.state == .paused {
                updateImmersiveSpaceStateIfNeeded(.inTransition)
                layerRenderer.waitUntilRunning()
                continue
            } else {
                updateImmersiveSpaceStateIfNeeded(.open)
                
                // Check for pending screenshot request
                if shouldCaptureScreenshot {
                    shouldCaptureScreenshot = false
                    let screenshotData = renderScreenshot()
                    if RENDERER_DEBUG {
                        if screenshotData != nil {
                            print("📷 Screenshot captured (\(screenshotData!.count) bytes)")
                        } else {
                            print("⚠️ Screenshot capture FAILED")
                        }
                    }
                    pendingScreenshotContinuation?.resume(returning: screenshotData)
                    pendingScreenshotContinuation = nil
                }
                
                // Check for pipeline profiling request
                if shouldRunProfiler {
                    shouldRunProfiler = false
                    profilePipelineComponents()
                }
                
                autoreleasepool {
                    self.renderFrame()
                }
            }
        }
    }

    private func updateImmersiveSpaceStateIfNeeded(_ state: ImmersiveSpaceState) {
        guard lastImmersiveSpaceState != state else { return }
        lastImmersiveSpaceState = state
        Task { @MainActor in
            if appModel.immersiveSpaceState != state {
                appModel.immersiveSpaceState = state
            }
        }
    }
}

// Generic matrix math utility functions
func matrix4x4_rotation(radians: Float, axis: SIMD3<Float>) -> matrix_float4x4 {
    let unitAxis = normalize(axis)
    let ct = cosf(radians)
    let st = sinf(radians)
    let ci = 1 - ct
    let x = unitAxis.x, y = unitAxis.y, z = unitAxis.z
    return matrix_float4x4.init(columns:(vector_float4(    ct + x * x * ci, y * x * ci + z * st, z * x * ci - y * st, 0),
                                         vector_float4(x * y * ci - z * st,     ct + y * y * ci, z * y * ci + x * st, 0),
                                         vector_float4(x * z * ci + y * st, y * z * ci - x * st,     ct + z * z * ci, 0),
                                         vector_float4(                  0,                   0,                   0, 1)))
}

func matrix4x4_translation(_ translationX: Float, _ translationY: Float, _ translationZ: Float) -> matrix_float4x4 {
    return matrix_float4x4.init(columns:(vector_float4(1, 0, 0, 0),
                                         vector_float4(0, 1, 0, 0),
                                         vector_float4(0, 0, 1, 0),
                                         vector_float4(translationX, translationY, translationZ, 1)))
}

func matrix4x4_scale(_ scaleX: Float, _ scaleY: Float, _ scaleZ: Float) -> matrix_float4x4 {
    return matrix_float4x4.init(columns:(vector_float4(scaleX, 0, 0, 0),
                                         vector_float4(0, scaleY, 0, 0),
                                         vector_float4(0, 0, scaleZ, 0),
                                         vector_float4(0, 0, 0, 1)))
}

// smoothPose removed: renderer uses raw drawable.deviceAnchor for async timewarp


func decomposePose(_ m: matrix_float4x4) -> (translation: SIMD3<Float>, rotation: simd_quatf) {
    let translation = SIMD3<Float>(m.columns.3.x, m.columns.3.y, m.columns.3.z)
    let rotation = simd_quaternion(m)
    return (translation, rotation)
}

func composePose(translation: SIMD3<Float>, rotation: simd_quatf) -> matrix_float4x4 {
    var mat = matrix_float4x4(rotation)
    mat.columns.3 = SIMD4<Float>(translation, 1)
    return mat
}
