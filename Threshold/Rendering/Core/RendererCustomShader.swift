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

extension Renderer {

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

    nonisolated static func activateEmbeddedFormulaDirect(device: MTLDevice, formula: EmbeddedFormula?) async throws {
        guard let formula else {
            customShaderState.update(library: nil, hash: nil)
            return
        }

        if customShaderState.currentHash() == formula.shortHash,
           customShaderState.currentLibrary() != nil {
            return
        }

        let compiler = customShaderState.compiler(for: device)
        let library = try await compiler.library(for: formula)
        customShaderState.update(library: library, hash: formula.shortHash)
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
        guard let formula else {
            // Deactivate.
            if customShaderLibrary != nil {
                evictCustomShaderPipelines()
                customShaderLibrary = nil
                customShaderHash = nil
            }
            return
        }

        // Already active and unchanged — no work.
        if customShaderHash == formula.shortHash, customShaderLibrary != nil {
            return
        }

        // Compile (cached internally by sourceHash).
        let compiler = ensureCompiler()
        let library = try await compiler.library(for: formula)

        evictCustomShaderPipelines()
        customShaderLibrary = library
        customShaderHash = formula.shortHash

        if RENDERER_DEBUG {
            print("🧪 [CustomShader] Activated '\(formula.name)' (hash=\(formula.shortHash))")
        }
    }

    // MARK: - Eviction

    /// Drop every cached pipeline whose key starts with the `CX` prefix. Called
    /// when the active custom shader changes or is removed.
    func evictCustomShaderPipelines() {
        var renderEvicted = 0
        var computeEvicted = 0

        let renderKeys = pipelineCache.keys.filter { $0.hasPrefix("CX") }
        for key in renderKeys {
            pipelineCache.removeValue(forKey: key)
            renderEvicted += 1
        }
        let computeKeys = computePipelineCache.keys.filter { $0.hasPrefix("CX") }
        for key in computeKeys {
            computePipelineCache.removeValue(forKey: key)
            computeEvicted += 1
        }

        // Reset fast-path so a stale cached pointer doesn't get returned.
        lastSelectedPipeline = nil
        lastSelectIter = -1
        lastSelectCustomHash = nil
        lastSelectedComputePipeline = nil
        lastComputeFI = -1
        lastComputeCustomHash = nil

        if RENDERER_DEBUG && (renderEvicted + computeEvicted) > 0 {
            print("🧹 [CustomShader] Evicted \(renderEvicted) render + \(computeEvicted) compute pipelines")
        }
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
