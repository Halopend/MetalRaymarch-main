//
//  BackupMerge.swift
//  Threshold
//
//  Pure, side-effect-free merge logic. Now used only when SWITCHING storage
//  locations (local ⇄ iCloud): the two folder stores are unioned newest-wins so
//  nothing is lost either direction. Kept separate from the managers' file I/O so
//  the rule — the part that, if wrong, silently loses or clobbers a user's
//  presets/scenes — can be unit-tested in isolation.
//
//  (The older tombstone-based reconcile was retired with the folder-as-source-of-
//  truth redesign: within a single store the folder is authoritative, and iCloud's
//  own file sync carries deletions between devices.)
//

import Foundation

enum BackupMerge {

    /// Union `local` and `cloud` by id, keeping the item with the NEWER timestamp.
    ///
    /// Never drops an id that exists on either side — that's the whole point when
    /// merging two stores on a mode switch. Tie-break: on an EQUAL timestamp
    /// `local` wins (stable + idempotent — merging a converged pair is a no-op).
    ///
    /// - Parameters:
    ///   - local: items from one store.
    ///   - cloud: items from the other store.
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
}
