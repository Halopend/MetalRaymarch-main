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

    /// The box payload exactly as generated before its roundness clamp gained
    /// the `size` upper bound (commit 56d01f55) — the revision embedded in every
    /// scene and auto-saved session written by earlier builds. Only the helper
    /// line differs, so reconstruct it from the current formula.
    private static var staleBoxPayload: EmbeddedFormula {
        var stale = FractalPrimitiveKind.box.formula
        stale.metalSource = stale.metalSource.replacingOccurrences(
            of: "float roundness = min(max(fp.params[1], 0.0f), size);",
            with: "float roundness = max(fp.params[1], 0.0f);"
        )
        return stale
    }

    @Test("Payloads embedded by earlier builds keep their trusted primitive identity")
    func staleBundledPayloadStillTrusted() {
        let stale = Self.staleBoxPayload
        // Guard the reconstruction itself: this hex is the ledger entry in
        // FractalPrimitiveKind.historicalBundledSourceHashes. If it mismatches,
        // the test rebuilt the wrong payload, not the one old builds shipped.
        #expect(stale.sourceHash
            == "ed1daccfbc870c8fa6915210fae8614eabd012624e2059651bc0350022105b8e")
        #expect(stale.sourceHash != FractalPrimitiveKind.box.formula.sourceHash)
        #expect(stale.bundledConstructionPrimitiveKind == .box)
    }

    @Test("Bundled payload edits must extend the historical trust ledger")
    func bundledPayloadSourceHashesArePinned() {
        // `bundledConstructionPrimitiveKind` trusts payloads by source hash, so
        // editing a shipped primitive's Metal source silently orphans every
        // scene saved by earlier builds unless the outgoing hash is kept. If a
        // pin below fails: append the hash pinned HERE (the pre-edit value) to
        // FractalPrimitiveKind.historicalBundledSourceHashes for that kind,
        // then update the pin to the new `sourceHash`. New kinds only need a
        // pin — no scenes embed them yet.
        let pinned: [FractalPrimitiveKind: String] = [
            .sphere: "741b5b3a773cc14b34b7ceacb944c352b54f7b0776b7a4f122995403266c8b3d",
            .box: "a177b1d1db51e3bf9cf0382c59e5c222d6451fbbb779d29e5d0e7663e1f2b2a4",
            .torus: "0f3cdea5c9204e59727704044142a7be4f873409ce06495cbf47e10b62475663",
            .octahedron: "4fbe1ed64ba13851b96fd1b87fe9d54221847f9976c86c2a092ffdfa68879eec",
            .capsule: "4440ffbcb8bf7ba1421f0db3af8bbc4177a41e515038f9afd84256ac70ba485a",
            .cylinder: "e18d980a6c2d2aba4f1ddabdc607a3b870d548519ad46c80a1f65e2dc283c89e",
            .cone: "b909ef549c1545c5180b4e17587531cbc84a628559ed8505be2b2fcac41f8e0d",
            .hexagonalPrism: "ecdeeaa2d3e2b461ee68a2ea344d048ca22b49d679138d043348486e0e7be0f3",
            .pyramid: "40d5e3f2823cd203c4704418ad963acb67544815686a672a31b073d2dbeb6333",
            .tetrahedron: "449b3aa1f96afbfb741786fe664332294dedce3ef1be419fe17bf3ff8380cfd1",
            .icosahedron: "6d717a8406d75a0fd33f8be082277495f3e93cb513aa591f5ddb886464777b53",
            .dodecahedron: "2bc3fdfe56f45c357ddaad9890c245c696882eee2f441bda7c8d9e6d89149325",
            .mandelboxSeed: "9503f36d41b58b08ab7adccd916dda6e1413a7bb586bb0de8996bbc16c06342b"
        ]
        for kind in FractalPrimitiveKind.allCases {
            #expect(
                kind.formula.sourceHash == pinned[kind],
                "\(kind.name) payload changed — move the old pin into historicalBundledSourceHashes before repinning"
            )
        }
        // Every ledger entry must still be recognized as its kind, and none may
        // duplicate a current payload (that would mean a pointless entry).
        for (kind, hashes) in FractalPrimitiveKind.historicalBundledSourceHashes {
            for hash in hashes {
                #expect(hash != kind.formula.sourceHash)
                #expect(hash.count == 64)
            }
        }
    }

    @Test("Raw float selectors from scene files convert without trapping")
    func rawSelectorConversionIsTotal() {
        // Scene decode applies formulaParamValues verbatim, so slot 0 can hold
        // any Float. `Int(Float)` traps on NaN/±inf/|v| > Int.max — the UI must
        // reject those instead of converting (the shader clamps the same slot).
        for primitive in FractalPrimitiveKind.allCases {
            #expect(FractalPrimitiveKind(rawSelector: Float(primitive.selector)) == primitive)
        }
        #expect(FractalPrimitiveKind(rawSelector: 0.4) == .sphere)   // rounds down
        #expect(FractalPrimitiveKind(rawSelector: 1e30) == nil)      // > Int.max: trapped before
        #expect(FractalPrimitiveKind(rawSelector: -1e30) == nil)
        #expect(FractalPrimitiveKind(rawSelector: .nan) == nil)      // trapped before
        #expect(FractalPrimitiveKind(rawSelector: .infinity) == nil)
        #expect(FractalPrimitiveKind(rawSelector: -.infinity) == nil)
        #expect(FractalPrimitiveKind(rawSelector: -1) == nil)
        #expect(FractalPrimitiveKind(rawSelector: 13) == nil)        // past the library
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
