//
//  AppModel+ExternalImport.swift
//  Threshold
//
//  Open-file flow (.threshscene / .threshmp / .threshanim / .threshfx):
//  open -> background decode -> direct load when already in the active store,
//  otherwise preview (with restore-on-cancel) -> import commit.
//  Kept outside AppModel so the app coordinator remains focused.
//

import Foundation

/// A decoded external document is transferred exactly once from the detached
/// parser to AppModel's main actor. The payloads are value graphs and remain
/// immutable while in transit.
private struct ExternalFileDecodeResult: @unchecked Sendable {
    enum Payload {
        case preset(FractalPreset)
        case animation(AnimationScene)
        case formula(EmbeddedFormulaContainer)
    }

    let payload: Payload?
    let failureDescription: String?

    static func success(_ payload: Payload) -> Self {
        Self(payload: payload, failureDescription: nil)
    }

    static func failure(_ description: String) -> Self {
        Self(payload: nil, failureDescription: description)
    }
}

extension AppModel {

    func openExternalFile(_ url: URL) {
        // Retire an older open request before presenting this one. A generation
        // guard prevents a cancelled parser from clearing the newer request's
        // progress UI if its JSON decode finishes late.
        externalImportDecodeTask?.cancel()
        externalImportDecodeGeneration &+= 1
        let generation = externalImportDecodeGeneration

        clearExternalPreview(restorePreviewedState: true)
        pendingExternalImport = nil

        guard let format = ThresholdExportFormat(fileExtension: url.pathExtension) else {
            externalImportLoadingFileName = nil
            errorReporter.report(.preset(.importFailed("Unsupported Threshold file: \(url.lastPathComponent).")))
            return
        }

        // Security-scoped access intentionally spans the detached read/decode:
        // stopping it immediately after creating the task can make Files/iCloud
        // URLs fail midway through hydration.
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        externalImportLoadingFileName = url.lastPathComponent
        ensureWindowContentVisible()

        externalImportDecodeTask = Task { @MainActor [weak self] in
            guard let self else {
                if didStartAccessing {
                    url.stopAccessingSecurityScopedResource()
                }
                return
            }
            defer {
                if didStartAccessing {
                    url.stopAccessingSecurityScopedResource()
                }
                if externalImportDecodeGeneration == generation {
                    externalImportLoadingFileName = nil
                    externalImportDecodeTask = nil
                }
            }

            // Give SwiftUI enough time to commit and draw the loading overlay
            // before a large document starts consuming CPU and memory bandwidth.
            // This is deliberately short for small files but long enough to span
            // several display frames on every supported refresh rate.
            do {
                try await Task.sleep(for: .milliseconds(120))
            } catch {
                return
            }
            guard externalImportDecodeGeneration == generation else { return }

            let worker = Task.detached(priority: .userInitiated) {
                Self.decodeExternalFile(at: url, format: format)
            }
            let result = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled,
                  externalImportDecodeGeneration == generation else { return }

            let isInActiveStore = await isOpenURLInActiveStore(url)
            guard !Task.isCancelled,
                  externalImportDecodeGeneration == generation else { return }

            finishOpeningExternalFile(
                result,
                fileName: url.lastPathComponent,
                format: format,
                isInActiveStore: isInActiveStore
            )
        }
    }

