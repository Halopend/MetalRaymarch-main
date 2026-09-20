import Foundation
import Synchronization

/// Platform input is a value, never a view, tracking session, or application model.
struct SceneFrameInput: Sendable {
    let timestamp: TimeInterval
    var mixedImmersion = false
    /// nil means this renderer has no hand-input capability, rather than six
    /// tracked fingers which happen to be released.
    var fingers: BandLevels? = nil
}

/// The settings, playback flag and clock travel together to every render backend.
struct EvaluatedSceneFrame: Sendable {
    let settings: RenderSettingsSnapshot
    let sceneGeneration: UInt64
    let timestamp: TimeInterval
    let deltaTime: TimeInterval
    let animationPlaying: Bool

    static func capture(_ settings: RenderSettings, at timestamp: TimeInterval,
                        deltaTime: TimeInterval = 0) -> Self {
        settings.withSceneTransaction {
            Self(settings: settings.snapshot(), sceneGeneration: settings.sceneLoadGeneration,
                 timestamp: timestamp, deltaTime: deltaTime,
                 animationPlaying: settings.isAnimationPlaying)
        }
    }
}

/// One evaluator per scene session. Main-actor adapters supply audio and animation;
/// the evaluator itself has no dependency on AppModel, SwiftUI, Metal or a device.
/// Rendering does not wait for a NEW main-actor evaluation; it consumes the last
/// complete frame. Settings access can briefly contend with a scene transaction.
/// Mutable evaluation state is MainActor-isolated; request/publication state uses Mutex.
final class SceneFrameEvaluator: @unchecked Sendable {
    private struct Requests {
        var latest: SceneFrameInput?
        var scheduled = false
        var completed: EvaluatedSceneFrame?
    }
    nonisolated init() {}

    private let requests = Mutex(Requests())
    @MainActor private var previousTime: TimeInterval?
    @MainActor private lazy var music = MusicReactiveEngine()
    @MainActor private var generation: UInt64?

    /// Coalesce multiple view/display requests into one scene evaluation. The
    /// newest input wins; time comes from the clock, not the number of views.
    func request(_ input: SceneFrameInput, settings: RenderSettings,
                 evaluate: @escaping @MainActor @Sendable (SceneFrameInput) -> EvaluatedSceneFrame) -> EvaluatedSceneFrame {
        let shouldSchedule = requests.withLock { state in
            if state.latest == nil || input.timestamp >= state.latest!.timestamp {
                state.latest = input
            }
            guard !state.scheduled else { return false }
            state.scheduled = true
            return true
        }
        if shouldSchedule {
            Task { @MainActor [weak self] in
                guard let self else { return }
                let pending = self.requests.withLock { state -> SceneFrameInput? in
                    let pending = state.latest
                    state.latest = nil
                    state.scheduled = false
                    return pending
                }
                guard let pending else { return }
                let frame = evaluate(pending)
                self.requests.withLock { $0.completed = frame }
            }
        }
        let completed = requests.withLock { $0.completed }
        // A committed scene must not display the previous scene while waiting
        // for its first evaluation. Capture its entire new state atomically.
        return settings.withSceneTransaction {
            if let completed, completed.sceneGeneration == settings.sceneLoadGeneration {
                return completed
            }
            return EvaluatedSceneFrame.capture(settings, at: input.timestamp)
        }
    }

    @MainActor
    func resetClock() {
        previousTime = nil
        requests.withLock { state in
            state.latest = nil
            state.completed = nil
        }
    }

    func latestCompletedFrame() -> EvaluatedSceneFrame? {
        requests.withLock { $0.completed }
    }

