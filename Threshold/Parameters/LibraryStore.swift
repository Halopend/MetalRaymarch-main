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
    @ObservationIgnored private var scanGeneration: UInt64 = 0

    init(storage: StorageLocation = .shared) {
        self.storage = storage
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
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// The active store root this index reflects.
    var root: URL? { storage.activeRoot }

    /// Rescan off the main actor; a stale scan is discarded by generation.
    func reload() {
        guard let root = storage.activeRoot else {
            index = .empty
            return
        }
        scanGeneration &+= 1
        let generation = scanGeneration
        Task.detached(priority: .utility) { [weak self] in
            let scanned = LibraryIndex.scan(root: root)
            await self?.apply(scanned, generation: generation)
        }
    }

    /// Synchronous rescan — for tests and callers that need the snapshot now.
    func reloadNow() {
        guard let root = storage.activeRoot else {
            index = .empty
            return
        }
        scanGeneration &+= 1
        index = LibraryIndex.scan(root: root)
    }

    private func apply(_ scanned: LibraryIndex, generation: UInt64) {
        guard generation == scanGeneration else { return }
        index = scanned
    }
}
