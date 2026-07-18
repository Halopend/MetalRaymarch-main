import Testing
@testable import Threshold

@Suite("Vision Pro adaptive render quality")
struct AdaptiveRenderQualityControllerTests {
    @Test("Critical frame loss sheds quality quickly without adjusting every frame")
    func criticalLoadResponse() {
        var controller = AdaptiveRenderQualityController()

        let first = controller.update(
            smoothedFPS: 40,
            ceiling: 0.5,
            sceneFloor: 0.45,
            now: 1.0,
            enabled: true
        )
        let duringCooldown = controller.update(
            smoothedFPS: 40,
            ceiling: 0.5,
            sceneFloor: 0.45,
            now: 1.2,
            enabled: true
        )
        let second = controller.update(
            smoothedFPS: 40,
            ceiling: 0.5,
            sceneFloor: 0.45,
            now: 1.5,
            enabled: true
        )

        #expect(abs(first - 0.4) < 0.0001)
        #expect(abs(duringCooldown - first) < 0.0001)
        #expect(abs(second - 0.3) < 0.0001)
    }

    @Test("Authored quality floor is a preference, not a stutter trap")
    func preferredFloorCanBeOverridden() {
        var controller = AdaptiveRenderQualityController()

        let atPreference = controller.update(
            smoothedFPS: 60,
            ceiling: 0.5,
            sceneFloor: 0.45,
            now: 1.0,
            enabled: true
        )
        let belowPreference = controller.update(
            smoothedFPS: 60,
            ceiling: 0.5,
            sceneFloor: 0.45,
            now: 2.0,
            enabled: true
        )

        #expect(abs(atPreference - 0.45) < 0.0001)
        #expect(belowPreference < 0.45)
        #expect(belowPreference >= QualityConfig.visionMinRenderQuality)
    }

    @Test("Recovery is slower than load shedding")
    func recoveryHysteresis() {
        var controller = AdaptiveRenderQualityController()
        _ = controller.update(
            smoothedFPS: 40,
            ceiling: 0.5,
            sceneFloor: 0.05,
            now: 1.0,
            enabled: true
        )

        let early = controller.update(
            smoothedFPS: 90,
            ceiling: 0.5,
            sceneFloor: 0.05,
            now: 2.0,
            enabled: true
        )
        let recovered = controller.update(
            smoothedFPS: 90,
            ceiling: 0.5,
            sceneFloor: 0.05,
            now: 2.5,
            enabled: true
        )

        #expect(abs(early - 0.4) < 0.0001)
        #expect(abs(recovered - 0.45) < 0.0001)
    }

    @Test("Invalid external values never reach the compositor")
    func invalidValuesAreSanitized() {
        var controller = AdaptiveRenderQualityController()

        let invalidCeiling = controller.update(
            smoothedFPS: .nan,
            ceiling: .nan,
            sceneFloor: .infinity,
            now: .infinity,
            enabled: true
        )
        let disabled = controller.update(
            smoothedFPS: 30,
            ceiling: .infinity,
            sceneFloor: .nan,
            now: 2,
            enabled: false
        )

        #expect(invalidCeiling.isFinite)
        #expect(abs(invalidCeiling - QualityConfig.visionDefaultRenderQuality) < 0.0001)
        #expect(abs(disabled - QualityConfig.visionDefaultRenderQuality) < 0.0001)
    }
}
