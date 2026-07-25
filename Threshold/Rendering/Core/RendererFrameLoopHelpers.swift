import Foundation
import ARKit
import simd

extension Renderer {
    /// Clear every renderer-side tracking mirror as soon as the provider or
    /// required joints drop. Otherwise the last valid hand remains latched into
    /// the DE while ARKit is paused/stopped.
    private func clearHandAttractionTrackingState() {
        lastLeftHandPalmPosition = .zero
        lastLeftHandTrackedForAttraction = false
        lastRightHandPalmPosition = .zero
        lastRightHandTrackedForAttraction = false
        lastLeftForearmWrist = .zero
        lastLeftForearmElbow = .zero
        lastLeftForearmTracked = false
        lastRightForearmWrist = .zero
        lastRightForearmElbow = .zero
        lastRightForearmTracked = false
    }

    func updateDynamicBufferState() {
        /// Update the state of our uniform buffers before rendering
        /// OPTIMIZATION: Use bitwise AND for modulo when maxBuffersInFlight is power of 2
        uniformBufferIndex = (uniformBufferIndex + 1) & (maxBuffersInFlight - 1)  // Faster than modulo for power of 2
        uniformBufferOffset = alignedUniformsSize * uniformBufferIndex
        uniforms = UnsafeMutableRawPointer(dynamicUniformBuffer.contents() + uniformBufferOffset).bindMemory(to:UniformsArray.self, capacity:1)
    }

