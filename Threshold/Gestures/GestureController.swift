//
//  GestureController.swift
//  Threshold
//
//  Two-hand gesture controls for fractal parameters
//
//  Usage:
//  - TWO-HAND PINCH: Pinch with both hands simultaneously
//    Finger-to-action mapping is configurable (see FingerGestureAction).
//    Default: index=grab, middle=minDistance, ring=fractalScale.
//  - SINGLE-HAND PINCH+DRAG: Move one hand while pinching
//    * Right hand index = translate position
//  - RIGHT HAND MENU GESTURE (configurable): Toggle menu visibility
//

import Foundation
#if os(visionOS)
import ARKit
#endif
import simd

// MARK: - Gesture Controller

/// Processes hand tracking data and maps gestures to render parameters
/// 
/// TWO-HAND DESIGN:
/// - Both hands must pinch with the SAME finger to activate a gesture
/// - Parameter scales RELATIVELY: if hands move 2× apart, parameter doubles
/// - Smoothing prevents jitter and provides natural feel
@MainActor
final class GestureController {
    let parameterPipeline: ParameterPipeline
    private var operationFrameCounter: UInt64 = 0
    private let menuToggleEngine = MenuToggleGestureEngine()
    private let perFingerTapEngine = PerFingerTapGestureEngine()
    private let arbitrationEngine = GestureArbitrationEngine()
    private let twoHandScalarEngine = TwoHandScalarGestureEngine()
    private let twoPointGrabEngine = TwoPointGrabEngine()
    private let singleHandDragEngine = SingleHandDragEngine()
    private var windowPullState = WindowPullGestureState()

    // ==========================================================================
    // PER-FRACTAL PARAMETER RANGES  (cached from FractalTypeDescriptor)
    // ==========================================================================

    private var cachedFractalType: FractalModelType?
    private var cachedScaleClamp: ClosedRange<Float> = 0.001...500.0
    private var cachedRanges: GestureParamRanges = .standard
    private var cachedRangesExtended: GestureParamRanges = .extended

    /// Refresh cached descriptor values when the fractal type changes.
    /// Call once per frame (or after preset load) — skips the registry
    /// lookup when the type hasn't changed.
    private func refreshCachedDescriptorValues() {
        guard let settings = renderSettings else { return }
        let current = settings.fractalType
        guard current != cachedFractalType else { return }
        let desc = FractalTypeRegistry.descriptor(for: current)
        cachedScaleClamp = desc.grabScaleClamp
        cachedRanges = desc.gestureRanges
        cachedRangesExtended = desc.gestureRangesExtended
        cachedFractalType = current
    }

    /// Get parameter ranges for current fractal type (from cache).
    private func currentRanges() -> GestureParamRanges {
        guard let settings = renderSettings else { return .standard }
        return settings.extendedGestureRange ? cachedRangesExtended : cachedRanges
    }

    @discardableResult
    func saveCurrentAsFractalDefaults() -> Bool {
        guard let settings = renderSettings else { return false }
        return FractalDefaultsStore.saveCurrentAsFractalDefaults(from: settings)
    }
    
    /// When true, parameter-changing gestures are suppressed so pinching and dragging
    /// menu controls does not also manipulate the scene. Menu toggle remains active
    /// so the gesture can still close or recover the menu window.
    var suppressParameterGestures: Bool = false
    
    // Hand tracking state
    private var leftHand: HandData = .zero
    private var rightHand: HandData = .zero
    
    // State is owned by mode engines; controller coordinates lifecycle only.

    // Left hand tracking stability: prevents two-hand gesture false triggers when
    // the left hand briefly enters ARKit's tracking field without the user intending
    // to perform a two-hand gesture.  The left hand must be continuously tracked
    // for a minimum number of frames before it can participate.
    private var leftHandStableFrames: Int = 0
    private var leftHandWasTracked: Bool = false
    /// Minimum frames left hand must be continuously tracked before two-hand gestures activate (~0.33s at 90Hz)
    private static let leftHandStabilityThreshold: Int = 30
    
    
    /// True when the left hand has been continuously tracked long enough to
    /// participate in two-hand gestures.  This prevents false triggers when the
    /// hand briefly enters ARKit's field of view.
    private var leftHandStable: Bool {
        leftHandStableFrames >= Self.leftHandStabilityThreshold
    }

    private var twoHandStateByDigit: [Int: TwoHandGestureState] {
        get { twoHandScalarEngine.state.perDigit }
        set { twoHandScalarEngine.state.perDigit = newValue }
    }

    private var grabState: TwoPointGrabGestureState {
        get { twoPointGrabEngine.state }
        set { twoPointGrabEngine.state = newValue }
    }

