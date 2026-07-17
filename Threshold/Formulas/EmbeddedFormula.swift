//
//  EmbeddedFormula.swift
//  Threshold
//
//  Portable distance-estimator payload that can ship inside .threshfx, .threshanim,
//  or .threshscene files. Carries Metal source for both DE variants
//  (DE_<stem> + DE_<stem>_Dist) plus catalog-style parameter metadata.
//
//  The renderer compiles the embedded source at runtime into a separate MTLLibrary
//  and treats the formula as FractalModelType.custom for dispatch & cache keying.
//

import CryptoKit
import Foundation

// MARK: - Container (for standalone .threshfx files)

/// File-level wrapper for a `.threshfx` document. Versioned so the schema can evolve.
struct EmbeddedFormulaContainer: Codable, Equatable {
    /// Schema version of the container format (current = 1).
    let version: Int
    /// The formula payload.
    var formula: EmbeddedFormula

    static let currentVersion: Int = 1

    init(formula: EmbeddedFormula, version: Int = EmbeddedFormulaContainer.currentVersion) {
        self.version = version
        self.formula = formula
    }
}

// MARK: - Effect kind

/// What kind of GPU effect an embedded payload carries. The format is otherwise
/// identical (`.threshfx`); only the required Metal functions + the compiler's
/// injection point differ. Stored as an OPTIONAL on `EmbeddedFormula` so old files
/// (no key) decode to nil → treated as `.fractal` (full backward compatibility).
enum EffectKind: String, Codable, Equatable, Sendable {
    /// A fractal distance estimator: defines `DE_<stem>` + `DE_<stem>_Dist`,
    /// injected at the dispatch markers; rides `FractalModelType.custom`.
    case fractal
    /// A space-domain warp: defines `customSpaceWarp` + `customSpaceWarpDEScale`,
    /// injected at `// __CUSTOM_SPACE_WARP__`; applies to any fractal.
    case spaceWarp
}

// MARK: - Embedded formula payload

/// A self-contained fractal distance estimator: Metal source + parameter metadata.
///
/// The same payload is embedded inside `.threshfx`, `.threshanim`, and `.threshscene`
/// files under the shared `embeddedFormula` JSON key. When loaded, the renderer:
///   1. Validates the source (length, regex, forbidden tokens).
///   2. Registers an ephemeral entry in `FormulaCatalog` keyed to `FractalModelType.custom`.
///   3. Synthesizes a Metal source that wraps the embedded DE in the standard render
///      kernels and compiles a separate MTLLibrary keyed by `sourceHash`.
struct EmbeddedFormula: Codable, Equatable {

    /// Two embedded formulas are considered equal when their `id` and
    /// `sourceHash` (SHA-256 of stem + Metal source) match. We avoid synthesized
    /// Equatable because `FormulaParamDescriptor` does not (yet) conform.
    static func == (lhs: EmbeddedFormula, rhs: EmbeddedFormula) -> Bool {
        lhs.id == rhs.id && lhs.sourceHash == rhs.sourceHash
    }

    // MARK: Schema

    /// Schema version. Lets future fields land without breaking older readers.
    var schemaVersion: Int

    /// Effect kind. Optional so old files (no key) decode to nil; use `effectKind`
    /// to read the resolved value (nil → `.fractal`).
    var kind: EffectKind?

    /// Resolved effect kind (defaults to `.fractal` for legacy payloads).
    var effectKind: EffectKind { kind ?? .fractal }

    /// Stable identifier (e.g. `"user.boxFold01"`). Must be unique within a session.
    var id: String

    /// Author-facing display name (e.g. `"Box Fold 01"`). Used in pickers.
    var name: String

    /// Optional grouping name shown alongside built-in categories. Defaults to "Custom".
    var category: String?

    /// Optional author / mathematician / artist credit.
    var author: String?

    /// Optional long-form description shown in info popovers.
    var formulaDescription: String?

    /// Bare function-name stem. The Metal source MUST define both
    /// `DE_<functionStem>` (orbit-tracking variant) and `DE_<functionStem>_Dist`
    /// (lean distance-only variant).
    /// Validated against `[A-Za-z_][A-Za-z0-9_]*`.
    var functionStem: String

