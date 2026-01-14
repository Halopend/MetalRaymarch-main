//
//  GestureController.swift
//  MetalRaymarch
//
//  Two-hand gesture controls for fractal parameters
//
//  Usage:
//  - TWO-HAND PINCH: Pinch with both hands simultaneously
//    * Index fingers = minDistance (pull apart = increase)
//    * Middle fingers = foldingLimit
//    * Ring fingers = sphereRadius
//  - SINGLE-HAND PINCH+DRAG: Move one hand while pinching
//    * Right hand index = translate position
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
    
    /// Get pinch position (midpoint between thumb and finger)
    func pinchPosition(digit: Int) -> SIMD3<Float> {
        let fingerTip: SIMD3<Float>
        switch digit {
        case 1: fingerTip = indexTip
        case 2: fingerTip = middleTip
        case 3: fingerTip = ringTip
        case 4: fingerTip = pinkyTip
        default: fingerTip = indexTip
        }
        return (thumbTip + fingerTip) * 0.5
    }
    
    func pinchStrength(digit: Int) -> Float {
        switch digit {
        case 1: return indexPinch
        case 2: return middlePinch
        case 3: return ringPinch
        case 4: return pinkyPinch
        default: return indexPinch
        }
    }
    
    static var zero: HandData { HandData() }
}

// MARK: - Two-Hand Gesture State

/// State for a two-hand scale gesture
struct TwoHandGestureState {
    var isActive: Bool = false
    var startDistance: Float = 0      // Distance between hands when gesture started
    var startParameterValue: Float = 0  // Parameter value when gesture started
}

// MARK: - Gesture Controller

/// Processes hand tracking data and maps gestures to render parameters
/// 
/// TWO-HAND DESIGN:
/// - Both hands must pinch with the SAME finger to activate a gesture
/// - Parameter scales RELATIVELY: if hands move 2× apart, parameter doubles
/// - Smoothing prevents jitter and provides natural feel
@MainActor
final class GestureController {
    
    // Pinch thresholds with hysteresis
    private let pinchActivateThreshold: Float = 0.65   // Must exceed to start gesture
    private let pinchReleaseThreshold: Float = 0.45    // Must fall below to end gesture
    
    // Ring finger needs lower thresholds (anatomically harder to pinch with thumb)
    private let ringPinchActivateThreshold: Float = 0.50
    private let ringPinchReleaseThreshold: Float = 0.30
    
    // Smoothing speed for frame-rate independent animation (higher = faster convergence)
    // 12.0 = ~63% convergence in 83ms, feels responsive yet smooth
    private let valueSmoothingSpeed: Float = 12.0
    
    // Hand distance range for DIRECT MAPPING (in meters)
    // Hands close together = min value, hands far apart = max value
    private let minHandDistance: Float = 0.05  // 5cm
    private let maxHandDistance: Float = 0.60  // 60cm
    // Guardrails to prevent accidental activation when hands are wide apart
    private let maxStartHandDistance: Float = 0.35  // Require hands within 35cm to start
    private let maxActiveHandDistance: Float = 0.80 // Allow expansion up to 80cm
    
    // Mandelbox parameter ranges - WIDE for exploration
    private let minDistanceRange: ClosedRange<Float> = 0.001...5.0
    private let foldingLimitRange: ClosedRange<Float> = 0.1...13.0
    private let sphereRadiusRange: ClosedRange<Float> = 0.01...2.0
    
    // Single-hand drag sensitivity
    private let translateSensitivity: Float = 1.0
    
    // Hand tracking state
    private var leftHand: HandData = .zero
    private var rightHand: HandData = .zero
    
    // Two-hand gesture states (one per finger pair)
    private var indexGestureState = TwoHandGestureState()    // minDistance
    private var middleGestureState = TwoHandGestureState()   // foldingLimit
    private var ringGestureState = TwoHandGestureState()     // sphereRadius
    
    // Single-hand drag state
    private var rightIndexDragActive: Bool = false
    private var rightIndexDragStartPos: SIMD3<Float> = .zero
    private var rightIndexPrevPos: SIMD3<Float> = .zero
    
    // Accumulated position from drag gestures (target position)
    private var accumulatedPosition: SIMD3<Float> = .zero
    
    // Reference to render settings
    private weak var renderSettings: RenderSettings?
    
    init(renderSettings: RenderSettings) {
        self.renderSettings = renderSettings
        
        // Initialize accumulated position from current settings
        accumulatedPosition = renderSettings.position
    }
    
    // MARK: - Hand Tracking Updates
    
