//
//  GestureController.swift
//  Threshold
//
//  Two-hand gesture controls for fractal parameters
//
//  Usage:
//  - TWO-HAND PINCH: Pinch with both hands simultaneously
//    Finger-to-action mapping is configurable (see FingerGestureAction).
//    Default: index=grab, middle=minDistance, ring=fractalScale, pinky=sphereRadius.
//  - SINGLE-HAND PINCH+DRAG: Move one hand while pinching
//    * Right hand index = translate position
//  - LEFT HAND FIST: Start/stop parameter recording
//  - RIGHT HAND MENU GESTURE (configurable): Toggle menu visibility
//

import Foundation
import ARKit
import simd

// MARK: - Debug Configuration

/// Set to true to enable verbose hand tracking debug logging
private let HAND_TRACKING_DEBUG = false

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

    /// Check if ring finger is touching palm (secondary menu-toggle gesture option)
    func ringFingerTouchingPalm() -> Float {
        guard simd_length_squared(palmCenter) > 1e-6,
              simd_length_squared(ringTip) > 1e-6 else { return 0 }

        let distance = simd_length(ringTip - palmCenter)

        // Ring finger sits slightly farther from palm center than middle finger.
        let touchDist: Float = 0.045
        let awayDist: Float = 0.11

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
    var startHeight: Float = 0          // Average Y position of hands when gesture started (for sensitivity scaling)
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
    let operationDispatcher: ParameterOperationDispatcher
    private var operationFrameCounter: UInt64 = 0
    
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
        
        // Use extended ranges if enabled
        if settings.extendedGestureRange {
            return Self.mandelboxExtendedRanges
        }
        
        return Self.mandelboxRanges
    }
    
    // STANDARD MANDELBOX (positive scale ~2-3)
    // - Large exploration ranges for dramatic parameter sweeps
    // - Scale controls overall density, foldingLimit controls box boundaries
    private static let mandelboxRanges = FractalParamRanges(
        minDistance: -2.0...8.0,          // minRadius² - affects sphere fold cutoff (now includes negative for inverted effects)
        foldingLimit: -5.0...20.0,        // Box fold boundary - wide range with negatives for unusual topology
        sphereRadius: -3.0...4.0,         // Sphere inversion radius (negative for inverse effects)
        fractalScale: -3.0...5.0,         // FAMOUS NEGATIVE SCALING FACTOR - creates stunning inverse fractals
        defaultMinDistance: 0.8,
        defaultFoldingLimit: 1.0,
        defaultSphereRadius: 0.5,
        defaultFractalScale: 2.8
    )
    
    // EXTENDED MANDELBOX RANGES
    // - Much wider ranges for extreme exploration
    // - Allows reaching more unusual/exotic parameter combinations
    private static let mandelboxExtendedRanges = FractalParamRanges(
        minDistance: -5.0...15.0,         // Extended: extreme minRadius² range with deep negatives
        foldingLimit: -10.0...30.0,       // Extended: allows very tight and very loose folds, deep inverse folding
        sphereRadius: -5.0...8.0,         // Extended: from negative to large sphere inversions
        fractalScale: -5.0...8.0,         // Extended: EXTREME negative scaling for wild inverse effects
        defaultMinDistance: 0.8,
        defaultFoldingLimit: 1.0,
        defaultSphereRadius: 0.5,
        defaultFractalScale: 2.8
    )
    
    /// When true, parameter-changing gestures (two-hand pinch, single-hand drag) are
    /// suppressed so that pinching to interact with the SwiftUI menu window does not
    /// also move through the fractal.  Menu toggle gesture is intentionally kept active.
    var suppressParameterGestures: Bool = false
    
    // Hand tracking state
    private var leftHand: HandData = .zero
    private var rightHand: HandData = .zero
    
    // Two-hand gesture states — one per finger pair, action-agnostic.
    // The action each finger performs is read from RenderSettings at dispatch time.
    private var fingerGestureState: [Int: TwoHandGestureState] = [
        1: TwoHandGestureState(),   // index
        2: TwoHandGestureState(),   // middle
        3: TwoHandGestureState(),   // ring
        4: TwoHandGestureState(),   // pinky
    ]
    
    // === TWO-POINT GRAB STATE (middle finger, both hands) ===
    // Grabs two points in space; pulling apart scales, rotating rotates the world.
    private var grabActive: Bool = false
    private var grabEndCooldown: Float = 0  // Prevents drag from stealing gesture after grab ends
    private var grabStartLeftPos: SIMD3<Float> = .zero       // Left pinch position when grab started
    private var grabStartRightPos: SIMD3<Float> = .zero      // Right pinch position when grab started
    private var grabStartDistance: Float = 0                  // Distance between hands at grab start
    private var grabStartMidpoint: SIMD3<Float> = .zero      // Midpoint of the two grab points at start
    private var grabStartAxis: SIMD3<Float> = .zero          // Normalized axis (right-left) at start
    private var grabStartRotation: simd_quatf = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)  // World rotation when grab started
    private var detailStartScale: Float = 1.0                  // detailScale when gesture started
    private var grabStartPosition: SIMD3<Float> = .zero      // World position when gesture started

    // Rotation breakaway state: rotation is suppressed until the hand delta exceeds the breakaway angle.
    // Once broken away, rotation tracks hands 1:1. Resets on each new grab.
    private var rotationBrokenAway: Bool = false
    private var breakawayBaseAxis: SIMD3<Float> = .zero      // Hand axis when breakaway occurred (for rebasing delta)
    
    // Single-hand drag state
    private var rightIndexDragActive: Bool = false
    private var rightIndexDragStartPos: SIMD3<Float> = .zero
    private var rightIndexPrevPos: SIMD3<Float> = .zero
    private var rightIndexPrevPalm: SIMD3<Float> = .zero
    
    // Accumulated position from drag gestures (target position)
    private var accumulatedPosition: SIMD3<Float> = .zero
    
    // === GMT-FRACTALS: Asymmetric Smoothed Gesture Speed ===
    // Like CameraController.ts's smoothedDistEstimate, but applied to gesture
    // drag magnitude. Instant response for deceleration (safety/precision),
    // lerped response for acceleration (prevents jarring speed-ups).
    private var smoothedDragSpeed: Float = 0.0
    
    // === MENU TOGGLE GESTURE STATE (Right hand, configurable mode) ===
    private var menuToggleActive: Bool = false
    private var menuToggleHoldTimer: Float = 0
    private var menuToggleCooldown: Float = 0  // Prevent rapid toggling
    
    // Gesture callbacks
    var onMenuToggle: (() -> Void)?
    
    // Reference to render settings
    private weak var renderSettings: RenderSettings?
    
    init(renderSettings: RenderSettings,
         operationDispatcher: ParameterOperationDispatcher? = nil) {
        self.renderSettings = renderSettings
        self.operationDispatcher = operationDispatcher ?? ParameterOperationDispatcher()
        
        // Initialize accumulated position from current settings
        accumulatedPosition = renderSettings.position
    }
    
    func setDebugTraceEnabled(_ enabled: Bool) {
        operationDispatcher.debugTraceEnabled = enabled
    }

    /// Sync internal state with current render settings.
    /// Call this after loading a preset to prevent jumps when gestures resume.
    func syncWithSettings() {
        guard let settings = renderSettings else { return }
        accumulatedPosition = settings.effectiveTargetPosition
        
        // Reset all gesture states to avoid stale data
        for digit in 1...4 { fingerGestureState[digit] = TwoHandGestureState() }
        grabActive = false
        grabEndCooldown = 0
        rightIndexDragActive = false
        menuToggleActive = false
        menuToggleHoldTimer = 0
        menuToggleCooldown = 0
        
        if HAND_TRACKING_DEBUG {
            print("🔄 GestureController synced with settings")
        }
    }
    
    /// Apply default parameter values for the current fractal type.
    /// Call this when switching fractal types to get good starting values.
    func applyFractalDefaults() {
        guard let settings = renderSettings else { return }
        let ranges = currentRanges()
        
        // Reset core shape properties (kept for smoothDamp/shader bridge).
        settings.targetMinDistance = ranges.defaultMinDistance
        settings.targetFoldingLimit = ranges.defaultFoldingLimit
        settings.targetSphereRadius = ranges.defaultSphereRadius
        settings.targetFractalScale = ranges.defaultFractalScale
        
        // Also update the immediate values for instant feedback
        settings.minDistance = ranges.defaultMinDistance
        settings.foldingLimit = ranges.defaultFoldingLimit
        settings.sphereRadius = ranges.defaultSphereRadius
        settings.fractalScale = ranges.defaultFractalScale

        // Reset formula params to catalog defaults (includes Mandelbox now).
        settings.formulaParams = settings.fractalType.defaultFormulaParams()

        // Fractal-specific default orientation.
        // Mandelbulb defaults requested: P75 Y180 R180 with detail scale 0.25.
        if settings.fractalType == .mandelbulb {
            let qx = simd_quatf(angle: .pi, axis: SIMD3<Float>(1, 0, 0))              // R180
            let qy = simd_quatf(angle: 75.0 * .pi / 180.0, axis: SIMD3<Float>(0, 1, 0)) // P75
            let qz = simd_quatf(angle: .pi, axis: SIMD3<Float>(0, 0, 1))              // Y180
            let mandelbulbFacing = simd_normalize(qz * qy * qx)
            settings.worldRotation = mandelbulbFacing
            settings.targetWorldRotation = mandelbulbFacing
            settings.detailScale = 0.25
            settings.targetDetailScale = 0.25

            // Center the Mandelbulb in front of the user by resetting position
            // to the initial default (prevents carry-over from previous fractal).
            let defaultPos = SIMD3<Float>(0.1, 0.1, 0.1)
            settings.position = defaultPos
            settings.targetPosition = defaultPos

            // Safety bubble clashes with the Mandelbulb surface — disable it.
            settings.safetyBubbleEnabled = false
        }
        
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
        operationFrameCounter &+= 1
        leftHand = buildHandData(from: leftAnchor)
        rightHand = buildHandData(from: rightAnchor)
        
        // Update cooldown timers
        if menuToggleCooldown > 0 {
            menuToggleCooldown = max(0, menuToggleCooldown - deltaTime)
        }
        if grabEndCooldown > 0 {
            grabEndCooldown = max(0, grabEndCooldown - deltaTime)
        }
        
        // Process all gesture mappings (sets targets on RenderSettings)
        processGestures()
        
        // Process special gestures
        processMenuToggleGesture(deltaTime: deltaTime)
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
        
        // Palm center (average of metacarpals for more accurate palm detection)
        // OPTIMIZATION: Use SIMD addition with single multiply instead of 4 multiplies
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
    
    private func menuToggleStrength(for mode: MenuToggleGestureMode) -> Float {
        switch mode {
        case .middleToPalm:
            return rightHand.middleFingerTouchingPalm()
        case .middleAndRingToPalm:
            return min(rightHand.middleFingerTouchingPalm(), rightHand.ringFingerTouchingPalm())
        case .fist:
            return rightHand.fistStrength()
        }
    }

    private func menuToggleThresholds(for mode: MenuToggleGestureMode, settings: RenderSettings) -> (activate: Float, release: Float) {
        let baseActivate = settings.menuToggleActivateThreshold
        let baseRelease = min(settings.menuToggleReleaseThreshold, baseActivate - 0.05)

        switch mode {
        case .middleToPalm:
            return (activate: baseActivate + 0.02, release: baseRelease + 0.02)
        case .middleAndRingToPalm:
            return (activate: baseActivate, release: baseRelease)
        case .fist:
            return (activate: min(0.96, baseActivate + 0.18), release: min(0.92, baseRelease + 0.15))
        }
    }

    /// Process right-hand menu toggle gesture with configurable mode and hold duration.
    private func processMenuToggleGesture(deltaTime: Float) {
        guard let settings = renderSettings else { return }

        guard settings.menuToggleGestureEnabled else {
            menuToggleActive = false
            menuToggleHoldTimer = 0
            return
        }

        guard rightHand.isTracked else {
            if menuToggleActive {
                menuToggleActive = false
                if HAND_TRACKING_DEBUG { print("👆 Menu toggle: right hand tracking lost") }
            }
            menuToggleHoldTimer = 0
            return
        }

        let mode = settings.menuToggleGestureMode
        let strength = menuToggleStrength(for: mode)
        let thresholds = menuToggleThresholds(for: mode, settings: settings)

        if HAND_TRACKING_DEBUG && strength > 0.2 {
            print("👆 Menu gesture [\(mode)] strength: \(String(format: "%.2f", strength)), active: \(menuToggleActive), hold: \(String(format: "%.2f", menuToggleHoldTimer)), cooldown: \(String(format: "%.2f", menuToggleCooldown))")
        }

        let shouldBeActive: Bool = menuToggleActive
            ? (strength >= thresholds.release)
            : (strength >= thresholds.activate)

        if shouldBeActive {
            if !menuToggleActive {
                menuToggleHoldTimer += deltaTime
                if menuToggleCooldown <= 0, menuToggleHoldTimer >= settings.menuToggleHoldDuration {
                    menuToggleActive = true
                    menuToggleHoldTimer = 0
                    menuToggleCooldown = settings.menuToggleCooldown
                    if HAND_TRACKING_DEBUG { print("👆 Menu toggle ACTIVATED - calling onMenuToggle callback") }
                    onMenuToggle?()
                }
            }
        } else {
            if menuToggleActive {
                menuToggleActive = false
                if HAND_TRACKING_DEBUG { print("👆 Menu toggle RELEASED") }
            }
            menuToggleHoldTimer = 0
        }
    }
    
    // MARK: - Gesture Processing
    
    private func processGestures() {
        guard let settings = renderSettings else { return }
        
        // ── Suppress parameter gestures while the user is interacting with the menu window ──
        // Eye-hover on the window sets this flag; we deactivate any in-flight gestures
        // cleanly so releasing the suppression doesn't cause a jump.
        if suppressParameterGestures {
            for digit in 1...4 {
                if fingerGestureState[digit]?.isActive == true { fingerGestureState[digit]?.isActive = false }
            }
            if grabActive                  { grabActive = false }
            if rightIndexDragActive        { rightIndexDragActive = false }
            settings.activeGestureIndex = 0
            settings.isGeometryGestureActive = false
            return
        }

        // Track active gesture for HUD display
        var activeDigit = 0
        
        // Get parameter ranges for current fractal type
        let ranges = currentRanges()
        
        // ── DATA-DRIVEN TWO-HAND GESTURE DISPATCH ──────────────────────────
        // Each finger pair reads its assigned action from RenderSettings.
        // Parameter gestures use processTwoHandGesture(); grab uses processTwoPointGrab().

        for digit in 1...4 {
            let binding = settings.bindingForDigit(digit)

            if case .parameter(let descriptor) = binding,
               let formulaIndex = descriptor.formulaIndex,
               let node = ParameterNodeRegistry.shared.node(for: descriptor) {
                processTwoHandGesture(
                    digit: digit,
                    state: &fingerGestureState[digit]!,
                    currentTarget: FormulaCatalog.getParam(settings.formulaParams, index: formulaIndex),
                    range: node.range,
                    parameterID: node.id
                ) { newValue in
                    let op = ParameterOperation(
                        targetID: node.id,
                        source: .gesture,
                        value: .absolute(newValue),
                        frameIndex: operationFrameCounter,
                        smoothing: .init()
                    )
                    operationDispatcher.dispatch(
                        ParameterTransaction(frameIndex: operationFrameCounter, operations: [op]),
                        settings: settings
                    )
                    UsageAnalytics.shared.trackHandGestureUsed()
                }
                if fingerGestureState[digit]!.isActive { activeDigit = digit }
                continue
            }

            guard case .core(let action) = binding else {
                if fingerGestureState[digit]?.isActive == true {
                    fingerGestureState[digit]?.isActive = false
                }
                continue
            }

            switch action {
            case .grab:
                processTwoPointGrab(digit: digit)
                if grabActive { activeDigit = digit }
                
            case .minDistance, .foldingLimit, .sphereRadius:
                // Shape params are now formula params for Mandelbox. Non-Mandelbox
                // types won't have these bindings (sanitised on type switch).
                guard settings.fractalType == .mandelbox else {
                    if fingerGestureState[digit]?.isActive == true {
                        fingerGestureState[digit]?.isActive = false
                    }
                    continue
                }
                processMandelboxShapeGesture(digit: digit, action: action, ranges: ranges, settings: settings, activeDigit: &activeDigit)

            case .fractalScale:
                // Fractal scale is a universal core parameter (all types).
                processCoreScaleGesture(digit: digit, ranges: ranges, settings: settings, activeDigit: &activeDigit)
                
            case .none:
                // Deactivate any stale state for unassigned fingers
                if fingerGestureState[digit]?.isActive == true {
                    fingerGestureState[digit]?.isActive = false
                }
            default:
                if fingerGestureState[digit]?.isActive == true {
                    fingerGestureState[digit]?.isActive = false
                }
            }
        }
        
        // Update active gesture for HUD
        settings.activeGestureIndex = activeDigit
        
        // Wire geometry gesture flag so the state machine and dynamic quality know
        // when a geometry-affecting gesture is in progress.
        let anyGeometryGestureActive = grabActive ||
            (1...4).contains(where: { fingerGestureState[$0]?.isActive == true })
        settings.isGeometryGestureActive = anyGeometryGestureActive
        
        // SINGLE-HAND gesture: Right index pinch drag → translate
        processRightIndexDrag()
    }
    
    // MARK: - Shape & Scale Gesture Dispatch
    
    /// Maps a FingerGestureAction (.minDistance / .foldingLimit / .sphereRadius)
    /// to the corresponding Mandelbox formula-param index.
    private static let shapeActionToFormulaIndex: [FingerGestureAction: Int] = [
        .minDistance:   0,
        .foldingLimit:  1,
        .sphereRadius:  2
    ]

    /// Dispatches a two-hand gesture for Mandelbox shape params through the unified
    /// formula-param dispatcher.  Preserves animation-offset blending so gestures
    /// during animation playback behave identically to the legacy core path.
    private func processMandelboxShapeGesture(
        digit: Int,
        action: FingerGestureAction,
        ranges: FractalParamRanges,
        settings: RenderSettings,
        activeDigit: inout Int
    ) {
        guard let formulaIndex = Self.shapeActionToFormulaIndex[action] else { return }
        
        let currentTarget: Float = {
            switch action {
            case .minDistance:   return settings.effectiveTargetMinDistance
            case .foldingLimit:  return settings.effectiveTargetFoldingLimit
            case .sphereRadius:  return settings.effectiveTargetSphereRadius
            default: return 0
            }
        }()

        let range: ClosedRange<Float> = {
            switch action {
            case .minDistance:  return ranges.minDistance
            case .foldingLimit: return ranges.foldingLimit
            case .sphereRadius: return ranges.sphereRadius
            default: return 0...1
            }
        }()

        let batch = ParameterNodeRegistry.shared.formulaBatch(for: .mandelbox)
        guard let node = batch.floatNodeByFormulaIndex[formulaIndex] else { return }

        processTwoHandGesture(
            digit: digit,
            state: &fingerGestureState[digit]!,
            currentTarget: currentTarget,
            range: range,
            parameterID: node.id
        ) { newValue in
            let targetValue: Float
            if settings.isAnimationPlaying {
                switch action {
                case .minDistance:
                    targetValue = newValue
                    settings.manualOffsetMinDistance = newValue - settings.animationBaseMinDistance
                case .foldingLimit:
                    targetValue = newValue
                    settings.manualOffsetFoldingLimit = newValue - settings.animationBaseFoldingLimit
                case .sphereRadius:
                    targetValue = newValue
                    settings.manualOffsetSphereRadius = newValue - settings.animationBaseSphereRadius
                default:
                    targetValue = newValue
                }
            } else {
                targetValue = newValue
            }
            let op = ParameterOperation(
                targetID: node.id,
                source: .gesture,
                value: .absolute(targetValue),
                frameIndex: operationFrameCounter,
                smoothing: .init()
            )
            operationDispatcher.dispatch(
                ParameterTransaction(frameIndex: operationFrameCounter, operations: [op]),
                settings: settings
            )
            UsageAnalytics.shared.trackHandGestureUsed()
        }
        if fingerGestureState[digit]!.isActive { activeDigit = digit }
    }

    /// Dispatches a two-hand gesture for the universal fractalScale core parameter.
    /// Kept on the core path because fractalScale has its own smoothDamp and
    /// applies to every fractal type.
    private func processCoreScaleGesture(
        digit: Int,
        ranges: FractalParamRanges,
        settings: RenderSettings,
        activeDigit: inout Int
    ) {
        processTwoHandGesture(
            digit: digit,
            state: &fingerGestureState[digit]!,
            currentTarget: settings.effectiveTargetFractalScale,
            range: ranges.fractalScale,
            parameterID: "core.targetFractalScale"
        ) { newValue in
            let targetValue: Float
            if settings.isAnimationPlaying {
                targetValue = newValue
                settings.manualOffsetFractalScale = newValue - settings.animationBaseFractalScale
            } else {
                targetValue = newValue
            }
            let op = ParameterOperation(
                targetID: "core.targetFractalScale",
                source: .gesture,
                value: .absolute(targetValue),
                frameIndex: operationFrameCounter,
                smoothing: .init()
            )
            operationDispatcher.dispatch(
                ParameterTransaction(frameIndex: operationFrameCounter, operations: [op]),
                settings: settings
            )
            UsageAnalytics.shared.trackHandGestureUsed()
        }
        if fingerGestureState[digit]!.isActive { activeDigit = digit }
    }
    
    // MARK: - Two-Point Grab Gesture (Configurable Finger, Both Hands)
    
    /// Two-point grab: both hands pinch the assigned finger to grab two points in space.
    /// - Pulling hands apart/together → scales the fractal world (detailScale)
    /// - Rotating the axis between hands → rotates the fractal world (worldRotation)
    /// - Position is derived so the pivot (hand midpoint) stays "pinned" in world space.
    ///
    /// Pivot-correct transform:
    ///   newModel = T(currentMid) × R(deltaRot) × S(deltaScale) × T(-startMid) × startModel
    /// Factored into T × R × R_fixed × S form:
    ///   newPos       = currentMid + rot(deltaRot, scaleRatio × (startPos - startMid))
    ///   newUserRot   = deltaRot × startRot
    ///   newDetailScale = startDetailScale × scaleRatio
    ///
    /// This works because uniform scaling commutes with rotation in the model matrix.
    private func processTwoPointGrab(digit: Int) {
        guard let settings = renderSettings else { return }
        
        let leftPinch = leftHand.pinchStrength(digit: digit)
        let rightPinch = rightHand.pinchStrength(digit: digit)
        
        let activateThresh = settings.twoHandPinchActivateThreshold
        let releaseThresh = settings.twoHandPinchReleaseThreshold
        
        let leftPos = leftHand.pinchPosition(digit: digit)
        let rightPos = rightHand.pinchPosition(digit: digit)
        
        let leftPosValid = simd_length_squared(leftPos) > 1e-6
        let rightPosValid = simd_length_squared(rightPos) > 1e-6
        
        let currentDistance = simd_length(leftPos - rightPos)
        let maxStartHandDistance = settings.gestureMaxStartHandDistance
        let maxActiveHandDistance = max(settings.gestureMaxActiveHandDistance, maxStartHandDistance)
        
        // Check if both hands are pinching
        let bothActive: Bool
        if grabActive {
            bothActive = leftHand.isTracked && rightHand.isTracked &&
                         leftPosValid && rightPosValid &&
                         currentDistance <= maxActiveHandDistance &&
                         leftPinch >= releaseThresh &&
                         rightPinch >= releaseThresh
        } else {
            bothActive = leftHand.isTracked && rightHand.isTracked &&
                         leftPosValid && rightPosValid &&
                         currentDistance <= maxStartHandDistance &&
                         leftPinch >= activateThresh &&
                         rightPinch >= activateThresh
        }
        
        // === GESTURE START ===
        if bothActive && !grabActive {
            grabActive = true
            grabStartLeftPos = leftPos
            grabStartRightPos = rightPos
            grabStartDistance = max(currentDistance, 0.01)  // Prevent division by zero
            grabStartMidpoint = (leftPos + rightPos) * 0.5
            let axis = rightPos - leftPos
            let axisLen = simd_length(axis)
            grabStartAxis = axisLen > 1e-4 ? axis / axisLen : SIMD3<Float>(1, 0, 0)
            // Capture CURRENT values (what's visually shown), not targets.
            // Since applyDetailState snaps current=target, these are the same after
            // the first gesture. But on the very first grab, we want what's on screen.
            grabStartRotation = settings.worldRotation
            detailStartScale = settings.detailScale
            grabStartPosition = settings.position
            rotationBrokenAway = !settings.rotationAutoSnap  // If snap disabled, act as if already broken away
            breakawayBaseAxis = .zero
            
            if HAND_TRACKING_DEBUG {
                print("🤲✊ Two-point GRAB started: dist=\(grabStartDistance), mid=\(grabStartMidpoint)")
            }
        }
        
        // === GESTURE ACTIVE ===
        if bothActive && grabActive {
            let currentMidpoint = (leftPos + rightPos) * 0.5
            let currentAxis = rightPos - leftPos
            let currentAxisLen = simd_length(currentAxis)
            let currentAxisNorm = currentAxisLen > 1e-4 ? currentAxis / currentAxisLen : grabStartAxis
            
            // 1) SCALE: ratio of current hand distance to start distance
            let scaleRatio = currentDistance / max(grabStartDistance, 0.01)
            let adjustedScale = detailStartScale * scaleRatio
            // Clamp to reasonable range (0.05× to 20× of starting scale)
            let clampedScale = max(0.05, min(20.0, adjustedScale))
            
            // 2) ROTATION: compute quaternion from start axis to current axis
            let dot = simd_clamp(simd_dot(grabStartAxis, currentAxisNorm), -1.0, 1.0)
            let cross = simd_cross(grabStartAxis, currentAxisNorm)
            let crossLen = simd_length(cross)
            
            let deltaRotation: simd_quatf
            if crossLen > 1e-6 {
                let angle = acos(dot)
                let rotAxis = cross / crossLen
                deltaRotation = simd_quatf(angle: angle, axis: rotAxis)
            } else if dot < 0 {
                let perp: SIMD3<Float> = abs(grabStartAxis.x) < 0.9
                    ? simd_normalize(simd_cross(grabStartAxis, SIMD3<Float>(1, 0, 0)))
                    : simd_normalize(simd_cross(grabStartAxis, SIMD3<Float>(0, 1, 0)))
                deltaRotation = simd_quatf(angle: .pi, axis: perp)
            } else {
                deltaRotation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
            }
            
            // 2b) BREAKAWAY GATE: suppress rotation until hand delta exceeds breakaway angle
            let effectiveRotation: simd_quatf
            if !rotationBrokenAway {
                // Measure angle between start axis and current axis
                let breakawayAngleRad = acos(simd_clamp(dot, -1.0, 1.0))
                let breakawayThresholdRad = settings.rotationBreakawayDegrees * (.pi / 180.0)
                if breakawayAngleRad >= breakawayThresholdRad {
                    // Broken away! Rebase so rotation starts from current hand position
                    rotationBrokenAway = true
                    breakawayBaseAxis = currentAxisNorm
                    grabStartRotation = settings.worldRotation
                    effectiveRotation = grabStartRotation  // No jump on the first frame
                } else {
                    effectiveRotation = grabStartRotation  // Hold at start rotation
                }
            } else if breakawayBaseAxis != .zero {
                // Recompute delta from the breakaway axis instead of the original grab axis
                let rebDot = simd_clamp(simd_dot(breakawayBaseAxis, currentAxisNorm), -1.0, 1.0)
                let rebCross = simd_cross(breakawayBaseAxis, currentAxisNorm)
                let rebCrossLen = simd_length(rebCross)
                let rebDelta: simd_quatf
                if rebCrossLen > 1e-6 {
                    rebDelta = simd_quatf(angle: acos(rebDot), axis: rebCross / rebCrossLen)
                } else if rebDot < 0 {
                    let perp: SIMD3<Float> = abs(breakawayBaseAxis.x) < 0.9
                        ? simd_normalize(simd_cross(breakawayBaseAxis, SIMD3<Float>(1, 0, 0)))
                        : simd_normalize(simd_cross(breakawayBaseAxis, SIMD3<Float>(0, 1, 0)))
                    rebDelta = simd_quatf(angle: .pi, axis: perp)
                } else {
                    rebDelta = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
                }
                effectiveRotation = (rebDelta * grabStartRotation).normalized
            } else {
                effectiveRotation = (deltaRotation * grabStartRotation).normalized
            }
            
            let newRotation = effectiveRotation
            
            // 3) POSITION: pivot-correct transform
            //    The world-space point under the hand midpoint stays "pinned" as
            //    scale and rotation change around it.
            //    newPos = currentMid + dR.act(scaleRatio × (startPos - startMid))
            let effectiveScaleRatio = clampedScale / max(detailStartScale, 1e-6)
            let startOffset = grabStartPosition - grabStartMidpoint
            let scaledOffset = effectiveScaleRatio * startOffset
            let rotatedOffset = deltaRotation.act(scaledOffset)
            let newPosition = currentMidpoint + rotatedOffset
            
            // DIRECT APPLICATION (intentional dispatcher bypass):
            // Position (SIMD3), rotation (quaternion), and grab-scale are set
            // atomically with no smoothing for 1:1 hand-to-world feel.
            // These bypass ParameterOperationDispatcher because:
            //   - Quaternions need slerp, not scalar lerp
            //   - Grab requires atomic snap (current == target, zeroed velocity)
            //   - The scalar dispatcher is not designed for vector/quat operations
            if settings.isAnimationPlaying {
                settings.manualOffsetPosition = newPosition - settings.animationBasePosition
                // Still need to set rotation/scale directly
                settings.worldRotation = newRotation
                settings.targetWorldRotation = newRotation
                settings.detailScale = clampedScale
                settings.targetDetailScale = clampedScale
            } else {
                settings.applyDetailState(
                    position: newPosition,
                    worldRotation: newRotation,
                    detailScale: clampedScale
                )
                accumulatedPosition = newPosition
            }
            
            // Track hand gesture usage for analytics
            UsageAnalytics.shared.trackHandGestureUsed()
        }
        
        // === GESTURE END ===
        if !bothActive && grabActive {
            grabActive = false
            grabEndCooldown = 0.15  // 150ms cooldown prevents drag from stealing

            // Apply rotation auto-snap on release: sets targetWorldRotation to the
            // nearest 45° aligned orientation (if within snap window), so the slerp
            // in interpolateToTargets() animates smoothly to the snapped pose.
            settings.applyRotationSnap()

            if HAND_TRACKING_DEBUG {
                let reason: String
                if !leftHand.isTracked || !rightHand.isTracked {
                    reason = "hand tracking lost"
                } else if leftPinch < releaseThresh || rightPinch < releaseThresh {
                    reason = "pinch released"
                } else {
                    reason = "hands too far apart"
                }
                print("🤲✊ Two-point GRAB ended (\(reason))")
            }
        }
    }
    
    /// Process a two-hand gesture for a specific finger
    /// Directly sets TARGET values - Renderer handles smoothing
    /// - Parameters:
    ///   - digit: 1=index, 2=middle, 3=ring, 4=pinky
    ///   - state: The gesture state to track
    ///   - currentTarget: The current target value (read from RenderSettings)
    ///   - range: The valid range for the parameter
    ///   - parameterID: Optional parameter node ID for per-parameter sensitivity lookup.
    ///     When nil, no per-parameter sensitivity is applied (spatial 1:1 default).
    ///   - setTarget: Closure to set the new target value
    private func processTwoHandGesture(
        digit: Int,
        state: inout TwoHandGestureState,
        currentTarget: Float,
        range: ClosedRange<Float>,
        parameterID: String? = nil,
        setTarget: (Float) -> Void
    ) {
        guard let settings = renderSettings else { return }
        
        let leftPinch = leftHand.pinchStrength(digit: digit)
        let rightPinch = rightHand.pinchStrength(digit: digit)
        
        // Use lower thresholds for ring finger (harder to pinch)
        let activateThresh = (digit == 3 || digit == 4) ? settings.ringPinchActivateThreshold : settings.twoHandPinchActivateThreshold
        let releaseThresh = (digit == 3 || digit == 4) ? settings.ringPinchReleaseThreshold : settings.twoHandPinchReleaseThreshold
        
        // Measure hand separation (only meaningful if both tracked)
        let leftPos = leftHand.pinchPosition(digit: digit)
        let rightPos = rightHand.pinchPosition(digit: digit)
        
        // Guard against zero positions (tracking glitch)
        let leftPosValid = simd_length_squared(leftPos) > 1e-6
        let rightPosValid = simd_length_squared(rightPos) > 1e-6

        let minHandDistance = settings.gestureMinHandDistance
        let maxHandDistance = max(minHandDistance + 0.05, settings.gestureMaxHandDistance)
        let maxStartHandDistance = settings.gestureMaxStartHandDistance
        let maxActiveHandDistance = max(settings.gestureMaxActiveHandDistance, maxStartHandDistance)
        
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
            // Track starting height (average Y of both hands) for vertical sensitivity scaling
            state.startHeight = (leftPos.y + rightPos.y) * 0.5
            
            if HAND_TRACKING_DEBUG {
                let binding = settings.bindingForDigit(digit)
                let action: FingerGestureAction
                if case .core(let coreAction) = binding {
                    action = coreAction
                } else {
                    action = .none
                }
                let mode = settings.useRelativeGestures ? "RELATIVE" : "ABSOLUTE"
                print("🤲 Two-hand \(action.displayName) gesture STARTED on digit \(digit) (\(mode)), startHeight: \(state.startHeight)")
            }
        }
        
        // Gesture active - set TARGET directly (Renderer smooths to this value)
        if bothActive {
            var hitLimit = false
            var newValue: Float
            
            if settings.useRelativeGestures {
                // RELATIVE: Change based on delta from start distance
                // Sensitivity: 1 = 10x slower (0.1x), 10 = normal (1.0x)
                let baseSensitivityMultiplier = settings.gestureSensitivity / 10.0
                
                // VERTICAL SENSITIVITY SCALING:
                // Lowering hands while spreading decreases sensitivity logarithmically.
                // 1 meter drop = 100x decrease in sensitivity (log scale).
                // Formula: multiplier = 10^(-2 * heightDrop) where heightDrop is in meters (0 to 1)
                let currentHeight = (leftPos.y + rightPos.y) * 0.5
                let heightDrop = max(0, state.startHeight - currentHeight)  // Only drops matter, not raises
                let maxDropForScaling: Float = 1.0  // 1 meter = full 100x reduction
                let normalizedDrop = min(heightDrop / maxDropForScaling, 1.0)  // Clamp to 0-1 range
                // Logarithmic scaling: 0m drop = 1x, 0.5m drop = 10x slower, 1m drop = 100x slower
                let verticalScaleFactor = pow(10.0, -2.0 * normalizedDrop)  // Range: 1.0 down to 0.01
                
                // Per-parameter sensitivity: lets users tune how much this specific
                // parameter changes per meter of hand separation.
                let perParamSens = parameterID.map { GestureSensitivityStore.shared.sensitivity(for: $0) } ?? 1.0
                let sensitivityMultiplier = baseSensitivityMultiplier * verticalScaleFactor * perParamSens
                
                let rangeSpan = range.upperBound - range.lowerBound
                let distSpan = max(maxHandDistance - minHandDistance, 0.001)
                let sensitivity = (rangeSpan / distSpan) * sensitivityMultiplier
                
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
        }
        
        // Gesture ended
        if !bothActive && state.isActive {
            state.isActive = false
            if HAND_TRACKING_DEBUG {
                let binding = settings.bindingForDigit(digit)
                let action: FingerGestureAction
                if case .core(let coreAction) = binding {
                    action = coreAction
                } else {
                    action = .none
                }
                let reason: String
                if !leftHand.isTracked || !rightHand.isTracked {
                    reason = "hand tracking lost"
                } else if leftPinch < releaseThresh || rightPinch < releaseThresh {
                    reason = "pinch released"
                } else {
                    reason = "hands too far apart"
                }
                print("🤲 Two-hand \(action.displayName) gesture on digit \(digit) ENDED (\(reason))")
            }
        }
    }
    
    /// Right-hand index pinch drag → position translate (XYZ)
    private func processRightIndexDrag() {
        guard let settings = renderSettings else { return }
        let pinchActivateThreshold = settings.twoHandPinchActivateThreshold
        let pinchReleaseThreshold = settings.twoHandPinchReleaseThreshold
        
        // Only if NOT doing a two-hand gesture with index fingers
        // Also block during grab-end cooldown to prevent drag from stealing the gesture
        guard fingerGestureState[1]?.isActive != true && !(grabActive && settings.bindingForDigit(1) == .core(.grab)) && grabEndCooldown <= 0 else {
            rightIndexDragActive = false
            return
        }
        
        // Check if left hand is attempting ANY pinch (user likely wants two-hand gesture)
        // This prevents drag from starting when user is setting up a two-hand pull-apart
        let leftAttemptingPinch = leftHand.isTracked && (
            leftHand.indexPinch >= 0.4 ||   // Index approaching pinch
            leftHand.middlePinch >= 0.4 ||  // Middle approaching pinch
            leftHand.ringPinch >= 0.3 ||    // Ring (lower threshold)
            leftHand.pinkyPinch >= 0.3      // Pinky (lower threshold)
        )
        
        let rightPinch = rightHand.indexPinch
        let active: Bool
        if rightIndexDragActive {
            // Once active, only left pinch causes immediate cancel
            active = rightHand.isTracked && rightPinch >= pinchReleaseThreshold && !leftAttemptingPinch
        } else {
            // Don't start drag if left hand is attempting any pinch
            active = rightHand.isTracked && rightPinch >= pinchActivateThreshold && !leftAttemptingPinch
        }
        
        // Gesture started
        if active && !rightIndexDragActive {
            rightIndexDragActive = true
            rightIndexDragStartPos = settings.effectiveTargetPosition
            rightIndexPrevPos = rightHand.pinchPosition(digit: 1)
            rightIndexPrevPalm = rightHand.palmPosition
            accumulatedPosition = settings.effectiveTargetPosition
            smoothedDragSpeed = 0.0  // Reset asymmetric smoothing on new gesture
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
            let deltaLength = simd_length(rawDelta)
            
            // === GMT-FRACTALS PATTERN: Asymmetric Smoothed Speed ===
            // Like CameraController.ts's smoothedDistEstimate (L34):
            // - Instant response when DECELERATING (user wants precision/stop)
            // - Lerped response when ACCELERATING (prevents jarring speed-ups)
            // This gives snappy stops with smooth speed ramp-ups.
            // NOTE: On gesture start, smoothedDragSpeed is 0 — initialize directly
            // from the first movement to avoid a dead-feeling cold-start ramp.
            let dt: Float = 1.0 / 90.0  // Approximate frame time at 90Hz
            if smoothedDragSpeed < 1e-8 {
                // First active frame after gesture start: seed from actual movement
                smoothedDragSpeed = deltaLength
            } else if deltaLength < smoothedDragSpeed {
                // Deceleration: instant response (safety, precision)
                smoothedDragSpeed = deltaLength
            } else {
                // Acceleration: lerp toward target (smooth ramp-up)
                let smoothing = max(0.0, min(1.0, settings.gestureSmoothingFactor))
                let lerpRate = 40.0 - (36.0 * smoothing) // 40 (snappy) -> 4 (very smooth)
                let lerpFactor = 1.0 - exp(-lerpRate * dt)
                smoothedDragSpeed += (deltaLength - smoothedDragSpeed) * lerpFactor
            }
            
            // Non-linear velocity response for flicking:
            // - Slow movements (< threshold): linear with base multiplier
            // - Fast movements: exponential boost for responsive flicking
            // Uses smoothedDragSpeed for the magnitude scaling (asymmetric smoothed)
            let slowThreshold: Float = 0.002  // 2mm/frame threshold
            let maxStep: Float = 0.30         // 30cm per frame cap
            let baseMultiplier: Float = 2.0   // Even slow movements get 2x boost
            
            var scaledDelta: SIMD3<Float>
            if deltaLength > 0 {
                let direction = rawDelta / deltaLength
                var scaledLength: Float
                
                // Use smoothedDragSpeed for the magnitude curve (asymmetric smoothing)
                // but keep the direction from rawDelta (no direction smoothing)
                let effectiveSpeed = smoothedDragSpeed
                
                if effectiveSpeed <= slowThreshold {
                    // Slow movement: boosted linear response
                    scaledLength = effectiveSpeed * baseMultiplier
                } else {
                    // Fast movement: apply acceleration curve
                    let excess = effectiveSpeed - slowThreshold
                    let boost: Float = 8.0   // Higher amplification
                    let power: Float = 1.1   // Gentler curve so it kicks in sooner
                    scaledLength = (slowThreshold * baseMultiplier) + pow(excess, power) * boost
                }
                
                // Cap at maximum
                scaledLength = min(scaledLength, maxStep)
                scaledDelta = direction * scaledLength
            } else {
                scaledDelta = .zero
            }

            // Apply translation (world space) to target.
            // Direct write (intentional dispatcher bypass) — position is a SIMD3 vector,
            // not a scalar parameter. See grab gesture for rationale.
            //
            // Scale inversely with detailScale so translation feels consistent:
            // - Zoomed in (large detailScale)  -> slower translation (more precision)
            // - Zoomed out (small detailScale) -> faster translation (more coverage)
            // Clamp range to avoid extreme behavior at very small/large scales.
            let zoomCompensation = simd_clamp(1.0 / max(settings.detailScale, 0.01), 0.2, 5.0)
            accumulatedPosition = accumulatedPosition + scaledDelta * settings.translationSensitivity * zoomCompensation
            if settings.isAnimationPlaying {
                settings.manualOffsetPosition = accumulatedPosition - settings.animationBasePosition
            } else {
                settings.targetPosition = accumulatedPosition
            }
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
    
}
