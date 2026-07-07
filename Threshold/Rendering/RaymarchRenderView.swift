#if os(macOS) || os(iOS)
import Metal
@preconcurrency import MetalKit
import ModelIO
import QuartzCore
import SwiftUI
import simd
import os
#if os(macOS)
import AppKit
#endif

// MARK: - Custom Shader Box (runtime-compiled .threshfx → Mac/iPad)

/// NSLock-guarded holder for the active runtime-compiled custom `MTLLibrary` and
/// its `EmbeddedFormula.shortHash`, plus the per-renderer `CustomShaderCompiler`.
///
/// `ThresholdMacRenderer` is a plain class touched from two threads — the render
/// thread reads `library`/`hash` every frame (in `resolveActivePipeline`), while
/// the activation handler writes them after an off-thread compile — so this box
/// serializes those accesses. It mirrors the visionOS `CustomShaderState`, and
/// because it owns the compile logic the activation handler can capture only
/// Sendable values (box + cache + device), never the non-Sendable renderer.
final class MacCustomShaderBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _library: MTLLibrary?
    private var _hash: String?
    private var _compiler: CustomShaderCompiler?

    /// The active custom library, or nil when no custom formula is installed.
    var library: MTLLibrary? { lock.lock(); defer { lock.unlock() }; return _library }
    /// `shortHash` of the active custom formula (used in the `CX{hash}_` cache key).
    var hash: String? { lock.lock(); defer { lock.unlock() }; return _hash }

    /// Atomic read of (library, hash) under a single lock. The render thread uses
    /// this so the cache-key hash and the build library always come from the SAME
    /// activation — two separate getter calls could otherwise tear if an
    /// activation lands between them (caching a library-B pipeline under hash-A).
    func snapshot() -> (library: MTLLibrary?, hash: String?) {
        lock.lock(); defer { lock.unlock() }; return (_library, _hash)
    }

    private func sharedCompiler(device: MTLDevice) -> CustomShaderCompiler {
        lock.lock(); defer { lock.unlock() }
        if let existing = _compiler { return existing }
        let made = CustomShaderCompiler(device: device)
        _compiler = made
        return made
    }

    private func set(library: MTLLibrary?, hash: String?) {
        lock.lock(); _library = library; _hash = hash; lock.unlock()
    }

    /// Compile + install a custom embedded formula (or pass nil to deactivate).
    /// The ~0.5–5 s compile runs on the `CustomShaderCompiler` actor — off the
    /// render and main threads. Library + hash are published together under one
    /// lock so a frame never sees library-A with hash-B.
    func activate(_ formula: EmbeddedFormula?,
                  warpStackSource: String? = nil,
                  warpStackSignature: String = "s0",
                  device: MTLDevice,
                  cache: MacSpecializedPipelineCache) async throws {
        // Effect set = optional .threshfx (fractal DE OR space warp) + the composable
        // transform-stack codegen. Key the library + pipelines by the combined hash so
        // distinct effect sets never alias. A built-in fractal + non-empty stack rides
        // a custom library exactly as a .threshfx warp on a built-in does.
        let isWarp = (formula?.effectKind == .spaceWarp)
        let fractalEffect = isWarp ? nil : formula
        let warpEffect = isWarp ? formula : nil
        let hasEffect = (formula != nil) || (warpStackSource != nil)
        guard hasEffect else {
            set(library: nil, hash: nil)
            cache.evict(prefix: "CX")   // drop every custom pipeline → back to default library
            return
        }
        let newHash = CustomShaderCompiler.combinedHash(fractal: fractalEffect, spaceWarp: warpEffect, warpStackSignature: warpStackSignature)
        if hash == newHash, library != nil { return }   // unchanged → no-op
        let compiled = try await sharedCompiler(device: device).library(forFractal: fractalEffect, spaceWarp: warpEffect,
                                                                        warpStackSource: warpStackSource, warpStackSignature: warpStackSignature)
        if let old = hash, old != newHash {
            cache.evict(prefix: "CX\(old)_")   // retire the previous effect's pipelines
        }
        set(library: compiled, hash: newHash)
    }

    /// Debug "Force Recompile": drop every cached specialized pipeline and the
    /// compiled custom library, then recompile + reinstall `formula` from source
    /// (`nil` = a built-in fractal, nothing to recompile). The cleared pipelines
    /// rebuild lazily in `resolveActivePipeline`, so this is safe to call while
    /// the render thread is live. Returns a short status summary for the UI.
    func forceRecompile(formula: EmbeddedFormula?,
                        device: MTLDevice,
                        cache: MacSpecializedPipelineCache) async -> String {
        cache.evict(prefix: "")                       // drop ALL specialized pipelines
        await sharedCompiler(device: device).evictAll()  // force a true source recompile
        set(library: nil, hash: nil)                  // bypass activate()'s no-op guard

        guard let formula else {
            return "Cleared the pipeline cache — rebuilding on next frames."
        }
        do {
            try await activate(formula, device: device, cache: cache)
            return "Recompiled '\(formula.name)' and cleared the pipeline cache."
        } catch {
            return "⚠️ Recompile of '\(formula.name)' failed: \(error.localizedDescription)"
        }
    }
}


#if os(macOS)

struct ThresholdMacRenderView: NSViewRepresentable {
    let appModel: AppModel

    func makeCoordinator() -> Coordinator {
        Coordinator(appModel: appModel)
    }

    func makeNSView(context: Context) -> MTKView {
        let device = MTLCreateSystemDefaultDevice()
        let view = ThresholdMacInteractiveView(frame: .zero, device: device)
        view.colorPixelFormat = .bgra8Unorm_srgb
        view.depthStencilPixelFormat = .depth32Float
        view.clearColor = MTLClearColor(red: 0.005, green: 0.006, blue: 0.008, alpha: 1.0)
        view.clearDepth = 1.0
        view.preferredFramesPerSecond = 120  // allow ProMotion; also gives finer vsync steps under load instead of the 60→30 cliff
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.framebufferOnly = true
        view.autoResizeDrawable = true
        view.inputDelegate = context.coordinator
        view.delegate = context.coordinator
        context.coordinator.configure(view)
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        context.coordinator.appModel = appModel
        (nsView as? ThresholdMacInteractiveView)?.inputDelegate = context.coordinator
    }

    static func dismantleNSView(_ nsView: MTKView, coordinator: Coordinator) {
        nsView.delegate = nil
        (nsView as? ThresholdMacInteractiveView)?.inputDelegate = nil
        coordinator.tearDown()
    }

    final class Coordinator: NSObject, MTKViewDelegate, ThresholdMacViewportInputDelegate {
        var appModel: AppModel
        private let inputController = ThresholdMacInputController()
        private var renderer: ThresholdMacRenderer?

        init(appModel: AppModel) {
            self.appModel = appModel
            super.init()
        }

        @MainActor
        func configure(_ view: MTKView) {
            appModel.rendererStartupWarmupComplete = false
            guard let device = view.device,
                  let metalLayer = view.layer as? CAMetalLayer else { return }
            metalLayer.device = device
            metalLayer.pixelFormat = view.colorPixelFormat
            metalLayer.framebufferOnly = true
            metalLayer.drawableSize = view.drawableSize
            renderer = ThresholdMacRenderer(device: device,
                                            appModel: appModel,
                                            inputController: inputController,
                                            metalLayer: metalLayer,
                                            colorPixelFormat: view.colorPixelFormat,
                                            depthPixelFormat: view.depthStencilPixelFormat,
                                            clearColor: view.clearColor)
            renderer?.drawableSizeDidChange(view.drawableSize)
            appModel.rendererStartupWarmupComplete = renderer != nil
            // Compile + activate runtime `.threshfx` formulas on Mac/iPad (was
            // visionOS-only). Binding here triggers the handler's didSet, which
            // re-activates any formula loaded before the view existed.
            if let renderer {
                appModel.activateEmbeddedFormulaHandler = renderer.embeddedFormulaActivator(renderSettings: appModel.renderSettings)
                appModel.forceShaderRecompileHandler = renderer.shaderRecompiler(appModel: appModel)
            }
        }

        func tearDown() {
            inputController.setFocus(false)
            renderer = nil
            Task { @MainActor [appModel] in
                appModel.activateEmbeddedFormulaHandler = nil
                appModel.forceShaderRecompileHandler = nil
                appModel.rendererStartupWarmupComplete = false
            }
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            renderer?.drawableSizeDidChange(size)
        }

        func draw(in view: MTKView) {
            renderer?.draw(appModel: appModel)
        }

        func viewportDidChangeFocus(_ isFocused: Bool) {
            inputController.setFocus(isFocused)
        }

        func viewportDidOrbit(delta: SIMD2<Float>) {
            inputController.addOrbit(delta: delta)
        }

        func viewportDidPan(delta: SIMD2<Float>) {
            inputController.addPan(delta: delta)
        }

        func viewportDidZoom(delta: Float) {
            inputController.addZoom(delta: delta)
        }

        func viewportDidChangeKey(_ key: ThresholdMacMovementKey, isPressed: Bool) {
            inputController.setMovementKey(key, isPressed: isPressed)
        }

        func viewportDidChangeShift(_ isPressed: Bool) {
            inputController.setShiftPressed(isPressed)
        }

        func viewportDidTogglePlayback() {
            inputController.requestPlaybackToggle()
        }

        func viewportDidRequestReset() {
            inputController.requestReset()
        }

        func viewportDidRequestSceneStep(_ step: Int) {
            inputController.requestSceneStep(step)
        }
    }
}
#endif


final class ThresholdMacRenderer {
    private enum SetupError: Error {
        case badVertexDescriptor
        case metalLibraryUnavailable
    }

    private struct CachedMeshBinding {
        let bufferIndex: Int
        let buffer: MTLBuffer
        let offset: Int
    }

    /// Mirrors the `MacMotionParams` struct in Shaders.metal (Stage B temporal
    /// upscaling). Bound only to the motion-vector pass — never the shared
    /// `Uniforms`.
    private struct MacMotionParams {
        var currentInvViewProj: matrix_float4x4
        var currentViewProjNoJitter: matrix_float4x4
        var previousViewProjNoJitter: matrix_float4x4
    }

    private struct TemporalInvalidationKey: Equatable {
        let fractalType: Int32
        let fractalIterations: Int
        let maxRaySteps: Int
        let minDistance: Int32
        let fractalScale: Int32
        let foldingLimit: Int32
        let sphereRadius: Int32
        let colorIterations: Int32
        let sphericalInversionMode: Int32
        let sphericalInversionRadius: Int32
        let sphereProjectionEnabled: Bool
        let sphereProjectionBlend: Int32
        let sphereProjectionRadius: Int32
        let safetyBubbleEnabled: Bool
        let safetyBubbleRadius: Int32
        let safetyBubbleShape: Int32
        let safetyBubbleFadeEnabled: Bool
        let safetyBubbleFadeWidth: Int32
        let safetyBubbleStrength: Int32
        let formulaParams: SIMD16<Int32>

        init(settings: RenderSettingsSnapshot) {
            fractalType = settings.fractalType.rawValue
            fractalIterations = settings.fractalIterations
            maxRaySteps = settings.maxRaySteps
            minDistance = Self.quantize(settings.minDistance)
            fractalScale = Self.quantize(settings.fractalScale)
            foldingLimit = Self.quantize(settings.foldingLimit)
            sphereRadius = Self.quantize(settings.sphereRadius)
            colorIterations = Self.quantize(settings.colorIterations)
            sphericalInversionMode = settings.sphericalInversionMode.rawValue
            sphericalInversionRadius = Self.quantize(settings.sphericalInversionRadius)
            sphereProjectionEnabled = settings.sphereProjectionEnabled
            sphereProjectionBlend = Self.quantize(settings.sphereProjectionBlend)
            sphereProjectionRadius = Self.quantize(settings.sphereProjectionRadius)
            safetyBubbleEnabled = settings.safetyBubbleEnabled
            safetyBubbleRadius = Self.quantize(settings.safetyBubbleRadius)
            safetyBubbleShape = Self.quantize(settings.safetyBubbleShape)
            safetyBubbleFadeEnabled = settings.safetyBubbleFadeEnabled
            safetyBubbleFadeWidth = Self.quantize(settings.safetyBubbleFadeWidth)
            safetyBubbleStrength = Self.quantize(settings.safetyBubbleStrength)
            formulaParams = SIMD16<Int32>(
                Self.quantize(FormulaCatalog.getParam(settings.formulaParams, index: 0)),
                Self.quantize(FormulaCatalog.getParam(settings.formulaParams, index: 1)),
                Self.quantize(FormulaCatalog.getParam(settings.formulaParams, index: 2)),
                Self.quantize(FormulaCatalog.getParam(settings.formulaParams, index: 3)),
                Self.quantize(FormulaCatalog.getParam(settings.formulaParams, index: 4)),
                Self.quantize(FormulaCatalog.getParam(settings.formulaParams, index: 5)),
                Self.quantize(FormulaCatalog.getParam(settings.formulaParams, index: 6)),
                Self.quantize(FormulaCatalog.getParam(settings.formulaParams, index: 7)),
                Self.quantize(FormulaCatalog.getParam(settings.formulaParams, index: 8)),
                Self.quantize(FormulaCatalog.getParam(settings.formulaParams, index: 9)),
                Self.quantize(FormulaCatalog.getParam(settings.formulaParams, index: 10)),
                Self.quantize(FormulaCatalog.getParam(settings.formulaParams, index: 11)),
                Self.quantize(FormulaCatalog.getParam(settings.formulaParams, index: 12)),
                Self.quantize(FormulaCatalog.getParam(settings.formulaParams, index: 13)),
                Self.quantize(FormulaCatalog.getParam(settings.formulaParams, index: 14)),
                Self.quantize(FormulaCatalog.getParam(settings.formulaParams, index: 15))
            )
        }

