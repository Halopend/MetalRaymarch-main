//
//  HandTrackingTypes.swift
//  Threshold
//
//  Lightweight hand tracking data consumed by GestureProcessor.
//  Part of the gesture engine decomposition (Phase 6).
//

import Foundation
import simd
#if os(visionOS)
import ARKit
#endif

// MARK: - Hand Tracking Data

/// Lightweight hand tracking data extracted from ARKit
struct HandData: Sendable {
    var isTracked: Bool = false
    var thumbTip: SIMD3<Float> = .zero
    var indexTip: SIMD3<Float> = .zero
    var middleTip: SIMD3<Float> = .zero
    var ringTip: SIMD3<Float> = .zero
    var pinkyTip: SIMD3<Float> = .zero
    var palmPosition: SIMD3<Float> = .zero
    var palmCenter: SIMD3<Float> = .zero  // Center of palm for gesture detection
    var wristPosition: SIMD3<Float> = .zero  // Wrist joint position
    var palmNormal: SIMD3<Float> = .zero  // Normal vector pointing outward from palm face

    // Forearm segment (world space) for the arm-slider music gesture: the
    // opposite hand's fingertip slides along elbow→wrist to set a value.
    var forearmWrist: SIMD3<Float> = .zero  // distal end (hand side)
    var forearmElbow: SIMD3<Float> = .zero  // proximal end (elbow side)
    var forearmTracked: Bool = false
    
    // Pinch values (0-1, 1 = fully pinched)
    var indexPinch: Float = 0
    var middlePinch: Float = 0
    var ringPinch: Float = 0
    
    /// Get pinch position (midpoint between thumb and finger)
    func pinchPosition(digit: Int) -> SIMD3<Float> {
        let fingerTip: SIMD3<Float>
        switch digit {
        case 1: fingerTip = indexTip
        case 2: fingerTip = middleTip
        case 3: fingerTip = ringTip
        default: fingerTip = indexTip
        }
        return (thumbTip + fingerTip) * 0.5
    }
    
    func pinchStrength(digit: Int) -> Float {
        switch digit {
        case 1: return indexPinch
        case 2: return middlePinch
        case 3: return ringPinch
        default: return indexPinch
        }
    }
    
    /// Calculate fist strength (0-1, 1 = fully closed fist)
    /// Based on how close all fingertips are to the palm center
    func fistStrength() -> Float {
        guard simd_length_squared(palmCenter) > 1e-6 else { return 0 }
        
        // Measure distance from each fingertip to palm center
        let indexDist = simd_length(indexTip - palmCenter)
        let middleDist = simd_length(middleTip - palmCenter)
        let ringDist = simd_length(ringTip - palmCenter)
        let pinkyDist = simd_length(pinkyTip - palmCenter)
        
        // Fist threshold distances (in meters)
        let closedDist: Float = 0.03  // 3cm = fully closed
        let openDist: Float = 0.12    // 12cm = fully open
        
        // Calculate strength for each finger
        func fingerStrength(_ dist: Float) -> Float {
            let normalized = 1.0 - ((dist - closedDist) / (openDist - closedDist))
            return simd_clamp(normalized, 0, 1)
        }
        
        // Exclude thumb — it wraps outside the other fingers in a fist,
        // placing thumbTip farther from palmCenter. VisionOS hand tracking also
        // loses precision on the thumb when other fingers are occluded.
        let strengths = [
            fingerStrength(indexDist),
            fingerStrength(middleDist),
            fingerStrength(ringDist),
            fingerStrength(pinkyDist)
        ]
        
        // Return minimum strength (all four fingers must be curled for a fist)
        return strengths.min() ?? 0
    }
    
    // MARK: - Per-Finger Palm Touch (0…1, 1 = touching)

    private func fingerTouchingPalm(tip: SIMD3<Float>, touchDist: Float, awayDist: Float) -> Float {
        guard simd_length_squared(palmCenter) > 1e-6,
              simd_length_squared(tip) > 1e-6 else { return 0 }
        let distance = simd_length(tip - palmCenter)
        let normalized = 1.0 - ((distance - touchDist) / (awayDist - touchDist))
        return simd_clamp(normalized, 0, 1)
    }

