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

    /// Cached scaler + textures for one size configuration. The adaptive-
    /// resolution controller oscillates between a handful of discrete render
    /// scales under fluctuating load; pooling lets `prepare()` reuse a prior
    /// build instead of reallocating textures and reconstructing the MetalFX
    /// scaler (tens of ms, on the render thread) every time it revisits a size.
    private struct PoolEntry {
        let inputSize: Size
        let outputSize: Size
        let colorTexture: MTLTexture
        let depthTexture: MTLTexture
        let motionTexture: MTLTexture
        let outputTexture: MTLTexture
        let scaler: MTLFXTemporalScaler
        var lastUsedFrame: Int
    }

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

    /// LRU pool of pre-built scaler configurations, keyed by (input, output)
    /// size. Bounded so revisited render scales reuse a build instead of
    /// reallocating. Accessed on the render thread only — no lock required.
    private var scalerPool: [PoolEntry] = []
    /// Capped low: each entry pins full-resolution output + MetalFX history
    /// textures, so VRAM scales with this count. The adaptive controller hovers
    /// in a narrow band of scales, so a few slots capture typical oscillation;
    /// rarer excursions just rebuild (one hitch) and re-pool.
    private let maxPoolSize = 4
    private var poolFrameCounter = 0

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

        let previousOutput = outputSize
        inputSize = newInput
        outputSize = newOutput

        // A changed output size (e.g. a window resize) invalidates every pooled
        // entry — each holds full-resolution textures sized for the old output.
        // Drop them so VRAM isn't pinned at the stale resolution.
        if newOutput != previousOutput {
            scalerPool.removeAll()
        }

        // Pool hit: reuse a previously-built scaler + textures for this size
        // instead of reallocating and reconstructing the MetalFX scaler.
        if let idx = scalerPool.firstIndex(where: { $0.inputSize == newInput && $0.outputSize == newOutput }) {
            let entry = scalerPool[idx]
            colorTexture = entry.colorTexture
            depthTexture = entry.depthTexture
            motionTexture = entry.motionTexture
            outputTexture = entry.outputTexture
            scaler = entry.scaler
            // Force a history reset: this scaler's accumulated history is from the
            // last time this size was active (frames ago, different camera pose),
            // so reusing it without a reset risks ghosting. A reset costs a frame
            // or two of reduced detail — far cheaper than a rebuild's stall.
            needsReset = true
            poolFrameCounter += 1
            scalerPool[idx].lastUsedFrame = poolFrameCounter
            return true
        }

        // Pool miss: rebuild, then cache the result for future reuse.
        let success = rebuild()
        if success,
           let colorTexture,
           let depthTexture,
           let motionTexture,
           let outputTexture,
           let scaler {
            poolFrameCounter += 1
            scalerPool.append(PoolEntry(
                inputSize: newInput,
                outputSize: newOutput,
                colorTexture: colorTexture,
                depthTexture: depthTexture,
                motionTexture: motionTexture,
                outputTexture: outputTexture,
                scaler: scaler,
                lastUsedFrame: poolFrameCounter
            ))
            if scalerPool.count > maxPoolSize {
                // Evict the least-recently-used entry. The just-appended entry has
                // the highest `lastUsedFrame`, so it is never the one evicted.
                scalerPool.sort { $0.lastUsedFrame < $1.lastUsedFrame }
                scalerPool.removeFirst()
            }
        }
        return success
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

        // Set reset BEFORE textures: newer MetalFX SDK versions clear tracked
        // texture state when reset=true, so textures must be (re-)assigned after.
        scaler.reset = needsReset || forceReset
        needsReset = false

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
