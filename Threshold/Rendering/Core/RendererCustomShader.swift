//
//  RendererCustomShader.swift
//  Threshold
//
//  Adds runtime-compiled embedded formula support to the Renderer actor.
//
//  When an `EmbeddedFormula` is active (loaded from a `.threshfx`, `.threshanim`,
//  or `.threshscene` file), the renderer compiles its Metal source via
//  `CustomShaderCompiler` and routes pipeline lookups for
//  `FractalModelType.custom` through the resulting `MTLLibrary`. Cache keys for
//  custom-formula pipelines are prefixed with `CX{shortHash}_` so they coexist
//  with the bundled built-in pipelines and so a formula switch can evict only
//  the previous formula's entries.
//

import Foundation
import Metal
import QuartzCore

extension Renderer {

    // MARK: - Self-heal

    /// Last-resort recovery for frames that arrive with `fractalType == .custom`
    /// but no compiled custom library. That state means a preset referencing a
    /// `.threshfx` formula was applied before (or its activation was lost
    /// across) the renderer's activation — cold-start file opens, immersive
    /// space re-entry rebinding handlers, or preview/import interleavings can
    /// all order that way, and without recovery the scene renders fog/sky
    /// forever. The formula stays registered on AppModel, so the renderer can
    /// simply re-activate it itself: any ordering bug degrades to a brief sky
    /// flash instead of a dead scene. Debounced to one attempt per second so a
    /// formula that genuinely fails to compile cannot hot-loop the compiler.
    func scheduleCustomLibrarySelfHeal() {
        let now = CACurrentMediaTime()
        guard !customLibrarySelfHealInFlight,
              now - lastCustomLibrarySelfHealAttempt > 1.0 else { return }
        customLibrarySelfHealInFlight = true
        lastCustomLibrarySelfHealAttempt = now

        Task { [weak self] in
            guard let self else { return }
            let (formula, stackSrc, stackSig) = await MainActor.run {
                (self.appModel.activeEmbeddedFormula,
                 self.appModel.renderSettings.warpStackCodegenSource,
                 self.appModel.renderSettings.warpStackCodegenSignature)
            }
            if formula != nil || stackSrc != nil {
                do {
                    try await self.activateEmbeddedFormula(formula, warpStackSource: stackSrc, warpStackSignature: stackSig)
                    print("🔧 [CustomScene] Self-heal: recompiled effect set after a frame requested it with no library installed")
                } catch {
                    print("❌ [CustomScene] Self-heal activation failed: \(error)")
                }
            }
            await self.finishCustomLibrarySelfHeal()
        }
    }

    private func finishCustomLibrarySelfHeal() {
        customLibrarySelfHealInFlight = false
    }

    // MARK: - State

    /// `MTLLibrary` for the currently active embedded formula (or `nil` when no
    /// `.threshfx` is loaded). Backed by `Renderer._customShaderLibraryStorage`
    /// to avoid stored-property limits on extensions.
    var customShaderLibrary: MTLLibrary? {
        get { Renderer.customShaderState.currentLibrary() }
        set { Renderer.customShaderState.update(library: newValue, hash: customShaderHash) }
    }

    /// `EmbeddedFormula.shortHash` for the active library, or `nil` when none.
    var customShaderHash: String? {
        get { Renderer.customShaderState.currentHash() }
        set { Renderer.customShaderState.update(library: customShaderLibrary, hash: newValue) }
    }

    /// Cache-key prefix to apply when looking up pipelines for the active
    /// embedded formula (returns "" when no custom library is active).
    func customCacheKeyPrefix() -> String {
        // Namespace whenever ANY custom library is active — a custom fractal OR a
        // custom space warp riding a built-in — so warp-on-built-in pipelines do
        // not collide with the default-library built-in pipelines.
        guard let h = customShaderHash else { return "" }
        return "CX\(h)_"
    }

