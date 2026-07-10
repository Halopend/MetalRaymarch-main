//
//  CustomShaderCompiler.swift
//  Threshold
//
//  Runtime Metal compiler for embedded `.threshfx` distance estimators.
//
//  Strategy
//  --------
//  Apple's `MTLDevice.makeLibrary(source:)` cannot resolve `#include "..."` for
//  bundled headers. To produce a self-contained Metal source we concatenate every
//  header that the static build relies on (`ShaderTypes.h`, `FractalFormulaCommon.h`,
//  every per-formula header, and `Shaders.metal`) — these source bodies live in the
//  build-generated `EmbeddedMetalSources` enum.
//  The user's DE source from `EmbeddedFormula.metalSource` is spliced in before
//  `FractalFormulas.h`, and the dispatch switches gain a `case FractalTypeCustom`
//  arm via the marker comments `// __CUSTOM_DISPATCH_DIST__` and
//  `// __CUSTOM_DISPATCH_ORBIT__`.
//
//  Compiled libraries are cached in-memory by `EmbeddedFormula.sourceHash`, so
//  switching back to a previously-loaded `.threshfx` is free.
//

import Foundation
@preconcurrency import Metal

/// Errors that can occur while compiling an embedded formula.
enum CustomShaderCompilerError: Error, CustomStringConvertible {
    case missingDispatchMarker(String)
    case metalCompileFailed(formula: String, detail: String)
    case libraryUnavailable

    var description: String {
        switch self {
        case .missingDispatchMarker(let m):
            return "Embedded shader template is missing dispatch marker '\(m)'. Verify the Generate Metal Embeds build phase."
        case .metalCompileFailed(let name, let detail):
            return "Custom shader '\(name)' failed to compile: \(detail)"
        case .libraryUnavailable:
            return "Custom shader library is unavailable (compiler not initialised)."
        }
    }
}

