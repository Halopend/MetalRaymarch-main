#if os(iOS)
import CoreMotion
import simd

/// Reads the iPad's built-in motion sensors via CoreMotion and exposes a
/// calibrated tilt, mirroring the `MacMotionSensor` interface so the shared
/// `ThresholdMacRenderer.applyTiltControl` is platform-agnostic.
///
/// We use `CMDeviceMotion.gravity` — a gravity-direction unit vector (in g)
/// expressed in the device frame. The calibrated tilt is the per-axis delta
/// from the orientation captured at first use (or on `calibrate()`), so the
/// resting pose maps to zero. Because both sensors report g-relative deltas,
/// the renderer's deadzone (0.04 g) and orbit gain apply identically across
/// platforms.
///
/// CoreMotion device-motion does not require a usage-description Info.plist key.
final class IOSTiltMotionSensor: TiltMotionSensor {
    private let manager = CMMotionManager()
    private var isStarted = false
    private var baseline: SIMD2<Float>?

    var isAvailable: Bool { manager.isDeviceMotionAvailable }

    init() {
        manager.deviceMotionUpdateInterval = 1.0 / 60.0
    }

    deinit {
        setActive(false)
    }

    func setActive(_ active: Bool) {
        guard manager.isDeviceMotionAvailable else { return }

        if active {
            guard !isStarted else { return }
            manager.deviceMotionUpdateInterval = 1.0 / 60.0
            manager.startDeviceMotionUpdates()
            isStarted = true
            baseline = nil
        } else if isStarted {
            manager.stopDeviceMotionUpdates()
            isStarted = false
            baseline = nil
        }
    }

    /// Recenters so the current physical orientation reads as zero tilt.
    func calibrate() {
        setActive(true)
        baseline = readRaw()
    }

    /// Returns calibrated tilt, or `nil` when motion is unavailable or no sample
    /// is ready yet. The first successful read also establishes the baseline.
    func read() -> MotionTilt? {
        guard isStarted, let raw = readRaw() else { return nil }
        let base = baseline ?? raw
        if baseline == nil { baseline = raw }
        let delta = raw - base
        return MotionTilt(roll: delta.x, pitch: delta.y)
    }

    /// Reads the current gravity-direction X/Y components (in g). Returns `nil`
    /// until the first device-motion sample arrives.
    private func readRaw() -> SIMD2<Float>? {
        guard let gravity = manager.deviceMotion?.gravity else { return nil }
        return SIMD2<Float>(Float(gravity.x), Float(gravity.y))
    }
}
#endif
