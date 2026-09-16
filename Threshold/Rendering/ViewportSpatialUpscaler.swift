#if (os(macOS) || os(iOS)) && canImport(MetalFX)
import Dispatch
import Metal
import MetalFX
import Synchronization

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
///
/// Scaler construction is EXPENSIVE — `makeSpatialScaler` blocks its thread
/// (the temporal sibling measured 0.2–2 s per size) and this class used to pay
/// it on the render thread — the MAIN thread on iPad, where temporal scaling is
/// disabled — on every pool miss (each step of a Render Quality drag or a live
/// window resize is a fresh size, so a drag was a hitch storm). Builds now run
/// on ONE private serial queue, coalesced latest-wins: until the requested
/// size lands, `prepare` returns `false` so the caller renders
/// direct-full-resolution (or an exact-size temporal pass when enabled) for
/// those frames — the same contract the temporal port documented.
///
/// Thread shape: `prepare`/`encode` are render-thread calls; the exposed
/// texture properties are render-thread-only mirrors of the active pooled
/// entry. All cross-thread state lives under one Mutex.
/// AUDIT — @unchecked Sendable: the Mutex guards everything the build queue
/// touches; the exposed `MTLTexture` vars are written in `prepare` and read
/// by the render thread within the same frame.
final class ViewportSpatialUpscaler: @unchecked Sendable {
    typealias Size = MetalFXSize

    /// MTLFXSpatialScaler rejects very small inputs; floor the shortest edge.
    static let minimumInputShortEdge = MetalFXTextureSupport.minimumInputShortEdge

    /// One ready configuration: the scaler plus every texture it owns.
    /// AUDIT — @unchecked: immutable references to Metal objects (documented
    /// thread-safe); the scaler's mutable per-encode properties are only
    /// touched by the render thread (encode).
    private struct Pass: @unchecked Sendable {
        let colorTexture: MTLTexture
        let depthTexture: MTLTexture
        let outputTexture: MTLTexture
        let scaler: MTLFXSpatialScaler
    }

    private struct Key: Hashable, Sendable {
        let inW: Int, inH: Int, outW: Int, outH: Int
    }

    private struct Entry: Sendable {
        let pass: Pass
        var lastUsed: Int
    }

    private struct State: Sendable {
        /// LRU pool of built scaler configurations. Bounded: each entry pins
        /// full-resolution output textures.
        var entries: [Key: Entry] = [:]
        /// Descriptor/allocation failures are negative-cached so an
        /// unsupported configuration is not rebuilt every frame.
        var failedKeys: Set<Key> = []
        var useCounter = 0
        /// The key `prepare` last returned — the render-thread mirrors follow.
        var activeKey: Key?
        /// The most recent requested output size; a completed build for a
        /// stale output (mid-resize) is discarded on arrival.
        var currentOutput = SIMD2<Int>(0, 0)
        /// The newest missing key (latest-wins: a drag's intermediate sizes
        /// overwrite each other here; only what's still wanted gets built).
        var wanted: Key?
        /// Whether the builder loop is live on `buildQueue`.
        var draining = false
    }

    private let device: MTLDevice
    private let colorFormat: MTLPixelFormat
    private let depthFormat: MTLPixelFormat
    private let state = Mutex<State>(State())
    private let maxPoolSize = 4
    /// The one thread scaler builds may occupy (see header). Builds must NOT
    /// run on the Swift cooperative pool: `makeSpatialScaler` blocks its
    /// thread, and under Xcode's Metal diagnostics blocked cooperative threads
    /// can wedge the whole app.
    private let buildQueue = DispatchQueue(
        label: "com.polinate.threshold.mac-mfx-spatial-build", qos: .userInitiated)

    // Render-thread mirrors of the active pooled entry (what `prepare` chose
    // this frame). Same surface the caller has always consumed.
    private(set) var inputSize = Size(width: 0, height: 0)
    private(set) var outputSize = Size(width: 0, height: 0)
    /// Low-resolution color target the raymarch renders into.
    private(set) var colorTexture: MTLTexture?
    /// Low-resolution depth target for the raymarch depth test (spatial scaling
    /// itself does not read depth, but the raymarch pass still needs one).
    private(set) var depthTexture: MTLTexture?
    /// Full-resolution upscaled output, sampled by the blit pass.
    private(set) var outputTexture: MTLTexture?

    init(device: MTLDevice, colorFormat: MTLPixelFormat, depthFormat: MTLPixelFormat) {
        self.device = device
        self.colorFormat = colorFormat
        self.depthFormat = depthFormat
    }

