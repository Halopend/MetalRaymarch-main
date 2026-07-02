import Foundation
import Metal
import MetalKit
import ModelIO
import simd
import CoreGraphics
#if canImport(AppKit)
import AppKit
#endif

// ═══════════════════════════════════════════════════════════════════════════
// Headless offscreen fractal renderer for the Quick Look extensions.
//
// A single still frame of Threshold's raymarcher with NO app, NO MTKView, no
// run loop. Faithful reproduction of the app's Mac screenshot path:
//   decode FractalPreset → RenderSettings → apply → snapshot()
//   → packUniforms (mirror of makeUniforms in RaymarchRenderView.swift)
//   → draw a proxy ellipsoid with screenshotVertexShader / fragmentShaderMono
//   → read back BGRA → CGImage.
//
// The raymarch shaders are compiled into THIS bundle's own default.metallib
// (Shaders.metal is a member of the extension target), so `makeDefaultLibrary`
// finds them — identical GPU code to the app.
// ═══════════════════════════════════════════════════════════════════════════

// MARK: - Matrix helpers (tiny local copies; identical math to RendererMath).

private func hr_translation(_ tx: Float, _ ty: Float, _ tz: Float) -> matrix_float4x4 {
    matrix_float4x4(columns: (
        SIMD4<Float>(1, 0, 0, 0),
        SIMD4<Float>(0, 1, 0, 0),
        SIMD4<Float>(0, 0, 1, 0),
        SIMD4<Float>(tx, ty, tz, 1)
    ))
}

private func hr_scale(_ sx: Float, _ sy: Float, _ sz: Float) -> matrix_float4x4 {
    matrix_float4x4(columns: (
        SIMD4<Float>(sx, 0, 0, 0),
        SIMD4<Float>(0, sy, 0, 0),
        SIMD4<Float>(0, 0, sz, 0),
        SIMD4<Float>(0, 0, 0, 1)
    ))
}

private func hr_matrix4x4(from q: simd_quatf) -> matrix_float4x4 {
    let m3 = matrix_float3x3(q)
    return matrix_float4x4(columns: (
        SIMD4<Float>(m3.columns.0, 0),
        SIMD4<Float>(m3.columns.1, 0),
        SIMD4<Float>(m3.columns.2, 0),
        SIMD4<Float>(0, 0, 0, 1)
    ))
}