    private var singleHandState: SingleHandDragEngineState {
        get { singleHandDragEngine.state }
        set { singleHandDragEngine.state = newValue }
    }

    
    // Gesture callbacks
    var onMenuToggle: (() -> Void)?
    var onAnimationPlayerToggle: (() -> Void)?
    var onOpenShapeMenu: (() -> Void)?
    var onOpenRenderMenu: (() -> Void)?
    var onMenuWindowPullTowardUser: (() -> Void)?
    
    // Reference to render settings
    private weak var renderSettings: RenderSettings?
    
    init(renderSettings: RenderSettings,
         parameterPipeline: ParameterPipeline) {
        self.renderSettings = renderSettings
        self.parameterPipeline = parameterPipeline
        
        // Initialize drag engine state from current settings
        singleHandDragEngine.reset(accumulatedPosition: renderSettings.position)
    }
    
    func setDebugTraceEnabled(_ enabled: Bool) {
        parameterPipeline.setDebugTraceEnabled(enabled)
    }

    /// Sync internal state with current render settings.
    /// Call this after loading a preset to prevent jumps when gestures resume.
    func syncWithSettings() {
        guard let settings = renderSettings else { return }
        singleHandDragEngine.state.accumulatedPosition = settings.effectiveTargetPosition
        refreshCachedDescriptorValues()
        
        // Reset all gesture states to avoid stale data
        twoHandScalarEngine.reset()
        twoPointGrabEngine.reset()
        singleHandDragEngine.reset(accumulatedPosition: settings.effectiveTargetPosition)
        menuToggleEngine.reset()
        perFingerTapEngine.reset()
        windowPullState = WindowPullGestureState()
    }
    
    /// Apply default parameter values for the current fractal type.
    /// Call this when switching fractal types to get good starting values.
    func applyFractalDefaults() {
        guard let settings = renderSettings else { return }
        FractalDefaultsStore.applyFractalDefaults(for: settings.fractalType, to: settings)
        
        // Reset gesture states
        syncWithSettings()
    }
    
    // MARK: - Hand Tracking Updates
    
    /// Update hand data from ARKit hand anchors.
    /// Called every frame via async dispatch. Sets TARGET values on RenderSettings.
    /// The Renderer's interpolateToTargets() handles smooth animation at 90Hz.
    /// - Parameter deltaTime: Time since last hand tracking update (not used for smoothing anymore)
#if os(visionOS)
    @available(visionOS 2.0, *)
    func updateHands(leftAnchor: HandAnchor?, rightAnchor: HandAnchor?, deltaTime: Float = 1.0/90.0) {
        operationFrameCounter &+= 1
        refreshCachedDescriptorValues()
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
        
        // Update cooldown timers in engine states
        if twoPointGrabEngine.state.endCooldown > 0 {
            twoPointGrabEngine.state.endCooldown = max(0, twoPointGrabEngine.state.endCooldown - deltaTime)
        }
        
        let menuAndMovementOnly = renderSettings?.menuAndMovementOnly ?? false

        // Process all gesture mappings (sets targets on RenderSettings)
        processGestures(menuAndMovementOnly: menuAndMovementOnly)
        
        // Process special gestures
        let context = GestureContext(leftHand: leftHand, rightHand: rightHand, leftHandStable: leftHandStable, suppressParameterGestures: suppressParameterGestures, deltaTime: deltaTime, ranges: currentRanges(), frameIndex: operationFrameCounter)

        // Sync per-finger tap engine config from settings each frame
        if let settings = renderSettings {
            perFingerTapEngine.isEnabled = settings.perFingerTapGestureEnabled
            perFingerTapEngine.leftHandActions = filteredPerFingerTapActions(settings.perFingerTapLeftActions, menuAndMovementOnly: menuAndMovementOnly)
            perFingerTapEngine.rightHandActions = filteredPerFingerTapActions(settings.perFingerTapRightActions, menuAndMovementOnly: menuAndMovementOnly)
            perFingerTapEngine.activateThreshold = settings.perFingerTapActivateThreshold
            perFingerTapEngine.releaseThreshold = settings.perFingerTapReleaseThreshold
            perFingerTapEngine.holdDuration = settings.perFingerTapHoldDuration
            perFingerTapEngine.cooldown = settings.perFingerTapCooldown
        }

        // Run per-finger tap engine (handles both menu and animation-player toggles)
        let tapOps = perFingerTapEngine.process(context: context)
        var didToggleMenu = false
        for op in tapOps {
            switch op {
            case .toggleMenu:
                didToggleMenu = true
                onMenuToggle?()
            case .toggleAnimationPlayer:
                onAnimationPlayerToggle?()
            case .openShapeMenu:
                onOpenShapeMenu?()
            case .openRenderMenu:
                onOpenRenderMenu?()
            default:
                break
            }
        }

        // Menu-toggle engine (supplements per-finger tap)
        if !didToggleMenu, let settings = renderSettings {
            let ops = menuToggleEngine.process(context: context, settings: settings)
            if ops.contains(where: { if case .toggleMenu = $0 { return true } else { return false } }) {
                onMenuToggle?()
            }
        }

        processWindowPullGesture(deltaTime: deltaTime)
    }
#endif

