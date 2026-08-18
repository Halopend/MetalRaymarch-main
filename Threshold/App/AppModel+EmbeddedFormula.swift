//
//  AppModel+EmbeddedFormula.swift
//  Threshold
//
//  Helpers for installing/uninstalling `.threshfx` embedded formulas and
//  bridging them into the FractalPreset import flow.
//

import Foundation
import simd

#if os(macOS) || os(iOS)
private let RENDERER_DEBUG = false
#endif

@inline(__always)
func customSceneDiagnostic(_ message: @autoclosure () -> String) {
    guard RENDERER_DEBUG else { return }
    print(message())
}

/// Result of `installEmbeddedFormulaIfNeededAndWait`. Callers that need to
/// know whether the renderer has *actually* compiled the formula (vs. just
/// having it registered in the catalogs for later activation) check for
/// `.ready` before applying presets that depend on it.
/// Result of `installEmbeddedFormulaForLiveEdit` — the editor's compile loop.
enum LiveEditCompileOutcome {
    /// Draft compiled and is rendering.
    case ready
    /// Custom scenes are disabled in Settings; the editor shows the gate hint.
    case disabled
    /// The renderer's activation handler isn't bound yet; retry on next edit.
    case rendererUnavailable
    /// `EmbeddedFormula.validate()` rejected the draft (size cap, forbidden
    /// tokens, missing DE functions). Pre-flight normally catches this first.
    case invalid(Error)
    /// Metal compilation failed; the error's description carries the full
    /// compiler log for line mapping. The previous library keeps rendering.
    case compileFailed(Error)
}

enum EmbeddedFormulaInstallResult: Equatable {
    /// Formula is activated and compiled in the renderer, OR no formula was
    /// requested. Safe to apply presets that reference this formula.
    case ready
    /// Formula is registered in the catalogs but the renderer's activation
    /// handler isn't bound yet (renderer hasn't started, or has been torn
    /// down). Callers MUST wait for `rendererStartupWarmupComplete` and re-run
    /// activation before applying a preset, or the first frame will fall
    /// through to the default `case .custom:` (returns 1e10) and render fog
    /// / sky only.
    case deferred
    /// Validation, registration, or compilation failed. The caller should
    /// surface the error and not apply the preset.
    case failed
}

@MainActor
extension AppModel {
    /// Custom-scenes feature flag. Default off; user opts in via
    /// Settings → Display → "Allow custom scenes".
    static let allowCustomScenesUserDefaultsKey = "allowCustomScenes"
    static var allowCustomScenes: Bool {
        UserDefaults.standard.bool(forKey: allowCustomScenesUserDefaultsKey)
    }

    /// Install a custom formula and wait for renderer activation to complete.
    /// Returns `.ready` when the formula is compiled in the renderer,
    /// `.deferred` when the renderer isn't up yet (caller must wait and retry),
    /// or `.failed` on validation / compile errors.
    @discardableResult
    func installEmbeddedFormulaIfNeededAndWait(_ formula: EmbeddedFormula?) async -> EmbeddedFormulaInstallResult {
        customSceneDiagnostic("🔬 [CSDiag] installEmbeddedFormulaIfNeededAndWait ENTRY formula=\(formula?.name ?? "nil") hash=\(formula?.shortHash ?? "nil") activeHash=\(activeEmbeddedFormulaHash ?? "nil") handlerReady=\(activateEmbeddedFormulaHandler != nil)")
        guard let formula else { return .ready }

        guard AppModel.allowCustomScenes || formula.isBundledConstructionPrimitive else {
            customSceneDiagnostic("🔬 [CSDiag] installEmbeddedFormula REFUSED — custom scenes feature disabled")
            errorReporter.report(.preset(.importFailed(
                "Custom scenes are disabled. Enable “Allow custom scenes” in Settings → Display to load this scene."
            )))
            return .failed
        }

        do {
            try formula.validate()
        } catch {
            customSceneDiagnostic("🔬 [CSDiag] ❌ installEmbeddedFormula validation failed: \(error)")
            errorReporter.report(.preset(.importFailed(
                "Failed to validate custom shader: \(error.localizedDescription)"
            )))
            return .failed
        }

        // Trusted construction primitives are already present in default.metallib.
        // Retain their embedded payload for portable scene attribution, but never
        // synthesize/compile the full renderer source on iPad (a large transient
        // allocation that can cause jetsam termination rather than a Swift error).
        if formula.isBundledConstructionPrimitive {
            FormulaCatalog.shared.unregisterEphemeral()
            FractalTypeRegistry.unregisterCustom()
            activeEmbeddedFormula = formula
            activeEmbeddedFormulaHash = formula.shortHash
            if let handler = activateEmbeddedFormulaHandler {
                do {
                    try await handler(nil)
                } catch {
                    errorReporter.report(.preset(.importFailed(
                        "Failed to restore bundled shaders: \(error.localizedDescription)"
                    )))
                    return .failed
                }
            }
            return .ready
        }

        let hash = formula.shortHash
        if activeEmbeddedFormulaHash != hash {
            FormulaCatalog.shared.registerEphemeral(formula)
            FractalTypeRegistry.registerCustom(formula)
            activeEmbeddedFormula = formula
            activeEmbeddedFormulaHash = hash
            customSceneDiagnostic("🔬 [CSDiag] installEmbeddedFormula registered in FormulaCatalog + FractalTypeRegistry")
        } else {
            customSceneDiagnostic("🔬 [CSDiag] installEmbeddedFormula already registered (hash unchanged)")
        }

        let handler = activateEmbeddedFormulaHandler
        if handler == nil {
            // Renderer isn't up yet (typical: a .threshfx was opened from
            // Finder before the user entered the immersive space). The
            // renderer's startup task will read `activeEmbeddedFormula` and
            // activate it once the handler binds. Callers MUST wait for
            // `rendererStartupWarmupComplete` before applying the preset.
            customSceneDiagnostic("🔬 [CSDiag] ⚠️ installEmbeddedFormula DEFERRED (handler nil) — pipeline cache will NOT have FractalTypeCustom arm until renderer starts")
            return .deferred
        }
        do {
            try await handler?(formula)
            customSceneDiagnostic("🔬 [CSDiag] installEmbeddedFormula handler completed")
            return .ready
        } catch {
            customSceneDiagnostic("🔬 [CSDiag] ❌ installEmbeddedFormula handler THREW: \(error)")
            errorReporter.report(.preset(.importFailed(
                "Failed to compile custom shader: \(error.localizedDescription)"
            )))
            uninstallEmbeddedFormula()
            return .failed
        }
    }

