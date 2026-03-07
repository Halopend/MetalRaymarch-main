//
//  MB3DImportService.swift
//  Threshold
//
//  In-app service to import MB3D parameter strings.
//  Can be called from a paste action, file import, or share sheet.
//

import Foundation

@MainActor
class MB3DImportService {

    struct ImportResult {
        let presetJSON: String
        let fractalType: String
        let params: [Float]
        let iterations: Int
        let position: [Float]
        let detailScale: Float
        let warnings: [String]
    }

    /// Try to import an MB3D parameter string.
    /// Returns nil if the string doesn't contain a valid MB3D block.
    static func tryImport(_ text: String, name: String? = nil) -> ImportResult? {
        // Locate the MB3D block
        guard let startRange = text.range(of: "Mandelbulb3D"),
              let openBrace = text[startRange.lowerBound...].firstIndex(of: "{"),
              let closeBrace = text[openBrace...].firstIndex(of: "}") else {
            return nil
        }

        let block = String(text[startRange.lowerBound...closeBrace])

        guard let scene = try? MB3DDecoder.decode(block) else {
            return nil
        }

        let conversion = MB3DToThreshold.convert(scene)
        let json = MB3DToThreshold.exportPresetJSON(scene, name: name)

        return ImportResult(
            presetJSON: json,
            fractalType: conversion.fractalType,
            params: conversion.params,
            iterations: conversion.iterations,
            position: conversion.position,
            detailScale: conversion.detailScale,
            warnings: conversion.warnings
        )
    }
}