    /// Metal source body for the distance estimator (the contents of a `.h` file).
    /// Must define both DE variants and may rely on declarations from
    /// `FractalFormulaCommon.h` (which is prepended automatically at compile time).
    var metalSource: String

    /// Catalog-style parameter metadata (reuses `FormulaParamDescriptor`).
    /// Indexes must be in 0...15 and unique.
    var params: [FormulaParamDescriptor]

    /// Optional default iteration count for new keyframes/presets.
    var defaultIterations: Int?

    /// Optional default color-iteration count.
    var defaultColorIterations: Int?

    /// Effect tags to surface in UI (raw `EffectTag.rawValue` strings).
    /// When omitted a baseline set is used. Stored raw so unknown tags from a future
    /// app version don't break decoding.
    var supportedEffectTagsRaw: [String]?

    // MARK: Derived

    /// SHA-256 of `functionStem | metalSource`. Used as the pipeline-cache key prefix
    /// and as the on-disk metallib filename.
    var sourceHash: String {
        var hasher = SHA256()
        hasher.update(data: Data(functionStem.utf8))
        hasher.update(data: Data("|".utf8))
        hasher.update(data: Data(metalSource.utf8))
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// First 12 hex chars of `sourceHash` — used in cache keys for readability.
    var shortHash: String {
        let h = sourceHash
        return String(h.prefix(12))
    }

    /// Built-in construction primitives are shipped as embedded formulas so a
    /// scene remains self-contained, but unlike imported `.threshfx` files they
    /// are trusted app content and do not require the experimental-import flag.
    var bundledConstructionPrimitiveKind: FractalPrimitiveKind? {
        let prefix = "com.puppypower.threshold.primitive."
        guard id.hasPrefix(prefix),
              let kind = FractalPrimitiveKind(rawValue: String(id.dropFirst(prefix.count))),
              self == kind.formula else { return nil }
        return kind
    }

    var isBundledConstructionPrimitive: Bool {
        bundledConstructionPrimitiveKind != nil
    }

    // MARK: Codable

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case kind
        case id
        case name
        case category
        case author
        case formulaDescription = "description"
        case functionStem
        case metalSource
        case params
        case defaultIterations
        case defaultColorIterations
        case supportedEffectTagsRaw = "supportedEffectTags"
    }

    init(
        schemaVersion: Int = 1,
        kind: EffectKind? = nil,
        id: String,
        name: String,
        category: String? = nil,
        author: String? = nil,
        formulaDescription: String? = nil,
        functionStem: String,
        metalSource: String,
        params: [FormulaParamDescriptor],
        defaultIterations: Int? = nil,
        defaultColorIterations: Int? = nil,
        supportedEffectTagsRaw: [String]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.kind = kind
        self.id = id
        self.name = name
        self.category = category
        self.author = author
        self.formulaDescription = formulaDescription
        self.functionStem = functionStem
        self.metalSource = metalSource
        self.params = params
        self.defaultIterations = defaultIterations
        self.defaultColorIterations = defaultColorIterations
        self.supportedEffectTagsRaw = supportedEffectTagsRaw
    }
}

// MARK: - Bundled construction primitives

/// Small analytic SDFs used as the seed geometry for the Transformations editor.
/// They deliberately use the same EmbeddedFormula contract as imported `.threshfx`
/// content, so saving a scene embeds the selected primitive and its attribution.
/// Current builds render these through the precompiled construction-primitive
/// type; the source payload keeps the scene portable to builds that only know
/// the runtime custom-formula contract.
enum FractalPrimitiveKind: String, CaseIterable, Identifiable {
    case sphere
    case box
    case torus
    case octahedron
    case mandelboxSeed

    var id: String { rawValue }

    var name: String {
        switch self {
        case .sphere: return "Sphere"
        case .box: return "Box"
        case .torus: return "Torus"
        case .octahedron: return "Octahedron"
        case .mandelboxSeed: return "Mandelbox Seed"
        }
    }

