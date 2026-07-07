//
//  PresetManager.swift
//  MetalProject
//
//  Created on January 11, 2026.
//

import SwiftUI
import Foundation

/// Single source of truth for Threshold's shareable file formats. The export
/// writers (PresetManager, AnimationManager, EmbeddedFormulaContainer) and the
/// export-tab format reference both read from here; the UTType declarations in
/// the platform Info.plists must mirror these extensions.
enum ThresholdExportFormat: CaseIterable, Sendable {
    case scenePreset
    case musicPreset
    case animationScene
    case musicVideoScene
    case customFormula

    /// Filename extension without the leading dot.
    var ext: String {
        switch self {
        case .scenePreset: return "threshscene"
        case .musicPreset: return "threshmp"
        case .animationScene: return "threshanim"
        case .musicVideoScene: return "threshanimv"
        case .customFormula: return "threshfx"
        }
    }

    /// One-line description shown in the export tab's format reference.
    var summary: String {
        switch self {
        case .scenePreset: return "Fractal preset (settings snapshot)"
        case .musicPreset: return "Music-reactive preset (audio mappings)"
        case .animationScene: return "Animation scene (keyframe sequence)"
        case .musicVideoScene: return "Animation + music (music video)"
        case .customFormula: return "Custom formula (standalone shader)"
        }
    }

    // MARK: - Routing

    /// Broad kind used to route imports and group extensions by payload.
    enum Category { case preset, animation, formula }

    var category: Category {
        switch self {
        case .scenePreset, .musicPreset: return .preset
        case .animationScene, .musicVideoScene: return .animation
        case .customFormula: return .formula
        }
    }

    /// Resolve a format from a filename extension (leading dot optional, any case).
    /// Returns nil for anything Threshold doesn't recognise.
    init?(fileExtension: String) {
        var e = fileExtension.lowercased()
        if e.hasPrefix(".") { e.removeFirst() }
        guard let match = Self.allCases.first(where: { $0.ext == e }) else { return nil }
        self = match
    }

    /// The preset format for a preset, chosen by whether it carries music mappings:
    /// `.threshmp` when music-reactive, `.threshscene` otherwise.
    static func preset(hasMusic: Bool) -> ThresholdExportFormat { hasMusic ? .musicPreset : .scenePreset }

    /// The animation format, chosen by whether the scene has an attached song:
    /// `.threshanimv` when it does, `.threshanim` otherwise.
    static func animation(hasSong: Bool) -> ThresholdExportFormat { hasSong ? .musicVideoScene : .animationScene }

    /// Every extension belonging to a category — for directory scans, prune, and decode.
    static func extensions(in category: Category) -> [String] {
        allCases.filter { $0.category == category }.map(\.ext)
    }

    // MARK: - Presentation (import sheet / preset list)

    /// Human-facing name for the format.
    var displayName: String {
        switch self {
        case .scenePreset:     return "Fractal Scene"
        case .musicPreset:     return "Music Preset"
        case .animationScene:  return "Animation"
        case .musicVideoScene: return "Music Video Animation"
        case .customFormula:   return "Custom Formula"
        }
    }

    /// SF Symbol representing the format.
    var iconName: String {
        switch self {
        case .scenePreset:     return "cube.transparent"
        case .musicPreset:     return "music.note.list"
        case .animationScene:  return "film.stack"
        case .musicVideoScene: return "music.note.tv"
        case .customFormula:   return "function"
        }
    }

    /// Accent colour used when presenting the format.
    var accentColor: Color {
        switch self {
        case .scenePreset, .customFormula:       return .purple
        case .musicPreset:                       return .blue
        case .animationScene, .musicVideoScene:  return .green
        }
    }
}

/// Runs an export (JSON encode + temp-file write, tens of ms for large
/// presets) off the main actor and delivers the URL back on it for sheet
/// presentation — keeps the tap animation from hitching.
func exportOffMain(_ produce: @escaping @Sendable () -> URL?,
                   onReady: @escaping @MainActor (URL) -> Void) {
    Task.detached(priority: .userInitiated) {
        guard let url = produce() else { return }
        await onReady(url)
    }
}

