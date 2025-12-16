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
import Spatial

// The 256 byte aligned size of our uniform structure
let alignedUniformsSize = (MemoryLayout<UniformsArray>.size + 0xFF) & -0x100

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
    var metalFXPipelineState: MTLRenderPipelineState?  // Pipeline for rgba16Float when using MetalFX
    var depthUpscalePipelineState: MTLRenderPipelineState?
    var depthState: MTLDepthStencilState
    var cubeMap: MTLTexture

    let inFlightSemaphore = DispatchSemaphore(value: maxBuffersInFlight)

    var uniformBufferOffset = 0

    var uniformBufferIndex = 0

    var uniforms: UnsafeMutablePointer<UniformsArray>

    let rasterSampleCount: Int
    var memorylessTargetIndex: Int = 0
    var memorylessTargets: [(color: MTLTexture, depth: MTLTexture)?]
    var hasLoggedFoveationAvailability = false
    var hasLoggedWorldTrackingWarning = false

    let isFoveationEnabled: Bool

    // Pose smoothing
    var smoothedDeviceTransform: matrix_float4x4 = matrix_identity_float4x4
    
    // FIX: Convert fixed alpha values to time constants (tau) for frame-rate independence.
    // Low tau (e.g., 0.012s) means faster, aggressive smoothing (for position).
    // High tau (e.g., 0.086s) means slower, gentle smoothing (for rotation).
    let posePositionTau: Double = 0.012 // Time constant for Position smoothing (~0.7 alpha at 90Hz)
    let poseRotationTau: Double = 0.086 // Time constant for Rotation smoothing (~0.12 alpha at 90Hz)

    // FPS tracking
    var lastPresentationTime: LayerRenderer.Clock.Instant?
    var smoothedFPS: Double = 0

    var smoothedPosition: SIMD3<Float> = .zero
    var smoothedScale: Float = 1.0

    var mesh: MTKMesh

    let arSession: ARKitSession
    let worldTracking: WorldTrackingProvider
    let layerRenderer: LayerRenderer
    let appModel: AppModel

    #if canImport(MetalFX)
    private var metalFXManager: MetalFXManager?
    private var formatConversionPipeline: MTLRenderPipelineState?
    #endif

    init(_ layerRenderer: LayerRenderer, appModel: AppModel) {
        self.layerRenderer = layerRenderer
        self.device = layerRenderer.device
        self.commandQueue = self.device.makeCommandQueue()!
        self.appModel = appModel
        self.isFoveationEnabled = layerRenderer.configuration.isFoveationEnabled

        let device = self.device
        if device.supports32BitMSAA && device.supportsTextureSampleCount(4) {
            rasterSampleCount = 1 // Optimized: Disable MSAA as it doesn't help with internal raymarching details
        } else {
            rasterSampleCount = 1
        }

        let uniformBufferSize = alignedUniformsSize * maxBuffersInFlight

        self.dynamicUniformBuffer = self.device.makeBuffer(length:uniformBufferSize,
                                                           options:[MTLResourceOptions.storageModeShared])!

        self.dynamicUniformBuffer.label = "UniformBuffer"

        self.memorylessTargets = .init(repeating: nil, count: maxBuffersInFlight)

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

        // Build MetalFX pipeline with rgba16Float format
        #if canImport(MetalFX)
        do {
            metalFXPipelineState = try Renderer.buildRenderPipelineWithDevice(device: device,
                                                                              layerRenderer: layerRenderer,
                                                                              rasterSampleCount: 1,
                                                                              mtlVertexDescriptor: mtlVertexDescriptor,
                                                                              colorFormat: .rgba16Float)
            
            depthUpscalePipelineState = try Renderer.buildDepthUpscalePipeline(device: device, 
                                                                               layerRenderer: layerRenderer, 
                                                                               mtlVertexDescriptor: mtlVertexDescriptor)
        } catch {
            print("⚠️ Unable to compile MetalFX or Depth Upscale pipeline: \(error)")
            metalFXPipelineState = nil
        }
        #endif

        let depthStateDescriptor = MTLDepthStencilDescriptor()
        depthStateDescriptor.depthCompareFunction = MTLCompareFunction.greater
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

        worldTracking = WorldTrackingProvider()
        arSession = ARKitSession()
    }

    private func startARSession() async {
        do {
            try await arSession.run([worldTracking])
        } catch {
            fatalError("Failed to initialize ARSession")
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
        let vertexFunction = library?.makeFunction(name: "formatConversionVertex")
        let fragmentFunction = library?.makeFunction(name: "depthUpscaleFragment")

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.label = "DepthUpscale"
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        
        pipelineDescriptor.colorAttachments[0].pixelFormat = .invalid
        pipelineDescriptor.depthAttachmentPixelFormat = layerRenderer.configuration.depthFormat
        
        return try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
    }

    static func buildRenderPipelineWithDevice(device: MTLDevice,
                                              layerRenderer: LayerRenderer,
                                              rasterSampleCount: Int,
                                              mtlVertexDescriptor: MTLVertexDescriptor,
                                              colorFormat: MTLPixelFormat? = nil) throws -> MTLRenderPipelineState {
        /// Build a render state pipeline object

        let library = device.makeDefaultLibrary()

        let vertexFunction = library?.makeFunction(name: "vertexShader")
        let fragmentFunction = library?.makeFunction(name: "fragmentShader")

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.label = "RenderPipeline"
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.vertexDescriptor = mtlVertexDescriptor
        pipelineDescriptor.rasterSampleCount = rasterSampleCount

        pipelineDescriptor.colorAttachments[0].pixelFormat = colorFormat ?? layerRenderer.configuration.colorFormat
        pipelineDescriptor.depthAttachmentPixelFormat = layerRenderer.configuration.depthFormat

        pipelineDescriptor.maxVertexAmplificationCount = layerRenderer.properties.viewCount

        return try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
    }

    static func buildMesh(device: MTLDevice,
                          mtlVertexDescriptor: MTLVertexDescriptor) throws -> MTKMesh {
        /// Create and condition mesh data to feed into a pipeline using the given vertex descriptor

        let metalAllocator = MTKMeshBufferAllocator(device: device)

//        let mdlMesh = MDLMesh.newBox(withDimensions: SIMD3<Float>(4, 4, 4),
//                                     segments: SIMD3<UInt32>(2, 2, 2),
//                                     geometryType: MDLGeometryType.triangles,
//                                     inwardNormals:false,
//                                     allocator: metalAllocator)
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

    private func memorylessRenderTargets(drawable: LayerRenderer.Drawable) -> (color: MTLTexture, depth: MTLTexture) {

        func renderTarget(resolveTexture: MTLTexture, cachedTexture: MTLTexture?) -> MTLTexture {
            if let cachedTexture,
               resolveTexture.width == cachedTexture.width && resolveTexture.height == cachedTexture.height {
                return cachedTexture
            } else {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: resolveTexture.pixelFormat,
                                                                          width: resolveTexture.width,
                                                                          height: resolveTexture.height,
                                                                          mipmapped: false)
                descriptor.usage = .renderTarget
                descriptor.textureType = .type2DMultisampleArray
                descriptor.sampleCount = rasterSampleCount
                descriptor.storageMode = .memoryless
                descriptor.arrayLength = resolveTexture.arrayLength
                return resolveTexture.device.makeTexture(descriptor: descriptor)!
            }
        }

        memorylessTargetIndex = (memorylessTargetIndex + 1) % maxBuffersInFlight

        let cachedTargets = memorylessTargets[memorylessTargetIndex]
        let newTargets = (renderTarget(resolveTexture: drawable.colorTextures[0], cachedTexture: cachedTargets?.color),
                          renderTarget(resolveTexture: drawable.depthTextures[0], cachedTexture: cachedTargets?.depth))

        memorylessTargets[memorylessTargetIndex] = newTargets

        return newTargets
    }

    private func updateGameState(drawable: LayerRenderer.Drawable, deviceAnchor: DeviceAnchor?) {
        /// Update any game state before rendering

        let settings = appModel.renderSettings
        
        // Smoothing
        let t: Float = 0.1
        smoothedPosition = smoothedPosition + (settings.position - smoothedPosition) * t
        smoothedScale = smoothedScale + (settings.scale - smoothedScale) * t
        
        let rotationMatrix = matrix4x4_rotation(radians: -.pi/2, axis: [0, 1, 0])
        let translationMatrix = matrix4x4_translation(smoothedPosition.x, smoothedPosition.y, smoothedPosition.z)
        let scaleMatrix = matrix4x4_scale(smoothedScale, smoothedScale, smoothedScale)
        
        let modelMatrix = translationMatrix * rotationMatrix * scaleMatrix
        
        let simdDeviceAnchor = smoothedDeviceTransform

        func uniforms(forViewIndex viewIndex: Int) -> Uniforms {
            let view = drawable.views[viewIndex]
            let viewMatrix = (simdDeviceAnchor * view.transform).inverse
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
                            colorIterations: settings.colorIterations)
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

        let time = LayerRenderer.Clock.Instant.epoch.duration(to: drawable.frameTiming.presentationTime).timeInterval
        let deviceAnchor = worldTracking.queryDeviceAnchor(atTimestamp: time)

        drawable.deviceAnchor = deviceAnchor

        // Calculate deltaTime for smoothing
        let deltaTime: TimeInterval
        if let last = lastPresentationTime {
            deltaTime = last.duration(to: drawable.frameTiming.presentationTime).timeInterval
        } else {
            deltaTime = 1.0 / 90.0 // Default to 90Hz
        }

        if let anchorTransform = deviceAnchor?.originFromAnchorTransform {
            smoothedDeviceTransform = smoothPose(previous: smoothedDeviceTransform,
                                                 current: anchorTransform,
                                                 deltaTime: deltaTime,
                                                 tauPosition: posePositionTau,
                                                 tauRotation: poseRotationTau)
        } else {
            smoothedDeviceTransform = matrix_identity_float4x4
        }

        // FPS tracking using predicted presentation interval
        if let last = lastPresentationTime {
            let dt = last.duration(to: drawable.frameTiming.presentationTime).timeInterval
            if dt > 0 {
                let instantFPS = 1.0 / dt
                let updatedFPS = smoothedFPS + (instantFPS - smoothedFPS) * 0.1
                smoothedFPS = updatedFPS
                Task { @MainActor in
                    appModel.fps = updatedFPS
                }
            }
        }
        lastPresentationTime = drawable.frameTiming.presentationTime

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

        self.updateGameState(drawable: drawable, deviceAnchor: deviceAnchor)

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
            renderPassDescriptor.depthAttachment.clearDepth = 0.0

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

//        renderEncoder.setCullMode(.back)
        renderEncoder.setCullMode(.front)

        renderEncoder.setFrontFacing(.counterClockwise)

        // Use MetalFX pipeline when upscaling (rgba16Float), otherwise use standard pipeline
        #if canImport(MetalFX)
        if upscalingEnabled, let fxPipeline = metalFXPipelineState {
            renderEncoder.setRenderPipelineState(fxPipeline)
        } else {
            renderEncoder.setRenderPipelineState(pipelineState)
        }
        #else
        renderEncoder.setRenderPipelineState(pipelineState)
        #endif

        renderEncoder.setDepthStencilState(depthState)

        renderEncoder.setVertexBuffer(dynamicUniformBuffer, offset:uniformBufferOffset, index: BufferIndex.uniforms.rawValue)
        
        // Also bind uniforms buffer for fragment shader since it now needs access to uniforms
        renderEncoder.setFragmentBuffer(dynamicUniformBuffer, offset:uniformBufferOffset, index: BufferIndex.uniforms.rawValue)

        // Use scaled viewports when upscaling, original viewports otherwise
        #if canImport(MetalFX)
        let viewports: [MTLViewport]
        if upscalingEnabled, let scale = metalFXManager?.configuration.scale {
            let factor = Double(scale)
            viewports = drawable.views.map { view in
                var viewport = view.textureMap.viewport
                viewport.originX *= factor
                viewport.originY *= factor
                viewport.width *= factor
                viewport.height *= factor
                return viewport
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
        if rasterSampleCount > 1 {
            let renderTargets = memorylessRenderTargets(drawable: drawable)
            renderPassDescriptor.colorAttachments[0].resolveTexture = drawable.colorTextures[0]
            renderPassDescriptor.colorAttachments[0].texture = renderTargets.color
            renderPassDescriptor.depthAttachment.resolveTexture = drawable.depthTextures[0]
            renderPassDescriptor.depthAttachment.texture = renderTargets.depth

            renderPassDescriptor.colorAttachments[0].storeAction = .multisampleResolve
            renderPassDescriptor.depthAttachment.storeAction = .multisampleResolve
        } else {
            renderPassDescriptor.colorAttachments[0].texture = drawable.colorTextures[0]
            renderPassDescriptor.depthAttachment.texture = drawable.depthTextures[0]

            renderPassDescriptor.colorAttachments[0].storeAction = .store
            renderPassDescriptor.depthAttachment.storeAction = .store
        }

        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0)
        renderPassDescriptor.depthAttachment.loadAction = .clear
        renderPassDescriptor.depthAttachment.clearDepth = 0.0
        
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
        guard metalFXPipelineState != nil else {
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

        let outputTexture = drawable.colorTextures[0]
        let outputWidth = outputTexture.width
        let outputHeight = outputTexture.height
        let inputWidth = max(1, Int(Float(outputWidth) * metalFXScale))
        let inputHeight = max(1, Int(Float(outputHeight) * metalFXScale))

        let config = MetalFXManager.Configuration(
            inputWidth: inputWidth,
            inputHeight: inputHeight,
            outputWidth: outputWidth,
            outputHeight: outputHeight,
            colorFormat: .rgba16Float,
            depthFormat: layerRenderer.configuration.depthFormat,
            scale: metalFXScale
        )

        do {
            if let manager = metalFXManager {
                try manager.update(configuration: config, viewCount: drawable.views.count)
            } else {
                metalFXManager = try MetalFXManager(device: device, configuration: config, viewCount: drawable.views.count)
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
    
    private func encodeMetalFXUpscale(commandBuffer: MTLCommandBuffer, drawable: LayerRenderer.Drawable) {
        guard let fx = metalFXManager, let output = fx.outputTexture else { return }

        do {
            try fx.encodeSpatialUpscale(commandBuffer: commandBuffer)
        } catch {
            print("⚠️ MetalFX upscale failed: \(error)")
            return
        }

        // Need format conversion: MetalFX outputs rgba16Float, drawable is BGRA8Unorm_sRGB
        let destinationTexture = drawable.colorTextures[0]
        
        // Create format conversion pipeline if needed
        if formatConversionPipeline == nil {
            createFormatConversionPipeline(destinationFormat: destinationTexture.pixelFormat)
        }
        
        guard let pipeline = formatConversionPipeline else {
            print("⚠️ Format conversion pipeline not available")
            return
        }
        
        let views = min(drawable.views.count, output.arrayLength)
        
        // Render each eye with format conversion
        for eye in 0..<views {
            guard let sourceView = output.makeTextureView(
                pixelFormat: output.pixelFormat,
                textureType: MTLTextureType.type2D,
                levels: 0..<1,
                slices: eye..<(eye + 1)
            ) else {
                print("⚠️ Failed to create source texture view for eye \(eye)")
                continue
            }
            
            // Create render pass targeting the drawable slice
            let renderPassDescriptor = MTLRenderPassDescriptor()
            
            if destinationTexture.textureType == .type2DArray {
                // For array textures, we need to render to a specific slice
                guard let destView = destinationTexture.makeTextureView(
                    pixelFormat: destinationTexture.pixelFormat,
                    textureType: MTLTextureType.type2D,
                    levels: 0..<1,
                    slices: eye..<(eye + 1)
                ) else {
                    print("⚠️ Failed to create destination texture view for eye \(eye)")
                    continue
                }
                renderPassDescriptor.colorAttachments[0].texture = destView
            } else {
                renderPassDescriptor.colorAttachments[0].texture = destinationTexture
            }
            
            renderPassDescriptor.colorAttachments[0].loadAction = .dontCare
            renderPassDescriptor.colorAttachments[0].storeAction = .store
            
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
                print("⚠️ Failed to create render encoder for format conversion (eye \(eye))")
                continue
            }
            
            encoder.label = "Format Conversion Eye \(eye)"
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentTexture(sourceView, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }

        copyFXDepthToDrawableDepth(fxDepth: fx.depthTexture, drawable: drawable, commandBuffer: commandBuffer)
    }
    
    func copyFXDepthToDrawableDepth(fxDepth: MTLTexture?, drawable: LayerRenderer.Drawable, commandBuffer: MTLCommandBuffer) {
        guard let src = fxDepth, let dst = drawable.depthTextures.first else { return }
        guard let pipeline = depthUpscalePipelineState else { return }

        let views = min(drawable.views.count, src.arrayLength)

        for eye in 0..<views {
            guard let srcView = src.makeTextureView(pixelFormat: src.pixelFormat, textureType: .type2D, levels: 0..<1, slices: eye..<(eye+1)),
                  let dstView = dst.makeTextureView(pixelFormat: dst.pixelFormat, textureType: .type2D, levels: 0..<1, slices: eye..<(eye+1)) 
            else { continue }

            let desc = MTLRenderPassDescriptor()
            desc.depthAttachment.texture = dstView
            desc.depthAttachment.loadAction = .dontCare
            desc.depthAttachment.storeAction = .store
            
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: desc) else { continue }
            
            // FIX 2: Explicitly set the viewport for the destination eye slice.
            let viewport = drawable.views[eye].textureMap.viewport
            encoder.setViewport(viewport)
            
            encoder.label = "Depth Upscale Eye \(eye)"
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentTexture(srcView, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }
    }
    
    private func createFormatConversionPipeline(destinationFormat: MTLPixelFormat) {
        guard let library = device.makeDefaultLibrary() else {
            print("⚠️ Failed to get default library for format conversion")
            return
        }
        
        guard let vertexFunc = library.makeFunction(name: "formatConversionVertex"),
              let fragmentFunc = library.makeFunction(name: "formatConversionFragment") else {
            print("⚠️ Format conversion shaders not found")
            return
        }
        
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "Format Conversion Pipeline"
        descriptor.vertexFunction = vertexFunc
        descriptor.fragmentFunction = fragmentFunc
        descriptor.colorAttachments[0].pixelFormat = destinationFormat
        
        do {
            formatConversionPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            print("✓ Format conversion pipeline created")
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

func radians_from_degrees(_ degrees: Float) -> Float {
    return (degrees / 180) * .pi
}

// Blend two poses with separate position and rotation smoothing factors
// FIX: Implementation uses the time-independent EMA formula: alpha = 1 - exp(-dt / tau)
func smoothPose(previous: matrix_float4x4, current: matrix_float4x4, deltaTime: TimeInterval, tauPosition: Double, tauRotation: Double) -> matrix_float4x4 {
    let prevPose = decomposePose(previous)
    let currPose = decomposePose(current)

    // Calculate time-independent alpha for position (using tauPosition)
    let alphaPos = 1.0 - pow(Float(M_E), -Float(deltaTime / tauPosition))
    // Calculate time-independent alpha for rotation (using tauRotation)
    let alphaRot = 1.0 - pow(Float(M_E), -Float(deltaTime / tauRotation))

    // Apply blending
    let blendedPos = prevPose.translation + (currPose.translation - prevPose.translation) * alphaPos
    let blendedRot = simd_slerp(prevPose.rotation, currPose.rotation, alphaRot)
    
    return composePose(translation: blendedPos, rotation: blendedRot)
}

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


