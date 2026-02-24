import Foundation

extension Renderer {
    /// Update dynamic render quality based on FPS performance (visionOS 26+)
    /// This implements Apple's WWDC25 Session 294 dynamic render quality API,
    /// extended to also dynamically adjust shader parameters (iterations, ray steps).
    func updateDynamicRenderQuality(fps: Double, deltaTime: TimeInterval) {
        if #available(visionOS 26.0, *) {
            guard let manager = dynamicRenderQualityManager as? DynamicRenderQualityManager else { return }

            let settings = appModel.renderSettings

            // Sync manager settings with RenderSettings (in case user changed them)
            manager.isEnabled = settings.dynamicRenderQualityEnabled
            manager.minQuality = settings.dynamicRenderQualityMin
            manager.maxQuality = settings.dynamicRenderQualityMax

            // Update the manager with current FPS - resolution scaling only applies if foveation is available
            let canUseResolutionScaling = layerRenderer.configuration.isFoveationEnabled
            manager.update(fps: fps, deltaTime: deltaTime,
                           layerRenderer: layerRenderer,
                           applyResolutionScaling: canUseResolutionScaling)

            // Sync current quality back to settings for UI display
            settings.currentRenderQuality = manager.currentQuality

            // === APPLY EFFECTIVE SHADER PARAMETERS ===
            // This is where the quality percentage actually affects rendering!
            // Scale iterations and ray steps based on current quality level.
            if manager.isEnabled {
                let effectiveIterations = manager.effectiveIterations(base: settings.baseFractalIterations)
                let effectiveRaySteps = manager.effectiveRaySteps(base: settings.baseMaxRaySteps)
                settings.fractalIterations = effectiveIterations
                settings.maxRaySteps = effectiveRaySteps
            }

            // Log status once
            if !hasLoggedDynamicQualityStatus && manager.isEnabled {
                hasLoggedDynamicQualityStatus = true
                let mode = canUseResolutionScaling ? "resolution + shader params" : "shader params only"
                if RENDERER_DEBUG { print("✓ Dynamic render quality active (\(mode)): adjusting based on FPS") }
            }

            // Optionally hint scene complexity when fractal parameters change significantly
            // This helps the manager anticipate quality needs
            let complexity = DynamicRenderQualityManager.estimateFractalComplexity(
                iterations: settings.baseFractalIterations,
                raySteps: settings.baseMaxRaySteps,
                tileSize: settings.tileSize
            )
            manager.hintSceneComplexity(complexity, layerRenderer: layerRenderer)
        }
    }
}
