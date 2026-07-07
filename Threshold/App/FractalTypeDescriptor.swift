//
//  FractalTypeDescriptor.swift
//  Threshold
//
//  Base CLASS + registry that replaces exhaustive switches in FractalModelType.
//  Adding a new fractal = one new subclass + one registration line.
//
//  Phase 5 of the architecture rebuild; converted from a protocol to a class
//  hierarchy in Stage 3 of the class-based module refactor (mirrors the Module
//  base-class pattern). The base owns all shared metadata defaults; concrete
//  fractal subclasses override only what differs. `FractalModelType.descriptor`
//  returns a `FractalTypeDescriptor` instance — Codable stays on the enum, so the
//  class is a non-Codable metadata façade and on-disk formats are unchanged.
//
//  NOTE: the base is named `FractalTypeDescriptor` (not `FractalType`) on purpose
//  — `FractalType` is the C NS_ENUM bridged from ShaderTypes.h and would collide.
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

// MARK: - Space Transforms (capability key)

/// Space-domain transforms a fractal can carry. These are "modules" in the
/// space domain: a scene declares them with a type key (see `ModuleKey.space`)
/// and the renderer applies them around the formula DE rather than inside it.
///
/// Mirrors `EffectTag` exactly — a fractal advertises which transforms are
/// meaningful via `supportedSpaceTransforms`, gated in the UI with
/// `FractalModelType.supports(_:SpaceTransform)`.
enum SpaceTransform: String, Codable, CaseIterable, Sendable {
    /// Radial sphere projection. On Mandelbox this is the native per-fold
    /// projection inside `Map()`; on every other fractal it is applied as a
    /// domain-space warp at the dispatch boundary (`applySphereProjectionDomain`).
    case sphereProjection
}

// MARK: - Base class

/// Base class for a fractal type's metadata. Concrete fractals subclass it and
/// override only what differs from the universal defaults.
///
/// @unchecked Sendable justification: every stored property is an immutable `let`
/// set at init and never mutated; overridable members are pure computed values.
/// The `.custom` overlay shares a single instance across threads, so post-init
/// immutability is load-bearing (see `CustomFractalDescriptor`).
class FractalTypeDescriptor: @unchecked Sendable {
    let rawValue: Int32
    let displayName: String
    let icon: String
    let category: String
    let codableString: String
    let isSelectableInUI: Bool

    init(rawValue: Int32,
         displayName: String,
         icon: String,
         category: String,
         codableString: String,
         isSelectableInUI: Bool) {
        self.rawValue = rawValue
        self.displayName = displayName
        self.icon = icon
        self.category = category
        self.codableString = codableString
        self.isSelectableInUI = isSelectableInUI
    }

    // ── Shared constants (formerly the protocol extension) ────────────────

    /// Effects supported by all fractal types.
    static var universalEffectTags: Set<EffectTag> {
        [.hueRotation, .pulse, .glow, .bloom, .fog, .gradientCycle, .linearRail]
    }

    /// Space transforms enabled for every fractal by default. Sphere projection
    /// works across all types because it is applied as a domain warp at the
    /// dispatch boundary (non-Mandelbox) or natively inside `Map()` (Mandelbox).
    /// "Enable broadly, prune by eye": individual subclasses can override
    /// `supportedSpaceTransforms` to `[]` (or a subset) once tuned visually.
    static var universalSpaceTransforms: Set<SpaceTransform> { [.sphereProjection] }

    /// Default core gesture actions for non-Mandelbox types.
    static var standardCoreGestureActions: [FingerGestureAction] {
        [.none, .grab, .translate]
    }

    /// Base FormulaParams with identity rotation matrices and zeroed params.
    static func baseFormulaParams() -> FormulaParams {
        var fp = FormulaParams()
        fp.rotMatrix1 = matrix_identity_float3x3
        fp.rotMatrix2 = matrix_identity_float3x3
        fp.params = (0,0,0,0, 0,0,0,0, 0,0,0,0, 0,0,0,0)
        return fp
    }

