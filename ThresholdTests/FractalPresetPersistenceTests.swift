//
//  FractalPresetPersistenceTests.swift
//  ThresholdTests
//
//  Guards the second lossy-persistence fix: ten visual scene-state fields that
//  lived in the domain configs (Display/Color/Lighting/SafetyBubble) but were
//  never captured by FractalPreset, so authoring them then saving silently lost
//  them on reload — the same class of bug as the sphere transforms in
//  SpaceModuleTests. Device-local performance/acceleration settings
//  (QualityConfig) are deliberately NOT persisted and are not exercised here.
//

import Testing
import Foundation
@testable import Threshold

@Suite("FractalPreset — previously-dropped scene state round-trips")
struct FractalPresetPersistenceTests {

    @Test("Platform / cell-shading / light-rate / extra effects / bubble-fade survive fromSettings → encode → decode → apply")
    func droppedFieldsRoundTrip() throws {
        let settings = RenderSettings()
        settings.fractalType = .mandelbox

        // Display
        settings.platformEnabled = false        // default true
        settings.platformRadius = 1.2           // default 1.888

        // Color
        settings.cellShadingEnabled = true       // default false
        settings.cellShadingLevels = 6.0         // default 4.0

        // Lighting
        settings.lightVariationRate = 0.25       // default 0.5
        var beat = BeatFlashEffect(); beat.enabled = true; beat.intensity = 0.7
        settings.beatFlashEffect = beat
        var polar = PolarRotationEffect(); polar.direction = .clockwise; polar.speed = 0.4
        settings.polarRotationEffect = polar
        var julia = JuliaDriftEffect(); julia.enabled = true; julia.speed = 0.35
        settings.juliaDriftEffect = julia

        // Safety bubble edge fade — get-only on RenderSettings, set via the config.
        var sb = settings.safetyBubbleConfig
        sb.fadeEnabled = false                    // default true
        sb.fadeWidth = 0.4                        // default 0.1
        settings.safetyBubbleConfig = sb

        // Capture → encode → decode (the path that was silently dropping values).
        let preset = FractalPreset.fromSettings(settings, name: "Dropped")
        #expect(preset.platformEnabled == false)
        #expect(preset.cellShadingEnabled == true)
        #expect(preset.safetyBubbleFadeEnabled == false)

        let data = try JSONEncoder().encode(preset)
        let decoded = try JSONDecoder().decode(FractalPreset.self, from: data)

        #expect(decoded.platformEnabled == false)
        #expect(abs((decoded.platformRadius ?? -1) - 1.2) < 1e-5)
        #expect(decoded.cellShadingEnabled == true)
        #expect(abs((decoded.cellShadingLevels ?? -1) - 6.0) < 1e-5)
        #expect(abs((decoded.lightVariationRate ?? -1) - 0.25) < 1e-5)
        #expect(decoded.beatFlashEffect?.enabled == true)
        #expect(abs((decoded.beatFlashEffect?.intensity ?? -1) - 0.7) < 1e-5)
        #expect(decoded.polarRotationEffect?.direction == .clockwise)
        #expect(abs((decoded.polarRotationEffect?.speed ?? -1) - 0.4) < 1e-5)
        #expect(decoded.juliaDriftEffect?.enabled == true)
        #expect(abs((decoded.juliaDriftEffect?.speed ?? -1) - 0.35) < 1e-5)
        #expect(decoded.safetyBubbleFadeEnabled == false)
        #expect(abs((decoded.safetyBubbleFadeWidth ?? -1) - 0.4) < 1e-5)

        // Restore into a fresh settings object.
        let fresh = RenderSettings()
        fresh.fractalType = .mandelbox
        decoded.apply(to: fresh)

        #expect(fresh.platformEnabled == false)
        #expect(abs(fresh.platformRadius - 1.2) < 1e-5)
        #expect(fresh.cellShadingEnabled == true)
        #expect(abs(fresh.cellShadingLevels - 6.0) < 1e-5)
        #expect(abs(fresh.lightVariationRate - 0.25) < 1e-5)
        #expect(fresh.beatFlashEffect.enabled == true)
        #expect(abs(fresh.beatFlashEffect.intensity - 0.7) < 1e-5)
        #expect(fresh.polarRotationEffect.direction == .clockwise)
        #expect(abs(fresh.polarRotationEffect.speed - 0.4) < 1e-5)
        #expect(fresh.juliaDriftEffect.enabled == true)
        #expect(abs(fresh.juliaDriftEffect.speed - 0.35) < 1e-5)
        #expect(fresh.safetyBubbleFadeEnabled == false)
        #expect(abs(fresh.safetyBubbleFadeWidth - 0.4) < 1e-5)
    }

