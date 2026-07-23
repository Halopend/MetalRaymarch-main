import Foundation
import simd

private struct ArmSliderHandState {
    var engaged = false
    var value: Float = 0
    var hasValue = false
}

private struct ArmSliderGestureState {
    var left = ArmSliderHandState()
    var right = ArmSliderHandState()
}

/// Absolute-position forearm controls for music intensity and damping.
///
/// The engine owns engagement, hysteresis, and smoothing state. It emits only
/// typed mutations; it never reaches into AppModel or RenderSettings.
final class ArmSliderGestureEngine {
    private var state = ArmSliderGestureState()

    func reset() {
        state = ArmSliderGestureState()
    }

    func process(
        context: GestureContext,
        parametersSuppressed: Bool,
        grabActive: Bool,
        geometryGestureActive: Bool,
        renderMutations: inout [GestureRenderMutation]
    ) -> Bool {
        guard !parametersSuppressed, !grabActive, !geometryGestureActive else {
            let shouldPersist = state.left.engaged || state.right.engaged
            reset()
            if shouldPersist { renderMutations.append(.persistAudioReactive) }
            return shouldPersist
        }

        var didCompleteGesture = false

        let leftWasEngaged = state.left.engaged
        if update(
            &state.left,
            elbow: context.leftHand.forearmElbow,
            wrist: context.leftHand.forearmWrist,
            pointer: context.rightHand.indexTip,
            tracked: context.leftHand.forearmTracked && context.rightHand.isTracked
        ) {
            renderMutations.append(.setFractalAudioAmount(state.left.value))
        } else if leftWasEngaged {
            renderMutations.append(.persistAudioReactive)
            state.left.hasValue = false
            didCompleteGesture = true
        }

        let rightWasEngaged = state.right.engaged
        if update(
            &state.right,
            elbow: context.rightHand.forearmElbow,
            wrist: context.rightHand.forearmWrist,
            pointer: context.leftHand.indexTip,
            tracked: context.rightHand.forearmTracked && context.leftHand.isTracked
        ) {
            renderMutations.append(
                .setFractalAudioDamping(state.right.value * GestureDefaults.armSliderDampingMax)
            )
        } else if rightWasEngaged {
            renderMutations.append(.persistAudioReactive)
            state.right.hasValue = false
            didCompleteGesture = true
        }

        return didCompleteGesture
    }

    private func update(
        _ state: inout ArmSliderHandState,
        elbow: SIMD3<Float>,
        wrist: SIMD3<Float>,
        pointer: SIMD3<Float>,
        tracked: Bool
    ) -> Bool {
        guard tracked,
              simd_length_squared(pointer) > 1e-6,
              simd_length_squared(elbow) > 1e-6,
              simd_length_squared(wrist) > 1e-6 else {
            state.engaged = false
            return false
        }

        let axis = wrist - elbow
        let length = simd_length(axis)
        guard length >= GestureDefaults.armSliderMinForearmLength else {
            state.engaged = false
            return false
        }

        let direction = axis / length
        let relativePointer = pointer - elbow
        let distanceAlongArm = simd_dot(relativePointer, direction)
        let normalizedPosition = distanceAlongArm / length
        let perpendicularDistance = simd_length(
            relativePointer - distanceAlongArm * direction
        )

        if state.engaged {
            state.engaged = perpendicularDistance <= GestureDefaults.armSliderReleaseRadius
                && normalizedPosition >= -0.20
                && normalizedPosition <= 1.20
        } else {
            state.engaged = perpendicularDistance <= GestureDefaults.armSliderEngageRadius
                && normalizedPosition >= -0.10
                && normalizedPosition <= 1.10
        }
        guard state.engaged else { return false }

        let target = simd_clamp(normalizedPosition, 0, 1)
        if state.hasValue {
            let alpha = simd_clamp(GestureDefaults.armSliderSmoothing, 0, 1)
            state.value += (target - state.value) * alpha
        } else {
            state.value = target
            state.hasValue = true
        }
        return true
    }
}