    /// Shared "look down the Julia-like view" camera (was cloned verbatim across
    /// Mandelbulb / MandelbulbJulia / QuaternionJulia — only the position differs).
    static func juliaLikeView(position: SIMD3<Float>) -> FractalViewDefaults {
        let qx = simd_quatf(angle: .pi, axis: SIMD3<Float>(1, 0, 0))
        let qy = simd_quatf(angle: 75.0 * .pi / 180.0, axis: SIMD3<Float>(0, 1, 0))
        let qz = simd_quatf(angle: .pi, axis: SIMD3<Float>(0, 0, 1))
        return FractalViewDefaults(
            position: position,
            rotation: simd_normalize(qz * qy * qx),
            detailScale: 0.25,
            safetyBubbleEnabled: false
        )
    }

    // ── Overridable capability / default members (universal defaults) ─────
    // Subclasses override only what differs; everything else is inherited.

    var supportedCoreGestureActions: [FingerGestureAction] { Self.standardCoreGestureActions }
    var supportedEffectTags: Set<EffectTag> { Self.universalEffectTags }
    /// Space-domain transforms this fractal supports (e.g. sphere projection).
    var supportedSpaceTransforms: Set<SpaceTransform> { Self.universalSpaceTransforms }

    func defaultFormulaParams() -> FormulaParams { Self.baseFormulaParams() }

    /// Per-type quality override (fractalIterations, raySteps) for a preset tier;
    /// nil = use the preset's own default values. Absorbs the per-type switch that
    /// lived in `QualityPreset.values(for:)`.
    func qualityValues(for preset: QualityPreset) -> (fractalIterations: Int, raySteps: Int)? { nil }

    /// LaTeX-ish display formula shown in the fractal browser; nil = none. Absorbs
    /// the per-type switch that lived in `FractalBrowserWindow.primaryEquation`.
    func primaryEquation() -> String? { nil }

    /// Fold the accumulated polar-rotation animation offset into the formula
    /// params. Default no-op (the type doesn't animate polar rotation). Absorbs
    /// the per-type switch that lived in `RenderSettings.snapshot()` — runs in the
    /// per-frame snapshot path, so subclasses must preserve their param indices.
    func applyPolarRotation(into fp: inout FormulaParams, accum: Float) {}

    // Gesture configuration
    var gestureRanges: GestureParamRanges { .standard }
    var gestureRangesExtended: GestureParamRanges { .extended }
    var grabScaleClamp: ClosedRange<Float> { 0.001...500.0 }
    var defaultViewState: FractalViewDefaults { FractalViewDefaults() }
    var defaultShapeParams: FractalShapeDefaults { FractalShapeDefaults() }

    /// Per-type default gesture bindings mapping single-hand slots to formula
    /// parameter triplet groups (e.g. "Mins", "Maxs"). Resolved from the formula
    /// catalog when the fractal type is switched.
    var defaultTripletBindings: [(slot: GestureSlot, groupName: String)] { [] }

    /// Per-type default gesture bindings mapping single-hand slots to scalar
    /// formula parameters (e.g. "Power", "PolarRotation"). Resolved from the
    /// formula catalog when the fractal type is switched.
    var defaultScalarBindings: [(slot: GestureSlot, paramName: String)] { [] }

    /// Color scheme applied when switching to this fractal type (nil = keep current).
    var defaultColorScheme: ColorScheme? { nil }
}

// MARK: - Registry

enum FractalTypeRegistry {
    private static let allDescriptors: [FractalTypeDescriptor] = [
        MandelboxDescriptor(),
        MandelbulbDescriptor(),
        MengerDescriptor(),
        MandelbulbJuliaDescriptor(),
        QuaternionJuliaDescriptor(),
        OctahedronDescriptor(),
        MengerSphereDescriptor(),
        TheliPseudoKleinianDescriptor(),
        KleinianDescriptor(),
        // Placeholder so `.custom` always resolves; real metadata is supplied
        // at scene-load time via `registerCustom(_:)`.
        CustomFractalDescriptor.placeholder,
    ]

