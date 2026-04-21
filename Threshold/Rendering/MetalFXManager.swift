#if canImport(MetalFX)
import MetalFX
import Metal

/// Optimized MetalFX spatial upscaler with cached views and scaler reuse.
/// Depth is preserved for ASW / reprojection.
final class MetalFXManager {

    // MARK: - Configuration

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

    // MARK: - Properties

    private let device: MTLDevice
    private(set) var configuration: Configuration
    private var viewCount: Int

    private var scalers: [MTLFXSpatialScaler] = []

    private(set) var inputTexture: MTLTexture?
    private(set) var depthTexture: MTLTexture?
    private(set) var outputTexture: MTLTexture?

    // Cached per-eye views (NO per-frame allocation)
    private var inputViews: [MTLTexture] = []
    private var outputViews: [MTLTexture] = []

    // MARK: - Init

    init(device: MTLDevice, configuration: Configuration, viewCount: Int) throws {
        self.device = device
        self.configuration = configuration
        self.viewCount = max(1, viewCount)

        try createTextures()
        try createOrUpdateScalers(resolutionChanged: true)
    }

    // MARK: - Public Update

    func update(configuration: Configuration, viewCount: Int) throws {
        let newViewCount = max(1, viewCount)

        let resolutionChanged =
            self.configuration.inputWidth  != configuration.inputWidth ||
            self.configuration.inputHeight != configuration.inputHeight ||
            self.configuration.outputWidth != configuration.outputWidth ||
            self.configuration.outputHeight != configuration.outputHeight ||
            self.configuration.colorFormat != configuration.colorFormat

        let viewCountChanged = self.viewCount != newViewCount

        self.configuration = configuration
        self.viewCount = newViewCount

        if resolutionChanged || viewCountChanged {
            try createTextures()
        }

        try createOrUpdateScalers(resolutionChanged: resolutionChanged)
    }

    // MARK: - Encoding

    func encodeSpatialUpscale(commandBuffer: MTLCommandBuffer, fence: MTLFence? = nil) throws {
        guard
            !inputViews.isEmpty,
            !outputViews.isEmpty,
            scalers.count >= viewCount
        else {
            throw Error.missingTextures
        }

        for eye in 0..<viewCount {
            let scaler = scalers[eye]
            scaler.colorTexture = inputViews[eye]
            scaler.outputTexture = outputViews[eye]
            
            // Set fence so MetalFX waits for scene rendering to complete
            // This prevents race conditions where the scaler reads before the scene is written
            scaler.fence = fence
            
            scaler.encode(commandBuffer: commandBuffer)
        }
    }

    // MARK: - Texture Creation

    private func createTextures() throws {

        inputViews.removeAll(keepingCapacity: true)
        outputViews.removeAll(keepingCapacity: true)

        // Low-res color input (rendered into)
        let inputDesc = MTLTextureDescriptor()
        inputDesc.textureType = .type2DArray
        inputDesc.arrayLength = viewCount
        inputDesc.width = configuration.inputWidth
        inputDesc.height = configuration.inputHeight
        inputDesc.pixelFormat = configuration.colorFormat
        inputDesc.storageMode = .private
        inputDesc.usage = [.renderTarget, .shaderRead]

        guard let input = device.makeTexture(descriptor: inputDesc) else {
            throw Error.textureCreationFailed("input")
        }
        input.label = "MetalFX Input"
        inputTexture = input

        // Depth texture (REQUIRED for ASW / reprojection)
        let depthDesc = MTLTextureDescriptor()
        depthDesc.textureType = .type2DArray
        depthDesc.arrayLength = viewCount
        depthDesc.width = configuration.inputWidth
        depthDesc.height = configuration.inputHeight
        depthDesc.pixelFormat = configuration.depthFormat
        depthDesc.storageMode = .private
        depthDesc.usage = [.renderTarget, .shaderRead]

        guard let depth = device.makeTexture(descriptor: depthDesc) else {
            throw Error.textureCreationFailed("depth")
        }
        depth.label = "MetalFX Depth"
        depthTexture = depth

        // Upscaled output
        let outputDesc = MTLTextureDescriptor()
        outputDesc.textureType = .type2DArray
        outputDesc.arrayLength = viewCount
        outputDesc.width = configuration.outputWidth
        outputDesc.height = configuration.outputHeight
        outputDesc.pixelFormat = configuration.colorFormat
        outputDesc.storageMode = .private
        outputDesc.usage = [.shaderRead, .shaderWrite, .renderTarget]

        guard let output = device.makeTexture(descriptor: outputDesc) else {
            throw Error.textureCreationFailed("output")
        }
        output.label = "MetalFX Output"
        outputTexture = output

        // Cache per-eye views ONCE
        for eye in 0..<viewCount {
            guard
                let inView = input.makeTextureView(
                    pixelFormat: input.pixelFormat,
                    textureType: .type2D,
                    levels: 0..<1,
                    slices: eye..<(eye + 1)
                ),
                let outView = output.makeTextureView(
                    pixelFormat: output.pixelFormat,
                    textureType: .type2D,
                    levels: 0..<1,
                    slices: eye..<(eye + 1)
                )
            else {
                throw Error.textureViewFailed
            }

            inView.label = "MetalFX Input Eye \(eye)"
            outView.label = "MetalFX Output Eye \(eye)"

            inputViews.append(inView)
            outputViews.append(outView)
        }
    }

    // MARK: - Scaler Creation / Reuse

    private func createOrUpdateScalers(resolutionChanged: Bool) throws {

        if resolutionChanged {
            scalers.removeAll(keepingCapacity: true)
        }

        let descriptor = MTLFXSpatialScalerDescriptor()
        descriptor.inputWidth = configuration.inputWidth
        descriptor.inputHeight = configuration.inputHeight
        descriptor.outputWidth = configuration.outputWidth
        descriptor.outputHeight = configuration.outputHeight
        descriptor.colorTextureFormat = configuration.colorFormat
        descriptor.outputTextureFormat = configuration.colorFormat

        // MetalFX rejects non-perceptual processing whenever either side uses
        // an sRGB pixel format. The compositor drawable is bgra8Unorm_srgb, so
        // the scaler must stay in perceptual mode unless the whole MetalFX path
        // is moved to a linear intermediate format.
        for _ in scalers.count..<viewCount {
            descriptor.colorProcessingMode = .perceptual
            let scaler = descriptor.makeSpatialScaler(device: device)
            guard let scaler else { throw Error.scalerCreationFailed }
            scaler.inputContentWidth = configuration.inputWidth
            scaler.inputContentHeight = configuration.inputHeight
            scalers.append(scaler)
        }
    }
}
#endif
