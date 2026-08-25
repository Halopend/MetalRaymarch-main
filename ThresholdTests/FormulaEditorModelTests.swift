//
//  FormulaEditorModelTests.swift
//  ThresholdTests
//
//  Headless coverage of the live editor's two-speed loop via an injected
//  compile stub: debounce coalescing, one-in-flight/latest-wins chaining,
//  keep-last-good on failure with log→user-line mapping, pre-flight
//  blocking, and pragma→params serialization on the instant path.
//

import Foundation
import Testing
@testable import Threshold

@MainActor
private final class CompileRecorder {
    var compiledSources: [String] = []
    var outcome: LiveEditCompileOutcome = .ready
    /// When true, compiles suspend until `release()`.
    var gated = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func handler(_ draft: EmbeddedFormula) async -> LiveEditCompileOutcome {
        compiledSources.append(draft.metalSource)
        if gated {
            await withCheckedContinuation { waiters.append($0) }
        }
        return outcome
    }

    func release() {
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().resume()
    }

    var suspendedCount: Int { waiters.count }
}

@MainActor
@Suite("Formula editor model", .serialized)
struct FormulaEditorModelTests {

    private let validSource = """
    // @param 0 "Radius" default=1.0 min=0.1 max=4.0
    FORCE_INLINE float DE_EditorFixture_Dist(float3 p, FormulaParams fp, float3x3 rot, int iterations) {
        return length(p) - fp.params[0];
    }
    FORCE_INLINE float2 DE_EditorFixture(float3 p, FormulaParams fp, float3x3 rot,
                                         int iterations, int colorIterations,
                                         thread OrbitData& orbit) {
        return float2(DE_EditorFixture_Dist(p, fp, rot, iterations), 0.0f);
    }
    """

    private func makeModel(recorder: CompileRecorder) -> FormulaEditorModel {
        let model = FormulaEditorModel(
            library: nil,
            compileHandler: { await recorder.handler($0) }
        )
        model.compileDebounce = .milliseconds(40)
        return model
    }