    /// Compile-and-activate for the LIVE FORMULA EDITOR. Differs from
    /// `installEmbeddedFormulaIfNeededAndWait` in exactly the ways live
    /// editing needs:
    ///  - no error banner — compile errors return to the editor, which maps
    ///    them to source lines and shows them inline;
    ///  - on failure the previous library keeps rendering (no
    ///    `uninstallEmbeddedFormula`) — keep-last-good;
    ///  - `activeEmbeddedFormula` advances only AFTER the handler succeeds,
    ///    so the renderer's self-heal can never hot-loop a broken draft;
    ///  - no catalog registration — the editor already registered the draft
    ///    on the instant (pragma-parse) path.
    func installEmbeddedFormulaForLiveEdit(_ draft: EmbeddedFormula) async -> LiveEditCompileOutcome {
        guard AppModel.allowCustomScenes else { return .disabled }
        do {
            try draft.validate()
        } catch {
            return .invalid(error)
        }
        guard let handler = activateEmbeddedFormulaHandler else { return .rendererUnavailable }
        do {
            try await handler(draft)
            activeEmbeddedFormula = draft
            activeEmbeddedFormulaHash = draft.shortHash
            return .ready
        } catch {
            return .compileFailed(error)
        }
    }

    /// Install a custom formula at runtime: register with FormulaCatalog +
    /// FractalTypeRegistry, then ask the renderer to compile and swap in the
    /// MTLLibrary. No-op when `formula` is nil or already active.
    func installEmbeddedFormulaIfNeeded(_ formula: EmbeddedFormula?) {
        Task { @MainActor in
            _ = await self.installEmbeddedFormulaIfNeededAndWait(formula)
        }
    }

    @discardableResult
    func activateEmbeddedFormulaForSceneLoad(_ formula: EmbeddedFormula?) async -> EmbeddedFormulaInstallResult {
        if let formula {
            return await installEmbeddedFormulaIfNeededAndWait(formula)
        }

        uninstallEmbeddedFormula()
        return .ready
    }

    /// Detach the active custom formula and restore default rendering paths.
    func uninstallEmbeddedFormula() {
        guard activeEmbeddedFormulaHash != nil else { return }
        // A space warp leaves fractalType untouched and drives spaceWarpStrength;
        // reset it on detach so the built-in Twist default doesn't linger at the
        // strength the warp set. (Harmless no-op for custom fractals.)
        let wasWarp = (activeEmbeddedFormula?.effectKind == .spaceWarp)
        FormulaCatalog.shared.unregisterEphemeral()
        FractalTypeRegistry.unregisterCustom()
        activeEmbeddedFormula = nil
        activeEmbeddedFormulaHash = nil
        if wasWarp { renderSettings.spaceWarpStrength = 0 }
        let handler = activateEmbeddedFormulaHandler
        Task { @MainActor in
            try? await handler?(nil)
        }
    }

    /// Build a default `FractalPreset` for a freshly imported `.threshfx` so the
    /// existing import-preview flow can render it without mutating live formula
    /// registration before the user previews or imports it.
    static func makeCustomPreset(from formula: EmbeddedFormula) -> FractalPreset {
        var preset = FractalPreset(name: formula.name)
        preset.fractalType = .custom
        preset.embeddedFormula = formula
        preset.fractalIterations = formula.defaultIterations ?? 9
        preset.colorIterations = Float(formula.defaultColorIterations ?? 8)

        var fp = FormulaParams()
        fp.rotMatrix1 = matrix_identity_float3x3
        fp.rotMatrix2 = matrix_identity_float3x3
        fp.params = (0,0,0,0, 0,0,0,0, 0,0,0,0, 0,0,0,0)
        for descriptor in formula.params {
            FormulaCatalog.setParam(&fp, index: descriptor.index, value: descriptor.default)
        }
        var values = [Float](repeating: 0, count: 16)
        for i in 0..<16 {
            values[i] = FormulaCatalog.getParam(fp, index: i)
        }
        preset.formulaParamValues = values
        return preset
    }
}
