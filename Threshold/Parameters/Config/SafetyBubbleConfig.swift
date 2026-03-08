//
//  SafetyBubbleConfig.swift
//  Threshold
//
//  Domain config: safety bubble around the camera to prevent clipping.
//  Part of the RenderSettings decomposition (Phase 1).
//

import Foundation

struct SafetyBubbleConfig: Codable, Equatable, Sendable {
    var enabled: Bool = false
    var radius: Float = 1.8        // 0.05 - 2.5 meters
    var shape: Float = 0.0         // 0 = sphere, 1 = cube, intermediate = morph
    var fadeEnabled: Bool = true
    var fadeWidth: Float = 0.1     // 0.0 - 1.0
    var strength: Float = 0.5     // 0.0 - 1.0

    // MARK: - Validation

    mutating func clamp() {
        radius = max(0.05, min(2.5, radius))
        shape = max(0.0, min(1.0, shape))
        fadeWidth = max(0.0, min(1.0, fadeWidth))
        strength = max(0.0, min(1.0, strength))
    }

    /// Compatibility alias matching the legacy `safetyBubbleBlend` name.
    var blend: Float {
        get { strength }
        set { strength = max(0.0, min(1.0, newValue)) }
    }
}
