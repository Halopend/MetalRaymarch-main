import AppIntents
import SwiftUI

// MARK: - Play Animation
struct PlayAnimationIntent: AppIntent {
    static let title: LocalizedStringResource = "Play animation"
    static let description: LocalizedStringResource = "Start playing the current animation scene"
    static let openAppWhenRun = true

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
    static let title: LocalizedStringResource = "Pause animation"
    static let description: LocalizedStringResource = "Pause the current animation scene"
    static let openAppWhenRun = true

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
    static let title: LocalizedStringResource = "Stop animation"
    static let description: LocalizedStringResource = "Stop the current animation scene"
    static let openAppWhenRun = true

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
    static let title: LocalizedStringResource = "Toggle audio reactivity"
    static let description: LocalizedStringResource = "Enable or disable audio-reactive visualization"
    static let openAppWhenRun = true

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
    static let title: LocalizedStringResource = "Enable audio reactivity"
    static let description: LocalizedStringResource = "Enable audio-reactive visualization"
    static let openAppWhenRun = true

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
    static let title: LocalizedStringResource = "Disable audio reactivity"
    static let description: LocalizedStringResource = "Disable audio-reactive visualization"
    static let openAppWhenRun = true

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
    static let title: LocalizedStringResource = "Increase audio sensitivity"
    static let description: LocalizedStringResource = "Increase the audio reactivity amount"
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let appModel = AppModel.shared else {
            return .result(dialog: "Threshold app not available")
        }

        let currentValue = appModel.renderSettings.fractalAudioAmount
        let newValue = min(1.0, currentValue + 0.1)
        appModel.renderSettings.fractalAudioAmount = newValue
        return .result(dialog: "Audio sensitivity set to \(Int((newValue * 100).rounded()))%")
    }
}

// MARK: - Decrease Audio Amount
struct DecreaseAudioAmountIntent: AppIntent {
    static let title: LocalizedStringResource = "Decrease audio sensitivity"
    static let description: LocalizedStringResource = "Decrease the audio reactivity amount"
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let appModel = AppModel.shared else {
            return .result(dialog: "Threshold app not available")
        }

        let currentValue = appModel.renderSettings.fractalAudioAmount
        let newValue = max(0.0, currentValue - 0.1)
        appModel.renderSettings.fractalAudioAmount = newValue
        return .result(dialog: "Audio sensitivity set to \(Int((newValue * 100).rounded()))%")
    }
}

// MARK: - Increase Beat Punch
struct IncreaseBeatPunchIntent: AppIntent {
    static let title: LocalizedStringResource = "Increase beat punch"
    static let description: LocalizedStringResource = "Increase the beat detection intensity"
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let appModel = AppModel.shared else {
            return .result(dialog: "Threshold app not available")
        }

        let currentValue = appModel.renderSettings.fractalBeatPunch
        let newValue = min(1.0, currentValue + 0.1)
        appModel.renderSettings.fractalBeatPunch = newValue
        return .result(dialog: "Beat punch set to \(Int((newValue * 100).rounded()))%")
    }
}

// MARK: - Decrease Beat Punch
struct DecreaseBeatPunchIntent: AppIntent {
    static let title: LocalizedStringResource = "Decrease beat punch"
    static let description: LocalizedStringResource = "Decrease the beat detection intensity"
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let appModel = AppModel.shared else {
            return .result(dialog: "Threshold app not available")
        }

        let currentValue = appModel.renderSettings.fractalBeatPunch
        let newValue = max(0.0, currentValue - 0.1)
        appModel.renderSettings.fractalBeatPunch = newValue
        return .result(dialog: "Beat punch set to \(Int((newValue * 100).rounded()))%")
    }
}

// ════════════════════════════════════════════════════════════════════════════
// MARK: - Music Transport (Apple Music / Spotify via MusicService)
// ════════════════════════════════════════════════════════════════════════════

// MARK: - Toggle Play/Pause Music
struct ToggleMusicPlaybackIntent: AppIntent {
    static let title: LocalizedStringResource = "Play or pause music"
    static let description: LocalizedStringResource = "Toggle playback of the music feeding the visualizer"
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let appModel = AppModel.shared else {
            return .result(dialog: "Threshold app not available")
        }

        appModel.musicService.togglePlayPause()
        // Transport is fire-and-forget (the provider runs async), so isPlaying
        // still reflects the pre-toggle state here. Report the action rather
        // than a state that may be wrong by the time Siri speaks it.
        return .result(dialog: "Toggling music playback")
    }
}

