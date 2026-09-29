//
//  LibraryIndexTests.swift
//  ThresholdTests
//
//  Pins the folder-as-taxonomy contract for the content library: every
//  directory below a kind root is a category, empty folders still appear,
//  legacy roots surface as ordinary categories, and only recognised
//  extensions are indexed (see CONTENT_MODEL_PROPOSAL.md §2.3–§2.4).
//

import Foundation
import Testing
@testable import Threshold

@Suite("Library index — folders are the taxonomy")
struct LibraryIndexTests {

    // MARK: Fixtures

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryIndexTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func teardown(_ root: URL) {
        try? FileManager.default.removeItem(at: root)
    }

    /// Creates an empty file at `relativePath` under `root`, making folders.
    @discardableResult
    private func plant(_ relativePath: String, in root: URL) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{}".utf8).write(to: url)
        return url
    }

    private func makeDirectory(_ relativePath: String, in root: URL) throws {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(relativePath, isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    // MARK: Extension recognition

    @Test("Canonical and legacy extensions are all indexed under their kind")
    func canonicalAndLegacyExtensionsIndex() throws {
        let root = try makeRoot()
        defer { teardown(root) }

        try plant("Scenes/canonical.thresh", in: root)
        try plant("Scenes/legacy.threshscene", in: root)
        try plant("Music Presets/music.threshmp", in: root)
        try plant("Animations/anim.threshanim", in: root)
        try plant("Animations/legacyanim.threshanimv", in: root)
        try plant("Formulas/effect.threshfx", in: root)

        let index = LibraryIndex.scan(root: root)

        #expect(index.items(.scene).count == 3)
        #expect(index.items(.animation).count == 2)
        #expect(index.items(.effect).count == 1)
        #expect(index.totalItemCount == 6)
    }

    @Test("Unrecognised extensions are ignored")
    func unknownExtensionsIgnored() throws {
        let root = try makeRoot()
        defer { teardown(root) }

        try plant("Scenes/notes.txt", in: root)
        try plant("Scenes/real.thresh", in: root)
        try plant("Scenes/backup.thresh.bak", in: root)

        let index = LibraryIndex.scan(root: root)
        #expect(index.items(.scene).map(\.fileName) == ["real.thresh"])
    }

    // MARK: Categories

    @Test("Nested folders become nested categories")
    func nestedFoldersBecomeCategories() throws {
        let root = try makeRoot()
        defer { teardown(root) }

        try plant("Scenes/Caverns/Ice Caves/Frozen.thresh", in: root)
        try plant("Scenes/Caverns/Damp.thresh", in: root)
        try plant("Scenes/Surface.thresh", in: root)

        let index = LibraryIndex.scan(root: root)
        let scenes = index.items(.scene)

        #expect(scenes.first { $0.displayName == "Frozen" }?.categoryPath == ["Caverns", "Ice Caves"])
        #expect(scenes.first { $0.displayName == "Damp" }?.categoryPath == ["Caverns"])
        #expect(scenes.first { $0.displayName == "Surface" }?.categoryPath == [])

        let top = index.categories(.scene)
        #expect(top.map(\.name) == ["Caverns"])
        #expect(top.first?.children.map(\.name) == ["Ice Caves"])
        // Caverns covers Damp + Frozen (recursive).
        #expect(top.first?.itemCount == 2)
        #expect(top.first?.children.first?.itemCount == 1)
    }

    @Test("An empty folder still appears as a category")
    func emptyFolderAppears() throws {
        let root = try makeRoot()
        defer { teardown(root) }

        try makeDirectory("Scenes/Empty Shelf", in: root)
        try plant("Scenes/Filled.thresh", in: root)

        let index = LibraryIndex.scan(root: root)
        let categories = index.categories(.scene)

        #expect(categories.map(\.name) == ["Empty Shelf"])
        #expect(categories.first?.itemCount == 0)
    }

    @Test("A legacy root becomes an ordinary top-level category")
    func legacyRootBecomesCategory() throws {
        let root = try makeRoot()
        defer { teardown(root) }

        try plant("Music Presets/Live Set.threshmp", in: root)
        try plant("Music Presets/Deep/One.threshmp", in: root)

        let index = LibraryIndex.scan(root: root)
        let scenes = index.items(.scene)

        #expect(scenes.first { $0.displayName == "Live Set" }?.categoryPath == ["Music Presets"])
        #expect(scenes.first { $0.displayName == "One" }?.categoryPath == ["Music Presets", "Deep"])
        #expect(index.categories(.scene).map(\.name) == ["Music Presets"])
    }

    @Test("A file whose extension disagrees with its root follows the extension")
    func extensionWinsOverRoot() throws {
        let root = try makeRoot()
        defer { teardown(root) }

        // A `.threshfx` dropped in Scenes/ is indexed as an effect, not lost.
        try plant("Scenes/Stray Effect.threshfx", in: root)

        let index = LibraryIndex.scan(root: root)
        #expect(index.items(.scene).isEmpty)
        #expect(index.items(.effect).map(\.displayName) == ["Stray Effect"])
    }

    // MARK: Filtering

    @Test("items(in:) includes descendants; itemsDirectly(in:) excludes them")
    func subtreeFiltering() throws {
        let root = try makeRoot()
        defer { teardown(root) }

        try plant("Scenes/Caverns/Damp.thresh", in: root)
        try plant("Scenes/Caverns/Ice Caves/Frozen.thresh", in: root)
        try plant("Scenes/Surface.thresh", in: root)

        let index = LibraryIndex.scan(root: root)

        #expect(index.items(in: .scene, categoryPath: []).count == 3)
        #expect(index.items(in: .scene, categoryPath: ["Caverns"]).count == 2)
        #expect(index.itemsDirectly(in: .scene, categoryPath: ["Caverns"]).count == 1)
        #expect(index.itemsDirectly(in: .scene, categoryPath: ["Caverns", "Ice Caves"]).count == 1)
    }

    // MARK: Single-file lookup

    @Test("categoryPath(for:root:) resolves a file without a full scan")
    func singleFileCategoryPath() throws {
        let root = try makeRoot()
        defer { teardown(root) }

        let direct = try plant("Scenes/Surface.thresh", in: root)
        let nested = try plant("Scenes/Caverns/Ice Caves/Frozen.thresh", in: root)
        let legacy = try plant("Music Presets/Deep/One.threshmp", in: root)
        let effect = try plant("Formulas/Mandelbox Variants/Box.threshfx", in: root)

        #expect(LibraryIndex.categoryPath(for: direct, root: root) == [])
        #expect(LibraryIndex.categoryPath(for: nested, root: root) == ["Caverns", "Ice Caves"])
        #expect(LibraryIndex.categoryPath(for: legacy, root: root) == ["Music Presets", "Deep"])
        #expect(LibraryIndex.categoryPath(for: effect, root: root) == ["Mandelbox Variants"])
    }

    @Test("categoryPath(for:root:) rejects files outside the store")
    func singleFileCategoryPathRejectsOutside() throws {
        let root = try makeRoot()
        defer { teardown(root) }

        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("outside-\(UUID().uuidString).thresh")
        #expect(LibraryIndex.categoryPath(for: outside, root: root) == nil)

        let unknownFolder = try plant("Elsewhere/Thing.thresh", in: root)
        #expect(LibraryIndex.categoryPath(for: unknownFolder, root: root) == nil)
    }

    @Test("A missing store root scans to an empty index")
    func missingRootIsEmpty() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString)", isDirectory: true)
        let index = LibraryIndex.scan(root: missing)
        #expect(index.totalItemCount == 0)
        #expect(index.categories(.scene).isEmpty)
    }
}
