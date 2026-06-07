//
//  DisplayConfig.swift
//  Threshold
//
//  Domain config: HUD, display toggles, and lighting play/mode.
//  Part of the RenderSettings decomposition (Phase 1).
//

import Foundation

struct DisplayConfig: Codable, Equatable, Sendable {
    var showMusicShortcuts: Bool = false
    var lightingPlay: Bool = false
    var lightingMode: LightingMode = .animated
    var sphericalInversionMode: SphericalInversionMode = .off
    var sphericalInversionRadius: Float = 2.0
    var platformRadius: Float = 3.0

    enum CodingKeys: String, CodingKey {
        case showMusicShortcuts, lightingPlay, lightingMode
        case sphericalInversionMode, sphericalInversionRadius, platformRadius
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        showMusicShortcuts = try container.decodeIfPresent(Bool.self, forKey: .showMusicShortcuts) ?? false
        lightingPlay = try container.decodeIfPresent(Bool.self, forKey: .lightingPlay) ?? false
        lightingMode = try container.decodeIfPresent(LightingMode.self, forKey: .lightingMode) ?? .animated
        sphericalInversionMode = try container.decodeIfPresent(SphericalInversionMode.self, forKey: .sphericalInversionMode) ?? .off
        sphericalInversionRadius = try container.decodeIfPresent(Float.self, forKey: .sphericalInversionRadius) ?? 2.0
        platformRadius = try container.decodeIfPresent(Float.self, forKey: .platformRadius) ?? 3.0
    }
}
