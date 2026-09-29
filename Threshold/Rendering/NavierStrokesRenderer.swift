//
//  NavierStrokesRenderer.swift
//  Threshold
//
//  Owns the 2D Navier-Stokes simulation state behind the "Navier Strokes"
//  post-processing layer (NavierStrokesShaders.metal), plus the CPU-side
//  scheduler that applies the effect inconsistently over time.
//
//  RESPONSIBILITIES
//  ----------------
//  - Lazily builds the sim's compute pipelines from the bundled default
//    metallib (no function constants — one generic pipeline per pass).
//  - Owns the ping-pong field textures (velocity / ink / pressure) plus curl
//    and divergence scratch targets, sized to a bounded sim resolution that is
//    aspect-matched to the output region. All fields are `type2DArray` with one
//    slice per view so the same kernels serve the stereo visionOS drawable and
//    the single-slice Mac/iOS render.
//  - Encodes the stable-fluids pass chain into the caller's command buffer:
//      splat(velocity) → advect → curl → vorticity confinement →
//      divergence → pressure(Jacobi × N) → gradient subtract →
//      splat(ink) → advect ink
//    It never touches the composed scene image — callers composite separately
//    (`encodeKernelComposite` on visionOS, the `navierCompositeFragment`
//    pipeline on Mac/iOS) so the layer composes over whatever is already on
//    screen.
//  - Runs the gust scheduler: a smooth value-noise gate authored by
//    `gustAmount`/`gustSpeed` modulates the composite blend AND the splat
//    impulses, so the effect is applied inconsistently over time; optional
//    audio-beat splats add one impulse per detected beat.
//
//  THREADING: all encode methods are called from the platform render loops
//  (Renderer's serial loop / RaymarchRenderView's MTKView draw). There is no
//  cross-thread state; the class is deliberately not Sendable.
//
//  IDENTITY CONTRACT: callers must not invoke any encode method while
//  `NavierStrokesEffect.isActive` is false — below the activation epsilon the
//  layer never allocates, dispatches, or changes a pixel.
//

import Foundation
import Metal
import simd

final class NavierStrokesRenderer {

    // MARK: - Tunables (internal policy, not user-facing)

    /// Long-edge resolution of the simulation grid. The fields are smooth and
    /// are sampled bilinearly by the full-resolution composite, so this cap
    /// keeps the multi-pass chain comfortably inside the frame budget at every
    /// drawable size while looking identical.
    static let simLongEdge: Int = 512
    /// Short-edge floor so very-wide viewports still resolve the flow.
    static let simShortEdgeMin: Int = 128
    /// Jacobi pressure sweeps are the chain's main cost; never exceed this even
    /// if a restored scene carried a larger value (the settings clamp at 40 too).
    static let maxPressureIterations = 40

    // MARK: - Pipeline states

    private(set) var splatPipeline: MTLComputePipelineState?
    private(set) var advectVelocityPipeline: MTLComputePipelineState?
    private(set) var curlPipeline: MTLComputePipelineState?
    private(set) var vorticityPipeline: MTLComputePipelineState?
    private(set) var divergencePipeline: MTLComputePipelineState?
    private(set) var pressurePipeline: MTLComputePipelineState?
    private(set) var gradientSubtractPipeline: MTLComputePipelineState?
    private(set) var advectDyePipeline: MTLComputePipelineState?
    private(set) var clearPipeline: MTLComputePipelineState?
    private(set) var compositePipeline: MTLComputePipelineState?
    /// Fragment composite for the Mac/iOS paths, which draw the final image
    /// straight into the CAMetalDrawable (plain 2D source + array sim fields).
    private(set) var compositeFragmentPipeline: MTLRenderPipelineState?

    private var pipelinesReady = false
    private var didLogPipelineFailure = false

    // MARK: - Simulation state

    private struct FieldPair {
        var textures: [MTLTexture] = []
        var index: Int = 0

        var read: MTLTexture? {
            textures.indices.contains(index) ? textures[index] : nil
        }
        var write: MTLTexture? {
            textures.indices.contains(1 - index) ? textures[1 - index] : nil
        }
        mutating func swap() {
            if textures.count == 2 { index = 1 - index }
        }
    }

