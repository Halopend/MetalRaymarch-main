import Foundation
import Testing
@testable import Threshold

@Suite("SceneState — canonical capture and restore")
struct SceneStatePersistenceTests {

    private struct CanonicalOnlyPreset: Encodable {
        let id: UUID
        let name: String
        let createdAt: Date
        let schemaVersion: Int
        let sceneState: SceneState
    }

    @Test("v3 captures omitted scene lanes and preserves device preferences")
    func capturesCompleteSceneOwnedState() throws {
        let source = RenderSettings()
        source.withPersistenceSuppressed {
            source.fractalType = .mandelbulb
            source.spaceWarpStrength = 1.25
            source.spaceWarpOrigin = SIMD3<Float>(0.4, -0.3, 0.8)
            source.spaceWarpAxis = SIMD3<Float>(1, 2, 3)
            source.infiniteZoomEnabled = true
            source.infiniteZoomRate = -0.42
            source.lightingPlay = true
            source.shadowsEnabled = false
            source.zoomFogCompensationEnabled = true

            var bubble = source.safetyBubbleConfig
            bubble.enabled = false
            bubble.mixedAutoShrinkEnabled = false
            bubble.mixedRadius = 0.72
            source.safetyBubbleConfig = bubble
        }

        let captured = FractalPreset.fromSettings(source, name: "Complete")
        #expect(captured.schemaVersion == FractalPreset.currentSchemaVersion)
        #expect(captured.sceneState?.schemaVersion == SceneState.currentSchemaVersion)

        let decoded = try JSONDecoder().decode(
            FractalPreset.self,
            from: try JSONEncoder().encode(captured)
        )

        let destination = RenderSettings()
        destination.withPersistenceSuppressed {
            // These are device/user preferences and must survive a shared scene.
            destination.showMusicShortcuts = true
            destination.foveationStrength = 0.73
            destination.coneMarchStrength = 0.61
            destination.adaptiveRenderQualityEnabled = false

            destination.spaceWarpStrength = 0
            destination.spaceWarpOrigin = .zero
            destination.infiniteZoomEnabled = false
            destination.lightingPlay = false
            destination.shadowsEnabled = true
            destination.zoomFogCompensationEnabled = false
            destination.safetyBubbleEnabled = true
        }

        decoded.apply(to: destination, includePerformance: false, scope: .session)

        #expect(abs(destination.spaceWarpStrength - 1.25) < 1e-5)
        #expect(destination.spaceWarpOrigin == SIMD3<Float>(0.4, -0.3, 0.8))
        #expect(destination.spaceWarpAxis == SIMD3<Float>(1, 2, 3))
        #expect(destination.infiniteZoomEnabled)
        #expect(abs(destination.infiniteZoomRate - (-0.42)) < 1e-5)
        #expect(destination.lightingPlay)
        #expect(destination.shadowsEnabled == false)
        #expect(destination.zoomFogCompensationEnabled)
        #expect(destination.safetyBubbleEnabled == false)
        #expect(destination.safetyBubbleMixedAutoShrink == false)
        #expect(abs(destination.safetyBubbleMixedRadius - 0.72) < 1e-5)

        #expect(destination.showMusicShortcuts)
        #expect(abs(destination.foveationStrength - 0.73) < 1e-5)
        #expect(abs(destination.coneMarchStrength - 0.61) < 1e-5)
        #expect(destination.adaptiveRenderQualityEnabled == false)
    }

    @Test("shared scene cannot disable comfort bubble; session rollback can")
    func safetyRestoreScope() {
        let source = RenderSettings()
        source.withPersistenceSuppressed { source.safetyBubbleEnabled = false }
        let preset = FractalPreset.fromSettings(source, name: "Bubble off")

        let sharedDestination = RenderSettings()
        sharedDestination.withPersistenceSuppressed { sharedDestination.safetyBubbleEnabled = true }
        preset.apply(to: sharedDestination, scope: .scene)
        #expect(sharedDestination.safetyBubbleEnabled)

        let sessionDestination = RenderSettings()
        sessionDestination.withPersistenceSuppressed { sessionDestination.safetyBubbleEnabled = true }
        preset.apply(to: sessionDestination, scope: .session)
        #expect(sessionDestination.safetyBubbleEnabled == false)
    }

