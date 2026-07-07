//
//  BackupMerge.swift
//  Threshold
//
//  Pure, side-effect-free merge logic for the iCloud backup. Kept separate from
//  ICloudBackupManager (which does the file I/O + @MainActor state) so the merge
//  rules can be unit-tested in isolation — the part that, if wrong, silently
//  loses or clobbers a user's presets/scenes.
//

import Foundation

/// Records that an item (preset or scene) with `id` was DELETED at `deletedAt`.
/// Tombstones let a deletion propagate through the cloud instead of the deleted
/// item silently reappearing from another device's copy (or the folder watcher).
/// A tombstone is overridden — "resurrected" — only by an item edited/created at
/// or after `deletedAt` (same id), at which point the tombstone is dropped.
struct BackupTombstone: Codable, Identifiable, Equatable {
    let id: UUID
    var deletedAt: Date
}

enum BackupMerge {

    /// Result of `reconcile`: the surviving items plus the tombstones still in
    /// effect (deletions not yet superseded by a newer item, kept so they keep
    /// propagating to other devices until garbage-collected).
    struct Reconciled<Item> {
        var items: [Item]
        var tombstones: [BackupTombstone]
    }

    /// Union `local` and `cloud` by id, keeping the item with the NEWER timestamp.
    ///
    /// Neither side is authoritative: this never drops an id that exists on either
    /// side (that's the whole point — the old blind mirror could). Deletions are a
    /// separate concern handled via tombstones, not by absence from one side.
    ///
    /// Tie-break: on an EQUAL timestamp, `local` wins. That's the stable choice —
    /// it stops a round-trip through the cloud from clobbering an equal local copy,
    /// and keeps the operation idempotent (merging a converged pair is a no-op).
    ///
    /// - Parameters:
    ///   - local: items currently on this device.
    ///   - cloud: items read back from the cloud folder(s).
    ///   - timestamp: the per-item modification time (preset `updatedAt`, scene `modifiedAt`).
    /// - Returns: the merged set (unordered; callers sort as they display).
    static func newestWins<Item: Identifiable>(
        local: [Item],
        cloud: [Item],
        timestamp: (Item) -> Date
    ) -> [Item] where Item.ID == UUID {
        var byID: [UUID: Item] = [:]
        byID.reserveCapacity(local.count + cloud.count)

        // Seed with cloud, then let local overwrite unless cloud is STRICTLY newer.
        for item in cloud {
            byID[item.id] = item
        }
        for item in local {
            if let existing = byID[item.id], timestamp(existing) > timestamp(item) {
                continue  // cloud copy is strictly newer — keep it
            }
            byID[item.id] = item  // local is newer-or-equal — local wins (incl. ties)
        }
        return Array(byID.values)
    }

    /// Union of tombstones by id, keeping the NEWEST `deletedAt` (a re-delete after
    /// a resurrection wins). Ties keep either — the timestamp is what matters.
    static func mergeTombstones(_ a: [BackupTombstone], _ b: [BackupTombstone]) -> [BackupTombstone] {
        var byID: [UUID: BackupTombstone] = [:]
        for t in a + b where (byID[t.id]?.deletedAt ?? .distantPast) < t.deletedAt {
            byID[t.id] = t
        }
        return Array(byID.values)
    }

    /// Full reconcile: newest-wins union of items, unioned tombstones, then resolve
    /// each item against its tombstone.
    ///   • tombstone strictly newer than the item  → item stays DELETED (tombstone kept)
    ///   • item newer-or-equal to the tombstone     → item WINS, tombstone dropped (resurrected)
    /// Item-less tombstones are retained so the deletion keeps propagating.
    static func reconcile<Item: Identifiable>(
        local: [Item], cloud: [Item],
        localTombstones: [BackupTombstone], cloudTombstones: [BackupTombstone],
        timestamp: (Item) -> Date
    ) -> Reconciled<Item> where Item.ID == UUID {
        let items = newestWins(local: local, cloud: cloud, timestamp: timestamp)
        var tombByID: [UUID: BackupTombstone] = [:]
        for t in mergeTombstones(localTombstones, cloudTombstones) { tombByID[t.id] = t }

        var survivors: [Item] = []
        survivors.reserveCapacity(items.count)
        for item in items {
            if let tomb = tombByID[item.id] {
                if tomb.deletedAt > timestamp(item) {
                    continue                              // deleted after last edit → stays gone
                }
                tombByID.removeValue(forKey: item.id)     // item is newer → resurrect, drop tombstone
            }
            survivors.append(item)
        }
        return Reconciled(items: survivors, tombstones: Array(tombByID.values))
    }
}
