//
//  FormulaBatchInvalidationTests.swift
//  ThresholdTests
//
//  Pins the live-edit invalidation seam: re-registering a custom formula
//  under the SAME id with different params must rebuild the .custom parameter
//  node batch. Before the registration-token fix, ParameterNodeRegistry keyed
//  its cache on the descriptor id alone, so an in-place edit left stale
//  sliders (old names, old ranges) bound to the new formula.
//

import Foundation
import Testing
@testable import Threshold

@Suite("Custom formula batch invalidation", .serialized)
struct FormulaBatchInvalidationTests {

    private func makeFormula(id: String, params: [FormulaParamDescriptor]) -> EmbeddedFormula {
        EmbeddedFormula(
            kind: .fractal,
            id: id,
            name: "Test Formula",
            category: "Tests",
            author: "ThresholdTests",
            formulaDescription: "Invalidation test fixture",
            functionStem: "InvalidationFixture",
            metalSource: """
            FORCE_INLINE float DE_InvalidationFixture_Dist(float3 p, FormulaParams fp) {
                return length(p) - fp.params[0];
            }
            FORCE_INLINE float2 DE_InvalidationFixture(float3 p, FormulaParams fp) {
                return float2(DE_InvalidationFixture_Dist(p, fp), 0.0f);
            }
            """,
            params: params,
            defaultIterations: 1,
            defaultColorIterations: 1,
            supportedEffectTagsRaw: []
        )
    }

    @Test("Re-registering the same formula id with edited params rebuilds the node batch")
    func sameIDReRegistrationRebuildsBatch() {
        defer { FormulaCatalog.shared.unregisterEphemeral() }

        let original = makeFormula(id: "test.invalidation.same-id", params: [
            FormulaParamDescriptor(index: 0, name: "Alpha", default: 1.0,
                                   min: 0.0, max: 2.0, step: 0.01)
        ])
        FormulaCatalog.shared.registerEphemeral(original)
        let batchBefore = ParameterNodeRegistry.shared.formulaBatch(for: .custom)
        #expect(batchBefore.floatNodeByFormulaIndex[0]?.range == 0.0...2.0)
        #expect(batchBefore.floatNodeByFormulaIndex[1] == nil)

        // Live edit: SAME id, new param set (renamed slot 0 with a new range,
        // plus a brand-new slot 1).
        let edited = makeFormula(id: "test.invalidation.same-id", params: [
            FormulaParamDescriptor(index: 0, name: "Beta", default: 3.0,
                                   min: 0.5, max: 4.0, step: 0.01),
            FormulaParamDescriptor(index: 1, name: "Gamma", default: 0.25,
                                   min: 0.0, max: 1.0, step: 0.01)
        ])
        FormulaCatalog.shared.registerEphemeral(edited)

        let batchAfter = ParameterNodeRegistry.shared.formulaBatch(for: .custom)
        #expect(batchAfter.floatNodeByFormulaIndex[0]?.range == 0.5...4.0)
        #expect(batchAfter.floatNodeByFormulaIndex[1] != nil)
    }

    @Test("Unregistering the ephemeral formula empties the custom batch")
    func unregisterEmptiesBatch() {
        let formula = makeFormula(id: "test.invalidation.unregister", params: [
            FormulaParamDescriptor(index: 0, name: "Alpha", default: 1.0,
                                   min: 0.0, max: 2.0, step: 0.01)
        ])
        FormulaCatalog.shared.registerEphemeral(formula)
        #expect(ParameterNodeRegistry.shared.formulaBatch(for: .custom)
            .floatNodeByFormulaIndex[0] != nil)

        FormulaCatalog.shared.unregisterEphemeral()
        #expect(FormulaCatalog.shared.customRegistrationToken() == nil)
        #expect(ParameterNodeRegistry.shared.formulaBatch(for: .custom)
            .floatNodeByFormulaIndex.isEmpty)
    }

    @Test("The registration token changes on every registration, even for the same id")
    func tokenChangesOnEveryRegistration() {
        defer { FormulaCatalog.shared.unregisterEphemeral() }

        let formula = makeFormula(id: "test.invalidation.token", params: [
            FormulaParamDescriptor(index: 0, name: "Alpha", default: 1.0,
                                   min: 0.0, max: 2.0, step: 0.01)
        ])
        FormulaCatalog.shared.registerEphemeral(formula)
        let first = FormulaCatalog.shared.customRegistrationToken()
        FormulaCatalog.shared.registerEphemeral(formula)
        let second = FormulaCatalog.shared.customRegistrationToken()
        #expect(first != nil)
        #expect(second != nil)
        #expect(first != second)
    }
}
