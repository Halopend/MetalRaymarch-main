//
//  CustomLightingParameterTests.swift
//  ThresholdTests
//
//  Guards the independent value bank exposed to imported lighting effects.
//

import Foundation
import Testing
@testable import Threshold

@Suite("External custom-lighting parameter contract")
struct CustomLightingParameterTests {

    private static func lighting(
        params: [FormulaParamDescriptor]
    ) -> EmbeddedFormula {
        EmbeddedFormula(
            kind: .lighting,
            id: "test.parameterized-lighting",
            name: "Parameterized Lighting",
            functionStem: "ParameterizedLighting",
            metalSource: """
            FORCE_INLINE ThresholdMaterial Lighting_ParameterizedLighting(
                ThresholdLightingContext context,
                ThresholdMaterial material
            ) {
                return material;
            }
            """,
            params: params
        )
    }

    @Test("Lighting descriptors validate, sort visible controls, and resolve a safe value bank")
    func descriptorValidationAndResolution() throws {
        let formula = Self.lighting(params: [
            FormulaParamDescriptor(
                index: 12,
                name: "Hidden Seed",
                default: 0.75,
                min: 0,
                max: 1,
                step: 0.01,
                isHidden: true
            ),
            FormulaParamDescriptor(
                index: 7,
                name: "Rim Strength",
                default: 0.25,
                min: -1,
                max: 1,
                step: 0.05
            ),
            FormulaParamDescriptor(
                index: 3,
                name: "Enabled",
                default: 1,
                min: 0,
                max: 1,
                step: 1,
                isBool: true
            )
        ])

        try formula.validate()
        #expect(formula.visibleParameters.map(\.index) == [3, 7])

        var overrides = [Float](repeating: 123, count: 16)
        overrides[3] = 0.49
        overrides[7] = 9
        overrides[12] = -9
        let resolved = formula.resolvedParameterValues(overrides: overrides)

        #expect(resolved.count == 16)
        #expect(resolved[3] == 0, "bool values below 0.5 normalize to false")
        #expect(resolved[7] == 1, "float overrides clamp to descriptor bounds")
        #expect(resolved[12] == 0, "hidden parameters still resolve and clamp")
        #expect(resolved[0] == 0, "undeclared slots ignore incoming values")
        #expect(resolved[15] == 0, "undeclared slots remain zero")

        overrides[3] = 0.5
        overrides[7] = .nan
        let finite = formula.resolvedParameterValues(overrides: overrides)
        #expect(finite[3] == 1, "bool values at the threshold normalize to true")
        #expect(finite[7] == 0.25, "non-finite overrides fall back to defaults")
    }

    @Test("Lighting validation rejects malformed bool metadata")
    func invalidBoolDescriptorIsRejected() {
        let formula = Self.lighting(params: [
            FormulaParamDescriptor(
                index: 3,
                name: "Enabled",
                default: 1,
                min: 0.25,
                max: 1,
                step: 1,
                isBool: true
            )
        ])

        do {
            try formula.validate()
            Issue.record("Expected a bool range that excludes zero to be rejected")
        } catch let error as EmbeddedFormula.ValidationError {
            guard case .invalidParamDescriptor(let index, _) = error else {
                Issue.record("Unexpected validation error: \(error)")
                return
            }
            #expect(index == 3)
        } catch {
            Issue.record("Unexpected validation error type: \(error)")
        }
    }

    @Test("The GPU lighting bank is compact and cannot mutate geometry parameters")
    func compactBankIsIndependentFromGeometry() {
        #expect(MemoryLayout<CustomLightingParams>.size == 16 * MemoryLayout<Float>.size)
        #expect(MemoryLayout<CustomLightingParams>.stride == 64)

        let packed = CustomLightingParams(values: [0.25, .nan, 3.5])
        let packedValues = packed.valuesArray()
        #expect(packedValues.count == 16)
        #expect(packedValues[0] == 0.25)
        #expect(packedValues[1] == 0, "the ABI packer must not forward NaN to Metal")
        #expect(packedValues[2] == 3.5)
        #expect(packedValues[15] == 0)

        let settings = RenderSettings()
        var geometry = settings.formulaParams
        FormulaCatalog.setParam(&geometry, index: 3, value: 42)
        settings.formulaParams = geometry
        settings.setCustomLightingParameterValues([0, 0, 0, 7])

        #expect(FormulaCatalog.getParam(settings.formulaParams, index: 3) == 42)
        #expect(settings.customLightingParameterValues[3] == 7)

        settings.setCustomLightingParameterValues([0, 0, 0, 11])
        #expect(FormulaCatalog.getParam(settings.formulaParams, index: 3) == 42)
        #expect(settings.customLightingParameterValues[3] == 11)
    }
}
