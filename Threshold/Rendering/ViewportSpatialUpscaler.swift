#if (os(macOS) || os(iOS)) && canImport(MetalFX)
import Metal
import MetalFX

/// macOS-only MetalFX spatial upscaler operating on plain single-view 2D
/// textures (the shared `MetalFXManager` uses `type2DArray`/per-eye views for
/// the visionOS stereo path, which is awkward to reuse for the Mac renderer).
///
/// The Mac renderer draws the raymarch into a reduced-resolution offscreen
/// color+depth target, then this upscaler resolves it to the full drawable
/// resolution. Its temporal sibling (`ViewportTemporalUpscaler`) also consumes
/// depth + motion vectors; the texture-management shape here is intentionally
/// close so the two mirror each other.
///
/// Color textures stay in the drawable's `bgra8Unorm_srgb` format so the
/// raymarch pipeline state needs no changes; MetalFX runs in `.perceptual`
/// mode (required whenever an sRGB format is involved).
final class ViewportSpatialUpscaler {
    typealias Size = MetalFXSize

    /// MTLFXSpatialScaler rejects very small inputs; floor the shortest edge.
    static let minimumInputShortEdge = MetalFXTextureSupport.minimumInputShortEdge

    private let device: MTLDevice
    private let colorFormat: MTLPixelFormat
    private let depthFormat: MTLPixelFormat

    private(set) var inputSize = Size(width: 0, height: 0)
    private(set) var outputSize = Size(width: 0, height: 0)

    /// Low-resolution color target the raymarch renders into.
    private(set) var colorTexture: MTLTexture?
    /// Low-resolution depth target for the raymarch depth test (spatial scaling
    /// itself does not read depth, but the raymarch pass still needs one).
    private(set) var depthTexture: MTLTexture?
    /// Full-resolution upscaled output, sampled by the blit pass.
    private(set) var outputTexture: MTLTexture?

    private var scaler: MTLFXSpatialScaler?
    /// A rejected configuration is deterministic on a given scaler/device in
    /// normal operation. Remember it until the requested size changes instead
    /// of repeating descriptor creation and texture allocation every frame.
    private var failedInputSize: Size?
    private var failedOutputSize: Size?

    init(device: MTLDevice, colorFormat: MTLPixelFormat, depthFormat: MTLPixelFormat) {
        self.device = device
        self.colorFormat = colorFormat
        self.depthFormat = depthFormat
    }

    /// Prepares textures and the scaler for the requested sizes. Returns `true`
    /// when the upscaler is ready; returns `false` when the input is too small
    /// for MetalFX (or allocation/scaler creation failed), signalling the caller
    /// to fall back to direct full-resolution rendering.
    func prepare(inputWidth: Int, inputHeight: Int, outputWidth: Int, outputHeight: Int) -> Bool {
        guard min(inputWidth, inputHeight) >= Self.minimumInputShortEdge,
              outputWidth >= inputWidth,
              outputHeight >= inputHeight else {
            return false
        }

        let newInput = Size(width: inputWidth, height: inputHeight)
        let newOutput = Size(width: outputWidth, height: outputHeight)

        if newInput == inputSize,
           newOutput == outputSize,
           colorTexture != nil,
           depthTexture != nil,
           outputTexture != nil,
           scaler != nil {
            return true
        }

        if failedInputSize == newInput, failedOutputSize == newOutput {
            return false
        }

        inputSize = newInput
        outputSize = newOutput
        let ready = rebuild()
        if ready {
            failedInputSize = nil
            failedOutputSize = nil
        } else {
            failedInputSize = newInput
            failedOutputSize = newOutput
        }
        return ready
    }

    private func rebuild() -> Bool {
        let descriptor = MTLFXSpatialScalerDescriptor()
        descriptor.inputWidth = inputSize.width
        descriptor.inputHeight = inputSize.height
        descriptor.outputWidth = outputSize.width
        descriptor.outputHeight = outputSize.height
        descriptor.colorTextureFormat = colorFormat
        descriptor.outputTextureFormat = colorFormat
        // sRGB formats require perceptual processing (same constraint the
        // visionOS `MetalFXManager` documents). Float formats carry LINEAR
        // extended-range (EDR) data — `.hdr` makes the scaler apply its own
        // reversible tonemap internally instead of misreading >1 energy as
        // perceptual values.
        switch colorFormat {
        case .rgba16Float, .bgra10_xr, .bgra10_xr_srgb, .rg11b10Float:
            descriptor.colorProcessingMode = .hdr
        default:
            descriptor.colorProcessingMode = .perceptual
        }

        guard let made = descriptor.makeSpatialScaler(device: device) else {
            print("❌ Mac MetalFX makeSpatialScaler failed: input=\(inputSize.width)x\(inputSize.height) output=\(outputSize.width)x\(outputSize.height)")
            scaler = nil
            return false
        }

        // MetalFX reports the minimum usage flags required by this concrete
        // scaler/device. Union those with the app's render/read roles instead of
        // assuming its internal encoder implementation is identical on every OS.
        var colorUsage = made.colorTextureUsage
        colorUsage.formUnion([.renderTarget, .shaderRead])
        var outputUsage = made.outputTextureUsage
        outputUsage.formUnion([.renderTarget, .shaderRead])

        colorTexture = makeTexture(width: inputSize.width,
                                   height: inputSize.height,
                                   format: colorFormat,
                                   usage: colorUsage,
                                   label: "Mac Upscale Input")
        depthTexture = makeTexture(width: inputSize.width,
                                   height: inputSize.height,
                                   format: depthFormat,
                                   usage: [.renderTarget],
                                   label: "Mac Upscale Depth")
        outputTexture = makeTexture(width: outputSize.width,
                                    height: outputSize.height,
                                    format: colorFormat,
                                    usage: outputUsage,
                                    label: "Mac Upscale Output")

        guard colorTexture != nil, depthTexture != nil, outputTexture != nil else {
            scaler = nil
            return false
        }

        made.inputContentWidth = inputSize.width
        made.inputContentHeight = inputSize.height
        scaler = made
        return true
    }

    /// Encodes the spatial upscale (`colorTexture` → `outputTexture`).
    func encode(commandBuffer: MTLCommandBuffer) {
        guard let scaler, let colorTexture, let outputTexture else { return }
        scaler.colorTexture = colorTexture
        scaler.outputTexture = outputTexture
        scaler.encode(commandBuffer: commandBuffer)
    }

    private func makeTexture(width: Int,
                             height: Int,
                             format: MTLPixelFormat,
                             usage: MTLTextureUsage,
                             label: String) -> MTLTexture? {
        MetalFXTextureSupport.makeTexture(device: device,
                                          width: width,
                                          height: height,
                                          format: format,
                                          usage: usage,
                                          depthFormat: depthFormat,
                                          label: label)
    }
}
#endif
