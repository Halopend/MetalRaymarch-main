//
//  GestureController.swift
//  MetalRaymarch
//
//  Hand gesture controls for fractal parameters
//

import Foundation
import ARKit
import simd

// MARK: - Hand Tracking Data

/// Lightweight hand tracking data extracted from ARKit
struct HandData {
    var isTracked: Bool = false
    var thumbTip: SIMD3<Float> = .zero
    var indexTip: SIMD3<Float> = .zero
    var middleTip: SIMD3<Float> = .zero
    var ringTip: SIMD3<Float> = .zero
    var pinkyTip: SIMD3<Float> = .zero
    var palmPosition: SIMD3<Float> = .zero
    
    // Pinch values (0-1, 1 = fully pinched)
    var indexPinch: Float = 0
    var middlePinch: Float = 0
    var ringPinch: Float = 0
    var pinkyPinch: Float = 0
    
    static var zero: HandData { HandData() }
}

// MARK: - Gesture State

/// Tracks active gesture state for delta calculations
struct GestureState {
    var isActive: Bool = false
    var startDistance: Float = 0   // Finger spread distance when gesture started
    var previousDistance: Float = 0
}

// MARK: - Gesture Controller

/// Processes hand tracking data and maps gestures to render parameters
@MainActor
final class GestureController {
    
    // Pinch thresholds with hysteresis to prevent flickering
    private let pinchActivateThreshold: Float = 0.85   // Must exceed to start gesture
    private let pinchReleaseThreshold: Float = 0.70    // Must fall below to end gesture
    
    // Spread gesture sensitivity (meters of finger spread to parameter range)
    private let spreadSensitivity: Float = 0.1  // 10cm spread = full parameter range
    private let spreadSmoothing: Float = 0.35   // 0..1; smaller = slower changes

    // Value ranges (wider than before to reduce clamping)
    private let minDistanceRange: ClosedRange<Float> = 0.0...3.0
    private let foldingLimitRange: ClosedRange<Float> = 0.0...3.0

    private let pinkySensitivity: Float = 0.1   // Spread thumb–pinky to adjust sphere radius
    private let pinkySmoothing: Float = 0.35

    private let ringSensitivity: Float = 0.1    // Spread thumb–ring to adjust folding limit
    private let ringSmoothing: Float = 0.35

    private let translateSensitivity: Float = 1.2 // meters per meter of palm drag (middle pinch)
    private let translateSmoothing: Float = 0.35
    
    // Hand tracking state
    private var leftHand: HandData = .zero
    private var rightHand: HandData = .zero
    
    // Gesture states for each mapping
    private var middleFingerSpreadState = GestureState()
    private var pinkySpreadState = GestureState()
    private var ringSpreadState = GestureState()
    private var rightMiddleDragActive: Bool = false
    private var rightMiddleDragStart: SIMD3<Float> = .zero
    private var rightMiddlePrevPalm: SIMD3<Float> = .zero
    
    // Reference to render settings
    private weak var renderSettings: RenderSettings?
    
    init(renderSettings: RenderSettings) {
        self.renderSettings = renderSettings
    }
    
    // MARK: - Hand Tracking Updates
    
    /// Update hand data from ARKit hand anchors
    @available(visionOS 2.0, *)
    func updateHands(leftAnchor: HandAnchor?, rightAnchor: HandAnchor?) {
        leftHand = buildHandData(from: leftAnchor)
        rightHand = buildHandData(from: rightAnchor)
        
        // Process all gesture mappings
        processGestures()
    }
    
