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
private let bundledVoronoiSpaceWarpResourceNameValue = "Voronoi3DFieldSpaceWarp"
private let bundledVoronoiSpaceWarpIDValue = "com.puppypower.threshold.example.voronoi3DFieldSpaceWarp"
// Append (never replace) hashes when the bundled source changes without changing
// its v1 control roles. Saved scenes embed the source that shipped with them, so
// retaining old entries preserves their Phase Offset presentation across updates.
private let bundledVoronoiSpaceWarpControlProfileSourceHashesValue: Set<String> = [
    "586ec7bc5db26d4029d8b0ff003e3ddbf1ca845262c87f95d51f51b9d5974218"
]

/// Cache the app-owned smoke-test payload once. Startup restore and the button
/// both use this exact copy, so a last-state file containing an older revision
/// of the demo cannot strand the user on stale metadata with "Demo Active".
@MainActor
private enum BundledLightingDemoResource {
    static let result: Result<EmbeddedFormula, Error> = {
        // Builds that preserve the synchronized resource hierarchy package the
        // demo under Examples/Formulas; flattened builds put it at the root.
        guard let url = Bundle.main.url(
            forResource: bundledLightingDemoResourceNameValue,
            withExtension: "threshfx",
            subdirectory: "Examples/Formulas"
        ) ?? Bundle.main.url(
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

/// The Transformations menu intentionally crosses the same container boundary as
/// a Finder/Files import. Keeping the sample as a real resource catches packaging,
/// JSON-schema, validation, and runtime-compiler regressions in the external-warp
/// contract instead of silently falling back to a Swift-authored approximation.
@MainActor
private enum BundledVoronoiSpaceWarpResource {
    static let result: Result<EmbeddedFormula, Error> = {
        guard let url = Bundle.main.url(
            forResource: bundledVoronoiSpaceWarpResourceNameValue,
            withExtension: "threshfx",
            subdirectory: "Examples/Formulas"
        ) ?? Bundle.main.url(
            forResource: bundledVoronoiSpaceWarpResourceNameValue,
            withExtension: "threshfx"
        ) else {
            return .failure(NSError(
                domain: "Threshold.BundledVoronoiSpaceWarp",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "The bundled 3D Voronoi space-warp .threshfx is missing from this build."]
            ))
        }
        do {
            let container = try EmbeddedFormulaContainer.decode(fromContainerAt: url)
            guard container.formula.id == bundledVoronoiSpaceWarpIDValue,
                  container.formula.effectKind == .spaceWarp,
                  bundledVoronoiSpaceWarpControlProfileSourceHashesValue
                    .contains(container.formula.sourceHash) else {
                return .failure(NSError(
                    domain: "Threshold.BundledVoronoiSpaceWarp",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey:
                        "The bundled 3D Voronoi modifier has an unexpected identity or effect kind."]
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
    /// Another primary/lighting request took ownership while this compile was in
    /// flight. The draft did not become the renderer's live formula.
    case superseded
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

/// User-visible truth for the single external space-warp slot. The payload is
/// staged before an asynchronous Metal compile, so views must not infer active
/// rendering from `activeEmbeddedFormula` alone.
enum CustomSpaceWarpRuntimeState: Equatable {
    case inactive
    case waitingForRenderer(name: String)
    case compiling(name: String)
    case active(name: String)
    case detaching(name: String)

    var name: String? {
        switch self {
        case .inactive: nil
        case .waitingForRenderer(let name), .compiling(let name),
             .active(let name), .detaching(let name): name
        }
    }

    var isBusy: Bool {
        switch self {
        case .compiling, .detaching: true
        case .inactive, .waitingForRenderer, .active: false
        }
    }

    var isActive: Bool {
        if case .active = self { return true }
        return false
    }

    var isPresent: Bool {
        if case .inactive = self { return false }
        return true
    }

    var canDetach: Bool {
        switch self {
        case .waitingForRenderer, .active: true
        case .inactive, .compiling, .detaching: false
        }
    }

    var overridesBuiltInStack: Bool {
        switch self {
        case .active, .detaching: true
        case .inactive, .waitingForRenderer, .compiling: false
        }
    }
}

/// Presentation is source-identity-gated because the legacy `param1/2/3` ABI is
/// intentionally effect-defined. Only recognized bundled Voronoi source revisions
/// may receive Voronoi-specific labels and ranges.
enum CustomSpaceWarpControlProfile: Equatable {
    case generic
    case bundledVoronoi
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
    let spaceWarpRuntimeState: CustomSpaceWarpRuntimeState
    let spaceWarpControlProfile: CustomSpaceWarpControlProfile
}

@MainActor
extension AppModel {
    /// Experimental custom-scenes feature flag. Default off; user opts in via
    /// Settings → Display → Experimental Display → "Allow custom scenes".
    static let allowCustomScenesUserDefaultsKey = "allowCustomScenes"
    static let bundledLightingDemoResourceName = bundledLightingDemoResourceNameValue
    static let bundledLightingDemoID = bundledLightingDemoIDValue
    static let bundledVoronoiSpaceWarpResourceName = bundledVoronoiSpaceWarpResourceNameValue
    static let bundledVoronoiSpaceWarpID = bundledVoronoiSpaceWarpIDValue
    static let bundledVoronoiSpaceWarpControlProfileSourceHashes =
        bundledVoronoiSpaceWarpControlProfileSourceHashesValue
    static var allowCustomScenes: Bool {
        UserDefaults.standard.bool(forKey: allowCustomScenesUserDefaultsKey)
    }

    /// Claim ownership of the next complete primary+lighting renderer state.
    /// AppModel uses this independently from the renderer's publication token so
    /// async callers can tell whether a `Void` activation callback actually still
    /// belongs to them when it returns.
    @discardableResult
    func beginEmbeddedEffectSetOperation() -> UInt64 {
        embeddedEffectSetOperationGeneration &+= 1
        return embeddedEffectSetOperationGeneration
    }

    func isCurrentEmbeddedEffectSetOperation(_ generation: UInt64) -> Bool {
        embeddedEffectSetOperationGeneration == generation
    }

    static var bundledLightingDemoSourceHash: String? {
        guard case .success(let formula) = BundledLightingDemoResource.result else {
            return nil
        }
        return formula.sourceHash
    }

    static var bundledVoronoiSpaceWarpSourceHash: String? {
        guard case .success(let formula) = BundledVoronoiSpaceWarpResource.result else {
            return nil
        }
        return formula.sourceHash
    }

    static var bundledVoronoiSpaceWarpShortHash: String? {
        guard case .success(let formula) = BundledVoronoiSpaceWarpResource.result else {
            return nil
        }
        return formula.shortHash
    }

    static func customSpaceWarpControlProfile(
        for formula: EmbeddedFormula?
    ) -> CustomSpaceWarpControlProfile {
        guard let formula,
              formula.id == bundledVoronoiSpaceWarpID,
              formula.effectKind == .spaceWarp,
              bundledVoronoiSpaceWarpControlProfileSourceHashes.contains(formula.sourceHash) else {
            return .generic
        }
        return .bundledVoronoi
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
            return await installEmbeddedLighting(lighting, persistOnPublication: true)
        case .failure(let error):
            errorReporter.report(.preset(.importFailed(
                "Could not read the bundled custom-lighting demo: \(error.localizedDescription)"
            )))
            return .failed
        }
    }

    /// Decode and install the app-shipped Voronoi modifier through the production
    /// `.threshfx` path. This is deliberately not a `SpaceWarpOpValue`: external
    /// v1 warps occupy the global custom-warp slot and temporarily override the
    /// ordered built-in stack, which remains preserved for detach.
    @discardableResult
    func installBundledVoronoiSpaceWarp() async -> EmbeddedFormulaInstallResult {
        switch BundledVoronoiSpaceWarpResource.result {
        case .success(let warp):
            return await installEmbeddedSpaceWarp(warp)
        case .failure(let error):
            errorReporter.report(.preset(.importFailed(
                "Could not read the bundled 3D Voronoi modifier: \(error.localizedDescription)"
            )))
            return .failed
        }
    }

    /// Make a user-requested standalone modifier durable at the renderer's
    /// publication boundary. Immediate installs can save now; renderer-late
    /// installs are committed by the next exact effect-set publication after
    /// Metal accepts the staged source.
    func persistCustomSpaceWarpInstall(
        _ result: EmbeddedFormulaInstallResult,
        expectedHash: String
    ) {
        switch result {
        case .ready:
            guard pendingFormulaSceneApplyDecision(
                expectedFormulaHash: expectedHash,
                effectKind: .spaceWarp
            ) == .apply else { return }
            pendingCustomSpaceWarpPersistenceHash = nil
            saveLastState()
        case .deferred:
            guard activeEmbeddedFormulaHash == expectedHash,
                  activeEmbeddedFormula?.effectKind == .spaceWarp else { return }
            // The renderer handler may bind, publish, and consume an empty token
            // before the awaiting installer resumes with `.deferred`. Confirm the
            // exact current publication here so that race saves immediately
            // instead of installing a token no future publication will drain.
            if pendingFormulaSceneApplyDecision(
                expectedFormulaHash: expectedHash,
                effectKind: .spaceWarp
            ) == .apply {
                pendingCustomSpaceWarpPersistenceHash = nil
                saveLastState()
                return
            }
            pendingCustomSpaceWarpPersistenceHash = expectedHash
        case .failed:
            // A failed result may belong to an older, superseded operation whose
            // source hash is identical to a newer deferred install. Validated
            // staging and the owning publication path clear their own tokens;
            // this caller cannot safely identify the token it would remove.
            break
        }
    }

    /// Persist the external modifier's uniform controls after dragging settles.
    /// Lifecycle checkpoints still call `saveLastState()` synchronously, so no
    /// final edit is lost if the app backgrounds before this delay expires.
    func scheduleCustomSpaceWarpSettingsPersistence() {
        customSpaceWarpSettingsPersistenceTask?.cancel()
        guard let expectedFormula = activeEmbeddedFormula,
              expectedFormula.effectKind == .spaceWarp,
              customSpaceWarpRuntimeState.isActive,
              pendingFormulaSceneApplyDecision(
                  expectedFormulaHash: expectedFormula.shortHash,
                  effectKind: .spaceWarp
              ) == .apply,
              let expectedPublication = publishedEmbeddedEffectSet else {
            customSpaceWarpSettingsPersistenceTask = nil
            return
        }
        let expectedID = expectedFormula.id
        let expectedSourceHash = expectedFormula.sourceHash
        customSpaceWarpSettingsPersistenceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let self else { return }
            self.customSpaceWarpSettingsPersistenceTask = nil
            guard let activeFormula = self.activeEmbeddedFormula,
                  activeFormula.id == expectedID,
                  activeFormula.sourceHash == expectedSourceHash,
                  activeFormula.effectKind == .spaceWarp,
                  self.customSpaceWarpRuntimeState.isActive,
                  self.embeddedEffectSetOperationGeneration
                    == expectedPublication.operationGeneration,
                  self.publishedEmbeddedEffectSet == expectedPublication,
                  self.activeEmbeddedFormulaHash == expectedPublication.primaryHash,
                  self.activeEmbeddedLightingHash == expectedPublication.lightingHash else { return }
            self.saveLastState()
        }
    }

    /// Compile and activate one external space-warp payload. The current v1
    /// effect model has one primary custom slot, so a custom DE and a custom warp
    /// cannot coexist; reject that combination instead of leaving `.custom`
    /// selected with no DE implementation.
    @discardableResult
    func installEmbeddedSpaceWarp(_ warp: EmbeddedFormula) async -> EmbeddedFormulaInstallResult {
        guard warp.effectKind == .spaceWarp else {
            errorReporter.report(.preset(.importFailed(
                "Expected a space-warp .threshfx payload, got '\(warp.effectKind.rawValue)'."
            )))
            return .failed
        }
        if renderSettings.fractalType == .custom
            || (activeEmbeddedFormula?.effectKind == .fractal
                && activeEmbeddedFormula?.isBundledConstructionPrimitive == false) {
            errorReporter.report(.preset(.importFailed(
                "External space warps currently share the custom-formula slot. Select a built-in fractal before loading this modifier."
            )))
            return .failed
        }

        if activeEmbeddedFormulaHash == warp.shortHash,
           pendingFormulaSceneApplyDecision(
               expectedFormulaHash: warp.shortHash,
               effectKind: .spaceWarp
           ) == .apply {
            activeEmbeddedFormula = warp
            customSpaceWarpControlProfile = Self.customSpaceWarpControlProfile(for: warp)
            customSpaceWarpRuntimeState = .active(name: warp.name)
            return .ready
        }

        return await activateEmbeddedEffectSetForSceneLoad(
            primary: warp,
            lighting: activeEmbeddedLighting,
            lightingParameterValues: customLightingParameterValues
        )
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
        if formula.effectKind == .spaceWarp {
            return await installEmbeddedSpaceWarp(formula)
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

        if activeEmbeddedFormula?.effectKind == .spaceWarp {
            // Replacing the external warp must be atomic: if the incoming DE
            // fails to compile, keep the last-good warp payload, controls, and
            // renderer library instead of exposing a half-replaced primary slot.
            return await activateEmbeddedEffectSetForSceneLoad(
                primary: formula,
                lighting: activeEmbeddedLighting,
                lightingParameterValues: customLightingParameterValues
            )
        }

        let operationGeneration = beginEmbeddedEffectSetOperation()

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
                    guard isCurrentEmbeddedEffectSetOperation(operationGeneration) else {
                        return .failed
                    }
                    reconcilePublishedEmbeddedEffectSetRuntime(
                        primary: formula,
                        lighting: activeEmbeddedLighting
                    )
                    recordPublishedEmbeddedEffectSet(
                        primaryHash: formula.shortHash,
                        lightingHash: activeEmbeddedLightingHash,
                        operationGeneration: operationGeneration
                    )
                    drainPendingSceneApplyIfPublished()
                } catch {
                    guard isCurrentEmbeddedEffectSetOperation(operationGeneration) else {
                        return .failed
                    }
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
            guard isCurrentEmbeddedEffectSetOperation(operationGeneration),
                  activeEmbeddedFormulaHash == hash else { return .failed }
            reconcilePublishedEmbeddedEffectSetRuntime(
                primary: formula,
                lighting: activeEmbeddedLighting
            )
            recordPublishedEmbeddedEffectSet(
                primaryHash: hash,
                lightingHash: activeEmbeddedLightingHash,
                operationGeneration: operationGeneration
            )
            drainPendingSceneApplyIfPublished()
            customSceneDiagnostic("🔬 [CSDiag] installEmbeddedFormula handler completed")
            return .ready
        } catch {
            guard isCurrentEmbeddedEffectSetOperation(operationGeneration),
                  activeEmbeddedFormulaHash == hash else { return .failed }
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
        parameterValues: [Float]? = nil,
        persistOnPublication: Bool = false
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
           pendingFormulaSceneApplyDecision(
               expectedFormulaHash: lighting.shortHash,
               effectKind: .lighting
           ) == .apply {
            // Source-equivalent reimports may still change names/ranges/defaults.
            // Refresh the active definition and values without recompiling.
            activeEmbeddedLighting = lighting
            configureCustomLightingParameters(
                for: lighting,
                overrides: parameterValues ?? customLightingParameterValues
            )
            if persistOnPublication {
                pendingCustomLightingPersistenceHash = lighting.shortHash
                consumePendingEffectPersistenceIfPublished()
            }
            return .ready
        }

        let previous = activeEmbeddedLighting
        let previousHash = activeEmbeddedLightingHash
        let previousRuntimeState = customLightingRuntimeState
        let previousParameterValues = customLightingParameterValues
        let previousPrimaryHash = activeEmbeddedFormulaHash
        let previousPublicationWasCurrent = hasCurrentPublishedEmbeddedEffectSet(
            primaryHash: previousPrimaryHash,
            lightingHash: previousHash
        )
        let operationGeneration = beginEmbeddedEffectSetOperation()
        activeEmbeddedLighting = lighting
        activeEmbeddedLightingHash = lighting.shortHash
        // Stage durability before any renderer await. A post-await caller can
        // otherwise resume after publication and install a token that no future
        // publication will consume. A new non-standalone lighting request owns
        // the slot and explicitly supersedes an older persistence intent.
        pendingCustomLightingPersistenceHash = persistOnPublication
            ? lighting.shortHash
            : nil
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
            guard isCurrentEmbeddedEffectSetOperation(operationGeneration),
                  activeEmbeddedLightingHash == lighting.shortHash else { return .failed }
            publishCustomLightingParameterValues(customLightingParameterValues)
            reconcilePublishedEmbeddedEffectSetRuntime(
                primary: activeEmbeddedFormula,
                lighting: lighting
            )
            recordPublishedEmbeddedEffectSet(
                primaryHash: activeEmbeddedFormulaHash,
                lightingHash: lighting.shortHash,
                operationGeneration: operationGeneration
            )
            drainPendingSceneApplyIfPublished()
            return .ready
        } catch {
            // A newer lighting request owns AppModel now; this obsolete failure
            // must not roll it back or present an error for the wrong source.
            guard isCurrentEmbeddedEffectSetOperation(operationGeneration),
                  activeEmbeddedLightingHash == lighting.shortHash else {
                return .failed
            }
            if pendingCustomLightingPersistenceHash == lighting.shortHash {
                pendingCustomLightingPersistenceHash = nil
            }
            // Keep-last-good: restore state before asking the renderer to view it.
            // A failed compile never publishes a new MTLLibrary, so this retry is
            // normally a no-op or an in-memory cache hit.
            activeEmbeddedLighting = previous
            activeEmbeddedLightingHash = previousHash
            customLightingRuntimeState = previousRuntimeState
            publishCustomLightingParameterValues(previousParameterValues)
            do {
                try await handler(primary, previous)
                guard isCurrentEmbeddedEffectSetOperation(operationGeneration),
                      activeEmbeddedLightingHash == previousHash else {
                    return .failed
                }
                reconcilePublishedEmbeddedEffectSetRuntime(
                    primary: activeEmbeddedFormula,
                    lighting: previous
                )
                recordPublishedEmbeddedEffectSet(
                    primaryHash: activeEmbeddedFormulaHash,
                    lightingHash: previousHash,
                    operationGeneration: operationGeneration
                )
                drainPendingSceneApplyIfPublished()
            } catch let rollbackError {
                guard isCurrentEmbeddedEffectSetOperation(operationGeneration) else {
                    return .failed
                }
                if previousPublicationWasCurrent,
                   activeEmbeddedFormulaHash == previousPrimaryHash,
                   activeEmbeddedLightingHash == previousHash {
                    reconcilePublishedEmbeddedEffectSetRuntime(
                        primary: activeEmbeddedFormula,
                        lighting: previous
                    )
                    recordPublishedEmbeddedEffectSet(
                        primaryHash: previousPrimaryHash,
                        lightingHash: previousHash,
                        operationGeneration: operationGeneration
                    )
                    drainPendingSceneApplyIfPublished()
                }
                errorReporter.report(.preset(.importFailed(
                    "Failed to restore the previous GPU effect set: \(rollbackError.localizedDescription)"
                )))
            }
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

        // A validated primary transaction supersedes a standalone warp intent.
        // A lighting intent may ride a new primary publication only while the
        // exact lighting source remains staged. Invalid requests never stage
        // state, so they must leave either intent intact.
        pendingCustomSpaceWarpPersistenceHash = nil
        if pendingCustomLightingPersistenceHash != lighting?.shortHash {
            pendingCustomLightingPersistenceHash = nil
        }

        let previousPublicationWasCurrent = hasCurrentPublishedEmbeddedEffectSet(
            primaryHash: activeEmbeddedFormulaHash,
            lightingHash: activeEmbeddedLightingHash
        )
        let operationGeneration = beginEmbeddedEffectSetOperation()

        // A settings checkpoint belongs to the currently published warp. Once a
        // validated effect-set transaction is about to stage new state, allowing
        // that older delayed write to fire could persist source before Metal
        // accepts it. Invalid requests leave the existing checkpoint untouched.
        customSpaceWarpSettingsPersistenceTask?.cancel()
        customSpaceWarpSettingsPersistenceTask = nil

        let previousPrimary = activeEmbeddedFormula
        let previousPrimaryHash = activeEmbeddedFormulaHash
        let previousLighting = activeEmbeddedLighting
        let previousLightingHash = activeEmbeddedLightingHash
        let previousLightingRuntimeState = customLightingRuntimeState
        let previousLightingParameterValues = customLightingParameterValues
        let previousWarpStrength = renderSettings.spaceWarpStrength
        let previousWarpRuntimeState = customSpaceWarpRuntimeState
        let previousWarpControlProfile = customSpaceWarpControlProfile

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
        customSpaceWarpControlProfile = primary?.effectKind == .spaceWarp
            ? Self.customSpaceWarpControlProfile(for: primary)
            : .generic
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
            customSpaceWarpRuntimeState = activateEmbeddedFormulaHandler == nil
                ? .waitingForRenderer(name: primary?.name ?? "External Space Warp")
                : .compiling(name: primary?.name ?? "External Space Warp")
        } else if previousPrimary?.effectKind == .spaceWarp {
            renderSettings.spaceWarpStrength = 0
            customSpaceWarpRuntimeState = .inactive
        } else {
            customSpaceWarpRuntimeState = .inactive
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
                        spaceWarpStrength: previousWarpStrength,
                        spaceWarpRuntimeState: previousWarpRuntimeState,
                        spaceWarpControlProfile: previousWarpControlProfile
                    )
                }
                return .deferred
            }
            pendingEmbeddedEffectSetRollback = nil
            return .ready
        }

        do {
            try await handler(rendererPrimary, lighting)
            guard isCurrentEmbeddedEffectSetOperation(operationGeneration),
                  activeEmbeddedFormulaHash == primary?.shortHash,
                  activeEmbeddedLightingHash == lighting?.shortHash else {
                return .failed
            }
            reconcilePublishedEmbeddedEffectSetRuntime(
                primary: primary,
                lighting: lighting
            )
            publishCustomLightingParameterValues(customLightingParameterValues)
            recordPublishedEmbeddedEffectSet(
                primaryHash: primary?.shortHash,
                lightingHash: lighting?.shortHash,
                operationGeneration: operationGeneration
            )
            drainPendingSceneApplyIfPublished()
            pendingEmbeddedEffectSetRollback = nil
            return .ready
        } catch {
            // If another request replaced either slot while this compile was in
            // flight, it owns AppModel now and the renderer suppresses stale
            // publication; never roll the newer request back.
            guard isCurrentEmbeddedEffectSetOperation(operationGeneration),
                  activeEmbeddedFormulaHash == primary?.shortHash,
                  activeEmbeddedLightingHash == lighting?.shortHash else {
                return .failed
            }

            activeEmbeddedFormula = previousPrimary
            activeEmbeddedFormulaHash = previousPrimaryHash
            activeEmbeddedLighting = previousLighting
            activeEmbeddedLightingHash = previousLightingHash
            customLightingRuntimeState = previousLightingRuntimeState
            customSpaceWarpRuntimeState = previousWarpRuntimeState
            customSpaceWarpControlProfile = previousWarpControlProfile
            publishCustomLightingParameterValues(previousLightingParameterValues)
            renderSettings.spaceWarpStrength = previousWarpStrength
            registerPrimary(previousPrimary)
            let previousRendererPrimary = previousPrimary?.isBundledConstructionPrimitive == true
                ? nil : previousPrimary
            do {
                try await handler(previousRendererPrimary, previousLighting)
                guard isCurrentEmbeddedEffectSetOperation(operationGeneration),
                      activeEmbeddedFormulaHash == previousPrimaryHash,
                      activeEmbeddedLightingHash == previousLightingHash else {
                    return .failed
                }
                reconcilePublishedEmbeddedEffectSetRuntime(
                    primary: previousPrimary,
                    lighting: previousLighting
                )
                recordPublishedEmbeddedEffectSet(
                    primaryHash: previousPrimaryHash,
                    lightingHash: previousLightingHash,
                    operationGeneration: operationGeneration
                )
                drainPendingSceneApplyIfPublished()
            } catch let rollbackError {
                guard isCurrentEmbeddedEffectSetOperation(operationGeneration) else {
                    return .failed
                }
                if previousPublicationWasCurrent,
                   activeEmbeddedFormulaHash == previousPrimaryHash,
                   activeEmbeddedLightingHash == previousLightingHash {
                    reconcilePublishedEmbeddedEffectSetRuntime(
                        primary: previousPrimary,
                        lighting: previousLighting
                    )
                    recordPublishedEmbeddedEffectSet(
                        primaryHash: previousPrimaryHash,
                        lightingHash: previousLightingHash,
                        operationGeneration: operationGeneration
                    )
                    drainPendingSceneApplyIfPublished()
                }
                errorReporter.report(.preset(.importFailed(
                    "Failed to restore the previous GPU effect set: \(rollbackError.localizedDescription)"
                )))
            }
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
        operationGeneration: UInt64,
        using handler: (EmbeddedFormula?, EmbeddedFormula?) async throws -> Void
    ) async -> Bool {
        guard isCurrentEmbeddedEffectSetOperation(operationGeneration),
              activeEmbeddedFormulaHash == expectedPrimary?.shortHash,
              activeEmbeddedLightingHash == expectedLighting?.shortHash,
              let rollback = pendingEmbeddedEffectSetRollback else {
            return false
        }

        pendingEmbeddedEffectSetRollback = nil
        if let expectedHash = expectedPrimary?.shortHash,
           pendingCustomSpaceWarpPersistenceHash == expectedHash {
            pendingCustomSpaceWarpPersistenceHash = nil
        }
        if let expectedHash = expectedLighting?.shortHash,
           pendingCustomLightingPersistenceHash == expectedHash {
            pendingCustomLightingPersistenceHash = nil
        }
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
        customSpaceWarpRuntimeState = rollback.spaceWarpRuntimeState
        customSpaceWarpControlProfile = rollback.spaceWarpControlProfile
        publishCustomLightingParameterValues(rollback.lightingParameterValues)
        renderSettings.spaceWarpStrength = rollback.spaceWarpStrength

        let rendererPrimary = rollback.primary?.isBundledConstructionPrimitive == true
            ? nil : rollback.primary
        do {
            try await handler(rendererPrimary, rollback.lighting)
            guard isCurrentEmbeddedEffectSetOperation(operationGeneration),
                  activeEmbeddedFormulaHash == rollback.primaryHash,
                  activeEmbeddedLightingHash == rollback.lightingHash else { return true }
            reconcilePublishedEmbeddedEffectSetRuntime(
                primary: rollback.primary,
                lighting: rollback.lighting
            )
            recordPublishedEmbeddedEffectSet(
                primaryHash: rollback.primaryHash,
                lightingHash: rollback.lightingHash,
                operationGeneration: operationGeneration
            )
            drainPendingSceneApplyIfPublished()
        } catch {
            guard isCurrentEmbeddedEffectSetOperation(operationGeneration) else { return true }
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
        let previousPrimary = activeEmbeddedFormula
        let previousPrimaryHash = activeEmbeddedFormulaHash
        let previousLighting = activeEmbeddedLighting
        let previousLightingHash = activeEmbeddedLightingHash
        let previousPublicationWasCurrent = hasCurrentPublishedEmbeddedEffectSet(
            primaryHash: previousPrimaryHash,
            lightingHash: previousLightingHash
        )
        let operationGeneration = beginEmbeddedEffectSetOperation()
        do {
            try await handler(draft, activeEmbeddedLighting)
            guard isCurrentEmbeddedEffectSetOperation(operationGeneration) else { return .superseded }
            if activeEmbeddedFormula?.effectKind == .spaceWarp {
                renderSettings.spaceWarpStrength = 0
                customSpaceWarpRuntimeState = .inactive
                customSpaceWarpControlProfile = .generic
            }
            activeEmbeddedFormula = draft
            activeEmbeddedFormulaHash = draft.shortHash
            reconcilePublishedEmbeddedEffectSetRuntime(
                primary: draft,
                lighting: activeEmbeddedLighting
            )
            recordPublishedEmbeddedEffectSet(
                primaryHash: draft.shortHash,
                lightingHash: activeEmbeddedLightingHash,
                operationGeneration: operationGeneration
            )
            drainPendingSceneApplyIfPublished()
            return .ready
        } catch {
            guard isCurrentEmbeddedEffectSetOperation(operationGeneration) else { return .superseded }
            if previousPublicationWasCurrent,
               activeEmbeddedFormulaHash == previousPrimaryHash,
               activeEmbeddedLightingHash == previousLightingHash {
                reconcilePublishedEmbeddedEffectSetRuntime(
                    primary: previousPrimary,
                    lighting: previousLighting
                )
                recordPublishedEmbeddedEffectSet(
                    primaryHash: previousPrimaryHash,
                    lightingHash: previousLightingHash,
                    operationGeneration: operationGeneration
                )
                drainPendingSceneApplyIfPublished()
            }
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
        let operationGeneration = beginEmbeddedEffectSetOperation()
        publishedEmbeddedEffectSet = nil
        // A space warp leaves fractalType untouched and drives spaceWarpStrength;
        // reset it on detach so the built-in Twist default doesn't linger at the
        // strength the warp set. (Harmless no-op for custom fractals.)
        let wasWarp = (activeEmbeddedFormula?.effectKind == .spaceWarp)
        let previousHash = activeEmbeddedFormulaHash
        FormulaCatalog.shared.unregisterEphemeral()
        FractalTypeRegistry.unregisterCustom()
        activeEmbeddedFormula = nil
        activeEmbeddedFormulaHash = nil
        customSpaceWarpRuntimeState = .inactive
        customSpaceWarpControlProfile = .generic
        if wasWarp {
            clearPendingCustomSpaceWarpActivation(for: previousHash)
            renderSettings.spaceWarpStrength = 0
        }
        guard let handler = activateEmbeddedFormulaHandler else { return }
        let lighting = activeEmbeddedLighting
        let lightingHash = activeEmbeddedLightingHash
        Task { @MainActor in
            guard self.isCurrentEmbeddedEffectSetOperation(operationGeneration) else { return }
            do {
                try await handler(nil, lighting)
                guard self.isCurrentEmbeddedEffectSetOperation(operationGeneration),
                      self.activeEmbeddedFormulaHash == nil,
                      self.activeEmbeddedLightingHash == lightingHash else { return }
                self.reconcilePublishedEmbeddedEffectSetRuntime(
                    primary: nil,
                    lighting: lighting
                )
                self.recordPublishedEmbeddedEffectSet(
                    primaryHash: nil,
                    lightingHash: lightingHash,
                    operationGeneration: operationGeneration
                )
                self.drainPendingSceneApplyIfPublished()
            } catch {
                // Preserve the historical fire-and-forget detach behavior. A
                // failed handler keeps the last-good renderer library; staged
                // AppModel state will be reconciled by the next owned operation.
            }
        }
    }

    /// Awaitable detach for the Transformations card. On a compiler/publish
    /// failure the previous payload and controls remain authoritative, matching
    /// the keep-last-good behavior used by custom lighting.
    @discardableResult
    func uninstallEmbeddedSpaceWarpAndWait() async -> Bool {
        guard let warp = activeEmbeddedFormula,
              warp.effectKind == .spaceWarp else { return true }

        let previousLightingHash = activeEmbeddedLightingHash
        let previousPublicationWasCurrent = hasCurrentPublishedEmbeddedEffectSet(
            primaryHash: activeEmbeddedFormulaHash,
            lightingHash: previousLightingHash
        )
        let operationGeneration = beginEmbeddedEffectSetOperation()
        publishedEmbeddedEffectSet = nil
        let previousHash = activeEmbeddedFormulaHash
        let previousStrength = renderSettings.spaceWarpStrength
        let previousState = customSpaceWarpRuntimeState
        let previousProfile = customSpaceWarpControlProfile
        activeEmbeddedFormula = nil
        activeEmbeddedFormulaHash = nil
        customSpaceWarpRuntimeState = .detaching(name: warp.name)

        guard let handler = activateEmbeddedFormulaHandler else {
            clearPendingCustomSpaceWarpActivation(for: previousHash)
            renderSettings.spaceWarpStrength = 0
            customSpaceWarpRuntimeState = .inactive
            customSpaceWarpControlProfile = .generic
            return true
        }

        do {
            try await handler(nil, activeEmbeddedLighting)
            // A newer primary request now owns AppModel. Detach itself may have
            // published successfully, but its caller must not checkpoint that
            // newer request before the newer Metal compilation finishes.
            guard isCurrentEmbeddedEffectSetOperation(operationGeneration),
                  activeEmbeddedFormulaHash == nil else { return false }
            clearPendingCustomSpaceWarpActivation(for: previousHash)
            renderSettings.spaceWarpStrength = 0
            customSpaceWarpRuntimeState = .inactive
            customSpaceWarpControlProfile = .generic
            reconcilePublishedEmbeddedEffectSetRuntime(
                primary: nil,
                lighting: activeEmbeddedLighting
            )
            recordPublishedEmbeddedEffectSet(
                primaryHash: nil,
                lightingHash: activeEmbeddedLightingHash,
                operationGeneration: operationGeneration
            )
            drainPendingSceneApplyIfPublished()
            return true
        } catch {
            guard isCurrentEmbeddedEffectSetOperation(operationGeneration),
                  activeEmbeddedFormulaHash == nil else { return false }
            activeEmbeddedFormula = warp
            activeEmbeddedFormulaHash = previousHash
            renderSettings.spaceWarpStrength = previousStrength
            customSpaceWarpRuntimeState = previousState
            customSpaceWarpControlProfile = previousProfile
            if previousPublicationWasCurrent,
               activeEmbeddedLightingHash == previousLightingHash {
                reconcilePublishedEmbeddedEffectSetRuntime(
                    primary: warp,
                    lighting: activeEmbeddedLighting
                )
                recordPublishedEmbeddedEffectSet(
                    primaryHash: previousHash,
                    lightingHash: previousLightingHash,
                    operationGeneration: operationGeneration
                )
                drainPendingSceneApplyIfPublished()
            }
            errorReporter.report(.preset(.importFailed(
                "Failed to detach external space warp: \(error.localizedDescription)"
            )))
            return false
        }
    }

    /// Cancel only deferred work owned by the modifier being detached. This is
    /// especially important for a menu-loaded warp queued before immersive-space
    /// startup: detaching it must not let the handler's later bind resurrect it.
    private func clearPendingCustomSpaceWarpActivation(for hash: String?) {
        customSpaceWarpSettingsPersistenceTask?.cancel()
        customSpaceWarpSettingsPersistenceTask = nil
        if pendingCustomSpaceWarpPersistenceHash == hash {
            pendingCustomSpaceWarpPersistenceHash = nil
        }
        if pendingSceneApplyAfterActivation?.formulaHash == hash {
            pendingSceneApplyAfterActivation = nil
        }
        if pendingPresetForActivation?.embeddedFormula?.shortHash == hash {
            pendingPresetForActivation = nil
            pendingPresetSceneNavigationRequest = nil
            pendingPresetLoadGeneration = nil
            pendingPresetApplyOptions = []
        }
        pendingEmbeddedEffectSetRollback = nil
    }

    /// Detach only the custom lighting sidecar. Geometry, formula parameters,
    /// space transforms, and the current Threshold lighting settings are kept.
    func uninstallEmbeddedLighting() {
        guard activeEmbeddedLightingHash != nil || activeEmbeddedLighting != nil else { return }
        pendingCustomLightingPersistenceHash = nil
        let previousPrimaryHash = activeEmbeddedFormulaHash
        let previousPublicationWasCurrent = hasCurrentPublishedEmbeddedEffectSet(
            primaryHash: previousPrimaryHash,
            lightingHash: activeEmbeddedLightingHash
        )
        let operationGeneration = beginEmbeddedEffectSetOperation()
        publishedEmbeddedEffectSet = nil
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
            guard self.isCurrentEmbeddedEffectSetOperation(operationGeneration) else { return }
            do {
                try await handler(primary, nil)
                guard self.isCurrentEmbeddedEffectSetOperation(operationGeneration),
                      self.activeEmbeddedLighting == nil,
                      self.activeEmbeddedLightingHash == nil else { return }
                self.publishCustomLightingParameterValues(self.customLightingParameterValues)
                self.reconcilePublishedEmbeddedEffectSetRuntime(
                    primary: self.activeEmbeddedFormula,
                    lighting: nil
                )
                self.recordPublishedEmbeddedEffectSet(
                    primaryHash: self.activeEmbeddedFormulaHash,
                    lightingHash: nil,
                    operationGeneration: operationGeneration
                )
                self.drainPendingSceneApplyIfPublished()
            } catch {
                guard self.isCurrentEmbeddedEffectSetOperation(operationGeneration),
                      self.activeEmbeddedLighting == nil,
                      self.activeEmbeddedLightingHash == nil else { return }
                self.activeEmbeddedLighting = previous
                self.activeEmbeddedLightingHash = previousHash
                self.customLightingRuntimeState = previousState
                self.publishCustomLightingParameterValues(previousValues)
                if previousPublicationWasCurrent,
                   self.activeEmbeddedFormulaHash == previousPrimaryHash {
                    self.reconcilePublishedEmbeddedEffectSetRuntime(
                        primary: self.activeEmbeddedFormula,
                        lighting: previous
                    )
                    self.recordPublishedEmbeddedEffectSet(
                        primaryHash: previousPrimaryHash,
                        lightingHash: previousHash,
                        operationGeneration: operationGeneration
                    )
                    self.drainPendingSceneApplyIfPublished()
                }
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
        pendingCustomLightingPersistenceHash = nil
        let previousPrimaryHash = activeEmbeddedFormulaHash
        let previousPublicationWasCurrent = hasCurrentPublishedEmbeddedEffectSet(
            primaryHash: previousPrimaryHash,
            lightingHash: activeEmbeddedLightingHash
        )
        let operationGeneration = beginEmbeddedEffectSetOperation()
        publishedEmbeddedEffectSet = nil
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
            guard isCurrentEmbeddedEffectSetOperation(operationGeneration) else { return false }
            if activeEmbeddedLighting == nil, activeEmbeddedLightingHash == nil {
                publishCustomLightingParameterValues(customLightingParameterValues)
                reconcilePublishedEmbeddedEffectSetRuntime(
                    primary: activeEmbeddedFormula,
                    lighting: nil
                )
                recordPublishedEmbeddedEffectSet(
                    primaryHash: activeEmbeddedFormulaHash,
                    lightingHash: nil,
                    operationGeneration: operationGeneration
                )
                drainPendingSceneApplyIfPublished()
            }
            return true
        } catch {
            guard isCurrentEmbeddedEffectSetOperation(operationGeneration),
                  activeEmbeddedLighting == nil,
                  activeEmbeddedLightingHash == nil else { return false }
            activeEmbeddedLighting = previous
            activeEmbeddedLightingHash = previousHash
            customLightingRuntimeState = previousState
            publishCustomLightingParameterValues(previousValues)
            if previousPublicationWasCurrent,
               activeEmbeddedFormulaHash == previousPrimaryHash {
                reconcilePublishedEmbeddedEffectSetRuntime(
                    primary: activeEmbeddedFormula,
                    lighting: previous
                )
                recordPublishedEmbeddedEffectSet(
                    primaryHash: previousPrimaryHash,
                    lightingHash: previousHash,
                    operationGeneration: operationGeneration
                )
                drainPendingSceneApplyIfPublished()
            }
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
