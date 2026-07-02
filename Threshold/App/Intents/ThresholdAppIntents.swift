// App Intents for Threshold - Siri Integration
// Controls fractal animations and music visualization
//
// QUARANTINED 2026-07-01: this file is work-in-progress (syntax/concurrency
// errors) and its folder is auto-included in every target by the synchronized
// group, so it was breaking all builds. Compiled out until it's finished —
// remove the #if/#endif wrapper (or define ENABLE_WIP_APP_INTENTS) to resume.
#if ENABLE_WIP_APP_INTENTS

import AppIntents
import Foundation

// MARK: - App Entities

struct SceneEntity: AppEntity {
    static let defaultQuery = SceneEntityQuery()
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Fractal Scene"
    var id: String

    @Property(title: "Name") var name: String
    @Property(title: "Description") var description: String
    @Property(title: "Complexity") var complexity: Double

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "Complexity: \(String(format: "%.1f", complexity))")
    }

    init(from scene: Scene) {
        self.id = scene.id
        self.name = scene.name
        self.description = scene.description
        self.complexity = scene.complexity
    }
}

struct MusicPresetEntity: AppEntity {
    static let defaultQuery = MusicPresetEntityQuery()
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Music Preset"
    var id: String

    @Property(title: "Title") var title: String
    @Property(title: "BPM") var bpm: Double
    @Property(title: "Energy") var energy: Double

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "BPM: \(Int(bpm)) | Energy: \(String(format: "%.1f", energy))")
    }

    init(from preset: MusicPreset) {
        self.id = preset.id
        self.title = preset.title
        self.bpm = preset.bpm
        self.energy = preset.energy
    }
}

// MARK: - Entity Queries

struct SceneEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [SceneEntity] {
        // Implementation would fetch scenes from storage
        return []
    }

    func suggestedEntities() async throws -> [SceneEntity] {
        // Return featured scenes
        return []
    }
}

struct MusicPresetEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [MusicPresetEntity] {
        // Implementation would fetch presets from storage
        return []
    }

    func suggestedEntities() async throws -> [MusicPresetEntity] {
        // Return popular presets
        return []
    }
}

// MARK: - App Enums

enum AnimationSpeed: String, AppEnum {
    case slow, normal, fast, turbo

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Speed"

    static var caseDisplayRepresentations: [AnimationSpeed: DisplayRepresentation] = [
        .slow: "Slow",
        .normal: "Normal",
        .fast: "Fast",
        .turbo: "Turbo"
    ]
}

enum IntentLightingMode: String, AppEnum {
    case ambient, directional, point, volumetric

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Lighting"

    static var caseDisplayRepresentations: [IntentLightingMode: DisplayRepresentation] = [
        .ambient: "Ambient",
        .directional: "Directional",
        .point: "Point",
        .volumetric: "Volumetric"
    ]
}

enum MoodPreset: String, AppEnum {
    case calm, energetic, mysterious, cosmic, abstract

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Mood"

    static var caseDisplayRepresentations: [MoodPreset: DisplayRepresentation] = [
        .calm: "Calm",
        .energetic: "Energetic",
        .mysterious: "Mysterious",
        .cosmic: "Cosmic",
        .abstract: "Abstract"
    ]
}

// MARK: - Main App Intents

struct ToggleAnimationIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle Animation"
    static var description = IntentDescription("Play or pause the current fractal animation")

    @Parameter(title: "Scene", default: "current") var scene: SceneEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Toggle animation for \($scene)")
    }

    func perform() async throws -> some IntentResult {
        // Implementation would toggle animation playback
        return .result(dialog: "Animation \(scene.name) toggled")
    }
}

struct SetLightingIntensityIntent: AppIntent {
    static var title: LocalizedStringResource = "Set Lighting Intensity"
    static var description = IntentDescription("Adjust the lighting intensity of the visualization")

    @Parameter(title: "Intensity", controlStyle: .slider, inclusiveRange: (0.0, 1.0), default: 0.5)
    var intensity: Double

    @Parameter(title: "Mode", default: IntentLightingMode.ambient)
    var mode: IntentLightingMode

    static var parameterSummary: some ParameterSummary {
        Summary("Set lighting intensity to \(String(format: "%.1f", \.$intensity)) in \($mode)")
    }

    func perform() async throws -> some IntentResult {
        // Implementation would set lighting intensity
        return .result(dialog: "Lighting intensity set to \(String(format: "%.1f", intensity)) in \(mode)")
    }
}

