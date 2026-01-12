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
//  - ONE-HAND PINCH+DRAG: Pinch and drag with right hand to translate
//    * Works even when left hand is tracked (as long as left isn't pinching)
//    * Right hand index pinch = translate position
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
    
    // Smoothed output values - Mandelbox
    private var smoothedMinDistance: SmoothedValue!
    private var smoothedFoldingLimit: SmoothedValue!
    private var smoothedSphereRadius: SmoothedValue!
    
    // Smoothed output values - IFS
    private var smoothedIFSScale: SmoothedValue!
    private var smoothedIFSOffset: SmoothedValue!
    private var smoothedIFSGlow: SmoothedValue!
    
    private var smoothedPosition: SIMD3<Float> = .zero
    
    // Reference to render settings
    private weak var renderSettings: RenderSettings?
    
    init(renderSettings: RenderSettings) {
        self.renderSettings = renderSettings
        
        // Initialize Mandelbox smoothed values
        smoothedMinDistance = SmoothedValue(initial: renderSettings.minDistance, smoothing: valueSmoothingFactor)
        smoothedFoldingLimit = SmoothedValue(initial: renderSettings.foldingLimit, smoothing: valueSmoothingFactor)
        smoothedSphereRadius = SmoothedValue(initial: renderSettings.sphereRadius, smoothing: valueSmoothingFactor)
        
        // Initialize IFS smoothed values
        smoothedIFSScale = SmoothedValue(initial: renderSettings.ifsScale, smoothing: valueSmoothingFactor)
        smoothedIFSOffset = SmoothedValue(initial: renderSettings.ifsOffset, smoothing: valueSmoothingFactor)
        smoothedIFSGlow = SmoothedValue(initial: renderSettings.ifsGlow, smoothing: valueSmoothingFactor)
        
        smoothedPosition = renderSettings.position
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
        // Pass startParameterValue INTO closure to avoid exclusive access conflict
        // Closure returns true if limit was hit
        
        // INDEX FINGER: minDistance (Mandelbox) / ifsScale (IFS)
        processTwoHandGesture(digit: 1, state: &indexGestureState, parameterUpdate: { [weak self] ratio, startValue in
            guard let self = self else { return false }
            let newValue = startValue * ratio
            if isIFS {
                let clamped = simd_clamp(newValue, self.ifsScaleRange.lowerBound, self.ifsScaleRange.upperBound)
                self.smoothedIFSScale.target = clamped
                return newValue != clamped
            } else {
                let clamped = simd_clamp(newValue, self.minDistanceRange.lowerBound, self.minDistanceRange.upperBound)
                self.smoothedMinDistance.target = clamped
                return newValue != clamped
            }
        })
        
        // MIDDLE FINGER: foldingLimit (Mandelbox) / ifsOffset (IFS)
        processTwoHandGesture(digit: 2, state: &middleGestureState, parameterUpdate: { [weak self] ratio, startValue in
            guard let self = self else { return false }
            let newValue = startValue * ratio
            if isIFS {
                let clamped = simd_clamp(newValue, self.ifsOffsetRange.lowerBound, self.ifsOffsetRange.upperBound)
                self.smoothedIFSOffset.target = clamped
                return newValue != clamped
            } else {
                let clamped = simd_clamp(newValue, self.foldingLimitRange.lowerBound, self.foldingLimitRange.upperBound)
                self.smoothedFoldingLimit.target = clamped
                return newValue != clamped
            }
        })
        
        // RING FINGER: sphereRadius (Mandelbox) / ifsGlow (IFS)
        processTwoHandGesture(digit: 3, state: &ringGestureState, parameterUpdate: { [weak self] ratio, startValue in
            guard let self = self else { return false }
            let newValue = startValue * ratio
            if isIFS {
                let clamped = simd_clamp(newValue, self.ifsGlowRange.lowerBound, self.ifsGlowRange.upperBound)
                self.smoothedIFSGlow.target = clamped
                return newValue != clamped
            } else {
                let clamped = simd_clamp(newValue, self.sphereRadiusRange.lowerBound, self.sphereRadiusRange.upperBound)
                self.smoothedSphereRadius.target = clamped
                return newValue != clamped
            }
        })
        
        // SINGLE-HAND gesture: Right index pinch drag → translate
        processRightIndexDrag()
        
        // Update smoothing for all values
        smoothedMinDistance.update()
        smoothedFoldingLimit.update()
        smoothedSphereRadius.update()
        smoothedIFSScale.update()
        smoothedIFSOffset.update()
        smoothedIFSGlow.update()
    }
    
    /// Process a two-hand scale gesture for a specific finger
    /// - Parameters:
    ///   - digit: 1=index, 2=middle, 3=ring, 4=pinky
    ///   - state: The gesture state to track
    ///   - parameterUpdate: Closure called with (scale ratio, start parameter value), returns true if limit hit
    private func processTwoHandGesture(digit: Int, state: inout TwoHandGestureState, parameterUpdate: (Float, Float) -> Bool) {
        guard let settings = renderSettings else { return }
        
        let leftPinch = leftHand.pinchStrength(digit: digit)
        let rightPinch = rightHand.pinchStrength(digit: digit)
        
        // Check if BOTH hands are pinching (with hysteresis)
        let bothActive: Bool
        if state.isActive {
            // Already active - use release threshold
            bothActive = leftHand.isTracked && rightHand.isTracked &&
                         leftPinch >= pinchReleaseThreshold &&
                         rightPinch >= pinchReleaseThreshold
        } else {
            // Not active - use activate threshold
            bothActive = leftHand.isTracked && rightHand.isTracked &&
                         leftPinch >= pinchActivateThreshold &&
                         rightPinch >= pinchActivateThreshold
        }
        
        // Gesture just started
        if bothActive && !state.isActive {
            state.isActive = true
            let leftPos = leftHand.pinchPosition(digit: digit)
            let rightPos = rightHand.pinchPosition(digit: digit)
            state.startDistance = simd_length(leftPos - rightPos)
            
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
        
        // Gesture active - calculate relative scale
        if bothActive {
            let leftPos = leftHand.pinchPosition(digit: digit)
            let rightPos = rightHand.pinchPosition(digit: digit)
            let currentDistance = simd_length(leftPos - rightPos)
            
            // Calculate ratio: how much has distance changed relative to start?
            // Avoid division by zero
            let ratio = state.startDistance > 0.01 ? currentDistance / state.startDistance : 1.0
            
            // Pass both ratio AND start value to avoid exclusive access conflict
            // Returns true if we hit a limit
            let hitLimit = parameterUpdate(ratio, state.startParameterValue)
            
            // Trigger screen flash when hitting limits
            if hitLimit {
                settings.triggerLimitFlash()
            }
            
            #if DEBUG
            struct DebugState { static var counter = 0 }
            DebugState.counter += 1
            if DebugState.counter % 60 == 0 {
                print("🤲 ratio: \(String(format: "%.2f", ratio))× (distance: \(String(format: "%.1f", currentDistance * 100))cm)")
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
    /// Now works with one hand - no longer requires left hand to be absent
    private func processRightIndexDrag() {
        guard let settings = renderSettings else { return }
        
        // Only if NOT doing a two-hand gesture with index fingers
        guard !indexGestureState.isActive else {
            rightIndexDragActive = false
            return
        }
        
        let rightPinch = rightHand.indexPinch
        let leftPinch = leftHand.indexPinch
        
        // Allow one-handed drag: right hand pinching while left hand is NOT pinching (or not tracked)
        // This enables translation with just one hand while still allowing two-hand gestures
        let leftNotPinching = !leftHand.isTracked || leftPinch < pinchActivateThreshold
        
        let active: Bool
        if rightIndexDragActive {
            // Stay active as long as right hand is pinching and left is not also pinching
            active = rightHand.isTracked && rightPinch >= pinchReleaseThreshold && leftNotPinching
        } else {
            // Activate when right hand pinches and left hand is not pinching
            active = rightHand.isTracked && rightPinch >= pinchActivateThreshold && leftNotPinching
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
        
        // IFS parameters
        settings.ifsScale = smoothedIFSScale.current
        settings.ifsOffset = smoothedIFSOffset.current
        settings.ifsGlow = smoothedIFSGlow.current
        
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
