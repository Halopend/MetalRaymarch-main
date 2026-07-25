//
//  MetalCompileDiagnosticsTests.swift
//  ThresholdTests
//
//  Pure log-parser cases plus a real-device pin: a formula with a deliberate
//  error on a known user-source line must map to exactly that line through
//  synthesizeSource's layout. The pin also fails loudly if the synthesized
//  prefix shape ever changes without fractalUserSourceStartLine following.
//

import Foundation
import Metal
import Testing
@testable import Threshold

@Suite("Metal compile diagnostics")
struct MetalCompileDiagnosticsTests {

    @Test("Log lines parse and rebase into user coordinates")
    func parseAndRebase() {
        let log = """
        program_source:5100:17: error: use of undeclared identifier 'radius'
                return length(p) - radius;
                                    ^
        program_source:5102:5: warning: unused variable 'q'
        program_source:12:1: note: expanded from here
        garbage line that must be ignored
        """
        // User source spliced at line 5099, 10 lines long.
        let diagnostics = MetalCompileLogParser.parse(
            log: log, userSourceStartLine: 5099, userSourceLineCount: 10)

        #expect(diagnostics.count == 3)
        #expect(diagnostics[0].severity == .error)
        #expect(diagnostics[0].userLine == 2)
        #expect(diagnostics[0].column == 17)
        #expect(diagnostics[0].message == "use of undeclared identifier 'radius'")
        #expect(diagnostics[1].severity == .warning)
        #expect(diagnostics[1].userLine == 4)
        // The note at synthesized line 12 is scaffolding — no user anchor.
        #expect(diagnostics[2].severity == .note)
        #expect(diagnostics[2].userLine == nil)
    }

    @Test("primaryError prefers user-anchored errors")
    func primaryErrorSelection() {
        let scaffolding = MetalCompileDiagnostic(
            userLine: nil, column: 1, severity: .error, message: "knock-on", rawLine: "")
        let anchored = MetalCompileDiagnostic(
            userLine: 7, column: 3, severity: .error, message: "real cause", rawLine: "")
        #expect(MetalCompileLogParser.primaryError(in: [scaffolding, anchored])?.message == "real cause")
        #expect(MetalCompileLogParser.primaryError(in: [scaffolding])?.message == "knock-on")
    }

    @Test("A deliberate error on user line 5 maps to user line 5 through the real compiler")
    func realDeviceLineMappingPin() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("No Metal device available — skipping the line-mapping pin")
            return
        }

        // Line 5 of the user source (1-based) contains the undeclared
        // identifier. Lines counted on metalSource exactly as spliced.
        let brokenSource = """
        // Line-mapping pin fixture.
        FORCE_INLINE float DE_LineMapPin_Dist(float3 p, FormulaParams fp) {
            return length(p) - fp.params[0];
        }
        static float bad() { return definitely_undeclared_identifier; }
        FORCE_INLINE float2 DE_LineMapPin(float3 p, FormulaParams fp) {
            return float2(DE_LineMapPin_Dist(p, fp), 0.0f);
        }
        """
        let formula = EmbeddedFormula(
            kind: .fractal,
            id: "test.diagnostics.linemap",
            name: "Line Map Pin",
            category: "Tests",
            author: "ThresholdTests",
            formulaDescription: nil,
            functionStem: "LineMapPin",
            metalSource: brokenSource,
            params: [],
            defaultIterations: 1,
            defaultColorIterations: 1,
            supportedEffectTagsRaw: []
        )

        let source = try CustomShaderCompiler.synthesizeSource(fractal: formula, spaceWarp: nil)
        let startLine = CustomShaderCompiler.fractalUserSourceStartLine(fractal: formula, spaceWarp: nil)
        let lineCount = brokenSource.components(separatedBy: "\n").count

        // Sanity: the layout helper and the actual synthesized text agree on
        // where the user source landed.
        let synthesizedLines = source.components(separatedBy: "\n")
        #expect(startLine <= synthesizedLines.count)
        #expect(synthesizedLines[startLine - 1] == "// Line-mapping pin fixture.")

        let options = MTLCompileOptions()
        do {
            _ = try await device.makeLibrary(source: source, options: options)
            Issue.record("The broken fixture compiled — the pin is not pinning")
        } catch {
            let log = (error as NSError).localizedDescription
            let diagnostics = MetalCompileLogParser.parse(
                log: log, userSourceStartLine: startLine, userSourceLineCount: lineCount)
            let primary = MetalCompileLogParser.primaryError(in: diagnostics)
            #expect(primary != nil, "No error diagnostic parsed from log: \(log.prefix(400))")
            #expect(primary?.userLine == 5,
                    "Expected the undeclared-identifier error on user line 5, got \(String(describing: primary?.userLine))")
        }
    }
}
