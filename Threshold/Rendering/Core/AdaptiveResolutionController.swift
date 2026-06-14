#if os(macOS) || os(iOS)
import Foundation
import QuartzCore
import Synchronization

/// Dynamic-resolution controller for the MetalFX upscaling path.
///
/// The raymarch fragment shader dominates frame cost, and that cost scales with
/// the number of pixels rendered. When the user has opted into upscaling (a
/// sub-native `resolutionScale`), the MetalFX scaler reconstructs detail from a
/// reduced-resolution render — so the cheapest way to hold a frame budget is to
/// render *even fewer* input pixels under load and recover toward the user's
/// chosen scale when there is headroom. This controller does exactly that.
///
/// Design notes:
/// - The user's `resolutionScale` is treated as a **ceiling**; the controller
///   only ever renders at or below it, never above. An explicit native (100%)
///   choice is left untouched by the caller (it never engages upscaling).
/// - Decisions are driven by **measured GPU frame time** (command-buffer
///   timestamps), not CPU FPS, so the budget reflects real GPU load.
/// - Scale changes are **quantized** to discrete steps and **rate-limited** with
///   asymmetric cooldowns. Every change resizes the offscreen targets (and
///   resets temporal history), so churn is deliberately throttled: quick to shed
///   load, slow and conservative to recover.
///
/// `record(gpuTime:)` runs on the command-buffer completion thread;
/// `currentScale(ceiling:)` runs on the render thread. State is guarded by a
/// `Mutex` so the cross-thread handoff is race-free.
final class AdaptiveResolutionController: Sendable {
    struct Config {
        /// Target GPU frame time in seconds (e.g. `1/60`).
        var targetFrameTime: Double = 1.0 / 60.0
        /// Absolute lower bound on the render scale.
        var floorScale: Float = 0.34
        /// Quantization granularity; also the per-change step size.
        var step: Float = 0.05
        /// Minimum seconds between reductions (shed load quickly).
        var downCooldown: Double = 0.30
        /// Minimum seconds between increases (recover cautiously to avoid ping-pong).
        var upCooldown: Double = 0.90
        /// GPU/target ratio above which the scale is reduced.
        var overBudgetRatio: Double = 1.05
        /// GPU/target ratio below which the scale is increased.
        var underBudgetRatio: Double = 0.80
        /// EMA smoothing factor for the measured GPU time (0…1, higher = snappier).
        var smoothing: Double = 0.15
    }

    private struct State {
        var smoothedGPUTime: Double = 0
        var scale: Float = 1.0
        var ceiling: Float = 1.0
        var lastChange: Double = 0
        var initialized = false
    }

    private let config: Config
    private let state = Mutex(State())

    init(config: Config = Config()) {
        self.config = config
    }

    /// Render thread: the effective render scale to use this frame, clamped to
    /// `[floorScale, ceiling]`. Pass the user's `resolutionScale` as the ceiling.
    func currentScale(ceiling: Float) -> Float {
        state.withLock { s in
            s.ceiling = ceiling
            if !s.initialized {
                s.scale = ceiling
                s.initialized = true
            }
            // The ceiling can move (slider) between frames — keep scale within it.
            s.scale = min(max(s.scale, config.floorScale), ceiling)
            return s.scale
        }
    }

    /// Completion thread: feed a measured GPU frame time (seconds) for the frame
    /// that just finished. Adjusts the scale at most once per call, respecting the
    /// cooldowns and quantization step.
    func record(gpuTime: Double) {
        guard gpuTime > 0 else { return }
        let now = CACurrentMediaTime()
        state.withLock { s in
            if s.smoothedGPUTime == 0 {
                s.smoothedGPUTime = gpuTime
            } else {
                s.smoothedGPUTime += (gpuTime - s.smoothedGPUTime) * config.smoothing
            }

            let ratio = s.smoothedGPUTime / config.targetFrameTime

            if ratio > config.overBudgetRatio,
               s.scale > config.floorScale,
               now - s.lastChange >= config.downCooldown {
                s.scale = max(config.floorScale, s.scale - config.step)
                s.lastChange = now
            } else if ratio < config.underBudgetRatio,
                      s.scale < s.ceiling,
                      now - s.lastChange >= config.upCooldown {
                s.scale = min(s.ceiling, s.scale + config.step)
                s.lastChange = now
            }
        }
    }

    /// Drops the smoothed history (e.g. after a long stall or app resume) so a
    /// single anomalous frame can't bias the next decision.
    func reset() {
        state.withLock { s in
            s.smoothedGPUTime = 0
        }
    }
}
#endif