    private func filteredPerFingerTapActions(_ actions: [PerFingerTapAction], menuAndMovementOnly: Bool) -> [PerFingerTapAction] {
        guard menuAndMovementOnly else { return actions }
        return actions.map { $0.isMenuEssentialAction ? $0 : .none }
    }
    
#if os(visionOS)
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

        // Wrist position
        data.wristPosition = jointPosition(.wrist)
        
        // Palm center (average of metacarpals for more accurate palm detection)
        // OPTIMIZATION: Use SIMD addition with single multiply instead of 4 multiplies
        let indexMeta = jointPosition(.indexFingerMetacarpal)
        let middleMeta = jointPosition(.middleFingerMetacarpal)
        let ringMeta = jointPosition(.ringFingerMetacarpal)
        let pinkyMeta = jointPosition(.littleFingerMetacarpal)
        data.palmCenter = (indexMeta + middleMeta + ringMeta + pinkyMeta) * 0.25

        // Palm normal: cross product of two vectors spanning the palm surface.
        // Uses index metacarpal → pinky metacarpal and wrist → middle metacarpal to define the plane.
        let palmEdge1 = pinkyMeta - indexMeta
        let palmEdge2 = middleMeta - data.wristPosition
        let rawNormal = simd_cross(palmEdge1, palmEdge2)
        let normalLen = simd_length(rawNormal)
        data.palmNormal = normalLen > 1e-6 ? rawNormal / normalLen : .zero
        
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
        
        // Index/middle have longer reach (8cm range), ring has shorter reach (6cm range)
        data.indexPinch = calculatePinch(fingerTip: data.indexTip, maxDist: 0.08)
        data.middlePinch = calculatePinch(fingerTip: data.middleTip, maxDist: 0.08)
        data.ringPinch = calculatePinch(fingerTip: data.ringTip, maxDist: 0.06)
        
