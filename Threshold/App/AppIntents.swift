import AppIntents
import SwiftUI

// MARK: - Play Animation
struct PlayAnimationIntent: AppIntent {
    static var title: LocalizedStringResource = "Play animation"
    static var description: LocalizedStringResource = "Start playing the current animation scene"
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let appModel = AppModel.shared else {
            return .result(dialog: "Threshold app not available")
        }

        appModel.animationManager?.play()
        return .result(dialog: "Animation playing")
    }
}

// MARK: - Pause Animation
struct PauseAnimationIntent: AppIntent {
    static var title: LocalizedStringResource = "Pause animation"
    static var description: LocalizedStringResource = "Pause the current animation scene"
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let appModel = AppModel.shared else {
            return .result(dialog: "Threshold app not available")
        }

        appModel.animationManager?.pause()
        return .result(dialog: "Animation paused")
    }
}

// MARK: - Stop Animation
struct StopAnimationIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop animation"
    static var description: LocalizedStringResource = "Stop the current animation scene"
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let appModel = AppModel.shared else {
            return .result(dialog: "Threshold app not available")
        }

        appModel.animationManager?.stop()
        return .result(dialog: "Animation stopped")
    }
}

// MARK: - Toggle Audio Reactivity
struct ToggleAudioReactivityIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle audio reactivity"
    static var description: LocalizedStringResource = "Enable or disable audio-reactive visualization"
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let appModel = AppModel.shared else {
            return .result(dialog: "Threshold app not available")
        }

        let currentValue = appModel.renderSettings.fractalAudioReactiveEnabled
        appModel.renderSettings.fractalAudioReactiveEnabled = !currentValue
        let state = !currentValue ? "enabled" : "disabled"
        return .result(dialog: "Audio reactivity \(state)")
    }
}

// MARK: - Enable Audio Reactivity
struct EnableAudioReactivityIntent: AppIntent {
    static var title: LocalizedStringResource = "Enable audio reactivity"
    static var description: LocalizedStringResource = "Enable audio-reactive visualization"
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let appModel = AppModel.shared else {
            return .result(dialog: "Threshold app not available")
        }

        appModel.renderSettings.fractalAudioReactiveEnabled = true
        return .result(dialog: "Audio reactivity enabled")
    }
}

// MARK: - Disable Audio Reactivity
struct DisableAudioReactivityIntent: AppIntent {
    static var title: LocalizedStringResource = "Disable audio reactivity"
    static var description: LocalizedStringResource = "Disable audio-reactive visualization"
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let appModel = AppModel.shared else {
            return .result(dialog: "Threshold app not available")
        }

        appModel.renderSettings.fractalAudioReactiveEnabled = false
        return .result(dialog: "Audio reactivity disabled")
    }
}

// MARK: - Increase Audio Amount
struct IncreaseAudioAmountIntent: AppIntent {
    static var title: LocalizedStringResource = "Increase audio sensitivity"
    static var description: LocalizedStringResource = "Increase the audio reactivity amount"
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let appModel = AppModel.shared else {
            return .result(dialog: "Threshold app not available")
        }

        let currentValue = appModel.renderSettings.fractalAudioAmount
        let newValue = min(1.0, currentValue + 0.1)
        appModel.renderSettings.fractalAudioAmount = newValue
        return .result(dialog: String(format: "Audio sensitivity set to %.0f%%", newValue * 100))
    }
}

// MARK: - Decrease Audio Amount
struct DecreaseAudioAmountIntent: AppIntent {
    static var title: LocalizedStringResource = "Decrease audio sensitivity"
    static var description: LocalizedStringResource = "Decrease the audio reactivity amount"
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let appModel = AppModel.shared else {
            return .result(dialog: "Threshold app not available")
        }

        let currentValue = appModel.renderSettings.fractalAudioAmount
        let newValue = max(0.0, currentValue - 0.1)
        appModel.renderSettings.fractalAudioAmount = newValue
        return .result(dialog: String(format: "Audio sensitivity set to %.0f%%", newValue * 100))
    }
}

// MARK: - Increase Beat Punch
struct IncreaseBeatPunchIntent: AppIntent {
    static var title: LocalizedStringResource = "Increase beat punch"
    static var description: LocalizedStringResource = "Increase the beat detection intensity"
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let appModel = AppModel.shared else {
            return .result(dialog: "Threshold app not available")
        }

        let currentValue = appModel.renderSettings.fractalBeatPunch
        let newValue = min(1.0, currentValue + 0.1)
        appModel.renderSettings.fractalBeatPunch = newValue
        return .result(dialog: String(format: "Beat punch set to %.0f%%", newValue * 100))
    }
}

// MARK: - Decrease Beat Punch
struct DecreaseBeatPunchIntent: AppIntent {
    static var title: LocalizedStringResource = "Decrease beat punch"
    static var description: LocalizedStringResource = "Decrease the beat detection intensity"
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let appModel = AppModel.shared else {
            return .result(dialog: "Threshold app not available")
        }

