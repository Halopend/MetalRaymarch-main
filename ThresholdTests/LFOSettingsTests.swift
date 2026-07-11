import Testing
@testable import Threshold

@Suite("LFO settings")
struct LFOSettingsTests {
    @Test("Frequency reaches one millihertz")
    func frequencyReachesOneMillihertz() {
        var settings = LFOSettings(
            enabled: true,
            frequency: 0.001,
            amplitude: 0.2,
            shape: .sine
        )

        settings.sanitizeInPlace()

        #expect(settings.frequency == 0.001)
    }

    @Test("Frequency clamps below the supported floor")
    func frequencyClampsBelowFloor() {
        var settings = LFOSettings(
            enabled: true,
            frequency: 0.000_01,
            amplitude: 0.2,
            shape: .sine
        )

        settings.sanitizeInPlace()

        #expect(settings.frequency == 0.001)
    }
}