    /// Explicit clock and inputs make this path usable in replay/export tests.
    /// The animation adapter runs AFTER music offsets are deposited, so its
    /// keyframe batch composes this frame's base + manual + audio values.
    @MainActor
    func evaluate(_ input: SceneFrameInput, settings: RenderSettings,
                  pipeline: ParameterPipeline, audio: AudioFeatureSnapshot,
                  advanceAnimation: (TimeInterval) -> Void) -> EvaluatedSceneFrame {
        let requestedTime = input.timestamp.isFinite ? input.timestamp : (previousTime ?? 0)
        let now = max(previousTime ?? requestedTime, requestedTime)
        let elapsed = previousTime.map { max(0, now - $0) } ?? 0
        previousTime = max(previousTime ?? now, now)
        // Bound integrators after suspension; the animation transport still
        // receives actual elapsed time, so a slow UI cannot slow down a song.
        let integrationDelta = Float(min(elapsed, 1.0 / 15.0))
        return settings.withSceneTransaction {
            if generation != settings.sceneLoadGeneration {
                // The new scene is already authoritative. Discard old layer
                // history WITHOUT writing outgoing values over the new scene.
                pipeline.prepareForScene(settings.sceneLoadGeneration)
                music.discardState()
                generation = settings.sceneLoadGeneration
            }
            updateMusic(input: input, settings: settings, pipeline: pipeline,
                        audio: audio, deltaTime: integrationDelta, timestamp: now)
            advanceAnimation(elapsed)
            // The keyframe batch establishes animated targets before smoothing
            // folds manual offsets into them. Reversing these steps erases a
            // manual geometry adjustment every frame during playback.
            settings.interpolateToTargets(deltaTime: integrationDelta)
            settings.updateLimitFlash(deltaTime: integrationDelta)
            settings.updateColorSchemeTransition(deltaTime: integrationDelta,
                                                  mixedImmersionActive: input.mixedImmersion)
            return EvaluatedSceneFrame.capture(settings, at: now, deltaTime: elapsed)
        }
    }

    @MainActor
    private func updateMusic(input: SceneFrameInput, settings: RenderSettings,
                             pipeline: ParameterPipeline, audio: AudioFeatureSnapshot,
                             deltaTime: Float, timestamp: TimeInterval) {
        let isAudioMode = settings.lightingMode == .audioReactive
            || settings.lightingMode == .visualizer || settings.fractalAudioReactiveEnabled
        let hasAudio = isAudioMode && audio.isActive && audio.mixed.isFinite
        var bands = input.fingers ?? BandLevels()
        func pinch(_ value: Float) -> Float { value.isFinite ? min(1, max(0, value)) : 0 }
        bands.leftIndexPinch = pinch(bands.leftIndexPinch)
        bands.leftMiddlePinch = pinch(bands.leftMiddlePinch)
        bands.leftRingPinch = pinch(bands.leftRingPinch)
        bands.rightIndexPinch = pinch(bands.rightIndexPinch)
        bands.rightMiddlePinch = pinch(bands.rightMiddlePinch)
        bands.rightRingPinch = pinch(bands.rightRingPinch)
        let features = audio.mixed
        bands.bass = hasAudio ? AudioBandMapping.scaledLevel(features.bass, sensitivity: settings.bassSensitivity) : 0
        bands.mid = hasAudio ? AudioBandMapping.scaledLevel(features.mid, sensitivity: settings.midSensitivity) : 0
        bands.treble = hasAudio ? AudioBandMapping.scaledLevel(features.treble, sensitivity: settings.trebleSensitivity) : 0
        bands.beat = hasAudio ? AudioBandMapping.scaledLevel(features.onset, sensitivity: settings.beatSensitivity) : 0
        bands.overall = hasAudio ? AudioBandMapping.scaledLevel(features.overall, sensitivity: 1) : 0
        settings.bassLevel = bands.bass
        settings.midLevel = bands.mid
        settings.trebleLevel = bands.treble
        settings.beatIntensity = bands.beat
        settings.audioLevel = bands.overall
        let hasFingers = input.fingers != nil && settings.hasEnabledFingerInputMapping
        if settings.fractalAudioReactiveEnabled && (hasAudio || hasFingers) {
            music.process(bandLevels: bands, settings: settings, deltaTime: deltaTime,
                          pipeline: pipeline, timestamp: timestamp)
        } else {
            music.reset(settings: settings, pipeline: pipeline)
        }
    }
}
