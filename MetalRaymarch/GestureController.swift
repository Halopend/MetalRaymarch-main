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

// MARK: - Smoothed Value

/// Value with exponential smoothing - smooth transitions, no jitter
/// Uses deltaTime for frame-rate independent animation speed
final class SmoothedValue {
    var target: Float
    private(set) var current: Float
    let speed: Float  // Convergence speed in units per second (higher = faster)
    
    // Default speed 15.0 means ~63% convergence in 1/15th second (~67ms)
    // This feels responsive while hiding frame-to-frame jitter
    init(initial: Float, speed: Float = 15.0) {
        self.target = initial
        self.current = initial
        self.speed = speed
    }
    
    /// Update current value towards target using deltaTime for frame-rate independence
    func update(deltaTime: Float) {
        // Exponential decay: factor = 1 - e^(-speed * dt)
        // At speed=15, dt=1/60: factor ≈ 0.22 (smooth)
        // At speed=15, dt=1/30: factor ≈ 0.39 (catches up on slow frames)
        let factor = 1.0 - exp(-speed * deltaTime)
        current = current + (target - current) * factor
    }
    
    /// Snap immediately to target (no smoothing)
    func snap() {
        current = target
    }
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
    
    // Smoothed output values - Mandelbox
    private var smoothedMinDistance: SmoothedValue!
    private var smoothedFoldingLimit: SmoothedValue!
    private var smoothedSphereRadius: SmoothedValue!
    
    private var smoothedPosition: SIMD3<Float> = .zero
    
    // Reference to render settings
    private weak var renderSettings: RenderSettings?
    
    init(renderSettings: RenderSettings) {
        self.renderSettings = renderSettings
        
        // Initialize Mandelbox smoothed values with frame-rate independent speed
        smoothedMinDistance = SmoothedValue(initial: renderSettings.minDistance, speed: valueSmoothingSpeed)
        smoothedFoldingLimit = SmoothedValue(initial: renderSettings.foldingLimit, speed: valueSmoothingSpeed)
        smoothedSphereRadius = SmoothedValue(initial: renderSettings.sphereRadius, speed: valueSmoothingSpeed)
        
        smoothedPosition = renderSettings.position
    }
    
    // MARK: - Hand Tracking Updates
    
    // Track deltaTime for frame-rate independent smoothing
    private var lastUpdateDeltaTime: Float = 1.0 / 90.0
    
    /// Update hand data from ARKit hand anchors
    /// - Parameter deltaTime: Time since last update in seconds (for frame-rate independent smoothing)
    @available(visionOS 2.0, *)
    func updateHands(leftAnchor: HandAnchor?, rightAnchor: HandAnchor?, deltaTime: Float = 1.0/90.0) {
        lastUpdateDeltaTime = deltaTime
        leftHand = buildHandData(from: leftAnchor)
        rightHand = buildHandData(from: rightAnchor)
        
        // Process all gesture mappings
        processGestures()
        
        // Apply smoothed values to settings
        applySmoothedValues()
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
        
        // TWO-HAND gestures
        // Supports both Absolute (direct mapping) and Relative (delta-based) modes
        
        // INDEX FINGER: minDistance
        processTwoHandGesture(digit: 1, state: &indexGestureState, target: smoothedMinDistance, range: minDistanceRange)
        if indexGestureState.isActive { activeDigit = 1 }
        
        // MIDDLE FINGER: foldingLimit
        processTwoHandGesture(digit: 2, state: &middleGestureState, target: smoothedFoldingLimit, range: foldingLimitRange)
        if middleGestureState.isActive { activeDigit = 2 }
        
        // RING FINGER: sphereRadius
        processTwoHandGesture(digit: 3, state: &ringGestureState, target: smoothedSphereRadius, range: sphereRadiusRange)
        if ringGestureState.isActive { activeDigit = 3 }
        
        // Update active gesture for HUD
        settings.activeGestureIndex = activeDigit
        
        // SINGLE-HAND gesture: Right index pinch drag → translate
        processRightIndexDrag()
        
        // Update smoothing for all values (frame-rate independent)
        smoothedMinDistance.update(deltaTime: lastUpdateDeltaTime)
        smoothedFoldingLimit.update(deltaTime: lastUpdateDeltaTime)
        smoothedSphereRadius.update(deltaTime: lastUpdateDeltaTime)
    }
    
    /// Process a two-hand gesture for a specific finger
    /// Supports Relative (Default) and Absolute (Direct Mapping) modes
    /// - Parameters:
    ///   - digit: 1=index, 2=middle, 3=ring, 4=pinky
    ///   - state: The gesture state to track
    ///   - target: The smoothed value to update
    ///   - range: The valid range for the parameter
    private func processTwoHandGesture(digit: Int, state: inout TwoHandGestureState, target: SmoothedValue, range: ClosedRange<Float>) {
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
            state.startParameterValue = target.target // Snap start value to current target
            
            #if DEBUG
            let paramNames = ["", "minDistance", "foldingLimit", "sphereRadius"]
            let paramName = paramNames[min(digit, 3)]
            let mode = settings.useRelativeGestures ? "RELATIVE" : "ABSOLUTE"
            print("🤲 Two-hand \(paramName) gesture STARTED (\(mode))")
            #endif
        }
        
        // Gesture active
        if bothActive {
            var hitLimit = false
            
            if settings.useRelativeGestures {
                // RELATIVE: Change based on delta from start distance
                // Calculate sensitivity: map (max-min hand dist) to (max-min parameter range)
                // This ensures full parameter range is reachable with similar physical movement
                let rangeSpan = range.upperBound - range.lowerBound
                let distSpan = maxHandDistance - minHandDistance
                let sensitivity = rangeSpan / distSpan
                
                let delta = currentDistance - state.startDistance
                let newValue = state.startParameterValue + (delta * sensitivity)
                
                target.target = min(range.upperBound, max(range.lowerBound, newValue))
                hitLimit = (target.target <= range.lowerBound + 1e-5 || target.target >= range.upperBound - 1e-5)
                
            } else {
                // ABSOLUTE: Map distance directly to 0-1 range
                let normalizedDistance = simd_clamp(
                    (currentDistance - minHandDistance) / (maxHandDistance - minHandDistance),
                    0.0, 1.0
                )
                
                let newValue = range.lowerBound + normalizedDistance * (range.upperBound - range.lowerBound)
                target.target = newValue
                hitLimit = (normalizedDistance <= 0.01 || normalizedDistance >= 0.99)
            }
            
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
            rightIndexDragStartPos = settings.position
            rightIndexPrevPos = rightHand.pinchPosition(digit: 1)
            #if DEBUG
            print("👆 Right index drag STARTED")
            #endif
        }
        
        // Gesture active - move position
        if active {
            let currentPos = rightHand.pinchPosition(digit: 1)
            let delta = currentPos - rightIndexPrevPos
            
            // Apply translation (world space)
            smoothedPosition = smoothedPosition + delta * translateSensitivity
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
    
    // MARK: - Apply to Settings
    
    private func applySmoothedValues() {
        guard let settings = renderSettings else { return }
        
        // Mandelbox parameters
        settings.minDistance = smoothedMinDistance.current
        settings.foldingLimit = smoothedFoldingLimit.current
        settings.sphereRadius = smoothedSphereRadius.current
        
        // Position smoothing (simple exponential)
        let posSmoothing: Float = 0.8
        settings.position = settings.position * posSmoothing + smoothedPosition * (1 - posSmoothing)
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
