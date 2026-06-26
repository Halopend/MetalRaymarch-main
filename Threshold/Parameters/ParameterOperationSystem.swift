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

    /// Current value of a core/effect target read straight from RenderSettings, or
    /// nil if the id isn't a routable core descriptor. Lets the gesture path seed a
    /// scalar drag for core params (which, unlike formula params, aren't read via
    /// `settings.formulaParams`).
    func coreValue(for targetID: String, settings: RenderSettings) -> Float? {
        coreDescriptors[targetID].map { $0.read(settings) }
    }

    private func recordLiveValue(_ targetID: String, base: Float, resolved: Float) {
        _liveValues.withLock { $0[targetID] = LiveValue(base: base, resolved: resolved) }
    }

    private struct CoreParameterDescriptor {
        let range: ClosedRange<Float>
        let motionStrategy: ParameterMotionStrategy
        let read: (RenderSettings) -> Float
        let write: (RenderSettings, Float) -> Void

        /// Playback-relative music routing. During animation playback `applyKeyframe`
        /// owns this param's backing var every frame, so the plain absolute `write`
        /// above would be stomped. When present and `isActive` (the scene keyframe drives
        /// the channel), the dispatcher instead deposits the pure music delta via
        /// `writeOffset`, which `applyKeyframe` composes on top of the live animation
        /// base. nil → the param isn't keyframe-driven, so the absolute write survives.
        let writeAudioOffset: ((RenderSettings, Float) -> Void)?
        let audioOffsetActiveDuringPlayback: ((RenderSettings) -> Bool)?

        /// Source range + motion from the canonical `ControlSpec` (single source
        /// of truth); only the RenderSettings read/write wiring is local here.
        init(spec: ControlSpec,
             read: @escaping (RenderSettings) -> Float,
             write: @escaping (RenderSettings, Float) -> Void,
             writeAudioOffset: ((RenderSettings, Float) -> Void)? = nil,
             audioOffsetActiveDuringPlayback: ((RenderSettings) -> Bool)? = nil) {
            self.range = spec.range
            self.motionStrategy = spec.motionStrategy
            self.read = read
            self.write = write
            self.writeAudioOffset = writeAudioOffset
            self.audioOffsetActiveDuringPlayback = audioOffsetActiveDuringPlayback
        }
    }

    static let routableDescriptorTargetIDs: Set<String> = Set(ParameterTargetID.coreAndEffect)

    private let coreDescriptors: [String: CoreParameterDescriptor] = [
        ControlCatalog.fractalScale.id: CoreParameterDescriptor(
            spec: ControlCatalog.fractalScale,
            read: { $0.targetFractalScale },
            write: { settings, value in settings.targetFractalScale = value },
            // fractalScale is always scene-driven during playback (non-optional keyframe).
            writeAudioOffset: { settings, offset in settings.audioOffsetFractalScale = offset },
            audioOffsetActiveDuringPlayback: { _ in true }
        ),
        ControlCatalog.colorMix.id: CoreParameterDescriptor(
            spec: ControlCatalog.colorMix,
            read: { $0.colorMix },
            write: { settings, value in settings.colorMix = value }
        ),
        ControlCatalog.iterations.id: CoreParameterDescriptor(
            spec: ControlCatalog.iterations,
            read: { Float($0.fractalIterations) },
            write: { settings, value in settings.fractalIterations = max(2, min(24, Int(round(value)))) }
        ),
        ControlCatalog.glow.id: CoreParameterDescriptor(
            spec: ControlCatalog.glow,
            read: { $0.glowEffect.intensity },
            write: { settings, value in settings.audioModulateGlowIntensity(value) },
            writeAudioOffset: { settings, offset in settings.audioOffsetGlowIntensity = offset },
            audioOffsetActiveDuringPlayback: { $0.sceneDrivesGlow }
        ),
        ControlCatalog.fog.id: CoreParameterDescriptor(
            spec: ControlCatalog.fog,
            read: { $0.fogEffect.intensity },
            write: { settings, value in settings.audioModulateFogIntensity(value) },
            writeAudioOffset: { settings, offset in settings.audioOffsetFogIntensity = offset },
            audioOffsetActiveDuringPlayback: { $0.sceneDrivesFog }
        ),
        ControlCatalog.bloom.id: CoreParameterDescriptor(
            spec: ControlCatalog.bloom,
            read: { $0.bloomEffect.strength },
            write: { settings, value in settings.audioModulateBloomStrength(value) },
            writeAudioOffset: { settings, offset in settings.audioOffsetBloomStrength = offset },
            audioOffsetActiveDuringPlayback: { $0.sceneDrivesBloom }
        ),
        ControlCatalog.hueSpeed.id: CoreParameterDescriptor(
            spec: ControlCatalog.hueSpeed,
            read: { $0.hueRotationEffect.speed },
            write: { settings, value in settings.audioModulateHueSpeed(value) },
            writeAudioOffset: { settings, offset in settings.audioOffsetHueSpeed = offset },
            audioOffsetActiveDuringPlayback: { $0.sceneDrivesHueSpeed }
        ),
        ControlCatalog.saturation.id: CoreParameterDescriptor(
            spec: ControlCatalog.saturation,
            read: { $0.colorSchemeSaturation },
            write: { settings, value in settings.audioModulateSaturation(value) },
            writeAudioOffset: { settings, offset in settings.audioOffsetSaturation = offset },
            audioOffsetActiveDuringPlayback: { $0.sceneDrivesSaturation }
        ),
        ControlCatalog.safetyBubbleRadius.id: CoreParameterDescriptor(
            spec: ControlCatalog.safetyBubbleRadius,
            read: { $0.safetyBubbleRadius },
            write: { settings, value in settings.audioModulateSafetyBubbleRadius(value) }
        ),
        ControlCatalog.sphereProjectionBlend.id: CoreParameterDescriptor(
            spec: ControlCatalog.sphereProjectionBlend,
            read: { $0.sphereProjectionBlend },
            write: { settings, value in settings.audioModulateSphereProjectionBlend(value) }
        ),
        ControlCatalog.sphereProjectionRadius.id: CoreParameterDescriptor(
            spec: ControlCatalog.sphereProjectionRadius,
            read: { $0.sphereProjectionRadius },
            write: { settings, value in settings.audioModulateSphereProjectionRadius(value) }
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

        if operation.source == .slider {
            // Manual edit: ask the music engine to re-zero this target's drift/
            // decay/phase so audio variation restarts cleanly around the new value.
            cache.renderSettings?.requestMusicRecenter(targetID: operation.targetID)
        }

        let formulaBatch = ParameterNodeRegistry.shared.formulaBatch(for: cache.fractalType)
        if let node = formulaBatch.floatNodes.first(where: { $0.id == operation.targetID }) {
            node.bootstrapBaseIfNeeded(from: node.readValue(cache), timestamp: timestamp)
            let current = node.resolvedValue(timestamp: timestamp)
            let incoming = operation.value.resolved(from: current)
            let resolved = node.applyLayer(layer, value: incoming, smoothingTime: operation.smoothing.smoothingTime, timestamp: timestamp)
            node.writeValue(cache, resolved)
            if operation.source == .slider {
                // A formula slider writes only this per-node stack; re-anchor the
                // separate settings-path stack the audio layer composes on so the
                // music center follows the edit instead of a frozen bootstrap.
                recenterMusicBase(targetID: operation.targetID, to: incoming)
            }
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

        if operation.source == .gesture {
            // Manual gesture edit: the .gesture layer already re-anchors the base
            // (same stack the audio layer uses); also re-zero the engine's
            // accumulated drift/decay/phase so variation restarts around it.
            settings.requestMusicRecenter(targetID: operation.targetID)
        }

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

            if settings.isAnimationPlaying {
                // During playback the per-frame formula rebuild owns `formulaParams`, so a
                // direct write is stomped. Route gesture/slider edits into the manual
                // override and music into the audio offset; the rebuild composes
                // animationBase + manualOffset + audioOffset. The music op carries a pure
                // delta, recovered as resolved − anchor (the additive `.music` layer).
                switch operation.source {
                case .gesture, .slider:
                    settings.setManualFormulaParamOverride(index: formulaIndex, value: resolved)
                case .audio:
                    settings.setAudioFormulaParamOffset(index: formulaIndex, offset: resolved - outcome.base)
                }
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

        // During animation playback, applyKeyframe owns this param's backing var every
        // frame, so an absolute music write is stomped. Deposit the pure music delta
        // (resolved − anchor) into the playback offset slot the keyframe composer reads.
        // Only `.music` ops reroute; gestures/sliders keep the absolute write so their
        // existing playback behavior is unchanged.
        if layer == .music,
           settings.isAnimationPlaying,
           let writeAudioOffset = descriptor.writeAudioOffset,
           descriptor.audioOffsetActiveDuringPlayback?(settings) == true {
            writeAudioOffset(settings, resolved - outcome.base)
        } else {
            descriptor.write(settings, resolved)
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

    /// Re-anchor the music "center of variation" for a formula target to a fresh
    /// manual value. The audio layer composes additively on the settings-path
    /// `formulaStacks`, but a formula slider writes a *separate* per-node stack, so
    /// without this the audio base stays frozen at its first bootstrap and
    /// overwrites the slider every frame. No-op until the stack exists (i.e. until
    /// audio has touched the target). Core/effect targets self-recenter via the
    /// shared `coreStacks` `.ui` write, so they are intentionally excluded here.
    func recenterMusicBase(targetID: String, to value: Float) {
        guard ParameterTargetID.parseFormulaID(targetID) != nil else { return }
        let timestamp = CFAbsoluteTimeGetCurrent()
        let touched: Bool = _state.withLock { state in
            guard var stack = state.formulaStacks[targetID] else { return false }
            stack.recenterBase(to: value, timestamp: timestamp, clearGesture: true)
            state.formulaStacks[targetID] = stack
            return true
        }
        if touched {
            // Collapse the live snapshot to the new base so the ghost marker
            // doesn't flash a stale offset before the next audio frame recomputes.
            recordLiveValue(targetID, base: value, resolved: value)
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
