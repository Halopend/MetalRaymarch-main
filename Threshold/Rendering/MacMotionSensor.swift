#if os(macOS)
import Foundation
import IOKit
import simd

/// Reads the built-in Sudden Motion Sensor (SMS) accelerometer present on Intel
/// MacBook / MacBook Pro / MacBook Air models via IOKit's `SMCMotionSensor`
/// service.
///
/// Apple Silicon Macs (and desktops) do not expose an accessible built-in
/// accelerometer, so `isAvailable` is `false` there and every `read()` returns
/// `nil` — callers should treat this as a graceful no-op.
///
/// The sensor reports three signed 16-bit axes (roughly ±256 per g). We expose a
/// calibrated tilt relative to the orientation captured at first use, so the
/// resting laptop pose maps to zero.
final class MacMotionSensor: TiltMotionSensor {
    private var connection: io_connect_t = 0
    private let isOpen: Bool
    private var baseline: SIMD3<Float>?

    /// IOKit user-client method selector for reading the SMS axes.
    private static let readSelector: UInt32 = 5
    /// Per-g scale the SMS reports (empirically ~250–256 counts per g).
    private static let countsPerG: Float = 250.0

    var isAvailable: Bool { isOpen }

    init() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("SMCMotionSensor"))
        guard service != 0 else {
            isOpen = false
            return
        }
        defer { IOObjectRelease(service) }

        var conn: io_connect_t = 0
        let result = IOServiceOpen(service, mach_task_self_, 0, &conn)
        if result == KERN_SUCCESS {
            connection = conn
            isOpen = true
        } else {
            isOpen = false
        }
    }

    deinit {
        if isOpen {
            IOServiceClose(connection)
        }
    }

    /// Recenters so the current physical orientation reads as zero tilt.
    func calibrate() {
        baseline = readRaw()
    }

    /// Returns calibrated tilt, or `nil` when the sensor is unavailable or the
    /// read failed. The first successful read also establishes the baseline.
    func read() -> MotionTilt? {
        guard isOpen, let raw = readRaw() else { return nil }
        let base = baseline ?? raw
        if baseline == nil { baseline = raw }

        let delta = (raw - base) / Self.countsPerG
        return MotionTilt(roll: delta.x, pitch: delta.y)
    }

    /// Reads the three raw axes from the sensor. Returns `nil` on failure.
    private func readRaw() -> SIMD3<Float>? {
        // The SMCMotionSensor user client expects a 40-byte (5 × UInt64) output
        // struct; the first three signed 16-bit values are the X/Y/Z axes.
        var output = [UInt64](repeating: 0, count: 5)
        var outputSize = output.count

        let result = output.withUnsafeMutableBytes { buffer -> kern_return_t in
            IOConnectCallStructMethod(connection,
                                      Self.readSelector,
                                      nil,
                                      0,
                                      buffer.baseAddress,
                                      &outputSize)
        }

        guard result == KERN_SUCCESS else { return nil }

        let axes = output.withUnsafeBytes { raw -> SIMD3<Float> in
            let i16 = raw.bindMemory(to: Int16.self)
            return SIMD3<Float>(Float(i16[0]), Float(i16[1]), Float(i16[2]))
        }
        return axes
    }
}
#endif
