//
//  EmbeddedFormulaCompileTests.swift
//  ThresholdTests
//
//  The strongest guard for EXTERNAL loading of scenes whose distance estimator
//  is *embedded* (custom-fractal `.threshfx` / `.threshscene` carrying an
//  `EmbeddedFormula`, and space-warp `.threshfx`). Decoding such a file is only
//  half the story — the renderer must compile the embedded Metal DE source into
//  an `MTLLibrary` at activation time (Renderer.activateEmbeddedFormula ->
//  CustomShaderCompiler.library(forFractal:spaceWarp:)). If that source has a
//  syntax error or a wrong DE signature, the scene decodes fine but renders
//  fog/sky forever with only a runtime log.
//
//  This test runs the EXACT production compile path (CustomShaderCompiler against
//  a real MTLDevice — available on the macOS test host) over every shipped
//  embedded-formula asset, so a broken embedded DE fails CI headlessly instead
//  of silently on-device.
//

import Testing
import Foundation
import Metal
@testable import Threshold

@Suite("External loading — embedded distance-estimator formulas compile to an MTLLibrary")
struct EmbeddedFormulaCompileTests {

    /// Repo `Threshold/Examples` directory, located relative to this source file.
    private static var examplesDir: URL {
        let thisFile = URL(fileURLWithPath: #filePath)
        let repoRoot = thisFile.deletingLastPathComponent().deletingLastPathComponent()
        return repoRoot.appendingPathComponent("Threshold/Examples")
    }

    private static func files(withExtension ext: String, in subdirs: [String]) -> [URL] {
        var out: [URL] = []
        for sub in subdirs {
            let dir = examplesDir.appendingPathComponent(sub)
            let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            out += urls.filter { $0.pathExtension.lowercased() == ext }
        }
        return out.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func iso8601Decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// Every embedded formula shipped in the example assets, paired with the
    /// source file it came from for clear failure messages.
    private static func collectEmbeddedFormulas() throws -> [(source: String, formula: EmbeddedFormula)] {
        var result: [(String, EmbeddedFormula)] = []
        let decoder = iso8601Decoder()

        // Presets (scene / music-preset) may carry an embedded DE fractal.
        for url in files(withExtension: "threshscene", in: ["Scenes"])
                 + files(withExtension: "threshmp", in: ["Scenes"]) {
            let preset = try decoder.decode(FractalPreset.self, from: Data(contentsOf: url))
            if let formula = preset.embeddedFormula {
                result.append((url.lastPathComponent, formula))
            }
        }

        // `.threshfx` containers are always an embedded formula (fractal DE or warp).
        for url in files(withExtension: "threshfx", in: ["Scenes", "Formulas"]) {
            let container = try EmbeddedFormulaContainer.decode(fromContainerAt: url)
            result.append((url.lastPathComponent, container.formula))
        }

        // Keep compatibility coverage for older builds that consume the embedded
        // source. Current builds use the precompiled construction-primitive path.
        for primitive in FractalPrimitiveKind.allCases {
            result.append(("Bundled primitive: \(primitive.name)", primitive.formula))
        }
        return result
    }

    @Test("Bundled construction primitives are valid, portable embedded formulas")
    func bundledPrimitivesValidate() throws {
        var ids = Set<String>()
        for primitive in FractalPrimitiveKind.allCases {
            let formula = primitive.formula
            try formula.validate()
            #expect(formula.effectKind == .fractal)
            #expect(formula.isBundledConstructionPrimitive)
            #expect(formula.bundledConstructionPrimitiveKind == primitive)
            #expect(ids.insert(formula.id).inserted)

            // An imported payload cannot claim the trusted/precompiled route by
            // copying only a bundled identifier.
            var spoofed = formula
            spoofed.metalSource += "\n// modified"
            #expect(!spoofed.isBundledConstructionPrimitive)
        }
    }

    @Test("Construction primitive selectors remain stable as the library grows")
    func bundledPrimitiveSelectorsRemainStable() {
        let expected: [(FractalPrimitiveKind, Int)] = [
            (.sphere, 0),
            (.box, 1),
            (.torus, 2),
            (.octahedron, 3),
            (.mandelboxSeed, 4),
            (.capsule, 5),
            (.cylinder, 6),
            (.cone, 7),
            (.hexagonalPrism, 8),
            (.pyramid, 9),
            (.tetrahedron, 10),
            (.icosahedron, 11),
            (.dodecahedron, 12)
        ]

        #expect(Set(expected.map { $0.1 }).count == expected.count)
        #expect(FractalPrimitiveKind.analyticCases.count == 12)
        #expect(!FractalPrimitiveKind.analyticCases.contains(.mandelboxSeed))

        for (primitive, selector) in expected {
            #expect(primitive.selector == selector)
            #expect(FractalPrimitiveKind(selector: selector) == primitive)
            #expect(Int(FormulaCatalog.getParam(
                primitive.bundledFormulaParams,
                index: 0
            ).rounded()) == selector)
        }
    }

    @Test("At least one embedded-formula example exists to exercise the compiler")
    func haveEmbeddedFormulas() throws {
        let formulas = try Self.collectEmbeddedFormulas()
        #expect(!formulas.isEmpty, "no embedded-formula example assets found under \(Self.examplesDir.path)")
    }

    @Test("Every embedded formula compiles through the production CustomShaderCompiler")
    func embeddedFormulasCompile() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            // No Metal device on this host (e.g. headless CI without a GPU) —
            // can't exercise the compiler. Decode coverage still runs in
            // ExampleSceneDecodeTests; skip rather than false-fail.
            Issue.record("No Metal device available; skipping embedded-DE compile coverage")
            return
        }

        let formulas = try Self.collectEmbeddedFormulas()
        let compiler = CustomShaderCompiler(device: device)

        for (source, formula) in formulas {
            let isWarp = formula.effectKind == .spaceWarp
            let kind = isWarp ? "space-warp" : "DE"
            do {
                // Route exactly as Renderer.activateEmbeddedFormula does: a warp
                // rides the built-in DEs (spaceWarp slot), a fractal supplies its
                // own DE (fractal slot).
                _ = try await compiler.library(
                    forFractal: isWarp ? nil : formula,
                    spaceWarp: isWarp ? formula : nil
                )
            } catch {
                // The error carries the exact Metal compiler diagnostic (file:line +
                // message), e.g. an embedded DE using the GLSL-ism `radians()` which
                // MSL does not provide. Surfaced in the test failure / .xcresult.
                Issue.record("Embedded \(kind) '\(formula.name)' from \(source) FAILED to compile: \(error)")
            }
        }
    }
}
