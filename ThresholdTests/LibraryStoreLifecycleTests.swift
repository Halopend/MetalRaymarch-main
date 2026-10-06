import Foundation
import Testing
@testable import Threshold

private actor LibraryScanGate {
    private var pending: [URL: CheckedContinuation<LibraryIndex, Never>] = [:]
    private var observers: [URL: CheckedContinuation<Void, Never>] = [:]

    func scan(_ root: URL) async -> LibraryIndex {
        await withCheckedContinuation { continuation in
            pending[root] = continuation
            observers.removeValue(forKey: root)?.resume()
        }
    }

    func waitForScan(_ root: URL) async {
        if pending[root] != nil { return }
        await withCheckedContinuation { observers[root] = $0 }
    }

    func finish(_ root: URL, with index: LibraryIndex) {
        pending.removeValue(forKey: root)?.resume(returning: index)
    }
}

@MainActor
private final class LibraryRootBox {
    var root: URL?
    init(_ root: URL?) { self.root = root }
}

@Suite("Library reload lifecycle")
@MainActor
struct LibraryStoreLifecycleTests {
    private func index() throws -> LibraryIndex {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Scenes"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("Scenes/test.threshscene"))
        return LibraryIndex.scan(root: root)
    }

    @Test("A scan cannot republish an old root after the root becomes unavailable")
    func nilRootInvalidatesScan() async throws {
        let root = URL(fileURLWithPath: "/tmp/library-a")
        let box = LibraryRootBox(root)
        let gate = LibraryScanGate()
        let store = LibraryStore(rootProvider: { box.root }, scan: { await gate.scan($0) })
        await gate.waitForScan(root)
        let oldTask = store.scanTask
        box.root = nil
        store.reload()
        await gate.finish(root, with: try index())
        await oldTask?.value
        #expect(store.index.totalItemCount == 0)
    }

    @Test("An old completion cannot overwrite the new root's result")
    func newRootWins() async throws {
        let a = URL(fileURLWithPath: "/tmp/library-a")
        let b = URL(fileURLWithPath: "/tmp/library-b")
        let box = LibraryRootBox(a)
        let gate = LibraryScanGate()
        let store = LibraryStore(rootProvider: { box.root }, scan: { await gate.scan($0) })
        await gate.waitForScan(a)
        let oldTask = store.scanTask
        box.root = b
        store.reload()
        await gate.waitForScan(b)
        let newTask = store.scanTask
        await gate.finish(b, with: try index())
        await newTask?.value
        await gate.finish(a, with: .empty)
        await oldTask?.value
        #expect(store.index.totalItemCount == 1)
    }

    @Test("A synchronous refresh invalidates an asynchronous scan")
    func synchronousRefreshWins() async throws {
        let root = URL(fileURLWithPath: "/tmp/library-a")
        let gate = LibraryScanGate()
        let store = LibraryStore(rootProvider: { root }, scan: { await gate.scan($0) })
        await gate.waitForScan(root)
        let oldTask = store.scanTask
        store.reloadNow()
        await gate.finish(root, with: try index())
        await oldTask?.value
        #expect(store.index.totalItemCount == 0)
    }
}
