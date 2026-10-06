//
//  LibraryIndex.swift
//  Threshold
//
//  Filesystem-derived view of the content library: which kind-root each file
//  lives under, and the folder path beneath it. Folders are the taxonomy —
//  every directory below a kind root is a user category (see
//  CONTENT_MODEL_PROPOSAL.md §2.4).
//
//  This is a deliberately cheap, recursive, contents-free scan: it reads
//  directory entries only and never decodes a file, so an iCloud placeholder
//  costs exactly as much as a hydrated file. Decoded metadata (tags, traits,
//  embedded effects) stays with the per-kind managers; this type answers only
//  "what is here, and where does it live".
//

import Foundation

// MARK: - Kind

/// Broad content kind. Mirrors `ThresholdExportFormat.Category`, but stays a
/// standalone `Sendable` value the index can key dictionaries by.
enum LibraryItemKind: String, CaseIterable, Sendable {
    case scene
    case animation
    case effect

    /// Sidebar section title.
    var displayName: String {
        switch self {
        case .scene: return "Scenes"
        case .animation: return "Animations"
        case .effect: return "Effects"
        }
    }

    /// The folder that owns this kind, relative to the store root.
    var rootFolderName: String {
        switch self {
        case .scene: return StorageLocation.scenesSubdir
        case .animation: return StorageLocation.animationsSubdir
        case .effect: return StorageLocation.formulasSubdir
        }
    }

    /// Folders from earlier releases that still hold this kind. Files here are
    /// indexed too, and the folder name becomes their top-level category so
    /// they surface in the sidebar instead of vanishing.
    var legacyFolderNames: [String] {
        switch self {
        case .scene: return [StorageLocation.musicPresetsSubdir]
        case .animation: return []
        case .effect: return []
        }
    }

    /// Kind implied by a file format. Extension is authoritative.
    init?(format: ThresholdExportFormat) {
        switch format.category {
        case .preset: self = .scene
        case .animation: self = .animation
        case .formula: self = .effect
        }
    }
}

// MARK: - Item

/// One indexed file. Contents are deliberately not decoded here.
struct LibraryIndexItem: Identifiable, Equatable, Sendable {
    let url: URL
    let kind: LibraryItemKind
    let format: ThresholdExportFormat
    /// Folder components below the kind root. Empty means the root category.
    /// A file inside a legacy root is prefixed with that folder's name.
    let categoryPath: [String]

    var id: String { url.path }
    var fileName: String { url.lastPathComponent }
    var displayName: String { url.deletingPathExtension().lastPathComponent }

    /// Human-readable breadcrumb for the item's folder.
    var categoryLabel: String {
        categoryPath.isEmpty ? kind.displayName : categoryPath.joined(separator: " / ")
    }

    /// True when the file sits exactly in `categoryPath`.
    func isDirectlyIn(_ path: [String]) -> Bool { categoryPath == path }

    /// True when the file sits in `path` or any folder beneath it.
    func isUnder(_ path: [String]) -> Bool {
        path.isEmpty || categoryPath.starts(with: path)
    }
}

// MARK: - Category

/// A folder-derived category node. `path` is empty for the root category.
struct LibraryCategory: Identifiable, Equatable, Sendable {
    let path: [String]
    var children: [LibraryCategory]
    /// Number of indexed items in this folder and everything beneath it.
    var itemCount: Int

    var id: String { path.joined(separator: "/") }
    /// Leaf name; empty for the root (callers use the kind's display name).
    var name: String { path.last ?? "" }
    var depth: Int { path.count }
}

// MARK: - Index

/// Immutable snapshot of the library's folders and files, grouped by kind.
struct LibraryIndex: Equatable, Sendable {
    private(set) var itemsByKind: [LibraryItemKind: [LibraryIndexItem]]
    private(set) var categoriesByKind: [LibraryItemKind: [LibraryCategory]]

    static let empty = LibraryIndex(itemsByKind: [:], categoriesByKind: [:])

    init(itemsByKind: [LibraryItemKind: [LibraryIndexItem]],
         categoriesByKind: [LibraryItemKind: [LibraryCategory]]) {
        self.itemsByKind = itemsByKind
        self.categoriesByKind = categoriesByKind
    }

    func items(_ kind: LibraryItemKind) -> [LibraryIndexItem] { itemsByKind[kind] ?? [] }

    /// Top-level categories for a kind (the root category is implicit).
    func categories(_ kind: LibraryItemKind) -> [LibraryCategory] { categoriesByKind[kind] ?? [] }

    /// Items in `categoryPath` or any folder beneath it. An empty path means
    /// every item of that kind (the section root).
    func items(in kind: LibraryItemKind, categoryPath: [String]) -> [LibraryIndexItem] {
        items(kind).filter { $0.isUnder(categoryPath) }
    }

    /// Items sitting exactly in `categoryPath`, excluding subfolders.
    func itemsDirectly(in kind: LibraryItemKind, categoryPath: [String]) -> [LibraryIndexItem] {
        items(kind).filter { $0.isDirectlyIn(categoryPath) }
    }

