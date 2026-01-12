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

// Reduce buffer count to 1 to minimize latency and swimming/catch artifacts.
let maxBuffersInFlight = 1

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
    
    // Tile-based compute pipelines (4x4, 2x2, and adaptive 8x8 variants)
    var tileRaymarchPipeline4x4: MTLComputePipelineState?
    var tileRaymarchPipeline2x2: MTLComputePipelineState?
    var adaptiveHierarchicalPipeline8x8: MTLComputePipelineState?  // Adaptive 3-level cascade
    var tileUniformBuffer: MTLBuffer?
    
    // Dedicated compute output texture (has .shaderWrite flag that drawable textures lack)
    var computeOutputTexture: MTLTexture?
    var computeOutputSize: SIMD2<Int> = .zero

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
        self.commandQueue = self.device.makeCommandQueue()!
        self.appModel = appModel

        let device = self.device

        let uniformBufferSize = alignedUniformsSize * maxBuffersInFlight

        self.dynamicUniformBuffer = self.device.makeBuffer(length:uniformBufferSize,
                                                           options:[MTLResourceOptions.storageModeShared])!

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
        
        // Build tile-based compute pipelines
        do {
            let library = device.makeDefaultLibrary()!
            
            // 4x4 tile kernel (16x DE reduction)
            if let kernel4x4 = library.makeFunction(name: "tileRaymarchKernel") {
                tileRaymarchPipeline4x4 = try device.makeComputePipelineState(function: kernel4x4)
            }
            
            // 2x2 tile kernel (4x DE reduction, higher quality)
            if let kernel2x2 = library.makeFunction(name: "tileRaymarchKernel2x2") {
                tileRaymarchPipeline2x2 = try device.makeComputePipelineState(function: kernel2x2)
            }
            
            // Adaptive 8x8 hierarchical kernel (3-level cascade, 3-8x speedup)
            if let kernel8x8 = library.makeFunction(name: "adaptiveHierarchical8x8") {
                adaptiveHierarchicalPipeline8x8 = try device.makeComputePipelineState(function: kernel8x8)
                print("✓ Adaptive 8x8 hierarchical pipeline ready (3-level cascade)")
            }
            
            // Uniform buffer for tile compute (one per eye)
            let tileUniformSize = MemoryLayout<TileUniforms>.stride * 2
            tileUniformBuffer = device.makeBuffer(length: tileUniformSize, options: .storageModeShared)
            tileUniformBuffer?.label = "TileUniforms"
            
            print("✓ Tile-based compute pipelines ready (4x4, 2x2, and adaptive 8x8)")
        } catch {
            print("⚠️ Failed to create tile compute pipelines: \(error)")
            tileRaymarchPipeline4x4 = nil
            tileRaymarchPipeline2x2 = nil
            adaptiveHierarchicalPipeline8x8 = nil
        }

        worldTracking = WorldTrackingProvider()
        handTracking = HandTrackingProvider()
        arSession = ARKitSession()
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
                                              usesVertexAmplification: Bool = true) throws -> MTLRenderPipelineState {
        /// Build a render state pipeline object

        let library = device.makeDefaultLibrary()

        let vertexFunction = library?.makeFunction(name: vertexFunctionName)
        let fragmentFunction = library?.makeFunction(name: fragmentFunctionName)

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.label = "RenderPipeline"
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.vertexDescriptor = mtlVertexDescriptor
        pipelineDescriptor.rasterSampleCount = rasterSampleCount

        pipelineDescriptor.colorAttachments[0].pixelFormat = colorFormat ?? layerRenderer.configuration.colorFormat
        pipelineDescriptor.depthAttachmentPixelFormat = layerRenderer.configuration.depthFormat

        pipelineDescriptor.maxVertexAmplificationCount = usesVertexAmplification ? layerRenderer.properties.viewCount : 1

        return try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
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
        
        // Update gesture controller on main actor
        Task { @MainActor in
            // Update tracking state for UI
            appModel.leftHandTracked = anchors.leftHand?.isTracked ?? false
            appModel.rightHandTracked = anchors.rightHand?.isTracked ?? false
            
            // Process gestures
            if #available(visionOS 2.0, *) {
                appModel.gestureController?.updateHands(
                    leftAnchor: anchors.leftHand,
                    rightAnchor: anchors.rightHand
                )
            }
        }
    }

    private func updateGameState(drawable: LayerRenderer.Drawable) {
        /// Update any game state before rendering

        let settings = appModel.renderSettings
        
        // Decay the limit flash effect
        settings.updateLimitFlash(deltaTime: 1.0 / 90.0)  // Assume 90fps
        
        // Smoothing
        let t: Float = 0.1
        smoothedPosition = smoothedPosition + (settings.position - smoothedPosition) * t
        smoothedScale = smoothedScale + (settings.scale - smoothedScale) * t
        
        let rotationMatrix = matrix4x4_rotation(radians: -.pi/2, axis: [0, 1, 0])
        let translationMatrix = matrix4x4_translation(smoothedPosition.x, smoothedPosition.y, smoothedPosition.z)
        let scaleMatrix = matrix4x4_scale(smoothedScale, smoothedScale, smoothedScale)
        
        let modelMatrix = translationMatrix * rotationMatrix * scaleMatrix
        
        // Use raw device anchor transform (no smoothing) to ensure compositor-predicted pose is used
        let deviceTransform = drawable.deviceAnchor?.originFromAnchorTransform ?? matrix_identity_float4x4

        func uniforms(forViewIndex viewIndex: Int) -> Uniforms {
            let view = drawable.views[viewIndex]
            let viewMatrix = (deviceTransform * view.transform).inverse
            let projection = drawable.computeProjection(viewIndex: viewIndex)
            let inverseProjection = projection.inverse
            
            let modelView = viewMatrix * modelMatrix
            let inverseModelView = modelView.inverse
            
            // Get fovea center from the view's texture map (normalized 0-1)
            return Uniforms(projectionMatrix: projection,
                            modelViewMatrix: modelView,
                            inverseModelViewMatrix: inverseModelView,
                            inverseProjectionMatrix: inverseProjection,
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
                            colorIterations: settings.colorIterations,
                            useHierarchical: settings.useHierarchical ? 1 : 0,
                            limitFlash: settings.limitFlash,
                            sceneIndex: Int32(settings.sceneIndex),
                            ifsScale: settings.ifsScale,
                            ifsOffset: settings.ifsOffset,
                            ifsGlow: settings.ifsGlow,
                            relaxFactor: settings.relaxFactor,
                            relaxBacktrack: settings.relaxBacktrack,
                            sdfScaleCoarse: settings.sdfScaleCoarse,
                            sdfScaleSuperCoarse: settings.sdfScaleSuperCoarse,
                            earlyTermRatio: settings.earlyTermRatio,
                            earlyTermCount: Int32(settings.earlyTermCount))
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

        _ = inFlightSemaphore.wait(timeout: DispatchTime.distantFuture)

        frame.startSubmission()

        let presentationTime = drawable.frameTiming.presentationTime
        let time = LayerRenderer.Clock.Instant.epoch.duration(to: presentationTime).timeInterval
        let deviceAnchor = worldTracking.queryDeviceAnchor(atTimestamp: time)

        drawable.deviceAnchor = deviceAnchor

        // Calculate deltaTime (clamped) for FPS tracking; pose smoothing removed
        let rawDelta = lastPresentationTime.map { $0.duration(to: presentationTime).timeInterval } ?? (1.0 / 90.0)
        let deltaTime = max(1.0 / 240.0, min(1.0 / 30.0, rawDelta))

        // FPS tracking using clamped interval (stable with triple buffering)
        if deltaTime > 0 {
            let instantFPS = 1.0 / deltaTime
            let updatedFPS = smoothedFPS + (instantFPS - smoothedFPS) * 0.1
            smoothedFPS = updatedFPS
            Task { @MainActor in
                appModel.fps = updatedFPS
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
        
        // Use MetalFX amplification pipeline when upscaling (uses amplification_id, outputs rgba16Float)
        #if canImport(MetalFX)
        if upscalingEnabled {
            if useQuadShared, let quadPipeline = metalFXQuadSharedPipelineState {
                renderEncoder.setRenderPipelineState(quadPipeline)
            } else if let fxAmpPipeline = metalFXAmplificationPipelineState {
                renderEncoder.setRenderPipelineState(fxAmpPipeline)
            } else {
                renderEncoder.setRenderPipelineState(pipelineState)
            }
        } else {
            if useQuadShared, let quadPipeline = quadSharedPipelineState {
                renderEncoder.setRenderPipelineState(quadPipeline)
            } else {
                renderEncoder.setRenderPipelineState(pipelineState)
            }
        }
        #else
        if useQuadShared, let quadPipeline = quadSharedPipelineState {
            renderEncoder.setRenderPipelineState(quadPipeline)
        } else {
            renderEncoder.setRenderPipelineState(pipelineState)
        }
        #endif

        renderEncoder.setDepthStencilState(depthState)

        renderEncoder.setVertexBuffer(dynamicUniformBuffer, offset:uniformBufferOffset, index: BufferIndex.uniforms.rawValue)
        
        // Also bind uniforms buffer for fragment shader since it now needs access to uniforms
        renderEncoder.setFragmentBuffer(dynamicUniformBuffer, offset:uniformBufferOffset, index: BufferIndex.uniforms.rawValue)

        // When rendering to MetalFX input, use FULL input texture as viewport.
        // MetalFX input is now physical-sized for performance.
        // When rendering to drawable with foveation, use the virtual viewport from drawable.
        #if canImport(MetalFX)
        let viewports: [MTLViewport]
        if upscalingEnabled,
           let fx = metalFXManager,
           let inputTex = fx.inputTexture {
            // Render to full MetalFX input texture (physical-sized).
            // Note: This uses physical aspect ratio which differs slightly from screen aspect.
            // The projection matrix is based on screen aspect, so there's minor horizontal
            // compression, but this is acceptable for the performance gain.
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
        // Use PHYSICAL dimensions for performance, but adjust projection matrix
        // to match the physical aspect ratio. This gives us:
        // - Fast rendering (physical-sized textures, ~5.6x fewer pixels)
        // - No distortion (projection adjusted to match render target)
        // - No rate map overhead during copy (direct physical→physical)
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
        
        // KEY INSIGHT: The projection matrix encodes screen aspect FOV.
        // We MUST render to screen aspect ratio to avoid distortion.
        // But we can render to SMALLER resolution while keeping screen aspect.
        //
        // Strategy: Output to physical WIDTH but scaled HEIGHT to maintain screen aspect.
        // This gives us ~same pixel count as physical, but correct aspect ratio.
        // Example: 2048 × 1640 (screen aspect) instead of 2048 × 1984 (physical aspect)
        //
        // The copy pass uses rate map which handles the mapping to physical drawable.
        // Rate map affects OUTPUT coordinates, not input sampling - so normalized UVs work.
        
        let targetOutputWidth = physicalWidth
        let targetOutputHeight = Int(Float(physicalWidth) / screenAspect)  // Maintain screen aspect
        
        let outputWidth = alignTo16(targetOutputWidth)
        let outputHeight = alignTo16(targetOutputHeight)
        
        let inputWidth = alignTo16(max(1, Int(round(Double(targetOutputWidth) * Double(metalFXScale)))))
        let inputHeight = alignTo16(max(1, Int(round(Double(targetOutputHeight) * Double(metalFXScale)))))
        
        // Store the scale factor for UV adjustment in copy shader
        // Our texture is smaller than screen, so UVs need scaling
        metalFXAspectCorrection = Float(outputWidth) / Float(screenWidth)  // Reuse this for UV scale
        
        lastMetalFXOutputSize = SIMD2(outputWidth, outputHeight)
        
        // Debug: print dimensions
        if !hasLoggedFoveationAvailability {
            print("🔍 MetalFX Config Debug (Screen-aspect, Physical-scale):")
            print("   Screen viewport: \(screenWidth) x \(screenHeight) (aspect \(screenAspect))")
            print("   Physical texture: \(physicalWidth) x \(physicalHeight) (aspect \(physicalAspect))")
            print("   MetalFX input: \(inputWidth) x \(inputHeight) (aspect \(Float(inputWidth)/Float(inputHeight)))")
            print("   MetalFX output: \(outputWidth) x \(outputHeight) (aspect \(Float(outputWidth)/Float(outputHeight)))")
            print("   Resolution scale: \(metalFXScale)")
            print("   UV scale for copy: \(metalFXAspectCorrection)")
            print("   Performance: ~\(String(format: "%.1f", Float(screenWidth * screenHeight) / Float(outputWidth * outputHeight)))x fewer pixels")
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
            foldingLimit: settings.foldingLimit,
            glowIntensity: settings.glowIntensity,
            colorMix: settings.colorMix,
            fractalIterations: Int32(settings.fractalIterations),
            colorIterations: Int32(settings.colorIterations),
            maxRaySteps: Int32(settings.maxRaySteps),
            eyeIndex: UInt32(viewIndex),
            debugHierarchical: settings.debugHierarchical ? 1 : 0,
            limitFlash: settings.limitFlash,
            sceneIndex: Int32(settings.sceneIndex),
            ifsScale: settings.ifsScale,
            ifsOffset: settings.ifsOffset,
            ifsGlow: settings.ifsGlow,
            relaxFactor: settings.relaxFactor,
            relaxBacktrack: settings.relaxBacktrack,
            sdfScaleCoarse: settings.sdfScaleCoarse,
            sdfScaleSuperCoarse: settings.sdfScaleSuperCoarse,
            earlyTermRatio: settings.earlyTermRatio,
            earlyTermCount: Int32(settings.earlyTermCount)
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
            // Use rate map for OUTPUT coordinate mapping (screen→physical)
            // MetalFX output has correct screen aspect, rate map handles writing to physical drawable
            let systemRateMap = drawable.rasterizationRateMaps.first
            
            if formatConversionPipeline == nil {
                createFormatConversionPipeline(destinationFormat: drawableFormat)
            }
            
            guard let pipeline = formatConversionPipeline else {
                print("⚠️ Format conversion pipeline not available")
                return
            }
            
            let renderPassDescriptor = MTLRenderPassDescriptor()
            
            // Use rate map for output coordinate transformation
            renderPassDescriptor.rasterizationRateMap = systemRateMap
            
            // Render to the array texture directly, not a view
            renderPassDescriptor.colorAttachments[0].texture = drawable.colorTextures[0]
            renderPassDescriptor.colorAttachments[0].loadAction = .clear
            renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            renderPassDescriptor.colorAttachments[0].storeAction = .store
            renderPassDescriptor.renderTargetArrayLength = views
            
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
                print("⚠️ Failed to create render encoder for format conversion")
                return
            }
            
            // Use screen-sized viewports (rate map transforms to physical)
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
            // Normalized UVs (0-1) sample correctly regardless of texture resolution
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

        // Use rate map for output coordinate transformation (screen→physical)
        let systemRateMap = drawable.rasterizationRateMaps.first
        let views = min(drawable.views.count, src.arrayLength)

        let desc = MTLRenderPassDescriptor()
        desc.rasterizationRateMap = systemRateMap
        desc.depthAttachment.texture = drawable.depthTextures[0]
        desc.depthAttachment.loadAction = .dontCare
        desc.depthAttachment.storeAction = .store
        desc.renderTargetArrayLength = views
        
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: desc) else { return }

        // Use screen-sized viewports (rate map transforms to physical)
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


