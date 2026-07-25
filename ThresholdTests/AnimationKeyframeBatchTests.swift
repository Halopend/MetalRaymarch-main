//
//  AnimationKeyframeBatchTests.swift
//  ThresholdTests
//
//  Pins the base × gesture × music composition math of the batched animation
//  keyframe apply (TECH_DEBT #3: three documented stomp regressions in this
//  layering, previously zero coverage). The batch must compose exactly like
//  the pre-batch per-setter path: immediates fold in audio offsets only,
//  targets fold in gesture + audio, rotation/zoom compose the manual override
//  onto the scene base, and scene-driven effect channels layer both offsets
//  onto the live value without disturbing the stored keyframe base.
//

import Foundation
import Testing
import simd
@testable import Threshold

@Suite("Animation keyframe batch composition")
struct AnimationKeyframeBatchTests {

    private func makeBatch(
        minDistance: Float = 0.6,
        foldingLimit: Float = 1.2,
        sphereRadius: Float = 0.4,
        fractalScale: Float = 2.5,
        scale: Float = 1.0,
        position: SIMD3<Float> = SIMD3<Float>(0.2, 0.3, 0.4),
        detailScale: Float = 1.5,
        worldRotation: simd_quatf = simd_quatf(angle: 0.5, axis: SIMD3<Float>(0, 1, 0)),
        baseFractalIterations: Int? = 14,
        baseMaxRaySteps: Int? = 220,
        glowIntensityBase: Float? = nil,
        saturationBase: Float? = nil
    ) -> RenderSettings.AnimationKeyframeBatch {
        RenderSettings.AnimationKeyframeBatch(
            minDistance: minDistance,
            foldingLimit: foldingLimit,
            sphereRadius: sphereRadius,
            fractalScale: fractalScale,
            scale: scale,
            position: position,
            detailScale: detailScale,
            worldRotation: worldRotation,
            baseFractalIterations: baseFractalIterations,
            baseMaxRaySteps: baseMaxRaySteps,
            formulaParamValues: nil,
            legacyProjectionBlend: nil,
            legacyProjectionRadius: nil,
            hueSpeedBase: nil,
            glowIntensityBase: glowIntensityBase,
            bloomStrengthBase: nil,
            fogIntensityBase: nil,
            saturationBase: saturationBase
        )
    }

    @Test("Immediates fold in audio offsets; targets fold in gesture + audio")
    func immediateAndTargetComposition() {
        let settings = RenderSettings()
        settings.withPersistenceSuppressed {
            settings.manualOffsetMinDistance = 0.05
            settings.audioOffsetMinDistance = 0.02
            settings.manualOffsetFoldingLimit = -0.1
            settings.audioOffsetFoldingLimit = 0.03
            settings.manualOffsetSphereRadius = 0.07
            settings.audioOffsetSphereRadius = -0.01
            settings.manualOffsetFractalScale = 0.2
            settings.audioOffsetFractalScale = 0.1
            settings.manualOffsetPosition = SIMD3<Float>(0.01, -0.02, 0.03)

            settings.applyAnimationKeyframeBatch(makeBatch())

            // Immediate values: base + audio offset only (the gesture offset
            // eases in via the target, preserving its smooth blend-in feel).
            #expect(abs(settings.minDistance - (0.6 + 0.02)) < 1e-5)
            #expect(abs(settings.foldingLimit - (1.2 + 0.03)) < 1e-5)
            #expect(abs(settings.sphereRadius - (0.4 - 0.01)) < 1e-5)
            #expect(abs(settings.fractalScale - (2.5 + 0.1)) < 1e-5)

            // Targets: base + gesture + audio, so both survive playback stop.
            #expect(abs(settings.targetMinDistance - (0.6 + 0.05 + 0.02)) < 1e-5)
            #expect(abs(settings.targetFoldingLimit - (1.2 - 0.1 + 0.03)) < 1e-5)
            #expect(abs(settings.targetSphereRadius - (0.4 + 0.07 - 0.01)) < 1e-5)
            #expect(abs(settings.targetFractalScale - (2.5 + 0.2 + 0.1)) < 1e-5)
            let expectedTargetPosition = SIMD3<Float>(0.2, 0.3, 0.4) + SIMD3<Float>(0.01, -0.02, 0.03)
            #expect(simd_length(settings.targetPosition - expectedTargetPosition) < 1e-5)
            // The live position tracks the scene base directly.
            #expect(simd_length(settings.position - SIMD3<Float>(0.2, 0.3, 0.4)) < 1e-5)
        }
    }

