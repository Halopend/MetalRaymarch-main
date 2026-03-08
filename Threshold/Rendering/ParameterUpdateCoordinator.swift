//
//  ParameterUpdateCoordinator.swift
//  Threshold
//
//  Decouples animation and audio updates from MainActor
//  Prevents UI blocking during heavy fractal rendering
//

import Foundation
import Observation

/// Coordinates parameter updates without blocking MainActor
/// Batches animation and audio operations into coordinated MainActor dispatch
final class ParameterUpdateCoordinator: @unchecked Sendable {
    private struct PendingParameterWork {
        let shouldUpdateAnimation: Bool
        let shouldUpdateAudio: Bool
        let deltaTime: TimeInterval
    }

    private let updateQueue = DispatchQueue(label: "parameter.update.coordinator", qos: .userInitiated)
    private weak var appModel: AppModel?
    
    // Rate limiting for different update types
    private var lastAnimationUpdate: TimeInterval = 0
    private var lastAudioUpdate: TimeInterval = 0
    private var pendingAnimationUpdate = false
    private var pendingAudioUpdate = false
    private var pendingDeltaTime: TimeInterval = 1.0 / 90.0
    private var isMainActorDispatchScheduled = false
    
    private let animationUpdateInterval: TimeInterval = 1.0 / 90.0  // 90Hz
    private let audioUpdateInterval: TimeInterval = 1.0 / 60.0      // 60Hz
    
    nonisolated init(appModel: AppModel) {
        self.appModel = appModel
    }
    
    /// Schedule parameter updates from render thread without blocking
    /// Batches animation and audio into coordinated MainActor dispatch
    nonisolated func scheduleParameterUpdates(
        shouldUpdateAnimation: Bool,
        shouldUpdateAudio: Bool,
        deltaTime: TimeInterval,
        currentTime: TimeInterval
    ) {
        updateQueue.async { [weak self] in
            self?.processPendingParameterUpdates(
                shouldUpdateAnimation: shouldUpdateAnimation,
                shouldUpdateAudio: shouldUpdateAudio,
                deltaTime: deltaTime,
                currentTime: currentTime
            )
        }
    }
    
    private func processPendingParameterUpdates(
        shouldUpdateAnimation: Bool,
        shouldUpdateAudio: Bool,
        deltaTime: TimeInterval,
        currentTime: TimeInterval
    ) {
        let needsAnimationUpdate = shouldUpdateAnimation && (currentTime - lastAnimationUpdate >= animationUpdateInterval)
        let needsAudioUpdate = shouldUpdateAudio && (currentTime - lastAudioUpdate >= audioUpdateInterval)
        
        // Only dispatch to MainActor if there's actual work to do
        guard needsAnimationUpdate || needsAudioUpdate else { return }
        
        if needsAnimationUpdate {
            lastAnimationUpdate = currentTime
        }
        if needsAudioUpdate {
            lastAudioUpdate = currentTime
        }

        pendingAnimationUpdate = pendingAnimationUpdate || needsAnimationUpdate
        pendingAudioUpdate = pendingAudioUpdate || needsAudioUpdate
        pendingDeltaTime = deltaTime
        
        guard !isMainActorDispatchScheduled else { return }

        isMainActorDispatchScheduled = true

        // Single batched MainActor dispatch.
        Task { @MainActor [weak self] in
            self?.applyParameterUpdates()
        }
    }
    
    @MainActor
    private func applyParameterUpdates() {
        let pendingWork = updateQueue.sync { () -> PendingParameterWork in
            defer {
                pendingAnimationUpdate = false
                pendingAudioUpdate = false
                isMainActorDispatchScheduled = false
            }

            return PendingParameterWork(
                shouldUpdateAnimation: pendingAnimationUpdate,
                shouldUpdateAudio: pendingAudioUpdate,
                deltaTime: pendingDeltaTime
            )
        }

        guard let appModel = appModel else { return }
        
        if pendingWork.shouldUpdateAnimation {
            appModel.animationManager?.update(deltaTime: pendingWork.deltaTime)
        }
        
        if pendingWork.shouldUpdateAudio {
            appModel.appleMusicManager.updateFrame()
        }
    }
}
