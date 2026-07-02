//
//  HandAttractionConfig.swift
//  Threshold
//
//  Domain config: an interaction sphere on each visionOS hand-tracking palm
//  that pulls the fractal surface toward the hand — the inverse of the
//  Safety Bubble's push-away carve. visionOS only (needs hand tracking).
//

import Foundation

struct HandAttractionConfig: Codable, Equatable, Sendable {
    // Off by default — an experimental, opt-in interaction, unlike the
    // comfort-driven Safety Bubble.
    var enabled: Bool = false
    var radius: Float = 0.35     // 0.05 - 1.0 meters — per-hand influence radius
    var strength: Float = 0.5    // 0.0 - 1.0 — how strongly/softly the surface reaches for the hand

    // MARK: - Validation

    mutating func clamp() {
        radius = radius.clamped(to: 0.05...1.0)
        strength = strength.clamped(to: 0.0...1.0)
    }
}
