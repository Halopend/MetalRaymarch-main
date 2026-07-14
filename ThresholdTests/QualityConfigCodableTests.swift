//
//  QualityConfigCodableTests.swift
//  ThresholdTests
//
//  Guards the Codable round-trip of the cone-coverage AA accel toggle
//  (coneCoverageAAEnabled). QualityConfig is device-local (not scene-persisted),
//  but it IS Codable and persisted to UserDefaults via SettingsPersistence, so a
//  new field must survive encode → decode and default to false when a key is
//  absent (old settings blobs). Mirrors the established smartAdvanceEnabled
//  pattern; see [[preset-persistence-dropped-fields]].
//

import Testing
import Foundation
@testable import Threshold

@Suite("QualityConfig — raymarch accelerator persistence")
struct QualityConfigCodableTests {

    @Test("raymarch accelerators default on and preserve explicit opt-out")
    func raymarchAcceleratorDefaultsAndOptOut() throws {
        let defaults = QualityConfig()
        #expect(defaults.computeTemporalReprojectionEnabled == true)
        #expect(defaults.smartAdvanceEnabled == true)

        let legacy = try JSONDecoder().decode(QualityConfig.self, from: Data("{}".utf8))
        #expect(legacy.computeTemporalReprojectionEnabled == true)
        #expect(legacy.smartAdvanceEnabled == true)

        var optedOut = defaults
        optedOut.computeTemporalReprojectionEnabled = false
        optedOut.smartAdvanceEnabled = false
        let decoded = try JSONDecoder().decode(
            QualityConfig.self,
            from: JSONEncoder().encode(optedOut)
        )
        #expect(decoded.computeTemporalReprojectionEnabled == false)
        #expect(decoded.smartAdvanceEnabled == false)
    }

    @Test("coneCoverageAAEnabled survives encode → decode")
    func coneCoverageAARoundTrips() throws {
        var config = QualityConfig()
        #expect(config.coneCoverageAAEnabled == false)   // default off

        config.coneCoverageAAEnabled = true
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(QualityConfig.self, from: data)
        #expect(decoded.coneCoverageAAEnabled == true)
    }

    @Test("coneCoverageAAEnabled defaults to false when the key is absent")
    func coneCoverageAADefaultsWhenMissing() throws {
        // An old settings blob with no coneCoverageAAEnabled key must decode to the
        // safe default rather than throwing.
        let json = Data("{}".utf8)
        let decoded = try JSONDecoder().decode(QualityConfig.self, from: json)
        #expect(decoded.coneCoverageAAEnabled == false)
    }
}
