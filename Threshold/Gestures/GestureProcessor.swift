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

/// Resolves application-command ownership when independent recognizers observe
/// the same hand pose. Recovery-menu presentation is authoritative from initial
/// recognition through release; per-finger shortcuts resume after that pose.
enum GestureCommandArbitration {
    static func commands(
        tapOperations: [GestureOperation],
        menuOperations: [GestureOperation],
        recoveryPoseClaimed: Bool
    ) -> [AppCommand] {
        if menuOperations.contains(.toggleMenu) {
            return [.toggleRadialMenu]
        }
        guard !recoveryPoseClaimed else { return [] }

        return tapOperations.compactMap { operation in
            switch operation {
            case .toggleAnimationPlayer:
                return .toggleAnimationPlayback
            case .openShapeMenu:
                return .selectRoute(.input(.parameters))
            case .openRenderMenu:
                return .selectRoute(.quality(.tuning))
            case .openQuickToggles:
                return .selectRoute(.quickToggles)
            case .toggleMenu, .trackGestureUsage:
                return nil
            }
        }
    }
}

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
    private var frameParameterOperations: [ParameterOperation] = []
    private var frameRenderMutations: [GestureRenderMutation] = []
    private let menuToggleEngine = MenuToggleGestureEngine()
    private let perFingerTapEngine = PerFingerTapGestureEngine()
    private let armSliderEngine = ArmSliderGestureEngine()
    private let twoHandScalarEngine = TwoHandScalarGestureEngine()
    private let grabEngine = TwoPointGrabGestureEngine()
    private let singleHandDragEngine = SingleHandDragGestureEngine()
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

    
    // Reference to render settings
    private weak var renderSettings: RenderSettings?
    
    init(renderSettings: RenderSettings,
         parameterPipeline: ParameterPipeline) {
        self.renderSettings = renderSettings
        self.parameterPipeline = parameterPipeline
    }
    
    func setDebugTraceEnabled(_ enabled: Bool) {
        parameterPipeline.setDebugTraceEnabled(enabled)
    }

    func setParameterGesturesSuppressed(_ suppressed: Bool) {
        if suppressed && !suppressParameterGestures {
            perFingerTapEngine.reset()
        }
        suppressParameterGestures = suppressed
    }

    /// Sync internal state with current render settings.
    /// Call this after loading a preset to prevent jumps when gestures resume.
    func syncWithSettings() {
        guard renderSettings != nil else { return }
        refreshCachedDescriptorValues()
        
        // Reset all gesture states to avoid stale data
        twoHandScalarEngine.reset()
        grabEngine.reset()
        singleHandDragEngine.reset()
        menuToggleEngine.reset()
        perFingerTapEngine.reset()
        armSliderEngine.reset()
    }
    
    // MARK: - Hand Tracking Updates
    
    /// Processes one Sendable pose snapshot on this actor's serial executor.
    func process(_ snapshot: HandPoseSnapshot) -> GestureOutput {
        let processingStart = ContinuousClock.now
        operationFrameCounter &+= 1
        frameParameterOperations.removeAll(keepingCapacity: true)
        frameRenderMutations.removeAll(keepingCapacity: true)
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
        grabEngine.tick(deltaTime: deltaTime)
        
        let context = GestureContext(leftHand: leftHand, rightHand: rightHand, deltaTime: deltaTime)

        // Evaluate recovery-menu ownership before scene gestures. This keeps the
        // activation/debounce frames from also changing geometry or parameters.
        let menuOps = menuToggleEngine.process(context: context, configuration: configuration)
        let recoveryPoseClaimed = menuToggleEngine.isClaimingPose
        processGestures(forceSuppressed: recoveryPoseClaimed)

        // Run both menu-related recognizers before dispatching either result.
        // The dedicated recovery gesture owns menu presentation for its full
        // hysteresis-delimited pose. Discard per-finger shortcuts while claimed
        // so a delayed tap cannot open a route after toggling its window.
        if recoveryPoseClaimed {
            perFingerTapEngine.reset()
        }
        let tapOps = (suppressParameterGestures || recoveryPoseClaimed)
            ? []
            : perFingerTapEngine.process(context: context)
        let commands = GestureCommandArbitration.commands(
            tapOperations: tapOps,
            menuOperations: menuOps,
            recoveryPoseClaimed: recoveryPoseClaimed
        )
        let menuActivationHand: GestureHandMode?
        if menuOps.contains(.toggleMenu) {
            menuActivationHand = menuToggleEngine.lastActivationHand
        } else if commands.contains(where: \.presentsSpatialMenu) {
            menuActivationHand = perFingerTapEngine.lastMenuActivationHand
        } else {
            menuActivationHand = nil
        }

        let didCompleteArmGesture = armSliderEngine.process(
            context: context,
            parametersSuppressed: suppressParameterGestures || recoveryPoseClaimed,
            grabActive: grabEngine.isActive,
            geometryGestureActive: renderSettings?.isGeometryGestureActive == true,
            renderMutations: &frameRenderMutations
        )
        if didCompleteArmGesture {
            didUseGesture = true
        }
        let publishUsage = didUseGesture && snapshot.timestamp - lastPublishedUsageTime >= 1
        if publishUsage { lastPublishedUsageTime = snapshot.timestamp }
        let processingDuration = processingStart.duration(to: .now)
        let durationComponents = processingDuration.components
        let processingNanoseconds =
            UInt64(max(0, durationComponents.seconds)) * 1_000_000_000
            + UInt64(max(0, durationComponents.attoseconds / 1_000_000_000))
        return GestureOutput(
            parameterOperations: frameParameterOperations,
            renderMutations: frameRenderMutations,
            commands: commands,
            menuActivationHand: menuActivationHand,
            diagnostics: GestureDiagnostics(
                leftTracked: leftHand.isTracked,
                rightTracked: rightHand.isTracked,
                activeGestureIndex: renderSettings?.activeGestureIndex ?? 0,
                parametersSuppressed: suppressParameterGestures,
                processingDurationNanoseconds: processingNanoseconds
            ),
            didUseGesture: publishUsage
        )
    }

    // MARK: - Gesture Processing
    
    private func processGestures(forceSuppressed: Bool = false) {
        guard let settings = renderSettings else { return }
        
        // ── Suppress parameter gestures while the user is interacting with the menu window ──
        if suppressParameterGestures || forceSuppressed {
            for digit in 1...3 {
                twoHandScalarEngine.deactivate(digit: digit)
            }
            grabEngine.deactivate()
            singleHandDragEngine.deactivateAll()
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
                // Formula params read from formulaParams; universal core params
                // (formulaIndex == nil, e.g. sphere projection) read from settings.
                let currentTarget: Float = descriptor.formulaIndex
                    .map { FormulaCatalog.getParam(settings.formulaParams, index: $0) }
                    ?? parameterPipeline.currentValue(for: node.id, settings: settings)
                    ?? node.range.lowerBound
                let result = twoHandScalarEngine.process(
                    digit: digit,
                    context: GestureContext(
                        leftHand: leftHand,
                        rightHand: rightHand,
                        deltaTime: 0
                    ),
                    leftHandStable: leftHandStable,
                    currentTarget: currentTarget,
                    range: node.range,
                    parameterID: node.id,
                    useRelativeGestures: settings.useRelativeGestures,
                    detailScale: settings.detailScale
                )
                if let newValue = result.value {
                    let op = ParameterOperation(
                        targetID: node.id,
                        source: .gesture,
                        value: newValue,
                        frameIndex: self.operationFrameCounter,
                        smoothing: ParameterOperationSmoothing(smoothingTime: GestureDefaults.gestureSmoothing)
                    )
                    self.frameParameterOperations.append(op)
                    self.didUseGesture = true
                }
                if result.hitLimit { settings.triggerLimitFlash() }
                if result.isActive { activeDigit = digit }
                continue
            }

            guard case .core(let action) = binding else {
                twoHandScalarEngine.deactivate(digit: digit)
                continue
            }

            switch action {
            case .grab:
                processTwoPointGrab(digit: digit)
                if grabEngine.isActive { activeDigit = digit }
                
            case .minDistance, .foldingLimit, .sphereRadius:
                guard settings.fractalType == .mandelbox else {
                    twoHandScalarEngine.deactivate(digit: digit)
                    continue
                }
                processMandelboxShapeGesture(digit: digit, action: action, ranges: ranges, settings: settings, activeDigit: &activeDigit)

            case .fractalScale:
                processCoreScaleGesture(digit: digit, ranges: ranges, settings: settings, activeDigit: &activeDigit)
                
            case .none, .translate:
                // translate is only valid for single-hand; deactivate any stale two-hand state
                twoHandScalarEngine.deactivate(digit: digit)
            }
        }
        
        // ── 2. SINGLE-HAND GESTURES (left + right, independent) ─────────
        var twoHandActiveMask: UInt8 = 0
        for digit in 1...3 where twoHandScalarEngine.isActive(digit: digit) {
            twoHandActiveMask |= 1 << UInt8(digit)
        }
        let singleHandResult = singleHandDragEngine.process(
            context: GestureContext(leftHand: leftHand, rightHand: rightHand, deltaTime: 0),
            settings: settings,
            parameterPipeline: parameterPipeline,
            frameIndex: operationFrameCounter,
            twoHandActiveMask: twoHandActiveMask,
            grabActive: grabEngine.isActive,
            grabEndCooldown: grabEngine.endCooldown,
            parameterOperations: &frameParameterOperations,
            renderMutations: &frameRenderMutations
        )
        if singleHandResult.activeDigit != 0 {
            activeDigit = singleHandResult.activeDigit
        }
        if singleHandResult.didUseGesture {
            didUseGesture = true
        }

        // Update active gesture for HUD
        settings.activeGestureIndex = activeDigit
        
        // Wire geometry gesture flag
        let anyGeometryGestureActive = grabEngine.isActive || singleHandResult.hasActiveGesture ||
            twoHandScalarEngine.hasActiveGesture
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
        let result = twoHandScalarEngine.process(
            digit: digit,
            context: GestureContext(leftHand: leftHand, rightHand: rightHand, deltaTime: 0),
            leftHandStable: leftHandStable,
            currentTarget: info.target(settings),
            range: info.range(ranges),
            parameterID: node.id,
            useRelativeGestures: settings.useRelativeGestures,
            detailScale: settings.detailScale
        )
        if let newValue = result.value {
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
            frameParameterOperations.append(op)
            didUseGesture = true
        }
        if result.hitLimit { settings.triggerLimitFlash() }
        if result.isActive { activeDigit = digit }
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
        let result = twoHandScalarEngine.process(
            digit: digit,
            context: GestureContext(leftHand: leftHand, rightHand: rightHand, deltaTime: 0),
            leftHandStable: leftHandStable,
            currentTarget: settings.effectiveTargetFractalScale,
            range: ranges.fractalScale,
            parameterID: ParameterTargetID.Core.fractalScale,
            useRelativeGestures: settings.useRelativeGestures,
            detailScale: settings.detailScale
        )
        if let newValue = result.value {
            if settings.isAnimationPlaying {
                settings.manualOffsetFractalScale = newValue - settings.animationBaseFractalScale
            }
            let op = ParameterOperation(
                targetID: ParameterTargetID.Core.fractalScale,
                source: .gesture,
                value: newValue,
                frameIndex: operationFrameCounter
            )
            frameParameterOperations.append(op)
            didUseGesture = true
        }
        if result.hitLimit { settings.triggerLimitFlash() }
        if result.isActive { activeDigit = digit }
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
        let result = grabEngine.process(
            digit: digit,
            context: GestureContext(leftHand: leftHand, rightHand: rightHand, deltaTime: 0),
            leftHandStable: leftHandStable,
            startPosition: settings.position,
            startRotation: settings.worldRotation,
            startDetailScale: settings.detailScale,
            scaleClamp: cachedScaleClamp
        )
        if let transform = result.transform {
            frameRenderMutations.append(.applyGrab(transform))
            didUseGesture = true
        }
    }
    
}

private extension AppCommand {
    var presentsSpatialMenu: Bool {
        switch self {
        case .toggleRadialMenu, .selectRoute:
            return true
        case .openAnimationEditor, .dismissRadialMenu,
             .resetViewport, .toggleAnimationPlayback:
            return false
        }
    }
}
