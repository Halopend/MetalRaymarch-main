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
    // Ball size as a fraction of the influence radius (the radius is the
    // smooth-blend reach; the ball is the solid core).
    var ballScale: Float = 0.35
    // Blend softness (×ball radius): how gradually the effect transitions
    // into the surrounding surface. Decoupled from strength.
    var softness: Float = 1.0
    // Pocket hollow size (×ball radius).
    var pocketSize: Float = 0.5
    // Pocket blend softness (×pocket radius).
    var pocketSoftness: Float = 0.6
    // Reach offset, meters: projects the ball outward from the body center
    // through the hand, so it floats in front of the palm instead of on it.
    var projectionDistance: Float = 0.0

    // MARK: - Codable (tolerant decode so adding fields never resets the
    // user's saved config to defaults)

    private enum CodingKeys: String, CodingKey {
        case enabled, radius, strength, pocketEnabled
        case ballScale, softness, pocketSize, pocketSoftness, projectionDistance
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        radius = try c.decodeIfPresent(Float.self, forKey: .radius) ?? 0.35
        strength = try c.decodeIfPresent(Float.self, forKey: .strength) ?? -0.35
        pocketEnabled = try c.decodeIfPresent(Bool.self, forKey: .pocketEnabled) ?? false
        ballScale = try c.decodeIfPresent(Float.self, forKey: .ballScale) ?? 0.35
        softness = try c.decodeIfPresent(Float.self, forKey: .softness) ?? 1.0
        pocketSize = try c.decodeIfPresent(Float.self, forKey: .pocketSize) ?? 0.5
        pocketSoftness = try c.decodeIfPresent(Float.self, forKey: .pocketSoftness) ?? 0.6
        projectionDistance = try c.decodeIfPresent(Float.self, forKey: .projectionDistance) ?? 0.0
    }

    // MARK: - Validation

    mutating func clamp() {
        radius = radius.clamped(to: 0.05...1.0)
        strength = strength.clamped(to: -1.0...1.0)
        ballScale = ballScale.clamped(to: 0.1...1.0)
        softness = softness.clamped(to: 0.05...2.0)
        pocketSize = pocketSize.clamped(to: 0.1...1.5)
        pocketSoftness = pocketSoftness.clamped(to: 0.1...1.5)
        projectionDistance = projectionDistance.clamped(to: 0.0...1.0)
    }
}
