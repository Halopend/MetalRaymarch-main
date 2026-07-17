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
    case mandelbulbJulia   = 5
    case quaternionJulia   = 6
    case octahedron        = 11
    case mengerSphere      = 14
    case theliPseudoKleinian = 15
    case kleinian              = 17
    case boxFoldMandelbulb     = 18
    /// Precompiled analytic seed used by the Transformations primitive menu.
    /// The selected primitive is carried in FormulaParams; saved scenes may also
    /// embed its source/attribution without requiring runtime Metal compilation.
    case constructionPrimitive = 23
    // Note: rawValue 20 was the removed `boxSphereFolder` type; old scenes that
    // encoded it decode to `.mandelbox` (see the Codable extension below).
    // Note: rawValue 21 is reserved for the legacy `mandelboxSphereProjection`
    // back-compat alias (decodes to `.mandelbox`); see the Codable extension below.
    // rawValue 22 was the removed `bulatovLimitSet` type; old scenes that encoded
    // it decode to `.mandelbox` (see the Codable extension below).
    /// Sentinel for runtime-compiled DE shaders (.threshfx). Mirrors
    /// `FractalTypeCustom` in ShaderTypes.h. The single active embedded formula
    /// is registered with `FractalTypeRegistry` and `FormulaCatalog` at load time.
    case custom                  = 1000
    
    /// Descriptor from the registry — all metadata is defined there.
    var descriptor: FractalTypeDescriptor { FractalTypeRegistry.descriptor(for: self) }

    var displayName: String { descriptor.displayName }
    
    var supportedCoreGestureActions: [FingerGestureAction] { descriptor.supportedCoreGestureActions }
    var icon: String { descriptor.icon }
    var category: String { descriptor.category }

    /// Quick check whether a given effect tag is meaningful for this fractal.
    func supports(_ tag: EffectTag) -> Bool { descriptor.supportedEffectTags.contains(tag) }

    /// Quick check whether a given space-domain transform applies to this fractal.
    func supports(_ transform: SpaceTransform) -> Bool { descriptor.supportedSpaceTransforms.contains(transform) }

    func defaultFormulaParams() -> FormulaParams {
        if FormulaCatalog.shared.descriptor(for: self) != nil {
            return FormulaCatalog.shared.buildParams(for: self)
        }
        return descriptor.defaultFormulaParams()
    }
}

extension FractalModelType {
    /// Types shown in the UI picker (descriptor.isSelectableInUI == true).
    static let selectableCases: [FractalModelType] = allCases.filter { $0.descriptor.isSelectableInUI }
}

// MARK: - Human-Readable Codable

extension FractalModelType: Codable {
    private var codableString: String { descriptor.codableString }

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
        }
        if let raw = try? container.decode(Int32.self) {
            if let value = FractalModelType(rawValue: raw) {
                self = value
                return
            }
        }
        // Back-compat alias: the dedicated "mandelboxSphereProjection" type
        // (rawValue 21) was folded into base `.mandelbox` + the Space-tab
        // "Sphere Projection" control. Old scenes/animations/presets that encoded
        // it (by string or by Int32 21) must still decode — map both to
        // `.mandelbox`. FractalPreset/AnimationScene additionally turn the
        // sphere-projection fields on when they see this legacy marker so the
        // saved look reproduces (params[4]/[5] → projection blend/radius).
        if let str = try? container.decode(String.self), str == "mandelboxSphereProjection" {
            self = .mandelbox
            return
        }
        if let raw = try? container.decode(Int32.self), raw == 21 {
            self = .mandelbox
            return
        }
        // Back-compat: the `bulatovLimitSet` (rawValue 22) and `boxSphereFolder`
        // (rawValue 20) types were removed. Old scenes/animations/presets that
        // encoded either (by string or Int32) fall back to `.mandelbox` so they
        // still load.
        if let str = try? container.decode(String.self),
           str == "bulatovLimitSet" || str == "boxSphereFolder" {
            self = .mandelbox
            return
        }
        if let raw = try? container.decode(Int32.self), raw == 22 || raw == 20 {
            self = .mandelbox
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container, debugDescription: "Invalid FractalModelType value")
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(codableString)
    }
}
