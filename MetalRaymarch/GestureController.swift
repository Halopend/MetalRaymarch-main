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

// MARK: - Smoothed Value (Legacy - simple exponential)

/// Value with exponential smoothing - smooth transitions, no jitter
final class SmoothedValue {
    var target: Float
    private(set) var current: Float
    let smoothing: Float  // 0 = instant, 0.9 = very slow
    
    init(initial: Float, smoothing: Float = 0.85) {
        self.target = initial
        self.current = initial
        self.smoothing = smoothing
    }
    
    /// Update current value towards target. Call once per frame.
    func update() {
        current = current * smoothing + target * (1 - smoothing)
    }
    
    /// Snap immediately to target (no smoothing)
    func snap() {
        current = target
    }
}

// MARK: - Jerk-Limited Value (Two-Stage Smoothing)

/// Two-stage parameter smoothing with jerk limiting for ultra-smooth transitions.
/// 
/// Stage 1: Gesture input → Target (raw input, may jump)
/// Stage 2: Target → Current (velocity/acceleration/jerk limited)
///
/// This ensures smooth motion even when:
/// - Hand tracking is lost and regained
/// - Target jumps due to gesture re-acquisition
/// - User makes rapid movements
final class JerkLimitedValue {
    // Target value (set by gestures, may jump)
    var target: Float
    
    // Current smoothed value (what gets rendered)
    private(set) var current: Float
    
    // Motion state
    private var velocity: Float = 0
    private var acceleration: Float = 0
    
    // Limits (per frame, assuming 90fps)
    let maxVelocity: Float      // Max change per frame
    let maxAcceleration: Float  // Max velocity change per frame
    let maxJerk: Float          // Max acceleration change per frame (smoothest)
    
    // Whether target updates are frozen (e.g., hand lost)
    var targetFrozen: Bool = false
    
    init(initial: Float, maxVelocity: Float = 0.1, maxAcceleration: Float = 0.02, maxJerk: Float = 0.005) {
        self.target = initial
        self.current = initial
        self.maxVelocity = maxVelocity
        self.maxAcceleration = maxAcceleration
        self.maxJerk = maxJerk
    }
    
    /// Update current value towards target with jerk-limited smoothing.
    /// Call once per frame.
    func update() {
        // Calculate desired velocity to reach target
        let error = target - current
        let desiredVelocity = simd_clamp(error, -maxVelocity, maxVelocity)
        
        // Calculate desired acceleration to reach desired velocity
        let velocityError = desiredVelocity - velocity
        let desiredAcceleration = simd_clamp(velocityError, -maxAcceleration, maxAcceleration)
        
        // Apply jerk limiting (smooth acceleration changes)
        let accelerationError = desiredAcceleration - acceleration
        let jerk = simd_clamp(accelerationError, -maxJerk, maxJerk)
        
        // Update motion state
        acceleration += jerk
        velocity += acceleration
        velocity = simd_clamp(velocity, -maxVelocity, maxVelocity)
        current += velocity
    }
    
    /// Snap immediately to target (no smoothing) - use sparingly
    func snap() {
        current = target
        velocity = 0
        acceleration = 0
    }
    
    /// Freeze target updates (call when hand tracking is lost)
    func freezeTarget() {
        targetFrozen = true
    }
    
    /// Unfreeze target updates (call when hand tracking is regained)
    func unfreezeTarget() {
        targetFrozen = false
    }
    
    /// Set target only if not frozen
    func setTargetIfNotFrozen(_ value: Float) {
        if !targetFrozen {
            target = value
        }
    }
}

// MARK: - Two-Hand Gesture State

/// State for a two-hand scale gesture with hand-loss recovery
struct TwoHandGestureState {
    var isActive: Bool = false
    var startDistance: Float = 0           // Distance between hands when gesture started
    var startParameterValue: Float = 0     // Parameter value when gesture started
    
    // Hand-loss recovery state
    var isInterrupted: Bool = false        // True if gesture was interrupted by hand loss
    var lastValidDistance: Float = 0       // Last known distance when both hands were tracked
    var lastValidRatio: Float = 1.0        // Last known ratio when both hands were tracked
    var interruptedParameterValue: Float = 0  // Parameter value when interrupted
    