        let currentValue = appModel.renderSettings.fractalBeatPunch
        let newValue = max(0.0, currentValue - 0.1)
        appModel.renderSettings.fractalBeatPunch = newValue
        return .result(dialog: String(format: "Beat punch set to %.0f%%", newValue * 100))
    }
}

// ════════════════════════════════════════════════════════════════════════════
// MARK: - Music Transport (Apple Music / Spotify via MusicService)
// ════════════════════════════════════════════════════════════════════════════

// MARK: - Toggle Play/Pause Music
struct ToggleMusicPlaybackIntent: AppIntent {
    static var title: LocalizedStringResource = "Play or pause music"
    static var description: LocalizedStringResource = "Toggle playback of the music feeding the visualizer"
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let appModel = AppModel.shared else {
            return .result(dialog: "Threshold app not available")
        }

        appModel.musicService.togglePlayPause()
        let state = appModel.musicService.isPlaying ? "Playing" : "Paused"
        return .result(dialog: "\(state) music")
    }
}

// MARK: - Next Track
struct NextTrackIntent: AppIntent {
    static var title: LocalizedStringResource = "Next track"
    static var description: LocalizedStringResource = "Skip to the next track"
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let appModel = AppModel.shared else {
            return .result(dialog: "Threshold app not available")
        }

        appModel.musicService.next()
        if let track = appModel.musicService.nowPlaying {
            return .result(dialog: "Now playing \(track.title) by \(track.artist)")
        }
        return .result(dialog: "Skipped to next track")
    }
}

// MARK: - Previous Track
struct PreviousTrackIntent: AppIntent {
    static var title: LocalizedStringResource = "Previous track"
    static var description: LocalizedStringResource = "Go back to the previous track"
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let appModel = AppModel.shared else {
            return .result(dialog: "Threshold app not available")
        }

        appModel.musicService.previous()
        if let track = appModel.musicService.nowPlaying {
            return .result(dialog: "Now playing \(track.title) by \(track.artist)")
        }
        return .result(dialog: "Went to previous track")
    }
}

// MARK: - Now Playing (query)
struct NowPlayingIntent: AppIntent {
    static var title: LocalizedStringResource = "What's playing"
    static var description: LocalizedStringResource = "Report the track currently feeding the visualizer"
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let appModel = AppModel.shared else {
            return .result(dialog: "Threshold isn't running")
        }

        guard let track = appModel.musicService.nowPlaying else {
            return .result(dialog: "Nothing is playing right now")
        }
        return .result(dialog: "\(track.title) by \(track.artist)")
    }
}

// ════════════════════════════════════════════════════════════════════════════
// MARK: - Parameterized Intents
// ════════════════════════════════════════════════════════════════════════════

/// Siri-fillable fractal type. Cases mirror `FractalModelType`'s selectable set;
/// `modelType` maps back to the engine enum by raw value.
enum FractalTypeAppEnum: String, AppEnum {
    case mandelbox
    case mandelbulb
    case menger
    case mandelbulbJulia
    case quaternionJulia
    case octahedron
    case mengerSphere
    case kleinian

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Fractal Type"

    static var caseDisplayRepresentations: [FractalTypeAppEnum: DisplayRepresentation] = [
        .mandelbox: "Mandelbox",
        .mandelbulb: "Mandelbulb",
        .menger: "Menger Sponge",
        .mandelbulbJulia: "Mandelbulb Julia",
        .quaternionJulia: "Quaternion Julia",
        .octahedron: "Octahedron",
        .mengerSphere: "Menger Sphere",
        .kleinian: "Kleinian",
    ]

    var modelType: FractalModelType {
        switch self {
        case .mandelbox:       return .mandelbox
        case .mandelbulb:      return .mandelbulb
        case .menger:          return .menger
        case .mandelbulbJulia: return .mandelbulbJulia
        case .quaternionJulia: return .quaternionJulia
        case .octahedron:      return .octahedron
        case .mengerSphere:    return .mengerSphere
        case .kleinian:        return .kleinian
        }
    }
}

// MARK: - Switch Fractal Type
struct SwitchFractalTypeIntent: AppIntent {
    static var title: LocalizedStringResource = "Switch fractal"
    static var description: LocalizedStringResource = "Change the active fractal type"
    static var openAppWhenRun = true

    @Parameter(title: "Fractal")
    var fractal: FractalTypeAppEnum

    static var parameterSummary: some ParameterSummary {
        Summary("Switch to \(\.$fractal)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let appModel = AppModel.shared else {
            return .result(dialog: "Threshold app not available")
        }

        appModel.renderSettings.fractalType = fractal.modelType
        return .result(dialog: "Switched to \(appModel.renderSettings.fractalType.displayName)")
    }
}

