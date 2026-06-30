//
//  AffineCoxeterGroup.swift
//  Threshold
//
//  Parser + catalog for the NAMED affine (Euclidean) Coxeter groups — the symmetry
//  groups of regular tessellations of n-dimensional Euclidean space. Affine groups
//  sit between the finite (spherical) Coxeter groups and the hyperbolic ones: their
//  Gram matrix is positive SEMI-definite, and that degeneracy is exactly what
//  introduces the TRANSLATIONS that tile space — vs a finite group's point-symmetric
//  rosette (the existing rank-3 spherical Coxeter fold, see SpaceWarpStackModel).
//
//  This file is STAGE 1: pure metadata (name → tilde → Coxeter symbol → acting
//  dimension → renderability). It is deliberately geometry-free — the mirror set +
//  offset fold is Stage 2 and must be verified visually on-device, because affine
//  geometry fails SILENTLY (a B̃-vs-C̃ length swap still tiles, just wrongly).
//
//  Renderability: X̃ₙ tiles R^n, and the renderer folds a 3D point, so only n ≤ 3 is
//  renderable. Higher groups (F̃₄, Ẽ₆₋₈, X̃ₙ≥₄) parse but are flagged non-renderable.
//

import Foundation

/// One named affine Coxeter group, resolved from user text.
struct AffineCoxeterGroup: Equatable {
    let family: Character   // A B C D E F G
    let rank: Int           // the subscript n in X̃ₙ — also the acting Euclidean dimension
    let tilde: String       // display form, e.g. "C̃₃"
    let coxeterSymbol: String   // bracket notation, e.g. "[4,3,4]" ("—" if not catalogued)
    let summary: String     // human description, e.g. "Cubic honeycomb"

    /// Euclidean dimension the group tiles (= rank). Only ≤ 3 folds a 3D point.
    var actingDim: Int { rank }
    var renderable: Bool { rank <= 3 }
}

enum AffineParseResult: Equatable {
    case ok(AffineCoxeterGroup)             // valid AND renderable (acts on ≤ 3D)
    case notRenderable(AffineCoxeterGroup)  // valid but acts on > 3D
    case invalid(String)                    // unparseable / not a real affine group
}

enum AffineCoxeter {
    /// Subscript-digit → ASCII, so "C̃₃" and "C3~" both parse.
    private static let subscriptDigits: [Character: Character] = [
        "₀": "0", "₁": "1", "₂": "2", "₃": "3", "₄": "4",
        "₅": "5", "₆": "6", "₇": "7", "₈": "8", "₉": "9",
    ]

    /// Catalogued symbol + summary for the small renderable groups. Keyed "F<n>".
    /// Non-catalogued (higher) groups get a generic symbol/summary.
    private static let known: [String: (symbol: String, summary: String)] = [
        "A1": ("[∞]",     "Apeirogon — two parallel mirrors (1-D strips)"),
        "A2": ("[3⁽³⁾]",  "Triangular tiling *333"),
        "C2": ("[4,4]",   "Square tiling *442"),
        "G2": ("[6,3]",   "Hexagonal tiling *632"),
        "A3": ("[3⁽⁴⁾]",  "Tetrahedral–octahedral honeycomb"),
        "B3": ("[4,3¹⋅¹]", "Alternated cubic honeycomb symmetry"),
        "C3": ("[4,3,4]", "Cubic honeycomb"),
    ]

    /// Parse a named affine group: "C3~", "c3", "C̃₃", "G2~" → result. The tilde is
    /// optional (these are always the affine extension). B₂/D₃ alias to C₂/A₃.
    static func parse(_ raw: String) -> AffineParseResult {
        // Normalise: drop whitespace + tildes, fold subscript digits, uppercase.
        var s = ""
        for ch in raw.trimmingCharacters(in: .whitespacesAndNewlines) {
            if ch == "~" || ch == "\u{0303}" || ch == "̃" { continue }   // ascii ~ + combining tilde
            s.append(subscriptDigits[ch] ?? ch)
        }
        s = s.uppercased()
        guard let fam = s.first, "ABCDEFG".contains(fam) else {
            return .invalid("Use a named affine group like C3~, G2~, A2~, F4~.")
        }
        let digits = s.dropFirst()
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber), let n = Int(digits) else {
            return .invalid("Missing rank — e.g. C3~ (the 3 is the dimension it tiles).")
        }

        // Per-family validity + low-rank aliases (B₂≡C₂, D₃≡A₃, D₂≡A₁×A₁).
        var family = fam
        let rank = n
        switch fam {
        case "A": guard n >= 1 else { return .invalid("Ãₙ needs n ≥ 1.") }
        case "B":
            if n == 2 { family = "C" }                       // B̃₂ ≡ C̃₂
            else { guard n >= 3 else { return .invalid("B̃ₙ needs n ≥ 3.") } }
        case "C": guard n >= 2 else { return .invalid("C̃ₙ needs n ≥ 2.") }
        case "D":
            if n == 3 { family = "A" }                        // D̃₃ ≡ Ã₃
            else { guard n >= 4 else { return .invalid("D̃ₙ needs n ≥ 4.") } }
        case "E": guard (6...8).contains(n) else { return .invalid("Ẽₙ only exists for n = 6, 7, 8.") }
        case "F": guard n == 4 else { return .invalid("F̃₄ is the only F affine group.") }
        case "G": guard n == 2 else { return .invalid("G̃₂ is the only G affine group.") }
        default:  return .invalid("Unknown family \(fam).")
        }

        let key = "\(family)\(rank)"
        let cat = known[key]
        let group = AffineCoxeterGroup(
            family: family, rank: rank,
            tilde: "\(family)\u{0303}\(subscriptString(rank))",
            coxeterSymbol: cat?.symbol ?? "—",
            summary: cat?.summary ?? "Affine \(family)\u{0303}\(subscriptString(rank)) — tiles \(rank)-D Euclidean space")
        return group.renderable ? .ok(group) : .notRenderable(group)
    }

    /// Int → unicode subscript ("3" → "₃") for display.
    static func subscriptString(_ n: Int) -> String {
        let map: [Character: Character] = [
            "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄",
            "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
        ]
        return String(String(n).map { map[$0] ?? $0 })
    }
}
