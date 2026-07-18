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

    @Test("render quality rejects non-finite values")
    func renderQualitySanitization() {
        #expect(QualityConfig.clampedVisionRenderQuality(.nan) == QualityConfig.visionDefaultRenderQuality)
        #expect(QualityConfig.clampedVisionRenderQuality(.infinity) == QualityConfig.visionDefaultRenderQuality)
        #expect(QualityConfig.clampedVisionRenderQuality(-.infinity) == QualityConfig.visionDefaultRenderQuality)

        var config = QualityConfig()
        config.renderQuality = .nan
        config.clamp()
        #expect(config.renderQuality == QualityConfig.visionDefaultRenderQuality)
    }

    @Test("temporal starts default on while smart advance remains opt-in")
    func raymarchAcceleratorDefaultsAndExplicitChoices() throws {
        let defaults = QualityConfig()
        #expect(defaults.computeTemporalReprojectionEnabled == true)
        #expect(defaults.smartAdvanceEnabled == false)

        let legacy = try JSONDecoder().decode(QualityConfig.self, from: Data("{}".utf8))
        #expect(legacy.computeTemporalReprojectionEnabled == true)
        #expect(legacy.smartAdvanceEnabled == false)

        var explicitChoices = defaults
        explicitChoices.computeTemporalReprojectionEnabled = false
        explicitChoices.smartAdvanceEnabled = true
        let decoded = try JSONDecoder().decode(
            QualityConfig.self,
            from: JSONEncoder().encode(explicitChoices)
        )
        #expect(decoded.computeTemporalReprojectionEnabled == false)
        #expect(decoded.smartAdvanceEnabled == true)
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
