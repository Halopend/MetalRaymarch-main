#if os(macOS) || os(iOS)
import Dispatch
import Metal
import MetalFX
import Synchronization
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
///
/// Scaler construction is EXPENSIVE — `makeTemporalScaler` blocks its thread
/// for a measured 0.2–2 s per size — and this class used to pay it on the
/// render thread on every pool miss (each step of a Render Quality drag or a
/// live window resize is a fresh size, so a drag was a hitch storm). Builds
/// now run on ONE private serial queue, coalesced latest-wins: until the
/// requested size lands, `prepare` returns the nearest READY size (or `false`
/// → the caller's spatial/direct fallback), so a resolution change costs zero
/// render-thread stalls. This mirrors ThresholdKit's TemporalUpscaler, which
/// was originally ported FROM this file and grew the async build; the fix is
/// ported back.
///
/// Builds must NOT run on the Swift cooperative pool: the compile blocks its
/// thread, sizes arrive faster than builds finish, and under Xcode's Metal
/// diagnostics (GPU capture / HUD / API validation) `makeTemporalScaler` can
/// wedge in dispatch_group_wait indefinitely — enough concurrent blocked
/// builds would strand every cooperative thread in the app. A wedged build on
/// the private queue strands only that queue; `prepare` keeps serving the
/// nearest ready size and logs the stall once instead of freezing.
///
/// Thread shape: `prepare`/`encode`/`requestReset` are render-thread calls;
/// the exposed texture properties are render-thread-only mirrors of the
/// active pooled entry. All cross-thread state lives under one Mutex.
/// AUDIT — @unchecked Sendable: the Mutex guards everything the build queue
/// touches; the exposed `MTLTexture` vars are written in `prepare` and read
/// by the render thread within the same frame.
final class MacTemporalUpscaler: @unchecked Sendable {
    typealias Size = MetalFXSize

    static let minimumInputShortEdge = MetalFXTextureSupport.minimumInputShortEdge
    static let motionFormat: MTLPixelFormat = .rg16Float
    /// MetalFX temporal scaling supports at most 3× per dimension. Inputs below
    /// `output / maxScaleFactor` are rejected (caller falls back to spatial).
    static let maxScaleFactor = 3.0

    /// One ready configuration: the scaler plus every texture it owns.
    /// AUDIT — @unchecked: immutable references to Metal objects (documented
    /// thread-safe); the scaler's mutable per-encode properties are only
    /// touched by the render thread (encode).
    private struct Pass: @unchecked Sendable {
        let colorTexture: MTLTexture
        let depthTexture: MTLTexture
        let motionTexture: MTLTexture
        let outputTexture: MTLTexture
        let scaler: MTLFXTemporalScaler
    }

    private struct Key: Hashable, Sendable {
        let inW: Int, inH: Int, outW: Int, outH: Int
    }

    private struct Entry: Sendable {
        let pass: Pass
        var lastUsed: Int
        /// Set on build and on pool revisit: the entry's accumulated history is
        /// frames old (different pose/scale) — reset, don't ghost.
        var needsReset: Bool
    }

    private struct State: Sendable {
        /// LRU pool of built scaler configurations. Bounded: each entry pins
        /// full-resolution output + MetalFX history textures.
        var entries: [Key: Entry] = [:]
        var useCounter = 0
        /// The key `prepare` last returned — `encode` consumes its reset flag.
        var activeKey: Key?
        /// The most recent requested output size; a completed build for a
        /// stale output (mid-resize) is discarded on arrival.
        var currentOutput = SIMD2<Int>(0, 0)
        /// The newest missing key (latest-wins: a drag's intermediate sizes
        /// overwrite each other here; only what's still wanted gets built).
        var wanted: Key?
        /// Whether the builder loop is live on `buildQueue`.
        var draining = false
        /// The key the builder is compiling right now — `prepare` skips
        /// re-requesting it, and ages it to detect a wedged build.
        var inFlight: Key?
        /// Consecutive `prepare` calls (≈ frames) the SAME key has been in
        /// flight; past `stalledBuildFrameLimit` it logs once.
        var inFlightAge = 0
        var reportedStall = false
        /// `requestReset` latches here; `encode` folds it into the active
        /// entry's reset.
        var resetRequested = true
    }

    private let device: MTLDevice
    private let colorFormat: MTLPixelFormat
    private let depthFormat: MTLPixelFormat
    /// The MetalFX output is written via compute, which sRGB pixel formats do
    /// not support on Apple Silicon. Use the non-sRGB twin (same bit layout);
    /// the blit samples it without sRGB decode and writes to the sRGB drawable,
    /// so the linear round-trip matches the spatial path.
    private let outputFormat: MTLPixelFormat
    private let state = Mutex<State>(State())
    private let maxPoolSize = 4
    /// The one thread scaler builds may occupy (see header).
    private let buildQueue = DispatchQueue(
        label: "com.polinate.threshold.mac-mfx-build", qos: .userInitiated)
    /// ~5–10 s at 60–120 fps before an in-flight build is reported stalled.
    private static let stalledBuildFrameLimit = 600

