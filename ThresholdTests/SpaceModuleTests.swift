//
//  SpaceModuleTests.swift
//  ThresholdTests
//
//  Guards the Space module: (1) sphere inversion/projection now persist through
//  save/load (previously dropped — the fields existed only in DisplayConfig and
//  were never captured by FractalPreset), and (2) a scene's typed `modules`
//  block routes + capability-filters into live settings.
//

import Testing
import Foundation
@testable import Threshold

@Suite("Space module — persistence & typed-param routing")
struct SpaceModuleTests {

    // MARK: Flat-field persistence (the lossy-load fix)

    @Test("Sphere inversion/projection survive fromSettings → encode → decode → apply")
    func sphereTransformsRoundTrip() throws {
        let settings = RenderSettings()
        settings.fractalType = .kleinian
        settings.sphericalInversionMode = .outwardIn
        settings.sphericalInversionRadius = 2.4
        settings.sphereProjectionEnabled = true
        settings.sphereProjectionBlend = 0.6
        settings.sphereProjectionRadius = 2.5

        // Capture → encode → decode (the path that was silently dropping values).
        let preset = FractalPreset.fromSettings(settings, name: "RoundTrip")
        #expect(preset.sphereProjectionEnabled == true)
        #expect(preset.sphericalInversionMode == .outwardIn)

        let data = try JSONEncoder().encode(preset)
        let decoded = try JSONDecoder().decode(FractalPreset.self, from: data)
        #expect(decoded.sphericalInversionMode == .outwardIn)
        #expect(decoded.sphereProjectionEnabled == true)
        #expect(abs((decoded.sphereProjectionBlend ?? -1) - 0.6) < 1e-5)
        #expect(abs((decoded.sphereProjectionRadius ?? -1) - 2.5) < 1e-5)
        #expect(abs((decoded.sphericalInversionRadius ?? -1) - 2.4) < 1e-5)

        // Restore into a fresh settings object.
        let fresh = RenderSettings()
        fresh.fractalType = .kleinian
        decoded.apply(to: fresh)
        #expect(fresh.sphericalInversionMode == .outwardIn)
        #expect(fresh.sphereProjectionEnabled == true)
        #expect(abs(fresh.sphereProjectionBlend - 0.6) < 1e-5)
        #expect(abs(fresh.sphereProjectionRadius - 2.5) < 1e-5)
        #expect(abs(fresh.sphericalInversionRadius - 2.4) < 1e-5)
    }

    @Test("Mandelbox still persists its sphere projection (no regression)")
    func mandelboxStillPersistsProjection() throws {
        let settings = RenderSettings()
        settings.fractalType = .mandelbox
        settings.sphereProjectionEnabled = true
        settings.sphereProjectionBlend = 0.8

        let preset = FractalPreset.fromSettings(settings, name: "MB")
        let decoded = try JSONDecoder().decode(FractalPreset.self, from: JSONEncoder().encode(preset))
        let fresh = RenderSettings()
        fresh.fractalType = .mandelbox
        decoded.apply(to: fresh)
        #expect(fresh.sphereProjectionEnabled == true)
        #expect(abs(fresh.sphereProjectionBlend - 0.8) < 1e-5)
    }