    @Test("Composable Transformations (spaceWarp type/strength/params/axis) survive round-trip")
    func transformationsRoundTrip() throws {
        let settings = RenderSettings()
        settings.fractalType = .mandelbulb
        settings.spaceWarpType = SpaceWarpKind.kaleidoscope.rawValue   // 6
        settings.spaceWarpStrength = 0.8
        settings.spaceWarpParam1 = 5.0    // segments
        settings.spaceWarpParam2 = 1.5
        settings.spaceWarpParam3 = -0.25
        settings.spaceWarpAxis = SIMD3<Float>(0.3, 0.6, -0.7)

        let preset = FractalPreset.fromSettings(settings, name: "Warp")
        #expect(preset.spaceWarpType == 6)
        #expect(abs((preset.spaceWarpStrength ?? -1) - 0.8) < 1e-5)

        let data = try JSONEncoder().encode(preset)
        let decoded = try JSONDecoder().decode(FractalPreset.self, from: data)

        #expect(decoded.spaceWarpType == 6)
        #expect(abs((decoded.spaceWarpStrength ?? -1) - 0.8) < 1e-5)
        #expect(abs((decoded.spaceWarpParam1 ?? -1) - 5.0) < 1e-5)
        #expect(abs((decoded.spaceWarpParam2 ?? -1) - 1.5) < 1e-5)
        #expect(decoded.spaceWarpAxis?.count == 3)

        let fresh = RenderSettings()
        fresh.fractalType = .mandelbulb
        decoded.apply(to: fresh)
        #expect(fresh.spaceWarpType == 6)
        #expect(abs(fresh.spaceWarpStrength - 0.8) < 1e-5)
        #expect(abs(fresh.spaceWarpParam1 - 5.0) < 1e-5)
        #expect(abs(fresh.spaceWarpParam2 - 1.5) < 1e-5)
        #expect(abs(fresh.spaceWarpAxis.x - 0.3) < 1e-5)
        #expect(abs(fresh.spaceWarpAxis.z - (-0.7)) < 1e-5)
    }

    @Test("Older scenes without the new keys decode to nil and leave live values untouched on apply")
    func legacySceneLeavesFieldsUntouched() throws {
        // A minimal flat scene with none of the newly-added keys (an older file).
        let json = """
        {
          "id": "00000000-0000-0000-0000-0000000000DD",
          "name": "Legacy",
          "createdAt": 0,
          "fractalIterations": 9,
          "maxRaySteps": 64,
          "colorMix": 0.5,
          "colorIterations": 8,
          "position": [0, 0, -1.2],
          "scale": 1,
          "fractalType": "mandelbox",
          "minDistance": 0.8,
          "fractalScale": 2.8,
          "foldingLimit": 1.0,
          "sphereRadius": 0.5
        }
        """
        let preset = try JSONDecoder().decode(FractalPreset.self, from: Data(json.utf8))
        #expect(preset.platformEnabled == nil)
        #expect(preset.cellShadingEnabled == nil)
        #expect(preset.lightVariationRate == nil)
        #expect(preset.beatFlashEffect == nil)
        #expect(preset.safetyBubbleFadeWidth == nil)

        // Pre-seed non-default live values; a legacy preset must NOT clobber them.
        let settings = RenderSettings()
        settings.fractalType = .mandelbox
        settings.platformEnabled = false
        settings.cellShadingEnabled = true
        settings.lightVariationRate = 0.2
        preset.apply(to: settings)

        #expect(settings.platformEnabled == false)
        #expect(settings.cellShadingEnabled == true)
        #expect(abs(settings.lightVariationRate - 0.2) < 1e-5)
    }
}