    /// Reset to initial state
    mutating func reset() {
        isActive = false
        isInterrupted = false
        startDistance = 0
        startParameterValue = 0
        lastValidDistance = 0
        lastValidRatio = 1.0
        interruptedParameterValue = 0
    }
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
    
    // Pinch thresholds with hysteresis (slightly higher than FractalVision for reliability)
    private let pinchActivateThreshold: Float = 0.90   // Must exceed to start gesture
    private let pinchReleaseThreshold: Float = 0.75    // Must fall below to end gesture
    
    // Value smoothing (higher = slower/smoother)
    private let valueSmoothingFactor: Float = 0.85
    
    // Mandelbox parameter ranges
    private let minDistanceRange: ClosedRange<Float> = 0.001...3.0
    private let foldingLimitRange: ClosedRange<Float> = 0.1...5.0
    private let sphereRadiusRange: ClosedRange<Float> = 0.01...2.0
    
    // IFS parameter ranges
    private let ifsScaleRange: ClosedRange<Float> = 1.2...2.5
    private let ifsOffsetRange: ClosedRange<Float> = 0.5...1.5
    private let ifsGlowRange: ClosedRange<Float> = 0.1...3.0
    
    // Single-hand drag sensitivity
    private let translateSensitivity: Float = 1.0
    
    // Hand tracking state
    private var leftHand: HandData = .zero
    private var rightHand: HandData = .zero
    
    // Two-hand gesture states (one per finger pair)
    private var indexGestureState = TwoHandGestureState()    // minDistance / ifsScale
    private var middleGestureState = TwoHandGestureState()   // foldingLimit / ifsOffset
    private var ringGestureState = TwoHandGestureState()     // sphereRadius / ifsGlow
    
    // Single-hand drag state
    private var rightIndexDragActive: Bool = false
    private var rightIndexDragStartPos: SIMD3<Float> = .zero
    private var rightIndexPrevPos: SIMD3<Float> = .zero
    
    // Jerk-limited output values - Mandelbox (two-stage smoothing)
    private var jerkMinDistance: JerkLimitedValue!
    private var jerkFoldingLimit: JerkLimitedValue!
    private var jerkSphereRadius: JerkLimitedValue!
    
    // Jerk-limited output values - IFS (two-stage smoothing)
    private var jerkIFSScale: JerkLimitedValue!
    private var jerkIFSOffset: JerkLimitedValue!
    private var jerkIFSGlow: JerkLimitedValue!
    
    // Jerk-limited position (3 components)
    private var jerkPositionX: JerkLimitedValue!
    private var jerkPositionY: JerkLimitedValue!
    private var jerkPositionZ: JerkLimitedValue!
    
    // Reference to render settings
    private weak var renderSettings: RenderSettings?
    
    init(renderSettings: RenderSettings) {
        self.renderSettings = renderSettings
        
        // Initialize Mandelbox jerk-limited values
        // Parameters: maxVelocity, maxAcceleration, maxJerk (per frame at 90fps)
        // Lower values = smoother but slower response
        jerkMinDistance = JerkLimitedValue(initial: renderSettings.minDistance, maxVelocity: 0.05, maxAcceleration: 0.01, maxJerk: 0.003)
        jerkFoldingLimit = JerkLimitedValue(initial: renderSettings.foldingLimit, maxVelocity: 0.08, maxAcceleration: 0.015, maxJerk: 0.004)
        jerkSphereRadius = JerkLimitedValue(initial: renderSettings.sphereRadius, maxVelocity: 0.03, maxAcceleration: 0.008, maxJerk: 0.002)
        
        // Initialize IFS jerk-limited values
        jerkIFSScale = JerkLimitedValue(initial: renderSettings.ifsScale, maxVelocity: 0.02, maxAcceleration: 0.005, maxJerk: 0.001)
        jerkIFSOffset = JerkLimitedValue(initial: renderSettings.ifsOffset, maxVelocity: 0.02, maxAcceleration: 0.005, maxJerk: 0.001)
        jerkIFSGlow = JerkLimitedValue(initial: renderSettings.ifsGlow, maxVelocity: 0.05, maxAcceleration: 0.01, maxJerk: 0.003)
        
        // Initialize position jerk-limited values (slower for smooth camera movement)
        jerkPositionX = JerkLimitedValue(initial: renderSettings.position.x, maxVelocity: 0.02, maxAcceleration: 0.005, maxJerk: 0.001)
        jerkPositionY = JerkLimitedValue(initial: renderSettings.position.y, maxVelocity: 0.02, maxAcceleration: 0.005, maxJerk: 0.001)
        jerkPositionZ = JerkLimitedValue(initial: renderSettings.position.z, maxVelocity: 0.02, maxAcceleration: 0.005, maxJerk: 0.001)
    }
    