    var icon: String {
        switch self {
        case .sphere, .mandelboxSeed: return "circle.fill"
        case .box: return "cube.fill"
        case .torus: return "circle.dashed"
        case .octahedron: return "diamond.fill"
        }
    }

    /// Parameters consumed by the statically compiled construction-primitive
    /// shader. Keeping this separate from the portable embedded formula lets
    /// iPad render trusted primitives without runtime-compiling all Shaders.metal.
    var bundledFormulaParams: FormulaParams {
        var fp = FractalTypeDescriptor.baseFormulaParams()
        switch self {
        case .sphere:
            fp.params.0 = 0; fp.params.1 = 1.0; fp.params.2 = 0.0
        case .box:
            fp.params.0 = 1; fp.params.1 = 1.0; fp.params.2 = 0.0
        case .torus:
            fp.params.0 = 2; fp.params.1 = 1.0; fp.params.2 = 0.25
        case .octahedron:
            fp.params.0 = 3; fp.params.1 = 1.0; fp.params.2 = 0.0
        case .mandelboxSeed:
            fp.params.0 = 4; fp.params.1 = 2.5; fp.params.2 = 0.0
        }
        FormulaCatalog.normalizeRotationFlags(&fp)
        return fp
    }

    var formula: EmbeddedFormula {
        let stem: String
        let description: String
        let params: [FormulaParamDescriptor]
        let helper: String

        switch self {
        case .sphere:
            stem = "PrimitiveSphere"
            description = "Analytic sphere seed for building forms with the transformation stack."
            params = [Self.param(0, "Radius", 1.0, 0.05, 4.0, 0.05)]
            helper = """
            FORCE_INLINE float primitiveDistance(float3 p, FormulaParams fp) {
                return length(p) - max(fp.params[0], 0.001f);
            }
            """
        case .box:
            stem = "PrimitiveBox"
            description = "Analytic rounded-box seed for building forms with the transformation stack."
            params = [
                Self.param(0, "Half Size", 1.0, 0.05, 4.0, 0.05),
                Self.param(1, "Roundness", 0.0, 0.0, 1.0, 0.01)
            ]
            helper = """
            FORCE_INLINE float primitiveDistance(float3 p, FormulaParams fp) {
                float size = max(fp.params[0], 0.001f);
                float roundness = max(fp.params[1], 0.0f);
                float3 q = abs(p) - float3(size - roundness);
                return length(max(q, 0.0f)) + min(max(q.x, max(q.y, q.z)), 0.0f) - roundness;
            }
            """
        case .torus:
            stem = "PrimitiveTorus"
            description = "Analytic torus seed for building forms with the transformation stack."
            params = [
                Self.param(0, "Major Radius", 1.0, 0.05, 4.0, 0.05),
                Self.param(1, "Tube Radius", 0.25, 0.02, 2.0, 0.02)
            ]
            helper = """
            FORCE_INLINE float primitiveDistance(float3 p, FormulaParams fp) {
                float2 q = float2(length(p.xz) - max(fp.params[0], 0.001f), p.y);
                return length(q) - max(fp.params[1], 0.001f);
            }
            """
        case .octahedron:
            stem = "PrimitiveOctahedron"
            description = "Analytic octahedron seed for building forms with the transformation stack."
            params = [Self.param(0, "Size", 1.0, 0.05, 4.0, 0.05)]
            helper = """
            FORCE_INLINE float primitiveDistance(float3 p, FormulaParams fp) {
                return (abs(p.x) + abs(p.y) + abs(p.z) - max(fp.params[0], 0.001f)) * 0.57735026919f;
            }
            """
        case .mandelboxSeed:
            stem = "MandelboxConstructionSeed"
            description = "The terminal sphere used by the classic Mandelbox distance estimator. Repeat Mandelbox Step transformations to build the recurrence."
            params = [Self.param(0, "Terminal Radius", 2.5, 0.05, 6.0, 0.05)]
            helper = """
            FORCE_INLINE float primitiveDistance(float3 p, FormulaParams fp) {
                return length(p) - max(fp.params[0], 0.001f);
            }
            """
        }

        return EmbeddedFormula(
            kind: .fractal,
            id: "com.puppypower.threshold.primitive.\(rawValue)",
            name: name,
            category: "Primitives",
            author: "Threshold",
            formulaDescription: description,
            functionStem: stem,
            metalSource: Self.metalSource(stem: stem, helper: helper),
            params: params,
            defaultIterations: 1,
            defaultColorIterations: 1,
            supportedEffectTagsRaw: []
        )
    }

