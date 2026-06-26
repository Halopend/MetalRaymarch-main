//
//  AdaptiveRenderQualityController.swift
//  Threshold
//
//  Vision Pro adaptive render-quality governor.
//
//  Closed-loop controller that nudges the compositor Render Quality DOWN when the
//  frame rate sags and back UP toward the user's ceiling when headroom returns.
//  The user's Render Quality slider is treated as the CEILING (max sharpness); the
//  controller renders at or below it and never below `QualityConfig.visionMinRenderQuality`.
//
//  Why it stays smooth and quiet:
//  - `layerRenderer.renderQuality` is ramped by Apple's compositor over a smoothed
//    transition (see `Renderer.applyRenderQualityIfNeeded`), so stepping it
//    occasionally reads as a gentle tween, not a snap.
//  - Adjustments happen at most once per `adjustInterval` (semi-infrequent), and
//    only outside a wide FPS dead-zone (`lowFPS`...`recoverFPS`). That hysteresis +
//    cooldown lets the loop settle at an equilibrium instead of hunting or getting
//    pinned at the floor.
//

import QuartzCore

/// Stateful — store one instance per renderer and call `update` once per frame.
/// Not thread-safe on its own; the visionOS `Renderer` actor serializes access.
struct AdaptiveRenderQualityController {
    /// Drop quality when smoothed FPS falls below this.
    var lowFPS: Double = 50
    /// Recover quality only once smoothed FPS climbs above this (hysteresis band).
    var recoverFPS: Double = 72
    /// Quality change per adjustment.
    var step: Float = 0.05
    /// Minimum spacing between adjustments — "semi-infrequent" so the compositor
    /// can tween each step before the next one lands.
    var adjustInterval: CFTimeInterval = 1.5

    /// Effective quality currently applied; `nil` until the first frame seeds it
    /// from the ceiling.
    private var effective: Float?
    private var lastAdjust: CFTimeInterval = 0

    /// Returns the render quality to apply this frame.
    /// - Parameters:
    ///   - smoothedFPS: the renderer's smoothed frame rate (prior-frame value is fine).
    ///   - ceiling: the user's Render Quality slider (the maximum allowed).
    ///   - now: a monotonic timestamp (`CACurrentMediaTime()`).
    ///   - enabled: the user's auto-adjust toggle.
    mutating func update(smoothedFPS: Double, ceiling: Float, now: CFTimeInterval, enabled: Bool) -> Float {
        let floor = min(QualityConfig.visionMinRenderQuality, ceiling)

        // Disabled → pass the ceiling through and re-seed, so re-enabling starts
        // from the user's current setting rather than a stale effective value.
        guard enabled else {
            effective = ceiling
            return ceiling
        }

        // Seed from the ceiling, then clamp into [floor, ceiling] every frame so a
        // slider move is honored immediately (the user can always cap quality).
        var quality = min(effective ?? ceiling, ceiling)
        quality = max(quality, floor)

        // Only consider a step on the cooldown, and only once FPS is meaningful.
        if smoothedFPS > 1, now - lastAdjust >= adjustInterval {
            if smoothedFPS < lowFPS, quality > floor {
                quality = max(floor, quality - step)   // shed load
                lastAdjust = now
            } else if smoothedFPS > recoverFPS, quality < ceiling {
                quality = min(ceiling, quality + step)  // recover toward the ceiling
                lastAdjust = now
            }
        }

        effective = quality
        return quality
    }
}