    /// Update hand tracking data and process gesture controls
    func updateHandTracking(atTime time: TimeInterval) {
        guard let ht = handTracking else {
            clearHandAttractionTrackingState()
            clearSpatialRadialTrackingState(atTime: time)
            updateSpatialRadialHandInteraction(with: nil)
            // Log once if handTracking provider is nil (should never happen after init)
            if !hasLoggedHandTrackingNil {
                hasLoggedHandTrackingNil = true
                print("⚠️ HandTrackingProvider is nil – hand gestures unavailable")
            }
            return
        }

        // Only process if hand tracking is running
        guard ht.state == .running else {
            clearHandAttractionTrackingState()
            clearSpatialRadialTrackingState(atTime: time)
            updateSpatialRadialHandInteraction(with: nil)
            // Throttled log for non-running state (once per 5 seconds)
            if time - lastHandTrackingStateLogTime > 5.0 {
                lastHandTrackingStateLogTime = time
                print("⚠️ HandTrackingProvider state: \(ht.state) – gestures inactive")
                Task { @MainActor in
                    self.appModel.handTrackingRunning = false
                    // Build a user-facing status string
                    switch ht.state {
                    case .stopped:
                        self.appModel.gestureStatus = "Hand tracking stopped (not authorized?)"
                    case .paused:
                        self.appModel.gestureStatus = "Hand tracking paused"
                    default:
                        self.appModel.gestureStatus = "Hand tracking not running (\(ht.state))"
                    }
                }
            }
            return
        }

        // Get hand anchors at the current time
        let anchors = ht.handAnchors(at: time)

        // Calculate deltaTime for this update
        let gestureUpdateDelta = Float(time - lastHandTrackingUpdateTime)
        lastHandTrackingUpdateTime = time

        if #available(visionOS 2.0, *) {
            let leftAnchor = anchors.leftHand
            let rightAnchor = anchors.rightHand
            let extracted = HandPoseSnapshot.extract(
                leftAnchor: leftAnchor,
                rightAnchor: rightAnchor,
                timestamp: time,
                deltaTime: gestureUpdateDelta
            )
            spatialHandTrackingIsRunning = true
            latestSpatialHandPose = extracted
            updateSpatialRadialHandInteraction(with: extracted)

            // The exact same extracted snapshot feeds attraction and recognition.
            lastLeftHandPalmPosition = extracted.leftHand.palmPosition
            lastLeftHandTrackedForAttraction = extracted.leftHand.isTracked
                && simd_length_squared(extracted.leftHand.palmPosition) > 1e-6
            lastRightHandPalmPosition = extracted.rightHand.palmPosition
            lastRightHandTrackedForAttraction = extracted.rightHand.isTracked
                && simd_length_squared(extracted.rightHand.palmPosition) > 1e-6
            lastLeftForearmWrist = extracted.leftHand.forearmWrist
            lastLeftForearmElbow = extracted.leftHand.forearmElbow
            lastLeftForearmTracked = extracted.leftHand.forearmTracked
            lastRightForearmWrist = extracted.rightHand.forearmWrist
            lastRightForearmElbow = extracted.rightHand.forearmElbow
            lastRightForearmTracked = extracted.rightHand.forearmTracked

            // Atomically decide whether to start a new dispatch or just accumulate
            // onto an in-flight one. Returns the delta to use if we're starting;
            // nil means a dispatch is already running and we only accumulated.
            let accumulatedDelta: Float? = handTrackingDispatchState.withLock { state in
                if state.inFlight {
                    state.pendingDelta += gestureUpdateDelta
                    return nil
                }
                let combined = gestureUpdateDelta + state.pendingDelta
                state.pendingDelta = 0
                state.inFlight = true
                return combined
            }

            guard let delta = accumulatedDelta else { return }
            let snapshot = HandPoseSnapshot(
                leftHand: extracted.leftHand,
                rightHand: extracted.rightHand,
                timestamp: time,
                deltaTime: delta
            )
            let shouldPublishDiagnostics = time - lastHandDiagnosticsPublishTime >= (1.0 / 15.0)
            if shouldPublishDiagnostics { lastHandDiagnosticsPublishTime = time }
            let gesturesEnabled = appModel.handTrackingEnabledForRenderer
            let processor = appModel.gestureProcessor
            let parameterPipeline = appModel.parameterPipeline
            let renderSettings = appModel.renderSettings
            let model = appModel

            let dispatchTask = Task.detached(priority: .userInitiated) { [weak self] in
                guard let self else { return }
                defer {
                    self.finishHandTrackingDispatch()
                    self.clearHandTrackingDispatchTask()
                }

                guard gesturesEnabled else {
                    guard shouldPublishDiagnostics else { return }
                    await MainActor.run {
                        model.handTrackingRunning = true
                        model.leftHandTracked = false
                        model.rightHandTracked = false
                        model.gestureStatus = "Hand tracking disabled in settings"
                    }
                    return
                }

                let output = await processor.process(snapshot)
                let requestsSpatialMenu = output.commands.contains { command in
                    switch command {
                    case .toggleRadialMenu, .selectRoute:
                        return true
                    case .openAnimationEditor, .dismissRadialMenu,
                         .resetViewport, .toggleAnimationPlayback:
                        return false
                    }
                }
                if requestsSpatialMenu {
                    await self.captureSpatialRadialActivationPose(
                        snapshot,
                        hand: output.menuActivationHand
                    )
                }
                if !output.parameterOperations.isEmpty {
                    parameterPipeline.dispatchGesture(
                        output.parameterOperations,
                        settings: renderSettings
                    )
                }
                for mutation in output.renderMutations {
                    mutation.apply(to: renderSettings)
                }
                guard shouldPublishDiagnostics || output.didUseGesture || !output.commands.isEmpty else {
                    return
                }
                await MainActor.run {
                    model.handTrackingRunning = true
                    if shouldPublishDiagnostics {
                        model.clearStaleHoverIfNeeded()
                    }
                    model.applyGestureOutput(output, publishDiagnostics: shouldPublishDiagnostics)
                }
            }
            handTrackingDispatchTask = dispatchTask
        }
    }

    nonisolated func finishHandTrackingDispatch() {
        handTrackingDispatchState.withLock { state in
            state.inFlight = false
        }
    }

    nonisolated func clearHandTrackingDispatchTask() {
        handTrackingDispatchTask = nil
    }
}
