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
    private let updateQueue = DispatchQueue(label: "parameter.update.coordinator", qos: .userInitiated)
    private weak var appModel: AppModel?
    
    // Rate limiting for different update types
    private var lastAnimationUpdate: TimeInterval = 0
    private var lastAudioUpdate: TimeInterval = 0
    private var lastSmoothingUpdate: TimeInterval = 0
    
    private let animationUpdateInterval: TimeInterval = 1.0 / 90.0  // 90Hz
    private let audioUpdateInterval: TimeInterval = 1.0 / 60.0      // 60Hz
    private let smoothingUpdateInterval: TimeInterval = 1.0 / 120.0  // 120Hz
    
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
        let needsSmoothingUpdate = currentTime - lastSmoothingUpdate >= smoothingUpdateInterval
        
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
        
        // Single batched MainActor dispatch
        Task { @MainActor [weak self] in
            self?.applyParameterUpdates(
                shouldUpdateAnimation: needsAnimationUpdate,
                shouldUpdateAudio: needsAudioUpdate,
                shouldUpdateSmoothing: needsSmoothingUpdate,
                deltaTime: Float(deltaTime),
                fractalType: fractalType
            )
        }
    }
    
    @MainActor
    private func applyParameterUpdates(
        shouldUpdateAnimation: Bool,
        shouldUpdateAudio: Bool,
        shouldUpdateSmoothing: Bool,
        deltaTime: Float,
        fractalType: FractalModelType
    ) {
        guard let appModel = appModel else { return }
        
        if shouldUpdateAnimation {
            appModel.animationManager?.update(deltaTime: TimeInterval(deltaTime))
        }
        
        if shouldUpdateAudio {
            appModel.spotifyManager.updateFrame()
            appModel.appleMusicManager.updateFrame()
        }
        
        if shouldUpdateSmoothing {
            ParameterNodeRegistry.shared.updateSmoothing(deltaTime: deltaTime, for: fractalType)
            let _ = ParameterNodeRegistry.shared.consumeDirtyNodes(for: fractalType)
        }
    }
}