        private static func quantize(_ value: Float) -> Int32 {
            Int32(clamping: Int((value * 10_000).rounded()))
        }
    }

    /// Benchmark-only shading-ablation mode routed into `uniforms.benchAblate`
    /// (>=10 activates fragmentMain's benchAblate branches). Always 0 outside a
    /// THRESHOLD_BENCHMARK run, so shipping behavior is untouched. The env value
    /// is the launch default; plan-mode benchmark jobs may retarget it between
    /// jobs (MacBenchmarkHarness) — a racy-by-design gate like the other
    /// benchmark toggles (main-actor write, render-thread read, measurement-only).
    static let benchAblateModeEnvDefault: UInt32 = {
        guard BenchmarkMode.isActive,
              let v = ProcessInfo.processInfo.environment["THRESHOLD_BENCHMARK_ABLATE"],
              let n = UInt32(v), n >= 10 else { return 0 }
        return n
    }()
    nonisolated(unsafe) static var benchAblateMode: UInt32 = benchAblateModeEnvDefault

    /// Synthetic environment for headless/dev testing (THRESHOLD_SYNTHETIC_ENV:
    /// `floor:y` · `sphere:x,y,z,r` · `box:cx,cy,cz,hx,hy,hz` joined by `;`,
    /// or "1" for a default demo room) — Mac has no room sensing to scan. nil
    /// (the normal case) leaves Environment Scrunch driven by its toggle alone,
    /// which on this platform means off.
    private static let syntheticEnvSpec: String? =
        ProcessInfo.processInfo.environment["THRESHOLD_SYNTHETIC_ENV"]
    private var macEnvGrid: EnvironmentSDFGrid?
    private var macEnvGridBakeAttempted = false

    /// Fractal distance cache (conservative distance-field grid) prototype,
    /// opt-in via THRESHOLD_DIST_CACHE=1 so the benchmark harness can A/B it.
    private static let distCacheRequested =
        ProcessInfo.processInfo.environment["THRESHOLD_DIST_CACHE"] == "1"
    private var distCache: FractalDistanceCache?
    private var distCacheInitAttempted = false
    /// Bake key for the frame being encoded; nil = cache ineligible this frame
    /// (no bake dispatch, no residency, shader sees enabled == 0).
    private var distCachePendingKey: Int?

    private static let alignedUniformsSize = (MemoryLayout<UniformsArray>.size + 0xFF) & -0x100
    private static let maxBuffersInFlight = 2
    private static let defaultTargetPosition = SIMD3<Float>(0.1, 0.1, 0.1)
    private static let minDetailScale: Float = 0.05
    // Manual scroll/pinch zoom ceiling. Raised for infinite-zoom: lets manual zoom
    // dive as deep as the auto driver (RenderSettings.infiniteZoomMaxScale). The
    // fp32-safe band ends ~4096× before the Phase 2 octave-rebase is needed.
    private static let maxDetailScale: Float = 4096.0
    private static let mouseRotationSpeed: Float = 0.006
    private static let mousePanSpeed: Float = 0.003
    private static let scrollZoomSpeed: Float = 0.035
    private static let keyboardMoveSpeed: Float = 1.6

    private let device: MTLDevice
    private let metalLayer: CAMetalLayer
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let depthPixelFormat: MTLPixelFormat
    private let colorPixelFormat: MTLPixelFormat
    private let vertexDescriptor: MTLVertexDescriptor
    private let specializedPipelineCache = MacSpecializedPipelineCache()
    /// Holds the active runtime-compiled custom (`.threshfx`) library + hash.
    /// Read on the render thread, written by the activation handler; guarded.
    private let customShaderBox = MacCustomShaderBox()
    private let spatialUpscaler: MacSpatialUpscaler
    private let temporalUpscaler: MacTemporalUpscaler
    /// Dynamic-resolution controller: lowers the offscreen render scale under GPU
    /// load and recovers toward the user's chosen scale. Only engaged while an
    /// upscaler is active (the user has opted into a sub-native `resolutionScale`).
    private let adaptiveResolution = AdaptiveResolutionController()
    private let blitPipelineState: MTLRenderPipelineState?
    private let motionPipelineState: MTLRenderPipelineState?
    private let clearColor: MTLClearColor
    private let inputController: ThresholdMacInputController
    private let uiUpdateCoordinator: UIUpdateCoordinator
    private let parameterUpdateCoordinator: ParameterUpdateCoordinator
    private let mesh: MTKMesh
    private let meshBindings: [CachedMeshBinding]
    private let uniformBuffers: [MTLBuffer]
    /// Per-frame GPU atomic counters [stepSum, hitCount] for live step profiling,
    /// ringed alongside `uniformBuffers` so the completion handler can read a slot
    /// the GPU has finished with. Bound every frame; only written by the shader
    /// when profiling is armed (see fragmentShaderMono / benchCollectSteps).
    private let benchCounterBuffers: [MTLBuffer]
    private let inFlightSemaphore = DispatchSemaphore(value: maxBuffersInFlight)
    private let baseRotationMatrix = matrix4x4_rotation(radians: -.pi / 2, axis: [0, 1, 0])
    private let startTime = CACurrentMediaTime()

    private var uniformBufferIndex = 0
    private var lastFrameTime = CACurrentMediaTime()
    private var smoothedFPS: Double = 0
    // GPU time per frame, smoothed. Written on the command-buffer completion
    // thread, read on the render thread — hence the lock. Surfaces the real,
    // vsync-independent render cost to the perf HUD.
    private let gpuFrameMsHolder = OSAllocatedUnfairLock<Double>(initialState: 0)
    // Latest measured average march steps to converge (per hit pixel). Written on
    // the completion thread when step profiling is armed, read on the render
    // thread to feed the perf dashboard. 0 = not measuring.
    private let avgStepsHolder = OSAllocatedUnfairLock<Double>(initialState: 0)
    private var smoothedScale: Float = 1.0
    private var smoothedMaxViewDistance: Float = RenderSettings.maxViewDistance
    private var drawableSize: CGSize = .zero
    private var depthTexture: MTLTexture?

    // Stage B temporal-upscaling state. Motion vectors reproject world positions
    // (reconstructed from the offscreen depth) through the previous frame's
    // un-jittered view-projection; the projection is sub-pixel jittered per frame
    // so the temporal scaler can resolve detail below native resolution.
    private var motionCurrentInvViewProj = matrix_identity_float4x4
    private var motionCurrentViewProjNoJitter = matrix_identity_float4x4
    private var motionPreviousViewProjNoJitter = matrix_identity_float4x4
    private var hasPreviousMotionMatrices = false
    private var currentJitterNDC = SIMD2<Float>.zero
    private var currentJitterPixels = SIMD2<Float>.zero
    private var haltonIndex: UInt32 = 0
    private var wasTemporalActive = false
    private var temporalInvalidationKey: TemporalInvalidationKey?

    // Shared music-reactive engine — same type used by the visionOS `Renderer`,
    // so the response-curve / LFO / dispatch math lives in exactly one place.
    private let musicReactiveEngine = MusicReactiveEngine()

    // Tilt-to-orbit sensor. On macOS this is the Intel-MacBook Sudden Motion
    // Sensor (IOKit); on iPad it is the CoreMotion gyroscope/attitude reader.
    // Both expose the same `TiltMotionSensor` interface so `applyTiltControl`
    // is platform-agnostic.
    private let motionSensor: any TiltMotionSensor = PlatformTiltSensor()
    private var wasTiltControlEnabled = false

    init?(device: MTLDevice,
                    appModel: AppModel,
                    inputController: ThresholdMacInputController,
          metalLayer: CAMetalLayer,
          colorPixelFormat: MTLPixelFormat,
          depthPixelFormat: MTLPixelFormat,
          clearColor: MTLClearColor) {
        self.device = device
        self.metalLayer = metalLayer
        self.depthPixelFormat = depthPixelFormat
        self.colorPixelFormat = colorPixelFormat
        self.clearColor = clearColor
                self.inputController = inputController
                self.uiUpdateCoordinator = UIUpdateCoordinator(appModel: appModel)
                self.parameterUpdateCoordinator = ParameterUpdateCoordinator(appModel: appModel)

        guard let commandQueue = device.makeCommandQueue() else { return nil }
        self.commandQueue = commandQueue

        let builtPipeline: MTLRenderPipelineState
        let builtMesh: MTKMesh
        let builtVertexDescriptor = Self.buildMetalVertexDescriptor()
        do {
            builtPipeline = try Self.buildRenderPipeline(device: device, colorPixelFormat: colorPixelFormat, depthPixelFormat: depthPixelFormat, vertexDescriptor: builtVertexDescriptor)
            builtMesh = try Self.buildMesh(device: device, vertexDescriptor: builtVertexDescriptor)
        } catch {
            print("ThresholdMac renderer setup failed: \(error)")
            return nil
        }
        pipelineState = builtPipeline
        vertexDescriptor = builtVertexDescriptor
        mesh = builtMesh

        spatialUpscaler = MacSpatialUpscaler(device: device,
                                             colorFormat: colorPixelFormat,
                                             depthFormat: depthPixelFormat)
        temporalUpscaler = MacTemporalUpscaler(device: device,
                                               colorFormat: colorPixelFormat,
                                               depthFormat: depthPixelFormat)
        blitPipelineState = Self.buildBlitPipeline(device: device, colorPixelFormat: colorPixelFormat)
        motionPipelineState = Self.buildMotionPipeline(device: device)

        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .less
        depthDescriptor.isDepthWriteEnabled = true
        guard let depthState = device.makeDepthStencilState(descriptor: depthDescriptor) else { return nil }
        self.depthState = depthState

        var buffers: [MTLBuffer] = []
        var benchBuffers: [MTLBuffer] = []
        for index in 0..<Self.maxBuffersInFlight {
            guard let buffer = device.makeBuffer(length: Self.alignedUniformsSize, options: .storageModeShared) else { return nil }
            buffer.label = "ThresholdMac Uniforms \(index)"
            buffers.append(buffer)
            guard let benchBuffer = device.makeBuffer(length: MemoryLayout<UInt32>.stride * 2, options: .storageModeShared) else { return nil }
            benchBuffer.label = "ThresholdMac BenchCounters \(index)"
            benchBuffers.append(benchBuffer)
        }
        uniformBuffers = buffers
        benchCounterBuffers = benchBuffers

        meshBindings = builtMesh.vertexDescriptor.layouts.enumerated().compactMap { index, layout in
            guard let layout = layout as? MDLVertexBufferLayout, layout.stride != 0 else { return nil }
            let vertexBuffer = builtMesh.vertexBuffers[index]
            return CachedMeshBinding(bufferIndex: index, buffer: vertexBuffer.buffer, offset: vertexBuffer.offset)
        }
    }

    func drawableSizeDidChange(_ size: CGSize) {
        drawableSize = size
        metalLayer.drawableSize = size
        // A resize transient (and the new pixel count) shouldn't bias the budget.
        adaptiveResolution.reset()
    }

    // MARK: - Headless benchmark support (BenchmarkMode / MacBenchmarkHarness)

