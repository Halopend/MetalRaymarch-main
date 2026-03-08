import Foundation

extension Renderer {
    // Track previous fractal complexity parameters to avoid per-frame hintSceneComplexity() calls.
    // hintSceneComplexity() unconditionally nudges quality down by 0.05 and bypasses the
    // update cooldown — calling it every frame drains quality at 4.5/s (0.05 * 90fps),
    // which overwhelms the 0.08/s increase rate and prevents recovery.
    private static var _lastHintedIterations: Int = -1
    private static var _lastHintedRaySteps: Int = -1
    private static var _lastHintedTileSize: Int = -1

    /// Update dynamic render quality based on FPS performance (visionOS 26+)
    /// This implements Apple's WWDC25 Session 294 dynamic render quality API
    /// using resolution scaling only (geometry-preserving).
    func updateDynamicRenderQuality(fps: Double, deltaTime: TimeInterval) {
        if #available(visionOS 26.0, *) {
            guard let manager = dynamicRenderQualityManager as? DynamicRenderQualityManager else { return }

            let settings = appModel.renderSettings

            // Keep fractal geometry stable: dynamic quality must not mutate DE/raymarch geometry knobs.
            settings.fractalIterations = settings.baseFractalIterations
            settings.maxRaySteps = settings.baseMaxRaySteps

            // Sync manager settings with RenderSettings (in case user changed them)
            manager.isEnabled = settings.dynamicRenderQualityEnabled
            manager.minQuality = settings.dynamicRenderQualityMin
            manager.maxQuality = settings.dynamicRenderQualityMax

            // Update the manager with current FPS - resolution scaling only applies if foveation is available
            let canUseResolutionScaling = layerRenderer.configuration.isFoveationEnabled

            // === GMT-FRACTALS PATTERN: Interaction-aware quality reduction ===
            // Like GMT's UniformManager downscaling during isGizmoInteracting/isCameraInteracting,
            // drop quality during ANY active interaction (menu OR hand gestures).
            // Menu interaction: 0.65 quality (UI responsiveness priority)
            // Gesture interaction: 0.55 quality (more aggressive — gestures cause rapid parameter
            // changes that invalidate per-frame work faster than menu hover)
            if settings.isMenuInteractionActive || settings.isGeometryGestureActive {
                let interactionQuality: Float = settings.isGeometryGestureActive ? 0.55 : 0.65
                let clampedQuality = max(settings.dynamicRenderQualityMin, min(settings.dynamicRenderQualityMax, interactionQuality))
                manager.setQuality(clampedQuality, layerRenderer: canUseResolutionScaling ? layerRenderer : nil)
                settings.currentRenderQuality = manager.currentQuality
                return
            }

            guard canUseResolutionScaling else {
                // No foveation support means no runtime quality lever here.
                settings.currentRenderQuality = manager.currentQuality
                return
            }

            manager.update(fps: fps, deltaTime: deltaTime,
                           layerRenderer: layerRenderer,
                           applyResolutionScaling: canUseResolutionScaling)

            // Sync current quality back to settings for UI display
            settings.currentRenderQuality = manager.currentQuality

            // Log status once
            if !hasLoggedDynamicQualityStatus && manager.isEnabled {
                hasLoggedDynamicQualityStatus = true
                let mode = "resolution scaling only"
                if RENDERER_DEBUG { print("✓ Dynamic render quality active (\(mode)): adjusting based on FPS") }
            }

            // Hint scene complexity only when fractal parameters actually change.
            // hintSceneComplexity() nudges currentQuality down by 0.05 and bypasses the
            // update cooldown — calling it every frame would drain quality faster than
            // the increase rate can recover.
            let currentIters = settings.baseFractalIterations
            let currentSteps = settings.baseMaxRaySteps
            let currentTile = settings.tileSize
            if currentIters != Self._lastHintedIterations ||
               currentSteps != Self._lastHintedRaySteps ||
               currentTile != Self._lastHintedTileSize {
                Self._lastHintedIterations = currentIters
                Self._lastHintedRaySteps = currentSteps
                Self._lastHintedTileSize = currentTile

                let complexity = DynamicRenderQualityManager.estimateFractalComplexity(
                    iterations: currentIters,
                    raySteps: currentSteps,
                    tileSize: currentTile
                )
                manager.hintSceneComplexity(complexity, layerRenderer: layerRenderer)
            }
        }
    }
}