    private var velocityPair = FieldPair()
    private var dyePair = FieldPair()
    private var pressurePair = FieldPair()
    private var divergenceTexture: MTLTexture?
    private var curlTexture: MTLTexture?

    /// Sim grid resolution in texels. Zero until first use.
    private(set) var simWidth = 0
    private(set) var simHeight = 0
    private var simArrayLength = 0
    /// Freshly created fields must be zeroed once (private texture contents
    /// are undefined until written; garbage pressure would fault the Jacobi).
    private var simNeedsClear = false

    /// Full-resolution composite destination (drawable format, per-view
    /// slices) — written by `strokesComposite` before the host's blit. VisionOS
    /// compute path only; the fragment paths composite into the drawable.
    private(set) var compositeOutputTexture: MTLTexture?

    // MARK: - Gust scheduler ("applied inconsistently over time")

    /// ∫ gustSpeed · dt — the envelope's phase. Integrated (not clock·speed) so
    /// a speed change bends the future curve without rescaling accumulated
    /// phase (the same policy as the hue/pulse cycle phases).
    private var gustPhase: Float = 0
    /// ∫ splatInterval · 1 — splat spacing clock (raw frame delta).
    private var splatClock: Float = 0
    /// Wandering splat path phase — advances with the envelope so bursts move.
    private var splatPathPhase: Float = 0
    /// When to fire the next splat batch.
    private var nextSplatAt: Float = 0
    /// Beat-gate hysteresis for audio-driven splats.
    private var beatWasActive = false
    /// Deterministic seed so the pattern is stable per session.
    private let noiseSeed: Float = 0.317

    // MARK: - Init

    private let device: MTLDevice

    init(device: MTLDevice) {
        self.device = device
    }

    // MARK: - Pipelines

    /// Builds the sim pipelines. Called lazily on first use so an inactive
    /// feature costs nothing at startup. Idempotent; a failed build keeps
    /// returning false (the layer then stays off — other paths are untouched).
    func ensurePipelines() -> Bool {
        if pipelinesReady { return true }
        guard let library = MetalLibraryCache.bundledDefaultLibrary(device: device) else {
            return false
        }

        let computeNames = [
            "strokesSplat",
            "strokesAdvectVelocity",
            "strokesCurl",
            "strokesVorticity",
            "strokesDivergence",
            "strokesPressureJacobi",
            "strokesGradientSubtract",
            "strokesAdvectDye",
            "strokesClear",
            "strokesComposite",
        ]
        var pipelines: [MTLComputePipelineState] = []
        pipelines.reserveCapacity(computeNames.count)
        for functionName in computeNames {
            // The sim kernels declare no function constants, so plain
            // `makeFunction(name:)` is correct for all of them.
            guard let function = library.makeFunction(name: functionName) else {
                logPipelineFailure("kernel '\(functionName)' not found in default library")
                return false
            }
            do {
                pipelines.append(try device.makeComputePipelineState(function: function))
            } catch {
                logPipelineFailure("failed to compile '\(functionName)': \(error.localizedDescription)")
                return false
            }
        }

        splatPipeline = pipelines[0]
        advectVelocityPipeline = pipelines[1]
        curlPipeline = pipelines[2]
        vorticityPipeline = pipelines[3]
        divergencePipeline = pipelines[4]
        pressurePipeline = pipelines[5]
        gradientSubtractPipeline = pipelines[6]
        advectDyePipeline = pipelines[7]
        clearPipeline = pipelines[8]
        compositePipeline = pipelines[9]
        pipelinesReady = true
        return true
    }

