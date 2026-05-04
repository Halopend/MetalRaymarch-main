//
//  AppModel+EmbeddedFormula.swift
//  Threshold
//
//  Helpers for installing/uninstalling `.threshfx` embedded formulas and
//  bridging them into the FractalPreset import flow.
//

import Foundation
import simd

@MainActor
extension AppModel {
    /// Install a custom formula and wait for renderer activation to complete.
    /// Returns `true` on success and `false` when validation/compilation fails.
    @discardableResult
    func installEmbeddedFormulaIfNeededAndWait(_ formula: EmbeddedFormula?) async -> Bool {
        guard let formula else { return true }

        print("🧪 [CustomScene] Activating formula '\(formula.name)' (hash=\(formula.shortHash))")

        do {
            try formula.validate()
        } catch {
            errorReporter.report(.preset(.importFailed(
                "Failed to validate custom shader: \(error.localizedDescription)"
            )))
            return false
        }

        let hash = formula.shortHash
        if activeEmbeddedFormulaHash != hash {
            FormulaCatalog.shared.registerEphemeral(formula)
            FractalTypeRegistry.registerCustom(formula)
            activeEmbeddedFormula = formula
            activeEmbeddedFormulaHash = hash
        }

        let handler = activateEmbeddedFormulaHandler
        if handler == nil {
            print("⚠️ [CustomScene] Renderer activation handler is not ready yet")
        }
        do {
            try await handler?(formula)
            print("✅ [CustomScene] Formula active: '\(formula.name)'")
            return true
        } catch {
            print("❌ [CustomScene] Formula compile failed: \(error)")
            errorReporter.report(.preset(.importFailed(
                "Failed to compile custom shader: \(error.localizedDescription)"
            )))
            uninstallEmbeddedFormula()
            return false
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
