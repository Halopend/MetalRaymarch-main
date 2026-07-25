#if os(macOS) || os(iOS)
import Dispatch
import Metal
import Synchronization

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
        var cache: [String: MTLRenderPipelineState] = [:]
        var pending: Set<String> = []
    }

    private let state = Mutex(State())

    func pipeline(for key: String) -> MTLRenderPipelineState? {
        state.withLock { $0.cache[key] }
    }

    /// Returns `true` if the caller should kick off a build (not cached and not
    /// already in flight). Marks the key pending so concurrent frames don't
    /// schedule duplicate compiles.
    func beginBuildIfNeeded(_ key: String) -> Bool {
        state.withLock { current in
            if current.cache[key] != nil || current.pending.contains(key) { return false }
            current.pending.insert(key)
            return true
        }
    }

    func store(_ pipeline: MTLRenderPipelineState, for key: String) {
        state.withLock { current in
            current.cache[key] = pipeline
            current.pending.remove(key)
        }
    }

    func failBuild(_ key: String) {
        _ = state.withLock { $0.pending.remove(key) }
    }

    /// Drop every cached pipeline (and any in-flight build) whose key starts with
    /// `prefix`. Used to retire a custom formula's `CX{hash}_` pipelines on switch
    /// or deactivation (pass `"CX"` to clear all custom pipelines).
    func evict(prefix: String) {
        state.withLock { current in
            current.cache = current.cache.filter { !$0.key.hasPrefix(prefix) }
            current.pending = current.pending.filter { !$0.hasPrefix(prefix) }
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
        let key: String
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
        let (supersededKey, shouldStart): (String?, Bool) = state.withLock { current in
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

        // Metal function-constant indices mirror FunctionConstantIndex:
        // 0=iterations, 2=safety bubble, 3=space warp, 6=ray steps,
        // 7=fractal type, 9=color iterations, 11=shadows,
        // 12=mandelbulb power, 16=environment, 17=sphere projection,
        // 18=hand field.
        let constants = MTLFunctionConstantValues()
        var iterations = request.iterations
        constants.setConstantValue(&iterations, type: .int, index: 0)
        var raySteps = request.raySteps
        constants.setConstantValue(&raySteps, type: .int, index: 6)
        var fractalType = request.fractalType
        constants.setConstantValue(&fractalType, type: .int, index: 7)
        var colorIterations = request.colorIterations
        constants.setConstantValue(&colorIterations, type: .int, index: 9)
        if var power = request.power {
            constants.setConstantValue(&power, type: .int, index: 12)
        }
        var safetyBubble = request.safetyBubbleEnabled
        constants.setConstantValue(&safetyBubble, type: .bool, index: 2)
        var shadows = request.shadowsEnabled
        constants.setConstantValue(&shadows, type: .bool, index: 11)
        var sphereProjection = request.sphereProjectionEnabled
        constants.setConstantValue(&sphereProjection, type: .bool, index: 17)
        var spaceWarp = request.hasSpaceWarp
        constants.setConstantValue(&spaceWarp, type: .bool, index: 3)
        var environment = request.hasEnvScrunch
        constants.setConstantValue(&environment, type: .bool, index: 16)
        var handField = request.hasHandField
        constants.setConstantValue(&handField, type: .bool, index: 18)

        guard let fragmentFunction = try? library.makeFunction(
            name: "fragmentShaderMono",
            constantValues: constants
        ) else { return nil }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "Threshold Viewport Specialized [\(request.key)]"
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
