import Foundation
import Synchronization
import simd

enum ParameterOperationSource: String, Codable, Sendable {
    case gesture
    case slider
    case audio
}

enum ParameterOperationValue: Codable, Sendable {
    case absolute(Float)

    func resolved(from current: Float) -> Float {
        switch self {
        case .absolute(let value): return value
        }
    }
}

struct ParameterOperationSmoothing: Codable, Sendable {
    var smoothingTime: Float?

    init(smoothingTime: Float? = nil) {
        self.smoothingTime = smoothingTime
    }
}

struct ParameterOperation: Codable, Sendable, Identifiable {
    let id: UUID
    let targetID: String
    let source: ParameterOperationSource
    let value: ParameterOperationValue
    let timestamp: TimeInterval
    let frameIndex: UInt64
    let smoothing: ParameterOperationSmoothing

    init(targetID: String,
         source: ParameterOperationSource,
         value: ParameterOperationValue,
         timestamp: TimeInterval = CFAbsoluteTimeGetCurrent(),
         frameIndex: UInt64,
         smoothing: ParameterOperationSmoothing = .init()) {
        self.id = UUID()
        self.targetID = targetID
        self.source = source
        self.value = value
        self.timestamp = timestamp
        self.frameIndex = frameIndex
        self.smoothing = smoothing
    }
}

struct ParameterTransaction: Sendable {
    let frameIndex: UInt64
    let timestamp: TimeInterval
    let operations: [ParameterOperation]

    init(frameIndex: UInt64,
         timestamp: TimeInterval = CFAbsoluteTimeGetCurrent(),
         operations: [ParameterOperation]) {
        self.frameIndex = frameIndex
        self.timestamp = timestamp
        self.operations = operations
    }
}

// Not @MainActor: instances are owned per-caller (UISettingsCache, GestureController, Renderer).
// The cache-based dispatch path is @MainActor since it touches MainActor-isolated node closures.
// The settings-based path only writes through lock-protected RenderSettings.
// Mutable layer stacks are synchronized so dispatch remains safe even if an owner
// starts driving one dispatcher from multiple contexts.
final class ParameterOperationDispatcher: @unchecked Sendable {
    private struct State: Sendable {
        var coreStacks: [String: ParameterLayerStack] = [:]
        var formulaStacks: [String: ParameterLayerStack] = [:]
    }

    struct SourcePolicy: Sendable {
        let priority: [ParameterOperationSource: Int]

        static let `default` = SourcePolicy(priority: [
            .gesture: 10,
            .slider: 25,
            .audio: 35
        ])

        func rank(for source: ParameterOperationSource) -> Int {
            priority[source] ?? 0
        }
    }

    private let _state = Mutex(State())

    /// Live (base, resolved) snapshot per target, refreshed every time an operation
    /// is applied through the settings path (gesture/animation/audio). The UI reads
    /// this to render a "derived value" ghost indicator without touching — and racing
    /// on — the authoritative, mutating layer stacks.
    struct LiveValue: Sendable {
        let base: Float
        let resolved: Float
        /// True when an additive layer is currently displacing the parameter enough
        /// to be worth showing as a distinct derived value.
        var isModulated: Bool { abs(resolved - base) > 1e-4 }
    }
    private let _liveValues = Mutex<[String: LiveValue]>([:])

    /// Latest (base, resolved) snapshot for a target, or nil if it has never been
    /// driven through the settings path.
    func liveValue(for targetID: String) -> LiveValue? {
        _liveValues.withLock { $0[targetID] }
    }

    private func recordLiveValue(_ targetID: String, base: Float, resolved: Float) {
        _liveValues.withLock { $0[targetID] = LiveValue(base: base, resolved: resolved) }
    }

    private struct CoreParameterDescriptor {
        let range: ClosedRange<Float>
        let motionStrategy: ParameterMotionStrategy
        let read: (RenderSettings) -> Float
        let write: (RenderSettings, Float) -> Void
    }

    static let routableDescriptorTargetIDs: Set<String> = Set(ParameterTargetID.coreAndEffect)

