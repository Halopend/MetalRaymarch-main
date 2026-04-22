//
//  ColorConfig.swift
//  Threshold
//
//  Domain config: color scheme, gradient state, and color grading.
//  Part of the RenderSettings decomposition (Phase 1).
//

import Foundation

struct ColorConfig: Codable, Equatable, Sendable {
    // Color scheme / gradient preset
    var colorScheme: ColorScheme = .classic
    var gradientState: GradientState = GradientState()

    // Color grading
    var colorMix: Float = 0.5              // 0.0 - 1.0
    var colorIterations: Float = 5.0
    var colorSchemeSaturation: Float = 1.7 // 0.0 - 3.0
    var colorSchemeContrast: Float = 1.08  // 0.95 - 1.15
    var colorSchemeGamma: Float = 0.85     // 0.2 - 1.0
    var colorSchemeVibrance: Float = 0.8   // 0.0 - 1.0
    var colorSchemeCurve: Float = 0.0      // -1.0 - 1.0
    var colorSchemeShadows: Float = -0.018 // -0.05 - 0.05
    var colorSchemeHighlights: Float = 0.02 // -0.5 - 1.0
    var lightingSoftness: Float = 0.5      // 0.0 - 1.0

    // Auto-transition
    var colorSchemeAutoTransition: Bool = false
    var colorSchemeAutoInterval: Float = 30.0  // 5.0 - 120.0
    var colorSchemeTransitionDuration: Float = 2.0  // 0.1 - 10.0

    // MARK: - Validation

    mutating func clamp() {
        colorMix = max(0.0, min(1.0, colorMix))
        colorSchemeSaturation = max(0.0, min(3.0, colorSchemeSaturation))
        colorSchemeContrast = max(0.95, min(1.15, colorSchemeContrast))
        colorSchemeGamma = max(0.2, min(1.0, colorSchemeGamma))
        colorSchemeVibrance = max(0.0, min(1.0, colorSchemeVibrance))
        colorSchemeCurve = max(-1.0, min(1.0, colorSchemeCurve))
        colorSchemeShadows = max(-0.05, min(0.05, colorSchemeShadows))
        colorSchemeHighlights = max(-0.5, min(1.0, colorSchemeHighlights))
        lightingSoftness = max(0.0, min(1.0, lightingSoftness))
        colorSchemeAutoInterval = max(5.0, min(120.0, colorSchemeAutoInterval))
        colorSchemeTransitionDuration = max(0.1, min(10.0, colorSchemeTransitionDuration))
    }
}