    // MARK: - Hand Tracking Updates
    
    /// Update hand data from ARKit hand anchors
    @available(visionOS 2.0, *)
    func updateHands(leftAnchor: HandAnchor?, rightAnchor: HandAnchor?) {
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
        guard let settings = renderSettings else { return }
        
        let isIFS = settings.sceneIndex == 1
        
        // TWO-HAND gestures (both hands pinching same finger)
        // Uses jerk-limited smoothing for ultra-smooth transitions
        // Handles hand-loss gracefully by freezing target when hand leaves FOV
        
        // INDEX FINGER: minDistance (Mandelbox) / ifsScale (IFS)
        processTwoHandGesture(digit: 1, state: &indexGestureState, parameterUpdate: { [weak self] ratio, startValue in
            guard let self = self else { return false }
            let newValue = startValue * ratio
            if isIFS {
                let clamped = simd_clamp(newValue, self.ifsScaleRange.lowerBound, self.ifsScaleRange.upperBound)
                self.jerkIFSScale.target = clamped
                return newValue != clamped
            } else {
                let clamped = simd_clamp(newValue, self.minDistanceRange.lowerBound, self.minDistanceRange.upperBound)
                self.jerkMinDistance.target = clamped
                return newValue != clamped
            }
        })
        
        // MIDDLE FINGER: foldingLimit (Mandelbox) / ifsOffset (IFS)
        processTwoHandGesture(digit: 2, state: &middleGestureState, parameterUpdate: { [weak self] ratio, startValue in
            guard let self = self else { return false }
            let newValue = startValue * ratio
            if isIFS {
                let clamped = simd_clamp(newValue, self.ifsOffsetRange.lowerBound, self.ifsOffsetRange.upperBound)
                self.jerkIFSOffset.target = clamped
                return newValue != clamped
            } else {
                let clamped = simd_clamp(newValue, self.foldingLimitRange.lowerBound, self.foldingLimitRange.upperBound)
                self.jerkFoldingLimit.target = clamped
                return newValue != clamped
            }
        })
        
        // RING FINGER: sphereRadius (Mandelbox) / ifsGlow (IFS)
        processTwoHandGesture(digit: 3, state: &ringGestureState, parameterUpdate: { [weak self] ratio, startValue in
            guard let self = self else { return false }
            let newValue = startValue * ratio
            if isIFS {
                let clamped = simd_clamp(newValue, self.ifsGlowRange.lowerBound, self.ifsGlowRange.upperBound)
                self.jerkIFSGlow.target = clamped
                return newValue != clamped
            } else {
                let clamped = simd_clamp(newValue, self.sphereRadiusRange.lowerBound, self.sphereRadiusRange.upperBound)
                self.jerkSphereRadius.target = clamped
                return newValue != clamped
            }
        })
        
        // SINGLE-HAND gesture: Right index pinch drag → translate
        processRightIndexDrag()
        
        // Update jerk-limited smoothing for all values (always runs, even when frozen)
        jerkMinDistance.update()
        jerkFoldingLimit.update()
        jerkSphereRadius.update()
        jerkIFSScale.update()
        jerkIFSOffset.update()
        jerkIFSGlow.update()
        jerkPositionX.update()
        jerkPositionY.update()
        jerkPositionZ.update()
    }
    
