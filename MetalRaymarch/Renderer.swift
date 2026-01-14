//
//  Renderer.swift
//  MetalProject
//
//  Created by MU on 18/11/24.
//

import CompositorServices
import Metal
import MetalKit
#if canImport(MetalFX)
import MetalFX
#endif
import simd
import ARKit

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

final class RendererTaskExecutor: TaskExecutor {
    private let queue = DispatchQueue(label: "RenderThreadQueue", qos: .userInteractive)

    func enqueue(_ job: UnownedJob) {
        queue.async {
          job.runSynchronously(on: self.asUnownedSerialExecutor())
        }
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
    var metalFXAmplificationPipelineState: MTLRenderPipelineState?  // Pipeline for amplification rgba16Float (uses amplification_id)
    var metalFXQuadSharedPipelineState: MTLRenderPipelineState?  // MetalFX + quad-shared
    var depthUpscalePipelineState: MTLRenderPipelineState?
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
    var specializedMetalFXPipelines: [PipelineKey: MTLRenderPipelineState] = [:]
    var specializedMetalFXQuadSharedPipelines: [PipelineKey: MTLRenderPipelineState] = [:]
    
    // Cached constant matrices (computed once, reused every frame)
    private let cachedRotationMatrix: matrix_float4x4
    
    // Tile-based compute pipelines (adaptive 8x8 hierarchical cascade)
    var adaptiveHierarchicalPipeline8x8: MTLComputePipelineState?  // Adaptive 3-level cascade
    var tileUniformBuffer: MTLBuffer?
    
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

    // Device pose smoothing removed — use raw device anchor from drawable for async timewarp
    

    // FPS tracking
    var lastPresentationTime: LayerRenderer.Clock.Instant?
    var smoothedFPS: Double = 0
    private var lastFPSUpdateTime: TimeInterval = 0
    private var lastHandTrackingUpdateTime: TimeInterval = 0  // Throttle hand UI updates
    private var cachedDeltaTime: Float = 1.0 / 90.0  // Cached for use in updateGameState

    var smoothedPosition: SIMD3<Float> = .zero
    var smoothedScale: Float = 1.0

    var mesh: MTKMesh

    let arSession: ARKitSession
    let worldTracking: WorldTrackingProvider
    var handTracking: HandTrackingProvider?
    let layerRenderer: LayerRenderer
    let appModel: AppModel

#if canImport(MetalFX)
    typealias UpscaleConfig = MetalFXManager.Configuration
#else
    typealias UpscaleConfig = Any
#endif

    #if canImport(MetalFX)
    private var metalFXManager: MetalFXManager?
    private var formatConversionPipeline: MTLRenderPipelineState?
    // Aspect ratio correction: physical_aspect / screen_aspect
    // Applied to projection matrix when rendering to physical-sized MetalFX textures
    private var metalFXAspectCorrection: Float = 1.0
    // Keep last output size so we don't recreate MetalFX textures every time the system
    // nudges the foveated viewport by a few pixels (that churn tanks perf).
    private var lastMetalFXOutputSize = SIMD2<Int>(repeating: 0)
    private var lastMetalFXConfig: MetalFXManager.Configuration?
    private var lastMetalFXViewCount: Int = 0
    #endif

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

        // Build MetalFX pipeline (no MSAA) for rendering into MetalFX input textures.
        #if canImport(MetalFX)
        do {
            // Pipeline for vertex amplification rendering to rgba16Float (uses amplification_id)
            metalFXAmplificationPipelineState = try Renderer.buildRenderPipelineWithDevice(device: device,
                                                                              layerRenderer: layerRenderer,
                                                                              rasterSampleCount: 1,
                                                                              mtlVertexDescriptor: mtlVertexDescriptor,
                                                                              colorFormat: .rgba16Float,
                                                                              vertexFunctionName: "vertexShader",
                                                                              fragmentFunctionName: "fragmentShader")
            
            // MetalFX + quad-shared pipeline
            metalFXQuadSharedPipelineState = try Renderer.buildRenderPipelineWithDevice(device: device,
                                                                              layerRenderer: layerRenderer,
                                                                              rasterSampleCount: 1,
                                                                              mtlVertexDescriptor: mtlVertexDescriptor,
                                                                              colorFormat: .rgba16Float,
                                                                              vertexFunctionName: "vertexShader",
                                                                              fragmentFunctionName: "fragmentShaderQuadShared")
            
            // Also build specialized MetalFX pipelines for quality presets
            var metalFXPipelineCount = 0
            for preset in qualityPresets {
                let iterCount = preset.fractalIterations
                let raySteps = preset.raySteps
                let key = PipelineKey(fractalIterations: iterCount, maxRaySteps: raySteps)
                let config = FunctionConstantConfig.forQualityPreset(preset)
                let constants = config.toMTLConstants()
                    
                if let pipeline = try? Renderer.buildRenderPipelineWithDevice(
                    device: device,
                    layerRenderer: layerRenderer,
                    rasterSampleCount: 1,
                    mtlVertexDescriptor: mtlVertexDescriptor,
                    colorFormat: .rgba16Float,
                    functionConstants: constants
                ) {
                    specializedMetalFXPipelines[key] = pipeline
                    metalFXPipelineCount += 1
                }
                
                if let pipeline = try? Renderer.buildRenderPipelineWithDevice(
                    device: device,
                    layerRenderer: layerRenderer,
                    rasterSampleCount: 1,
                    mtlVertexDescriptor: mtlVertexDescriptor,
                    colorFormat: .rgba16Float,
                    fragmentFunctionName: "fragmentShaderQuadShared",
                    functionConstants: constants
                ) {
                    specializedMetalFXQuadSharedPipelines[key] = pipeline
                }
            }
            print("✓ Built \(metalFXPipelineCount) specialized MetalFX pipelines")
            
            depthUpscalePipelineState = try Renderer.buildDepthUpscalePipeline(device: device, 
                                                                               layerRenderer: layerRenderer, 
                                                                               mtlVertexDescriptor: mtlVertexDescriptor)
        } catch {
            print("⚠️ Unable to compile MetalFX or Depth Upscale pipeline: \(error)")
            metalFXAmplificationPipelineState = nil
            metalFXQuadSharedPipelineState = nil
        }
        #endif

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
        do {
            var providers: [any DataProvider] = [worldTracking]
            if let ht = handTracking {
                providers.append(ht)
            }
            try await arSession.run(providers)
            print("✓ ARKit session started with world tracking and hand tracking")
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

    static func buildDepthUpscalePipeline(device: MTLDevice,
                                          layerRenderer: LayerRenderer,
                                          mtlVertexDescriptor: MTLVertexDescriptor) throws -> MTLRenderPipelineState {
        let library = device.makeDefaultLibrary()
        let vertexFunction = library?.makeFunction(name: "formatConversionVertexStereo")
        let fragmentFunction = library?.makeFunction(name: "depthUpscaleFragmentStereo")

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.label = "DepthUpscaleStereo"
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        
        pipelineDescriptor.colorAttachments[0].pixelFormat = .invalid
        pipelineDescriptor.depthAttachmentPixelFormat = layerRenderer.configuration.depthFormat
        pipelineDescriptor.maxVertexAmplificationCount = layerRenderer.properties.viewCount
        
        return try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
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
            case .low: qualityMode = 2
            case .mid: qualityMode = 1  
            case .high: qualityMode = 0
            case .ultra: qualityMode = 0
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
    func selectPipeline(forIterations iterations: Int, raySteps: Int, useQuadShared: Bool, useMetalFX: Bool) -> MTLRenderPipelineState {
        let key = PipelineKey(fractalIterations: iterations, maxRaySteps: raySteps)
        
        if useMetalFX {
            if useQuadShared {
                // Try specialized MetalFX quad-shared first
                if let specialized = specializedMetalFXQuadSharedPipelines[key] {
                    return specialized
                }
                // Fallback to general MetalFX quad-shared
                return metalFXQuadSharedPipelineState ?? pipelineState
            } else {
                // Try specialized MetalFX first
                if let specialized = specializedMetalFXPipelines[key] {
                    return specialized
                }
                // Fallback to general MetalFX
                return metalFXAmplificationPipelineState ?? pipelineState
            }
        } else {
            if useQuadShared {
                // Try specialized quad-shared first
                if let specialized = specializedQuadSharedPipelines[key] {
                    return specialized
                }
                // Fallback to general quad-shared
                return quadSharedPipelineState ?? pipelineState
            } else {
                // Try specialized standard first
                if let specialized = specializedPipelines[key] {
                    return specialized
                }
                // Fallback to general pipeline
                return pipelineState
            }
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
        
        // Throttle UI updates to 30Hz to reduce main actor contention (was every frame)
        // But track actual deltaTime since last gesture update for smooth animation
        let gestureUpdateDelta = Float(time - lastHandTrackingUpdateTime)
        guard time - lastHandTrackingUpdateTime > 0.033 else { return }
        lastHandTrackingUpdateTime = time
        
        // Update gesture controller on main actor with proper deltaTime
        Task { @MainActor in
            // Update tracking state for UI
            appModel.leftHandTracked = anchors.leftHand?.isTracked ?? false
            appModel.rightHandTracked = anchors.rightHand?.isTracked ?? false
            
            // Process gestures with deltaTime for frame-rate independent smoothing
            if #available(visionOS 2.0, *) {
                appModel.gestureController?.updateHands(
                    leftAnchor: anchors.leftHand,
                    rightAnchor: anchors.rightHand,
                    deltaTime: gestureUpdateDelta
                )
            }
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

        func uniforms(forViewIndex viewIndex: Int) -> Uniforms {
            let view = drawable.views[viewIndex]
            let viewMatrix = (deviceTransform * view.transform).inverse
            let projection = drawable.computeProjection(viewIndex: viewIndex)
            let inverseProjection = projection.inverse
            
            let modelView = viewMatrix * modelMatrix
            let inverseModelView = modelView.inverse
            let inverseView = viewMatrix.inverse
            
            // Get fovea center from the view's texture map (normalized 0-1)
            return Uniforms(projectionMatrix: projection,
                            modelViewMatrix: modelView,
                            inverseModelViewMatrix: inverseModelView,
                            inverseProjectionMatrix: inverseProjection,
                            viewMatrix: viewMatrix,
                            inverseViewMatrix: inverseView,
                            time: Float(appModel.clock.time),
                            minDistance: settings.minDistance,
                            foveaCenter: SIMD2<Float>(0.5, 0.5),
                            fractalScale: settings.fractalScale,
                            fractalIterations: Int32(settings.fractalIterations),
                            maxRaySteps: Int32(settings.maxRaySteps),
                            foveationIntensity: settings.foveationIntensity,
                            colorMix: settings.colorMix,
                            glowIntensity: settings.glowIntensity,
                            foldingLimit: settings.foldingLimit,
                            sphereRadius: settings.sphereRadius,
                            safetyBubbleRadius: settings.safetyBubbleRadius,
                            safetyBubbleEnabled: settings.safetyBubbleEnabled ? 1 : 0,
                            colorIterations: settings.colorIterations,
                            useHierarchical: settings.useHierarchical ? 1 : 0,
                            limitFlash: settings.limitFlash,
                            showHUD: settings.showHUD ? 1 : 0,
                            activeGesture: Int32(settings.activeGestureIndex))
        }

        self.uniforms[0].uniforms.0 = uniforms(forViewIndex: 0)
        if drawable.views.count > 1 {
            self.uniforms[0].uniforms.1 = uniforms(forViewIndex: 1)
        }

//        rotation += 0.01
    }

    func renderFrame() {
        /// Per frame updates hare

        guard let frame = layerRenderer.queryNextFrame() else { return }

        frame.startUpdate()

        // Perform frame independent work

        frame.endUpdate()

        guard let timing = frame.predictTiming() else { return }
        LayerRenderer.Clock().wait(until: timing.optimalInputTime)

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            fatalError("Failed to create command buffer")
        }

        guard let drawable = frame.queryDrawable() else { return }

        // Wait for a buffer to become available. With maxBuffersInFlight=2,
        // this allows CPU/GPU pipelining while preventing frame accumulation.
        // The 2-buffer setup prevents the 45fps vsync lock that occurred with 1 buffer.
        _ = inFlightSemaphore.wait(timeout: DispatchTime.distantFuture)

        frame.startSubmission()

        let presentationTime = drawable.frameTiming.presentationTime
        let time = LayerRenderer.Clock.Instant.epoch.duration(to: presentationTime).timeInterval
        let deviceAnchor = worldTracking.queryDeviceAnchor(atTimestamp: time)

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
        }
        lastPresentationTime = presentationTime

        let semaphore = inFlightSemaphore
        commandBuffer.addCompletedHandler { (_ commandBuffer)-> Swift.Void in
            semaphore.signal()
        }

        self.updateDynamicBufferState()

        #if canImport(MetalFX)
        let upscalingEnabled = configureMetalFXIfNeeded(for: drawable)
        #else
        let upscalingEnabled = false
        #endif

        // Update hand tracking and process gestures
        self.updateHandTracking(atTime: time)

        self.updateGameState(drawable: drawable)

        // Check if using adaptive 8x8 compute pipeline
        let tileSize = appModel.renderSettings.tileSize
        let useAdaptiveCompute = (tileSize == 8) && adaptiveHierarchicalPipeline8x8 != nil
        
        if useAdaptiveCompute {
            // Use compute-based rendering for 8x8 adaptive hierarchical
            let computeRendered = renderWithAdaptiveCompute(
                commandBuffer: commandBuffer,
                drawable: drawable,
                upscalingEnabled: upscalingEnabled
            )
            
            if computeRendered {
                // MetalFX upscaling if enabled
                #if canImport(MetalFX)
                if upscalingEnabled {
                    encodeMetalFXUpscale(commandBuffer: commandBuffer, drawable: drawable)
                }
                #endif
                
                drawable.encodePresent(commandBuffer: commandBuffer)
                commandBuffer.commit()
                frame.endSubmission()
                return  // Skip fragment-based rendering
            }
        }
        
        // Fall back to fragment-based rendering
        let renderPassDescriptor = MTLRenderPassDescriptor()

        #if canImport(MetalFX)
        if upscalingEnabled, let fx = metalFXManager, let inputTex = fx.inputTexture {
            // Render to MetalFX input texture (lower resolution)
            renderPassDescriptor.colorAttachments[0].texture = inputTex
            renderPassDescriptor.colorAttachments[0].loadAction = .clear
            renderPassDescriptor.colorAttachments[0].storeAction = .store
            renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0)

            renderPassDescriptor.depthAttachment.texture = fx.depthTexture
            renderPassDescriptor.depthAttachment.loadAction = .clear
            renderPassDescriptor.depthAttachment.storeAction = .store
            renderPassDescriptor.depthAttachment.clearDepth = 1.0

            renderPassDescriptor.rasterizationRateMap = nil
            renderPassDescriptor.renderTargetArrayLength = inputTex.arrayLength
        } else {
            configureDirectRenderTargets(renderPassDescriptor: renderPassDescriptor, drawable: drawable)
        }
        #else
        configureDirectRenderTargets(renderPassDescriptor: renderPassDescriptor, drawable: drawable)
        #endif

        /// Final pass rendering code here
        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            fatalError("Failed to create render encoder")
        }

        renderEncoder.label = "Primary Render Encoder"

        renderEncoder.pushDebugGroup("Draw Box")

        renderEncoder.setCullMode(.front)

        renderEncoder.setFrontFacing(.counterClockwise)

        // Select pipeline based on tile size and MetalFX settings
        // tileSize: 0 = standard per-pixel, 2 = quad-shared (2x2 SIMD), 8 = compute-based (handled above)
        let useQuadShared = (tileSize == 2)
        
        // Get current iteration count for specialized pipeline selection
        let currentIterations = appModel.renderSettings.fractalIterations
        let currentRaySteps = appModel.renderSettings.maxRaySteps
        
        // Use specialized pipeline with fixed iteration count for full loop unrolling
        // This is THE critical optimization - Map() inner loop can be fully unrolled
        #if canImport(MetalFX)
        let selectedPipeline = selectPipeline(
            forIterations: currentIterations,
            raySteps: currentRaySteps,
            useQuadShared: useQuadShared,
            useMetalFX: upscalingEnabled
        )
        renderEncoder.setRenderPipelineState(selectedPipeline)
        #else
        let selectedPipeline = selectPipeline(
            forIterations: currentIterations,
            raySteps: currentRaySteps,
            useQuadShared: useQuadShared,
            useMetalFX: false
        )
        renderEncoder.setRenderPipelineState(selectedPipeline)
        #endif

        renderEncoder.setDepthStencilState(depthState)

        renderEncoder.setVertexBuffer(dynamicUniformBuffer, offset:uniformBufferOffset, index: BufferIndex.uniforms.rawValue)
        
        // Also bind uniforms buffer for fragment shader since it now needs access to uniforms
        renderEncoder.setFragmentBuffer(dynamicUniformBuffer, offset:uniformBufferOffset, index: BufferIndex.uniforms.rawValue)

        // When rendering to MetalFX input, use full input texture as viewport.
        // MetalFX input is screen-aspect-sized (scaled down) to match projection matrix.
        // When rendering to drawable with foveation, use the virtual viewport from drawable.
        #if canImport(MetalFX)
        let viewports: [MTLViewport]
        if upscalingEnabled,
           let fx = metalFXManager,
           let inputTex = fx.inputTexture {
            // Render to full MetalFX input texture (screen-aspect, scaled down).
            // The projection matrix is based on screen aspect, so this matches correctly.
            // We fill the entire texture - it's already sized for screen aspect ratio.
            viewports = drawable.views.map { view in
                let vp = view.textureMap.viewport
                return MTLViewport(originX: 0.0,
                                   originY: 0.0,
                                   width: Double(inputTex.width),
                                   height: Double(inputTex.height),
                                   znear: vp.znear,
                                   zfar: vp.zfar)
            }
        } else {
            viewports = drawable.views.map { $0.textureMap.viewport }
        }
        #else
        let viewports = drawable.views.map { $0.textureMap.viewport }
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
        if upscalingEnabled {
            encodeMetalFXUpscale(commandBuffer: commandBuffer, drawable: drawable)
        }
        #endif

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
    
    #if canImport(MetalFX)
    private func configureMetalFXIfNeeded(for drawable: LayerRenderer.Drawable) -> Bool {
        guard metalFXAmplificationPipelineState != nil else {
            Task { @MainActor in
                appModel.metalFXAvailable = false
                appModel.metalFXStatus = "MetalFX pipeline not available"
            }
            return false
        }
        
        let hasFamilySupport = device.supportsFamily(.apple7) || device.supportsFamily(.metal3)
        if !hasFamilySupport {
            Task { @MainActor in
                appModel.metalFXAvailable = false
                appModel.metalFXStatus = "GPU family not supported"
            }
            return false
        }
        
        let metalFXScale = appModel.renderSettings.resolutionScale
        
        // If scale is 1.0, don't use MetalFX (render at full resolution directly)
        if metalFXScale >= 0.99 {
            Task { @MainActor in
                appModel.metalFXAvailable = true
                appModel.metalFXStatus = "Disabled (scale=1.0)"
            }
            return false
        }

        // MetalFX input and output sizing:
        // CRITICAL: MetalFX textures must use SCREEN aspect ratio to match projection matrix!
        // The projection matrix from drawable.computeProjection() encodes screen FOV.
        // If we render to physical aspect, the projection is wrong and causes distortion.
        //
        // Strategy:
        // - Input/Output use SCREEN aspect ratio (matches projection matrix)
        // - Rate map transforms screen coordinates to physical drawable on copy
        // - This preserves correct spatial projection for VR
        func alignTo16(_ value: Int) -> Int { max(16, (value + 15) & ~15) }

        // Get both screen and physical dimensions
        let screenViewport = drawable.views[0].textureMap.viewport
        let screenWidth = Int(screenViewport.width)
        let screenHeight = Int(screenViewport.height)
        let physicalWidth = drawable.colorTextures[0].width
        let physicalHeight = drawable.colorTextures[0].height
        
        // Calculate aspect ratios
        let screenAspect = Float(screenWidth) / Float(screenHeight)
        let physicalAspect = Float(physicalWidth) / Float(physicalHeight)
        
        // Use SCREEN dimensions for MetalFX to match projection matrix
        // Output matches screen size, rate map handles physical transformation
        let outputWidth = alignTo16(screenWidth)
        let outputHeight = alignTo16(screenHeight)
        
        // Input is scaled-down version of screen size
        let inputWidth = alignTo16(max(1, Int(round(Double(screenWidth) * Double(metalFXScale)))))
        let inputHeight = alignTo16(max(1, Int(round(Double(screenHeight) * Double(metalFXScale)))))
        
        // Store aspect correction (not used in this mode since we use rate map)
        metalFXAspectCorrection = 1.0
        
        lastMetalFXOutputSize = SIMD2(outputWidth, outputHeight)
        
        // Debug: print dimensions
        if !hasLoggedFoveationAvailability {
            print("🔍 MetalFX Config Debug (Screen-aspect for correct projection):")
            print("   Screen viewport: \(screenWidth) x \(screenHeight) (aspect \(screenAspect))")
            print("   Physical drawable: \(physicalWidth) x \(physicalHeight) (aspect \(physicalAspect))")
            print("   MetalFX input: \(inputWidth) x \(inputHeight) (\(metalFXScale)x scale)")
            print("   MetalFX output: \(outputWidth) x \(outputHeight) (screen-sized)")
            print("   Rate map handles screen→physical transformation")
            print("   Pixel reduction: render \(inputWidth * inputHeight) vs full \(physicalWidth * physicalHeight) = \(String(format: "%.1f", Float(physicalWidth * physicalHeight) / Float(inputWidth * inputHeight)))x fewer")
            hasLoggedFoveationAvailability = true
        }

        let config = MetalFXManager.Configuration(
            inputWidth: inputWidth,
            inputHeight: inputHeight,
            outputWidth: outputWidth,
            outputHeight: outputHeight,
            colorFormat: .rgba16Float,
            depthFormat: layerRenderer.configuration.depthFormat,
            scale: metalFXScale
        )

        let viewCount = drawable.views.count
        let needsUpdate = metalFXManager == nil || config != lastMetalFXConfig || viewCount != lastMetalFXViewCount

        do {
            if needsUpdate {
                if let manager = metalFXManager {
                    try manager.update(configuration: config, viewCount: viewCount)
                } else {
                    metalFXManager = try MetalFXManager(device: device, configuration: config, viewCount: viewCount)
                }
                lastMetalFXConfig = config
                lastMetalFXViewCount = viewCount
            }
            
            let available = (metalFXManager?.inputTexture != nil)
            Task { @MainActor in
                appModel.metalFXAvailable = available
                appModel.metalFXStatus = available ? "Active (scale \(metalFXScale))" : "Textures not ready"
            }
            return available
        } catch {
            print("⚠️ MetalFX configuration failed: \(error)")
            metalFXManager = nil
            Task { @MainActor in
                appModel.metalFXAvailable = false
                appModel.metalFXStatus = "Failed: \(error)"
            }
            return false
        }
    }
    #endif  // canImport(MetalFX)
    
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
            foldingLimit: settings.foldingLimit,
            glowIntensity: settings.glowIntensity,
            colorMix: settings.colorMix,
            fractalIterations: Int32(settings.fractalIterations),
            colorIterations: Int32(settings.colorIterations),
            maxRaySteps: Int32(settings.maxRaySteps),
            eyeIndex: UInt32(viewIndex),
            debugHierarchical: settings.debugHierarchical ? 1 : 0,
            limitFlash: settings.limitFlash
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
    
    /// Renders using the adaptive 8x8 compute pipeline instead of fragment shaders
    /// Returns true if compute rendering was used
    private func renderWithAdaptiveCompute(
        commandBuffer: MTLCommandBuffer,
        drawable: LayerRenderer.Drawable,
        upscalingEnabled: Bool
    ) -> Bool {
        guard adaptiveHierarchicalPipeline8x8 != nil else { return false }
        
        // Determine output texture based on whether MetalFX upscaling is active
        let outputTexture: MTLTexture
        let needsBlit: Bool
        
        #if canImport(MetalFX)
        if upscalingEnabled, let fx = metalFXManager, let inputTex = fx.inputTexture {
            // Use MetalFX input texture (already has .shaderWrite)
            outputTexture = inputTex
            needsBlit = false  // MetalFX will handle the upscale to drawable
        } else {
            // Create our own compute-writable texture and blit to drawable
            guard let computeTex = ensureComputeOutputTexture(for: drawable) else {
                return false
            }
            outputTexture = computeTex
            needsBlit = true
        }
        #else
        // Without MetalFX, use our own compute texture
        guard let computeTex = ensureComputeOutputTexture(for: drawable) else {
            return false
        }
        outputTexture = computeTex
        needsBlit = true
        #endif
        
        // Render each eye
        for viewIndex in 0..<drawable.views.count {
            encodeAdaptiveCompute(
                commandBuffer: commandBuffer,
                outputTexture: outputTexture,
                drawable: drawable,
                viewIndex: viewIndex
            )
        }
        
        // If not using MetalFX, blit our compute output to drawable
        if needsBlit {
            blitComputeOutputToDrawable(commandBuffer: commandBuffer, drawable: drawable)
        }
        
        return true
    }
    
    #if canImport(MetalFX)
    private func encodeMetalFXUpscale(commandBuffer: MTLCommandBuffer, drawable: LayerRenderer.Drawable) {
        guard let fx = metalFXManager, let output = fx.outputTexture else { return }

        do {
            try fx.encodeSpatialUpscale(commandBuffer: commandBuffer)
        } catch {
            print("⚠️ MetalFX upscale failed: \(error)")
            return
        }

        // Copy MetalFX output to drawable.
        // MetalFX output is physical-sized (matches drawable), so we can copy directly
        // without rate map transformation. Projection was adjusted to match physical aspect.

        // Copy MetalFX output to drawable using format conversion
        // MetalFX outputs rgba16Float, drawable expects BGRA8Unorm_sRGB
        let views = min(drawable.views.count, output.arrayLength)
        
        let drawableFormat = drawable.colorTextures[0].pixelFormat
        let outputFormat = output.pixelFormat
        
        // Use direct blit when formats match (physical-sized output matches physical drawable)
        if drawableFormat == outputFormat {
            // Direct blit when formats match
            guard let blit = commandBuffer.makeBlitCommandEncoder() else { return }
            
            for eye in 0..<views {
                let destinationTexture: MTLTexture
                let destinationSlice: Int
                let drawableViewport = drawable.views[eye].textureMap.viewport

                if drawable.colorTextures.count > eye {
                    // Dedicated layout
                    destinationTexture = drawable.colorTextures[eye]
                    destinationSlice = 0
                } else {
                    // Layered layout
                    destinationTexture = drawable.colorTextures[0]
                    destinationSlice = eye
                }

                let destOriginX = max(0, Int(drawableViewport.originX.rounded()))
                let destOriginY = max(0, Int(drawableViewport.originY.rounded()))
                let maxWidth = max(0, destinationTexture.width - destOriginX)
                let maxHeight = max(0, destinationTexture.height - destOriginY)
                let copyWidth = min(output.width, maxWidth)
                let copyHeight = min(output.height, maxHeight)

                if copyWidth <= 0 || copyHeight <= 0 { continue }

                blit.copy(from: output,
                          sourceSlice: eye,
                          sourceLevel: 0,
                          sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                          sourceSize: MTLSize(width: copyWidth, height: copyHeight, depth: 1),
                          to: destinationTexture,
                          destinationSlice: destinationSlice,
                          destinationLevel: 0,
                          destinationOrigin: MTLOrigin(x: destOriginX, y: destOriginY, z: 0))
            }
            blit.endEncoding()
        } else {
            // Need format conversion via render pass - use single stereo pass with vertex amplification
            // MetalFX output is screen-sized, rate map transforms to physical drawable
            let systemRateMap = drawable.rasterizationRateMaps.first
            
            if formatConversionPipeline == nil {
                createFormatConversionPipeline(destinationFormat: drawableFormat)
            }
            
            guard let pipeline = formatConversionPipeline else {
                print("⚠️ Format conversion pipeline not available")
                return
            }
            
            let renderPassDescriptor = MTLRenderPassDescriptor()
            
            // Use rate map to transform screen coordinates to physical drawable
            renderPassDescriptor.rasterizationRateMap = systemRateMap
            
            // Render to the array texture directly, not a view
            renderPassDescriptor.colorAttachments[0].texture = drawable.colorTextures[0]
            renderPassDescriptor.colorAttachments[0].loadAction = .dontCare
            renderPassDescriptor.colorAttachments[0].storeAction = .store
            renderPassDescriptor.renderTargetArrayLength = views
            
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
                print("⚠️ Failed to create render encoder for format conversion")
                return
            }
            
            // Use SCREEN-sized viewports (rate map transforms to physical)
            let viewports = drawable.views.prefix(views).map { view -> MTLViewport in
                let vp = view.textureMap.viewport
                return MTLViewport(originX: vp.originX,
                                   originY: vp.originY,
                                   width: vp.width,
                                   height: vp.height,
                                   znear: 0.0, zfar: 1.0)
            }
            encoder.setViewports(viewports)
            
            // Use vertex amplification to render both eyes
            var viewMappings = (0..<views).map {
                MTLVertexAmplificationViewMapping(viewportArrayIndexOffset: UInt32($0),
                                                  renderTargetArrayIndexOffset: UInt32($0))
            }
            encoder.setVertexAmplificationCount(views, viewMappings: &viewMappings)
            
            encoder.label = "Format Conversion Stereo"
            encoder.setRenderPipelineState(pipeline)
            // Pass the full array texture - shader samples using eye index from amplification_id
            encoder.setFragmentTexture(output, index: 0)
            
            // No aspect correction needed - MetalFX output has correct screen aspect
            var aspectCorrection: Float = 1.0
            encoder.setFragmentBytes(&aspectCorrection, length: MemoryLayout<Float>.size, index: 0)
            
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }

        copyFXDepthToDrawableDepth(fxDepth: fx.depthTexture, drawable: drawable, commandBuffer: commandBuffer)
    }
    
