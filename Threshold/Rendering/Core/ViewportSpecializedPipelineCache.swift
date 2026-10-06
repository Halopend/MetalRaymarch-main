#if os(macOS) || os(iOS)
import Foundation
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
/// Tickets identify an individual build, including a rebuild of an evicted key.
struct PipelineBuildTicket: Equatable, Sendable {
    let key: String
    let generation: UInt64
}

/// Bounded cache shared by the viewport and pure cache-policy tests.
final class SpecializationCache<Value: Sendable>: Sendable {
    struct Statistics: Sendable {
        var hits = 0
        var builds = 0
        var failures = 0
        var evictions = 0
        var staleCompletions = 0
    }
    private struct Failure {
        var count: Int
        var retryAfter: TimeInterval
    }
    private struct State {
        var cache: [String: Value] = [:]
        var recency: [String] = []
        var pending: [String: PipelineBuildTicket] = [:]
        var failures: [String: Failure] = [:]
        var generation: UInt64 = 0
        var statistics = Statistics()
    }
    private let state = Mutex(State())
    private let capacity: Int
    init(capacity: Int = 64) { self.capacity = max(1, capacity) }

    func pipeline(for key: String) -> Value? {
        state.withLock { current in
            guard let value = current.cache[key] else { return nil }
            current.recency.removeAll { $0 == key }
            current.recency.append(key)
            current.statistics.hits += 1
            return value
        }
    }

    func beginBuildIfNeeded(_ key: String,
                            now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> PipelineBuildTicket? {
        state.withLock { current in
            guard current.cache[key] == nil, current.pending[key] == nil,
                  now >= (current.failures[key]?.retryAfter ?? 0) else { return nil }
            current.generation &+= 1
            let ticket = PipelineBuildTicket(key: key, generation: current.generation)
            current.pending[key] = ticket
            current.statistics.builds += 1
            return ticket
        }
    }

    func store(_ pipeline: Value, ticket: PipelineBuildTicket) {
        state.withLock { current in
            guard current.pending[ticket.key] == ticket else {
                current.statistics.staleCompletions += 1
                return
            }
            current.pending.removeValue(forKey: ticket.key)
            current.failures.removeValue(forKey: ticket.key)
            current.cache[ticket.key] = pipeline
            current.recency.removeAll { $0 == ticket.key }
            current.recency.append(ticket.key)
            while current.recency.count > capacity {
                current.cache.removeValue(forKey: current.recency.removeFirst())
                current.statistics.evictions += 1
            }
        }
    }

    /// Superseded requests release their ticket without recording a compiler failure.
    func cancelBuild(_ ticket: PipelineBuildTicket) {
        state.withLock { current in
            if current.pending[ticket.key] == ticket {
                current.pending.removeValue(forKey: ticket.key)
            }
        }
    }

    func failBuild(_ ticket: PipelineBuildTicket,
                   now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        state.withLock { current in
            guard current.pending[ticket.key] == ticket else { return }
            current.pending.removeValue(forKey: ticket.key)
            let count = min(5, (current.failures[ticket.key]?.count ?? 0) + 1)
            // Bound failure metadata as well as completed GPU resources.
            if current.failures[ticket.key] == nil, current.failures.count >= capacity,
               let oldest = current.failures.min(by: { $0.value.retryAfter < $1.value.retryAfter })?.key {
                current.failures.removeValue(forKey: oldest)
            }
            current.failures[ticket.key] = Failure(count: count,
                retryAfter: now + min(4, 0.25 * pow(2, Double(count - 1))))
            current.statistics.failures += 1
        }
    }

    func evict(prefix: String) {
        state.withLock { current in
            let removed = current.cache.keys.filter { $0.hasPrefix(prefix) }
            for key in removed { current.cache.removeValue(forKey: key) }
            current.statistics.evictions += removed.count
            current.recency.removeAll { $0.hasPrefix(prefix) }
            current.pending = current.pending.filter { !$0.key.hasPrefix(prefix) }
            current.failures = current.failures.filter { !$0.key.hasPrefix(prefix) }
        }
    }

    var statistics: Statistics { state.withLock { $0.statistics } }
    var count: Int { state.withLock { $0.cache.count } }
}

typealias ViewportSpecializedPipelineCache = SpecializationCache<MTLRenderPipelineState>

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
        let ticket: PipelineBuildTicket
        var key: String { ticket.key }
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
        let (supersededTicket, shouldStart): (PipelineBuildTicket?, Bool) = state.withLock { current in
            let supersededTicket = current.wanted?.ticket == request.ticket
                ? nil
                : current.wanted?.ticket
            current.wanted = request
            guard !current.draining else { return (supersededTicket, false) }
            current.draining = true
            return (supersededTicket, true)
        }

        // The renderer marked this key pending before handing it to us. If a
        // newer request replaced it before work began, release that pending mark
        // so revisiting the configuration can schedule it again.
        if let supersededTicket {
            cache.cancelBuild(supersededTicket)
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

            if let pipeline = autoreleasepool(invoking: { build(request) }) {
                cache.store(pipeline, ticket: request.ticket)
            } else {
                cache.failBuild(request.ticket)
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
