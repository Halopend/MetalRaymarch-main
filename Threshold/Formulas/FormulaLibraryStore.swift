//
//  FormulaLibraryStore.swift
//  Threshold
//
//  User-authored custom formulas as standalone `.threshfx` files in the
//  store's Formulas/ subfolder — beside Scenes, Music Presets, and Animations
//  in both the local and iCloud roots, and browsable in Files.app. Before
//  this store existed, custom formulas were discoverable only by scanning
//  scene presets for embedded payloads; the live-code editor needs a real
//  create → save → rename → reload lifecycle.
//

import Foundation
import Observation

/// One saved formula file: the decoded payload plus the URL it came from.
struct FormulaLibraryEntry: Identifiable, Equatable {
    let url: URL
    let formula: EmbeddedFormula

    var id: String { url.path }

    static func == (lhs: FormulaLibraryEntry, rhs: FormulaLibraryEntry) -> Bool {
        lhs.url == rhs.url && lhs.formula.shortHash == rhs.formula.shortHash
    }
}

@MainActor
@Observable
final class FormulaLibraryStore {

    /// Library entries sorted by formula name, deduplicated by formula id
    /// (one file per formula identity — a duplicate with unchanged source is
    /// still a distinct library entry, unlike the shortHash dedupe used for
    /// scene-embedded discovery). Corrupt or non-decoding files are skipped,
    /// never fatal.
    private(set) var entries: [FormulaLibraryEntry] = []

    // nonisolated(unsafe): only written once during MainActor init and read
    // in deinit for removal — no concurrent access is possible.
    @ObservationIgnored nonisolated(unsafe) private var observers: [any NSObjectProtocol] = []
    private let storage: StorageLocation

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

    // MARK: - Paths

    private var formulasDirectory: URL? {
        storage.activeRoot.map(StorageLocation.formulasDir)
    }

    // MARK: - Loading

    func reload() {
        guard let dir = formulasDirectory else {
            entries = []
            return
        }
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension.lowercased() == "threshfx" } ?? []

        var seenIDs = Set<String>()
        var loaded: [FormulaLibraryEntry] = []
        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let formula = (try? EmbeddedFormulaContainer.decode(fromContainerAt: url))?.formula else {
                continue
            }
            guard seenIDs.insert(formula.id).inserted else { continue }
            loaded.append(FormulaLibraryEntry(url: url, formula: formula))
        }
        entries = loaded.sorted {
            $0.formula.name.localizedCaseInsensitiveCompare($1.formula.name) == .orderedAscending
        }
    }

    /// The library entry currently persisted for `shortHash`, if any.
    func entry(withHash shortHash: String) -> FormulaLibraryEntry? {
        entries.first { $0.formula.shortHash == shortHash }
    }

    // MARK: - Lifecycle

    /// Persist `formula` as a new library file (or overwrite the file already
    /// holding this formula id). Returns the saved entry.
    @discardableResult
    func save(_ formula: EmbeddedFormula) throws -> FormulaLibraryEntry {
        guard let dir = formulasDirectory else {
            throw CocoaError(.fileNoSuchFile)
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // One file per formula id: an in-place edit (same id, new source)
        // replaces its own file rather than accumulating stale versions.
        let existing = entries.first { $0.formula.id == formula.id }?.url
        let url = existing ?? uniqueURL(for: formula.name, in: dir)

        let data = try EmbeddedFormulaContainer(formula: formula).encode()
        try data.write(to: url, options: .atomic)
        reload()
        return entries.first { $0.formula.id == formula.id }
            ?? FormulaLibraryEntry(url: url, formula: formula)
    }

    /// Rename the entry's display name; the file moves to match.
    func rename(_ entry: FormulaLibraryEntry, to newName: String) throws {
        var formula = entry.formula
        formula.name = newName
        let dir = entry.url.deletingLastPathComponent()
        let destination = uniqueURL(for: newName, in: dir, excluding: entry.url)

        let data = try EmbeddedFormulaContainer(formula: formula).encode()
        try data.write(to: destination, options: .atomic)
        if destination != entry.url {
            try? FileManager.default.removeItem(at: entry.url)
        }
        reload()
    }

    /// Duplicate as a new formula identity (fresh id, " Copy" suffix).
    @discardableResult
    func duplicate(_ entry: FormulaLibraryEntry) throws -> FormulaLibraryEntry {
        var copy = entry.formula
        copy.id = "user.\(UUID().uuidString.lowercased())"
        copy.name = "\(entry.formula.name) Copy"
        return try save(copy)
    }

    func delete(_ entry: FormulaLibraryEntry) throws {
        try FileManager.default.removeItem(at: entry.url)
        reload()
    }

    // MARK: - Helpers

    private func uniqueURL(for name: String, in dir: URL, excluding: URL? = nil) -> URL {
        let stem = PresetManager.sanitizedExportFileNameStem(name)
        var candidate = dir.appendingPathComponent("\(stem).threshfx")
        var counter = 2
        while candidate != excluding, FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(stem)-\(counter).threshfx")
            counter += 1
        }
        return candidate
    }
}