    /// Returns the library that should resolve fragment / compute functions.
    /// Built-in fractals continue to render through the bundled default library
    /// so their cache stays hot.
    func renderingLibrary() -> MTLLibrary? {
        // Return the active custom library for ANY fractal type: a custom fractal
        // renders its own DE; a built-in with an active space warp renders the
        // built-in DE (present in the superset library) with the warp injected.
        // nil → the bundled default library.
        return customShaderLibrary
    }

    // MARK: - Activation / deactivation

    /// Compiles the supplied formula and installs its library, evicting any
    /// previous custom-formula pipelines. Pass `nil` to deactivate.
    ///
    /// Throws if Metal compilation fails. The renderer continues to function
    /// (built-in fractal types unaffected).
    /// Activate the current EFFECT SET = (custom fractal/warp formula) + (composable
    /// transform stack codegen). Any of the three may be absent. The stack codegen
    /// (`warpStackSource`/`warpStackSignature`) is read from `RenderSettings` by the
    /// caller and baked into the combined hash so distinct stacks compile + cache
    /// distinct libraries. A built-in fractal with a non-empty stack rides a custom
    /// library exactly as a `.threshfx` warp on a built-in does.
    func activateEmbeddedFormula(_ formula: EmbeddedFormula?,
                                 warpStackSource: String? = nil,
                                 warpStackSignature: String = "s0") async throws {

        let isWarp = (formula?.effectKind == .spaceWarp)
        let fractalEffect = isWarp ? nil : formula
        let warpEffect = isWarp ? formula : nil
        let hasEffect = (formula != nil) || (warpStackSource != nil)

        guard hasEffect else {
            // Nothing active (no formula, empty stack) → detach, fall back to the
            // bundled default library. Pipelines stay cached (hash-namespaced, inert).
            if customShaderLibrary != nil {
                resetPipelineFastPaths()
                customShaderLibrary = nil
                customShaderHash = nil
            }
            return
        }

        let newHash = CustomShaderCompiler.combinedHash(fractal: fractalEffect, spaceWarp: warpEffect, warpStackSignature: warpStackSignature)

        // Already active and unchanged — no work (self-heal retries, startup
        // re-activations, and stack slider tweaks that didn't change structure).
        if customShaderHash == newHash, customShaderLibrary != nil {
            return
        }

        // All custom effects share the namespaced cache, so the warm-start gate's
        // geometry key cannot tell two effect sets apart — depth rendered by the
        // outgoing effect must never seed the incoming one's marches.

        // Compile (cached internally by combined hash). While this runs the default
        // library's runtime-loop fallback keeps rendering the current stack.
        let compiler = ensureCompiler()
        let library = try await compiler.library(forFractal: fractalEffect, spaceWarp: warpEffect,
                                                 warpStackSource: warpStackSource, warpStackSignature: warpStackSignature)

        customShaderLibrary = library
        customShaderHash = newHash
        retainCustomShaderPipelines(mostRecentHash: newHash)

    }

    // MARK: - Force recompile (debug)

    /// Debug "Force Recompile": drop every cached pipeline state (built-in +
    /// custom) so they rebuild fresh on the next frames, and recompile the
    /// active custom `.threshfx` library from source. Safe to call mid-render:
    /// the actor serializes this against frame-time pipeline selection, and a
    /// cleared cache falls back to the base `pipelineState` while specialized
    /// variants rebuild lazily (the same path used for cold starts and formula
    /// switches). Returns a short status summary for the UI.
    func forceRecompileShaders() async -> String {
        let renderCount = pipelineCache.count
        let computeCount = computePipelineCache.count

        // Drop all cached pipeline states; next frames rebuild lazily.
        pipelineCache.removeAll()
        computePipelineCache.removeAll()
        recentCustomFormulaHashes.removeAll()
        resetPipelineFastPaths()

        // If a custom formula is active, recompile it from source. Evicting the
        // compiler's library cache and detaching the live library forces
        // `activateEmbeddedFormula` past its no-op guard and re-runs the Metal
        // compiler instead of returning the cached `MTLLibrary`.
        let formula = await MainActor.run { appModel.activeEmbeddedFormula }
        if let formula {
            await ensureCompiler().evictAll()
            customShaderLibrary = nil
            customShaderHash = nil
            do {
                try await activateEmbeddedFormula(formula)
                return "Recompiled '\(formula.name)' and cleared \(renderCount) render / \(computeCount) compute pipelines."
            } catch {
                return "⚠️ Recompile of '\(formula.name)' failed: \(error.localizedDescription)"
            }
        }

        return "Cleared \(renderCount) render / \(computeCount) pipelines — rebuilding on next frames."
    }

