#if os(macOS)
import AppKit
import Metal
@preconcurrency import MetalKit
import ModelIO
import QuartzCore
import SwiftUI
import simd

struct ThresholdMacRenderView: NSViewRepresentable {
    let appModel: AppModel

    func makeCoordinator() -> Coordinator {
        Coordinator(appModel: appModel)
    }

    func makeNSView(context: Context) -> MTKView {
        let device = MTLCreateSystemDefaultDevice()
        let view = MTKView(frame: .zero, device: device)
        view.colorPixelFormat = .bgra8Unorm_srgb
        view.depthStencilPixelFormat = .depth32Float
        view.clearColor = MTLClearColor(red: 0.005, green: 0.006, blue: 0.008, alpha: 1.0)
        view.clearDepth = 1.0
        view.preferredFramesPerSecond = 60
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.framebufferOnly = true
        view.autoResizeDrawable = true
        view.delegate = context.coordinator
        context.coordinator.configure(view)
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        context.coordinator.appModel = appModel
    }

    static func dismantleNSView(_ nsView: MTKView, coordinator: Coordinator) {
        nsView.delegate = nil
        coordinator.tearDown()
    }

    @MainActor
    final class Coordinator: NSObject, MTKViewDelegate {
        var appModel: AppModel
        private var renderer: ThresholdMacRenderer?

        init(appModel: AppModel) {
            self.appModel = appModel
            super.init()
        }

        func configure(_ view: MTKView) {
            guard let device = view.device else { return }
            renderer = ThresholdMacRenderer(device: device, colorPixelFormat: view.colorPixelFormat, depthPixelFormat: view.depthStencilPixelFormat)
        }

        func tearDown() {
            renderer = nil
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            renderer?.drawableSizeDidChange(size)
        }

        func draw(in view: MTKView) {
            renderer?.draw(in: view, appModel: appModel)
        }
    }
}

@MainActor
private final class ThresholdMacRenderer {
    private enum SetupError: Error {
        case badVertexDescriptor
        case metalLibraryUnavailable
    }

    private struct CachedMeshBinding {
        let bufferIndex: Int
        let buffer: MTLBuffer
        let offset: Int
    }

    private static let alignedUniformsSize = (MemoryLayout<UniformsArray>.size + 0xFF) & -0x100
    private static let maxBuffersInFlight = 2

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let mesh: MTKMesh
    private let meshBindings: [CachedMeshBinding]
    private let uniformBuffers: [MTLBuffer]
    private let inFlightSemaphore = DispatchSemaphore(value: maxBuffersInFlight)
    private let baseRotationMatrix = matrix4x4_rotation(radians: -.pi / 2, axis: [0, 1, 0])
    private let startTime = CACurrentMediaTime()

    private var uniformBufferIndex = 0
    private var lastFrameTime = CACurrentMediaTime()
    private var smoothedFPS: Double = 0
    private var smoothedScale: Float = 1.0
    private var smoothedMaxViewDistance: Float = RenderSettings.maxViewDistance
    private var drawableSize: CGSize = .zero

