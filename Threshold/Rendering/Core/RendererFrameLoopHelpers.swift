import Foundation

extension Renderer {
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
            // Log once if handTracking provider is nil (should never happen after init)
            if !hasLoggedHandTrackingNil {
                hasLoggedHandTrackingNil = true
                print("⚠️ HandTrackingProvider is nil – hand gestures unavailable")
            }
            return
        }

        // Only process if hand tracking is running
        guard ht.state == .running else {
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

        // Process gestures via async dispatch to MainActor
        // GestureController is @MainActor so updateHands must run there.
        // UI state updates (leftHandTracked, rightHandTracked) are throttled to ~15Hz
        // since they trigger @Observable invalidation but are only visual indicators.
        if #available(visionOS 2.0, *) {
            let leftAnchor = anchors.leftHand
            let rightAnchor = anchors.rightHand

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

            let dispatchTask = Task { @MainActor [weak self] in
                guard let self else { return }
                defer {
                    // Call directly — finishHandTrackingDispatch is nonisolated
                    // and grabs its own Mutex lock; no need to hop back to the
                    // Renderer actor (which is stuck in a synchronous render loop).
                    self.finishHandTrackingDispatch()
                    self.clearHandTrackingDispatchTask()
                }

                // Mark tracking as running (for UI diagnostics)
                if !self.appModel.handTrackingRunning {
                    self.appModel.handTrackingRunning = true
                }

                guard self.appModel.handTrackingEnabled else {
                    if self.appModel.leftHandTracked {
                        self.appModel.leftHandTracked = false
                    }
                    if self.appModel.rightHandTracked {
                        self.appModel.rightHandTracked = false
                    }
                    self.appModel.gestureStatus = "Hand tracking disabled in settings"
                    return
                }

                // Clear stale hover to prevent gesture suppression from getting stuck
                self.appModel.clearStaleHoverIfNeeded()

                // Only update UI-facing tracking state at ~15Hz to reduce @Observable invalidation
                // Checking gestureUpdateDelta here: if accumulated time > 66ms, update UI state
                if delta > 0.066 {
                    let isLeftTracked = leftAnchor?.isTracked ?? false
                    let isRightTracked = rightAnchor?.isTracked ?? false
                    if self.appModel.leftHandTracked != isLeftTracked {
                        self.appModel.leftHandTracked = isLeftTracked
                    }
                    if self.appModel.rightHandTracked != isRightTracked {
                        self.appModel.rightHandTracked = isRightTracked
                    }

                    // Update diagnostic status
                    let suppressed = self.appModel.gestureController?.suppressParameterGestures ?? false
                    if suppressed {
                        self.appModel.gestureStatus = "Suppressed (looking at menu window)"
                    } else if !isLeftTracked && !isRightTracked {
                        self.appModel.gestureStatus = "No hands detected"
                    } else {
                        let activeGesture = self.appModel.renderSettings.activeGestureIndex
                        if activeGesture > 0 {
                            let names = ["", "Index → minDist", "Middle → foldLimit", "Ring → sphereRadius", "Pinky → scale"]
                            self.appModel.gestureStatus = "Active: \(names[min(activeGesture, 4)])"
                        } else {
                            var parts: [String] = []
                            if isLeftTracked { parts.append("L") }
                            if isRightTracked { parts.append("R") }
                            self.appModel.gestureStatus = "Ready (\(parts.joined(separator: "+")) tracked)"
                        }
                    }
                }

                // Gesture processing always runs for responsive controls
                self.appModel.gestureController?.updateHands(
                    leftAnchor: leftAnchor,
                    rightAnchor: rightAnchor,
                    deltaTime: delta
                )
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
