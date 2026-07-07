//
//  BackupMergeTests.swift
//  ThresholdTests
//
//  Exhaustive tests for BackupMerge.newestWins — the iCloud merge rule. If this
//  is wrong the app silently loses or clobbers user presets/scenes, so cover the
//  add / edit / conflict / tie / disjoint / empty cases explicitly.
//

import Testing
import Foundation
@testable import Threshold

@Suite("BackupMerge.newestWins — id-keyed newest-wins union")
struct BackupMergeTests {

    private struct Item: Identifiable, Equatable {
        let id: UUID
        var tag: String     // which side / version this came from
        var ts: Date
    }

    private func merge(_ local: [Item], _ cloud: [Item]) -> [UUID: Item] {
        let merged = BackupMerge.newestWins(local: local, cloud: cloud, timestamp: { $0.ts })
        // No id should ever appear twice.
        #expect(merged.count == Set(merged.map(\.id)).count, "merge produced duplicate ids")
        return Dictionary(uniqueKeysWithValues: merged.map { ($0.id, $0) })
    }

    private func t(_ s: TimeInterval) -> Date { Date(timeIntervalSince1970: s) }

    @Test("Both empty -> empty")
    func bothEmpty() {
        #expect(BackupMerge.newestWins(local: [Item](), cloud: [Item](), timestamp: { $0.ts }).isEmpty)
    }

    @Test("Disjoint ids -> union of both (nothing dropped)")
    func disjointUnion() {
        let a = Item(id: UUID(), tag: "local", ts: t(1))
        let b = Item(id: UUID(), tag: "cloud", ts: t(1))
        let m = merge([a], [b])
        #expect(m.count == 2)
        #expect(m[a.id]?.tag == "local")
        #expect(m[b.id]?.tag == "cloud")
    }

    @Test("Local-only survives (restore must not drop un-backed-up presets)")
    func localOnlySurvives() {
        let a = Item(id: UUID(), tag: "local", ts: t(5))
        let m = merge([a], [])
        #expect(m[a.id]?.tag == "local")
    }

    @Test("Cloud-only survives (backup must not drop another device's presets)")
    func cloudOnlySurvives() {
        let a = Item(id: UUID(), tag: "cloud", ts: t(5))
        let m = merge([], [a])
        #expect(m[a.id]?.tag == "cloud")
    }

    @Test("Same id, local newer -> local wins")
    func localNewerWins() {
        let id = UUID()
        let m = merge([Item(id: id, tag: "local-new", ts: t(10))],
                      [Item(id: id, tag: "cloud-old", ts: t(5))])
        #expect(m.count == 1)
        #expect(m[id]?.tag == "local-new")
    }

    @Test("Same id, cloud newer -> cloud wins (no clobber of a newer remote edit)")
    func cloudNewerWins() {
        let id = UUID()
        let m = merge([Item(id: id, tag: "local-old", ts: t(5))],
                      [Item(id: id, tag: "cloud-new", ts: t(10))])
        #expect(m.count == 1)
        #expect(m[id]?.tag == "cloud-new")
    }

    @Test("Same id, equal timestamp -> local wins (stable, idempotent)")
    func tieGoesToLocal() {
        let id = UUID()
        let m = merge([Item(id: id, tag: "local", ts: t(7))],
                      [Item(id: id, tag: "cloud", ts: t(7))])
        #expect(m[id]?.tag == "local")
    }

    @Test("Idempotent: merging a converged pair returns the same set")
    func idempotent() {
        let items = [Item(id: UUID(), tag: "x", ts: t(1)), Item(id: UUID(), tag: "y", ts: t(2))]
        let once = BackupMerge.newestWins(local: items, cloud: items, timestamp: { $0.ts })
        #expect(Set(once.map(\.id)) == Set(items.map(\.id)))
        #expect(once.count == items.count)
    }

