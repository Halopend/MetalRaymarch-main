//
//  AppModel+SceneLoading.swift
//  Threshold
//
//  Static-scene / preset loading orchestration: the eased apply path, the
//  formula-activation deferral queue, renderer-readiness wait, and per-preset
//  gesture overrides. Extracted verbatim from AppModel to keep the app
//  coordinator focused; behaviour is unchanged.
//

import Foundation

extension AppModel {

    /// Loads a jumping-off / static scene preset through the full pipeline:
    /// embedded-formula install, pipeline prep, eased parameter transition,
    /// gesture overrides, and a settings-changed notification so any live UI
    /// reloads its cache. Shared by the keyboard scene-switch shortcut, the
    /// in-app browse UI, and external file imports (`.threshscene`/`.threshfx`)
    /// so all entry points stay in lockstep.
    @MainActor
    func loadStaticScene(
        _ preset: FractalPreset,
        options: StaticSceneLoadOptions = [],
        manualSceneNavigationRequest: ManualSceneNavigationRequest? = nil
    ) {
        if manualSceneNavigationRequest == nil {
            manualStaticSceneNavigationCursor = nil
        }
        // Exit keyframe-animation mode before loading a static scene. While an
        // animation is playing, `RenderSettings.isAnimationPlaying` makes the
        // effective-target getters return the per-frame `animationBase` and the
        // keyframe loop keeps overwriting it every frame — so a newly loaded
        // scene never takes hold; the animation "overtakes" it. The in-app grid
        // browser already tears down here before calling us; doing it centrally
        // keeps every entry point (keyboard cycle, swipe, external import, App
        // Intents) in lockstep. Runs synchronously (main-actor) before the async
        // apply Task so the stop lands immediately on tap/keypress.
        animationManager?.clearCurrentSceneSelection()
        staticSceneLoadGeneration &+= 1
        let generation = staticSceneLoadGeneration
        staticSceneLoadTask?.cancel()
        let source = options.isEmpty ? "keyboard" : "external"
        staticSceneLoadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.staticSceneLoadGeneration == generation { self.staticSceneLoadTask = nil }
            }
            customSceneDiagnostic("🔬 [CSDiag] AppModel.loadStaticScene source=\(source) name='\(preset.name)' ft=\(preset.fractalType.rawValue) embeddedFormula=\(preset.embeddedFormula?.name ?? "nil")")
            let installResult = await activateEmbeddedEffectSetForSceneLoad(
                primary: preset.embeddedFormula,
                lighting: preset.embeddedLighting,
                lightingParameterValues: preset.embeddedLightingParamValues
            )
            guard !Task.isCancelled, staticSceneLoadGeneration == generation else { return }
            customSceneDiagnostic("🔬 [CSDiag] AppModel.loadStaticScene effect-set activation returned \(installResult)")
            if installResult == .failed { return }
            if installResult == .deferred {
                // Renderer isn't up yet (typical: an external scene opened
                // before immersive presentation). Both immutable effect slots
                // are staged; the handler's didSet compiles them together.
                queuePresetApplyAfterFormulaActivation(
                    preset,
                    options: options,
                    manualSceneNavigationRequest: manualSceneNavigationRequest,
                    loadGeneration: generation
                )
                return
            }
            // Direct (non-deferred) load: clear any leftover queued preset /
            // scene from a previous deferred import, so a stale queued apply
            // can't fire on the next handler binding.
            pendingPresetForActivation = nil
            pendingPresetSceneNavigationRequest = nil
            pendingPresetLoadGeneration = nil
            pendingPresetApplyOptions = []
            pendingSceneApplyAfterActivation = nil
            guard !Task.isCancelled, staticSceneLoadGeneration == generation else { return }
            await applyLoadedScene(
                preset,
                options: options,
                manualSceneNavigationRequest: manualSceneNavigationRequest
            )
        }
    }

    /// Wait for `activateEmbeddedFormulaHandler` to bind, then apply the
    /// supplied preset. Surfaces a clear status message in the meantime so
    /// the user knows the import succeeded and they need to enter the scene
    /// to see it. Used as the deferred-activation follow-up to
    /// `loadStaticScene`.
    @MainActor
    func queuePresetApplyAfterFormulaActivation(
        _ preset: FractalPreset,
        options: StaticSceneLoadOptions,
        manualSceneNavigationRequest: ManualSceneNavigationRequest? = nil,
        loadGeneration: UInt64,
        timeout: TimeInterval = 10
    ) {
        // Persist + close the import sheet immediately so the user gets
        // visual feedback that the import succeeded. The *visual* scene
        // application (parameters, gesture overrides, eased transition) is
        // what waits for the renderer to come up.
        if options.contains(.saveToLibrary) {
            _ = presetManager.importPreset(preset)
        }
        if options.contains(.closeExternalSheet) {
            clearExternalPreview(restorePreviewedState: false)
            pendingExternalImport = nil
            ensureWindowContentVisible()
        }
        // Stash the preset so the activateEmbeddedFormulaHandler.didSet
        // (and the renderer's startup deferred-activation block) can apply
        // it once the formula has actually been compiled in the renderer.
        // This handles the case where the user enters the scene *after* our
        // 10s timeout has expired: the renderer's startup picks up
        // `activeEmbeddedFormula` and the didSet consumes the queued preset.
        pendingPresetForActivation = preset
        pendingPresetSceneNavigationRequest = manualSceneNavigationRequest
        pendingPresetLoadGeneration = loadGeneration
        pendingPresetApplyOptions = options.contains(.persistLastState)
            ? [.persistLastState] : []
        // Auto-open the immersive space if the user is on the menu (or in
        // any state other than already-open). The view that owns
        // @Environment(\.openImmersiveSpace) observes the notification and
        // triggers the open. This is the only way to bridge the import
        // sheet (AppModel-level) to the SwiftUI environment value.
        if immersiveSpaceState != .open {
            NotificationCenter.default.post(
                name: AppModel.requestOpenImmersiveSpaceNotification,
                object: nil,
                userInfo: ["presetID": preset.id.uuidString]
            )
        }
        Task { @MainActor in
            customSceneDiagnostic("🔬 [CSDiag] queuePresetApplyAfterFormulaActivation name='\(preset.name)' hash=\(preset.embeddedFormula?.shortHash ?? "nil")")
            let deadline = Date().addingTimeInterval(timeout)
            while activateEmbeddedFormulaHandler == nil {
                guard staticSceneLoadGeneration == loadGeneration,
                      pendingPresetForActivation?.id == preset.id,
                      pendingPresetLoadGeneration == loadGeneration else { return }
                if Date() > deadline {
                    errorReporter.report(.preset(.importFailed(
                        "Custom scene is queued. Enter the immersive space to compile and render the custom shader."
                    )))
                    return
                }
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            }
            // Binding the handler synchronously launches its didSet activation,
            // which owns both compilation and the queued-preset drain. Do not
            // start a duplicate compile here: a superseded call can return before
            // the publishing call and make scene application race the pipeline.
        }
    }

    /// The shared tail of `loadStaticScene` and
    /// `queuePresetApplyAfterFormulaActivation`. Runs the eased preset
    /// transition, gesture overrides, and sheet/library/lastState cleanup
    /// exactly once per scene load. Caller is responsible for ensuring the
    /// formula is compiled before invoking this.
    @MainActor
    func applyLoadedScene(
        _ preset: FractalPreset,
        options: StaticSceneLoadOptions,
        manualSceneNavigationRequest: ManualSceneNavigationRequest? = nil
    ) async {
        // Custom and built-in scenes wait here alike: a custom formula has no
        // usable pipeline until its specialized one is compiled, and a built-in
        // one may be specialized from the very settings this function is about
        // to mutate, so neither may overlap the mutation below.
        //
        // NOTE: only the visionOS compositor renderer installs
        // `preparePipelineHandler` (see `Renderer.startRenderLoop`;
        // `Rendering/Renderer.swift` is excluded from the ThresholdMac and
        // ThresholdiOS targets). On iPad/Mac this is a no-op, and prewarming is
        // not needed there: `ViewportRenderer.selectPipeline` builds the
        // specialized pipeline in the background and draws the current frame
        // with the generic one. Rapid iPad scene taps are made safe by the
        // generation/cancellation guards in `loadStaticScene`, not by this await.
        await preparePipelineHandler?(preset)
        guard !Task.isCancelled else { return }
        customSceneDiagnostic("🔬 [CSDiag] applyLoadedScene preparePipelineHandler completed; loading preset NOW")
        // Snapshot the currently displayed parameters so the load can ease
        // from them toward the new preset.
        renderSettings.beginSceneTransitionSnapshot()
        presetManager.loadPreset(
            preset,
            into: renderSettings,
            includePerformance: false,
            resetEnvironment: true
        )
        // Ease displayed parameters toward the new preset's values over the
        // configured "Same Scene Transition Time" instead of snapping.
        renderSettings.commitSceneTransition()
        applyPresetGestureOverridesIfNeeded(for: preset)
        syncGestureProcessor()
        rememberActiveResetPreset(preset)
        if options.contains(.saveToLibrary) {
            _ = presetManager.importPreset(preset)
        }
        if options.contains(.persistLastState) {
            saveLastState()
        }
        NotificationCenter.default.post(name: AppModel.fractalSettingsDidChangeNotification, object: nil)
        if options.contains(.closeExternalSheet) {
            clearExternalPreview(restorePreviewedState: false)
            pendingExternalImport = nil
            ensureWindowContentVisible()
        }
        if let manualSceneNavigationRequest {
            completeManualSceneNavigation(
                manualSceneNavigationRequest,
                sceneName: preset.name
            )
        }
    }

    /// Wait for the renderer's custom-shader activation handler to bind, then
    /// ask it to compile and install the supplied formula's MTLLibrary.
    ///
    /// On visionOS the handler binds as soon as the user enters the immersive
    /// space (see `Renderer.startRenderLoop`); on iOS / macOS the renderer
    /// runs as soon as the main view appears, so the handler is usually
    /// already present by the time a user-driven import happens.
    ///
    /// We poll the handler — not `rendererStartupWarmupComplete` — because the
    /// handler is the *minimum* signal that "the renderer is alive and can
    /// accept activations." Warmup is a stronger signal (compute pipelines
    /// cached) but it can lag by several seconds; the handler binds first.
    ///
    /// If the user never enters the immersive space, we give up after
    /// `timeout` seconds and return `false` — the renderer-side deferred
    /// activation block will still pick up `activeEmbeddedFormula` if/when
    /// the user later enters the scene, so the formula is not lost.
    @MainActor
    func waitForRendererAndActivate(_ formula: EmbeddedFormula, timeout: TimeInterval = 10) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while activateEmbeddedFormulaHandler == nil {
            if Date() > deadline {
                errorReporter.report(.preset(.importFailed(
                    "Custom scene is queued. Enter the immersive space to compile and render the custom shader."
                )))
                return false
            }
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }
        guard let handler = activateEmbeddedFormulaHandler else {
            // Lost the race: the renderer torn down between our poll and now.
            errorReporter.report(.preset(.importFailed(
                "Custom scene is queued. Enter the immersive space to compile and render the custom shader."
            )))
            return false
        }
        // The renderer's startup also re-reads activeEmbeddedFormula and
        // activates it the moment the handler binds, but call again here to
        // cover the case where our poll won the race. The activation is a
        // no-op when the hash + library already match.
        do {
            try await handler(formula, activeEmbeddedLighting)
            return true
        } catch {
            errorReporter.report(.preset(.importFailed(
                "Failed to compile custom shader: \(error.localizedDescription)"
            )))
            uninstallEmbeddedFormula()
            return false
        }
    }

    /// Applies preset-specific gesture binding overrides for known scenes.
    func applyPresetGestureOverridesIfNeeded(for preset: FractalPreset) {
        let normalizedName = preset.name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard ["ring around the rosie", "a space ring odyssey"].contains(normalizedName),
              preset.fractalType == .kleinian else { return }

        let triplets = ParameterNodeRegistry.shared.gestureBindableTriplets(for: .kleinian)
        guard let minsTriplet = triplets.first(where: { $0.groupName == "Mins" }),
              let maxsTriplet = triplets.first(where: { $0.groupName == "Maxs" }) else { return }

        renderSettings.withPersistenceSuppressed {
            renderSettings.setBinding(
                .parameterTriplet(minsTriplet),
                for: GestureSlot(hand: .left, finger: .middle)
            )
            renderSettings.setBinding(
                .parameterTriplet(maxsTriplet),
                for: GestureSlot(hand: .right, finger: .middle)
            )
        }
    }
}
