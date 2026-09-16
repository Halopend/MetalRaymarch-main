import Foundation
import Testing
@testable import Threshold

/// Pins the single shared band-mapping helper (tech debt #26). The visionOS
/// Renderer, the Mac/iPad render view, and the Music tab meters must all
/// produce identical levels from identical inputs — and a non-finite audio
/// feature must never reach `RenderSettings` band fields, where it would
/// poison the uniform buffer and break the frame.
@Suite("Audio band mapping")
struct AudioBandMappingTests {
    @Test("Scales a feature by its sensitivity")
    func scalesBySensitivity() {
        #expect(AudioBandMapping.scaledLevel(0.5, sensitivity: 1.0) == 0.5)
        #expect(AudioBandMapping.scaledLevel(0.5, sensitivity: 2.0) == 1.0)
        #expect(AudioBandMapping.scaledLevel(0.25, sensitivity: 2.0) == 0.5)
        #expect(AudioBandMapping.scaledLevel(0.0, sensitivity: 4.0) == 0.0)
    }

    @Test("Clamps to the 0...1 range")
    func clampsToUnitRange() {
        #expect(AudioBandMapping.scaledLevel(1.5, sensitivity: 1.0) == 1.0)
        #expect(AudioBandMapping.scaledLevel(3.0, sensitivity: 4.0) == 1.0)
        #expect(AudioBandMapping.scaledLevel(-0.5, sensitivity: 1.0) == 0.0)
        #expect(AudioBandMapping.scaledLevel(0.5, sensitivity: -1.0) == 0.0)
    }

    @Test("Non-finite feature maps to zero, never NaN")
    func nonFiniteFeatureMapsToZero() {
        #expect(AudioBandMapping.scaledLevel(.nan, sensitivity: 1.0) == 0.0)
        #expect(AudioBandMapping.scaledLevel(.infinity, sensitivity: 1.0) == 0.0)
        #expect(AudioBandMapping.scaledLevel(-.infinity, sensitivity: 1.0) == 0.0)
    }

    @Test("Non-finite sensitivity maps to zero")
    func nonFiniteSensitivityMapsToZero() {
        #expect(AudioBandMapping.scaledLevel(0.5, sensitivity: .nan) == 0.0)
        #expect(AudioBandMapping.scaledLevel(0.5, sensitivity: .infinity) == 0.0)
    }

    @Test("Overflowing product maps to zero instead of clamping infinity")
    func overflowingProductMapsToZero() {
        // 1e30 × 1e30 overflows to infinity; a naive min/max clamp would
        // produce max(0, .infinity) → 1.0 or NaN depending on evaluation
        // order. The helper must reject the overflow outright.
        #expect(AudioBandMapping.scaledLevel(1e30, sensitivity: 1e30) == 0.0)
    }

    @Test("Overall level uses sensitivity 1.0 with the same finite guard")
    func overallLaneUsesUnitSensitivity() {
        #expect(AudioBandMapping.scaledLevel(0.7, sensitivity: 1.0) == 0.7)
        #expect(AudioBandMapping.scaledLevel(2.0, sensitivity: 1.0) == 1.0)
        #expect(AudioBandMapping.scaledLevel(.nan, sensitivity: 1.0) == 0.0)
    }
}