    private func waitUntil(_ condition: @MainActor () -> Bool,
                           timeoutMs: Int = 3_000) async {
        for _ in 0..<(timeoutMs / 5) {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test("Rapid edits coalesce into one compile of the latest draft")
    func debounceCoalescing() async {
        let recorder = CompileRecorder()
        let model = makeModel(recorder: recorder)

        model.setSource(validSource.replacingOccurrences(of: "1.0", with: "1.1"))
        model.setSource(validSource.replacingOccurrences(of: "1.0", with: "1.2"))
        model.setSource(validSource.replacingOccurrences(of: "1.0", with: "1.3"))

        await waitUntil { model.status == .live }
        #expect(recorder.compiledSources.count == 1)
        #expect(recorder.compiledSources.first?.contains("default=1.3") == true)
        #expect(model.status == .live)
    }

    @Test("Manual mode never compiles an edit until Compile is pressed")
    func manualCompilation() async {
        let recorder = CompileRecorder()
        let model = makeModel(recorder: recorder)
        model.setAutomaticallyCompilesEdits(false)

        model.setSource(validSource)
        try? await Task.sleep(for: .milliseconds(120))
        #expect(recorder.compiledSources.isEmpty)
        #expect(model.status == .idle)

        model.compileNow()
        await waitUntil { model.status == .live }
        #expect(recorder.compiledSources.count == 1)
    }

    @Test("Compile publishes an untouched formula loaded in manual mode")
    func manualLoadedFormulaPublishesBeforeCompile() async {
        let recorder = CompileRecorder()
        var published: [EmbeddedFormula] = []
        var events: [String] = []
        let model = FormulaEditorModel(
            library: nil,
            compileHandler: { draft in
                events.append("compile")
                return await recorder.handler(draft)
            },
            definitionChangedHandler: { draft in
                events.append("publish")
                published.append(draft)
            }
        )
        model.setAutomaticallyCompilesEdits(false)
        let loaded = EmbeddedFormula(
            kind: .fractal,
            id: "builtin.editor-fixture",
            name: "Editor Fixture",
            category: "Built-in",
            author: nil,
            formulaDescription: nil,
            functionStem: "EditorFixture",
            metalSource: validSource,
            params: [],
            defaultIterations: nil,
            defaultColorIterations: nil,
            supportedEffectTagsRaw: []
        )

        model.load(loaded)
        #expect(published.isEmpty)

        model.compileNow()
        await waitUntil { model.status == .live }

        #expect(published.map(\.id) == [loaded.id])
        #expect(events == ["publish", "compile"])
        #expect(recorder.compiledSources.count == 1)
    }

    @Test("Function constant indices are unique and pin the DE-tail slots")
    func functionConstantIndices() {
        let indices = FunctionConstantIndex.shaderSpecializationCases.map(\.rawValue)
        #expect(Set(indices).count == indices.count)
        #expect(indices == Array(0...18))
        #expect(FunctionConstantIndex.sphereProjectionEnabled.rawValue == 17)
        #expect(FunctionConstantIndex.hasHandField.rawValue == 18)
    }

    @Test("An edit during a compile chains exactly one follow-up (latest wins)")
    func latestWinsChaining() async {
        let recorder = CompileRecorder()
        recorder.gated = true
        let model = makeModel(recorder: recorder)

        model.setSource(validSource)
        model.compileNow()
        await waitUntil { recorder.suspendedCount == 1 }
        #expect(model.status == .compiling)

        // Two more "editions" while the first compile is stuck in flight.
        model.setSource(validSource.replacingOccurrences(of: "Radius", with: "RadiusB"))
        model.compileNow()
        model.setSource(validSource.replacingOccurrences(of: "Radius", with: "RadiusC"))
        model.compileNow()

        recorder.release()
        await waitUntil { recorder.suspendedCount == 1 }
        recorder.release()
        await waitUntil { model.status == .live }

        // First compile + exactly one chained follow-up with the NEWEST source.
        #expect(recorder.compiledSources.count == 2)
        #expect(recorder.compiledSources.last?.contains("RadiusC") == true)
    }

    @Test("A failed compile maps the log to user lines and keeps diagnostics")
    func compileFailureMapsDiagnostics() async {
        let recorder = CompileRecorder()
        let model = makeModel(recorder: recorder)
        model.setSource(validSource)

        // Build the fake Metal log against the REAL layout for this draft, so
        // the mapping assertion exercises fractalUserSourceStartLine.
        let draft = model.currentDraft()
        let startLine = CustomShaderCompiler.fractalUserSourceStartLine(fractal: draft, spaceWarp: nil)
        let log = "program_source:\(startLine + 2):9: error: use of undeclared identifier 'nope'"
        recorder.outcome = .compileFailed(NSError(
            domain: "MTLLibraryErrorDomain", code: 3,
            userInfo: [NSLocalizedDescriptionKey: log]))

        model.compileNow()
        await waitUntil { model.status == .compileFailed }

        #expect(model.status == .compileFailed)
        #expect(model.compileDiagnostics.count == 1)
        #expect(model.compileDiagnostics.first?.userLine == 3)
        #expect(model.compileDiagnostics.first?.severity == .error)

        // Recovery: a successful compile clears the diagnostics.
        recorder.outcome = .ready
        model.compileNow()
        await waitUntil { model.status == .live }
        #expect(model.compileDiagnostics.isEmpty)
    }

    @Test("Pragma errors and unresolved stems block compilation up front")
    func preflightBlocks() async {
        let recorder = CompileRecorder()
        let model = makeModel(recorder: recorder)

        // Duplicate index = pragma error.
        model.setSource("""
        // @param 0 "A" default=0 min=0 max=1
        // @param 0 "B" default=0 min=0 max=1
        \(validSource)
        """)
        model.compileNow()
        #expect(model.status == .blockedByParseIssues)
        #expect(recorder.compiledSources.isEmpty)

        // No DE pair = unresolved stem.
        model.setSource("// @param 0 \"A\" default=0 min=0 max=1\nfloat nothing;")
        model.compileNow()
        #expect(model.status == .blockedByParseIssues)
        #expect(model.stemDerivation == .missing)
        #expect(recorder.compiledSources.isEmpty)
    }

    @Test("The instant path serializes pragmas into the draft's params")
    func draftCarriesParsedParams() {
        let recorder = CompileRecorder()
        let model = makeModel(recorder: recorder)
        model.setSource(validSource)

        let draft = model.currentDraft()
        #expect(draft.params.count == 1)
        #expect(draft.params.first?.name == "Radius")
        #expect(draft.functionStem == "EditorFixture")
        #expect(draft.id == model.formulaID)
    }

    @Test("Loading a legacy formula without pragmas seeds pragma lines")
    func legacyLoadSeedsPragmas() {
        let recorder = CompileRecorder()
        let model = makeModel(recorder: recorder)

        let legacySource = """
        FORCE_INLINE float DE_Legacy_Dist(float3 p, FormulaParams fp, float3x3 rot, int iterations) {
            return length(p) - fp.params[0];
        }
        FORCE_INLINE float2 DE_Legacy(float3 p, FormulaParams fp, float3x3 rot,
                                      int iterations, int colorIterations,
                                      thread OrbitData& orbit) {
            return float2(0.0f);
        }
        """
        let legacy = EmbeddedFormula(
            kind: .fractal, id: "user.legacy", name: "Legacy",
            category: "Custom", author: nil, formulaDescription: nil,
            functionStem: "Legacy", metalSource: legacySource,
            params: [FormulaParamDescriptor(index: 0, name: "Size", default: 1,
                                            min: 0.1, max: 3, step: 0.01)],
            defaultIterations: nil, defaultColorIterations: nil,
            supportedEffectTagsRaw: [])

        model.load(legacy)
        #expect(model.source.hasPrefix("// @param 0 \"Size\""))
        #expect(model.parsedParams.count == 1)
        #expect(model.parsedParams.first?.name == "Size")
        #expect(!model.isDirty)
    }

    @Test("Invalidating the editor drops an in-flight compile and stops new ones")
    func invalidateDropsInFlightCompile() async {
        let recorder = CompileRecorder()
        recorder.gated = true
        let model = makeModel(recorder: recorder)

        model.setSource(validSource)
        model.compileNow()
        await waitUntil { recorder.suspendedCount == 1 }
        #expect(model.status == .compiling)

        // Editor dismissed while the Metal compile is still running.
        model.invalidate()
        #expect(model.isInvalidated)
        #expect(model.status != .compiling)

        // The stale result must not flip the editor live, and edits after
        // dismissal must not start further compiles.
        recorder.release()
        model.setSource(validSource.replacingOccurrences(of: "Radius", with: "RadiusZ"))
        model.compileNow()
        try? await Task.sleep(for: .milliseconds(120))
        #expect(model.status != .live)
        #expect(recorder.compiledSources.count == 1)
    }

    @Test("Save failures are reported instead of swallowed")
    func saveFailureIsReported() {
        // No library backing the model: save() returns nil without throwing,
        // so the no-error path must clear any stale message.
        let model = makeModel(recorder: CompileRecorder())
        #expect(model.saveReportingErrors())
        #expect(model.saveErrorMessage == nil)
    }
}
