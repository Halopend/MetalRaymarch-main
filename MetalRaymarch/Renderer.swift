//
//  Renderer.swift
//  MetalProject
//
//  Created by MU on 18/11/24.
//

import CompositorServices
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

// Kuwahara filter parameters - must match shader definition
struct KuwaharaParams {
    var radius: Float       // Filter kernel radius (2-8)
    var sharpness: Float    // Edge sharpness factor (1-16)
    var resolution: SIMD2<Float>  // Texture resolution
    var eyeIndex: UInt32    // For stereo array textures
}

// Function constant indices - must match the indices in Shaders.metal
// These allow compile-time shader specialization for better performance
enum FunctionConstantIndex: Int {
    case fractalIterations = 0
    case shadowIterations = 1
    case safetyBubbleEnabled = 2
    case showHUD = 3
    case qualityMode = 4
    case debugHierarchical = 5
    case maxRaySteps = 6  // Max ray marching steps for loop unrolling
}

enum RendererError: Error {
    case badVertexDescriptor
}

extension LayerRenderer.Clock.Instant.Duration {
    var timeInterval: TimeInterval {
        let nanoseconds = TimeInterval(components.attoseconds / 1_000_000_000)
        return TimeInterval(components.seconds) + (nanoseconds / TimeInterval(NSEC_PER_SEC))
    }
}

/// Dedicated render thread using a persistent Thread object with high priority.\n/// This avoids thread hopping and preemption that causes micro-stutters with DispatchQueue.
final class RendererTaskExecutor: TaskExecutor {
    private var pendingJobs: [UnownedJob] = []
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var isRunning = true
    private var renderThread: Thread?
    
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
        return pendingJobs.isEmpty ? nil : pendingJobs.removeFirst()
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
    
    // === SPECIALIZED PIPELINES BY (iterations, raySteps) ===
    // Pre-compiled pipelines with fixed iteration and ray step counts for full loop unrolling
    // This is THE critical optimization - Map() loop and raymarch loop can be fully unrolled
    // Key: PipelineKey(fractalIterations, maxRaySteps)
    struct PipelineKey: Hashable {
        let fractalIterations: Int
        let maxRaySteps: Int
    }
    var specializedPipelines: [PipelineKey: MTLRenderPipelineState] = [:]
    var specializedQuadSharedPipelines: [PipelineKey: MTLRenderPipelineState] = [:]
    
    // Cached constant matrices (computed once, reused every frame)
    private let cachedRotationMatrix: matrix_float4x4
    
    // Tile-based compute pipelines (adaptive 8x8 hierarchical cascade)
    var adaptiveHierarchicalPipeline8x8: MTLComputePipelineState?  // Adaptive 3-level cascade
    var tileUniformBuffer: MTLBuffer?
    
    // Kuwahara filter pipeline (painterly post-processing)
    var kuwaharaPipeline: MTLComputePipelineState?
    var kuwaharaSimplePipeline: MTLComputePipelineState?
    var kuwaharaIntermediateTexture: MTLTexture?  // For in-place filtering
    
    // Dedicated compute output texture (has .shaderWrite flag that drawable textures lack)
    var computeOutputTexture: MTLTexture?
    var computeOutputSize: SIMD2<Int> = .zero
    
    // Screenshot capture
    var screenshotTexture: MTLTexture?
    var screenshotPipeline: MTLRenderPipelineState?
    var screenshotDepthTexture: MTLTexture?
    var pendingScreenshotContinuation: CheckedContinuation<Data?, Never>?
    var shouldCaptureScreenshot: Bool = false

    let inFlightSemaphore = DispatchSemaphore(value: maxBuffersInFlight)

    var uniformBufferOffset = 0

    var uniformBufferIndex = 0

    var uniforms: UnsafeMutablePointer<UniformsArray>

    let rasterSampleCount: Int = 1
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

    // Device pose smoothing removed — use raw device anchor from drawable for async timewarp
    

    // FPS tracking
    var lastPresentationTime: LayerRenderer.Clock.Instant?
    var smoothedFPS: Double = 0
    private var lastFPSUpdateTime: TimeInterval = 0
    private var lastHandTrackingUpdateTime: TimeInterval = 0  // Throttle hand UI updates
    private var cachedDeltaTime: Float = 1.0 / 90.0  // Cached for use in updateGameState
    private var lastPerfLogTime: TimeInterval = 0
    private let perfLogFrameMsThreshold: Double = 30.0  // ~33 FPS

