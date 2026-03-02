//
//  FractalModelType.swift
//  Threshold
//
//  Fractal type enum matching ShaderTypes.h FractalType enum (15 values)
//

import Foundation
import simd

enum FractalModelType: Int32, CaseIterable {
    case mandelbox         = 0
    case mandelbulb        = 1
    case menger            = 2
    case sierpinski        = 3
    case dodecahedron      = 4
    case pseudoKleinian    = 5
    case quaternionJulia   = 6
    case amazingSurface    = 7
    case pseudoKnightyan   = 8
    case mandalayBox       = 9
    case sphereSponge      = 10
    case octahedron        = 11
    case icosahedron       = 12
    case surfaceKIFS       = 13
    case mengerSphere      = 14
    
    var displayName: String {
        switch self {
        case .mandelbox:       return "Mandelbox"
        case .mandelbulb:      return "Mandelbulb"
        case .menger:          return "Menger Sponge"
        case .sierpinski:      return "Sierpinski"
        case .dodecahedron:    return "Dodecahedron"
        case .pseudoKleinian:  return "Pseudo Kleinian"
        case .quaternionJulia: return "Quaternion Julia"
        case .amazingSurface:  return "Amazing Surface"
        case .pseudoKnightyan: return "Pseudo Knightyan"
        case .mandalayBox:     return "Mandalay Box"
        case .sphereSponge:    return "Sphere Sponge"
        case .octahedron:      return "Octahedron"
        case .icosahedron:     return "Icosahedron"
        case .surfaceKIFS:     return "Surface KIFS"
        case .mengerSphere:    return "Menger Sphere"
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
            return [.none, .grab, .minDistance, .foldingLimit, .sphereRadius, .fractalScale]
        default:
            return [.none, .grab, .fractalScale]
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
        case .pseudoKleinian:  return "building.columns"
        case .quaternionJulia: return "atom"
        case .amazingSurface:  return "sparkles"
        case .pseudoKnightyan: return "leaf"
        case .mandalayBox:     return "building.2"
        case .sphereSponge:    return "circle.grid.3x3"
        case .octahedron:      return "diamond"
        case .icosahedron:     return "seal"
        case .surfaceKIFS:     return "tree"
        case .mengerSphere:    return "circle.grid.cross"
        }
    }
    
    /// Category for grouping in UI
    var category: String {
        switch self {
        case .mandelbox, .amazingSurface, .mandalayBox:
            return "Box Folds"
        case .mandelbulb, .quaternionJulia:
            return "Power / Quaternion"
        case .menger, .sierpinski, .dodecahedron, .octahedron, .icosahedron, .mengerSphere:
            return "Kaleidoscopic IFS"
        case .pseudoKleinian, .pseudoKnightyan, .sphereSponge, .surfaceKIFS:
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
        case .pseudoKleinian:
            // Size=1, CSize=(0.8,0.8,1.3), C=(0,0,0), DEoffset=0, Offset=(0,0,-1)
            fp.params.0 = 1.0; fp.params.1 = 0.8; fp.params.2 = 0.8; fp.params.3 = 1.3
            fp.params.10 = -1.0
        case .quaternionJulia:
            // C=(-0.2,0.8,0,0), Threshold=10
            fp.params.0 = -0.2; fp.params.1 = 0.8; fp.params.4 = 10.0
        case .amazingSurface:
            // Scale=2, MinRad2=0.25
            fp.params.0 = 2.0; fp.params.1 = 0.25
        case .pseudoKnightyan:
            // CSize=(0.82,0.92,0.78), Size=1, DEfact=1, TwiddleRXY=0.13
            fp.params.0 = 0.82; fp.params.1 = 0.92; fp.params.2 = 0.78
            fp.params.3 = 1.0; fp.params.4 = 1.0; fp.params.5 = 0.13
        case .mandalayBox:
            // Scale=-1.77, MinRad2=0.42, DoBoxFold=0, fo=(1,1,1), g=(0,0,0), Serial=0
            fp.params.0 = -1.77; fp.params.1 = 0.42
            fp.params.3 = 1.0; fp.params.4 = 1.0; fp.params.5 = 1.0
        case .sphereSponge:
            // Scale=2, BubbleSize=3
            fp.params.0 = 2.0; fp.params.1 = 3.0
        case .octahedron:
            // Scale=2, Offset=(1,0,0)
            fp.params.0 = 2.0; fp.params.1 = 1.0
        case .icosahedron:
            // Scale=2, Phi=1.618, Offset=(1,0,0)
            fp.params.0 = 2.0; fp.params.1 = 1.618; fp.params.2 = 1.0
        case .surfaceKIFS:
            // Scale=1.7, Fold=(0,0,0), Julia=(-2,-2,-0.5), RotVector=(0,0,1), RotAngle=40
            fp.params.0 = 1.7
            fp.params.4 = -2.0; fp.params.5 = -2.0; fp.params.6 = -0.5
            fp.params.7 = 0.0; fp.params.8 = 0.0; fp.params.9 = 1.0; fp.params.10 = 40.0
        case .mengerSphere:
            // Scale=3, Offset=(1,1,1), Spherify=0
            fp.params.0 = 3.0; fp.params.1 = 1.0; fp.params.2 = 1.0; fp.params.3 = 1.0
        case .mandelbox:
            // Min Distance=0.8, Folding Limit=1.0, Sphere Radius=0.5
            fp.params.0 = 0.8; fp.params.1 = 1.0; fp.params.2 = 0.5
        }
        
        return fp
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
        case .pseudoKleinian:  return "pseudoKleinian"
        case .quaternionJulia: return "quaternionJulia"
        case .amazingSurface:  return "amazingSurface"
        case .pseudoKnightyan: return "pseudoKnightyan"
        case .mandalayBox:     return "mandalayBox"
        case .sphereSponge:    return "sphereSponge"
        case .octahedron:      return "octahedron"
        case .icosahedron:     return "icosahedron"
        case .surfaceKIFS:     return "surfaceKIFS"
        case .mengerSphere:    return "mengerSphere"
        }
    }

    private static let stringMap: [String: FractalModelType] = {
        var map: [String: FractalModelType] = [:]
        for c in FractalModelType.allCases { map[c.codableString] = c }
        return map
    }()

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let str = try? container.decode(String.self),
           let value = Self.stringMap[str] {
            self = value
        } else if let raw = try? container.decode(Int32.self),
                  let value = FractalModelType(rawValue: raw) {
            self = value
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Invalid FractalModelType value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(codableString)
    }
}
