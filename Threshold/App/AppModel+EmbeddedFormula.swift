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
/// having it registered in the catalogs for later activation) check
/// `.isReady` before applying presets that depend on it.
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
    var isReady: Bool { self == .ready }
}

@MainActor
extension AppModel {
    /// Experimental custom-scenes feature flag. Default off; user opts in via
    /// Settings → General → "Allow custom scenes (experimental)".
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

        guard AppModel.allowCustomScenes else {
            customSceneDiagnostic("🔬 [CSDiag] installEmbeddedFormula REFUSED — custom scenes feature disabled")
            errorReporter.report(.preset(.importFailed(
                "Custom scenes are experimental. Enable “Allow custom scenes” in Settings → General to load this scene."
            )))
            return .failed
        }

        print("🧪 [CustomScene] Activating formula '\(formula.name)' (hash=\(formula.shortHash))")

        do {
            try formula.validate()
        } catch {
            customSceneDiagnostic("🔬 [CSDiag] ❌ installEmbeddedFormula validation failed: \(error)")
            errorReporter.report(.preset(.importFailed(
                "Failed to validate custom shader: \(error.localizedDescription)"
            )))
            return .failed
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
            print("⚠️ [CustomScene] Renderer activation handler is not ready yet — will activate once the scene loads")
            customSceneDiagnostic("🔬 [CSDiag] ⚠️ installEmbeddedFormula DEFERRED (handler nil) — pipeline cache will NOT have FractalTypeCustom arm until renderer starts")
            return .deferred
        }
        do {
            try await handler?(formula)
            print("✅ [CustomScene] Formula active: '\(formula.name)'")
            customSceneDiagnostic("🔬 [CSDiag] installEmbeddedFormula handler completed")
            return .ready
        } catch {
            print("❌ [CustomScene] Formula compile failed: \(error)")
            customSceneDiagnostic("🔬 [CSDiag] ❌ installEmbeddedFormula handler THREW: \(error)")
            errorReporter.report(.preset(.importFailed(
                "Failed to compile custom shader: \(error.localizedDescription)"
            )))
            uninstallEmbeddedFormula()
            return .failed
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
        FormulaCatalog.shared.unregisterEphemeral()
        FractalTypeRegistry.unregisterCustom()
        activeEmbeddedFormula = nil
        activeEmbeddedFormulaHash = nil
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