    private static let staticDescriptors: [Int32: FractalTypeDescriptor] = {
        var d: [Int32: FractalTypeDescriptor] = [:]
        for desc in allDescriptors { d[desc.rawValue] = desc }
        #if DEBUG
        validateRegistry(d)
        #endif
        return d
    }()

    #if DEBUG
    /// Startup tripwire for registry integrity. Catches a fat-fingered
    /// `super.init(rawValue:)` or a missing/duplicate descriptor BEFORE it can
    /// silently shift the Int32-fallback decode of an old `.threshscene`.
    /// NOTE: this validates the SWIFT side only — it does NOT bind the Metal
    /// dispatch switches / relaxedOmegaCap (those stay hand-synced until the
    /// shader-codegen step lands).
    private static func validateRegistry(_ d: [Int32: FractalTypeDescriptor]) {
        // Presence: every enum case resolves to a descriptor.
        for c in FractalModelType.allCases {
            assert(d[c.rawValue] != nil,
                   "FractalTypeRegistry: missing descriptor for \(c) (rawValue \(c.rawValue))")
        }
        // Count: the descriptor set covers exactly the enum (a non-colliding wrong
        // rawValue would leave one enum case unmapped → also tripped by presence).
        assert(d.count == FractalModelType.allCases.count,
               "FractalTypeRegistry: descriptor count \(d.count) != enum case count \(FractalModelType.allCases.count)")
        // Uniqueness: no two descriptors share a rawValue (a collision would
        // overwrite a slot) or a codableString (the primary on-disk key).
        assert(allDescriptors.count == Set(allDescriptors.map(\.rawValue)).count,
               "FractalTypeRegistry: duplicate rawValue across descriptors")
        assert(allDescriptors.count == Set(allDescriptors.map(\.codableString)).count,
               "FractalTypeRegistry: duplicate codableString across descriptors")
    }
    #endif

    /// Lock-protected overlay for ephemeral descriptors (currently only `.custom`).
    private static let overlayLock = NSLock()
    nonisolated(unsafe) private static var overlay: [Int32: FractalTypeDescriptor] = [:]

    static func descriptor(for type: FractalModelType) -> FractalTypeDescriptor {
        overlayLock.lock()
        let dynamic = overlay[type.rawValue]
        overlayLock.unlock()
        if let dynamic { return dynamic }
        guard let desc = staticDescriptors[type.rawValue] else {
            preconditionFailure("FractalTypeRegistry: no descriptor for \(type) (rawValue \(type.rawValue))")
        }
        return desc
    }

    /// Register a runtime descriptor built from an embedded formula. Replaces any
    /// previously-active `.custom` descriptor.
    static func registerCustom(_ formula: EmbeddedFormula) {
        let desc = CustomFractalDescriptor(formula: formula)
        overlayLock.lock()
        // The instance is shared across threads via the overlay; its @unchecked
        // Sendable contract depends on every stored property staying immutable
        // after init (a fresh instance is built per registerCustom call).
        overlay[FractalModelType.custom.rawValue] = desc
        overlayLock.unlock()
    }

    /// Remove the active `.custom` descriptor; subsequent lookups fall back to
    /// the placeholder.
    static func unregisterCustom() {
        overlayLock.lock()
        overlay.removeValue(forKey: FractalModelType.custom.rawValue)
        overlayLock.unlock()
    }
}

// MARK: - Concrete Descriptors

private final class MandelboxDescriptor: FractalTypeDescriptor, @unchecked Sendable {
    init() {
        super.init(rawValue: 0, displayName: "Mandelbox", icon: "cube.transparent",
                   category: "Box Folds", codableString: "mandelbox", isSelectableInUI: true)
    }
    override func primaryEquation() -> String? { "p_{n+1} = scale * boxFold(sphereFold(p_n)) + c" }
    override var supportedCoreGestureActions: [FingerGestureAction] {
        [.none, .grab, .minDistance, .foldingLimit, .sphereRadius, .fractalScale, .translate]
    }
    override var defaultColorScheme: ColorScheme? { .rainbow }
    override func defaultFormulaParams() -> FormulaParams {
        var fp = Self.baseFormulaParams()
        fp.params.0 = 0.8; fp.params.1 = 1.0; fp.params.2 = 0.5
        FormulaCatalog.normalizeRotationFlags(&fp)
        return fp
    }
}

