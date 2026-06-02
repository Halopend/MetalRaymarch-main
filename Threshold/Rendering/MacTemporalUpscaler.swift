#if os(macOS) || os(iOS)
import Metal
import MetalFX
import simd

/// macOS-only MetalFX *temporal* upscaler — the Stage B sibling of
/// `MacSpatialUpscaler`. Where the spatial scaler resolves a single frame, the
/// temporal scaler accumulates sub-pixel-jittered history using a depth buffer
/// and per-pixel motion vectors, giving markedly better stability/detail at low
/// render scales.
///
/// To stay low-risk this reuses the same color format the raymarch already
/// renders (`bgra8Unorm_srgb`) instead of forcing the raymarch pipelines to a
/// linear HDR variant. `MTLFXTemporalScaler` accepts the format; if a given
/// driver/format combination rejects it, `prepare` returns `false` and the
/// caller falls back to the spatial scaler (or direct render).
final class MacTemporalUpscaler {
    typealias Size = MetalFXSize

    static let minimumInputShortEdge = MetalFXTextureSupport.minimumInputShortEdge
    static let motionFormat: MTLPixelFormat = .rg16Float
    /// MetalFX temporal scaling supports at most 3× per dimension. Inputs below
    /// `output / maxScaleFactor` are rejected (caller falls back to spatial).
    static let maxScaleFactor = 3.0

    private let device: MTLDevice
    private let colorFormat: MTLPixelFormat
    private let depthFormat: MTLPixelFormat
    /// The MetalFX output is written via compute, which sRGB pixel formats do
    /// not support on Apple Silicon. Use the non-sRGB twin (same bit layout);
    /// the blit samples it without sRGB decode and writes to the sRGB drawable,
    /// so the linear round-trip matches the spatial path.
    private let outputFormat: MTLPixelFormat

    private(set) var inputSize = Size(width: 0, height: 0)
    private(set) var outputSize = Size(width: 0, height: 0)

    /// Low-resolution color target the raymarch renders into.
    private(set) var colorTexture: MTLTexture?
    /// Low-resolution depth (sampled by the motion pass and read by the scaler).
    private(set) var depthTexture: MTLTexture?
    /// Screen-space motion vectors produced by the motion pass.
    private(set) var motionTexture: MTLTexture?
    /// Full-resolution upscaled output, sampled by the blit pass.
    private(set) var outputTexture: MTLTexture?

    private var scaler: MTLFXTemporalScaler?

    /// Set true the first frame after a (re)build so the scaler discards stale
    /// history; the caller can also force it on camera cuts / view resets.
    private var needsReset = true

    init(device: MTLDevice, colorFormat: MTLPixelFormat, depthFormat: MTLPixelFormat) {
        self.device = device
        self.colorFormat = colorFormat
        self.depthFormat = depthFormat
        self.outputFormat = Self.writableTwin(of: colorFormat)
    }

    /// Maps an sRGB pixel format to its writable non-sRGB equivalent (same bit
    /// layout). Non-sRGB formats are returned unchanged.
    private static func writableTwin(of format: MTLPixelFormat) -> MTLPixelFormat {
        switch format {
        case .bgra8Unorm_srgb: return .bgra8Unorm
        case .rgba8Unorm_srgb: return .rgba8Unorm
        default: return format
        }
    }

    /// Prepares textures and the scaler for the requested sizes. Returns `true`
    /// when ready; `false` when the input is too small or temporal scaling is
    /// unsupported for this configuration (caller should fall back).
    func prepare(inputWidth: Int, inputHeight: Int, outputWidth: Int, outputHeight: Int) -> Bool {
        guard min(inputWidth, inputHeight) >= Self.minimumInputShortEdge,
              outputWidth >= inputWidth,
              outputHeight >= inputHeight,
              Double(outputWidth) <= Double(inputWidth) * Self.maxScaleFactor,
              Double(outputHeight) <= Double(inputHeight) * Self.maxScaleFactor else {
            return false
        }

        let newInput = Size(width: inputWidth, height: inputHeight)
        let newOutput = Size(width: outputWidth, height: outputHeight)

        if newInput == inputSize,
           newOutput == outputSize,
           colorTexture != nil,
           depthTexture != nil,
           motionTexture != nil,
           outputTexture != nil,
           scaler != nil {
            return true
        }

        inputSize = newInput
        outputSize = newOutput
        return rebuild()
    }