    private static func param(_ index: Int, _ name: String, _ value: Float,
                              _ min: Float, _ max: Float, _ step: Float) -> FormulaParamDescriptor {
        FormulaParamDescriptor(index: index, name: name, default: value,
                               min: min, max: max, step: step)
    }

    private static func metalSource(stem: String, helper: String) -> String {
        """
        // Threshold bundled construction primitive. This source is embedded in
        // saved scenes so the primitive remains portable as a custom fractal type.
        \(helper)

        FORCE_INLINE float DE_\(stem)(float3 pos, FormulaParams fp, float3x3 rot,
                                      int iterations, int colorIterations,
                                      thread OrbitData& orbit) {
            (void)iterations; (void)colorIterations;
            float3 p = hasRot1Precomputed(fp) ? (rot * pos) : pos;
            float d = primitiveDistance(p, fp);
            orbit.trap = dot(p, p);
            orbit.trapIteration = 0;
            orbit.trapPosition = p;
            orbit.finalP = p;
            orbit.iterationsUsed = 1;
            return d;
        }

        FORCE_INLINE float DE_\(stem)_Dist(float3 pos, FormulaParams fp,
                                           float3x3 rot, int iterations) {
            (void)iterations;
            float3 p = hasRot1Precomputed(fp) ? (rot * pos) : pos;
            return primitiveDistance(p, fp);
        }
        """
    }
}

// MARK: - Validation

extension EmbeddedFormula {

    /// Reasons an embedded formula payload may be rejected before compilation.
    enum ValidationError: Error, Equatable, CustomStringConvertible {
        case unsupportedSchemaVersion(Int)
        case emptyId
        case invalidFunctionStem(String)
        case emptyMetalSource
        case metalSourceTooLong(Int)
        case forbiddenToken(String)
        case missingFunctionDefinition(String)
        case duplicateParamIndex(Int)
        case paramIndexOutOfRange(Int)

        var description: String {
            switch self {
            case .unsupportedSchemaVersion(let v):
                return "Embedded formula schema version \(v) is not supported by this build."
            case .emptyId:
                return "Embedded formula is missing an id."
            case .invalidFunctionStem(let stem):
                return "Embedded formula function stem '\(stem)' is invalid (must match [A-Za-z_][A-Za-z0-9_]*)."
            case .emptyMetalSource:
                return "Embedded formula has empty Metal source."
            case .metalSourceTooLong(let n):
                return "Embedded formula Metal source is too long (\(n) bytes; max \(EmbeddedFormula.maxSourceBytes))."
            case .forbiddenToken(let tok):
                return "Embedded formula contains forbidden token '\(tok)'."
            case .missingFunctionDefinition(let name):
                return "Embedded formula source does not appear to define '\(name)'."
            case .duplicateParamIndex(let i):
                return "Embedded formula has duplicate parameter index \(i)."
            case .paramIndexOutOfRange(let i):
                return "Embedded formula parameter index \(i) is out of range (must be 0...15)."
            }
        }
    }

    /// Maximum permitted size of `metalSource` in bytes (UTF-8). Keeps scene files
    /// reasonable and bounds compile time.
    static let maxSourceBytes: Int = 64 * 1024

    /// Tokens that must not appear anywhere in `metalSource`. These would let the
    /// embedded payload pull in arbitrary headers or files at compile time, which
    /// defeats the validation we do up-front.
    static let forbiddenTokens: [String] = [
        "#import",
        "#include",
        "@import"
    ]