/// Compiles `EmbeddedFormula` payloads into runnable `MTLLibrary` instances.
///
/// Thread safety: this is an `actor`, so all cache access is serialized on the
/// compiler's executor. The owning `Renderer` actor obtains libraries via
/// `library(forFractal:spaceWarp:)` and forwards them to `RendererPipelineCache`
/// on the main renderer queue.
actor CustomShaderCompiler {

    private static let shaderFormulaIncludeMarker = "#include \"../Formulas/FractalFormulas.h\""

    private static let shaderSections: (preamble: String, body: String) = {
        let source = EmbeddedMetalSources.shadersMetal
        guard let includeRange = source.range(of: shaderFormulaIncludeMarker) else {
            return (stripLocalIncludes(source), "")
        }

        let preamble = String(source[..<includeRange.lowerBound])
        var bodyStart = includeRange.upperBound
        if bodyStart < source.endIndex, source[bodyStart] == "\r" {
            bodyStart = source.index(after: bodyStart)
        }
        if bodyStart < source.endIndex, source[bodyStart] == "\n" {
            bodyStart = source.index(after: bodyStart)
        }
        let body = String(source[bodyStart...])
        return (stripLocalIncludes(preamble), stripLocalIncludes(body))
    }()

    private static let synthesizedSourcePrefix: String = {
        var pieces: [String] = []
        pieces.reserveCapacity(15)

        // Standard prelude. Header guards in metal_stdlib / simd already protect
        // against the duplicate include emitted later by Shaders.metal's preamble.
        pieces.append("#include <metal_stdlib>")
        pieces.append("#include <simd/simd.h>")
        pieces.append("using namespace metal;")

        // Shader macros + function constants must come before built-in formula
        // headers because those headers reference FORCE_INLINE and FC_* values.
        pieces.append(shaderSections.preamble)

        // Type declarations + helpers.
        pieces.append(stripLocalIncludes(EmbeddedMetalSources.shaderTypesH))
        pieces.append(stripLocalIncludes(EmbeddedMetalSources.fractalFormulaCommonH))

        // Built-in formula headers — Shaders.metal still references their dispatch
        // arms even though only the custom case runs on this pipeline.
        let builtIns: [String] = [
            EmbeddedMetalSources.mandelbulbH,
            EmbeddedMetalSources.mengerH,
            EmbeddedMetalSources.quaternionJuliaH,
            EmbeddedMetalSources.octahedronH,
            EmbeddedMetalSources.mengerSphereH,
            EmbeddedMetalSources.theliPseudoKleinianH,
            EmbeddedMetalSources.kleinianH,
        ]
        for body in builtIns {
            pieces.append(stripLocalIncludes(body))
        }

        return pieces.joined(separator: "\n\n")
    }()

    private static let strippedDispatchTemplate = stripLocalIncludes(EmbeddedMetalSources.fractalFormulasH)
    private static let synthesizedSourceSuffix = shaderSections.body

    private let device: MTLDevice
    private var libraryCache: [String: MTLLibrary] = [:]

    init(device: MTLDevice) {
        self.device = device
    }

    // MARK: - Public API

    /// Returns a compiled `MTLLibrary` for the given formula, building on cache miss.
    /// The library exposes the same fragment/compute/vertex entry points as the
    /// bundled `default.metallib` — function-constant specialization for `FI`/`RS`/etc.
    /// continues to work via `library.makeFunction(name:constantValues:)`.
    /// Stable cache key for an effect set (fractal + space warp). Distinct from a
    /// single formula's `sourceHash`, so old and combined entries never collide.
    /// `warpStackSignature` is RETIRED (warp codegen was removed; the stack renders
    /// via the bundled count-driven runtime loop). It is now always "s0", kept only
    /// so the cache key shape is unchanged for the custom-FORMULA path.
    static func combinedHash(fractal: EmbeddedFormula?, spaceWarp: EmbeddedFormula?,
                             warpStackSignature: String = "s0") -> String {
        "f\(fractal?.shortHash ?? "0")w\(spaceWarp?.shortHash ?? "0")\(warpStackSignature)"
    }

    /// Compile (or return cached) the combined library for an effect set.
    ///
    /// Compilation goes through Metal's **async** completion-handler API rather
    /// than the synchronous `makeLibrary(source:)`. The synchronous variant
    /// blocks the calling thread for the entire front-end + back-end compile,
    /// which for the large combined source (full Shaders.metal scaffolding + the
    /// embedded DE) can run for seconds on Apple Silicon. Inside this `actor`
    /// that thread is a Swift cooperative-pool thread; starving the pool on
    /// visionOS makes the app miss the compositor's frame deadline and the
    /// system kills it with no Swift trace. This bites precisely on a *fresh*
    /// custom-shader activation — e.g. opening a `.threshscene`/`.threshfx` from
    /// Finder — because an already-active formula is a cache hit that never
    /// recompiles (which is why the currently-loaded scene appears to "work"
    /// while every other custom scene crashes on external load). The async API
    /// hands the work to Metal's own compile queue and suspends the actor,
    /// freeing the cooperative thread so frames keep flowing.
    func library(forFractal fractal: EmbeddedFormula?, spaceWarp: EmbeddedFormula?,
                 warpStackSource: String? = nil, warpStackSignature: String = "s0") async throws -> MTLLibrary {
        let key = Self.combinedHash(fractal: fractal, spaceWarp: spaceWarp, warpStackSignature: warpStackSignature)
        if let cached = libraryCache[key] {
            return cached
        }
        let source = try Self.synthesizeSource(fractal: fractal, spaceWarp: spaceWarp, warpStackSource: warpStackSource)
        let options = MTLCompileOptions()
        if #available(visionOS 2.0, *) {
            options.mathMode = .fast
        } else {
            options.fastMathEnabled = true
        }

        let device = self.device
        let formulaName = fractal?.name ?? spaceWarp?.name ?? "effect"
        do {
            let lib: MTLLibrary = try await withCheckedThrowingContinuation { continuation in
                // The completion handler runs on a Metal-owned thread, not this
                // actor's executor; it only resumes the continuation, so it
                // touches no actor-isolated state.
                device.makeLibrary(source: source, options: options) { library, error in
                    if let library {
                        continuation.resume(returning: library)
                    } else {
                        continuation.resume(throwing: error ?? CustomShaderCompilerError.metalCompileFailed(
                            formula: formulaName,
                            detail: "Metal returned no library and no error."
                        ))
                    }
                }
            }
            libraryCache[key] = lib
            return lib
        } catch let error as CustomShaderCompilerError {
            throw error
        } catch {
            throw CustomShaderCompilerError.metalCompileFailed(
                formula: formulaName,
                detail: (error as NSError).localizedDescription
            )
        }
    }

    /// Drop every cached library so the next `library(...)` call recompiles from
    /// source. Used by the debug "Force Recompile" action — re-activating a
    /// formula otherwise returns the cached `MTLLibrary` and never re-runs the
    /// Metal compiler.
    func evictAll() {
        libraryCache.removeAll()
    }

    // MARK: - Source synthesis

    /// Stitch the user's DE source into the bundled Metal sources to produce a
    /// self-contained string suitable for `device.makeLibrary(source:)`.
    /// Stitch the active effect SET into one self-contained Metal source. A custom
    /// fractal DE is injected at the dispatch markers; a custom space warp is
    /// injected at `// __CUSTOM_SPACE_WARP__`. Either may be nil (the corresponding
    /// markers keep their built-in defaults).
    static func synthesizeSource(fractal: EmbeddedFormula?, spaceWarp: EmbeddedFormula?,
                                 warpStackSource: String? = nil) throws -> String {
        var pieces: [String] = []
        pieces.reserveCapacity(9)

        pieces.append("// === Custom effect shader (auto-synthesized at runtime) ===")
        if let fractal { pieces.append("// Fractal: \(fractal.id) — \(fractal.name) [\(fractal.shortHash)]") }
        if let spaceWarp { pieces.append("// Space warp: \(spaceWarp.id) — \(spaceWarp.name) [\(spaceWarp.shortHash)]") }
        pieces.append(Self.synthesizedSourcePrefix)

        // Custom fractal DE source — defines DE_<stem> + DE_<stem>_Dist.
        if let fractal {
            pieces.append("// === Embedded fractal source — '\(fractal.id)' ===")
            pieces.append(fractal.metalSource)
            pieces.append("// === End embedded fractal source ===")
        }

        // FractalFormulas.h: inject the custom dispatch arm only when a fractal is
        // present; otherwise the markers stay as comments (FractalTypeCustom → far).
        let dispatchH: String
        if let fractal {
            dispatchH = try injectCustomDispatch(Self.strippedDispatchTemplate, stem: fractal.functionStem)
        } else {
            dispatchH = Self.strippedDispatchTemplate
        }
        pieces.append(dispatchH)

        // Render kernels + helpers (Shaders.metal body) — inject the space warp at
        // its marker when present (replaces the built-in Twist default).
        var suffix = Self.synthesizedSourceSuffix
        if let spaceWarp {
            suffix = try injectCustomSpaceWarp(suffix, warpSource: spaceWarp.metalSource)
        }
        // Composable transform stack codegen — unrolled, type-dispatched
        // spaceWarpStackApply/DEScale. A custom .threshfx warp (above) takes
        // precedence (it #defines THRESHOLD_CUSTOM_SPACE_WARP so applySpaceWarp
        // never calls the stack), so injecting both is harmless.
        if let warpStackSource {
            suffix = try injectSpaceWarpStack(suffix, generated: warpStackSource)
        }
        pieces.append(suffix)

        return pieces.joined(separator: "\n\n")
    }

    /// Replace the `// __SPACEWARP_STACK_CODEGEN__` marker with the generated
    /// unrolled stack (which begins with `#define THRESHOLD_CODEGEN_SPACEWARP_STACK`
    /// to suppress the bundled runtime-loop defaults guarded by the matching
    /// `#ifndef`).
    static func injectSpaceWarpStack(_ src: String, generated: String) throws -> String {
        let marker = "// __SPACEWARP_STACK_CODEGEN__"
        guard src.contains(marker) else { throw CustomShaderCompilerError.missingDispatchMarker(marker) }
        let replacement = """
        // __SPACEWARP_STACK_CODEGEN__ (codegen stack injected)
        \(generated)
        """
        return src.replacingOccurrences(of: marker, with: replacement)
    }

    /// Replace the `// __CUSTOM_SPACE_WARP__` marker with the plugin's warp source,
    /// preceded by `#define THRESHOLD_CUSTOM_SPACE_WARP` so the built-in default
    /// definitions (guarded by `#ifndef THRESHOLD_CUSTOM_SPACE_WARP`) are skipped —
    /// no duplicate-symbol collision.
    static func injectCustomSpaceWarp(_ src: String, warpSource: String) throws -> String {
        let marker = "// __CUSTOM_SPACE_WARP__"
        guard src.contains(marker) else { throw CustomShaderCompilerError.missingDispatchMarker(marker) }
        let replacement = """
        // __CUSTOM_SPACE_WARP__ (custom space warp injected)
        #define THRESHOLD_CUSTOM_SPACE_WARP
        // === Embedded space-warp source ===
        \(warpSource)
        // === End embedded space-warp source ===
        """
        return src.replacingOccurrences(of: marker, with: replacement)
    }

    /// Remove `#include "..."` and `#import "..."` directives that reference
    /// headers we've already concatenated into the source string. Angle-bracket
    /// system includes (`<metal_stdlib>`, `<simd/simd.h>`) are kept.
    static func stripLocalIncludes(_ src: String) -> String {
        var out: [Substring] = []
        out.reserveCapacity(src.count / 40 + 1)
        for line in src.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            if trimmed.hasPrefix(#"#include ""#) || trimmed.hasPrefix(#"#import ""#) {
                continue
            }
            out.append(line)
        }
        return out.joined(separator: "\n")
    }

    /// Inject `case FractalTypeCustom: return DE_<stem>...` arms into both
    /// dispatch switches by replacing the `// __CUSTOM_DISPATCH_*__` markers
    /// embedded in `FractalFormulas.h`.
    static func injectCustomDispatch(_ src: String, stem: String) throws -> String {
        let distMarker  = "// __CUSTOM_DISPATCH_DIST__"
        let orbitMarker = "// __CUSTOM_DISPATCH_ORBIT__"

        guard src.contains(distMarker)  else { throw CustomShaderCompilerError.missingDispatchMarker(distMarker) }
        guard src.contains(orbitMarker) else { throw CustomShaderCompilerError.missingDispatchMarker(orbitMarker) }

        let distArm = """
            case FractalTypeCustom:
                return DE_\(stem)_Dist(pos, fp, fp.rotMatrix1, iterations);
        """
        let orbitArm = """
            case FractalTypeCustom:
                return DE_\(stem)(pos, fp, fp.rotMatrix1, iterations, colorIterations, orbit);
        """

        return src
            .replacingOccurrences(of: distMarker,  with: distArm)
            .replacingOccurrences(of: orbitMarker, with: orbitArm)
    }
}
