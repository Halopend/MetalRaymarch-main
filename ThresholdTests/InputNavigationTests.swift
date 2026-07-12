import Testing
@testable import Threshold

@Suite("Input navigation taxonomy")
struct InputNavigationTests {

    @Test("Visible Input sections omit legacy split reactivity routes")
    func visibleSections() {
        #expect(MusicRailSection.visibleCases == [
            .playback, .reactive, .songs, .playlists, .albums
        ])

        #if os(macOS)
        #expect(MusicRailSection.availableCases == [.playback, .reactive])
        #else
        #expect(MusicRailSection.availableCases == MusicRailSection.visibleCases)
        #endif

        #expect(!MusicRailSection.visibleCases.contains(.mappings))
        #expect(!MusicRailSection.visibleCases.contains(.presets))
    }

    @Test("Legacy Input routes canonicalize to the combined Reactivity page")
    func legacyRoutesCanonicalize() {
        #expect(MusicRailSection.mappings.canonical == .reactive)
        #expect(MusicRailSection.presets.canonical == .reactive)
        #expect(MusicRailSection(rawValue: "Mappings")?.canonical == .reactive)
        #expect(MusicRailSection(rawValue: "Presets")?.canonical == .reactive)

        for section in MusicRailSection.visibleCases {
            #expect(section.canonical == section)
        }

        #expect(MusicRailSection.mappings.musicPanelTab == .reactive)
        #expect(MusicRailSection.presets.musicPanelTab == .reactive)

        #expect(MusicPanelTab.mappings.canonical == .reactive)
        #expect(MusicPanelTab.presets.canonical == .reactive)
        #expect(MusicPanelTab.visualizations.canonical == .reactive)
        #expect(MusicPanelTab(rawValue: "Mappings")?.canonical == .reactive)
        #expect(MusicPanelTab(rawValue: "Presets")?.canonical == .reactive)
    }

    @Test("Legacy reactive pins canonicalize and deduplicate in stable order")
    func legacyPinsCanonicalizeAndDeduplicate() {
        #expect(PinnedRailControl.visualizationsReactive.canonical == .musicReactive)
        #expect(PinnedRailControl.musicMappings.canonical == .musicReactive)
        #expect(PinnedRailControl.musicPresets.canonical == .musicReactive)

        let canonical = PinnedRailControl.canonicalized([
            .musicMappings,
            .exploreJumpingOff,
            .musicReactive,
            .musicPresets,
            .visualizationsReactive,
            .musicPlayback,
            .exploreJumpingOff,
        ])

        #expect(canonical == [
            .musicReactive,
            .exploreJumpingOff,
            .musicPlayback,
        ])
    }
}
