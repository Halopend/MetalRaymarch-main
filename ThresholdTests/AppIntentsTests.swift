import Testing
@testable import Threshold

@Suite("App Intents invariants")
struct AppIntentsTests {
    @Test("Fractal AppEnum covers every selectable built-in fractal")
    func fractalEnumCoversSelectableBuiltIns() {
        let exposedTypes = Set(FractalTypeAppEnum.allCases.map(\.modelType))
        let selectableBuiltIns = Set(
            FractalModelType.selectableCases.filter { $0 != .custom }
        )

        #expect(
            exposedTypes == selectableBuiltIns,
            "App Intents fractal cases drifted from the in-app selectable set"
        )
    }
}
