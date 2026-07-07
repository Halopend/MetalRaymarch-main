//
//  EmbedFreshnessTests.swift
//  ThresholdTests
//
//  TECH_DEBT.md #1 — the embed-freshness gate.
//
//  `EmbeddedMetalSources.swift` is a generated copy of ShaderTypes.h, the
//  formula headers, and Shaders.metal, used by CustomShaderCompiler to build
//  runtime `.threshfx` libraries. Regeneration (Scripts/generate_metal_embeds.sh
//  / `build.sh embeds`) is manual, and a stale copy fails SILENTLY: the static
//  pipelines use the new struct layouts while every runtime-compiled formula
//  uses the old ones — mis-laid-out uniforms, not a compile error. This bit
//  live on 2026-07-01 (`benchAblate`) and needed 4 hand-regens on 2026-07-02.
//
//  These tests pin every embedded block byte-for-byte to its on-disk source,
//  so a stale regen is a red test instead of a corrupted render.
//
//  Generator contract this relies on (generate_metal_embeds.sh): each block is
//  emitted as `#"""` + newline + file bytes + newline + `"""#` with the closing
//  delimiter at column 0, so the Swift string value is exactly the file bytes.
//

import Testing
import Foundation
@testable import Threshold

@Suite("EmbeddedMetalSources freshness — embeds must match the on-disk shader sources")
struct EmbedFreshnessTests {

    /// Repo root, derived from this source file's compile-time path. Tests for
    /// this project run from the repo (Scripts/build.sh test), so the sources
    /// are always present; a missing file is a real failure, not a skip.
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // …/ThresholdTests
        .deletingLastPathComponent()   // repo root

    /// Every block the generator emits, in generator order.
    private static let blocks: [(name: String, embedded: String, path: String)] = [
        ("shaderTypesH",          EmbeddedMetalSources.shaderTypesH,          "Threshold/Rendering/ShaderTypes.h"),
        ("fractalFormulaCommonH", EmbeddedMetalSources.fractalFormulaCommonH, "Threshold/Formulas/FractalFormulaCommon.h"),
        ("fractalFormulasH",      EmbeddedMetalSources.fractalFormulasH,      "Threshold/Formulas/FractalFormulas.h"),
        ("mandelbulbH",           EmbeddedMetalSources.mandelbulbH,           "Threshold/Formulas/Mandelbulb/Mandelbulb.h"),
        ("mengerH",               EmbeddedMetalSources.mengerH,               "Threshold/Formulas/Menger/Menger.h"),
        ("quaternionJuliaH",      EmbeddedMetalSources.quaternionJuliaH,      "Threshold/Formulas/QuaternionJulia/QuaternionJulia.h"),
        ("octahedronH",           EmbeddedMetalSources.octahedronH,           "Threshold/Formulas/Octahedron/Octahedron.h"),
        ("mengerSphereH",         EmbeddedMetalSources.mengerSphereH,         "Threshold/Formulas/MengerSphere/MengerSphere.h"),
        ("theliPseudoKleinianH",  EmbeddedMetalSources.theliPseudoKleinianH,  "Threshold/Formulas/TheliPseudoKleinian/TheliPseudoKleinian.h"),
        ("kleinianH",             EmbeddedMetalSources.kleinianH,             "Threshold/Formulas/Kleinian/Kleinian.h"),
        ("shadersMetal",          EmbeddedMetalSources.shadersMetal,          "Threshold/Rendering/Shaders.metal"),
    ]

    @Test("Every embedded source block matches its on-disk file byte-for-byte")
    func embedsAreFresh() throws {
        for block in Self.blocks {
            let url = Self.repoRoot.appendingPathComponent(block.path)
            let onDisk = try String(contentsOf: url, encoding: .utf8)
            if block.embedded != onDisk {
                // Don't dump 6k-line strings — report the first divergent line.
                let embeddedLines = block.embedded.components(separatedBy: "\n")
                let diskLines = onDisk.components(separatedBy: "\n")
                let firstDiff = zip(embeddedLines, diskLines).enumerated()
                    .first { $1.0 != $1.1 }.map { $0.offset + 1 }
                    ?? min(embeddedLines.count, diskLines.count) + 1
                Issue.record("""
                    STALE EMBED: \(block.name) no longer matches \(block.path) \
                    (first difference at line \(firstDiff); embedded \(embeddedLines.count) \
                    vs on-disk \(diskLines.count) lines). Run Scripts/generate_metal_embeds.sh \
                    (or Scripts/build.sh embeds) and commit the result — a stale embed silently \
                    mis-lays-out structs for every runtime-compiled .threshfx formula.
                    """)
            }
        }
    }

    @Test("The block table covers every embedded constant (new emit_block lines must be added here)")
    func blockTableIsComplete() throws {
        // If someone adds an emit_block to the generator, this test must grow
        // with it or freshness silently stops being checked for the new file.
        // The generator script is the source of truth for the block list.
        let script = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("Scripts/generate_metal_embeds.sh"),
            encoding: .utf8)
        let emitted = script.components(separatedBy: "\n")
            .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("emit_block ") }
        #expect(emitted.count == Self.blocks.count,
                "generate_metal_embeds.sh emits \(emitted.count) blocks but EmbedFreshnessTests checks \(Self.blocks.count) — keep them in lockstep")
    }
}
