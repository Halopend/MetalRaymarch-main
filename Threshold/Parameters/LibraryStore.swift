//
//  LibraryStore.swift
//  Threshold
//
//  Observable owner of the filesystem-derived `LibraryIndex`. Keeps one
//  up-to-date folder/category snapshot for the whole app and rescans off the
//  main actor, so an added folder becomes a category without blocking the UI
//  or decoding a single file (see LibraryIndex).
//

import Foundation
import Observation

@MainActor
@Observable
final class LibraryStore {

    /// Latest successful scan. `.empty` until the active root resolves.
    private(set) var index: LibraryIndex = .empty

    // Mirrors FormulaLibraryStore: only written once on MainActor and read in
    // deinit for removal, so no concurrent access is possible.
    @ObservationIgnored nonisolated(unsafe) private var observers: [any NSObjectProtocol] = []
    private let storage: StorageLocation
    private let rootProvider: @MainActor @Sendable () -> URL?
    private let scan: @Sendable (URL) async -> LibraryIndex
    @ObservationIgnored private var scanGeneration: UInt64 = 0
    @ObservationIgnored private(set) var scanTask: Task<Void, Never>?

    init(storage: StorageLocation = .shared,
         rootProvider: (@MainActor @Sendable () -> URL?)? = nil,
         scan: @escaping @Sendable (URL) async -> LibraryIndex = LibraryStore.scanOffMain) {
        self.storage = storage
        self.rootProvider = rootProvider ?? { storage.activeRoot }
        self.scan = scan
        reload()
        for name in [StorageLocation.rootResolvedNotification, StorageLocation.modeChangedNotification] {
            observers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.reload() }
            })
        }
    }

    deinit {
        scanTask?.cancel()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// The active store root this index reflects.
    var root: URL? { rootProvider() }

    /// Rescan off the main actor; a stale scan is discarded by generation.
    func reload() {
        scanGeneration &+= 1
        scanTask?.cancel()
        scanTask = nil
        guard let root = rootProvider() else {
            index = .empty
            return
        }
        let generation = scanGeneration
        let scan = self.scan
        scanTask = Task { [weak self] in
            // Coalesce storage notifications before starting filesystem work.
            do { try await Task.sleep(for: .milliseconds(100)) }
            catch { return }
            guard !Task.isCancelled else { return }
            let scanned = await scan(root)
            guard !Task.isCancelled else { return }
            self?.apply(scanned, generation: generation, root: root)
        }
    }

    /// Synchronous rescan — for tests and callers that need the snapshot now.
    func reloadNow() {
        scanGeneration &+= 1
        scanTask?.cancel()
        scanTask = nil
        guard let root = rootProvider() else {
            index = .empty
            return
        }
        index = LibraryIndex.scan(root: root)
    }

    nonisolated private static func scanOffMain(_ root: URL) async -> LibraryIndex {
        let worker = Task.detached(priority: .utility) { LibraryIndex.scan(root: root) }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private func apply(_ scanned: LibraryIndex, generation: UInt64, root: URL) {
        guard generation == scanGeneration, root == rootProvider() else { return }
        index = scanned
        scanTask = nil
    }
}