    /// Update hand data from ARKit hand anchors.
    /// Called asynchronously at ~30Hz. Sets TARGET values on RenderSettings.
    /// The Renderer's interpolateToTargets() handles smooth animation at 90Hz.
    /// - Parameter deltaTime: Time since last hand tracking update (not used for smoothing anymore)
    @available(visionOS 2.0, *)
    func updateHands(leftAnchor: HandAnchor?, rightAnchor: HandAnchor?, deltaTime: Float = 1.0/90.0) {
        leftHand = buildHandData(from: leftAnchor)
        rightHand = buildHandData(from: rightAnchor)
        
        // Process all gesture mappings (sets targets on RenderSettings)
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
        // Ring finger has shorter reach to thumb anatomically, so use tighter range
        let pinchMinDist: Float = 0.02  // 2cm = full pinch (same for all)
        
        func calculatePinch(fingerTip: SIMD3<Float>, maxDist: Float) -> Float {
            let distance = simd_length(data.thumbTip - fingerTip)
            let normalized = 1.0 - ((distance - pinchMinDist) / (maxDist - pinchMinDist))
            return simd_clamp(normalized, 0, 1)
        }
        
        // Index/middle have longer reach (8cm range), ring/pinky have shorter reach (6cm range)
        data.indexPinch = calculatePinch(fingerTip: data.indexTip, maxDist: 0.08)
        data.middlePinch = calculatePinch(fingerTip: data.middleTip, maxDist: 0.08)
        data.ringPinch = calculatePinch(fingerTip: data.ringTip, maxDist: 0.06)   // Tighter range for ring
        data.pinkyPinch = calculatePinch(fingerTip: data.pinkyTip, maxDist: 0.055) // Even tighter for pinky
        
        return data
    }
    
    // MARK: - Gesture Processing
    
    private func processGestures() {
        guard let settings = renderSettings else { return }
        
        // Track active gesture for HUD display
        var activeDigit = 0
        
        // TWO-HAND gestures - directly set TARGET values on RenderSettings
        // Renderer handles smoothing in interpolateToTargets()
        
        // INDEX FINGER: minDistance
        processTwoHandGesture(
            digit: 1,
            state: &indexGestureState,
            currentTarget: settings.targetMinDistance,
            range: minDistanceRange
        ) { newValue in
            settings.targetMinDistance = newValue
        }
        if indexGestureState.isActive { activeDigit = 1 }
        
        // MIDDLE FINGER: foldingLimit
        processTwoHandGesture(
            digit: 2,
            state: &middleGestureState,
            currentTarget: settings.targetFoldingLimit,
            range: foldingLimitRange
        ) { newValue in
            settings.targetFoldingLimit = newValue
        }
        if middleGestureState.isActive { activeDigit = 2 }
        
        // RING FINGER: sphereRadius
        processTwoHandGesture(
            digit: 3,
            state: &ringGestureState,
            currentTarget: settings.targetSphereRadius,
            range: sphereRadiusRange
        ) { newValue in
            settings.targetSphereRadius = newValue
        }
        if ringGestureState.isActive { activeDigit = 3 }
        
        // Update active gesture for HUD
        settings.activeGestureIndex = activeDigit
        
        // SINGLE-HAND gesture: Right index pinch drag → translate
        processRightIndexDrag()
    }
    
