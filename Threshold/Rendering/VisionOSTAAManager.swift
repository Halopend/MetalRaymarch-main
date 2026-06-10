#if canImport(CompositorServices)
import Metal

// Manages double-buffered history textures and the TAA resolve compute pipeline
// for the visionOS renderer. MTLFXTemporalScaler is unavailable on visionOS;
// this is the hand-rolled equivalent using rgba16Float ping-pong history and a
// neighbourhood-variance-clamped exponential blend.
//
// Usage (per frame, after MetalFX spatial upscale):
//   1. Call prepare() to ensure textures match the drawable size.
//   2. Call encode() once per eye, passing the MetalFX output as currentTex.
//   3. Call advanceHistory() after encoding both eyes.
//   4. Pass outputTexture to resolveMetalFXOutputToDrawable() instead of
//      the MetalFX output texture — the RCAS resolve + sRGB write continues
//      to work unchanged since it reads texture2d_array<float> (format-agnostic).
final class VisionOSTAAManager {

    // rgba16Float keeps the accumulated result in linear space, avoiding
    // gamma-quantisation drift from repeated 8-bit round-trips.
    static let historyFormat: MTLPixelFormat = .rgba16Float

    private let device: MTLDevice
    private var pipeline: MTLComputePipelineState?

    // Ping-pong pair: one is read (history from last frame), one is written (new history).
    private var historyTextures: [MTLTexture] = []
    private var historyReadIndex: Int = 0  // index of the "previous frame" texture

    // Full-resolution TAA result for this frame. Fed to the RCAS resolve pass.
    private(set) var outputTexture: MTLTexture?

    private var size: SIMD2<Int> = .zero
    private var viewCount: Int = 0

    // When true the next encode call uses blendFactor = 1.0, discarding stale history.
    private var needsReset = true

    init(device: MTLDevice) throws {
        self.device = device
        guard let library = device.makeDefaultLibrary(),
              let fn = library.makeFunction(name: "taaResolve") else {
            throw RendererError.metalLibraryUnavailable
        }
        pipeline = try device.makeComputePipelineState(function: fn)
    }

    // Call once per frame before encode(). Returns false if texture allocation failed.
    func prepare(width: Int, height: Int, viewCount: Int) -> Bool {
        let newSize = SIMD2(width, height)
        let newViewCount = max(1, viewCount)
        if newSize == size && newViewCount == self.viewCount &&
           historyTextures.count == 2 && outputTexture != nil {
            return true
        }
        size = newSize
        self.viewCount = newViewCount
        needsReset = true
        historyReadIndex = 0

        let desc = MTLTextureDescriptor()
        desc.textureType = .type2DArray
        desc.pixelFormat = Self.historyFormat
        desc.width = width
        desc.height = height
        desc.arrayLength = newViewCount
        desc.storageMode = .private
        desc.usage = [.shaderRead, .shaderWrite]

        historyTextures = (0..<2).compactMap { i in
            let t = device.makeTexture(descriptor: desc)
            t?.label = "TAA History \(i)"
            return t
        }
        guard historyTextures.count == 2 else { return false }

        let outDesc = desc.copy() as! MTLTextureDescriptor
        outputTexture = device.makeTexture(descriptor: outDesc)
        outputTexture?.label = "TAA Output"
        return outputTexture != nil
    }

    // Force history discard on the next encode (camera cut, parameter change, etc.)
    func requestReset() { needsReset = true }

    // Encode the TAA resolve pass for one eye.
    // currentTex: the MetalFX spatial output (bgra8Unorm_srgb, full-res 2D array).
    // blendFactor: 0.1 when stable, 0.3-0.5 while parameters are settling. Overridden
    //              with 1.0 when needsReset is set.
    func encode(
        commandBuffer: MTLCommandBuffer,
        currentTex: MTLTexture,
        viewIndex: Int,
        invProjMatrix: matrix_float4x4,
        invViewMatrix: matrix_float4x4,
        previousViewProjMatrix: matrix_float4x4,
        blendFactor: Float
    ) {
        guard let pipeline,
              let output = outputTexture,
              historyTextures.count == 2 else { return }

        let histRead  = historyTextures[historyReadIndex]
        let histWrite = historyTextures[1 - historyReadIndex]

        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.label = "TAA Resolve Eye \(viewIndex)"
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(currentTex, index: 0)
        encoder.setTexture(histRead,   index: 1)
        encoder.setTexture(histWrite,  index: 2)
        encoder.setTexture(output,     index: 3)

        var u = TAATileUniforms(
            invProjMatrix:          invProjMatrix,
            invViewMatrix:          invViewMatrix,
            previousViewProjMatrix: previousViewProjMatrix,
            resolution:             SIMD2<Float>(Float(size.x), Float(size.y)),
            blendFactor:            needsReset ? 1.0 : blendFactor,
            eyeIndex:               UInt32(viewIndex)
        )
        encoder.setBytes(&u, length: MemoryLayout<TAATileUniforms>.stride, index: 0)

        let w = pipeline.threadExecutionWidth
        let h = pipeline.maxTotalThreadsPerThreadgroup / w
        encoder.dispatchThreads(
            MTLSize(width: size.x, height: size.y, depth: 1),
            threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1)
        )
        encoder.endEncoding()
    }

    // Call after encoding ALL eyes for this frame to advance the ping-pong index
    // and clear the reset flag.
    func advanceHistory() {
        historyReadIndex = 1 - historyReadIndex
        needsReset = false
    }
}
#endif
