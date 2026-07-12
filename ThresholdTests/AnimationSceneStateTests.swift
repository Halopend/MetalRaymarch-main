//
//  AnimationSceneStateTests.swift
//  ThresholdTests
//
//  Regression coverage for canonical animation baselines and keyframe scale.
//

import Foundation
import Testing
@testable import Threshold

@Suite("Animation scenes — canonical baseline and scale compatibility")
struct AnimationSceneStateTests {

    private func keyframe(name: String, scale: Float, duration: TimeInterval = 1) -> AnimationKeyframe {
        AnimationKeyframe(
            name: name,
            duration: duration,
            minDistance: 0.8,
            foldingLimit: 1.0,
            sphereRadius: 0.5,
            fractalScale: 2.8,
            scale: scale,
            position: .zero
        )
    }

    private func scene(fractalType: FractalModelType = .mandelbox) -> AnimationScene {
        var scene = AnimationScene(
            name: "Scale",
            initialKeyframe: keyframe(name: "Start", scale: 2, duration: 0),
            fractalType: fractalType
        )
        scene.keyframes.append(keyframe(name: "End", scale: 4))
        return scene
    }

    @Test("Base scale interpolates in linear and Catmull-Rom paths")
    func scaleInterpolation() {
        let start = keyframe(name: "Start", scale: 2)
        let end = keyframe(name: "End", scale: 4)
        #expect(abs(start.interpolated(to: end, t: 0.25).scale - 2.5) < 0.0001)

        let points = [
            keyframe(name: "P0", scale: 1),
            keyframe(name: "P1", scale: 2),
            keyframe(name: "P2", scale: 3),
            keyframe(name: "P3", scale: 4),
        ]
        let spline = CatmullRomSpline.interpolateKeyframes(
            points,
            fromIndex: 1,
            toIndex: 2,
            t: 0.5,
            isLooping: false
        )
        #expect(abs(spline.scale - 2.5) < 0.0001)
    }

    @Test("Canonical animation baseline survives Codable")
    func baselineRoundTrip() throws {
        let settings = RenderSettings()
        settings.withPersistenceSuppressed {
            settings.fractalType = .mandelbox
            settings.spaceWarpStrength = 0.72
            settings.spaceWarpOrigin = SIMD3<Float>(1, 2, 3)
            settings.infiniteZoomEnabled = true
            settings.infiniteZoomRate = -0.4
            settings.lightingPlay = true
            settings.scale = 2
        }

        var original = scene()
        original.baseline = SceneState(capturing: settings, immersionStyle: "window")

        let decoded = try JSONDecoder().decode(
            AnimationScene.self,
            from: JSONEncoder().encode(original)
        )

        #expect(decoded.baseline == original.baseline)
        #expect(decoded.baseline?.presentation.immersionStyle == "window")
        #expect(decoded.baseline?.motion.infiniteZoomEnabled == true)
        #expect(abs((decoded.baseline?.space.warpStrength ?? -1) - 0.72) < 0.0001)
    }

    @MainActor
    @Test("Playback applies baseline first, then the keyframe scale")
    func baselinePlayback() {
        let authored = RenderSettings()
        authored.withPersistenceSuppressed {
            authored.fractalType = .mandelbox
            authored.lightingPlay = true
            authored.spaceWarpStrength = 0.67
            authored.spaceWarpOrigin = SIMD3<Float>(3, 2, 1)
            authored.infiniteZoomEnabled = true
            authored.infiniteZoomRate = 0.33
            authored.safetyBubbleEnabled = false
        }

        var animation = scene()
        animation.baseline = SceneState(capturing: authored, immersionStyle: "window")

        let destination = RenderSettings()
        destination.withPersistenceSuppressed {
            destination.lightingPlay = false
            destination.spaceWarpStrength = 0
            destination.infiniteZoomEnabled = false
            destination.scale = 9
            destination.safetyBubbleEnabled = true
        }

        let manager = AnimationManager(renderSettings: destination)
        manager.currentScene = animation
        manager.play()

        #expect(destination.lightingPlay == true)
        #expect(abs(destination.spaceWarpStrength - 0.67) < 0.0001)
        #expect(destination.spaceWarpOrigin == SIMD3<Float>(3, 2, 1))
        #expect(destination.infiniteZoomEnabled == true)
        #expect(abs(destination.infiniteZoomRate - 0.33) < 0.0001)
        #expect(abs(destination.scale - 2) < 0.0001)
        #expect(destination.safetyBubbleEnabled)

        manager.stop()
    }

