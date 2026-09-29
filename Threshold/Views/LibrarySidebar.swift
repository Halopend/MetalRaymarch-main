//
//  LibrarySidebar.swift
//  Threshold
//
//  Folder-derived navigation for the browse surface. The catalog is pure and
//  testable — it turns a `LibraryIndex` into rows; the view only renders them.
//

import Foundation

/// A selectable sidebar row.
enum LibrarySidebarSelection: Hashable, Sendable {
    /// The library root — every item of that kind.
    case all(LibraryItemKind)
    /// A folder-derived category.
    case category(LibraryItemKind, path: [String])
}

/// One row: an "All" row or a folder category.
struct LibrarySidebarRow: Identifiable, Hashable, Sendable {
    let selection: LibrarySidebarSelection
    let title: String
    let icon: String
    /// Nesting depth; 0 for "All" and top-level categories.
    let depth: Int
    /// Items in this row.
    let itemCount: Int?

    var id: LibrarySidebarSelection { selection }

    var isAll: Bool {
        if case .all = selection { return true }
        return false
    }

}

/// Every row for one content kind.
struct LibrarySidebarSection: Identifiable, Hashable, Sendable {
    let kind: LibraryItemKind
    let rows: [LibrarySidebarRow]

    var id: String { kind.rawValue }
}

enum LibrarySidebarCatalog {

    /// "All" plus every folder category for `kind`, depth-first and indented.
    static func section(kind: LibraryItemKind, index: LibraryIndex) -> LibrarySidebarSection {
        var rows: [LibrarySidebarRow] = [
            LibrarySidebarRow(
                selection: .all(kind),
                title: "All \(kind.displayName)",
                icon: "square.grid.2x2",
                depth: 0,
                itemCount: index.items(kind).count
            )
        ]
        append(index.categories(kind), kind: kind, depth: 0, into: &rows)
        return LibrarySidebarSection(kind: kind, rows: rows)
    }

    /// True when `item` belongs under a *library* selection. A category row
    /// matches its whole subtree, so picking "Caverns" also shows
    /// "Caverns/Ice Caves".
    static func matches(_ item: LibraryIndexItem, selection: LibrarySidebarSelection) -> Bool {
        switch selection {
        case .all(let kind):
            return item.kind == kind
        case .category(let kind, let path):
            return item.kind == kind && item.isUnder(path)
        }
    }

    private static func append(
        _ categories: [LibraryCategory],
        kind: LibraryItemKind,
        depth: Int,
        into rows: inout [LibrarySidebarRow]
    ) {
        for category in categories {
            rows.append(LibrarySidebarRow(
                selection: .category(kind, path: category.path),
                title: category.name,
                icon: "folder",
                depth: depth,
                itemCount: category.itemCount
            ))
            append(category.children, kind: kind, depth: depth + 1, into: &rows)
        }
    }
}