    @available(visionOS 2.0, *)
    private func buildHandData(from anchor: HandAnchor?) -> HandData {
        guard let anchor = anchor, anchor.isTracked else {
            return .zero
        }
        
        var data = HandData()
        data.isTracked = true
        
        let skeleton = anchor.handSkeleton
        let transform = anchor.originFromAnchorTransform
        
        // Helper to get world position of a joint
        func jointPosition(_ jointName: HandSkeleton.JointName) -> SIMD3<Float> {
            guard let joint = skeleton?.joint(jointName), joint.isTracked else {
                return .zero
            }
            let localTransform = joint.anchorFromJointTransform
            let worldTransform = transform * localTransform
            return SIMD3<Float>(worldTransform.columns.3.x, worldTransform.columns.3.y, worldTransform.columns.3.z)
        }
        
        // Extract finger positions
        data.thumbTip = jointPosition(.thumbTip)
        data.indexTip = jointPosition(.indexFingerTip)
        data.middleTip = jointPosition(.middleFingerTip)
        data.ringTip = jointPosition(.ringFingerTip)
        data.pinkyTip = jointPosition(.littleFingerTip)
        
        // Palm position (use wrist or middle metacarpal)
        data.palmPosition = jointPosition(.middleFingerMetacarpal)
        
        // Calculate pinch values based on distance between thumb and each finger
        let pinchMaxDist: Float = 0.08  // 8cm = no pinch
        let pinchMinDist: Float = 0.02  // 2cm = full pinch
        
        func calculatePinch(fingerTip: SIMD3<Float>) -> Float {
            let distance = simd_length(data.thumbTip - fingerTip)
            let normalized = 1.0 - ((distance - pinchMinDist) / (pinchMaxDist - pinchMinDist))
            return simd_clamp(normalized, 0, 1)
        }
        
        data.indexPinch = calculatePinch(fingerTip: data.indexTip)
        data.middlePinch = calculatePinch(fingerTip: data.middleTip)
        data.ringPinch = calculatePinch(fingerTip: data.ringTip)
        data.pinkyPinch = calculatePinch(fingerTip: data.pinkyTip)
        
        return data
    }
    
    // MARK: - Gesture Processing
    
    private func processGestures() {
        // Middle finger spread → minDistance
        processMiddleFingerSpread()

        // Pinky spread → sphereRadius
        processPinkySpread()

        // Ring spread → foldingLimit
        processRingSpread()

        // Right middle pinch drag → position translate
        processRightMiddleDrag()
        
        // Add more gesture mappings here...
    }
    
    /// Middle finger pinch + spread apart → controls minDistance
    /// Start: Pinch middle finger to thumb on EITHER hand
    /// Control: While holding pinch, spread thumb and middle finger apart to increase minDistance
    private func processMiddleFingerSpread() {
        guard let settings = renderSettings else { return }
        
        // Check if either hand has middle finger pinch active
        let leftActive = isPinchActive(value: leftHand.middlePinch, wasActive: middleFingerSpreadState.isActive && leftHand.isTracked)
        let rightActive = isPinchActive(value: rightHand.middlePinch, wasActive: middleFingerSpreadState.isActive && rightHand.isTracked)
        
        // Use whichever hand is active (prefer left if both)
        let activeHand: HandData?
        if leftActive && leftHand.isTracked {
            activeHand = leftHand
        } else if rightActive && rightHand.isTracked {
            activeHand = rightHand
        } else {
            activeHand = nil
        }
        
        let isActive = activeHand != nil
        
        // Gesture just started
        if isActive && !middleFingerSpreadState.isActive {
            middleFingerSpreadState.isActive = true
            if let hand = activeHand {
                middleFingerSpreadState.startDistance = simd_length(hand.thumbTip - hand.middleTip)
                middleFingerSpreadState.previousDistance = middleFingerSpreadState.startDistance
            }
            #if DEBUG
            print("🤏 Middle finger spread gesture STARTED (minDistance: \(settings.minDistance))")
            #endif
        }
        
        // Gesture active - update parameter
        if isActive, let hand = activeHand {
            let currentDistance = simd_length(hand.thumbTip - hand.middleTip)
            let deltaDistance = currentDistance - middleFingerSpreadState.previousDistance

            // Map spread movement to relative parameter change
            let parameterDelta = deltaDistance / spreadSensitivity
            // Smooth the per-frame change to avoid jittery jumps
            let smoothedStep = parameterDelta * spreadSmoothing
            let newValue = simd_clamp(
                settings.minDistance + smoothedStep,
                minDistanceRange.lowerBound,
                minDistanceRange.upperBound
            )

            settings.minDistance = newValue
            middleFingerSpreadState.previousDistance = currentDistance
            
            #if DEBUG
            // Throttled logging
            struct DebugState { static var counter = 0 }
            DebugState.counter += 1
            if DebugState.counter % 30 == 0 {
                print("🤏 minDistance: \(String(format: "%.3f", newValue)) (delta: \(String(format: "%.3f", deltaDistance * 100))cm)")
            }
            #endif
        }
        
        // Gesture ended
        if !isActive && middleFingerSpreadState.isActive {
            middleFingerSpreadState.isActive = false
            #if DEBUG
            print("🤏 Middle finger spread gesture ENDED (minDistance: \(settings.minDistance))")
            #endif
        }
    }