    /// Fragment composite pipeline for the Mac/iOS render paths (plain 2D
    /// source + array sim fields, written into the CAMetalDrawable). Reuses
    /// the existing `macBlitVertex` full-screen triangle.
    func ensureCompositeFragmentPipeline(colorFormat: MTLPixelFormat) -> Bool {
        if compositeFragmentPipeline != nil { return true }
        guard ensurePipelines(),
              let library = MetalLibraryCache.bundledDefaultLibrary(device: device),
              let vertexFunction = library.makeFunction(name: "macBlitVertex"),
              let fragmentFunction = library.makeFunction(name: "navierCompositeFragment") else {
            return false
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "NavierStrokesComposite"
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.rasterSampleCount = 1
        descriptor.colorAttachments[0].pixelFormat = colorFormat
        do {
            compositeFragmentPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            logPipelineFailure("composite fragment pipeline: \(error.localizedDescription)")
            compositeFragmentPipeline = nil
        }
        return compositeFragmentPipeline != nil
    }

    private func logPipelineFailure(_ message: String) {
        guard !didLogPipelineFailure else { return }
        didLogPipelineFailure = true
        print("⚠️ Navier Strokes disabled: \(message)")
    }

    // MARK: - Texture management

    private func makeFieldTexture(
        pixelFormat: MTLPixelFormat,
        width: Int,
        height: Int,
        arrayLength: Int,
        label: String
    ) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type2DArray
        descriptor.pixelFormat = pixelFormat
        descriptor.width = width
        descriptor.height = height
        descriptor.arrayLength = arrayLength
        descriptor.storageMode = .private
        descriptor.usage = [.shaderRead, .shaderWrite]
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.label = label
        return texture
    }

    /// Sim grid size: long edge pinned, short edge follows the region's aspect
    /// (so uv-space splats stay round and the sim never wastes texels).
    static func simSizeFor(regionWidth: Int, regionHeight: Int) -> (width: Int, height: Int) {
        let aspect = Float(regionWidth) / Float(max(regionHeight, 1))
        let clamped = max(0.2, min(5.0, aspect.isFinite ? abs(aspect) : 1.0))
        if clamped >= 1.0 {
            let height = max(simShortEdgeMin, Int((Float(simLongEdge) / clamped).rounded()))
            return (simLongEdge, height)
        }
        let width = max(simShortEdgeMin, Int((Float(simLongEdge) * clamped).rounded()))
        return (width, simLongEdge)
    }

    /// (Re)creates the field textures for a new viewport shape / view count.
    /// Contents are intentionally lost (the fields restart from rest) — a
    /// resize changes the uv mapping, so stale state would smear from wrong
    /// coordinates.
    func ensureSimTextures(
        regionWidth: Int,
        regionHeight: Int,
        arrayLength: Int
    ) -> Bool {
        let size = Self.simSizeFor(regionWidth: regionWidth, regionHeight: regionHeight)
        if let read = velocityPair.read,
           read.width == size.width, read.height == size.height,
           read.arrayLength == arrayLength,
           simArrayLength == arrayLength,
           dyePair.read != nil, pressurePair.read != nil,
           divergenceTexture != nil, curlTexture != nil {
            return true
        }
        releaseSimTextures()

        func makePair(_ format: MTLPixelFormat, _ label: String) -> FieldPair? {
            guard let a = makeFieldTexture(pixelFormat: format,
                                           width: size.width,
                                           height: size.height,
                                           arrayLength: arrayLength,
                                           label: "\(label).A"),
                  let b = makeFieldTexture(pixelFormat: format,
                                           width: size.width,
                                           height: size.height,
                                           arrayLength: arrayLength,
                                           label: "\(label).B") else { return nil }
            return FieldPair(textures: [a, b], index: 0)
        }

        guard let velocity = makePair(.rg16Float, "NavierStrokes Velocity"),
              let dye = makePair(.rgba16Float, "NavierStrokes Ink"),
              let pressure = makePair(.r16Float, "NavierStrokes Pressure"),
              let divergence = makeFieldTexture(pixelFormat: .r16Float,
                                                width: size.width,
                                                height: size.height,
                                                arrayLength: arrayLength,
                                                label: "NavierStrokes Divergence"),
              let curl = makeFieldTexture(pixelFormat: .r16Float,
                                          width: size.width,
                                          height: size.height,
                                          arrayLength: arrayLength,
                                          label: "NavierStrokes Curl") else {
            releaseSimTextures()
            return false
        }
        velocityPair = velocity
        dyePair = dye
        pressurePair = pressure
        divergenceTexture = divergence
        curlTexture = curl
        simWidth = size.width
        simHeight = size.height
        simArrayLength = arrayLength
        simNeedsClear = true
        return true
    }