    init?(device: MTLDevice, colorPixelFormat: MTLPixelFormat, depthPixelFormat: MTLPixelFormat) {
        self.device = device

        guard let commandQueue = device.makeCommandQueue() else { return nil }
        self.commandQueue = commandQueue

        let builtPipeline: MTLRenderPipelineState
        let builtMesh: MTKMesh
        do {
            let vertexDescriptor = Self.buildMetalVertexDescriptor()
            builtPipeline = try Self.buildRenderPipeline(device: device, colorPixelFormat: colorPixelFormat, depthPixelFormat: depthPixelFormat, vertexDescriptor: vertexDescriptor)
            builtMesh = try Self.buildMesh(device: device, vertexDescriptor: vertexDescriptor)
        } catch {
            print("ThresholdMac renderer setup failed: \(error)")
            return nil
        }
        pipelineState = builtPipeline
        mesh = builtMesh

        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .less
        depthDescriptor.isDepthWriteEnabled = true
        guard let depthState = device.makeDepthStencilState(descriptor: depthDescriptor) else { return nil }
        self.depthState = depthState

        var buffers: [MTLBuffer] = []
        for index in 0..<Self.maxBuffersInFlight {
            guard let buffer = device.makeBuffer(length: Self.alignedUniformsSize, options: .storageModeShared) else { return nil }
            buffer.label = "ThresholdMac Uniforms \(index)"
            buffers.append(buffer)
        }
        uniformBuffers = buffers

        meshBindings = builtMesh.vertexDescriptor.layouts.enumerated().compactMap { index, layout in
            guard let layout = layout as? MDLVertexBufferLayout, layout.stride != 0 else { return nil }
            let vertexBuffer = builtMesh.vertexBuffers[index]
            return CachedMeshBinding(bufferIndex: index, buffer: vertexBuffer.buffer, offset: vertexBuffer.offset)
        }
    }

    func drawableSizeDidChange(_ size: CGSize) {
        drawableSize = size
    }

    func draw(in view: MTKView, appModel: AppModel) {
        guard appModel.isAppActive,
              drawableSize.width > 1,
              drawableSize.height > 1,
              let drawable = view.currentDrawable,
              let renderPassDescriptor = view.currentRenderPassDescriptor else {
            return
        }

        guard inFlightSemaphore.wait(timeout: .now()) == .success else { return }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            inFlightSemaphore.signal()
            return
        }

        commandBuffer.addCompletedHandler { [inFlightSemaphore] _ in
            inFlightSemaphore.signal()
        }