struct AdjustTempoIntent: AppIntent {
    static var title: LocalizedStringResource = "Adjust Tempo"
    static var description = IntentDescription("Control the animation tempo and damping")

    @Parameter(title: "Tempo", controlStyle: .slider, inclusiveRange: (0.1, 5.0), default: 1.0)
    var tempo: Double

    @Parameter(title: "Damping", controlStyle: .slider, inclusiveRange: (0.0, 1.0), default: 0.5)
    var damping: Double

    static var parameterSummary: some ParameterSummary {
        Summary("Set tempo to \(String(format: "%.1f", \.$tempo)) and damping to \(String(format: "%.1f", \.$damping))")
    }

    func perform() async throws -> some IntentResult {
        // Implementation would adjust tempo and damping
        return .result(dialog: "Tempo set to \(String(format: "%.1f", tempo)) and damping to \(String(format: "%.1f", damping))")
    }
}

struct SetMoodIntent: AppIntent {
    static var title: LocalizedStringResource = "Set Mood"
    static var description = IntentDescription("Apply a mood preset to the visualization")

    @Parameter(title: "Mood", default: MoodPreset.cosmic)
    var mood: MoodPreset

    @Parameter(title: "Intensity", controlStyle: .slider, inclusiveRange: (0.0, 1.0), default: 0.7)
    var intensity: Double

    static var parameterSummary: some ParameterSummary {
        Summary("Apply \($mood) mood with intensity \(String(format: "%.1f", \.$intensity))")
    }

    func perform() async throws -> some IntentResult {
        // Implementation would apply mood preset
        return .result(dialog: "Applied \(mood) mood with intensity \(String(format: "%.1f", intensity))")
    }
}

struct ApplySpaceEffectIntent: AppIntent {
    static var title: LocalizedStringResource = "Apply Space Effect"
    static var description = IntentDescription("Apply space transformation effects to the visualization")

    @Parameter(title: "Effect Type", optionsProvider: SpaceEffectOptionsProvider())
    var effectType: String

    @Parameter(title: "Intensity", controlStyle: .slider, inclusiveRange: (0.0, 1.0), default: 0.5)
    var intensity: Double

    static var parameterSummary: some ParameterSummary {
        Summary("Apply \($effectType) effect with intensity \(String(format: "%.1f", \.$intensity))")
    }

    func perform() async throws -> some IntentResult {
        // Implementation would apply space effect
        return .result(dialog: "Applied \(effectType) effect with intensity \(String(format: "%.1f", intensity))")
    }
}

// MARK: - App Shortcuts Provider

struct ThresholdAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        [
            AppShortcut(
                intent: ToggleAnimationIntent(),
                phrases: [
                    "Toggle animation",
                    "Play/pause fractal animation",
                    "Start/stop Threshold animation"
                ],
                shortTitle: "Toggle",
                systemImageName: "play.pause"
            ),
            AppShortcut(
                intent: SetLightingIntensityIntent(),
                phrases: [
                    "Set lighting intensity",
                    "Adjust lights",
                    "Change lighting in Threshold"
                ],
                shortTitle: "Lighting",
                systemImageName: "lightbulb"
            ),
            AppShortcut(
                intent: AdjustTempoIntent(),
                phrases: [
                    "Adjust tempo",
                    "Set animation speed",
                    "Change tempo in Threshold"
                ],
                shortTitle: "Tempo",
                systemImageName: "speedometer"
            ),
            AppShortcut(
                intent: SetMoodIntent(),
                phrases: [
                    "Set mood",
                    "Apply mood preset",
                    "Change mood in Threshold"
                ],
                shortTitle: "Mood",
                systemImageName: "moon"
            ),
            AppShortcut(
                intent: ApplySpaceEffectIntent(),
                phrases: [
                    "Apply space effect",
                    "Add space transformation",
                    "Apply cosmic effect"
                ],
                shortTitle: "Space",
                systemImageName: "star"
            )
        ]
    }

    static var shortcutTileColor: ShortcutTileColor = .systemBlue
}

// MARK: - Supporting Types

struct Scene {
    let id: String
    let name: String
    let description: String
    let complexity: Double
}

struct MusicPreset {
    let id: String
    let title: String
    let bpm: Double
    let energy: Double
}

struct SpaceEffectOptionsProvider: OptionsProvider {
    func options(for parameter: Parameter<IntentFile>) -> [IntentFile] {
        // Return available space effects
        []
    }
}
#endif  // ENABLE_WIP_APP_INTENTS
