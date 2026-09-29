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

// MARK: - Picker provenance (library vs embedded)

/// Where an effect definition physically lives. Library effects are reusable
/// `.threshfx` files; embedded effects are private to the document carrying
/// them (see CONTENT_MODEL_PROPOSAL.md §2.7).
enum EffectProvenance: Equatable {
    case library(URL)
    case embedded

    var isLibrary: Bool {
        if case .library = self { return true }
        return false
    }
}

/// One row in the effects picker.
struct EffectPickerEntry: Identifiable, Equatable {
    let formula: EmbeddedFormula
    let provenance: EffectProvenance

    var id: String { formula.shortHash }
    var isLibrary: Bool { provenance.isLibrary }

    /// Caption telling the user where this effect comes from.
    var provenanceLabel: String {
        switch provenance {
        case .library: return "Library"
        case .embedded: return "Embedded"
        }
    }

    /// Library effects wear their kind's glyph; embedded ones wear a link, so a
    /// private non-reusable payload is unmistakable.
    var provenanceIcon: String {
        switch provenance {
        case .library: return formula.effectKind.icon
        case .embedded: return "link"
        }
    }
}

/// A kind-grouped block of picker entries.
struct EffectPickerSection: Identifiable, Equatable {
    let kind: EffectKind
    let entries: [EffectPickerEntry]

    var id: String { kind.rawValue }
    var title: String { kind.librarySectionTitle }
}

/// Builds the effects picker from **library files only**. Embedded payloads are
/// deliberately excluded from the reusable set: they belong to the single
/// document that carries them and must not be offered for another scene.
enum EffectPickerCatalog {

    /// Reusable rows: every library `.threshfx` file.
    static func libraryEntries(_ entries: [FormulaLibraryEntry]) -> [EffectPickerEntry] {
        entries.map { EffectPickerEntry(formula: $0.formula, provenance: .library($0.url)) }
    }

    /// Kinds present, in a stable display order, each with its entries sorted
    /// by name.
    static func sections(_ entries: [EffectPickerEntry]) -> [EffectPickerSection] {
        var byKind: [EffectKind: [EffectPickerEntry]] = [:]
        for entry in entries {
            byKind[entry.formula.effectKind, default: []].append(entry)
        }
        let orderedKinds = EffectKind.libraryOrder
            + byKind.keys.filter { !EffectKind.libraryOrder.contains($0) }
        return orderedKinds.compactMap { kind in
            guard let items = byKind[kind], !items.isEmpty else { return nil }
            return EffectPickerSection(
                kind: kind,
                entries: items.sorted {
                    $0.formula.name.localizedStandardCompare($1.formula.name) == .orderedAscending
                }
            )
        }
    }

