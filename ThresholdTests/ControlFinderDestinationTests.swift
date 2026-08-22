import Testing
@testable import Threshold

@Suite("Control Finder destination catalog")
struct ControlFinderDestinationTests {
    @Test("Opening Look replaces a removed saved section with Color")
    func staleLookSectionFallsBackToColor() {
        #expect(VisualizationsRailSection.reactive.lookWorkspaceDestination == .color)
        #expect(VisualizationsRailSection.mapping.lookWorkspaceDestination == .mapping)
        #expect(VisualizationsRailSection.allCases.allSatisfy {
            $0.lookWorkspaceDestination == $0
        })
    }

    @Test("Catalog IDs are unique and every destination is routable")
    func uniqueRoutableDestinations() {
        let catalog = ControlFinderDestination.catalog
        #expect(catalog.count >= 32)
        #expect(Set(catalog.map(\.id)).count == catalog.count)
        #expect(catalog.allSatisfy { !$0.title.isEmpty && !$0.path.isEmpty && !$0.description.isEmpty })
        #expect(catalog.allSatisfy { !$0.target.stableID.isEmpty })
    }

    @Test("Catalog covers every current navigation section")
    func routeCoverage() {
        var explore = Set<String>()
        var shape = Set<String>()
        var visualizations = Set<String>()
        var performance = Set<String>()
        var music = Set<String>()
        var settings = Set<String>()
        var utilities = Set<String>()
        var hasAnimationEditor = false

        for destination in ControlFinderDestination.catalog {
            switch destination.target {
            case .route(.explore(let section)): explore.insert(section.rawValue)
            case .route(.shape(let section)): shape.insert(section.rawValue)
            case .route(.look(let section)): visualizations.insert(section.rawValue)
            case .route(.quality(let section)): performance.insert(section.rawValue)
            case .route(.input(let section)): music.insert(section.rawValue)
            case .route(.settings(let section)): settings.insert(section.rawValue)
            case .route(.gestures): utilities.insert("gestures")
            case .route(.quickToggles): utilities.insert("quickToggles")
            case .command(.openAnimationEditor): hasAnimationEditor = true
            case .workspace, .route, .command: break
            }
        }

        #expect(explore == Set(ExploreRailSection.allCases.map(\.rawValue)))
        #expect(shape == Set(ShapeRailSection.allCases.map(\.rawValue)))
        #expect(visualizations == Set(VisualizationsRailSection.allCases.map(\.rawValue)))
        #expect(performance == Set(PerformanceRailSection.allCases.map(\.rawValue)))
        #expect(music == Set(MusicRailSection.allCases.map(\.rawValue)))
        #expect(settings == Set(SettingsSubTab.visibleCases.map(\.rawValue)))
        #expect(utilities == ["gestures", "quickToggles"])
        #expect(hasAnimationEditor)
    }

    @Test("Platform filtering hides unsupported routes")
    func platformFiltering() {
        let mac = ControlFinderDestination.results(matching: "", on: .macOS)
        let iPad = ControlFinderDestination.results(matching: "", on: .iPadOS)
        let vision = ControlFinderDestination.results(matching: "", on: .visionOS)

        #expect(mac.count < iPad.count)
        #expect(iPad.count < vision.count)

        #expect(!mac.contains { $0.id == "input.Songs" })
        #expect(iPad.contains { $0.id == "input.Songs" })
        #expect(!iPad.contains { $0.id == "shape.Hands" })
        #expect(vision.contains { $0.id == "shape.Hands" })
        #expect(mac.contains { $0.id == "explore.Mixed" })
    }

    @Test("Search uses titles, descriptions, paths, and synonyms")
    func keywordSearch() {
        let fog = ControlFinderDestination.results(matching: "fog", on: .visionOS)
        #expect(fog.contains { $0.target == .route(.look(.atmosphere)) })

        let metrics = ControlFinderDestination.results(matching: "fps gpu", on: .macOS)
        #expect(metrics.first?.id == "quality.Tuning")

        let colour = ControlFinderDestination.results(matching: "colour", on: .iPadOS)
        #expect(colour.first?.id == "look.Color")

        let edge = ControlFinderDestination.results(matching: "edge outline", on: .macOS)
        #expect(edge.contains { $0.target == .route(.look(.grading)) })

        let custom = ControlFinderDestination.results(matching: "threshfx", on: .macOS)
        #expect(custom.first?.id == "explore.Custom Scenes")

        let mapping = ControlFinderDestination.results(matching: "audio mapping smoothing", on: .macOS)
        #expect(mapping.first?.id == "input.Reactive")

        let preset = ControlFinderDestination.results(matching: "reactivity preset", on: .macOS)
        #expect(preset.first?.id == "input.Reactive")
    }
}
