import Testing
@testable import Threshold

@Suite("Input navigation taxonomy")
struct InputNavigationTests {

    @Test("Visible Input sections use the requested order and keep library subroutes routable")
    func visibleSections() {
        #expect(MusicRailSection.allCases == [
            .parameters, .reactive, .playback, .songs, .playlists, .albums
        ])
        #expect(MusicRailSection.visibleCases == [.parameters, .reactive, .playback])

        #expect(MusicRailSection.availableCases(for: .macOS) == MusicRailSection.visibleCases)
        #expect(MusicRailSection.availableCases(for: .iPadOS) == MusicRailSection.visibleCases)
        #expect(MusicRailSection.availableCases(for: .visionOS) == MusicRailSection.visibleCases)
        #expect(MusicRailSection.playback.title == "Sources")

        #expect(!MusicRailSection.allCases.contains(.mappings))
        #expect(!MusicRailSection.allCases.contains(.presets))
    }

    @Test("Legacy Input routes canonicalize to the combined Reactivity page")
    func legacyRoutesCanonicalize() {
        #expect(MusicRailSection.mappings.canonical == .reactive)
        #expect(MusicRailSection.presets.canonical == .reactive)
        #expect(MusicRailSection(rawValue: "Mappings")?.canonical == .reactive)
        #expect(MusicRailSection(rawValue: "Presets")?.canonical == .reactive)

        for section in MusicRailSection.allCases {
            #expect(section.canonical == section)
        }

    }

    @Test("Semantic route IDs canonicalize old Input pages")
    func semanticRouteIDsCanonicalize() {
        #expect(AppRoute.input(.mappings).stableID == AppRoute.input(.reactive).stableID)
        #expect(AppRoute.input(.presets).stableID == AppRoute.input(.reactive).stableID)
        #expect(AppRoute.look(.reactive).stableID != AppRoute.input(.reactive).stableID)
    }
}
