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
        case scalerCreationFailed(inputWidth: Int, inputHeight: Int, outputWidth: Int, outputHeight: Int)
        case missingTextures
        case textureViewFailed
        case inputTooSmall(width: Int, height: Int, minimum: Int)

        var description: String {
            switch self {
            case .textureCreationFailed(let name):
                return "Failed to create \(name) texture"
            case .scalerCreationFailed(let iw, let ih, let ow, let oh):
                return "Failed to create spatial scaler (input=\(iw)x\(ih) output=\(ow)x\(oh)). Likely below MTLFXSpatialScaler minimum size."
            case .missingTextures:
                return "MetalFX textures not ready"
            case .textureViewFailed:
                return "Failed to create eye texture view"
            case .inputTooSmall(let w, let h, let minimum):
                return "MetalFX input too small (\(w)x\(h)); shortest edge must be >= \(minimum)"
            }
        }
    }

    // MARK: - Constants

    /// MTLFXSpatialScaler does not officially document a minimum input size,
    /// but empirically rejects (or asserts on) very small inputs. Floor the
    /// shortest edge to a safe value and require `outputWidth >= inputWidth`
    /// (and same for height) to avoid degenerate descriptors.
    static let minimumInputShortEdge: Int = 128
    static let minimumInputLongEdge: Int = 192

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

    // Phase 2.9: 2-slot pool. When the user drags the resolution slider, values
    // often oscillate between two adjacent buckets (e.g. 0.65 ↔ 0.66). Stashing
    // the previous full snapshot (textures + scalers + viewCount) lets us swap
    // back instead of rebuilding both halves.
    private struct PooledSnapshot {
        var configuration: Configuration
        var viewCount: Int
        var scalers: [MTLFXSpatialScaler]
        var inputTexture: MTLTexture?
        var depthTexture: MTLTexture?
        var outputTexture: MTLTexture?
        var inputViews: [MTLTexture]
        var outputViews: [MTLTexture]
    }
    private var pooledSnapshot: PooledSnapshot?

    private func captureSnapshot() -> PooledSnapshot {
        PooledSnapshot(
            configuration: configuration,
            viewCount: viewCount,
            scalers: scalers,
            inputTexture: inputTexture,
            depthTexture: depthTexture,
            outputTexture: outputTexture,
            inputViews: inputViews,
            outputViews: outputViews
        )
    }

    private func restoreSnapshot(_ snap: PooledSnapshot) {
        configuration = snap.configuration
        viewCount = snap.viewCount
        scalers = snap.scalers
        inputTexture = snap.inputTexture
        depthTexture = snap.depthTexture
        outputTexture = snap.outputTexture
        inputViews = snap.inputViews
        outputViews = snap.outputViews
    }

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

        // Phase 2.9: pool swap. If the incoming config matches the stashed
        // snapshot, swap them instead of rebuilding.
        if resolutionChanged || viewCountChanged,
           let snap = pooledSnapshot,
           snap.configuration.inputWidth  == configuration.inputWidth,
           snap.configuration.inputHeight == configuration.inputHeight,
           snap.configuration.outputWidth == configuration.outputWidth,
           snap.configuration.outputHeight == configuration.outputHeight,
           snap.configuration.colorFormat == configuration.colorFormat,
           snap.configuration.depthFormat == configuration.depthFormat,
           snap.viewCount == newViewCount {
            let current = captureSnapshot()
            restoreSnapshot(snap)
            // Adopt the new (non-size) config fields like `scale`.
            self.configuration = configuration
            pooledSnapshot = current
            try createOrUpdateScalers(resolutionChanged: false)
            return
        }

        if resolutionChanged || viewCountChanged {
            // Stash current state before rebuilding so the next swap may hit.
            pooledSnapshot = captureSnapshot()
        }

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
        // Phase 2.8: Drop `.shaderWrite` — MTLFXSpatialScaler writes via its
        // internal render-encoder path on visionOS 1+/iOS 17+, so the public
        // texture only needs `.renderTarget` for the scaler write and
        // `.shaderRead` for the downstream resolve sample. Removing
        // `.shaderWrite` lets Metal enable lossless framebuffer compression on
        // this texture (~1.5–3 MB / eye saved + reduced bandwidth).
        outputDesc.usage = [.shaderRead, .renderTarget]

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
        descriptor.colorProcessingMode = .perceptual

        // Append any new scalers required to match viewCount.
        for _ in scalers.count..<viewCount {
            guard let scaler = descriptor.makeSpatialScaler(device: device) else {
                // Unconditional log so production crash reports point at the
                // exact size combo that tripped MTLFXSpatialScaler.
                print("❌ MetalFX makeSpatialScaler failed: input=\(configuration.inputWidth)x\(configuration.inputHeight) output=\(configuration.outputWidth)x\(configuration.outputHeight) format=\(configuration.colorFormat.rawValue)")
                throw Error.scalerCreationFailed(
                    inputWidth: configuration.inputWidth,
                    inputHeight: configuration.inputHeight,
                    outputWidth: configuration.outputWidth,
                    outputHeight: configuration.outputHeight
                )
            }
            scalers.append(scaler)
        }

        // Always (re)assign content sizes — including for reused scalers — so a
        // resolution change applied to existing scalers is honored. Previously
        // these were only set on creation, so reused scalers retained stale
        // content dimensions when only a subset of the configuration changed.
        for index in 0..<min(viewCount, scalers.count) {
            scalers[index].inputContentWidth = configuration.inputWidth
            scalers[index].inputContentHeight = configuration.inputHeight
        }
    }
}
#endif