private final class MandelbulbDescriptor: FractalTypeDescriptor, @unchecked Sendable {
    init() {
        super.init(rawValue: 1, displayName: "Mandelbulb", icon: "globe",
                   category: "Power / Quaternion", codableString: "mandelbulb", isSelectableInUI: true)
    }
    override func primaryEquation() -> String? { "z_{n+1} = z_n^p + c" }
    override func applyPolarRotation(into fp: inout FormulaParams, accum: Float) {
        // params[4] = PolarRotation — add the accumulated offset to the user's static value.
        let base = FormulaCatalog.getParam(fp, index: 4)
        FormulaCatalog.setParam(&fp, index: 4, value: base + accum)
    }
    override func qualityValues(for preset: QualityPreset) -> (fractalIterations: Int, raySteps: Int)? {
        switch preset {
        case .low:    return (4, 68)
        case .medium: return (6, 88)
        case .high:   return (8, 97)
        case .ultra:  return (10, 102)
        }
    }
    override var supportedEffectTags: Set<EffectTag> { Self.universalEffectTags.union([.polarRotation]) }
    override func defaultFormulaParams() -> FormulaParams {
        var fp = Self.baseFormulaParams()
        fp.params.0 = 8.0; fp.params.1 = 4.0; fp.params.2 = 1.0
        FormulaCatalog.normalizeRotationFlags(&fp)
        return fp
    }
    override var grabScaleClamp: ClosedRange<Float> { 0.0005...2000.0 }
    override var defaultViewState: FractalViewDefaults {
        Self.juliaLikeView(position: SIMD3<Float>(0.1, 0.1, -0.9))
    }
    override var defaultScalarBindings: [(slot: GestureSlot, paramName: String)] {
        [
            (GestureSlot(hand: .left, finger: .middle), "PolarRotation"),
            (GestureSlot(hand: .left, finger: .index), "Power"),
        ]
    }
}

private final class MengerDescriptor: FractalTypeDescriptor, @unchecked Sendable {
    init() {
        super.init(rawValue: 2, displayName: "Menger Sponge", icon: "square.grid.3x3",
                   category: "Kaleidoscopic IFS", codableString: "menger", isSelectableInUI: true)
    }
    override func primaryEquation() -> String? { "p_{n+1} = scale * fold_menger(p_n) + c" }
    override func defaultFormulaParams() -> FormulaParams {
        var fp = Self.baseFormulaParams()
        fp.params.0 = 3.0; fp.params.1 = 1.0; fp.params.2 = 1.0; fp.params.3 = 1.0
        FormulaCatalog.normalizeRotationFlags(&fp)
        return fp
    }
}