    @Test("Mixed batch: adds from both sides + per-id newest, in one pass")
    func mixedBatch() {
        let shared = UUID(), localOnly = UUID(), cloudOnly = UUID()
        let local = [
            Item(id: shared, tag: "local-new", ts: t(20)),   // newer than cloud's
            Item(id: localOnly, tag: "local-only", ts: t(3)),
        ]
        let cloud = [
            Item(id: shared, tag: "cloud-old", ts: t(10)),
            Item(id: cloudOnly, tag: "cloud-only", ts: t(3)),
        ]
        let m = merge(local, cloud)
        #expect(m.count == 3)
        #expect(m[shared]?.tag == "local-new")
        #expect(m[localOnly]?.tag == "local-only")
        #expect(m[cloudOnly]?.tag == "cloud-only")
    }

    // MARK: - Tombstone reconcile

    private func tomb(_ id: UUID, _ at: Date) -> BackupTombstone {
        BackupTombstone(id: id, deletedAt: at)
    }

    private func reconcile(_ local: [Item], _ cloud: [Item],
                           lt: [BackupTombstone] = [], ct: [BackupTombstone] = [])
    -> BackupMerge.Reconciled<Item> {
        let r = BackupMerge.reconcile(local: local, cloud: cloud,
                                      localTombstones: lt, cloudTombstones: ct,
                                      timestamp: { $0.ts })
        #expect(r.items.count == Set(r.items.map(\.id)).count, "reconcile produced duplicate item ids")
        #expect(r.tombstones.count == Set(r.tombstones.map(\.id)).count, "duplicate tombstone ids")
        return r
    }

    @Test("No tombstones -> items survive, no tombstones emitted")
    func reconcileNoTombstones() {
        let a = Item(id: UUID(), tag: "a", ts: t(1))
        let r = reconcile([a], [])
        #expect(r.items.map(\.id) == [a.id])
        #expect(r.tombstones.isEmpty)
    }

    @Test("Tombstone strictly newer than item -> item deleted, tombstone kept")
    func tombstoneDeletes() {
        let id = UUID()
        let r = reconcile([Item(id: id, tag: "a", ts: t(5))], [], lt: [tomb(id, t(10))])
        #expect(r.items.isEmpty)
        #expect(r.tombstones.map(\.id) == [id])
    }

    @Test("Item newer than tombstone -> resurrected, tombstone dropped")
    func itemResurrects() {
        let id = UUID()
        let r = reconcile([Item(id: id, tag: "a", ts: t(20))], [], lt: [tomb(id, t(10))])
        #expect(r.items.map(\.id) == [id])
        #expect(r.tombstones.isEmpty)
    }

    @Test("Tie (deletedAt == item ts) -> item wins (no loss on ambiguity)")
    func tombstoneTieItemWins() {
        let id = UUID()
        let r = reconcile([Item(id: id, tag: "a", ts: t(7))], [], lt: [tomb(id, t(7))])
        #expect(r.items.map(\.id) == [id])
        #expect(r.tombstones.isEmpty)
    }

    @Test("Item-less tombstone is retained (keeps propagating to other devices)")
    func itemlessTombstoneRetained() {
        let id = UUID()
        let r = reconcile([], [], lt: [tomb(id, t(3))])
        #expect(r.items.isEmpty)
        #expect(r.tombstones.map(\.id) == [id])
    }

    @Test("Cross-device delete: local still has the item, cloud tombstone newer -> deleted")
    func crossDeviceDelete() {
        let id = UUID()
        let r = reconcile([Item(id: id, tag: "local", ts: t(5))], [], ct: [tomb(id, t(9))])
        #expect(r.items.isEmpty)
        #expect(r.tombstones.map(\.id) == [id])
    }

    @Test("mergeTombstones: union by id, newest deletedAt wins")
    func mergeTombstonesNewest() {
        let id = UUID(), other = UUID()
        let merged = BackupMerge.mergeTombstones([tomb(id, t(5)), tomb(other, t(1))], [tomb(id, t(9))])
        let byID = Dictionary(uniqueKeysWithValues: merged.map { ($0.id, $0) })
        #expect(merged.count == 2)
        #expect(byID[id]?.deletedAt == t(9))
        #expect(byID[other]?.deletedAt == t(1))
    }
}
