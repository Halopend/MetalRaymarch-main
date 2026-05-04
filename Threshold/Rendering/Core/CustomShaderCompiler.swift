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
//  generated `EmbeddedMetalSources` enum (refresh via `Scripts/generate_metal_embeds.sh`).
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
            return "Embedded shader template is missing dispatch marker '\(m)'. Run Scripts/generate_metal_embeds.sh."
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
/// `library(for:)` and forwards them to `RendererPipelineCache` on the main
/// renderer queue.
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
            EmbeddedMetalSources.boxSphereFolderH,
            EmbeddedMetalSources.mandelboxSphereProjectionH,
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
    func library(for formula: EmbeddedFormula) throws -> MTLLibrary {
        let key = formula.sourceHash
        if let cached = libraryCache[key] {
            return cached
        }
        let source = try Self.synthesizeSource(for: formula)
        let options = MTLCompileOptions()
        if #available(visionOS 2.0, *) {
            options.mathMode = .fast
        } else {
            options.fastMathEnabled = true
        }

        do {
            let lib = try device.makeLibrary(source: source, options: options)
            libraryCache[key] = lib
            return lib
        } catch {
            let detail = (error as NSError).localizedDescription
            throw CustomShaderCompilerError.metalCompileFailed(
                formula: formula.name,
                detail: detail
            )
        }
    }

    /// Drop a previously-compiled library (for example when its source hash is
    /// no longer referenced). Currently used for cache eviction on formula switch.
    func evict(sourceHash: String) {
        libraryCache.removeValue(forKey: sourceHash)
    }

    /// Drop every cached library. Called when the active formula changes and the
    /// renderer wants to bound memory growth.
    func evictAll() {
        libraryCache.removeAll(keepingCapacity: false)
    }

    // MARK: - Source synthesis

    /// Stitch the user's DE source into the bundled Metal sources to produce a
    /// self-contained string suitable for `device.makeLibrary(source:)`.
    static func synthesizeSource(for formula: EmbeddedFormula) throws -> String {
        var pieces: [String] = []
        pieces.reserveCapacity(7)

        pieces.append("// === Custom DE shader (auto-synthesized at runtime) ===")
        pieces.append("// Embedded formula: \(formula.id) — \(formula.name)")
        pieces.append("// sourceHash = \(formula.shortHash)")
        pieces.append(Self.synthesizedSourcePrefix)

        // User's DE source — defines DE_<stem> + DE_<stem>_Dist. Wrapped in a
        // banner so any compile error includes a clear marker in the diagnostic
        // line numbering.
        pieces.append("// === Embedded user formula source — '\(formula.id)' ===")
        pieces.append(formula.metalSource)
        pieces.append("// === End embedded user formula source ===")

        // FractalFormulas.h with the custom dispatch arms injected.
        let dispatchH = try injectCustomDispatch(
            Self.strippedDispatchTemplate,
            stem: formula.functionStem
        )
        pieces.append(dispatchH)

        // Render kernels + helpers.
        pieces.append(Self.synthesizedSourceSuffix)

        return pieces.joined(separator: "\n\n")
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
