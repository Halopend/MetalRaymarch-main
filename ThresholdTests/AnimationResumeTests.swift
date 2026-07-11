//
//  AnimationResumeTests.swift
//  ThresholdTests
//

import Testing
import simd
@testable import Threshold

@Suite("Animation pause/resume")
struct AnimationResumeTests {
    private func keyframe(name: String,
                          position: SIMD3<Float>,
                          duration: TimeInterval = 2) -> AnimationKeyframe {
        AnimationKeyframe(
            name: name,
            duration: duration,
            minDistance: 0.5,
            foldingLimit: 1,
            sphereRadius: 1,
            fractalScale: 2,
            position: position,
            easingType: .linear
        )
    }

    @Test("Explored paused scene rejoins the fixed playhead before advancing")
    @MainActor
    func exploredSceneSmoothlyRejoinsPlayhead() {
        let settings = RenderSettings()
        let manager = AnimationManager(renderSettings: settings)
        let originalTransitionDuration = manager.sceneTransitionDuration
        defer { manager.sceneTransitionDuration = originalTransitionDuration }
        manager.sceneTransitionDuration = 0.4

        var scene = AnimationScene(name: "Resume")
        scene.keyframes = [
            keyframe(name: "Start", position: .zero),
            keyframe(name: "End", position: SIMD3<Float>(4, 0, 0))
        ]
        manager.currentScene = scene
        manager.play()
        manager.update(deltaTime: 0.5)
        manager.pause()

        let pausedElapsed = manager.playhead.elapsedInSegment
        let timelinePosition = settings.position
        let exploredPosition = SIMD3<Float>(10, 2, -1)
        settings.position = exploredPosition
        settings.targetPosition = exploredPosition

        manager.play()
        #expect(manager.playhead.elapsedInSegment == pausedElapsed)
        #expect(simd_distance(settings.position, exploredPosition) < 1e-5)

        manager.update(deltaTime: 0.2)
        #expect(manager.playhead.elapsedInSegment == pausedElapsed)
        #expect(simd_distance(settings.position, exploredPosition) > 0.1)
        #expect(simd_distance(settings.position, timelinePosition) > 0.1)

        manager.update(deltaTime: 0.2)
        #expect(manager.playhead.elapsedInSegment == pausedElapsed)
        #expect(simd_distance(settings.position, timelinePosition) < 1e-4)

        manager.update(deltaTime: 0.1)
        #expect(manager.playhead.elapsedInSegment > pausedElapsed)
    }

    @Test("Ping-pong resume preserves backward direction and playhead")
    @MainActor
    func pingPongResumePreservesDirection() {
        let settings = RenderSettings()
        let manager = AnimationManager(renderSettings: settings)

        var scene = AnimationScene(name: "Ping-pong")
        scene.playbackMode = .pingPong
        scene.keyframes = [
            keyframe(name: "A", position: SIMD3<Float>(0, 0, 0), duration: 1),
            keyframe(name: "B", position: SIMD3<Float>(1, 0, 0), duration: 1),
            keyframe(name: "C", position: SIMD3<Float>(2, 0, 0), duration: 1)
        ]
        manager.currentScene = scene
        manager.play()
        manager.update(deltaTime: 2.5)
        manager.pause()

        let pausedIndex = manager.playhead.currentKeyframeIndex
        let pausedElapsed = manager.playhead.elapsedInSegment
        #expect(manager.playhead.isGoingForward == false)

        manager.play()

        #expect(manager.playhead.currentKeyframeIndex == pausedIndex)
        #expect(manager.playhead.elapsedInSegment == pausedElapsed)
        #expect(manager.playhead.isGoingForward == false)
    }
}
