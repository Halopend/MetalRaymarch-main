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

private let bundledLightingDemoResourceNameValue = "IridescentRimLighting"
private let bundledLightingDemoIDValue = "com.puppypower.threshold.example.iridescentRimLighting"

/// Cache the app-owned smoke-test payload once. Startup restore and the button
/// both use this exact copy, so a last-state file containing an older revision
/// of the demo cannot strand the user on stale metadata with "Demo Active".
@MainActor
private enum BundledLightingDemoResource {
    static let result: Result<EmbeddedFormula, Error> = {
        guard let url = Bundle.main.url(
            forResource: bundledLightingDemoResourceNameValue,
            withExtension: "threshfx"
        ) else {
            return .failure(NSError(
                domain: "Threshold.BundledLightingDemo",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "The bundled custom-lighting demo is missing from this build."]
            ))
        }
        do {
            let container = try EmbeddedFormulaContainer.decode(fromContainerAt: url)
            guard container.formula.id == bundledLightingDemoIDValue else {
                return .failure(NSError(
                    domain: "Threshold.BundledLightingDemo",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey:
                        "The bundled custom-lighting demo has an unexpected identity."]
                ))
            }
            return .success(container.formula)
        } catch {
            return .failure(error)
        }
    }()
}

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

/// User-visible truth about the lighting sidecar's relationship to the live
/// renderer. `activeEmbeddedLighting` is intentionally staged before an async
/// Metal compile begins, so views must not infer "rendering" from that payload
/// alone.
enum CustomLightingRuntimeState: Equatable {
    case inactive
    case waitingForRenderer(name: String)
    case compiling(name: String)
    case active(name: String)

    var name: String? {
        switch self {
        case .inactive: nil
        case .waitingForRenderer(let name), .compiling(let name), .active(let name): name
        }
    }

    var isBusy: Bool {
        switch self {
        case .waitingForRenderer, .compiling: true
        case .inactive, .active: false
        }
    }

    var isActive: Bool {
        if case .active = self { return true }
        return false
    }
}

/// Last effect set known to have preceded a renderer-unavailable scene load.
/// Deferred loads stage their payloads so renderer startup can discover them;
/// this snapshot lets a later compile failure return to the genuinely previous
/// state instead of leaving half of the staged set installed.
struct EmbeddedEffectSetRollbackSnapshot {
    let primary: EmbeddedFormula?
    let primaryHash: String?
    let lighting: EmbeddedFormula?
    let lightingHash: String?
    let lightingRuntimeState: CustomLightingRuntimeState
    let lightingParameterValues: [Float]
    let spaceWarpStrength: Float
}

@MainActor
extension AppModel {
    /// Experimental custom-scenes feature flag. Default off; user opts in via
    /// Settings → Display → Experimental Display → "Allow custom scenes".
    static let allowCustomScenesUserDefaultsKey = "allowCustomScenes"
    static let bundledLightingDemoResourceName = bundledLightingDemoResourceNameValue
    static let bundledLightingDemoID = bundledLightingDemoIDValue
    static var allowCustomScenes: Bool {
        UserDefaults.standard.bool(forKey: allowCustomScenesUserDefaultsKey)
    }

    static var bundledLightingDemoSourceHash: String? {
        guard case .success(let formula) = BundledLightingDemoResource.result else {
            return nil
        }
        return formula.sourceHash
    }

    /// A bundled smoke test is app-owned rather than user-authored. Upgrade its
    /// persisted copy on relaunch so newly added controls/source are immediately
    /// testable; ordinary external effects always keep their embedded payload.
    static func currentBundledLightingDemo(
        replacingPersisted lighting: EmbeddedFormula
    ) -> EmbeddedFormula {
        guard lighting.id == bundledLightingDemoID,
              case .success(let current) = BundledLightingDemoResource.result else {
            return lighting
        }
        return current
    }

    /// Publish one coherent parameter state to SwiftUI and the renderer. The
    /// renderer reads only RenderSettings' lock-protected packed copy.
    private func publishCustomLightingParameterValues(_ values: [Float]) {
        stageCustomLightingParameterValues(values)
        renderSettings.setCustomLightingParameterValues(customLightingParameterValues)
    }

