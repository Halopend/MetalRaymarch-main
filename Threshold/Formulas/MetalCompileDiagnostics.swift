//
//  MetalCompileDiagnostics.swift
//  Threshold
//
//  Maps Metal runtime-compile logs back to lines of the user's formula
//  source. `device.makeLibrary(source:)` reports positions in the SYNTHESIZED
//  source (`program_source:LINE:COL: severity: message`), whose first ~5,000
//  lines are the concatenated engine scaffolding. The editor records where the
//  user's source was spliced in (`CustomShaderCompiler.fractalUserSourceStartLine`)
//  and this parser rebases each diagnostic into user coordinates; positions
//  outside the user range keep `userLine == nil` ("in generated scaffolding").
//

import Foundation

/// One diagnostic from a Metal compile log, rebased to user-source lines.
struct MetalCompileDiagnostic: Equatable, Sendable {
    enum Severity: String, Equatable, Sendable {
        case error
        case warning
        case note
    }

    /// 1-based line in the USER's formula source, or nil when the position
    /// falls outside the spliced range (an error in the surrounding
    /// scaffolding — usually a knock-on from the user's code, e.g. a missing
    /// function the dispatch arm references).
    var userLine: Int?
    var column: Int?
    var severity: Severity
    var message: String
    /// The unmodified log line, for the disclosure/detail view.
    var rawLine: String
}

enum MetalCompileLogParser {

    /// Extract `program_source:LINE:COL: severity: message` diagnostics from a
    /// Metal compile log and rebase them into user-source coordinates.
    ///
    /// - Parameters:
    ///   - log: the full compiler output (survives inside the thrown
    ///     `NSError.localizedDescription` on macOS/visionOS/iOS).
    ///   - userSourceStartLine: 1-based line in the synthesized source where
    ///     the user's source begins.
    ///   - userSourceLineCount: number of lines in the user's source.
    static func parse(log: String,
                      userSourceStartLine: Int,
                      userSourceLineCount: Int) -> [MetalCompileDiagnostic] {
        var diagnostics: [MetalCompileDiagnostic] = []

        for rawLine in log.components(separatedBy: "\n") {
            guard let match = rawLine.firstMatch(
                of: /program_source:(\d+):(\d+):\s+(error|warning|note):\s*(.*)/
            ) else { continue }

            guard let metalLine = Int(match.1), let column = Int(match.2),
                  let severity = MetalCompileDiagnostic.Severity(rawValue: String(match.3))
            else { continue }

            let rebased = metalLine - userSourceStartLine + 1
            let userLine = (rebased >= 1 && rebased <= userSourceLineCount) ? rebased : nil

            diagnostics.append(MetalCompileDiagnostic(
                userLine: userLine,
                column: column,
                severity: severity,
                message: String(match.4),
                rawLine: rawLine
            ))
        }

        return diagnostics
    }

    /// Convenience: the first user-anchored error, else the first error of any
    /// kind — what a status pill shows when there's room for one line.
    static func primaryError(in diagnostics: [MetalCompileDiagnostic]) -> MetalCompileDiagnostic? {
        diagnostics.first { $0.severity == .error && $0.userLine != nil }
            ?? diagnostics.first { $0.severity == .error }
    }
}
