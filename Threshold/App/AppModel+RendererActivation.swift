//
//  AppModel+RendererActivation.swift
//  Threshold
//
//  Render-loop lifecycle: registration handshake, active render-loop task
//  set/cancel, and renderer-handler teardown. Extracted verbatim from AppModel
//  to keep the app coordinator focused; behaviour is unchanged.
//

import Foundation

extension AppModel {

    @discardableResult
    func beginRenderLoopRegistration() -> UUID {
        activeRenderLoopTask?.cancel()
        clearRendererHandlers()

        let id = UUID()
        activeRenderLoopID = id
        rendererStartupWarmupComplete = false
        return id
    }

    func setActiveRenderLoopTask(_ task: Task<Void, Never>, id: UUID) {
        guard activeRenderLoopID == id else {
            task.cancel()
            return
        }

        activeRenderLoopTask = task
    }

    func cancelActiveRenderLoop() {
        activeRenderLoopTask?.cancel()
        activeRenderLoopTask = nil
        activeRenderLoopID = nil
        clearRendererHandlers()
    }

    func clearRendererHandlers(renderLoopID: UUID) {
        guard activeRenderLoopID == renderLoopID else { return }

        activeRenderLoopTask = nil
        activeRenderLoopID = nil
        clearRendererHandlers()
    }

    private func clearRendererHandlers() {
        // Invalidate completions from presentation tasks owned by the renderer
        // whose handlers are about to be removed.
        spatialMenuPresentationGeneration &+= 1
        if let lighting = activeEmbeddedLighting {
            customLightingRuntimeState = .waitingForRenderer(name: lighting.name)
        } else {
            customLightingRuntimeState = .inactive
        }
        captureScreenshotHandler = nil
        preparePipelineHandler = nil
        preparePipelineForValuesHandler = nil
        triggerProfilerHandler = nil
        forceShaderRecompileHandler = nil
        activateEmbeddedFormulaHandler = nil
        presentSpatialMenuHandler = nil
        dismissSpatialMenuHandler = nil
        if isSpatialMenuVisible {
            setSpatialMenuVisible(false)
        }
        rendererStartupWarmupComplete = false
    }
}