    var smoothedPosition: SIMD3<Float> = .zero
    var smoothedScale: Float = 1.0
    


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
            print("✓ Quad-shared pipeline ready (2x2 SIMD grouping)")
        } catch {
            print("⚠️ Quad-shared pipeline failed: \(error)")
            quadSharedPipelineState = nil
        }
        
        // === BUILD SPECIALIZED PIPELINES FOR COMMON (iterations, raySteps) COMBINATIONS ===
        // This is THE critical optimization. Both loops can be unrolled:
        // 1. Map() inner loop (50-100+ calls per pixel × iterations each)
        // 2. Scene() raymarch loop (1 call per pixel × raySteps iterations)
        // With fixed counts, the compiler can fully unroll both loops, eliminating:
        // - Loop counter overhead
        // - Branch prediction misses  
        // - Register spilling from loop variables
        // Expected: 30-50% overall performance improvement
        
        // Quality presets: Low (6,32), Mid (9,64), High (12,100), Ultra (16,128)
        // Only build pipelines for exact preset combinations (4 pipelines, not 16)
        let qualityPresets = QualityPreset.allCases
        
        var pipelineCount = 0
        print("Building specialized pipelines for \(qualityPresets.count) quality presets...")
        
        for preset in qualityPresets {
            let iterCount = preset.fractalIterations
            let raySteps = preset.raySteps
            let key = PipelineKey(fractalIterations: iterCount, maxRaySteps: raySteps)
            let config = FunctionConstantConfig.forQualityPreset(preset)
            let constants = config.toMTLConstants()
            
            // Standard pipeline
            if let pipeline = try? Renderer.buildRenderPipelineWithDevice(
                device: device,
                layerRenderer: layerRenderer,
                rasterSampleCount: rasterSampleCount,
                mtlVertexDescriptor: mtlVertexDescriptor,
                functionConstants: constants
            ) {
                specializedPipelines[key] = pipeline
                pipelineCount += 1
                print("  ✓ \(preset.rawValue): FI=\(iterCount), RI=\(raySteps)")
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
                specializedQuadSharedPipelines[key] = pipeline
            }
        }
        print("✓ Built \(pipelineCount) specialized standard pipelines")

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
            // Using known iteration count allows full loop unrolling in Map()
            let computeConstants = MTLFunctionConstantValues()
            var fractalIters: Int32 = 6  // Default fractal iterations
            var shadowIters: Int32 = 4   // Default shadow iterations
            var noSafetyBubble: Bool = false
            var noDebug: Bool = false
            computeConstants.setConstantValue(&fractalIters, type: .int, index: FunctionConstantIndex.fractalIterations.rawValue)
            computeConstants.setConstantValue(&shadowIters, type: .int, index: FunctionConstantIndex.shadowIterations.rawValue)
            computeConstants.setConstantValue(&noSafetyBubble, type: .bool, index: FunctionConstantIndex.safetyBubbleEnabled.rawValue)
            computeConstants.setConstantValue(&noDebug, type: .bool, index: FunctionConstantIndex.debugHierarchical.rawValue)
            
            // Adaptive 8x8 hierarchical kernel (3-level cascade, 3-8x speedup) - with function constants
            if let kernel8x8 = try? library.makeFunction(name: "adaptiveHierarchical8x8", constantValues: computeConstants) {
                adaptiveHierarchicalPipeline8x8 = try device.makeComputePipelineState(function: kernel8x8)
                print("✓ Adaptive 8x8 hierarchical pipeline specialized with function constants")
            } else if let kernel8x8 = library.makeFunction(name: "adaptiveHierarchical8x8") {
                adaptiveHierarchicalPipeline8x8 = try device.makeComputePipelineState(function: kernel8x8)
                print("✓ Adaptive 8x8 hierarchical pipeline ready (3-level cascade)")
            }
            
            // Uniform buffer for tile compute (one per eye)
            let tileUniformSize = MemoryLayout<TileUniforms>.stride * 2
            tileUniformBuffer = device.makeBuffer(length: tileUniformSize, options: .storageModeShared)
            tileUniformBuffer?.label = "TileUniforms"
            
            // === KUWAHARA FILTER PIPELINES ===
            if let kuwaharaKernel = library.makeFunction(name: "anisotropicKuwaharaFilter") {
                kuwaharaPipeline = try device.makeComputePipelineState(function: kuwaharaKernel)
                print("✓ Anisotropic Kuwahara filter pipeline ready")
            }
            if let kuwaharaSimpleKernel = library.makeFunction(name: "kuwaharaFilterSimple") {
                kuwaharaSimplePipeline = try device.makeComputePipelineState(function: kuwaharaSimpleKernel)
                print("✓ Simple Kuwahara filter pipeline ready")
            }
            
            print("✓ Tile-based compute pipeline ready (adaptive 8x8)")
        } catch {
            print("⚠️ Failed to create tile compute pipelines: \(error)")
            adaptiveHierarchicalPipeline8x8 = nil
        }
        
        worldTracking = WorldTrackingProvider()
        handTracking = HandTrackingProvider()
        arSession = ARKitSession()
        // Setup screenshot capture pipeline
        setupScreenshotCapture()
        
        // === DYNAMIC RENDER QUALITY (WWDC25 Session 294) ===
        // Initialize dynamic quality manager if available on this OS version
        setupDynamicRenderQuality()
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
                print("✓ Dynamic render quality manager initialized (visionOS 26+)")
                print("  Target: \(settings.dynamicRenderQualityTarget), Range: \(settings.dynamicRenderQualityMin)-\(settings.dynamicRenderQualityMax)")
            } else {
                print("ℹ️ Dynamic render quality: Foveation not enabled (quality adjustment disabled)")
            }
        } else {
            print("ℹ️ Dynamic render quality: Requires visionOS 26+")
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
            print("✓ Screenshot capture pipeline ready")
        } catch {
            print("⚠️ Failed to create screenshot pipeline: \(error)")
        }
    }

    private func startARSession() async {
        // We only request head-tracking permission so we can keep the request minimal
        guard WorldTrackingProvider.isSupported else {
            print("⚠️ World tracking is not supported on this device")
            return
        }

        print("ℹ️ Requesting only world sensing (for pose) plus hand tracking; no extra sensors requested.")
        var authStatus = await arSession.queryAuthorization(for: [.worldSensing, .handTracking])
        if authStatus[.worldSensing] == .notDetermined || authStatus[.handTracking] == .notDetermined {
            print("🔐 Requesting ARKit world-sensing + hand-tracking authorization")
            authStatus = await arSession.requestAuthorization(for: [.worldSensing, .handTracking])
        }

        if authStatus[.worldSensing] != .allowed {
            print("⚠️ World sensing not authorized. Status: \(String(describing: authStatus[.worldSensing]))")
            print("   Pose will be limited (rotation only)")
        }

        if authStatus[.handTracking] != .allowed {
            print("⚠️ Hand tracking not authorized. Status: \(String(describing: authStatus[.handTracking]))")
        }
        
        do {
            var providers: [any DataProvider] = [worldTracking]
            if let ht = handTracking, authStatus[.handTracking] == .allowed {
                providers.append(ht)
            }
            try await arSession.run(providers)
            print("✓ ARKit session started with world tracking and hand tracking")
            
            // Log world tracking state
            print("  World tracking state: \(worldTracking.state)")
        } catch {
            if !hasLoggedWorldTrackingWarning {
                print("⚠️ ARKit session failed: \(error)")
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
        
        /// Creates MTLFunctionConstantValues from this config
        func toMTLConstants() -> MTLFunctionConstantValues {
            let constants = MTLFunctionConstantValues()
            
            if var iterations = fractalIterations {
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
            
            return constants
        }
        
        /// Creates a config optimized for high performance (Low quality preset: FI=6, RI=32)
        static var highPerformance: FunctionConstantConfig {
            return FunctionConstantConfig(
                fractalIterations: 6,
                shadowIterations: 4,
                safetyBubbleEnabled: false,
                showHUD: false,
                qualityMode: 2,  // Low quality
                debugHierarchical: false,
                maxRaySteps: 32
            )
        }
        
        /// Creates a config for high quality rendering (Ultra quality preset: FI=16, RI=128)
        static var highQuality: FunctionConstantConfig {
            return FunctionConstantConfig(
                fractalIterations: 16,
                shadowIterations: 14,
                safetyBubbleEnabled: true,
                showHUD: true,
                qualityMode: 0,  // High quality
                debugHierarchical: false,
                maxRaySteps: 128
            )
        }
        
        /// Creates a config for each quality preset
        static func forQualityPreset(_ preset: QualityPreset) -> FunctionConstantConfig {
            let qualityMode: Int32
            switch preset {
            case .iter6: qualityMode = 2
            case .iter7: qualityMode = 2
            case .iter8: qualityMode = 1
            case .iter9: qualityMode = 1
            case .iter12: qualityMode = 0
            case .iter16: qualityMode = 0
            }
            return FunctionConstantConfig(
                fractalIterations: Int32(preset.fractalIterations),
                shadowIterations: Int32(max(preset.fractalIterations - 2, 2)),
                safetyBubbleEnabled: true,
                showHUD: true,
                qualityMode: qualityMode,
                debugHierarchical: false,
                maxRaySteps: Int32(preset.raySteps)
            )
        }
    }
    
    /// Select the best specialized pipeline for the given iteration count and ray steps
    /// Falls back to general pipeline if no specialized version exists
    func selectPipeline(forIterations iterations: Int, raySteps: Int, useQuadShared: Bool) -> MTLRenderPipelineState {
        let key = PipelineKey(fractalIterations: iterations, maxRaySteps: raySteps)
        
        if useQuadShared {
            if let specialized = specializedQuadSharedPipelines[key] {
                return specialized
            }
            return quadSharedPipelineState ?? pipelineState
        } else {
            if let specialized = specializedPipelines[key] {
                return specialized
            }
            return pipelineState
        }
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

        uniformBufferIndex = (uniformBufferIndex + 1) % maxBuffersInFlight

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
    /// This implements Apple's WWDC25 Session 294 dynamic render quality API.
    private func updateDynamicRenderQuality(fps: Double, deltaTime: TimeInterval) {
        if #available(visionOS 26.0, *) {
            guard let manager = dynamicRenderQualityManager as? DynamicRenderQualityManager else { return }
            
            let settings = appModel.renderSettings
            
            // Sync manager settings with RenderSettings (in case user changed them)
            manager.isEnabled = settings.dynamicRenderQualityEnabled
            manager.minQuality = settings.dynamicRenderQualityMin
            manager.maxQuality = settings.dynamicRenderQualityMax
            
            // Update the manager with current FPS
            manager.update(fps: fps, deltaTime: deltaTime, layerRenderer: layerRenderer)
            
            // Sync current quality back to settings for UI display
            settings.currentRenderQuality = manager.currentQuality
            
            // Log status once
            if !hasLoggedDynamicQualityStatus && manager.isEnabled {
                hasLoggedDynamicQualityStatus = true
                if layerRenderer.configuration.isFoveationEnabled {
                    print("✓ Dynamic render quality active: adjusting based on FPS")
                }
            }
            
            // Optionally hint scene complexity when fractal parameters change significantly
            // This helps the manager anticipate quality needs
            let complexity = DynamicRenderQualityManager.estimateFractalComplexity(
                iterations: settings.fractalIterations,
                raySteps: settings.maxRaySteps,
                tileSize: settings.tileSize
            )
            manager.hintSceneComplexity(complexity, layerRenderer: layerRenderer)
        }
    }

    private func updateGameState(drawable: LayerRenderer.Drawable) {
        /// Update any game state before rendering

        let settings = appModel.renderSettings
        
        // === INTERPOLATE GESTURE-CONTROLLED VALUES ===
        // This is the SINGLE source of truth for smoothing gesture parameters.
        // Called every frame at 90Hz for smooth animation regardless of gesture update rate (30Hz).
        settings.interpolateToTargets(deltaTime: cachedDeltaTime)
        
        // Decay the limit flash effect using actual deltaTime
        settings.updateLimitFlash(deltaTime: cachedDeltaTime)
        
        // === COLOR SCHEME TRANSITION UPDATE ===
        // Smoothly transition between color schemes
        settings.updateColorSchemeTransition(deltaTime: cachedDeltaTime)
        
        // === AUDIO REACTIVE UPDATE ===
        // Pull audio level from analyzer if in audio-reactive mode
        if settings.lightingMode == .audioReactive && appModel.audioAnalyzer.isCapturing {
            let combinedLevel = appModel.audioAnalyzer.level * 0.6 + appModel.audioAnalyzer.bassLevel * 0.4
            settings.audioLevel = combinedLevel
        }
        
        // Use already-smoothed position from settings (interpolated above)
        // Scale gets its own smoothing since it's not gesture-controlled
        let smoothSpeed: Float = 15.0
        let smoothFactor = 1.0 - exp(-smoothSpeed * cachedDeltaTime)
        smoothedPosition = settings.position  // Already smoothed by interpolateToTargets
        smoothedScale = smoothedScale + (settings.scale - smoothedScale) * smoothFactor
        
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
            print("📍 Device anchor first frame:")
            print("   Position: (\(position.x), \(position.y), \(position.z))")
            print("   isTracked: \(anchor.isTracked)")
            // If position is exactly (0,0,0), world sensing permission may not be granted
            if position.x == 0 && position.y == 0 && position.z == 0 {
                print("   ⚠️ Position is origin - world sensing may not be authorized!")
            }
        }

        func uniforms(forViewIndex viewIndex: Int) -> Uniforms {
            let view = drawable.views[viewIndex]
            let viewMatrix = (deviceTransform * view.transform).inverse
            let projection = drawable.computeProjection(viewIndex: viewIndex)
            let inverseProjection = projection.inverse
            
            let modelView = viewMatrix * modelMatrix
            let inverseModelView = modelView.inverse
            let inverseView = viewMatrix.inverse

            // Optional lighting play mode: gently modulate color and glow
            let baseColorMix = settings.colorMix
            let baseGlow = settings.glowIntensity
            let lightingWave = sin(Float(appModel.clock.time) * 1.2)
            let animatedColorMix = settings.lightingPlay ? min(max(baseColorMix + lightingWave * 0.08, 0.0), 1.0) : baseColorMix
            let animatedGlow = settings.lightingPlay ? min(max(baseGlow + max(0, lightingWave) * 0.25, 0.0), 2.0) : baseGlow
            
            // Get color scheme parameters (handles transitions internally)
            let colorSchemeParams = settings.getColorSchemeParams()
            
            // Get fovea center from the view's texture map (normalized 0-1)
            return Uniforms(projectionMatrix: projection,
                            modelViewMatrix: modelView,
                            inverseModelViewMatrix: inverseModelView,
                            inverseProjectionMatrix: inverseProjection,
                            viewMatrix: viewMatrix,
                            inverseViewMatrix: inverseView,
                            time: Float(appModel.clock.time),
                            minDistance: settings.minDistance,
                            fractalScale: settings.fractalScale,
                            fractalIterations: Int32(settings.fractalIterations),
                            maxRaySteps: Int32(settings.maxRaySteps),
                            colorMix: animatedColorMix,
                            glowIntensity: animatedGlow,
                            foldingLimit: settings.foldingLimit,
                            sphereRadius: settings.sphereRadius,
                            safetyBubbleRadius: settings.safetyBubbleRadius,
                            safetyBubbleEnabled: settings.safetyBubbleEnabled ? 1 : 0,
                            safetyBubbleShape: settings.safetyBubbleShape,
                            colorIterations: settings.colorIterations,
                            useHierarchical: settings.useHierarchical ? 1 : 0,
                            limitFlash: settings.limitFlash,
                            showHUD: settings.showHUD ? 1 : 0,
                            activeGesture: Int32(settings.activeGestureIndex),
                            fractalType: settings.fractalType.rawValue,
                            lightingMode: settings.lightingMode.rawValue,
                            audioLevel: settings.audioLevel,
                            emissiveEnabled: settings.emissiveEnabled ? 1 : 0,
                            emissivePattern: Int32(settings.emissivePattern),
                            emissiveIntensity: settings.emissiveIntensity,
                            emissiveThreshold: settings.emissiveThreshold,
                            emissiveColor: settings.emissiveColor,
                            emissiveSpeed: settings.emissiveSpeed,
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

        // FPS tracking using clamped interval (stable with triple buffering)
        if deltaTime > 0 {
            let instantFPS = 1.0 / deltaTime
            let updatedFPS = smoothedFPS + (instantFPS - smoothedFPS) * 0.1
            smoothedFPS = updatedFPS
            
            // Throttle UI updates to 4Hz (every 0.25s) to prevent SwiftUI layout thrashing
            if time - lastFPSUpdateTime > 0.25 {
                lastFPSUpdateTime = time
                Task { @MainActor in
                    appModel.fps = updatedFPS
                }
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

        self.updateGameState(drawable: drawable)

        let settings = appModel.renderSettings

        // Check if using adaptive 8x8 compute pipeline
        let tileSize = settings.tileSize
        // MetalFX spatial upscaling disabled - causes frame drops without quality benefit
        let wantsMetalFX = false
        let useAdaptiveCompute = (tileSize == 8) && adaptiveHierarchicalPipeline8x8 != nil && !wantsMetalFX
        
        if useAdaptiveCompute {
            // Use compute-based rendering for 8x8 adaptive hierarchical
            let computeRendered = renderWithAdaptiveCompute(
                commandBuffer: commandBuffer,
                drawable: drawable
            )
            
            if computeRendered {
                // Apply Kuwahara post-processing if enabled
                if settings.kuwaharaEnabled {
                    applyKuwaharaFilter(commandBuffer: commandBuffer, drawable: drawable, settings: settings)
                }
                
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
                settings: settings,
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
        let currentIterations = appModel.renderSettings.fractalIterations
        let currentRaySteps = appModel.renderSettings.maxRaySteps
        
        // Use specialized pipeline with fixed iteration count for full loop unrolling
        // This is THE critical optimization - Map() inner loop can be fully unrolled
        let selectedPipeline = selectPipeline(
            forIterations: currentIterations,
            raySteps: currentRaySteps,
            useQuadShared: useQuadShared
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
        
        // === KUWAHARA POST-PROCESSING ===
        if settings.kuwaharaEnabled {
            applyKuwaharaFilter(commandBuffer: commandBuffer, drawable: drawable, settings: settings)
        }
        
    #if canImport(MetalFX)
        if let context = metalFXContext {
            try? context.manager.encodeSpatialUpscale(commandBuffer: commandBuffer, fence: nil)
            blitMetalFXOutputToDrawable(commandBuffer: commandBuffer, metalFX: context.manager, drawable: drawable)
        }
    #endif

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
                    settings: settings,
                    wantsMetalFX: wantsMetalFX,
                    useAdaptiveCompute: useAdaptiveCompute,
                    metalFXInputSize: metalFXInputSize,
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
            if !hasLoggedFoveationAvailability {
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
        settings: RenderSettings,
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
        print("⚠️ Slow frame: ft=\(String(format: "%.2f", frameMs))ms fps=\(String(format: "%.1f", fps)) gpu=\(gpuText)ms cpu=\(String(format: "%.2f", cpuEncodeMs))ms path=\(pathText) MetalFX=\(metalFXText) tile=\(settings.tileSize) iters=\(settings.fractalIterations) steps=\(settings.maxRaySteps) views=\(viewCount)")
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
                if !hasLoggedFoveationAvailability {
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
        settings: RenderSettings,
        rasterizationRateMap: MTLRasterizationRateMap?
    ) -> (MetalFXManager, Int, Int)? {
        let outputWidth = drawable.colorTextures[0].width
        let outputHeight = drawable.colorTextures[0].height
        let viewCount = drawable.views.count

        var inputWidth = max(1, Int(Float(outputWidth) * settings.resolutionScale))
        var inputHeight = max(1, Int(Float(outputHeight) * settings.resolutionScale))

        if layerRenderer.configuration.isFoveationEnabled, let map = rasterizationRateMap {
            let physical = map.physicalSize(layer: 0)
            if physical.width > 0 && physical.height > 0 {
                inputWidth = physical.width
                inputHeight = physical.height
            }
        }

        let config = MetalFXManager.Configuration(
            inputWidth: inputWidth,
            inputHeight: inputHeight,
            outputWidth: outputWidth,
            outputHeight: outputHeight,
            colorFormat: drawable.colorTextures[0].pixelFormat,
            depthFormat: drawable.depthTextures[0].pixelFormat,
            scale: settings.resolutionScale
        )

        do {
            if metalFXManager == nil {
                metalFXManager = try MetalFXManager(device: device, configuration: config, viewCount: viewCount)
            } else {
                try metalFXManager?.update(configuration: config, viewCount: viewCount)
            }
        } catch {
            if !hasLoggedMetalFXFallback {
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
        viewIndex: Int
    ) {
        guard let pipeline = adaptiveHierarchicalPipeline8x8,
              let uniformBuffer = tileUniformBuffer else {
            print("⚠️ Adaptive compute pipeline not available")
            return
        }
        
        let settings = appModel.renderSettings
        let view = drawable.views[viewIndex]
        
        // Build model matrix (must match fragment shader exactly!)
        let t: Float = 0.1
        let currentSmoothedPosition = smoothedPosition + (settings.position - smoothedPosition) * t
        let currentSmoothedScale = smoothedScale + (settings.scale - smoothedScale) * t
        
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
        let colorSchemeParams = settings.getColorSchemeParams()
        
        var tileUniforms = TileUniforms(
            invViewMatrix: inverseModelView,  // Use inverse MODEL-VIEW, not just inverse view!
            invProjMatrix: projection.inverse,
            cameraPos: cameraPos,
            time: Float(appModel.clock.time),
            resolution: SIMD2<Float>(Float(outputTexture.width), Float(outputTexture.height)),
            minDistance: settings.minDistance,
            fractalScale: settings.fractalScale,
            sphereRadius: settings.sphereRadius,
            safetyBubbleRadius: settings.safetyBubbleRadius,
            safetyBubbleEnabled: settings.safetyBubbleEnabled ? 1 : 0,
            safetyBubbleShape: settings.safetyBubbleShape,
            foldingLimit: settings.foldingLimit,
            glowIntensity: settings.glowIntensity,
            colorMix: settings.colorMix,
            fractalIterations: Int32(settings.fractalIterations),
            colorIterations: Int32(settings.colorIterations),
            maxRaySteps: Int32(settings.maxRaySteps),
            eyeIndex: UInt32(viewIndex),
            debugHierarchical: settings.debugHierarchical ? 1 : 0,
            limitFlash: settings.limitFlash,
            fractalType: settings.fractalType.rawValue,
            lightingMode: settings.lightingMode.rawValue,
            audioLevel: settings.audioLevel,
            emissiveEnabled: settings.emissiveEnabled ? 1 : 0,
            emissivePattern: Int32(settings.emissivePattern),
            emissiveIntensity: settings.emissiveIntensity,
            emissiveThreshold: settings.emissiveThreshold,
            emissiveColor: settings.emissiveColor,
            emissiveSpeed: settings.emissiveSpeed,
            colorScheme: colorSchemeParams
        )
        
        // Copy uniforms to buffer
        let uniformOffset = MemoryLayout<TileUniforms>.stride * viewIndex
        memcpy(uniformBuffer.contents().advanced(by: uniformOffset), &tileUniforms, MemoryLayout<TileUniforms>.size)
        
        // Create compute encoder
        guard let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
            print("⚠️ Failed to create compute encoder")
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
            print("⚠️ Failed to create compute output texture")
            return nil
        }
        texture.label = "Adaptive Compute Output"
        
        computeOutputTexture = texture
        computeOutputSize = SIMD2(width, height)
        print("📐 Created compute output texture: \(width)×\(height) × \(viewCount) layers")
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
    
    // MARK: - Kuwahara Filter
    
    /// Creates or resizes the intermediate texture for Kuwahara filtering
    private func ensureKuwaharaIntermediateTexture(matching texture: MTLTexture, viewCount: Int) -> MTLTexture? {
        // Check if existing texture matches
        if let existing = kuwaharaIntermediateTexture,
           existing.width == texture.width,
           existing.height == texture.height,
           existing.arrayLength == viewCount {
            return existing
        }
        
        // Create new texture with read/write access
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type2DArray
        descriptor.pixelFormat = texture.pixelFormat
        descriptor.width = texture.width
        descriptor.height = texture.height
        descriptor.arrayLength = viewCount
        descriptor.storageMode = .private
        descriptor.usage = [.shaderWrite, .shaderRead]
        
        guard let newTexture = device.makeTexture(descriptor: descriptor) else {
            print("⚠️ Failed to create Kuwahara intermediate texture")
            return nil
        }
        newTexture.label = "Kuwahara Intermediate"
        
        kuwaharaIntermediateTexture = newTexture
        print("📐 Created Kuwahara intermediate texture: \(texture.width)×\(texture.height) × \(viewCount) layers")
        return newTexture
    }
    
    /// Applies anisotropic Kuwahara filter as a post-processing effect
    private func applyKuwaharaFilter(
        commandBuffer: MTLCommandBuffer,
        drawable: LayerRenderer.Drawable,
        settings: RenderSettings
    ) {
        // Use simple pipeline for lower radii (faster), anisotropic for higher (better quality)
        let pipeline = settings.kuwaharaRadius > 4.0 ? kuwaharaPipeline : kuwaharaSimplePipeline
        guard let pipeline = pipeline else { return }
        
        let colorTexture = drawable.colorTextures[0]
        let viewCount = drawable.views.count
        
        // Ensure we have an intermediate texture for ping-pong filtering
        guard let intermediateTexture = ensureKuwaharaIntermediateTexture(matching: colorTexture, viewCount: viewCount) else {
            return
        }
        
        // Process each eye
        for eyeIndex in 0..<viewCount {
            // Step 1: Copy drawable to intermediate (since drawable may not have shaderRead)
            guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else { continue }
            blitEncoder.label = "Copy to Kuwahara Input \(eyeIndex)"
            
            let sourceTexture: MTLTexture
            let sourceSlice: Int
            if drawable.colorTextures.count > eyeIndex {
                sourceTexture = drawable.colorTextures[eyeIndex]
                sourceSlice = 0
            } else {
                sourceTexture = colorTexture
                sourceSlice = eyeIndex
            }
            
            blitEncoder.copy(
                from: sourceTexture,
                sourceSlice: sourceSlice,
                sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(width: sourceTexture.width, height: sourceTexture.height, depth: 1),
                to: intermediateTexture,
                destinationSlice: eyeIndex,
                destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
            )
            blitEncoder.endEncoding()
            
            // Step 2: Apply Kuwahara filter (intermediate -> compute output)
            guard let computeOutputTexture = ensureComputeOutputTexture(for: drawable) else { continue }
            guard let computeEncoder = commandBuffer.makeComputeCommandEncoder() else { continue }
            computeEncoder.label = "Kuwahara Filter \(eyeIndex)"
            
            // Create params for this eye
            var params = KuwaharaParams(
                radius: settings.kuwaharaRadius,
                sharpness: settings.kuwaharaSharpness,
                resolution: SIMD2<Float>(Float(colorTexture.width), Float(colorTexture.height)),
                eyeIndex: UInt32(eyeIndex)
            )
            
            computeEncoder.setComputePipelineState(pipeline)
            computeEncoder.setTexture(intermediateTexture, index: 0)      // Input
            computeEncoder.setTexture(computeOutputTexture, index: 1)     // Output
            // Use setBytes to avoid race condition - each encoder gets its own copy
            computeEncoder.setBytes(&params, length: MemoryLayout<KuwaharaParams>.size, index: 0)
            
            // Dispatch threads
            let threadgroupSize = MTLSize(width: 16, height: 16, depth: 1)
            let threadgroups = MTLSize(
                width: (colorTexture.width + threadgroupSize.width - 1) / threadgroupSize.width,
                height: (colorTexture.height + threadgroupSize.height - 1) / threadgroupSize.height,
                depth: 1
            )
            computeEncoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadgroupSize)
            computeEncoder.endEncoding()
            
            // Step 3: Copy result back to drawable
            guard let blitBack = commandBuffer.makeBlitCommandEncoder() else { continue }
            blitBack.label = "Copy Kuwahara Output \(eyeIndex)"
            
            let destTexture: MTLTexture
            let destSlice: Int
            if drawable.colorTextures.count > eyeIndex {
                destTexture = drawable.colorTextures[eyeIndex]
                destSlice = 0
            } else {
                destTexture = colorTexture
                destSlice = eyeIndex
            }
            
            blitBack.copy(
                from: computeOutputTexture,
                sourceSlice: eyeIndex,
                sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(width: computeOutputTexture.width, height: computeOutputTexture.height, depth: 1),
                to: destTexture,
                destinationSlice: destSlice,
                destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
            )
            blitBack.endEncoding()
        }
    }
    
    /// Renders using the adaptive 8x8 compute pipeline instead of fragment shaders
    /// Returns true if compute rendering was used
    private func renderWithAdaptiveCompute(
        commandBuffer: MTLCommandBuffer,
        drawable: LayerRenderer.Drawable
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
                viewIndex: viewIndex
            )
        }
        
        // Blit compute output to drawable for presentation
        blitComputeOutputToDrawable(commandBuffer: commandBuffer, drawable: drawable)
        
        return true
    }


    func renderLoop() {
        while true {
            if !appModel.isAppActive {
                // Avoid submitting GPU work while backgrounded
                Thread.sleep(forTimeInterval: 0.05)
                continue
            }
            if layerRenderer.state == .invalidated {
                print("Layer is invalidated")
                Task { @MainActor in
                    appModel.immersiveSpaceState = .closed
                }
                return
            } else if layerRenderer.state == .paused {
                Task { @MainActor in
                    appModel.immersiveSpaceState = .inTransition
                }
                layerRenderer.waitUntilRunning()
                continue
            } else {
                Task { @MainActor in
                    if appModel.immersiveSpaceState != .open {
                        appModel.immersiveSpaceState = .open
                    }
                }
                
                // Check for pending screenshot request
                if shouldCaptureScreenshot {
                    shouldCaptureScreenshot = false
                    let screenshotData = renderScreenshot()
                    if screenshotData != nil {
                        print("📷 Screenshot captured (\(screenshotData!.count) bytes)")
                    } else {
                        print("⚠️ Screenshot capture FAILED")
                    }
                    pendingScreenshotContinuation?.resume(returning: screenshotData)
                    pendingScreenshotContinuation = nil
                }
                
                autoreleasepool {
                    self.renderFrame()
                }
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


