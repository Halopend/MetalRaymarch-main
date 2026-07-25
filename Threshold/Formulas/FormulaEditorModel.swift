//
//  FormulaEditorModel.swift
//  Threshold
//
//  UI-free engine of the live formula editor. Owns the two-speed loop:
//
//  INSTANT (every keystroke, <1 ms): parse `// @param` pragmas + derive the
//  DE_<stem> pair → re-register the draft in the catalogs → the parameter
//  sliders regenerate this frame via the registration-token invalidation.
//  The renderer is untouched — it keeps drawing the last good library.
//
//  DEBOUNCED (0.9 s after the last edit, or Compile Now): validate() +
//  pragma/stem pre-flight (free), then hand the draft to
//  `AppModel.installEmbeddedFormulaForLiveEdit` (0.5–5 s Metal compile,
//  latest-wins with one compile in flight and at most one pending). On
//  failure the compile log is mapped back to user-source lines; the previous
//  shader keeps rendering.
//
//  Invariant (SpaceWarpStackCodegen post-mortem): parameter VALUES always
//  flow through the per-frame formulaParams[16] uniforms. A compile changes
//  CODE only, so the instant UI and the slow shader can disagree for seconds
//  with zero rendering breakage.
//
//  Superseded draft libraries are left in CustomShaderCompiler's in-memory
//  cache for the session (one per successful compile generation; the cache
//  dies with the process and pipeline retention is bounded MRU-4).
//

import Foundation
import Observation

@MainActor
@Observable
final class FormulaEditorModel {

    enum Status: Equatable {
        /// Nothing to compile yet (fresh model, or draft never activated).
        case idle
        /// Pragma/stem problems block compilation; see `pragmaDiagnostics`
        /// and `stemDerivation`.
        case blockedByParseIssues
        /// A Metal compile is running (or queued behind one in flight).
        case compiling
        /// The current draft compiled and is rendering.
        case live
        /// The last compile failed; see `compileDiagnostics`.
        case compileFailed
        /// Custom scenes are disabled in Settings → General.
        case disabled
        /// The renderer hasn't bound its activation handler yet.
        case rendererUnavailable
    }

    // MARK: - Draft state (observable)

    private(set) var formulaID: String
    private(set) var name: String
    private(set) var source: String
    private(set) var isDirty = false
    private(set) var status: Status = .idle
    private(set) var pragmaDiagnostics: [FormulaPragmaDiagnostic] = []
    private(set) var compileDiagnostics: [MetalCompileDiagnostic] = []
    private(set) var stemDerivation: FormulaStemDerivation = .missing
    private(set) var parsedParams: [FormulaParamDescriptor] = []
    /// The library file backing this draft, when it was loaded from (or has
    /// been saved to) the library.
    private(set) var savedEntry: FormulaLibraryEntry?

    // MARK: - Dependencies

    /// Compile hook. Production wires `AppModel.installEmbeddedFormulaForLiveEdit`;
    /// tests inject a stub so the loop is exercised headlessly.
    var compileHandler: @MainActor (EmbeddedFormula) async -> LiveEditCompileOutcome
    /// Called on the instant path with each re-registered draft. Production
    /// wires `ControlStateStore.noteCustomFormulaDefinitionChanged`.
    var definitionChangedHandler: @MainActor (EmbeddedFormula) -> Void
    var compileDebounce: Duration = .milliseconds(900)

    private let library: FormulaLibraryStore?

    // MARK: - Compile-loop state

    private var debounceTask: Task<Void, Never>?
    private var compileInFlight = false
    private var pendingCompile = false
    /// Monotonic edit generation; results for stale generations are discarded.
    private var generation: UInt64 = 0

    // MARK: - Init

    init(library: FormulaLibraryStore? = nil,
         compileHandler: @escaping @MainActor (EmbeddedFormula) async -> LiveEditCompileOutcome = { _ in .rendererUnavailable },
         definitionChangedHandler: @escaping @MainActor (EmbeddedFormula) -> Void = { _ in }) {
        self.library = library
        self.compileHandler = compileHandler
        self.definitionChangedHandler = definitionChangedHandler
        self.formulaID = "user.\(UUID().uuidString.lowercased())"
        self.name = "New Formula"
        self.source = Self.newFormulaTemplate
        refreshParse()
    }

    // MARK: - Templates

