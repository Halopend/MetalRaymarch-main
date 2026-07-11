//
//  AppModel+ExternalImport.swift
//  Threshold
//
//  External-file import flow (.threshscene / .threshmp / .threshanim / .threshfx):
//  open -> preview (with restore-on-cancel) -> commit. Extracted verbatim from
//  AppModel to keep the app coordinator focused; behaviour is unchanged.
//

import Foundation

extension AppModel {

    func openExternalFile(_ url: URL) {
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        clearExternalPreview(restorePreviewedState: true)
        pendingExternalImport = nil

        // Route by the file-type registry's category rather than re-hardcoding the
        // extension groups here (single source of truth: ThresholdExportFormat).
        switch ThresholdExportFormat(fileExtension: url.pathExtension)?.category {
        case .preset:
            do {
                let preset = try presetManager.decodePreset(from: url)
                pendingExternalImport = ExternalFileImportRequest(
                    fileName: url.lastPathComponent,
                    fileExtension: url.pathExtension.lowercased(),
                    payload: .preset(preset)
                )
                ensureWindowContentVisible()
            } catch {
                errorReporter.report(.preset(.importFailed("Could not read \(url.lastPathComponent).")))
            }

        case .animation:
            do {
                guard let scene = try animationManager?.decodeScene(from: url) else {
                    errorReporter.report(.animation(.importFailed("Animation manager is unavailable.")))
                    return
                }
                pendingExternalImport = ExternalFileImportRequest(
                    fileName: url.lastPathComponent,
                    fileExtension: url.pathExtension.lowercased(),
                    payload: .animation(scene)
                )
                ensureWindowContentVisible()
            } catch {
                errorReporter.report(.animation(.importFailed("Could not read \(url.lastPathComponent).")))
            }

        case .formula:
            do {
                let container = try EmbeddedFormulaContainer.decode(fromContainerAt: url)
                if container.formula.effectKind == .spaceWarp {
                    // A space-warp effect applies to the current fractal — install
                    // it directly rather than routing through the custom-fractal
                    // preset/preview path (which would force fractalType = .custom).
                    installSpaceWarp(container.formula)
                    // Persist immediately so the warp survives relaunch. The other
                    // external-import paths persist via loadStaticScene's
                    // .persistLastState option; the direct space-warp install
                    // bypasses that, so save here to match their guarantee.
                    saveLastState()
                    ensureWindowContentVisible()
                    return
                }
                let preset = AppModel.makeCustomPreset(from: container.formula)
                pendingExternalImport = ExternalFileImportRequest(
                    fileName: url.lastPathComponent,
                    fileExtension: "threshfx",
                    payload: .preset(preset)
                )
                ensureWindowContentVisible()
            } catch {
                errorReporter.report(.preset(.importFailed("Could not read \(url.lastPathComponent): \(error.localizedDescription)")))
            }

        case nil:
            errorReporter.report(.preset(.importFailed("Unsupported Threshold file: \(url.lastPathComponent).")))
        }
    }

    func previewExternalImport(_ request: ExternalFileImportRequest) {
        if activeExternalPreviewID != request.id {
            clearExternalPreview(restorePreviewedState: true)
            activeExternalPreviewID = request.id
        }

        switch request.payload {
        case .preset(let preset):
            if externalPreviewRestorePreset == nil {
                externalPreviewRestorePreset = FractalPreset.fromSettings(
                    renderSettings,
                    name: "__externalPreviewRestore__",
                    embeddedFormula: activeEmbeddedFormula
                )
            }
            if !externalPreviewCapturedEmbeddedFormula {
                externalPreviewRestoreEmbeddedFormula = activeEmbeddedFormula
                externalPreviewCapturedEmbeddedFormula = true
            }
            // Defer to the shared scene-load helper so external previews get
            // the same eased transition + gesture overrides as keyboard loads.
            // Guard against stale previews being applied if the user has already
            // moved on to a different import request.
            Task { @MainActor [self] in
                guard activeExternalPreviewID == request.id else { return }
                loadStaticScene(preset, options: [])
            }

        case .animation(let scene):
            if !externalPreviewCapturedScene {
                externalPreviewRestoreScene = animationManager?.currentScene
                externalPreviewCapturedScene = true
            }
            if !externalPreviewCapturedEmbeddedFormula {
                externalPreviewRestoreEmbeddedFormula = activeEmbeddedFormula
                externalPreviewCapturedEmbeddedFormula = true
            }
            guard let formula = scene.embeddedFormula else {
                installEmbeddedFormulaIfNeeded(nil)
                animationManager?.currentScene = scene
                return
            }
            if formula.effectKind == .spaceWarp {
                // A space warp rides the active fractal — install it directly,
                // exactly as the preset path (loadStaticScene) and the standalone
                // .threshfx path do, instead of registering it as a .custom
                // fractal via activateEmbeddedFormulaForSceneLoad (which would
                // force fractalType = .custom and bind the wrong Metal entry
                // points). installSpaceWarp handles the renderer-not-up case
                // itself (re-activates on handler bind), so no deferred queue.
                installSpaceWarp(formula)
                animationManager?.currentScene = scene
                return
            }
            Task { @MainActor in
                let installResult = await activateEmbeddedFormulaForSceneLoad(formula)
                let ready: Bool
                switch installResult {
                case .ready:
                    ready = true
                case .deferred:
                    ready = await waitForRendererAndActivate(formula)
                    if !ready {
                        // Renderer never came up within the wait: queue the
                        // apply behind the activation handler instead of
                        // silently dropping the preview.
                        queueSceneApplyAfterFormulaActivation(formulaHash: formula.shortHash) { [self] in
                            guard activeExternalPreviewID == request.id else { return }
                            animationManager?.currentScene = scene
                        }
                        return
                    }
                case .failed:
                    ready = false
                }
                guard ready, activeExternalPreviewID == request.id else { return }
                animationManager?.currentScene = scene
            }
        }
    }

