//
//  TombstoneStore.swift
//  Threshold
//
//  Persisted local record of DELETIONS (presets and scenes). When the user
//  deletes an item we drop a tombstone here; the iCloud backup then propagates
//  that deletion to the cloud (and other devices) instead of the item silently
//  reappearing from another device's copy or the folder watcher.
//
//  Two shared stores mirror the two syncable item kinds:
//    • TombstoneStore.presets  — deleted FractalPresets
//    • TombstoneStore.scenes   — deleted user AnimationScenes
//
//  The pure reconcile/merge rules live in BackupMerge; this class is only the
//  on-disk @MainActor state around them. A tombstone is superseded ("resurrected")
//  by an item edited/created at or after its deletedAt — see BackupMerge.reconcile.
//

import Foundation
import Observation

@Observable
@MainActor
final class TombstoneStore {

    /// Shared store for deleted fractal presets.
    static let presets = TombstoneStore(fileName: "preset_tombstones.json")
    /// Shared store for deleted user animation scenes.
    static let scenes  = TombstoneStore(fileName: "scene_tombstones.json")

    private(set) var tombstones: [BackupTombstone] = []

    @ObservationIgnored private let fileName: String
    @ObservationIgnored private let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()
    @ObservationIgnored private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    init(fileName: String) {
        self.fileName = fileName
        load()
    }

    private var fileURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent(fileName)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        tombstones = (try? decoder.decode([BackupTombstone].self, from: data)) ?? []
    }

    private func save() {
        do {
            let data = try encoder.encode(tombstones)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("❌ Failed to save tombstones (\(fileName)): \(error)")
        }
    }

    /// Record (or refresh) a tombstone for `id` at `at` (defaults to now).
    /// A newer `deletedAt` overrides an older one for the same id.
    func record(_ id: UUID, at: Date = Date()) {
        tombstones = BackupMerge.mergeTombstones(tombstones, [BackupTombstone(id: id, deletedAt: at)])
        save()
    }

    /// Replace the whole set (after a reconcile with the cloud) and persist.
    func replaceAll(_ new: [BackupTombstone]) {
        tombstones = new
        save()
    }

    /// True if `id` is deleted as of `itemTimestamp` — a tombstone exists whose
    /// `deletedAt` is strictly newer than the item. Used by the folder watcher
    /// to avoid resurrecting a scene the user just deleted. (Strictly-newer ties
    /// go to the item, matching BackupMerge.reconcile.)
    func isDeleted(_ id: UUID, newerThan itemTimestamp: Date) -> Bool {
        guard let tomb = tombstones.first(where: { $0.id == id }) else { return false }
        return tomb.deletedAt > itemTimestamp
    }
}