    /// Process a two-hand gesture for a specific finger
    /// Directly sets TARGET values - Renderer handles smoothing
    /// - Parameters:
    ///   - digit: 1=index, 2=middle, 3=ring, 4=pinky
    ///   - state: The gesture state to track
    ///   - currentTarget: The current target value (read from RenderSettings)
    ///   - range: The valid range for the parameter
    ///   - setTarget: Closure to set the new target value
    private func processTwoHandGesture(
        digit: Int,
        state: inout TwoHandGestureState,
        currentTarget: Float,
        range: ClosedRange<Float>,
        setTarget: (Float) -> Void
    ) {
        guard let settings = renderSettings else { return }
        
        let leftPinch = leftHand.pinchStrength(digit: digit)
        let rightPinch = rightHand.pinchStrength(digit: digit)
        
        // Use lower thresholds for ring finger (harder to pinch)
        let activateThresh = (digit == 3) ? ringPinchActivateThreshold : pinchActivateThreshold
        let releaseThresh = (digit == 3) ? ringPinchReleaseThreshold : pinchReleaseThreshold
        
        // Measure hand separation (only meaningful if both tracked)
        let leftPos = leftHand.pinchPosition(digit: digit)
        let rightPos = rightHand.pinchPosition(digit: digit)
        let currentDistance = simd_length(leftPos - rightPos)

        // Check if BOTH hands are pinching (with hysteresis) and within distance guardrails
        let bothActive: Bool
        if state.isActive {
            // Already active - allow up to maxActiveHandDistance, use release threshold
            bothActive = leftHand.isTracked && rightHand.isTracked &&
                         currentDistance <= maxActiveHandDistance &&
                         leftPinch >= releaseThresh &&
                         rightPinch >= releaseThresh
        } else {
            // Not active - require hands to be reasonably close to start
            bothActive = leftHand.isTracked && rightHand.isTracked &&
                         currentDistance <= maxStartHandDistance &&
                         leftPinch >= activateThresh &&
                         rightPinch >= activateThresh
        }
        
        // Gesture just started
        if bothActive && !state.isActive {
            state.isActive = true
            state.startDistance = currentDistance
            state.startParameterValue = currentTarget  // Capture current target when gesture starts
            
            #if DEBUG
            let paramNames = ["", "minDistance", "foldingLimit", "sphereRadius"]
            let paramName = paramNames[min(digit, 3)]
            let mode = settings.useRelativeGestures ? "RELATIVE" : "ABSOLUTE"
            print("🤲 Two-hand \(paramName) gesture STARTED (\(mode))")
            #endif
        }
        
        // Gesture active - set TARGET directly (Renderer smooths to this value)
        if bothActive {
            var hitLimit = false
            var newValue: Float
            
            if settings.useRelativeGestures {
                // RELATIVE: Change based on delta from start distance
                let rangeSpan = range.upperBound - range.lowerBound
                let distSpan = maxHandDistance - minHandDistance
                let sensitivity = rangeSpan / distSpan
                
                let delta = currentDistance - state.startDistance
                newValue = state.startParameterValue + (delta * sensitivity)
                newValue = min(range.upperBound, max(range.lowerBound, newValue))
                hitLimit = (newValue <= range.lowerBound + 1e-5 || newValue >= range.upperBound - 1e-5)
                
            } else {
                // ABSOLUTE: Map distance directly to 0-1 range
                let normalizedDistance = simd_clamp(
                    (currentDistance - minHandDistance) / (maxHandDistance - minHandDistance),
                    0.0, 1.0
                )
                
                newValue = range.lowerBound + normalizedDistance * (range.upperBound - range.lowerBound)
                hitLimit = (normalizedDistance <= 0.01 || normalizedDistance >= 0.99)
            }
            
            // Set target value directly - Renderer handles smoothing
            setTarget(newValue)
            
            // Trigger screen flash when hitting limits
            if hitLimit {
                settings.triggerLimitFlash()
            }
            
            #if DEBUG
            struct DebugState { static var counter = 0 }
            DebugState.counter += 1
            if DebugState.counter % 60 == 0 {
                // print("🤲 distance: \(String(format: "%.1f", currentDistance * 100))cm")
            }
            #endif
        }
        
        // Gesture ended
        if !bothActive && state.isActive {
            state.isActive = false
            #if DEBUG
            let paramName = ["", "minDistance", "foldingLimit", "sphereRadius"][min(digit, 3)]
            print("🤲 Two-hand \(paramName) gesture ENDED")
            #endif
        }
    }
    
    /// Right-hand index pinch drag → position translate
    private func processRightIndexDrag() {
        guard let settings = renderSettings else { return }
        
        // Only if NOT doing a two-hand gesture with index fingers
        guard !indexGestureState.isActive else {
            rightIndexDragActive = false
            return
        }
        
        let rightPinch = rightHand.indexPinch
        let active: Bool
        if rightIndexDragActive {
            active = rightHand.isTracked && rightPinch >= pinchReleaseThreshold
        } else {
            active = rightHand.isTracked && rightPinch >= pinchActivateThreshold && !leftHand.isTracked
        }
        
        // Gesture started
        if active && !rightIndexDragActive {
            rightIndexDragActive = true
            rightIndexDragStartPos = settings.targetPosition
            rightIndexPrevPos = rightHand.pinchPosition(digit: 1)
            accumulatedPosition = settings.targetPosition
            #if DEBUG
            print("👆 Right index drag STARTED")
            #endif
        }
        
        // Gesture active - update target position directly
        if active {
            let currentPos = rightHand.pinchPosition(digit: 1)
            let delta = currentPos - rightIndexPrevPos
            
            // Apply translation (world space) to target
            accumulatedPosition = accumulatedPosition + delta * translateSensitivity
            settings.targetPosition = accumulatedPosition
            rightIndexPrevPos = currentPos
        }
        
        // Gesture ended
        if !active && rightIndexDragActive {
            rightIndexDragActive = false
            #if DEBUG
            print("👆 Right index drag ENDED")
            #endif
        }
    }
    
    // MARK: - Pinch Detection
    
    /// Check if pinch is active with hysteresis
    private func isPinchActive(value: Float, wasActive: Bool) -> Bool {
        if wasActive {
            return value >= pinchReleaseThreshold
        } else {
            return value >= pinchActivateThreshold
        }
    }
}
