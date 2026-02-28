import Foundation
import simd

enum ParameterOperationSource: String, Codable, Sendable {
    case gesture
    case slider
    case windowSlider
    case animation
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

@MainActor
final class ParameterOperationDispatcher {
    struct SourcePolicy: Sendable {
        let priority: [ParameterOperationSource: Int]

        static let `default` = SourcePolicy(priority: [
            .gesture: 10,
            .windowSlider: 20,
            .slider: 25,
            .animation: 30,
            .preset: 40,
            .system: 50
        ])

        func rank(for source: ParameterOperationSource) -> Int {
            priority[source] ?? 0
        }
    }

    private let sourcePolicy: SourcePolicy
    var debugTraceEnabled = false

    init(sourcePolicy: SourcePolicy = .default) {
        self.sourcePolicy = sourcePolicy
    }

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

    private func apply(_ operation: ParameterOperation, cache: UISettingsCache) {
        let formulaBatch = ParameterNodeRegistry.shared.formulaBatch(for: cache.fractalType)
        if let node = formulaBatch.floatNodes.first(where: { $0.id == operation.targetID }) {
            let current = node.readValue(cache)
            let newValue = operation.value.resolved(from: current)
            node.writeValue(cache, newValue)
            if debugTraceEnabled {
                print("🧮 ParamOp frame=\(operation.frameIndex) target=\(operation.targetID) src=\(operation.source.rawValue) value=\(newValue)")
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

        applyCore(operation, settings: cache.renderSettings)
    }

    private func apply(_ operation: ParameterOperation, settings: RenderSettings) {
        let pieces = operation.targetID.split(separator: ".")
        if pieces.count >= 4,
           pieces[0] == "formula",
           let formulaIndex = Int(pieces[2]) {
            var params = settings.formulaParams
            let current = FormulaCatalog.getParam(params, index: formulaIndex)
            let newValue = operation.value.resolved(from: current)
            FormulaCatalog.setParam(&params, index: formulaIndex, value: newValue)
            settings.formulaParams = params
            if debugTraceEnabled {
                print("🧮 ParamOp frame=\(operation.frameIndex) target=\(operation.targetID) src=\(operation.source.rawValue) value=\(newValue)")
            }
            return
        }

        applyCore(operation, settings: settings)
    }

    private func applyCore(_ operation: ParameterOperation, settings: RenderSettings?) {
        guard let settings else { return }

        func assign(_ current: Float, _ set: (Float) -> Void) {
            let newValue = operation.value.resolved(from: current)
            set(newValue)
            if debugTraceEnabled {
                print("🧮 ParamOp frame=\(operation.frameIndex) target=\(operation.targetID) src=\(operation.source.rawValue) value=\(newValue)")
            }
        }

        switch operation.targetID {
        case "core.targetMinDistance":
            assign(settings.targetMinDistance) { settings.targetMinDistance = $0 }
        case "core.targetFoldingLimit":
            assign(settings.targetFoldingLimit) { settings.targetFoldingLimit = $0 }
        case "core.targetSphereRadius":
            assign(settings.targetSphereRadius) { settings.targetSphereRadius = $0 }
        case "core.fractalScale":
            assign(settings.fractalScale) { settings.fractalScale = $0 }
        default:
            break
        }
    }
}