    /// Process a two-hand scale gesture for a specific finger with hand-loss recovery
    /// 
    /// Key behavior:
    /// - When both hands are tracked and pinching: update target normally
    /// - When one hand loses tracking: freeze target (no jumps), mark as interrupted
    /// - When hand returns: resume from where we left off using lastValidRatio
    /// - When pinch is released: end gesture completely
    ///
    /// - Parameters:
    ///   - digit: 1=index, 2=middle, 3=ring, 4=pinky
    ///   - state: The gesture state to track
    ///   - parameterUpdate: Closure called with (scale ratio, start parameter value), returns true if limit hit
    private func processTwoHandGesture(digit: Int, state: inout TwoHandGestureState, parameterUpdate: (Float, Float) -> Bool) {
        guard let settings = renderSettings else { return }
        
        let leftPinch = leftHand.pinchStrength(digit: digit)
        let rightPinch = rightHand.pinchStrength(digit: digit)
        
        // Determine tracking and pinch states separately
        let bothTracked = leftHand.isTracked && rightHand.isTracked
        let leftPinching = leftPinch >= (state.isActive ? pinchReleaseThreshold : pinchActivateThreshold)
        let rightPinching = rightPinch >= (state.isActive ? pinchReleaseThreshold : pinchActivateThreshold)
        let bothPinching = leftPinching && rightPinching
        
        // Check if at least one hand is still pinching (for interrupted state)
        let atLeastOnePinching = (leftHand.isTracked && leftPinching) || (rightHand.isTracked && rightPinching)
        
        // Full active state: both tracked AND both pinching
        let fullyActive = bothTracked && bothPinching
        
        // === STATE MACHINE ===
        
        // CASE 1: Gesture not active, check for start
        if !state.isActive && !state.isInterrupted {
            if fullyActive {
                // Start new gesture
                state.isActive = true
                state.isInterrupted = false
                let leftPos = leftHand.pinchPosition(digit: digit)
                let rightPos = rightHand.pinchPosition(digit: digit)
                state.startDistance = simd_length(leftPos - rightPos)
                state.lastValidDistance = state.startDistance
                state.lastValidRatio = 1.0
                
                // Store starting parameter value based on scene
                let isIFS = settings.sceneIndex == 1
                switch digit {
                case 1: state.startParameterValue = isIFS ? settings.ifsScale : settings.minDistance
                case 2: state.startParameterValue = isIFS ? settings.ifsOffset : settings.foldingLimit
                case 3: state.startParameterValue = isIFS ? settings.ifsGlow : settings.sphereRadius
                default: state.startParameterValue = 1.0
                }
                
                #if DEBUG
                let mandelboxNames = ["", "minDistance", "foldingLimit", "sphereRadius"]
                let ifsNames = ["", "ifsScale", "ifsOffset", "ifsGlow"]
                let paramName = isIFS ? ifsNames[min(digit, 3)] : mandelboxNames[min(digit, 3)]
                print("🤲 Two-hand \(paramName) gesture STARTED (value: \(state.startParameterValue), distance: \(String(format: "%.2f", state.startDistance * 100))cm)")
                #endif
            }
            return
        }
        
        // CASE 2: Gesture active and both hands tracked - normal operation
        if state.isActive && fullyActive {
            let leftPos = leftHand.pinchPosition(digit: digit)
            let rightPos = rightHand.pinchPosition(digit: digit)
            let currentDistance = simd_length(leftPos - rightPos)
            
            // Calculate ratio relative to start
            let ratio = state.startDistance > 0.01 ? currentDistance / state.startDistance : 1.0
            
            // Store last valid state for recovery
            state.lastValidDistance = currentDistance
            state.lastValidRatio = ratio
            
            // Update parameter
            let hitLimit = parameterUpdate(ratio, state.startParameterValue)
            if hitLimit {
                settings.triggerLimitFlash()
            }
            
            // Clear interrupted flag if we were recovering
            if state.isInterrupted {
                state.isInterrupted = false
                #if DEBUG
                print("🤲 Gesture RESUMED from interruption")
                #endif
            }
            
            #if DEBUG
            struct DebugState { static var counter = 0 }
            DebugState.counter += 1
            if DebugState.counter % 60 == 0 {
                print("🤲 ratio: \(String(format: "%.2f", ratio))× (distance: \(String(format: "%.1f", currentDistance * 100))cm)")
            }
            #endif
            return
        }
        
        // CASE 3: Gesture was active but one hand lost tracking - INTERRUPT (don't end)
        if state.isActive && !bothTracked && atLeastOnePinching {
            // Transition to interrupted state - freeze target, don't jump
            state.isActive = false
            state.isInterrupted = true
            state.interruptedParameterValue = state.startParameterValue * state.lastValidRatio
            
            #if DEBUG
            let paramName = ["", "minDistance", "foldingLimit", "sphereRadius"][min(digit, 3)]
            print("🤲 Two-hand \(paramName) gesture INTERRUPTED (hand lost, freezing at ratio \(String(format: "%.2f", state.lastValidRatio))×)")
            #endif
            return
        }
        
        // CASE 4: Gesture was interrupted, check for recovery or end
        if state.isInterrupted {
            if fullyActive {
                // Both hands back and pinching - RESUME gesture
                // Use current distance as new reference, but keep the interrupted parameter value
                let leftPos = leftHand.pinchPosition(digit: digit)
                let rightPos = rightHand.pinchPosition(digit: digit)
                let currentDistance = simd_length(leftPos - rightPos)
                
                // Reset start values to resume from interrupted state
                state.startDistance = currentDistance
                state.startParameterValue = state.interruptedParameterValue
                state.lastValidDistance = currentDistance
                state.lastValidRatio = 1.0
                
                state.isActive = true
                state.isInterrupted = false
                
                #if DEBUG
                let paramName = ["", "minDistance", "foldingLimit", "sphereRadius"][min(digit, 3)]
                print("🤲 Two-hand \(paramName) gesture RECOVERED (new start value: \(String(format: "%.3f", state.startParameterValue)))")
                #endif
            } else if !atLeastOnePinching {
                // Both hands released pinch - END gesture completely
                state.reset()
                
                #if DEBUG
                let paramName = ["", "minDistance", "foldingLimit", "sphereRadius"][min(digit, 3)]
                print("🤲 Two-hand \(paramName) gesture ENDED (pinch released during interruption)")
                #endif
            }
            // Otherwise stay interrupted (waiting for recovery or release)
            return
        }
        
        // CASE 5: Gesture was active but pinch released - END gesture
        if state.isActive && !bothPinching {
            state.reset()
            
            #if DEBUG
            let paramName = ["", "minDistance", "foldingLimit", "sphereRadius"][min(digit, 3)]
            print("🤲 Two-hand \(paramName) gesture ENDED (pinch released)")
            #endif
        }
    }
    
