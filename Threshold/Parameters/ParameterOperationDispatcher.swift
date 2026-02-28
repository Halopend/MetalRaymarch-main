import Foundation

enum ParameterArbitrationPolicy: String, CaseIterable, Codable, Sendable {
    case lastWriterWins
    case gesturePriorityWhileActive
    case weightedBlend
}

enum ParameterArbitrationSource: String, CaseIterable, Codable, Sendable {
    case ui
    case gesture
    case animation
    case audio
    case system
}

struct ParameterOperationMetricsSnapshot: Sendable {
    let operationsProcessedThisFrame: Int
    let maxOperationsPerFrame: Int
    let frameBudgetBreaches: Int
    let currentFrameIndex: UInt64
}

final class ParameterArbitrationDispatcher: @unchecked Sendable {
    static let shared = ParameterArbitrationDispatcher()

    private struct SourceState {
        var lastWriter: ParameterArbitrationSource = .system
        var lastWriteTime: CFTimeInterval = 0
        var gestureActiveUntil: CFTimeInterval = 0
        var weightedInputs: [ParameterArbitrationSource: Float] = [:]
    }

    private var policy: ParameterArbitrationPolicy = .gesturePriorityWhileActive
    private var sourceStateByParameterID: [String: SourceState] = [:]

    private var currentFrameIndex: UInt64 = 0
    private var operationsProcessedThisFrame: Int = 0
    private var maxOperationsPerFrame: Int = 0
    private var frameBudgetBreaches: Int = 0

    private let maxOperationBudgetPerFrame = 128
    private let gestureHoldWindowMs: CFTimeInterval = 180
    private let lock = NSLock()

    private init() {}

    func beginFrame() {
        lock.lock()
        defer { lock.unlock() }

        currentFrameIndex &+= 1
        maxOperationsPerFrame = max(maxOperationsPerFrame, operationsProcessedThisFrame)
        operationsProcessedThisFrame = 0
    }

    func setArbitrationPolicy(_ newPolicy: ParameterArbitrationPolicy) {
        lock.lock()
        policy = newPolicy
        lock.unlock()
    }

    func arbitrationPolicy() -> ParameterArbitrationPolicy {
        lock.lock()
        defer { lock.unlock() }
        return policy
    }

    func applyFloat(parameterID: String,
                    incomingValue: Float,
                    source: ParameterArbitrationSource,
                    currentValue: @autoclosure () -> Float,
                    apply: (Float) -> Void) {
        let resolved = resolveValue(parameterID: parameterID,
                                    incomingValue: incomingValue,
                                    source: source,
                                    currentValue: currentValue())
        apply(resolved)
    }

    func metricsSnapshot() -> ParameterOperationMetricsSnapshot {
        lock.lock()
        defer { lock.unlock() }

        return ParameterOperationMetricsSnapshot(
            operationsProcessedThisFrame: operationsProcessedThisFrame,
            maxOperationsPerFrame: maxOperationsPerFrame,
            frameBudgetBreaches: frameBudgetBreaches,
            currentFrameIndex: currentFrameIndex
        )
    }

    private func resolveValue(parameterID: String,
                              incomingValue: Float,
                              source: ParameterArbitrationSource,
                              currentValue: Float) -> Float {
        lock.lock()
        defer { lock.unlock() }

        operationsProcessedThisFrame += 1
        if operationsProcessedThisFrame > maxOperationBudgetPerFrame {
            frameBudgetBreaches += 1
            ParameterDebugLogGate.log("Per-frame operation budget breached (\(operationsProcessedThisFrame)/\(maxOperationBudgetPerFrame)).")
        }

        let now = CFAbsoluteTimeGetCurrent()
        var state = sourceStateByParameterID[parameterID] ?? SourceState()
        state.lastWriter = source
        state.lastWriteTime = now

        if source == .gesture {
            state.gestureActiveUntil = now + (gestureHoldWindowMs / 1_000)
        }

        let resolved: Float
        switch policy {
        case .lastWriterWins:
            resolved = incomingValue

        case .gesturePriorityWhileActive:
            if now <= state.gestureActiveUntil, source != .gesture,
               let heldGestureValue = state.weightedInputs[.gesture] {
                resolved = heldGestureValue
            } else {
                resolved = incomingValue
            }

        case .weightedBlend:
            state.weightedInputs[source] = incomingValue
            let weights: [ParameterArbitrationSource: Float] = [
                .gesture: 0.6,
                .ui: 1.0,
                .animation: 0.75,
                .audio: 0.35,
                .system: 0.5
            ]

            var weightedTotal: Float = 0
            var totalWeight: Float = 0
            for (src, value) in state.weightedInputs {
                let weight = weights[src] ?? 0.5
                weightedTotal += value * weight
                totalWeight += weight
            }
            resolved = totalWeight > 0 ? (weightedTotal / totalWeight) : currentValue
        }

        state.weightedInputs[source] = resolved
        sourceStateByParameterID[parameterID] = state
        return resolved
    }
}