    /// Update the observable/control state without changing the bank consumed
    /// by the currently published Metal library. Replacement effects use this
    /// while compiling so lighting A can never interpret lighting B's slots.
    private func stageCustomLightingParameterValues(_ values: [Float]) {
        let padded = Array((values + Array(repeating: 0, count: 16)).prefix(16))
        customLightingParameterValues = padded
    }

    func customLightingParameterValue(at index: Int) -> Float {
        guard customLightingParameterValues.indices.contains(index) else { return 0 }
        return customLightingParameterValues[index]
    }

    /// Live uniform-only update. This never invokes the shader activation
    /// handler, changes a source hash, or touches geometry FormulaParams.
    func setCustomLightingParameter(index: Int, value: Float) {
        guard let lighting = activeEmbeddedLighting,
              lighting.effectKind == .lighting,
              lighting.params.contains(where: { $0.index == index }) else { return }
        var next = customLightingParameterValues
        if next.count < 16 { next += Array(repeating: 0, count: 16 - next.count) }
        next[index] = value
        publishCustomLightingParameterValues(
            lighting.resolvedParameterValues(overrides: next)
        )
    }

    func resetCustomLightingParameters() {
        guard let lighting = activeEmbeddedLighting else { return }
        publishCustomLightingParameterValues(lighting.resolvedParameterValues())
    }

    var customLightingParametersAreAtDefaults: Bool {
        guard let lighting = activeEmbeddedLighting else { return true }
        let defaults = lighting.resolvedParameterValues()
        return zip(customLightingParameterValues, defaults).allSatisfy {
            abs($0 - $1) <= 0.000_001
        }
    }

    /// Stage descriptor defaults or persisted scene overrides before a library
    /// is published. Values are source-independent, so this is safe before or
    /// after Metal compilation and remains live across fractal switches.
    func configureCustomLightingParameters(
        for lighting: EmbeddedFormula?,
        overrides: [Float]? = nil,
        commitToRenderer: Bool = true
    ) {
        let values = lighting?.resolvedParameterValues(overrides: overrides)
            ?? Array(repeating: 0, count: 16)
        if commitToRenderer {
            publishCustomLightingParameterValues(values)
        } else {
            stageCustomLightingParameterValues(values)
        }
    }

    /// Installs the copy shipped inside the currently running app. This gives
    /// users a deterministic smoke test that cannot accidentally open an older
    /// installed Threshold build through Finder's document association.
    @discardableResult
    func installBundledLightingDemo() async -> EmbeddedFormulaInstallResult {
        switch BundledLightingDemoResource.result {
        case .success(let lighting):
            return await installEmbeddedLighting(lighting)
        case .failure(let error):
            errorReporter.report(.preset(.importFailed(
                "Could not read the bundled custom-lighting demo: \(error.localizedDescription)"
            )))
            return .failed
        }
    }

