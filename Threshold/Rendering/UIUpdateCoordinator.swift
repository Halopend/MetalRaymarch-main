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
    private let applyPendingWorkHandler: @Sendable @MainActor (PendingUIWork) -> Void
    
    // Rate limiting constants
    private let fpsUpdateInterval: TimeInterval = 0.5  // 2Hz FPS display
    private let analyticsInterval: TimeInterval = 0.25 // 4Hz analytics
    
    nonisolated init(appModel: AppModel) {
        self.applyPendingWorkHandler = { [weak appModel] pendingWork in
            guard let appModel else { return }

            if let fps = pendingWork.fps {
                appModel.renderMetrics.fps = fps
            }

            if pendingWork.shouldUpdateAnalytics {
                let settings = appModel.renderSettings
                let qualityPreset = QualityPreset.detect(
                    fractalIterations: settings.fractalIterations,
                    raySteps: settings.maxRaySteps
                )?.rawValue ?? "custom"

                UsageAnalytics.shared.sample(
                    settings: settings,
                    fps: pendingWork.analyticsFPS ?? pendingWork.fps ?? appModel.renderMetrics.fps,
                    currentQuality: qualityPreset
                )
            }
        }
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

        applyPendingWorkHandler(pendingWork)
    }
}
