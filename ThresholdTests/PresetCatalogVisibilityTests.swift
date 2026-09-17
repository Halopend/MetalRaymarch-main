import Foundation
import Testing
@testable import Threshold

@Suite("Preset catalog platform visibility")
struct PresetCatalogVisibilityTests {
    private let environmentID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    private let ordinaryID = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
    private let userEnvironmentID = UUID(uuidString: "10000000-0000-0000-0000-000000000003")!

    @Test("Environment-capable catalogs preserve every scene and its order")
    func environmentCapableCatalogPreservesAllScenes() {
        let bundledEnvironment = makePreset(id: environmentID, name: "Bundled environment", environmentEnabled: true)
        let ordinary = makePreset(id: ordinaryID, name: "Ordinary")
        let userEnvironment = makePreset(id: userEnvironmentID, name: "User environment", environmentEnabled: true)
        let stored = [ordinary, bundledEnvironment, userEnvironment]

        let result = PresetManager.filterSceneCatalogPresets(
            stored,
            bundledPresets: [bundledEnvironment, ordinary],
            supportsEnvironmentReconstruction: true
        )

        #expect(result.map(\.id) == stored.map(\.id))
    }

    @Test("Unsupported catalogs hide only environment-dependent bundled identities")
    func unsupportedCatalogFiltersByBundledProvenance() {
        let bundledEnvironment = makePreset(id: environmentID, name: "Bundled environment", environmentEnabled: true)
        let ordinary = makePreset(id: ordinaryID, name: "Ordinary")
        let userEnvironment = makePreset(id: userEnvironmentID, name: "User environment", environmentEnabled: true)

        // Simulate an already-seeded bundled preset whose stored fields or name were edited.
        let editedSeededCopy = makePreset(id: environmentID, name: "Edited seeded copy")
        let stored = [ordinary, editedSeededCopy, userEnvironment]

        let result = PresetManager.filterSceneCatalogPresets(
            stored,
            bundledPresets: [bundledEnvironment, ordinary],
            supportsEnvironmentReconstruction: false
        )

        #expect(result.map(\.id) == [ordinaryID, userEnvironmentID])
    }

    @Test("Canonical scene state can classify a bundled environment scene")
    func canonicalEnvironmentFlagIsRecognized() {
        var bundledEnvironment = makePreset(id: environmentID, name: "Canonical environment")
        var sceneState = SceneState()
        sceneState.quality.envScrunchEnabled = true
        bundledEnvironment.sceneState = sceneState

        let result = PresetManager.filterSceneCatalogPresets(
            [bundledEnvironment],
            bundledPresets: [bundledEnvironment],
            supportsEnvironmentReconstruction: false
        )

        #expect(result.isEmpty)
    }

    @Test("Vision Pro catalogs exclude screen-only tagged scenes")
    func screenOnlyScenesAreExcludedFromVisionCatalog() {
        var screenOnly = makePreset(id: environmentID, name: "Overwhelming")
        screenOnly.tags = [SceneTagging.screenOnlyTag]
        let ordinary = makePreset(id: ordinaryID, name: "Ordinary")

        let visionResult = PresetManager.filterSceneCatalogPresets(
            [screenOnly, ordinary],
            bundledPresets: [],
            supportsEnvironmentReconstruction: true,
            includesScreenOnlyScenes: false
        )
        let screenResult = PresetManager.filterSceneCatalogPresets(
            [screenOnly, ordinary],
            bundledPresets: [],
            supportsEnvironmentReconstruction: true,
            includesScreenOnlyScenes: true
        )

        #expect(visionResult.map(\.id) == [ordinaryID])
        #expect(screenResult.map(\.id) == [environmentID, ordinaryID])
    }

    @Test("Mac-only bundled identities stay hidden from non-Mac catalogs")
    func macOnlyBundledScenesAreExcludedFromNonMacCatalogs() {
        var bundledMacOnly = makePreset(id: environmentID, name: "Mountain")
        bundledMacOnly.tags = [SceneTagging.macOnlyTag]
        // Simulate a copy seeded before the bundled scene gained its tag.
        let previouslySeededCopy = makePreset(id: environmentID, name: "Mountain")
        let ordinary = makePreset(id: ordinaryID, name: "Ordinary")

        let nonMacResult = PresetManager.filterSceneCatalogPresets(
            [previouslySeededCopy, ordinary],
            bundledPresets: [bundledMacOnly],
            supportsEnvironmentReconstruction: true,
            includesScreenOnlyScenes: true,
            includesMacOnlyScenes: false
        )
        let macResult = PresetManager.filterSceneCatalogPresets(
            [previouslySeededCopy, ordinary],
            bundledPresets: [bundledMacOnly],
            supportsEnvironmentReconstruction: true,
            includesScreenOnlyScenes: true,
            includesMacOnlyScenes: true
        )

        #expect(nonMacResult.map(\.id) == [ordinaryID])
        #expect(macResult.map(\.id) == [environmentID, ordinaryID])
    }

    @Test("Flat-display catalogs hide Mixed-reality scenes until opted in")
    func mixedRealityScenesAreHiddenUntilOptedIn() {
        var bundledMixed = makePreset(id: environmentID, name: "Passthrough float")
        bundledMixed.mixedModeScene = true
        // A user-authored copy whose scene file itself carries the Mixed mark.
        var userMixed = makePreset(id: userEnvironmentID, name: "User mixed")
        userMixed.mixedModeScene = true
        let ordinary = makePreset(id: ordinaryID, name: "Ordinary")

        let gatedResult = PresetManager.filterSceneCatalogPresets(
            [bundledMixed, userMixed, ordinary],
            bundledPresets: [bundledMixed],
            supportsEnvironmentReconstruction: true,
            includesMixedRealityScenes: false
        )
        let optedInResult = PresetManager.filterSceneCatalogPresets(
            [bundledMixed, userMixed, ordinary],
            bundledPresets: [bundledMixed],
            supportsEnvironmentReconstruction: true,
            includesMixedRealityScenes: true
        )

        #expect(gatedResult.map(\.id) == [ordinaryID])
        #expect(optedInResult.map(\.id) == [environmentID, userEnvironmentID, ordinaryID])
    }

    @Test("A stored copy seeded before its bundled source was marked Mixed is still classified")
    func seededMixedCopyIsClassifiedByBundledProvenance() {
        var bundledMixed = makePreset(id: environmentID, name: "Passthrough")
        bundledMixed.mixedModeScene = true
        var storedCopy = bundledMixed
        storedCopy.mixedModeScene = nil
        let ordinary = makePreset(id: ordinaryID, name: "Ordinary")

        let result = PresetManager.filterSceneCatalogPresets(
            [storedCopy, ordinary],
            bundledPresets: [bundledMixed],
            supportsEnvironmentReconstruction: true,
            includesMixedRealityScenes: false
        )

        #expect(result.map(\.id) == [ordinaryID])
    }

    private func makePreset(
        id: UUID,
        name: String,
        environmentEnabled: Bool = false
    ) -> FractalPreset {
        var preset = FractalPreset(id: id, name: name)
        preset.envScrunchEnabled = environmentEnabled
        return preset
    }
}
