//
//  DynamicRenderQualityManager.swift
//  MetalProject
//
//  Dynamic Render Quality implementation based on WWDC25 Session 294
//  "What's new in Metal rendering for immersive apps"
//
//  This manager dynamically adjusts LayerRenderer.renderQuality based on
//  frame rate performance, allowing the system to allocate more compute
//  resources when needed and increase visual fidelity when possible.
//

import Foundation
import CompositorServices

/// Manages dynamic render quality adjustments based on frame rate performance.
///
/// From Apple's guidance (WWDC25 #294):
/// - Higher render quality = larger textures, more detail, more GPU work
/// - Lower render quality = smaller textures, less detail, faster rendering
/// - Quality changes are smoothly transitioned by the system
///
/// For raymarching fractals, this allows:
/// - Lower quality when exploring complex, dense fractal regions
/// - Higher quality when viewing simpler areas or when paused
/// - Automatic FPS-based adjustment without user intervention
@available(visionOS 26.0, *)
final class DynamicRenderQualityManager {
    
    // MARK: - Configuration
    
    /// Target frame rate for quality adjustments (default: 90 FPS for visionOS)
    var targetFPS: Double = 90.0
    
    /// Threshold below which quality starts decreasing (target - buffer)
    var decreaseThreshold: Double { targetFPS - 5.0 }  // 85 FPS
    
    /// Threshold above which quality can increase (target - small buffer)
    var increaseThreshold: Double { targetFPS - 2.0 }  // 88 FPS
    
    /// Minimum render quality (0.5 = 50% of max resolution)
    var minQuality: Float = 0.5
    
    /// Maximum render quality (1.0 = full resolution)
    var maxQuality: Float = 1.0
    
    /// Default/baseline render quality
    var defaultQuality: Float = 0.7
    
    /// Rate of quality decrease per second when below threshold
    var decreaseRate: Float = 0.15
    
    /// Rate of quality increase per second when above threshold
    var increaseRate: Float = 0.08
    
    /// Smoothing speed for FPS averaging (Freya Holmér exponential decay)
    /// Higher = more responsive, lower = smoother. 10.0 gives ~63% convergence in 100ms
    var fpsSmoothingSpeed: Double = 10.0
    
    /// Minimum time between quality updates (prevents oscillation)
    var updateCooldown: TimeInterval = 0.1
    
    /// Enable/disable dynamic quality adjustment
    var isEnabled: Bool = true
    
    // MARK: - State
    
    /// Current render quality (0.0 - 1.0)
    private(set) var currentQuality: Float
    
    /// Smoothed FPS value for stable quality decisions
    private var smoothedFPS: Double = 90.0
    
    /// Last time quality was updated
    private var lastUpdateTime: TimeInterval = 0
    
    /// Frame count for statistics
    private var frameCount: Int = 0
    
    /// Total time below threshold for logging
    private var timeBelowThreshold: TimeInterval = 0
    
    /// Debug logging enabled
    var debugLogging: Bool = false
    
    // MARK: - Initialization
    
    init(defaultQuality: Float = 0.7) {
        self.currentQuality = defaultQuality
        self.defaultQuality = defaultQuality
    }
    
    // MARK: - Public API
    
    /// Update the quality manager with the current frame's FPS.
    /// Call this every frame to enable dynamic adjustments.
    ///
    /// - Parameters:
    ///   - fps: Current frame rate (instantaneous or smoothed)
    ///   - deltaTime: Time since last frame in seconds
    ///   - layerRenderer: The LayerRenderer to apply quality changes to (optional, for resolution scaling)
    ///   - applyResolutionScaling: Whether to apply LayerRenderer.renderQuality (requires foveation)
    func update(fps: Double, deltaTime: TimeInterval, layerRenderer: LayerRenderer? = nil, applyResolutionScaling: Bool = true) {
        guard isEnabled else { return }
        
        frameCount += 1
        
        // Smooth the FPS using frame-rate independent exponential decay (Freya Holmér technique)
        // factor = 1 - e^(-speed * dt), gives consistent smoothing regardless of frame rate
        let fpsSmoothFactor = 1.0 - exp(-fpsSmoothingSpeed * deltaTime)
        smoothedFPS = smoothedFPS + (fps - smoothedFPS) * fpsSmoothFactor
        
        // Apply cooldown to prevent rapid oscillation
        let currentTime = CACurrentMediaTime()
        guard currentTime - lastUpdateTime >= updateCooldown else { return }
        lastUpdateTime = currentTime
        
        // Calculate quality adjustment
        let previousQuality = currentQuality
        
        if smoothedFPS < decreaseThreshold {
            // Below target: decrease quality to improve performance
            let deficit = Float((decreaseThreshold - smoothedFPS) / decreaseThreshold)
            let adjustment = decreaseRate * Float(deltaTime) * (1.0 + deficit * 2.0)
            currentQuality = max(minQuality, currentQuality - adjustment)
            timeBelowThreshold += deltaTime
        } else if smoothedFPS > increaseThreshold && currentQuality < maxQuality {
            // Above target with headroom: gradually increase quality
            let surplus = Float((smoothedFPS - increaseThreshold) / targetFPS)
            let adjustment = increaseRate * Float(deltaTime) * (1.0 + surplus)
            currentQuality = min(maxQuality, currentQuality + adjustment)
        }
        
        // Only apply if quality changed meaningfully (avoid constant updates)
        if abs(currentQuality - previousQuality) > 0.01 {
            // Apply resolution scaling if LayerRenderer is provided and foveation is enabled
            if applyResolutionScaling, let layerRenderer = layerRenderer,
               layerRenderer.configuration.isFoveationEnabled {
                applyQuality(to: layerRenderer)
            }
            
            if debugLogging {
                print("[DynQuality] FPS: \(String(format: "%.1f", smoothedFPS)) → Quality: \(String(format: "%.2f", currentQuality))")
            }
        }
    }
    
