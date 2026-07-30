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
    private(set) var outputTexture: MTLTexture?

    // Ping-pong depth pair for the temporal march warm-start: the fragment pass
    // renders depth into one while the shader samples the other (last frame's).
    private var depthTextures: [MTLTexture] = []
    private var depthWriteIndex = 0
    /// False until a frame has actually been rendered into the previous slot
    /// (fresh textures contain garbage).
    private(set) var depthHistoryValid = false

    /// Current frame's depth render target.
    var depthTexture: MTLTexture? {
        depthTextures.isEmpty ? nil : depthTextures[depthWriteIndex]
    }

    /// Previous frame's depth (valid only when `depthHistoryValid`).
    var previousDepthTexture: MTLTexture? {
        depthTextures.count == 2 ? depthTextures[1 - depthWriteIndex] : nil
    }

    /// Call once per frame after all passes reading the current depth have been
    /// encoded. Makes this frame's depth next frame's history.
    func advanceDepthHistory() {
        guard depthTextures.count == 2 else { return }
        depthHistoryValid = true
        depthWriteIndex = 1 - depthWriteIndex
    }

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
        var depthTextures: [MTLTexture]
        var outputTexture: MTLTexture?
        var inputViews: [MTLTexture]
        var outputViews: [MTLTexture]
    }
    private var pooledSnapshot: PooledSnapshot?

    private static let pooledTextureBudgetBytes = 160 * 1024 * 1024

    static func estimatedBytesPerPixel(for format: MTLPixelFormat) -> Int {
        switch format {
        case .rgba16Float, .rgba16Unorm, .rgba16Snorm, .rgba16Uint, .rgba16Sint:
            return 8
        case .rgba32Float, .rgba32Uint, .rgba32Sint:
            return 16
        case .r32Float, .r32Uint, .r32Sint,
             .depth32Float, .depth32Float_stencil8,
             .bgra8Unorm, .bgra8Unorm_srgb,
             .rgba8Unorm, .rgba8Unorm_srgb, .rgba8Snorm, .rgba8Uint, .rgba8Sint:
            return 4
        case .r16Float, .r16Unorm, .r16Snorm, .r16Uint, .r16Sint,
             .rg8Unorm, .rg8Snorm, .rg8Uint, .rg8Sint:
            return 2
        case .r8Unorm, .r8Snorm, .r8Uint, .r8Sint:
            return 1
        default:
            return 8
        }
    }

    private static func estimatedTextureBytes(configuration: Configuration, viewCount: Int) -> Int {
        let views = max(1, viewCount)
        let inputPixels = max(1, configuration.inputWidth) * max(1, configuration.inputHeight) * views
        let outputPixels = max(1, configuration.outputWidth) * max(1, configuration.outputHeight) * views
        let colorBytes = estimatedBytesPerPixel(for: configuration.colorFormat)
        let depthBytes = estimatedBytesPerPixel(for: configuration.depthFormat)

        // Input color + two input-depth history textures + output color.
        return inputPixels * (colorBytes + depthBytes + depthBytes) + outputPixels * colorBytes
    }

    private func captureSnapshot() -> PooledSnapshot {
        PooledSnapshot(
            configuration: configuration,
            viewCount: viewCount,
            scalers: scalers,
            inputTexture: inputTexture,
            depthTextures: depthTextures,
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
        depthTextures = snap.depthTextures
        outputTexture = snap.outputTexture
        inputViews = snap.inputViews
        outputViews = snap.outputViews
        // Restored textures hold stale frames — depth history must re-prime.
        depthWriteIndex = 0
        depthHistoryValid = false
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
            // Stash current state before rebuilding so the next swap may hit, but
            // never keep two large texture sets around on Vision Pro memory paths.
            let currentBytes = Self.estimatedTextureBytes(configuration: self.configuration, viewCount: self.viewCount)
            let nextBytes = Self.estimatedTextureBytes(configuration: configuration, viewCount: newViewCount)
            pooledSnapshot = (currentBytes + nextBytes) <= Self.pooledTextureBudgetBytes
                ? captureSnapshot()
                : nil
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

        // Depth textures (REQUIRED for ASW / reprojection; ping-pong pair so the
        // raymarch can warm-start from last frame's depth while writing this one)
        let depthDesc = MTLTextureDescriptor()
        depthDesc.textureType = .type2DArray
        depthDesc.arrayLength = viewCount
        depthDesc.width = configuration.inputWidth
        depthDesc.height = configuration.inputHeight
        depthDesc.pixelFormat = configuration.depthFormat
        depthDesc.storageMode = .private
        depthDesc.usage = [.renderTarget, .shaderRead]

        depthTextures = (0..<2).compactMap { i in
            let t = device.makeTexture(descriptor: depthDesc)
            t?.label = "MetalFX Depth \(i)"
            return t
        }
        guard depthTextures.count == 2 else {
            throw Error.textureCreationFailed("depth")
        }
        depthWriteIndex = 0
        depthHistoryValid = false

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
        // an sRGB pixel format, so sRGB drawables must stay perceptual. Float
        // formats carry LINEAR extended-range (EDR) data — `.hdr` makes the
        // scaler apply its own reversible tonemap internally instead of
        // misreading >1 energy as perceptual values (same switch as the Mac
        // `ViewportSpatialUpscaler`).
        switch configuration.colorFormat {
        case .rgba16Float, .bgra10_xr, .bgra10_xr_srgb, .rg11b10Float:
            descriptor.colorProcessingMode = .hdr
        default:
            descriptor.colorProcessingMode = .perceptual
        }

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
