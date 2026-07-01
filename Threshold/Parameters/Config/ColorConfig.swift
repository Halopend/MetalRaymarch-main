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
    var colorIterations: Float = 8.0   // 4.0 - 16.0 (matches runtime default; was 5.0)
    var colorSchemeSaturation: Float = 1.7 // 0.0 - 3.0
    var colorSchemeContrast: Float = 1.08  // 0.95 - 1.15
    var colorSchemeGamma: Float = 0.85     // 0.2 - 1.0
    var colorSchemeVibrance: Float = 0.8   // 0.0 - 1.0
    var colorSchemeCurve: Float = 0.0      // -1.0 - 1.0
    var colorSchemeShadows: Float = -0.018 // -0.05 - 0.05
    var colorSchemeHighlights: Float = 0.02 // -0.5 - 1.0
    var lightingSoftness: Float = 0.5      // 0.0 - 1.0
    var cellShadingEnabled: Bool = false
    var cellShadingLevels: Float = 4.0     // 2.0 - 8.0
    var aoStrength: Float = 0.0            // 0.0 - 1.0 (0 = old flat ambient, default)
    var tonemapStrength: Float = 0.0       // 0.0 - 1.0 (0 = old plain clamp, default)

    // Auto-transition
    var colorSchemeAutoTransition: Bool = false
    var colorSchemeAutoInterval: Float = 30.0  // 5.0 - 120.0
    var colorSchemeTransitionDuration: Float = 2.0  // 0.1 - 10.0

    // MARK: - Validation

    mutating func clamp() {
        colorMix = colorMix.clamped(to: ControlCatalog.colorMix)
        colorIterations = ControlCatalog.colorIterations.clamp(colorIterations)
        colorSchemeSaturation = colorSchemeSaturation.clamped(to: ControlCatalog.saturation)
        colorSchemeContrast = ControlCatalog.colorSchemeContrast.clamp(colorSchemeContrast)
        colorSchemeGamma = ControlCatalog.colorSchemeGamma.clamp(colorSchemeGamma)
        colorSchemeVibrance = ControlCatalog.colorSchemeVibrance.clamp(colorSchemeVibrance)
        colorSchemeCurve = ControlCatalog.colorSchemeCurve.clamp(colorSchemeCurve)
        colorSchemeShadows = ControlCatalog.colorSchemeShadows.clamp(colorSchemeShadows)
        colorSchemeHighlights = ControlCatalog.colorSchemeHighlights.clamp(colorSchemeHighlights)
        lightingSoftness = ControlCatalog.lightingSoftness.clamp(lightingSoftness)
        cellShadingLevels = ControlCatalog.cellShadingLevels.clamp(cellShadingLevels)
        aoStrength = ControlCatalog.aoStrength.clamp(aoStrength)
        tonemapStrength = ControlCatalog.tonemapStrength.clamp(tonemapStrength)
        colorSchemeAutoInterval = ControlCatalog.colorSchemeAutoInterval.clamp(colorSchemeAutoInterval)
        colorSchemeTransitionDuration = ControlCatalog.colorSchemeTransitionDuration.clamp(colorSchemeTransitionDuration)
    }
}