// MARK: - Set Audio Sensitivity
struct SetAudioSensitivityIntent: AppIntent {
    static var title: LocalizedStringResource = "Set audio sensitivity"
    static var description: LocalizedStringResource = "Set the audio reactivity amount to a specific level"
    static var openAppWhenRun = true

    @Parameter(title: "Percent", default: 60,
               controlStyle: .field,
               inclusiveRange: (0, 100))
    var percent: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Set audio sensitivity to \(\.$percent)%")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let appModel = AppModel.shared else {
            return .result(dialog: "Threshold app not available")
        }

        let clamped = max(0, min(100, percent))
        appModel.renderSettings.fractalAudioAmount = Float(clamped) / 100.0
        return .result(dialog: "Audio sensitivity set to \(clamped)%")
    }
}

// MARK: - AppShortcutsProvider
struct ThresholdAppShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PlayAnimationIntent(),
            phrases: ["Play the animation in \(.applicationName)",
                      "Start \(.applicationName) animation"],
            shortTitle: "Play",
            systemImageName: "play.fill"
        )

        AppShortcut(
            intent: PauseAnimationIntent(),
            phrases: ["Pause the animation in \(.applicationName)",
                      "Pause \(.applicationName)"],
            shortTitle: "Pause",
            systemImageName: "pause.fill"
        )

        AppShortcut(
            intent: StopAnimationIntent(),
            phrases: ["Stop the animation in \(.applicationName)",
                      "Stop \(.applicationName)"],
            shortTitle: "Stop",
            systemImageName: "stop.fill"
        )

        AppShortcut(
            intent: EnableAudioReactivityIntent(),
            phrases: ["Enable audio reactivity in \(.applicationName)",
                      "Turn on \(.applicationName) audio"],
            shortTitle: "Enable Audio",
            systemImageName: "waveform.circle.fill"
        )

        AppShortcut(
            intent: DisableAudioReactivityIntent(),
            phrases: ["Disable audio reactivity in \(.applicationName)",
                      "Turn off \(.applicationName) audio"],
            shortTitle: "Disable Audio",
            systemImageName: "waveform.circle"
        )

        AppShortcut(
            intent: ToggleAudioReactivityIntent(),
            phrases: ["Toggle audio reactivity in \(.applicationName)"],
            shortTitle: "Toggle Audio",
            systemImageName: "waveform.circle.fill"
        )

        AppShortcut(
            intent: IncreaseAudioAmountIntent(),
            phrases: ["Increase audio sensitivity in \(.applicationName)",
                      "Turn up \(.applicationName) audio"],
            shortTitle: "Boost Audio",
            systemImageName: "speaker.wave.2.fill"
        )

        AppShortcut(
            intent: DecreaseAudioAmountIntent(),
            phrases: ["Decrease audio sensitivity in \(.applicationName)",
                      "Turn down \(.applicationName) audio"],
            shortTitle: "Lower Audio",
            systemImageName: "speaker.wave.1.fill"
        )

        AppShortcut(
            intent: IncreaseBeatPunchIntent(),
            phrases: ["Increase beat punch in \(.applicationName)",
                      "More \(.applicationName) beat punch"],
            shortTitle: "Boost Beat",
            systemImageName: "bolt.fill"
        )

        AppShortcut(
            intent: DecreaseBeatPunchIntent(),
            phrases: ["Decrease beat punch in \(.applicationName)",
                      "Less \(.applicationName) beat punch"],
            shortTitle: "Lower Beat",
            systemImageName: "bolt"
        )

        AppShortcut(
            intent: ToggleMusicPlaybackIntent(),
            phrases: ["Play or pause music in \(.applicationName)",
                      "Play music in \(.applicationName)",
                      "Pause music in \(.applicationName)"],
            shortTitle: "Play/Pause Music",
            systemImageName: "playpause.fill"
        )

        AppShortcut(
            intent: NextTrackIntent(),
            phrases: ["Next track in \(.applicationName)",
                      "Skip track in \(.applicationName)"],
            shortTitle: "Next Track",
            systemImageName: "forward.fill"
        )

        AppShortcut(
            intent: PreviousTrackIntent(),
            phrases: ["Previous track in \(.applicationName)"],
            shortTitle: "Previous Track",
            systemImageName: "backward.fill"
        )

        AppShortcut(
            intent: NowPlayingIntent(),
            phrases: ["What's playing in \(.applicationName)",
                      "What song is \(.applicationName) playing"],
            shortTitle: "Now Playing",
            systemImageName: "music.note"
        )

        AppShortcut(
            intent: SwitchFractalTypeIntent(),
            phrases: ["Switch fractal in \(.applicationName)",
                      "Change \(.applicationName) fractal"],
            shortTitle: "Switch Fractal",
            systemImageName: "cube.transparent"
        )

        AppShortcut(
            intent: SetAudioSensitivityIntent(),
            phrases: ["Set audio sensitivity in \(.applicationName)"],
            shortTitle: "Set Sensitivity",
            systemImageName: "dial.medium"
        )
    }
}
