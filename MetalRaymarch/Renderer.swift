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
    var metalFXPipelineState: MTLRenderPipelineState?  // Pipeline for per-eye rgba16Float (uses eyeIndex)
    var metalFXAmplificationPipelineState: MTLRenderPipelineState?  // Pipeline for amplification rgba16Float (uses amplification_id)
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

        // Build MetalFX pipeline (no MSAA) for rendering into MetalFX input textures.
        // Uses explicit per-eye shader variants to avoid relying on vertex amplification IDs.
        #if canImport(MetalFX)
        do {
            // Pipeline for per-eye rendering (explicit eyeIndex)
            metalFXPipelineState = try Renderer.buildRenderPipelineWithDevice(device: device,
                                                                              layerRenderer: layerRenderer,
                                                                              rasterSampleCount: 1,
                                                                              mtlVertexDescriptor: mtlVertexDescriptor,
                                                                              colorFormat: .rgba16Float,
                                                                              vertexFunctionName: "vertexShaderEyeIndex",
                                                                              fragmentFunctionName: "fragmentShaderEyeIndex",
                                                                              usesVertexAmplification: false)
            
            // Pipeline for vertex amplification rendering to rgba16Float (uses amplification_id)
            metalFXAmplificationPipelineState = try Renderer.buildRenderPipelineWithDevice(device: device,
                                                                              layerRenderer: layerRenderer,
                                                                              rasterSampleCount: 1,
                                                                              mtlVertexDescriptor: mtlVertexDescriptor,
                                                                              colorFormat: .rgba16Float,
                                                                              vertexFunctionName: "vertexShader",
                                                                              fragmentFunctionName: "fragmentShader")
            
            depthUpscalePipelineState = try Renderer.buildDepthUpscalePipeline(device: device, 
                                                                               layerRenderer: layerRenderer, 
                                                                               mtlVertexDescriptor: mtlVertexDescriptor)
        } catch {
            print("⚠️ Unable to compile MetalFX or Depth Upscale pipeline: \(error)")
            metalFXPipelineState = nil
            metalFXAmplificationPipelineState = nil
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

        worldTracking = WorldTrackingProvider()
        arSession = ARKitSession()
    }

    private func startARSession() async {
        do {
            try await arSession.run([worldTracking])
        } catch {
            if !hasLoggedWorldTrackingWarning {
                print("⚠️ World tracking unavailable: \(error)")
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

        #if canImport(MetalFX)
        // DISABLED: Per-eye MetalFX path - using vertex amplification path instead for debugging
        // This block is skipped to test if the issue is in per-eye rendering vs vertex amplification
        if false,  // DISABLED FOR TESTING
           upscalingEnabled,
           let fx = metalFXManager,
           let inputTex = fx.inputTexture,
           let depthTex = fx.depthTexture,
           let fxPipeline = metalFXPipelineState {

            let views = min(drawable.views.count, inputTex.arrayLength)
            
            // Debug: Log dimensions once
            if !hasLoggedFoveationAvailability {
                let vp = drawable.views[0].textureMap.viewport
                let drawTex = drawable.colorTextures[0]
                print("🔍 MetalFX Debug:")
                print("   Drawable texture: \(drawTex.width)x\(drawTex.height)")
                print("   Viewport: origin=(\(vp.originX),\(vp.originY)) size=\(vp.width)x\(vp.height)")
                print("   Input texture: \(inputTex.width)x\(inputTex.height)")
                print("   Output texture: \(fx.outputTexture?.width ?? 0)x\(fx.outputTexture?.height ?? 0)")
                hasLoggedFoveationAvailability = true
            }

            for eye in 0..<views {
                guard let colorView = inputTex.makeTextureView(
                    pixelFormat: inputTex.pixelFormat,
                    textureType: .type2D,
                    levels: 0..<1,
                    slices: eye..<(eye + 1)
                ), let depthView = depthTex.makeTextureView(
                    pixelFormat: depthTex.pixelFormat,
                    textureType: .type2D,
                    levels: 0..<1,
                    slices: eye..<(eye + 1)
                ) else {
                    continue
                }

                let pass = MTLRenderPassDescriptor()
                pass.colorAttachments[0].texture = colorView
                pass.colorAttachments[0].loadAction = .clear
                pass.colorAttachments[0].storeAction = .store
                pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0)

                pass.depthAttachment.texture = depthView
                pass.depthAttachment.loadAction = .clear
                pass.depthAttachment.storeAction = .store
                pass.depthAttachment.clearDepth = 1.0

                pass.rasterizationRateMap = nil
                pass.renderTargetArrayLength = 1

                guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
                    continue
                }

                renderEncoder.label = "MetalFX Eye \(eye) Render Encoder"
                renderEncoder.pushDebugGroup("Draw Box")
                renderEncoder.setCullMode(.front)
                renderEncoder.setFrontFacing(.counterClockwise)
                renderEncoder.setRenderPipelineState(fxPipeline)
                renderEncoder.setDepthStencilState(depthState)

                renderEncoder.setVertexBuffer(dynamicUniformBuffer, offset: uniformBufferOffset, index: BufferIndex.uniforms.rawValue)
                renderEncoder.setFragmentBuffer(dynamicUniformBuffer, offset: uniformBufferOffset, index: BufferIndex.uniforms.rawValue)

                var eyeIndex = UInt32(eye)
                renderEncoder.setVertexBytes(&eyeIndex, length: MemoryLayout<UInt32>.size, index: BufferIndex.eyeIndex.rawValue)
                renderEncoder.setFragmentBytes(&eyeIndex, length: MemoryLayout<UInt32>.size, index: BufferIndex.eyeIndex.rawValue)

                // Use exact texture dimensions to avoid floating-point discrepancies between
                // viewport size and texture size. The projection matrix is resolution-independent.
                let originalViewport = drawable.views[eye].textureMap.viewport
                let viewport = MTLViewport(
                    originX: 0,
                    originY: 0,
                    width: Double(inputTex.width),
                    height: Double(inputTex.height),
                    znear: originalViewport.znear,
                    zfar: originalViewport.zfar
                )
                renderEncoder.setViewport(viewport)

                for (index, element) in mesh.vertexDescriptor.layouts.enumerated() {
                    guard let layout = element as? MDLVertexBufferLayout else {
                        renderEncoder.endEncoding()
                        return
                    }

                    if layout.stride != 0 {
                        let buffer = mesh.vertexBuffers[index]
                        renderEncoder.setVertexBuffer(buffer.buffer, offset: buffer.offset, index: index)
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
            }

            encodeMetalFXUpscale(commandBuffer: commandBuffer, drawable: drawable)
            drawable.encodePresent(commandBuffer: commandBuffer)
            commandBuffer.commit()
            frame.endSubmission()
            return
        }
        #endif

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

//        renderEncoder.setCullMode(.back)
        renderEncoder.setCullMode(.front)

        renderEncoder.setFrontFacing(.counterClockwise)

        // Use MetalFX amplification pipeline when upscaling (uses amplification_id, outputs rgba16Float)
        #if canImport(MetalFX)
        if upscalingEnabled, let fxAmpPipeline = metalFXAmplificationPipelineState {
            renderEncoder.setRenderPipelineState(fxAmpPipeline)
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

        // When rendering to MetalFX input, use physical texture dimensions as viewport
        // When rendering to drawable with foveation, use the virtual viewport from drawable
        #if canImport(MetalFX)
        let viewports: [MTLViewport]
        if upscalingEnabled, let inputTex = metalFXManager?.inputTexture {
            // Render to physical texture dimensions (no foveation)
            let viewport = MTLViewport(
                originX: 0,
                originY: 0,
                width: Double(inputTex.width),
                height: Double(inputTex.height),
                znear: 0.0,
                zfar: 1.0
            )
            viewports = Array(repeating: viewport, count: drawable.views.count)
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

        // MetalFX input and output sizing:
        // - Output: Must match physical drawable texture for the copy to work
        // - Input: Scaled version of output, maintaining the same aspect ratio
        //
        // The projection matrix from drawable.computeProjection() is based on tangent values
        // which define angular FOV, making it resolution-independent. As long as we maintain
        // the correct aspect ratio, the projection works correctly.
        //
        // Note: The logical viewport (view.textureMap.viewport) may differ from physical texture
        // due to foveation, but both should have the same aspect ratio.
        let drawableTexture = drawable.colorTextures[0]
        let logicalViewport = drawable.views[0].textureMap.viewport
        
        // Use the logical viewport size (the region the system actually samples) to size MetalFX,
        // but stabilize it so tiny gaze-driven viewport jitters don't force us to recreate
        // MetalFX textures/scalers every frame (that was the perf cliff when Spatial was enabled).
        func alignTo16(_ value: Int) -> Int { max(16, (value + 15) & ~15) }
        func stabilized(_ value: Int, previous: Int, tolerance: Int = 24) -> Int {
            guard previous > 0 else { return value }
            return abs(value - previous) <= tolerance ? previous : value
        }

        let physicalWidth = drawable.colorTextures[0].width
        let physicalHeight = drawable.colorTextures[0].height

        var viewportWidth = max(1, Int(round(logicalViewport.width)))
        var viewportHeight = max(1, Int(round(logicalViewport.height)))

        viewportWidth = min(viewportWidth, physicalWidth)
        viewportHeight = min(viewportHeight, physicalHeight)

        viewportWidth = stabilized(viewportWidth, previous: lastMetalFXOutputSize.x)
        viewportHeight = stabilized(viewportHeight, previous: lastMetalFXOutputSize.y)

        let outputWidth = alignTo16(viewportWidth)
        let outputHeight = alignTo16(viewportHeight)
        lastMetalFXOutputSize = SIMD2(outputWidth, outputHeight)

        let inputWidth = alignTo16(max(1, Int(round(Double(outputWidth) * Double(metalFXScale)))))
        let inputHeight = alignTo16(max(1, Int(round(Double(outputHeight) * Double(metalFXScale)))))
        
        // Debug: print dimensions and check aspect ratio
        if !hasLoggedFoveationAvailability {
            let physicalAspect = Float(drawableTexture.width) / Float(drawableTexture.height)
            let logicalAspect = Float(logicalViewport.width) / Float(logicalViewport.height)
            let aspectDiff = abs(physicalAspect - logicalAspect)
            
            print("🔍 MetalFX Config Debug:")
            print("   Physical texture: \(physicalWidth) x \(physicalHeight) (aspect=\(physicalAspect))")
            print("   Logical viewport: \(Int(logicalViewport.width)) x \(Int(logicalViewport.height)) origin=(\(Int(logicalViewport.originX)), \(Int(logicalViewport.originY))) (aspect=\(logicalAspect))")
            print("   MetalFX input: \(inputWidth) x \(inputHeight)")
            print("   MetalFX output: \(outputWidth) x \(outputHeight)")
            print("   Resolution scale: \(metalFXScale)")
            
            if aspectDiff > 0.01 {
                print("   ⚠️ ASPECT RATIO MISMATCH: physical vs logical differ by \(aspectDiff)!")
                print("   This may cause zoom/warp issues with projection.")
            } else {
                print("   ✓ Aspect ratios match")
            }
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
    
    private func encodeMetalFXUpscale(commandBuffer: MTLCommandBuffer, drawable: LayerRenderer.Drawable) {
        guard let fx = metalFXManager, let output = fx.outputTexture else { return }

        do {
            try fx.encodeSpatialUpscale(commandBuffer: commandBuffer)
        } catch {
            print("⚠️ MetalFX upscale failed: \(error)")
            return
        }

        // DEBUG: Log dimension comparison once
        if !hasLoggedFoveationAvailability {
            print("🔍 MetalFX Copy Debug:")
            print("   MetalFX output: \(output.width) x \(output.height) (arrayLength=\(output.arrayLength))")
            if let first = drawable.colorTextures.first {
                print("   Drawable[0]: \(first.width) x \(first.height) (type=\(first.textureType.rawValue))")
            }
            for (i, view) in drawable.views.enumerated() {
                let vp = view.textureMap.viewport
                print("   View[\(i)] viewport: origin=(\(vp.originX), \(vp.originY)) size=\(vp.width) x \(vp.height)")
            }
        }

        // Copy MetalFX output to drawable using format conversion
        // MetalFX outputs rgba16Float, drawable expects BGRA8Unorm_sRGB
        let views = min(drawable.views.count, output.arrayLength)
        
        // Check if formats match - if so, we can use blit
        let drawableFormat = drawable.colorTextures[0].pixelFormat
        let outputFormat = output.pixelFormat
        
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
            // Need format conversion via render pass
            if formatConversionPipeline == nil {
                createFormatConversionPipeline(destinationFormat: drawableFormat)
            }
            
            guard let pipeline = formatConversionPipeline else {
                print("⚠️ Format conversion pipeline not available")
                return
            }
            
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
                
                let renderPassDescriptor = MTLRenderPassDescriptor()
                
                // Handle both dedicated and layered layouts
                let destinationTexture: MTLTexture
                if drawable.colorTextures.count > eye {
                    destinationTexture = drawable.colorTextures[eye]
                } else {
                    destinationTexture = drawable.colorTextures[0]
                }
                
                if destinationTexture.textureType == .type2DArray {
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

                let viewport = drawable.views[eye].textureMap.viewport
                let originX = viewport.originX
                let originY = viewport.originY
                let target = renderPassDescriptor.colorAttachments[0].texture
                let width = min(Double(output.width), Double(target?.width ?? 0) - originX)
                let height = min(Double(output.height), Double(target?.height ?? 0) - originY)
                if width <= 0 || height <= 0 {
                    encoder.endEncoding()
                    continue
                }
                encoder.setViewport(MTLViewport(originX: originX,
                                                originY: originY,
                                                width: width,
                                                height: height,
                                                znear: 0.0, zfar: 1.0))
                
                encoder.label = "Format Conversion Eye \(eye)"
                encoder.setRenderPipelineState(pipeline)
                encoder.setFragmentTexture(sourceView, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                encoder.endEncoding()
            }
        }

        copyFXDepthToDrawableDepth(fxDepth: fx.depthTexture, drawable: drawable, commandBuffer: commandBuffer)
    }
    
    func copyFXDepthToDrawableDepth(fxDepth: MTLTexture?, drawable: LayerRenderer.Drawable, commandBuffer: MTLCommandBuffer) {
        guard let src = fxDepth else { return }
        guard let pipeline = depthUpscalePipelineState else { return }

        let views = min(drawable.views.count, src.arrayLength)

        for eye in 0..<views {
            guard let srcView = src.makeTextureView(pixelFormat: src.pixelFormat, textureType: .type2D, levels: 0..<1, slices: eye..<(eye+1))
            else { continue }
            
            // Handle both dedicated and layered layouts
            let destinationDepth: MTLTexture
            if drawable.depthTextures.count > eye {
                destinationDepth = drawable.depthTextures[eye]
            } else if let first = drawable.depthTextures.first {
                destinationDepth = first
            } else {
                continue
            }

            let desc = MTLRenderPassDescriptor()
            
            if destinationDepth.textureType == .type2DArray {
                guard let dstView = destinationDepth.makeTextureView(pixelFormat: destinationDepth.pixelFormat, textureType: .type2D, levels: 0..<1, slices: eye..<(eye+1))
                else { continue }
                desc.depthAttachment.texture = dstView
            } else {
                desc.depthAttachment.texture = destinationDepth
            }
            
            desc.depthAttachment.loadAction = .dontCare
            desc.depthAttachment.storeAction = .store
            
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: desc) else { continue }

            if let target = desc.depthAttachment.texture {
                let viewport = drawable.views[eye].textureMap.viewport
                let width = min(viewport.width, Double(target.width) - viewport.originX)
                let height = min(viewport.height, Double(target.height) - viewport.originY)
                if width <= 0 || height <= 0 {
                    encoder.endEncoding()
                    continue
                }
                encoder.setViewport(MTLViewport(originX: viewport.originX,
                                               originY: viewport.originY,
                                               width: width,
                                               height: height,
                                               znear: 0.0, zfar: 1.0))
            }
            
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