    // Render-thread mirrors of the active pooled entry (what `prepare` chose
    // this frame). Same surface the caller has always consumed.
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
    /// when a scaler is READY — the exact requested size when its build has
    /// landed, else the nearest ready size for the same output (the exact
    /// build is kicked off in the background). Returns `false` (caller falls
    /// back to spatial/direct) when the input is out of MetalFX range or no
    /// build for this output has completed yet. Never blocks.
    func prepare(inputWidth: Int, inputHeight: Int, outputWidth: Int, outputHeight: Int) -> Bool {
        guard MTLFXTemporalScalerDescriptor.supportsDevice(device),
              min(inputWidth, inputHeight) >= Self.minimumInputShortEdge,
              outputWidth >= inputWidth,
              outputHeight >= inputHeight,
              Double(outputWidth) <= Double(inputWidth) * Self.maxScaleFactor,
              Double(outputHeight) <= Double(inputHeight) * Self.maxScaleFactor else {
            state.withLock { $0.activeKey = nil }
            clearActiveMirrors()
            return false
        }

        let key = Key(inW: inputWidth, inH: inputHeight,
                      outW: outputWidth, outH: outputHeight)
        let (pass, startDrain, reportStall): (Pass?, Bool, Bool) = state.withLock { s in
            s.useCounter += 1
            // A changed output size (window resize) strands every pooled
            // entry's full-resolution textures — drop them all.
            let out = SIMD2(outputWidth, outputHeight)
            if s.currentOutput != out {
                s.currentOutput = out
                s.entries.removeAll()
            }

            // Age the in-flight build; report a wedge exactly once per build.
            var reportStall = false
            if s.inFlight != nil {
                s.inFlightAge += 1
                if s.inFlightAge == Self.stalledBuildFrameLimit, !s.reportedStall {
                    s.reportedStall = true
                    reportStall = true
                }
            }

            if var entry = s.entries[key] {
                entry.lastUsed = s.useCounter
                // Revisited after rendering another size: its history is
                // frames old (different pose/scale) — reset, don't ghost.
                entry.needsReset = entry.needsReset || s.activeKey != key
                s.entries[key] = entry
                s.activeKey = key
                return (entry.pass, false, reportStall)
            }

            // Miss: latest-wins — overwrite whatever stale size a fast drag
            // left here. Skip only when the builder is ALREADY on this key.
            var startDrain = false
            if s.inFlight != key {
                s.wanted = key
                if !s.draining {
                    s.draining = true
                    startDrain = true
                }
            }

            // Nearest ready fallback: the entry whose input area is closest
            // to the request (same output — everything pooled matches).
            let target = inputWidth * inputHeight
            let nearest = s.entries.min {
                abs($0.key.inW * $0.key.inH - target)
                    < abs($1.key.inW * $1.key.inH - target)
            }
            if let nearest {
                var entry = nearest.value
                entry.lastUsed = s.useCounter
                entry.needsReset = entry.needsReset || s.activeKey != nearest.key
                s.entries[nearest.key] = entry
                s.activeKey = nearest.key
                return (entry.pass, startDrain, reportStall)
            }
            s.activeKey = nil
            return (nil, startDrain, reportStall)
        }

        if reportStall {
            print("""
                ⚠️ Mac temporal scaler build stalled (>\(Self.stalledBuildFrameLimit) \
                frames in makeTemporalScaler) — Xcode Metal diagnostics (GPU \
                capture / HUD / API validation) can wedge it; rendering \
                continues at nearest/spatial/full resolution
                """)
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
        motionTexture = pass.motionTexture
        outputTexture = pass.outputTexture
        return true
    }

    private func clearActiveMirrors() {
        colorTexture = nil
        depthTexture = nil
        motionTexture = nil
        outputTexture = nil
        inputSize = Size(width: 0, height: 0)
        outputSize = Size(width: 0, height: 0)
    }

    /// Forces the next encode to reset accumulated history (e.g. view reset).
    func requestReset() {
        state.withLock { $0.resetRequested = true }
    }

    /// The builder loop (buildQueue only): take the newest wanted key, build
    /// it, publish, repeat until nothing is wanted. Builds superseded
    /// mid-compile still publish — a valid size for this output is a useful
    /// nearest-fallback — but a key whose OUTPUT went stale (resize) is
    /// dropped without paying for the build.
    private func drainBuilds() {
        while true {
            let next: Key? = state.withLock { s in
                guard let key = s.wanted,
                      s.currentOutput == SIMD2(key.outW, key.outH) else {
                    s.wanted = nil
                    s.draining = false
                    s.inFlight = nil
                    s.inFlightAge = 0
                    return nil
                }
                s.wanted = nil
                s.inFlight = key
                s.inFlightAge = 0
                s.reportedStall = false
                return key
            }
            guard let key = next else { return }

            let started = ProcessInfo.processInfo.systemUptime
            let built = build(key: key)
            let seconds = ProcessInfo.processInfo.systemUptime - started
            if seconds > 5 {
                print("""
                    ⚠️ Mac temporal scaler build took \(Int(seconds))s \
                    (\(key.inW)x\(key.inH)→\(key.outW)x\(key.outH)) — expected \
                    0.2–2s; Metal diagnostics slow this dramatically
                    """)
            }

            state.withLock { s in
                s.inFlight = nil
                s.inFlightAge = 0
                // Discard a build that raced a resize (stale output).
                guard let built,
                      s.currentOutput == SIMD2(key.outW, key.outH)
                else { return }
                s.entries[key] = Entry(
                    pass: built, lastUsed: s.useCounter, needsReset: true)
                if s.entries.count > maxPoolSize,
                   let evict = s.entries.filter({ $0.key != s.activeKey })
                       .min(by: { $0.value.lastUsed < $1.value.lastUsed }) {
                    s.entries.removeValue(forKey: evict.key)
                }
            }
        }
    }

    private func build(key: Key) -> Pass? {
        guard
            let color = makeTexture(width: key.inW, height: key.inH,
                                    format: colorFormat,
                                    usage: [.renderTarget, .shaderRead],
                                    label: "Mac Temporal Color"),
            let depth = makeTexture(width: key.inW, height: key.inH,
                                    format: depthFormat,
                                    usage: [.renderTarget, .shaderRead],
                                    label: "Mac Temporal Depth"),
            let motion = makeTexture(width: key.inW, height: key.inH,
                                     format: Self.motionFormat,
                                     usage: [.renderTarget, .shaderRead],
                                     label: "Mac Temporal Motion"),
            let output = makeTexture(width: key.outW, height: key.outH,
                                     format: outputFormat,
                                     usage: [.shaderRead, .shaderWrite, .renderTarget],
                                     label: "Mac Temporal Output")
        else { return nil }

        let descriptor = MTLFXTemporalScalerDescriptor()
        descriptor.inputWidth = key.inW
        descriptor.inputHeight = key.inH
        descriptor.outputWidth = key.outW
        descriptor.outputHeight = key.outH
        descriptor.colorTextureFormat = colorFormat
        descriptor.depthTextureFormat = depthFormat
        descriptor.motionTextureFormat = Self.motionFormat
        descriptor.outputTextureFormat = outputFormat

        guard let made = descriptor.makeTemporalScaler(device: device) else {
            print("❌ Mac MetalFX makeTemporalScaler failed: input=\(key.inW)x\(key.inH) output=\(key.outW)x\(key.outH)")
            return nil
        }
        // Raymarch depth is standard 0 (near) … 1 (far) — not reversed.
        made.isDepthReversed = false
        return Pass(colorTexture: color, depthTexture: depth,
                    motionTexture: motion, outputTexture: output, scaler: made)
    }

    /// Encodes the temporal upscale for the pass `prepare` just returned
    /// (render thread, same frame). `jitterPixels` is the sub-pixel offset that
    /// was applied to the projection this frame (input-pixel units);
    /// `forceReset` discards history (camera cut / view reset).
    func encode(commandBuffer: MTLCommandBuffer,
                jitterPixels: SIMD2<Float>,
                forceReset: Bool) {
        let ready: (Pass, Bool)? = state.withLock { s in
            guard let key = s.activeKey, var entry = s.entries[key] else {
                return nil
            }
            let reset = entry.needsReset || s.resetRequested || forceReset
            entry.needsReset = false
            s.resetRequested = false
            s.entries[key] = entry
            return (entry.pass, reset)
        }
        guard let (pass, reset) = ready else { return }

        // Set reset BEFORE textures: newer MetalFX SDK versions clear tracked
        // texture state when reset=true, so textures must be (re-)assigned after.
        pass.scaler.reset = reset

        pass.scaler.colorTexture = pass.colorTexture
        pass.scaler.depthTexture = pass.depthTexture
        pass.scaler.motionTexture = pass.motionTexture
        pass.scaler.outputTexture = pass.outputTexture
        pass.scaler.inputContentWidth = pass.colorTexture.width
        pass.scaler.inputContentHeight = pass.colorTexture.height
        // MetalFX expects the jitter offset that shifts samples relative to the
        // pixel center, in input pixels.
        pass.scaler.jitterOffsetX = jitterPixels.x
        pass.scaler.jitterOffsetY = jitterPixels.y
        // Motion vectors are stored as UV-space deltas; scale to input pixels.
        pass.scaler.motionVectorScaleX = Float(pass.colorTexture.width)
        pass.scaler.motionVectorScaleY = Float(pass.colorTexture.height)

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