    /// Right-hand index pinch drag → position translate (with jerk-limited smoothing)
    private func processRightIndexDrag() {
        guard let settings = renderSettings else { return }
        
        // Only if NOT doing a two-hand gesture with index fingers
        guard !indexGestureState.isActive && !indexGestureState.isInterrupted else {
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
        
        // Gesture active - update position targets
        if active {
            let currentPos = rightHand.pinchPosition(digit: 1)
            let delta = currentPos - rightIndexPrevPos
            
            // Update jerk-limited position targets (world space)
            jerkPositionX.target += delta.x * translateSensitivity
            jerkPositionY.target += delta.y * translateSensitivity
            jerkPositionZ.target += delta.z * translateSensitivity
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
    
    /// Apply jerk-limited smoothed values to render settings
    /// This is the second stage of the two-stage pipeline:
    /// Stage 1: Gesture input → Target (may jump)
    /// Stage 2: Target → Current (jerk-limited, always smooth)
    private func applySmoothedValues() {
        guard let settings = renderSettings else { return }
        
        // Mandelbox parameters (jerk-limited)
        settings.minDistance = jerkMinDistance.current
        settings.foldingLimit = jerkFoldingLimit.current
        settings.sphereRadius = jerkSphereRadius.current
        
        // IFS parameters (jerk-limited)
        settings.ifsScale = jerkIFSScale.current
        settings.ifsOffset = jerkIFSOffset.current
        settings.ifsGlow = jerkIFSGlow.current
        
        // Position (jerk-limited)
        settings.position = SIMD3<Float>(jerkPositionX.current, jerkPositionY.current, jerkPositionZ.current)
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
