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
}