// MARK: - Next Track
struct NextTrackIntent: AppIntent {
    static let title: LocalizedStringResource = "Next track"
    static let description: LocalizedStringResource = "Skip to the next track"
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let appModel = AppModel.shared else {
            return .result(dialog: "Threshold app not available")
        }

        appModel.musicService.next()
        // nowPlaying still reflects the previous track until the provider's
        // async transport completes, so report the action, not a stale track.
        return .result(dialog: "Skipping to the next track")
    }
}

// MARK: - Previous Track
struct PreviousTrackIntent: AppIntent {
    static let title: LocalizedStringResource = "Previous track"
    static let description: LocalizedStringResource = "Go back to the previous track"
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let appModel = AppModel.shared else {
            return .result(dialog: "Threshold app not available")
        }

        appModel.musicService.previous()
        // Same async caveat as next track: avoid announcing a stale track.
        return .result(dialog: "Going to the previous track")
    }
}

// MARK: - Now Playing (query)
struct NowPlayingIntent: AppIntent {
    static let title: LocalizedStringResource = "What's playing"
    static let description: LocalizedStringResource = "Report the track currently feeding the visualizer"
    static let openAppWhenRun = false

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
    // Each case's rawValue == the matching FractalModelType.codableString, so
    // `modelType` resolves by lookup (no converter switch). Covers every
    // selectable static type (previously missing 3 → unreachable via Siri).
    case mandelbox
    case mandelbulb
    case mandelbulbJulia
    case menger
    case quaternionJulia
    case octahedron
    case mengerSphere
    case theliPseudoKleinian
    case kleinian
    case boxSphereFolder
    case bulatovLimitSet

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Fractal Type"

    static let caseDisplayRepresentations: [FractalTypeAppEnum: DisplayRepresentation] = [
        .mandelbox: "Mandelbox",
        .mandelbulb: "Mandelbulb",
        .mandelbulbJulia: "Mandelbulb Julia",
        .menger: "Menger Sponge",
        .quaternionJulia: "Quaternion Julia",
        .octahedron: "Octahedron",
        .mengerSphere: "Menger Sphere",
        .theliPseudoKleinian: "Theli Pseudo Kleinian",
        .kleinian: "Kleinian",
        .boxSphereFolder: "Box Sphere Folder",
        .bulatovLimitSet: "Bulatov Limit Set",
    ]

    /// Maps back to the engine enum by matching the shared codableString
    /// (AppEnum case name == FractalModelType.codableString).
    var modelType: FractalModelType {
        FractalModelType.allCases.first { $0.descriptor.codableString == rawValue } ?? .mandelbox
    }
}

// MARK: - Switch Fractal Type
struct SwitchFractalTypeIntent: AppIntent {
    static let title: LocalizedStringResource = "Switch fractal"
    static let description: LocalizedStringResource = "Change the active fractal type"
    static let openAppWhenRun = true

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
    static let title: LocalizedStringResource = "Set audio sensitivity"
    static let description: LocalizedStringResource = "Set the audio reactivity amount to a specific level"
    static let openAppWhenRun = true

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
    // NOTE: AppShortcutsProvider registers a MAXIMUM of 10 App Shortcuts —
    // anything past the 10th is silently dropped. The full set of intents below
    // is still available in the Shortcuts app and Spotlight; this list is just
    // the curated zero-config voice phrases. Keep it at 10 and lead with the
    // highest-value voice commands (parameterized ones especially).
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
            intent: ToggleAudioReactivityIntent(),
            phrases: ["Toggle audio reactivity in \(.applicationName)",
                      "Turn on \(.applicationName) audio",
                      "Turn off \(.applicationName) audio"],
            shortTitle: "Toggle Audio",
            systemImageName: "waveform.circle.fill"
        )

        AppShortcut(
            intent: SetAudioSensitivityIntent(),
            phrases: ["Set audio sensitivity in \(.applicationName)"],
            shortTitle: "Set Sensitivity",
            systemImageName: "dial.medium"
        )

        AppShortcut(
            intent: IncreaseBeatPunchIntent(),
            phrases: ["Increase beat punch in \(.applicationName)",
                      "More \(.applicationName) beat punch"],
            shortTitle: "Boost Beat",
            systemImageName: "bolt.fill"
        )

        AppShortcut(
            intent: SwitchFractalTypeIntent(),
            phrases: ["Switch fractal in \(.applicationName)",
                      "Change \(.applicationName) fractal"],
            shortTitle: "Switch Fractal",
            systemImageName: "cube.transparent"
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
    }
}