    private let coreDescriptors: [String: CoreParameterDescriptor] = [
        ParameterTargetID.Core.fractalScale: CoreParameterDescriptor(
            range: -5.0...8.0,
            motionStrategy: .smoothDamp,
            read: { $0.targetFractalScale },
            write: { settings, value in settings.targetFractalScale = value }
        ),
        ParameterTargetID.Core.colorMix: CoreParameterDescriptor(
            range: 0.0...1.0,
            motionStrategy: .layerLerp,
            read: { $0.colorMix },
            write: { settings, value in settings.colorMix = value }
        ),
        ParameterTargetID.Core.iterations: CoreParameterDescriptor(
            range: 2.0...24.0,
            motionStrategy: .layerLerp,
            read: { Float($0.fractalIterations) },
            write: { settings, value in settings.fractalIterations = max(2, min(24, Int(round(value)))) }
        ),
        ParameterTargetID.Effect.glow: CoreParameterDescriptor(
            range: 0.0...2.0,
            motionStrategy: .layerLerp,
            read: { $0.glowEffect.intensity },
            write: { settings, value in settings.audioModulateGlowIntensity(value) }
        ),
        ParameterTargetID.Effect.fog: CoreParameterDescriptor(
            range: 0.0...1.0,
            motionStrategy: .layerLerp,
            read: { $0.fogEffect.intensity },
            write: { settings, value in settings.audioModulateFogIntensity(value) }
        ),
        ParameterTargetID.Effect.bloom: CoreParameterDescriptor(
            range: 0.0...2.0,
            motionStrategy: .layerLerp,
            read: { $0.bloomEffect.strength },
            write: { settings, value in settings.audioModulateBloomStrength(value) }
        ),
        ParameterTargetID.Effect.hueSpeed: CoreParameterDescriptor(
            range: 0.0...0.5,
            motionStrategy: .layerLerp,
            read: { $0.hueRotationEffect.speed },
            write: { settings, value in settings.audioModulateHueSpeed(value) }
        ),
        ParameterTargetID.Effect.saturation: CoreParameterDescriptor(
            range: 0.0...3.0,
            motionStrategy: .layerLerp,
            read: { $0.colorSchemeSaturation },
            write: { settings, value in settings.audioModulateSaturation(value) }
        )
    ]

    private let sourcePolicy: SourcePolicy
    var debugTraceEnabled = false

    init(sourcePolicy: SourcePolicy = .default) {
        self.sourcePolicy = sourcePolicy
    }

    @MainActor
    func dispatch(_ transaction: ParameterTransaction, cache: UISettingsCache) {
        resolve(transaction).forEach { resolved in
            apply(resolved, cache: cache)
        }
    }

    /// Convenience: wrap a bare operation array into a transaction.
    @MainActor
    func dispatch(_ operations: [ParameterOperation], cache: UISettingsCache) {
        guard let first = operations.first else { return }
        let txn = ParameterTransaction(frameIndex: first.frameIndex, operations: operations)
        dispatch(txn, cache: cache)
    }

    func dispatch(_ transaction: ParameterTransaction, settings: RenderSettings) {
        resolve(transaction).forEach { resolved in
            apply(resolved, settings: settings)
        }
    }

    /// Convenience: wrap a bare operation array into a transaction.
    func dispatch(_ operations: [ParameterOperation], settings: RenderSettings) {
        guard let first = operations.first else { return }
        let txn = ParameterTransaction(frameIndex: first.frameIndex, operations: operations)
        dispatch(txn, settings: settings)
    }

    private func resolve(_ transaction: ParameterTransaction) -> [ParameterOperation] {
        var grouped: [String: [ParameterOperation]] = [:]
        for operation in transaction.operations {
            grouped[operation.targetID, default: []].append(operation)
        }

        var resolved: [ParameterOperation] = []
        for (_, operations) in grouped {
            guard let winner = operations.max(by: { lhs, rhs in
                let leftRank = sourcePolicy.rank(for: lhs.source)
                let rightRank = sourcePolicy.rank(for: rhs.source)
                if leftRank != rightRank { return leftRank < rightRank }
                return lhs.timestamp < rhs.timestamp
            }) else { continue }

            if debugTraceEnabled, operations.count > 1 {
                let contenders = operations
                    .map { "\($0.source.rawValue)(p:\(sourcePolicy.rank(for: $0.source)))" }
                    .joined(separator: ", ")
                print("🧮 ParamOp conflict target=\(winner.targetID) [\(contenders)] -> \(winner.source.rawValue)")
            }

            resolved.append(winner)
        }

        return resolved
    }

