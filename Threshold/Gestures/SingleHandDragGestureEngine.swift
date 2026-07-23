import Foundation
import simd

private struct SingleHandDragState {
    var isActive = false
    var previousPosition: SIMD3<Float> = .zero
    var previousPalm: SIMD3<Float> = .zero
    var values: SIMD3<Float> = .zero
    var value: Float = 0
}

struct SingleHandDragFrameResult: Sendable {
    let activeDigit: Int
    let hasActiveGesture: Bool
    let didUseGesture: Bool
}

/// Stateful single-hand drag recognizer for translation, scalar, and triplet
/// bindings. GestureSlot is the state key, avoiding persistence-key String
/// construction and hashing in the per-frame path.
final class SingleHandDragGestureEngine {
    private var states: [GestureSlot: SingleHandDragState] = [:]

    func reset() {
        states.removeAll(keepingCapacity: true)
    }

    func deactivateAll() {
        for slot in states.keys {
            states[slot]?.isActive = false
        }
    }

    func process(
        context: GestureContext,
        settings: RenderSettings,
        parameterPipeline: ParameterPipeline,
        frameIndex: UInt64,
        twoHandActiveMask: UInt8,
        grabActive: Bool,
        grabEndCooldown: Float,
        parameterOperations: inout [ParameterOperation],
        renderMutations: inout [GestureRenderMutation]
    ) -> SingleHandDragFrameResult {
        var activeDigit = 0
        var didUseGesture = false

        for (handMode, handData) in [
            (GestureHandMode.left, context.leftHand),
            (.right, context.rightHand),
        ] {
            let lockedFinger = (1...3).first { digit in
                guard let finger = FingerDigit(rawValue: digit) else { return false }
                return GestureDirection.allCases.contains { direction in
                    let slot = GestureSlot(
                        hand: handMode,
                        finger: finger,
                        direction: direction
                    )
                    return states[slot]?.isActive == true
                }
            }

            for digit in 1...3 {
                guard let finger = FingerDigit(rawValue: digit) else { continue }
                for direction in GestureDirection.allCases {
                    let slot = GestureSlot(
                        hand: handMode,
                        finger: finger,
                        direction: direction
                    )
                    let binding = settings.binding(for: slot)
                    if process(
                        slot: slot,
                        hand: handData,
                        binding: binding,
                        lockedFinger: lockedFinger,
                        context: context,
                        settings: settings,
                        parameterPipeline: parameterPipeline,
                        frameIndex: frameIndex,
                        twoHandActiveMask: twoHandActiveMask,
                        grabActive: grabActive,
                        grabEndCooldown: grabEndCooldown,
                        parameterOperations: &parameterOperations,
                        renderMutations: &renderMutations
                    ) {
                        activeDigit = digit
                        didUseGesture = true
                    }
                }
            }
        }

        if activeDigit == 0 {
            for digit in 1...3 where states.contains(where: {
                $0.key.finger.rawValue == digit && $0.value.isActive
            }) {
                activeDigit = digit
            }
        }
        return SingleHandDragFrameResult(
            activeDigit: activeDigit,
            hasActiveGesture: states.values.contains(where: \.isActive),
            didUseGesture: didUseGesture
        )
    }