    /// Full-resolution composite destination (drawable format, per-view
    /// slices) — written by the `strokesComposite` kernel before the host's
    /// blit. Recreated on size/format/view-count change (contents need not
    /// survive: every active pixel is rewritten each frame).
    func ensureCompositeOutput(
        source: MTLTexture,
        arrayLength: Int
    ) -> MTLTexture? {
        if let existing = compositeOutputTexture,
           existing.width == source.width,
           existing.height == source.height,
           existing.arrayLength == arrayLength,
           existing.pixelFormat == source.pixelFormat {
            return existing
        }
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type2DArray
        descriptor.pixelFormat = source.pixelFormat
        descriptor.width = source.width
        descriptor.height = source.height
        descriptor.arrayLength = arrayLength
        descriptor.storageMode = .private
        descriptor.usage = [.shaderRead, .shaderWrite]
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.label = "NavierStrokes Composite Output"
        compositeOutputTexture = texture
        return texture
    }

    /// Drops every allocation owned by the sim (mirrors
    /// `releaseAdaptiveComputeAuxiliaryTextures`). Safe any time; the next
    /// active frame rebuilds. Command buffers retain resources they reference,
    /// so an in-flight frame stays valid while the pool goes nil.
    func releaseSimTextures() {
        velocityPair = FieldPair()
        dyePair = FieldPair()
        pressurePair = FieldPair()
        divergenceTexture = nil
        curlTexture = nil
        compositeOutputTexture = nil
        simWidth = 0
        simHeight = 0
        simArrayLength = 0
        simNeedsClear = false
    }

    // MARK: - Gust scheduler

    /// Deterministic 1D value noise in [-1, 1] (classic hash + cubic
    /// interpolation). Drives the gust gate and the wandering splat path so
    /// the intermittency pattern is organic but stable.
    private static func valueNoise(_ x: Float, seed: Float) -> Float {
        func hash(_ n: Float) -> Float {
            let s = sinf(n * 12.9898 + seed * 78.233) * 43758.5453
            return s - floorf(s)
        }
        let i = floorf(x)
        let f = x - i
        let a = hash(i)
        let b = hash(i + 1)
        let t = f * f * (3 - 2 * f)
        return (a + (b - a) * t) * 2 - 1
    }

    /// Splat spacing: dense during a full envelope, sparse while idling,
    /// randomized ±40% so bursts never land on a fixed beat.
    private func nextSplatInterval(_ effect: NavierStrokesEffect) -> Float {
        let base = 0.28 - 0.16 * effect.gustAmount
        let jitter = 0.6 + 0.8 * abs(Self.valueNoise(splatClock * 0.7, seed: noiseSeed + 11))
        return max(0.05, base * jitter)
    }