    func copyFXDepthToDrawableDepth(fxDepth: MTLTexture?, drawable: LayerRenderer.Drawable, commandBuffer: MTLCommandBuffer) {
        guard let src = fxDepth else { return }
        guard let pipeline = depthUpscalePipelineState else { return }

        // Depth upscale: low-res input depth → physical-sized drawable depth
        // Input depth is screen-aspect-sized (same as MetalFX input)
        // Rate map transforms screen coordinates to physical drawable
        let systemRateMap = drawable.rasterizationRateMaps.first
        let views = min(drawable.views.count, src.arrayLength)

        let desc = MTLRenderPassDescriptor()
        desc.rasterizationRateMap = systemRateMap
        desc.depthAttachment.texture = drawable.depthTextures[0]
        desc.depthAttachment.loadAction = .dontCare
        desc.depthAttachment.storeAction = .store
        desc.renderTargetArrayLength = views
        
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: desc) else { return }

        // Use SCREEN-sized viewports (rate map transforms to physical)
        let viewports = drawable.views.prefix(views).map { view -> MTLViewport in
            let vp = view.textureMap.viewport
            return MTLViewport(originX: vp.originX,
                               originY: vp.originY,
                               width: vp.width,
                               height: vp.height,
                               znear: 0.0, zfar: 1.0)
        }
        encoder.setViewports(viewports)
        
