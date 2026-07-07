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

enum BackupMerge {

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
}