private final class MandelbulbJuliaDescriptor: FractalTypeDescriptor, @unchecked Sendable {
    init() {
        super.init(rawValue: 5, displayName: "Mandelbulb Julia", icon: "globe.badge.chevron.backward",
                   category: "Power / Quaternion", codableString: "mandelbulbJulia", isSelectableInUI: true)
    }
    override func primaryEquation() -> String? { "z_{n+1} = z_n^p + c_{julia}" }
    override func applyPolarRotation(into fp: inout FormulaParams, accum: Float) {
        // params[4] = PolarRotation — same as Mandelbulb.
        let base = FormulaCatalog.getParam(fp, index: 4)
        FormulaCatalog.setParam(&fp, index: 4, value: base + accum)
    }
    override func qualityValues(for preset: QualityPreset) -> (fractalIterations: Int, raySteps: Int)? {
        switch preset {
        case .low:    return (4, 68)
        case .medium: return (6, 88)
        case .high:   return (8, 97)
        case .ultra:  return (10, 102)
        }
    }
    override var supportedEffectTags: Set<EffectTag> { Self.universalEffectTags.union([.polarRotation, .juliaDrift]) }
    override func defaultFormulaParams() -> FormulaParams {
        var fp = Self.baseFormulaParams()
        fp.params.0 = 8.0   // Power
        fp.params.1 = 4.0   // Bailout
        fp.params.2 = 1.0   // DerivBias
        fp.params.8 = 1.0   // Julia enabled
        fp.params.9 = 0.2   // JuliaC.x
        fp.params.10 = -0.15 // JuliaC.y
        fp.params.11 = 0.35  // JuliaC.z
        FormulaCatalog.normalizeRotationFlags(&fp)
        return fp
    }
    override var grabScaleClamp: ClosedRange<Float> { 0.0005...2000.0 }
    override var defaultViewState: FractalViewDefaults {
        Self.juliaLikeView(position: SIMD3<Float>(0.1, 0.1, -1.45))
    }
    override var defaultTripletBindings: [(slot: GestureSlot, groupName: String)] {
        [
            (GestureSlot(hand: .right, finger: .middle), "JuliaC"),
        ]
    }
    override var defaultScalarBindings: [(slot: GestureSlot, paramName: String)] {
        [
            (GestureSlot(hand: .left, finger: .middle), "PolarRotation"),
            (GestureSlot(hand: .left, finger: .index), "Power"),
        ]
    }
}

private final class QuaternionJuliaDescriptor: FractalTypeDescriptor, @unchecked Sendable {
    init() {
        super.init(rawValue: 6, displayName: "Quaternion Julia", icon: "atom",
                   category: "Power / Quaternion", codableString: "quaternionJulia", isSelectableInUI: true)
    }
    override func primaryEquation() -> String? { "q_{n+1} = q_n^2 + c" }
    override func applyPolarRotation(into fp: inout FormulaParams, accum: Float) {
        // Rotate the C-constant through the (x,y) plane of quaternion space.
        let cx = FormulaCatalog.getParam(fp, index: 0)
        let cy = FormulaCatalog.getParam(fp, index: 1)
        let cosA = cos(accum)
        let sinA = sin(accum)
        FormulaCatalog.setParam(&fp, index: 0, value: cx * cosA - cy * sinA)
        FormulaCatalog.setParam(&fp, index: 1, value: cx * sinA + cy * cosA)
    }
    override var supportedEffectTags: Set<EffectTag> { Self.universalEffectTags.union([.polarRotation]) }
    override func defaultFormulaParams() -> FormulaParams {
        var fp = Self.baseFormulaParams()
        fp.params.0 = -0.2; fp.params.1 = 0.8; fp.params.4 = 10.0
        FormulaCatalog.normalizeRotationFlags(&fp)
        return fp
    }
    override var defaultTripletBindings: [(slot: GestureSlot, groupName: String)] {
        [
            (GestureSlot(hand: .right, finger: .middle), "C"),
        ]
    }
    override var defaultViewState: FractalViewDefaults {
        Self.juliaLikeView(position: SIMD3<Float>(0.1, 0.1, -1.45))
    }
}

private final class OctahedronDescriptor: FractalTypeDescriptor, @unchecked Sendable {
    init() {
        super.init(rawValue: 11, displayName: "Octahedron", icon: "diamond",
                   category: "Kaleidoscopic IFS", codableString: "octahedron", isSelectableInUI: true)
    }
    override func primaryEquation() -> String? { "p_{n+1} = scale * fold_octahedral(p_n) + c" }
    override func defaultFormulaParams() -> FormulaParams {
        var fp = Self.baseFormulaParams()
        fp.params.0 = 2.0; fp.params.1 = 1.0
        FormulaCatalog.normalizeRotationFlags(&fp)
        return fp
    }
}