    /// Prepares textures and the scaler for the requested sizes. Returns `true`
    /// only when the EXACT requested configuration is ready; returns `false`
    /// while a missing configuration builds in the background (caller falls
    /// back to direct full-resolution rendering) or when the input is too
    /// small for MetalFX. Never blocks.
    func prepare(inputWidth: Int, inputHeight: Int, outputWidth: Int, outputHeight: Int) -> Bool {
        guard min(inputWidth, inputHeight) >= Self.minimumInputShortEdge,
              outputWidth >= inputWidth,
              outputHeight >= inputHeight else {
            state.withLock { $0.activeKey = nil }
            clearActiveMirrors()
            return false
        }

        let key = Key(inW: inputWidth, inH: inputHeight,
                      outW: outputWidth, outH: outputHeight)
        let (pass, startDrain) = state.withLock { s -> (Pass?, Bool) in
            s.useCounter += 1
            // A changed output size (window resize) strands every pooled
            // entry's full-resolution textures — drop them all.
            let out = SIMD2(outputWidth, outputHeight)
            if s.currentOutput != out {
                s.currentOutput = out
                s.entries.removeAll()
                s.failedKeys.removeAll()
            }

            if let entry = s.entries[key] {
                var entry = entry
                entry.lastUsed = s.useCounter
                s.entries[key] = entry
                s.activeKey = key
                // This exact ready entry is the newest request; do not leave
                // an older queued size behind it.
                s.wanted = nil
                return (entry.pass, false)
            }

            if s.failedKeys.contains(key) {
                s.wanted = nil
                s.activeKey = nil
                return (nil, false)
            }

            // Miss: latest-wins — overwrite whatever stale size a fast drag
            // left here. If the builder is ALREADY on this exact key, clear
            // any older queued size; the in-flight result is what is wanted.
            var startDrain = false
            s.wanted = key
            if !s.draining {
                s.draining = true
                startDrain = true
            }

            // Do not substitute a differently-sized pass: the caller renders
            // direct full-resolution while the exact-size build completes.
            s.activeKey = nil
            return (nil, startDrain)
        }

        if startDrain {
            buildQueue.async { [self] in drainBuilds() }
        }
        guard let pass else {
            clearActiveMirrors()
            return false
        }
        inputSize = Size(width: pass.colorTexture.width, height: pass.colorTexture.height)
        outputSize = Size(width: pass.outputTexture.width, height: pass.outputTexture.height)
        colorTexture = pass.colorTexture
        depthTexture = pass.depthTexture
        outputTexture = pass.outputTexture
        return true
    }

    private func clearActiveMirrors() {
        colorTexture = nil
        depthTexture = nil
        outputTexture = nil
        inputSize = Size(width: 0, height: 0)
        outputSize = Size(width: 0, height: 0)
    }

    /// The builder loop (buildQueue only): take the newest wanted key, build
    /// it, publish, repeat until nothing is wanted. Builds superseded
    /// mid-compile still publish into the bounded pool so revisiting that
    /// exact size is instant, but a key whose OUTPUT went stale (resize) is
    /// dropped.
    private func drainBuilds() {
        while true {
            let next: Key? = state.withLock { s in
                guard let key = s.wanted,
                      s.currentOutput == SIMD2(key.outW, key.outH) else {
                    s.wanted = nil
                    s.draining = false
                    return nil
                }
                s.wanted = nil
                return key
            }
            guard let key = next else { return }

            if let built = build(key: key) {
                state.withLock { s in
                    // Discard a build that raced a resize (stale output).
                    guard s.currentOutput == SIMD2(key.outW, key.outH) else { return }
                    s.failedKeys.remove(key)
                    s.entries[key] = Entry(pass: built, lastUsed: s.useCounter)
                    if s.entries.count > maxPoolSize,
                       let evict = s.entries
                           .filter({ $0.key != s.activeKey })
                           .min(by: { $0.value.lastUsed < $1.value.lastUsed }) {
                        s.entries.removeValue(forKey: evict.key)
                    }
                }
            } else {
                state.withLock { s in
                    guard s.currentOutput == SIMD2(key.outW, key.outH) else { return }
                    s.failedKeys.insert(key)
                }
            }
        }
    }

    private func build(key: Key) -> Pass? {
        let descriptor = MTLFXSpatialScalerDescriptor()
        descriptor.inputWidth = key.inW
        descriptor.inputHeight = key.inH
        descriptor.outputWidth = key.outW
        descriptor.outputHeight = key.outH
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
            print("❌ Mac MetalFX makeSpatialScaler failed: input=\(key.inW)x\(key.inH) output=\(key.outW)x\(key.outH)")
            return nil
        }

        // MetalFX reports the minimum usage flags required by this concrete
        // scaler/device. Union those with the app's render/read roles instead of
        // assuming its internal encoder implementation is identical on every OS.
        var colorUsage = made.colorTextureUsage
        colorUsage.formUnion([.renderTarget, .shaderRead])
        var outputUsage = made.outputTextureUsage
        outputUsage.formUnion([.renderTarget, .shaderRead])

        guard
            let color = makeTexture(width: key.inW, height: key.inH,
                                    format: colorFormat,
                                    usage: colorUsage,
                                    label: "Mac Upscale Input"),
            let depth = makeTexture(width: key.inW, height: key.inH,
                                    format: depthFormat,
                                    usage: [.renderTarget],
                                    label: "Mac Upscale Depth"),
            let output = makeTexture(width: key.outW, height: key.outH,
                                     format: colorFormat,
                                     usage: outputUsage,
                                     label: "Mac Upscale Output")
        else {
            return nil
        }

        made.inputContentWidth = key.inW
        made.inputContentHeight = key.inH
        return Pass(colorTexture: color,
                    depthTexture: depth,
                    outputTexture: output,
                    scaler: made)
    }

    /// Encodes the spatial upscale (`colorTexture` → `outputTexture`).
    func encode(commandBuffer: MTLCommandBuffer) {
        guard let pass = state.withLock({ s in s.activeKey.flatMap { s.entries[$0]?.pass } }),
              let colorTexture, let outputTexture else { return }
        pass.scaler.colorTexture = colorTexture
        pass.scaler.outputTexture = outputTexture
        pass.scaler.encode(commandBuffer: commandBuffer)
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