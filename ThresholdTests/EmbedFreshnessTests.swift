//
//  EmbedFreshnessTests.swift
//  ThresholdTests
//
//  TECH_DEBT.md #1 — the embed-freshness gate.
//
//  `EmbeddedMetalSources.swift` is generated into each target's Derived Sources
//  directory from ShaderTypes.h, the formula headers, and Shaders.metal. It is
//  used by CustomShaderCompiler to build runtime `.threshfx` libraries.
//
//  These tests pin the build phase and generator contract byte-for-byte so a
//  wiring regression cannot silently corrupt runtime-compiled shaders.
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
                    vs on-disk \(diskLines.count) lines). The Generate Metal Embeds build \
                    phase is stale or miswired; clean the build and verify its input list.
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
