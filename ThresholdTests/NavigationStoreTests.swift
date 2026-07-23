import Foundation
import Testing

@testable import Threshold

@MainActor
@Suite("Canonical navigation store")
struct NavigationStoreTests {
    private func isolatedDefaults() -> (UserDefaults, String) {
        let name = "NavigationStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return (defaults, name)
    }

    @Test("Reducer restores root history and utility return route")
    func rootHistoryAndReturnRoute() {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = NavigationStore(profile: .visionOS, defaults: defaults, allowsCustomScenes: true)

        store.select(.shape(.formula))
        store.select(.look(.motion))
        store.select(.quickToggles)
        #expect(store.currentRoute == .quickToggles)
        #expect(store.state.returnRoute == .look(.motion))

        store.dispatch(.returnToWorkspace)
        #expect(store.currentRoute == .look(.motion))

        store.selectRoot(.shape)
        #expect(store.currentRoute == .shape(.formula))
    }

    @Test("Pinning uses canonical route IDs and stable order")
    func canonicalPinning() {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(
            "musicMappings,exploreJumpingOff,musicReactive,musicPresets,visualizationsReactive,musicPlayback,exploreJumpingOff",
            forKey: "ContentView.pinnedRailControls"
        )

        let store = NavigationStore(profile: .visionOS, defaults: defaults, allowsCustomScenes: true)
        #expect(store.pinnedRouteIDs == [
            AppRoute.input(.reactive).stableID,
            AppRoute.explore(.jumpingOff).stableID,
            AppRoute.input(.playback).stableID
        ])
    }

    @Test("Legacy nested selection wins over dock state")
    func preciseLegacyRouteWins() {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("Performance", forKey: "ContentView.topDockTab")
        defaults.set("Fractal", forKey: "ContentView.selectedTab")
        defaults.set("Shape", forKey: "ContentView.fractalSubTab")
        defaults.set("Formula", forKey: "ContentView.shapeInnerTab")

        let store = NavigationStore(profile: .visionOS, defaults: defaults, allowsCustomScenes: true)
        #expect(store.currentRoute == .shape(.formula))
        #expect(defaults.data(forKey: NavigationStore.snapshotKey) != nil)
        #expect(defaults.object(forKey: "ContentView.selectedTab") == nil)
        #expect(defaults.object(forKey: "ContentView.topDockTab") == nil)
    }

    @Test("Every removed legacy route has a canonical destination", arguments: [
        ("Visualizations", VisualizationsRailSection.reactive.rawValue, AppRoute.input(.reactive)),
        ("Music", MusicRailSection.mappings.rawValue, AppRoute.input(.reactive)),
        ("Music", MusicRailSection.presets.rawValue, AppRoute.input(.reactive)),
        ("Shape", ShapeRailSection.performance.rawValue, AppRoute.quality(.tuning))
    ])
    func removedLegacyRoutes(
        tab: String,
        legacySection: String,
        expected: AppRoute
    ) {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(tab, forKey: "ContentView.topDockTab")
        switch tab {
        case "Visualizations":
            defaults.set(legacySection, forKey: "ContentView.visualizationsRailSection")
        case "Music":
            defaults.set(legacySection, forKey: "ContentView.musicRailSection")
        case "Shape":
            defaults.set(legacySection, forKey: "ContentView.shapeRailSection")
        default:
            break
        }

        let store = NavigationStore(profile: .visionOS, defaults: defaults, allowsCustomScenes: true)
        #expect(store.currentRoute == expected)
    }

    @Test("Unavailable routes fall back by injected platform profile")
    func unavailableRouteFallbacks() {
        let (macDefaults, macName) = isolatedDefaults()
        defer { macDefaults.removePersistentDomain(forName: macName) }
        let mac = NavigationStore(profile: .macOS, defaults: macDefaults, allowsCustomScenes: false)

        mac.select(.shape(.hands))
        #expect(mac.currentRoute == .shape(.parameters))
        mac.select(.input(.songs))
        #expect(mac.currentRoute == .input(.playback))
        mac.select(.explore(.customScenes))
        #expect(mac.currentRoute == .explore(.jumpingOff))
        mac.select(.gestures)
        #expect(mac.currentRoute == .settings(.display))

        let (visionDefaults, visionName) = isolatedDefaults()
        defer { visionDefaults.removePersistentDomain(forName: visionName) }
        let vision = NavigationStore(profile: .visionOS, defaults: visionDefaults, allowsCustomScenes: true)
        vision.select(.shape(.hands))
        #expect(vision.currentRoute == .shape(.hands))
    }

    @Test("Hierarchy and Finder targets reduce identically")
    func presentationSourceParity() {
        let hierarchy = NavigationHierarchy.application(availability: .resolve(
            profile: .visionOS,
            allowsCustomScenes: true,
            includesGestureEditing: true
        ))
        let expected = AppRoute.look(.mapping)
        let hierarchyTarget = hierarchy.node(withID: expected.stableID)!.target
        let finderTarget = ControlFinderDestination.catalog.first {
            $0.target.stableID == expected.stableID
        }!.target

        for target in [
            hierarchyTarget,
            finderTarget,
            .route(expected),                 // flat/radial/spatial presentation
            .command(.selectRoute(expected)), // App Intent / gesture command
        ] {
            let (defaults, name) = isolatedDefaults()
            let store = NavigationStore(profile: .visionOS, defaults: defaults, allowsCustomScenes: true)
            store.activate(target)
            #expect(store.currentRoute == expected)
            defaults.removePersistentDomain(forName: name)
        }
    }
}
