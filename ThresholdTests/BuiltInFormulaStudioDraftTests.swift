import Testing
@testable import Threshold

@Suite("Built-in formula Studio drafts")
struct BuiltInFormulaStudioDraftTests {
    @Test("Every selectable built-in opens its own valid equation source")
    func selectableBuiltInsProduceDrafts() throws {
        for type in FractalModelType.selectableCases where type != .custom {
            let values = type.defaultFormulaParams()
            let draft = try #require(EmbeddedFormula.studioDraft(
                for: type,
                parameterValues: values,
                mandelboxScale: 2.8
            ))

            #expect(draft.name == type.displayName)
            #expect(draft.metalSource.contains("DE_\(draft.functionStem)("))
            #expect(draft.metalSource.contains("DE_\(draft.functionStem)_Dist("))
            #expect(!draft.metalSource.contains("#ifndef DE_"))
            try draft.validate()
        }
    }

    @Test("Studio draft keeps the active parameter values")
    func activeValuesBecomeDraftDefaults() throws {
        var values = FractalModelType.mandelbulb.defaultFormulaParams()
        FormulaCatalog.setParam(&values, index: 0, value: 11)

        let draft = try #require(EmbeddedFormula.studioDraft(
            for: .mandelbulb,
            parameterValues: values,
            mandelboxScale: 2.8
        ))
        let power = try #require(draft.params.first { $0.index == 0 })

        #expect(power.default == 11)
    }
}
