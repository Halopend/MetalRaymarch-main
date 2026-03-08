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


    // MARK: - Validation

    mutating func clamp() {
        minDistance = max(-5.0, min(15.0, minDistance))
        fractalScale = max(-5.0, min(8.0, fractalScale))
        foldingLimit = max(-10.0, min(30.0, foldingLimit))
        sphereRadius = max(-5.0, min(8.0, sphereRadius))
        let maxPos: Float = 100.0
        position.x = max(-maxPos, min(maxPos, position.x))
        position.y = max(-maxPos, min(maxPos, position.y))
        position.z = max(-maxPos, min(maxPos, position.z))
    }

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
        fractalType = try c.decode(FractalModelType.self, forKey: .fractalType)

        if let vals = try c.decodeIfPresent([Float].self, forKey: .formulaParamValues) {
            formulaParams = fractalType.defaultFormulaParams()
            for i in 0..<min(16, vals.count) {
                FormulaCatalog.setParam(&formulaParams, index: i, value: vals[i])
            }
        } else {
            formulaParams = fractalType.defaultFormulaParams()
        }

        minDistance = try c.decode(Float.self, forKey: .minDistance)
        fractalScale = try c.decode(Float.self, forKey: .fractalScale)
        foldingLimit = try c.decode(Float.self, forKey: .foldingLimit)
        sphereRadius = try c.decode(Float.self, forKey: .sphereRadius)
        position = try c.decode(SIMD3<Float>.self, forKey: .position)
        scale = try c.decode(Float.self, forKey: .scale)

        let rx = try c.decode(Float.self, forKey: .worldRotationX)
        let ry = try c.decode(Float.self, forKey: .worldRotationY)
        let rz = try c.decode(Float.self, forKey: .worldRotationZ)
        let rw = try c.decode(Float.self, forKey: .worldRotationW)
        worldRotation = simd_quatf(ix: rx, iy: ry, iz: rz, r: rw).normalized
        detailScale = try c.decode(Float.self, forKey: .detailScale)
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
