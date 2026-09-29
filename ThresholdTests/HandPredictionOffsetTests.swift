//
//  HandPredictionOffsetTests.swift
//  ThresholdTests
//
//  Guards the `handPredictionOffsetMs` latency trim: it is a device/ergonomics
//  setting, not scene content, so it must (a) survive a config decode that
//  predates the field without stomping the rest of the hand config, (b) clamp to
//  its ControlSpec range rather than letting a stale preset drive ARKit's
//  prediction to something absurd, and (c) round-trip through the hand config
//  bridge that both persistence and presets use.
//

import Testing
import Foundation
@testable import Threshold

@Suite("Hand prediction offset — range, decode, and config round-trip")
struct HandPredictionOffsetTests {

    @Test("Defaults to zero (trust ARKit's own prediction)")
    func defaultsToZero() {
        #expect(HandAttractionConfig().predictionOffsetMs == 0)
        let settings = RenderSettings()
        #expect(settings.handPredictionOffsetMs == 0)
    }

    @Test("Default sits inside the declared range")
    func defaultInRange() {
        #expect(ControlCatalog.handPredictionOffset.range.contains(
            ControlCatalog.handPredictionOffset.defaultValue))
        // The trim must be able to reach behind photon time as well as ahead:
        // a sculpting field can want a pose the predictor cannot give it.
        #expect(ControlCatalog.handPredictionOffset.range.lowerBound < 0)
    }

    @Test("Setter clamps to the ControlSpec range")
    func setterClamps() {
        let settings = RenderSettings()
        settings.withPersistenceSuppressed {
            settings.handPredictionOffsetMs = 10_000
            #expect(settings.handPredictionOffsetMs == ControlCatalog.handPredictionOffset.range.upperBound)
            settings.handPredictionOffsetMs = -10_000
            #expect(settings.handPredictionOffsetMs == ControlCatalog.handPredictionOffset.range.lowerBound)
            settings.handPredictionOffsetMs = 25
            #expect(settings.handPredictionOffsetMs == 25)
        }
    }

    @Test("Config clamp() enforces the range")
    func configClamp() {
        var config = HandAttractionConfig()
        config.predictionOffsetMs = 500
        config.clamp()
        #expect(config.predictionOffsetMs == ControlCatalog.handPredictionOffset.range.upperBound)
    }

    @Test("A config saved before this field existed decodes to the default")
    func decodesPreexistingConfigWithoutField() throws {
        // Exactly what an install persisted before the field shipped.
        let legacy = """
        {"enabled":true,"radius":0.5,"strength":0.2,"pocketEnabled":false,
         "ballScale":0.4,"softness":0.8,"pocketSize":0.6,"pocketSoftness":0.2,
         "projectionDistance":0.1,"forearmEnabled":true,"forearmRadius":0.07}
        """
        let config = try JSONDecoder().decode(HandAttractionConfig.self, from: Data(legacy.utf8))
        #expect(config.predictionOffsetMs == 0)
        // The rest of the config must survive the addition untouched.
        #expect(config.radius == 0.5)
        #expect(config.forearmEnabled == true)
        #expect(config.forearmRadius == 0.07)
    }

    @Test("Round-trips through the RenderSettings hand-config bridge")
    func configBridgeRoundTrip() {
        let settings = RenderSettings()
        settings.withPersistenceSuppressed {
            var config = settings.handAttractionConfig
            config.predictionOffsetMs = 33
            settings.handAttractionConfig = config
            #expect(settings.handPredictionOffsetMs == 33)
            #expect(settings.handAttractionConfig.predictionOffsetMs == 33)
        }
    }

    @Test("Restoring a preset that predates the field leaves the default")
    func presetRestoreWithoutField() throws {
        let legacy = """
        {"enabled":true,"radius":0.4}
        """
        let config = try JSONDecoder().decode(HandAttractionConfig.self, from: Data(legacy.utf8))
        #expect(config.predictionOffsetMs == 0)
    }
}
