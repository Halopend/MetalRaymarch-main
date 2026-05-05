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

    // MARK: Codable

    enum CodingKeys: String, CodingKey {
        case schemaVersion
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

        // Cheap text check — confirm both DE variants appear by name.
        let fullName = "DE_\(functionStem)"
        let distName = "DE_\(functionStem)_Dist"
        if !Self.containsFunctionDefinition(in: metalSource, named: fullName) {
            throw ValidationError.missingFunctionDefinition(fullName)
        }
        if !Self.containsFunctionDefinition(in: metalSource, named: distName) {
            throw ValidationError.missingFunctionDefinition(distName)
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
        let container = try JSONDecoder().decode(EmbeddedFormulaContainer.self, from: data)
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
}
