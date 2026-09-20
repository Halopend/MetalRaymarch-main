import Foundation
import Synchronization
import simd

enum ParameterOperationSource: String, Codable, Sendable {
    case gesture
    case slider
    case audio
}

struct ParameterOperationSmoothing: Codable, Sendable {
    var smoothingTime: Float?

    init(smoothingTime: Float? = nil) {
        self.smoothingTime = smoothingTime
    }
}

struct ParameterOperation: Codable, Sendable {
    let targetID: String
    let source: ParameterOperationSource
    let value: Float
    let timestamp: TimeInterval
    let frameIndex: UInt64
    let smoothing: ParameterOperationSmoothing

    init(targetID: String,
         source: ParameterOperationSource,
         value: Float,
         timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime,
         frameIndex: UInt64,
         smoothing: ParameterOperationSmoothing = .init()) {
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
         timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime,
         operations: [ParameterOperation]) {
        self.frameIndex = frameIndex
        self.timestamp = timestamp
        self.operations = operations
    }
}

// One instance per scene session. UI, gesture and audio entry points acquire
// the settings transaction before pipeline state, keeping resolution and writes
// atomic. UI cache projection is MainActor-isolated; engine dispatch is not.
final class ParameterPipeline: @unchecked Sendable {
    private struct State: Sendable {
        var coreStacks: [String: ParameterLayerStack] = [:]
        var formulaStacks: [String: ParameterLayerStack] = [:]
        var sceneGeneration: UInt64?
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

    /// Current value of a core/effect target read straight from RenderSettings, or
    /// nil if the id isn't a routable core descriptor. Lets the gesture path seed a
    /// scalar drag for core params (which, unlike formula params, aren't read via
    /// `settings.formulaParams`).
    func coreValue(for targetID: String, settings: RenderSettings) -> Float? {
        (RenderParameterCatalog.byID[targetID]?.settings).map { $0.read(settings) }
    }

    private func recordLiveValue(_ targetID: String, base: Float, resolved: Float) {
        _liveValues.withLock { $0[targetID] = LiveValue(base: base, resolved: resolved) }
    }

    private let sourcePolicy: SourcePolicy
    var debugTraceEnabled = false

    init(sourcePolicy: SourcePolicy = .default) {
        self.sourcePolicy = sourcePolicy
    }

    func setDebugTraceEnabled(_ enabled: Bool) {
        debugTraceEnabled = enabled
    }

    @MainActor
    func dispatchUI(_ operations: [ParameterOperation], cache: ControlStateStore) {
        dispatch(operations, cache: cache)
    }

    func dispatchGesture(_ operations: [ParameterOperation], settings: RenderSettings) {
        dispatch(operations, settings: settings)
    }

    func dispatchAudio(_ operations: [ParameterOperation], settings: RenderSettings) {
        dispatch(operations, settings: settings)
    }

    func currentValue(for targetID: String, settings: RenderSettings) -> Float? {
        coreValue(for: targetID, settings: settings)
    }

    @MainActor
    func dispatch(_ transaction: ParameterTransaction, cache: ControlStateStore) {
        guard let settings = cache.renderSettings else { return }
        settings.withSceneTransaction {
            prepareForScene(settings.sceneLoadGeneration)
            resolve(transaction).forEach { apply($0, cache: cache) }
        }
    }

    /// Convenience: wrap a bare operation array into a transaction.
    @MainActor
    func dispatch(_ operations: [ParameterOperation], cache: ControlStateStore) {
        guard let first = operations.first else { return }
        let txn = ParameterTransaction(frameIndex: first.frameIndex, operations: operations)
        dispatch(txn, cache: cache)
    }

    func dispatch(_ transaction: ParameterTransaction, settings: RenderSettings) {
        settings.withSceneTransaction {
            prepareForScene(settings.sceneLoadGeneration)
            resolve(transaction).forEach { apply($0, settings: settings) }
        }
    }

    /// Convenience: wrap a bare operation array into a transaction.
    func dispatch(_ operations: [ParameterOperation], settings: RenderSettings) {
        guard let first = operations.first else { return }
        let txn = ParameterTransaction(frameIndex: first.frameIndex, operations: operations)
        dispatch(txn, settings: settings)
    }

    /// Called inside the settings transaction before consuming inputs or evaluating a frame.
    func prepareForScene(_ generation: UInt64) {
        let changed = _state.withLock { state in
            guard state.sceneGeneration != generation else { return false }
            state.coreStacks.removeAll()
            state.formulaStacks.removeAll()
            state.sceneGeneration = generation
            return true
        }
        if changed { _liveValues.withLock { $0.removeAll() } }
    }

    private func resolve(_ transaction: ParameterTransaction) -> [ParameterOperation] {
        // Deduplicate each source, not the entire target: an audio delta must
        // compose with a slider/gesture base even when delivered in one batch.
        var latest: [String: [ParameterOperationSource: ParameterOperation]] = [:]
        for operation in transaction.operations where operation.value.isFinite && operation.timestamp.isFinite {
            if let previous = latest[operation.targetID]?[operation.source],
               previous.timestamp > operation.timestamp { continue }
            latest[operation.targetID, default: [:]][operation.source] = operation
        }
        return latest.keys.sorted().flatMap { target in
            latest[target]!.values.sorted {
                let lhs = sourcePolicy.rank(for: $0.source)
                let rhs = sourcePolicy.rank(for: $1.source)
                return lhs == rhs ? $0.source.rawValue < $1.source.rawValue : lhs < rhs
            }
        }
    }

