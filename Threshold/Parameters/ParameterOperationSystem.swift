import Foundation
import simd

enum ParameterOperationSource: String, Codable, Sendable {
    case gesture
    case slider
    case windowSlider
    case animation
    case precompute
    case audio
    case preset
    case system
}

enum ParameterOperationValue: Codable, Sendable {
    case absolute(Float)
    case delta(Float)

    func resolved(from current: Float) -> Float {
        switch self {
        case .absolute(let value): return value
        case .delta(let delta): return current + delta
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
final class ParameterOperationDispatcher: @unchecked Sendable {
    struct SourcePolicy: Sendable {
        let priority: [ParameterOperationSource: Int]

        static let `default` = SourcePolicy(priority: [
            .gesture: 10,
            .windowSlider: 20,
            .slider: 25,
            .precompute: 28,
            .animation: 30,
            .audio: 35,
            .preset: 40,
            .system: 50
        ])

        func rank(for source: ParameterOperationSource) -> Int {
            priority[source] ?? 0
        }
    }

    private var coreStacks: [String: ParameterLayerStack] = [:]
    private var formulaStacks: [String: ParameterLayerStack] = [:]

    private struct CoreParameterDescriptor {
        let range: ClosedRange<Float>
        let bundle: ParameterBundle
        let read: (RenderSettings) -> Float
        let write: (RenderSettings, Float) -> Void
    }

    private let coreDescriptors: [String: CoreParameterDescriptor] = [
        "core.targetFractalScale": CoreParameterDescriptor(
            range: -5.0...8.0,
            bundle: .scale,
            read: { $0.targetFractalScale },
            write: { settings, value in settings.targetFractalScale = value }
        ),
        "core.colorMix": CoreParameterDescriptor(
            range: 0.0...1.0,
            bundle: .color,
            read: { $0.colorMix },
            write: { settings, value in settings.colorMix = value }
        ),
        "core.fractalIterations": CoreParameterDescriptor(
            range: 2.0...24.0,
            bundle: .fractalCore,
            read: { Float($0.fractalIterations) },
            write: { settings, value in settings.fractalIterations = max(2, min(24, Int(round(value)))) }
        ),
        "effect.glow": CoreParameterDescriptor(
            range: 0.0...2.0,
            bundle: .lighting,
            read: { $0.glowEffect.intensity },
            write: { settings, value in settings.audioModulateGlowIntensity(value) }
        ),
        "effect.fog": CoreParameterDescriptor(
            range: 0.0...1.0,
            bundle: .lighting,
            read: { $0.fogEffect.intensity },
            write: { settings, value in settings.audioModulateFogIntensity(value) }
        ),
        "effect.bloom": CoreParameterDescriptor(
            range: 0.0...2.0,
            bundle: .lighting,
            read: { $0.bloomEffect.strength },
            write: { settings, value in settings.audioModulateBloomStrength(value) }
        ),
        "effect.hueSpeed": CoreParameterDescriptor(
            range: 0.0...0.5,
            bundle: .color,
            read: { $0.hueRotationEffect.speed },
            write: { settings, value in settings.audioModulateHueSpeed(value) }
        ),
        "effect.saturation": CoreParameterDescriptor(
            range: 0.0...3.0,
            bundle: .color,
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

    func dispatch(_ transaction: ParameterTransaction, settings: RenderSettings) {
        resolve(transaction).forEach { resolved in
            apply(resolved, settings: settings)
        }
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
        let pieces = operation.targetID.split(separator: ".")
        if pieces.count >= 4,
           pieces[0] == "formula",
           let fractalRaw = Int(pieces[1]),
           let formulaIndex = Int(pieces[2]),
           let fractalType = FractalModelType(rawValue: Int32(fractalRaw)) {
            var params = settings.formulaParams
            let current = FormulaCatalog.getParam(params, index: formulaIndex)
            let nodeRange: ClosedRange<Float> = ParameterNodeRegistry.shared
                .node(for: fractalType, formulaIndex: formulaIndex)?.range ?? -Float.greatestFiniteMagnitude...Float.greatestFiniteMagnitude
            var stack = formulaStacks[operation.targetID] ?? ParameterLayerStack(defaultValue: current, range: nodeRange, timestamp: timestamp)
            stack.setBaseIfNeeded(current, timestamp: timestamp)
            let incoming = operation.value.resolved(from: stack.resolvedValue(at: timestamp))
            // Mandelbox shape params (indices 0-2) use smoothDamp in
            // interpolateToTargets via the bridge, so bypass the layer stack's
            // own exponential lerp to avoid double-smoothing.
            let useSmoothDampBridge = fractalType == .mandelbox && formulaIndex <= 2
            let effectiveSmoothTime = useSmoothDampBridge ? Float(0) : operation.smoothing.smoothingTime
            let resolved = stack.apply(layer: layer, value: incoming, smoothingTime: effectiveSmoothTime, timestamp: timestamp)
            FormulaCatalog.setParam(&params, index: formulaIndex, value: resolved)
            settings.formulaParams = params
            formulaStacks[operation.targetID] = stack
            if debugTraceEnabled {
                print("🧮 ParamOp frame=\(operation.frameIndex) target=\(operation.targetID) src=\(operation.source.rawValue) value=\(resolved)")
            }
            return
        }

        applyCore(operation, settings: settings, layer: layer)
    }

    /// Core parameters that already have smoothDamp in `interpolateToTargets()`.
    /// For these, the layer stack resolves priority (which source wins) but does NOT
    /// add its own exponential lerp — that caused double-smoothing and stall bugs
    /// where the partially-lerped value froze when operations stopped arriving.
    private static let smoothDampedCoreIDs: Set<String> = [
        "core.targetFractalScale"
    ]

    private func applyCore(_ operation: ParameterOperation, settings: RenderSettings?, layer: ParameterLayer) {
        guard let settings else { return }
        guard let descriptor = coreDescriptors[operation.targetID] else { return }

        let bypassLayerSmoothing = Self.smoothDampedCoreIDs.contains(operation.targetID)

        var stack = coreStacks[operation.targetID]

        if stack == nil {
            let base = descriptor.read(settings)
            stack = ParameterLayerStack(defaultValue: base, range: descriptor.range, timestamp: operation.timestamp)
        }

        stack?.setBaseIfNeeded(descriptor.read(settings), timestamp: operation.timestamp)

        let current = stack?.resolvedValue(at: operation.timestamp) ?? descriptor.read(settings)
        let incoming = operation.value.resolved(from: current)

        if bypassLayerSmoothing {
            // smoothDamp in interpolateToTargets() handles animation, so bypass the
            // layer stack's own exponential lerp (smoothingTime=0). However, use the
            // stack's *resolved* value for the write so that the music layer's
            // additive offset is correctly combined with the base (gesture/slider)
            // value instead of overwriting it with the raw incoming offset.
            let resolved = stack?.apply(layer: layer, value: incoming, smoothingTime: 0, timestamp: operation.timestamp)
                ?? min(descriptor.range.upperBound, max(descriptor.range.lowerBound, incoming))
            descriptor.write(settings, resolved)
        } else {
            let resolved = stack?.apply(layer: layer, value: incoming, smoothingTime: operation.smoothing.smoothingTime, timestamp: operation.timestamp) ?? incoming
            descriptor.write(settings, min(descriptor.range.upperBound, max(descriptor.range.lowerBound, resolved)))
        }
        if let stack { coreStacks[operation.targetID] = stack }

        if debugTraceEnabled {
            print("🧮 ParamOp frame=\(operation.frameIndex) target=\(operation.targetID) src=\(operation.source.rawValue) value=\(incoming)")
        }
    }

    private func layer(for source: ParameterOperationSource) -> ParameterLayer {
        switch source {
        case .gesture: return .gesture
        case .slider, .windowSlider, .preset: return .ui
        case .precompute: return .precompute
        case .audio: return .music
        case .animation, .system: return .system
        }
    }

    /// Zero out the music (audio) layer in every core parameter stack and re-write
    /// the stack-resolved value to settings. Call when audio reactivity stops so
    /// stale music offsets don't bleed into subsequent slider / gesture operations.
    func clearMusicLayers(settings: RenderSettings) {
        let timestamp = CFAbsoluteTimeGetCurrent()
        for (id, var stack) in coreStacks {
            let resolved = stack.apply(layer: .music, value: 0, smoothingTime: 0, timestamp: timestamp)
            coreStacks[id] = stack
            // For bypass IDs, write the corrected value to settings so the stale
            // music offset is removed.  Non-bypass IDs also benefit from cleanup.
            if let descriptor = coreDescriptors[id] {
                descriptor.write(settings, resolved)
            }
        }
        // Also clear the music layer in formula param stacks (e.g. Mandelbox
        // shape params that are now dispatched via the formula path).
        var params = settings.formulaParams
        for (id, var stack) in formulaStacks {
            let resolved = stack.apply(layer: .music, value: 0, smoothingTime: 0, timestamp: timestamp)
            formulaStacks[id] = stack
            // Parse formula index from the ID and write back to formulaParams
            let pieces = id.split(separator: ".")
            if pieces.count >= 3, pieces[0] == "formula",
               let formulaIndex = Int(pieces[2]) {
                FormulaCatalog.setParam(&params, index: formulaIndex, value: resolved)
            }
        }
        settings.formulaParams = params
    }

    /// Discard all formula parameter layer stacks. Call when the fractal type
    /// changes so stale entries from the old type's formula params don't interfere
    /// with the new type.
    func clearFormulaStacks() {
        formulaStacks.removeAll()
    }
}