    @MainActor
    private func apply(_ operation: ParameterOperation, cache: UISettingsCache) {
        let timestamp = operation.timestamp
        let layer = layer(for: operation.source)

        let formulaBatch = ParameterNodeRegistry.shared.formulaBatch(for: cache.fractalType)
        if let node = formulaBatch.floatNodes.first(where: { $0.id == operation.targetID }) {
            node.bootstrapBaseIfNeeded(from: node.readValue(cache), timestamp: timestamp)
            let current = node.resolvedValue(timestamp: timestamp)
            let incoming = operation.value.resolved(from: current)
            let resolved = node.applyLayer(layer, value: incoming, smoothingTime: operation.smoothing.smoothingTime, timestamp: timestamp)
            node.writeValue(cache, resolved)
            if debugTraceEnabled {
                print("🧮 ParamOp frame=\(operation.frameIndex) target=\(operation.targetID) src=\(operation.source.rawValue) value=\(resolved)")
            }
            return
        }

        if let boolNode = formulaBatch.boolNodes.first(where: { $0.id == operation.targetID }) {
            let current = boolNode.readValue(cache) ? 1 as Float : 0 as Float
            let newValue = operation.value.resolved(from: current)
            boolNode.writeValue(cache, newValue >= 0.5)
            if debugTraceEnabled {
                print("🧮 ParamOp frame=\(operation.frameIndex) target=\(operation.targetID) src=\(operation.source.rawValue) value=\(newValue >= 0.5)")
            }
            return
        }

        applyCore(operation, settings: cache.renderSettings, layer: layer)
    }

    private func apply(_ operation: ParameterOperation, settings: RenderSettings) {
        let timestamp = operation.timestamp
        let layer = layer(for: operation.source)
        if let formulaID = ParameterTargetID.parseFormulaID(operation.targetID) {
            let fractalType = formulaID.fractalType
            let formulaIndex = formulaID.formulaIndex
            var params = settings.formulaParams
            let current = FormulaCatalog.getParam(params, index: formulaIndex)
            let nodeRange: ClosedRange<Float> = ParameterNodeRegistry.shared
                .node(for: fractalType, formulaIndex: formulaIndex)?.range ?? -Float.greatestFiniteMagnitude...Float.greatestFiniteMagnitude
            let outcome = _state.withLock { state -> (resolved: Float, base: Float) in
                var stack = state.formulaStacks[operation.targetID] ?? ParameterLayerStack(defaultValue: current, range: nodeRange, timestamp: timestamp)
                stack.setBaseIfNeeded(current, timestamp: timestamp)
                let incoming = operation.value.resolved(from: stack.resolvedValue(at: timestamp))
                let strategy = ParameterNodeRegistry.shared
                    .node(for: fractalType, formulaIndex: formulaIndex)?
                    .motionStrategy ?? .layerLerp
                let effectiveSmoothTime = smoothingTime(for: strategy, requested: operation.smoothing.smoothingTime)
                let resolved = stack.apply(layer: layer, value: incoming, smoothingTime: effectiveSmoothTime, timestamp: timestamp)
                let anchor = stack.baseRawValue ?? current
                state.formulaStacks[operation.targetID] = stack
                return (resolved, anchor)
            }
            let resolved = outcome.resolved
            recordLiveValue(operation.targetID, base: outcome.base, resolved: resolved)
            let usesPlaybackRelativeManualOverride: Bool = settings.isAnimationPlaying && {
                switch operation.source {
                case .gesture, .slider:
                    return true
                default:
                    return false
                }
            }()

            if usesPlaybackRelativeManualOverride {
                settings.setManualFormulaParamOverride(index: formulaIndex, value: resolved)
            } else {
                FormulaCatalog.setParam(&params, index: formulaIndex, value: resolved)
                settings.formulaParams = params
            }
            if debugTraceEnabled {
                print("🧮 ParamOp frame=\(operation.frameIndex) target=\(operation.targetID) src=\(operation.source.rawValue) value=\(resolved)")
            }
            return
        }

        applyCore(operation, settings: settings, layer: layer)
    }

