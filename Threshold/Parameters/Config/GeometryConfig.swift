//
//  GeometryConfig.swift
//  Threshold
//
//  Domain config: fractal type, formula params, position, scale, rotation.
//  Part of the RenderSettings decomposition (Phase 1).
//

import Foundation
import simd

struct GeometryConfig: Codable, Sendable {
    // Fractal type and formula
    var fractalType: FractalModelType = .mandelbox
    var formulaParams: FormulaParams = FractalModelType.mandelbox.defaultFormulaParams()

    // Core shape parameters
    var minDistance: Float = 0.8
    var fractalScale: Float = 2.8
    var foldingLimit: Float = 1.0
    var sphereRadius: Float = 0.5

    // Position & scale
    var position: SIMD3<Float> = .zero
    var scale: Float = 1.0

    // Detail transform (two-point grab)
    var worldRotation: simd_quatf = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    var detailScale: Float = 1.0


    // MARK: - Codable

    // FormulaParams is a C struct (not automatically Codable).
    // We encode/decode its 16 float slots via FormulaCatalog helpers.

    enum CodingKeys: String, CodingKey {
        case fractalType, formulaParamValues
        case minDistance, fractalScale, foldingLimit, sphereRadius
        case position, scale
        case worldRotationX, worldRotationY, worldRotationZ, worldRotationW
        case detailScale
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(fractalType, forKey: .fractalType)

        // Serialize FormulaParams as [Float]
        var vals = [Float](repeating: 0, count: 16)
        for i in 0..<16 { vals[i] = FormulaCatalog.getParam(formulaParams, index: i) }
        try c.encode(vals, forKey: .formulaParamValues)

        try c.encode(minDistance, forKey: .minDistance)
        try c.encode(fractalScale, forKey: .fractalScale)
        try c.encode(foldingLimit, forKey: .foldingLimit)
        try c.encode(sphereRadius, forKey: .sphereRadius)
        try c.encode(position, forKey: .position)
        try c.encode(scale, forKey: .scale)

        try c.encode(worldRotation.imag.x, forKey: .worldRotationX)
        try c.encode(worldRotation.imag.y, forKey: .worldRotationY)
        try c.encode(worldRotation.imag.z, forKey: .worldRotationZ)
        try c.encode(worldRotation.real, forKey: .worldRotationW)
        try c.encode(detailScale, forKey: .detailScale)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fractalType = try c.decodeIfPresent(FractalModelType.self, forKey: .fractalType) ?? .mandelbox

        if let vals = try c.decodeIfPresent([Float].self, forKey: .formulaParamValues) {
            formulaParams = fractalType.defaultFormulaParams()
            for i in 0..<min(16, vals.count) {
                FormulaCatalog.setParam(&formulaParams, index: i, value: vals[i])
            }
        } else {
            formulaParams = fractalType.defaultFormulaParams()
        }

        minDistance = try c.decodeIfPresent(Float.self, forKey: .minDistance) ?? 0.8
        fractalScale = try c.decodeIfPresent(Float.self, forKey: .fractalScale) ?? 2.8
        foldingLimit = try c.decodeIfPresent(Float.self, forKey: .foldingLimit) ?? 1.0
        sphereRadius = try c.decodeIfPresent(Float.self, forKey: .sphereRadius) ?? 0.5
        position = try c.decodeIfPresent(SIMD3<Float>.self, forKey: .position) ?? .zero
        scale = try c.decodeIfPresent(Float.self, forKey: .scale) ?? 1.0

        let rx = try c.decodeIfPresent(Float.self, forKey: .worldRotationX) ?? 0
        let ry = try c.decodeIfPresent(Float.self, forKey: .worldRotationY) ?? 0
        let rz = try c.decodeIfPresent(Float.self, forKey: .worldRotationZ) ?? 0
        let rw = try c.decodeIfPresent(Float.self, forKey: .worldRotationW) ?? 1
        worldRotation = simd_quatf(ix: rx, iy: ry, iz: rz, r: rw).normalized
        detailScale = try c.decodeIfPresent(Float.self, forKey: .detailScale) ?? 1.0
    }

    init() {}
}

// MARK: - Equatable
// FormulaParams is a C struct and simd_quatf lacks auto-synthesis.

extension GeometryConfig: Equatable {
    static func == (lhs: GeometryConfig, rhs: GeometryConfig) -> Bool {
        guard lhs.fractalType == rhs.fractalType,
              lhs.minDistance == rhs.minDistance,
              lhs.fractalScale == rhs.fractalScale,
              lhs.foldingLimit == rhs.foldingLimit,
              lhs.sphereRadius == rhs.sphereRadius,
              lhs.position == rhs.position,
              lhs.scale == rhs.scale,
              lhs.detailScale == rhs.detailScale
        else { return false }

        // Compare simd_quatf component-wise
        let lq = lhs.worldRotation, rq = rhs.worldRotation
        guard lq.real == rq.real, lq.imag == rq.imag else { return false }

        // Compare FormulaParams slot-by-slot
        for i in 0..<16 {
            if FormulaCatalog.getParam(lhs.formulaParams, index: i) !=
               FormulaCatalog.getParam(rhs.formulaParams, index: i) {
                return false
            }
        }
        return true
    }
}