    /// Pinky pinch + spread → controls sphereRadius
    private func processPinkySpread() {
        guard let settings = renderSettings else { return }

        let leftActive = isPinchActive(value: leftHand.pinkyPinch, wasActive: pinkySpreadState.isActive && leftHand.isTracked)
        let rightActive = isPinchActive(value: rightHand.pinkyPinch, wasActive: pinkySpreadState.isActive && rightHand.isTracked)

        let activeHand: HandData?
        if leftActive && leftHand.isTracked {
            activeHand = leftHand
        } else if rightActive && rightHand.isTracked {
            activeHand = rightHand
        } else {
            activeHand = nil
        }

        let isActive = activeHand != nil

        if isActive && !pinkySpreadState.isActive {
            pinkySpreadState.isActive = true
            if let hand = activeHand {
                let d = simd_length(hand.thumbTip - hand.pinkyTip)
                pinkySpreadState.startDistance = d
                pinkySpreadState.previousDistance = d
            }
        }

        if isActive, let hand = activeHand {
            let currentDistance = simd_length(hand.thumbTip - hand.pinkyTip)
            let deltaDistance = currentDistance - pinkySpreadState.previousDistance

            let parameterDelta = deltaDistance / pinkySensitivity
            let smoothedStep = parameterDelta * pinkySmoothing
            let newValue = max(0.01, settings.sphereRadius + smoothedStep)

            settings.sphereRadius = newValue
            pinkySpreadState.previousDistance = currentDistance
        }

        if !isActive && pinkySpreadState.isActive {
            pinkySpreadState.isActive = false
        }
    }

    /// Ring pinch + spread → controls foldingLimit
    private func processRingSpread() {
        guard let settings = renderSettings else { return }

        let leftActive = isPinchActive(value: leftHand.ringPinch, wasActive: ringSpreadState.isActive && leftHand.isTracked)
        let rightActive = isPinchActive(value: rightHand.ringPinch, wasActive: ringSpreadState.isActive && rightHand.isTracked)

        let activeHand: HandData?
        if leftActive && leftHand.isTracked {
            activeHand = leftHand
        } else if rightActive && rightHand.isTracked {
            activeHand = rightHand
        } else {
            activeHand = nil
        }

        let isActive = activeHand != nil

        if isActive && !ringSpreadState.isActive {
            ringSpreadState.isActive = true
            if let hand = activeHand {
                let d = simd_length(hand.thumbTip - hand.ringTip)
                ringSpreadState.startDistance = d
                ringSpreadState.previousDistance = d
            }
        }

        if isActive, let hand = activeHand {
            let currentDistance = simd_length(hand.thumbTip - hand.ringTip)
            let deltaDistance = currentDistance - ringSpreadState.previousDistance

            let parameterDelta = deltaDistance / ringSensitivity
            let smoothedStep = parameterDelta * ringSmoothing
            let newValue = simd_clamp(
                settings.foldingLimit + smoothedStep,
                foldingLimitRange.lowerBound,
                foldingLimitRange.upperBound
            )

            settings.foldingLimit = newValue
            ringSpreadState.previousDistance = currentDistance
        }

        if !isActive && ringSpreadState.isActive {
            ringSpreadState.isActive = false
        }
    }

    /// Right-hand middle pinch drag → position (x/z/y via palm movement)
    private func processRightMiddleDrag() {
        guard let settings = renderSettings else { return }

        // Only right hand for translation
        let active = isPinchActive(value: rightHand.middlePinch, wasActive: rightMiddleDragActive && rightHand.isTracked)

        if active && !rightMiddleDragActive {
            rightMiddleDragActive = true
            rightMiddleDragStart = settings.position
            rightMiddlePrevPalm = rightHand.palmPosition
        }

        if active {
            let currentPalm = rightHand.palmPosition
            let delta = currentPalm - rightMiddlePrevPalm

            // Map palm movement to world translation (x,y,z)
            let step = delta * translateSensitivity * translateSmoothing
            settings.position = rightMiddleDragStart + step
            rightMiddleDragStart = settings.position
            rightMiddlePrevPalm = currentPalm
        }

        if !active && rightMiddleDragActive {
            rightMiddleDragActive = false
        }
    }
    
    /// Check if pinch is active with hysteresis
    private func isPinchActive(value: Float, wasActive: Bool) -> Bool {
        if wasActive {
            return value >= pinchReleaseThreshold
        } else {
            return value >= pinchActivateThreshold
        }
    }
}