    /// Advance the scheduler one frame.
    /// Returns the composite blend (`appliedAmount`) and the splat impulse
    /// energy for this frame. `gustAmount == 0` degenerates to a constant
    /// envelope (steady application) while the scheduler keeps injecting
    /// splats so the fluid keeps moving.
    private func updateScheduler(
        _ effect: NavierStrokesEffect,
        deltaTime: Float,
        beat: Float
    ) -> (appliedAmount: Float, splatEnergy: Float) {
        guard effect.isActive else { return (0, 0) }

        let step = max(deltaTime, 0)
        gustPhase = (gustPhase + effect.gustSpeed * step)
            .truncatingRemainder(dividingBy: 1024)
        splatClock += step

        // Gate: value noise only opens past a threshold authored by
        // gustAmount — 0 keeps the gate essentially open (steady strokes),
        // 1 makes gusts rare and dramatic.
        let threshold = 1.0 - (1.0 - effect.gustAmount) * 0.9
        let noise = Self.valueNoise(gustPhase, seed: noiseSeed)
        let gate = max(0, min(1, (noise - threshold) / max(1.0 - threshold, 0.001)))
        let shaped = gate * gate * (3 - 2 * gate)
        let envelope = 1.0 - effect.gustAmount * (1.0 - shaped)

        // Splat energy keeps a small idle floor so the sim stays warm while a
        // gust is closed — reopening shows motion instead of a cold start.
        var splatEnergy = effect.splatIntensity * (0.15 + 0.75 * envelope)

        if effect.audioSplats, beat > 0.45 {
            // Beat hysteresis: one extra impulse per detected beat.
            if !beatWasActive {
                splatEnergy = min(2.0, splatEnergy + beat * effect.splatIntensity)
                nextSplatAt = min(nextSplatAt, splatClock)
            }
            beatWasActive = true
        } else if beat <= 0.45 {
            beatWasActive = false
        }

        return (effect.strength * envelope, splatEnergy)
    }

    /// Wandering splat center: smooth noise path over the envelope phase, so a
    /// burst's splats travel across the frame instead of blinking in place.
    private func splatPoint(_ offset: Float) -> SIMD2<Float> {
        let t = splatPathPhase + offset
        let point = SIMD2<Float>(
            0.5 + 0.42 * Self.valueNoise(t, seed: noiseSeed + 3.1),
            0.5 + 0.42 * Self.valueNoise(t, seed: noiseSeed + 7.7)
        )
        // Keep splats fully on the sim grid (their Gaussian support is ±2σ).
        return simd_clamp(point, SIMD2<Float>(0.08, 0.08), SIMD2<Float>(0.92, 0.92))
    }

    /// Build the splat batch's C-array tuple (Swift imports fixed C arrays as
    /// tuples — filled slot-by-slot, mirroring the gradientStops pattern).
    /// Unused slots carry strength 0, which the kernel skips.
    private static func splatTuple(
        points: [SIMD2<Float>],
        radius: Float,
        strength: Float
    ) -> (vector_float4, vector_float4, vector_float4, vector_float4) {
        return (splatSlot(points, 0, radius, strength),
                splatSlot(points, 1, radius, strength),
                splatSlot(points, 2, radius, strength),
                splatSlot(points, 3, radius, strength))
    }

    private static func splatSlot(
        _ points: [SIMD2<Float>],
        _ index: Int,
        _ radius: Float,
        _ strength: Float
    ) -> vector_float4 {
        guard points.indices.contains(index) else { return vector_float4(0, 0, 0, 0) }
        return vector_float4(points[index].x, points[index].y, radius, strength)
    }

    // MARK: - Dispatch helpers

    private func dispatch(
        _ encoder: MTLComputeCommandEncoder,
        pipeline: MTLComputePipelineState,
        width: Int,
        height: Int,
        arrayLength: Int
    ) {
        let width1 = max(1, width)
        let height1 = max(1, height)
        var groupWidth = min(pipeline.threadExecutionWidth, width1)
        var groupHeight = min(pipeline.maxTotalThreadsPerThreadgroup / max(groupWidth, 1), 64)
        groupWidth = max(1, min(groupWidth, width1))
        groupHeight = max(1, min(groupHeight, height1))
        encoder.dispatchThreads(
            MTLSize(width: width1, height: height1, depth: arrayLength),
            threadsPerThreadgroup: MTLSize(width: groupWidth, height: groupHeight, depth: 1)
        )
    }

    /// One sim-kernel dispatch with a `NavierStrokesSimParams` byte block and
    /// up to three texture bindings (unused indices keep previous bindings
    /// harmless — each kernel reads exactly what it declares).
    private func encodeSimPass(
        _ encoder: MTLComputeCommandEncoder,
        pipeline: MTLComputePipelineState,
        params: inout NavierStrokesSimParams,
        textures: [MTLTexture?],
        label: String
    ) {
        encoder.pushDebugGroup(label)
        encoder.setComputePipelineState(pipeline)
        encoder.setBytes(&params,
                         length: MemoryLayout<NavierStrokesSimParams>.stride,
                         index: 0)
        for (index, texture) in textures.enumerated() {
            encoder.setTexture(texture, index: index)
        }
        dispatch(encoder, pipeline: pipeline,
                 width: simWidth, height: simHeight, arrayLength: simArrayLength)
        encoder.popDebugGroup()
    }