    /// Starter source: a sphere-fold DE with the exact function signatures the
    /// dispatch arms call, plus a pragma the author can copy from.
    static let newFormulaTemplate = """
    // @param 0 "Scale" default=2.0 min=0.5 max=4.0 step=0.01
    // @param 1 "Min R²" default=0.25 min=0.01 max=1.0 step=0.01

    // Lean distance-only variant — called for every march step.
    FORCE_INLINE float DE_MyFormula_Dist(float3 pos, FormulaParams fp, float3x3 rot, int iterations) {
        float scale = max(fp.params[0], 0.1f);
        float minR2 = max(fp.params[1], 1e-4f);
        float3 p = pos;
        float dr = 1.0f;
        for (int i = 0; i < iterations; ++i) {
            p = clamp(p, -1.0f, 1.0f) * 2.0f - p;
            float r2 = dot(p, p);
            if (r2 < minR2) { float k = 1.0f / minR2; p *= k; dr *= k; }
            else if (r2 < 1.0f) { float k = 1.0f / r2; p *= k; dr *= k; }
            p = p * scale;
            dr = dr * scale + 1.0f;
        }
        return 0.5f * length(p) / max(abs(dr), 1e-6f);
    }

    // Orbit-tracking variant — feeds coloring. Keep the math identical.
    FORCE_INLINE float DE_MyFormula(float3 pos, FormulaParams fp, float3x3 rot,
                                    int iterations, int colorIterations,
                                    thread OrbitData& orbit) {
        float scale = max(fp.params[0], 0.1f);
        float minR2 = max(fp.params[1], 1e-4f);
        float3 p = pos;
        float dr = 1.0f;
        float trap = 1e20f;
        int trapIter = 0;
        float3 trapPos = pos;
        int trapIterations = min(max(colorIterations, 0), iterations);
        int i = 0;
        for (; i < iterations; ++i) {
            p = clamp(p, -1.0f, 1.0f) * 2.0f - p;
            float r2 = dot(p, p);
            if (r2 < minR2) { float k = 1.0f / minR2; p *= k; dr *= k; }
            else if (r2 < 1.0f) { float k = 1.0f / r2; p *= k; dr *= k; }
            p = p * scale;
            dr = dr * scale + 1.0f;
            if (i < trapIterations) {
                float r2t = dot(p, p);
                if (r2t < trap) { trap = r2t; trapIter = i; trapPos = p; }
            }
        }
        orbit.trap = trap;
        orbit.trapIteration = trapIter;
        orbit.trapPosition = trapPos;
        orbit.finalP = p;
        orbit.iterationsUsed = i;
        return 0.5f * length(p) / max(abs(dr), 1e-6f);
    }
    """

    // MARK: - Loading

    /// Reset to a fresh draft (New Formula) — new identity, template source,
    /// same handlers — and activate it.
    func startNewDraft() {
        formulaID = "user.\(UUID().uuidString.lowercased())"
        name = "New Formula"
        source = Self.newFormulaTemplate
        savedEntry = nil
        isDirty = false
        compileDiagnostics = []
        refreshParse()
        activate()
    }

    /// Begin editing an existing formula (library entry or scene-embedded).
    /// Legacy payloads without pragmas get pragma lines prepended so the
    /// source becomes the single authoring surface.
    func load(_ formula: EmbeddedFormula, savedEntry: FormulaLibraryEntry? = nil) {
        formulaID = formula.id
        name = formula.name
        let parsed = FormulaPragmaParser.parse(formula.metalSource)
        if parsed.hasPragmas || formula.params.isEmpty {
            source = formula.metalSource
        } else {
            source = FormulaPragmaParser.pragmaLines(for: formula.params)
                + "\n\n" + formula.metalSource
        }
        self.savedEntry = savedEntry
        isDirty = false
        refreshParse()
    }

    // MARK: - Editing (instant path)

    func setName(_ newName: String) {
        guard newName != name else { return }
        name = newName
        isDirty = true
        applyInstantUpdate()
    }

    func setSource(_ newSource: String) {
        guard newSource != source else { return }
        source = newSource
        isDirty = true
        applyInstantUpdate()
    }

    /// Activate the draft for the first time (editor opened): register it and
    /// kick the first compile without waiting for an edit.
    func activate() {
        applyInstantUpdate(immediateCompile: true)
    }

    /// Skip the debounce (Cmd-B / Compile Now).
    func compileNow() {
        debounceTask?.cancel()
        debounceTask = nil
        startCompileIfPossible()
    }

