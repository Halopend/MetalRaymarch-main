//
//  FractalTypeDescriptor.swift
//  Threshold
//
//  Protocol + registry that replaces exhaustive switches in FractalModelType.
//  Adding a new fractal = one new descriptor + one registration line.
//
//  Phase 5 of the architecture rebuild.
//

import Foundation
import simd

// MARK: - Protocol

protocol FractalTypeDescriptor {
    var rawValue: Int32 { get }
    var displayName: String { get }
    var icon: String { get }
    var category: String { get }
    var codableString: String { get }
    var supportedCoreGestureActions: [FingerGestureAction] { get }
    var supportedEffectTags: Set<EffectTag> { get }
    var isSelectableInUI: Bool { get }
    func defaultFormulaParams() -> FormulaParams
}

// MARK: - Shared constants

extension FractalTypeDescriptor {
    /// Effects supported by all fractal types.
    static var universalEffectTags: Set<EffectTag> {
        [.hueRotation, .pulse, .glow, .bloom, .fog, .gradientCycle]
    }

    /// Default core gesture actions for non-Mandelbox types.
    static var standardCoreGestureActions: [FingerGestureAction] {
        [.none, .grab, .fractalScale, .translate]
    }

    /// Base FormulaParams with identity rotation matrices and zeroed params.
    static func baseFormulaParams() -> FormulaParams {
        var fp = FormulaParams()
        fp.rotMatrix1 = matrix_identity_float3x3
        fp.rotMatrix2 = matrix_identity_float3x3
        fp.params = (0,0,0,0, 0,0,0,0, 0,0,0,0, 0,0,0,0)
        return fp
    }
}

// MARK: - Registry

enum FractalTypeRegistry {
    private static var descriptors: [Int32: FractalTypeDescriptor] = {
        var d: [Int32: FractalTypeDescriptor] = [:]
        for desc in allDescriptors { d[desc.rawValue] = desc }
        return d
    }()

    private static let allDescriptors: [FractalTypeDescriptor] = [
        MandelboxDescriptor(),
        MandelbulbDescriptor(),
        MengerDescriptor(),
        SierpinskiDescriptor(),
        DodecahedronDescriptor(),
        QuaternionJuliaDescriptor(),
        SphereSpongeDescriptor(),
        OctahedronDescriptor(),
        MengerSphereDescriptor(),
        TheliPseudoKleinianDescriptor(),
        KleinianDescriptor(),
    ]

    static func descriptor(for type: FractalModelType) -> FractalTypeDescriptor {
        descriptors[type.rawValue]!
    }
}

// MARK: - Concrete Descriptors

private struct MandelboxDescriptor: FractalTypeDescriptor {
    let rawValue: Int32 = 0
    let displayName = "Mandelbox"
    let icon = "cube.transparent"
    let category = "Box Folds"
    let codableString = "mandelbox"
    let isSelectableInUI = true
    var supportedCoreGestureActions: [FingerGestureAction] {
        [.none, .grab, .minDistance, .foldingLimit, .sphereRadius, .fractalScale, .translate]
    }
    var supportedEffectTags: Set<EffectTag> { Self.universalEffectTags }
    func defaultFormulaParams() -> FormulaParams {
        var fp = Self.baseFormulaParams()
        fp.params.0 = 0.8; fp.params.1 = 1.0; fp.params.2 = 0.5
        FormulaCatalog.normalizeRotationFlags(&fp)
        return fp
    }
}

private struct MandelbulbDescriptor: FractalTypeDescriptor {
    let rawValue: Int32 = 1
    let displayName = "Mandelbulb"
    let icon = "globe"
    let category = "Power / Quaternion"
    let codableString = "mandelbulb"
    let isSelectableInUI = true
    let supportedCoreGestureActions = standardCoreGestureActions
    var supportedEffectTags: Set<EffectTag> { Self.universalEffectTags.union([.polarRotation]) }
    func defaultFormulaParams() -> FormulaParams {
        var fp = Self.baseFormulaParams()
        fp.params.0 = 8.0; fp.params.1 = 4.0; fp.params.2 = 1.0
        FormulaCatalog.normalizeRotationFlags(&fp)
        return fp
    }
}

private struct MengerDescriptor: FractalTypeDescriptor {
    let rawValue: Int32 = 2
    let displayName = "Menger Sponge"
    let icon = "square.grid.3x3"
    let category = "Kaleidoscopic IFS"
    let codableString = "menger"
    let isSelectableInUI = true
    let supportedCoreGestureActions = standardCoreGestureActions
    var supportedEffectTags: Set<EffectTag> { Self.universalEffectTags }
    func defaultFormulaParams() -> FormulaParams {
        var fp = Self.baseFormulaParams()
        fp.params.0 = 3.0; fp.params.1 = 1.0; fp.params.2 = 1.0; fp.params.3 = 1.0
        FormulaCatalog.normalizeRotationFlags(&fp)
        return fp
    }
}

private struct SierpinskiDescriptor: FractalTypeDescriptor {
    let rawValue: Int32 = 3
    let displayName = "Sierpinski"
    let icon = "triangle"
    let category = "Kaleidoscopic IFS"
    let codableString = "sierpinski"
    let isSelectableInUI = true
    let supportedCoreGestureActions = standardCoreGestureActions
    var supportedEffectTags: Set<EffectTag> { Self.universalEffectTags }
    func defaultFormulaParams() -> FormulaParams {
        var fp = Self.baseFormulaParams()
        fp.params.0 = 2.0; fp.params.1 = 1.0; fp.params.2 = 1.0; fp.params.3 = 1.0
        FormulaCatalog.normalizeRotationFlags(&fp)
        return fp
    }
}

