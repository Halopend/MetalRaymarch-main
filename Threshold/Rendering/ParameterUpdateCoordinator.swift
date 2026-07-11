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
        var pendingPresetBankReset = false
        var wasPresetBankSourceActive: Bool?
        var pendingDeltaTime: TimeInterval = 1.0 / 90.0
        var isMainActorDispatchScheduled = false
    }

    private struct PendingParameterWork: Sendable {
        let shouldUpdateAnimation: Bool
        let shouldUpdateAudio: Bool
        let shouldResetPresetBank: Bool
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

            if pendingWork.shouldResetPresetBank {
                appModel.resetMusicPresetBankEffectTrigger()
            }
            if pendingWork.shouldUpdateAudio {
                appModel.appleMusicManager.updateFrame()
                appModel.updateMusicPresetBankEffect()
            }
        }
    }
    
    /// Schedule parameter updates from render thread without blocking.
    /// Batches animation and audio into coordinated MainActor dispatch.
    nonisolated func scheduleParameterUpdates(
        shouldUpdateAnimation: Bool,
        shouldUpdateAudio: Bool,
        musicPresetBankEffectEnabled: Bool,
        hasActiveAudioSource: Bool,
        deltaTime: TimeInterval,
        currentTime: TimeInterval
    ) {
        let shouldDispatch = _state.withLock { state -> Bool in
            let needsAnimationUpdate = shouldUpdateAnimation &&
                (currentTime - state.lastAnimationUpdate >= animationUpdateInterval)
            let needsAudioUpdate = shouldUpdateAudio &&
                (currentTime - state.lastAudioUpdate >= audioUpdateInterval)
            let presetBankSourceIsActive = musicPresetBankEffectEnabled && hasActiveAudioSource
            // A nil prior state means this is a newly-created render session.
            // Always reset once at that boundary: audio may have stopped and
            // restarted while no coordinator existed to observe either edge.
            let needsPresetBankReset = musicPresetBankEffectEnabled
                && (state.wasPresetBankSourceActive == nil
                    || (state.wasPresetBankSourceActive == true && !hasActiveAudioSource))
            state.wasPresetBankSourceActive = presetBankSourceIsActive
            
            guard needsAnimationUpdate || needsAudioUpdate || needsPresetBankReset else { return false }
            
            if needsAnimationUpdate {
                state.lastAnimationUpdate = currentTime
            }
            if needsAudioUpdate {
                state.lastAudioUpdate = currentTime
            }
            
            state.pendingAnimationUpdate = state.pendingAnimationUpdate || needsAnimationUpdate
            state.pendingAudioUpdate = state.pendingAudioUpdate || needsAudioUpdate
            state.pendingPresetBankReset = state.pendingPresetBankReset || needsPresetBankReset
            state.pendingDeltaTime = deltaTime
            
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
                state.pendingPresetBankReset = false
                state.isMainActorDispatchScheduled = false
            }

            return PendingParameterWork(
                shouldUpdateAnimation: state.pendingAnimationUpdate,
                shouldUpdateAudio: state.pendingAudioUpdate,
                shouldResetPresetBank: state.pendingPresetBankReset,
                deltaTime: state.pendingDeltaTime
            )
        }

        applyPendingWorkHandler(pendingWork)
    }
}