    @MainActor
    private func apply(_ operation: ParameterOperation, cache: ControlStateStore) {
        guard let settings = cache.renderSettings else { return }
        // UI and external inputs now use exactly the same layer history and
        // playback composition. The cache is a projection, never a second owner.
        apply(operation, settings: settings)
        if ParameterTargetID.parseFormulaID(operation.targetID) != nil {
            cache.formulaParams = settings.formulaParams
        }
    }

    private func apply(_ operation: ParameterOperation, settings: RenderSettings) {
        let timestamp = operation.timestamp
        let layer = layer(for: operation.source)

        if operation.source == .gesture || operation.source == .slider {
            // Manual gesture edit: the .gesture layer already re-anchors the base
            // (same stack the audio layer uses); also re-zero the engine's
            // accumulated drift/decay/phase so variation restarts around it.
            settings.requestMusicRecenter(targetID: operation.targetID)
        }

        if let formulaID = ParameterTargetID.parseFormulaID(operation.targetID) {
            let fractalType = formulaID.fractalType
            guard fractalType == settings.fractalType else { return }
            let formulaIndex = formulaID.formulaIndex
            let params = settings.formulaParams
            let current = FormulaCatalog.getParam(params, index: formulaIndex)
            let nodeRange: ClosedRange<Float> = ParameterNodeRegistry.shared
                .node(for: fractalType, formulaIndex: formulaIndex)?.range ?? -Float.greatestFiniteMagnitude...Float.greatestFiniteMagnitude
            let outcome = _state.withLock { state -> (resolved: Float, base: Float) in
                var stack = state.formulaStacks[operation.targetID] ?? ParameterLayerStack(defaultValue: current, range: nodeRange, timestamp: timestamp)
                stack.setBaseIfNeeded(current, timestamp: timestamp)
                let incoming = operation.value
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

            if settings.isAnimationPlaying {
                // During playback the per-frame formula rebuild owns `formulaParams`, so a
                // direct write is stomped. Route gesture/slider edits into the manual
                // override and music into the audio offset; the rebuild composes
                // animationBase + manualOffset + audioOffset. The music op carries a pure
                // delta, recovered as resolved − anchor (the additive `.music` layer).
                switch operation.source {
                case .gesture, .slider:
                    settings.setManualFormulaParamOverride(index: formulaIndex, value: outcome.base)
                case .audio:
                    settings.setAudioFormulaParamOffset(index: formulaIndex, offset: resolved - outcome.base)
                }
            } else {
                // Atomic per-slot write (inside the settings lock): the old
                // read → setParam → write-back through the property raced a
                // concurrent gesture/audio dispatch and lost one update.
                settings.mutateFormulaParam(index: formulaIndex, value: resolved)
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
        // Slice 3: source the off-main read/write + playback-offset closures from the
        // authored catalog (narrowed `settingsBinding` — never the @MainActor ui pair),
        // and range/motion from the canonical spec, instead of the deleted local
        // `coreDescriptors` literal. Behavior-identical to the prior CoreParameterDescriptor.
        guard let binding = RenderParameterCatalog.byID[operation.targetID]?.settings,
              let spec = ControlCatalog.spec(operation.targetID) else { return }

        let base = binding.read(settings)
        let outcome = _state.withLock { state -> (resolved: Float, base: Float) in
            var stack = state.coreStacks[operation.targetID] ?? ParameterLayerStack(defaultValue: base, range: spec.range, timestamp: operation.timestamp)
            stack.setBaseIfNeeded(base, timestamp: operation.timestamp)

            let incoming = operation.value
            let effectiveSmoothTime = smoothingTime(for: spec.motionStrategy, requested: operation.smoothing.smoothingTime)
            let resolved = stack.apply(layer: layer, value: incoming, smoothingTime: effectiveSmoothTime, timestamp: operation.timestamp)
            let anchor = stack.baseRawValue ?? base

            state.coreStacks[operation.targetID] = stack
            return (min(spec.range.upperBound, max(spec.range.lowerBound, resolved)), anchor)
        }
        let resolved = outcome.resolved

        recordLiveValue(operation.targetID, base: outcome.base, resolved: resolved)

        let isAnimated = settings.isAnimationPlaying
            && binding.audioOffsetActiveDuringPlayback?(settings) == true
        if layer == .music, isAnimated, let writeAudioOffset = binding.writeAudioOffset {
            writeAudioOffset(settings, resolved - outcome.base)
        } else {
            // Manual input changes the base, never a value that already includes
            // music. Preserve that adjustment as the animation advances.
            if isAnimated { binding.writeManualBase?(settings, outcome.base) }
            binding.write(settings, resolved)
        }

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
        settings.withSceneTransaction {
            prepareForScene(settings.sceneLoadGeneration)
            let timestamp = ProcessInfo.processInfo.systemUptime
            let currentFractal = settings.fractalType
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
                    if let formula = ParameterTargetID.parseFormulaID(id), formula.fractalType == currentFractal {
                        let formulaIndex = formula.formulaIndex
                        formulaWrites.append((formulaIndex, resolved))
                    }
                }

                return (coreWrites, formulaWrites)
            }

            for (id, resolved) in cleared.core {
                RenderParameterCatalog.byID[id]?.settings.write(settings, resolved)
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
    }

    /// Drop all layer history after a scene/preset becomes authoritative.
    ///
    /// Scene loading writes the new values directly to RenderSettings. Keeping
    /// the old stacks alive would let the next audio tick resolve against the
    /// previous scene's UI base and write those values back into the new scene.
    /// Resetting here makes the next operation bootstrap from the freshly loaded
    /// settings instead of from stale layer state.
    func resetForSceneLoad() {
        _state.withLock { state in
            state.coreStacks.removeAll()
            state.formulaStacks.removeAll()
        }
        _liveValues.withLock { $0.removeAll() }
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