// MARK: - Uniforms packing
//
// Faithful reproduction of `makeUniforms(settings:elapsedTime:deltaTime:)` in
// RaymarchRenderView.swift. For a single still frame we take the smoothing
// shortcut: with a huge implicit deltaTime every exponential smoother snaps to
// its target (smoothed == target). baseRotation = identity, jitter = 0,
// warm-start = 0.
func packUniforms(_ settings: RenderSettingsSnapshot,
                  drawableSize: CGSize,
                  elapsedTime: Float) -> Uniforms {
    let smoothedScale = settings.scale

    let userRotationMatrix = hr_matrix4x4(from: settings.worldRotation)
    let combinedRotationMatrix = userRotationMatrix * matrix_identity_float4x4
    let effectiveScale = smoothedScale * settings.detailScale
    let translationMatrix = hr_translation(settings.position.x, settings.position.y, settings.position.z)
    let scaleMatrix = hr_scale(effectiveScale, effectiveScale, effectiveScale)
    let modelMatrix = translationMatrix * combinedRotationMatrix * scaleMatrix

    let isKleinianFamily = settings.fractalType == .kleinian || settings.fractalType == .theliPseudoKleinian
    let traceScaleFloor: Float = isKleinianFamily ? 0.02 : 0.15
    let maxViewDistanceCap: Float = isKleinianFamily ? 420.0 : 80.0
    let baseViewDistance: Float = isKleinianFamily ? RenderSettings.maxViewDistance * 2.0 : RenderSettings.maxViewDistance
    let viewDistanceScale = max(min(effectiveScale, smoothedScale), traceScaleFloor)
    var targetMaxViewDistance = min(maxViewDistanceCap, baseViewDistance / viewDistanceScale)
    // Zoom-out: lift the horizon so the WORLD-space range never drops below
    // baseViewDistance (mirrors RaymarchRenderView; no-op at scale >= the floor).
    let safeScale = max(effectiveScale, 1e-4)
    if effectiveScale < traceScaleFloor {
        // Cover camera→model distance too; stay under kRayMissThreshold (900).
        let camDistWorld = simd_length(SIMD3<Float>(0, 0, 3) - settings.position)
        targetMaxViewDistance = max(targetMaxViewDistance,
                                    min(880.0, (camDistWorld + baseViewDistance) / safeScale))
    }
    let horizonCap = max(maxViewDistanceCap, 880.0)
    let maxViewDistance = max(4.0, min(horizonCap, targetMaxViewDistance))

    let aspect = Float(max(drawableSize.width, 1) / max(drawableSize.height, 1))
    let projection = RenderPrecompute.makePerspectiveProjection(fovyRadians: Float.pi / 3, aspect: aspect, nearZ: 0.01, farZ: 500.0)
    let viewMatrix = hr_translation(0, 0, -3.0)
    let modelView = viewMatrix * modelMatrix
    let inverseModelView = modelView.inverse
    let jitteredProjection = projection

    let precomputedFractal = RenderPrecompute.makePrecomputedFractal(from: settings)
    let precomputedLighting = RenderPrecompute.makePrecomputedLighting(time: elapsedTime,
                                                           lightingMode: settings.lightingMode,
                                                           audioLevel: settings.audioLevel,
                                                           bassLevel: settings.bassLevel,
                                                           midLevel: settings.midLevel,
                                                           trebleLevel: settings.trebleLevel,
                                                           beatIntensity: settings.beatIntensity,
                                                           vibrance: settings.colorSchemeParams.vibrance,
                                                           lightingSoftness: settings.lightingSoftness)
    let precomputedAudio = RenderPrecompute.makePrecomputedAudio(from: settings)
    var precomputedFog = RenderPrecompute.makePrecomputedFog(from: settings)
    // Zoom fog compensation (Settings toggle, default off): holds the fog's WORLD
    // radius constant on zoom-out for the whole range below scale 1 (no-op at
    // scale >= 1; mirrors RaymarchRenderView — was previously hardcoded on for
    // Kleinian only, and briefly keyed to the unrelated 0.15 horizon-lift floor).
    if settings.zoomFogCompensationEnabled {
        let baseFog = precomputedFog.fog.x
        if baseFog > 1e-6 {
            let fogScale = min(1.0, max(effectiveScale, 1e-4))
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

    // Hoisted out of the Uniforms(...) call below: the single-expression init is
    // large enough that nested calls/ternaries push swiftc's type-checker over its
    // "reasonable time" limit.
    let isMandelbulb = settings.fractalType == .mandelbulb
    let bubbleEnabled: Int32 = isMandelbulb ? 0 : (settings.safetyBubbleEnabled ? 1 : 0)
    let bubbleStrength: Float = isMandelbulb ? 0.0 : settings.safetyBubbleStrength
    // Zoom-out epsilon/LOD rescale (1.0 at scale >= 0.15; mirrors RaymarchRenderView).
    let zoomOutEpsilonLoosen: Float = max(1.0, 0.15 / max(effectiveScale, 1e-4))
    let zoomOutLODScale: Float = min(1.0, effectiveScale / 0.15)
    let coneMarchScale = RenderPrecompute.coneMarchScale(
        strength: settings.coneMarchStrength,
        projection: projection,
        viewportHeight: Float(drawableSize.height))
    let pixelFootprintPerDist = RenderPrecompute.pixelFootprintPerDist(
        projection: projection,
        viewportHeight: Float(drawableSize.height))
    let springLen = simd_length(settings.springDisplacement)
    let springVisible: Int32 = (settings.springActive || springLen > 0.001) ? 1 : 0
    let renderResolution = SIMD2<Float>(Float(drawableSize.width), Float(drawableSize.height))

    return Uniforms(projectionMatrix: jitteredProjection,
                    modelViewMatrix: modelView,
                    inverseModelViewMatrix: inverseModelView,
                    previousViewProjMatrix: matrix_identity_float4x4,
                    previousInvViewProjMatrix: matrix_identity_float4x4,
                    time: elapsedTime,
                    minDistance: settings.minDistance,
                    fractalScale: settings.fractalScale,
                    fractalIterations: Int32(settings.fractalIterations),
                    maxRaySteps: Int32(settings.maxRaySteps),
                    maxViewDistance: maxViewDistance,
                    marchEpsilonScale: (1.0 / max(effectiveScale, 1.0)) * zoomOutEpsilonLoosen,
                    colorMix: animatedColorMix,
                    glowIntensity: animatedGlow,
                    foldingLimit: settings.foldingLimit,
                    sphereRadius: settings.sphereRadius,
                    safetyBubbleRadius: scaleCorrectedBubbleRadius,
                    safetyBubbleEnabled: bubbleEnabled,
                    safetyBubbleShape: settings.safetyBubbleShape,
                    safetyBubbleFadeEnabled: settings.safetyBubbleFadeEnabled ? 1 : 0,
                    safetyBubbleFadeWidth: scaleCorrectedFadeWidth,
                    safetyBubbleStrength: bubbleStrength,
                    colorIterations: settings.colorIterations,
                    limitFlash: settings.limitFlash,
                    activeGesture: Int32(settings.activeGestureIndex),
                    warmStartEnabled: 0,
                    fractalType: settings.fractalType.rawValue,
                    lightingSoftness: settings.lightingSoftness,
                    sphericalInversionMode: settings.sphericalInversionMode.rawValue,
                    sphericalInversionRadius: settings.sphericalInversionRadius,
                    sphereProjectionBlend: settings.sphereProjectionEnabled ? settings.sphereProjectionBlend : 0,
                    sphereProjectionRadius: settings.sphereProjectionRadius,
                    spaceWarpStrength: settings.spaceWarpStrength,
                    spaceWarpParam1: settings.spaceWarpParam1,
                    spaceWarpParam2: settings.spaceWarpParam2,
                    spaceWarpParam3: settings.spaceWarpParam3,
                    spaceWarpAxis: settings.spaceWarpAxis,
                    spaceWarpStack: settings.spaceWarpStack,
                    stepMultiplier: settings.stepMultiplier,
                    boundingSphereRadius: settings.estimatedBoundingSphereRadius,
                    smartAdvanceEnabled: settings.smartAdvanceEnabled ? 1 : 0,
                    coneMarchScale: coneMarchScale,
                    shadowsEnabled: settings.shadowsEnabled ? 1 : 0,
                    distanceLODFalloff: settings.distanceLODStrength * 0.5 * zoomOutLODScale,
                    benchCollectSteps: 0,
                    pixelFootprintPerDist: pixelFootprintPerDist,
                    coarseRateMagMax: 1.0,
                    springDisplacementX: settings.springDisplacement.x,
                    springDisplacementY: settings.springDisplacement.y,
                    springDisplacementZ: settings.springDisplacement.z,
                    springStretch: springLen,
                    springAnchorNDC: SIMD2<Float>(0.7, -0.7),
                    springVisible: springVisible,
                    springRestRadius: 0.06,
                    jitterOffset: .zero,
                    renderResolution: renderResolution,
                    floorPlane: SIMD4<Float>(0, 1, 0, 0),
                    floorCenterRadius: SIMD4<Float>(0, 0, 0, 0),
                    formulaParams: settings.formulaParams,
                    precomputedFractal: precomputedFractal,
                    precomputedLighting: precomputedLighting,
                    precomputedAudio: precomputedAudio,
                    precomputedFog: precomputedFog,
                    colorScheme: settings.colorSchemeParams,
                    benchAblate: 0,
                    passthroughBackground: 0,
                    boundingFogEnabled: 0,
                    boundingShadowDepth: 0)
}

// MARK: - Headless Metal render harness

/// Immutable after `init` (all stored state is `let` GPU objects), so safe to
/// share across the Quick Look extension's worker threads.
final class HeadlessRenderer: @unchecked Sendable {

    /// Shared instance. nil if Metal or the bundled shaders are unavailable —
    /// callers must treat that as "no live render" and fall back.
    static let shared: HeadlessRenderer? = try? HeadlessRenderer()

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState        // built-in fractals
    private let depthState: MTLDepthStencilState
    private let mesh: MTKMesh
    private let vertexDescriptor: MTLVertexDescriptor

    /// Custom (embedded-DE) pipelines compiled on demand from a scene's Metal
    /// source, cached by `EmbeddedFormula.sourceHash` so the interactive view
    /// never recompiles per frame.
    private let cacheLock = NSLock()
    private var customPipelines: [String: MTLRenderPipelineState] = [:]

    /// Exposed so an interactive MTKView can share the same device.
    var metalDevice: MTLDevice { device }

    /// Largest square render we produce; Quick Look scales down as needed.
    private let maxSide = 1024
    private let minSide = 128

    enum Failure: Error { case noDevice, noQueue, noLibrary, noFunction(String), badMesh }

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw Failure.noDevice }
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw Failure.noQueue }
        self.commandQueue = queue

        // Shaders.metal is compiled into this extension bundle's default metallib;
        // this library backs the BUILT-IN fractal pipeline only (embedded-DE
        // scenes compile their own library from EmbeddedMetalSources at runtime).
        // Headless test seam: `THRESHOLD_QL_METALLIB` lets the render-check tool
        // (Scripts/ql_render_check.sh) point at a prebuilt metallib since a plain
        // CLI has no app bundle. Unset in the shipping appex → normal bundle path.
        let library: MTLLibrary?
        if let p = ProcessInfo.processInfo.environment["THRESHOLD_QL_METALLIB"] {
            library = try? device.makeLibrary(URL: URL(fileURLWithPath: p))
        } else {
            let bundle = Bundle(for: HeadlessRenderer.self)
            library = (try? device.makeDefaultLibrary(bundle: bundle)) ?? device.makeDefaultLibrary()
        }
        guard let library else { throw Failure.noLibrary }

        guard let vertexFunction = library.makeFunction(name: "screenshotVertexShader") else {
            throw Failure.noFunction("screenshotVertexShader")
        }
        guard let fragmentFunction = try? library.makeFunction(name: "fragmentShaderMono",
                                                               constantValues: MTLFunctionConstantValues()) else {
            throw Failure.noFunction("fragmentShaderMono")
        }

        let vd = MTLVertexDescriptor()
        vd.attributes[VertexAttribute.position.rawValue].format = .float3
        vd.attributes[VertexAttribute.position.rawValue].offset = 0
        vd.attributes[VertexAttribute.position.rawValue].bufferIndex = BufferIndex.meshPositions.rawValue
        vd.attributes[VertexAttribute.texcoord.rawValue].format = .float2
        vd.attributes[VertexAttribute.texcoord.rawValue].offset = 0
        vd.attributes[VertexAttribute.texcoord.rawValue].bufferIndex = BufferIndex.meshGenerics.rawValue
        vd.layouts[BufferIndex.meshPositions.rawValue].stride = 12
        vd.layouts[BufferIndex.meshPositions.rawValue].stepFunction = .perVertex
        vd.layouts[BufferIndex.meshGenerics.rawValue].stride = 8
        vd.layouts[BufferIndex.meshGenerics.rawValue].stepFunction = .perVertex
        self.vertexDescriptor = vd

        let pd = MTLRenderPipelineDescriptor()
        pd.label = "Threshold QL Raymarch"
        pd.vertexFunction = vertexFunction
        pd.fragmentFunction = fragmentFunction
        pd.vertexDescriptor = vd
        pd.colorAttachments[0].pixelFormat = .bgra8Unorm
        pd.depthAttachmentPixelFormat = .depth32Float
        pd.rasterSampleCount = 1
        self.pipelineState = try device.makeRenderPipelineState(descriptor: pd)

        let dsd = MTLDepthStencilDescriptor()
        dsd.depthCompareFunction = .less
        dsd.isDepthWriteEnabled = true
        guard let ds = device.makeDepthStencilState(descriptor: dsd) else { throw Failure.badMesh }
        self.depthState = ds

        let allocator = MTKMeshBufferAllocator(device: device)
        let mdlMesh = MDLMesh.newEllipsoid(withRadii: SIMD3<Float>(repeating: 100),
                                           radialSegments: 64, verticalSegments: 32,
                                           geometryType: .triangles,
                                           inwardNormals: false, hemisphere: false,
                                           allocator: allocator)
        let mdlVD = MTKModelIOVertexDescriptorFromMetal(vd)
        (mdlVD.attributes[VertexAttribute.position.rawValue] as! MDLVertexAttribute).name = MDLVertexAttributePosition
        (mdlVD.attributes[VertexAttribute.texcoord.rawValue] as! MDLVertexAttribute).name = MDLVertexAttributeTextureCoordinate
        mdlMesh.vertexDescriptor = mdlVD
        guard let built = try? MTKMesh(mesh: mdlMesh, device: device) else { throw Failure.badMesh }
        self.mesh = built
    }

    // MARK: Public render entry points

    /// Render a scene / music-preset. Live-renders built-in fractals AND scenes
    /// with an embedded distance estimator (the DE Metal source is compiled at
    /// runtime and cached). Returns nil only when a scene claims `.custom` but
    /// carries no formula, or on GPU failure. Never throws.
    func render(preset: FractalPreset, pixelSize: CGSize) -> CGImage? {
        if preset.fractalType == .custom && preset.embeddedFormula == nil { return nil }
        let settings = RenderSettings()
        preset.apply(to: settings)
        return render(snapshot: settings.snapshot(), pixelSize: pixelSize, formula: preset.embeddedFormula)
    }

    func render(snapshot: RenderSettingsSnapshot, pixelSize: CGSize, formula: EmbeddedFormula? = nil) -> CGImage? {
        guard let pipeline = resolvePipeline(for: formula) else { return nil }
        let requested = Int(max(pixelSize.width, pixelSize.height).rounded())
        let side = max(minSide, min(maxSide, requested == 0 ? 512 : requested))
        let uniforms = packUniforms(snapshot, drawableSize: CGSize(width: side, height: side), elapsedTime: 0)
        return renderImage(uniforms: uniforms, side: side, pipeline: pipeline)
    }

    /// Live-render a snapshot into an interactive MTKView's current drawable.
    /// The view must be configured `.bgra8Unorm` + depth `.depth32Float` to
    /// match the shared pipeline. Presents and commits; safe to call from the
    /// main thread on demand. Pass the scene's `formula` for embedded-DE scenes.
    func render(snapshot: RenderSettingsSnapshot, in view: MTKView, formula: EmbeddedFormula? = nil) {
        guard let pipeline = resolvePipeline(for: formula),
              let rpd = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let cmd = commandQueue.makeCommandBuffer() else { return }
        let size = view.drawableSize
        let uniforms = packUniforms(snapshot, drawableSize: size, elapsedTime: 0)
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        rpd.depthAttachment.loadAction = .clear
        rpd.depthAttachment.clearDepth = 1.0
        guard encodeDraw(uniforms: uniforms, passDescriptor: rpd, width: Int(size.width),
                         height: Int(size.height), pipeline: pipeline, commandBuffer: cmd) else { return }
        cmd.present(drawable)
        cmd.commit()
    }

    /// Whether a scene at `url` needs (and can get) a compiled custom pipeline —
    /// used to pre-warm the compile before the interactive view's first frame.
    @discardableResult
    func prewarm(formula: EmbeddedFormula?) -> Bool { resolvePipeline(for: formula) != nil }

    // MARK: Pipeline resolution (built-in vs embedded-DE)

    private func resolvePipeline(for formula: EmbeddedFormula?) -> MTLRenderPipelineState? {
        guard let formula else { return pipelineState }
        let key = formula.sourceHash
        cacheLock.lock()
        let cached = customPipelines[key]
        cacheLock.unlock()
        if let cached { return cached }
        guard let built = compileCustomPipeline(formula) else { return nil }
        cacheLock.lock()
        customPipelines[key] = built
        cacheLock.unlock()
        return built
    }

    /// Synthesize the self-contained Metal source (base shaders + the scene's DE
    /// spliced in, via the app's `CustomShaderCompiler`), compile it, and build a
    /// pipeline on the same entry points. Compilation can take a second or two;
    /// callers cache the result.
    private func compileCustomPipeline(_ formula: EmbeddedFormula) -> MTLRenderPipelineState? {
        let isWarp = formula.effectKind == .spaceWarp
        guard let source = try? CustomShaderCompiler.synthesizeSource(
            fractal: isWarp ? nil : formula, spaceWarp: isWarp ? formula : nil) else { return nil }
        let options = MTLCompileOptions()
        if #available(macOS 15.0, *) { options.mathMode = .fast } else { options.fastMathEnabled = true }
        guard let lib = try? device.makeLibrary(source: source, options: options),
              let vfn = lib.makeFunction(name: "screenshotVertexShader"),
              let ffn = try? lib.makeFunction(name: "fragmentShaderMono", constantValues: MTLFunctionConstantValues())
        else { return nil }
        let pd = MTLRenderPipelineDescriptor()
        pd.label = "Threshold QL Custom DE"
        pd.vertexFunction = vfn
        pd.fragmentFunction = ffn
        pd.vertexDescriptor = vertexDescriptor
        pd.colorAttachments[0].pixelFormat = .bgra8Unorm
        pd.depthAttachmentPixelFormat = .depth32Float
        pd.rasterSampleCount = 1
        return try? device.makeRenderPipelineState(descriptor: pd)
    }

    // MARK: Core render

    /// Shared draw: binds pipeline + uniforms + proxy mesh into a render pass.
    /// Returns false if the encoder or uniform buffer could not be created.
    @discardableResult
    private func encodeDraw(uniforms: Uniforms, passDescriptor rpd: MTLRenderPassDescriptor,
                            width: Int, height: Int, pipeline: MTLRenderPipelineState,
                            commandBuffer cmd: MTLCommandBuffer) -> Bool {
        var uniformsArray = UniformsArray(uniforms: (uniforms, uniforms))
        guard let uniformBuffer = device.makeBuffer(bytes: &uniformsArray,
                                                    length: MemoryLayout<UniformsArray>.stride,
                                                    options: .storageModeShared),
              let benchBuffer = device.makeBuffer(length: 16, options: .storageModeShared),
              let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return false }
        enc.setCullMode(.front)
        enc.setFrontFacing(.counterClockwise)
        enc.setRenderPipelineState(pipeline)
        enc.setDepthStencilState(depthState)
        enc.setViewport(MTLViewport(originX: 0, originY: 0, width: Double(width), height: Double(height), znear: 0, zfar: 1))
        enc.setVertexBuffer(uniformBuffer, offset: 0, index: BufferIndex.uniforms.rawValue)
        enc.setFragmentBuffer(uniformBuffer, offset: 0, index: BufferIndex.uniforms.rawValue)
        enc.setFragmentBuffer(benchBuffer, offset: 0, index: BufferIndex.benchCounters.rawValue)
        for (i, vb) in mesh.vertexBuffers.enumerated() {
            enc.setVertexBuffer(vb.buffer, offset: vb.offset, index: i)
        }
        for submesh in mesh.submeshes {
            enc.drawIndexedPrimitives(type: submesh.primitiveType,
                                      indexCount: submesh.indexCount,
                                      indexType: submesh.indexType,
                                      indexBuffer: submesh.indexBuffer.buffer,
                                      indexBufferOffset: submesh.indexBuffer.offset)
        }
        enc.endEncoding()
        return true
    }

    private func renderImage(uniforms: Uniforms, side: Int, pipeline: MTLRenderPipelineState) -> CGImage? {
        let colorDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                 width: side, height: side, mipmapped: false)
        colorDesc.usage = [.renderTarget, .shaderRead]
        colorDesc.storageMode = .shared
        guard let colorTex = device.makeTexture(descriptor: colorDesc) else { return nil }

        let depthDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float,
                                                                 width: side, height: side, mipmapped: false)
        depthDesc.usage = [.renderTarget]
        depthDesc.storageMode = .private
        guard let depthTex = device.makeTexture(descriptor: depthDesc) else { return nil }

        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = colorTex
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].storeAction = .store
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        rpd.depthAttachment.texture = depthTex
        rpd.depthAttachment.loadAction = .clear
        rpd.depthAttachment.storeAction = .dontCare
        rpd.depthAttachment.clearDepth = 1.0

        guard let cmd = commandQueue.makeCommandBuffer() else { return nil }
        guard encodeDraw(uniforms: uniforms, passDescriptor: rpd, width: side, height: side,
                         pipeline: pipeline, commandBuffer: cmd) else { return nil }
        if let blit = cmd.makeBlitCommandEncoder() {
            blit.synchronize(resource: colorTex)
            blit.endEncoding()
        }
        cmd.commit()
        cmd.waitUntilCompleted()
        if cmd.error != nil { return nil }
        return Self.makeCGImage(from: colorTex, side: side)
    }

    private static func makeCGImage(from texture: MTLTexture, side: Int) -> CGImage? {
        let bytesPerRow = side * 4
        var raw = [UInt8](repeating: 0, count: bytesPerRow * side)
        raw.withUnsafeMutableBytes { ptr in
            texture.getBytes(ptr.baseAddress!, bytesPerRow: bytesPerRow,
                             from: MTLRegionMake2D(0, 0, side, side), mipmapLevel: 0)
        }
        let cs = CGColorSpaceCreateDeviceRGB()
        // bgra8Unorm (little-endian) → byteOrder32Little + premultipliedFirst reads BGRA.
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue).union(.byteOrder32Little)
        guard let ctx = CGContext(data: &raw, width: side, height: side, bitsPerComponent: 8,
                                  bytesPerRow: bytesPerRow, space: cs, bitmapInfo: bitmapInfo.rawValue) else { return nil }
        return ctx.makeImage()
    }
}
