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
    /// Optional post-sphere-fold radial projection layered on the standard
    /// Mandelbox ("Accidental Sphere Projection" look) as a togglable option.
    var sphereProjectionEnabled: Bool = false
    var sphereProjectionBlend: Float = 1.0
    var sphereProjectionRadius: Float = 1.0
    var platformRadius: Float = 1.888
    /// When `false`, the renderer skips building the glass-floor field in
    /// the immersive space. The radius value is preserved so toggling back
    /// on restores the previous size. Defaults to `true` for parity with
    /// the always-on behavior the app shipped with.
    var platformEnabled: Bool = true

    enum CodingKeys: String, CodingKey {
        case showMusicShortcuts, lightingPlay, lightingMode
        case sphericalInversionMode, sphericalInversionRadius, platformRadius
        case sphereProjectionEnabled, sphereProjectionBlend, sphereProjectionRadius
        case platformEnabled
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        showMusicShortcuts = try container.decodeIfPresent(Bool.self, forKey: .showMusicShortcuts) ?? false
        lightingPlay = try container.decodeIfPresent(Bool.self, forKey: .lightingPlay) ?? false
        lightingMode = try container.decodeIfPresent(LightingMode.self, forKey: .lightingMode) ?? .animated
        sphericalInversionMode = try container.decodeIfPresent(SphericalInversionMode.self, forKey: .sphericalInversionMode) ?? .off
        sphericalInversionRadius = try container.decodeIfPresent(Float.self, forKey: .sphericalInversionRadius) ?? 2.0
        sphereProjectionEnabled = try container.decodeIfPresent(Bool.self, forKey: .sphereProjectionEnabled) ?? false
        sphereProjectionBlend = try container.decodeIfPresent(Float.self, forKey: .sphereProjectionBlend) ?? 1.0
        sphereProjectionRadius = try container.decodeIfPresent(Float.self, forKey: .sphereProjectionRadius) ?? 1.0
        // Clamp on decode so previously-saved larger radii (old max was 3.0) snap into
        // the new 0.5…2.5 m range and stay consistent with the slider bounds.
        platformRadius = min(2.5, max(0.5, try container.decodeIfPresent(Float.self, forKey: .platformRadius) ?? 1.888))
        platformEnabled = try container.decodeIfPresent(Bool.self, forKey: .platformEnabled) ?? true
    }
}
