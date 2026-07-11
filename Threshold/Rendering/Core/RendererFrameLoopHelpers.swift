import Foundation
import ARKit
import simd

extension Renderer {
    /// Hand Attraction: world-space palm position for one hand anchor, or `.zero`
    /// when untracked. Mirrors GestureController.buildHandData's own extraction
    /// (middle-finger metacarpal reads as the palm).
    @available(visionOS 2.0, *)
    static func palmPosition(from anchor: HandAnchor?) -> SIMD3<Float> {
        guard let anchor, anchor.isTracked,
              let joint = anchor.handSkeleton?.joint(.middleFingerMetacarpal), joint.isTracked else {
            return .zero
        }
        let worldTransform = anchor.originFromAnchorTransform * joint.anchorFromJointTransform
        return SIMD3<Float>(worldTransform.columns.3.x, worldTransform.columns.3.y, worldTransform.columns.3.z)
    }

    /// Wrist + elbow world positions for the Hand Attraction forearm capsule.
    static func forearmSegment(from anchor: HandAnchor?) -> (wrist: SIMD3<Float>, elbow: SIMD3<Float>, tracked: Bool) {
        guard let anchor, anchor.isTracked, let skeleton = anchor.handSkeleton else {
            return (.zero, .zero, false)
        }
        let wristJoint = skeleton.joint(.forearmWrist)
        let elbowJoint = skeleton.joint(.forearmArm)
        guard wristJoint.isTracked, elbowJoint.isTracked else { return (.zero, .zero, false) }
        func world(_ joint: HandSkeleton.Joint) -> SIMD3<Float> {
            let t = anchor.originFromAnchorTransform * joint.anchorFromJointTransform
            return SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        }
        return (world(wristJoint), world(elbowJoint), true)
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
            if time - lastHandProviderWarningTime > 5.0 {
                lastHandProviderWarningTime = time
                print("⚠️ HandTrackingProvider state: \(ht.state) – gestures inactive")
            }
            return
        }

        // Get hand anchors at the current time
        let anchors = ht.handAnchors(at: time)

        // Calculate deltaTime for this update
        let gestureUpdateDelta = Float(time - lastHandTrackingUpdateTime)
        lastHandTrackingUpdateTime = time

        // Process gestures via async dispatch to MainActor.
        // GestureController is @MainActor so updateHands must run there.
        if #available(visionOS 2.0, *) {
            let leftAnchor = anchors.leftHand
            let rightAnchor = anchors.rightHand

            // Hand Attraction (visionOS only): cache each palm's world-space
            // position directly on the Renderer actor, synchronously — GestureController
            // is @MainActor and updateGameState runs on the render loop, so routing
            // through it would require an actor hop. These mirror buildHandData's own
            // extraction and are read back in makeHandAttractionUniforms this same frame.
            lastLeftHandPalmPosition = Self.palmPosition(from: leftAnchor)
            lastLeftHandTrackedForAttraction = leftAnchor?.isTracked ?? false
            lastRightHandPalmPosition = Self.palmPosition(from: rightAnchor)
            lastRightHandTrackedForAttraction = rightAnchor?.isTracked ?? false
            let leftForearm = Self.forearmSegment(from: leftAnchor)
            lastLeftForearmWrist = leftForearm.wrist
            lastLeftForearmElbow = leftForearm.elbow
            lastLeftForearmTracked = leftForearm.tracked
            let rightForearm = Self.forearmSegment(from: rightAnchor)
            lastRightForearmWrist = rightForearm.wrist
            lastRightForearmElbow = rightForearm.elbow
            lastRightForearmTracked = rightForearm.tracked

            // Head pose for gestures that need a facing-relative frame (the
            // open-palm scene swipe resolves "left/right" against this).
            let headTransform = worldTracking.queryDeviceAnchor(atTimestamp: time)?.originFromAnchorTransform

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

                guard self.appModel.handTrackingEnabled else { return }

                // Clear stale hover to prevent gesture suppression from getting stuck
                self.appModel.clearStaleHoverIfNeeded()

                // Gesture processing always runs for responsive controls
                self.appModel.gestureController?.updateHands(
                    leftAnchor: leftAnchor,
                    rightAnchor: rightAnchor,
                    deltaTime: delta,
                    headTransform: headTransform
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
