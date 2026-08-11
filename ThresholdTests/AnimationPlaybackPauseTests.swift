//
//  AnimationPlaybackPauseTests.swift
//  ThresholdTests
//
//  Regression coverage for pause/resume transport semantics.
//

import Foundation
import Testing
@testable import Threshold

@Suite("Animation pause and resume")
struct AnimationPlaybackPauseTests {

    private func keyframe(
        name: String,
        value: Float,
        duration: TimeInterval
    ) -> AnimationKeyframe {
        AnimationKeyframe(
            name: name,
            duration: duration,
            minDistance: value,
            foldingLimit: 1,
            sphereRadius: 0.5,
            fractalScale: 2,
            scale: 1,
            position: .zero
        )
    }

    private func scene(
        mode: AnimationPlaybackMode = .forward,
        segmentDuration: TimeInterval = 10
    ) -> AnimationScene {
        var result = AnimationScene(
            name: "Pause test",
            initialKeyframe: keyframe(name: "Start", value: 0.5, duration: 0),
            fractalType: .mandelbox
        )
        result.keyframes.append(
            keyframe(name: "Middle", value: 0.75, duration: segmentDuration)
        )
        result.keyframes.append(
            keyframe(name: "End", value: 1, duration: segmentDuration)
        )
        result.playbackMode = mode
        result.isLooping = true
        return result
    }

    @MainActor
    @Test("Pause freezes the playhead and Play resumes it")
    func pauseFreezesAndResumeContinues() {
        let settings = RenderSettings()
        let manager = AnimationManager(renderSettings: settings)
        manager.currentScene = scene()

        manager.play()
        manager.update(deltaTime: 0.25)
        let pausedIndex = manager.playhead.currentKeyframeIndex
        let pausedElapsed = manager.playhead.elapsedInSegment

        manager.pause()

        #expect(manager.isPaused)
        #expect(!manager.isPlaying)
        #expect(!settings.isAnimationPlaying)

        manager.update(deltaTime: 2)
        #expect(manager.playhead.currentKeyframeIndex == pausedIndex)
        #expect(manager.playhead.elapsedInSegment == pausedElapsed)

        manager.play()

        #expect(manager.isPlaying)
        #expect(!manager.isPaused)
        #expect(settings.isAnimationPlaying)
        #expect(manager.playhead.currentKeyframeIndex == pausedIndex)
        #expect(manager.playhead.elapsedInSegment == pausedElapsed)

        manager.update(deltaTime: 0.25)
        #expect(manager.playhead.elapsedInSegment > pausedElapsed)
        manager.stop()
    }

    @MainActor
    @Test("Resume preserves reverse and ping-pong direction")
    func resumePreservesDirection() {
        let reverseManager = AnimationManager(renderSettings: RenderSettings())
        reverseManager.currentScene = scene(mode: .reverse)
        reverseManager.play()
        reverseManager.update(deltaTime: 0.25)
        let reverseIndex = reverseManager.playhead.currentKeyframeIndex
        let reverseElapsed = reverseManager.playhead.elapsedInSegment

        reverseManager.pause()
        reverseManager.play()

        #expect(reverseManager.playhead.currentKeyframeIndex == reverseIndex)
        #expect(reverseManager.playhead.elapsedInSegment == reverseElapsed)
        #expect(!reverseManager.playhead.isGoingForward)
        reverseManager.stop()

        let pingPongManager = AnimationManager(renderSettings: RenderSettings())
        pingPongManager.currentScene = scene(mode: .pingPong, segmentDuration: 1)
        pingPongManager.play()
        pingPongManager.update(deltaTime: 2.25)
        #expect(!pingPongManager.playhead.isGoingForward)
        let pingPongIndex = pingPongManager.playhead.currentKeyframeIndex
        let pingPongElapsed = pingPongManager.playhead.elapsedInSegment

        pingPongManager.pause()
        pingPongManager.play()

        #expect(pingPongManager.playhead.currentKeyframeIndex == pingPongIndex)
        #expect(pingPongManager.playhead.elapsedInSegment == pingPongElapsed)
        #expect(!pingPongManager.playhead.isGoingForward)
        pingPongManager.stop()
    }

    @MainActor
    @Test("Resume does not restart an attached song")
    func resumeDoesNotRestartAttachedSong() {
        var accompaniedScene = scene()
        accompaniedScene.attachedSong = SongAttachment(
            trackID: UnifiedTrackID(serviceID: "appleMusic", nativeID: "pause-test"),
            title: "Pause Test",
            artist: "Threshold"
        )

        let manager = AnimationManager(renderSettings: RenderSettings())
        var playSongCallCount = 0
        manager.playSongHandler = { _ in playSongCallCount += 1 }
        manager.currentScene = accompaniedScene

        manager.play()
        manager.pause()
        manager.play()

        #expect(playSongCallCount == 1)
        manager.stop()
    }

    @MainActor
    @Test("Stop resets progress while Pause preserves it")
    func stopResetsPausedProgress() {
        let manager = AnimationManager(renderSettings: RenderSettings())
        manager.currentScene = scene()
        manager.play()
        manager.update(deltaTime: 0.5)
        manager.pause()

        #expect(manager.playhead.elapsedInSegment > 0)
        manager.stop()

        #expect(manager.playhead.state == .stopped)
        #expect(manager.playhead.currentKeyframeIndex == 0)
        #expect(manager.playhead.elapsedInSegment == 0)
    }

    @MainActor
    @Test("Selecting another scene clears the paused playhead")
    func sceneChangeClearsPausedPlayhead() {
        let manager = AnimationManager(renderSettings: RenderSettings())
        manager.currentScene = scene()
        manager.play()
        manager.update(deltaTime: 0.5)
        manager.pause()

        let replacement = scene(mode: .reverse)
        manager.currentScene = replacement

        #expect(!manager.isPaused)
        #expect(manager.playhead.state == .stopped)
        #expect(manager.playhead.sceneID == replacement.id)
        #expect(manager.playhead.currentKeyframeIndex == 0)
        #expect(manager.playhead.elapsedInSegment == 0)

        manager.play()
        #expect(manager.isPlaying)
        #expect(manager.playhead.currentKeyframeIndex == replacement.keyframes.count - 1)
        #expect(!manager.playhead.isGoingForward)
        manager.stop()
    }
}
