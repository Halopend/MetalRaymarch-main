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
        var pendingGPUMs: Double?
        var pendingAvgSteps: Double?
        var pendingFrameGapP95Ms: Double?
        var pendingFrameGapP99Ms: Double?
        var pendingMaximumFrameGapMs: Double?
        var pendingHitchCount: Int?
        var pendingAnalyticsFPS: Double?
        var hasPendingAnalyticsUpdate = false
        var isMainActorDispatchScheduled = false
    }

    private struct PendingUIWork: Sendable {
        let fps: Double?
        let gpuMs: Double?
        let avgStepsPerPixel: Double?
        let frameGapP95Ms: Double?
        let frameGapP99Ms: Double?
        let maximumFrameGapMs: Double?
        let hitchCount: Int?
        let analyticsFPS: Double?
        let shouldUpdateAnalytics: Bool
    }

    private let _state = Mutex(State())
    private let applyPendingWorkHandler: @Sendable @MainActor (PendingUIWork) -> Void
    
    // Rate limiting constants
    private let fpsUpdateInterval: TimeInterval = 0.5    // 2 Hz FPS display
    private let analyticsInterval: TimeInterval = 0.25  // 4 Hz analytics

    nonisolated init(appModel: AppModel) {
        self.applyPendingWorkHandler = { [weak appModel] pendingWork in
            guard let appModel else { return }

            if let fps = pendingWork.fps {
                appModel.renderMetrics.fps = fps
            }

            if let gpuMs = pendingWork.gpuMs {
                appModel.renderMetrics.gpuFrameMs = gpuMs
            }

            // Publish even 0 so turning profiling off clears the stale reading
            // (the render thread writes 0 to the holder when not measuring).
            if let steps = pendingWork.avgStepsPerPixel {
                appModel.renderMetrics.avgStepsPerPixel = steps
            }

            if let p95 = pendingWork.frameGapP95Ms {
                appModel.renderMetrics.frameGapP95Ms = p95
            }
            if let p99 = pendingWork.frameGapP99Ms {
                appModel.renderMetrics.frameGapP99Ms = p99
            }
            if let maximum = pendingWork.maximumFrameGapMs {
                appModel.renderMetrics.maximumFrameGapMs = maximum
            }
            if let hitchCount = pendingWork.hitchCount {
                appModel.renderMetrics.hitchCount = hitchCount
            }

            if pendingWork.shouldUpdateAnalytics,
               UsageAnalytics.persistedAnalyticsEnabled {
                let settings = appModel.renderSettings
                let qualityPreset = QualityPreset.detect(
                    fractalIterations: settings.fractalIterations,
                    raySteps: settings.maxRaySteps,
                    fractalType: settings.fractalType
                )?.rawValue ?? "custom"

                UsageAnalytics.shared.sample(
                    settings: settings,
                    fps: pendingWork.analyticsFPS ?? pendingWork.fps ?? appModel.renderMetrics.fps,
                    currentQuality: qualityPreset
                )
            }
        }
    }
    
    /// Called from render thread — schedules UI updates without blocking.
    nonisolated func scheduleUIUpdate(
        fps: Double,
        gpuMs: Double? = nil,
        avgStepsPerPixel: Double? = nil,
        frameGapP95Ms: Double? = nil,
        frameGapP99Ms: Double? = nil,
        maximumFrameGapMs: Double? = nil,
        hitchCount: Int? = nil,
        currentTime: TimeInterval
    ) {
        let shouldDispatch = _state.withLock { state -> Bool in
            let shouldUpdateFPS = currentTime - state.lastFPSScheduleTime >= fpsUpdateInterval
            let shouldUpdateAnalytics = currentTime - state.lastAnalyticsScheduleTime >= analyticsInterval

            if shouldUpdateFPS {
                state.pendingFPSUpdate = fps
                state.pendingGPUMs = gpuMs
                state.pendingAvgSteps = avgStepsPerPixel
                state.pendingFrameGapP95Ms = frameGapP95Ms
                state.pendingFrameGapP99Ms = frameGapP99Ms
                state.pendingMaximumFrameGapMs = maximumFrameGapMs
                state.pendingHitchCount = hitchCount
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
                state.pendingGPUMs = nil
                state.pendingAvgSteps = nil
                state.pendingFrameGapP95Ms = nil
                state.pendingFrameGapP99Ms = nil
                state.pendingMaximumFrameGapMs = nil
                state.pendingHitchCount = nil
                state.pendingAnalyticsFPS = nil
                state.hasPendingAnalyticsUpdate = false
                state.isMainActorDispatchScheduled = false
            }

            return PendingUIWork(
                fps: state.pendingFPSUpdate,
                gpuMs: state.pendingGPUMs,
                avgStepsPerPixel: state.pendingAvgSteps,
                frameGapP95Ms: state.pendingFrameGapP95Ms,
                frameGapP99Ms: state.pendingFrameGapP99Ms,
                maximumFrameGapMs: state.pendingMaximumFrameGapMs,
                hitchCount: state.pendingHitchCount,
                analyticsFPS: state.pendingAnalyticsFPS,
                shouldUpdateAnalytics: state.hasPendingAnalyticsUpdate
            )
        }

        applyPendingWorkHandler(pendingWork)
    }
}