    @MainActor
    @Test("Legacy playback clears unrelated prior-scene lanes and preserves comfort")
    func legacyPlaybackHasAuthoritativeDefaults() {
        var animation = scene(fractalType: .mandelbox)
        animation.baseline = nil
        animation.safetyBubbleEnabled = false

        let destination = RenderSettings()
        destination.withPersistenceSuppressed {
            destination.spaceWarpStrength = 1.4
            destination.spaceWarpOrigin = SIMD3<Float>(1, 2, 3)
            destination.spaceWarpAxis = SIMD3<Float>(1, 0, 0)
            destination.infiniteZoomEnabled = true
            destination.lightingPlay = true
            destination.shadowsEnabled = false
            destination.zoomFogCompensationEnabled = true
            destination.sphericalInversionMode = .outwardIn
            destination.sphereProjectionEnabled = true
            destination.platformEnabled = false
            destination.boundingSphereSkipEnabled = true
            destination.envScrunchEnabled = true
            destination.safetyBubbleEnabled = true
        }

        let manager = AnimationManager(renderSettings: destination)
        manager.currentScene = animation
        manager.play()

        #expect(destination.spaceWarpStrength == 0)
        #expect(destination.spaceWarpOrigin == .zero)
        #expect(destination.spaceWarpAxis == SIMD3<Float>(0, 1, 0))
        #expect(destination.infiniteZoomEnabled == false)
        #expect(destination.lightingPlay == false)
        #expect(destination.shadowsEnabled)
        #expect(destination.zoomFogCompensationEnabled == false)
        #expect(destination.sphericalInversionMode == .off)
        #expect(destination.sphereProjectionEnabled == false)
        #expect(destination.platformEnabled)
        #expect(destination.boundingSphereSkipEnabled == false)
        #expect(destination.envScrunchEnabled == false)
        #expect(destination.safetyBubbleEnabled)

        manager.stop()
    }

    @Test("Embedded space warp preserves fractal type; fractal payload selects custom")
    func embeddedEffectKindControlsFractalType() throws {
        var warpScene = scene(fractalType: .mandelbox)
        warpScene.embeddedFormula = EmbeddedFormula(
            kind: .spaceWarp,
            id: "test.warp",
            name: "Warp",
            functionStem: "TestWarp",
            metalSource: """
            float3 customSpaceWarp(float3 p) { return p; }
            float customSpaceWarpDEScale(float3 p) { return 1.0; }
            """,
            params: []
        )
        let decodedWarp = try JSONDecoder().decode(
            AnimationScene.self,
            from: JSONEncoder().encode(warpScene)
        )
        #expect(decodedWarp.fractalType == .mandelbox)

        var fractalScene = scene(fractalType: .mandelbox)
        fractalScene.embeddedFormula = EmbeddedFormula(
            kind: .fractal,
            id: "test.fractal",
            name: "Fractal",
            functionStem: "TestFractal",
            metalSource: """
            float DE_TestFractal(float3 p) { return length(p); }
            float DE_TestFractal_Dist(float3 p) { return length(p); }
            """,
            params: []
        )
        let decodedFractal = try JSONDecoder().decode(
            AnimationScene.self,
            from: JSONEncoder().encode(fractalScene)
        )
        #expect(decodedFractal.fractalType == .custom)
    }
}
