//
//  SafetyBubbleConfig.swift
//  Threshold
//
//  Domain config: safety bubble around the camera to prevent clipping.
//  Part of the RenderSettings decomposition (Phase 1).
//

import Foundation

enum SafetyBubbleShapeFamily: String, CaseIterable, Identifiable, Sendable {
    case sphere = "Sphere"
    case cube = "Cube"
    case platonic = "Platonic"

    var id: Self { self }
}

enum SafetyBubbleShapePreset: Int, CaseIterable, Identifiable, Sendable {
    case sphere = 0
    case cube = 1
    case tetrahedral = 2
    case negativeCube = 3
    case octahedron = 4
    case icosahedron = 5
    case dodecahedron = 6

    static let maxStoredValue: Float = 6.0

    static var platonicOptions: [SafetyBubbleShapePreset] {
        [.tetrahedral, .octahedron, .icosahedron, .dodecahedron]
    }

    var id: Self { self }

    var displayName: String {
        switch self {
        case .sphere:
            return "Sphere"
        case .cube:
            return "Cube"
        case .tetrahedral:
            return "Tetrahedral"
        case .negativeCube:
            return "Negative Cube"
        case .octahedron:
            return "Octahedron"
        case .icosahedron:
            return "Icosahedron"
        case .dodecahedron:
            return "Dodecahedron"
        }
    }

    var family: SafetyBubbleShapeFamily {
        switch self {
        case .sphere:
            return .sphere
        case .cube:
            return .cube
        case .tetrahedral, .negativeCube, .octahedron, .icosahedron, .dodecahedron:
            return .platonic
        }
    }

    var storedValue: Float {
        Float(rawValue)
    }

    init(storedValue: Float) {
        if storedValue > 1.0 {
            self = SafetyBubbleShapePreset(rawValue: Int(storedValue.rounded())) ?? .tetrahedral
        } else if storedValue >= 0.5 {
            self = .cube
        } else {
            self = .sphere
        }
    }

    static func family(for storedValue: Float) -> SafetyBubbleShapeFamily {
        SafetyBubbleShapePreset(storedValue: storedValue).family
    }

    static func storedValue(for family: SafetyBubbleShapeFamily, currentValue: Float) -> Float {
        switch family {
        case .sphere:
            return SafetyBubbleShapePreset.sphere.storedValue
        case .cube:
            return SafetyBubbleShapePreset.cube.storedValue
        case .platonic:
            let currentPreset = SafetyBubbleShapePreset(storedValue: currentValue)
            if currentPreset.family == .platonic {
                return currentPreset.storedValue
            }
            return SafetyBubbleShapePreset.tetrahedral.storedValue
        }
    }
}

struct SafetyBubbleConfig: Codable, Equatable, Sendable {
    var enabled: Bool = false
    var radius: Float = 1.8        // 0.05 - 2.5 meters
    var shape: Float = 0.0         // 0...1 = legacy sphere/cube morph, 2...6 = discrete presets
    var fadeEnabled: Bool = true
    var fadeWidth: Float = 0.1     // 0.0 - 1.0
    var strength: Float = 0.5     // 0.0 - 1.0

    // MARK: - Validation

    mutating func clamp() {
        radius = ControlCatalog.safetyBubbleRadius.clamp(radius)
        shape = max(0.0, min(SafetyBubbleShapePreset.maxStoredValue, shape))
        fadeWidth = max(0.0, min(1.0, fadeWidth))
        strength = max(0.0, min(1.0, strength))
    }
}
