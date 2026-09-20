import Foundation
import Synchronization
import Testing
@testable import Threshold

@MainActor
@Suite("Shared scene evaluation")
struct SceneFrameEvaluatorTests {
    private func audio(at time: Double, bass: Float = 0.6) -> AudioFeatureSnapshot {
        AudioFeatureSnapshot(timestamp: time, contributions: [],
                             mixed: AudioFeatures(bass: bass, overall: 0.5),
                             provenance: .pcm, isActive: true)
    }

    @Test("Audio, animation and shader state are captured after the same evaluation")
    func coherentFrame() {
        let settings = RenderSettings()
        let pipeline = ParameterPipeline()
        let evaluator = SceneFrameEvaluator()
        settings.withPersistenceSuppressed {
            settings.lightingMode = .audioReactive
            settings.fractalAudioReactiveEnabled = false
            settings.bassSensitivity = 1
            let frame = evaluator.evaluate(.init(timestamp: 10), settings: settings,
                                           pipeline: pipeline, audio: audio(at: 10)) { _ in
                #expect(settings.bassLevel == 0.6)
                settings.fractalScale = 3
                settings.targetFractalScale = 3
                settings.isAnimationPlaying = true
            }
            #expect(frame.settings.bassLevel == 0.6)
            #expect(abs(frame.settings.fractalScale - 3) < 0.00001)
            let capturedScale = frame.settings.fractalScale
            #expect(frame.animationPlaying)
            #expect(frame.timestamp == 10)
            settings.fractalScale = 4
            #expect(frame.settings.fractalScale == capturedScale)
        }
    }

    @Test("Transport receives elapsed time once, including slow frames and duplicate view requests")
    func clock() {
        let settings = RenderSettings()
        let pipeline = ParameterPipeline()
        let evaluator = SceneFrameEvaluator()
        var deltas: [Double] = []
        for time in [10.0, 10.5, 10.5, 10.4, 11] {
            _ = evaluator.evaluate(.init(timestamp: time), settings: settings,
                                   pipeline: pipeline, audio: .empty(at: time)) { deltas.append($0) }
        }
        #expect(deltas == [0, 0.5, 0, 0, 0.5])
    }

    @Test("Turning off an audio mode clears levels instead of retaining the last beat")
    func clearsLevels() {
        let settings = RenderSettings()
        let pipeline = ParameterPipeline()
        let evaluator = SceneFrameEvaluator()
        settings.withPersistenceSuppressed {
            settings.lightingMode = .audioReactive
            settings.fractalAudioReactiveEnabled = false
            _ = evaluator.evaluate(.init(timestamp: 10), settings: settings,
                                   pipeline: pipeline, audio: audio(at: 10)) { _ in }
            settings.lightingMode = .staticLight
            let frame = evaluator.evaluate(.init(timestamp: 11), settings: settings,
                                           pipeline: pipeline, audio: audio(at: 11)) { _ in }
            #expect(frame.settings.bassLevel == 0)
            #expect(frame.settings.audioLevel == 0)
        }
    }

    @Test("A new scene discards old modulation history without restoring the outgoing base")
    func sceneReplacement() {
        let settings = RenderSettings()
        let pipeline = ParameterPipeline()
        let evaluator = SceneFrameEvaluator()
        settings.withPersistenceSuppressed {
            settings.fractalAudioReactiveEnabled = false
            _ = evaluator.evaluate(.init(timestamp: 10), settings: settings,
                                   pipeline: pipeline, audio: .empty(at: 10)) { _ in }
            pipeline.dispatchAudio([.init(targetID: ParameterTargetID.Effect.glow, source: .audio,
                                          value: 0.1, timestamp: 10, frameIndex: 0)], settings: settings)
            settings.beginSceneTransitionSnapshot()
            settings.audioModulateGlowIntensity(0.7)
            settings.commitSceneTransition()
            let frame = evaluator.evaluate(.init(timestamp: 11), settings: settings,
                                           pipeline: pipeline, audio: .empty(at: 11)) { _ in }
            #expect(settings.glowEffect.intensity == 0.7)
            #expect(frame.sceneGeneration == settings.sceneLoadGeneration)
            #expect(pipeline.liveValue(for: ParameterTargetID.Effect.glow) == nil)
        }
    }

    @Test("A manual edit after replacement survives the evaluator's generation reset")
    func preservesNewSceneInput() {
        let settings = RenderSettings()
        let pipeline = ParameterPipeline()
        let evaluator = SceneFrameEvaluator()
        _ = evaluator.evaluate(.init(timestamp: 10), settings: settings,
                               pipeline: pipeline, audio: .empty(at: 10)) { _ in }
        settings.withSceneReplacement { settings.audioModulateGlowIntensity(0.2) }
        pipeline.dispatch([.init(targetID: ParameterTargetID.Effect.glow, source: .slider,
                                 value: 0.6, timestamp: 11, frameIndex: 1)], settings: settings)
        _ = evaluator.evaluate(.init(timestamp: 11), settings: settings,
                               pipeline: pipeline, audio: .empty(at: 11)) { _ in }
        #expect(pipeline.liveValue(for: ParameterTargetID.Effect.glow)?.base == 0.6)
    }

    @Test("Multiple renderers coalesce to the latest input before publishing")
    func coalesces() async {
        let settings = RenderSettings()
        let evaluator = SceneFrameEvaluator()
        var times: [Double] = []
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let evaluate: @MainActor @Sendable (SceneFrameInput) -> EvaluatedSceneFrame = { input in
                times.append(input.timestamp)
                done.resume()
                return .capture(settings, at: input.timestamp)
            }
            _ = evaluator.request(.init(timestamp: 10), settings: settings, evaluate: evaluate)
            _ = evaluator.request(.init(timestamp: 11), settings: settings, evaluate: evaluate)
        }
        #expect(times == [11])
        #expect(evaluator.latestCompletedFrame()?.timestamp == 11)
    }
}

@Suite("Atomic scene state")
struct AtomicSceneStateTests {
    @Test("Snapshot readers cannot observe the middle of a multi-property scene commit")
    func snapshotsAreAtomic() {
        let settings = RenderSettings()
        settings.withSceneTransaction {
            settings.minDistance = 1
            settings.foldingLimit = 1
        }
        let failures = Mutex(0)
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            for i in 1...4000 {
                settings.withSceneTransaction {
                    settings.minDistance = Float(i)
                    settings.foldingLimit = Float(i)
                }
            }
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            for _ in 0..<4000 {
                let state = settings.snapshot()
                if state.minDistance != state.foldingLimit { failures.withLock { $0 += 1 } }
            }
            group.leave()
        }
        #expect(group.wait(timeout: .now() + 10) == .success)
        #expect(failures.withLock { $0 } == 0)
    }
}