        let uniformBuffer = uniformBuffers[uniformBufferIndex]
        uniformBufferIndex = (uniformBufferIndex + 1) % uniformBuffers.count
        writeUniforms(to: uniformBuffer, appModel: appModel)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            commandBuffer.commit()
            return
        }

        encoder.setRenderPipelineState(pipelineState)
        encoder.setDepthStencilState(depthState)
        for binding in meshBindings {
            encoder.setVertexBuffer(binding.buffer, offset: binding.offset, index: binding.bufferIndex)
        }
        encoder.setVertexBuffer(uniformBuffer, offset: 0, index: BufferIndex.uniforms.rawValue)
        encoder.setFragmentBuffer(uniformBuffer, offset: 0, index: BufferIndex.uniforms.rawValue)

        for submesh in mesh.submeshes {
            encoder.drawIndexedPrimitives(type: submesh.primitiveType,
                                          indexCount: submesh.indexCount,
                                          indexType: submesh.indexType,
                                          indexBuffer: submesh.indexBuffer.buffer,
                                          indexBufferOffset: submesh.indexBuffer.offset)
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func writeUniforms(to buffer: MTLBuffer, appModel: AppModel) {
        let now = CACurrentMediaTime()
        let deltaTime = max(1.0 / 240.0, min(now - lastFrameTime, 1.0 / 15.0))
        lastFrameTime = now

        let settings = appModel.renderSettings
        settings.interpolateToTargets(deltaTime: Float(deltaTime))
        settings.updateLimitFlash(deltaTime: Float(deltaTime))
        settings.updateColorSchemeTransition(deltaTime: Float(deltaTime))

        if settings.isAnimationPlaying {
            appModel.animationManager?.update(deltaTime: deltaTime)
        }

        if settings.lightingMode == .audioReactive || settings.lightingMode == .visualizer || settings.fractalAudioReactiveEnabled {
            appModel.appleMusicManager.updateFrame()
        }

        updateFPS(deltaTime: deltaTime, appModel: appModel)

        let snapshot = settings.snapshot()
        let uniforms = makeUniforms(settings: snapshot, elapsedTime: Float(now - startTime), deltaTime: Float(deltaTime))
        let pointer = buffer.contents().bindMemory(to: UniformsArray.self, capacity: 1)
        pointer.pointee.uniforms.0 = uniforms
        pointer.pointee.uniforms.1 = uniforms
    }

    private func updateFPS(deltaTime: TimeInterval, appModel: AppModel) {
        guard deltaTime > 0 else { return }
        let instantFPS = 1.0 / deltaTime
        let smoothFactor = 1.0 - exp(-10.0 * deltaTime)
        smoothedFPS += (instantFPS - smoothedFPS) * smoothFactor
        appModel.renderMetrics.fps = smoothedFPS
    }

    private func makeUniforms(settings: RenderSettingsSnapshot, elapsedTime: Float, deltaTime: Float) -> Uniforms {
        let smoothFactor = 1.0 - exp(-15.0 * deltaTime)
        smoothedScale += (settings.scale - smoothedScale) * smoothFactor

        let userRotationMatrix = matrix4x4_from_quaternion(settings.worldRotation)
        let combinedRotationMatrix = userRotationMatrix * baseRotationMatrix
        let effectiveScale = smoothedScale * settings.detailScale
        let translationMatrix = matrix4x4_translation(settings.position.x, settings.position.y, settings.position.z)
        let scaleMatrix = matrix4x4_scale(effectiveScale, effectiveScale, effectiveScale)
        let modelMatrix = translationMatrix * combinedRotationMatrix * scaleMatrix

        let isKleinianFamily = settings.fractalType == .kleinian || settings.fractalType == .theliPseudoKleinian
        let traceScaleFloor: Float = isKleinianFamily ? 0.02 : 0.15
        let traceScale = max(effectiveScale, traceScaleFloor)
        let maxViewDistanceCap: Float = isKleinianFamily ? 420.0 : 80.0
        let baseViewDistance: Float = isKleinianFamily ? RenderSettings.maxViewDistance * 2.0 : RenderSettings.maxViewDistance
        let targetMaxViewDistance = min(maxViewDistanceCap, baseViewDistance / traceScale)
        let maxViewDistanceSpeed: Float = targetMaxViewDistance > smoothedMaxViewDistance ? 30.0 : 10.0
        let maxViewDistanceBlend = 1.0 - exp(-maxViewDistanceSpeed * deltaTime)
        smoothedMaxViewDistance += (targetMaxViewDistance - smoothedMaxViewDistance) * maxViewDistanceBlend
        let maxViewDistance = max(4.0, min(maxViewDistanceCap, smoothedMaxViewDistance))

        let aspect = Float(max(drawableSize.width, 1) / max(drawableSize.height, 1))
        let projection = Self.makePerspectiveProjection(fovyRadians: Float.pi / 3, aspect: aspect, nearZ: 0.01, farZ: 500.0)
        let viewMatrix = matrix4x4_translation(0, 0, -3.0)
        let modelView = viewMatrix * modelMatrix
        let inverseModelView = modelView.inverse

        let precomputedFractal = Self.makePrecomputedFractal(from: settings)
        let precomputedLighting = Self.makePrecomputedLighting(time: elapsedTime,
                                                               lightingMode: settings.lightingMode,
                                                               audioLevel: settings.audioLevel,
                                                               bassLevel: settings.bassLevel,
                                                               midLevel: settings.midLevel,
                                                               trebleLevel: settings.trebleLevel,
                                                               beatIntensity: settings.beatIntensity)
        let precomputedAudio = Self.makePrecomputedAudio(from: settings)
        var precomputedFog = Self.makePrecomputedFog(from: settings)
        if isKleinianFamily {
            let baseFog = precomputedFog.fog.x
            if baseFog > 1e-6 {
                let fogScale = min(1.0, max(0.08, traceScale / 0.15))
                let fogIntensity = baseFog * fogScale
                let inverseFog = fogIntensity > 1e-6 ? 1.0 / fogIntensity : 0.0
                precomputedFog = PrecomputedFog(fog: SIMD4<Float>(fogIntensity, inverseFog, 0.0, 0.0), color: precomputedFog.color)
            }
        }

        let lightingWave = sin(elapsedTime * 1.2)
        let animatedColorMix = settings.lightingPlay ? min(max(settings.colorMix + lightingWave * 0.08, 0.0), 1.0) : settings.colorMix
        let baseGlow = settings.colorSchemeParams.glowIntensity
        let animatedGlow = settings.lightingPlay ? min(max(baseGlow + max(0, lightingWave) * 0.25, 0.0), 2.0) : baseGlow
        let scaleCorrectedBubbleRadius = settings.safetyBubbleRadius / max(effectiveScale, 0.001)
        let scaleCorrectedFadeWidth = settings.safetyBubbleFadeWidth / max(effectiveScale, 0.001)

        return Uniforms(projectionMatrix: projection,
                        modelViewMatrix: modelView,
                        inverseModelViewMatrix: inverseModelView,
                        time: elapsedTime,
                        minDistance: settings.minDistance,
                        fractalScale: settings.fractalScale,
                        fractalIterations: Int32(settings.fractalIterations),
                        maxRaySteps: Int32(settings.maxRaySteps),
                        maxViewDistance: maxViewDistance,
                        colorMix: animatedColorMix,
                        glowIntensity: animatedGlow,
                        foldingLimit: settings.foldingLimit,
                        sphereRadius: settings.sphereRadius,
                        safetyBubbleRadius: scaleCorrectedBubbleRadius,
                        safetyBubbleEnabled: settings.fractalType == .mandelbulb ? 0 : (settings.safetyBubbleEnabled ? 1 : 0),
                        safetyBubbleShape: settings.safetyBubbleShape,
                        safetyBubbleFadeEnabled: settings.safetyBubbleFadeEnabled ? 1 : 0,
                        safetyBubbleFadeWidth: scaleCorrectedFadeWidth,
                        safetyBubbleStrength: settings.fractalType == .mandelbulb ? 0.0 : settings.safetyBubbleStrength,
                        colorIterations: settings.colorIterations,
                        limitFlash: settings.limitFlash,
                        activeGesture: Int32(settings.activeGestureIndex),
                        fractalType: settings.fractalType.rawValue,
                        lightingSoftness: settings.lightingSoftness,
                        sphericalInversionMode: settings.sphericalInversionMode.rawValue,
                        sphericalInversionRadius: settings.sphericalInversionRadius,
                        stepMultiplier: settings.stepMultiplier,
                        boundingSphereRadius: settings.estimatedBoundingSphereRadius,
                        springDisplacementX: settings.springDisplacement.x,
                        springDisplacementY: settings.springDisplacement.y,
                        springDisplacementZ: settings.springDisplacement.z,
                        springStretch: simd_length(settings.springDisplacement),
                        springAnchorNDC: SIMD2<Float>(0.7, -0.7),
                        springVisible: (settings.springActive || simd_length(settings.springDisplacement) > 0.001) ? 1 : 0,
                        springRestRadius: 0.06,
                        jitterOffset: .zero,
                        _pad_uniforms: [0, 0],
                        formulaParams: settings.formulaParams,
                        precomputedFractal: precomputedFractal,
                        precomputedLighting: precomputedLighting,
                        precomputedAudio: precomputedAudio,
                        precomputedFog: precomputedFog,
                        colorScheme: settings.colorSchemeParams)
    }

    private static func buildRenderPipeline(device: MTLDevice,
                                            colorPixelFormat: MTLPixelFormat,
                                            depthPixelFormat: MTLPixelFormat,
                                            vertexDescriptor: MTLVertexDescriptor) throws -> MTLRenderPipelineState {
        guard let library = device.makeDefaultLibrary(),
              let vertexFunction = library.makeFunction(name: "screenshotVertexShader") else {
                        throw SetupError.metalLibraryUnavailable
        }

        let constants = MTLFunctionConstantValues()
        let fragmentFunction = try library.makeFunction(name: "fragmentShaderMono", constantValues: constants)

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "ThresholdMac Raymarch Pipeline"
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.vertexDescriptor = vertexDescriptor
        descriptor.rasterSampleCount = 1
        descriptor.colorAttachments[0].pixelFormat = colorPixelFormat
        descriptor.depthAttachmentPixelFormat = depthPixelFormat

        return try device.makeRenderPipelineState(descriptor: descriptor)
    }

    private static func buildMetalVertexDescriptor() -> MTLVertexDescriptor {
        let descriptor = MTLVertexDescriptor()

        descriptor.attributes[VertexAttribute.position.rawValue].format = .float3
        descriptor.attributes[VertexAttribute.position.rawValue].offset = 0
        descriptor.attributes[VertexAttribute.position.rawValue].bufferIndex = BufferIndex.meshPositions.rawValue

        descriptor.attributes[VertexAttribute.texcoord.rawValue].format = .float2
        descriptor.attributes[VertexAttribute.texcoord.rawValue].offset = 0
        descriptor.attributes[VertexAttribute.texcoord.rawValue].bufferIndex = BufferIndex.meshGenerics.rawValue

        descriptor.layouts[BufferIndex.meshPositions.rawValue].stride = 12
        descriptor.layouts[BufferIndex.meshPositions.rawValue].stepRate = 1
        descriptor.layouts[BufferIndex.meshPositions.rawValue].stepFunction = .perVertex

        descriptor.layouts[BufferIndex.meshGenerics.rawValue].stride = 8
        descriptor.layouts[BufferIndex.meshGenerics.rawValue].stepRate = 1
        descriptor.layouts[BufferIndex.meshGenerics.rawValue].stepFunction = .perVertex

        return descriptor
    }

    private static func buildMesh(device: MTLDevice, vertexDescriptor: MTLVertexDescriptor) throws -> MTKMesh {
        let allocator = MTKMeshBufferAllocator(device: device)
        let mesh = MDLMesh.newEllipsoid(withRadii: SIMD3<Float>(repeating: 100),
                                        radialSegments: 64,
                                        verticalSegments: 32,
                                        geometryType: .triangles,
                                        inwardNormals: false,
                                        hemisphere: false,
                                        allocator: allocator)

        let modelIODescriptor = MTKModelIOVertexDescriptorFromMetal(vertexDescriptor)
        guard let attributes = modelIODescriptor.attributes as? [MDLVertexAttribute] else {
            throw SetupError.badVertexDescriptor
        }
        attributes[VertexAttribute.position.rawValue].name = MDLVertexAttributePosition
        attributes[VertexAttribute.texcoord.rawValue].name = MDLVertexAttributeTextureCoordinate
        mesh.vertexDescriptor = modelIODescriptor

        return try MTKMesh(mesh: mesh, device: device)
    }

    private static func makePerspectiveProjection(fovyRadians: Float, aspect: Float, nearZ: Float, farZ: Float) -> matrix_float4x4 {
        let yScale = 1.0 / tan(fovyRadians * 0.5)
        let xScale = yScale / aspect
        let zScale = farZ / (nearZ - farZ)
        let wzScale = nearZ * farZ / (nearZ - farZ)

        return matrix_float4x4(columns: (
            SIMD4<Float>(xScale, 0, 0, 0),
            SIMD4<Float>(0, yScale, 0, 0),
            SIMD4<Float>(0, 0, zScale, -1),
            SIMD4<Float>(0, 0, wzScale, 0)
        ))
    }

    private static func makePrecomputedFractal(from settings: RenderSettingsSnapshot) -> PrecomputedFractalParams {
        let inverseMinRadius = 1.0 / settings.minDistance
        var scale = SIMD4<Float>(repeating: settings.fractalScale * inverseMinRadius)
        scale.w = abs(scale.w)

        let absScaleMinusOne = abs(settings.fractalScale - 1.0)
        let absScalePower = pow(max(abs(settings.fractalScale), 1e-6), Float(1 - settings.fractalIterations))
        let sphereRadiusSquared = settings.sphereRadius * settings.sphereRadius

        return PrecomputedFractalParams(scale: scale,
                                        absScalem1: absScaleMinusOne,
                                        absScalePow: absScalePower,
                                        invSphereRadiusSq: 1.0 / sphereRadiusSquared,
                                        sphereRadiusSq: sphereRadiusSquared)
    }

    private static func makePrecomputedLighting(time: Float,
                                                lightingMode: LightingMode,
                                                audioLevel: Float,
                                                bassLevel: Float,
                                                midLevel: Float,
                                                trebleLevel: Float,
                                                beatIntensity: Float) -> PrecomputedLighting {
        let animatedTime = time * 0.01 + 15.00
        let spotLightPosition: SIMD3<Float>
        let lightIntensity: Float

        switch lightingMode {
        case .staticLight:
            spotLightPosition = SIMD3<Float>(2.0, 1.5, 2.0)
            lightIntensity = 1.0
        case .audioReactive:
            let basePosition = SIMD3<Float>(1.5, 1.0, 1.5)
            let bassAmplitude = max(audioLevel, bassLevel) * 2.0
            let trebleSpeed = 2.0 + trebleLevel * 4.0
            let audioOffset = SIMD3<Float>(sin(animatedTime * trebleSpeed) * bassAmplitude,
                                           midLevel * 2.0,
                                           cos(animatedTime * trebleSpeed) * bassAmplitude)
            spotLightPosition = basePosition + audioOffset
            lightIntensity = 0.5 + audioLevel * 1.0 + bassLevel * 0.5
        case .visualizer:
            let beatJump = beatIntensity * 3.0
            let orbitSpeed = 1.5 + midLevel * 3.0
            spotLightPosition = SIMD3<Float>(
                sin(animatedTime * orbitSpeed) * (2.0 + bassLevel * 2.0) + beatJump * sin(animatedTime * 8.0),
                1.0 + trebleLevel * 2.0 + beatIntensity * 1.5,
                cos(animatedTime * orbitSpeed) * (2.0 + bassLevel * 2.0) + beatJump * cos(animatedTime * 8.0)
            )
            lightIntensity = 0.3 + bassLevel * 1.5 + beatIntensity * 0.5
        case .animated:
            let pathTime = animatedTime + 0.03
            let path = SIMD3<Float>(-0.78 + 3.0 * sin(2.14 * pathTime),
                                    0.05 + 2.5 * sin(0.942 * pathTime + 1.3),
                                    0.05 + 3.5 * cos(3.594 * pathTime))
            let offset = SIMD3<Float>(sin(animatedTime * 18.4),
                                      cos(animatedTime * 17.98),
                                      sin(animatedTime * 22.53)) * 0.2
            spotLightPosition = path + offset
            lightIntensity = 0.9 + sin(animatedTime * 1.5) * 0.15
        }

        return PrecomputedLighting(spotLightPosition: spotLightPosition, lightIntensity: lightIntensity)
    }

    private static func makePrecomputedAudio(from settings: RenderSettingsSnapshot) -> PrecomputedAudio {
        let maxBand = max(settings.bassLevel, max(settings.midLevel, settings.trebleLevel))
        let weightedEnergy = settings.bassLevel * 0.6 + settings.midLevel * 0.3 + settings.trebleLevel * 0.1
        return PrecomputedAudio(bands: SIMD4<Float>(settings.bassLevel, settings.midLevel, settings.trebleLevel, settings.beatIntensity),
                                energy: SIMD2<Float>(maxBand, weightedEnergy),
                                pad: .zero)
    }

    private static func makePrecomputedFog(from settings: RenderSettingsSnapshot) -> PrecomputedFog {
        let fogIntensity = settings.fogEnabled ? settings.fogIntensity : 0.0
        let inverseFog = fogIntensity > 1e-6 ? 1.0 / fogIntensity : 0.0
        return PrecomputedFog(fog: SIMD4<Float>(fogIntensity, inverseFog, 0.0, 0.0),
                              color: SIMD4<Float>(settings.fogColor.x, settings.fogColor.y, settings.fogColor.z, 0.0))
    }
}
#endif