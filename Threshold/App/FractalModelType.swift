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
    
    var displayName: String {
        switch self {
        case .mandelbox:       return "Mandelbox"
        case .mandelbulb:      return "Mandelbulb"
        case .menger:          return "Menger Sponge"
        case .sierpinski:      return "Sierpinski"
        case .dodecahedron:    return "Dodecahedron"
        case .quaternionJulia: return "Quaternion Julia"
        case .sphereSponge:    return "Sphere Sponge"
        case .octahedron:      return "Octahedron"
        case .mengerSphere:    return "Menger Sphere"
        case .theliPseudoKleinian: return "Theli Pseudo Kleinian"
        case .kleinian:            return "Kleinian"
        }
    }
    
    /// Core gesture actions that are meaningful for this fractal type.
    /// Mandelbox keeps the legacy shape-param actions (.minDistance, .foldingLimit,
    /// .sphereRadius) so existing gesture bindings serialise correctly; they are
    /// routed to the formula-param dispatcher at runtime.
    /// All types get .fractalScale since the Scale slider is universal.
    var supportedCoreGestureActions: [FingerGestureAction] {
        switch self {
        case .mandelbox:
            return [.none, .grab, .minDistance, .foldingLimit, .sphereRadius, .fractalScale, .translate]
        default:
            return [.none, .grab, .fractalScale, .translate]
        }
    }

    /// Icon name for UI
    var icon: String {
        switch self {
        case .mandelbox:       return "cube.transparent"
        case .mandelbulb:      return "globe"
        case .menger:          return "square.grid.3x3"
        case .sierpinski:      return "triangle"
        case .dodecahedron:    return "pentagon"
        case .quaternionJulia: return "atom"
        case .sphereSponge:    return "circle.grid.3x3"
        case .octahedron:      return "diamond"
        case .mengerSphere:    return "circle.grid.cross"
        case .theliPseudoKleinian: return "cube"
        case .kleinian:            return "wand.and.stars"
        }
    }
    
    /// Category for grouping in UI
    var category: String {
        switch self {
        case .mandelbox:
            return "Box Folds"
        case .mandelbulb, .quaternionJulia:
            return "Power / Quaternion"
        case .menger, .sierpinski, .dodecahedron, .octahedron, .mengerSphere:
            return "Kaleidoscopic IFS"
        case .sphereSponge, .theliPseudoKleinian, .kleinian:
            return "Julia Box"
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // EFFECT TAGS — Associates effects with compatible fractal types.
    // Universal effects (hue, pulse, glow, bloom, fog, gradientCycle) apply to
    // every fractal. Geometry-specific effects like polarRotation are restricted.
    // ═══════════════════════════════════════════════════════════════════════════

    /// The set of universal effect tags shared by all fractal types.
    private static let universalTags: Set<EffectTag> = [
        .hueRotation, .pulse, .glow, .bloom, .fog, .gradientCycle
    ]

    /// Effects this fractal type supports. UI should hide cards for unsupported tags.
    var supportedEffectTags: Set<EffectTag> {
        switch self {
        case .mandelbulb, .quaternionJulia:
            return Self.universalTags.union([.polarRotation])
        default:
            return Self.universalTags
        }
    }

    /// Quick check whether a given effect tag is meaningful for this fractal.
    func supports(_ tag: EffectTag) -> Bool {
        supportedEffectTags.contains(tag)
    }
    
    /// Build default FormulaParams for non-Mandelbox types
    func defaultFormulaParams() -> FormulaParams {
        var fp = FormulaParams()
        fp.rotMatrix1 = matrix_identity_float3x3
        fp.rotMatrix2 = matrix_identity_float3x3
        // Zero-init params tuple
        fp.params = (0,0,0,0, 0,0,0,0, 0,0,0,0, 0,0,0,0)
        
        switch self {
        case .mandelbulb:
            // Power=8, Bailout=4, DerivBias=1, Alternate=0, PolarRot=0, PolarRot2=0
            fp.params.0 = 8.0; fp.params.1 = 4.0; fp.params.2 = 1.0
        case .menger:
            // Scale=3, Offset=(1,1,1)
            fp.params.0 = 3.0; fp.params.1 = 1.0; fp.params.2 = 1.0; fp.params.3 = 1.0
        case .sierpinski:
            // Scale=2, Offset=(1,1,1)
            fp.params.0 = 2.0; fp.params.1 = 1.0; fp.params.2 = 1.0; fp.params.3 = 1.0
        case .dodecahedron:
            // Scale=2, Phi=1.618, Log10Bailout=2
            fp.params.0 = 2.0; fp.params.1 = 1.618; fp.params.2 = 2.0
        case .quaternionJulia:
            // C=(-0.2,0.8,0,0), Threshold=10
            fp.params.0 = -0.2; fp.params.1 = 0.8; fp.params.4 = 10.0
        case .sphereSponge:
            // Scale=2, BubbleSize=3
            fp.params.0 = 2.0; fp.params.1 = 3.0
        case .octahedron:
            // Scale=2, Offset=(1,0,0)
            fp.params.0 = 2.0; fp.params.1 = 1.0
        case .mengerSphere:
            // Scale=3, Offset=(1,1,1), Spherify=0
            fp.params.0 = 3.0; fp.params.1 = 1.0; fp.params.2 = 1.0; fp.params.3 = 1.0
        case .theliPseudoKleinian:
            // Size=1, CSize=(1,1,1), C=(0,0,0), DEoffset=0, Offset=(0,0,0),
            // MnIterations=2, MnScale=3, MnOffset=(1,1,1)
            fp.params.0 = 1.0
            fp.params.1 = 1.0; fp.params.2 = 1.0; fp.params.3 = 1.0
            fp.params.7 = 0.0
            fp.params.11 = 2.0
            fp.params.12 = 3.0
            fp.params.13 = 1.0; fp.params.14 = 1.0; fp.params.15 = 1.0
        case .mandelbox:
            // Min Distance=0.8, Folding Limit=1.0, Sphere Radius=0.5
            fp.params.0 = 0.8; fp.params.1 = 1.0; fp.params.2 = 0.5
        case .kleinian:
            // Mins=(-0.3252,-0.7862,-0.0948), SphFold=0.69,
            // Maxs=(0.35,1.0,1.22), CrossR=0.84, ColorOfs=0.25, ColorScale=1.0
            fp.params.0 = -0.3252; fp.params.1 = -0.7862; fp.params.2 = -0.0948
            fp.params.3 = 0.69
            fp.params.4 = 0.35; fp.params.5 = 1.0; fp.params.6 = 1.22
            fp.params.7 = 0.84
            fp.params.8 = 0.25; fp.params.9 = 1.0
        }

        FormulaCatalog.normalizeRotationFlags(&fp)
        
        return fp
    }
}

extension FractalModelType {
    /// Types shown in the UI picker. theliPseudoKleinian is hidden.
    static var selectableCases: [FractalModelType] {
        allCases.filter { $0 != .theliPseudoKleinian }
    }
}

// MARK: - Human-Readable Codable

extension FractalModelType: Codable {
    private var codableString: String {
        switch self {
        case .mandelbox:       return "mandelbox"
        case .mandelbulb:      return "mandelbulb"
        case .menger:          return "menger"
        case .sierpinski:      return "sierpinski"
        case .dodecahedron:    return "dodecahedron"
        case .quaternionJulia: return "quaternionJulia"
        case .sphereSponge:    return "sphereSponge"
        case .octahedron:      return "octahedron"
        case .mengerSphere:    return "mengerSphere"
        case .theliPseudoKleinian: return "theliPseudoKleinian"
        case .kleinian:            return "kleinian"
        }
    }

    /// Maps removed/renamed fractal type strings to their replacements.
    private static let legacyStringMap: [String: FractalModelType] = [
        "apollonianGasket": .theliPseudoKleinian,
        "apollonianLight": .theliPseudoKleinian,
        "pseudoKleinian": .theliPseudoKleinian,
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
        18: .kleinian,             // future alias
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
