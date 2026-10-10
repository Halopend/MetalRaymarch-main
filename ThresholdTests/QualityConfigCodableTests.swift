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

    @Test("The platform minimum survives quality persistence and live restoration")
    func minimumResolutionRoundTrip() throws {
        #if os(iOS)
        #expect(QualityConfig.minimumResolutionScale == 0.10)
        #expect(QualityConfig.maximumResolutionScale == 0.50)
        #expect(ControlCatalog.resolutionScale.range.upperBound == 0.50)
        #else
        #expect(QualityConfig.minimumResolutionScale == 0.33)
        #expect(QualityConfig.maximumResolutionScale == 1.0)
        #expect(ControlCatalog.resolutionScale.range.upperBound == 1.0)
        #endif
        var config = QualityConfig()
        config.resolutionScale = QualityConfig.minimumResolutionScale
        config.clamp()
        let restored = try JSONDecoder().decode(QualityConfig.self, from: JSONEncoder().encode(config))
        let settings = RenderSettings()
        settings.qualityConfig = restored
        #expect(settings.resolutionScale == QualityConfig.minimumResolutionScale)
        settings.resolutionScale = 0
        #expect(settings.resolutionScale == QualityConfig.minimumResolutionScale)
    }

    @Test("Retired cone warm-start settings are ignored without losing compute settings")
    func retiredConeToggleMigration() throws {
        let data = Data(#"{"coarsePrepassWarmStartEnabled":true,"tileSize":8,"computeTemporalReprojectionEnabled":false}"#.utf8)
        let config = try JSONDecoder().decode(QualityConfig.self, from: data)
        #expect(config.tileSize == 8)
        #expect(!config.computeTemporalReprojectionEnabled)
        let encoded = try JSONEncoder().encode(config)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["coarsePrepassWarmStartEnabled"] == nil)
        let restored = try JSONDecoder().decode(QualityConfig.self, from: encoded)
        #expect(restored == config)
    }

    @Test("default resolution matches the platform's Low preset")
    func resolutionDefaults() {
#if os(iOS)
        #expect(QualityConfig().resolutionScale == 0.25)
        #expect(ControlCatalog.resolutionScale.defaultValue == 0.25)
        #expect(SceneQualityTarget.standard.resolutionScale == 0.25)
        #expect(QualityConfig.minimumResolutionScale == 0.10)
#else
        #expect(QualityConfig().resolutionScale == 0.33)
        #expect(ControlCatalog.resolutionScale.defaultValue == 0.33)
        #expect(SceneQualityTarget.standard.resolutionScale == 0.33)
        #expect(QualityConfig.minimumResolutionScale == 0.33)
#endif

        #if os(macOS) || os(iOS)
        #expect(RenderSettings().resolutionScale == QualityConfig.defaultResolutionScale)
        #endif
    }

    @Test("detail budget presets scale from the platform ceiling")
    func detailBudgetPresetsUsePlatformCeiling() {
        #if os(iOS)
        #expect(DetailBudgetPreset.visiblePresets.count == 6)
        #expect(DetailBudgetPreset.minimum.scale == 0.10)
        #expect(DetailBudgetPreset.veryLow.scale == 0.20)
        #expect(DetailBudgetPreset.low.scale == 0.25)
        #expect(abs(DetailBudgetPreset.medium.scale - (1.0 / 3.0)) < 0.0001)
        #expect(abs(DetailBudgetPreset.high.scale - (5.0 / 12.0)) < 0.0001)
        #expect(DetailBudgetPreset.full.scale == 0.50)
        #expect(QualityConfig.displayedResolutionPercent(DetailBudgetPreset.minimum.scale) == 20)
        #expect(QualityConfig.displayedResolutionPercent(DetailBudgetPreset.veryLow.scale) == 40)
        #expect(QualityConfig.displayedResolutionPercent(DetailBudgetPreset.low.scale) == 50)
        #expect(QualityConfig.displayedResolutionPercent(DetailBudgetPreset.medium.scale) == 67)
        #expect(QualityConfig.displayedResolutionPercent(DetailBudgetPreset.high.scale) == 83)
        #expect(QualityConfig.displayedResolutionPercent(DetailBudgetPreset.full.scale) == 100)
        #expect(SceneQualityTarget.high.resolutionScale == 0.375)
        #expect(SceneQualityTarget.ultra.resolutionScale == 0.50)
        #else
        #expect(DetailBudgetPreset.visiblePresets.count == 4)
        #expect(DetailBudgetPreset.low.scale == 0.33)
        #expect(DetailBudgetPreset.medium.scale == 0.50)
        #expect(DetailBudgetPreset.high.scale == 0.75)
        #expect(DetailBudgetPreset.full.scale == 1.0)
        #expect(QualityConfig.displayedResolutionPercent(DetailBudgetPreset.low.scale) == 33)
        #expect(QualityConfig.displayedResolutionPercent(DetailBudgetPreset.full.scale) == 100)
        #expect(SceneQualityTarget.high.resolutionScale == 0.75)
        #expect(SceneQualityTarget.ultra.resolutionScale == 1.0)
        #endif
    }

    @Test("quality restoration clamps old resolution values to platform maximum")
    func restoredResolutionRespectsPlatformMaximum() throws {
        var config = try JSONDecoder().decode(
            QualityConfig.self,
            from: Data(#"{"resolutionScale":1.0}"#.utf8)
        )
        config.clamp()
        #expect(config.resolutionScale == QualityConfig.maximumResolutionScale)

        let settings = RenderSettings()
        settings.qualityConfig = config
        #expect(settings.resolutionScale == QualityConfig.maximumResolutionScale)
        settings.resolutionScale = 1.0
        #expect(settings.resolutionScale == QualityConfig.maximumResolutionScale)
    }

    @Test("Vision Pro default render quality matches the desktop Low detail budget")
    func visionRenderQualityDefaultsToLow() throws {
        // Vision Pro is the most thermally constrained target, so a fresh
        // install opens at the same 33% budget as the Mac/iOS Low preset and
        // the adaptive governor recovers sharpness headroom-first from there.
        #expect(QualityConfig.visionDefaultRenderQuality == 0.33)
        #expect(QualityConfig().renderQuality == 0.33)

        // The live settings and the Codable fallback agree, so a settings blob
        // missing the renderQuality key decodes to the same Low default.
        #expect(RenderSettings().renderQuality == 0.33)
        let legacy = try JSONDecoder().decode(QualityConfig.self, from: Data("{}".utf8))
        #expect(legacy.renderQuality == 0.33)

        // The governor seeds from the ceiling, so a fresh install's first
        // frame targets 33% rather than the former 0.5.
        var controller = AdaptiveRenderQualityController()
        let seeded = controller.update(
            smoothedFPS: 90,
            ceiling: QualityConfig().renderQuality,
            sceneFloor: QualityConfig.visionMinRenderQuality,
            now: 1.0,
            enabled: true
        )
        #expect(abs(seeded - 0.33) < 0.0001)
    }

    @Test("first launch quality is the Low preset")
    func firstLaunchQualityIsLowPreset() {
        // Fresh-install budgets must sit exactly on the Low preset so the UI's
        // preset chips highlight Low on first launch (see QualityPreset.detect).
        #expect(QualityConfig().baseFractalIterations == QualityPreset.low.fractalIterations)
        #expect(QualityConfig().baseMaxRaySteps == QualityPreset.low.raySteps)
        #expect(QualityPreset.detect(
            fractalIterations: QualityConfig().baseFractalIterations,
            raySteps: QualityConfig().baseMaxRaySteps
        ) == .low)

        #if os(macOS) || os(iOS)
        #expect(RenderSettings().baseFractalIterations == QualityPreset.low.fractalIterations)
        #expect(RenderSettings().baseMaxRaySteps == QualityPreset.low.raySteps)
        #endif

        // Slider reset defaults agree with the first-launch state.
        #expect(ControlCatalog.iterations.defaultValue == Float(QualityPreset.low.fractalIterations))
        #expect(ControlCatalog.maxRaySteps.defaultValue == Float(QualityPreset.low.raySteps))

        // A settings blob missing the quality keys decodes to the same Low default.
        let legacy = try? JSONDecoder().decode(QualityConfig.self, from: Data("{}".utf8))
        #expect(legacy?.baseFractalIterations == QualityPreset.low.fractalIterations)
        #expect(legacy?.baseMaxRaySteps == QualityPreset.low.raySteps)
    }

    @Test("first-launch opening scene does not stomp the Low preset")
    @MainActor
    func openingSceneKeepsLowPreset() {
        // On a fresh install restoreLastState finds no saved last state and
        // applies mandelboxDefaultPreset(). That preset must carry the Low
        // budget, and applying it must leave the device at Low.
        let opening = PresetManager.mandelboxDefaultPreset()
        #expect(opening.fractalIterations == QualityPreset.low.fractalIterations)
        #expect(opening.maxRaySteps == QualityPreset.low.raySteps)

        let fresh = RenderSettings()
        #expect(fresh.baseFractalIterations == QualityPreset.low.fractalIterations)
        opening.apply(to: fresh, scope: .session)
        #expect(fresh.baseFractalIterations == QualityPreset.low.fractalIterations)
        #expect(fresh.baseMaxRaySteps == QualityPreset.low.raySteps)

        // A preset created without explicit quality carries the same Low budget
        // (FractalPreset's placeholder defaults), so scene captures from a fresh
        // install and legacy keyless scene files stay Low too.
        let blank = FractalPreset(name: "Blank")
        #expect(blank.fractalIterations == QualityPreset.low.fractalIterations)
        #expect(blank.maxRaySteps == QualityPreset.low.raySteps)
    }

    @Test("legacy quality without resolution preserves native fallback")
    func legacyResolutionFallback() throws {
        let legacy = try JSONDecoder().decode(QualityConfig.self, from: Data("{}".utf8))
        #expect(legacy.resolutionScale == 1.0)
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
