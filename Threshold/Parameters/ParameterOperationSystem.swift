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
    var easing: String?
    var smoothingTime: Float?
    var metadata: [String: Float]

    init(easing: String? = nil, smoothingTime: Float? = nil, metadata: [String: Float] = [:]) {
        self.easing = easing
        self.smoothingTime = smoothingTime
        self.metadata = metadata
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
         timestamp: TimeInterval = Date().timeIntervalSince1970,
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
         timestamp: TimeInterval = Date().timeIntervalSince1970,
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
        "core.targetMinDistance": CoreParameterDescriptor(
            range: -5.0...15.0,
            bundle: .fractalCore,
            read: { $0.targetMinDistance },
            write: { settings, value in settings.targetMinDistance = value }
        ),
        "core.targetFoldingLimit": CoreParameterDescriptor(
            range: -10.0...30.0,
            bundle: .fractalCore,
            read: { $0.targetFoldingLimit },
            write: { settings, value in settings.targetFoldingLimit = value }
        ),
        "core.targetSphereRadius": CoreParameterDescriptor(
            range: -5.0...8.0,
            bundle: .fractalCore,
            read: { $0.targetSphereRadius },
            write: { settings, value in settings.targetSphereRadius = value }
        ),
        "core.fractalScale": CoreParameterDescriptor(
            range: -5.0...8.0,
            bundle: .scale,
            read: { $0.fractalScale },
            write: { settings, value in settings.fractalScale = value }
        ),
        "core.colorMix": CoreParameterDescriptor(
            range: 0.0...1.0,
            bundle: .color,
            read: { $0.colorMix },
            write: { settings, value in settings.colorMix = value }
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
            let resolved = stack.apply(layer: layer, value: incoming, smoothingTime: operation.smoothing.smoothingTime, timestamp: timestamp)
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

    private func applyCore(_ operation: ParameterOperation, settings: RenderSettings?, layer: ParameterLayer) {
        guard let settings else { return }
        guard let descriptor = coreDescriptors[operation.targetID] else { return }

        var stack = coreStacks[operation.targetID]

        if stack == nil {
            let base = descriptor.read(settings)
            stack = ParameterLayerStack(defaultValue: base, range: descriptor.range, timestamp: operation.timestamp)
        }

        stack?.setBaseIfNeeded(descriptor.read(settings), timestamp: operation.timestamp)

        let current = stack?.resolvedValue(at: operation.timestamp) ?? descriptor.read(settings)
        let incoming = operation.value.resolved(from: current)
        let resolved = stack?.apply(layer: layer, value: incoming, smoothingTime: operation.smoothing.smoothingTime, timestamp: operation.timestamp) ?? incoming
        descriptor.write(settings, min(descriptor.range.upperBound, max(descriptor.range.lowerBound, resolved)))
        if let stack { coreStacks[operation.targetID] = stack }

        if debugTraceEnabled {
            print("🧮 ParamOp frame=\(operation.frameIndex) target=\(operation.targetID) src=\(operation.source.rawValue) value=\(resolved)")
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
}
