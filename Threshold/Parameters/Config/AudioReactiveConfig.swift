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
    var fractalAudioDamping: Float = 0.0       // 0.0 - 1.0

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

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fractalAudioReactiveEnabled = try container.decodeIfPresent(Bool.self, forKey: .fractalAudioReactiveEnabled) ?? false
        fractalAudioAmount = try container.decodeIfPresent(Float.self, forKey: .fractalAudioAmount) ?? 0.25
        fractalBeatPunch = try container.decodeIfPresent(Float.self, forKey: .fractalBeatPunch) ?? 0.3
        fractalAudioDamping = try container.decodeIfPresent(Float.self, forKey: .fractalAudioDamping) ?? 0.0
        bassSensitivity = try container.decodeIfPresent(Float.self, forKey: .bassSensitivity) ?? 1.0
        midSensitivity = try container.decodeIfPresent(Float.self, forKey: .midSensitivity) ?? 1.0
        trebleSensitivity = try container.decodeIfPresent(Float.self, forKey: .trebleSensitivity) ?? 1.0
        beatSensitivity = try container.decodeIfPresent(Float.self, forKey: .beatSensitivity) ?? 1.0
        musicReactiveMappings = try container.decodeIfPresent([MusicReactiveMapping].self, forKey: .musicReactiveMappings) ?? []
        tripletMusicGains = try container.decodeIfPresent([String: Float].self, forKey: .tripletMusicGains) ?? [:]
        clamp()
    }
    // `CodingKeys` and `encode(to:)` are both synthesized; `init(from:)` stays
    // custom only to supply defaults for missing keys in older saved data.

    mutating func clamp() {
        fractalAudioAmount = max(0.0, min(1.0, fractalAudioAmount))
        fractalBeatPunch = max(0.0, min(1.0, fractalBeatPunch))
        fractalAudioDamping = max(0.0, min(1.0, fractalAudioDamping))
        bassSensitivity = max(0.0, min(2.0, bassSensitivity))
        midSensitivity = max(0.0, min(2.0, midSensitivity))
        trebleSensitivity = max(0.0, min(2.0, trebleSensitivity))
        beatSensitivity = max(0.0, min(2.0, beatSensitivity))
    }
}
