#if os(macOS)
/// macOS doesn't expose built-in computer motion through a supported public
/// API. Keep tilt control unavailable instead of relying on an undocumented
/// IOKit user-client contract that isn't suitable for App Store distribution.
final class MacMotionSensor: TiltMotionSensor {
    let isAvailable = false
    func calibrate() {}
    func read() -> MotionTilt? { nil }
}
#endif
