//
//  FormulaSourcePragmas.swift
//  Threshold
//
//  Parameter declarations parsed straight out of custom-formula Metal source,
//  so the live editor can regenerate the slider UI on every keystroke without
//  waiting for a compile. Pragmas are ordinary Metal line comments:
//
//      // @param 0 "Scale" default=2.0 min=0.5 max=4.0 step=0.01
//      // @param 3 "Julia Mode" default=0 min=0 max=1 bool
//
//  They survive round-trips inside `EmbeddedFormula.metalSource` unchanged,
//  are invisible to the Metal compiler and to older app versions, and are
//  serialized into the `.threshfx` `params` array on save so every existing
//  consumer (catalog registration, node batches, music targets, QuickLook)
//  works without schema changes.
//
//  Values NEVER flow through pragmas at render time — they declare UI only.
//  All parameter values ride the per-frame formulaParams[16] uniforms, so the
//  instant-parse UI and the debounced background compile can disagree for
//  seconds with zero rendering breakage (the SpaceWarpStackCodegen post-mortem
//  invariant).
//

import Foundation

/// One message anchored to a 1-based line of the user's formula source.
struct FormulaPragmaDiagnostic: Equatable, Sendable {
    enum Severity: Equatable, Sendable {
        case warning
        case error
    }

    var line: Int
    var severity: Severity
    var message: String
}

/// Result of scanning a formula source for `// @param` pragmas.
/// (Not Equatable: `FormulaParamDescriptor` deliberately has no synthesized
/// equality — see EmbeddedFormula's hand-written `==`.)
struct FormulaPragmaParseResult {
    /// Parsed declarations, sorted by index (deterministic ordinal so music
    /// bindings keyed by filtered position cannot silently re-point when the
    /// author reorders pragma lines).
    var params: [FormulaParamDescriptor]
    var diagnostics: [FormulaPragmaDiagnostic]
    /// True when at least one line attempted a `@param` pragma — the signal
    /// that pragmas (not a legacy JSON params array) are the source of truth.
    var hasPragmas: Bool
}

/// How `DE_<stem>` / `DE_<stem>_Dist` derivation went.
enum FormulaStemDerivation: Equatable {
    case derived(String)
    /// No stem defines both required functions.
    case missing
    /// More than one stem defines both; the author must disambiguate.
    case ambiguous([String])

    var stem: String? {
        if case .derived(let stem) = self { return stem }
        return nil
    }
}

enum FormulaPragmaParser {

    static let maxParamIndex = 15

    // MARK: - Parsing

    /// Scan `source` line by line for `// @param` pragmas. Malformed lines
    /// produce diagnostics, never crashes; well-formed params on other lines
    /// are unaffected.
    static func parse(_ source: String) -> FormulaPragmaParseResult {
        var params: [Int: FormulaParamDescriptor] = [:]
        var diagnostics: [FormulaPragmaDiagnostic] = []
        var hasPragmas = false

        let lines = source.components(separatedBy: "\n")
        for (offset, rawLine) in lines.enumerated() {
            let lineNumber = offset + 1
            guard let body = pragmaBody(of: rawLine) else { continue }
            hasPragmas = true

            switch parsePragmaBody(body) {
            case .success(var descriptor, let warnings):
                for warning in warnings {
                    diagnostics.append(.init(line: lineNumber, severity: .warning, message: warning))
                }
                if params[descriptor.index] != nil {
                    diagnostics.append(.init(
                        line: lineNumber, severity: .error,
                        message: "Duplicate @param index \(descriptor.index); this line is ignored."))
                    continue
                }
                if descriptor.default < descriptor.min || descriptor.default > descriptor.max {
                    diagnostics.append(.init(
                        line: lineNumber, severity: .warning,
                        message: "default=\(format(descriptor.default)) is outside min…max; clamped."))
                    descriptor = FormulaParamDescriptor(
                        index: descriptor.index, name: descriptor.name,
                        default: Swift.min(Swift.max(descriptor.default, descriptor.min), descriptor.max),
                        min: descriptor.min, max: descriptor.max, step: descriptor.step,
                        isBool: descriptor.isBool, isHidden: descriptor.isHidden)
                }
                params[descriptor.index] = descriptor
            case .failure(let message):
                diagnostics.append(.init(line: lineNumber, severity: .error, message: message))
            }
        }

        return FormulaPragmaParseResult(
            params: params.values.sorted { $0.index < $1.index },
            diagnostics: diagnostics,
            hasPragmas: hasPragmas
        )
    }

