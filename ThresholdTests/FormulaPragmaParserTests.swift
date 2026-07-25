//
//  FormulaPragmaParserTests.swift
//  ThresholdTests
//
//  Grammar coverage for the live-editor pragma parser: happy paths, every
//  diagnostic class (malformed lines must produce messages, never crashes,
//  and must not damage well-formed params on other lines), stem derivation,
//  and the round-trip serializer used to seed pragmas from legacy JSON params.
//

import Foundation
import Testing
@testable import Threshold

@Suite("Formula pragma parser")
struct FormulaPragmaParserTests {

    @Test("A full pragma parses every field")
    func fullPragma() {
        let source = """
        // @param 0 "Fold Scale" default=2.0 min=0.5 max=4.0 step=0.01
        float unrelated = 1.0;
        """
        let result = FormulaPragmaParser.parse(source)
        #expect(result.hasPragmas)
        #expect(result.diagnostics.isEmpty)
        #expect(result.params.count == 1)
        let param = result.params[0]
        #expect(param.index == 0)
        #expect(param.name == "Fold Scale")
        #expect(param.default == 2.0)
        #expect(param.min == 0.5)
        #expect(param.max == 4.0)
        #expect(param.step == 0.01)
        #expect(param.isBool == nil)
        #expect(param.isHidden == nil)
    }

    @Test("bool and hidden flags, key order freedom, and XYZ-suffix names")
    func flagsAndKeyOrder() {
        let source = """
        // @param 3 "Julia Mode" max=1 default=0 min=0 bool
        //@param 4 "Offset.x" min=-2 max=2 default=0 hidden
        """
        let result = FormulaPragmaParser.parse(source)
        #expect(result.diagnostics.isEmpty)
        #expect(result.params.count == 2)
        #expect(result.params[0].isBool == true)
        #expect(result.params[1].isHidden == true)
        #expect(result.params[1].name == "Offset.x")
    }

    @Test("Params come back sorted by index regardless of line order")
    func sortedByIndex() {
        let source = """
        // @param 5 "B" default=0 min=0 max=1
        // @param 1 "A" default=0 min=0 max=1
        """
        let result = FormulaPragmaParser.parse(source)
        #expect(result.params.map(\.index) == [1, 5])
    }

    @Test("Missing step defaults to a 1-2-5 series step")
    func defaultStep() {
        let source = #"// @param 0 "Scale" default=1 min=0 max=2"#
        let result = FormulaPragmaParser.parse(source)
        // (2-0)/200 = 0.01 exactly.
        #expect(result.params[0].step == 0.01)

        // 0...300 → raw 1.5 → snaps to 2.
        #expect(FormulaPragmaParser.defaultStep(min: 0, max: 300) == 2)
        // 0...60 → raw 0.3 → snaps to 0.2 (mantissa 3 < 3.5).
        #expect(abs(FormulaPragmaParser.defaultStep(min: 0, max: 60) - 0.2) < 1e-6)
        // 0...1000 → raw 5 → snaps to 5.
        #expect(FormulaPragmaParser.defaultStep(min: 0, max: 1000) == 5)
    }

    @Test("Every malformed line yields a diagnostic without harming the others")
    func malformedLines() {
        let source = """
        // @param 0 "Good" default=1 min=0 max=2
        // @param 99 "OutOfRange" default=0 min=0 max=1
        // @param 1 "NoDefault" min=0 max=1
        // @param 2 "BadNumber" default=abc min=0 max=1
        // @param 3 "MinNotBelowMax" default=0 min=1 max=1
        // @param 4 "Unterminated default=0 min=0 max=1
        // @param x "NoIndex" default=0 min=0 max=1
        // @param 5 "NegativeStep" default=0 min=0 max=1 step=-1
        """
        let result = FormulaPragmaParser.parse(source)
        #expect(result.params.map(\.index) == [0])
        #expect(result.diagnostics.count == 7)
        #expect(result.diagnostics.allSatisfy { $0.severity == .error })
        // Lines are 1-based and anchored to the offending pragma.
        #expect(result.diagnostics.map(\.line) == [2, 3, 4, 5, 6, 7, 8])
    }