    private func encodeSplat(
        _ encoder: MTLComputeCommandEncoder,
        splats: (vector_float4, vector_float4, vector_float4, vector_float4),
        velocity: SIMD2<Float>,
        ink: SIMD3<Float>,
        inkAmount: Float,
        source: MTLTexture,
        destination: MTLTexture
    ) {
        guard let pipeline = splatPipeline else { return }
        var params = NavierStrokesSplatParams()
        params.splats = splats
        params.velocity = vector_float2(velocity.x, velocity.y)
        params.color = vector_float4(ink.x, ink.y, ink.z, inkAmount)
        params.aspect = Float(simWidth) / Float(max(simHeight, 1))

        encoder.pushDebugGroup("Navier Strokes Splat")
        encoder.setComputePipelineState(pipeline)
        encoder.setBytes(&params,
                         length: MemoryLayout<NavierStrokesSplatParams>.stride,
                         index: 0)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(destination, index: 1)
        dispatch(encoder, pipeline: pipeline,
                 width: simWidth, height: simHeight, arrayLength: simArrayLength)
        encoder.popDebugGroup()
    }

    private func encodeClearIfNeeded(_ encoder: MTLComputeCommandEncoder) {
        guard simNeedsClear, let pipeline = clearPipeline else { return }
        for pair in [velocityPair, dyePair, pressurePair] {
            for texture in pair.textures where texture != nil {
                encoder.pushDebugGroup("Navier Strokes Clear")
                encoder.setComputePipelineState(pipeline)
                encoder.setTexture(texture, index: 0)
                dispatch(encoder, pipeline: pipeline,
                         width: simWidth, height: simHeight, arrayLength: simArrayLength)
                encoder.popDebugGroup()
            }
        }
        if let divergence = divergenceTexture {
            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(divergence, index: 0)
            dispatch(encoder, pipeline: pipeline,
                     width: simWidth, height: simHeight, arrayLength: simArrayLength)
        }
        if let curl = curlTexture {
            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(curl, index: 0)
            dispatch(encoder, pipeline: pipeline,
                     width: simWidth, height: simHeight, arrayLength: simArrayLength)
        }
        simNeedsClear = false
    }

    // MARK: - Frame entry points

    /// Result of `encodeSimulation` — the fields the caller's composite pass
    /// samples, plus the scheduler's blend for this frame.
    struct SimulationResult {
        let velocity: MTLTexture
        let dye: MTLTexture
        let appliedAmount: Float
        let displacement: Float
        let inkTint: SIMD3<Float>
        let inkGain: Float
    }

    /// Advances the simulation one frame and encodes its pass chain into
    /// `commandBuffer`. Returns the field textures + composite parameters, or
    /// nil when the chain could not be encoded — the caller must then skip the
    /// layer entirely for this frame (the source is left untouched, so the
    /// fallback is the identity bypass).
    ///
    /// `deltaTime` is the raw frame delta in seconds (clamped internally);
    /// `regionWidth/regionHeight` size the sim grid's aspect (the physical /
    /// viewport region the upstream path wrote — the same convention the edge
    /// detector uses). `beat` is the precomputed audio beat level (0 when the
    /// layer's audio splats are off).
    func encodeSimulation(
        commandBuffer: MTLCommandBuffer,
        effect: NavierStrokesEffect,
        deltaTime: Float,
        viewCount: Int,
        regionWidth: Int,
        regionHeight: Int,
        audioBeat: Float
    ) -> SimulationResult? {
        guard effect.isActive, ensurePipelines() else { return nil }
        // Advance the scheduler FIRST: a fully-closed gust gate means the
        // composite would blend to identity this frame, so skip the whole sim
        // chain (the fields freeze mid-stroke and resume organically on the
        // next open gate — no invisible GPU work between gusts).
        let schedule = updateScheduler(effect, deltaTime: deltaTime, beat: audioBeat)
        guard schedule.appliedAmount > NavierStrokesEffect.activationEpsilon,
              ensureSimTextures(regionWidth: regionWidth,
                                regionHeight: regionHeight,
                                arrayLength: viewCount) else {
            return nil
        }
        guard let splatPipeline, let advectVelocityPipeline, let curlPipeline,
              let vorticityPipeline, let divergencePipeline, let pressurePipeline,
              let gradientSubtractPipeline, let advectDyePipeline,
              velocityPair.read != nil, velocityPair.write != nil,
              dyePair.read != nil, dyePair.write != nil,
              pressurePair.read != nil, pressurePair.write != nil,
              divergenceTexture != nil, curlTexture != nil,
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return nil
        }
        encoder.label = "Navier Strokes Simulation"

