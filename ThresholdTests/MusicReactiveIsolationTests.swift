import Foundation
import Testing
@testable import Threshold

@Suite("Music reactive effect isolation")
struct MusicReactiveIsolationTests {
    private func mappings() -> [MusicReactiveMapping] {
        [
            MusicReactiveTarget.fractalScale.defaultMapping(enabled: true),
            MusicReactiveTarget.glow.defaultMapping(enabled: false),
            MusicReactiveTarget.fog.defaultMapping(enabled: true),
        ]
    }

    @Test("Isolation is immediate, temporary, and restores authored enabled states")
    func isolatesAndRestores() {
        let settings = RenderSettings()
        let authored = mappings()
        settings.musicReactiveMappings = authored

        #expect(settings.setMusicReactiveIsolation(authored[1].id))
        #expect(settings.isolatedMusicReactiveMappingID == authored[1].id)
        #expect(settings.effectiveMusicReactiveMappings.map(\.isEnabled) == [false, true, false])

        // Neither the authored model nor its persistence snapshot contains the
        // temporary disabled states.
        #expect(settings.musicReactiveMappings.map(\.isEnabled) == [true, false, true])
        #expect(settings.audioReactiveConfig.musicReactiveMappings.map(\.isEnabled) == [true, false, true])

        #expect(settings.setMusicReactiveIsolation(nil))
        #expect(settings.isolatedMusicReactiveMappingID == nil)
        #expect(settings.effectiveMusicReactiveMappings.map(\.isEnabled) == [true, false, true])
    }

    @Test("Selecting another effect switches isolation without losing the baseline")
    func switchesIsolatedEffect() {
        let settings = RenderSettings()
        let authored = mappings()
        settings.musicReactiveMappings = authored

        #expect(settings.setMusicReactiveIsolation(authored[0].id))
        #expect(settings.effectiveMusicReactiveMappings.map(\.isEnabled) == [true, false, false])

        #expect(settings.setMusicReactiveIsolation(authored[2].id))
        #expect(settings.effectiveMusicReactiveMappings.map(\.isEnabled) == [false, false, true])

        settings.setMusicReactiveIsolation(nil)
        #expect(settings.effectiveMusicReactiveMappings.map(\.isEnabled) == [true, false, true])
    }

    @Test("Removing or restoring over the isolated effect ends the temporary session safely")
    func invalidationEndsIsolation() {
        let settings = RenderSettings()
        let authored = mappings()
        settings.musicReactiveMappings = authored
        settings.setMusicReactiveIsolation(authored[1].id)

        settings.musicReactiveMappings = [authored[0], authored[2]]
        #expect(settings.isolatedMusicReactiveMappingID == nil)
        #expect(settings.effectiveMusicReactiveMappings.map(\.isEnabled) == [true, true])

        settings.musicReactiveMappings = authored
        settings.setMusicReactiveIsolation(authored[0].id)
        let restoredConfig = settings.audioReactiveConfig
        settings.audioReactiveConfig = restoredConfig
        #expect(settings.isolatedMusicReactiveMappingID == nil)
        #expect(settings.effectiveMusicReactiveMappings.map(\.isEnabled) == [true, false, true])
    }

    @Test("Unknown mapping cannot replace the current isolation target")
    func rejectsUnknownMapping() {
        let settings = RenderSettings()
        let authored = mappings()
        settings.musicReactiveMappings = authored
        settings.setMusicReactiveIsolation(authored[0].id)

        #expect(!settings.setMusicReactiveIsolation(UUID()))
        #expect(settings.isolatedMusicReactiveMappingID == authored[0].id)
        #expect(settings.effectiveMusicReactiveMappings.map(\.isEnabled) == [true, false, false])
    }
}