        return data
    }
        #endif
    
    // MARK: - Special Gesture Processing
    
    private func processWindowPullGesture(deltaTime: Float) {
        guard let settings = renderSettings else { return }

        if windowPullState.cooldown > 0 {
            windowPullState.cooldown = max(0, windowPullState.cooldown - deltaTime)
        }

        if suppressParameterGestures {
            windowPullState.isActive = false
            windowPullState.startPalmPosition = .zero
            windowPullState.hasTriggered = false
            return
        }

        guard rightHand.isTracked,
              simd_length_squared(rightHand.palmPosition) > 1e-6 else {
            windowPullState = WindowPullGestureState(cooldown: windowPullState.cooldown)
            return
        }

        let poseStrength = min(rightHand.middleFingerTouchingPalm(), rightHand.ringFingerTouchingPalm())
        let activateThreshold = max(0.55, settings.menuToggleActivateThreshold)
        let releaseThreshold = max(0.20, min(settings.menuToggleReleaseThreshold, activateThreshold - 0.10))
        let poseActive = windowPullState.isActive
            ? poseStrength >= releaseThreshold
            : poseStrength >= activateThreshold

        guard poseActive else {
            windowPullState.isActive = false
            windowPullState.startPalmPosition = .zero
            windowPullState.hasTriggered = false
            return
        }

        if !windowPullState.isActive {
            windowPullState.isActive = true
            windowPullState.startPalmPosition = rightHand.palmPosition
            windowPullState.hasTriggered = false
            return
        }

        guard windowPullState.cooldown <= 0,
              !windowPullState.hasTriggered else { return }

        let delta = rightHand.palmPosition - windowPullState.startPalmPosition
        let pullTowardUser = delta.z
        let lateralDrift = hypot(delta.x, delta.y)
        if pullTowardUser >= 0.08, pullTowardUser > lateralDrift * 0.75 {
            windowPullState.hasTriggered = true
            windowPullState.cooldown = 0.8
            onMenuWindowPullTowardUser?()
        }
    }
    
    // MARK: - Gesture Processing
    
    private func processGestures(menuAndMovementOnly: Bool) {
        guard let settings = renderSettings else { return }
        
        // ── Suppress parameter gestures while the user is interacting with the menu window ──
        if suppressParameterGestures {
            for digit in 1...3 {
                if twoHandStateByDigit[digit]?.isActive == true { twoHandStateByDigit[digit]?.isActive = false }
            }
            if grabState.isActive { grabState.isActive = false; grabState.mapping = nil }
            for key in singleHandState.perSlot.keys { singleHandState.perSlot[key]?.isActive = false }
            settings.activeGestureIndex = 0
            settings.isGeometryGestureActive = false
            return
        }

        var activeDigit = 0
        let ranges = currentRanges()
        
        // ── 1. BOTH-HAND GESTURE DISPATCH (two-hand pull-apart) ─────────
        for digit in 1...3 {
            let binding = settings.binding(forHand: .both, digit: digit)

            if menuAndMovementOnly && !binding.isMovementBinding {
                if twoHandStateByDigit[digit]?.isActive == true {
                    twoHandStateByDigit[digit]?.isActive = false
                }
                if digit == 1, grabState.isActive {
                    grabState.isActive = false
                    grabState.mapping = nil
                }
                continue
            }

            // Runtime conflict guard: skip if any single-hand drag is active for this digit
            guard let finger = FingerDigit(rawValue: digit) else { continue }
            // Check all directional sub-slots (vertical + horizontal) for each hand.
            let leftActive = GestureDirection.allCases.contains {
                singleHandState.perSlot[GestureSlot(hand: .left, finger: finger, direction: $0).persistenceKey]?.isActive == true
            }
            let rightActive = GestureDirection.allCases.contains {
                singleHandState.perSlot[GestureSlot(hand: .right, finger: finger, direction: $0).persistenceKey]?.isActive == true
            }
            let decision = arbitrationEngine.decide(
                GestureArbitrationInput(
                    digit: digit,
                    twoHandCandidate: true,
                    twoHandCurrentlyActive: twoHandStateByDigit[digit]?.isActive == true,
                    leftSingleActive: leftActive,
                    rightSingleActive: rightActive,
                    grabActive: grabState.isActive,
                    grabEndCooldown: grabState.endCooldown
                )
            )
            if !decision.allowTwoHand {
                if twoHandStateByDigit[digit]?.isActive == true {
                    twoHandStateByDigit[digit]?.isActive = false
                }
                continue
            }

            if case .parameter(let descriptor) = binding,
               let formulaIndex = descriptor.formulaIndex,
               let node = ParameterNodeRegistry.shared.node(for: descriptor) {
                guard var digitState = twoHandStateByDigit[digit] else { continue }
                processTwoHandGesture(
                    digit: digit,
                    state: &digitState,
                    currentTarget: FormulaCatalog.getParam(settings.formulaParams, index: formulaIndex),
                    range: node.range,
                    parameterID: node.id
                ) { newValue in
                    let op = ParameterOperation(
                        targetID: node.id,
                        source: .gesture,
                        value: .absolute(newValue),
                        frameIndex: self.operationFrameCounter,
                        smoothing: ParameterOperationSmoothing(smoothingTime: settings.gestureSmoothing)
                    )
                    self.parameterPipeline.dispatchGesture([op], settings: settings)
                    UsageAnalytics.shared.trackHandGestureUsed()
                }
                twoHandStateByDigit[digit] = digitState
                if digitState.isActive { activeDigit = digit }
                continue
            }

            guard case .core(let action) = binding else {
                if twoHandStateByDigit[digit]?.isActive == true {
                    twoHandStateByDigit[digit]?.isActive = false
                }
                continue
            }

            switch action {
            case .grab:
                processTwoPointGrab(digit: digit)
                if grabState.isActive { activeDigit = digit }
                
            case .minDistance, .foldingLimit, .sphereRadius:
                guard settings.fractalType == .mandelbox else {
                    if twoHandStateByDigit[digit]?.isActive == true {
                        twoHandStateByDigit[digit]?.isActive = false
                    }
                    continue
                }
                processMandelboxShapeGesture(digit: digit, action: action, ranges: ranges, settings: settings, activeDigit: &activeDigit)

            case .fractalScale:
                processCoreScaleGesture(digit: digit, ranges: ranges, settings: settings, activeDigit: &activeDigit)
                
            case .none, .translate:
                // translate is only valid for single-hand; deactivate any stale two-hand state
                if twoHandStateByDigit[digit]?.isActive == true {
                    twoHandStateByDigit[digit]?.isActive = false
                }
            }
        }
        
        // ── 2. SINGLE-HAND GESTURES (left + right, independent) ─────────
        for (handMode, handData) in [(GestureHandMode.left, leftHand), (.right, rightHand)] {
            // Winner-takes-all: find which finger digit (if any) currently owns this hand.
            // Once locked, all other fingers on this hand are blocked from activating
            // until the locked finger fully releases. This prevents index/middle cross-fire.
            let lockedFinger: Int? = (1...3).first { digit in
                guard let f = FingerDigit(rawValue: digit) else { return false }
                return GestureDirection.allCases.contains { dir in
                    let key = GestureSlot(hand: handMode, finger: f, direction: dir).persistenceKey
                    return singleHandState.perSlot[key]?.isActive == true
                }
            }
            for digit in 1...3 {
                guard let finger = FingerDigit(rawValue: digit) else { continue }
                // Process both vertical and horizontal sub-slots for each finger
                for direction in GestureDirection.allCases {
                    let slot = GestureSlot(hand: handMode, finger: finger, direction: direction)
                    let binding = settings.binding(for: slot)
                    processSingleHandDrag(slot: slot, hand: handData, binding: binding,
                                         lockedFinger: lockedFinger,
                                         menuAndMovementOnly: menuAndMovementOnly,
                                         settings: settings, activeDigit: &activeDigit)
                }
            }
        }

        // Update active gesture for HUD
        settings.activeGestureIndex = activeDigit
        
        // Wire geometry gesture flag
        let anySingleHandActive = singleHandState.perSlot.values.contains { $0.isActive }
        let anyGeometryGestureActive = grabState.isActive || anySingleHandActive ||
            (1...3).contains(where: { twoHandStateByDigit[$0]?.isActive == true })
        settings.isGeometryGestureActive = anyGeometryGestureActive
    }
    
    // MARK: - Shape & Scale Gesture Dispatch
    
    /// Maps a FingerGestureAction (.minDistance / .foldingLimit / .sphereRadius)
    /// to its formula-param index, current target, range, and animation-offset writer.
    private static let shapeActionToFormulaIndex: [FingerGestureAction: Int] = [
        .minDistance:   0,
        .foldingLimit:  1,
        .sphereRadius:  2
    ]

    private typealias ShapeInfo = (
        target: (RenderSettings) -> Float,
        range: (GestureParamRanges) -> ClosedRange<Float>,
        writeOffset: (RenderSettings, Float) -> Void
    )

    private static let shapeActionInfo: [FingerGestureAction: ShapeInfo] = [
        .minDistance: (
            target: { $0.effectiveTargetMinDistance },
            range:  { $0.minDistance },
            writeOffset: { $0.manualOffsetMinDistance = $1 - $0.animationBaseMinDistance }
        ),
        .foldingLimit: (
            target: { $0.effectiveTargetFoldingLimit },
            range:  { $0.foldingLimit },
            writeOffset: { $0.manualOffsetFoldingLimit = $1 - $0.animationBaseFoldingLimit }
        ),
        .sphereRadius: (
            target: { $0.effectiveTargetSphereRadius },
            range:  { $0.sphereRadius },
            writeOffset: { $0.manualOffsetSphereRadius = $1 - $0.animationBaseSphereRadius }
        ),
    ]

    /// Dispatches a two-hand gesture for Mandelbox shape params through the unified
    /// formula-param dispatcher.  Preserves animation-offset blending so gestures
    /// during animation playback behave identically to the legacy core path.
    private func processMandelboxShapeGesture(
        digit: Int,
        action: FingerGestureAction,
        ranges: GestureParamRanges,
        settings: RenderSettings,
        activeDigit: inout Int
    ) {
        guard let formulaIndex = Self.shapeActionToFormulaIndex[action],
              let info = Self.shapeActionInfo[action] else { return }

        let batch = ParameterNodeRegistry.shared.formulaBatch(for: .mandelbox)
        guard let node = batch.floatNodeByFormulaIndex[formulaIndex] else { return }
        guard var digitState = twoHandStateByDigit[digit] else { return }

        processTwoHandGesture(
            digit: digit,
            state: &digitState,
            currentTarget: info.target(settings),
            range: info.range(ranges),
            parameterID: node.id
        ) { newValue in
            if settings.isAnimationPlaying {
                info.writeOffset(settings, newValue)
            }
            let op = ParameterOperation(
                targetID: node.id,
                source: .gesture,
                value: .absolute(newValue),
                frameIndex: operationFrameCounter,
                smoothing: ParameterOperationSmoothing(smoothingTime: settings.gestureSmoothing)
            )
            parameterPipeline.dispatchGesture([op], settings: settings)
            UsageAnalytics.shared.trackHandGestureUsed()
        }
        twoHandStateByDigit[digit] = digitState
        if digitState.isActive { activeDigit = digit }
    }

    /// Dispatches a two-hand gesture for the universal fractalScale core parameter.
    /// Kept on the core path because fractalScale has its own smoothDamp and
    /// applies to every fractal type.
    private func processCoreScaleGesture(
        digit: Int,
        ranges: GestureParamRanges,
        settings: RenderSettings,
        activeDigit: inout Int
    ) {
        guard var digitState = twoHandStateByDigit[digit] else { return }
        processTwoHandGesture(
            digit: digit,
            state: &digitState,
            currentTarget: settings.effectiveTargetFractalScale,
            range: ranges.fractalScale,
            parameterID: ParameterTargetID.Core.fractalScale
        ) { newValue in
            if settings.isAnimationPlaying {
                settings.manualOffsetFractalScale = newValue - settings.animationBaseFractalScale
            }
            let op = ParameterOperation(
                targetID: ParameterTargetID.Core.fractalScale,
                source: .gesture,
                value: .absolute(newValue),
                frameIndex: operationFrameCounter
            )
            parameterPipeline.dispatchGesture([op], settings: settings)
            UsageAnalytics.shared.trackHandGestureUsed()
        }
        twoHandStateByDigit[digit] = digitState
        if digitState.isActive { activeDigit = digit }
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
        if grabState.isActive {
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
        if bothActive && !grabState.isActive {
            grabState.isActive = true
            
            // Capture CURRENT values (what's visually shown), not targets.
            // Build the pre-computed inverse mapping from gesture → fractal space.
            grabState.mapping = GrabZoomMapping(
                leftPos: leftPos, rightPos: rightPos,
                position: settings.position,
                rotation: settings.worldRotation,
                detailScale: settings.detailScale
            )
            grabState.originalAxis = grabState.mapping!.startAxis
            grabState.rotationBrokenAway = !settings.rotationAutoSnap  // If snap disabled, act as if already broken away
        }
        
        // === GESTURE ACTIVE ===
        if bothActive && grabState.isActive, var mapping = grabState.mapping {
            
            // ── Rotation breakaway gate ──────────────────────────────────
            // Rotation is suppressed until the hand axis diverges enough from
            // the original start axis. On breakaway, rebase the entire mapping
            // to the current state so scale+position+rotation all continue
            // smoothly from here with no jump.
            if !grabState.rotationBrokenAway {
                let currentAxis = rightPos - leftPos
                let currentAxisLen = simd_length(currentAxis)
                let currentAxisNorm = currentAxisLen > 1e-4 ? currentAxis / currentAxisLen : grabState.originalAxis
                let dot = simd_clamp(simd_dot(grabState.originalAxis, currentAxisNorm), -1.0, 1.0)
                let breakawayAngleRad = acos(dot)
                let breakawayThresholdRad = settings.rotationBreakawayDegrees * (.pi / 180.0)
                
                if breakawayAngleRad >= breakawayThresholdRad {
                    grabState.rotationBrokenAway = true
                    // Rebase: snapshot current state as the new baseline for
                    // the mapping so rotation, scale, and position all start
                    // from the current values — no jump.
                    mapping.rebase(
                        leftPos: leftPos, rightPos: rightPos,
                        position: settings.position,
                        rotation: settings.worldRotation,
                        detailScale: settings.detailScale
                    )
                    grabState.mapping = mapping
                }
            }
            
            // ── Per-fractal scale clamp (cached from descriptor) ─────────
            let scaleClamp = cachedScaleClamp

            // ── Evaluate the mapping ─────────────────────────────────────
            let result: (position: SIMD3<Float>, rotation: simd_quatf, detailScale: Float)
            if grabState.rotationBrokenAway {
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
                singleHandState.accumulatedPosition = result.position
            }
            
            UsageAnalytics.shared.trackHandGestureUsed()
        }
        
        // === GESTURE END ===
        if !bothActive && grabState.isActive {
            grabState.isActive = false
            grabState.mapping = nil
            grabState.endCooldown = 0.15  // 150ms cooldown prevents drag from stealing

            // Apply rotation auto-snap on release
            settings.applyRotationSnap()
        }
    }
    
    /// Process a two-hand gesture for a specific finger
    /// Directly sets TARGET values - Renderer handles smoothing
    /// - Parameters:
    ///   - digit: 1=index, 2=middle, 3=ring
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
        let activateThresh = (digit == 3) ? settings.ringPinchActivateThreshold : settings.twoHandPinchActivateThreshold
        let releaseThresh = (digit == 3) ? settings.ringPinchReleaseThreshold : settings.twoHandPinchReleaseThreshold
        
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
                
                // Zoom compensation: when zoomed in, reduce sensitivity so fine
                // adjustments are easier.  10× zoom → ~3× less sensitive.
                // Uses pow(scale, -0.5) for a dampened inverse relationship.
                let zoomScale = max(settings.detailScale, 0.01)
                let zoomCompensation: Float = zoomScale > 1.001 ? pow(zoomScale, -0.5) : 1.0
                let sensitivityMultiplier = baseSensitivityMultiplier * verticalScaleFactor * perParamSens * zoomCompensation
                
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
        lockedFinger: Int?,
        menuAndMovementOnly: Bool,
        settings: RenderSettings,
        activeDigit: inout Int
    ) {
        let key = slot.persistenceKey
        let digit = slot.finger.rawValue
        let activateThresh = settings.twoHandPinchActivateThreshold
        let releaseThresh = settings.twoHandPinchReleaseThreshold

        // Skip unassigned slots
        if case .core(.none) = binding { 
            singleHandState.perSlot[key]?.isActive = false
            return
        }

        if menuAndMovementOnly && !binding.isMovementBinding {
            singleHandState.perSlot[key]?.isActive = false
            return
        }

        // Block if BOTH-hand two-hand gesture is active for this digit
        if twoHandStateByDigit[digit]?.isActive == true {
            singleHandState.perSlot[key]?.isActive = false
            return
        }

        // Block during grab-end cooldown
        if grabState.endCooldown > 0 || grabState.isActive {
            singleHandState.perSlot[key]?.isActive = false
            return
        }

        // Check if the OTHER hand is attempting a pinch on a digit that has a
        // both-hand binding.  Only those pinches indicate a possible two-hand
        // gesture; pinches on digits with only single-hand bindings are the
        // other hand doing its own independent gesture and should not block.
        // Also skip digits where the other hand already owns an active single-
        // hand drag — that hand is doing its own gesture, not a two-hand attempt.
        let otherHand = (slot.hand == .right) ? leftHand : rightHand
        var otherAttemptingPinch = false
        if otherHand.isTracked {
            let otherHandMode: GestureHandMode = (slot.hand == .right) ? .left : .right
            for d in 1...3 {
                let bothBinding = settings.binding(forHand: .both, digit: d)
                if case .core(.none) = bothBinding { continue }
                // If the other hand already has an active single-hand drag for
                // this digit, the two-hand gesture won't fire (guarded in step 1),
                // so don't treat this pinch as a two-hand attempt.
                if let finger = FingerDigit(rawValue: d) {
                    // Check all directional sub-slots (vertical + horizontal).
                    let otherDragActive = GestureDirection.allCases.contains {
                        singleHandState.perSlot[GestureSlot(hand: otherHandMode, finger: finger, direction: $0).persistenceKey]?.isActive == true
                    }
                    if otherDragActive { continue }
                }
                let threshold: Float = (d == 3) ? 0.45 : 0.55
                if otherHand.pinchStrength(digit: d) >= threshold {
                    otherAttemptingPinch = true
                    break
                }
            }
        }

        let pinch = hand.pinchStrength(digit: digit)
        var state = singleHandState.perSlot[key] ?? SingleHandDragPerSlotState()
        // Winner-takes-all: another finger already owns this hand — suppress.
        let isLockedOut = lockedFinger != nil && lockedFinger != digit
        let active: Bool
        if state.isActive {
            // Release uses normal threshold — no lead gap needed once active.
            // Don't let the other hand's pinch kill an established gesture —
            // the two-hand guard (step 1) already prevents two-hand from
            // activating while any single-hand drag is active for the same digit.
            active = hand.isTracked && pinch >= releaseThresh
        } else if isLockedOut {
            // This hand is locked to a different finger — block activation.
            active = false
        } else {
            // Minimum lead gap: activating finger must outpace the strongest other
            // finger on this hand. Anatomical finger coupling means pinching index
            // drives middle to ~60–70%; a 0.15 gap requirement prevents them from
            // both firing when the user intends only one.
            let minLeadGap: Float = 0.15
            let otherPinch = (1...3).filter { $0 != digit }
                .map { hand.pinchStrength(digit: $0) }
                .max() ?? 0
            active = hand.isTracked && pinch >= activateThresh && !otherAttemptingPinch
                  && (pinch - otherPinch) >= minLeadGap
        }

        // ── Handle by binding type ──────────────────────────────────────
        switch binding {
        case .core(.translate):
            // Position XYZ pinch-drag
            if active && !state.isActive {
                state.isActive = true
                state.accumulatedPosition = settings.effectiveTargetPosition
                singleHandDragEngine.state.accumulatedPosition = settings.effectiveTargetPosition
                state.prevPos = hand.pinchPosition(digit: digit)
                state.prevPalm = hand.palmPosition
                if settings.useSpringBlob {
                    settings.springActive = true
                }
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

                let maxZoomCompensation: Float = (settings.fractalType == .mandelbulb) ? 1.5 : 2.0
                let zoomCompensation = simd_clamp(1.0 / pow(max(settings.detailScale, 0.01), 0.3), 0.5, maxZoomCompensation)
                let inputDelta = scaledDelta * settings.translationSensitivity * zoomCompensation

                if settings.useSpringBlob {
                    // Drive spring displacement (accumulates stretch while held)
                    settings.springDisplacement = settings.springDisplacement + inputDelta
                    // Store velocity for fling on release
                    settings.springVelocity = inputDelta * 90.0  // ~1/90s per hand tracking update
                } else {
                    // Direct mode: apply position immediately
                    if settings.isAnimationPlaying {
                        settings.manualOffsetPosition = settings.manualOffsetPosition + inputDelta
                    } else {
                        settings.targetPosition = settings.targetPosition + inputDelta
                    }
                }

                state.prevPos = currentPos
                state.prevPalm = currentPos
                activeDigit = digit
            }
            if !active && state.isActive {
                state.isActive = false
                if settings.useSpringBlob {
                    settings.springActive = false  // Release: spring flings
                }
            }

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

                // Zoom compensation: dampen sensitivity when zoomed in.
                let zoomScale = max(settings.detailScale, 0.01)
                let zoomComp: Float = zoomScale > 1.001 ? pow(zoomScale, -0.5) : 1.0

                if deltaLength > 0 {
                    let direction = rawDelta / deltaLength
                    let scaledDelta = direction * min(deltaLength * sensitivity * zoomComp, maxStep) * rangeSpan

                    state.startValues.x = simd_clamp(state.startValues.x + scaledDelta.x, triplet.range.lowerBound, triplet.range.upperBound)
                    state.startValues.y = simd_clamp(state.startValues.y + scaledDelta.y, triplet.range.lowerBound, triplet.range.upperBound)
                    state.startValues.z = simd_clamp(state.startValues.z + scaledDelta.z, triplet.range.lowerBound, triplet.range.upperBound)

                    let tripletSmoothing = ParameterOperationSmoothing(smoothingTime: settings.gestureSmoothing)
                    let ops = [
                        ParameterOperation(targetID: triplet.xNodeID, source: .gesture, value: .absolute(state.startValues.x), frameIndex: operationFrameCounter, smoothing: tripletSmoothing),
                        ParameterOperation(targetID: triplet.yNodeID, source: .gesture, value: .absolute(state.startValues.y), frameIndex: operationFrameCounter, smoothing: tripletSmoothing),
                        ParameterOperation(targetID: triplet.zNodeID, source: .gesture, value: .absolute(state.startValues.z), frameIndex: operationFrameCounter, smoothing: tripletSmoothing),
                    ]
                    parameterPipeline.dispatchGesture(ops, settings: settings)
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
                singleHandState.perSlot[key] = state
                return
            }
            if active && !state.isActive {
                state.isActive = true
                state.startValue = FormulaCatalog.getParam(settings.formulaParams, index: formulaIndex)
                state.prevPos = hand.pinchPosition(digit: digit)
            }
            if active && state.isActive {
                let currentPos = hand.pinchPosition(digit: digit)
                // Map the finger-movement axis from the slot direction:
                // horizontal → X (left/right), depth → Z (toward/away), vertical → Y (up/down).
                let axisDelta: Float
                switch slot.direction {
                case .horizontal: axisDelta = currentPos.x - state.prevPos.x
                case .depth:      axisDelta = currentPos.z - state.prevPos.z
                default:          axisDelta = currentPos.y - state.prevPos.y
                }
                let sensitivity = settings.gestureSensitivity
                let rangeSpan = node.range.upperBound - node.range.lowerBound
                let maxStep: Float = 0.15

                // Zoom compensation: dampen sensitivity when zoomed in.
                let zoomScale = max(settings.detailScale, 0.01)
                let zoomComp: Float = zoomScale > 1.001 ? pow(zoomScale, -0.5) : 1.0
                let scaledDelta = simd_clamp(axisDelta * sensitivity * zoomComp * rangeSpan, -maxStep * rangeSpan, maxStep * rangeSpan)
                state.startValue = simd_clamp(state.startValue + scaledDelta, node.range.lowerBound, node.range.upperBound)

                let op = ParameterOperation(
                    targetID: node.id,
                    source: .gesture,
                    value: .absolute(state.startValue),
                    frameIndex: operationFrameCounter,
                    smoothing: ParameterOperationSmoothing(smoothingTime: settings.gestureSmoothing)
                )
                parameterPipeline.dispatchGesture([op], settings: settings)
                UsageAnalytics.shared.trackHandGestureUsed()
                state.prevPos = currentPos
                activeDigit = digit
            }
            if !active && state.isActive { state.isActive = false }

        default:
            // .core(.grab), .core(.fractalScale), etc. are only valid for both-hand
            state.isActive = false
        }

        singleHandState.perSlot[key] = state
    }
    
}