    func importExternalFile(_ request: ExternalFileImportRequest) {
        switch request.payload {
        case .preset(let preset):
            // External imports are the only path that needs to (a) persist the
            // preset to the user's library, (b) write the new state to
            // lastState.json, and (c) close the import sheet. The shared helper
            // handles all of those when asked, otherwise behaves like the
            // in-app scene load.
            loadStaticScene(preset, options: [.saveToLibrary, .persistLastState, .closeExternalSheet])
            return

        case .animation(let scene):
            guard let formula = scene.embeddedFormula else {
                uninstallEmbeddedFormula()
                let importedScene = animationManager?.importScene(scene)
                animationManager?.currentScene = importedScene
                clearExternalPreview(restorePreviewedState: false)
                pendingExternalImport = nil
                ensureWindowContentVisible()
                return
            }
            if formula.effectKind == .spaceWarp {
                // Space warp: install directly (see the preview branch + the
                // .threshfx path) rather than registering a .custom fractal.
                installSpaceWarp(formula)
                let importedScene = animationManager?.importScene(scene)
                animationManager?.currentScene = importedScene
                clearExternalPreview(restorePreviewedState: false)
                pendingExternalImport = nil
                ensureWindowContentVisible()
                return
            }
            Task { @MainActor [self] in
                let installResult = await activateEmbeddedFormulaForSceneLoad(formula)
                let ready: Bool
                switch installResult {
                case .ready:
                    ready = true
                case .deferred:
                    ready = await waitForRendererAndActivate(formula)
                    if !ready {
                        // Renderer never came up within the wait. Persist the
                        // import + close the sheet now (the user's intent is
                        // committed), and queue the scene apply behind the
                        // activation handler so it loads when they enter the
                        // immersive space instead of being silently dropped.
                        let importedScene = self.animationManager?.importScene(scene)
                        self.clearExternalPreview(restorePreviewedState: false)
                        self.pendingExternalImport = nil
                        self.ensureWindowContentVisible()
                        queueSceneApplyAfterFormulaActivation(formulaHash: formula.shortHash) { [self] in
                            animationManager?.currentScene = importedScene
                        }
                        return
                    }
                case .failed:
                    ready = false
                }
                guard ready else { return }
                let importedScene = animationManager?.importScene(scene)
                animationManager?.currentScene = importedScene
                clearExternalPreview(restorePreviewedState: false)
                pendingExternalImport = nil
                ensureWindowContentVisible()
            }
            return
        }
    }

    func cancelExternalImport(_ request: ExternalFileImportRequest) {
        if activeExternalPreviewID == request.id {
            clearExternalPreview(restorePreviewedState: true)
        }
        if pendingExternalImport?.id == request.id {
            pendingExternalImport = nil
        }
    }

    func clearExternalPreview(restorePreviewedState: Bool) {
        if restorePreviewedState {
            if externalPreviewCapturedEmbeddedFormula {
                if let formula = externalPreviewRestoreEmbeddedFormula {
                    installEmbeddedFormulaIfNeeded(formula)
                } else {
                    uninstallEmbeddedFormula()
                }
            }
            if let preset = externalPreviewRestorePreset {
                preset.apply(to: renderSettings, resetEnvironment: true)
                gestureController?.syncWithSettings()
                NotificationCenter.default.post(name: AppModel.fractalSettingsDidChangeNotification, object: nil)
            }
            if externalPreviewCapturedScene {
                animationManager?.currentScene = externalPreviewRestoreScene
            }
        }

        externalPreviewRestorePreset = nil
        externalPreviewRestoreScene = nil
        externalPreviewRestoreEmbeddedFormula = nil
        externalPreviewCapturedScene = false
        externalPreviewCapturedEmbeddedFormula = false
        activeExternalPreviewID = nil
        // Drop any animation-scene apply queued behind a deferred formula
        // activation. Without this, a queued closure from an abandoned preview
        // (cancel) or a superseded import (opening a new file) could fire later
        // when an unrelated formula with a colliding shortHash activates,
        // applying the wrong scene. Every code path that queues a scene does so
        // *after* its clearExternalPreview call, so this never drops a live queue.
        pendingSceneApplyAfterActivation = nil
    }
}
