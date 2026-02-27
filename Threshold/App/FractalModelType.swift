//
//  FractalModelType.swift
//  Threshold
//
//  Fractal type enum matching ShaderTypes.h FractalType enum (15 values)
//

import Foundation
import simd

enum FractalModelType: Int32, Codable, CaseIterable {
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
    
    /// Whether this type uses the Mandelbox-specific path (FractalParams + box/sphere fold macros)
    var usesMandelboxParams: Bool { self == .mandelbox }
    
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
    
    /// Build default FormulaParams for non-Mandelbox types
    func defaultFormulaParams() -> FormulaParams {
        var fp = FormulaParams()
        fp.rotMatrix1 = matrix_identity_float3x3
        fp.rotMatrix2 = matrix_identity_float3x3
        // Zero-init params tuple
        fp.params = (0,0,0,0, 0,0,0,0, 0,0,0,0, 0,0,0,0)
        
        switch self {
        case .mandelbulb:
            // Power=8, Bailout=4, DerivBias=1, Alternate=0, PolarRot=0
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
            break // Uses dedicated Mandelbox path
        }
        
        return fp
    }
}