    /// Install a custom formula and wait for renderer activation to complete.
    /// Returns `.ready` when the formula is compiled in the renderer,
    /// `.deferred` when the renderer isn't up yet (caller must wait and retry),
    /// or `.failed` on validation / compile errors.
    @discardableResult
    func installEmbeddedFormulaIfNeededAndWait(_ formula: EmbeddedFormula?) async -> EmbeddedFormulaInstallResult {
        customSceneDiagnostic("🔬 [CSDiag] installEmbeddedFormulaIfNeededAndWait ENTRY formula=\(formula?.name ?? "nil") hash=\(formula?.shortHash ?? "nil") activeHash=\(activeEmbeddedFormulaHash ?? "nil") handlerReady=\(activateEmbeddedFormulaHandler != nil)")
        guard let formula else { return .ready }
        if formula.effectKind == .lighting {
            return await installEmbeddedLighting(formula)
        }

        guard AppModel.allowCustomScenes || formula.isBundledConstructionPrimitive else {
            customSceneDiagnostic("🔬 [CSDiag] installEmbeddedFormula REFUSED — custom scenes feature disabled")
            errorReporter.report(.preset(.importFailed(
                "Custom scenes are experimental. Enable “Allow custom scenes” in Settings → Display → Experimental Display to load this scene."
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
                    try await handler(nil, activeEmbeddedLighting)
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
            try await handler?(formula, activeEmbeddedLighting)
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

    /// Compile and attach a custom lighting material modifier without replacing
    /// the current fractal or space warp. The renderer compiles the complete
    /// primary+lighting effect set atomically; on failure, the previous lighting
    /// payload and already-rendering library remain active.
    @discardableResult
    func installEmbeddedLighting(
        _ lighting: EmbeddedFormula,
        parameterValues: [Float]? = nil
    ) async -> EmbeddedFormulaInstallResult {
        guard lighting.effectKind == .lighting else {
            errorReporter.report(.preset(.importFailed(
                "Expected a lighting .threshfx payload, got '\(lighting.effectKind.rawValue)'."
            )))
            return .failed
        }
        guard AppModel.allowCustomScenes else {
            errorReporter.report(.preset(.importFailed(
                "Custom lighting is experimental. Enable “Allow custom scenes” in Settings → Display → Experimental Display to load this effect."
            )))
            return .failed
        }
        do {
            try lighting.validate()
        } catch {
            errorReporter.report(.preset(.importFailed(
                "Failed to validate custom lighting: \(error.localizedDescription)"
            )))
            return .failed
        }

        // Opening an already-rendered, byte-identical payload is a successful
        // no-op. This keeps the smoke-test button honest instead of presenting
        // a fake "Reload" compile that the renderer cache immediately skips.
        if activeEmbeddedLightingHash == lighting.shortHash,
           customLightingRuntimeState.isActive {
            // Source-equivalent reimports may still change names/ranges/defaults.
            // Refresh the active definition and values without recompiling.
            activeEmbeddedLighting = lighting
            configureCustomLightingParameters(
                for: lighting,
                overrides: parameterValues ?? customLightingParameterValues
            )
            return .ready
        }

        let previous = activeEmbeddedLighting
        let previousHash = activeEmbeddedLightingHash
        let previousRuntimeState = customLightingRuntimeState
        let previousParameterValues = customLightingParameterValues
        activeEmbeddedLighting = lighting
        activeEmbeddedLightingHash = lighting.shortHash
        let hasRenderer = activateEmbeddedFormulaHandler != nil
        configureCustomLightingParameters(
            for: lighting,
            overrides: parameterValues,
            commitToRenderer: !hasRenderer
        )

        guard let handler = activateEmbeddedFormulaHandler else {
            // The renderer's handler bind reads both active slots and compiles
            // them together, matching the existing deferred custom-scene path.
            customLightingRuntimeState = .waitingForRenderer(name: lighting.name)
            return .deferred
        }

        customLightingRuntimeState = .compiling(name: lighting.name)
        let primary = activeEmbeddedFormula?.isBundledConstructionPrimitive == true
            ? nil : activeEmbeddedFormula
        do {
            try await handler(primary, lighting)
            guard activeEmbeddedLightingHash == lighting.shortHash else { return .ready }
            publishCustomLightingParameterValues(customLightingParameterValues)
            customLightingRuntimeState = .active(name: lighting.name)
            return .ready
        } catch {
            // A newer lighting request owns AppModel now; this obsolete failure
            // must not roll it back or present an error for the wrong source.
            guard activeEmbeddedLightingHash == lighting.shortHash else {
                return .ready
            }
            // Keep-last-good: restore state before asking the renderer to view it.
            // A failed compile never publishes a new MTLLibrary, so this retry is
            // normally a no-op or an in-memory cache hit.
            activeEmbeddedLighting = previous
            activeEmbeddedLightingHash = previousHash
            customLightingRuntimeState = previousRuntimeState
            publishCustomLightingParameterValues(previousParameterValues)
            try? await handler(primary, previous)
            errorReporter.report(.preset(.importFailed(
                "Failed to compile custom lighting: \(error.localizedDescription)"
            )))
            return .failed
        }
    }

    /// Stage and compile a scene's primary and lighting payloads as one immutable
    /// transaction. This avoids compiling lighting against the outgoing DE and
    /// then compiling the incoming DE separately, and it gives scene loading a
    /// single rollback boundary when Metal rejects either source.
    @discardableResult
    func activateEmbeddedEffectSetForSceneLoad(
        primary requestedPrimary: EmbeddedFormula?,
        lighting requestedLighting: EmbeddedFormula?,
        lightingParameterValues: [Float]? = nil
    ) async -> EmbeddedFormulaInstallResult {
        var primary = requestedPrimary
        var lighting = requestedLighting
        if primary?.effectKind == .lighting {
            if lighting == nil { lighting = primary }
            primary = nil
        }

        let needsCustomCompilation = (primary?.isBundledConstructionPrimitive == false)
            || lighting != nil
        if needsCustomCompilation, !AppModel.allowCustomScenes {
            errorReporter.report(.preset(.importFailed(
                "Custom GPU effects are experimental. Enable “Allow custom scenes” in Settings → Display → Experimental Display to load this scene."
            )))
            return .failed
        }

        do {
            if let primary {
                guard primary.effectKind == .fractal || primary.effectKind == .spaceWarp else {
                    throw EmbeddedFormula.ValidationError.missingFunctionDefinition(
                        "a fractal or space-warp primary entry point"
                    )
                }
                try primary.validate()
            }
            if let lighting {
                guard lighting.effectKind == .lighting else {
                    throw EmbeddedFormula.ValidationError.missingFunctionDefinition("Lighting_<stem>")
                }
                try lighting.validate()
            }
        } catch {
            errorReporter.report(.preset(.importFailed(
                "Failed to validate embedded effect set: \(error.localizedDescription)"
            )))
            return .failed
        }

        let previousPrimary = activeEmbeddedFormula
        let previousPrimaryHash = activeEmbeddedFormulaHash
        let previousLighting = activeEmbeddedLighting
        let previousLightingHash = activeEmbeddedLightingHash
        let previousLightingRuntimeState = customLightingRuntimeState
        let previousLightingParameterValues = customLightingParameterValues
        let previousWarpStrength = renderSettings.spaceWarpStrength

        func registerPrimary(_ formula: EmbeddedFormula?) {
            FormulaCatalog.shared.unregisterEphemeral()
            FractalTypeRegistry.unregisterCustom()
            if let formula,
               formula.effectKind == .fractal,
               !formula.isBundledConstructionPrimitive {
                FormulaCatalog.shared.registerEphemeral(formula)
                FractalTypeRegistry.registerCustom(formula)
            }
        }

        registerPrimary(primary)
        activeEmbeddedFormula = primary
        activeEmbeddedFormulaHash = primary?.shortHash
        activeEmbeddedLighting = lighting
        activeEmbeddedLightingHash = lighting?.shortHash
        let hasRenderer = activateEmbeddedFormulaHandler != nil
        configureCustomLightingParameters(
            for: lighting,
            overrides: lightingParameterValues,
            commitToRenderer: !hasRenderer
        )
        if let lighting {
            customLightingRuntimeState = activateEmbeddedFormulaHandler == nil
                ? .waitingForRenderer(name: lighting.name)
                : .compiling(name: lighting.name)
        } else {
            customLightingRuntimeState = .inactive
        }
        if primary?.effectKind == .spaceWarp {
            if renderSettings.spaceWarpStrength <= 0 {
                renderSettings.spaceWarpStrength = 0.6
            }
        } else if previousPrimary?.effectKind == .spaceWarp {
            renderSettings.spaceWarpStrength = 0
        }

        let rendererPrimary = primary?.isBundledConstructionPrimitive == true ? nil : primary
        guard let handler = activateEmbeddedFormulaHandler else {
            if needsCustomCompilation {
                // A chain of renderer-unavailable scene selections must keep
                // the original, last-rendered rollback point rather than each
                // newly staged (but never compiled) intermediate selection.
                if pendingEmbeddedEffectSetRollback == nil {
                    pendingEmbeddedEffectSetRollback = EmbeddedEffectSetRollbackSnapshot(
                        primary: previousPrimary,
                        primaryHash: previousPrimaryHash,
                        lighting: previousLighting,
                        lightingHash: previousLightingHash,
                        lightingRuntimeState: previousLightingRuntimeState,
                        lightingParameterValues: previousLightingParameterValues,
                        spaceWarpStrength: previousWarpStrength
                    )
                }
                return .deferred
            }
            pendingEmbeddedEffectSetRollback = nil
            return .ready
        }

        do {
            try await handler(rendererPrimary, lighting)
            guard activeEmbeddedFormulaHash == primary?.shortHash,
                  activeEmbeddedLightingHash == lighting?.shortHash else {
                return .ready
            }
            customLightingRuntimeState = lighting.map {
                .active(name: $0.name)
            } ?? .inactive
            publishCustomLightingParameterValues(customLightingParameterValues)
            pendingEmbeddedEffectSetRollback = nil
            return .ready
        } catch {
            // If another request replaced either slot while this compile was in
            // flight, it owns AppModel now and the renderer suppresses stale
            // publication; never roll the newer request back.
            guard activeEmbeddedFormulaHash == primary?.shortHash,
                  activeEmbeddedLightingHash == lighting?.shortHash else {
                return .ready
            }

            activeEmbeddedFormula = previousPrimary
            activeEmbeddedFormulaHash = previousPrimaryHash
            activeEmbeddedLighting = previousLighting
            activeEmbeddedLightingHash = previousLightingHash
            customLightingRuntimeState = previousLightingRuntimeState
            publishCustomLightingParameterValues(previousLightingParameterValues)
            renderSettings.spaceWarpStrength = previousWarpStrength
            registerPrimary(previousPrimary)
            let previousRendererPrimary = previousPrimary?.isBundledConstructionPrimitive == true
                ? nil : previousPrimary
            try? await handler(previousRendererPrimary, previousLighting)
            errorReporter.report(.preset(.importFailed(
                "Failed to compile embedded effect set: \(error.localizedDescription)"
            )))
            return .failed
        }
    }

    /// Restore the effect set captured before a deferred activation was staged.
    /// Returns false when there is no applicable snapshot (the caller may use
    /// its ordinary detach recovery instead). The expected hashes prevent an
    /// obsolete compile failure from rolling back a newer request.
    @discardableResult
    func restoreDeferredEffectSetAfterFailure(
        expectedPrimary: EmbeddedFormula?,
        expectedLighting: EmbeddedFormula?,
        using handler: (EmbeddedFormula?, EmbeddedFormula?) async throws -> Void
    ) async -> Bool {
        guard activeEmbeddedFormulaHash == expectedPrimary?.shortHash,
              activeEmbeddedLightingHash == expectedLighting?.shortHash,
              let rollback = pendingEmbeddedEffectSetRollback else {
            return false
        }

        pendingEmbeddedEffectSetRollback = nil
        FormulaCatalog.shared.unregisterEphemeral()
        FractalTypeRegistry.unregisterCustom()
        if let primary = rollback.primary,
           primary.effectKind == .fractal,
           !primary.isBundledConstructionPrimitive {
            FormulaCatalog.shared.registerEphemeral(primary)
            FractalTypeRegistry.registerCustom(primary)
        }
        activeEmbeddedFormula = rollback.primary
        activeEmbeddedFormulaHash = rollback.primaryHash
        activeEmbeddedLighting = rollback.lighting
        activeEmbeddedLightingHash = rollback.lightingHash
        customLightingRuntimeState = rollback.lightingRuntimeState
        publishCustomLightingParameterValues(rollback.lightingParameterValues)
        renderSettings.spaceWarpStrength = rollback.spaceWarpStrength

        let rendererPrimary = rollback.primary?.isBundledConstructionPrimitive == true
            ? nil : rollback.primary
        do {
            try await handler(rendererPrimary, rollback.lighting)
            customLightingRuntimeState = rollback.lighting.map {
                .active(name: $0.name)
            } ?? .inactive
        } catch {
            errorReporter.report(.preset(.importFailed(
                "Failed to restore the previous GPU effect set: \(error.localizedDescription)"
            )))
        }
        return true
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
            try await handler(draft, activeEmbeddedLighting)
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
        let lighting = activeEmbeddedLighting
        Task { @MainActor in
            try? await handler?(nil, lighting)
        }
    }

    /// Detach only the custom lighting sidecar. Geometry, formula parameters,
    /// space transforms, and the current Threshold lighting settings are kept.
    func uninstallEmbeddedLighting() {
        guard activeEmbeddedLightingHash != nil || activeEmbeddedLighting != nil else { return }
        let previous = activeEmbeddedLighting
        let previousHash = activeEmbeddedLightingHash
        let previousState = customLightingRuntimeState
        let previousValues = customLightingParameterValues
        activeEmbeddedLighting = nil
        activeEmbeddedLightingHash = nil
        customLightingRuntimeState = .inactive
        // Remove the controls immediately, but keep the old GPU bank alive until
        // the renderer has actually stopped using the old lighting library.
        configureCustomLightingParameters(for: nil, commitToRenderer: false)
        let primary = activeEmbeddedFormula?.isBundledConstructionPrimitive == true
            ? nil : activeEmbeddedFormula
        guard let handler = activateEmbeddedFormulaHandler else {
            publishCustomLightingParameterValues(customLightingParameterValues)
            return
        }
        Task { @MainActor in
            do {
                try await handler(primary, nil)
                guard self.activeEmbeddedLighting == nil,
                      self.activeEmbeddedLightingHash == nil else { return }
                self.publishCustomLightingParameterValues(self.customLightingParameterValues)
            } catch {
                guard self.activeEmbeddedLighting == nil,
                      self.activeEmbeddedLightingHash == nil else { return }
                self.activeEmbeddedLighting = previous
                self.activeEmbeddedLightingHash = previousHash
                self.customLightingRuntimeState = previousState
                self.publishCustomLightingParameterValues(previousValues)
                self.errorReporter.report(.preset(.importFailed(
                    "Failed to detach custom lighting: \(error.localizedDescription)"
                )))
            }
        }
    }

    /// Awaitable variant used by scene loading so a detach cannot race the next
    /// combined effect-set activation and publish an older library afterward.
    @discardableResult
    func uninstallEmbeddedLightingAndWait() async -> Bool {
        guard activeEmbeddedLightingHash != nil || activeEmbeddedLighting != nil else { return true }
        let previous = activeEmbeddedLighting
        let previousHash = activeEmbeddedLightingHash
        let previousState = customLightingRuntimeState
        let previousValues = customLightingParameterValues
        activeEmbeddedLighting = nil
        activeEmbeddedLightingHash = nil
        customLightingRuntimeState = .inactive
        configureCustomLightingParameters(for: nil, commitToRenderer: false)
        let primary = activeEmbeddedFormula?.isBundledConstructionPrimitive == true
            ? nil : activeEmbeddedFormula
        guard let handler = activateEmbeddedFormulaHandler else {
            publishCustomLightingParameterValues(customLightingParameterValues)
            return true
        }
        do {
            try await handler(primary, nil)
            if activeEmbeddedLighting == nil, activeEmbeddedLightingHash == nil {
                publishCustomLightingParameterValues(customLightingParameterValues)
            }
            return true
        } catch {
            guard activeEmbeddedLighting == nil,
                  activeEmbeddedLightingHash == nil else { return false }
            activeEmbeddedLighting = previous
            activeEmbeddedLightingHash = previousHash
            customLightingRuntimeState = previousState
            publishCustomLightingParameterValues(previousValues)
            self.errorReporter.report(.preset(.importFailed(
                "Failed to detach custom lighting: \(error.localizedDescription)"
            )))
            return false
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