    @Test("A grab gesture composes onto animated rotation and zoom instead of being stomped")
    func rotationAndZoomOverrideComposition() {
        let settings = RenderSettings()
        settings.withPersistenceSuppressed {
            let grabRotation = simd_quatf(angle: 0.8, axis: SIMD3<Float>(1, 0, 0))
            settings.manualRotationOffset = grabRotation
            settings.manualOffsetDetailScale = 0.5

            let sceneRotation = simd_quatf(angle: 0.5, axis: SIMD3<Float>(0, 1, 0))
            settings.applyAnimationKeyframeBatch(makeBatch(detailScale: 1.5, worldRotation: sceneRotation))

            let expected = (grabRotation * sceneRotation).normalized
            let dot = abs(simd_dot(settings.worldRotation.vector, expected.vector))
            #expect(dot > 0.9999)
            #expect(abs(settings.detailScale - 2.0) < 1e-5)
            #expect(abs(settings.targetDetailScale - 2.0) < 1e-5)

            // The scene base is stored un-composed so the override can decay.
            let baseDot = abs(simd_dot(settings.animationBaseWorldRotation.vector, sceneRotation.vector))
            #expect(baseDot > 0.9999)
            #expect(abs(settings.animationBaseDetailScale - 1.5) < 1e-5)
        }
    }

    @Test("Zoom composition floors at 0.01 when a grab drags the animated base negative")
    func zoomFloorSurvivesNegativeOffset() {
        let settings = RenderSettings()
        settings.withPersistenceSuppressed {
            settings.manualOffsetDetailScale = -5.0
            settings.applyAnimationKeyframeBatch(makeBatch(detailScale: 0.2))
            #expect(abs(settings.detailScale - 0.01) < 1e-6)
        }
    }

    @Test("Scene-driven glow layers gesture + music onto the live value, keeps the raw base")
    func sceneDrivenEffectChannelComposition() {
        let settings = RenderSettings()
        settings.withPersistenceSuppressed {
            settings.manualOffsetGlowIntensity = 0.3
            settings.audioOffsetGlowIntensity = 0.4

            settings.applyAnimationKeyframeBatch(makeBatch(glowIntensityBase: 0.8))

            #expect(settings.sceneDrivesGlow)
            #expect(abs(settings.animationBaseGlowIntensity - 0.8) < 1e-5)
            // Live value = clamp(base + gesture + music) via the control spec.
            let expected = ControlCatalog.glow.clamp(0.8 + 0.3 + 0.4)
            #expect(abs(settings.glowEffect.intensity - expected) < 1e-5)

            // An undriven channel releases its drive flag.
            settings.applyAnimationKeyframeBatch(makeBatch(glowIntensityBase: nil))
            #expect(!settings.sceneDrivesGlow)
        }
    }

    @Test("A user iteration-budget override survives keyframe application")
    func iterationBudgetOverrideSkipsKeyframeBudget() {
        let settings = RenderSettings()
        settings.withPersistenceSuppressed {
            settings.baseFractalIterations = 9
            settings.baseMaxRaySteps = 111

            // nil budget fields = user override active; keyframe must not stomp.
            settings.applyAnimationKeyframeBatch(
                makeBatch(baseFractalIterations: nil, baseMaxRaySteps: nil))
            #expect(settings.baseFractalIterations == 9)
            #expect(settings.baseMaxRaySteps == 111)

            // With no override, the keyframe budget applies (clamped to the
            // control spec — 16...200 for ray steps, so 220 lands at 200).
            settings.applyAnimationKeyframeBatch(
                makeBatch(baseFractalIterations: 14, baseMaxRaySteps: 220))
            #expect(settings.baseFractalIterations == 14)
            #expect(settings.baseMaxRaySteps == 200)
            #expect(settings.fractalIterations == 14)
            #expect(settings.maxRaySteps == 200)
        }
    }
}