    private var benchColorTexture: MTLTexture?
    private var benchDepthTexture: MTLTexture?
    /// When set, animation time is pinned to this value for the next frame(s) —
    /// used by `captureBenchmarkBytes` so PNG regression captures are
    /// phase-deterministic. Always nil outside the harness.
    private var benchFixedTime: Float?

    /// During a pinned-time capture, also pin the CPU-accumulated color-cycle
    /// phases (they integrate ∫speed·dt across the run, so they land at a
    /// run-dependent value that `time` pinning alone can't fix). Identity when
    /// `benchFixedTime` is nil, i.e. on every normal frame.
    private func benchStableColorScheme(_ scheme: ColorSchemeParams) -> ColorSchemeParams {
        guard benchFixedTime != nil else { return scheme }
        var s = scheme
        s.hueCyclePhase = 1.0
        s.pulseCyclePhase = 1.0
        s.animTime = 5.0
        s.gradientOffset = 0.25
        return s
    }

    /// Shared offscreen raymarch encode used by the headless benchmark harness.
    /// Renders one native-resolution frame into the given targets and blocks until
    /// the GPU finishes, returning measured cost. Faithful to the shipping raymarch
    /// GPU cost: same specialized pipeline, uniforms, distance-estimator, and
    /// in-kernel step counter as `draw(appModel:)`'s native path — it just bypasses
    /// the CAMetalLayer drawable / MTKView display link / MetalFX so a benchmark
    /// can run continuously with no on-screen window.
    private func encodeBenchmarkPass(color: MTLTexture, depth: MTLTexture, appModel: AppModel)
        -> (gpuMs: Double, cpuEncodeMs: Double, avgSteps: Double)? {
        let cpuStart = CACurrentMediaTime()
        let frameSlot = uniformBufferIndex
        let uniformBuffer = uniformBuffers[frameSlot]
        uniformBufferIndex = (uniformBufferIndex + 1) % uniformBuffers.count
        writeUniforms(to: uniformBuffer, appModel: appModel)

        let benchBuffer = benchCounterBuffers[frameSlot]
        let collectSteps = BenchmarkManager.shared.shouldCollectSteps
        if collectSteps { memset(benchBuffer.contents(), 0, MemoryLayout<UInt32>.stride * 2) }

        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return nil }
        // Fractal distance cache: bake in the measured command buffer so the
        // harness sees the cache's true amortized cost (rebake only on change).
        if let distCache, let key = distCachePendingKey {
            distCache.encodeBakeIfNeeded(commandBuffer: commandBuffer,
                                         uniformBuffer: uniformBuffer,
                                         key: key)
        }
        let pipeline = resolveActivePipeline(appModel: appModel)
        let descriptor = makeOffscreenRenderPassDescriptor(color: color, depth: depth)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return nil }
        encodeRaymarch(into: encoder, pipeline: pipeline, uniformBuffer: uniformBuffer, benchBuffer: benchBuffer)
        encoder.endEncoding()
        let cpuEncodeMs = (CACurrentMediaTime() - cpuStart) * 1000.0

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        let gpuMs = max(0.0, (commandBuffer.gpuEndTime - commandBuffer.gpuStartTime) * 1000.0)
        var avgSteps = 0.0
        if collectSteps {
            let counters = benchBuffer.contents().bindMemory(to: UInt32.self, capacity: 2)
            let hit = counters[1]
            avgSteps = hit > 0 ? Double(counters[0]) / Double(hit) : 0
        }
        return (gpuMs, cpuEncodeMs, avgSteps)
    }

    /// Perf-measurement path: renders into cached `.private` targets (no CPU
    /// readback overhead) and returns cost.
    func renderBenchmarkFrame(appModel: AppModel, width: Int, height: Int)
        -> (gpuMs: Double, cpuEncodeMs: Double, avgSteps: Double)? {
        guard width > 0, height > 0 else { return nil }
        drawableSize = CGSize(width: width, height: height)

        if benchColorTexture?.width != width || benchColorTexture?.height != height {
            let cd = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: colorPixelFormat, width: width, height: height, mipmapped: false)
            cd.usage = [.renderTarget, .shaderRead]
            cd.storageMode = .private
            let dd = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: depthPixelFormat, width: width, height: height, mipmapped: false)
            dd.usage = [.renderTarget]
            dd.storageMode = .private
            benchColorTexture = device.makeTexture(descriptor: cd)
            benchDepthTexture = device.makeTexture(descriptor: dd)
        }
        guard let color = benchColorTexture, let depth = benchDepthTexture else { return nil }
        return encodeBenchmarkPass(color: color, depth: depth, appModel: appModel)
    }

    /// Visual-verification path: renders one frame into a CPU-readable `.shared`
    /// color target and returns the raw BGRA8 bytes so the harness can write a PNG
    /// (used to confirm an optimization didn't change the image). Animation time is
    /// pinned to a fixed value for this frame so captures are phase-deterministic
    /// (color cycling otherwise lands at a run-dependent phase → bogus diffs). Not
    /// on the perf hot path — allocates per call.
    func captureBenchmarkBytes(appModel: AppModel, width: Int, height: Int)
        -> (bytes: Data, bytesPerRow: Int)? {
        guard width > 0, height > 0 else { return nil }
        benchFixedTime = 5.0
        defer { benchFixedTime = nil }
        drawableSize = CGSize(width: width, height: height)
        let cd = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: colorPixelFormat, width: width, height: height, mipmapped: false)
        cd.usage = [.renderTarget, .shaderRead]
        cd.storageMode = .shared
        let dd = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: depthPixelFormat, width: width, height: height, mipmapped: false)
        dd.usage = [.renderTarget]
        dd.storageMode = .private
        guard let color = device.makeTexture(descriptor: cd),
              let depth = device.makeTexture(descriptor: dd),
              encodeBenchmarkPass(color: color, depth: depth, appModel: appModel) != nil else { return nil }

        let bytesPerRow = width * 4
        var data = Data(count: bytesPerRow * height)
        data.withUnsafeMutableBytes { raw in
            color.getBytes(raw.baseAddress!, bytesPerRow: bytesPerRow,
                           from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        return (data, bytesPerRow)
    }

    func draw(appModel: AppModel) {
        guard appModel.isAppActive,
              drawableSize.width > 1,
              drawableSize.height > 1 else {
            return
        }

        // Brackets the whole frame (every return path below) as one Instruments
        // signpost interval; see RenderSignposts.swift.
        let frameTraceState = RenderTrace.begin("Frame")
        defer { RenderTrace.end("Frame", frameTraceState) }

        // The drawable is acquired later (after the in-flight gate) so a busy
        // drawable pool can't block the render thread during CPU prep. The
        // resolution math uses the view's known drawable size instead; this
        // equals the drawable's texture dimensions except for a brief window
        // during a live resize, which the post-acquisition size guard below
        // catches (that frame is skipped rather than blit at the wrong scale).
        let drawableWidth = Int(drawableSize.width)
        let drawableHeight = Int(drawableSize.height)

        // Decide whether to render at reduced resolution and MetalFX-upscale to
        // the drawable. The offscreen target stays in the drawable's sRGB color
        // format so the raymarch pipeline needs no changes; only sub-native
        // scales engage a scaler. Temporal upscaling is preferred when supported
        // (better stability/detail); the spatial scaler is the fallback.
        let resolutionScale = appModel.renderSettings.resolutionScale
        var temporalPass: (color: MTLTexture, depth: MTLTexture, motion: MTLTexture, output: MTLTexture)?
        var spatialPass: (color: MTLTexture, depth: MTLTexture, output: MTLTexture)?
        if resolutionScale < 0.985, blitPipelineState != nil {
            // Dynamic resolution: the user's `resolutionScale` is the ceiling; the
            // controller renders at or below it to hold the GPU frame budget and
            // recovers when there is headroom. MetalFX reconstructs the detail.
            let effectiveScale = adaptiveResolution.currentScale(ceiling: resolutionScale)
            let inputWidth = max(1, Int((Float(drawableWidth) * effectiveScale).rounded()))
            let inputHeight = max(1, Int((Float(drawableHeight) * effectiveScale).rounded()))
            // MetalFX temporal supports at most 3× per dimension and rejects
            // inputs with a short edge under `minimumInputShortEdge`; clamp the
            // temporal input up to both floors so the lowest slider settings
            // stay on the temporal path instead of falling back to spatial.
            let minTemporalWidth = min(drawableWidth, max(
                Int((Double(drawableWidth) / MacTemporalUpscaler.maxScaleFactor).rounded(.up)),
                MacTemporalUpscaler.minimumInputShortEdge))
            let minTemporalHeight = min(drawableHeight, max(
                Int((Double(drawableHeight) / MacTemporalUpscaler.maxScaleFactor).rounded(.up)),
                MacTemporalUpscaler.minimumInputShortEdge))
            let temporalInputWidth = max(inputWidth, minTemporalWidth)
            let temporalInputHeight = max(inputHeight, minTemporalHeight)
            if motionPipelineState != nil,
               temporalUpscaler.prepare(inputWidth: temporalInputWidth,
                                        inputHeight: temporalInputHeight,
                                        outputWidth: drawableWidth,
                                        outputHeight: drawableHeight),
               let color = temporalUpscaler.colorTexture,
               let depth = temporalUpscaler.depthTexture,
               let motion = temporalUpscaler.motionTexture,
               let output = temporalUpscaler.outputTexture {
                temporalPass = (color, depth, motion, output)
            } else if spatialUpscaler.prepare(inputWidth: inputWidth,
                                              inputHeight: inputHeight,
                                              outputWidth: drawableWidth,
                                              outputHeight: drawableHeight),
                      let color = spatialUpscaler.colorTexture,
                      let depth = spatialUpscaler.depthTexture,
                      let output = spatialUpscaler.outputTexture {
                spatialPass = (color, depth, output)
            }
        }

        // Sub-pixel projection jitter only applies on the temporal path (the
        // scaler needs jittered samples to accumulate detail). Compute it before
        // `writeUniforms` so `makeUniforms` can bake it into the projection.
        if temporalPass != nil {
            haltonIndex = haltonIndex &+ 1
            let jx = Self.halton(haltonIndex, base: 2) - 0.5
            let jy = Self.halton(haltonIndex, base: 3) - 0.5
            currentJitterPixels = SIMD2<Float>(jx, jy)
            let w = Float(max(temporalUpscaler.inputSize.width, 1))
            let h = Float(max(temporalUpscaler.inputSize.height, 1))
            currentJitterNDC = SIMD2<Float>(2.0 * jx / w, 2.0 * jy / h)
        } else {
            currentJitterPixels = .zero
            currentJitterNDC = .zero
        }

        let inFlightWaitTraceState = RenderTrace.begin("InFlight Wait")
        let inFlightWaitResult = inFlightSemaphore.wait(timeout: .now())
        RenderTrace.end("InFlight Wait", inFlightWaitTraceState)
        guard inFlightWaitResult == .success else { return }

        // Acquire the drawable as late as possible — only after the in-flight
        // gate has admitted this frame — so a busy drawable pool stalls nothing
        // but this already-committed frame.
        guard let drawable = metalLayer.nextDrawable() else {
            inFlightSemaphore.signal()
            return
        }
        // This frame's upscaler targets and output size were computed from
        // `drawableSize`. During a live resize the layer can briefly hand back a
        // drawable whose texture lags that size; skip the rare mismatched frame
        // rather than blit at the wrong scale — the next frame re-syncs.
        guard drawable.texture.width == drawableWidth,
              drawable.texture.height == drawableHeight else {
            inFlightSemaphore.signal()
            return
        }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            inFlightSemaphore.signal()
            return
        }
        // Traces this command buffer's commit→completion latency regardless of
        // which of the frame's several `commandBuffer.commit()` call sites ends
        // up firing.
        RenderTrace.traceGPU("GPU Frame", commandBuffer: commandBuffer)

        // The direct (native-resolution) path renders straight into the drawable
        // and needs the drawable-sized depth target.
        let directPassDescriptor: MTLRenderPassDescriptor?
        if temporalPass == nil, spatialPass == nil {
            guard let descriptor = makeRenderPassDescriptor(drawable: drawable) else {
                inFlightSemaphore.signal()
                return
            }
            directPassDescriptor = descriptor
        } else {
            directPassDescriptor = nil
        }

        // Feed measured GPU frame time to the dynamic-resolution controller, but
        // only for frames that actually upscaled — a native-resolution frame's
        // cost would bias the budget for the upscaled path.
        let didUpscale = temporalPass != nil || spatialPass != nil
        commandBuffer.addCompletedHandler { [inFlightSemaphore, adaptiveResolution, gpuFrameMsHolder] buffer in
            inFlightSemaphore.signal()
            let gpuSeconds = buffer.gpuEndTime - buffer.gpuStartTime
            if gpuSeconds > 0 {
                // Smooth on every frame (not just upscaled ones) so the HUD has a
                // GPU-cost reading at native resolution too.
                let ms = gpuSeconds * 1000.0
                gpuFrameMsHolder.withLock { smoothed in
                    smoothed = smoothed <= 0 ? ms : smoothed + (ms - smoothed) * 0.1
                }
            }
            if didUpscale {
                adaptiveResolution.record(gpuTime: gpuSeconds)
            }
        }

        let frameSlot = uniformBufferIndex
        let uniformBuffer = uniformBuffers[frameSlot]
        uniformBufferIndex = (uniformBufferIndex + 1) % uniformBuffers.count
        writeUniforms(to: uniformBuffer, appModel: appModel)

        // Fractal distance cache: (re)bake before the render pass when a
        // DE-shaping parameter changed. Same command buffer ⇒ never stale.
        if let distCache, let key = distCachePendingKey {
            distCache.encodeBakeIfNeeded(commandBuffer: commandBuffer,
                                         uniformBuffer: uniformBuffer,
                                         key: key)
        }

        // Step profiling: zero this slot's counters before the GPU accumulates
        // into them, then read back the converged-ray average once the frame
        // completes. When off we still bind the buffer (the shader argument is
        // declared) but pay only one bool read, and push 0 so the HUD clears.
        let benchBuffer = benchCounterBuffers[frameSlot]
        let collectSteps = BenchmarkManager.shared.shouldCollectSteps
        if collectSteps {
            memset(benchBuffer.contents(), 0, MemoryLayout<UInt32>.stride * 2)
        }
        commandBuffer.addCompletedHandler { [avgStepsHolder, benchBuffer, collectSteps] _ in
            guard collectSteps else { avgStepsHolder.withLock { $0 = 0 }; return }
            let counters = benchBuffer.contents().bindMemory(to: UInt32.self, capacity: 2)
            let hitCount = counters[1]
            let avg = hitCount > 0 ? Double(counters[0]) / Double(hitCount) : 0
            avgStepsHolder.withLock { $0 = avg }
        }

        let activePipeline = resolveActivePipeline(appModel: appModel)

        if let temporalPass, let blitPipelineState, let motionPipelineState {
            // 1. Raymarch into the low-resolution offscreen target. Depth is
            //    stored (not discarded) so the motion pass + scaler can read it.
            let offscreenDescriptor = makeOffscreenRenderPassDescriptor(color: temporalPass.color,
                                                                        depth: temporalPass.depth,
                                                                        storeDepth: true)
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: offscreenDescriptor) else {
                commandBuffer.commit()
                return
            }
            encodeRaymarch(into: encoder, pipeline: activePipeline, uniformBuffer: uniformBuffer, benchBuffer: benchBuffer)
            encoder.endEncoding()

            // 2. Motion-vector pass: reconstruct world position from depth and
            //    reproject through the previous frame's view-projection.
            let motionDescriptor = MTLRenderPassDescriptor()
            motionDescriptor.colorAttachments[0].texture = temporalPass.motion
            motionDescriptor.colorAttachments[0].loadAction = .dontCare
            motionDescriptor.colorAttachments[0].storeAction = .store
            guard let motionEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: motionDescriptor) else {
                commandBuffer.commit()
                return
            }
            motionEncoder.setRenderPipelineState(motionPipelineState)
            motionEncoder.setFragmentTexture(temporalPass.depth, index: 0)
            var motionParams = MacMotionParams(currentInvViewProj: motionCurrentInvViewProj,
                                               currentViewProjNoJitter: motionCurrentViewProjNoJitter,
                                               previousViewProjNoJitter: motionPreviousViewProjNoJitter)
            motionEncoder.setFragmentBytes(&motionParams,
                                           length: MemoryLayout<MacMotionParams>.stride,
                                           index: 0)
            motionEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            motionEncoder.endEncoding()

            // 3. MetalFX temporal upscale → full-resolution output. Reset history
            //    when temporal scaling has just (re)engaged.
            temporalUpscaler.encode(commandBuffer: commandBuffer,
                                    jitterPixels: currentJitterPixels,
                                    forceReset: !wasTemporalActive)

            // 4. Blit the upscaled output to the drawable.
            let blitDescriptor = MTLRenderPassDescriptor()
            blitDescriptor.colorAttachments[0].texture = drawable.texture
            blitDescriptor.colorAttachments[0].loadAction = .dontCare
            blitDescriptor.colorAttachments[0].storeAction = .store
            guard let blitEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: blitDescriptor) else {
                commandBuffer.commit()
                return
            }
            blitEncoder.setRenderPipelineState(blitPipelineState)
            blitEncoder.setFragmentTexture(temporalPass.output, index: 0)
            blitEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            blitEncoder.endEncoding()

            wasTemporalActive = true
        } else if let spatialPass, let blitPipelineState {
            // 1. Raymarch into the low-resolution offscreen target.
            let offscreenDescriptor = makeOffscreenRenderPassDescriptor(color: spatialPass.color,
                                                                        depth: spatialPass.depth)
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: offscreenDescriptor) else {
                commandBuffer.commit()
                return
            }
            encodeRaymarch(into: encoder, pipeline: activePipeline, uniformBuffer: uniformBuffer, benchBuffer: benchBuffer)
            encoder.endEncoding()

            // 2. MetalFX spatial upscale → full-resolution output.
            spatialUpscaler.encode(commandBuffer: commandBuffer)

            // 3. Blit the upscaled output to the drawable.
            let blitDescriptor = MTLRenderPassDescriptor()
            blitDescriptor.colorAttachments[0].texture = drawable.texture
            blitDescriptor.colorAttachments[0].loadAction = .dontCare
            blitDescriptor.colorAttachments[0].storeAction = .store
            guard let blitEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: blitDescriptor) else {
                commandBuffer.commit()
                return
            }
            blitEncoder.setRenderPipelineState(blitPipelineState)
            blitEncoder.setFragmentTexture(spatialPass.output, index: 0)
            blitEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            blitEncoder.endEncoding()

            wasTemporalActive = false
        } else if let directPassDescriptor {
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: directPassDescriptor) else {
                commandBuffer.commit()
                return
            }
            encodeRaymarch(into: encoder, pipeline: activePipeline, uniformBuffer: uniformBuffer, benchBuffer: benchBuffer)
            encoder.endEncoding()

            wasTemporalActive = false
        }

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// Encodes the raymarch draw into an active render encoder. Shared by the
    /// direct (native) and offscreen (upscaled) render passes.
    private func encodeRaymarch(into encoder: MTLRenderCommandEncoder,
                                pipeline: MTLRenderPipelineState,
                                uniformBuffer: MTLBuffer,
                                benchBuffer: MTLBuffer) {
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthState)
        // The raymarch proxy is a radius-100 ellipsoid drawn from the inside; the
        // camera sits at its center and we shade the far wall it points at. "Zoom"
        // scales that proxy by effectiveScale (detailScale up to 40), so when zoomed
        // in the far wall recedes past the fixed projection far plane (farZ = 500)
        // and the rasterizer clips the very center triangles the forward rays need —
        // punching a background hole that widens as you zoom. Clamp depth instead of
        // clipping so the proxy always covers the screen; the fragment shader writes
        // its own per-pixel hit depth anyway, so clamped proxy z is inert.
        encoder.setDepthClipMode(.clamp)
        for binding in meshBindings {
            encoder.setVertexBuffer(binding.buffer, offset: binding.offset, index: binding.bufferIndex)
        }
        encoder.setVertexBuffer(uniformBuffer, offset: 0, index: BufferIndex.uniforms.rawValue)
        encoder.setFragmentBuffer(uniformBuffer, offset: 0, index: BufferIndex.uniforms.rawValue)
        // Environment Scrunch grid is reached bindlessly (GPU address in the
        // uniforms) — make it resident for the fragment march.
        if let envGrid = macEnvGrid {
            encoder.useResource(envGrid.buffer, usage: .read, stages: .fragment)
        }
        // Fractal distance cache grid is also bindless (GPU address in the
        // uniforms) — declare residency whenever it's enabled this frame.
        if let distCache, distCachePendingKey != nil {
            encoder.useResource(distCache.buffer, usage: .read, stages: .fragment)
        }
        // fragmentShaderMono declares benchCounters at this index; bind every
        // frame so the argument is satisfied even when profiling is off.
        encoder.setFragmentBuffer(benchBuffer, offset: 0, index: BufferIndex.benchCounters.rawValue)

        for submesh in mesh.submeshes {
            encoder.drawIndexedPrimitives(type: submesh.primitiveType,
                                          indexCount: submesh.indexCount,
                                          indexType: submesh.indexType,
                                          indexBuffer: submesh.indexBuffer.buffer,
                                          indexBufferOffset: submesh.indexBuffer.offset)
        }
    }

    private func makeOffscreenRenderPassDescriptor(color: MTLTexture, depth: MTLTexture, storeDepth: Bool = false) -> MTLRenderPassDescriptor {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = color
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = clearColor
        descriptor.depthAttachment.texture = depth
        descriptor.depthAttachment.loadAction = .clear
        descriptor.depthAttachment.storeAction = storeDepth ? .store : .dontCare
        descriptor.depthAttachment.clearDepth = 1.0
        return descriptor
    }

    /// Mirrors the visionOS `FunctionConstantConfig.specializedMandelbulbPower`:
    /// returns the integer Mandelbulb power for `fastPowR` dead-code elimination
    /// when the power is a near-integer from the supported set, else `nil`.
    private static func specializedMandelbulbPower(fractalType: FractalModelType,
                                                   formulaParams: FormulaParams) -> Int32? {
        guard fractalType == .mandelbulb else { return nil }
        let rawPower = FormulaCatalog.getParam(formulaParams, index: 0)
        let rounded = roundf(rawPower)
        guard abs(rawPower - rounded) < 0.01,
              [2, 3, 4, 5, 6, 8, 10, 12, 16].contains(Int(rounded)) else {
            return nil
        }
        return Int32(rounded)
    }

    /// Picks the function-constant–specialized `fragmentShaderMono` pipeline for
    /// the current settings when available, otherwise the generic pipeline.
    /// Kicks off an async build the first time a configuration is seen so future
    /// frames get the fully-unrolled fast path without hitching the render thread.
    /// Updates `appModel.isUsingSpecializedPipeline` (drives the bolt indicator).
    private func resolveActivePipeline(appModel: AppModel) -> MTLRenderPipelineState {
        let settings = appModel.renderSettings
        // deIterationMismatch biases the baked FC_FRACTAL_ITERATIONS (geometry fold count)
        // while the DE stays normalized to the unbiased count (RenderPrecompute) — reproduces
        // the "Accidental Sphere Projection" under-fold. Negative → fewer folds → sphere.
        // Flows into the cache key below, so each bias gets its own specialized pipeline.
        // See Context/ACCIDENTAL_SPHERE_PROJECTION.md.
        let geomIterations = max(0, settings.fractalIterations + Int(settings.deIterationMismatch.rounded()))
        let iterations = Int32(geomIterations)
        let raySteps = Int32(settings.maxRaySteps)
        let fractalType = settings.fractalType.rawValue
        let colorIterations = Int32(settings.colorIterations)
        let power = Self.specializedMandelbulbPower(
            fractalType: settings.fractalType,
            formulaParams: settings.formulaParams
        )

        let powerKey = power.map { "_P\($0)" } ?? ""
        // Atomic (library, hash) read so the cache-key hash and the build library
        // always come from the SAME activation. Namespace custom-formula pipelines
        // by source hash so library-A's FT1000 pipeline is never reused for
        // library-B (matches visionOS `CX{hash}_`), and so deactivation can evict
        // exactly one formula's set.
        let custom = customShaderBox.snapshot()
        let customPrefix: String = {
            // Namespace whenever ANY custom library is active (custom fractal OR a
            // space warp riding a built-in), not only fractalType == .custom.
            guard let h = custom.hash else { return "" }
            return "CX\(h)_"
        }()
        // A scene with NO transforms bakes FC_HAS_SPACEWARP=false, so the whole
        // space-warp seam (applyWarpOp switch, per-op loop, deScale threading) is
        // dead-code-eliminated from the hot DE path. Conservative: any non-empty
        // stack OR any active custom library (which may carry a `.threshfx` warp)
        // keeps it ON. Derived from the SAME `settings` snapshot the constant is set
        // from and folded into the cache key, so the key and the baked FC can never
        // desync (no stale-pipeline "transforms silently vanish" bug). Toggling the
        // first transform flips the key → cache miss → the generic pipeline (FC unset
        // → defaults ON) renders correctly while the new variant compiles.
        let hasSpaceWarp = !settings.spaceWarpStack.isEmpty || custom.hash != nil
        let key = customPrefix + "FT\(fractalType)_FI\(iterations)_RS\(raySteps)_CI\(colorIterations)\(powerKey)_SW\(hasSpaceWarp ? 1 : 0)"

        if let specialized = specializedPipelineCache.pipeline(for: key) {
            appModel.isUsingSpecializedPipeline = true
            return specialized
        }

        // Not ready yet — schedule a background build and use the generic
        // pipeline for this frame.
        if specializedPipelineCache.beginBuildIfNeeded(key) {
            buildSpecializedPipeline(
                key: key,
                iterations: iterations,
                raySteps: raySteps,
                fractalType: fractalType,
                colorIterations: colorIterations,
                power: power,
                hasSpaceWarp: hasSpaceWarp,
                customLibrary: custom.library
            )
        }
        appModel.isUsingSpecializedPipeline = false
        return pipelineState
    }

    /// Asynchronously compiles a specialized `fragmentShaderMono` pipeline and
    /// stores it in the cache. Function-constant specialization unrolls the
    /// iteration/ray-step loops and devirtualizes the fractal DE dispatch.
    private func buildSpecializedPipeline(key: String,
                                          iterations: Int32,
                                          raySteps: Int32,
                                          fractalType: Int32,
                                          colorIterations: Int32,
                                          power: Int32?,
                                          hasSpaceWarp: Bool,
                                          customLibrary: MTLLibrary?) {
        let cache = specializedPipelineCache
        // When a custom `.threshfx` is active, build against its runtime-compiled
        // library (a drop-in for default.metallib whose FractalFormulas.h has the
        // `case FractalTypeCustom` arm). Built-ins resolve identically against it.
        // `customLibrary` is snapshotted together with the key's hash in
        // resolveActivePipeline, so the pipeline and its `CX{hash}_` key agree.
        guard let library = customLibrary ?? device.makeDefaultLibrary(),
              let vertexFunction = library.makeFunction(name: "screenshotVertexShader") else {
            cache.failBuild(key)
            return
        }

        // Metal function-constant indices (mirrors the visionOS
        // `FunctionConstantIndex`, which is unavailable on macOS because it
        // lives in a CompositorServices-only file): 0=fractalIterations,
        // 6=maxRaySteps, 7=fractalType, 9=colorIterations, 12=mandelbulbPower.
        let constants = MTLFunctionConstantValues()
        var fi = iterations
        constants.setConstantValue(&fi, type: .int, index: 0)
        var rs = raySteps
        constants.setConstantValue(&rs, type: .int, index: 6)
        var ft = fractalType
        constants.setConstantValue(&ft, type: .int, index: 7)
        var ci = colorIterations
        constants.setConstantValue(&ci, type: .int, index: 9)
        if var p = power {
            constants.setConstantValue(&p, type: .int, index: 12)
        }
        // FC_HAS_SPACEWARP (index 3): bake the space-warp seam in/out. Baked false only
        // for scenes provably without any transform, letting the whole warp path DCE.
        var sw = hasSpaceWarp
        constants.setConstantValue(&sw, type: .bool, index: 3)

        let fragmentFunction: MTLFunction
        do {
            fragmentFunction = try library.makeFunction(name: "fragmentShaderMono", constantValues: constants)
        } catch {
            cache.failBuild(key)
            return
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "ThresholdMac Specialized [\(key)]"
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.vertexDescriptor = vertexDescriptor
        descriptor.rasterSampleCount = 1
        descriptor.colorAttachments[0].pixelFormat = colorPixelFormat
        descriptor.depthAttachmentPixelFormat = depthPixelFormat

        device.makeRenderPipelineState(descriptor: descriptor) { pipeline, _ in
            if let pipeline {
                cache.store(pipeline, for: key)
            } else {
                cache.failBuild(key)
            }
        }
    }

    /// A `@Sendable` activation closure for `AppModel.activateEmbeddedFormulaHandler`,
    /// bound to this renderer's custom-shader box + pipeline cache. Lets Mac/iPad
    /// load runtime-compiled `.threshfx` formulas exactly as visionOS does — the
    /// compiled library is a drop-in for `default.metallib`, so the existing
    /// function-constant specialization renders the custom DE. Captures only
    /// Sendable values (box, cache, device), never the renderer itself.
    func embeddedFormulaActivator(renderSettings: RenderSettings) -> @Sendable (EmbeddedFormula?) async throws -> Void {
        let box = customShaderBox
        let cache = specializedPipelineCache
        let device = self.device
        // RenderSettings is @unchecked Sendable; it carries the composable
        // transform-stack codegen (regenerated on structural change) that we bake
        // into the compiled library so a built-in fractal + stack runs unrolled.
        return { formula in
            try await box.activate(formula,
                                   warpStackSource: renderSettings.warpStackCodegenSource,
                                   warpStackSignature: renderSettings.warpStackCodegenSignature,
                                   device: device, cache: cache)
        }
    }

    /// A `@Sendable` recompile closure for `AppModel.forceShaderRecompileHandler`,
    /// bound to this renderer's custom-shader box + pipeline cache (the debug
    /// "Force Recompile" button). Reads the active formula from `appModel` on the
    /// main actor, then clears caches and recompiles. Captures only Sendable
    /// values (box, cache, device, appModel), never the renderer itself.
    func shaderRecompiler(appModel: AppModel) -> @Sendable () async -> String {
        let box = customShaderBox
        let cache = specializedPipelineCache
        let device = self.device
        return {
            let formula = await MainActor.run { appModel.activeEmbeddedFormula }
            return await box.forceRecompile(formula: formula, device: device, cache: cache)
        }
    }

    private func makeRenderPassDescriptor(drawable: CAMetalDrawable) -> MTLRenderPassDescriptor? {
        guard let depthTexture = depthTexture(width: drawable.texture.width, height: drawable.texture.height) else {
            return nil
        }

        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = drawable.texture
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = clearColor
        descriptor.depthAttachment.texture = depthTexture
        descriptor.depthAttachment.loadAction = .clear
        descriptor.depthAttachment.storeAction = .dontCare
        descriptor.depthAttachment.clearDepth = 1.0
        return descriptor
    }

    private func depthTexture(width: Int, height: Int) -> MTLTexture? {
        if let depthTexture, depthTexture.width == width, depthTexture.height == height {
            return depthTexture
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: depthPixelFormat,
                                                                  width: max(width, 1),
                                                                  height: max(height, 1),
                                                                  mipmapped: false)
        descriptor.usage = .renderTarget
        #if os(iOS)
        descriptor.storageMode = .memoryless
        #else
        descriptor.storageMode = .private
        #endif
        depthTexture = device.makeTexture(descriptor: descriptor)
        depthTexture?.label = "ThresholdMac Depth"
        return depthTexture
    }

    private func writeUniforms(to buffer: MTLBuffer, appModel: AppModel) {
        let now = CACurrentMediaTime()
        let deltaTime = max(1.0 / 240.0, min(now - lastFrameTime, 1.0 / 15.0))
        lastFrameTime = now

        let settings = appModel.renderSettings
        applyDesktopInput(appModel: appModel, settings: settings, deltaTime: deltaTime)
        settings.interpolateToTargets(deltaTime: Float(deltaTime))
        settings.updateLimitFlash(deltaTime: Float(deltaTime))
        settings.updateColorSchemeTransition(deltaTime: Float(deltaTime),
                                             mixedImmersionActive: appModel.immersionStyleForRenderer == .mixed)

        let isAudioMode = settings.lightingMode == .audioReactive ||
            settings.lightingMode == .visualizer ||
            settings.fractalAudioReactiveEnabled
        let hasActiveAudioSources = appModel.audioAnalyzer.isCapturing || appModel.appleMusicManager.isActive

        parameterUpdateCoordinator.scheduleParameterUpdates(
            shouldUpdateAnimation: settings.isAnimationPlaying,
            shouldUpdateAudio: isAudioMode && hasActiveAudioSources,
            deltaTime: deltaTime,
            currentTime: now
        )
        updateAudioLevels(appModel: appModel,
                          settings: settings,
                          isAudioMode: isAudioMode,
                          hasActiveAudioSources: hasActiveAudioSources)
        updateMusicReactiveParameters(appModel: appModel,
                                      settings: settings,
                                      isAudioMode: isAudioMode,
                                      hasActiveAudioSources: hasActiveAudioSources,
                                      deltaTime: Float(deltaTime))

        updateFPS(deltaTime: deltaTime)
        uiUpdateCoordinator.scheduleUIUpdate(fps: smoothedFPS,
                                             gpuMs: gpuFrameMsHolder.withLock { $0 },
                                             avgStepsPerPixel: avgStepsHolder.withLock { $0 },
                                             currentTime: now)

        let snapshot = settings.snapshot()
        updateTemporalInvalidationState(settings: snapshot)
        // benchFixedTime pins animation time for the harness's PNG-capture frame so
        // visual-regression diffs are deterministic (color cycles/warps otherwise
        // land at a run-dependent phase). nil in normal use and for perf frames.
        let effectiveElapsed = benchFixedTime ?? Float(now - startTime)
        let uniforms = makeUniforms(settings: snapshot, elapsedTime: effectiveElapsed, deltaTime: Float(deltaTime))
        let pointer = buffer.contents().bindMemory(to: UniformsArray.self, capacity: 1)
        pointer.pointee.uniforms.0 = uniforms
        pointer.pointee.uniforms.1 = uniforms
    }

    private func updateTemporalInvalidationState(settings: RenderSettingsSnapshot) {
        let newKey = TemporalInvalidationKey(settings: settings)
        if let oldKey = temporalInvalidationKey, oldKey != newKey {
            temporalUpscaler.requestReset()
            hasPreviousMotionMatrices = false
        }
        temporalInvalidationKey = newKey

        if settings.geometryState != .stable || settings.isGeometryGestureActive {
            temporalUpscaler.requestReset()
        }
    }

    private func applyDesktopInput(appModel: AppModel, settings: RenderSettings, deltaTime: TimeInterval) {
        applyTiltControl(settings: settings, deltaTime: deltaTime)

        let input = inputController.consumeFrame()

        if input.shouldResetView {
            resetDesktopView(settings: settings)
        }

        if input.sceneStep != 0 {
            let forward = input.sceneStep > 0
            Task { @MainActor [weak appModel] in
                appModel?.cycleJumpingOffScene(forward: forward)
            }
        }

        if input.shouldTogglePlayback {
            Task { @MainActor [weak appModel] in
                guard let appModel,
                      let animationManager = appModel.animationManager else { return }

                if animationManager.isPlaying {
                    animationManager.stop()
                    return
                }

                if animationManager.currentScene?.keyframes.count ?? 0 < 2 {
                    animationManager.currentScene = animationManager.scenes.first { $0.keyframes.count >= 2 }
                }
                animationManager.play()
            }
        }

        var targetRotation = settings.targetWorldRotation
        var targetDetailScale = settings.targetDetailScale
        var positionDelta = SIMD3<Float>.zero
        var orbited = false
        var zoomed = false

        let gestureSensitivity = max(GestureDefaults.gestureSensitivity / 10.0, 0.1)
        let translationSensitivity = GestureDefaults.translationSensitivity

        if simd_length_squared(input.orbitDelta) > 0 {
            let yawAngle = -input.orbitDelta.x * Self.mouseRotationSpeed * gestureSensitivity
            let pitchAngle = -input.orbitDelta.y * Self.mouseRotationSpeed * gestureSensitivity
            let yawRotation = simd_quatf(angle: yawAngle, axis: SIMD3<Float>(0, 1, 0))
            let pitchRotation = simd_quatf(angle: pitchAngle, axis: SIMD3<Float>(1, 0, 0))
            let rotated = yawRotation * targetRotation * pitchRotation
            targetRotation = abs(simd_length_squared(rotated.vector) - 1.0) > 1e-4 ? rotated.normalized : rotated
            orbited = true
        }

        if input.zoomDelta != 0 {
            let zoomFactor = exp(-input.zoomDelta * Self.scrollZoomSpeed * gestureSensitivity)
            targetDetailScale = min(Self.maxDetailScale, max(Self.minDetailScale, targetDetailScale * zoomFactor))
            zoomed = true
        }

        let zoomCompensation = simd_clamp(1.0 / pow(max(targetDetailScale, 0.01), 0.3), 0.5, 2.0)

        if simd_length_squared(input.panDelta) > 0 {
            let panScale = Self.mousePanSpeed * translationSensitivity * zoomCompensation
            positionDelta += SIMD3<Float>(input.panDelta.x * panScale, -input.panDelta.y * panScale, 0)
        }

        let moveStep = Float(deltaTime) * Self.keyboardMoveSpeed * translationSensitivity * zoomCompensation
        if input.isShiftPressed {
            if input.pressedKeys.contains(.forward) {
                positionDelta.y += moveStep
            }
            if input.pressedKeys.contains(.backward) {
                positionDelta.y -= moveStep
            }
        } else {
            if input.pressedKeys.contains(.forward) {
                positionDelta.z += moveStep
            }
            if input.pressedKeys.contains(.backward) {
                positionDelta.z -= moveStep
            }
        }
        if input.pressedKeys.contains(.left) {
            positionDelta.x -= moveStep
        }
        if input.pressedKeys.contains(.right) {
            positionDelta.x += moveStep
        }

        if positionDelta != .zero {
            if settings.isAnimationPlaying {
                settings.manualOffsetPosition = settings.manualOffsetPosition + positionDelta
            } else {
                settings.targetPosition = settings.targetPosition + positionDelta
            }
        }

        // During animation, route orbit/zoom through the same override model as the
        // grab gesture (offset relative to the scene's animated base) so applyKeyframe
        // doesn't stomp desktop input every frame. Gate on actual input so an idle frame
        // leaves the offset untouched and the decay-back to the animation can run —
        // mirrors the positionDelta gate above. Invariant must match GestureController:772.
        if settings.isAnimationPlaying {
            if orbited {
                settings.manualRotationOffset = targetRotation * settings.animationBaseWorldRotation.inverse
                settings.worldRotation = targetRotation
                settings.targetWorldRotation = targetRotation
            }
            if zoomed {
                settings.manualOffsetDetailScale = targetDetailScale - settings.animationBaseDetailScale
                settings.detailScale = targetDetailScale
                settings.targetDetailScale = targetDetailScale
            }
        } else {
            settings.targetWorldRotation = targetRotation
            settings.targetDetailScale = targetDetailScale
        }
    }

    private func updateAudioLevels(appModel: AppModel,
                                   settings: RenderSettings,
                                   isAudioMode: Bool,
                                   hasActiveAudioSources: Bool) {
        guard isAudioMode else { return }

        guard hasActiveAudioSources else {
            settings.bassLevel = 0
            settings.midLevel = 0
            settings.trebleLevel = 0
            settings.beatIntensity = 0
            settings.audioLevel = 0
            return
        }

        let analyzer = appModel.audioAnalyzer
        let appleMusicManager = appModel.appleMusicManager
        let bassSensitivity = settings.bassSensitivity
        let midSensitivity = settings.midSensitivity
        let trebleSensitivity = settings.trebleSensitivity
        let beatSensitivity = settings.beatSensitivity

        var totalBass: Float = 0
        var totalMid: Float = 0
        var totalTreble: Float = 0
        var totalBeat: Float = 0
        var totalLevel: Float = 0
        var sourceCount: Float = 0

        if analyzer.isCapturing {
            totalBass += analyzer.bassLevel
            totalMid += analyzer.midLevel
            totalTreble += analyzer.trebleLevel
            totalBeat = max(totalBeat, analyzer.onsetLevel)  // real spectral-flux onset, not a loudness envelope
            totalLevel += analyzer.level
            sourceCount += 1
        }

        if appleMusicManager.isActive {
            totalBass += appleMusicManager.bassLevel
            totalMid += appleMusicManager.midLevel
            totalTreble += appleMusicManager.trebleLevel
            totalBeat = max(totalBeat, appleMusicManager.beatIntensity)
            totalLevel += appleMusicManager.overallLevel
            sourceCount += 1
        }

        guard sourceCount > 0 else {
            settings.bassLevel = 0
            settings.midLevel = 0
            settings.trebleLevel = 0
            settings.beatIntensity = 0
            settings.audioLevel = 0
            return
        }

        let inverseSourceCount = 1.0 / sourceCount
        settings.bassLevel = min(1.0, totalBass * inverseSourceCount * bassSensitivity)
        settings.midLevel = min(1.0, totalMid * inverseSourceCount * midSensitivity)
        settings.trebleLevel = min(1.0, totalTreble * inverseSourceCount * trebleSensitivity)
        settings.beatIntensity = min(1.0, totalBeat * beatSensitivity)
        settings.audioLevel = totalLevel * inverseSourceCount
    }

    private func updateMusicReactiveParameters(appModel: AppModel,
                                               settings: RenderSettings,
                                               isAudioMode: Bool,
                                               hasActiveAudioSources: Bool,
                                               deltaTime: Float) {
        guard isAudioMode, hasActiveAudioSources, settings.fractalAudioReactiveEnabled else {
            clearMusicReactiveLayersIfNeeded(appModel: appModel, settings: settings)
            return
        }

        // The aggregation in `updateAudioLevels` produced the per-band levels; the
        // shared engine applies damping, response curves, the LFO overlay, and dispatch.
        let bandLevels = BandLevels(bass: settings.bassLevel,
                                    mid: settings.midLevel,
                                    treble: settings.trebleLevel,
                                    beat: settings.beatIntensity,
                                    overall: settings.audioLevel)
        musicReactiveEngine.process(bandLevels: bandLevels,
                                    settings: settings,
                                    deltaTime: deltaTime,
                                    pipeline: appModel.parameterPipeline)
    }

    private func clearMusicReactiveLayersIfNeeded(appModel: AppModel, settings: RenderSettings) {
        musicReactiveEngine.reset(settings: settings, pipeline: appModel.parameterPipeline)
    }

    /// Reads the Sudden Motion Sensor and injects tilt as orbit input when
    /// tilt-control is enabled. Sustained tilt produces continuous orbit (tilt
    /// the laptop to spin the fractal; return it level to stop). No-op when the
    /// sensor is unavailable (Apple Silicon / desktops) or the setting is off.
    private func applyTiltControl(settings: RenderSettings, deltaTime: TimeInterval) {
        let enabled = settings.macTiltControlEnabled
        // No-op on macOS (the SMS samples on demand); on iOS this starts/stops
        // CoreMotion so it doesn't run while tilt control is off.
        motionSensor.setActive(enabled)
        guard enabled, motionSensor.isAvailable else {
            wasTiltControlEnabled = enabled
            return
        }

        // Recenter on the enable edge so the current pose reads as level.
        if !wasTiltControlEnabled {
            motionSensor.calibrate()
        }
        wasTiltControlEnabled = enabled

        guard let tilt = motionSensor.read() else { return }

        // Ignore small tilts so a resting laptop doesn't drift.
        let deadzone: Float = 0.04
        func shaped(_ v: Float) -> Float {
            let m = abs(v)
            guard m > deadzone else { return 0 }
            return (m - deadzone) * (v < 0 ? -1 : 1)
        }

        let roll = shaped(tilt.roll)
        let pitch = shaped(tilt.pitch)
        guard roll != 0 || pitch != 0 else { return }

        // Map tilt (g-relative) to an equivalent per-frame mouse-orbit delta so
        // it flows through the same sensitivity pipeline as drag orbiting.
        // Normalized to 60 fps so the spin rate is frame-rate independent.
        let frameScale = Float(deltaTime) * 60.0
        let tiltOrbitGain: Float = 26.0
        let orbit = SIMD2<Float>(roll * tiltOrbitGain * frameScale,
                                 pitch * tiltOrbitGain * frameScale)
        inputController.addOrbit(delta: orbit)
    }

    private func resetDesktopView(settings: RenderSettings) {
        if settings.isAnimationPlaying {
            settings.clearAnimationManualOffsets()
        } else {
            settings.position = Self.defaultTargetPosition
            settings.targetPosition = Self.defaultTargetPosition
        }
        settings.resetDetailTransform()
        // Discard temporal history so the camera jump doesn't smear.
        temporalUpscaler.requestReset()
    }

    private func updateFPS(deltaTime: TimeInterval) {
        guard deltaTime > 0 else { return }
        let instantFPS = 1.0 / deltaTime
        let smoothFactor = 1.0 - exp(-10.0 * deltaTime)
        smoothedFPS += (instantFPS - smoothedFPS) * smoothFactor
    }

    private func makeUniforms(settings: RenderSettingsSnapshot, elapsedTime: Float, deltaTime: Float) -> Uniforms {
        // Environment Scrunch (Mac): bake the synthetic environment once on
        // first need — the grid is world-anchored and static on this platform.
        if settings.envScrunchEnabled, !macEnvGridBakeAttempted, let spec = Self.syntheticEnvSpec {
            macEnvGridBakeAttempted = true
            macEnvGrid = EnvironmentSDFGrid.bakeSynthetic(
                device: device,
                primitives: EnvironmentSDFGrid.parseSynthetic(spec))
        }
        // Fractal distance cache: decide eligibility + bake key for this frame.
        // The bake itself is encoded in draw() (same command buffer, before the
        // render pass) so the grid the fragment march reads is never stale.
        var distCacheParams = DistanceCacheParams()
        distCachePendingKey = nil
        if Self.distCacheRequested, FractalDistanceCache.isEligible(settings: settings) {
            if distCache == nil, !distCacheInitAttempted {
                distCacheInitAttempted = true
                distCache = FractalDistanceCache(device: device)
            }
            if let cache = distCache {
                distCachePendingKey = FractalDistanceCache.bakeKey(settings: settings)
                distCacheParams = cache.makeParams(enabled: true)
            }
        }

        let smoothFactor = 1.0 - exp(-15.0 * deltaTime)
        smoothedScale += (settings.scale - smoothedScale) * smoothFactor

        let userRotationMatrix = matrix4x4_from_quaternion(settings.worldRotation)
        let combinedRotationMatrix = userRotationMatrix * baseRotationMatrix
        let effectiveScale = smoothedScale * settings.detailScale
        let translationMatrix = matrix4x4_translation(settings.position.x, settings.position.y, settings.position.z)
        let scaleMatrix = matrix4x4_scale(effectiveScale, effectiveScale, effectiveScale)
        let modelMatrix = translationMatrix * combinedRotationMatrix * scaleMatrix

        let isKleinianFamily = settings.fractalType == .kleinian || settings.fractalType == .theliPseudoKleinian
        let traceScaleFloor: Float = isKleinianFamily ? 0.02 : 0.15
        // Family cap + base horizon stay below the projection far plane (farZ 500)
        // so raymarch depth stays valid. (The old render-distance multiplier was
        // measured to have almost no perf effect and was hardcoded to 1×.)
        let maxViewDistanceCap: Float = isKleinianFamily ? 420.0 : 80.0
        let baseViewDistance: Float = isKleinianFamily ? RenderSettings.maxViewDistance * 2.0 : RenderSettings.maxViewDistance
        // The march runs in MODEL space, where the fractal is a fixed size and
        // detail-scale "zoom" only moves the camera toward the origin. Dividing the
        // view distance by the zoomed scale is correct for zooming OUT (camera
        // recedes, needs more range) but WRONG for zooming IN: it collapses the
        // ray range below the fractal's own extent, clipping the long center rays
        // and punching a growing hole in the view center. Cap the divisor at the
        // base scale so zooming in never shrinks the range below the base.
        let viewDistanceScale = max(min(effectiveScale, smoothedScale), traceScaleFloor)
        var targetMaxViewDistance = min(maxViewDistanceCap, baseViewDistance / viewDistanceScale)
        // Zoom-out: once the divisor floors, the WORLD horizon (maxViewDistance ×
        // scale) shrinks with the model and the fractal dissolves at a
        // camera-centered sphere. Lift the horizon so the world-space range never
        // drops below baseViewDistance. No-op while effectiveScale >= the floor.
        let safeScale = max(effectiveScale, 1e-4)
        if effectiveScale < traceScaleFloor {
            // Cover camera→model distance too (position offsets eat into the
            // budget), and stay under kRayMissThreshold (900) — hits past it are
            // classified as misses in the shader.
            let camDistWorld = simd_length(SIMD3<Float>(0, 0, 3) - settings.position)
            targetMaxViewDistance = max(targetMaxViewDistance,
                                        min(880.0, (camDistWorld + baseViewDistance) / safeScale))
        }
        let maxViewDistanceSpeed: Float = targetMaxViewDistance > smoothedMaxViewDistance ? 30.0 : 10.0
        let maxViewDistanceBlend = 1.0 - exp(-maxViewDistanceSpeed * deltaTime)
        smoothedMaxViewDistance += (targetMaxViewDistance - smoothedMaxViewDistance) * maxViewDistanceBlend
        let horizonCap = max(maxViewDistanceCap, 880.0)
        let maxViewDistance = max(4.0, min(horizonCap, smoothedMaxViewDistance))

        let aspect = Float(max(drawableSize.width, 1) / max(drawableSize.height, 1))
        let projection = RenderPrecompute.makePerspectiveProjection(fovyRadians: Float.pi / 3, aspect: aspect, nearZ: 0.01, farZ: 500.0)
        let viewMatrix = matrix4x4_translation(0, 0, -3.0)
        let modelView = viewMatrix * modelMatrix
        let inverseModelView = modelView.inverse

        // Stage B: bake the sub-pixel jitter into the projection (zero when the
        // temporal path is inactive, so this is a no-op for the other paths) and
        // cache the matrices the motion-vector pass needs. The reconstruction
        // inverse uses the *jittered* view-projection (matching the jittered
        // depth); motion is measured from the *un-jittered* current/previous
        // view-projections so it carries pure geometric motion.
        var jitteredProjection = projection
        jitteredProjection.columns.2.x += currentJitterNDC.x
        jitteredProjection.columns.2.y += currentJitterNDC.y
        let viewProjNoJitter = projection * modelView
        let viewProjJittered = jitteredProjection * modelView
        motionPreviousViewProjNoJitter = hasPreviousMotionMatrices ? motionCurrentViewProjNoJitter : viewProjNoJitter
        motionCurrentViewProjNoJitter = viewProjNoJitter
        motionCurrentInvViewProj = viewProjJittered.inverse
        hasPreviousMotionMatrices = true

        let precomputedFractal = RenderPrecompute.makePrecomputedFractal(from: settings)
        let precomputedLighting = RenderPrecompute.makePrecomputedLighting(time: elapsedTime,
                                                               lightingMode: settings.lightingMode,
                                                               audioLevel: settings.audioLevel,
                                                               bassLevel: settings.bassLevel,
                                                               midLevel: settings.midLevel,
                                                               trebleLevel: settings.trebleLevel,
                                                               beatIntensity: settings.beatIntensity,
                                                               vibrance: settings.colorSchemeParams.vibrance,
                                                               lightingSoftness: settings.lightingSoftness)
        let precomputedAudio = RenderPrecompute.makePrecomputedAudio(from: settings)
        var precomputedFog = RenderPrecompute.makePrecomputedFog(from: settings)
        // Zoom fog compensation (Settings toggle, default off): fog operates on
        // MODEL-space march distance, so on zoom-out the fog sphere's world radius
        // shrinks with the model and washes out the fractal — starting as soon as
        // scale drops below 1.0 (uncompensated fogIntensity is scale-invariant, so
        // worldRadius = scale/(2*fogIntensity) shrinks the moment you zoom out at
        // all). Scaling intensity by effectiveScale holds the fog's WORLD radius
        // constant at its scale==1 value for the whole zoom-out range — a no-op at
        // scale >= 1 (zoom-in keeps its original, uncompensated look). (Was
        // previously hardcoded on for the Kleinian family only, and briefly keyed
        // to the unrelated 0.15 horizon-lift floor.)
        if settings.zoomFogCompensationEnabled {
            let baseFog = precomputedFog.fog.x
            if baseFog > 1e-6 {
                let fogScale = min(1.0, max(effectiveScale, 1e-4))
                let fogIntensity = baseFog * fogScale
                let inverseFog = fogIntensity > 1e-6 ? 1.0 / fogIntensity : 0.0
                precomputedFog = PrecomputedFog(fog: SIMD4<Float>(fogIntensity, inverseFog, 0.0, 0.0), color: precomputedFog.color)
            }
        }
        // Zoom-out epsilon/LOD rescale (both 1.0 at scale >= 0.15 → byte-identical):
        // the hit threshold must loosen ∝ 1/scale to track the constant world-space
        // pixel footprint (this also bounds step cost over the lifted horizon), and
        // distance-LOD reads model-space t, so its falloff shrinks with scale to
        // avoid collapsing iterations everywhere on zoom-out.
        let zoomOutEpsilonLoosen: Float = max(1.0, 0.15 / max(effectiveScale, 1e-4))
        let zoomOutLODScale: Float = min(1.0, effectiveScale / 0.15)

        let lightingWave = sin(elapsedTime * 1.2)
        let animatedColorMix = settings.lightingPlay ? min(max(settings.colorMix + lightingWave * 0.08, 0.0), 1.0) : settings.colorMix
        let baseGlow = settings.colorSchemeParams.glowIntensity
        let animatedGlow = settings.lightingPlay ? min(max(baseGlow + max(0, lightingWave) * 0.25, 0.0), 2.0) : baseGlow
        let scaleCorrectedBubbleRadius = settings.safetyBubbleRadius / max(effectiveScale, 0.001)
        let scaleCorrectedFadeWidth = settings.safetyBubbleFadeWidth / max(effectiveScale, 0.001)

        return Uniforms(projectionMatrix: jitteredProjection,
                        modelViewMatrix: modelView,
                        inverseModelViewMatrix: inverseModelView,
                        // Warm start is visionOS-only (FC_WARM_START compiled out
                        // of the Mac pipelines); these stay inert here.
                        previousViewProjMatrix: matrix_identity_float4x4,
                        previousInvViewProjMatrix: matrix_identity_float4x4,
                        time: elapsedTime,
                        minDistance: settings.minDistance,
                        fractalScale: settings.fractalScale,
                        fractalIterations: Int32(settings.fractalIterations),
                        maxRaySteps: Int32(settings.maxRaySteps),
                        maxViewDistance: maxViewDistance,
                        // Infinite zoom: tighten the march hit-threshold floor as we zoom in
                        // so fine detail keeps resolving (1.0 at base → byte-identical);
                        // loosen it past the zoom-out floor (see zoomOutEpsilonLoosen).
                        marchEpsilonScale: (1.0 / max(effectiveScale, 1.0)) * zoomOutEpsilonLoosen,
                        colorMix: animatedColorMix,
                        glowIntensity: animatedGlow,
                        foldingLimit: settings.foldingLimit,
                        sphereRadius: settings.sphereRadius,
                        safetyBubbleRadius: scaleCorrectedBubbleRadius,
                        safetyBubbleEnabled: settings.fractalType == .mandelbulb ? 0 : (settings.safetyBubbleEnabled ? 1 : 0),
                        safetyBubbleShape: settings.safetyBubbleShape,
                        safetyBubbleFadeEnabled: settings.safetyBubbleFadeEnabled ? 1 : 0,
                        safetyBubbleFadeWidth: scaleCorrectedFadeWidth,
                        safetyBubbleStrength: settings.fractalType == .mandelbulb ? 0.0 : settings.safetyBubbleStrength,
                        // Hand Attraction needs ARKit hand tracking — visionOS only.
                        handField: .off,
                        colorIterations: settings.colorIterations,
                        limitFlash: settings.limitFlash,
                        activeGesture: Int32(settings.activeGestureIndex),
                        warmStartEnabled: 0,
                        fractalType: settings.fractalType.rawValue,
                        lightingSoftness: settings.lightingSoftness,
                        sphericalInversionMode: settings.sphericalInversionMode.rawValue,
                        sphericalInversionRadius: settings.sphericalInversionRadius,
                        sphereProjectionBlend: settings.sphereProjectionEnabled ? settings.sphereProjectionBlend : 0,
                        sphereProjectionRadius: settings.sphereProjectionRadius,
                        spaceWarpStrength: settings.spaceWarpStrength,
                        spaceWarpParam1: settings.spaceWarpParam1,
                        spaceWarpParam2: settings.spaceWarpParam2,
                        spaceWarpParam3: settings.spaceWarpParam3,
                        spaceWarpAxis: settings.spaceWarpAxis,
                        spaceWarpStack: settings.spaceWarpStack,
                        stepMultiplier: settings.stepMultiplier,
                        boundingSphereRadius: settings.estimatedBoundingSphereRadius,
                        smartAdvanceEnabled: settings.smartAdvanceEnabled ? 1 : 0,
                        // Native drawable height by design: when MetalFX dynamic
                        // resolution renders the march at a smaller offscreen size,
                        // using the native height yields a slightly smaller cone
                        // than ideal — strictly conservative (finer stop, never
                        // skips visible detail; sharper pre-upscale, just less of
                        // the speedup). Not worth threading the per-frame input
                        // height through the resolution branches for an off-by-
                        // default control. visionOS paths use the true viewport.
                        coneMarchScale: RenderPrecompute.coneMarchScale(
                            strength: settings.coneMarchStrength,
                            projection: projection,
                            viewportHeight: Float(drawableSize.height)),
                        coneCoverageAAEnabled: settings.coneCoverageAAEnabled ? 1 : 0,
                        shadowsEnabled: settings.shadowsEnabled ? 1 : 0,
                        distanceLODFalloff: settings.distanceLODStrength * 0.5 * zoomOutLODScale,
                        benchCollectSteps: BenchmarkManager.shared.shouldCollectSteps ? 1 : 0,
                        // Conservative cone coarse-prepass: Mac uses fragmentShaderMono,
                        // which never reads the coarse texture (FC off), so these only
                        // keep the shared Uniforms initializer well-formed.
                        pixelFootprintPerDist: RenderPrecompute.pixelFootprintPerDist(
                            projection: projection,
                            viewportHeight: Float(drawableSize.height)),
                        coarseRateMagMax: 1.0,
                        springDisplacementX: settings.springDisplacement.x,
                        springDisplacementY: settings.springDisplacement.y,
                        springDisplacementZ: settings.springDisplacement.z,
                        springStretch: simd_length(settings.springDisplacement),
                        springAnchorNDC: SIMD2<Float>(0.7, -0.7),
                        springVisible: (settings.springActive || simd_length(settings.springDisplacement) > 0.001) ? 1 : 0,
                        springRestRadius: 0.06,
                        jitterOffset: .zero,
                        renderResolution: [1, 1],
                        floorPlane: SIMD4<Float>(0, 1, 0, 0),
                        floorCenterRadius: SIMD4<Float>(0, 0, 0, 0),
                        formulaParams: settings.formulaParams,
                        precomputedFractal: precomputedFractal,
                        precomputedLighting: precomputedLighting,
                        precomputedAudio: precomputedAudio,
                        precomputedFog: precomputedFog,
                        colorScheme: benchStableColorScheme(settings.colorSchemeParams),
                        benchAblate: Self.benchAblateMode,
                        passthroughBackground: 0,
                        boundingFogEnabled: Int32(settings.boundingShapeFogMode),
                        boundingShadowDepth: settings.boundingShapeShadowDepth,
                        boundingShapeType: settings.boundingShapeType,
                        boundToSpaceMode: settings.resolvedBoundToSpaceMode,
                        boundSpaceSize: settings.boundSpaceSize,
                        boundAmbientStrength: settings.boundAmbientStrength,
                        modelToWorldMatrix: modelMatrix,
                        // Mac has no room sensing; a synthetic environment can be
                        // injected via THRESHOLD_SYNTHETIC_ENV for headless/dev
                        // verification of the scrunch path.
                        envScrunch: settings.makeEnvScrunchParams(
                            modelToWorld: modelMatrix,
                            gridOrigin: macEnvGrid?.originWorld ?? .zero,
                            gridCell: macEnvGrid?.cellSize ?? .zero,
                            gridAddress: macEnvGrid?.gpuAddress ?? 0,
                            surfaceMinWorld: macEnvGrid?.surfaceMinWorld ?? .zero,
                            surfaceMaxWorld: macEnvGrid?.surfaceMaxWorld ?? .zero,
                            farClampMeters: EnvironmentSDFGrid.clampFar),
                        distCache: distCacheParams,
                        // Pin the Bounding Shape while the Linear Rail slides
                        // content through it (0 when the rail is off).
                        boundingShapeCenter: settings.boundingShapeCenterModel(modelMatrix: modelMatrix))
    }

    private static func buildRenderPipeline(device: MTLDevice,
                                            colorPixelFormat: MTLPixelFormat,
                                            depthPixelFormat: MTLPixelFormat,
                                            vertexDescriptor: MTLVertexDescriptor) throws -> MTLRenderPipelineState {
        guard let library = device.makeDefaultLibrary(),
              let vertexFunction = library.makeFunction(name: "screenshotVertexShader") else {
                        throw SetupError.metalLibraryUnavailable
        }

        let constants = MTLFunctionConstantValues()
        let fragmentFunction = try library.makeFunction(name: "fragmentShaderMono", constantValues: constants)

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "ThresholdMac Raymarch Pipeline"
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.vertexDescriptor = vertexDescriptor
        descriptor.rasterSampleCount = 1
        descriptor.colorAttachments[0].pixelFormat = colorPixelFormat
        descriptor.depthAttachmentPixelFormat = depthPixelFormat

        return try device.makeRenderPipelineState(descriptor: descriptor)
    }

    /// Full-screen blit pipeline that copies the MetalFX upscaled output to the
    /// drawable. Single-view, no vertex/depth attachments — the vertex shader
    /// generates an oversized triangle from `vertex_id`.
    private static func buildBlitPipeline(device: MTLDevice, colorPixelFormat: MTLPixelFormat) -> MTLRenderPipelineState? {
        guard let library = device.makeDefaultLibrary(),
              let vertexFunction = library.makeFunction(name: "macBlitVertex"),
              let fragmentFunction = library.makeFunction(name: "macBlitFragment") else {
            return nil
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "ThresholdMac Blit Pipeline"
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.rasterSampleCount = 1
        descriptor.colorAttachments[0].pixelFormat = colorPixelFormat
        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }

    /// Full-screen motion-vector pipeline (Stage B). Reads the offscreen depth
    /// and writes screen-space motion into an `rg16Float` target for the
    /// temporal scaler. No depth attachment.
    private static func buildMotionPipeline(device: MTLDevice) -> MTLRenderPipelineState? {
        guard let library = device.makeDefaultLibrary(),
              let vertexFunction = library.makeFunction(name: "macBlitVertex"),
              let fragmentFunction = library.makeFunction(name: "macMotionFragment") else {
            return nil
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "ThresholdMac Motion Pipeline"
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.rasterSampleCount = 1
        descriptor.colorAttachments[0].pixelFormat = MacTemporalUpscaler.motionFormat
        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }

    /// Radical-inverse Halton sample in `[0, 1)` — sub-pixel jitter sequence for
    /// temporal upscaling (base 2 for X, base 3 for Y).
    private static func halton(_ index: UInt32, base: UInt32) -> Float {
        var result: Float = 0
        var fraction: Float = 1
        var i = index
        while i > 0 {
            fraction /= Float(base)
            result += fraction * Float(i % base)
            i /= base
        }
        return result
    }

    private static func buildMetalVertexDescriptor() -> MTLVertexDescriptor {
        let descriptor = MTLVertexDescriptor()

        descriptor.attributes[VertexAttribute.position.rawValue].format = .float3
        descriptor.attributes[VertexAttribute.position.rawValue].offset = 0
        descriptor.attributes[VertexAttribute.position.rawValue].bufferIndex = BufferIndex.meshPositions.rawValue

        descriptor.attributes[VertexAttribute.texcoord.rawValue].format = .float2
        descriptor.attributes[VertexAttribute.texcoord.rawValue].offset = 0
        descriptor.attributes[VertexAttribute.texcoord.rawValue].bufferIndex = BufferIndex.meshGenerics.rawValue

        descriptor.layouts[BufferIndex.meshPositions.rawValue].stride = 12
        descriptor.layouts[BufferIndex.meshPositions.rawValue].stepRate = 1
        descriptor.layouts[BufferIndex.meshPositions.rawValue].stepFunction = .perVertex

        descriptor.layouts[BufferIndex.meshGenerics.rawValue].stride = 8
        descriptor.layouts[BufferIndex.meshGenerics.rawValue].stepRate = 1
        descriptor.layouts[BufferIndex.meshGenerics.rawValue].stepFunction = .perVertex

        return descriptor
    }

    private static func buildMesh(device: MTLDevice, vertexDescriptor: MTLVertexDescriptor) throws -> MTKMesh {
        let allocator = MTKMeshBufferAllocator(device: device)
        let mesh = MDLMesh.newEllipsoid(withRadii: SIMD3<Float>(repeating: 100),
                                        radialSegments: 64,
                                        verticalSegments: 32,
                                        geometryType: .triangles,
                                        inwardNormals: false,
                                        hemisphere: false,
                                        allocator: allocator)

        let modelIODescriptor = MTKModelIOVertexDescriptorFromMetal(vertexDescriptor)
        guard let attributes = modelIODescriptor.attributes as? [MDLVertexAttribute] else {
            throw SetupError.badVertexDescriptor
        }
        attributes[VertexAttribute.position.rawValue].name = MDLVertexAttributePosition
        attributes[VertexAttribute.texcoord.rawValue].name = MDLVertexAttributeTextureCoordinate
        mesh.vertexDescriptor = modelIODescriptor

        return try MTKMesh(mesh: mesh, device: device)
    }
}

#if os(iOS)
import UIKit

/// iPad host for the shared `ThresholdMacRenderer`. Wraps an `MTKView` in a
/// `UIViewRepresentable` and translates touch gestures into the same
/// orbit / pan / zoom input the macOS trackpad path feeds, so the renderer is
/// byte-identical across platforms:
///   • one-finger drag  → orbit
///   • two-finger drag  → pan
///   • pinch            → zoom (mirrors the macOS `magnify` convention)
///
/// The orbit/pan/zoom sign and gain match the validated macOS conventions;
/// if motion feels inverted on device, flip the `dy`/`dx` sign in the gesture
/// handlers — the renderer math is unchanged.
struct ThresholdiOSRenderView: UIViewRepresentable {
    let appModel: AppModel

    func makeCoordinator() -> Coordinator {
        Coordinator(appModel: appModel)
    }

    func makeUIView(context: Context) -> MTKView {
        let device = MTLCreateSystemDefaultDevice()
        let view = TouchVisualizingMTKView(frame: .zero, device: device)
        view.colorPixelFormat = .bgra8Unorm_srgb
        view.depthStencilPixelFormat = .depth32Float
        view.clearColor = MTLClearColor(red: 0.005, green: 0.006, blue: 0.008, alpha: 1.0)
        view.clearDepth = 1.0
        view.preferredFramesPerSecond = 120  // allow ProMotion; also gives finer vsync steps under load instead of the 60→30 cliff
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.framebufferOnly = true
        view.autoResizeDrawable = true
        view.isMultipleTouchEnabled = true
        view.delegate = context.coordinator
        context.coordinator.attachGestures(to: view)
        context.coordinator.configure(view)
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        context.coordinator.appModel = appModel
    }

    static func dismantleUIView(_ uiView: MTKView, coordinator: Coordinator) {
        uiView.delegate = nil
        coordinator.tearDown()
    }

    final class Coordinator: NSObject, MTKViewDelegate, UIGestureRecognizerDelegate {
        var appModel: AppModel
        private let inputController = ThresholdMacInputController()
        private var renderer: ThresholdMacRenderer?

        // Incremental gesture tracking. UIPanGestureRecognizer reports cumulative
        // translation; we feed per-callback deltas (points) to match the macOS
        // per-event delta convention.
        private var lastOrbitTranslation: CGPoint = .zero
        private var lastPanTranslation: CGPoint = .zero
        private var lastPinchScale: CGFloat = 1.0
        private weak var twoFingerPan: UIPanGestureRecognizer?
        private weak var pinch: UIPinchGestureRecognizer?

        init(appModel: AppModel) {
            self.appModel = appModel
            super.init()
        }

        @MainActor
        func configure(_ view: MTKView) {
            appModel.rendererStartupWarmupComplete = false
            guard let device = view.device,
                  let metalLayer = view.layer as? CAMetalLayer else { return }
            metalLayer.device = device
            metalLayer.pixelFormat = view.colorPixelFormat
            metalLayer.framebufferOnly = true
            metalLayer.drawableSize = view.drawableSize
            renderer = ThresholdMacRenderer(device: device,
                                            appModel: appModel,
                                            inputController: inputController,
                                            metalLayer: metalLayer,
                                            colorPixelFormat: view.colorPixelFormat,
                                            depthPixelFormat: view.depthStencilPixelFormat,
                                            clearColor: view.clearColor)
            renderer?.drawableSizeDidChange(view.drawableSize)
            appModel.rendererStartupWarmupComplete = renderer != nil
            // Compile + activate runtime `.threshfx` formulas on Mac/iPad (was
            // visionOS-only). Binding here triggers the handler's didSet, which
            // re-activates any formula loaded before the view existed.
            if let renderer {
                appModel.activateEmbeddedFormulaHandler = renderer.embeddedFormulaActivator(renderSettings: appModel.renderSettings)
                appModel.forceShaderRecompileHandler = renderer.shaderRecompiler(appModel: appModel)
            }
        }

        func attachGestures(to view: UIView) {
            let orbit = UIPanGestureRecognizer(target: self, action: #selector(handleOrbit(_:)))
            orbit.minimumNumberOfTouches = 1
            orbit.maximumNumberOfTouches = 1
            orbit.delegate = self
            // Keep raw touches flowing to the view so the touch
            // visualization overlay can track fingers through the gesture.
            orbit.cancelsTouchesInView = false

            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            pan.minimumNumberOfTouches = 2
            pan.maximumNumberOfTouches = 2
            pan.delegate = self
            pan.cancelsTouchesInView = false
            twoFingerPan = pan

            let pinchGesture = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
            pinchGesture.delegate = self
            pinchGesture.cancelsTouchesInView = false
            pinch = pinchGesture

            view.addGestureRecognizer(orbit)
            view.addGestureRecognizer(pan)
            view.addGestureRecognizer(pinchGesture)
        }

        func tearDown() {
            inputController.setFocus(false)
            renderer = nil
            Task { @MainActor [appModel] in
                appModel.activateEmbeddedFormulaHandler = nil
                appModel.forceShaderRecompileHandler = nil
                appModel.rendererStartupWarmupComplete = false
            }
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            renderer?.drawableSizeDidChange(size)
        }

        func draw(in view: MTKView) {
            renderer?.draw(appModel: appModel)
        }

        @objc private func handleOrbit(_ gesture: UIPanGestureRecognizer) {
            let translation = gesture.translation(in: gesture.view)
            switch gesture.state {
            case .began:
                lastOrbitTranslation = .zero
                inputController.setFocus(true)
            case .changed:
                let delta = SIMD2<Float>(Float(translation.x - lastOrbitTranslation.x),
                                         Float(translation.y - lastOrbitTranslation.y))
                lastOrbitTranslation = translation
                if simd_length_squared(delta) > 0 {
                    inputController.addOrbit(delta: delta)
                }
            default:
                lastOrbitTranslation = .zero
            }
        }

        @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
            let translation = gesture.translation(in: gesture.view)
            switch gesture.state {
            case .began:
                lastPanTranslation = .zero
                inputController.setFocus(true)
            case .changed:
                let delta = SIMD2<Float>(Float(translation.x - lastPanTranslation.x),
                                         Float(translation.y - lastPanTranslation.y))
                lastPanTranslation = translation
                if simd_length_squared(delta) > 0 {
                    inputController.addPan(delta: delta)
                }
            default:
                lastPanTranslation = .zero
            }
        }

        @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            switch gesture.state {
            case .began:
                lastPinchScale = gesture.scale
                inputController.setFocus(true)
            case .changed:
                // Mirror the macOS `magnify` convention: pinch-out (scale > 1)
                // feeds a negative zoom delta, which the renderer maps to a
                // larger detail scale (zoom in).
                let delta = Float(gesture.scale - lastPinchScale)
                lastPinchScale = gesture.scale
                if delta != 0 {
                    inputController.addZoom(delta: -delta * 18.0)
                }
            default:
                lastPinchScale = 1.0
            }
        }

        // Allow the two-finger pan and pinch to run together (natural combined
        // pan + zoom); keep the one-finger orbit exclusive.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            let pair: Set<ObjectIdentifier> = [ObjectIdentifier(gestureRecognizer), ObjectIdentifier(other)]
            var allowed: Set<ObjectIdentifier> = []
            if let twoFingerPan { allowed.insert(ObjectIdentifier(twoFingerPan)) }
            if let pinch { allowed.insert(ObjectIdentifier(pinch)) }
            return pair.isSubset(of: allowed)
        }
    }
}
#endif
#endif
