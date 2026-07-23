//
//  GestureProcessor.swift
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
import simd

// MARK: - Gesture Processor

/// Processes hand tracking data and maps gestures to render parameters
/// 
/// TWO-HAND DESIGN:
/// - Both hands must pinch with the SAME finger to activate a gesture
/// - Parameter scales RELATIVELY: if hands move 2× apart, parameter doubles
/// - Smoothing prevents jitter and provides natural feel
actor GestureProcessor {
    let parameterPipeline: ParameterPipeline
    private var operationFrameCounter: UInt64 = 0
    private let menuToggleEngine = MenuToggleGestureEngine()
    private let perFingerTapEngine = PerFingerTapGestureEngine()
    private var twoHandScalarState = TwoHandScalarEngineState()
    private var twoPointGrabState = TwoPointGrabGestureState()
    private var singleHandDragState = SingleHandDragEngineState()
    private var armSliderState = ArmSliderGestureState()
    private var configuration = GestureConfigurationSnapshot.initial
    private var didUseGesture = false
    private var lastPublishedUsageTime: TimeInterval = -.infinity

    // ==========================================================================
    // PER-FRACTAL PARAMETER RANGES  (cached from FractalTypeDescriptor)
    // ==========================================================================

    private var cachedFractalType: FractalModelType?
    private var cachedScaleClamp: ClosedRange<Float> = 0.001...500.0
    private var cachedRanges: GestureParamRanges = .standard

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
        cachedFractalType = current
    }

    /// Get parameter ranges for current fractal type (from cache).
    private func currentRanges() -> GestureParamRanges {
        cachedRanges
    }

    /// When true, parameter-changing gestures are suppressed so pinching and dragging
    /// menu controls does not also manipulate the scene. Menu toggle remains active
    /// so the gesture can still close or recover the menu window.
    private var suppressParameterGestures = false
    
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
        get { twoHandScalarState.perDigit }
        set { twoHandScalarState.perDigit = newValue }
    }

    private var grabState: TwoPointGrabGestureState {
        get { twoPointGrabState }
        set { twoPointGrabState = newValue }
    }

    private var singleHandState: SingleHandDragEngineState {
        get { singleHandDragState }
        set { singleHandDragState = newValue }
    }

    
    // Reference to render settings
    private weak var renderSettings: RenderSettings?
    
    init(renderSettings: RenderSettings,
         parameterPipeline: ParameterPipeline) {
        self.renderSettings = renderSettings
        self.parameterPipeline = parameterPipeline
        
        singleHandDragState.accumulatedPosition = renderSettings.position
    }
    
    func setDebugTraceEnabled(_ enabled: Bool) {
        parameterPipeline.setDebugTraceEnabled(enabled)
    }

    func setParameterGesturesSuppressed(_ suppressed: Bool) {
        suppressParameterGestures = suppressed
    }

    /// Sync internal state with current render settings.
    /// Call this after loading a preset to prevent jumps when gestures resume.
    func syncWithSettings() {
        guard let settings = renderSettings else { return }
        singleHandDragState.accumulatedPosition = settings.effectiveTargetPosition
        refreshCachedDescriptorValues()
        
        // Reset all gesture states to avoid stale data
        twoHandScalarState = TwoHandScalarEngineState()
        twoPointGrabState = TwoPointGrabGestureState()
        singleHandDragState = SingleHandDragEngineState(
            perSlot: [:],
            accumulatedPosition: settings.effectiveTargetPosition
        )
        menuToggleEngine.reset()
        perFingerTapEngine.reset()
        armSliderState.left = ArmSliderHandState()
        armSliderState.right = ArmSliderHandState()
    }
    
    // MARK: - Hand Tracking Updates
    
    /// Processes one Sendable pose snapshot on this actor's serial executor.
    func process(_ snapshot: HandPoseSnapshot) -> GestureOutput {
        operationFrameCounter &+= 1
        refreshCachedDescriptorValues()
        leftHand = snapshot.leftHand
        rightHand = snapshot.rightHand
        let deltaTime = snapshot.deltaTime

        if let settings = renderSettings,
           let updated = settings.gestureConfigurationSnapshot(ifNewerThan: configuration.version) {
            configuration = updated
            perFingerTapEngine.isEnabled = updated.perFingerTapEnabled
            perFingerTapEngine.leftHandActions = updated.leftTapActions
            perFingerTapEngine.rightHandActions = updated.rightTapActions
            perFingerTapEngine.activateThreshold = updated.tapActivateThreshold
            perFingerTapEngine.releaseThreshold = updated.tapReleaseThreshold
            perFingerTapEngine.holdDuration = updated.tapHoldDuration
            perFingerTapEngine.cooldown = updated.tapCooldown
        }
        didUseGesture = false

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
        if twoPointGrabState.endCooldown > 0 {
            twoPointGrabState.endCooldown = max(0, twoPointGrabState.endCooldown - deltaTime)
        }
        
        // Process all gesture mappings (sets targets on RenderSettings)
        processGestures()
        
        // Process special gestures
        let context = GestureContext(leftHand: leftHand, rightHand: rightHand, deltaTime: deltaTime)

        var commands: [AppCommand] = []
        // Run per-finger tap engine. It cannot emit the recovery-menu command.
        let tapOps = perFingerTapEngine.process(context: context)
        for op in tapOps {
            switch op {
            case .toggleMenu: break
            case .toggleAnimationPlayer:
                commands.append(.toggleAnimationPlayback)
            case .openShapeMenu:
                commands.append(.selectRoute(.shape(.parameters)))
            case .openRenderMenu:
                commands.append(.selectRoute(.quality(.tuning)))
            case .openQuickToggles:
                commands.append(.selectRoute(.quickToggles))
            default:
                break
            }
        }

        // The recovery engine always runs, including during parameter suppression.
        let menuOps = menuToggleEngine.process(context: context, configuration: configuration)
        if menuOps.contains(.toggleMenu) {
            commands.append(.toggleRadialMenu)
        }

        processArmSliderGesture(deltaTime: deltaTime)
        let publishUsage = didUseGesture && snapshot.timestamp - lastPublishedUsageTime >= 1
        if publishUsage { lastPublishedUsageTime = snapshot.timestamp }
        return GestureOutput(
            commands: commands,
            diagnostics: GestureDiagnostics(
                leftTracked: leftHand.isTracked,
                rightTracked: rightHand.isTracked,
                activeGestureIndex: renderSettings?.activeGestureIndex ?? 0,
                parametersSuppressed: suppressParameterGestures
            ),
            didUseGesture: publishUsage
        )
    }
    
    // MARK: - Arm Slider (fingertip slides along the forearm → music strength)

    /// Absolute-position control: the OPPOSITE hand's index fingertip slides
    /// along a forearm (elbow→wrist). Left forearm sets music INTENSITY
    /// (fractalAudioAmount), right forearm sets music DAMPENING
    /// (fractalAudioDamping). "Down the arm" (toward the hand) increases the
    /// value. Values persist on release. visionOS-only in practice (needs hand
    /// tracking); harmless elsewhere since the hands are never tracked.
    private func processArmSliderGesture(deltaTime: Float) {
        // Stand down while the menu owns a hand or a manipulation gesture is
        // active, so a pinch-drag near the arm can't also nudge the music.
        guard let settings = renderSettings,
              !suppressParameterGestures,
              !grabState.isActive,
              settings.isGeometryGestureActive != true else {
            if armSliderState.left.engaged || armSliderState.right.engaged {
                renderSettings?.persistAudioReactiveNow()
            }
            armSliderState.left = ArmSliderHandState()
            armSliderState.right = ArmSliderHandState()
            return
        }

        // Left forearm ← right index fingertip → music intensity (0…1).
        let leftWas = armSliderState.left.engaged
        if updateArmSlider(&armSliderState.left,
                           elbow: leftHand.forearmElbow, wrist: leftHand.forearmWrist,
                           pointer: rightHand.indexTip,
                           tracked: leftHand.forearmTracked && rightHand.isTracked) {
            settings.setFractalAudioAmountLive(armSliderState.left.value)
        } else if leftWas {
            settings.persistAudioReactiveNow()
            armSliderState.left.hasValue = false
            didUseGesture = true
        }

        // Right forearm ← left index fingertip → music dampening (0…max).
        let rightWas = armSliderState.right.engaged
        if updateArmSlider(&armSliderState.right,
                           elbow: rightHand.forearmElbow, wrist: rightHand.forearmWrist,
                           pointer: leftHand.indexTip,
                           tracked: rightHand.forearmTracked && leftHand.isTracked) {
            settings.setFractalAudioDampingLive(armSliderState.right.value * GestureDefaults.armSliderDampingMax)
        } else if rightWas {
            settings.persistAudioReactiveNow()
            armSliderState.right.hasValue = false
            didUseGesture = true
        }
    }

    /// Advances one forearm's slider. Projects the pointer fingertip onto the
    /// elbow→wrist axis; engages (with hysteresis) only while the fingertip is
    /// close to and alongside the arm. Returns true while engaged, updating
    /// `state.value` (smoothed normalized position 0…1). Mutates only `state`.
    private func updateArmSlider(_ state: inout ArmSliderHandState,
                                 elbow: SIMD3<Float>, wrist: SIMD3<Float>,
                                 pointer: SIMD3<Float>, tracked: Bool) -> Bool {
        guard tracked,
              simd_length_squared(pointer) > 1e-6,
              simd_length_squared(elbow) > 1e-6,
              simd_length_squared(wrist) > 1e-6 else {
            state.engaged = false
            return false
        }

        let axis = wrist - elbow
        let len = simd_length(axis)
        guard len >= GestureDefaults.armSliderMinForearmLength else {
            state.engaged = false
            return false
        }
        let dir = axis / len
        let rel = pointer - elbow
        let along = simd_dot(rel, dir)
        let tRaw = along / len
        let perp = simd_length(rel - along * dir)

        // Engage close to the arm and alongside it; stay engaged under a looser
        // radius and a small overhang past each end (hysteresis).
        let nowEngaged: Bool
        if state.engaged {
            nowEngaged = perp <= GestureDefaults.armSliderReleaseRadius && tRaw >= -0.20 && tRaw <= 1.20
        } else {
            nowEngaged = perp <= GestureDefaults.armSliderEngageRadius && tRaw >= -0.10 && tRaw <= 1.10
        }
        state.engaged = nowEngaged
        guard nowEngaged else { return false }

        let target = simd_clamp(tRaw, 0, 1)
        if state.hasValue {
            let alpha = simd_clamp(GestureDefaults.armSliderSmoothing, 0, 1)
            state.value += (target - state.value) * alpha
        } else {
            state.value = target
            state.hasValue = true
        }
        return true
    }

    // MARK: - Gesture Processing
    
    private func processGestures() {
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

            // Runtime conflict guard: skip if any single-hand drag is active for this digit
            guard FingerDigit(rawValue: digit) != nil else { continue }
            if case .parameter(let descriptor) = binding,
               let node = ParameterNodeRegistry.shared.node(for: descriptor) {
                guard var digitState = twoHandStateByDigit[digit] else { continue }
                // Formula params read from formulaParams; universal core params
                // (formulaIndex == nil, e.g. sphere projection) read from settings.
                let currentTarget: Float = descriptor.formulaIndex
                    .map { FormulaCatalog.getParam(settings.formulaParams, index: $0) }
                    ?? parameterPipeline.currentValue(for: node.id, settings: settings)
                    ?? node.range.lowerBound
                processTwoHandGesture(
                    digit: digit,
                    state: &digitState,
                    currentTarget: currentTarget,
                    range: node.range,
                    parameterID: node.id
                ) { newValue in
                    let op = ParameterOperation(
                        targetID: node.id,
                        source: .gesture,
                        value: newValue,
                        frameIndex: self.operationFrameCounter,
                        smoothing: ParameterOperationSmoothing(smoothingTime: GestureDefaults.gestureSmoothing)
                    )
                    self.parameterPipeline.dispatchGesture([op], settings: settings)
                    self.didUseGesture = true
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
        target: @Sendable (RenderSettings) -> Float,
        range: @Sendable (GestureParamRanges) -> ClosedRange<Float>,
        writeOffset: @Sendable (RenderSettings, Float) -> Void
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
                value: newValue,
                frameIndex: operationFrameCounter,
                smoothing: ParameterOperationSmoothing(smoothingTime: GestureDefaults.gestureSmoothing)
            )
            parameterPipeline.dispatchGesture([op], settings: settings)
            didUseGesture = true
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
                value: newValue,
                frameIndex: operationFrameCounter
            )
            parameterPipeline.dispatchGesture([op], settings: settings)
            didUseGesture = true
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
        
        let activateThresh = GestureDefaults.twoHandPinchActivateThreshold
        let releaseThresh = GestureDefaults.twoHandPinchReleaseThreshold
        
        let leftPos = leftHand.pinchPosition(digit: digit)
        let rightPos = rightHand.pinchPosition(digit: digit)
        
        let leftPosValid = simd_length_squared(leftPos) > 1e-6
        let rightPosValid = simd_length_squared(rightPos) > 1e-6
        
        let currentDistance = simd_length(leftPos - rightPos)
        let maxStartHandDistance = GestureDefaults.gestureMaxStartHandDistance
        let maxActiveHandDistance = max(GestureDefaults.gestureMaxActiveHandDistance, maxStartHandDistance)
        
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
        }

        // === GESTURE ACTIVE ===
        if bothActive && grabState.isActive, let mapping = grabState.mapping {

            // ── Per-fractal scale clamp (cached from descriptor) ─────────
            let scaleClamp = cachedScaleClamp

            // ── Evaluate the mapping (rotation + scale + position track 1:1) ──
            let result = mapping.evaluate(leftPos: leftPos, rightPos: rightPos, scaleClamp: scaleClamp)
            
            // ── Apply to render settings ─────────────────────────────────
            // Direct application (intentional dispatcher bypass):
            // Position (SIMD3), rotation (quaternion), and grab-scale bypass
            // ParameterPipeline because quaternions need slerp,
            // and grab requires 1:1 tracking, not scalar lerp.
            if settings.isAnimationPlaying {
                settings.manualOffsetPosition = result.position - settings.animationBasePosition
                // Store rotation/zoom as overrides relative to the scene's animated base so
                // they ride along and survive the next applyKeyframe; also write the absolute
                // result for this frame's 1:1 responsiveness.
                settings.manualRotationOffset = result.rotation * settings.animationBaseWorldRotation.inverse
                settings.manualOffsetDetailScale = result.detailScale - settings.animationBaseDetailScale
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
            
            didUseGesture = true
        }
        
        // === GESTURE END ===
        if !bothActive && grabState.isActive {
            grabState.isActive = false
            grabState.mapping = nil
            grabState.endCooldown = 0.15  // 150ms cooldown prevents drag from stealing
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
        let activateThresh = (digit == 3) ? GestureDefaults.ringPinchActivateThreshold : GestureDefaults.twoHandPinchActivateThreshold
        let releaseThresh = (digit == 3) ? GestureDefaults.ringPinchReleaseThreshold : GestureDefaults.twoHandPinchReleaseThreshold
        
        // Measure hand separation (only meaningful if both tracked)
        let leftPos = leftHand.pinchPosition(digit: digit)
        let rightPos = rightHand.pinchPosition(digit: digit)
        
        // Guard against zero positions (tracking glitch)
        let leftPosValid = simd_length_squared(leftPos) > 1e-6
        let rightPosValid = simd_length_squared(rightPos) > 1e-6

        let minHandDistance = GestureDefaults.gestureMinHandDistance
        let maxHandDistance = max(minHandDistance + 0.05, GestureDefaults.gestureMaxHandDistance)
        let maxStartHandDistance = GestureDefaults.gestureMaxStartHandDistance
        let maxActiveHandDistance = max(GestureDefaults.gestureMaxActiveHandDistance, maxStartHandDistance)
        
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
                let baseSensitivityMultiplier = GestureDefaults.gestureSensitivity / 10.0
                
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
        settings: RenderSettings,
        activeDigit: inout Int
    ) {
        let key = slot.persistenceKey
        let digit = slot.finger.rawValue
        let activateThresh = GestureDefaults.twoHandPinchActivateThreshold
        let releaseThresh = GestureDefaults.twoHandPinchReleaseThreshold

        // Skip unassigned slots
        if case .core(.none) = binding { 
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
                singleHandDragState.accumulatedPosition = settings.effectiveTargetPosition
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

                let maxZoomCompensation: Float = (settings.fractalType == .mandelbulb) ? 1.5 : 2.0
                let zoomCompensation = simd_clamp(1.0 / pow(max(settings.detailScale, 0.01), 0.3), 0.5, maxZoomCompensation)
                let inputDelta = scaledDelta * GestureDefaults.translationSensitivity * zoomCompensation

                // Apply position immediately
                if settings.isAnimationPlaying {
                    settings.manualOffsetPosition = settings.manualOffsetPosition + inputDelta
                } else {
                    settings.targetPosition = settings.targetPosition + inputDelta
                }

                state.prevPos = currentPos
                state.prevPalm = currentPos
                activeDigit = digit
            }
            if !active && state.isActive {
                state.isActive = false
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
                let sensitivity = GestureDefaults.gestureSensitivity
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

                    let tripletSmoothing = ParameterOperationSmoothing(smoothingTime: GestureDefaults.gestureSmoothing)
                    let ops = [
                        ParameterOperation(targetID: triplet.xNodeID, source: .gesture, value: state.startValues.x, frameIndex: operationFrameCounter, smoothing: tripletSmoothing),
                        ParameterOperation(targetID: triplet.yNodeID, source: .gesture, value: state.startValues.y, frameIndex: operationFrameCounter, smoothing: tripletSmoothing),
                        ParameterOperation(targetID: triplet.zNodeID, source: .gesture, value: state.startValues.z, frameIndex: operationFrameCounter, smoothing: tripletSmoothing),
                    ]
                    parameterPipeline.dispatchGesture(ops, settings: settings)
                    self.didUseGesture = true
                }
                state.prevPos = currentPos
                activeDigit = digit
            }
            if !active && state.isActive { state.isActive = false }

        case .parameter(let descriptor):
            // 1D scalar pinch-drag (vertical movement → parameter value)
            guard let node = ParameterNodeRegistry.shared.node(for: descriptor) else {
                state.isActive = false
                singleHandState.perSlot[key] = state
                return
            }
            if active && !state.isActive {
                state.isActive = true
                // Formula params read from formulaParams; universal core params
                // (formulaIndex == nil, e.g. sphere projection) read from settings.
                if let formulaIndex = descriptor.formulaIndex {
                    state.startValue = FormulaCatalog.getParam(settings.formulaParams, index: formulaIndex)
                } else {
                    state.startValue = parameterPipeline.currentValue(for: node.id, settings: settings) ?? node.range.lowerBound
                }
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
                let sensitivity = GestureDefaults.gestureSensitivity
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
                    value: state.startValue,
                    frameIndex: operationFrameCounter,
                    smoothing: ParameterOperationSmoothing(smoothingTime: GestureDefaults.gestureSmoothing)
                )
                parameterPipeline.dispatchGesture([op], settings: settings)
                didUseGesture = true
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
