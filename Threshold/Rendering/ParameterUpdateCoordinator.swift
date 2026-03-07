//
//  ParameterUpdateCoordinator.swift
//  Threshold
//
//  Decouples parameter smoothing and animation updates from MainActor
//  Prevents UI blocking during heavy fractal rendering
//

import Foundation
import Observation

/// Coordinates parameter updates without blocking MainActor
/// Batches smoothing operations and defers non-critical updates
final class ParameterUpdateCoordinator: @unchecked Sendable {
    private struct PendingParameterWork {
        let shouldUpdateAnimation: Bool
        let shouldUpdateAudio: Bool
        let shouldUpdateSmoothing: Bool
        let deltaTime: TimeInterval
        let fractalType: FractalModelType
    }

    private let updateQueue = DispatchQueue(label: "parameter.update.coordinator", qos: .userInitiated)
    private weak var appModel: AppModel?
    
    // Rate limiting for different update types
    private var lastAnimationUpdate: TimeInterval = 0
    private var lastAudioUpdate: TimeInterval = 0
    private var lastSmoothingUpdate: TimeInterval = 0
    private var pendingAnimationUpdate = false
    private var pendingAudioUpdate = false
    private var pendingSmoothingUpdate = false
    private var pendingDeltaTime: TimeInterval = 1.0 / 90.0
    private var pendingFractalType: FractalModelType = .mandelbulb
    private var isMainActorDispatchScheduled = false
    
    private let animationUpdateInterval: TimeInterval = 1.0 / 90.0  // 90Hz
    private let audioUpdateInterval: TimeInterval = 1.0 / 60.0      // 60Hz
    // Smoothing does not need to run every frame; 45Hz is a good balance between
    // responsiveness and MainActor/CPU overhead under heavy rendering load.
    private let smoothingUpdateInterval: TimeInterval = 1.0 / 45.0
    
    nonisolated init(appModel: AppModel) {
        self.appModel = appModel
    }
    
    /// Schedule parameter updates from render thread without blocking
    /// Batches animation, audio, and smoothing into coordinated MainActor dispatch
    nonisolated func scheduleParameterUpdates(
        shouldUpdateAnimation: Bool,
        shouldUpdateAudio: Bool,
        deltaTime: TimeInterval,
        currentTime: TimeInterval,
        fractalType: FractalModelType
    ) {
        updateQueue.async { [weak self] in
            self?.processPendingParameterUpdates(
                shouldUpdateAnimation: shouldUpdateAnimation,
                shouldUpdateAudio: shouldUpdateAudio,
                deltaTime: deltaTime,
                currentTime: currentTime,
                fractalType: fractalType
            )
        }
    }
    
    private func processPendingParameterUpdates(
        shouldUpdateAnimation: Bool,
        shouldUpdateAudio: Bool,
        deltaTime: TimeInterval,
        currentTime: TimeInterval,
        fractalType: FractalModelType
    ) {
        let needsAnimationUpdate = shouldUpdateAnimation && (currentTime - lastAnimationUpdate >= animationUpdateInterval)
        let needsAudioUpdate = shouldUpdateAudio && (currentTime - lastAudioUpdate >= audioUpdateInterval)
        let needsSmoothingUpdate = (shouldUpdateAnimation || shouldUpdateAudio)
            && (currentTime - lastSmoothingUpdate >= smoothingUpdateInterval)
        
        // Only dispatch to MainActor if there's actual work to do
        guard needsAnimationUpdate || needsAudioUpdate || needsSmoothingUpdate else { return }
        
        if needsAnimationUpdate {
            lastAnimationUpdate = currentTime
        }
        if needsAudioUpdate {
            lastAudioUpdate = currentTime
        }
        if needsSmoothingUpdate {
            lastSmoothingUpdate = currentTime
        }

        pendingAnimationUpdate = pendingAnimationUpdate || needsAnimationUpdate
        pendingAudioUpdate = pendingAudioUpdate || needsAudioUpdate
        pendingSmoothingUpdate = pendingSmoothingUpdate || needsSmoothingUpdate
        pendingDeltaTime = deltaTime
        pendingFractalType = fractalType
        
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
                pendingSmoothingUpdate = false
                isMainActorDispatchScheduled = false
            }

            return PendingParameterWork(
                shouldUpdateAnimation: pendingAnimationUpdate,
                shouldUpdateAudio: pendingAudioUpdate,
                shouldUpdateSmoothing: pendingSmoothingUpdate,
                deltaTime: pendingDeltaTime,
                fractalType: pendingFractalType
            )
        }

        guard let appModel = appModel else { return }
        
        if pendingWork.shouldUpdateAnimation {
            appModel.animationManager?.update(deltaTime: pendingWork.deltaTime)
        }
        
        if pendingWork.shouldUpdateAudio {
            appModel.appleMusicManager.updateFrame()
        }
        
        if pendingWork.shouldUpdateSmoothing {
            let smoothingDelta = Float(pendingWork.deltaTime)
            ParameterNodeRegistry.shared.updateSmoothing(deltaTime: smoothingDelta, for: pendingWork.fractalType)
        }
    }
}