    private func applyCore(_ operation: ParameterOperation, settings: RenderSettings?, layer: ParameterLayer) {
        guard let settings else { return }
        guard let descriptor = coreDescriptors[operation.targetID] else { return }

        let base = descriptor.read(settings)
        let outcome = _state.withLock { state -> (resolved: Float, base: Float) in
            var stack = state.coreStacks[operation.targetID] ?? ParameterLayerStack(defaultValue: base, range: descriptor.range, timestamp: operation.timestamp)
            stack.setBaseIfNeeded(base, timestamp: operation.timestamp)

            let current = stack.resolvedValue(at: operation.timestamp)
            let incoming = operation.value.resolved(from: current)
            let effectiveSmoothTime = smoothingTime(for: descriptor.motionStrategy, requested: operation.smoothing.smoothingTime)
            let resolved = stack.apply(layer: layer, value: incoming, smoothingTime: effectiveSmoothTime, timestamp: operation.timestamp)
            let anchor = stack.baseRawValue ?? base

            state.coreStacks[operation.targetID] = stack
            return (min(descriptor.range.upperBound, max(descriptor.range.lowerBound, resolved)), anchor)
        }
        let resolved = outcome.resolved

        recordLiveValue(operation.targetID, base: outcome.base, resolved: resolved)
        descriptor.write(settings, resolved)

        if debugTraceEnabled {
            print("🧮 ParamOp frame=\(operation.frameIndex) target=\(operation.targetID) src=\(operation.source.rawValue) value=\(resolved)")
        }
    }

    private func layer(for source: ParameterOperationSource) -> ParameterLayer {
        switch source {
        case .gesture: return .gesture
        case .slider: return .ui
        case .audio: return .music
        }
    }

    private func smoothingTime(for strategy: ParameterMotionStrategy, requested: Float?) -> Float? {
        switch strategy {
        case .none, .smoothDamp:
            return 0
        case .layerLerp:
            return requested
        }
    }

    /// Zero out the music (audio) layer in every core parameter stack and re-write
    /// the stack-resolved value to settings. Call when audio reactivity stops so
    /// stale music offsets don't bleed into subsequent slider / gesture operations.
    func clearMusicLayers(settings: RenderSettings) {
        let timestamp = CFAbsoluteTimeGetCurrent()
        let cleared = _state.withLock { state -> (core: [(String, Float)], formula: [(Int, Float)]) in
            var coreWrites: [(String, Float)] = []
            var formulaWrites: [(Int, Float)] = []

            for (id, var stack) in state.coreStacks {
                let resolved = stack.apply(layer: .music, value: 0, smoothingTime: 0, timestamp: timestamp)
                state.coreStacks[id] = stack
                coreWrites.append((id, resolved))
            }

            for (id, var stack) in state.formulaStacks {
                let resolved = stack.apply(layer: .music, value: 0, smoothingTime: 0, timestamp: timestamp)
                state.formulaStacks[id] = stack
                if let formula = ParameterTargetID.parseFormulaID(id) {
                    let formulaIndex = formula.formulaIndex
                    formulaWrites.append((formulaIndex, resolved))
                }
            }

            return (coreWrites, formulaWrites)
        }

        for (id, resolved) in cleared.core {
            if let descriptor = coreDescriptors[id] {
                descriptor.write(settings, resolved)
            }
        }

        var params = settings.formulaParams
        for (formulaIndex, resolved) in cleared.formula {
            FormulaCatalog.setParam(&params, index: formulaIndex, value: resolved)
        }
        settings.formulaParams = params

        // Music is gone: collapse the derived snapshot to base so the UI ghost
        // indicators fade out and stop displaying a stale offset.
        for (id, resolved) in cleared.core {
            recordLiveValue(id, base: resolved, resolved: resolved)
        }
        _liveValues.withLock { live in
            for id in live.keys where ParameterTargetID.parseFormulaID(id) != nil {
                if let v = live[id] { live[id] = LiveValue(base: v.resolved, resolved: v.resolved) }
            }
        }
    }

    /// Discard all formula parameter layer stacks. Call when the fractal type
    /// changes so stale entries from the old type's formula params don't interfere
    /// with the new type.
    func clearFormulaStacks() {
        _state.withLock { state in
            state.formulaStacks.removeAll()
        }
        _liveValues.withLock { live in
            for id in live.keys where ParameterTargetID.parseFormulaID(id) != nil {
                live.removeValue(forKey: id)
            }
        }
    }
}