    /// Get the effective iteration count based on current quality and base value.
    /// Lower quality = fewer iterations for better performance.
    func effectiveIterations(base: Int) -> Int {
        // Scale iterations: at 1.0 quality use full, at minQuality use ~60%
        let scale = 0.6 + 0.4 * currentQuality
        return max(4, Int(Float(base) * scale))
    }
    
    /// Get the effective ray steps based on current quality and base value.
    /// Lower quality = fewer ray steps for better performance.
    func effectiveRaySteps(base: Int) -> Int {
        // Scale ray steps: at 1.0 quality use full, at minQuality use ~50%
        let scale = 0.5 + 0.5 * currentQuality
        return max(24, Int(Float(base) * scale))
    }
    
    /// Force a specific quality level (bypasses automatic adjustment temporarily)
    ///
    /// - Parameters:
    ///   - quality: Quality level (0.0 - 1.0)
    ///   - layerRenderer: Optional LayerRenderer to apply resolution quality changes to
    func setQuality(_ quality: Float, layerRenderer: LayerRenderer? = nil) {
        currentQuality = max(minQuality, min(maxQuality, quality))
        if let layerRenderer = layerRenderer, layerRenderer.configuration.isFoveationEnabled {
            applyQuality(to: layerRenderer)
        }
    }
    
    /// Reset to default quality
    func reset(layerRenderer: LayerRenderer? = nil) {
        currentQuality = defaultQuality
        smoothedFPS = targetFPS
        timeBelowThreshold = 0
        if let layerRenderer = layerRenderer, layerRenderer.configuration.isFoveationEnabled {
            applyQuality(to: layerRenderer)
        }
    }
    
    /// Get statistics for debugging/UI
    func getStats() -> (smoothedFPS: Double, quality: Float, belowThreshold: TimeInterval) {
        return (smoothedFPS, currentQuality, timeBelowThreshold)
    }
    
    // MARK: - Private
    
    private func applyQuality(to layerRenderer: LayerRenderer) {
        // The system smoothly transitions between quality levels
        layerRenderer.renderQuality = LayerRenderer.RenderQuality(currentQuality)
    }
}

// MARK: - Preset Quality Levels

@available(visionOS 26.0, *)
extension DynamicRenderQualityManager {
    
    /// Quality preset for different scene types
    enum QualityPreset {
        /// High quality for simple scenes or menus (0.9)
        case high
        /// Balanced quality for typical fractal exploration (0.7)
        case balanced
        /// Performance mode for complex scenes (0.55)
        case performance
        /// Custom quality level
        case custom(Float)
        
        var value: Float {
            switch self {
            case .high: return 0.9
            case .balanced: return 0.7
            case .performance: return 0.55
            case .custom(let v): return v
            }
        }
    }
    
    /// Apply a quality preset
    func applyPreset(_ preset: QualityPreset, layerRenderer: LayerRenderer? = nil) {
        setQuality(preset.value, layerRenderer: layerRenderer)
    }
}

// MARK: - Scene-Based Quality Hints

@available(visionOS 26.0, *)
extension DynamicRenderQualityManager {
    
    /// Hint that the scene complexity has changed.
    /// This can be called when fractal parameters change significantly.
    ///
    /// - Parameters:
    ///   - complexity: Estimated complexity (0.0 = simple, 1.0 = very complex)
    ///   - layerRenderer: Optional LayerRenderer to apply resolution quality changes to
    func hintSceneComplexity(_ complexity: Float, layerRenderer: LayerRenderer? = nil) {
        // Map complexity to quality: higher complexity → lower quality target
        // But don't force the change, just adjust the targets
        let targetQuality = maxQuality - (maxQuality - minQuality) * complexity * 0.5
        
        // If current quality is significantly higher than appropriate, nudge down
        if currentQuality > targetQuality + 0.1 {
            currentQuality = currentQuality - 0.05
            if let layerRenderer = layerRenderer, layerRenderer.configuration.isFoveationEnabled {
                applyQuality(to: layerRenderer)
            }
        }
    }
    
    /// Estimate fractal complexity from parameters
    static func estimateFractalComplexity(iterations: Int, raySteps: Int, tileSize: Int) -> Float {
        // Higher iterations and ray steps = more complex
        let iterComplexity = Float(min(iterations, 16)) / 16.0
        let rayComplexity = Float(min(raySteps, 128)) / 128.0
        
        // Smaller tiles = more work per pixel (less sharing)
        let tileComplexity = tileSize == 0 ? 1.0 : Float(8 - min(tileSize, 8)) / 8.0
        
        return (iterComplexity * 0.4 + rayComplexity * 0.3 + tileComplexity * 0.3)
    }
}