    /// True when `hash` is NOT backed by a library file — i.e. the active effect
    /// was embedded in a scene and is not reusable elsewhere.
    static func isEmbeddedOnly(hash: String?, libraryHashes: Set<String>) -> Bool {
        guard let hash else { return false }
        return !libraryHashes.contains(hash)
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

    // Scan generation: bumped on every reload; a detached scan applies only
    // while its generation is still current, so a root change mid-scan can
    // never install a stale snapshot. `scanTask` lets tests await the flight.
    @ObservationIgnored private var scanGeneration: UInt64 = 0
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    /// True once any scan (sync or async) has applied. Guards the mutation
    /// fast path: before the first apply, `entries` is not yet disk truth, so
    /// `save` falls back to a synchronous rescan to locate overwrite targets.
    @ObservationIgnored private var initialScanApplied = false

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

    /// Rescan the library off the main actor. Directory I/O, iCloud hydration
    /// checks, reads, and JSON decoding all run detached; only the resulting
    /// `entries` assignment hops back to MainActor. Previously this decoded
    /// every `.threshfx` file synchronously at init and on every root/mode
    /// notification — a multi-second main-actor stall that hitched the render
    /// loop (and the music-reactive visuals) while the library was indexing.
    /// A stale scan is discarded by generation.
    func reload() {
        guard let dir = formulasDirectory else {
            scanGeneration &+= 1
            scanTask = nil
            initialScanApplied = true
            entries = []
            return
        }
        scanGeneration &+= 1
        let generation = scanGeneration
        scanTask = Task.detached(priority: .utility) { [weak self] in
            let scanned = Self.scanFormulaLibrary(directory: dir)
            await self?.apply(scanned, generation: generation)
        }
    }

    /// Synchronous rescan — for tests and callers that need the snapshot now.
    /// Same trade-off as `PresetManager.loadPresetsNow`: does the full decode
    /// on the calling actor, so reserve it for tooling and one-shot flows.
    func reloadNow() {
        scanGeneration &+= 1
        scanTask = nil
        guard let dir = formulasDirectory else {
            initialScanApplied = true
            entries = []
            return
        }
        entries = Self.scanFormulaLibrary(directory: dir)
        initialScanApplied = true
    }

    /// Awaits the most recently scheduled async scan (no-op when none is
    /// in flight) — deterministic hook for tests observing the detached path.
    func waitForScan() async {
        await scanTask?.value
    }

    private func apply(_ scanned: [FormulaLibraryEntry], generation: UInt64) {
        guard generation == scanGeneration else { return }
        entries = scanned
        initialScanApplied = true
    }

    /// Full scan of `dir`: enumerate `.threshfx` files, skip un-hydrated
    /// iCloud placeholders, decode, dedupe by formula id (newest modified
    /// wins), sort by name. Non-throwing: unreadable or corrupt files are
    /// skipped, never fatal. `nonisolated` so `reload` can run it detached.
    private nonisolated static func scanFormulaLibrary(directory dir: URL) -> [FormulaLibraryEntry] {
        let fm = FileManager.default
        // Recursive: every folder below Formulas/ is a user category.
        let urls = (fm.enumerator(at: dir, includingPropertiesForKeys: [
            .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
            .contentModificationDateKey
        ], options: [.skipsHiddenFiles, .skipsPackageDescendants])?
            .compactMap { $0 as? URL } ?? [])
            .filter { $0.pathExtension.lowercased() == "threshfx" }

        var bestByID: [String: (url: URL, modified: Date)] = [:]
        var loaded: [FormulaLibraryEntry] = []
        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            // iCloud placeholder policy (ported from PresetManager): reading an
            // un-hydrated placeholder synchronously materializes it — a
            // MainActor-blocked multi-second stall that also made the entry
            // "vanish" (so `save()` would then write a duplicate-id file).
            // Skip placeholders until the system hydrates them.
            let values = try? url.resourceValues(forKeys: [
                .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey
            ])
            if values?.isUbiquitousItem == true {
                let status = values?.ubiquitousItemDownloadingStatus
                guard status == .current || status == .downloaded else { continue }
            }
            guard let formula = (try? EmbeddedFormulaContainer.decode(fromContainerAt: url))?.formula else {
                continue
            }
            // One file per formula id — post-hydration duplicates (the same id
            // saved to a second file while a placeholder was skipped) keep the
            // NEWEST content instead of the alphabetically-first file.
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if let existing = bestByID[formula.id] {
                if existing.modified >= modified { continue }
                loaded.removeAll { $0.url == existing.url }
            }
            bestByID[formula.id] = (url, modified)
            loaded.append(FormulaLibraryEntry(url: url, formula: formula))
        }
        return loaded.sorted {
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
        // Until the first scan applies, `entries` is not disk truth, so fall
        // back to a synchronous rescan (first save after launch only — the
        // case where an async init scan is still in flight).
        if !initialScanApplied { reloadNow() }
        let existing = entries.first { $0.formula.id == formula.id }?.url
        let url = existing ?? uniqueURL(for: formula.name, in: dir)

        let data = try EmbeddedFormulaContainer(formula: formula).encode()
        try data.write(to: url, options: .atomic)
        upsert(FormulaLibraryEntry(url: url, formula: formula))
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
        if !initialScanApplied { reloadNow() } else {
            upsert(FormulaLibraryEntry(url: destination, formula: formula))
        }
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
        if !initialScanApplied { reloadNow(); return }
        entries.removeAll { $0.url == entry.url }
        // If a same-id duplicate file survives elsewhere (post-hydration
        // dupes), it must now surface as the id's representative — let the
        // off-main scan reconcile it instead of decoding synchronously.
        reload()
    }

    /// In-place entry update after a targeted write: one file per formula id,
    /// newest content wins — exactly what a full scan would conclude, without
    /// rescanning (and re-decoding) the whole library on the main actor.
    private func upsert(_ entry: FormulaLibraryEntry) {
        entries.removeAll { $0.formula.id == entry.formula.id || $0.url == entry.url }
        entries.append(entry)
        entries.sort { $0.formula.name.localizedCaseInsensitiveCompare($1.formula.name) == .orderedAscending }
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
