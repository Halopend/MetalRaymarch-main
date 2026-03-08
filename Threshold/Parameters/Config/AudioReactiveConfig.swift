//
//  AudioReactiveConfig.swift
//  Threshold
//
//  Domain config: audio reactivity settings and music-reactive mappings.
//  Part of the RenderSettings decomposition (Phase 1).
//

import Foundation

struct AudioReactiveConfig: Codable, Equatable, Sendable {
    // Master toggle and overall amount
    var fractalAudioReactiveEnabled: Bool = false
    var fractalAudioAmount: Float = 0.25       // 0.0 - 1.0
    var fractalBeatPunch: Float = 0.3          // 0.0 - 1.0

    // Band sensitivities
    var bassSensitivity: Float = 1.0           // 0.0 - 2.0
    var midSensitivity: Float = 1.0            // 0.0 - 2.0
    var trebleSensitivity: Float = 1.0         // 0.0 - 2.0
    var beatSensitivity: Float = 1.0           // 0.0 - 2.0

    // Visualizer
    var visualizerMode: Int32 = 0
    var visualizerIntensity: Float = 0.5       // 0.0 - 1.0

    // Per-target music-reactive mappings
    var musicReactiveMappings: [MusicReactiveMapping] = []

    // Legacy boolean toggles (derived from musicReactiveMappings in RenderSettings)
    var fractalAudioAffectsScale: Bool = false
    var fractalAudioAffectsFolding: Bool = false
    var fractalAudioAffectsRadius: Bool = false
    var fractalAudioAffectsColorMix: Bool = false
    var fractalAudioAffectsGlow: Bool = false
    var fractalAudioAffectsFog: Bool = false
    var fractalAudioAffectsBloom: Bool = false
    var fractalAudioAffectsHueSpeed: Bool = false
    var fractalAudioAffectsSaturation: Bool = false
    var fractalAudioAffectsIterations: Bool = false

    // MARK: - Validation

    mutating func clamp() {
        fractalAudioAmount = max(0.0, min(1.0, fractalAudioAmount))
        fractalBeatPunch = max(0.0, min(1.0, fractalBeatPunch))
        bassSensitivity = max(0.0, min(2.0, bassSensitivity))
        midSensitivity = max(0.0, min(2.0, midSensitivity))
        trebleSensitivity = max(0.0, min(2.0, trebleSensitivity))
        beatSensitivity = max(0.0, min(2.0, beatSensitivity))
        visualizerIntensity = max(0.0, min(1.0, visualizerIntensity))
    }
}
