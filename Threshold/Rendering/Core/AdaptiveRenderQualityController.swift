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
    /// Drop quality when smoothed FPS falls below this. Seventy-two is the
    /// lowest cadence that still feels consistently fluid in-headset; waiting
    /// until the old 50 FPS threshold made the governor tolerate visible judder.
    var lowFPS: Double = 72
    /// Recover quality only once smoothed FPS climbs above this (hysteresis band).
    var recoverFPS: Double = 84
    /// Below this cadence the app is badly GPU-bound, so shed resolution faster.
    var criticalFPS: Double = 50
    /// Quality change per adjustment.
    var step: Float = 0.05
    /// Larger step used only while the presentation cadence is critically low.
    var criticalStep: Float = 0.10
    /// Minimum spacing between ordinary downscale adjustments.
    var adjustInterval: CFTimeInterval = 0.75
    /// Critical downscaling reacts promptly, but still leaves time for the
    /// compositor's smoothed render-quality transition to begin.
    var criticalAdjustInterval: CFTimeInterval = 0.5
    /// Recovery is deliberately slower than load shedding to prevent oscillation.
    var recoverInterval: CFTimeInterval = 1.5

    /// Effective quality currently applied; `nil` until the first frame seeds it
    /// from the ceiling.
    private var effective: Float?
    private var lastAdjust: CFTimeInterval = 0

    /// Returns the render quality to apply this frame.
    /// - Parameters:
    ///   - smoothedFPS: the renderer's smoothed frame rate (prior-frame value is fine).
    ///   - ceiling: the user's Render Quality slider (the maximum allowed).
    ///   - sceneFloor: the loaded scene's preferred quality floor (a high/ultra
    ///     scene lifts this so it resists downscaling). Sustained low FPS may move
    ///     below it; only the global minimum is hard.
    ///   - now: a monotonic timestamp (`CACurrentMediaTime()`).
    ///   - enabled: the user's auto-adjust toggle.
    mutating func update(smoothedFPS: Double, ceiling: Float, sceneFloor: Float, now: CFTimeInterval, enabled: Bool) -> Float {
        let ceiling = QualityConfig.clampedVisionRenderQuality(ceiling)
        let hardFloor = QualityConfig.visionMinRenderQuality
        // A scene's authored target is a soft preference. It slows further
        // downscaling once reached, but must never trap a heavy scene at a
        // visibly stuttering cadence.
        let preferredFloor = min(
            ceiling,
            QualityConfig.clampedVisionRenderQuality(sceneFloor, fallback: hardFloor)
        )

        // Disabled → pass the ceiling through and re-seed, so re-enabling starts
        // from the user's current setting rather than a stale effective value.
        guard enabled else {
            effective = ceiling
            return ceiling
        }

        // Seed from the ceiling, then clamp into [hardFloor, ceiling] every frame so a
        // slider move is honored immediately (the user can always cap quality).
        var quality = min(effective ?? ceiling, ceiling)
        quality = max(quality.isFinite ? quality : ceiling, hardFloor)

        // Only consider a step once FPS and the monotonic timestamp are valid.
        if smoothedFPS.isFinite, smoothedFPS > 1, now.isFinite {
            let elapsed = max(0, now - lastAdjust)
            if smoothedFPS < criticalFPS,
               quality > hardFloor,
               elapsed >= criticalAdjustInterval {
                quality = max(hardFloor, quality - criticalStep)
                lastAdjust = now
            } else if smoothedFPS < lowFPS,
                      quality > hardFloor,
                      elapsed >= adjustInterval {
                // Below an authored quality preference, continue shedding load at
                // half speed. Smoothness wins, but the hint still has weight.
                let downStep = quality <= preferredFloor ? step * 0.5 : step
                quality = max(hardFloor, quality - downStep)
                lastAdjust = now
            } else if smoothedFPS > recoverFPS,
                      quality < ceiling,
                      elapsed >= recoverInterval {
                quality = min(ceiling, quality + step)
                lastAdjust = now
            }
        }

        effective = quality
        return quality
    }
}