    /// Forces the next encode to reset accumulated history (e.g. view reset).
    func requestReset() {
        needsReset = true
    }

    private func rebuild() -> Bool {
        guard MTLFXTemporalScalerDescriptor.supportsDevice(device) else {
            scaler = nil
            return false
        }

        colorTexture = makeTexture(width: inputSize.width,
                                   height: inputSize.height,
                                   format: colorFormat,
                                   usage: [.renderTarget, .shaderRead],
                                   label: "Mac Temporal Color")
        depthTexture = makeTexture(width: inputSize.width,
                                   height: inputSize.height,
                                   format: depthFormat,
                                   usage: [.renderTarget, .shaderRead],
                                   label: "Mac Temporal Depth")
        motionTexture = makeTexture(width: inputSize.width,
                                    height: inputSize.height,
                                    format: Self.motionFormat,
                                    usage: [.renderTarget, .shaderRead],
                                    label: "Mac Temporal Motion")
        outputTexture = makeTexture(width: outputSize.width,
                                    height: outputSize.height,
                                    format: outputFormat,
                                    usage: [.shaderRead, .shaderWrite],
                                    label: "Mac Temporal Output")

        guard colorTexture != nil, depthTexture != nil,
              motionTexture != nil, outputTexture != nil else {
            scaler = nil
            return false
        }

        let descriptor = MTLFXTemporalScalerDescriptor()
        descriptor.inputWidth = inputSize.width
        descriptor.inputHeight = inputSize.height
        descriptor.outputWidth = outputSize.width
        descriptor.outputHeight = outputSize.height
        descriptor.colorTextureFormat = colorFormat
        descriptor.depthTextureFormat = depthFormat
        descriptor.motionTextureFormat = Self.motionFormat
        descriptor.outputTextureFormat = outputFormat

        guard let made = descriptor.makeTemporalScaler(device: device) else {
            print("❌ Mac MetalFX makeTemporalScaler failed: input=\(inputSize.width)x\(inputSize.height) output=\(outputSize.width)x\(outputSize.height)")
            scaler = nil
            return false
        }
        // Raymarch depth is standard 0 (near) … 1 (far) — not reversed.
        made.isDepthReversed = false
        scaler = made
        needsReset = true
        return true
    }

    /// Encodes the temporal upscale. `jitterPixels` is the sub-pixel offset that
    /// was applied to the projection this frame (input-pixel units);
    /// `forceReset` discards history (camera cut / view reset).
    func encode(commandBuffer: MTLCommandBuffer,
                jitterPixels: SIMD2<Float>,
                forceReset: Bool) {
        guard let scaler,
              let colorTexture,
              let depthTexture,
              let motionTexture,
              let outputTexture else { return }

        scaler.colorTexture = colorTexture
        scaler.depthTexture = depthTexture
        scaler.motionTexture = motionTexture
        scaler.outputTexture = outputTexture
        scaler.inputContentWidth = inputSize.width
        scaler.inputContentHeight = inputSize.height
        // MetalFX expects the jitter offset that shifts samples relative to the
        // pixel center, in input pixels.
        scaler.jitterOffsetX = jitterPixels.x
        scaler.jitterOffsetY = jitterPixels.y
        // Motion vectors are stored as UV-space deltas; scale to input pixels.
        scaler.motionVectorScaleX = Float(inputSize.width)
        scaler.motionVectorScaleY = Float(inputSize.height)
        scaler.reset = needsReset || forceReset
        needsReset = false

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