    @Test("Older scenes without sphere fields decode without error")
    func legacySceneDecodes() throws {
        // A minimal flat scene with none of the new keys (i.e. an older file).
        let json = """
        {
          "id": "00000000-0000-0000-0000-0000000000AA",
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
        #expect(preset.sphereProjectionEnabled == nil)
        #expect(preset.modules == nil)
    }

    // MARK: Capability key

    @Test("Sphere projection is enabled broadly (capability key present)")
    func capabilityKeyBroad() {
        // "Enable broadly, prune by eye": every type supports it by default.
        for type in FractalModelType.selectableCases {
            #expect(type.supports(.sphereProjection),
                    "Expected \(type) to advertise sphereProjection by default")
        }
    }

    // MARK: Typed `modules` block routing

    @Test("modules.space block decodes, routes, and capability-filters on apply")
    func moduleBlockRoutesAndApplies() throws {
        let json = """
        {
          "id": "00000000-0000-0000-0000-0000000000BB",
          "name": "Module Scene",
          "createdAt": 0,
          "fractalIterations": 10,
          "maxRaySteps": 96,
          "colorMix": 0.5,
          "colorIterations": 8,
          "position": [0, 0, -1.4],
          "scale": 1,
          "fractalType": "kleinian",
          "minDistance": 0.8,
          "fractalScale": 2.8,
          "foldingLimit": 1.0,
          "sphereRadius": 0.6,
          "schemaVersion": 2,
          "modules": {
            "space": {
              "params": {
                "sphereProjectionEnabled": true,
                "sphereProjectionBlend": 0.7,
                "sphereProjectionRadius": 1.5,
                "sphericalInversionMode": "outwardIn",
                "sphericalInversionRadius": 2.2
              }
            }
          }
        }
        """
        let preset = try JSONDecoder().decode(FractalPreset.self, from: Data(json.utf8))
        #expect(preset.modules?["space"] != nil)

        let settings = RenderSettings()
        settings.fractalType = .kleinian
        preset.apply(to: settings)

        #expect(settings.sphereProjectionEnabled == true)
        #expect(abs(settings.sphereProjectionBlend - 0.7) < 1e-5)
        #expect(abs(settings.sphereProjectionRadius - 1.5) < 1e-5)
        #expect(settings.sphericalInversionMode == .outwardIn)
        #expect(abs(settings.sphericalInversionRadius - 2.2) < 1e-5)
    }

    @Test("Capability gate routes fractal-specific vs universal params correctly")
    func capabilityGate() {
        // Universal transform: always passes regardless of fractal.
        #expect(ModuleRegistry.capability(.space, param: "sphericalInversionRadius", for: .menger))
        // Fractal-specific transform: defers to the capability key.
        #expect(ModuleRegistry.capability(.space, param: "sphereProjectionEnabled", for: .kleinian)
                == FractalModelType.kleinian.supports(.sphereProjection))
    }

    // MARK: Lighting module

    @Test("Lighting module routes universal effects (glow/hue/fog) on any fractal")
    func lightingModuleRoutesUniversal() {
        let settings = RenderSettings()
        settings.fractalType = .kleinian
        let block = ModuleParamBlock(params: [
            "glowEnabled": .bool(true), "glowIntensity": .double(0.5),
            "hueRotationEnabled": .bool(true), "hueRotationSpeed": .double(0.07),
            "fogEnabled": .bool(true), "fogIntensity": .double(0.3),
            "lightingMode": .string("animated"),
        ])
        ModuleRegistry.apply(.lighting, block: block, to: settings)

        #expect(settings.glowEffect.enabled == true)
        #expect(abs(settings.glowEffect.intensity - 0.5) < 1e-5)
        #expect(settings.hueRotationEffect.enabled == true)
        #expect(abs(settings.hueRotationEffect.speed - 0.07) < 1e-5)
        #expect(settings.fogEffect.enabled == true)
        #expect(settings.lightingMode == .animated)
    }

    @Test("Lighting capability gate: polar rotation skipped on unsupported, applied on supported")
    func lightingCapabilityGate() {
        let block = ModuleParamBlock(params: [
            "polarRotationDirection": .string("clockwise"),
            "polarRotationSpeed": .double(0.3),
        ])

        // Kleinian does NOT support polar rotation → skipped (stays off).
        #expect(FractalModelType.kleinian.supports(.polarRotation) == false)
        let kleinian = RenderSettings()
        kleinian.fractalType = .kleinian
        ModuleRegistry.apply(.lighting, block: block, to: kleinian)
        #expect(kleinian.polarRotationEffect.direction == .off)

        // Mandelbulb DOES support it → applied.
        #expect(FractalModelType.mandelbulb.supports(.polarRotation) == true)
        let mandelbulb = RenderSettings()
        mandelbulb.fractalType = .mandelbulb
        ModuleRegistry.apply(.lighting, block: block, to: mandelbulb)
        #expect(mandelbulb.polarRotationEffect.direction == .clockwise)
        #expect(abs(mandelbulb.polarRotationEffect.speed - 0.3) < 1e-5)
    }

    @Test("Lighting module decodes from a scene's modules block")
    func lightingModuleDecodesFromScene() throws {
        let json = """
        {
          "id": "00000000-0000-0000-0000-0000000000CC",
          "name": "Lit Scene",
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
          "sphereRadius": 0.5,
          "schemaVersion": 2,
          "modules": {
            "lighting": { "params": { "glowEnabled": true, "glowIntensity": 0.6, "pulseEnabled": true, "pulseAmount": 0.2 } }
          }
        }
        """
        let preset = try JSONDecoder().decode(FractalPreset.self, from: Data(json.utf8))
        let settings = RenderSettings()
        settings.fractalType = .mandelbox
        preset.apply(to: settings)
        #expect(settings.glowEffect.enabled == true)
        #expect(abs(settings.glowEffect.intensity - 0.6) < 1e-5)
        #expect(settings.pulseEffect.enabled == true)
        #expect(abs(settings.pulseEffect.amount - 0.2) < 1e-5)
    }
}
