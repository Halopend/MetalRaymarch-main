//
//  LibrarySidebarTests.swift
//  ThresholdTests
//
//  Pins the folder-derived sidebar rows: "All" plus every category,
//  depth-first and indented, with counts that include descendants — the
//  structure that makes an added folder a selectable category
//  (see CONTENT_MODEL_PROPOSAL.md §2.8).
//

import Foundation
import Testing
@testable import Threshold

@Suite("Library sidebar — folder rows")
struct LibrarySidebarTests {

    // MARK: Fixtures

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibrarySidebarTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func teardown(_ root: URL) {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func plant(_ relativePath: String, in root: URL) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("{}".utf8).write(to: url)
        return url
    }

    // MARK: Rows

    @Test("An empty store yields just the All row")
    func emptyStoreYieldsAllRow() {
        let section = LibrarySidebarCatalog.section(kind: .scene, index: .empty)
        #expect(section.rows.count == 1)
        #expect(section.rows.first?.isAll == true)
        #expect(section.rows.first?.itemCount == 0)
        #expect(section.rows.first?.title == "All Scenes")
    }

    @Test("Categories are depth-first with increasing depth and descendant counts")
    func rowsAreDepthFirstWithCounts() throws {
        let root = try makeRoot()
        defer { teardown(root) }

        try plant("Scenes/Caverns/Ice Caves/Frozen.thresh", in: root)
        try plant("Scenes/Caverns/Damp.thresh", in: root)
        try plant("Scenes/Surface.thresh", in: root)
        try plant("Animations/Intro.threshanim", in: root)

        let index = LibraryIndex.scan(root: root)
        let section = LibrarySidebarCatalog.section(kind: .scene, index: index)

        #expect(section.rows.map(\.title) == ["All Scenes", "Caverns", "Ice Caves"])
        #expect(section.rows.map(\.depth) == [0, 0, 1])
        #expect(section.rows.map(\.itemCount) == [3, 2, 1], "counts include descendants")

        // The animation kind is a separate section, unaffected by scene folders.
        let animations = LibrarySidebarCatalog.section(kind: .animation, index: index)
        #expect(animations.rows.map(\.title) == ["All Animations"])
        #expect(animations.rows.first?.itemCount == 1)
    }

    @Test("An empty folder still becomes a row")
    func emptyFolderBecomesRow() throws {
        let root = try makeRoot()
        defer { teardown(root) }

        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Scenes/Empty Shelf", isDirectory: true),
            withIntermediateDirectories: true
        )

        let section = LibrarySidebarCatalog.section(kind: .scene, index: LibraryIndex.scan(root: root))
        #expect(section.rows.map(\.title) == ["All Scenes", "Empty Shelf"])
        #expect(section.rows.last?.itemCount == 0)
    }

    // MARK: Matching

    @Test("A category row matches its whole subtree; All matches the kind")
    func matching() throws {
        let root = try makeRoot()
        defer { teardown(root) }

        try plant("Scenes/Caverns/Ice Caves/Frozen.thresh", in: root)
        try plant("Scenes/Surface.thresh", in: root)
        try plant("Animations/Intro.threshanim", in: root)

        let index = LibraryIndex.scan(root: root)
        let frozen = try #require(index.items(.scene).first { $0.displayName == "Frozen" })
        let surface = try #require(index.items(.scene).first { $0.displayName == "Surface" })
        let intro = try #require(index.items(.animation).first)

        let allScenes: LibrarySidebarSelection = .all(.scene)
        let caverns: LibrarySidebarSelection = .category(.scene, path: ["Caverns"])
        let iceCaves: LibrarySidebarSelection = .category(.scene, path: ["Caverns", "Ice Caves"])

        #expect(LibrarySidebarCatalog.matches(frozen, selection: allScenes))
        #expect(LibrarySidebarCatalog.matches(surface, selection: allScenes))
        #expect(!LibrarySidebarCatalog.matches(intro, selection: allScenes), "kind is respected")

        #expect(LibrarySidebarCatalog.matches(frozen, selection: caverns), "subtree match")
        #expect(!LibrarySidebarCatalog.matches(surface, selection: caverns))
        #expect(LibrarySidebarCatalog.matches(frozen, selection: iceCaves))
    }
}
