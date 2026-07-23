import Foundation
import simd

private struct TwoPointGrabGestureState {
    var isActive = false
    var endCooldown: Float = 0
    var mapping: GrabZoomMapping?
}

struct GrabTransform: Sendable {
    let position: SIMD3<Float>
    let rotation: simd_quatf
    let detailScale: Float
}

struct TwoPointGrabGestureResult: Sendable {
    let transform: GrabTransform?
    let isActive: Bool
}

/// Stateful two-point grab recognizer and 1:1 transform mapper.
///
/// The engine owns its inverse mapping and cooldown. It emits a transform value
/// for the render worker rather than mutating RenderSettings during recognition.
final class TwoPointGrabGestureEngine {
    private var state = TwoPointGrabGestureState()

    var isActive: Bool { state.isActive }
    var endCooldown: Float { state.endCooldown }

    func reset() {
        state = TwoPointGrabGestureState()
    }

    func deactivate() {
        state.isActive = false
        state.mapping = nil
    }

    func tick(deltaTime: Float) {
        guard state.endCooldown > 0 else { return }
        state.endCooldown = max(0, state.endCooldown - deltaTime)
    }

    func process(
        digit: Int,
        context: GestureContext,
        leftHandStable: Bool,
        startPosition: SIMD3<Float>,
        startRotation: simd_quatf,
        startDetailScale: Float,
        scaleClamp: ClosedRange<Float>
    ) -> TwoPointGrabGestureResult {
        let leftPinch = context.leftHand.pinchStrength(digit: digit)
        let rightPinch = context.rightHand.pinchStrength(digit: digit)
        let leftPosition = context.leftHand.pinchPosition(digit: digit)
        let rightPosition = context.rightHand.pinchPosition(digit: digit)
        let leftPositionValid = simd_length_squared(leftPosition) > 1e-6
        let rightPositionValid = simd_length_squared(rightPosition) > 1e-6
        let currentDistance = simd_length(leftPosition - rightPosition)
        let maximumStartDistance = GestureDefaults.gestureMaxStartHandDistance
        let maximumActiveDistance = max(
            GestureDefaults.gestureMaxActiveHandDistance,
            maximumStartDistance
        )

        let bothActive: Bool
        if state.isActive {
            bothActive = context.leftHand.isTracked
                && context.rightHand.isTracked
                && leftPositionValid
                && rightPositionValid
                && currentDistance <= maximumActiveDistance
                && leftPinch >= GestureDefaults.twoHandPinchReleaseThreshold
                && rightPinch >= GestureDefaults.twoHandPinchReleaseThreshold
        } else {
            bothActive = leftHandStable
                && context.rightHand.isTracked
                && leftPositionValid
                && rightPositionValid
                && currentDistance <= maximumStartDistance
                && leftPinch >= GestureDefaults.twoHandPinchActivateThreshold
                && rightPinch >= GestureDefaults.twoHandPinchActivateThreshold
        }

        if bothActive && !state.isActive {
            state.isActive = true
            state.mapping = GrabZoomMapping(
                leftPos: leftPosition,
                rightPos: rightPosition,
                position: startPosition,
                rotation: startRotation,
                detailScale: startDetailScale
            )
        }

        var transform: GrabTransform?
        if bothActive, state.isActive, let mapping = state.mapping {
            let result = mapping.evaluate(
                leftPos: leftPosition,
                rightPos: rightPosition,
                scaleClamp: scaleClamp
            )
            transform = GrabTransform(
                position: result.position,
                rotation: result.rotation,
                detailScale: result.detailScale
            )
        }

        if !bothActive && state.isActive {
            state.isActive = false
            state.mapping = nil
            state.endCooldown = 0.15
        }

        return TwoPointGrabGestureResult(
            transform: transform,
            isActive: state.isActive
        )
    }
}
