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

    // Per-target music-reactive mappings
    var musicReactiveMappings: [MusicReactiveMapping] = []

    // Per-triplet gain multiplier (keyed by triplet groupName, default 1.0)
    var tripletMusicGains: [String: Float] = [:]

    // MARK: - Validation

    mutating func clamp() {
        fractalAudioAmount = max(0.0, min(1.0, fractalAudioAmount))
        fractalBeatPunch = max(0.0, min(1.0, fractalBeatPunch))
        bassSensitivity = max(0.0, min(2.0, bassSensitivity))
        midSensitivity = max(0.0, min(2.0, midSensitivity))
        trebleSensitivity = max(0.0, min(2.0, trebleSensitivity))
        beatSensitivity = max(0.0, min(2.0, beatSensitivity))
    }
}