    /// Returns the text after `// @param` when the line is a pragma attempt.
    private static func pragmaBody(of line: String) -> Substring? {
        var trimmed = Substring(line)
        while let first = trimmed.first, first == " " || first == "\t" {
            trimmed = trimmed.dropFirst()
        }
        guard trimmed.hasPrefix("//") else { return nil }
        var comment = trimmed.dropFirst(2)
        while let first = comment.first, first == " " || first == "\t" {
            comment = comment.dropFirst()
        }
        guard comment.hasPrefix("@param") else { return nil }
        return comment.dropFirst("@param".count)
    }

    private enum PragmaBodyResult {
        case success(FormulaParamDescriptor, warnings: [String])
        case failure(String)
    }

    private static func parsePragmaBody(_ body: Substring) -> PragmaBodyResult {
        var scanner = body[...]

        func skipWhitespace() {
            while let first = scanner.first, first == " " || first == "\t" {
                scanner = scanner.dropFirst()
            }
        }

        // <index>
        skipWhitespace()
        var indexText = ""
        while let first = scanner.first, first.isNumber {
            indexText.append(first)
            scanner = scanner.dropFirst()
        }
        guard let index = Int(indexText) else {
            return .failure(#"Expected a parameter index after @param, e.g. // @param 0 "Name" default=1 min=0 max=2"#)
        }
        guard index >= 0, index <= maxParamIndex else {
            return .failure("Parameter index \(index) is out of range 0…\(maxParamIndex).")
        }

        // "<Display Name>"
        skipWhitespace()
        guard scanner.first == "\"" else {
            return .failure("Expected a double-quoted display name after the index.")
        }
        scanner = scanner.dropFirst()
        var name = ""
        while let first = scanner.first, first != "\"" {
            name.append(first)
            scanner = scanner.dropFirst()
        }
        guard scanner.first == "\"" else {
            return .failure("Unterminated display name — missing closing quote.")
        }
        scanner = scanner.dropFirst()
        guard !name.isEmpty else {
            return .failure("The display name must not be empty.")
        }

        // key=value pairs and flags, any order.
        var defaultValue: Float?
        var minValue: Float?
        var maxValue: Float?
        var stepValue: Float?
        var isBool = false
        var isHidden = false
        var warnings: [String] = []

        while true {
            skipWhitespace()
            guard let first = scanner.first else { break }
            guard first.isLetter else {
                return .failure("Unexpected text “\(scanner.prefix(12))…” — expected key=value pairs or the bool/hidden flags.")
            }
            var token = ""
            while let ch = scanner.first, ch.isLetter || ch.isNumber || ch == "_" {
                token.append(ch)
                scanner = scanner.dropFirst()
            }
            if scanner.first == "=" {
                scanner = scanner.dropFirst()
                var valueText = ""
                while let ch = scanner.first, ch != " ", ch != "\t" {
                    valueText.append(ch)
                    scanner = scanner.dropFirst()
                }
                switch token {
                case "default", "min", "max", "step":
                    guard let value = Float(valueText), value.isFinite else {
                        return .failure("\(token)=\(valueText) is not a finite number.")
                    }
                    switch token {
                    case "default": defaultValue = value
                    case "min": minValue = value
                    case "max": maxValue = value
                    default: stepValue = value
                    }
                default:
                    // Unknown keys warn and are skipped — their value need
                    // not be numeric (a future `curve=log` must not brick
                    // the whole pragma on older app versions).
                    warnings.append("Unknown key “\(token)” ignored.")
                }
            } else {
                switch token {
                case "bool": isBool = true
                case "hidden": isHidden = true
                default:
                    warnings.append("Unknown flag “\(token)” ignored.")
                }
            }
        }

        guard let defaultValue else { return .failure("Missing default=<value>.") }
        guard let minValue else { return .failure("Missing min=<value>.") }
        guard let maxValue else { return .failure("Missing max=<value>.") }
        guard minValue < maxValue else {
            return .failure("min must be strictly less than max (got min=\(format(minValue)) max=\(format(maxValue))).")
        }
        if let stepValue, stepValue <= 0 {
            return .failure("step must be positive.")
        }

        let descriptor = FormulaParamDescriptor(
            index: index,
            name: name,
            default: defaultValue,
            min: minValue,
            max: maxValue,
            step: stepValue ?? defaultStep(min: minValue, max: maxValue),
            isBool: isBool ? true : nil,
            isHidden: isHidden ? true : nil
        )
        return .success(descriptor, warnings: warnings)
    }

    /// ~200 increments across the range, snapped to a 1-2-5 series so the
    /// step reads as a human number (0.01, 0.02, 0.05, …).
    static func defaultStep(min: Float, max: Float) -> Float {
        let raw = (max - min) / 200
        guard raw > 0, raw.isFinite else { return 0.01 }
        let exponent = floor(log10(raw))
        let magnitude = pow(10, exponent)
        let mantissa = raw / magnitude
        let snapped: Float = mantissa < 1.5 ? 1 : (mantissa < 3.5 ? 2 : 5)
        return snapped * magnitude
    }

    // MARK: - Function stem derivation

    /// Derive the `functionStem` from the source: the unique `X` for which
    /// both `DE_X` and `DE_X_Dist` appear. Removes a whole class of "stem
    /// doesn't match the functions" user error.
    static func deriveFunctionStem(from source: String) -> FormulaStemDerivation {
        var tokens: Set<String> = []
        let scalars = Array(source.unicodeScalars)
        var i = 0
        while i < scalars.count {
            // Find "DE_" at a non-identifier boundary.
            if scalars[i] == "D",
               i + 2 < scalars.count,
               scalars[i + 1] == "E", scalars[i + 2] == "_",
               (i == 0 || !isIdentifierScalar(scalars[i - 1])) {
                var j = i + 3
                var body = ""
                while j < scalars.count, isIdentifierScalar(scalars[j]) {
                    body.unicodeScalars.append(scalars[j])
                    j += 1
                }
                if !body.isEmpty {
                    tokens.insert(body)
                }
                i = j
            } else {
                i += 1
            }
        }

        let stems = tokens
            .filter { !$0.hasSuffix("_Dist") && tokens.contains("\($0)_Dist") }
            .sorted()
        switch stems.count {
        case 0: return .missing
        case 1: return .derived(stems[0])
        default: return .ambiguous(stems)
        }
    }

    private static func isIdentifierScalar(_ scalar: Unicode.Scalar) -> Bool {
        (scalar >= "a" && scalar <= "z") || (scalar >= "A" && scalar <= "Z")
            || (scalar >= "0" && scalar <= "9") || scalar == "_"
    }

    // MARK: - Serialization

    /// Render a params array back into pragma lines — used to seed the editor
    /// when opening a legacy `.threshfx` whose params live only in JSON.
    static func pragmaLines(for params: [FormulaParamDescriptor]) -> String {
        params
            .sorted { $0.index < $1.index }
            .map { param in
                var line = "// @param \(param.index) \"\(param.name)\""
                line += " default=\(format(param.default))"
                line += " min=\(format(param.min))"
                line += " max=\(format(param.max))"
                line += " step=\(format(param.step))"
                if param.isBool == true { line += " bool" }
                if param.isHidden == true { line += " hidden" }
                return line
            }
            .joined(separator: "\n")
    }

    private static func format(_ value: Float) -> String {
        String(format: "%g", value)
    }
}
