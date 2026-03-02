import Foundation

/// Loads and caches bundled flame collections from the app bundle.
/// Each `.flame` file may contain multiple `<flame>` elements (Apophysis format).
@MainActor
final class FlameLibrary: ObservableObject {
    static let shared = FlameLibrary()

    /// A single entry in the library: a named FlameDocument parsed from a bundled file.
    struct Entry: Identifiable {
        let id: String          // "filename:index"
        let flame: FlameDocument
        let sourceFile: String  // Bundle resource name
        let index: Int          // Position within that file
    }

    @Published private(set) var entries: [Entry] = []
    @Published private(set) var isLoaded = false

    private init() {}

    /// Load all bundled .flame files. Safe to call multiple times (no-op after first load).
    func loadIfNeeded() {
        guard !isLoaded else { return }
        isLoaded = true

        var allEntries: [Entry] = []
        let bundle = Bundle.main
        let extensions = ["flame", "flam3"]

        for ext in extensions {
            guard let urls = bundle.urls(forResourcesWithExtension: ext, subdirectory: nil) else { continue }
            for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let sourceName = url.deletingPathExtension().lastPathComponent
                do {
                    let data = try Data(contentsOf: url)
                    let parser = FlameXMLParser()
                    let flames = try parser.parseAll(data: data)
                    for (i, flame) in flames.enumerated() {
                        allEntries.append(Entry(
                            id: "\(sourceName):\(i)",
                            flame: flame,
                            sourceFile: sourceName,
                            index: i
                        ))
                    }
                } catch {
                    print("[FlameLibrary] Failed to parse \(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }

        entries = allEntries
        print("[FlameLibrary] Loaded \(entries.count) flames from \(extensions.count) extension types")
    }

    /// Returns the first flame in the library (the default).
    var defaultFlame: FlameDocument? {
        entries.first?.flame
    }

    /// Look up a flame by name (case-insensitive).
    func flame(named name: String) -> FlameDocument? {
        entries.first { $0.flame.name.lowercased() == name.lowercased() }?.flame
    }
}