    /// Validates the payload. Throws on first failure.
    func validate() throws {
        guard schemaVersion <= EmbeddedFormulaContainer.currentVersion else {
            throw ValidationError.unsupportedSchemaVersion(schemaVersion)
        }
        guard !id.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ValidationError.emptyId
        }
        try Self.validateFunctionStem(functionStem)

        let trimmed = metalSource.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ValidationError.emptyMetalSource
        }
        let byteCount = metalSource.utf8.count
        guard byteCount <= Self.maxSourceBytes else {
            throw ValidationError.metalSourceTooLong(byteCount)
        }
        for token in Self.forbiddenTokens where metalSource.contains(token) {
            throw ValidationError.forbiddenToken(token)
        }

        // Cheap text check — confirm the kind's required functions appear by name.
        let requiredFunctions: [String]
        switch effectKind {
        case .fractal:
            requiredFunctions = ["DE_\(functionStem)", "DE_\(functionStem)_Dist"]
        case .spaceWarp:
            // Bare names: the compiler's `#define THRESHOLD_CUSTOM_SPACE_WARP`
            // skips the built-in defaults, so there is no symbol collision.
            requiredFunctions = ["customSpaceWarp", "customSpaceWarpDEScale"]
        }
        for fn in requiredFunctions where !Self.containsFunctionDefinition(in: metalSource, named: fn) {
            throw ValidationError.missingFunctionDefinition(fn)
        }

        // Parameter index bounds + uniqueness.
        var seen = Set<Int>()
        for p in params {
            guard p.index >= 0 && p.index < 16 else {
                throw ValidationError.paramIndexOutOfRange(p.index)
            }
            if !seen.insert(p.index).inserted {
                throw ValidationError.duplicateParamIndex(p.index)
            }
        }
    }

    private static func validateFunctionStem(_ stem: String) throws {
        guard !stem.isEmpty else {
            throw ValidationError.invalidFunctionStem(stem)
        }
        let firstScalar = stem.unicodeScalars.first!
        let isFirstValid = firstScalar.isASCII &&
            (CharacterSet.letters.contains(firstScalar) || firstScalar == "_")
        guard isFirstValid else {
            throw ValidationError.invalidFunctionStem(stem)
        }
        for scalar in stem.unicodeScalars.dropFirst() {
            let ok = scalar.isASCII &&
                (CharacterSet.alphanumerics.contains(scalar) || scalar == "_")
            guard ok else {
                throw ValidationError.invalidFunctionStem(stem)
            }
        }
    }

    private static func containsFunctionDefinition(in source: String, named name: String) -> Bool {
        let escapedName = NSRegularExpression.escapedPattern(for: name)
        let pattern = "(?m)^\\s*(?:[A-Za-z_][A-Za-z0-9_]*\\s+)+" + escapedName + "\\s*\\("
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return source.contains(name)
        }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return regex.firstMatch(in: source, options: [], range: range) != nil
    }
}

// MARK: - File I/O helpers

extension EmbeddedFormulaContainer {

    /// Decodes a `.threshfx` container from disk, validating the formula payload.
    static func decode(fromContainerAt url: URL) throws -> EmbeddedFormulaContainer {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        // Defensive: matches PresetManager.decodePreset / AnimationManager so a
        // future Date field on the formula wouldn't silently break .threshfx
        // imports. Harmless today (the container has no Date fields).
        decoder.dateDecodingStrategy = .iso8601
        let container = try decoder.decode(EmbeddedFormulaContainer.self, from: data)
        try container.formula.validate()
        return container
    }

    /// Encodes this container to JSON data with stable, sorted keys for diff-friendly output.
    func encode() throws -> Data {
        try formula.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// Writes this container to a shareable `.threshfx` file in the temp
    /// directory. Call off the main actor (see `exportOffMain`) — validate +
    /// encode + write blocks for the file's size.
    func exportToFile() -> URL? {
        let fileName = "\(PresetManager.sanitizedExportFileNameStem(formula.name)).\(ThresholdExportFormat.customFormula.ext)"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        do {
            try encode().write(to: url)
            return url
        } catch {
            print("Failed to export formula: \(error)")
            return nil
        }
    }
}
