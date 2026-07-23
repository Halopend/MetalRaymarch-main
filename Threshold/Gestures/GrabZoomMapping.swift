//
//  GrabZoomMapping.swift
//  Threshold
//
//  Pre-computed inverse mapping from hand gesture space to fractal world transform.
//  Extracted for GestureProcessor as part of Phase 6 decomposition.
//

import Foundation
import simd

/// Pre-computed inverse mapping from hand gesture space → fractal world transform.
///
/// Captured once when a two-point grab begins (and rebased at rotation breakaway).
/// Each frame the mapping evaluates current hand positions into the target fractal
/// transform using **true 1:1 scale tracking** with midpoint-grounded pivot:
///
/// ```
///   scaleRatio    = currentHandDistance / startHandDistance
///   newScale      = startDetailScale  × scaleRatio
///   deltaRot      = quaternion(startAxis → currentAxis)
///   newRotation   = deltaRot × startRotation
///   newPosition   = currentMidpoint + deltaRot.act(scaleRatio × (startPos − startMid))
/// ```
///
/// The position formula ensures the world-space point that was under the hand
/// midpoint at gesture start stays pinned to wherever the midpoint moves, while
/// scale and rotation expand / twist around that anchor.
struct GrabZoomMapping {
    // ── Hand-space snapshot ──────────────────────────────────────────────
    var startMidpoint: SIMD3<Float>
    var startDistance: Float           // clamped ≥ 0.01
    var startAxis: SIMD3<Float>       // normalized right→left

    // ── Fractal-space snapshot ───────────────────────────────────────────
    var startPosition: SIMD3<Float>
    var startRotation: simd_quatf
    var startDetailScale: Float

    // ── Factory ──────────────────────────────────────────────────────────
    init(leftPos: SIMD3<Float>, rightPos: SIMD3<Float>,
         position: SIMD3<Float>, rotation: simd_quatf, detailScale: Float) {
        self.startMidpoint = (leftPos + rightPos) * 0.5
        self.startDistance = max(simd_length(leftPos - rightPos), 0.01)
        let axis = rightPos - leftPos
        let axisLen = simd_length(axis)
        self.startAxis = axisLen > 1e-4 ? axis / axisLen : SIMD3<Float>(1, 0, 0)
        self.startPosition = position
        self.startRotation = rotation
        self.startDetailScale = detailScale
    }

    /// Rebase to the current state — called at rotation breakaway so the
    /// mapping continues smoothly from the current transform without a jump.
    mutating func rebase(leftPos: SIMD3<Float>, rightPos: SIMD3<Float>,
                         position: SIMD3<Float>, rotation: simd_quatf, detailScale: Float) {
        self = GrabZoomMapping(leftPos: leftPos, rightPos: rightPos,
                               position: position, rotation: rotation, detailScale: detailScale)
    }

    // ── Evaluation ───────────────────────────────────────────────────────

    /// Full evaluation: 1:1 scale + rotation + pivot-correct position.
    func evaluate(leftPos: SIMD3<Float>, rightPos: SIMD3<Float>,
                  scaleClamp: ClosedRange<Float> = 0.001...500.0
    ) -> (position: SIMD3<Float>, rotation: simd_quatf, detailScale: Float) {
        let currentAxis = rightPos - leftPos
        let currentAxisLen = simd_length(currentAxis)
        let currentAxisNorm = currentAxisLen > 1e-4 ? currentAxis / currentAxisLen : startAxis
        let deltaRotation = Self.quaternionBetweenAxes(from: startAxis, to: currentAxisNorm)
        return evaluateCore(leftPos: leftPos, rightPos: rightPos, scaleClamp: scaleClamp,
                            rotation: (deltaRotation * startRotation).normalized,
                            rotateOffset: { deltaRotation.act($0) })
    }

    /// Scale-only evaluation: rotation stays at startRotation (pre-breakaway phase).
    func evaluateScaleOnly(leftPos: SIMD3<Float>, rightPos: SIMD3<Float>,
                           scaleClamp: ClosedRange<Float> = 0.001...500.0
    ) -> (position: SIMD3<Float>, rotation: simd_quatf, detailScale: Float) {
        evaluateCore(leftPos: leftPos, rightPos: rightPos, scaleClamp: scaleClamp,
                     rotation: startRotation, rotateOffset: { $0 })
    }

    /// Shared scale + pivot-position logic.
    private func evaluateCore(
        leftPos: SIMD3<Float>, rightPos: SIMD3<Float>,
        scaleClamp: ClosedRange<Float>,
        rotation: simd_quatf,
        rotateOffset: (SIMD3<Float>) -> SIMD3<Float>
    ) -> (position: SIMD3<Float>, rotation: simd_quatf, detailScale: Float) {
        let currentMidpoint = (leftPos + rightPos) * 0.5
        let scaleRatio = simd_length(leftPos - rightPos) / startDistance
        let newDetailScale = simd_clamp(startDetailScale * scaleRatio,
                                        scaleClamp.lowerBound, scaleClamp.upperBound)
        let effectiveScaleRatio = newDetailScale / max(startDetailScale, 1e-6)
        let scaledOffset = effectiveScaleRatio * (startPosition - startMidpoint)
        return (currentMidpoint + rotateOffset(scaledOffset), rotation, newDetailScale)
    }

    // ── Helpers ──────────────────────────────────────────────────────────

    /// Shortest-arc quaternion rotating unit vector `from` to unit vector `to`.
    static func quaternionBetweenAxes(from a: SIMD3<Float>, to b: SIMD3<Float>) -> simd_quatf {
        let dot = simd_clamp(simd_dot(a, b), -1.0, 1.0)
        let cross = simd_cross(a, b)
        let crossLen = simd_length(cross)

        if crossLen > 1e-6 {
            return simd_quatf(angle: acos(dot), axis: cross / crossLen)
        } else if dot < 0 {
            // Anti-parallel: rotate π around any perpendicular axis
            let perp: SIMD3<Float> = abs(a.x) < 0.9
                ? simd_normalize(simd_cross(a, SIMD3<Float>(1, 0, 0)))
                : simd_normalize(simd_cross(a, SIMD3<Float>(0, 1, 0)))
            return simd_quatf(angle: .pi, axis: perp)
        } else {
            return simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)  // identity
        }
    }
}
