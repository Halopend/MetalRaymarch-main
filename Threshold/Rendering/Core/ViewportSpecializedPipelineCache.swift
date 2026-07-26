#if os(macOS) || os(iOS)
import Dispatch
import Metal
import Synchronization

/// Hashable identity of one function-constant specialization. Replaces the
/// previous interpolated ~60-char String key so the per-frame cache probe
/// hashes a few machine words instead of formatting and hashing a String.
struct ViewportPipelineKey: Hashable, Sendable {
    /// Combined custom-effect source hash when ANY custom library is active
    /// (custom fractal OR a space warp riding a built-in); nil on the pure
    /// bundled-library path. Namespaces custom pipelines so library-A's
    /// FT1000 pipeline is never reused for library-B, and so deactivation can
    /// evict exactly one effect's set (matches visionOS `CX{hash}_`).
    let customHash: String?
    let fractalType: Int32
    let iterations: Int32
    let raySteps: Int32
    let colorIterations: Int32
    let power: Int32?
    let safetyBubbleEnabled: Bool
    let shadowsEnabled: Bool
    let sphereProjectionEnabled: Bool
    let hasSpaceWarp: Bool
    let hasEnvScrunch: Bool
    let hasHandField: Bool

    /// Human-readable form for pipeline labels — same shape as the retired
    /// String key. Built once per pipeline compile, never on the frame path.
    var labelDescription: String {
        let powerKey = power.map { "_P\($0)" } ?? ""
        let customPrefix = customHash.map { "CX\($0)_" } ?? ""
        return customPrefix + "FT\(fractalType)_FI\(iterations)_RS\(raySteps)_CI\(colorIterations)\(powerKey)"
            + "_B\(safetyBubbleEnabled ? 1 : 0)_SH\(shadowsEnabled ? 1 : 0)_SP\(sphereProjectionEnabled ? 1 : 0)"
            + "_SW\(hasSpaceWarp ? 1 : 0)_ES\(hasEnvScrunch ? 1 : 0)_HF\(hasHandField ? 1 : 0)"
    }
}

/// `Mutex`-protected cache of function-constant–specialized `fragmentShaderMono`
/// pipelines for the macOS/iOS renderer. Specializing on iteration/ray-step/fractal
/// counts lets the Metal compiler fully unroll the `Map()` and `Scene()` loops
/// and devirtualize the DE dispatch — the same optimization the visionOS
/// `Renderer` already performs. Builds run asynchronously off the render thread;
/// the generic pipeline is used until the specialized variant is ready.
///
/// The render thread reads the cache *synchronously* every frame (see
/// `resolveActivePipeline`) and must return a pipeline for the current frame, so
/// an `actor` is the wrong tool — it would force the hot-path read to be `async`.
/// `Mutex` keeps the access synchronous while giving compiler-checked `Sendable`
/// isolation, so the async `makeRenderPipelineState` completion handler can safely
/// store results without manual lock management.
final class ViewportSpecializedPipelineCache: Sendable {
    private struct State {
        var cache: [ViewportPipelineKey: MTLRenderPipelineState] = [:]
        var pending: Set<ViewportPipelineKey> = []
    }

    private let state = Mutex(State())

    func pipeline(for key: ViewportPipelineKey) -> MTLRenderPipelineState? {
        state.withLock { $0.cache[key] }
    }

    /// Returns `true` if the caller should kick off a build (not cached and not
    /// already in flight). Marks the key pending so concurrent frames don't
    /// schedule duplicate compiles.
    func beginBuildIfNeeded(_ key: ViewportPipelineKey) -> Bool {
        state.withLock { current in
            if current.cache[key] != nil || current.pending.contains(key) { return false }
            current.pending.insert(key)
            return true
        }
    }

    func store(_ pipeline: MTLRenderPipelineState, for key: ViewportPipelineKey) {
        state.withLock { current in
            current.cache[key] = pipeline
            current.pending.remove(key)
        }
    }

    func failBuild(_ key: ViewportPipelineKey) {
        _ = state.withLock { $0.pending.remove(key) }
    }

    /// Drop every cached pipeline (and any in-flight build). Debug
    /// "Force Recompile" — everything rebuilds lazily on later frames.
    func evictAll() {
        state.withLock { current in
            current.cache.removeAll()
            current.pending.removeAll()
        }
    }

    /// Drop every custom-library pipeline (any `customHash`). Used when
    /// deactivating back to the bundled default library.
    func evictAllCustom() {
        state.withLock { current in
            current.cache = current.cache.filter { $0.key.customHash == nil }
            current.pending = current.pending.filter { $0.customHash == nil }
        }
    }

    /// Retire exactly one custom effect's pipelines (and in-flight builds) on
    /// effect switch.
    func evict(customHash: String) {
        state.withLock { current in
            current.cache = current.cache.filter { $0.key.customHash != customHash }
            current.pending = current.pending.filter { $0.customHash != customHash }
        }
    }
}