    @Test("A duplicate index keeps the first declaration and flags the second")
    func duplicateIndex() {
        let source = """
        // @param 0 "First" default=1 min=0 max=2
        // @param 0 "Second" default=0 min=0 max=1
        """
        let result = FormulaPragmaParser.parse(source)
        #expect(result.params.count == 1)
        #expect(result.params[0].name == "First")
        #expect(result.diagnostics.count == 1)
        #expect(result.diagnostics[0].line == 2)
        #expect(result.diagnostics[0].severity == .error)
    }

    @Test("Unknown keys and flags warn but do not reject the param")
    func unknownKeysWarn() {
        let source = #"// @param 0 "Scale" default=1 min=0 max=2 curve=log fancy"#
        let result = FormulaPragmaParser.parse(source)
        #expect(result.params.count == 1)
        #expect(result.diagnostics.count == 2)
        #expect(result.diagnostics.allSatisfy { $0.severity == .warning })
    }

    @Test("An out-of-range default clamps with a warning")
    func defaultClamps() {
        let source = #"// @param 0 "Scale" default=9 min=0 max=2"#
        let result = FormulaPragmaParser.parse(source)
        #expect(result.params[0].default == 2)
        #expect(result.diagnostics.count == 1)
        #expect(result.diagnostics[0].severity == .warning)
    }

    @Test("Sources without pragmas report hasPragmas == false")
    func noPragmas() {
        let source = """
        // A perfectly ordinary comment mentioning @param usage in prose? No —
        float DE_Thing_Dist(float3 p, FormulaParams fp) { return length(p); }
        """
        let result = FormulaPragmaParser.parse(source)
        #expect(!result.hasPragmas)
        #expect(result.params.isEmpty)
    }

    // MARK: - Stem derivation

    @Test("A unique DE_<stem> / DE_<stem>_Dist pair derives the stem")
    func stemDerivation() {
        let source = """
        FORCE_INLINE float DE_SphereFold_Dist(float3 p, FormulaParams fp) { return 0.0f; }
        FORCE_INLINE float2 DE_SphereFold(float3 p, FormulaParams fp) { return float2(0); }
        """
        #expect(FormulaPragmaParser.deriveFunctionStem(from: source) == .derived("SphereFold"))
    }

    @Test("A lone _Dist function derives nothing")
    func stemMissing() {
        let source = "float DE_Alone_Dist(float3 p) { return 0.0f; }"
        #expect(FormulaPragmaParser.deriveFunctionStem(from: source) == .missing)
    }

    @Test("Two complete pairs are ambiguous")
    func stemAmbiguous() {
        let source = """
        float DE_One_Dist(float3 p) { return 0; } float2 DE_One(float3 p) { return 0; }
        float DE_Two_Dist(float3 p) { return 0; } float2 DE_Two(float3 p) { return 0; }
        """
        #expect(FormulaPragmaParser.deriveFunctionStem(from: source) == .ambiguous(["One", "Two"]))
    }

    // MARK: - Round trip

    @Test("Serialized pragma lines re-parse to the same params")
    func roundTrip() {
        let params = [
            FormulaParamDescriptor(index: 0, name: "Fold Scale", default: 2.0,
                                   min: 0.5, max: 4.0, step: 0.01),
            FormulaParamDescriptor(index: 3, name: "Julia Mode", default: 0,
                                   min: 0, max: 1, step: 1, isBool: true),
            FormulaParamDescriptor(index: 7, name: "Detail", default: 0.5,
                                   min: 0, max: 1, step: 0.005, isHidden: true)
        ]
        let lines = FormulaPragmaParser.pragmaLines(for: params)
        let reparsed = FormulaPragmaParser.parse(lines)
        #expect(reparsed.diagnostics.isEmpty)
        #expect(reparsed.params.count == params.count)
        for (original, round) in zip(params, reparsed.params) {
            #expect(round.index == original.index)
            #expect(round.name == original.name)
            #expect(round.default == original.default)
            #expect(round.min == original.min)
            #expect(round.max == original.max)
            #expect(round.step == original.step)
            #expect((round.isBool == true) == (original.isBool == true))
            #expect((round.isHidden == true) == (original.isHidden == true))
        }
    }
}
