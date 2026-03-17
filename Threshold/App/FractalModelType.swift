//
//  FractalModelType.swift
//  Threshold
//
//  Fractal type enum matching ShaderTypes.h FractalType enum
//

import Foundation
import simd

enum FractalModelType: Int32, CaseIterable {
    case mandelbox         = 0
    case mandelbulb        = 1
    case menger            = 2
    case sierpinski        = 3
    case dodecahedron      = 4
    case quaternionJulia   = 6
    case sphereSponge      = 10
    case octahedron        = 11
    case mengerSphere      = 14
    case theliPseudoKleinian = 15
    case kleinian              = 17
    case boxSphereFolder         = 20
    
    /// Descriptor from the registry — all metadata is defined there.
    var descriptor: FractalTypeDescriptor { FractalTypeRegistry.descriptor(for: self) }

    var displayName: String { descriptor.displayName }
    
    var supportedCoreGestureActions: [FingerGestureAction] { descriptor.supportedCoreGestureActions }
    var icon: String { descriptor.icon }
    var category: String { descriptor.category }
    var supportedEffectTags: Set<EffectTag> { descriptor.supportedEffectTags }

    /// Quick check whether a given effect tag is meaningful for this fractal.
    func supports(_ tag: EffectTag) -> Bool { descriptor.supportedEffectTags.contains(tag) }

    func defaultFormulaParams() -> FormulaParams { descriptor.defaultFormulaParams() }
}

extension FractalModelType {
    /// Types shown in the UI picker (descriptor.isSelectableInUI == true).
    static let selectableCases: [FractalModelType] = allCases.filter { $0.descriptor.isSelectableInUI }
}

// MARK: - Human-Readable Codable

extension FractalModelType: Codable {
    private var codableString: String { descriptor.codableString }

    /// Maps removed/renamed fractal type strings to their replacements.
    private static let legacyStringMap: [String: FractalModelType] = [
        "apollonianGasket": .theliPseudoKleinian,
        "apollonianLight": .theliPseudoKleinian,
        "amazingSurface": .mandelbox,
        "pseudoKnightyan": .mandelbox,
        "mandalayBox": .mandelbox,
        "icosahedron": .dodecahedron,
        "surfaceKIFS": .mengerSphere,
    ]

    /// Maps removed raw Int32 values to their replacements.
    private static let legacyRawMap: [Int32: FractalModelType] = [
        5: .theliPseudoKleinian,   // pseudoKleinian
        7: .mandelbox,             // amazingSurface
        8: .mandelbox,             // pseudoKnightyan
        9: .mandelbox,             // mandalayBox
        12: .dodecahedron,         // icosahedron
        13: .mengerSphere,         // surfaceKIFS
        16: .theliPseudoKleinian,  // old apollonian
    ]

    private static let stringMap: [String: FractalModelType] = {
        var map: [String: FractalModelType] = [:]
        for c in FractalModelType.allCases { map[c.codableString] = c }
        return map
    }()

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let str = try? container.decode(String.self) {
            if let value = Self.stringMap[str] {
                self = value
                return
            }
            if let legacy = Self.legacyStringMap[str] {
                self = legacy
                return
            }
        }
        if let raw = try? container.decode(Int32.self) {
            if let value = FractalModelType(rawValue: raw) {
                self = value
                return
            }
            if let legacy = Self.legacyRawMap[raw] {
                self = legacy
                return
            }
        }
        throw DecodingError.dataCorruptedError(
            in: container, debugDescription: "Invalid FractalModelType value")
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(codableString)
    }
}
