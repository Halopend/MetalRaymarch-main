import Foundation
import simd

struct TwoHandScalarGestureResult: Sendable {
    let value: Float?
    let isActive: Bool
    let hitLimit: Bool
}

/// Stateful two-hand pull-apart recognizer for scalar parameters.
///
/// It owns per-finger activation and relative-mapping state. The coordinator
/// supplies the semantic target/range and turns the returned value into a
/// ParameterOperation.
final class TwoHandScalarGestureEngine {
    // Indexes 1...3 map directly to index/middle/ring. Index 0 is unused so the
    // hot path avoids dictionaries and hashing.
    private var states = Array(repeating: TwoHandGestureState(), count: 4)

    func reset() {
        for index in states.indices {
            states[index] = TwoHandGestureState()
        }
    }

    func deactivate(digit: Int) {
        guard states.indices.contains(digit) else { return }
        states[digit].isActive = false
    }

    func isActive(digit: Int) -> Bool {
        states.indices.contains(digit) && states[digit].isActive
    }

    var hasActiveGesture: Bool {
        states[1...3].contains(where: \.isActive)
    }

    func process(
        digit: Int,
        context: GestureContext,
        leftHandStable: Bool,
        currentTarget: Float,
        range: ClosedRange<Float>,
        parameterID: String?,
        useRelativeGestures: Bool,
        detailScale: Float
    ) -> TwoHandScalarGestureResult {
        guard states.indices.contains(digit) else {
            return TwoHandScalarGestureResult(value: nil, isActive: false, hitLimit: false)
        }

        var state = states[digit]
        let leftPinch = context.leftHand.pinchStrength(digit: digit)
        let rightPinch = context.rightHand.pinchStrength(digit: digit)
        let activateThreshold = digit == 3
            ? GestureDefaults.ringPinchActivateThreshold
            : GestureDefaults.twoHandPinchActivateThreshold
        let releaseThreshold = digit == 3
            ? GestureDefaults.ringPinchReleaseThreshold
            : GestureDefaults.twoHandPinchReleaseThreshold
        let leftPosition = context.leftHand.pinchPosition(digit: digit)
        let rightPosition = context.rightHand.pinchPosition(digit: digit)
        let leftPositionValid = simd_length_squared(leftPosition) > 1e-6
        let rightPositionValid = simd_length_squared(rightPosition) > 1e-6

        let minimumDistance = GestureDefaults.gestureMinHandDistance
        let maximumDistance = max(
            minimumDistance + 0.05,
            GestureDefaults.gestureMaxHandDistance
        )
        let maximumStartDistance = GestureDefaults.gestureMaxStartHandDistance
        let maximumActiveDistance = max(
            GestureDefaults.gestureMaxActiveHandDistance,
            maximumStartDistance
        )
        let currentDistance = simd_length(leftPosition - rightPosition)

        let bothActive: Bool
        if state.isActive {
            bothActive = context.leftHand.isTracked
                && context.rightHand.isTracked
                && leftPositionValid
                && rightPositionValid
                && currentDistance <= maximumActiveDistance
                && leftPinch >= releaseThreshold
                && rightPinch >= releaseThreshold
        } else {
            bothActive = leftHandStable
                && context.rightHand.isTracked
                && leftPositionValid
                && rightPositionValid
                && currentDistance <= maximumStartDistance
                && leftPinch >= activateThreshold
                && rightPinch >= activateThreshold
        }

        if bothActive && !state.isActive {
            state.isActive = true
            state.startDistance = currentDistance
            state.startParameterValue = currentTarget
            state.startHeight = (leftPosition.y + rightPosition.y) * 0.5
        }

        var value: Float?
        var hitLimit = false
        if bothActive {
            if useRelativeGestures {
                let baseSensitivity = GestureDefaults.gestureSensitivity / 10
                let currentHeight = (leftPosition.y + rightPosition.y) * 0.5
                let heightDrop = max(0, state.startHeight - currentHeight)
                let verticalScale = pow(10, -2 * min(heightDrop, 1))
                let parameterSensitivity = parameterID.map {
                    GestureSensitivityStore.shared.sensitivity(for: $0)
                } ?? 1
                let clampedDetailScale = max(detailScale, 0.01)
                let zoomCompensation: Float = clampedDetailScale > 1.001
                    ? pow(clampedDetailScale, -0.5)
                    : 1
                let distanceSpan = max(maximumDistance - minimumDistance, 0.001)
                let sensitivity = ((range.upperBound - range.lowerBound) / distanceSpan)
                    * baseSensitivity
                    * verticalScale
                    * parameterSensitivity
                    * zoomCompensation
                let candidate = state.startParameterValue
                    + (currentDistance - state.startDistance) * sensitivity
                let clamped = simd_clamp(candidate, range.lowerBound, range.upperBound)
                value = clamped
                hitLimit = clamped <= range.lowerBound + 1e-5
                    || clamped >= range.upperBound - 1e-5
            } else {
                let normalizedDistance = simd_clamp(
                    (currentDistance - minimumDistance) / (maximumDistance - minimumDistance),
                    0,
                    1
                )
                value = range.lowerBound
                    + normalizedDistance * (range.upperBound - range.lowerBound)
                hitLimit = normalizedDistance <= 0.01 || normalizedDistance >= 0.99
            }
        }

        if !bothActive && state.isActive {
            state.isActive = false
        }
        states[digit] = state
        return TwoHandScalarGestureResult(
            value: value,
            isActive: state.isActive,
            hitLimit: hitLimit
        )
    }
}