    @Test("legacy scenes clear state lanes they could not encode")
    func legacySceneClearsNewLanes() throws {
        let json = """
        {
          "id": "00000000-0000-0000-0000-000000000321",
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
          "foldingLimit": 1,
          "sphereRadius": 0.5
        }
        """
        let legacy = try JSONDecoder().decode(FractalPreset.self, from: Data(json.utf8))
        #expect(legacy.sceneState == nil)

        let destination = RenderSettings()
        destination.withPersistenceSuppressed {
            destination.spaceWarpStrength = 1.8
            destination.spaceWarpOrigin = SIMD3<Float>(1, 2, 3)
            destination.spaceWarpAxis = SIMD3<Float>(1, 0, 0)
            destination.infiniteZoomEnabled = true
            destination.infiniteZoomRate = -1
            destination.lightingPlay = true
            destination.shadowsEnabled = false
            destination.zoomFogCompensationEnabled = true
            destination.vignetteStrength = 0
        }

        legacy.apply(to: destination)
        #expect(destination.spaceWarpStrength == 0)
        #expect(destination.spaceWarpOrigin == .zero)
        #expect(destination.spaceWarpAxis == SIMD3<Float>(0, 1, 0))
        #expect(destination.infiniteZoomEnabled == false)
        #expect(abs(destination.infiniteZoomRate - 0.15) < 1e-5)
        #expect(destination.lightingPlay == false)
        #expect(destination.shadowsEnabled)
        #expect(destination.zoomFogCompensationEnabled == false)
        #expect(abs(destination.vignetteStrength - 1.0) < 1e-5)
    }

    @Test("domain configs tolerate older empty payloads")
    func domainConfigsTolerateMissingKeys() throws {
        let geometry = try JSONDecoder().decode(GeometryConfig.self, from: Data("{}".utf8))
        let color = try JSONDecoder().decode(ColorConfig.self, from: Data("{}".utf8))

        #expect(geometry.fractalType == .mandelbox)
        #expect(geometry.worldRotation.real == 1)
        #expect(abs(geometry.fractalScale - 2.8) < 1e-5)
        #expect(color.colorScheme == .classic)
        #expect(abs(color.lightingSoftness - 0.35) < 1e-5)
        #expect(abs(color.vignetteStrength - 1.0) < 1e-5)
    }

    @Test("canonical audio mappings determine music-preset classification")
    func canonicalMusicClassification() {
        var preset = FractalPreset(name: "Music")
        var state = SceneState()
        state.audioReactive.musicReactiveMappings = [
            MusicReactiveTarget.glow.defaultMapping(enabled: true)
        ]
        preset.sceneState = state
        preset.musicReactiveMappings = nil
        preset.audioReactiveConfig = nil
        #expect(preset.hasMusicReactiveMappings)
    }

    @Test("schema-3 canonical-only documents decode, apply, and re-encode without flat defaults stomping state")
    func canonicalOnlyDocument() throws {
        var state = SceneState()
        state.geometry.fractalType = .mandelbulb
        state.geometry.formulaParams = FractalModelType.mandelbulb.defaultFormulaParams()
        state.geometry.position = SIMD3<Float>(1, -2, 3)
        state.geometry.scale = 2.25
        state.color.cellShadingEnabled = true
        state.color.cellShadingLevels = 7
        state.lighting.glowEffect = GlowEffect(enabled: true, intensity: 0.81)
        state.display.platformEnabled = false
        state.quality.boundingShapeEnabled = true
        state.quality.boundingShapeType = SafetyBubbleShapePreset.icosahedron.storedValue
        state.space.warpStrength = 0.93
        state.motion.infiniteZoomEnabled = true

        let document = CanonicalOnlyPreset(
            id: UUID(),
            name: "Canonical only",
            createdAt: Date(timeIntervalSinceReferenceDate: 123),
            schemaVersion: FractalPreset.currentSchemaVersion,
            sceneState: state
        )
        let decoded = try JSONDecoder().decode(
            FractalPreset.self,
            from: JSONEncoder().encode(document)
        )
        let redecoded = try JSONDecoder().decode(
            FractalPreset.self,
            from: JSONEncoder().encode(decoded)
        )

        let destination = RenderSettings()
        redecoded.apply(to: destination, includePerformance: false, scope: .session)

        #expect(destination.fractalType == .mandelbulb)
        #expect(destination.position == SIMD3<Float>(1, -2, 3))
        #expect(abs(destination.scale - 2.25) < 1e-5)
        #expect(destination.cellShadingEnabled)
        #expect(abs(destination.cellShadingLevels - 7) < 1e-5)
        #expect(destination.glowEffect.enabled)
        #expect(abs(destination.glowEffect.intensity - 0.81) < 1e-5)
        #expect(destination.platformEnabled == false)
        #expect(destination.boundingSphereSkipEnabled)
        #expect(destination.boundingShapeType == SafetyBubbleShapePreset.icosahedron.storedValue)
        #expect(abs(destination.spaceWarpStrength - 0.93) < 1e-5)
        #expect(destination.infiniteZoomEnabled)
    }