    /// Thumb touching palm (thumb tip to palm center).
    func thumbTouchingPalm() -> Float {
        // Thumb is shorter and curls inward; tighter thresholds.
        fingerTouchingPalm(tip: thumbTip, touchDist: 0.035, awayDist: 0.10)
    }

    /// Index finger touching palm.
    func indexFingerTouchingPalm() -> Float {
        fingerTouchingPalm(tip: indexTip, touchDist: 0.038, awayDist: 0.115)
    }

    /// Check if middle finger is touching palm (for menu toggle)
    func middleFingerTouchingPalm() -> Float {
        fingerTouchingPalm(tip: middleTip, touchDist: 0.038, awayDist: 0.115)
    }

    /// Check if ring finger is touching palm (secondary menu-toggle gesture option)
    func ringFingerTouchingPalm() -> Float {
        // Ring finger sits slightly farther from palm center than middle finger.
        fingerTouchingPalm(tip: ringTip, touchDist: 0.045, awayDist: 0.11)
    }

    func ringFingerTouchingWrist() -> Float {
        guard simd_length_squared(wristPosition) > 1e-6,
              simd_length_squared(ringTip) > 1e-6 else { return 0 }

        let distance = simd_length(ringTip - wristPosition)
        let touchDist: Float = 0.04
        let awayDist: Float = 0.11
        let normalized = 1.0 - ((distance - touchDist) / (awayDist - touchDist))
        return simd_clamp(normalized, 0, 1)
    }

    /// Pinky finger touching palm.
    func pinkyFingerTouchingPalm() -> Float {
        // Pinky is shortest and closest to palm edge; slightly tighter thresholds.
        fingerTouchingPalm(tip: pinkyTip, touchDist: 0.032, awayDist: 0.10)
    }

    /// Check if the opposite hand's fingertips are near this hand's wrist (wrist tap detection).
    /// Returns 0-1 strength based on proximity of the other hand's index fingertip to this hand's wrist.
    func wristTapStrength(otherHand: HandData) -> Float {
        guard isTracked, otherHand.isTracked,
              simd_length_squared(wristPosition) > 1e-6,
              simd_length_squared(otherHand.indexTip) > 1e-6 else { return 0 }

        let distance = simd_length(otherHand.indexTip - wristPosition)

        // Wrist tap thresholds (in meters)
        let touchDist: Float = 0.04   // 4cm = tapping
        let awayDist: Float = 0.12    // 12cm = clearly away

        let normalized = 1.0 - ((distance - touchDist) / (awayDist - touchDist))
        return simd_clamp(normalized, 0, 1)
    }

    /// Check if thumb and index finger are pinched with palm facing upward.
    /// Returns 0-1 strength combining thumb-index proximity and palm-up orientation.
    func thumbToIndexPalmUpStrength() -> Float {
        guard isTracked,
              simd_length_squared(thumbTip) > 1e-6,
              simd_length_squared(indexTip) > 1e-6,
              simd_length_squared(palmNormal) > 1e-6 else { return 0 }

        // Thumb-to-index pinch distance
        let pinchDist = simd_length(thumbTip - indexTip)
        let touchDist: Float = 0.025  // 2.5cm = pinched
        let awayDist: Float = 0.07    // 7cm = apart
        let pinchStrength = simd_clamp(1.0 - ((pinchDist - touchDist) / (awayDist - touchDist)), 0, 1)

        // Palm-up check: palm normal should point upward (positive Y in world space)
        // palmNormal.y > 0 means palm faces up; we want a smooth falloff
        let upwardness = simd_clamp(palmNormal.y, 0, 1)  // 0 = sideways/down, 1 = fully up
        let palmUpThreshold: Float = 0.3  // Require at least ~17° above horizontal
        let palmUpStrength = simd_clamp((upwardness - palmUpThreshold) / (1.0 - palmUpThreshold), 0, 1)

        // Both conditions must be met — use min instead of multiply so a
        // good pinch with reasonable palm orientation still produces usable strength
        return min(pinchStrength, palmUpStrength)
    }
    
    static var zero: HandData { HandData() }
}

struct HandPoseSnapshot: Sendable {
    let leftHand: HandData
    let rightHand: HandData
    let timestamp: TimeInterval
    let deltaTime: Float
}

