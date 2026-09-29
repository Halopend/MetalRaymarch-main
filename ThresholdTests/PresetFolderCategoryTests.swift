//
//  PresetFolderCategoryTests.swift
//  ThresholdTests
//
//  Locks in the folder-as-category contract for the scene store:
//   * scenes in nested folders are scanned (recursive reads),
//   * their folder becomes their category path,
//   * the legacy Music Presets/ root surfaces as an ordinary category,
//   * and editing a scene saves it back into its own folder rather than
//     relocating it to the store root.
//
//  See CONTENT_MODEL_PROPOSAL.md §2.4.
//

import Foundation
import Testing
@testable import Threshold

@MainActor
@Suite(.serialized)
struct PresetFolderCategoryTests {

    // MARK: Harness

    private func makeStoreRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PresetFolderCategory-\(UUID().uuidString)", isDirectory: true)
        StorageLocation.shared.ensureLayout(at: root)
        StorageLocation.shared.testRootOverride = root
        UserDefaults.standard.set(true, forKey: "Scene.legacyMigrated")
        UserDefaults.standard.set(true, forKey: "Preset.legacyMigrated")
        return root
    }

    private func teardown(_ root: URL) {
        StorageLocation.shared.testRootOverride = nil
        try? FileManager.default.removeItem(at: root)
    }

    /// Mark the store as having already received every bundled preset, so the
    /// test sees only the files it plants.
    private func markSeeded(_ root: URL) throws {
        let ids = PresetManager.bundledPresetsForBenchmark().map(\.id)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(ids).write(
            to: root.appendingPathComponent(PresetManager.bundledCatalogMarkerFileName)
        )
        // Also suppress the targeted `w` scene migration marker.
        try Data("[]".utf8).write(
            to: root.appendingPathComponent(PresetManager.wSceneEdgeDetectionFixMarkerFileName)
        )
    }

    private var isoEncoder: JSONEncoder {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e
    }

    private var isoDecoder: JSONDecoder {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }

    @discardableResult
    private func plant(_ preset: FractalPreset, at relativePath: String, in root: URL) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try isoEncoder.encode(preset).write(to: url)
        return url
    }

    private func storedURLs(id: UUID, under root: URL) -> [URL] {
        let exts = ThresholdExportFormat.extensions(in: .preset)
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter { url in
            guard exts.contains(url.pathExtension),
                  let data = try? Data(contentsOf: url),
                  let preset = try? isoDecoder.decode(FractalPreset.self, from: data)
            else { return false }
            return preset.id == id
        }
    }

    // MARK: Tests

    @Test("Scenes in nested folders are scanned and carry their folder as a category")
    func nestedScenesAreScannedWithCategory() async throws {
        let root = makeStoreRoot()
        defer { teardown(root) }
        try markSeeded(root)

        let frozen = FractalPreset(name: "Frozen")
        try plant(frozen, at: "Scenes/Caverns/Ice Caves/Frozen.thresh", in: root)

        let manager = PresetManager()
        await manager.loadPresetsNow()

        #expect(manager.presets.contains { $0.id == frozen.id },
                "a scene nested two folders deep must still be loaded")
        #expect(manager.categoryPathsByPresetID[frozen.id] == ["Caverns", "Ice Caves"])
    }

    @Test("A scene directly in Scenes/ maps to the root category")
    func rootSceneHasEmptyCategory() async throws {
        let root = makeStoreRoot()
        defer { teardown(root) }
        try markSeeded(root)

        let surface = FractalPreset(name: "Surface")
        try plant(surface, at: "Scenes/Surface.threshscene", in: root)

        let manager = PresetManager()
        await manager.loadPresetsNow()

        #expect(manager.categoryPathsByPresetID[surface.id] == [])
    }

    @Test("The legacy Music Presets/ root surfaces as an ordinary category")
    func legacyMusicRootBecomesCategory() async throws {
        let root = makeStoreRoot()
        defer { teardown(root) }
        try markSeeded(root)

        let live = FractalPreset(name: "Live Set")
        try plant(live, at: "Music Presets/Deep/Live Set.threshmp", in: root)

        let manager = PresetManager()
        await manager.loadPresetsNow()

        #expect(manager.presets.contains { $0.id == live.id })
        #expect(manager.categoryPathsByPresetID[live.id] == ["Music Presets", "Deep"])
    }

    @Test("Editing a nested scene saves it back into its own folder")
    func editKeepsSceneInItsFolder() async throws {
        let root = makeStoreRoot()
        defer { teardown(root) }
        try markSeeded(root)

        var damp = FractalPreset(name: "Damp")
        try plant(damp, at: "Scenes/Caverns/Damp.thresh", in: root)

        let manager = PresetManager()
        await manager.loadPresetsNow()

        // Edit the scene the way a settings change would.
        damp.fractalScale += 0.5
        let result = manager.updatePreset(damp)
        guard case .saved = result else {
            Issue.record("updatePreset did not report a save: \(result)")
            return
        }

        // The prior file is removed asynchronously *after* the replacement is
        // safely on disk, so assert the invariant rather than an exact count:
        // every file for this id (old and new) must sit in Caverns, never in
        // the Scenes root.
        let urls = storedURLs(id: damp.id, under: root)
        #expect(!urls.isEmpty, "the edited scene must still have a store file")
        #expect(
            urls.allSatisfy { $0.deletingLastPathComponent().lastPathComponent == "Caverns" },
            "the edited scene must stay in its Caverns folder, not move to the root"
        )
        #expect(manager.categoryPathsByPresetID[damp.id] == ["Caverns"])
    }

    @Test("A saved scene records its folder category inside the file")
    func savedSceneRecordsCategoryPathHint() async throws {
        let root = makeStoreRoot()
        defer { teardown(root) }
        try markSeeded(root)

        var scene = FractalPreset(name: "Nested")
        try plant(scene, at: "Scenes/Caverns/Ice Caves/Nested.thresh", in: root)

        let manager = PresetManager()
        await manager.loadPresetsNow()

        scene.fractalScale += 1
        _ = manager.updatePreset(scene)

        // The original file (planted without a hint) may briefly coexist with
        // the replacement, so assert that the hint was written somewhere.
        let hints = storedURLs(id: scene.id, under: root).compactMap { url -> [String]? in
            (try? isoDecoder.decode(FractalPreset.self, from: Data(contentsOf: url)))?.categoryPath
        }
        #expect(hints.contains(["Caverns", "Ice Caves"]),
                "a saved scene should carry its folder path for sharing; got \(hints)")
    }
}
