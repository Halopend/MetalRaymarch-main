#if os(macOS) || os(iOS) || os(visionOS)
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
        /// Ceiling on the backed-off up-cooldown after repeated bounce-backs (see
        /// `record(gpuTime:)`). Without a cap a pathological scene could back off
        /// forever; this bounds the worst case to "recheck at most this often".
        var maxUpCooldown: Double = 8.0
        /// A downshift within this long of the last upshift means the upshift
        /// didn't stick — the true equilibrium sits between two quantized steps
        /// (very common for a raymarch workload hovering near budget), so
        /// retrying every `upCooldown` forever just thrashes the render size,
        /// discarding MetalFX temporal history on each change and keeping the
        /// image perpetually soft. Treat it as a bounce and back off.
        var bounceWindow: Double = 2.0
        /// How long the scale must hold without needing a downshift before the
        /// backed-off up-cooldown resets to its base value — confirms the
        /// bounce was a real boundary and not a one-off spike (a stall, a
        /// transient GC/thermal blip) before letting recovery attempts resume
        /// at full frequency.
        var stabilityDecayWindow: Double = 6.0
    }

    private struct State {
        var smoothedGPUTime: Double = 0
        var scale: Float = 1.0
        var ceiling: Float = 1.0
        var lastChange: Double = 0
        var initialized = false
        /// When the most recent upshift/downshift happened (`-.infinity` until
        /// the first one) — used to detect a downshift bouncing off a recent
        /// upshift, and to know how long the current scale has held.
        var lastUpshiftTime: Double = -.infinity
        var lastDownshiftTime: Double = -.infinity
        /// Current up-cooldown; grows on a detected bounce, decays after
        /// sustained stability. Starts at the base `Config.upCooldown`.
        var dynamicUpCooldown: Double
    }

    private let config: Config
    private let state: Mutex<State>

    init(config: Config = Config()) {
        self.config = config
        self.state = Mutex(State(dynamicUpCooldown: config.upCooldown))
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
                // A downshift shortly after an upshift means the upshift didn't
                // stick — the equilibrium sits between two quantized steps, so
                // retrying at the base cooldown would just thrash forever
                // (each change resets MetalFX temporal history). Back off.
                if now - s.lastUpshiftTime < config.bounceWindow {
                    s.dynamicUpCooldown = min(config.maxUpCooldown, s.dynamicUpCooldown * 2.0)
                }
                s.scale = max(config.floorScale, s.scale - config.step)
                s.lastChange = now
                s.lastDownshiftTime = now
            } else if ratio < config.underBudgetRatio,
                      s.scale < s.ceiling,
                      now - s.lastChange >= s.dynamicUpCooldown {
                s.scale = min(s.ceiling, s.scale + config.step)
                s.lastChange = now
                s.lastUpshiftTime = now
            } else if s.dynamicUpCooldown > config.upCooldown,
                      now - s.lastDownshiftTime >= config.stabilityDecayWindow {
                // Held this scale without needing to shed load for a while —
                // the earlier bounce likely isn't the steady-state boundary
                // anymore (scene/settings changed), so let recovery attempts
                // resume at full frequency instead of staying backed off forever.
                s.dynamicUpCooldown = config.upCooldown
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
