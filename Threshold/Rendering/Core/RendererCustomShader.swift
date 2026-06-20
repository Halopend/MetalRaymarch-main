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
            let formula = await MainActor.run { self.appModel.activeEmbeddedFormula }
            if let formula {
                do {
                    try await self.activateEmbeddedFormula(formula)
                    print("🔧 [CustomScene] Self-heal: recompiled '\(formula.name)' after a frame requested it with no library installed")
                } catch {
                    print("❌ [CustomScene] Self-heal activation failed for '\(formula.name)': \(error)")
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
    /// embedded formula (returns "" when no custom library is active or when
    /// the supplied fractal type isn't `.custom`).
    func customCacheKeyPrefix(for fractalType: FractalModelType) -> String {
        guard fractalType == .custom, let h = customShaderHash else { return "" }
        return "CX\(h)_"
    }

    /// Returns the library that should resolve fragment / compute functions for
    /// the supplied fractal type. Built-in fractals continue to render through
    /// the bundled default library so their cache stays hot.
    func renderingLibrary(for fractalType: FractalModelType) -> MTLLibrary? {
        if fractalType == .custom { return customShaderLibrary }
        return nil
    }

    // MARK: - Activation / deactivation

    /// Compiles the supplied formula and installs its library, evicting any
    /// previous custom-formula pipelines. Pass `nil` to deactivate.
    ///
    /// Throws if Metal compilation fails. The renderer continues to function
    /// (built-in fractal types unaffected).
    func activateEmbeddedFormula(_ formula: EmbeddedFormula?) async throws {
        customSceneDiagnostic("🔬 [CSDiag] activateEmbeddedFormula ENTRY formula=\(formula?.name ?? "nil") newHash=\(formula?.shortHash ?? "nil") currentHash=\(customShaderHash ?? "nil") libraryPresent=\(customShaderLibrary != nil)")
        guard let formula else {
            // Deactivate. Pipelines stay cached (keys are hash-namespaced and
            // inert while inactive) — preview/restore flows often bring the
            // same formula straight back.
            if customShaderLibrary != nil {
                customSceneDiagnostic("🔬 [CSDiag] activateEmbeddedFormula DEACTIVATE — library detached, pipelines retained")
                warmStartGate.invalidate()
                resetPipelineFastPaths()
                customShaderLibrary = nil
                customShaderHash = nil
            }
            return
        }

        // Already active and unchanged — no work (and no warm-start cut:
        // self-heal retries and startup re-activations land here).
        if customShaderHash == formula.shortHash, customShaderLibrary != nil {
            customSceneDiagnostic("🔬 [CSDiag] activateEmbeddedFormula NO-OP (hash unchanged + library present)")
            return
        }

        // All custom formulas share FractalTypeCustom, so the warm-start gate's
        // geometry key cannot tell two .threshfx DEs apart — depth rendered by
        // the outgoing formula must never seed the incoming one's marches.
        warmStartGate.invalidate()

        // Compile (cached internally by sourceHash).
        customSceneDiagnostic("🔬 [CSDiag] activateEmbeddedFormula compiling library…")
        let compiler = ensureCompiler()
        let library = try await compiler.library(for: formula)

        customShaderLibrary = library
        customShaderHash = formula.shortHash
        retainCustomShaderPipelines(mostRecentHash: formula.shortHash)

        customSceneDiagnostic("🔬 [CSDiag] ✅ activateEmbeddedFormula INSTALLED '\(formula.name)' hash=\(formula.shortHash) — library now present")
        if RENDERER_DEBUG {
            print("🧪 [CustomShader] Activated '\(formula.name)' (hash=\(formula.shortHash))")
        }
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

        if RENDERER_DEBUG && (renderEvicted + computeEvicted) > 0 {
            print("🧹 [CustomShader] Evicted \(renderEvicted) render + \(computeEvicted) compute pipelines for \(hash)")
        }
        customSceneDiagnostic("🔬 [CSDiag] evictCustomShaderPipelines(forHash: \(hash)) render=\(renderEvicted) compute=\(computeEvicted)")
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
