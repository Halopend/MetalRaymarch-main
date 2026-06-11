#if os(macOS) || os(iOS)
import simd

/// Calibrated device tilt in g-relative units, shared by the macOS Sudden
/// Motion Sensor reader and the iPad CoreMotion reader. `roll` is left/right
/// tilt, `pitch` is front/back tilt; both are zero at the calibration pose.
struct MotionTilt {
    var roll: Float
    var pitch: Float
}

/// Common interface for the platform tilt sensors so `ThresholdMacRenderer`'s
/// `applyTiltControl` stays platform-agnostic. macOS reads the built-in
/// accelerometer (Intel only); iOS reads CoreMotion gravity.
protocol TiltMotionSensor: AnyObject {
    /// `true` when a usable sensor exists on this device.
    var isAvailable: Bool { get }
    /// Starts/stops sampling. macOS reads on demand and ignores this; iOS uses
    /// it to avoid running CoreMotion when tilt control is off.
    func setActive(_ active: Bool)
    /// Recenters so the current physical orientation reads as zero tilt.
    func calibrate()
    /// Returns the calibrated tilt, or `nil` when unavailable / no sample ready.
    func read() -> MotionTilt?
}

extension TiltMotionSensor {
    // Default no-op: sensors that sample on demand (macOS SMS) need no lifecycle.
    func setActive(_ active: Bool) {}
}

#if os(macOS)
typealias PlatformTiltSensor = MacMotionSensor
#elseif os(iOS)
typealias PlatformTiltSensor = IOSTiltMotionSensor
#endif
#endif
