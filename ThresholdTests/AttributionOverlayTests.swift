#if os(macOS)
import Testing

@testable import Threshold

@Suite("Attribution overlay base distance estimator")
struct AttributionOverlayTests {
    @Test("Built-in fractals use catalog identity and attribution")
    func builtInFractal() {
        let info = BaseDistanceEstimatorInfo.resolve(
            fractalType: .mandelbox,
            formulaParams: FractalModelType.mandelbox.defaultFormulaParams(),
            embeddedFormula: nil
        )

        #expect(info.name == "Mandelbox")
        #expect(info.author == "Tom Lowe")
        #expect(info.accessibilityDescription.contains("Mandelbox"))
    }

    @Test("Custom fractal payload supplies the base DE identity")
    func customFractal() {
        let formula = embeddedFormula(
            kind: .fractal,
            name: "Orbit Bloom",
            author: "A. Author"
        )
        let info = BaseDistanceEstimatorInfo.resolve(
            fractalType: .custom,
            formulaParams: FractalModelType.mandelbox.defaultFormulaParams(),
            embeddedFormula: formula
        )

        #expect(info.name == "Orbit Bloom")
        #expect(info.author == "A. Author")
    }

    @Test("Space warps never replace the built-in base DE identity")
    func spaceWarpKeepsBaseFractal() {
        let warp = embeddedFormula(
            kind: .spaceWarp,
            name: "Misleading Warp",
            author: "Warp Author"
        )
        let info = BaseDistanceEstimatorInfo.resolve(
            fractalType: .mandelbulb,
            formulaParams: FractalModelType.mandelbulb.defaultFormulaParams(),
            embeddedFormula: warp
        )

        #expect(info.name == "Mandelbulb")
        #expect(info.name != warp.name)
    }

    @Test("Construction primitives report the selected analytic DE")
    func constructionPrimitive() {
        let info = BaseDistanceEstimatorInfo.resolve(
            fractalType: .constructionPrimitive,
            formulaParams: FractalPrimitiveKind.sphere.bundledFormulaParams,
            embeddedFormula: FractalPrimitiveKind.sphere.formula
        )

        #expect(info.name == "Sphere")
        #expect(info.author == "Threshold")
    }

    private func embeddedFormula(
        kind: EffectKind,
        name: String,
        author: String?
    ) -> EmbeddedFormula {
        EmbeddedFormula(
            kind: kind,
            id: "test.\(name)",
            name: name,
            author: author,
            functionStem: "TestFormula",
            metalSource: "",
            params: []
        )
    }
}
#endif