/// Manages saving and loading of presets
@MainActor
@Observable
class PresetManager {
    private(set) var presets: [FractalPreset] = []
    private static var bundledPresetsCache: [FractalPreset]?
    private let maxBackupCount: Int? = nil  // nil = unlimited retention
    private var pendingSaveTask: Task<Void, Never>?
    private let saveDebounceNanoseconds: UInt64 = 250_000_000
    private var lastBackupAt: Date?
    private let backupInterval: TimeInterval = 30
    @ObservationIgnored private let presetDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
    @ObservationIgnored private let presetEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]  // browseable store files
        return encoder
    }()
    /// Observers that reload the store when the active root resolves or the mode changes.
    /// `nonisolated(unsafe)` so the nonisolated deinit can unregister them; the only
    /// deinit access is removal, and NotificationCenter is thread-safe.
    @ObservationIgnored nonisolated(unsafe) private var storageObservers: [NSObjectProtocol] = []

    /// Live iCloud folder watcher (reflects external adds/deletes without relaunch).
    @ObservationIgnored private var iCloudQuery: NSMetadataQuery?
    @ObservationIgnored nonisolated(unsafe) private var iCloudQueryObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var watchedPresetDirs: [URL] = []
    private static let backupTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated static func sanitizedExportFileNameStem(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:\n\r")
        let cleaned = name.components(separatedBy: invalid).joined()
            .replacingOccurrences(of: " ", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "._- "))
        return cleaned.isEmpty ? "Untitled" : String(cleaned.prefix(64))
    }
    
    /// URL for the presets directory in the app's documents
    private var presetsDirectory: URL {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let presetsPath = documentsPath.appendingPathComponent("FractalPresets", isDirectory: true)
        
        // Create directory if it doesn't exist
        if !FileManager.default.fileExists(atPath: presetsPath.path) {
            try? FileManager.default.createDirectory(at: presetsPath, withIntermediateDirectories: true)
        }
        
        return presetsPath
    }
    
    /// Legacy single-blob store (pre-folder). Migration SOURCE only.
    private var legacyPresetsFileURL: URL {
        presetsDirectory.appendingPathComponent("presets.json")
    }

    // MARK: - Folder store (source of truth)

    /// Active store root for the current mode (nil while iCloud is resolving).
    private var storeRoot: URL? { StorageLocation.shared.activeRoot }

    /// Directory for timestamped safety backups. Always local, independent of the
    /// active store mode — a recovery net, never the source of truth.
    private var backupsDirectory: URL {
        let dir = StorageLocation.shared.backupsRoot.appendingPathComponent("Presets", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Build `Sanitized_Name_<short-id>.<ext>` so a rename can't collide with
    /// another item sharing the same display name.
    private nonisolated static func sanitizedFileName(_ name: String, id: UUID, ext: String) -> String {
        "\(sanitizedExportFileNameStem(name))_\(id.uuidString.prefix(8)).\(ext)"
    }

    init() {
        loadPresets()
        // The folder store is the source of truth: reload whenever the active root
        // resolves (iCloud discovery finishes) or the user switches storage mode,
        // so files added/removed in the folder mirror into the app.
        for name in [StorageLocation.rootResolvedNotification, StorageLocation.modeChangedNotification] {
            let observer = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.loadPresets() }
            }
            storageObservers.append(observer)
        }
    }

    deinit {
        storageObservers.forEach { NotificationCenter.default.removeObserver($0) }
        iCloudQueryObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: - Live iCloud watcher

    /// Watch the iCloud Scenes/ + Music Presets/ folders for external changes and
    /// reload on any add/update/remove. Idempotent for the same dirs.
    func startWatchingiCloudPresets(scenesDir: URL, musicDir: URL) {
        let dirs = [scenesDir, musicDir]
        guard watchedPresetDirs != dirs else { return }
        stopWatchingiCloudPresets()
        watchedPresetDirs = dirs
        loadPresets()   // immediate pass for files already present

        let query = NSMetadataQuery()
        query.searchScopes = dirs
        query.predicate = NSPredicate(format: "%K ENDSWITH '.threshscene' OR %K ENDSWITH '.threshmp'",
                                      NSMetadataItemFSNameKey, NSMetadataItemFSNameKey)
        query.operationQueue = .main
        let reload: @Sendable (Notification) -> Void = { [weak self] _ in
            Task { @MainActor in self?.loadPresets() }
        }
        let o1 = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main, using: reload)
        let o2 = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidUpdate, object: query, queue: .main, using: reload)
        iCloudQueryObservers = [o1, o2]
        query.start()
        iCloudQuery = query
        print("☁️ Watching iCloud preset folders for changes")
    }

    func stopWatchingiCloudPresets() {
        iCloudQuery?.stop()
        iCloudQuery = nil
        iCloudQueryObservers.forEach { NotificationCenter.default.removeObserver($0) }
        iCloudQueryObservers.removeAll()
        watchedPresetDirs = []
    }

    private static func bundledPresets(forceRefresh: Bool = false) -> [FractalPreset] {
        if forceRefresh || bundledPresetsCache == nil {
            bundledPresetsCache = loadBundledPresets()
        }
        return bundledPresetsCache ?? []
    }

    // MARK: - Folder store: scan / migrate / seed

    /// Decode every preset file under the store's Scenes/ + Music Presets/ folders.
    private func scanStorePresets(root: URL) -> [FractalPreset] {
        let exts = ThresholdExportFormat.extensions(in: .preset)
        var byID: [UUID: FractalPreset] = [:]
        for dir in [StorageLocation.scenesDir(root), StorageLocation.musicPresetsDir(root)] {
            guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for url in files where exts.contains(url.pathExtension) {
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
                guard let data = try? Data(contentsOf: url),
                      let preset = try? presetDecoder.decode(FractalPreset.self, from: data) else { continue }
                byID[preset.id] = preset
            }
        }
        return Array(byID.values)
    }

    /// Legacy single-blob presets (migration source), or nil if none.
    private func loadLegacyPresetsBlob() -> [FractalPreset]? {
        guard FileManager.default.fileExists(atPath: legacyPresetsFileURL.path),
              let data = try? Data(contentsOf: legacyPresetsFileURL),
              let arr = try? presetDecoder.decode([FractalPreset].self, from: data) else { return nil }
        return arr
    }

    /// One-time-per-store setup: migrate the legacy blob into per-file layout, and
    /// seed bundled defaults exactly once per store.
    ///
    /// Seeding is gated on the marker file's EXISTENCE, not its contents. The store
    /// lives in iCloud, where the marker can be an un-downloaded placeholder whose
    /// read fails; if we treated a failed read as "never seeded" we'd re-write every
    /// bundled default and RESURRECT any default the user deleted (the store's files
    /// are the source of truth). Existence survives the placeholder, so once seeded
    /// we never seed again and a deleted default stays deleted.
    private func migrateAndSeedIfNeeded(root: URL) {
        let marker = root.appendingPathComponent(".seeded-bundled.json")
        try? FileManager.default.startDownloadingUbiquitousItem(at: marker)
        let alreadySeeded = FileManager.default.fileExists(atPath: marker.path)

        var present = Set(scanStorePresets(root: root).map(\.id))

        // Legacy migration runs once, globally (the blob only exists in the old
        // sandbox location and migrates into whichever store is first active).
        let legacyMigratedKey = "Preset.legacyMigrated"
        if !UserDefaults.standard.bool(forKey: legacyMigratedKey) {
            if let legacy = loadLegacyPresetsBlob() {
                for preset in legacy where !present.contains(preset.id) {
                    writePresetFile(preset, root: root); present.insert(preset.id)
                }
                print("📦 Migrated \(legacy.count) preset(s) from legacy presets.json")
            }
            UserDefaults.standard.set(true, forKey: legacyMigratedKey)
        }

        // Seed bundled defaults ONCE per store. `!present` keeps any migrated/edited
        // copy; the marker then locks seeding off forever for this store. (A brand
        // new bundled preset in a future build won't auto-seed into an already-seeded
        // store — the correct trade for never resurrecting a user deletion.)
        guard !alreadySeeded else { return }
        for preset in Self.bundledPresets() where !present.contains(preset.id) {
            writePresetFile(preset, root: root)
        }
        let seededIDs = Self.bundledPresets().map(\.id)
        if let data = try? presetEncoder.encode(seededIDs) {
            try? data.write(to: marker, options: .atomic)
        }
        print("🌱 Seeded \(seededIDs.count) bundled preset(s) into store")
    }

    // MARK: - Folder store: per-file write / remove

    /// Write one preset as its own file, routed by music-reactivity
    /// (.threshmp → Music Presets/, .threshscene → Scenes/). Removes any prior
    /// file for the same id first, so a rename or a music-reactivity change can't
    /// leave an orphan copy.
    private func writePresetFile(_ preset: FractalPreset, root: URL) {
        let hasMusic = preset.hasMusicReactiveMappings
        let dir = hasMusic ? StorageLocation.musicPresetsDir(root) : StorageLocation.scenesDir(root)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        removePresetFiles(id: preset.id, root: root)
        let ext = ThresholdExportFormat.preset(hasMusic: hasMusic).ext
        let url = dir.appendingPathComponent(Self.sanitizedFileName(preset.name, id: preset.id, ext: ext))
        do {
            let data = try presetEncoder.encode(preset)
            try data.write(to: url, options: .atomic)
        } catch {
            print("Failed to write preset file: \(error)")
        }
    }

    /// Delete every store file (both folders) whose decoded id matches `id`.
    private func removePresetFiles(id: UUID, root: URL) {
        let exts = ThresholdExportFormat.extensions(in: .preset)
        for dir in [StorageLocation.scenesDir(root), StorageLocation.musicPresetsDir(root)] {
            guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for url in files where exts.contains(url.pathExtension) {
                if let data = try? Data(contentsOf: url),
                   let preset = try? presetDecoder.decode(FractalPreset.self, from: data), preset.id == id {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
    }

    /// Persist a single preset to the store (no-op until the root resolves).
    private func persist(_ preset: FractalPreset) {
        guard let root = storeRoot else { return }
        writePresetFile(preset, root: root)
    }

    /// Load all presets from the active store folder (the source of truth).
    /// Migrates + seeds on first use of a store, then mirrors its files.
    func loadPresets(forceRefreshBundled: Bool = false) {
        if forceRefreshBundled { _ = Self.bundledPresets(forceRefresh: true) }
        guard let root = storeRoot else {
            // iCloud chosen but not resolved yet — stay empty; reload on rootResolved.
            presets = []
            return
        }
        StorageLocation.shared.ensureLayout(at: root)
        migrateAndSeedIfNeeded(root: root)
        presets = scanStorePresets(root: root).sorted { $0.createdAt > $1.createdAt }
        FractalPreset.clearThumbnailCache()
    }

    /// Bundled defaults are seeded once per store; there's nothing to "re-merge"
    /// anymore, so this just reloads the folder (picking up any external changes).
    func refreshBundledPresets() {
        _ = Self.bundledPresets(forceRefresh: true)
        loadPresets()
    }
    
    /// Snapshot the CURRENT preset set as one timestamped backup blob — the safety
    /// net. Debounced so a burst of edits produces a single snapshot.
    private func scheduleBackup() {
        pendingSaveTask?.cancel()
        pendingSaveTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: self.saveDebounceNanoseconds)
            guard !Task.isCancelled else { return }
            self.snapshotBackup()
        }
    }

    private func snapshotBackup() {
        guard !presets.isEmpty else { return }
        if let data = try? presetEncoder.encode(presets) { writeBackup(data: data) }
    }

    /// Force an immediate timestamped backup of the CURRENT presets, bypassing
    /// the throttle. Call this before any destructive replace so data is always
    /// recoverable from the Backups folder.
    func backupCurrentPresetsNow() {
        guard !presets.isEmpty else { return }
        lastBackupAt = nil // defeat the throttle for this safety snapshot
        snapshotBackup()
    }

    /// Replace all presets and mirror the array into the store folder: write each
    /// preset's file, and remove store files whose id is no longer present.
    func replaceAll(with newPresets: [FractalPreset]) {
        presets = newPresets
        if let root = storeRoot {
            let keep = Set(newPresets.map(\.id))
            for id in scanStorePresets(root: root).map(\.id) where !keep.contains(id) {
                removePresetFiles(id: id, root: root)
            }
            for preset in newPresets { writePresetFile(preset, root: root) }
        }
        scheduleBackup()
    }

    /// Write a timestamped backup. Retention is currently unlimited:
    /// `maxBackupCount` is nil, so `pruneBackups` never removes old backups.
    private func writeBackup(data: Data) {
        let now = Date()
        if let lastBackupAt, now.timeIntervalSince(lastBackupAt) < backupInterval {
            return
        }
        self.lastBackupAt = now

        let stamp = Self.backupTimestampFormatter.string(from: now)
        let backupURL = backupsDirectory.appendingPathComponent("presets-\(stamp).json")
        do {
            try data.write(to: backupURL)
            if let limit = maxBackupCount {
                pruneBackups(keeping: limit)
            }
        } catch {
            print("Failed to write presets backup: \(error)")
        }
    }

    /// Keep only the newest N backups to avoid unbounded growth
    private func pruneBackups(keeping count: Int) {
        do {
            let files = try FileManager.default.contentsOfDirectory(at: backupsDirectory, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles)
            let sorted = files.sorted { (a, b) -> Bool in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da > db
            }
            for url in sorted.dropFirst(count) {
                try? FileManager.default.removeItem(at: url)
            }
        } catch {
            print("Failed to prune backups: \(error)")
        }
    }
    
    /// Save current settings as a new preset
    func savePreset(name: String, settings: RenderSettings, thumbnailData: Data? = nil, embeddedFormula: EmbeddedFormula? = nil) {
        let preset = FractalPreset.fromSettings(settings, name: name, thumbnailData: thumbnailData, embeddedFormula: embeddedFormula)
        presets.insert(preset, at: 0) // Add to beginning (newest first)
        persist(preset)
        scheduleBackup()

        // Track for analytics with full preset data
        UsageAnalytics.shared.trackPresetSaved(preset: preset)
    }

    /// Delete a preset. Removing its file IS the deletion — under folder-as-truth
    /// that removal is what propagates (iCloud syncs the delete to other devices).
    func deletePreset(_ preset: FractalPreset) {
        presets.removeAll { $0.id == preset.id }
        FractalPreset.clearThumbnailCache(for: preset.id)
        if let root = storeRoot { removePresetFiles(id: preset.id, root: root) }
        scheduleBackup()
    }

    /// Delete preset at index
    func deletePreset(at offsets: IndexSet) {
        let removed = offsets.compactMap { index in
            presets.indices.contains(index) ? presets[index] : nil
        }
        presets.remove(atOffsets: offsets)
        for preset in removed {
            FractalPreset.clearThumbnailCache(for: preset.id)
            if let root = storeRoot { removePresetFiles(id: preset.id, root: root) }
        }
        scheduleBackup()
    }
    
    /// Load a preset's settings
    func loadPreset(_ preset: FractalPreset,
                    into settings: RenderSettings,
                    includePerformance: Bool = true,
                    resetEnvironment: Bool = false) {
        preset.apply(to: settings,
                     includePerformance: includePerformance,
                     resetEnvironment: resetEnvironment)
        // Track for analytics
        UsageAnalytics.shared.trackPresetLoaded(name: preset.name)
    }
    
    /// Export a preset to a file URL.
    /// Uses `.threshmp` for presets with music-reactive mappings, `.threshscene` otherwise.
    /// Nonisolated: encoding + the temp-file write can take tens of ms for
    /// large presets — call it off the main actor (see `exportOffMain`).
    nonisolated static func exportPresetFile(_ preset: FractalPreset) -> URL? {
        let hasMusicMappings = preset.hasMusicReactiveMappings
        let format: ThresholdExportFormat = hasMusicMappings ? .musicPreset : .scenePreset
        let fileName = "\(Self.sanitizedExportFileNameStem(preset.name)).\(format.ext)"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(preset)
            try data.write(to: tempURL)
            return tempURL
        } catch {
            print("Failed to export preset: \(error)")
            return nil
        }
    }

    func decodePreset(from url: URL) throws -> FractalPreset {
        let data = try Data(contentsOf: url)
        return try presetDecoder.decode(FractalPreset.self, from: data)
    }

    @discardableResult
    func importPreset(_ preset: FractalPreset) -> FractalPreset {
        if let existingIndex = presets.firstIndex(where: { $0.id == preset.id }) {
            presets[existingIndex] = preset
        } else {
            presets.insert(preset, at: 0)
        }
        persist(preset)
        scheduleBackup()
        FractalPreset.clearThumbnailCache(for: preset.id)
        UsageAnalytics.shared.trackPresetSaved(preset: preset)
        return preset
    }

    @discardableResult
    func importPreset(from url: URL) -> FractalPreset? {
        do {
            return importPreset(try decodePreset(from: url))
        } catch {
            print("Failed to import preset from \(url.lastPathComponent): \(error)")
            return nil
        }
    }
    
}

