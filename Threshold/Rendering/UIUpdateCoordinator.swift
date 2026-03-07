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
    private let updateQueue = DispatchQueue(label: "ui.update.coordinator", qos: .userInitiated)
    private var lastFPSUpdate: TimeInterval = 0
    private var lastAnalyticsUpdate: TimeInterval = 0
    private var pendingFPSUpdate: Double = 0
    private var hasPendingFPSUpdate = false
    
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
        let shouldUpdateFPS = currentTime - lastFPSUpdate >= fpsUpdateInterval
        let shouldUpdateAnalytics = currentTime - lastAnalyticsUpdate >= analyticsInterval
        
        if shouldUpdateFPS {
            pendingFPSUpdate = fps
            hasPendingFPSUpdate = true
            lastFPSUpdate = currentTime
        }
        
        if shouldUpdateAnalytics || hasPendingFPSUpdate {
            // Batch updates to minimize MainActor dispatches
            Task { @MainActor [weak self] in
                self?.applyPendingUpdates(currentTime: currentTime)
            }
        }
    }
    
    @MainActor
    private func applyPendingUpdates(currentTime: TimeInterval) {
        guard let appModel = appModel else { return }
        
        // Apply FPS update if pending
        if hasPendingFPSUpdate {
            appModel.fps = pendingFPSUpdate
            hasPendingFPSUpdate = false
        }
        
        // Update analytics at separate rate
        if currentTime - lastAnalyticsUpdate >= analyticsInterval {
            updateAnalytics(appModel: appModel, fps: pendingFPSUpdate)
            lastAnalyticsUpdate = currentTime
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