    // MARK: - Eviction

    /// How many recent custom formulas keep their specialized pipelines cached.
    /// Keys are namespaced per formula hash (`CX{hash}_`) and frame-time
    /// selection filters to the ACTIVE hash, so retained pipelines are inert
    /// until their formula re-activates — switching back becomes a cache hit
    /// instead of a recompile storm. Pipelines are small (~100-500 KB each),
    /// so four formulas' worth is a few MB at most.
    static let customPipelineRetentionLimit = 4

    /// Record `hash` as the most recently used custom formula and evict
    /// pipelines only for formulas that fall off the MRU list. Replaces the
    /// previous blanket "evict every CX* entry on each switch", which forced
    /// a full recompile every time the user A/B'd two formulas.
    func retainCustomShaderPipelines(mostRecentHash hash: String) {
        recentCustomFormulaHashes.removeAll { $0 == hash }
        recentCustomFormulaHashes.insert(hash, at: 0)
        while recentCustomFormulaHashes.count > Self.customPipelineRetentionLimit {
            let evicted = recentCustomFormulaHashes.removeLast()
            evictCustomShaderPipelines(forHash: evicted)
        }
        resetPipelineFastPaths()
    }

    /// Drop cached pipelines belonging to one specific custom formula.
    func evictCustomShaderPipelines(forHash hash: String) {
        let prefix = "CX\(hash)_"
        var renderEvicted = 0
        var computeEvicted = 0

        for key in pipelineCache.keys.filter({ $0.hasPrefix(prefix) }) {
            pipelineCache.removeValue(forKey: key)
            renderEvicted += 1
        }
        for key in computePipelineCache.keys.filter({ $0.hasPrefix(prefix) }) {
            computePipelineCache.removeValue(forKey: key)
            computeEvicted += 1
        }

    }

    /// Reset the one-entry pipeline fast paths so a stale cached pointer from
    /// the previous formula can't be returned after a switch/deactivation.
    func resetPipelineFastPaths() {
        lastSelectedPipeline = nil
        lastSelectIter = -1
        lastSelectCustomHash = nil
        lastSelectedComputePipeline = nil
        lastComputeFI = -1
        lastComputeCustomHash = nil
    }

    // MARK: - Helpers

    private func ensureCompiler() -> CustomShaderCompiler {
        Renderer.customShaderState.compiler(for: device)
    }

    // MARK: - Storage

    /// Storage holder kept outside the `Renderer` actor's stored-property
    /// declaration so extensions can vend computed accessors. Access is
    /// already serialized by the `Renderer` actor.
    final class CustomShaderState: @unchecked Sendable {
        private let lock = NSLock()
        private var library: MTLLibrary?
        private var hash: String?
        private var compiler: CustomShaderCompiler?

        func currentLibrary() -> MTLLibrary? {
            lock.lock()
            defer { lock.unlock() }
            return library
        }

        func currentHash() -> String? {
            lock.lock()
            defer { lock.unlock() }
            return hash
        }

        func update(library: MTLLibrary?, hash: String?) {
            lock.lock()
            self.library = library
            self.hash = hash
            lock.unlock()
        }

        func compiler(for device: MTLDevice) -> CustomShaderCompiler {
            lock.lock()
            defer { lock.unlock() }
            if let compiler { return compiler }
            let compiler = CustomShaderCompiler(device: device)
            self.compiler = compiler
            return compiler
        }
    }

    /// Single per-process holder. The `Renderer` is the sole owner of the live
    /// instance (one renderer per app), so storing this statically simplifies
    /// the actor isolation while keeping the storage isolated by construction.
    nonisolated(unsafe) static var customShaderState = CustomShaderState()
}
