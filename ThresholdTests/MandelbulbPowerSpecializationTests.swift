//
//  MandelbulbPowerSpecializationTests.swift
//  ThresholdTests
//
//  Pins the single shared rule for when Mandelbulb power is safe to bake into
//  shader function constants.
//

import Testing
@testable import Threshold

@Suite("Mandelbulb power specialization")
struct MandelbulbPowerSpecializationTests {

    @Test("Supported near-integer powers specialize")
    func supportedNearIntegerPowersSpecialize() {
        for power in [2, 3, 4, 5, 6, 8, 10, 12, 16] {
            #expect(FormulaCatalog.specializedMandelbulbPower(rawPower: Float(power) + 0.005) == Int32(power))
        }
    }

    @Test("Unsupported or non-integer powers stay runtime-driven")
    func unsupportedPowersDoNotSpecialize() {
        let powers: [Float] = [1.0, 7.0, 9.0, 11.0, 2.25, 8.02]
        for power in powers {
            #expect(FormulaCatalog.specializedMandelbulbPower(rawPower: power) == nil)
        }
    }
}
