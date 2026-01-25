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
//    * Pinky fingers = fractalScale
//  - SINGLE-HAND PINCH+DRAG: Move one hand while pinching
//    * Right hand index = translate position
//  - LEFT HAND FIST: Start/stop parameter recording
//  - RIGHT HAND MIDDLE FINGER TO PALM: Toggle menu visibility
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
    var palmCenter: SIMD3<Float> = .zero  // Center of palm for gesture detection
    
    // Additional joint positions for advanced gestures
    var indexKnuckle: SIMD3<Float> = .zero
    var middleKnuckle: SIMD3<Float> = .zero
    var ringKnuckle: SIMD3<Float> = .zero
    var pinkyKnuckle: SIMD3<Float> = .zero
    var wrist: SIMD3<Float> = .zero
    
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
    
    /// Calculate fist strength (0-1, 1 = fully closed fist)
    /// Based on how close all fingertips are to the palm center
    func fistStrength() -> Float {
        guard simd_length_squared(palmCenter) > 1e-6 else { return 0 }
        
        // Measure distance from each fingertip to palm center
        let indexDist = simd_length(indexTip - palmCenter)
        let middleDist = simd_length(middleTip - palmCenter)
        let ringDist = simd_length(ringTip - palmCenter)
        let pinkyDist = simd_length(pinkyTip - palmCenter)
        let thumbDist = simd_length(thumbTip - palmCenter)
        
        // Fist threshold distances (in meters)
        let closedDist: Float = 0.03  // 3cm = fully closed
        let openDist: Float = 0.12    // 12cm = fully open
        
        // Calculate strength for each finger
        func fingerStrength(_ dist: Float) -> Float {
            let normalized = 1.0 - ((dist - closedDist) / (openDist - closedDist))
            return simd_clamp(normalized, 0, 1)
        }
        
        let strengths = [
            fingerStrength(indexDist),
            fingerStrength(middleDist),
            fingerStrength(ringDist),
            fingerStrength(pinkyDist),
            fingerStrength(thumbDist)
        ]
        
        // Return minimum strength (all fingers must be curled for a fist)
        return strengths.min() ?? 0
    }
    
    /// Check if middle finger is touching palm (for menu toggle)
    func middleFingerTouchingPalm() -> Float {
        guard simd_length_squared(palmCenter) > 1e-6,
              simd_length_squared(middleTip) > 1e-6 else { return 0 }
        
        let distance = simd_length(middleTip - palmCenter)
        
        // Touch threshold (in meters)
        let touchDist: Float = 0.04   // 4cm = touching
        let awayDist: Float = 0.10    // 10cm = clearly away
        
        let normalized = 1.0 - ((distance - touchDist) / (awayDist - touchDist))
        return simd_clamp(normalized, 0, 1)
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
    private let pinchActivateThreshold: Float = 0.8   // Must exceed to start gesture
    private let pinchReleaseThreshold: Float = 0.6    // Must fall below to end gesture
    
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
    
    // ==========================================================================
    // PER-FRACTAL PARAMETER RANGES
    // Each fractal type has different optimal parameter ranges
    // ==========================================================================
    
    /// Parameter ranges for a specific fractal type
    struct FractalParamRanges {
        let minDistance: ClosedRange<Float>
        let foldingLimit: ClosedRange<Float>
        let sphereRadius: ClosedRange<Float>
        let fractalScale: ClosedRange<Float>
        
        // Default values when switching to this fractal
        let defaultMinDistance: Float
        let defaultFoldingLimit: Float
        let defaultSphereRadius: Float
        let defaultFractalScale: Float
    }
    
    /// Get parameter ranges for current fractal type
    private func currentRanges() -> FractalParamRanges {
        guard let settings = renderSettings else {
            return Self.mandelboxRanges
        }
        
        switch settings.fractalType {
        case .mandelbox:
            return Self.mandelboxRanges
        case .triforce:
            return Self.triforceRanges
        case .negativeMandelbox:
            return Self.negativeMandelboxRanges
        }
    }
    
    // STANDARD MANDELBOX (positive scale ~2-3)
    // - Large exploration ranges for dramatic parameter sweeps
    // - Scale controls overall density, foldingLimit controls box boundaries
    private static let mandelboxRanges = FractalParamRanges(
        minDistance: 0.8...5.0,           // minRadius² - affects sphere fold cutoff
        foldingLimit: 0.5...13.0,         // Box fold boundary - wide range
        sphereRadius: 0.1...2.0,          // Sphere inversion radius
        fractalScale: 1.5...4.0,          // Typical positive scale range
        defaultMinDistance: 0.8,
        defaultFoldingLimit: 1.0,
        defaultSphereRadius: 0.5,
        defaultFractalScale: 2.8
    )
    
    // NEGATIVE MANDELBOX (scale = -1.5)
    // - Tighter ranges because -1.5 scale is very sensitive
    // - Small changes create big visual differences
    // - Reference: https://sites.google.com/site/mandelbox/negative-1-5-mandelbox
    // - Standard params: s=-1.5, r=0.5 (minRad²=0.25), f=1.0
    private static let negativeMandelboxRanges = FractalParamRanges(
        minDistance: 0.1...1.0,           // minRadius² - tighter range (0.25 typical)
        foldingLimit: 0.5...2.0,          // Box fold - tighter (1.0 typical)
        sphereRadius: 0.3...1.0,          // Sphere radius (0.5 typical)
        fractalScale: 1.5...4.0,          // Scale (not directly used, -1.5 is fixed)
        defaultMinDistance: 0.25,         // r² where r=0.5
        defaultFoldingLimit: 1.0,
        defaultSphereRadius: 0.5,
        defaultFractalScale: 2.8          // UI only - actual scale is -1.5
    )
    
    // TRIFORCE / KALEIDOSCOPIC IFS
    // - Scale drives complexity, offset controls position in IFS space
    // - foldingLimit affects tetrahedron fold intensity
    private static let triforceRanges = FractalParamRanges(
        minDistance: 0.5...3.0,           // Not used much in IFS
        foldingLimit: 0.5...5.0,          // Fold intensity
        sphereRadius: 0.1...2.0,          // Not used much in IFS
        fractalScale: 1.5...4.0,          // IFS scale factor
        defaultMinDistance: 1.0,
        defaultFoldingLimit: 1.0,
        defaultSphereRadius: 0.5,
        defaultFractalScale: 2.0
    )
    
    // Single-hand drag sensitivity
    private let translateSensitivity: Float = 1.0
    
    // Hand tracking state
    private var leftHand: HandData = .zero
    private var rightHand: HandData = .zero
    
    // Two-hand gesture states (one per finger pair)
    private var indexGestureState = TwoHandGestureState()    // minDistance
    private var middleGestureState = TwoHandGestureState()   // foldingLimit
    private var ringGestureState = TwoHandGestureState()     // sphereRadius
    private var pinkyGestureState = TwoHandGestureState()    // fractalScale
    
    // Single-hand drag state
    private var rightIndexDragActive: Bool = false
    private var rightIndexDragStartPos: SIMD3<Float> = .zero
    private var rightIndexPrevPos: SIMD3<Float> = .zero
    private var rightIndexPrevPalm: SIMD3<Float> = .zero
    
    // Accumulated position from drag gestures (target position)
    private var accumulatedPosition: SIMD3<Float> = .zero
    
    // === FIST GESTURE STATE (Left hand - recording) ===
    private var leftFistActive: Bool = false
    private let fistActivateThreshold: Float = 0.75   // Must exceed to start fist gesture
    private let fistReleaseThreshold: Float = 0.5     // Must fall below to end fist gesture
    
    // === MENU TOGGLE GESTURE STATE (Right hand - middle finger to palm) ===
    private var menuToggleActive: Bool = false
    private var menuToggleCooldown: Float = 0  // Prevent rapid toggling
    private let menuToggleActivateThreshold: Float = 0.65  // Lowered from 0.8 for easier activation
    private let menuToggleReleaseThreshold: Float = 0.4    // Lowered from 0.5
    private let menuToggleCooldownDuration: Float = 1.0  // 1 second cooldown
    
    // Gesture callbacks
    var onRecordingToggle: (() -> Void)?
    var onMenuToggle: (() -> Void)?
    
    // Reference to render settings
    private weak var renderSettings: RenderSettings?
    
    init(renderSettings: RenderSettings) {
        self.renderSettings = renderSettings
        
        // Initialize accumulated position from current settings
        accumulatedPosition = renderSettings.position
    }
    
    /// Sync internal state with current render settings.
    /// Call this after loading a preset to prevent jumps when gestures resume.
    func syncWithSettings() {
        guard let settings = renderSettings else { return }
        accumulatedPosition = settings.targetPosition
        
        // Reset all gesture states to avoid stale data
        indexGestureState = TwoHandGestureState()
        middleGestureState = TwoHandGestureState()
        ringGestureState = TwoHandGestureState()
        pinkyGestureState = TwoHandGestureState()
        rightIndexDragActive = false
        leftFistActive = false
        menuToggleActive = false
        
        #if DEBUG
        print("🔄 GestureController synced with settings")
        #endif
    }
    
    /// Apply default parameter values for the current fractal type.
    /// Call this when switching fractal types to get good starting values.
    func applyFractalDefaults() {
        guard let settings = renderSettings else { return }
        let ranges = currentRanges()
        
        settings.targetMinDistance = ranges.defaultMinDistance
        settings.targetFoldingLimit = ranges.defaultFoldingLimit
        settings.targetSphereRadius = ranges.defaultSphereRadius
        settings.fractalScale = ranges.defaultFractalScale
        
        // Also update the immediate values for instant feedback
        settings.minDistance = ranges.defaultMinDistance
        settings.foldingLimit = ranges.defaultFoldingLimit
        settings.sphereRadius = ranges.defaultSphereRadius
        
        // Reset gesture states
        syncWithSettings()
        
        #if DEBUG
        print("🎛️ Applied defaults for \(settings.fractalType): minDist=\(ranges.defaultMinDistance), fold=\(ranges.defaultFoldingLimit), sphere=\(ranges.defaultSphereRadius)")
        #endif
    }
    
    /// Get the parameter ranges for the current fractal type (for UI sliders)
    func getParameterRanges() -> (minDistance: ClosedRange<Float>, foldingLimit: ClosedRange<Float>, sphereRadius: ClosedRange<Float>) {
        let ranges = currentRanges()
        return (ranges.minDistance, ranges.foldingLimit, ranges.sphereRadius)
    }
    
    // MARK: - Hand Tracking Updates
    
    /// Update hand data from ARKit hand anchors.
    /// Called every frame via async dispatch. Sets TARGET values on RenderSettings.
    /// The Renderer's interpolateToTargets() handles smooth animation at 90Hz.
    /// - Parameter deltaTime: Time since last hand tracking update (not used for smoothing anymore)
    @available(visionOS 2.0, *)
    func updateHands(leftAnchor: HandAnchor?, rightAnchor: HandAnchor?, deltaTime: Float = 1.0/90.0) {
        leftHand = buildHandData(from: leftAnchor)
        rightHand = buildHandData(from: rightAnchor)
        
        // Update cooldown timer
        if menuToggleCooldown > 0 {
            menuToggleCooldown -= deltaTime
        }
        
        // Process all gesture mappings (sets targets on RenderSettings)
        processGestures()
        
        // Process special gestures
        processLeftFistGesture()
        processMenuToggleGesture()
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
        
        // Knuckle positions for fist detection
        data.indexKnuckle = jointPosition(.indexFingerKnuckle)
        data.middleKnuckle = jointPosition(.middleFingerKnuckle)
        data.ringKnuckle = jointPosition(.ringFingerKnuckle)
        data.pinkyKnuckle = jointPosition(.littleFingerKnuckle)
        data.wrist = jointPosition(.wrist)
        
        // Palm position (use wrist or middle metacarpal)
        data.palmPosition = jointPosition(.middleFingerMetacarpal)
        
        // Palm center (average of metacarpals for more accurate palm detection)
        let indexMeta = jointPosition(.indexFingerMetacarpal)
        let middleMeta = jointPosition(.middleFingerMetacarpal)
        let ringMeta = jointPosition(.ringFingerMetacarpal)
        let pinkyMeta = jointPosition(.littleFingerMetacarpal)
        data.palmCenter = (indexMeta + middleMeta + ringMeta + pinkyMeta) * 0.25
        
        // Calculate pinch values based on distance between thumb and each finger
        // Ring finger has shorter reach to thumb anatomically, so use tighter range
        let pinchMinDist: Float = 0.02  // 2cm = full pinch (same for all)
        
        func calculatePinch(fingerTip: SIMD3<Float>, maxDist: Float) -> Float {
            // Guard against untracked joints (both at zero would give false positive)
            if simd_length_squared(data.thumbTip) < 1e-6 || simd_length_squared(fingerTip) < 1e-6 {
                return 0  // Can't determine pinch if joints aren't tracked
            }
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
    
    // MARK: - Special Gesture Processing
    
    /// Process left hand fist gesture for recording toggle
    private func processLeftFistGesture() {
        guard leftHand.isTracked else {
            if leftFistActive {
                leftFistActive = false
                #if DEBUG
                print("✊ Left fist: tracking lost")
                #endif
            }
            return
        }
        
        let fistStrength = leftHand.fistStrength()
        
        // Check for fist with hysteresis
        let shouldBeActive: Bool
        if leftFistActive {
            shouldBeActive = fistStrength >= fistReleaseThreshold
        } else {
            shouldBeActive = fistStrength >= fistActivateThreshold
        }
        
        // Gesture state changed
        if shouldBeActive && !leftFistActive {
            // Fist just activated - trigger recording toggle
            leftFistActive = true
            onRecordingToggle?()
            #if DEBUG
            print("✊ Left fist ACTIVATED - toggling recording")
            #endif
        } else if !shouldBeActive && leftFistActive {
            // Fist released
            leftFistActive = false
            #if DEBUG
            print("✊ Left fist RELEASED")
            #endif
        }
    }
    
    /// Process right hand middle finger to palm gesture for menu toggle
    private func processMenuToggleGesture() {
        guard rightHand.isTracked else {
            if menuToggleActive {
                menuToggleActive = false
                #if DEBUG
                print("👆 Menu toggle: right hand tracking lost")
                #endif
            }
            return
        }
        
        // Skip if on cooldown
        guard menuToggleCooldown <= 0 else { return }
        
        let touchStrength = rightHand.middleFingerTouchingPalm()
        
        #if DEBUG
        // Log touch strength periodically for debugging (every ~30 frames when strength > 0.3)
        if touchStrength > 0.3 {
            print("👆 Menu gesture - touchStrength: \(String(format: "%.2f", touchStrength)), active: \(menuToggleActive), cooldown: \(String(format: "%.2f", menuToggleCooldown))")
        }
        #endif
        
        // Check for touch with hysteresis
        let shouldBeActive: Bool
        if menuToggleActive {
            shouldBeActive = touchStrength >= menuToggleReleaseThreshold
        } else {
            shouldBeActive = touchStrength >= menuToggleActivateThreshold
        }
        
        // Gesture state changed
        if shouldBeActive && !menuToggleActive {
            // Touch just activated - trigger menu toggle
            menuToggleActive = true
            menuToggleCooldown = menuToggleCooldownDuration
            onMenuToggle?()
            #if DEBUG
            print("👆 Menu toggle ACTIVATED")
            #endif
        } else if !shouldBeActive && menuToggleActive {
            // Touch released
            menuToggleActive = false
        }
    }
    
    // MARK: - Gesture Processing
    
    private func processGestures() {
        guard let settings = renderSettings else { return }
        
        // Track active gesture for HUD display
        var activeDigit = 0
        
        // Get parameter ranges for current fractal type
        let ranges = currentRanges()
        
        // TWO-HAND gestures - directly set TARGET values on RenderSettings
        // Renderer handles smoothing in interpolateToTargets()
        
        // INDEX FINGER: minDistance
        processTwoHandGesture(
            digit: 1,
            state: &indexGestureState,
            currentTarget: settings.targetMinDistance,
            range: ranges.minDistance
        ) { newValue in
            settings.targetMinDistance = newValue
        }
        if indexGestureState.isActive { activeDigit = 1 }
        
        // MIDDLE FINGER: foldingLimit
        processTwoHandGesture(
            digit: 2,
            state: &middleGestureState,
            currentTarget: settings.targetFoldingLimit,
            range: ranges.foldingLimit
        ) { newValue in
            settings.targetFoldingLimit = newValue
        }
        if middleGestureState.isActive { activeDigit = 2 }
        
        // RING FINGER: sphereRadius (sphere inversion radius)
        processTwoHandGesture(
            digit: 3,
            state: &ringGestureState,
            currentTarget: settings.targetSphereRadius,
            range: ranges.sphereRadius
        ) { newValue in
            settings.targetSphereRadius = newValue
        }
        if ringGestureState.isActive { activeDigit = 3 }

        // PINKY FINGER: fractalScale
        processTwoHandGesture(
            digit: 4,
            state: &pinkyGestureState,
            currentTarget: settings.fractalScale,
            range: ranges.fractalScale
        ) { newValue in
            settings.fractalScale = newValue
        }
        if pinkyGestureState.isActive { activeDigit = 4 }
        
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
        let activateThresh = (digit == 3 || digit == 4) ? ringPinchActivateThreshold : pinchActivateThreshold
        let releaseThresh = (digit == 3 || digit == 4) ? ringPinchReleaseThreshold : pinchReleaseThreshold
        
        // Measure hand separation (only meaningful if both tracked)
        let leftPos = leftHand.pinchPosition(digit: digit)
        let rightPos = rightHand.pinchPosition(digit: digit)
        
        // Guard against zero positions (tracking glitch)
        let leftPosValid = simd_length_squared(leftPos) > 1e-6
        let rightPosValid = simd_length_squared(rightPos) > 1e-6
        
        let currentDistance = simd_length(leftPos - rightPos)

        // Check if BOTH hands are pinching (with hysteresis) and within distance guardrails
        let bothActive: Bool
        if state.isActive {
            // Already active - allow up to maxActiveHandDistance, use release threshold
            bothActive = leftHand.isTracked && rightHand.isTracked &&
                         leftPosValid && rightPosValid &&
                         currentDistance <= maxActiveHandDistance &&
                         leftPinch >= releaseThresh &&
                         rightPinch >= releaseThresh
        } else {
            // Not active - require hands to be reasonably close to start
            bothActive = leftHand.isTracked && rightHand.isTracked &&
                         leftPosValid && rightPosValid &&
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
            let paramNames = ["", "minDistance", "foldingLimit", "sphereRadius", "fractalScale"]
            let paramName = paramNames[min(digit, 4)]
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
            let paramName = ["", "minDistance", "foldingLimit", "sphereRadius", "fractalScale"][min(digit, 4)]
            let reason: String
            if !leftHand.isTracked || !rightHand.isTracked {
                reason = "hand tracking lost"
            } else if leftPinch < releaseThresh || rightPinch < releaseThresh {
                reason = "pinch released"
            } else {
                reason = "hands too far apart"
            }
            print("🤲 Two-hand \(paramName) gesture ENDED (\(reason))")
            #endif
        }
    }
    
    /// Right-hand index pinch drag → position translate (XYZ)
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
            active = rightHand.isTracked && rightPinch >= pinchActivateThreshold
        }
        
        // Gesture started
        if active && !rightIndexDragActive {
            rightIndexDragActive = true
            rightIndexDragStartPos = settings.targetPosition
            rightIndexPrevPos = rightHand.pinchPosition(digit: 1)
            rightIndexPrevPalm = rightHand.palmPosition
            accumulatedPosition = settings.targetPosition
            #if DEBUG
            print("👆 Right index drag STARTED")
            #endif
        }
        
        // Gesture active - update target position directly
        if active {
            // Prefer palm for smoother tracking; fall back to pinch midpoint if palm is zero (not tracked)
            var currentPos = rightHand.palmPosition
            if simd_length_squared(currentPos) == 0 { // palm not tracked
                currentPos = rightHand.pinchPosition(digit: 1)
            }
            var previousPos = rightIndexPrevPalm
            if simd_length_squared(previousPos) == 0 { // previous palm not tracked
                previousPos = rightIndexPrevPos
            }

            let rawDelta = currentPos - previousPos
            // Clamp delta to avoid spikes on sporadic joints
            let maxStep: Float = 0.05 // 5 cm per frame cap
            let deltaLength = simd_length(rawDelta)
            let delta = (deltaLength > maxStep && deltaLength > 0) ? rawDelta * (maxStep / deltaLength) : rawDelta

            // Apply translation (world space) to target
            accumulatedPosition = accumulatedPosition + delta * translateSensitivity
            settings.targetPosition = accumulatedPosition
            rightIndexPrevPos = currentPos
            rightIndexPrevPalm = currentPos
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
