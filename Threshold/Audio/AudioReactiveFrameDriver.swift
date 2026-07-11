import Foundation
import os

/// Shared per-frame audio aggregation and music-reactive dispatch for every
/// renderer. Keeping this here makes source blending, sanitization, and reset
/// behavior identical on desktop and visionOS.
enum AudioReactiveFrameDriver {
    private static let logger = Logger(
        subsystem: "com.puppypower.Threshold",
        category: "AudioReactiveFrame"
    )

    static func update(
        analyzer: AudioAnalyzer,
        appleMusicManager: AppleMusicManager,
        settings: RenderSettings,
        isAudioMode: Bool,
        engine: MusicReactiveEngine,
        pipeline: ParameterPipeline,
        deltaTime: Float
    ) {
        guard isAudioMode else {
            zeroLevels(in: settings)
            engine.reset(settings: settings, pipeline: pipeline)
            return
        }

        var totalBass: Float = 0
        var totalMid: Float = 0
        var totalTreble: Float = 0
        var totalBeat: Float = 0
        var totalLevel: Float = 0
        var sourceCount: Float = 0

        if analyzer.isCapturing {
            totalBass += analyzer.bassLevel
            totalMid += analyzer.midLevel
            totalTreble += analyzer.trebleLevel
            totalBeat = max(totalBeat, analyzer.onsetLevel)
            totalLevel += analyzer.level
            sourceCount += 1
        }

        if appleMusicManager.isActive {
            totalBass += appleMusicManager.bassLevel
            totalMid += appleMusicManager.midLevel
            totalTreble += appleMusicManager.trebleLevel
            totalBeat = max(totalBeat, appleMusicManager.beatIntensity)
            totalLevel += appleMusicManager.overallLevel
            sourceCount += 1
        }

        let hasStandaloneLFO = settings.musicReactiveMappings.contains {
            $0.isEnabled && $0.lfo.enabled
        }

        guard sourceCount > 0 || hasStandaloneLFO,
              totalBass.isFinite, totalMid.isFinite, totalTreble.isFinite,
              totalBeat.isFinite, totalLevel.isFinite else {
            if sourceCount > 0 {
                logger.error("Non-finite analyzer input; zeroing audio-reactive levels")
            }
            zeroLevels(in: settings)
            engine.reset(settings: settings, pipeline: pipeline)
            return
        }

        let inverseSourceCount = sourceCount > 0 ? 1.0 / sourceCount : 0
        let levels = BandLevels(
            bass: min(1.0, totalBass * inverseSourceCount * settings.bassSensitivity),
            mid: min(1.0, totalMid * inverseSourceCount * settings.midSensitivity),
            treble: min(1.0, totalTreble * inverseSourceCount * settings.trebleSensitivity),
            beat: min(1.0, totalBeat * settings.beatSensitivity),
            overall: totalLevel * inverseSourceCount
        )

        settings.bassLevel = levels.bass
        settings.midLevel = levels.mid
        settings.trebleLevel = levels.treble
        settings.beatIntensity = levels.beat
        settings.audioLevel = levels.overall

        guard settings.fractalAudioReactiveEnabled else {
            engine.reset(settings: settings, pipeline: pipeline)
            return
        }

        engine.process(
            bandLevels: levels,
            settings: settings,
            deltaTime: deltaTime,
            pipeline: pipeline
        )
    }

    private static func zeroLevels(in settings: RenderSettings) {
        settings.bassLevel = 0
        settings.midLevel = 0
        settings.trebleLevel = 0
        settings.beatIntensity = 0
        settings.audioLevel = 0
    }
}
