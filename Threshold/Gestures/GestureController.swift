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

private let customFractalDefaultsKey = "customFractalDefaults.v1"

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

// MARK: - Grab Zoom Mapping

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
        let currentMidpoint = (leftPos + rightPos) * 0.5
        let currentDistance = simd_length(leftPos - rightPos)
        let currentAxis = rightPos - leftPos
        let currentAxisLen = simd_length(currentAxis)
        let currentAxisNorm = currentAxisLen > 1e-4 ? currentAxis / currentAxisLen : startAxis

        // 1) SCALE — true 1:1 ratio of hand separation
        let scaleRatio = currentDistance / startDistance
        let newDetailScale = simd_clamp(startDetailScale * scaleRatio,
                                        scaleClamp.lowerBound, scaleClamp.upperBound)
        let effectiveScaleRatio = newDetailScale / max(startDetailScale, 1e-6)

        // 2) ROTATION — quaternion from start axis → current axis
        let deltaRotation = Self.quaternionBetweenAxes(from: startAxis, to: currentAxisNorm)
        let newRotation = (deltaRotation * startRotation).normalized

        // 3) POSITION — midpoint-grounded pivot
        let startOffset = startPosition - startMidpoint
        let scaledOffset = effectiveScaleRatio * startOffset
        let rotatedOffset = deltaRotation.act(scaledOffset)
        let newPosition = currentMidpoint + rotatedOffset

        return (newPosition, newRotation, newDetailScale)
    }

    /// Scale-only evaluation: rotation stays at startRotation (pre-breakaway phase).
    func evaluateScaleOnly(leftPos: SIMD3<Float>, rightPos: SIMD3<Float>,
                           scaleClamp: ClosedRange<Float> = 0.001...500.0
    ) -> (position: SIMD3<Float>, rotation: simd_quatf, detailScale: Float) {
        let currentMidpoint = (leftPos + rightPos) * 0.5
        let currentDistance = simd_length(leftPos - rightPos)

        // 1) SCALE — true 1:1 ratio
        let scaleRatio = currentDistance / startDistance
        let newDetailScale = simd_clamp(startDetailScale * scaleRatio,
                                        scaleClamp.lowerBound, scaleClamp.upperBound)
        let effectiveScaleRatio = newDetailScale / max(startDetailScale, 1e-6)

        // 2) ROTATION — identity delta (no rotation change)
        let newRotation = startRotation

        // 3) POSITION — midpoint-grounded pivot, no rotation component
        let startOffset = startPosition - startMidpoint
        let scaledOffset = effectiveScaleRatio * startOffset
        let newPosition = currentMidpoint + scaledOffset

        return (newPosition, newRotation, newDetailScale)
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

    private struct StoredFractalDefaults: Codable {
        var minDistance: Float
        var foldingLimit: Float
        var sphereRadius: Float
        var fractalScale: Float
        var formulaParamsData: Data
        var detailScale: Float
        var position: [Float]
        var worldRotation: [Float]
        var safetyBubbleEnabled: Bool?
    }
    
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

    private func makeFactoryDefaults(for fractalType: FractalModelType, ranges: FractalParamRanges) -> StoredFractalDefaults {
        var formulaParams = fractalType.defaultFormulaParams()
        let identity = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        var detailScale: Float = 1.0
        var position = SIMD3<Float>.zero
        var rotation = identity
        var safetyBubbleEnabled: Bool? = nil

        if fractalType == .mandelbulb {
            let qx = simd_quatf(angle: .pi, axis: SIMD3<Float>(1, 0, 0))
            let qy = simd_quatf(angle: 75.0 * .pi / 180.0, axis: SIMD3<Float>(0, 1, 0))
            let qz = simd_quatf(angle: .pi, axis: SIMD3<Float>(0, 0, 1))
            rotation = simd_normalize(qz * qy * qx)
            detailScale = 0.25
            position = SIMD3<Float>(0.1, 0.1, -0.9)
            safetyBubbleEnabled = false
        }

        FormulaCatalog.normalizeRotationFlags(&formulaParams)
        return StoredFractalDefaults(
            minDistance: ranges.defaultMinDistance,
            foldingLimit: ranges.defaultFoldingLimit,
            sphereRadius: ranges.defaultSphereRadius,
            fractalScale: ranges.defaultFractalScale,
            formulaParamsData: Self.serializeFormulaParams(formulaParams),
            detailScale: detailScale,
            position: [position.x, position.y, position.z],
            worldRotation: [rotation.vector.x, rotation.vector.y, rotation.vector.z, rotation.vector.w],
            safetyBubbleEnabled: safetyBubbleEnabled
        )
    }

    private static func serializeFormulaParams(_ formulaParams: FormulaParams) -> Data {
        var copy = formulaParams
        return withUnsafeBytes(of: &copy) { Data($0) }
    }

    private static func deserializeFormulaParams(_ data: Data) -> FormulaParams? {
        let size = MemoryLayout<FormulaParams>.size
        guard data.count == size else { return nil }
        var formulaParams = FormulaParams()
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            memcpy(&formulaParams, baseAddress, size)
        }
        FormulaCatalog.normalizeRotationFlags(&formulaParams)
        return formulaParams
    }

    private func loadStoredDefaultsMap() -> [String: StoredFractalDefaults] {
        guard let data = UserDefaults.standard.data(forKey: customFractalDefaultsKey) else { return [:] }
        return (try? JSONDecoder().decode([String: StoredFractalDefaults].self, from: data)) ?? [:]
    }

    private func saveStoredDefaultsMap(_ defaultsMap: [String: StoredFractalDefaults]) {
        guard let data = try? JSONEncoder().encode(defaultsMap) else { return }
        UserDefaults.standard.set(data, forKey: customFractalDefaultsKey)
    }

    private func applyStoredDefaults(_ stored: StoredFractalDefaults, to settings: RenderSettings) {
        settings.targetMinDistance = stored.minDistance
        settings.targetFoldingLimit = stored.foldingLimit
        settings.targetSphereRadius = stored.sphereRadius
        settings.targetFractalScale = stored.fractalScale

        settings.minDistance = stored.minDistance
        settings.foldingLimit = stored.foldingLimit
        settings.sphereRadius = stored.sphereRadius
        settings.fractalScale = stored.fractalScale

        if let formulaParams = Self.deserializeFormulaParams(stored.formulaParamsData) {
            settings.formulaParams = formulaParams
        }

        if stored.position.count == 3 {
            let position = SIMD3<Float>(stored.position[0], stored.position[1], stored.position[2])
            settings.position = position
            settings.targetPosition = position
        }

        if stored.worldRotation.count == 4 {
            let rotation = simd_quatf(ix: stored.worldRotation[0],
                                      iy: stored.worldRotation[1],
                                      iz: stored.worldRotation[2],
                                      r: stored.worldRotation[3]).normalized
            settings.worldRotation = rotation
            settings.targetWorldRotation = rotation
        }

        settings.detailScale = stored.detailScale
        settings.targetDetailScale = stored.detailScale

        if let safetyBubbleEnabled = stored.safetyBubbleEnabled {
            settings.safetyBubbleEnabled = safetyBubbleEnabled
        }
    }

    @discardableResult
    func saveCurrentAsFractalDefaults() -> Bool {
        guard let settings = renderSettings else { return false }

        let fractalType = settings.fractalType
        let stored = StoredFractalDefaults(
            minDistance: settings.minDistance,
            foldingLimit: settings.foldingLimit,
            sphereRadius: settings.sphereRadius,
            fractalScale: settings.fractalScale,
            formulaParamsData: Self.serializeFormulaParams(settings.formulaParams),
            detailScale: settings.detailScale,
            position: [settings.position.x, settings.position.y, settings.position.z],
            worldRotation: [settings.worldRotation.vector.x,
                            settings.worldRotation.vector.y,
                            settings.worldRotation.vector.z,
                            settings.worldRotation.vector.w],
            safetyBubbleEnabled: settings.safetyBubbleEnabled
        )

        var defaultsMap = loadStoredDefaultsMap()
        defaultsMap[String(fractalType.rawValue)] = stored
        saveStoredDefaultsMap(defaultsMap)
        return true
    }
    
    /// When true, parameter-changing gestures (two-hand pinch, single-hand drag) are
    /// suppressed so that pinching to interact with the SwiftUI menu window does not
    /// also move through the fractal.  Menu toggle gesture is intentionally kept active.
    var suppressParameterGestures: Bool = false
    
    // Hand tracking state
    private var leftHand: HandData = .zero
    private var rightHand: HandData = .zero
    
    // Two-hand gesture states — one per finger (index/middle/ring), action-agnostic.
    // The action each finger performs is read from RenderSettings at dispatch time.
    private var fingerGestureState: [Int: TwoHandGestureState] = [
        1: TwoHandGestureState(),   // index
        2: TwoHandGestureState(),   // middle
        3: TwoHandGestureState(),   // ring
    ]
    
    // === TWO-POINT GRAB STATE ===
    private var grabActive: Bool = false
    private var grabEndCooldown: Float = 0
    private var grabMapping: GrabZoomMapping?
    private var grabOriginalAxis: SIMD3<Float> = .zero
    private var rotationBrokenAway: Bool = false
    
    // === UNIFIED SINGLE-HAND DRAG STATE (per GestureSlot) ===
    struct SingleHandDragState {
        var isActive: Bool = false
        var prevPos: SIMD3<Float> = .zero
        var prevPalm: SIMD3<Float> = .zero
        var startValues: SIMD3<Float> = .zero   // for triplets
        var startValue: Float = 0                // for scalars
        var accumulatedPosition: SIMD3<Float> = .zero  // for translate
    }
    private var singleHandDragState: [String: SingleHandDragState] = [:]
    
    // Accumulated position from drag gestures (shared for translate bindings)
    private var accumulatedPosition: SIMD3<Float> = .zero

    // Left hand tracking stability: prevents two-hand gesture false triggers when
    // the left hand briefly enters ARKit's tracking field without the user intending
    // to perform a two-hand gesture.  The left hand must be continuously tracked
    // for a minimum number of frames before it can participate.
    private var leftHandStableFrames: Int = 0
    private var leftHandWasTracked: Bool = false
    /// Minimum frames left hand must be continuously tracked before two-hand gestures activate (~0.33s at 90Hz)
    private static let leftHandStabilityThreshold: Int = 30
    
    // === GMT-FRACTALS: Asymmetric Smoothed Gesture Speed ===
    // === MENU TOGGLE GESTURE STATE (Right hand, configurable mode) ===
    private var menuToggleActive: Bool = false
    private var menuToggleHoldTimer: Float = 0
    private var menuToggleCooldown: Float = 0  // Prevent rapid toggling
    
    /// True when the left hand has been continuously tracked long enough to
    /// participate in two-hand gestures.  This prevents false triggers when the
    /// hand briefly enters ARKit's field of view.
    private var leftHandStable: Bool {
        leftHandStableFrames >= Self.leftHandStabilityThreshold
    }
    
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
        for digit in 1...3 { fingerGestureState[digit] = TwoHandGestureState() }
        grabActive = false
        grabEndCooldown = 0
        grabMapping = nil
        singleHandDragState.removeAll()
        menuToggleActive = false
        menuToggleHoldTimer = 0
        menuToggleCooldown = 0
        
    }
    
    /// Apply default parameter values for the current fractal type.
    /// Call this when switching fractal types to get good starting values.
    func applyFractalDefaults() {
        guard let settings = renderSettings else { return }
        let ranges = currentRanges()
        let defaultsMap = loadStoredDefaultsMap()
        let storedDefaults = defaultsMap[String(settings.fractalType.rawValue)]
            ?? makeFactoryDefaults(for: settings.fractalType, ranges: ranges)
        applyStoredDefaults(storedDefaults, to: settings)
        
        // Reset gesture states
        syncWithSettings()
        
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
        
        // Track left hand stability: count continuous frames of tracking.
        // Resets when the left hand disappears from tracking.
        if leftHand.isTracked {
            if !leftHandWasTracked {
                leftHandStableFrames = 0  // Just appeared — reset counter
            }
            leftHandStableFrames = min(leftHandStableFrames + 1, Self.leftHandStabilityThreshold + 1)
        } else {
            leftHandStableFrames = 0
        }
        leftHandWasTracked = leftHand.isTracked
        
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
            }
            menuToggleHoldTimer = 0
            return
        }

        let mode = settings.menuToggleGestureMode
        let strength = menuToggleStrength(for: mode)
        let thresholds = menuToggleThresholds(for: mode, settings: settings)

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
                    onMenuToggle?()
                }
            }
        } else {
            if menuToggleActive {
                menuToggleActive = false
            }
            menuToggleHoldTimer = 0
        }
    }
    
    // MARK: - Gesture Processing
    
    private func processGestures() {
        guard let settings = renderSettings else { return }
        
        // ── Suppress parameter gestures while the user is interacting with the menu window ──
        if suppressParameterGestures {
            for digit in 1...3 {
                if fingerGestureState[digit]?.isActive == true { fingerGestureState[digit]?.isActive = false }
            }
            if grabActive { grabActive = false; grabMapping = nil }
            for key in singleHandDragState.keys { singleHandDragState[key]?.isActive = false }
            settings.activeGestureIndex = 0
            settings.isGeometryGestureActive = false
            return
        }

        var activeDigit = 0
        let ranges = currentRanges()
        
        // ── 1. BOTH-HAND GESTURE DISPATCH (two-hand pull-apart) ─────────
        for digit in 1...3 {
            let binding = settings.binding(forHand: .both, digit: digit)

            // Runtime conflict guard: skip if any single-hand drag is active for this digit
            guard let finger = FingerDigit(rawValue: digit) else { continue }
            let leftKey = GestureSlot(hand: .left, finger: finger).persistenceKey
            let rightKey = GestureSlot(hand: .right, finger: finger).persistenceKey
            if singleHandDragState[leftKey]?.isActive == true ||
               singleHandDragState[rightKey]?.isActive == true {
                if fingerGestureState[digit]?.isActive == true {
                    fingerGestureState[digit]?.isActive = false
                }
                continue
            }

            if case .parameter(let descriptor) = binding,
               let formulaIndex = descriptor.formulaIndex,
               let node = ParameterNodeRegistry.shared.node(for: descriptor) {
                guard fingerGestureState[digit] != nil else { continue }
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
                        frameIndex: self.operationFrameCounter,
                        smoothing: .init()
                    )
                    self.operationDispatcher.dispatch(
                        ParameterTransaction(frameIndex: self.operationFrameCounter, operations: [op]),
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
                guard settings.fractalType == .mandelbox else {
                    if fingerGestureState[digit]?.isActive == true {
                        fingerGestureState[digit]?.isActive = false
                    }
                    continue
                }
                processMandelboxShapeGesture(digit: digit, action: action, ranges: ranges, settings: settings, activeDigit: &activeDigit)

            case .fractalScale:
                processCoreScaleGesture(digit: digit, ranges: ranges, settings: settings, activeDigit: &activeDigit)
                
            case .none, .translate:
                // translate is only valid for single-hand; deactivate any stale two-hand state
                if fingerGestureState[digit]?.isActive == true {
                    fingerGestureState[digit]?.isActive = false
                }
            }
        }
        
        // ── 2. LEFT-HAND SINGLE-HAND GESTURES ──────────────────────────
        for digit in 1...3 {
            guard let finger = FingerDigit(rawValue: digit) else { continue }
            let slot = GestureSlot(hand: .left, finger: finger)
            let binding = settings.binding(for: slot)
            processSingleHandDrag(slot: slot, hand: leftHand, binding: binding, settings: settings, activeDigit: &activeDigit)
        }

        // ── 3. RIGHT-HAND SINGLE-HAND GESTURES ─────────────────────────
        for digit in 1...3 {
            guard let finger = FingerDigit(rawValue: digit) else { continue }
            let slot = GestureSlot(hand: .right, finger: finger)
            let binding = settings.binding(for: slot)
            processSingleHandDrag(slot: slot, hand: rightHand, binding: binding, settings: settings, activeDigit: &activeDigit)
        }

        // Update active gesture for HUD
        settings.activeGestureIndex = activeDigit
        
        // Wire geometry gesture flag
        let anySingleHandActive = singleHandDragState.values.contains { $0.isActive }
        let anyGeometryGestureActive = grabActive || anySingleHandActive ||
            (1...3).contains(where: { fingerGestureState[$0]?.isActive == true })
        settings.isGeometryGestureActive = anyGeometryGestureActive
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
    ///
    /// **1:1 SCALING**: hand separation ratio maps directly to detailScale.
    ///   10 cm → 50 cm apart = 5× zoom, no deadzone, no attenuation.
    ///
    /// **MIDPOINT GROUNDING**: the world-space point under the hand midpoint at
    ///   gesture start stays pinned to wherever the midpoint moves. Scale and
    ///   rotation expand/twist around that anchor.
    ///
    /// **PRE-COMPUTED MAPPING** (`GrabZoomMapping`): captured once at gesture start,
    ///   it encodes the inverse map from hand positions → fractal transform.
    ///   Each frame, `mapping.evaluate(hands)` produces the target transform.
    ///   At rotation breakaway the mapping is rebased to the current state.
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
            // Already active — use release thresholds, no stability requirement
            bothActive = leftHand.isTracked && rightHand.isTracked &&
                         leftPosValid && rightPosValid &&
                         currentDistance <= maxActiveHandDistance &&
                         leftPinch >= releaseThresh &&
                         rightPinch >= releaseThresh
        } else {
            // Not active — require left hand to be stably tracked to prevent
            // false triggers when the left hand briefly enters the FOV.
            bothActive = leftHandStable && rightHand.isTracked &&
                         leftPosValid && rightPosValid &&
                         currentDistance <= maxStartHandDistance &&
                         leftPinch >= activateThresh &&
                         rightPinch >= activateThresh
        }
        
        // === GESTURE START ===
        if bothActive && !grabActive {
            grabActive = true
            
            // Capture CURRENT values (what's visually shown), not targets.
            // Build the pre-computed inverse mapping from gesture → fractal space.
            grabMapping = GrabZoomMapping(
                leftPos: leftPos, rightPos: rightPos,
                position: settings.position,
                rotation: settings.worldRotation,
                detailScale: settings.detailScale
            )
            grabOriginalAxis = grabMapping!.startAxis
            rotationBrokenAway = !settings.rotationAutoSnap  // If snap disabled, act as if already broken away
            
        }
        
        // === GESTURE ACTIVE ===
        if bothActive && grabActive, var mapping = grabMapping {
            
            // ── Rotation breakaway gate ──────────────────────────────────
            // Rotation is suppressed until the hand axis diverges enough from
            // the original start axis. On breakaway, rebase the entire mapping
            // to the current state so scale+position+rotation all continue
            // smoothly from here with no jump.
            if !rotationBrokenAway {
                let currentAxis = rightPos - leftPos
                let currentAxisLen = simd_length(currentAxis)
                let currentAxisNorm = currentAxisLen > 1e-4 ? currentAxis / currentAxisLen : grabOriginalAxis
                let dot = simd_clamp(simd_dot(grabOriginalAxis, currentAxisNorm), -1.0, 1.0)
                let breakawayAngleRad = acos(dot)
                let breakawayThresholdRad = settings.rotationBreakawayDegrees * (.pi / 180.0)
                
                if breakawayAngleRad >= breakawayThresholdRad {
                    rotationBrokenAway = true
                    // Rebase: snapshot current state as the new baseline for
                    // the mapping so rotation, scale, and position all start
                    // from the current values — no jump.
                    mapping.rebase(
                        leftPos: leftPos, rightPos: rightPos,
                        position: settings.position,
                        rotation: settings.worldRotation,
                        detailScale: settings.detailScale
                    )
                    grabMapping = mapping
                }
            }
            
            // ── Per-fractal scale clamp ─────────────────────────────────
            // Mandelbulb starts at detailScale 0.25 and needs deep zoom;
            // give it a much wider clamp range.
            let scaleClamp: ClosedRange<Float> = (settings.fractalType == .mandelbulb)
                ? 0.0005...2000.0
                : 0.001...500.0

            // ── Evaluate the mapping ─────────────────────────────────────
            let result: (position: SIMD3<Float>, rotation: simd_quatf, detailScale: Float)
            if rotationBrokenAway {
                result = mapping.evaluate(leftPos: leftPos, rightPos: rightPos, scaleClamp: scaleClamp)
            } else {
                result = mapping.evaluateScaleOnly(leftPos: leftPos, rightPos: rightPos, scaleClamp: scaleClamp)
            }
            
            // ── Apply to render settings ─────────────────────────────────
            // Direct application (intentional dispatcher bypass):
            // Position (SIMD3), rotation (quaternion), and grab-scale bypass
            // ParameterOperationDispatcher because quaternions need slerp,
            // and grab requires 1:1 tracking, not scalar lerp.
            if settings.isAnimationPlaying {
                settings.manualOffsetPosition = result.position - settings.animationBasePosition
                settings.worldRotation = result.rotation
                settings.targetWorldRotation = result.rotation
                settings.detailScale = result.detailScale
                settings.targetDetailScale = result.detailScale
            } else {
                settings.applyDetailState(
                    position: result.position,
                    worldRotation: result.rotation,
                    detailScale: result.detailScale,
                    responsiveness: 1.0  // Near-direct 1:1 tracking
                )
                accumulatedPosition = result.position
            }
            
            UsageAnalytics.shared.trackHandGestureUsed()
        }
        
        // === GESTURE END ===
        if !bothActive && grabActive {
            grabActive = false
            grabMapping = nil
            grabEndCooldown = 0.15  // 150ms cooldown prevents drag from stealing

            // Apply rotation auto-snap on release
            settings.applyRotationSnap()

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
            // Not active - require left hand to be stably tracked (prevents
            // false triggers when it briefly enters ARKit's FOV).
            bothActive = leftHandStable && rightHand.isTracked &&
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
        }
    }
    
    // MARK: - Unified Single-Hand Drag

    /// Unified single-hand pinch-drag handler for any hand+finger slot.
    /// Handles .translate (position), .parameterTriplet (xyz), .parameter (1D scalar),
    /// and skips .core(.none) or unsupported bindings.
    private func processSingleHandDrag(
        slot: GestureSlot,
        hand: HandData,
        binding: GestureActionBinding,
        settings: RenderSettings,
        activeDigit: inout Int
    ) {
        let key = slot.persistenceKey
        let digit = slot.finger.rawValue
        let activateThresh = settings.twoHandPinchActivateThreshold
        let releaseThresh = settings.twoHandPinchReleaseThreshold

        // Skip unassigned slots
        if case .core(.none) = binding { 
            singleHandDragState[key]?.isActive = false
            return
        }

        // Block if BOTH-hand two-hand gesture is active for this digit
        if fingerGestureState[digit]?.isActive == true {
            singleHandDragState[key]?.isActive = false
            return
        }

        // Block during grab-end cooldown
        if grabEndCooldown > 0 || grabActive {
            singleHandDragState[key]?.isActive = false
            return
        }

        // Check if the OTHER hand is attempting any pinch (likely a two-hand gesture)
        let otherHand = (slot.hand == .right) ? leftHand : rightHand
        let otherAttemptingPinch = otherHand.isTracked && (
            otherHand.indexPinch >= 0.55 ||
            otherHand.middlePinch >= 0.55 ||
            otherHand.ringPinch >= 0.45
        )

        let pinch = hand.pinchStrength(digit: digit)
        var state = singleHandDragState[key] ?? SingleHandDragState()
        let active: Bool
        if state.isActive {
            active = hand.isTracked && pinch >= releaseThresh && !otherAttemptingPinch
        } else {
            active = hand.isTracked && pinch >= activateThresh && !otherAttemptingPinch
        }

        // ── Handle by binding type ──────────────────────────────────────
        switch binding {
        case .core(.translate):
            // Position XYZ pinch-drag (previously processRightIndexDrag)
            if active && !state.isActive {
                state.isActive = true
                state.accumulatedPosition = settings.effectiveTargetPosition
                accumulatedPosition = settings.effectiveTargetPosition
                state.prevPos = hand.pinchPosition(digit: digit)
                state.prevPalm = hand.palmPosition
            }
            if active && state.isActive {
                var currentPos = hand.palmPosition
                if simd_length_squared(currentPos) == 0 { currentPos = hand.pinchPosition(digit: digit) }
                var previousPos = state.prevPalm
                if simd_length_squared(previousPos) == 0 { previousPos = state.prevPos }

                let rawDelta = currentPos - previousPos
                let deltaLength = simd_length(rawDelta)
                let maxStep: Float = 0.30
                let baseMultiplier: Float = 3.0

                var scaledDelta: SIMD3<Float> = .zero
                if deltaLength > 0 {
                    let direction = rawDelta / deltaLength
                    scaledDelta = direction * min(deltaLength * baseMultiplier, maxStep)
                }

                let maxZoomCompensation: Float = (settings.fractalType == .mandelbulb) ? 2.0 : 3.0
                let zoomCompensation = simd_clamp(1.0 / sqrt(max(settings.detailScale, 0.01)), 0.35, maxZoomCompensation)
                accumulatedPosition = accumulatedPosition + scaledDelta * settings.translationSensitivity * zoomCompensation
                if settings.isAnimationPlaying {
                    settings.manualOffsetPosition = accumulatedPosition - settings.animationBasePosition
                } else {
                    settings.targetPosition = accumulatedPosition
                }
                state.prevPos = currentPos
                state.prevPalm = currentPos
                activeDigit = digit
            }
            if !active && state.isActive { state.isActive = false }

        case .parameterTriplet(let triplet):
            // XYZ triplet pinch-drag
            if active && !state.isActive {
                state.isActive = true
                let fp = settings.formulaParams
                state.startValues = SIMD3<Float>(
                    FormulaCatalog.getParam(fp, index: triplet.xFormulaIndex),
                    FormulaCatalog.getParam(fp, index: triplet.yFormulaIndex),
                    FormulaCatalog.getParam(fp, index: triplet.zFormulaIndex)
                )
                state.prevPos = hand.pinchPosition(digit: digit)
            }
            if active && state.isActive {
                let currentPos = hand.pinchPosition(digit: digit)
                let rawDelta = currentPos - state.prevPos
                let deltaLength = simd_length(rawDelta)
                let maxStep: Float = 0.15
                let sensitivity = settings.gestureSensitivity
                let rangeSpan = triplet.range.upperBound - triplet.range.lowerBound

                if deltaLength > 0 {
                    let direction = rawDelta / deltaLength
                    let scaledDelta = direction * min(deltaLength * sensitivity, maxStep) * rangeSpan

                    state.startValues.x = simd_clamp(state.startValues.x + scaledDelta.x, triplet.range.lowerBound, triplet.range.upperBound)
                    state.startValues.y = simd_clamp(state.startValues.y + scaledDelta.y, triplet.range.lowerBound, triplet.range.upperBound)
                    state.startValues.z = simd_clamp(state.startValues.z + scaledDelta.z, triplet.range.lowerBound, triplet.range.upperBound)

                    let ops = [
                        ParameterOperation(targetID: triplet.xNodeID, source: .gesture, value: .absolute(state.startValues.x), frameIndex: operationFrameCounter, smoothing: .init()),
                        ParameterOperation(targetID: triplet.yNodeID, source: .gesture, value: .absolute(state.startValues.y), frameIndex: operationFrameCounter, smoothing: .init()),
                        ParameterOperation(targetID: triplet.zNodeID, source: .gesture, value: .absolute(state.startValues.z), frameIndex: operationFrameCounter, smoothing: .init()),
                    ]
                    operationDispatcher.dispatch(
                        ParameterTransaction(frameIndex: operationFrameCounter, operations: ops),
                        settings: settings
                    )
                    UsageAnalytics.shared.trackHandGestureUsed()
                }
                state.prevPos = currentPos
                activeDigit = digit
            }
            if !active && state.isActive { state.isActive = false }

        case .parameter(let descriptor):
            // 1D scalar pinch-drag (vertical movement → parameter value)
            guard let formulaIndex = descriptor.formulaIndex,
                  let node = ParameterNodeRegistry.shared.node(for: descriptor) else {
                state.isActive = false
                singleHandDragState[key] = state
                return
            }
            if active && !state.isActive {
                state.isActive = true
                state.startValue = FormulaCatalog.getParam(settings.formulaParams, index: formulaIndex)
                state.prevPos = hand.pinchPosition(digit: digit)
            }
            if active && state.isActive {
                let currentPos = hand.pinchPosition(digit: digit)
                let verticalDelta = currentPos.y - state.prevPos.y
                let sensitivity = settings.gestureSensitivity
                let rangeSpan = node.range.upperBound - node.range.lowerBound
                let maxStep: Float = 0.15

                let scaledDelta = simd_clamp(verticalDelta * sensitivity * rangeSpan, -maxStep * rangeSpan, maxStep * rangeSpan)
                state.startValue = simd_clamp(state.startValue + scaledDelta, node.range.lowerBound, node.range.upperBound)

                let op = ParameterOperation(
                    targetID: node.id,
                    source: .gesture,
                    value: .absolute(state.startValue),
                    frameIndex: operationFrameCounter,
                    smoothing: .init()
                )
                operationDispatcher.dispatch(
                    ParameterTransaction(frameIndex: operationFrameCounter, operations: [op]),
                    settings: settings
                )
                UsageAnalytics.shared.trackHandGestureUsed()
                state.prevPos = currentPos
                activeDigit = digit
            }
            if !active && state.isActive { state.isActive = false }

        default:
            // .core(.grab), .core(.fractalScale), etc. are only valid for both-hand
            state.isActive = false
        }

        singleHandDragState[key] = state
    }
    
}
