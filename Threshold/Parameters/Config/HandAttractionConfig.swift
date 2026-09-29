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
    // On by default. The tuned attract-with-pocket feel (2026-07-02 user
    // calibration) is the preset every user gets out of the box; fine-tuning
    // lives in Settings → Advanced → Hand Interaction.
    var enabled: Bool = true
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
    // Extra prediction trim, milliseconds, added on top of CompositorServices'
    // `trackableAnchorTime` when querying hand poses. ARKit's base prediction is
    // already applied by that timestamp (it is per-frame and variable, per
    // frame_timing.h), so this only compensates for latency the base does not
    // cover — chiefly this app's own render pipeline depth. 0 = trust ARKit.
    // Negative reaches *behind* photon time, which can suit a sculpting field
    // better than a registered overlay. Overshoot is visible: the DE bulge leads
    // the real hand and snaps when the predictor corrects.
    var predictionOffsetMs: Float = 0

    // MARK: - Codable (tolerant decode so adding fields never resets the
    // user's saved config to defaults)

    private enum CodingKeys: String, CodingKey {
        case enabled, radius, strength, pocketEnabled
        case ballScale, softness, pocketSize, pocketSoftness, projectionDistance
        case forearmEnabled, forearmRadius
        case predictionOffsetMs
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
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
        predictionOffsetMs = try c.decodeIfPresent(Float.self, forKey: .predictionOffsetMs) ?? 0
    }

    // MARK: - Validation

    mutating func clamp() {
        radius = radius.clamped(to: ControlCatalog.handAttractionRadius)
        strength = strength.clamped(to: ControlCatalog.handAttractionStrength)
        ballScale = ballScale.clamped(to: ControlCatalog.handAttractionBallScale)
        softness = softness.clamped(to: ControlCatalog.handAttractionSoftness)
        pocketSize = pocketSize.clamped(to: ControlCatalog.handAttractionPocketSize)
        pocketSoftness = pocketSoftness.clamped(to: ControlCatalog.handAttractionPocketSoftness)
        projectionDistance = projectionDistance.clamped(
            to: ControlCatalog.handAttractionProjectionDistance
        )
        forearmRadius = forearmRadius.clamped(to: ControlCatalog.handAttractionForearmRadius)
        predictionOffsetMs = predictionOffsetMs.clamped(to: ControlCatalog.handPredictionOffset)
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