        // Fixed, bounded step: fluid advection is explicit, so a long stall
        // must not explode the field (clamped to 1/240...1/30 s).
        let dt = min(max(deltaTime.isFinite ? deltaTime : 1.0 / 60.0, 1.0 / 240.0), 1.0 / 30.0)
            * effect.simSpeed
        let texelSize = SIMD2<Float>(1.0 / Float(simWidth), 1.0 / Float(simHeight))
        var simParams = NavierStrokesSimParams(
            texelSize: vector_float2(texelSize.x, texelSize.y),
            dt: dt,
            velocityDissipation: effect.velocityDissipation,
            dyeDissipation: effect.dyeDissipation,
            curl: effect.curlStrength,
            pressureIterations: Int32(min(effect.pressureIterations, Self.maxPressureIterations))
        )

        encodeClearIfNeeded(encoder)

        // ── Velocity impulse splats (scheduler-composed batch) ──
        var splatPoints: [SIMD2<Float>] = []
        if splatClock >= nextSplatAt, schedule.splatEnergy > 0,
           let splatSource = velocityPair.read, let splatDestination = velocityPair.write {
            splatPathPhase += 0.35 * dt * effect.simSpeed + 0.02
            let count = 1 + (Int(splatPathPhase * 8) % 3)  // 1...3 wandering points
            for slot in 0..<count {
                splatPoints.append(splatPoint(Float(slot) * 0.31))
            }
            let angle = Self.valueNoise(splatPathPhase * 1.7, seed: noiseSeed + 13) * .pi
            let flowDirection = SIMD2<Float>(cos(angle), sin(angle))
                * schedule.splatEnergy * 2.0
            encodeSplat(encoder,
                        splats: Self.splatTuple(points: splatPoints,
                                                radius: max(effect.splatRadius, 0.01),
                                                strength: schedule.splatEnergy),
                        velocity: flowDirection,
                        ink: SIMD3<Float>(0, 0, 0),
                        inkAmount: 0,
                        source: splatSource,
                        destination: splatDestination)
            velocityPair.swap()
            nextSplatAt = splatClock + nextSplatInterval(effect)
        }

        // ── Stable fluids: advection → vorticity → projection ──
        encodeSimPass(encoder, pipeline: advectVelocityPipeline,
                      params: &simParams,
                      textures: [velocityPair.read, velocityPair.write],
                      label: "Navier Strokes Advect Velocity")
        velocityPair.swap()

        encodeSimPass(encoder, pipeline: curlPipeline,
                      params: &simParams,
                      textures: [velocityPair.read, curlTexture],
                      label: "Navier Strokes Curl")

        encodeSimPass(encoder, pipeline: vorticityPipeline,
                      params: &simParams,
                      textures: [velocityPair.read, curlTexture, velocityPair.write],
                      label: "Navier Strokes Vorticity Confinement")
        velocityPair.swap()

        encodeSimPass(encoder, pipeline: divergencePipeline,
                      params: &simParams,
                      textures: [velocityPair.read, divergenceTexture],
                      label: "Navier Strokes Divergence")

