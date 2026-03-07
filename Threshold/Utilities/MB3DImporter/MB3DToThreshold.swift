//
//  MB3DToThreshold.swift
//  Threshold
//
//  Converts MB3DDecodedScene → Threshold preset JSON (.threshmp)
//

import Foundation

enum MB3DToThreshold {

    struct ConversionResult {
        let fractalType: String
        let params: [Float]        // 32-element params[] array
        let iterations: Int
        let position: [Float]      // [x, y, z]
        let detailScale: Float
        let warnings: [String]
    }

    /// Convert a decoded MB3D scene to Threshold parameters.
    static func convert(_ scene: MB3DDecodedScene) -> ConversionResult {
        var warnings: [String] = []

        // ── Fractal type ──
        let fractalType: String
        if let suggested = scene.suggestedThresholdType {
            fractalType = suggested
        } else if let primary = scene.formulaSlots.first {
            warnings.append("Unknown formula \(primary.formulaName) (ID \(primary.formulaID))")
            fractalType = "mandelbox"
        } else {
            warnings.append("No formula slots — defaulting to mandelbox")
            fractalType = "mandelbox"
        }

        // Hybrid warning
        if scene.formulaSlots.count > 1 {
            let names = scene.formulaSlots.map {
                "\($0.formulaName)(\($0.formulaID))"
            }
            warnings.append(
                "Hybrid: \(names.joined(separator: " + ")). Only primary imported.")
        }

        // ── Formula parameters → params[0..31] ──
        var params = [Float](repeating: 0, count: 32)
        if let primary = scene.primaryFormulaSlot {
            // Copy dOptionValue[0..15] → params[0..15]
            for (i, v) in primary.parameterValues.enumerated() where i < 16 {
                params[i] = Float(v)
            }
        }

        // ── Camera ──
        // MB3D: dXmid/dYmid/dZmid is the fractal centre.  dZoom controls scale.
        // stepWidth = 2.1345 / (zoom * width)
        let sw = scene.stepWidth > 0
            ? scene.stepWidth
            : 2.1345 / (scene.zoom * Double(max(scene.width, 1)))
        let scaleFactor = Float(sw * Double(scene.width) * 0.5)

        // Use the camera centre directly — Threshold can orbit around it
        var position: [Float] = [
            Float(scene.cameraX),
            Float(scene.cameraY),
            Float(scene.cameraZ)
        ]
        // If camera is at origin, push back a bit so user can see the fractal
        if position.allSatisfy({ abs($0) < 1e-10 }) {
            position = [0, 0, -1.5]
        }

        let detailScale = min(max(scaleFactor, 0.01), 10.0)
        let iterations = scene.primaryFormulaSlot?.iterations ?? scene.maxIterations

        return ConversionResult(
            fractalType: fractalType,
            params: params,
            iterations: iterations,
            position: position,
            detailScale: detailScale,
            warnings: warnings
        )
    }

    /// Export as Threshold preset JSON string (.threshmp compatible).
    static func exportPresetJSON(_ scene: MB3DDecodedScene, name: String? = nil) -> String {
        let result = convert(scene)
        let presetName = name ?? scene.title ?? "MB3D Import"

        var lines: [String] = ["{"]
        lines.append("  \"name\": \"\(presetName)\",")
        lines.append("  \"fractalType\": \"\(result.fractalType)\",")
        lines.append("  \"iterations\": \(result.iterations),")

        let paramStr = result.params.map { String($0) }.joined(separator: ", ")
        lines.append("  \"params\": [\(paramStr)],")

        let posStr = result.position.map { String($0) }.joined(separator: ", ")
        lines.append("  \"position\": [\(posStr)],")

        lines.append("  \"detailScale\": \(result.detailScale),")
        lines.append("  \"importSource\": \"Mandelbulb3D v\(scene.version)\",")

        if !result.warnings.isEmpty {
            let ws = result.warnings.map { "\"\($0)\"" }.joined(separator: ", ")
            lines.append("  \"importWarnings\": [\(ws)],")
        }

        if let primary = scene.primaryFormulaSlot {
            lines.append("  \"mb3d_formulaID\": \(primary.formulaID),")
            lines.append("  \"mb3d_formulaName\": \"\(primary.formulaName)\",")
        }

        lines.append("  \"mb3d_mandId\": \(scene.mandId),")
        lines.append("  \"mb3d_zoom\": \(scene.zoom),")
        lines.append("  \"mb3d_bailout\": \(scene.bailout),")
        lines.append("  \"mb3d_fov\": \(scene.fov)")
        lines.append("}")

        return lines.joined(separator: "\n")
    }
}
