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
        guard let ht = handTracking else { return }

        // Only process if hand tracking is running
        guard ht.state == .running else { return }

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
            if isHandTrackingDispatchInFlight {
                pendingHandTrackingDelta += gestureUpdateDelta
                return
            }

            isHandTrackingDispatchInFlight = true
            let accumulatedDelta = gestureUpdateDelta + pendingHandTrackingDelta
            pendingHandTrackingDelta = 0

            Task { @MainActor in
                defer {
                    Task {
                        await self.finishHandTrackingDispatch()
                    }
                }

                guard self.appModel.handTrackingEnabled else {
                    if self.appModel.leftHandTracked {
                        self.appModel.leftHandTracked = false
                    }
                    if self.appModel.rightHandTracked {
                        self.appModel.rightHandTracked = false
                    }
                    return
                }

                // Only update UI-facing tracking state at ~15Hz to reduce @Observable invalidation
                // Checking gestureUpdateDelta here: if accumulated time > 66ms, update UI state
                if accumulatedDelta > 0.066 {
                    let isLeftTracked = leftAnchor?.isTracked ?? false
                    let isRightTracked = rightAnchor?.isTracked ?? false
                    if self.appModel.leftHandTracked != isLeftTracked {
                        self.appModel.leftHandTracked = isLeftTracked
                    }
                    if self.appModel.rightHandTracked != isRightTracked {
                        self.appModel.rightHandTracked = isRightTracked
                    }
                }

                // Gesture processing always runs for responsive controls
                self.appModel.gestureController?.updateHands(
                    leftAnchor: leftAnchor,
                    rightAnchor: rightAnchor,
                    deltaTime: accumulatedDelta
                )
            }
        }
    }

    func finishHandTrackingDispatch() {
        isHandTrackingDispatchInFlight = false
    }
}
