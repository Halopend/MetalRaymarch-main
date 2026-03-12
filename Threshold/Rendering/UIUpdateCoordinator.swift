//
//  UIUpdateCoordinator.swift
//  Threshold
//
//  Decoupled UI update system to prevent UI lag during fractal rendering drops
//

import Foundation
import SwiftUI
import Observation
import Synchronization

/// Coordinates UI updates from the render thread without blocking MainActor.
/// Uses Mutex-protected rate-limiting state and batched MainActor dispatches
/// to minimize observation invalidation.
final class UIUpdateCoordinator: Sendable {
    private struct State {
        var lastFPSScheduleTime: TimeInterval = 0
        var lastAnalyticsScheduleTime: TimeInterval = 0
        var pendingFPSUpdate: Double?
        var pendingAnalyticsFPS: Double?
        var hasPendingAnalyticsUpdate = false
        var isMainActorDispatchScheduled = false
    }

    private struct PendingUIWork: Sendable {
        let fps: Double?
        let analyticsFPS: Double?
        let shouldUpdateAnalytics: Bool
    }

    private let _state = Mutex(State())
    
    // Rate limiting constants
    private let fpsUpdateInterval: TimeInterval = 0.5  // 2Hz FPS display
    private let analyticsInterval: TimeInterval = 0.25 // 4Hz analytics
    
    // Weak reference to avoid retain cycles (nonisolated(unsafe) because AppModel is @MainActor;
    // only dereferenced inside @MainActor applyPendingUpdates)
    nonisolated(unsafe) private weak var appModel: AppModel?
    
    nonisolated init(appModel: AppModel) {
        self.appModel = appModel
    }
    
    /// Called from render thread - schedules UI updates without blocking
    nonisolated func scheduleUIUpdate(fps: Double, currentTime: TimeInterval) {
        let shouldDispatch = _state.withLock { state -> Bool in
            let shouldUpdateFPS = currentTime - state.lastFPSScheduleTime >= fpsUpdateInterval
            let shouldUpdateAnalytics = currentTime - state.lastAnalyticsScheduleTime >= analyticsInterval
            
            if shouldUpdateFPS {
                state.pendingFPSUpdate = fps
                state.lastFPSScheduleTime = currentTime
            }
            
            if shouldUpdateAnalytics {
                state.pendingAnalyticsFPS = fps
                state.hasPendingAnalyticsUpdate = true
                state.lastAnalyticsScheduleTime = currentTime
            }
            
            guard (state.pendingFPSUpdate != nil || state.hasPendingAnalyticsUpdate),
                  !state.isMainActorDispatchScheduled else {
                return false
            }
            
            state.isMainActorDispatchScheduled = true
            return true
        }
        
        if shouldDispatch {
            Task { @MainActor [weak self] in
                self?.applyPendingUpdates()
            }
        }
    }
    
    @MainActor
    private func applyPendingUpdates() {
        let pendingWork = _state.withLock { state -> PendingUIWork in
            defer {
                state.pendingFPSUpdate = nil
                state.pendingAnalyticsFPS = nil
                state.hasPendingAnalyticsUpdate = false
                state.isMainActorDispatchScheduled = false
            }

            return PendingUIWork(
                fps: state.pendingFPSUpdate,
                analyticsFPS: state.pendingAnalyticsFPS,
                shouldUpdateAnalytics: state.hasPendingAnalyticsUpdate
            )
        }

        guard let appModel = appModel else { return }
        
        // Apply FPS update if pending
        if let fps = pendingWork.fps {
            appModel.fps = fps
        }
        
        // Update analytics at separate rate
        if pendingWork.shouldUpdateAnalytics {
            updateAnalytics(appModel: appModel, fps: pendingWork.analyticsFPS ?? pendingWork.fps ?? appModel.fps)
        }
    }
    
    @MainActor
    private func updateAnalytics(appModel: AppModel, fps: Double) {
        let settings = appModel.renderSettings
        let qualityPreset = QualityPreset.detect(
            fractalIterations: settings.fractalIterations,
            raySteps: settings.maxRaySteps
        )?.rawValue ?? "custom"
        
        UsageAnalytics.shared.sample(
            settings: settings,
            fps: fps,
            currentQuality: qualityPreset
        )
    }
}