    var totalItemCount: Int { itemsByKind.values.reduce(0) { $0 + $1.count } }
}

// MARK: - Scanning

extension LibraryIndex {

    /// Recursively indexes every kind root under `root`. Read-only and
    /// non-throwing: an unreadable or missing root is simply skipped.
    nonisolated static func scan(root: URL, fileManager: FileManager = .default) -> LibraryIndex {
        var state = WalkState()

        for kind in LibraryItemKind.allCases {
            guard !Task.isCancelled else { return .empty }
            let primary = root.appendingPathComponent(kind.rootFolderName, isDirectory: true)
            walk(directory: primary, prefix: [], scannedKind: kind,
                 fileManager: fileManager, state: &state)

            for legacyName in kind.legacyFolderNames {
                let legacy = root.appendingPathComponent(legacyName, isDirectory: true)
                walk(directory: legacy, prefix: [legacyName], scannedKind: kind,
                     fileManager: fileManager, state: &state)
            }
        }

        var categoriesByKind: [LibraryItemKind: [LibraryCategory]] = [:]
        for kind in LibraryItemKind.allCases {
            guard !Task.isCancelled else { return .empty }
            let kindItems = state.items[kind] ?? []
            var paths = state.directories[kind] ?? []
            for item in kindItems where !item.categoryPath.isEmpty {
                for end in 1...item.categoryPath.count {
                    paths.insert(Array(item.categoryPath.prefix(end)))
                }
            }
            categoriesByKind[kind] = makeTree(categoryPaths: paths,
                                              itemPaths: kindItems.map(\.categoryPath))
        }

        return LibraryIndex(itemsByKind: state.items, categoriesByKind: categoriesByKind)
    }

    /// Category path for a single file URL, without scanning the whole store.
    /// Returns nil when the URL is outside `root` or not under a known root.
    nonisolated static func categoryPath(for url: URL, root: URL) -> [String]? {
        let standardizedURL = url.standardizedFileURL
        let standardizedRoot = root.standardizedFileURL
        guard StorageLocation.contains(standardizedURL, in: standardizedRoot) else { return nil }

        let relative = standardizedURL.pathComponents
            .dropFirst(standardizedRoot.pathComponents.count)
        guard let first = relative.first else { return nil }
        let belowRoot = Array(relative.dropFirst().dropLast())

        for kind in LibraryItemKind.allCases {
            if first == kind.rootFolderName { return belowRoot }
            if kind.legacyFolderNames.contains(first) { return [first] + belowRoot }
        }
        return nil
    }

    // MARK: Internals

    private struct WalkState {
        var items: [LibraryItemKind: [LibraryIndexItem]] = [:]
        var directories: [LibraryItemKind: Set<[String]>] = [:]
    }

    private nonisolated static func walk(
        directory: URL,
        prefix: [String],
        scannedKind: LibraryItemKind,
        fileManager: FileManager,
        state: inout WalkState
    ) {
        guard !Task.isCancelled else { return }
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for url in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard !Task.isCancelled else { return }
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?
                .isDirectory ?? false

            if isDirectory {
                let path = prefix + [url.lastPathComponent]
                state.directories[scannedKind, default: []].insert(path)
                walk(directory: url, prefix: path, scannedKind: scannedKind,
                     fileManager: fileManager, state: &state)
                continue
            }

            // Extension is authoritative for kind, so a stray `.threshfx` in a
            // scene folder is still indexed as an effect rather than dropped.
            guard let format = ThresholdExportFormat(fileExtension: url.pathExtension),
                  let kind = LibraryItemKind(format: format) else { continue }
            state.items[kind, default: []].append(
                LibraryIndexItem(url: url, kind: kind, format: format, categoryPath: prefix)
            )
        }
    }

    /// Builds a nested category tree from the set of folders seen, annotating
    /// each node with how many items it covers (including descendants).
    private nonisolated static func makeTree(
        categoryPaths: Set<[String]>,
        itemPaths: [[String]]
    ) -> [LibraryCategory] {
        var childNamesByParent: [String: Set<String>] = [:]
        func key(_ path: [String]) -> String { path.joined(separator: "/") }

        for path in categoryPaths {
            for index in path.indices {
                let parent = Array(path.prefix(index))
                childNamesByParent[key(parent), default: []].insert(path[index])
            }
        }

        func makeNode(_ path: [String]) -> LibraryCategory {
            let names = childNamesByParent[key(path)] ?? []
            let children = names
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                .map { makeNode(path + [$0]) }
            let count = itemPaths.reduce(0) { partial, itemPath in
                partial + (path.isEmpty || itemPath.starts(with: path) ? 1 : 0)
            }
            return LibraryCategory(path: path, children: children, itemCount: count)
        }

        return (childNamesByParent[""] ?? [])
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { makeNode([$0]) }
    }
}
