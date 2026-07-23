#if os(iOS) && !canImport(MetalFX)
import Metal
import simd

/// Native-resolution fallbacks for iPad Simulator SDKs that do not ship
/// MetalFX. Keeping the same surface as the device implementations lets the
/// shared renderer compile and automatically take its existing direct-render
/// path whenever `prepare` returns `false`.
final class ViewportSpatialUpscaler {
    typealias Size = MetalFXSize

    static let minimumInputShortEdge = MetalFXTextureSupport.minimumInputShortEdge

    private(set) var inputSize = Size(width: 0, height: 0)
    private(set) var outputSize = Size(width: 0, height: 0)
    private(set) var colorTexture: MTLTexture?
    private(set) var depthTexture: MTLTexture?
    private(set) var outputTexture: MTLTexture?

    init(device: MTLDevice, colorFormat: MTLPixelFormat, depthFormat: MTLPixelFormat) {}

    func prepare(inputWidth: Int, inputHeight: Int, outputWidth: Int, outputHeight: Int) -> Bool {
        false
    }

    func encode(commandBuffer: MTLCommandBuffer) {}
}

final class ViewportTemporalUpscaler: @unchecked Sendable {
    typealias Size = MetalFXSize

    static let minimumInputShortEdge = MetalFXTextureSupport.minimumInputShortEdge
    static let motionFormat: MTLPixelFormat = .rg16Float
    static let maxScaleFactor = 3.0

    private(set) var inputSize = Size(width: 0, height: 0)
    private(set) var outputSize = Size(width: 0, height: 0)
    private(set) var colorTexture: MTLTexture?
    private(set) var depthTexture: MTLTexture?
    private(set) var motionTexture: MTLTexture?
    private(set) var outputTexture: MTLTexture?

    init(device: MTLDevice, colorFormat: MTLPixelFormat, depthFormat: MTLPixelFormat) {}

    func prepare(inputWidth: Int, inputHeight: Int, outputWidth: Int, outputHeight: Int) -> Bool {
        false
    }

    func requestReset() {}

    func encode(commandBuffer: MTLCommandBuffer,
                jitterPixels: SIMD2<Float>,
                forceReset: Bool) {}
}
#endif