// MARK: - Default Presets (loaded from bundled preset JSON files)
extension PresetManager {
    
    // ─── Bundle-loaded default scenes ────────────────────────────────────
    // Built-in presets are stored as .threshscene / .threshmp JSON files in
    // Examples/Scenes (bundled as app resources). This keeps the
    // preset data in the same format as user exports and avoids
    // hardcoding parameter values in Swift.
    
    private static func loadBundledPresets() -> [FractalPreset] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        // Bundled scene files use either `.threshscene` / `.threshmp` or the
        // double extension `.threshscene.json` / `.threshmp.json` (some assets
        // were exported with the `.json` suffix to keep editor syntax
        // highlighting). Synchronized Xcode resource folders may flatten some
        // resources into the bundle root, so collect from every known location.
        var sceneURLs: [URL] = []
        var musicPresetURLs: [URL] = []
        let sceneExts = ["threshscene", "json"]
        let musicExts = ["threshmp", "json"]

        for ext in sceneExts {
            sceneURLs += Bundle.main.urls(forResourcesWithExtension: ext, subdirectory: "Examples/Scenes") ?? []
            sceneURLs += Bundle.main.urls(forResourcesWithExtension: ext, subdirectory: "Examples/Mixed") ?? []
            sceneURLs += Bundle.main.urls(forResourcesWithExtension: ext, subdirectory: "Examples/Custom Scene Example") ?? []
            sceneURLs += Bundle.main.urls(forResourcesWithExtension: ext, subdirectory: nil) ?? []
        }
        for ext in musicExts {
            musicPresetURLs += Bundle.main.urls(forResourcesWithExtension: ext, subdirectory: "Examples/Scenes") ?? []
            musicPresetURLs += Bundle.main.urls(forResourcesWithExtension: ext, subdirectory: "Examples/Mixed") ?? []
            musicPresetURLs += Bundle.main.urls(forResourcesWithExtension: ext, subdirectory: nil) ?? []
        }
        // Filter the .json hits down to ones that are actually our preset files.
        sceneURLs = sceneURLs.filter {
            let n = $0.lastPathComponent
            return n.hasSuffix(".threshscene") || n.hasSuffix(".threshscene.json")
        }
        musicPresetURLs = musicPresetURLs.filter {
            let n = $0.lastPathComponent
            return n.hasSuffix(".threshmp") || n.hasSuffix(".threshmp.json")
        }

