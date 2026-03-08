//
//  DisplayConfig.swift
//  Threshold
//
//  Domain config: HUD, display toggles, and lighting play/mode.
//  Part of the RenderSettings decomposition (Phase 1).
//

import Foundation

struct DisplayConfig: Codable, Equatable, Sendable {
    var showHUD: Bool = false
    var showMusicShortcuts: Bool = false
    var lightingPlay: Bool = false
    var lightingMode: LightingMode = .animated
}
