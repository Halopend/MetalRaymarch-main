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

// MARK: - Gesture Parameter Ranges

/// Clamping ranges for gesture-driven parameter changes.
struct GestureParamRanges {
    let minDistance: ClosedRange<Float>
    let foldingLimit: ClosedRange<Float>
    let sphereRadius: ClosedRange<Float>
    let fractalScale: ClosedRange<Float>

    static let standard = GestureParamRanges(
        minDistance: -2.0...8.0,
        foldingLimit: -5.0...20.0,
        sphereRadius: -3.0...4.0,
        fractalScale: -3.0...5.0
    )

    static let extended = GestureParamRanges(
        minDistance: -5.0...15.0,
        foldingLimit: -10.0...30.0,
        sphereRadius: -5.0...8.0,
        fractalScale: -5.0...8.0
    )
}

/// Default camera/view state when switching to a fractal type.
struct FractalViewDefaults {
    var position: SIMD3<Float> = .zero
    var rotation: simd_quatf = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    var detailScale: Float = 1.0
    var safetyBubbleEnabled: Bool? = nil
}

/// Default shape/scale parameter values when switching to a fractal type.
/// Only meaningful for Mandelbox (which exposes minDistance/foldingLimit/sphereRadius
/// as user-facing gesture-controllable parameters). Other types use neutral defaults.
struct FractalShapeDefaults {
    var minDistance: Float = 0.8
    var foldingLimit: Float = 1.0
    var sphereRadius: Float = 0.5
    var fractalScale: Float = 2.8
}

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

    // Gesture configuration
    var gestureRanges: GestureParamRanges { get }
    var gestureRangesExtended: GestureParamRanges { get }
    var grabScaleClamp: ClosedRange<Float> { get }
    var defaultViewState: FractalViewDefaults { get }
    var defaultShapeParams: FractalShapeDefaults { get }
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

    // ── Gesture defaults ──────────────────────────────────────────────
    var gestureRanges: GestureParamRanges { .standard }
    var gestureRangesExtended: GestureParamRanges { .extended }
    var grabScaleClamp: ClosedRange<Float> { 0.001...500.0 }
    var defaultViewState: FractalViewDefaults { FractalViewDefaults() }
    var defaultShapeParams: FractalShapeDefaults { FractalShapeDefaults() }
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
        PseudoKleinianDescriptor(),
        PseudoKleinianMengerDescriptor(),
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
    var grabScaleClamp: ClosedRange<Float> { 0.0005...2000.0 }
    var defaultViewState: FractalViewDefaults {
        let qx = simd_quatf(angle: .pi, axis: SIMD3<Float>(1, 0, 0))
        let qy = simd_quatf(angle: 75.0 * .pi / 180.0, axis: SIMD3<Float>(0, 1, 0))
        let qz = simd_quatf(angle: .pi, axis: SIMD3<Float>(0, 0, 1))
        return FractalViewDefaults(
            position: SIMD3<Float>(0.1, 0.1, -0.9),
            rotation: simd_normalize(qz * qy * qx),
            detailScale: 0.25,
            safetyBubbleEnabled: false
        )
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

private struct PseudoKleinianDescriptor: FractalTypeDescriptor {
    let rawValue: Int32 = 18
    let displayName = "Pseudo Kleinian (MB3D)"
    let icon = "cube.fill"
    let category = "Julia Box"
    let codableString = "pseudoKleinian"
    let isSelectableInUI = true
    let supportedCoreGestureActions = standardCoreGestureActions
    var supportedEffectTags: Set<EffectTag> { Self.universalEffectTags }
    func defaultFormulaParams() -> FormulaParams {
        var fp = Self.baseFormulaParams()
        fp.params.0 = 1.0     // MaxR2
        fp.params.1 = 0.0     // Offset.x
        fp.params.2 = 0.0     // Offset.y
        fp.params.3 = 0.0     // Offset.z
        fp.params.4 = 1.0     // Gap.x
        fp.params.5 = 1.0     // Gap.y
        fp.params.6 = 1.0     // Gap.z
        fp.params.7 = 1.0     // Scale
        fp.params.8 = 0.0     // Fold.x
        fp.params.9 = 0.0     // Fold.y
        fp.params.10 = 0.0    // Fold.z
        fp.params.11 = 1.0    // BoxLimit
        fp.params.12 = 2.0    // BoxValue
        fp.params.13 = 1.0    // CSize.x
        fp.params.14 = 1.0    // CSize.y
        fp.params.15 = 1.0    // CSize.z
        FormulaCatalog.normalizeRotationFlags(&fp)
        return fp
    }
}

private struct PseudoKleinianMengerDescriptor: FractalTypeDescriptor {
    let rawValue: Int32 = 19
    let displayName = "PK Menger Hybrid"
    let icon = "cube.transparent.fill"
    let category = "Julia Box"
    let codableString = "pseudoKleinianMenger"
    let isSelectableInUI = true
    let supportedCoreGestureActions = standardCoreGestureActions
    var supportedEffectTags: Set<EffectTag> { Self.universalEffectTags }
    func defaultFormulaParams() -> FormulaParams {
        var fp = Self.baseFormulaParams()
        fp.params.0 = 1.46218  // Size
        fp.params.1 = 1.0      // CSize.x
        fp.params.2 = 1.0      // CSize.y
        fp.params.3 = 1.0      // CSize.z
        fp.params.4 = -0.11024 // C.x
        fp.params.5 = 0.0      // C.y
        fp.params.6 = 0.0      // C.z
        fp.params.7 = 1.26088  // Offset.x
        fp.params.8 = 1.52172  // Offset.y
        fp.params.9 = -0.69564 // Offset.z
        fp.params.10 = 4.0     // iScale
        fp.params.11 = 1.0     // v1
        fp.params.12 = 1.0     // v3
        fp.params.13 = 0.85484 // w1.x
        fp.params.14 = 1.0     // w1.y
        fp.params.15 = 0.80646 // w1.z
        FormulaCatalog.normalizeRotationFlags(&fp)
        return fp
    }
}