    @Test("Buddhabrot user controls have a complete session checkpoint")
    func buddhabrotSessionCheckpoint() throws {
        let settings = BuddhabrotSettings()
        settings.power = 11.5
        settings.renderMode = .volumeRayMarch
        settings.colorMid = SIMD3<Float>(0.1, 0.7, 0.2)
        settings.volumeScale = 1.4
        settings.autoRotate = false
        settings.maxSplatCount = 131_072

        let data = try JSONEncoder().encode(settings.config)
        let decoded = try JSONDecoder().decode(BuddhabrotConfig.self, from: data)
        let restored = BuddhabrotSettings()
        restored.config = decoded

        #expect(abs(restored.power - 11.5) < 1e-5)
        #expect(restored.renderMode == .volumeRayMarch)
        #expect(restored.colorMid == SIMD3<Float>(0.1, 0.7, 0.2))
        #expect(abs(restored.volumeScale - 1.4) < 1e-5)
        #expect(restored.autoRotate == false)
        #expect(restored.maxSplatCount == 131_072)
        #expect(restored.needsClear)
    }

    @Test("Buddhabrot restore validates allocation-sensitive and non-finite values")
    func buddhabrotRestoreValidation() throws {
        let malformedJSON = """
        {
          "resolution": 999999,
          "power": -40,
          "maxIterations": 999999,
          "batchSize": -1,
          "batchesPerFrame": 99,
          "normalizationInterval": 0,
          "maxSplatCount": -5,
          "splatOpacity": 8,
          "brightnessScale": -4
        }
        """
        let decoded = try JSONDecoder().decode(BuddhabrotConfig.self, from: Data(malformedJSON.utf8))
        #expect(decoded.resolution == 756)
        #expect(decoded.power == 2)
        #expect(decoded.maxIterations == 500)
        #expect(decoded.batchSize == 4_096)
        #expect(decoded.batchesPerFrame == 8)
        #expect(decoded.normalizationInterval == 1)
        #expect(decoded.maxSplatCount == 65_536)
        #expect(decoded.splatOpacity == 1)
        #expect(decoded.brightnessScale == 0.1)

        var constructed = BuddhabrotConfig()
        constructed.power = .infinity
        constructed.colorMid = SIMD3<Float>(.nan, -2, 3)
        let restored = BuddhabrotSettings()
        restored.config = constructed
        #expect(restored.power == 8)
        #expect(restored.colorMid == SIMD3<Float>(0.6, 0, 1))
    }

    @Test("SharePlay updates cannot disable local comfort")
    func sharePlayComfortPolicy() {
        let source = RenderSettings()
        source.withPersistenceSuppressed {
            source.safetyBubbleEnabled = false
            source.position = SIMD3<Float>(4, 5, 6)
        }
        let message = FractalSyncMessage(from: source, senderID: UUID())

        let destination = RenderSettings()
        destination.withPersistenceSuppressed {
            destination.safetyBubbleEnabled = true
            destination.position = .zero
        }
        message.apply(to: destination)

        #expect(destination.safetyBubbleEnabled)
        #expect(destination.targetPosition == SIMD3<Float>(4, 5, 6))
    }

    @Test("lifecycle flush commits the pending user-origin snapshot, not later scene mutations")
    func persistenceOriginBoundary() {
        let defaults = UserDefaults.standard
        let key = SettingsPersistence.Domain.quality.rawValue
        let original = defaults.data(forKey: key)
        defer {
            if let original {
                defaults.set(original, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        let settings = RenderSettings()
        settings.withPersistenceSuppressed {
            settings.shadowsEnabled = true
            settings.foveationStrength = 0.1
        }

        // Explicit user edit captures this complete quality-domain instant.
        settings.foveationStrength = 0.73
        // A subsequent scene apply changes the live renderer but is not a new
        // preference write and therefore must not alter the pending payload.
        settings.withPersistenceSuppressed {
            settings.shadowsEnabled = false
        }
        SettingsPersistence.flushPendingSaves()

        let persisted = SettingsPersistence.load(QualityConfig.self, domain: .quality)
        #expect(abs((persisted?.foveationStrength ?? -1) - 0.73) < 1e-5)
        #expect(persisted?.shadowsEnabled == true)
        #expect(settings.shadowsEnabled == false)
    }
}
