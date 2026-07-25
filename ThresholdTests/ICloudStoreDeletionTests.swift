//
//  ICloudStoreDeletionTests.swift
//  ThresholdTests
//
//  Regression guard for the cross-device iCloud data-loss bug fixed in
//  "fix(icloud): stop routine edits from deleting other devices' scenes".
//
//  Under folder-as-truth the store folder (which may be the shared iCloud
//  Drive folder) is the source of truth. saveScenes()/replaceAll() used to
//  infer deletions by diffing that folder against the IN-MEMORY list — but
//  scanUserScenes()/scanStorePresets() skip not-yet-downloaded iCloud files,
//  so a scene another device just added (a dataless placeholder at reload,
//  materialized moments later) was absent from memory and got deleted on the
//  next routine edit, propagating the delete to every device.
//
//  These tests plant a store file the manager doesn't know about (standing in
//  for another device's item) and assert a routine edit / replace never
//  deletes it. They run against a temp root via StorageLocation.testRootOverride
//  so nothing touches the real app sandbox.
//

import Testing
import Foundation
@testable import Threshold

@MainActor
@Suite(.serialized)
struct ICloudStoreDeletionTests {

    @Test("Unknown File Provider status is hydrated without blocking on large placeholders")
    func unknownFileProviderStatusPolicy() {
        #expect(StorePlaceholderReadPolicy.requiresHydration(
            isUbiquitous: true,
            downloadStatus: nil
        ))
        #expect(!StorePlaceholderReadPolicy.requiresHydration(
            isUbiquitous: true,
            downloadStatus: .downloaded
        ))
        #expect(!StorePlaceholderReadPolicy.requiresHydration(
            isUbiquitous: true,
            downloadStatus: .current
        ))

        #expect(StorePlaceholderReadPolicy.canProbeUnknownStatus(
            downloadStatus: nil,
            fileSize: 32_000,
            allocatedSize: 0,
            maximumSize: 1_000_000
        ))
        #expect(!StorePlaceholderReadPolicy.canProbeUnknownStatus(
            downloadStatus: nil,
            fileSize: 32_000_000,
            allocatedSize: 0,
            maximumSize: 1_000_000
        ))
        #expect(StorePlaceholderReadPolicy.canProbeUnknownStatus(
            downloadStatus: nil,
            fileSize: 32_000_000,
            allocatedSize: 4_096,
            maximumSize: 1_000_000
        ))
        #expect(!StorePlaceholderReadPolicy.canProbeUnknownStatus(
            downloadStatus: .notDownloaded,
            fileSize: 32_000,
            allocatedSize: 0,
            maximumSize: 1_000_000
        ))
    }

    // MARK: - Harness

    /// Make a unique temp store root and point StorageLocation at it. The caller
    /// must `defer teardown(root)`.
    private func makeStoreRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThresholdStoreTest-\(UUID().uuidString)", isDirectory: true)
        StorageLocation.shared.ensureLayout(at: root)
        StorageLocation.shared.testRootOverride = root
        // Skip legacy-blob migration so the temp store starts clean and
        // deterministic regardless of the host machine's real Documents.
        UserDefaults.standard.set(true, forKey: "Scene.legacyMigrated")
        UserDefaults.standard.set(true, forKey: "Preset.legacyMigrated")
        return root
    }

    private func teardown(_ root: URL) {
        StorageLocation.shared.testRootOverride = nil
        try? FileManager.default.removeItem(at: root)
    }

    private var isoEncoder: JSONEncoder {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e
    }
    private var isoDecoder: JSONDecoder {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }

    /// Write a scene file directly into the store's Animations/ folder, standing
    /// in for a file another device synced in that this manager never loaded.
    private func plantScene(_ scene: AnimationScene, in root: URL) throws {
        let dir = StorageLocation.animationsDir(root)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("Planted_\(scene.id.uuidString.prefix(8)).threshanim")
        try isoEncoder.encode(scene).write(to: url)
    }

    /// True if some file under Animations/ decodes to a scene with `id`.
    private func sceneFileExists(id: UUID, in root: URL) -> Bool {
        let dir = StorageLocation.animationsDir(root)
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return false }
        for url in files where ["threshanim", "threshanimv"].contains(url.pathExtension) {
            if let data = try? Data(contentsOf: url),
               let s = try? isoDecoder.decode(AnimationScene.self, from: data),
               s.id == id {
                return true
            }
        }
        return false
    }

    private func plantPreset(_ preset: FractalPreset, in root: URL) throws {
        let dir = StorageLocation.scenesDir(root)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("Planted_\(preset.id.uuidString.prefix(8)).threshscene")
        try isoEncoder.encode(preset).write(to: url)
    }

    private func presetFileExists(id: UUID, in root: URL) -> Bool {
        for dir in [StorageLocation.scenesDir(root), StorageLocation.musicPresetsDir(root)] {
            guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for url in files where ["threshscene", "threshmp"].contains(url.pathExtension) {
                if let data = try? Data(contentsOf: url),
                   let p = try? isoDecoder.decode(FractalPreset.self, from: data),
                   p.id == id {
                    return true
                }
            }
        }
        return false
    }

    // MARK: - Scenes

    @Test("A routine scene edit does NOT delete an unknown store file (the bug)")
    func routineEditKeepsUnknownStoreFile() throws {
        let root = makeStoreRoot()
        defer { teardown(root) }

        let mgr = AnimationManager()
        let a = mgr.createScene(name: "A")            // this device's scene → written
        #expect(sceneFileExists(id: a.id, in: root))

        // Another device's scene lands in the shared folder; this manager never
        // loaded it (it isn't in userScenes).
        let foreign = AnimationScene(name: "FromOtherDevice")
        try plantScene(foreign, in: root)
        #expect(!mgr.userScenes.contains { $0.id == foreign.id })

        // A routine edit persists via saveScenes(). Pre-fix this pruned every
        // store file whose id wasn't in userScenes — deleting `foreign`.
        var edited = a
        edited.name = "A renamed"
        mgr.updateScene(edited)

        #expect(sceneFileExists(id: foreign.id, in: root),
                "routine edit must NOT delete another device's scene file")
        #expect(sceneFileExists(id: a.id, in: root))
    }

    @Test("replaceUserScenes removes only ids the app is dropping, not unknown files")
    func replaceUserScenesAttributedDeletion() throws {
        let root = makeStoreRoot()
        defer { teardown(root) }

        let mgr = AnimationManager()
        let a = mgr.createScene(name: "A")
        let c = mgr.createScene(name: "C")
        let foreign = AnimationScene(name: "FromOtherDevice")
        try plantScene(foreign, in: root)

        // Drop C (a known scene). A stays; C's file goes; the unknown planted
        // file is untouched because it was never in the in-memory set.
        mgr.replaceUserScenes(with: [a])

        #expect(sceneFileExists(id: a.id, in: root))
        #expect(!sceneFileExists(id: c.id, in: root), "an explicitly dropped scene's file is removed")
        #expect(sceneFileExists(id: foreign.id, in: root), "an unknown store file is never removed by a replace")
    }

    @Test("Deleting a scene removes its own file")
    func deleteSceneRemovesItsFile() throws {
        let root = makeStoreRoot()
        defer { teardown(root) }

        let mgr = AnimationManager()
        let a = mgr.createScene(name: "A")
        #expect(sceneFileExists(id: a.id, in: root))

        mgr.deleteScene(a)
        #expect(!sceneFileExists(id: a.id, in: root))
    }

    // MARK: - Presets

    @Test("A successful preset save reports durable storage")
    func presetSaveReportsSuccess() throws {
        let root = makeStoreRoot()
        try Data("[]".utf8).write(to: root.appendingPathComponent(".seeded-bundled.json"))
        defer { teardown(root) }

        let manager = PresetManager()
        let result = manager.savePreset(name: "Durable", settings: RenderSettings())

        #expect(result == .saved)
        let saved = try #require(manager.presets.first { $0.name == "Durable" })
        #expect(presetFileExists(id: saved.id, in: root))
    }

    @Test("A failed preset write is reported and does not leave a saved-looking ghost")
    func presetSaveFailureIsVisible() throws {
        let blocker = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThresholdStoreBlocker-\(UUID().uuidString)")
        try Data("not a directory".utf8).write(to: blocker)
        StorageLocation.shared.testRootOverride = blocker
        defer {
            StorageLocation.shared.testRootOverride = nil
            try? FileManager.default.removeItem(at: blocker)
        }

        let manager = PresetManager()
        let result = manager.savePreset(name: "Cannot Persist", settings: RenderSettings())

        guard case .failed(let detail) = result else {
            Issue.record("Expected a failed save, got \(result)")
            return
        }
        #expect(!detail.isEmpty)
        #expect(!manager.presets.contains { $0.name == "Cannot Persist" })
    }

    @Test("PresetManager.replaceAll drops only known ids, never an unknown store file")
    func presetReplaceAllAttributedDeletion() throws {
        let root = makeStoreRoot()
        // Mark the store already-seeded so init doesn't write bundled defaults —
        // keeps the store deterministic for id-specific assertions.
        try Data("[]".utf8).write(to: root.appendingPathComponent(".seeded-bundled.json"))
        defer { teardown(root) }

        let mgr = PresetManager()
        let keep = mgr.importPreset(FractalPreset(name: "Keep"))
        let drop = mgr.importPreset(FractalPreset(name: "Drop"))
        let foreign = FractalPreset(name: "FromOtherDevice")
        try plantPreset(foreign, in: root)

        // Replace with the set minus `drop`; `foreign` was never in memory.
        let remaining = mgr.presets.filter { $0.id != drop.id }
        mgr.replaceAll(with: remaining)

        #expect(presetFileExists(id: keep.id, in: root))
        #expect(!presetFileExists(id: drop.id, in: root), "an explicitly dropped preset's file is removed")
        #expect(presetFileExists(id: foreign.id, in: root), "an unknown store file is never removed by replaceAll")
    }
}
