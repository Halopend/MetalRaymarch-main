import Testing
@testable import Threshold

@Suite("Input navigation taxonomy")
struct InputNavigationTests {

    @Test("Visible Input sections omit legacy split reactivity routes")
    func visibleSections() {
        #expect(MusicRailSection.visibleCases == [
            .playback, .reactive, .songs, .playlists, .albums
        ])

        #expect(MusicRailSection.availableCases(for: .macOS) == [.playback, .reactive])
        #expect(MusicRailSection.availableCases(for: .iPadOS) == MusicRailSection.visibleCases)
        #expect(MusicRailSection.availableCases(for: .visionOS) == MusicRailSection.visibleCases)

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

    @Test("Semantic route IDs canonicalize old Input pages")
    func semanticRouteIDsCanonicalize() {
        #expect(AppRoute.input(.mappings).stableID == AppRoute.input(.reactive).stableID)
        #expect(AppRoute.input(.presets).stableID == AppRoute.input(.reactive).stableID)
        #expect(AppRoute.look(.reactive).stableID != AppRoute.input(.reactive).stableID)
    }
}