/// Builds viewport specializations completely away from the render thread.
///
/// `MTLDevice.makeRenderPipelineState` has an asynchronous overload, but creating
/// a function with constant values can itself perform substantial synchronous
/// compiler work. Doing that first half from `draw(in:)` produced visible pauses
/// that Xcode's main-thread hang detector could not see. This builder keeps both
/// halves on one utility queue and coalesces rapid key changes latest-wins, so a
/// slider drag cannot fan out into a concurrent Metal compile storm.
final class ViewportSpecializedPipelineBuilder: @unchecked Sendable {
    struct Request: @unchecked Sendable {
        let key: ViewportPipelineKey
        let iterations: Int32
        let raySteps: Int32
        let fractalType: Int32
        let colorIterations: Int32
        let power: Int32?
        let safetyBubbleEnabled: Bool
        let shadowsEnabled: Bool
        let sphereProjectionEnabled: Bool
        let hasSpaceWarp: Bool
        let hasEnvScrunch: Bool
        let hasHandField: Bool
        let customLibrary: MTLLibrary?
    }

    private struct State: @unchecked Sendable {
        var wanted: Request?
        var draining = false
    }

    private let device: MTLDevice
    private let colorPixelFormat: MTLPixelFormat
    private let depthPixelFormat: MTLPixelFormat
    private let vertexDescriptor: MTLVertexDescriptor
    private let cache: ViewportSpecializedPipelineCache
    private let state = Mutex(State())
    private let buildQueue = DispatchQueue(
        label: "com.polinate.threshold.viewport-specialized-pipeline",
        qos: .utility
    )

    init(
        device: MTLDevice,
        colorPixelFormat: MTLPixelFormat,
        depthPixelFormat: MTLPixelFormat,
        vertexDescriptor: MTLVertexDescriptor,
        cache: ViewportSpecializedPipelineCache
    ) {
        self.device = device
        self.colorPixelFormat = colorPixelFormat
        self.depthPixelFormat = depthPixelFormat
        self.vertexDescriptor = vertexDescriptor.copy() as! MTLVertexDescriptor
        self.cache = cache
    }

    func request(_ request: Request) {
        let (supersededKey, shouldStart): (ViewportPipelineKey?, Bool) = state.withLock { current in
            let supersededKey = current.wanted?.key == request.key
                ? nil
                : current.wanted?.key
            current.wanted = request
            guard !current.draining else { return (supersededKey, false) }
            current.draining = true
            return (supersededKey, true)
        }

        // The renderer marked this key pending before handing it to us. If a
        // newer request replaced it before work began, release that pending mark
        // so revisiting the configuration can schedule it again.
        if let supersededKey {
            cache.failBuild(supersededKey)
        }

        if shouldStart {
            buildQueue.async { [self] in
                drainBuilds()
            }
        }
    }

    private func drainBuilds() {
        while true {
            let request: Request? = state.withLock { current in
                guard let request = current.wanted else {
                    current.draining = false
                    return nil
                }
                current.wanted = nil
                return request
            }
            guard let request else { return }

            if let pipeline = build(request) {
                cache.store(pipeline, for: request.key)
            } else {
                cache.failBuild(request.key)
            }
        }
    }

    private func build(_ request: Request) -> MTLRenderPipelineState? {
        guard let library = request.customLibrary
                ?? MetalLibraryCache.bundledDefaultLibrary(device: device),
              let vertexFunction = library.makeFunction(name: "screenshotVertexShader")
        else { return nil }

        let constants = MTLFunctionConstantValues()
        var iterations = request.iterations
        constants.setConstantValue(&iterations, type: .int, index: FunctionConstantIndex.fractalIterations.rawValue)
        var raySteps = request.raySteps
        constants.setConstantValue(&raySteps, type: .int, index: FunctionConstantIndex.maxRaySteps.rawValue)
        var fractalType = request.fractalType
        constants.setConstantValue(&fractalType, type: .int, index: FunctionConstantIndex.fractalType.rawValue)
        var colorIterations = request.colorIterations
        constants.setConstantValue(&colorIterations, type: .int, index: FunctionConstantIndex.colorIterations.rawValue)
        if var power = request.power {
            constants.setConstantValue(&power, type: .int, index: FunctionConstantIndex.mandelbulbPower.rawValue)
        }
        var safetyBubble = request.safetyBubbleEnabled
        constants.setConstantValue(&safetyBubble, type: .bool, index: FunctionConstantIndex.safetyBubbleEnabled.rawValue)
        var shadows = request.shadowsEnabled
        constants.setConstantValue(&shadows, type: .bool, index: FunctionConstantIndex.shadowsEnabled.rawValue)
        var sphereProjection = request.sphereProjectionEnabled
        constants.setConstantValue(&sphereProjection, type: .bool, index: FunctionConstantIndex.sphereProjectionEnabled.rawValue)
        var spaceWarp = request.hasSpaceWarp
        constants.setConstantValue(&spaceWarp, type: .bool, index: FunctionConstantIndex.hasSpaceWarp.rawValue)
        var environment = request.hasEnvScrunch
        constants.setConstantValue(&environment, type: .bool, index: FunctionConstantIndex.hasEnvScrunch.rawValue)
        var handField = request.hasHandField
        constants.setConstantValue(&handField, type: .bool, index: FunctionConstantIndex.hasHandField.rawValue)

        guard let fragmentFunction = try? library.makeFunction(
            name: "fragmentShaderMono",
            constantValues: constants
        ) else { return nil }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "Threshold Viewport Specialized [\(request.key.labelDescription)]"
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.vertexDescriptor = vertexDescriptor
        descriptor.rasterSampleCount = 1
        descriptor.colorAttachments[0].pixelFormat = colorPixelFormat
        descriptor.depthAttachmentPixelFormat = depthPixelFormat

        // Intentionally synchronous on this private serial queue: this keeps
        // Metal from compiling several stale variants concurrently while the
        // generic pipeline continues rendering frames.
        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }
}
#endif
