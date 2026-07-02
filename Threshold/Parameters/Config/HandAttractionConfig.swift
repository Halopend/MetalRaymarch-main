//
//  HandAttractionConfig.swift
//  Threshold
//
//  Domain config: an interaction sphere on each visionOS hand-tracking palm
//  that pulls or pushes the fractal surface relative to the hand — the
//  signed generalization of the Safety Bubble's push-away carve.
//  visionOS only (needs hand tracking).
//

import Foundation

struct HandAttractionConfig: Codable, Equatable, Sendable {
    // Off by default — an experimental, opt-in interaction, unlike the
    // comfort-driven Safety Bubble.
    var enabled: Bool = false
    var radius: Float = 0.35     // 0.05 - 1.0 meters — per-hand influence radius
    // Signed: negative = Repel (surface recoils from the hand, the default
    // feel), positive = Attract (surface reaches for the hand). 0 = off.
    var strength: Float = -0.35
    // Attract-only: carves a small pocket right at the hand so it still
    // reads as a place for the hand to sit, even while the surrounding
    // surface pulls toward it (dual-sphere: outer attract shell + inner
    // repel hollow).
    var pocketEnabled: Bool = false

    // MARK: - Validation

    mutating func clamp() {
        radius = radius.clamped(to: 0.05...1.0)
        strength = strength.clamped(to: -1.0...1.0)
    }
}
