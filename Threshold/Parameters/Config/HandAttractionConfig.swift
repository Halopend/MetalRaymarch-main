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
    /// Hand Effects beta flag (default off). Gates the Shape → Hands tab and
    /// the effect itself until the feature graduates. User opts in via
    /// Settings → Experimental → "Hand Effects (Beta)".
    static let betaUserDefaultsKey = "handEffectsBeta"
    static var betaEnabled: Bool {
        UserDefaults.standard.bool(forKey: betaUserDefaultsKey)
    }

    // BETA: off by default. The tuned attract-with-pocket feel (2026-07-02
    // user calibration) is preserved as the preset the user gets when they
    // opt in via Settings → "Hand Effects (Beta)".
    var enabled: Bool = false
    var radius: Float = 0.36     // 0.05 - 1.0 meters — per-hand influence radius
    // Signed: negative = Repel (surface recoils from the hand), positive =
    // Attract (surface reaches for the hand). 0 = off.
    var strength: Float = 0.39
    // Attract-only: carves a small pocket right at the hand so it still
    // reads as a place for the hand to sit, even while the surrounding
    // surface pulls toward it (dual-sphere: outer attract shell + inner
    // repel hollow).
    var pocketEnabled: Bool = true
    // Ball size as a fraction of the influence radius (the radius is the
    // smooth-blend reach; the ball is the solid core).
    var ballScale: Float = 0.5
    // Blend softness (×ball radius): how gradually the effect transitions
    // into the surrounding surface. Decoupled from strength.
    var softness: Float = 0.73
    // Pocket hollow size (×ball radius).
    var pocketSize: Float = 0.77
    // Pocket blend softness (×pocket radius).
    var pocketSoftness: Float = 0.18
    // Reach offset, meters: projects the ball outward from the body center
    // through the hand, so it floats in front of the palm instead of on it.
    var projectionDistance: Float = 0.08
    // Forearm capsule: always CARVES empty space along the wrist→elbow
    // segment (regardless of the signed hand strength), so the real forearm
    // stays visible — the compositor draws passthrough hands/arms only where
    // the scene depth is farther than the limb.
    var forearmEnabled: Bool = false
    // Forearm capsule radius, meters.
    var forearmRadius: Float = 0.06

    // MARK: - Codable (tolerant decode so adding fields never resets the
    // user's saved config to defaults)

    private enum CodingKeys: String, CodingKey {
        case enabled, radius, strength, pocketEnabled
        case ballScale, softness, pocketSize, pocketSoftness, projectionDistance
        case forearmEnabled, forearmRadius
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        radius = try c.decodeIfPresent(Float.self, forKey: .radius) ?? 0.36
        strength = try c.decodeIfPresent(Float.self, forKey: .strength) ?? 0.39
        pocketEnabled = try c.decodeIfPresent(Bool.self, forKey: .pocketEnabled) ?? true
        ballScale = try c.decodeIfPresent(Float.self, forKey: .ballScale) ?? 0.5
        softness = try c.decodeIfPresent(Float.self, forKey: .softness) ?? 0.73
        pocketSize = try c.decodeIfPresent(Float.self, forKey: .pocketSize) ?? 0.77
        pocketSoftness = try c.decodeIfPresent(Float.self, forKey: .pocketSoftness) ?? 0.18
        projectionDistance = try c.decodeIfPresent(Float.self, forKey: .projectionDistance) ?? 0.08
        forearmEnabled = try c.decodeIfPresent(Bool.self, forKey: .forearmEnabled) ?? false
        forearmRadius = try c.decodeIfPresent(Float.self, forKey: .forearmRadius) ?? 0.06
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
        forearmRadius = forearmRadius.clamped(to: 0.02...0.3)
    }
}

// MARK: - Shader-facing hand block (single source — TECH_DEBT.md #2 + #8d)

extension HandFieldParams {
    /// THE fallback shape (ball scale, blend softness, pocket size, pocket
    /// softness). Every path that needs a disabled-but-well-formed hand block
    /// uses `.off`, so this default can never again drift between the Mac,
    /// Quick Look, and visionOS uniform builders (it did, three times).
    static let defaultShape = SIMD4<Float>(0.35, 1.0, 0.5, 0.6)

    /// Disabled hand block for paths without ARKit hand tracking (Mac + QL).
    static var off: HandFieldParams {
        var p = HandFieldParams()
        p.shape = Self.defaultShape
        return p
    }
}