        // Deep scan as a final safety net for mixed resource layouts.
        if let resourcePath = Bundle.main.resourcePath {
            let enumerator = FileManager.default.enumerator(atPath: resourcePath)
            while let file = enumerator?.nextObject() as? String {
                let url = URL(fileURLWithPath: resourcePath).appendingPathComponent(file)
                if file.hasSuffix(".threshscene") || file.hasSuffix(".threshscene.json") {
                    sceneURLs.append(url)
                } else if file.hasSuffix(".threshmp") || file.hasSuffix(".threshmp.json") {
                    musicPresetURLs.append(url)
                }
            }
        }

        let allURLs = Array(Set(sceneURLs + musicPresetURLs))
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        guard !allURLs.isEmpty else {
            print("⚠️ DefaultPresets: no bundled .threshscene/.threshmp files found anywhere in bundle")
            return []
        }
        print("ℹ️ DefaultPresets: found \(allURLs.count) bundled preset file(s): \(allURLs.map(\.lastPathComponent))")

        var presets: [FractalPreset] = []
        for url in allURLs {
            do {
                let data = try Data(contentsOf: url)
                var preset = try decoder.decode(FractalPreset.self, from: data)
                // Scenes shipped under Examples/Mixed are authored for Mixed
                // immersion: mark them even when the file predates the
                // mixedModeScene field, so loading one switches the headset to
                // Mixed and they populate the Mixed browse section.
                if url.pathComponents.contains("Mixed") {
                    preset.mixedModeScene = true
                }
                presets.append(preset)
            } catch {
                print("⚠️ DefaultPresets: failed to decode \(url.lastPathComponent) — \(error)")
            }
        }
        // The multi-location scan can find the same file both in its Examples
        // subdirectory and flattened at the bundle root. Dedupe by preset id,
        // letting a Mixed-marked copy win regardless of scan order.
        let mixedIDs = Set(presets.filter { $0.mixedModeScene == true }.map(\.id))
        var seenIDs = Set<UUID>()
        var uniquePresets: [FractalPreset] = []
        for var preset in presets where seenIDs.insert(preset.id).inserted {
            if mixedIDs.contains(preset.id) {
                preset.mixedModeScene = true
            }
            uniquePresets.append(preset)
        }
        print("ℹ️ DefaultPresets: successfully decoded \(uniquePresets.count) unique preset(s) (\(mixedIDs.count) mixed-mode)")
        return uniquePresets
    }
    
    /// Clean Mandelbox at the default/reset position, used as the first-launch
    /// default when no `__lastState__` has been saved yet.
    static func mandelboxDefaultPreset() -> FractalPreset {
        var preset = FractalPreset(name: "Mandelbox")
        preset.fractalType = .mandelbox
        preset.fractalScale = 2.8
        preset.foldingLimit = 1.0
        preset.sphereRadius = 0.5
        preset.minDistance = 0.18
        preset.position = SIMD3<Float>(0, 0, -1.15)
        preset.scale = 1.0
        return preset
    }
    
    /// Merge built-in presets with local presets.
    func addBuiltInPresetsIfNeeded() {
        refreshBundledPresets()
    }
    
    // MARK: - Last State Auto-Save/Restore
    
    /// URL for the last state file
    private var lastStateFileURL: URL {
        presetsDirectory.appendingPathComponent("lastState.json")
    }
    
    /// Save current settings as "last state" for restore on next launch
    func saveLastState(from settings: RenderSettings, embeddedFormula: EmbeddedFormula? = nil) {
        let preset = FractalPreset.fromSettings(settings, name: "__lastState__", embeddedFormula: embeddedFormula)
        
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(preset)
            try data.write(to: lastStateFileURL, options: .atomic)
            print("💾 Last state saved")
        } catch {
            print("Failed to save last state: \(error)")
        }
    }
    
    /// Restore last state to settings if available.
    /// Returns the applied preset so callers can restore auxiliary state
    /// (for example embedded custom formulas) alongside render settings.
    /// When no saved state exists, loads and returns the default Mandelbox preset.
    @discardableResult
    func restoreLastState(to settings: RenderSettings) -> FractalPreset? {
        guard FileManager.default.fileExists(atPath: lastStateFileURL.path) else {
            print("ℹ️ No last state found - loading Mandelbox default")
            let defaultPreset = PresetManager.mandelboxDefaultPreset()
            defaultPreset.apply(to: settings)
            return defaultPreset
        }
        
        do {
            let data = try Data(contentsOf: lastStateFileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let preset = try decoder.decode(FractalPreset.self, from: data)
            preset.apply(to: settings)
            print("✅ Last state restored")
            return preset
        } catch {
            print("Failed to restore last state: \(error)")
            return nil
        }
    }
}
