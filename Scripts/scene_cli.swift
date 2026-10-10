// Appended to the shared SceneFileCodec by scenes.sh; no app build required.
private enum CLIError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let message): return message }
    }
}

private func reportError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

private let usage = """
Usage: Scripts/scenes.sh compress FOLDER [--recursive] [--dry-run]

Compress scene files in place, preserving filenames and exact JSON contents.
Already compressed files are verified and skipped. Files that would grow stay JSON.
Supported: .thresh, .threshscene, .threshmp, .threshanim, .threshanimv
  --recursive   Include subfolders (hidden files and symlinks are skipped).
  --dry-run     Report conversions and savings without writing files.
  --help        Show this help.

Example: Scripts/scenes.sh compress "/path/to/Scenes" --recursive
"""

private func runSceneCLI() throws -> Int32 {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments.contains("--help") || arguments == ["help"] {
        print(usage)
        return 0
    }
    guard arguments.first == "compress" else { throw CLIError.message(usage) }
    let rest = arguments.dropFirst()
    let unknown = rest.filter { $0.hasPrefix("--") && !["--recursive", "--dry-run"].contains($0) }
    guard unknown.isEmpty else { throw CLIError.message("Unknown option: \(unknown.joined(separator: ", "))\n\(usage)") }
    let paths = rest.filter { !$0.hasPrefix("--") }
    guard paths.count == 1 else { throw CLIError.message(usage) }
    let root = URL(fileURLWithPath: NSString(string: paths[0]).expandingTildeInPath).standardizedFileURL
    let manager = FileManager.default
    var isDirectory: ObjCBool = false
    guard manager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
        throw CLIError.message("Folder does not exist: \(root.path)")
    }
    let recursive = arguments.contains("--recursive")
    let dryRun = arguments.contains("--dry-run")
    let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
    var traversalErrors: [String] = []
    let urls: [URL]
    if recursive {
        guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { url, error in
            traversalErrors.append("\(url.path): \(error.localizedDescription)")
            return true
        }) else { throw CLIError.message("Cannot read folder: \(root.path)") }
        urls = enumerator.allObjects.compactMap { $0 as? URL }
    } else {
        urls = try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
    }
    let extensions: Set<String> = ["thresh", "threshscene", "threshmp", "threshanim", "threshanimv"]
    var converted = 0, skipped = 0, failed = traversalErrors.count, savings = 0
    for error in traversalErrors { reportError("ERROR \(error)") }
    for url in urls.filter({ extensions.contains($0.pathExtension.lowercased()) }).sorted(by: { $0.path < $1.path }) {
        do {
            let resource = try url.resourceValues(forKeys: keys)
            guard resource.isRegularFile == true, resource.isSymbolicLink != true else { continue }
            guard (resource.fileSize ?? 0) <= SceneFileCodec.maximumJSONSize + 48 else {
                throw SceneFileCodec.FileError.tooLarge
            }
            let original = try Data(contentsOf: url)
            let json = try SceneFileCodec.jsonData(from: original)
            guard try JSONSerialization.jsonObject(with: json) is [String: Any] else {
                throw CLIError.message("Scene JSON must be an object.")
            }
            if SceneFileCodec.isCompressed(original) {
                skipped += 1
                print("SKIP already compressed: \(url.path)")
                continue
            }
            let compressed = try SceneFileCodec.compressJSON(json)
            guard compressed != original else {
                skipped += 1
                print("SKIP no size savings: \(url.path)")
                continue
            }
            guard try SceneFileCodec.jsonData(from: compressed) == original else {
                throw CLIError.message("Lossless verification failed; original preserved.")
            }
            if !dryRun {
                // Detect edits made while this command was preparing the conversion.
                guard try Data(contentsOf: url) == original else {
                    throw CLIError.message("File changed during conversion; original preserved.")
                }
                try compressed.write(to: url, options: .atomic)
            }
            converted += 1
            savings += original.count - compressed.count
            print("\(dryRun ? "WOULD COMPRESS" : "COMPRESSED") \(url.path): \(original.count) → \(compressed.count) bytes")
        } catch {
            failed += 1
            reportError("ERROR \(url.path): \(error.localizedDescription)")
        }
    }
    print("\(dryRun ? "Dry run: " : "")\(converted) \(dryRun ? "would compress" : "compressed"), \(skipped) skipped, \(failed) failed; \(savings) bytes \(dryRun ? "would be saved" : "saved").")
    return failed == 0 ? 0 : 1
}

do { exit(try runSceneCLI()) }
catch {
    reportError(error.localizedDescription)
    exit(2)
}
