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

    @Test("default resolution is 50 percent")
    func resolutionDefaults() {
        #expect(QualityConfig().resolutionScale == 0.5)
        #expect(SceneQualityTarget.standard.macResolutionScale == 0.5)

        #if os(macOS)
        #expect(RenderSettings().resolutionScale == 0.5)
        #endif
    }

    @Test("cone marching defaults to 84 percent")
    func coneMarchingDefaults() throws {
        #expect(QualityConfig().coneMarchStrength == 0.84)
        #expect(ControlCatalog.coneMarchStrength.defaultValue == 0.84)

        let legacy = try JSONDecoder().decode(QualityConfig.self, from: Data("{}".utf8))
        #expect(legacy.coneMarchStrength == 0.84)
    }

    @Test("cone marching supports the extended 200 percent range")
    func coneMarchingExtendedRange() {
        #expect(ControlCatalog.coneMarchStrength.range == 0.0...2.0)

        var config = QualityConfig()
        config.coneMarchStrength = 1.5
        config.clamp()
        #expect(config.coneMarchStrength == 1.5)

        config.coneMarchStrength = 3.0
        config.clamp()
        #expect(config.coneMarchStrength == 2.0)

        let projection = RenderPrecompute.makePerspectiveProjection(
            fovyRadians: .pi / 2,
            aspect: 1,
            nearZ: 0.1,
            farZ: 500
        )
        let formerMaximum = RenderPrecompute.coneMarchScale(
            strength: 1,
            projection: projection,
            viewportHeight: 1_000
        )
        let extendedMaximum = RenderPrecompute.coneMarchScale(
            strength: 2,
            projection: projection,
            viewportHeight: 1_000
        )
        #expect(abs(extendedMaximum - formerMaximum * 2) < 1e-8)
    }

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
