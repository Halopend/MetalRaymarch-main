//
//  FractalModelType.swift
//  Threshold
//
//  Fractal type enum matching ShaderTypes.h
//

import Foundation

enum FractalModelType: Int32, Codable, CaseIterable {
    case mandelbox = 0
    case mandelbulb = 1
    case menger = 2
    case infinity = 3
    case tetrahedron = 4
    case prism = 5
    case sphereProjection = 6
    
    var displayName: String {
        switch self {
        case .mandelbox: return "Mandelbox"
        case .mandelbulb: return "Mandelbulb"
        case .menger: return "Menger"
        case .infinity: return "Infinity"
        case .tetrahedron: return "Tetrahedron"
        case .prism: return "Prism"
        case .sphereProjection: return "Sphere Projection"
        }
    }
}