    private func applyInstantUpdate(immediateCompile: Bool = false) {
        generation &+= 1
        refreshParse()

        // Register the draft so the parameter UI regenerates NOW, even while
        // the source itself is mid-edit or broken — sliders follow pragmas,
        // values ride the uniforms, the renderer stays on last-good code.
        definitionChangedHandler(currentDraft())

        if immediateCompile {
            compileNow()
        } else {
            scheduleDebouncedCompile()
        }
    }

    private func refreshParse() {
        let parsed = FormulaPragmaParser.parse(source)
        parsedParams = parsed.params
        pragmaDiagnostics = parsed.diagnostics
        stemDerivation = FormulaPragmaParser.deriveFunctionStem(from: source)
    }

    /// The draft as it stands. The stem falls back to a placeholder while the
    /// source doesn't define a unique DE pair (registration tolerates it; the
    /// compile pre-flight blocks it with a diagnostic instead).
    func currentDraft() -> EmbeddedFormula {
        EmbeddedFormula(
            kind: .fractal,
            id: formulaID,
            name: name,
            category: "My Formulas",
            author: nil,
            formulaDescription: nil,
            functionStem: stemDerivation.stem ?? "PendingStem",
            metalSource: source,
            params: parsedParams,
            defaultIterations: nil,
            defaultColorIterations: nil,
            supportedEffectTagsRaw: []
        )
    }

    // MARK: - Compile loop (debounced path)

    private func scheduleDebouncedCompile() {
        debounceTask?.cancel()
        let delay = compileDebounce
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.debounceTask = nil
            self?.startCompileIfPossible()
        }
    }

    private func startCompileIfPossible() {
        // Free pre-flight: pragma errors or an unresolved stem block the
        // 0.5–5 s compile before it starts.
        let hasPragmaErrors = pragmaDiagnostics.contains { $0.severity == .error }
        guard !hasPragmaErrors, stemDerivation.stem != nil else {
            status = .blockedByParseIssues
            return
        }

        // One compile in flight; the newest draft compiles right after.
        guard !compileInFlight else {
            pendingCompile = true
            return
        }
        compileInFlight = true
        status = .compiling
        let draft = currentDraft()
        let startedGeneration = generation

        Task { [weak self] in
            guard let self else { return }
            let outcome = await self.compileHandler(draft)
            self.finishCompile(outcome: outcome, startedGeneration: startedGeneration, draft: draft)
        }
    }

    private func finishCompile(outcome: LiveEditCompileOutcome,
                               startedGeneration: UInt64,
                               draft: EmbeddedFormula) {
        compileInFlight = false

        // A newer draft is waiting: chain into it and discard this result's
        // diagnostics (they describe superseded source).
        if pendingCompile {
            pendingCompile = false
            startCompileIfPossible()
            return
        }

        // Edits arrived while compiling but the debounce hasn't fired yet:
        // this result is stale for status purposes; let the debounce decide.
        guard startedGeneration == generation else { return }

        switch outcome {
        case .ready:
            compileDiagnostics = []
            status = .live
        case .disabled:
            status = .disabled
        case .rendererUnavailable:
            status = .rendererUnavailable
        case .invalid(let error):
            compileDiagnostics = [MetalCompileDiagnostic(
                userLine: nil, column: nil, severity: .error,
                message: String(describing: error), rawLine: "")]
            status = .compileFailed
        case .compileFailed(let error):
            let log = (error as NSError).localizedDescription
            let startLine = CustomShaderCompiler.fractalUserSourceStartLine(
                fractal: draft, spaceWarp: nil)
            let lineCount = draft.metalSource.reduce(into: 1) { count, ch in
                if ch == "\n" { count += 1 }
            }
            let parsed = MetalCompileLogParser.parse(
                log: log, userSourceStartLine: startLine, userSourceLineCount: lineCount)
            compileDiagnostics = parsed.isEmpty
                ? [MetalCompileDiagnostic(userLine: nil, column: nil, severity: .error,
                                          message: log, rawLine: log)]
                : parsed
            status = .compileFailed
        }
    }

    // MARK: - Persistence

    /// Serialize the parsed pragmas into the params array and write to the
    /// library. Every existing `.threshfx` consumer reads the JSON params,
    /// so saved files work in older app versions too.
    @discardableResult
    func save() throws -> FormulaLibraryEntry? {
        guard let library else { return nil }
        let entry = try library.save(currentDraft())
        savedEntry = entry
        isDirty = false
        return entry
    }
}