        let pressureIterations = min(max(effect.pressureIterations, 2), Self.maxPressureIterations)
        for _ in 0..<pressureIterations {
            encodeSimPass(encoder, pipeline: pressurePipeline,
                          params: &simParams,
                          textures: [divergenceTexture, pressurePair.read, pressurePair.write],
                          label: "Navier Strokes Pressure Jacobi")
            pressurePair.swap()
        }

        encodeSimPass(encoder, pipeline: gradientSubtractPipeline,
                      params: &simParams,
                      textures: [pressurePair.read, velocityPair.read, velocityPair.write],
                      label: "Navier Strokes Gradient Subtract")
        velocityPair.swap()

        // ── Ink: splat then advect by the projected velocity ──
        if schedule.splatEnergy > 0,
           let dyeWrite = dyePair.write,
           let dyeRead = dyePair.read {
            // Ink splats reuse the same batch points; the shared strength
            // scales the Gaussian, and `color.a` carries the ink amount.
            let inkSplats = Self.splatTuple(points: splatPoints,
                                            radius: max(effect.splatRadius, 0.01),
                                            strength: 1.0)
            encodeSplat(encoder,
                        splats: inkSplats,
                        velocity: SIMD2<Float>(0, 0),
                        ink: effect.tintColor,
                        inkAmount: 0.45,
                        source: dyeRead,
                        destination: dyeWrite)
            dyePair.swap()
        }

        encodeSimPass(encoder, pipeline: advectDyePipeline,
                      params: &simParams,
                      textures: [dyePair.read, velocityPair.read, dyePair.write],
                      label: "Navier Strokes Advect Ink")
        dyePair.swap()

        encoder.endEncoding()

        guard let velocity = velocityPair.read, let dye = dyePair.read else { return nil }
        return SimulationResult(
            velocity: velocity,
            dye: dye,
            appliedAmount: schedule.appliedAmount,
            displacement: effect.displacement,
            inkTint: effect.tintColor,
            inkGain: 1.0
        )
    }

    /// Full-resolution composite KERNEL (visionOS compute path): drags the
    /// composed scene image along the fluid and lays ink over it, writing
    /// `dest` (drawable format, per-view slices) for the host's blit. The
    /// dispatch is bounded to the physical/viewport region, matching the edge
    /// detector's convention. Returns false when the blend is closed this
    /// frame or the pass could not be encoded — the caller then presents the
    /// untouched source via its normal path (the identity bypass).
    func encodeKernelComposite(
        commandBuffer: MTLCommandBuffer,
        source: MTLTexture,
        destination: MTLTexture,
        regionWidth: Int,
        regionHeight: Int,
        viewCount: Int,
        result: SimulationResult
    ) -> Bool {
        guard result.appliedAmount > NavierStrokesEffect.activationEpsilon,
              let pipeline = compositePipeline,
              let velocity = velocityPair.read, let dye = dyePair.read,
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return false
        }
        var params = NavierStrokesCompositeParams(
            inkTint: vector_float3(result.inkTint.x, result.inkTint.y, result.inkTint.z),
            displacement: result.displacement,
            appliedAmount: result.appliedAmount,
            inkGain: result.inkGain,
            _pad0: 0, _pad1: 0, _pad2: 0
        )
        encoder.label = "Navier Strokes Composite"
        encoder.setComputePipelineState(pipeline)
        encoder.setBytes(&params,
                         length: MemoryLayout<NavierStrokesCompositeParams>.stride,
                         index: 0)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(velocity, index: 1)
        encoder.setTexture(dye, index: 2)
        encoder.setTexture(destination, index: 3)
        dispatch(encoder, pipeline: pipeline,
                 width: max(1, regionWidth), height: max(1, regionHeight),
                 arrayLength: viewCount)
        encoder.endEncoding()
        return true
    }

    /// Identity check the callers use before routing a frame through the layer
    /// (mirrors `edgeDetectionEffect.isActive` + pipeline readiness).
    func isReady(effect: NavierStrokesEffect) -> Bool {
        effect.isActive && ensurePipelines()
    }
}