    private func process(
        slot: GestureSlot,
        hand: HandData,
        binding: GestureActionBinding,
        lockedFinger: Int?,
        context: GestureContext,
        settings: RenderSettings,
        parameterPipeline: ParameterPipeline,
        frameIndex: UInt64,
        twoHandActiveMask: UInt8,
        grabActive: Bool,
        grabEndCooldown: Float,
        parameterOperations: inout [ParameterOperation],
        renderMutations: inout [GestureRenderMutation]
    ) -> Bool {
        let digit = slot.finger.rawValue

        if case .core(.none) = binding {
            states[slot]?.isActive = false
            return false
        }
        if twoHandActiveMask & (1 << UInt8(digit)) != 0 {
            states[slot]?.isActive = false
            return false
        }
        if grabEndCooldown > 0 || grabActive {
            states[slot]?.isActive = false
            return false
        }

        let otherHand = slot.hand == .right ? context.leftHand : context.rightHand
        var otherAttemptingPinch = false
        if otherHand.isTracked {
            let otherHandMode: GestureHandMode = slot.hand == .right ? .left : .right
            for otherDigit in 1...3 {
                let bothBinding = settings.binding(forHand: .both, digit: otherDigit)
                if case .core(.none) = bothBinding { continue }
                if let otherFinger = FingerDigit(rawValue: otherDigit) {
                    let otherDragActive = GestureDirection.allCases.contains { direction in
                        let otherSlot = GestureSlot(
                            hand: otherHandMode,
                            finger: otherFinger,
                            direction: direction
                        )
                        return states[otherSlot]?.isActive == true
                    }
                    if otherDragActive { continue }
                }
                let threshold: Float = otherDigit == 3 ? 0.45 : 0.55
                if otherHand.pinchStrength(digit: otherDigit) >= threshold {
                    otherAttemptingPinch = true
                    break
                }
            }
        }

        let pinch = hand.pinchStrength(digit: digit)
        var state = states[slot] ?? SingleHandDragState()
        let isLockedOut = lockedFinger != nil && lockedFinger != digit
        let active: Bool
        if state.isActive {
            active = hand.isTracked
                && pinch >= GestureDefaults.twoHandPinchReleaseThreshold
        } else if isLockedOut {
            active = false
        } else {
            var strongestOtherPinch: Float = 0
            for otherDigit in 1...3 where otherDigit != digit {
                strongestOtherPinch = max(
                    strongestOtherPinch,
                    hand.pinchStrength(digit: otherDigit)
                )
            }
            active = hand.isTracked
                && pinch >= GestureDefaults.twoHandPinchActivateThreshold
                && !otherAttemptingPinch
                && pinch - strongestOtherPinch >= 0.15
        }

        var usedGesture = false
        switch binding {
        case .core(.translate):
            if active && !state.isActive {
                state.isActive = true
                state.previousPosition = hand.pinchPosition(digit: digit)
                state.previousPalm = hand.palmPosition
            }
            if active && state.isActive {
                var currentPosition = hand.palmPosition
                if simd_length_squared(currentPosition) == 0 {
                    currentPosition = hand.pinchPosition(digit: digit)
                }
                var previousPosition = state.previousPalm
                if simd_length_squared(previousPosition) == 0 {
                    previousPosition = state.previousPosition
                }

                let rawDelta = currentPosition - previousPosition
                let deltaLength = simd_length(rawDelta)
                var scaledDelta = SIMD3<Float>.zero
                if deltaLength > 0 {
                    scaledDelta = rawDelta / deltaLength * min(deltaLength * 3, 0.30)
                }
                let maximumZoomCompensation: Float =
                    settings.fractalType == .mandelbulb ? 1.5 : 2
                let zoomCompensation = simd_clamp(
                    1 / pow(max(settings.detailScale, 0.01), 0.3),
                    0.5,
                    maximumZoomCompensation
                )
                renderMutations.append(
                    .translatePosition(
                        scaledDelta
                            * GestureDefaults.translationSensitivity
                            * zoomCompensation
                    )
                )
                state.previousPosition = currentPosition
                state.previousPalm = currentPosition
                usedGesture = true
            }

        case .parameterTriplet(let triplet):
            if active && !state.isActive {
                state.isActive = true
                let parameters = settings.formulaParams
                state.values = SIMD3<Float>(
                    FormulaCatalog.getParam(parameters, index: triplet.xFormulaIndex),
                    FormulaCatalog.getParam(parameters, index: triplet.yFormulaIndex),
                    FormulaCatalog.getParam(parameters, index: triplet.zFormulaIndex)
                )
                state.previousPosition = hand.pinchPosition(digit: digit)
            }
            if active && state.isActive {
                let currentPosition = hand.pinchPosition(digit: digit)
                let rawDelta = currentPosition - state.previousPosition
                let deltaLength = simd_length(rawDelta)
                let rangeSpan = triplet.range.upperBound - triplet.range.lowerBound
                let zoomScale = max(settings.detailScale, 0.01)
                let zoomCompensation: Float = zoomScale > 1.001
                    ? pow(zoomScale, -0.5)
                    : 1

                if deltaLength > 0 {
                    let scaledDelta = rawDelta / deltaLength
                        * min(
                            deltaLength
                                * GestureDefaults.gestureSensitivity
                                * zoomCompensation,
                            0.15
                        )
                        * rangeSpan
                    state.values = simd_clamp(
                        state.values + scaledDelta,
                        SIMD3<Float>(repeating: triplet.range.lowerBound),
                        SIMD3<Float>(repeating: triplet.range.upperBound)
                    )
                    let smoothing = ParameterOperationSmoothing(
                        smoothingTime: GestureDefaults.gestureSmoothing
                    )
                    parameterOperations.append(
                        ParameterOperation(
                            targetID: triplet.xNodeID,
                            source: .gesture,
                            value: state.values.x,
                            frameIndex: frameIndex,
                            smoothing: smoothing
                        )
                    )
                    parameterOperations.append(
                        ParameterOperation(
                            targetID: triplet.yNodeID,
                            source: .gesture,
                            value: state.values.y,
                            frameIndex: frameIndex,
                            smoothing: smoothing
                        )
                    )
                    parameterOperations.append(
                        ParameterOperation(
                            targetID: triplet.zNodeID,
                            source: .gesture,
                            value: state.values.z,
                            frameIndex: frameIndex,
                            smoothing: smoothing
                        )
                    )
                    usedGesture = true
                }
                state.previousPosition = currentPosition
            }

        case .parameter(let descriptor):
            guard let node = ParameterNodeRegistry.shared.node(for: descriptor) else {
                state.isActive = false
                states[slot] = state
                return false
            }
            if active && !state.isActive {
                state.isActive = true
                if let formulaIndex = descriptor.formulaIndex {
                    state.value = FormulaCatalog.getParam(
                        settings.formulaParams,
                        index: formulaIndex
                    )
                } else {
                    state.value = parameterPipeline.currentValue(
                        for: node.id,
                        settings: settings
                    ) ?? node.range.lowerBound
                }
                state.previousPosition = hand.pinchPosition(digit: digit)
            }
            if active && state.isActive {
                let currentPosition = hand.pinchPosition(digit: digit)
                let axisDelta: Float
                switch slot.direction {
                case .horizontal:
                    axisDelta = currentPosition.x - state.previousPosition.x
                case .depth:
                    axisDelta = currentPosition.z - state.previousPosition.z
                default:
                    axisDelta = currentPosition.y - state.previousPosition.y
                }
                let rangeSpan = node.range.upperBound - node.range.lowerBound
                let zoomScale = max(settings.detailScale, 0.01)
                let zoomCompensation: Float = zoomScale > 1.001
                    ? pow(zoomScale, -0.5)
                    : 1
                let scaledDelta = simd_clamp(
                    axisDelta
                        * GestureDefaults.gestureSensitivity
                        * zoomCompensation
                        * rangeSpan,
                    -0.15 * rangeSpan,
                    0.15 * rangeSpan
                )
                state.value = simd_clamp(
                    state.value + scaledDelta,
                    node.range.lowerBound,
                    node.range.upperBound
                )
                parameterOperations.append(
                    ParameterOperation(
                        targetID: node.id,
                        source: .gesture,
                        value: state.value,
                        frameIndex: frameIndex,
                        smoothing: ParameterOperationSmoothing(
                            smoothingTime: GestureDefaults.gestureSmoothing
                        )
                    )
                )
                state.previousPosition = currentPosition
                usedGesture = true
            }

        default:
            state.isActive = false
        }

        if !active && state.isActive {
            state.isActive = false
        }
        states[slot] = state
        return usedGesture
    }
}
