#if canImport(MetalFX)
import MetalFX
import Metal

/// Minimal MetalFX spatial upscaler used by the raymarch renderer
/// Creates per-eye input/output textures and encodes spatial upscale.
final class MetalFXManager {
    struct Configuration: Equatable {
        var inputWidth: Int
        var inputHeight: Int
        var outputWidth: Int
        var outputHeight: Int
        var colorFormat: MTLPixelFormat
        var depthFormat: MTLPixelFormat
        var scale: Float
    }

    enum Error: Swift.Error, CustomStringConvertible {
        case textureCreationFailed(String)
        case scalerCreationFailed
        case missingTextures
        case textureViewFailed

        var description: String {
            switch self {
            case .textureCreationFailed(let name):
                return "Failed to create \(name) texture"
            case .scalerCreationFailed:
                return "Failed to create spatial scaler"
            case .missingTextures:
                return "MetalFX textures not ready"
            case .textureViewFailed:
                return "Failed to create eye texture view"
            }
        }
    }

    private let device: MTLDevice
    private(set) var configuration: Configuration
    private var viewCount: Int

    private var scalers: [MTLFXSpatialScaler] = []

    private(set) var inputTexture: MTLTexture?
    private(set) var depthTexture: MTLTexture?
    private(set) var outputTexture: MTLTexture?

    init(device: MTLDevice, configuration: Configuration, viewCount: Int) throws {
        self.device = device
        self.configuration = configuration
        self.viewCount = max(1, viewCount)
        try createTextures()
        try createScalers()
    }

    func update(configuration: Configuration, viewCount: Int) throws {
        if self.configuration == configuration && self.viewCount == viewCount { return }
        self.configuration = configuration
        self.viewCount = max(1, viewCount)
        try createTextures()
        try createScalers()
    }

    func encodeSpatialUpscale(commandBuffer: MTLCommandBuffer) throws {
        guard let input = inputTexture, let output = outputTexture else {
            throw Error.missingTextures
        }

        for eye in 0..<viewCount {
            guard let inView = input.makeTextureView(
                pixelFormat: input.pixelFormat,
                textureType: .type2D,
                levels: 0..<1,
                slices: eye..<(eye + 1)
            ), let outView = output.makeTextureView(
                pixelFormat: output.pixelFormat,
                textureType: .type2D,
                levels: 0..<1,
                slices: eye..<(eye + 1)
            ) else {
                throw Error.textureViewFailed
            }

            guard eye < scalers.count else { throw Error.scalerCreationFailed }
            let scaler = scalers[eye]
            scaler.colorTexture = inView
            scaler.outputTexture = outView
            // Tell the scaler exactly how much of the input texture contains valid content
            scaler.inputContentWidth = configuration.inputWidth
            scaler.inputContentHeight = configuration.inputHeight
            scaler.encode(commandBuffer: commandBuffer)
        }
    }

    private func createTextures() throws {
        // Input (low-res render target) - MUST have renderTarget for render pass
        let inputDescriptor = MTLTextureDescriptor()
        inputDescriptor.textureType = .type2DArray
        inputDescriptor.arrayLength = viewCount
        inputDescriptor.width = configuration.inputWidth
        inputDescriptor.height = configuration.inputHeight
        inputDescriptor.pixelFormat = configuration.colorFormat
        inputDescriptor.storageMode = .private
        // Explicitly set renderTarget first, then add shaderRead
        inputDescriptor.usage = MTLTextureUsage(rawValue: MTLTextureUsage.renderTarget.rawValue | MTLTextureUsage.shaderRead.rawValue)

        guard let input = device.makeTexture(descriptor: inputDescriptor) else {
            throw Error.textureCreationFailed("input")
        }
        input.label = "MetalFX Input"
        
        // Verify usage was set correctly
        guard input.usage.contains(.renderTarget) else {
            throw Error.textureCreationFailed("input - renderTarget usage not set (got \(input.usage.rawValue))")
        }
        inputTexture = input

        // Depth for offscreen render
        let depthDescriptor = MTLTextureDescriptor()
        depthDescriptor.textureType = .type2DArray
        depthDescriptor.arrayLength = viewCount
        depthDescriptor.width = configuration.inputWidth
        depthDescriptor.height = configuration.inputHeight
        depthDescriptor.pixelFormat = configuration.depthFormat
        depthDescriptor.storageMode = .private
        depthDescriptor.usage = [.renderTarget, .shaderRead]

        guard let depth = device.makeTexture(descriptor: depthDescriptor) else {
            throw Error.textureCreationFailed("depth")
        }
        depth.label = "MetalFX Depth"
        depthTexture = depth

        // Output (upscaled) - needs renderTarget for potential use in render passes
        let outputDescriptor = MTLTextureDescriptor()
        outputDescriptor.textureType = .type2DArray
        outputDescriptor.arrayLength = viewCount
        outputDescriptor.width = configuration.outputWidth
        outputDescriptor.height = configuration.outputHeight
        outputDescriptor.pixelFormat = configuration.colorFormat
        outputDescriptor.storageMode = .private
        outputDescriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]

        guard let output = device.makeTexture(descriptor: outputDescriptor) else {
            throw Error.textureCreationFailed("output")
        }
        output.label = "MetalFX Output"
        outputTexture = output
    }

    private func createScalers() throws {
        let descriptor = MTLFXSpatialScalerDescriptor()
        descriptor.inputWidth = configuration.inputWidth
        descriptor.inputHeight = configuration.inputHeight
        descriptor.outputWidth = configuration.outputWidth
        descriptor.outputHeight = configuration.outputHeight
        descriptor.colorTextureFormat = configuration.colorFormat
        descriptor.outputTextureFormat = configuration.colorFormat
        descriptor.colorProcessingMode = .perceptual

        var newScalers: [MTLFXSpatialScaler] = []
        for _ in 0..<viewCount {
            guard let scaler = descriptor.makeSpatialScaler(device: device) else {
                throw Error.scalerCreationFailed
            }
            newScalers.append(scaler)
        }
        scalers = newScalers
    }
}
#endif