        // Use vertex amplification
        var viewMappings = (0..<views).map {
            MTLVertexAmplificationViewMapping(viewportArrayIndexOffset: UInt32($0),
                                              renderTargetArrayIndexOffset: UInt32($0))
        }
        encoder.setVertexAmplificationCount(views, viewMappings: &viewMappings)
        
        encoder.label = "Depth Upscale Stereo"
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(src, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }
    
    private func createFormatConversionPipeline(destinationFormat: MTLPixelFormat) {
        guard let library = device.makeDefaultLibrary() else {
            print("⚠️ Failed to get default library for format conversion")
            return
        }
        
        guard let vertexFunc = library.makeFunction(name: "formatConversionVertexStereo"),
              let fragmentFunc = library.makeFunction(name: "formatConversionFragmentStereo") else {
            print("⚠️ Format conversion stereo shaders not found")
            return
        }
        
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "Format Conversion Pipeline Stereo"
        descriptor.vertexFunction = vertexFunc
        descriptor.fragmentFunction = fragmentFunc
        descriptor.colorAttachments[0].pixelFormat = destinationFormat
        descriptor.maxVertexAmplificationCount = layerRenderer.properties.viewCount
        
        do {
            formatConversionPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            print("✓ Format conversion stereo pipeline created")
        } catch {
            print("⚠️ Failed to create format conversion pipeline: \(error)")
        }
    }
    #endif

    func renderLoop() {
        while true {
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