private final class MengerSphereDescriptor: FractalTypeDescriptor, @unchecked Sendable {
    init() {
        super.init(rawValue: 14, displayName: "Menger Sphere", icon: "circle.grid.cross",
                   category: "Kaleidoscopic IFS", codableString: "mengerSphere", isSelectableInUI: true)
    }
    override func primaryEquation() -> String? { "p_{n+1} = scale * blend_menger_sphere(p_n) + c" }
    override func defaultFormulaParams() -> FormulaParams {
        var fp = Self.baseFormulaParams()
        fp.params.0 = 3.0; fp.params.1 = 1.0; fp.params.2 = 1.0; fp.params.3 = 1.0
        FormulaCatalog.normalizeRotationFlags(&fp)
        return fp
    }
}

private final class TheliPseudoKleinianDescriptor: FractalTypeDescriptor, @unchecked Sendable {
    init() {
        super.init(rawValue: 15, displayName: "Theli Pseudo Kleinian", icon: "cube",
                   category: "Hybrid Folds", codableString: "theliPseudoKleinian", isSelectableInUI: true)
    }
    override func primaryEquation() -> String? { "p_{n+1} = fold(p_n) + c" }
    override func defaultFormulaParams() -> FormulaParams {
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

private final class KleinianDescriptor: FractalTypeDescriptor, @unchecked Sendable {
    init() {
        super.init(rawValue: 17, displayName: "Kleinian", icon: "wand.and.stars",
                   category: "Hybrid Folds", codableString: "kleinian", isSelectableInUI: true)
    }
    override func primaryEquation() -> String? { "z_{n+1} = fold(z_n) + c" }
    override var defaultTripletBindings: [(slot: GestureSlot, groupName: String)] {
        [
            (GestureSlot(hand: .left, finger: .middle), "Mins"),
            (GestureSlot(hand: .right, finger: .middle), "Maxs"),
        ]
    }
    override func defaultFormulaParams() -> FormulaParams {
        var fp = Self.baseFormulaParams()
        fp.params.0 = -0.3252; fp.params.1 = -0.7862; fp.params.2 = -0.0948
        fp.params.3 = 0.69
        fp.params.4 = 0.35; fp.params.5 = 1.0; fp.params.6 = 1.22
        fp.params.7 = 0.84
        FormulaCatalog.normalizeRotationFlags(&fp)
        return fp
    }
}

// MARK: - Custom (runtime-compiled embedded formula)

/// Descriptor for the single active embedded formula loaded from a `.threshfx`
/// payload (or embedded inside a `.threshanim` / `.threshscene` file).
/// Built dynamically by `FractalTypeRegistry.registerCustom(_:)`.
///
/// Unlike the static types, its displayName/category/isSelectableInUI are derived
/// at runtime from the formula, so it has its own init (not the uniform 6-scalar
/// designated init). `formula` and all stored props stay `let` so the shared
/// overlay instance is safe across threads (see registerCustom).
///
/// Until a real formula is registered, the registry holds `placeholder`, which
/// keeps lookups safe but reports `isSelectableInUI = false` so the picker hides it.
final class CustomFractalDescriptor: FractalTypeDescriptor, @unchecked Sendable {
    private let formula: EmbeddedFormula?

    init(formula: EmbeddedFormula) {
        self.formula = formula
        super.init(rawValue: 1000, displayName: formula.name, icon: "scroll",
                   category: formula.category ?? "Custom", codableString: "custom", isSelectableInUI: true)
    }

    private init() {
        self.formula = nil
        super.init(rawValue: 1000, displayName: "Custom Formula", icon: "scroll",
                   category: "Custom", codableString: "custom", isSelectableInUI: false)
    }

    /// Empty descriptor used until an embedded formula is registered.
    static let placeholder = CustomFractalDescriptor()

    override func defaultFormulaParams() -> FormulaParams {
        var fp = Self.baseFormulaParams()
        if let formula {
            for p in formula.params {
                FormulaCatalog.setParam(&fp, index: p.index, value: p.`default`)
            }
        }
        FormulaCatalog.normalizeRotationFlags(&fp)
        return fp
    }
}
