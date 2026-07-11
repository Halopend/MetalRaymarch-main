import Foundation
import Testing
@testable import Threshold

@Suite("Music preset banks")
struct MusicPresetBankTests {
    private func preset(
        _ name: String,
        id: UUID = UUID(),
        musicReactive: Bool = false,
        custom: Bool = false,
        mixed: Bool = false
    ) -> FractalPreset {
        var preset = FractalPreset(id: id, name: name)
        if musicReactive {
            preset.musicReactiveMappings = [
                MusicReactiveMapping(
                    target: .glow,
                    source: .beat,
                    amount: 1,
                    isEnabled: true
                )
            ]
        }
        if custom {
            preset.embeddedFormula = EmbeddedFormula(
                id: "test.\(id.uuidString)",
                name: "Test Formula",
                functionStem: "TestFormula",
                metalSource: "// Test-only marker",
                params: []
            )
        }
        if mixed {
            preset.mixedModeScene = true
        }
        return preset
    }

    @Test("banks filter and preserve the authored preset order")
    func bankFiltering() {
        let jumpingOff = preset("Static")
        let nameOverride = preset("Mandel box flower", musicReactive: true)
        let musicReactive = preset("Reactive", musicReactive: true)
        let lastState = preset("__lastState__")
        let custom = preset("Custom", custom: true)
        let mixed = preset("Mixed", mixed: true)
        let source = [jumpingOff, nameOverride, musicReactive, lastState, custom, mixed]

        #expect(
            MusicPresetBank.jumpingOff.presets(from: source).map(\.id)
                == [jumpingOff.id, nameOverride.id]
        )
        #expect(
            MusicPresetBank.musicReactive.presets(from: source).map(\.id)
                == [musicReactive.id]
        )
        #expect(
            MusicPresetBank.allStatic.presets(from: source).map(\.id)
                == [jumpingOff.id, nameOverride.id, musicReactive.id]
        )
    }

    @Test("bank classification prefers canonical audio config over legacy mappings")
    func bankClassificationUsesCanonicalAudioConfig() {
        let mapping = MusicReactiveMapping(
            target: .glow,
            source: .beat,
            amount: 1,
            isEnabled: true
        )

        var canonicalOnly = preset("Canonical only")
        var canonicalReactiveConfig = AudioReactiveConfig()
        canonicalReactiveConfig.musicReactiveMappings = [mapping]
        canonicalOnly.audioReactiveConfig = canonicalReactiveConfig
        canonicalOnly.musicReactiveMappings = nil

        var staleLegacy = preset("Stale legacy", musicReactive: true)
        staleLegacy.audioReactiveConfig = AudioReactiveConfig()

        let source = [canonicalOnly, staleLegacy]
        #expect(MusicPresetBank.musicReactive.presets(from: source).map(\.id) == [canonicalOnly.id])
        #expect(MusicPresetBank.jumpingOff.presets(from: source).map(\.id) == [staleLegacy.id])
    }

    @Test("effect defaults are safe and cadence is normalized to at least one drop")
    func effectDefaultsAndNormalization() {
        let defaults = MusicPresetBankEffect()
        #expect(defaults.isEnabled == false)
        #expect(defaults.bank == .musicReactive)
        #expect(defaults.dropsPerChange == 8)
        #expect(defaults.minimumInterval == 8)

        let normalized = MusicPresetBankEffect(
            isEnabled: true,
            bank: .allStatic,
            dropsPerChange: 0,
            minimumInterval: .nan
        )
        #expect(normalized.dropsPerChange == 1)
        #expect(normalized.minimumInterval == 8)

        let clamped = MusicPresetBankEffect(
            dropsPerChange: 100,
            minimumInterval: 0
        )
        #expect(clamped.dropsPerChange == 32)
        #expect(clamped.minimumInterval == 2)
    }

    @Test("effect configuration round-trips through Codable")
    func effectCodableRoundTrip() throws {
        let effect = MusicPresetBankEffect(
            isEnabled: true,
            bank: .jumpingOff,
            dropsPerChange: 3,
            minimumInterval: 12
        )

        let decoded = try JSONDecoder().decode(
            MusicPresetBankEffect.self,
            from: JSONEncoder().encode(effect)
        )

        #expect(decoded == effect)
    }

    @Test("legacy music config without a bank effect decodes to disabled defaults")
    func legacyMusicConfigDefaultsBankEffect() throws {
        let legacyJSON = #"""
        {
            "preferences": {
                "preferredServiceID": null,
                "servicePriority": ["appleMusic"]
            },
            "presets": []
        }
        """#

        let decoded = try JSONDecoder().decode(
            SettingsPersistence.MusicConfig.self,
            from: Data(legacyJSON.utf8)
        )

        #expect(decoded.preferences.preferredServiceID == nil)
        #expect(decoded.preferences.servicePriority == ["appleMusic"])
        #expect(decoded.presets.isEmpty)
        #expect(decoded.presetBankEffect == MusicPresetBankEffect())
    }

    @Test("unknown future bank values do not discard the rest of music config")
    func unknownBankValueIsContained() throws {
        let futureJSON = #"""
        {
            "preferences": {
                "preferredServiceID": "appleMusic",
                "servicePriority": ["appleMusic"]
            },
            "presets": [],
            "presetBankEffect": {
                "isEnabled": true,
                "bank": "futureBank",
                "dropsPerChange": 4,
                "minimumInterval": 12
            }
        }
        """#

        let decoded = try JSONDecoder().decode(
            SettingsPersistence.MusicConfig.self,
            from: Data(futureJSON.utf8)
        )

        #expect(decoded.preferences.preferredServiceID == "appleMusic")
        #expect(decoded.preferences.servicePriority == ["appleMusic"])
        #expect(decoded.presetBankEffect.isEnabled)
        #expect(decoded.presetBankEffect.bank == .musicReactive)
        #expect(decoded.presetBankEffect.dropsPerChange == 4)
        #expect(decoded.presetBankEffect.minimumInterval == 12)
    }

    @Test("music config persists its selected bank effect")
    func musicConfigPersistsBankEffect() throws {
        let effect = MusicPresetBankEffect(
            isEnabled: true,
            bank: .allStatic,
            dropsPerChange: 5,
            minimumInterval: 15
        )
        var config = SettingsPersistence.MusicConfig()
        config.presetBankEffect = effect

        let decoded = try JSONDecoder().decode(
            SettingsPersistence.MusicConfig.self,
            from: JSONEncoder().encode(config)
        )

        #expect(decoded.presetBankEffect == effect)
    }

    @Test("cycler advances in either direction and wraps at both ends")
    func cyclerAdvancesAndWraps() {
        let a = preset("A")
        let b = preset("B")
        let c = preset("C")
        let presets = [a, b, c]

        #expect(MusicPresetBankCycler.nextPreset(in: presets, after: a.id)?.id == b.id)
        #expect(MusicPresetBankCycler.nextPreset(in: presets, after: c.id)?.id == a.id)
        #expect(MusicPresetBankCycler.nextPreset(in: presets, after: c.id, forward: false)?.id == b.id)
        #expect(MusicPresetBankCycler.nextPreset(in: presets, after: a.id, forward: false)?.id == c.id)
    }

    @Test("cycler handles empty, unknown-current, and singleton banks")
    func cyclerBoundaryCases() {
        let only = preset("Only")
        let unknown = UUID()

        #expect(MusicPresetBankCycler.nextPreset(in: [], after: nil) == nil)
        #expect(MusicPresetBankCycler.nextPreset(in: [only], after: nil)?.id == only.id)
        #expect(MusicPresetBankCycler.nextPreset(in: [only], after: only.id)?.id == only.id)
        #expect(MusicPresetBankCycler.nextPreset(in: [only], after: unknown)?.id == only.id)

        let first = preset("First")
        let last = preset("Last")
        #expect(MusicPresetBankCycler.nextPreset(in: [first, last], after: unknown)?.id == first.id)
        #expect(
            MusicPresetBankCycler.nextPreset(
                in: [first, last],
                after: unknown,
                forward: false
            )?.id == last.id
        )
    }

    @Test("one sustained beat is counted once and a low level rearms the trigger")
    func triggerUsesRisingEdges() {
        var trigger = MusicPresetBankTrigger()
        let configuration = MusicPresetBankEffect(isEnabled: true, dropsPerChange: 2)

        #expect(trigger.update(
            beatIntensity: 1,
            configuration: configuration,
            hasActiveSource: true,
            now: 0
        ) == false)
        #expect(trigger.update(
            beatIntensity: 1,
            configuration: configuration,
            hasActiveSource: true,
            now: 100
        ) == false)
        #expect(trigger.update(
            beatIntensity: 0,
            configuration: configuration,
            hasActiveSource: true,
            now: 101
        ) == false)
        #expect(trigger.update(
            beatIntensity: 1,
            configuration: configuration,
            hasActiveSource: true,
            now: 200
        ) == true)
    }

    @Test("raw Drop envelope remains active when a scene sets beat sensitivity to zero")
    func rawDropEnvelopeIgnoresSceneBeatSensitivity() {
        var sceneAudioConfig = AudioReactiveConfig()
        sceneAudioConfig.beatSensitivity = 0
        let rawDrop = MusicPresetBankDropEnvelope.merged(
            analyzerOnset: 1,
            analyzerIsActive: true,
            playbackBeat: 0,
            playbackIsActive: false
        )

        #expect(rawDrop == 1)
        #expect(rawDrop * sceneAudioConfig.beatSensitivity == 0)

        var trigger = MusicPresetBankTrigger()
        let configuration = MusicPresetBankEffect(isEnabled: true, dropsPerChange: 1)
        let didTrigger = trigger.update(
            beatIntensity: rawDrop,
            configuration: configuration,
            hasActiveSource: true,
            now: 0
        )
        #expect(didTrigger)
    }

    @Test("trigger fires only after the configured number of distinct drops")
    func triggerHonorsDropCadence() {
        var trigger = MusicPresetBankTrigger()
        let configuration = MusicPresetBankEffect(isEnabled: true, dropsPerChange: 3)

        #expect(drop(on: &trigger, configuration: configuration, at: 0) == false)
        #expect(drop(on: &trigger, configuration: configuration, at: 10) == false)
        #expect(drop(on: &trigger, configuration: configuration, at: 20) == true)
        #expect(drop(on: &trigger, configuration: configuration, at: 30) == false)
    }

    @Test("trigger debounces onset bounce inside the minimum Drop interval")
    func triggerDebouncesOnsetBounce() {
        var trigger = MusicPresetBankTrigger()
        let configuration = MusicPresetBankEffect(isEnabled: true, dropsPerChange: 2)

        #expect(drop(on: &trigger, configuration: configuration, at: 0) == false)
        #expect(drop(on: &trigger, configuration: configuration, at: 0.1) == false)
        #expect(drop(on: &trigger, configuration: configuration, at: 0.21) == true)
    }

    @Test("cooldown rejects an immediate scene change and later permits one")
    func triggerEnforcesCooldown() {
        var trigger = MusicPresetBankTrigger()
        let configuration = MusicPresetBankEffect(
            isEnabled: true,
            dropsPerChange: 1,
            minimumInterval: 2
        )

        #expect(drop(on: &trigger, configuration: configuration, at: 0) == true)
        #expect(drop(on: &trigger, configuration: configuration, at: 0.5) == false)
        #expect(drop(on: &trigger, configuration: configuration, at: 2.1) == true)
    }

    @Test("disabled configuration and missing audio source reset trigger state")
    func triggerRequiresEnabledEffectAndActiveSource() {
        var trigger = MusicPresetBankTrigger()
        let enabled = MusicPresetBankEffect(isEnabled: true, dropsPerChange: 1)
        let disabled = MusicPresetBankEffect(isEnabled: false, dropsPerChange: 1)

        #expect(trigger.update(
            beatIntensity: 1,
            configuration: disabled,
            hasActiveSource: true,
            now: 0
        ) == false)
        #expect(trigger.update(
            beatIntensity: 1,
            configuration: enabled,
            hasActiveSource: true,
            now: 1
        ) == true)

        #expect(trigger.update(
            beatIntensity: 0,
            configuration: enabled,
            hasActiveSource: true,
            now: 2
        ) == false)
        #expect(trigger.update(
            beatIntensity: 1,
            configuration: enabled,
            hasActiveSource: false,
            now: 3
        ) == false)
        #expect(trigger.update(
            beatIntensity: 1,
            configuration: enabled,
            hasActiveSource: true,
            now: 4
        ) == true)
    }

    @Test("explicit reset clears a partial cadence")
    func triggerResetClearsProgress() {
        var trigger = MusicPresetBankTrigger()
        let configuration = MusicPresetBankEffect(isEnabled: true, dropsPerChange: 2)

        #expect(drop(on: &trigger, configuration: configuration, at: 0) == false)
        trigger.reset()
        #expect(drop(on: &trigger, configuration: configuration, at: 10) == false)
        #expect(drop(on: &trigger, configuration: configuration, at: 20) == true)
    }

    private func drop(
        on trigger: inout MusicPresetBankTrigger,
        configuration: MusicPresetBankEffect,
        at time: TimeInterval
    ) -> Bool {
        _ = trigger.update(
            beatIntensity: 0,
            configuration: configuration,
            hasActiveSource: true,
            now: time - 0.001
        )
        return trigger.update(
            beatIntensity: 1,
            configuration: configuration,
            hasActiveSource: true,
            now: time
        )
    }
}