private struct DodecahedronDescriptor: FractalTypeDescriptor {
    let rawValue: Int32 = 4
    let displayName = "Dodecahedron"
    let icon = "pentagon"
    let category = "Kaleidoscopic IFS"
    let codableString = "dodecahedron"
    let isSelectableInUI = true
    let supportedCoreGestureActions = standardCoreGestureActions
    var supportedEffectTags: Set<EffectTag> { Self.universalEffectTags }
    func defaultFormulaParams() -> FormulaParams {
        var fp = Self.baseFormulaParams()
        fp.params.0 = 2.0; fp.params.1 = 1.618; fp.params.2 = 2.0
        FormulaCatalog.normalizeRotationFlags(&fp)
        return fp
    }
}

private struct QuaternionJuliaDescriptor: FractalTypeDescriptor {
    let rawValue: Int32 = 6
    let displayName = "Quaternion Julia"
    let icon = "atom"
    let category = "Power / Quaternion"
    let codableString = "quaternionJulia"
    let isSelectableInUI = true
    let supportedCoreGestureActions = standardCoreGestureActions
    var supportedEffectTags: Set<EffectTag> { Self.universalEffectTags.union([.polarRotation]) }
    func defaultFormulaParams() -> FormulaParams {
        var fp = Self.baseFormulaParams()
        fp.params.0 = -0.2; fp.params.1 = 0.8; fp.params.4 = 10.0
        FormulaCatalog.normalizeRotationFlags(&fp)
        return fp
    }
}

private struct SphereSpongeDescriptor: FractalTypeDescriptor {
    let rawValue: Int32 = 10
    let displayName = "Sphere Sponge"
    let icon = "circle.grid.3x3"
    let category = "Julia Box"
    let codableString = "sphereSponge"
    let isSelectableInUI = true
    let supportedCoreGestureActions = standardCoreGestureActions
    var supportedEffectTags: Set<EffectTag> { Self.universalEffectTags }
    func defaultFormulaParams() -> FormulaParams {
        var fp = Self.baseFormulaParams()
        fp.params.0 = 2.0; fp.params.1 = 3.0
        FormulaCatalog.normalizeRotationFlags(&fp)
        return fp
    }
}

private struct OctahedronDescriptor: FractalTypeDescriptor {
    let rawValue: Int32 = 11
    let displayName = "Octahedron"
    let icon = "diamond"
    let category = "Kaleidoscopic IFS"
    let codableString = "octahedron"
    let isSelectableInUI = true
    let supportedCoreGestureActions = standardCoreGestureActions
    var supportedEffectTags: Set<EffectTag> { Self.universalEffectTags }
    func defaultFormulaParams() -> FormulaParams {
        var fp = Self.baseFormulaParams()
        fp.params.0 = 2.0; fp.params.1 = 1.0
        FormulaCatalog.normalizeRotationFlags(&fp)
        return fp
    }
}

private struct MengerSphereDescriptor: FractalTypeDescriptor {
    let rawValue: Int32 = 14
    let displayName = "Menger Sphere"
    let icon = "circle.grid.cross"
    let category = "Kaleidoscopic IFS"
    let codableString = "mengerSphere"
    let isSelectableInUI = true
    let supportedCoreGestureActions = standardCoreGestureActions
    var supportedEffectTags: Set<EffectTag> { Self.universalEffectTags }
    func defaultFormulaParams() -> FormulaParams {
        var fp = Self.baseFormulaParams()
        fp.params.0 = 3.0; fp.params.1 = 1.0; fp.params.2 = 1.0; fp.params.3 = 1.0
        FormulaCatalog.normalizeRotationFlags(&fp)
        return fp
    }
}

private struct TheliPseudoKleinianDescriptor: FractalTypeDescriptor {
    let rawValue: Int32 = 15
    let displayName = "Theli Pseudo Kleinian"
    let icon = "cube"
    let category = "Julia Box"
    let codableString = "theliPseudoKleinian"
    let isSelectableInUI = false
    let supportedCoreGestureActions = standardCoreGestureActions
    var supportedEffectTags: Set<EffectTag> { Self.universalEffectTags }
    func defaultFormulaParams() -> FormulaParams {
        var fp = Self.baseFormulaParams()
        fp.params.0 = 1.0
        fp.params.1 = 1.0; fp.params.2 = 1.0; fp.params.3 = 1.0
        fp.params.7 = 0.0
        fp.params.11 = 2.0
        fp.params.12 = 3.0
        fp.params.13 = 1.0; fp.params.14 = 1.0; fp.params.15 = 1.0
        FormulaCatalog.normalizeRotationFlags(&fp)
        return fp
    }
}

private struct KleinianDescriptor: FractalTypeDescriptor {
    let rawValue: Int32 = 17
    let displayName = "Kleinian"
    let icon = "wand.and.stars"
    let category = "Julia Box"
    let codableString = "kleinian"
    let isSelectableInUI = true
    let supportedCoreGestureActions = standardCoreGestureActions
    var supportedEffectTags: Set<EffectTag> { Self.universalEffectTags }
    func defaultFormulaParams() -> FormulaParams {
        var fp = Self.baseFormulaParams()
        fp.params.0 = -0.3252; fp.params.1 = -0.7862; fp.params.2 = -0.0948
        fp.params.3 = 0.69
        fp.params.4 = 0.35; fp.params.5 = 1.0; fp.params.6 = 1.22
        fp.params.7 = 0.84
        fp.params.8 = 0.25; fp.params.9 = 1.0
        FormulaCatalog.normalizeRotationFlags(&fp)
        return fp
    }
}