    /// iCloud root discovery is asynchronous at launch. Give it a short chance
    /// to resolve before classifying an opened iCloud document as external, so a
    /// Finder open during app startup cannot produce a redundant import prompt.
    private func isOpenURLInActiveStore(_ url: URL) async -> Bool {
        let storage = StorageLocation.shared
        if storage.containsInActiveStore(url) { return true }
        guard storage.mode == .iCloud, storage.activeRoot == nil else { return false }

        for _ in 0..<40 {
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                return false
            }
            if storage.containsInActiveStore(url) { return true }
            if storage.activeRoot != nil { return false }
        }
        return false
    }

    private nonisolated static func decodeExternalFile(
        at url: URL,
        format: ThresholdExportFormat
    ) -> ExternalFileDecodeResult {
        do {
            switch format.category {
            case .preset:
                let data = try Data(contentsOf: url, options: [.mappedIfSafe])
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                return .success(.preset(try decoder.decode(FractalPreset.self, from: data)))

            case .animation:
                let data = try Data(contentsOf: url, options: [.mappedIfSafe])
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                return .success(.animation(try decoder.decode(AnimationScene.self, from: data)))

            case .formula:
                return .success(.formula(try EmbeddedFormulaContainer.decode(fromContainerAt: url)))
            }
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private func finishOpeningExternalFile(
        _ result: ExternalFileDecodeResult,
        fileName: String,
        format: ThresholdExportFormat,
        isInActiveStore: Bool
    ) {
        guard let payload = result.payload else {
            let detail = result.failureDescription.map { ": \($0)" } ?? ""
            switch format.category {
            case .animation:
                errorReporter.report(.animation(.importFailed("Could not read \(fileName)\(detail)")))
            case .preset, .formula:
                errorReporter.report(.preset(.importFailed("Could not read \(fileName)\(detail)")))
            }
            return
        }

        if isInActiveStore {
            openManagedStoreFile(payload)
            return
        }

        switch payload {
        case .preset(let preset):
            pendingExternalImport = ExternalFileImportRequest(
                fileName: fileName,
                fileExtension: format.ext,
                payload: .preset(preset)
            )
            ensureWindowContentVisible()

        case .animation(let scene):
            guard animationManager != nil else {
                errorReporter.report(.animation(.importFailed("Animation manager is unavailable.")))
                return
            }
            pendingExternalImport = ExternalFileImportRequest(
                fileName: fileName,
                fileExtension: format.ext,
                payload: .animation(scene)
            )
            ensureWindowContentVisible()

        case .formula(let container):
            if container.formula.effectKind == .spaceWarp {
                // A space-warp effect applies to the current fractal — install
                // it directly rather than routing through the custom-fractal
                // preset/preview path.
                installSpaceWarp(container.formula)
                saveLastState()
                ensureWindowContentVisible()
                return
            }
            let preset = AppModel.makeCustomPreset(from: container.formula)
            pendingExternalImport = ExternalFileImportRequest(
                fileName: fileName,
                fileExtension: format.ext,
                payload: .preset(preset)
            )
            ensureWindowContentVisible()
        }
    }

    /// Open a document that already belongs to the active local/iCloud library.
    /// Nothing is persisted here: the folder is already the source of truth.
    private func openManagedStoreFile(_ payload: ExternalFileDecodeResult.Payload) {
        switch payload {
        case .preset(let preset):
            loadStaticScene(preset)

        case .animation(let scene):
            guard animationManager != nil else {
                errorReporter.report(.animation(.importFailed("Animation manager is unavailable.")))
                return
            }
            openManagedAnimationScene(scene)

        case .formula(let container):
            if container.formula.effectKind == .spaceWarp {
                installSpaceWarp(container.formula)
                saveLastState()
            } else {
                loadStaticScene(AppModel.makeCustomPreset(from: container.formula))
            }
        }

        ensureWindowContentVisible()
    }

    private func openManagedAnimationScene(_ scene: AnimationScene) {
        guard let formula = scene.embeddedFormula else {
            uninstallEmbeddedFormula()
            animationManager?.currentScene = scene
            return
        }
        if formula.effectKind == .spaceWarp {
            installSpaceWarp(formula)
            animationManager?.currentScene = scene
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
                    queueSceneApplyAfterFormulaActivation(formulaHash: formula.shortHash) { [self] in
                        animationManager?.currentScene = scene
                        ensureWindowContentVisible()
                    }
                    return
                }
            case .failed:
                ready = false
            }
            guard ready else { return }
            animationManager?.currentScene = scene
            ensureWindowContentVisible()
        }
    }

    func previewExternalImport(_ request: ExternalFileImportRequest) {
        customSceneDiagnostic("🔬 [CSDiag] previewExternalImport id=\(request.id) payload=\(request.payload)")
        if activeExternalPreviewID != request.id {
            clearExternalPreview(restorePreviewedState: true)
            activeExternalPreviewID = request.id
        }

        switch request.payload {
        case .preset(let preset):
            customSceneDiagnostic("🔬 [CSDiag] previewExternalImport .preset name='\(preset.name)' ft=\(preset.fractalType.rawValue) embeddedFormula=\(preset.embeddedFormula?.name ?? "nil")")
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
        customSceneDiagnostic("🔬 [CSDiag] importExternalFile id=\(request.id)")
        switch request.payload {
        case .preset(let preset):
            customSceneDiagnostic("🔬 [CSDiag] importExternalFile .preset name='\(preset.name)' ft=\(preset.fractalType.rawValue) embeddedFormula=\(preset.embeddedFormula?.name ?? "nil")")
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
                preset.apply(
                    to: renderSettings,
                    resetEnvironment: true,
                    scope: .session
                )
                syncGestureProcessor()
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
