//
//  ParameterUpdateCoordinator.swift
//  Threshold
//
//  Decouples animation and audio updates from MainActor
//  Prevents UI blocking during heavy fractal rendering
//

import Foundation
import Observation
import Synchronization

/// Coordinates parameter updates without blocking MainActor.
/// Uses Mutex-protected rate-limiting state and batched MainActor dispatch
/// to prevent per-frame contention.
final class ParameterUpdateCoordinator: Sendable {
    private struct State {
        var lastAnimationUpdate: TimeInterval = 0
        var lastAudioUpdate: TimeInterval = 0
        var pendingAnimationUpdate = false
        var pendingAudioUpdate = false
        /// Frame deltas banked since the last CONSUMED animation update. The
        /// animation gate only decides *when* to dispatch; the dt handed to
        /// `AnimationManager.update` must be the elapsed time since the last
        /// consumed update — the sum of every frame delta in between — not the
        /// last single frame's dt. On a 120 Hz display the 90 Hz gate passes
        /// every other frame, and storing the per-frame dt ran keyframed
        /// animation at ~0.5× real speed (scenes drift out of sync with
        /// attached audio the same way).
        var accumulatedAnimationDelta: TimeInterval = 0
        var isMainActorDispatchScheduled = false
    }

    private struct PendingParameterWork: Sendable {
        let shouldUpdateAnimation: Bool
        let shouldUpdateAudio: Bool
        let deltaTime: TimeInterval
    }

    private let _state = Mutex(State())
    private let applyPendingWorkHandler: @Sendable @MainActor (PendingParameterWork) -> Void
    
    // Rate limiting for different update types
    private let animationUpdateInterval: TimeInterval = 1.0 / 90.0  // 90Hz
    private let audioUpdateInterval: TimeInterval = 1.0 / 60.0      // 60Hz
    
    nonisolated init(appModel: AppModel) {
        self.applyPendingWorkHandler = { [weak appModel] pendingWork in
            guard let appModel else { return }

            if pendingWork.shouldUpdateAnimation {
                appModel.animationManager?.update(deltaTime: pendingWork.deltaTime)
            }

            if pendingWork.shouldUpdateAudio {
                appModel.audioHub.updateFrame()
            }
        }
    }
    
    /// Schedule parameter updates from render thread without blocking.
    /// Batches animation and audio into coordinated MainActor dispatch.
    nonisolated func scheduleParameterUpdates(
        shouldUpdateAnimation: Bool,
        shouldUpdateAudio: Bool,
        deltaTime: TimeInterval,
        currentTime: TimeInterval
    ) {
        let shouldDispatch = _state.withLock { state -> Bool in
            let needsAnimationUpdate = shouldUpdateAnimation &&
                (currentTime - state.lastAnimationUpdate >= animationUpdateInterval)
            let needsAudioUpdate = shouldUpdateAudio &&
                (currentTime - state.lastAudioUpdate >= audioUpdateInterval)

            // Animation dt bookkeeping must run BEFORE the early return: the
            // frames the animation gate declines are exactly the ones whose
            // deltas must be banked for the next consumed update.
            if shouldUpdateAnimation {
                state.accumulatedAnimationDelta += deltaTime
            } else {
                // Animation not playing: don't carry stale accumulation into
                // the next playback session.
                state.accumulatedAnimationDelta = 0
            }

            guard needsAnimationUpdate || needsAudioUpdate else { return false }

            if needsAnimationUpdate {
                state.lastAnimationUpdate = currentTime
            }
            if needsAudioUpdate {
                state.lastAudioUpdate = currentTime
            }

            state.pendingAnimationUpdate = state.pendingAnimationUpdate || needsAnimationUpdate
            state.pendingAudioUpdate = state.pendingAudioUpdate || needsAudioUpdate
            
            guard !state.isMainActorDispatchScheduled else { return false }
            
            state.isMainActorDispatchScheduled = true
            return true
        }
        
        if shouldDispatch {
            Task { @MainActor [weak self] in
                self?.applyParameterUpdates()
            }
        }
    }
    
    @MainActor
    private func applyParameterUpdates() {
        let pendingWork = _state.withLock { state -> PendingParameterWork in
            defer {
                state.pendingAnimationUpdate = false
                state.pendingAudioUpdate = false
                state.isMainActorDispatchScheduled = false
            }

            // Consume the accumulated dt exactly when the animation update is
            // delivered — this is the elapsed time since the previous consumed
            // update, regardless of how many gate cycles it spanned.
            var deltaTime: TimeInterval = 0
            if state.pendingAnimationUpdate {
                deltaTime = max(state.accumulatedAnimationDelta, 1.0 / 240.0)
                state.accumulatedAnimationDelta = 0
            }

            return PendingParameterWork(
                shouldUpdateAnimation: state.pendingAnimationUpdate,
                shouldUpdateAudio: state.pendingAudioUpdate,
                deltaTime: deltaTime
            )
        }

        applyPendingWorkHandler(pendingWork)
    }
}
