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

    /// Matching analytic primitive for promoting a Bounding shape into the
    /// construction stack's seed geometry. Negative Cube remains a legacy
    /// safety-bubble-only SDF and is intentionally not offered by Bounding.
    var seedPrimitiveKind: FractalPrimitiveKind? {
        switch self {
        case .sphere: return .sphere
        case .cube: return .box
        case .tetrahedral: return .tetrahedron
        case .octahedron: return .octahedron
        case .icosahedron: return .icosahedron
        case .dodecahedron: return .dodecahedron
        case .negativeCube: return nil
        }
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
    /// Comfort default: on Vision Pro the bubble starts ON so scenes can't push
    /// geometry into the viewer's face. Desktop/iPad keep it off — there the
    /// bubble is purely a scene-authored aesthetic.
#if os(visionOS)
    static let defaultEnabled = true
#else
    static let defaultEnabled = false
#endif
    /// Default strength = Blend UI slider at halfway (slider shows 1 − √strength).
    static let defaultStrength: Float = 0.25

    var enabled: Bool = SafetyBubbleConfig.defaultEnabled
    var radius: Float = 1.8        // 0.05 - 2.5 meters
    var shape: Float = 0.0         // 0...1 = legacy sphere/cube morph, 2...6 = discrete presets
    var fadeEnabled: Bool = true
    var fadeWidth: Float = 0.1     // 0.0 - 1.0
    var strength: Float = SafetyBubbleConfig.defaultStrength     // 0.0 - 1.0
    /// Mixed immersion: cap the bubble at `mixedRadius` while Mixed is active.
    /// In Mixed you're "outside" the fractal looking at it in your room, so a
    /// large comfort bubble mostly just hollows out the object. Live override —
    /// the saved radius is untouched and returns when leaving Mixed.
    var mixedAutoShrinkEnabled: Bool = true
    var mixedRadius: Float = 0.3   // 0.05 - 1.0 meters

    // MARK: - Codable (tolerant decode so adding fields never resets the
    // user's saved bubble config — it carries a comfort-default migration)

    private enum CodingKeys: String, CodingKey {
        case enabled, radius, shape, fadeEnabled, fadeWidth, strength
        case mixedAutoShrinkEnabled, mixedRadius
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? SafetyBubbleConfig.defaultEnabled
        radius = try c.decodeIfPresent(Float.self, forKey: .radius) ?? 1.8
        shape = try c.decodeIfPresent(Float.self, forKey: .shape) ?? 0.0
        fadeEnabled = try c.decodeIfPresent(Bool.self, forKey: .fadeEnabled) ?? true
        fadeWidth = try c.decodeIfPresent(Float.self, forKey: .fadeWidth) ?? 0.1
        strength = try c.decodeIfPresent(Float.self, forKey: .strength) ?? SafetyBubbleConfig.defaultStrength
        mixedAutoShrinkEnabled = try c.decodeIfPresent(Bool.self, forKey: .mixedAutoShrinkEnabled) ?? true
        mixedRadius = try c.decodeIfPresent(Float.self, forKey: .mixedRadius) ?? 0.3
    }

    // MARK: - Validation

    /// GPU coupling: the fast-normal gate in Shaders.metal
    /// (`worldFieldsMayAlterDistance` + `kSafetyBubbleNormalBandMargin`) treats
    /// the bubble as inert outside `fadeWidth + margin` of the wall so hit
    /// pixels away from the bubble keep the zero-probe analytic normal paths.
    /// That margin was derived against THESE ranges — radius ≤ 2.5 bounds the
    /// hit distance (and therefore the normal-probe epsilon) near the wall, and
    /// fadeWidth ≤ 1 bounds the influence band. Widening either range requires
    /// re-deriving the margin (see the shader comment), or normals just outside
    /// the band could seam.
    mutating func clamp() {
        radius = ControlCatalog.safetyBubbleRadius.clamp(radius)
        shape = shape.clamped(to: 0.0...SafetyBubbleShapePreset.maxStoredValue)
        fadeWidth = fadeWidth.clamped(to: 0.0...1.0)
        strength = strength.clamped(to: 0.0...1.0)
        mixedRadius = mixedRadius.clamped(to: 0.05...1.0)
    }
}
