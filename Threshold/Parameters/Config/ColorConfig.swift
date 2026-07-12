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
    var colorSchemeContrast: Float = 1.08  // 0.75 - 1.5
    var colorSchemeGamma: Float = 0.85     // 0.2 - 2.0
    var colorSchemeVibrance: Float = 0.8   // 0.0 - 1.0
    var colorSchemeCurve: Float = 0.0      // -1.0 - 1.0
    var colorSchemeShadows: Float = -0.018 // -0.05 - 0.05
    var colorSchemeHighlights: Float = 0.02 // -0.5 - 1.0
    var lightingSoftness: Float = 0.35     // 0.0 - 1.0
    var cellShadingEnabled: Bool = false
    var cellShadingLevels: Float = 4.0     // 2.0 - 8.0
    var aoStrength: Float = 0.0            // 0.0 - 1.0 (0 = old flat ambient, default)
    var tonemapStrength: Float = 0.0       // 0.0 - 1.0 (0 = old plain clamp, default)
    /// 1 preserves the historical always-on vignette; 0 is fully off.
    var vignetteStrength: Float = 1.0

    // Auto-transition
    var colorSchemeAutoTransition: Bool = false
    var colorSchemeAutoInterval: Float = 30.0  // 5.0 - 120.0
    var colorSchemeTransitionDuration: Float = 2.0  // 0.1 - 10.0

    init() {}

    /// Tolerant domain decode: adding a color control must not make an older
    /// UserDefaults blob or SceneState lose the entire color domain.
    private enum CodingKeys: String, CodingKey {
        case colorScheme, gradientState
        case colorMix, colorIterations, colorSchemeSaturation, colorSchemeContrast
        case colorSchemeGamma, colorSchemeVibrance, colorSchemeCurve
        case colorSchemeShadows, colorSchemeHighlights, lightingSoftness
        case cellShadingEnabled, cellShadingLevels, aoStrength, tonemapStrength
        case vignetteStrength
        case colorSchemeAutoTransition, colorSchemeAutoInterval
        case colorSchemeTransitionDuration
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        colorScheme = try c.decodeIfPresent(ColorScheme.self, forKey: .colorScheme) ?? .classic
        gradientState = try c.decodeIfPresent(GradientState.self, forKey: .gradientState) ?? GradientState()
        colorMix = try c.decodeIfPresent(Float.self, forKey: .colorMix) ?? 0.5
        colorIterations = try c.decodeIfPresent(Float.self, forKey: .colorIterations) ?? 8.0
        colorSchemeSaturation = try c.decodeIfPresent(Float.self, forKey: .colorSchemeSaturation) ?? 1.7
        colorSchemeContrast = try c.decodeIfPresent(Float.self, forKey: .colorSchemeContrast) ?? 1.08
        colorSchemeGamma = try c.decodeIfPresent(Float.self, forKey: .colorSchemeGamma) ?? 0.85
        colorSchemeVibrance = try c.decodeIfPresent(Float.self, forKey: .colorSchemeVibrance) ?? 0.8
        colorSchemeCurve = try c.decodeIfPresent(Float.self, forKey: .colorSchemeCurve) ?? 0.0
        colorSchemeShadows = try c.decodeIfPresent(Float.self, forKey: .colorSchemeShadows) ?? -0.018
        colorSchemeHighlights = try c.decodeIfPresent(Float.self, forKey: .colorSchemeHighlights) ?? 0.02
        lightingSoftness = try c.decodeIfPresent(Float.self, forKey: .lightingSoftness) ?? 0.35
        cellShadingEnabled = try c.decodeIfPresent(Bool.self, forKey: .cellShadingEnabled) ?? false
        cellShadingLevels = try c.decodeIfPresent(Float.self, forKey: .cellShadingLevels) ?? 4.0
        aoStrength = try c.decodeIfPresent(Float.self, forKey: .aoStrength) ?? 0.0
        tonemapStrength = try c.decodeIfPresent(Float.self, forKey: .tonemapStrength) ?? 0.0
        vignetteStrength = try c.decodeIfPresent(Float.self, forKey: .vignetteStrength) ?? 1.0
        colorSchemeAutoTransition = try c.decodeIfPresent(Bool.self, forKey: .colorSchemeAutoTransition) ?? false
        colorSchemeAutoInterval = try c.decodeIfPresent(Float.self, forKey: .colorSchemeAutoInterval) ?? 30.0
        colorSchemeTransitionDuration = try c.decodeIfPresent(Float.self, forKey: .colorSchemeTransitionDuration) ?? 2.0
        clamp()
    }

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
        vignetteStrength = ControlCatalog.vignetteStrength.clamp(vignetteStrength)
        colorSchemeAutoInterval = ControlCatalog.colorSchemeAutoInterval.clamp(colorSchemeAutoInterval)
        colorSchemeTransitionDuration = ControlCatalog.colorSchemeTransitionDuration.clamp(colorSchemeTransitionDuration)
    }
}
