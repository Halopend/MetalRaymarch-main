import Testing
@testable import Threshold

@Suite("Control Finder destination catalog")
struct ControlFinderDestinationTests {
    @Test("Opening Look replaces a removed saved section with Color")
    func staleLookSectionFallsBackToColor() {
        #expect(VisualizationsRailSection.reactive.lookWorkspaceDestination == .color)
        #expect(VisualizationsRailSection.mapping.lookWorkspaceDestination == .mapping)
        #expect(VisualizationsRailSection.visibleCases.allSatisfy {
            $0.lookWorkspaceDestination == $0
        })
    }

    @Test("Catalog IDs are unique and every destination is routable")
    func uniqueRoutableDestinations() {
        let catalog = ControlFinderDestination.catalog
        #expect(catalog.count == 31)
        #expect(Set(catalog.map(\.id)).count == catalog.count)
        #expect(catalog.allSatisfy { !$0.title.isEmpty && !$0.path.isEmpty && !$0.description.isEmpty })
        #expect(catalog.allSatisfy { $0.route != nil })
    }

    @Test("Catalog covers every current navigation section")
    func routeCoverage() {
        var explore = Set<String>()
        var shape = Set<String>()
        var visualizations = Set<String>()
        var performance = Set<String>()
        var music = Set<String>()
        var settings = Set<String>()
        var sidebar = Set<String>()
        var hasAnimationEditor = false

        for destination in ControlFinderDestination.catalog {
            switch destination.route {
            case .explore(let section): explore.insert(section.rawValue)
            case .shape(let section): shape.insert(section.rawValue)
            case .visualizations(let section): visualizations.insert(section.rawValue)
            case .performance(let section): performance.insert(section.rawValue)
            case .music(let section): music.insert(section.rawValue)
            case .settings(let section): settings.insert(section.rawValue)
            case .sidebar(let tab): sidebar.insert(tab.rawValue)
            case .animationEditor: hasAnimationEditor = true
            case nil: break
            }
        }

        #expect(explore == Set(ExploreRailSection.allCases.map(\.rawValue)))
        #expect(shape == Set(ShapeRailSection.allCases.filter { $0 != .performance }.map(\.rawValue)))
        #expect(visualizations == Set(VisualizationsRailSection.visibleCases.map(\.rawValue)))
        #expect(performance == Set(PerformanceRailSection.allCases.map(\.rawValue)))
        #expect(music == Set(MusicRailSection.visibleCases.map(\.rawValue)))
        #expect(settings == Set(SettingsSubTab.visibleCases.map(\.rawValue)))
        #expect(sidebar.contains(SidebarTab.gestures.rawValue))
        #expect(sidebar.contains(SidebarTab.quickToggles.rawValue))
        #expect(hasAnimationEditor)
    }

    @Test("Platform filtering hides unsupported routes")
    func platformFiltering() {
        let mac = ControlFinderDestination.results(matching: "", on: .macOS)
        let iPad = ControlFinderDestination.results(matching: "", on: .iOS)
        let vision = ControlFinderDestination.results(matching: "", on: .visionOS)

        #expect(mac.count == 26)
        #expect(iPad.count == 29)
        #expect(vision.count == 31)

        #expect(!mac.contains { $0.id == "music.Songs" })
        #expect(iPad.contains { $0.id == "music.Songs" })
        #expect(!iPad.contains { $0.id == "shape.Hands" })
        #expect(vision.contains { $0.id == "shape.Hands" })
        #expect(mac.contains { $0.id == "explore.Mixed" })
    }

    @Test("Search uses titles, descriptions, paths, and synonyms")
    func keywordSearch() {
        let fog = ControlFinderDestination.results(matching: "fog", on: .visionOS)
        #expect(fog.first?.id == "visualizations.Atmosphere")

        let metrics = ControlFinderDestination.results(matching: "fps gpu", on: .macOS)
        #expect(metrics.first?.id == "performance.Overview")

        let colour = ControlFinderDestination.results(matching: "colour", on: .iOS)
        #expect(colour.first?.id == "visualizations.Color")

        let edge = ControlFinderDestination.results(matching: "edge outline", on: .macOS)
        #expect(edge.first?.id == "visualizations.Grading")

        let custom = ControlFinderDestination.results(matching: "threshfx", on: .macOS)
        #expect(custom.first?.id == "explore.Custom Scenes")

        let mapping = ControlFinderDestination.results(matching: "audio mapping smoothing", on: .macOS)
        #expect(mapping.first?.id == "music.Reactive")

        let preset = ControlFinderDestination.results(matching: "reactivity preset", on: .macOS)
        #expect(preset.first?.id == "music.Reactive")
    }
}
