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
    var fractalAudioDamping: Float = 0.0       // 0.0 - 3.0

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
        // isFinite guards: range-clamping alone does not protect against NaN/Inf
        // values that can be restored from a save file corrupted by a power-loss
        // event (min/max with NaN propagate in Swift's generic Comparable path).
        fractalAudioAmount  = fractalAudioAmount.isFinite  ? fractalAudioAmount.clamped(to: 0.0...1.0)  : 0.25
        fractalBeatPunch    = fractalBeatPunch.isFinite    ? fractalBeatPunch.clamped(to: 0.0...1.0)    : 0.3
        fractalAudioDamping = fractalAudioDamping.isFinite ? fractalAudioDamping.clamped(to: 0.0...3.0) : 0.0
        bassSensitivity     = bassSensitivity.isFinite     ? bassSensitivity.clamped(to: 0.0...2.0)     : 1.0
        midSensitivity      = midSensitivity.isFinite      ? midSensitivity.clamped(to: 0.0...2.0)      : 1.0
        trebleSensitivity   = trebleSensitivity.isFinite   ? trebleSensitivity.clamped(to: 0.0...2.0)   : 1.0
        beatSensitivity     = beatSensitivity.isFinite     ? beatSensitivity.clamped(to: 0.0...2.0)     : 1.0
        // Sanitize per-triplet gain map: remove any NaN/Inf or out-of-range entries.
        tripletMusicGains = tripletMusicGains.mapValues { v in
            v.isFinite ? v.clamped(to: 0.0...4.0) : 1.0
        }
    }
}
