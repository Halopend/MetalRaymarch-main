//
//  FormulaLibraryStoreTests.swift
//  ThresholdTests
//
//  Exercises the Formulas/ library lifecycle against a temp directory via
//  StorageLocation.testRootOverride: save, overwrite-by-id, rename, duplicate,
//  delete, dedupe-by-shortHash, and corrupt-file resilience.
//

import Foundation
import Testing
@testable import Threshold

@MainActor
@Suite("Formula library store", .serialized)
struct FormulaLibraryStoreTests {

    private func makeStore() throws -> (FormulaLibraryStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FormulaLibraryStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let storage = StorageLocation()
        storage.testRootOverride = root
        return (FormulaLibraryStore(storage: storage), root)
    }

    private func makeFormula(id: String, name: String, radius: Float = 1.0) -> EmbeddedFormula {
        EmbeddedFormula(
            kind: .fractal,
            id: id,
            name: name,
            category: "Tests",
            author: "ThresholdTests",
            formulaDescription: "Library store fixture",
            functionStem: "LibraryFixture",
            metalSource: """
            // Radius \(radius) varies the sourceHash between fixtures.
            FORCE_INLINE float DE_LibraryFixture_Dist(float3 p, FormulaParams fp) {
                return length(p) - \(radius)f * fp.params[0];
            }
            FORCE_INLINE float2 DE_LibraryFixture(float3 p, FormulaParams fp) {
                return float2(DE_LibraryFixture_Dist(p, fp), 0.0f);
            }
            """,
            params: [FormulaParamDescriptor(index: 0, name: "Radius", default: 1.0,
                                            min: 0.1, max: 4.0, step: 0.01)],
            defaultIterations: 1,
            defaultColorIterations: 1,
            supportedEffectTagsRaw: []
        )
    }

    @Test("Save, reload, and read back a formula")
    func saveAndReload() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let formula = makeFormula(id: "user.test.save", name: "Sphere Thing")
        let entry = try store.save(formula)
        #expect(entry.formula.id == "user.test.save")
        #expect(entry.url.pathExtension == "threshfx")

        // A fresh store over the same root sees the file via the async
        // initial scan (init reloads off the main actor now).
        let storage = StorageLocation()
        storage.testRootOverride = root
        let reopened = FormulaLibraryStore(storage: storage)
        await reopened.waitForScan()
        #expect(reopened.entries.count == 1)
        #expect(reopened.entries[0].formula.name == "Sphere Thing")
    }

    @Test("Saving the same formula id overwrites its file instead of accumulating")
    func saveSameIDOverwrites() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try store.save(makeFormula(id: "user.test.same", name: "V One", radius: 1.0))
        _ = try store.save(makeFormula(id: "user.test.same", name: "V One", radius: 2.0))

        #expect(store.entries.count == 1)
        let files = try FileManager.default.contentsOfDirectory(
            at: StorageLocation.formulasDir(root), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "threshfx" }
        #expect(files.count == 1)
        // The surviving payload is the edited one.
        #expect(store.entries[0].formula.metalSource.contains("2.0f *") == true
                || store.entries[0].formula.metalSource.contains("Radius 2.0"))
    }

    @Test("Rename moves the file and keeps the payload")
    func rename() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let entry = try store.save(makeFormula(id: "user.test.rename", name: "Old Name"))
        try store.rename(entry, to: "New Name")

        #expect(store.entries.count == 1)
        #expect(store.entries[0].formula.name == "New Name")
        #expect(store.entries[0].url.lastPathComponent.contains("New_Name"))
        #expect(!FileManager.default.fileExists(atPath: entry.url.path))
    }

    @Test("Duplicate mints a fresh identity with a Copy suffix")
    func duplicate() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let original = try store.save(makeFormula(id: "user.test.dup", name: "Base"))
        let copy = try store.duplicate(original)

        #expect(store.entries.count == 2)
        #expect(copy.formula.id != original.formula.id)
        #expect(copy.formula.name == "Base Copy")
    }

    @Test("Delete removes the entry and its file")
    func delete() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let entry = try store.save(makeFormula(id: "user.test.delete", name: "Doomed"))
        try store.delete(entry)
        #expect(store.entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: entry.url.path))
    }

    @Test("Corrupt files are skipped and identical payloads dedupe by hash")
    func corruptAndDuplicateFiles() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let dir = StorageLocation.formulasDir(root)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // A corrupt file must not break loading.
        try Data("not json at all".utf8).write(to: dir.appendingPathComponent("garbage.threshfx"))

        // Two files with byte-identical payloads (same sourceHash) collapse to one entry.
        let formula = makeFormula(id: "user.test.dedupe", name: "Twin")
        let data = try EmbeddedFormulaContainer(formula: formula).encode()
        try data.write(to: dir.appendingPathComponent("twin-a.threshfx"))
        try data.write(to: dir.appendingPathComponent("twin-b.threshfx"))

        store.reloadNow()
        #expect(store.entries.count == 1)
        #expect(store.entries[0].formula.name == "Twin")
    }

    @Test("reload() applies asynchronously without decoding on the main actor")
    func reloadAppliesAsynchronously() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        // A file dropped on disk while the store exists shows up after the
        // detached rescan lands — no synchronous decode on the caller.
        let dir = StorageLocation.formulasDir(root)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try EmbeddedFormulaContainer(
            formula: makeFormula(id: "user.test.async", name: "Async Thing")
        ).encode()
        try data.write(to: dir.appendingPathComponent("async.threshfx"))

        store.reload()
        await store.waitForScan()
        #expect(store.entries.count == 1)
        #expect(store.entries[0].formula.id == "user.test.async")
    }

    @Test("Save before the initial scan applies still overwrites, not duplicates")
    func saveBeforeInitialScanAppliesOverwrites() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        // A same-id file already on disk, written while the store's initial
        // async scan may still be in flight.
        let dir = StorageLocation.formulasDir(root)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let preexisting = try EmbeddedFormulaContainer(
            formula: makeFormula(id: "user.test.race", name: "Race Thing")
        ).encode()
        try preexisting.write(to: dir.appendingPathComponent("race_thing.threshfx"))

        _ = try store.save(makeFormula(id: "user.test.race", name: "Race Thing", radius: 2.0))
        await store.waitForScan()

        let files = try FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "threshfx" }
        #expect(files.count == 1)
        #expect(store.entries.count == 1)
        // The surviving payload is the edited one.
        #expect(store.entries[0].formula.metalSource.contains("2.0f *") == true
                || store.entries[0].formula.metalSource.contains("Radius 2.0"))
    }
}