#if os(visionOS)
@available(visionOS 2.0, *)
extension HandPoseSnapshot {
    /// Extract every joint required by attraction and gesture engines exactly
    /// once on the Renderer actor. No ARKit anchor crosses the processing seam.
    static func extract(
        leftAnchor: HandAnchor?,
        rightAnchor: HandAnchor?,
        timestamp: TimeInterval,
        deltaTime: Float
    ) -> HandPoseSnapshot {
        HandPoseSnapshot(
            leftHand: handData(from: leftAnchor),
            rightHand: handData(from: rightAnchor),
            timestamp: timestamp,
            deltaTime: deltaTime
        )
    }

    private static func handData(from anchor: HandAnchor?) -> HandData {
        guard let anchor, anchor.isTracked, let skeleton = anchor.handSkeleton else { return .zero }
        let origin = anchor.originFromAnchorTransform

        func position(_ name: HandSkeleton.JointName) -> SIMD3<Float> {
            let joint = skeleton.joint(name)
            guard joint.isTracked else { return .zero }
            let world = origin * joint.anchorFromJointTransform
            return SIMD3<Float>(world.columns.3.x, world.columns.3.y, world.columns.3.z)
        }

        var hand = HandData()
        hand.isTracked = true
        hand.thumbTip = position(.thumbTip)
        hand.indexTip = position(.indexFingerTip)
        hand.middleTip = position(.middleFingerTip)
        hand.ringTip = position(.ringFingerTip)
        hand.pinkyTip = position(.littleFingerTip)
        hand.palmPosition = position(.middleFingerMetacarpal)
        hand.wristPosition = position(.wrist)
        hand.forearmWrist = position(.forearmWrist)
        hand.forearmElbow = position(.forearmArm)
        hand.forearmTracked = simd_length_squared(hand.forearmWrist) > 1e-6
            && simd_length_squared(hand.forearmElbow) > 1e-6

        let indexMeta = position(.indexFingerMetacarpal)
        let middleMeta = position(.middleFingerMetacarpal)
        let ringMeta = position(.ringFingerMetacarpal)
        let pinkyMeta = position(.littleFingerMetacarpal)
        // Average only the joints ARKit actually tracked. An untracked joint
        // reads .zero here; averaging it in drags palmCenter toward the world
        // origin while still passing nonzero guards — the spatial menu then
        // plants at that displaced point.
        let trackedMetacarpals = [indexMeta, middleMeta, ringMeta, pinkyMeta]
            .filter { simd_length_squared($0) > 1e-9 }
        hand.palmCenter = trackedMetacarpals.isEmpty
            ? .zero
            : trackedMetacarpals.reduce(SIMD3<Float>.zero, +) / Float(trackedMetacarpals.count)

        let normalInputsTracked = simd_length_squared(indexMeta) > 1e-9
            && simd_length_squared(middleMeta) > 1e-9
            && simd_length_squared(pinkyMeta) > 1e-9
            && simd_length_squared(hand.wristPosition) > 1e-9
        let rawNormal = normalInputsTracked
            ? simd_cross(pinkyMeta - indexMeta, middleMeta - hand.wristPosition)
            : .zero
        let normalLength = simd_length(rawNormal)
        hand.palmNormal = normalLength > 1e-6 ? rawNormal / normalLength : .zero

        func pinch(_ finger: SIMD3<Float>, maximumDistance: Float) -> Float {
            guard simd_length_squared(hand.thumbTip) > 1e-6,
                  simd_length_squared(finger) > 1e-6 else { return 0 }
            let normalized = 1 - (simd_length(hand.thumbTip - finger) - 0.02)
                / (maximumDistance - 0.02)
            return simd_clamp(normalized, 0, 1)
        }
        hand.indexPinch = pinch(hand.indexTip, maximumDistance: 0.05)
        hand.middlePinch = pinch(hand.middleTip, maximumDistance: 0.05)
        hand.ringPinch = pinch(hand.ringTip, maximumDistance: 0.04)
        return hand
    }
}
#endif

// MARK: - Two-Hand Gesture State

/// State for a two-hand scale gesture
struct TwoHandGestureState {
    var isActive: Bool = false
    var startDistance: Float = 0      // Distance between hands when gesture started
    var startParameterValue: Float = 0  // Parameter value when gesture started
    var startHeight: Float = 0          // Average Y position of hands when gesture started (for sensitivity scaling)
}
