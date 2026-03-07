//
//  UIUpdateCoordinator.swift
//  Threshold
//
//  Decoupled UI update system to prevent UI lag during fractal rendering drops
//

import Foundation
import SwiftUI
import Observation

/// Coordinates UI updates from the render thread without blocking MainActor
/// Uses rate limiting and batching to minimize observation invalidation
final class UIUpdateCoordinator: @unchecked Sendable {
    private struct PendingUIWork {
        let fps: Double?
        let analyticsFPS: Double?
        let shouldUpdateAnalytics: Bool
    }

    private let updateQueue = DispatchQueue(label: "ui.update.coordinator", qos: .userInitiated)
    private var lastFPSScheduleTime: TimeInterval = 0
    private var lastAnalyticsScheduleTime: TimeInterval = 0
    private var pendingFPSUpdate: Double?
    private var pendingAnalyticsFPS: Double?
    private var hasPendingAnalyticsUpdate = false
    private var isMainActorDispatchScheduled = false
    
    // Rate limiting constants
    private let fpsUpdateInterval: TimeInterval = 0.5  // 2Hz FPS display
    private let analyticsInterval: TimeInterval = 0.25 // 4Hz analytics
    
    // Weak reference to avoid retain cycles
    private weak var appModel: AppModel?
    
    nonisolated init(appModel: AppModel) {
        self.appModel = appModel
    }
    
    /// Called from render thread - schedules UI updates without blocking
    nonisolated func scheduleUIUpdate(fps: Double, currentTime: TimeInterval) {
        updateQueue.async { [weak self] in
            self?.processPendingUpdates(fps: fps, currentTime: currentTime)
        }
    }
    
    private func processPendingUpdates(fps: Double, currentTime: TimeInterval) {
        let shouldUpdateFPS = currentTime - lastFPSScheduleTime >= fpsUpdateInterval
        let shouldUpdateAnalytics = currentTime - lastAnalyticsScheduleTime >= analyticsInterval
        
        if shouldUpdateFPS {
            pendingFPSUpdate = fps
            lastFPSScheduleTime = currentTime
        }

        if shouldUpdateAnalytics {
            pendingAnalyticsFPS = fps
            hasPendingAnalyticsUpdate = true
            lastAnalyticsScheduleTime = currentTime
        }
        
        guard (pendingFPSUpdate != nil || hasPendingAnalyticsUpdate), !isMainActorDispatchScheduled else {
            return
        }

        isMainActorDispatchScheduled = true

        // Batch updates to minimize MainActor dispatches and coalesce bursts.
        Task { @MainActor [weak self] in
            self?.applyPendingUpdates()
        }
    }
    
    @MainActor
    private func applyPendingUpdates() {
        let pendingWork = updateQueue.sync { () -> PendingUIWork in
            defer {
                pendingFPSUpdate = nil
                pendingAnalyticsFPS = nil
                hasPendingAnalyticsUpdate = false
                isMainActorDispatchScheduled = false
            }

            return PendingUIWork(
                fps: pendingFPSUpdate,
                analyticsFPS: pendingAnalyticsFPS,
                shouldUpdateAnalytics: hasPendingAnalyticsUpdate
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
