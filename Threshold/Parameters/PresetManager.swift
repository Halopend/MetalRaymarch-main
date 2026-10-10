//
//  PresetManager.swift
//  MetalProject
//
//  Created on January 11, 2026.
//

import SwiftUI
import Foundation

/// Carries decoded bundle presets from the utility worker to the main-actor
/// cache. The preset graph is immutable during this transfer.
private struct BundledPresetCollection: @unchecked Sendable {
    let presets: [FractalPreset]
}

/// Single source of truth for Threshold's shareable file formats. The export
/// writers (PresetManager, AnimationManager, EmbeddedFormulaContainer) and the
/// export-tab format reference both read from here; the UTType declarations in
/// the platform Info.plists must mirror these extensions.
/// Three file types, three schemas, three folders. Music-reactivity and an
/// attached song are *traits inside the file*, not file types — so `.threshmp`
/// and `.threshanimv` are no longer written. They stay readable forever via
/// `legacyExtensions` (see CONTENT_MODEL_PROPOSAL.md §2.3).
enum ThresholdExportFormat: CaseIterable, Sendable {
    case scenePreset
    case animationScene
    case customFormula

    /// Canonical filename extension without the leading dot. This is the ONLY
    /// extension written on export.
    var ext: String {
        switch self {
        case .scenePreset: return "thresh"
        case .animationScene: return "threshanim"
        case .customFormula: return "threshfx"
        }
    }

    /// Extensions from earlier releases that still decode to this format.
    /// Read-compatibility only — never written.
    var legacyExtensions: [String] {
        switch self {
        case .scenePreset: return ["threshscene", "threshmp"]
        case .animationScene: return ["threshanimv"]
        case .customFormula: return []
        }
    }

    /// Canonical extension first, then legacy aliases — for directory scans,
    /// prune, decode, and UTI matching.
    var readableExtensions: [String] { [ext] + legacyExtensions }

    /// One-line description shown in the export tab's format reference.
    var summary: String {
        switch self {
        case .scenePreset: return "Scene (settings + optional audio mappings)"
        case .animationScene: return "Animation scene (keyframe sequence)"
        case .customFormula: return "Custom effect (standalone shader)"
        }
    }

    // MARK: - Routing

    /// Broad kind used to route imports and group extensions by payload.
    enum Category { case preset, animation, formula }

    var category: Category {
        switch self {
        case .scenePreset: return .preset
        case .animationScene: return .animation
        case .customFormula: return .formula
        }
    }

    /// Resolve a format from a filename extension (leading dot optional, any
    /// case). Accepts this build's canonical extensions and every legacy alias.
    /// Returns nil for anything Threshold doesn't recognise.
    init?(fileExtension: String) {
        var e = fileExtension.lowercased()
        if e.hasPrefix(".") { e.removeFirst() }
        guard let match = Self.allCases.first(where: { $0.readableExtensions.contains(e) }) else { return nil }
        self = match
    }

    /// Every extension belonging to a category (canonical + legacy) — for
    /// directory scans, prune, and decode.
    static func extensions(in category: Category) -> [String] {
        allCases.filter { $0.category == category }.flatMap(\.readableExtensions)
    }

    // MARK: - Presentation (import sheet / preset list)

    /// Human-facing name for the format.
    var displayName: String {
        switch self {
        case .scenePreset:     return "Threshold Scene"
        case .animationScene:  return "Animation"
        case .customFormula:   return "Custom Effect"
        }
    }

    /// SF Symbol representing the format.
    var iconName: String {
        switch self {
        case .scenePreset:     return "cube.transparent"
        case .animationScene:  return "film.stack"
        case .customFormula:   return "function"
        }
    }

    /// Accent colour used when presenting the format.
    var accentColor: Color {
        switch self {
        case .scenePreset:     return .purple
        case .animationScene:  return .green
        case .customFormula:   return .purple
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

/// Immediate disposition of a user-authored preset save.
enum PresetSaveResult: Equatable {
    case saved
    case queuedForStorage
    case failed(String)
}

/// File Provider-backed iCloud URLs do not always vend
/// `ubiquitousItemDownloadingStatus` on macOS. Treat an explicit downloaded
/// state as readable, and only probe an unknown-status placeholder when it is
/// small (or already has local allocation). Probes run off MainActor.
enum StorePlaceholderReadPolicy {
    static func requiresHydration(
        isUbiquitous: Bool,
        downloadStatus: URLUbiquitousItemDownloadingStatus?
    ) -> Bool {
        guard isUbiquitous else { return false }
        return downloadStatus != .current && downloadStatus != .downloaded
    }

    static func canProbeUnknownStatus(
        downloadStatus: URLUbiquitousItemDownloadingStatus?,
        fileSize: Int?,
        allocatedSize: Int?,
        maximumSize: Int
    ) -> Bool {
        guard downloadStatus == nil else { return false }
        if (allocatedSize ?? 0) > 0 { return true }
        guard let fileSize else { return false }
        return fileSize <= maximumSize
    }
}

/// Manages saving and loading of presets
@MainActor
@Observable
class PresetManager {
    private(set) var presets: [FractalPreset] = []
    /// True only while a detached store scan is enumerating and decoding preset
    /// files. Debounce time and the idle metadata watcher are intentionally not
    /// included, so UI activity reflects work that is actually executing.
    private(set) var isIndexingPresetFiles = false
    private static var bundledPresetsCache: [FractalPreset]?
    static let bundledCatalogMarkerFileName = ".seeded-bundled.json"
    /// Older releases wrote incremental catalog snapshots to separate markers.
    /// Discover those files by prefix so their recorded IDs can be folded into
    /// the automatic manifest without carrying a hard-coded catalog ledger.
    private static let legacyBundledCatalogMarkerPrefix = ".seeded-official-scenes-"
    /// Existing installs seeded the original `w` asset with a near-max edge
    /// detector. Keep this correction independent from catalog seeding: it must
    /// update that exact bad payload without recreating a scene the user deleted.
    static let wSceneEdgeDetectionFixMarkerFileName = ".migrated-w-edge-detection-v1.json"
    static let wSceneID = UUID(uuidString: "35AB0B54-3FCB-4CB0-A7D2-D6F7FFDAD1D1")!
    private static let legacyWSceneEdgeDetection = EdgeDetectionEffect(
        enabled: true,
        strength: 0.98378974,
        threshold: 0.10392282,
        softness: 0.043115318,
        windowRadius: 3
    )
    /// Finite backup retention. Unlimited retention grew `Documents/Backups/`
    /// to hundreds of MB (each snapshot embeds ~30–80 KB base64 thumbnails per
    /// preset, every 30 s during editing sessions). 24 × ~one snapshot each is
    /// a comfortable safety window.
    private let maxBackupCount: Int? = 24
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

    private struct PresetFileSignature: Equatable, Sendable {
        let fileSize: Int?
        let modificationDate: Date?
    }

    /// FractalPreset is a value graph. A detached scan owns each value until the
    /// completed result is transferred back to MainActor exactly once.
    private struct CachedPresetFile: @unchecked Sendable {
        let signature: PresetFileSignature
        let preset: FractalPreset
    }

    private struct PresetScanRequest: @unchecked Sendable {
        let root: URL
        let cachedFiles: [URL: CachedPresetFile]
        let bundledBySeededFileName: [String: FractalPreset]
        let allowsPlaceholderProbe: Bool
        let failedPlaceholderProbeURLs: Set<URL>
    }

    private struct PresetScanResult: @unchecked Sendable {
        let presets: [FractalPreset]
        let bundledPlaceholderFallbacks: [FractalPreset]
        let cachedFiles: [URL: CachedPresetFile]
        let fileCount: Int
        let decodedCount: Int
        let reusedCount: Int
        let pendingDownloadCount: Int
        let retryablePlaceholderCount: Int
        let failedPlaceholderProbeURLs: Set<URL>
        let cancelled: Bool
    }

    /// Bundle-backed display values for seeded files that are present in the
    /// active store but not readable yet. They never participate in persistence
    /// or cross-store merge decisions.
    private var bundledPlaceholderFallbacks: [FractalPreset] = []
    @ObservationIgnored private var presetFileCache: [URL: CachedPresetFile] = [:]
    @ObservationIgnored private var presetReloadTask: Task<Void, Never>?
    @ObservationIgnored private var presetReloadGeneration: UInt64 = 0
    @ObservationIgnored private var activePresetScanCount = 0
    @ObservationIgnored private var failedPlaceholderProbeURLs: Set<URL> = []
    @ObservationIgnored private var mostRecentWriteError: String?
    /// Saves made while iCloud/root discovery is unresolved. They are flushed
    /// before the first reload from that root so the folder-as-truth scan cannot
    /// discard an in-memory scene the user just created.
    @ObservationIgnored private var pendingRootWrites: [UUID: FractalPreset] = [:]
    /// Deletions queued while the active root is unresolved — without this a
    /// delete was a silent no-op and the next folder scan RESURRECTED the
    /// deleted scene from its still-present file.
    @ObservationIgnored private var pendingRootDeletions: Set<UUID> = []
    private static let presetReloadDebounce: Duration = .milliseconds(350)
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
        // Bundle enumeration and decoding can touch dozens of resources. Keep
        // it off the main actor so the first window and onboarding controls are
        // interactive while the catalog warms up.
        Task { @MainActor [weak self] in
            guard let self else { return }
            let bundled = await Task.detached(priority: .utility) {
                BundledPresetCollection(presets: Self.loadBundledPresets())
            }.value
            Self.bundledPresetsCache = bundled.presets
            self.loadPresets(immediate: true)
        }
        // The folder store is the source of truth: reload whenever the active root
        // resolves (iCloud discovery finishes) or the user switches storage mode,
        // so files added/removed in the folder mirror into the app.
        for name in [StorageLocation.rootResolvedNotification, StorageLocation.modeChangedNotification] {
            let observer = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.flushPendingRootWrites()
                    self?.loadPresets()
                }
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
        loadPresets()   // coalesced pass for files already present

        let query = NSMetadataQuery()
        query.searchScopes = dirs
        // Watch every extension that resolves to a preset (canonical + legacy
        // aliases), so a folder drop of any readable scene type refreshes.
        let presetExts = ThresholdExportFormat.extensions(in: .preset)
        query.predicate = NSCompoundPredicate(orPredicateWithSubpredicates: presetExts.map {
            NSPredicate(format: "%K ENDSWITH %@", NSMetadataItemFSNameKey, ".\($0)")
        })
        // File Provider can emit a burst of metadata events while iCloud is
        // hydrating the folder. Keep query gathering/notification delivery off
        // the main actor; only the debounced `loadPresets()` hop below touches
        // observable app state.
        let queryQueue = OperationQueue()
        queryQueue.maxConcurrentOperationCount = 1
        queryQueue.qualityOfService = .utility
        query.operationQueue = queryQueue
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

    private func ensureBundledPresetsLoaded() async {
        guard Self.bundledPresetsCache == nil else { return }
        let bundled = await Task.detached(priority: .utility) {
            BundledPresetCollection(presets: Self.loadBundledPresets())
        }.value
        Self.bundledPresetsCache = bundled.presets
    }

    /// Stable, process-local bundled catalog for deterministic headless runs.
    /// Benchmarking must not depend on whether File Provider has hydrated the
    /// seeded copies in the active store; user/store entries are overlaid by ID
    /// in `MacBenchmarkHarness` so edited presets still take precedence.
    static func bundledPresetsForBenchmark() -> [FractalPreset] {
        bundledPresets()
    }

    /// Presets suitable for the user-facing scene catalog on this platform.
    ///
    /// `presets` deliberately remains the unfiltered source of truth so bundled
    /// seeding, iCloud sync, export, and diagnostics retain every scene. Catalog
    /// filtering keys off bundled source IDs, which also catches copies already
    /// seeded into the preset store without hiding user-authored environment scenes.
    /// Mixed-reality scenes additionally respect the live Settings → Display
    /// opt-in (`MixedRealitySceneCatalogSettings`) on flat-display hosts.
    var sceneCatalogPresets: [FractalPreset] {
        var catalogByID = Dictionary(uniqueKeysWithValues: bundledPlaceholderFallbacks.map { ($0.id, $0) })
        for preset in presets {
            catalogByID[preset.id] = preset
        }
        return Self.filterSceneCatalogPresets(
            Array(catalogByID.values).sorted { $0.createdAt > $1.createdAt },
            // If a view asks before the background bundle load completes, show
            // store results now; the load's following scan publishes the full
            // catalog. A UI read must never decode every bundled asset.
            bundledPresets: Self.bundledPresetsCache ?? [],
            supportsEnvironmentReconstruction: Self.supportsEnvironmentReconstructionInSceneCatalog,
            includesScreenOnlyScenes: Self.includesScreenOnlyScenesInSceneCatalog,
            includesMacOnlyScenes: Self.includesMacOnlyScenesInSceneCatalog,
            includesMixedRealityScenes: Self.includesMixedRealityScenesInSceneCatalog
        )
    }

    /// Folder category for every scene file currently known to the store, keyed
    /// by preset id. Folders are the taxonomy: a file in `Scenes/Caverns/Ice/`
    /// maps to `["Caverns", "Ice"]`, one directly in `Scenes/` to `[]`, and one
    /// in the legacy `Music Presets/` root to `["Music Presets", …]`. Presets
    /// with no store file (bundle placeholders) map to the root category.
    ///
    /// Derived from the scan cache rather than persisted, so it can never drift
    /// from where the file actually is. Callers should read it once per render
    /// pass — it is O(files).
    var categoryPathsByPresetID: [UUID: [String]] {
        guard let root = storeRoot else { return [:] }
        var result: [UUID: [String]] = [:]
        result.reserveCapacity(presetFileCache.count)
        for (url, cached) in presetFileCache {
            result[cached.preset.id] = LibraryIndex.categoryPath(for: url, root: root) ?? []
        }
        for fallback in bundledPlaceholderFallbacks {
            result[fallback.id] = result[fallback.id] ?? []
        }
        return result
    }

    private static var includesScreenOnlyScenesInSceneCatalog: Bool {
#if os(visionOS)
        false
#else
        true
#endif
    }

    private static var includesMacOnlyScenesInSceneCatalog: Bool {
#if os(macOS)
        true
#else
        false
#endif
    }

    /// Mixed-reality scenes are authored for Vision Pro Mixed immersion.
    /// Flat-display hosts hide them from the catalog unless the user opts in
    /// via Settings → Display; the read is live so toggling updates the
    /// catalog without a relaunch.
    private static var includesMixedRealityScenesInSceneCatalog: Bool {
        MixedRealitySceneCatalogSettings.includesScenes
    }

    private static var supportsEnvironmentReconstructionInSceneCatalog: Bool {
#if os(visionOS)
        true
#else
        false
#endif
    }

    nonisolated static func filterSceneCatalogPresets(
        _ presets: [FractalPreset],
        bundledPresets: [FractalPreset],
        supportsEnvironmentReconstruction: Bool,
        includesScreenOnlyScenes: Bool = true,
        includesMacOnlyScenes: Bool = true,
        includesMixedRealityScenes: Bool = true
    ) -> [FractalPreset] {
        // Platform classification travels inside the bundled file and is
        // authoritative for every copy carrying that identity — including
        // copies seeded into the store by an older release, whose re-encoded
        // `platformVisibility` field can be stale in EITHER direction: a
        // preset tightened to Mac-only must hide on non-Mac hosts, and one
        // loosened to unrestricted must resurface there. The seed marker
        // prevents re-writing those copies, so the bundled file's CURRENT
        // classification is the only thing that can reclassify them.
        // User-authored scenes (unique ids) keep their own field.
        let bundledVisibilityByID: [UUID: PlatformVisibility] = Dictionary(
            bundledPresets.map { ($0.id, PlatformVisibility.resolved($0.platformVisibility)) },
            uniquingKeysWith: { first, _ in first }
        )
        // Mixed-immersion classification travels inside the scene file
        // (`mixedModeScene`), so a stored copy usually classifies itself; the
        // bundled-ID cross-reference also catches copies seeded before the
        // field existed but whose bundled source was later marked Mixed.
        let mixedRealityBundledIDs = Set(bundledPresets.compactMap {
            $0.mixedModeScene == true ? $0.id : nil
        })
        let platformVisiblePresets = presets.filter {
            let visibility = bundledVisibilityByID[$0.id]
                ?? PlatformVisibility.resolved($0.platformVisibility)
            guard includesMacOnlyScenes || visibility != .mac else {
                return false
            }
            guard includesScreenOnlyScenes || (visibility != .flat && visibility != .mac) else {
                return false
            }
            guard includesMixedRealityScenes
                    || ($0.mixedModeScene != true && !mixedRealityBundledIDs.contains($0.id)) else {
                return false
            }
            return true
        }

        guard !supportsEnvironmentReconstruction else { return platformVisiblePresets }

        let environmentBundledIDs = Set(bundledPresets.compactMap { preset -> UUID? in
            let requiresEnvironment = preset.envScrunchEnabled == true
                || preset.sceneState?.quality.envScrunchEnabled == true
            return requiresEnvironment ? preset.id : nil
        })

        guard !environmentBundledIDs.isEmpty else { return platformVisiblePresets }
        return platformVisiblePresets.filter { !environmentBundledIDs.contains($0.id) }
    }

    // MARK: - Folder store: scan / migrate / seed

    /// Decode changed preset files under Scenes/ + Music Presets/. Directory I/O,
    /// iCloud hydration checks, reads, and JSON decoding all run off MainActor.
    private nonisolated static func scanStorePresets(_ request: PresetScanRequest) -> PresetScanResult {
        let exts = ThresholdExportFormat.extensions(in: .preset)
        let resourceKeys: Set<URLResourceKey> = [
            .contentModificationDateKey,
            .fileSizeKey,
            .fileAllocatedSizeKey,
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey
        ]
        var byID: [UUID: FractalPreset] = [:]
        var allURLs: [URL] = []
        // Recursive: every folder below Scenes/ (and the legacy Music Presets/)
        // is a user category, so nested scenes must be scanned, not just the
        // root. See CONTENT_MODEL_PROPOSAL.md §2.4.
        for dir in [StorageLocation.scenesDir(request.root), StorageLocation.musicPresetsDir(request.root)] {
            guard let enumerator = FileManager.default.enumerator(
                at: dir,
                includingPropertiesForKeys: Array(resourceKeys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let url as URL in enumerator where exts.contains(url.pathExtension) {
                allURLs.append(url)
            }
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var newCache: [URL: CachedPresetFile] = [:]
        var fallbackByID: [UUID: FractalPreset] = [:]
        var decodedCount = 0
        var reusedCount = 0
        var pendingDownloadCount = 0
        var retryablePlaceholderCount = 0
        var didProbePlaceholder = false
        var failedPlaceholderProbeURLs = request.failedPlaceholderProbeURLs
        let presetURLs = allURLs.sorted { $0.path < $1.path }

        for rawURL in presetURLs {
            if Task.isCancelled {
                return PresetScanResult(
                    presets: [], bundledPlaceholderFallbacks: [],
                    cachedFiles: request.cachedFiles, fileCount: presetURLs.count,
                    decodedCount: decodedCount, reusedCount: reusedCount,
                    pendingDownloadCount: pendingDownloadCount,
                    retryablePlaceholderCount: retryablePlaceholderCount,
                    failedPlaceholderProbeURLs: failedPlaceholderProbeURLs,
                    cancelled: true
                )
            }

            let url = rawURL.standardizedFileURL
            let values = try? url.resourceValues(forKeys: resourceKeys)
            let signature = PresetFileSignature(
                fileSize: values?.fileSize,
                modificationDate: values?.contentModificationDate
            )
            let cached = request.cachedFiles[url]

            if let cached, cached.signature == signature {
                newCache[url] = cached
                byID[cached.preset.id] = cached.preset
                reusedCount += 1
                continue
            }

            let downloadStatus = values?.ubiquitousItemDownloadingStatus
            let requiresHydration = StorePlaceholderReadPolicy.requiresHydration(
                isUbiquitous: values?.isUbiquitousItem == true,
                downloadStatus: downloadStatus
            )
            var isPlaceholderProbe = false

            // Legacy iCloud reports an explicit not-downloaded state. Modern
            // File Provider can instead report nil forever, even though a
            // background read can materialize the file. Show any known bundled
            // value immediately, then probe at most one small unknown-status
            // file per pass so the catalog fills progressively without a long
            // serial stall.
            if requiresHydration {
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
                pendingDownloadCount += 1

                let fallback = request.bundledBySeededFileName[url.lastPathComponent]
                if let fallback {
                    fallbackByID[fallback.id] = fallback
                }

                let canProbe = request.allowsPlaceholderProbe &&
                    !didProbePlaceholder &&
                    !failedPlaceholderProbeURLs.contains(url) &&
                    StorePlaceholderReadPolicy.canProbeUnknownStatus(
                        downloadStatus: downloadStatus,
                        fileSize: values?.fileSize,
                        allocatedSize: values?.fileAllocatedSize,
                        maximumSize: 2 * 1_024 * 1_024
                    )
                if canProbe {
                    didProbePlaceholder = true
                    isPlaceholderProbe = true
                } else {
                    if let cached {
                        newCache[url] = cached
                        byID[cached.preset.id] = cached.preset
                        reusedCount += 1
                    }
                    if downloadStatus == nil,
                       !failedPlaceholderProbeURLs.contains(url),
                       StorePlaceholderReadPolicy.canProbeUnknownStatus(
                           downloadStatus: downloadStatus,
                           fileSize: values?.fileSize,
                           allocatedSize: values?.fileAllocatedSize,
                           maximumSize: 2 * 1_024 * 1_024
                       ) {
                        retryablePlaceholderCount += 1
                    }
                    continue
                }
            }

            guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
                  var preset = try? SceneFileCodec.decode(FractalPreset.self, from: data, decoder: decoder) else {
                if isPlaceholderProbe {
                    failedPlaceholderProbeURLs.insert(url)
                }
                // An external atomic replace can race the scan. Retain the last
                // good value until the next metadata callback rather than making
                // the item briefly disappear from the UI.
                if let cached {
                    newCache[url] = cached
                    byID[cached.preset.id] = cached.preset
                    reusedCount += 1
                }
                continue
            }

            // Stamp the folder this file actually lives in, so exports and
            // shared copies carry an accurate category hint.
            preset.categoryPath = LibraryIndex.categoryPath(for: url, root: request.root)

            decodedCount += 1
            let entry = CachedPresetFile(signature: signature, preset: preset)
            newCache[url] = entry
            byID[preset.id] = preset
        }

        return PresetScanResult(
            presets: byID.values.sorted { $0.createdAt > $1.createdAt },
            bundledPlaceholderFallbacks: fallbackByID.values.sorted { $0.createdAt > $1.createdAt },
            cachedFiles: newCache,
            fileCount: presetURLs.count,
            decodedCount: decodedCount,
            reusedCount: reusedCount,
            pendingDownloadCount: pendingDownloadCount,
            retryablePlaceholderCount: retryablePlaceholderCount,
            failedPlaceholderProbeURLs: failedPlaceholderProbeURLs,
            cancelled: false
        )
    }

    /// Legacy single-blob presets (migration source), or nil if none.
    private func loadLegacyPresetsBlob() -> [FractalPreset]? {
        guard FileManager.default.fileExists(atPath: legacyPresetsFileURL.path),
              let data = try? Data(contentsOf: legacyPresetsFileURL),
              let arr = try? presetDecoder.decode([FractalPreset].self, from: data) else { return nil }
        return arr
    }

    /// Migrate the legacy blob and merge newly bundled presets into this store.
    /// The seed marker is a monotonic, automatically generated manifest of bundle
    /// IDs the store has already seen. A set difference discovers new assets while
    /// preserving deletions of older bundled presets.
    @discardableResult
    private func migrateAndSeedIfNeeded(root: URL, presentPresetIDs: Set<UUID>) async -> Bool {
        let marker = root.appendingPathComponent(Self.bundledCatalogMarkerFileName)

        // The off-main scan supplies the IDs actually present in this root. Do not
        // use the currently displayed array here: during a storage-mode switch it
        // still belongs to the previous root.
        var present = presentPresetIDs
        var wroteFiles = false

        // Legacy migration runs once, globally (the blob only exists in the old
        // sandbox location and migrates into whichever store is first active).
        let legacyMigratedKey = "Preset.legacyMigrated"
        if !UserDefaults.standard.bool(forKey: legacyMigratedKey) {
            var migrationSucceeded = true
            if FileManager.default.fileExists(atPath: legacyPresetsFileURL.path) {
                guard let legacy = loadLegacyPresetsBlob() else {
                    print("❌ Legacy preset migration deferred: presets.json could not be decoded")
                    return wroteFiles
                }
                for (index, preset) in legacy.enumerated() where !present.contains(preset.id) {
                    if writeNewPresetFile(preset, root: root) != nil {
                        present.insert(preset.id)
                        wroteFiles = true
                    } else {
                        migrationSucceeded = false
                    }
                    if index.isMultiple(of: 3) { await Task.yield() }
                }
                print("📦 Migrated \(legacy.count) preset(s) from legacy presets.json")
            }
            if migrationSucceeded {
                UserDefaults.standard.set(true, forKey: legacyMigratedKey)
            }
        }

        let bundled = Self.bundledPresets()
        let catalogMarkerURLs = bundledCatalogMarkerURLs(root: root, primary: marker)
        guard let seenIDs = readSeenBundledPresetIDs(from: catalogMarkerURLs) else {
            // A dataless iCloud marker must never be mistaken for an empty
            // manifest: that would resurrect every bundled preset the user deleted.
            for url in catalogMarkerURLs {
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            }
            print("☁️ Bundled preset manifest is not readable yet; deferring catalog update")
            return wroteFiles
        }

        let additions = bundled.filter { !seenIDs.contains($0.id) }
        var seedSucceeded = true
        for (index, preset) in additions.enumerated() where !present.contains(preset.id) {
            if writeNewPresetFile(preset, root: root) != nil {
                present.insert(preset.id)
                wroteFiles = true
            } else {
                seedSucceeded = false
            }
            if index.isMultiple(of: 3) { await Task.yield() }
        }

        guard seedSucceeded else { return wroteFiles }
        let updatedSeenIDs = seenIDs.union(bundled.map(\.id))
        guard writeSeenBundledPresetIDs(updatedSeenIDs, to: marker) else {
            return wroteFiles
        }
        if !additions.isEmpty {
            print("🌱 Discovered \(additions.count) new bundled preset(s)")
        }
        return wroteFiles
    }

    private func bundledCatalogMarkerURLs(root: URL, primary: URL) -> [URL] {
        var urls: [URL] = []
        if FileManager.default.fileExists(atPath: primary.path) {
            urls.append(primary)
        }
        let legacyURLs = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ))?.filter {
            $0.lastPathComponent.hasPrefix(Self.legacyBundledCatalogMarkerPrefix)
        } ?? []
        urls.append(contentsOf: legacyURLs)
        return Array(Set(urls))
    }

    private func readSeenBundledPresetIDs(from markerURLs: [URL]) -> Set<UUID>? {
        var result = Set<UUID>()
        for url in markerURLs {
            guard let data = try? Data(contentsOf: url),
                  let ids = try? presetDecoder.decode([UUID].self, from: data)
            else { return nil }
            result.formUnion(ids)
        }
        return result
    }

    private func writeSeenBundledPresetIDs(_ seenIDs: Set<UUID>, to marker: URL) -> Bool {
        let ids = seenIDs.sorted { $0.uuidString < $1.uuidString }
        guard let data = try? presetEncoder.encode(ids) else { return false }
        do {
            try data.write(to: marker, options: .atomic)
            return true
        } catch {
            print("❌ Failed to write bundled-preset manifest: \(error)")
            return false
        }
    }

    /// Correct the exact `w` scene payload shipped before the edge-contour fix.
    ///
    /// This is intentionally not another catalog seed: a user may have deleted
    /// `w`, or tuned its edge detector themselves. Only the original dual
    /// representation is changed, and a missing scene remains missing.
    @discardableResult
    private func migrateLegacyWSceneEdgeDetectionIfNeeded(
        root: URL,
        placeholderPresetIDs: Set<UUID>
    ) -> Bool {
        let marker = root.appendingPathComponent(Self.wSceneEdgeDetectionFixMarkerFileName)
        guard !FileManager.default.fileExists(atPath: marker.path) else { return false }

        // A bundled fallback represents an existing but unhydrated iCloud file.
        // Wait for the real file rather than treating it as a missing/deleted scene.
        guard !placeholderPresetIDs.contains(Self.wSceneID) else { return false }

        guard let index = presets.firstIndex(where: { $0.id == Self.wSceneID }) else {
            _ = markLegacyWSceneEdgeDetectionFixApplied(at: marker)
            return false
        }

        var preset = presets[index]
        guard let flatEffect = preset.edgeDetectionEffect,
              flatEffect == Self.legacyWSceneEdgeDetection,
              var sceneState = preset.sceneState,
              sceneState.lighting.edgeDetectionEffect == Self.legacyWSceneEdgeDetection
        else {
            // The scene is either user-authored or has already been corrected.
            _ = markLegacyWSceneEdgeDetectionFixApplied(at: marker)
            return false
        }

        // Keep the authored threshold, softness, and radius so the user can turn
        // the effect back on later without losing its original tuning.
        var correctedFlatEffect = flatEffect
        correctedFlatEffect.enabled = false
        correctedFlatEffect.strength = 0
        preset.edgeDetectionEffect = correctedFlatEffect

        var correctedCanonicalEffect = sceneState.lighting.edgeDetectionEffect
        correctedCanonicalEffect.enabled = false
        correctedCanonicalEffect.strength = 0
        sceneState.lighting.edgeDetectionEffect = correctedCanonicalEffect
        preset.sceneState = sceneState

        guard writePresetFile(preset, root: root) else { return false }
        presets[index] = preset
        _ = markLegacyWSceneEdgeDetectionFixApplied(at: marker)
        return true
    }

    private func markLegacyWSceneEdgeDetectionFixApplied(at marker: URL) -> Bool {
        guard let data = try? presetEncoder.encode([Self.wSceneID]) else { return false }
        do {
            try data.write(to: marker, options: .atomic)
            return true
        } catch {
            print("❌ Failed to write w edge-detection migration marker: \(error)")
            return false
        }
    }

    // MARK: - Folder store: per-file write / remove

    /// Write one preset as its own file (`.thresh`). Removes any prior file for
    /// the same id only AFTER the replacement is safely on disk, and saves back
    /// into the folder the scene already lives in so an edit never relocates it
    /// out of its category. This preserves the previous copy if encoding or
    /// writing fails.
    @discardableResult
    private func writePresetFile(_ preset: FractalPreset, root: URL) -> Bool {
        let preferredDirectory = storedDirectory(forPresetID: preset.id)
        guard let writtenURL = writeNewPresetFile(preset, root: root,
                                                  preferredDirectory: preferredDirectory) else { return false }
        removePresetFiles(id: preset.id, root: root, excluding: [writtenURL])
        return true
    }

    /// Directory currently holding `preset`'s store file, so an edit saves back
    /// into the same folder category instead of relocating to the root.
    /// nil when the preset has no store file yet (a fresh import/seeded scene).
    private func storedDirectory(forPresetID id: UUID) -> URL? {
        presetFileCache.first { $0.value.preset.id == id }?.key.deletingLastPathComponent()
    }

    /// Write a known-absent preset without scanning the store first. Used by
    /// migration/seeding after the detached scan has already established IDs.
    /// New scenes write to `Scenes/` as `.thresh`: music-reactivity is a trait
    /// inside the file, so it no longer picks a folder or an extension.
    @discardableResult
    private func writeNewPresetFile(_ preset: FractalPreset, root: URL,
                                    preferredDirectory: URL? = nil) -> URL? {
        let dir = preferredDirectory ?? StorageLocation.scenesDir(root)
        let ext = ThresholdExportFormat.scenePreset.ext
        let url = dir.appendingPathComponent(Self.sanitizedFileName(preset.name, id: preset.id, ext: ext))
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // Record where the file lives, so a shared/exported copy carries a
            // category hint the recipient can restore. (`FractalPreset`'s own
            // encoder also re-emits the legacy visibility tag.)
            var stored = preset
            stored.categoryPath = LibraryIndex.categoryPath(for: url, root: root)
            let data = try SceneFileCodec.encode(stored, encoder: presetEncoder)
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            let detail = error.localizedDescription
            mostRecentWriteError = detail
            print("Failed to write preset file: \(detail)")
            return nil
        }
    }

    /// Delete every store file (both folders) whose decoded id matches `id`.
    private func removePresetFiles(id: UUID, root: URL, excluding: Set<URL> = []) {
        removePresetFiles(ids: [id], root: root, excluding: excluding)
    }

    /// Delete every store file (both folders) whose decoded id is in `ids`, scanning
    /// each folder once (vs one scan per id). Used by the delete sites and `replaceAll`.
    ///
    /// Runs OFF the main actor: the sweep decodes EVERY store file, and an
    /// iCloud placeholder can synchronously materialize mid-read — a
    /// multi-second main-actor stall on every save/rename/delete/replaceAll
    /// (same treatment as the store scan). Callers already updated the
    /// in-memory set, so the async file removal races nothing: the reload
    /// invalidation hides the deleted ids until the removal completes.
    private func removePresetFiles(ids: Set<UUID>, root: URL, excluding: Set<URL> = []) {
        guard !ids.isEmpty else { return }
        let excluded = Set(excluding.map(\.standardizedFileURL))
        let exts = ThresholdExportFormat.extensions(in: .preset)
        let decoder = presetDecoder
        Task.detached(priority: .utility) {
            for dir in [StorageLocation.scenesDir(root), StorageLocation.musicPresetsDir(root)] {
                guard let enumerator = FileManager.default.enumerator(
                    at: dir, includingPropertiesForKeys: Self.fileResourceKeys,
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
                // `while let nextObject()` rather than `for … in enumerator`:
                // NSEnumerator's iterator is unavailable from async contexts.
                while let item = enumerator.nextObject() {
                    guard let url = item as? URL, exts.contains(url.pathExtension) else { continue }
                    guard !excluded.contains(url.standardizedFileURL) else { continue }
                    if Self.isUnmaterializedPlaceholder(url) { continue }
                    if let data = try? Data(contentsOf: url),
                       let preset = try? SceneFileCodec.decode(FractalPreset.self, from: data, decoder: decoder), ids.contains(preset.id) {
                        try? FileManager.default.removeItem(at: url)
                    }
                }
            }
        }
    }

    /// Resource keys fetched with directory enumerations (shared by the
    /// placeholder probe).
    nonisolated private static let fileResourceKeys: [URLResourceKey] = [
        .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
        .fileSizeKey, .totalFileAllocatedSizeKey
    ]

    /// True when the file is an iCloud placeholder that has NOT been confirmed
    /// readable locally — reading one synchronously materializes it. Mirrors
    /// `StorePlaceholderReadPolicy`.
    nonisolated private static func isUnmaterializedPlaceholder(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: Set(fileResourceKeys)) else { return false }
        guard values.isUbiquitousItem == true else { return false }
        let status = values.ubiquitousItemDownloadingStatus
        if status == .current || status == .downloaded { return false }
        return true
    }

    /// Persist a single preset, queueing it while the active root resolves.
    private func persist(_ preset: FractalPreset) -> PresetSaveResult {
        guard let root = storeRoot else {
            pendingRootWrites[preset.id] = preset
            // iCloud discovery can transiently leave the active root nil. Keep a
            // recoverable local snapshot and retry discovery instead of claiming
            // the scene was written to a store that does not exist yet.
            backupCurrentPresetsNow()
            StorageLocation.shared.resolveICloud()
            return .queuedForStorage
        }
        invalidatePresetReloadForLocalMutation()
        mostRecentWriteError = nil
        if writePresetFile(preset, root: root) {
            pendingRootWrites.removeValue(forKey: preset.id)
            return .saved
        }
        return .failed(mostRecentWriteError ?? "The scene store could not be written.")
    }

    private func flushPendingRootWrites() {
        guard let root = storeRoot, !pendingRootWrites.isEmpty || !pendingRootDeletions.isEmpty else { return }
        if !pendingRootWrites.isEmpty {
            invalidatePresetReloadForLocalMutation()
            let pending = pendingRootWrites
            for (id, preset) in pending {
                if writePresetFile(preset, root: root) {
                    pendingRootWrites.removeValue(forKey: id)
                }
            }
        }
        if !pendingRootDeletions.isEmpty {
            invalidatePresetReloadForLocalMutation()
            let deletions = pendingRootDeletions
            pendingRootDeletions.removeAll()
            for id in deletions {
                removePresetFiles(id: id, root: root)
            }
        }
    }

    private func invalidatePresetReloadForLocalMutation() {
        presetReloadGeneration &+= 1
        presetReloadTask?.cancel()
        presetReloadTask = nil
    }

    /// Schedule a folder mirror. Watcher, foreground, and startup bursts are
    /// debounced into a single detached scan.
    func loadPresets(forceRefreshBundled: Bool = false, immediate: Bool = false) {
        if forceRefreshBundled { _ = Self.bundledPresets(forceRefresh: true) }
        guard let root = storeRoot else {
            // iCloud chosen but not resolved yet. Keep saves queued during
            // discovery visible; rootResolved flushes them before the disk scan.
            presetReloadGeneration &+= 1
            presetReloadTask?.cancel()
            presetFileCache = [:]
            bundledPlaceholderFallbacks = []
            failedPlaceholderProbeURLs = []
            presets = pendingRootWrites.values
                .filter { !pendingRootDeletions.contains($0.id) }
                .sorted { $0.createdAt > $1.createdAt }
            return
        }
        StorageLocation.shared.ensureLayout(at: root)
        schedulePresetReload(
            root: root,
            reason: immediate ? "initial" : "coalesced",
            immediate: immediate,
            allowsPlaceholderProbe: false
        )
    }

    /// Immediate off-main reload for storage-mode merges, where the merge must
    /// consume the newly selected store before writing the union back.
    func loadPresetsNow(forceRefreshBundled: Bool = false) async {
        await ensureBundledPresetsLoaded()
        if forceRefreshBundled { _ = Self.bundledPresets(forceRefresh: true) }
        presetReloadGeneration &+= 1
        presetReloadTask?.cancel()
        guard let root = storeRoot else {
            presetFileCache = [:]
            bundledPlaceholderFallbacks = []
            failedPlaceholderProbeURLs = []
            presets = []
            return
        }
        StorageLocation.shared.ensureLayout(at: root)
        let result = await performPresetScan(makePresetScanRequest(
            root: root,
            allowsPlaceholderProbe: false
        ))
        guard !result.cancelled else { return }
        await applyPresetScanResult(result, root: root, reason: "immediate")
    }

    private func makePresetScanRequest(
        root: URL,
        allowsPlaceholderProbe: Bool
    ) -> PresetScanRequest {
        // Bundled presets may already be seeded on disk under any readable
        // scene extension (`.thresh`, `.threshscene`, `.threshmp`), so index
        // every alias to keep the iCloud placeholder fallback working.
        var bundledByName: [String: FractalPreset] = [:]
        for preset in Self.bundledPresetsCache ?? [] {
            for ext in ThresholdExportFormat.scenePreset.readableExtensions {
                bundledByName[Self.sanitizedFileName(preset.name, id: preset.id, ext: ext)] = preset
            }
        }
        return PresetScanRequest(
            root: root,
            cachedFiles: presetFileCache,
            bundledBySeededFileName: bundledByName,
            allowsPlaceholderProbe: allowsPlaceholderProbe,
            failedPlaceholderProbeURLs: failedPlaceholderProbeURLs
        )
    }

    private func schedulePresetReload(
        root: URL,
        reason: String,
        immediate: Bool,
        allowsPlaceholderProbe: Bool
    ) {
        if !allowsPlaceholderProbe {
            failedPlaceholderProbeURLs = []
        }
        presetReloadGeneration &+= 1
        let generation = presetReloadGeneration
        presetReloadTask?.cancel()
        let request = makePresetScanRequest(
            root: root,
            allowsPlaceholderProbe: allowsPlaceholderProbe
        )
        presetReloadTask = Task { [weak self] in
            if !immediate {
                do {
                    try await Task.sleep(for: Self.presetReloadDebounce)
                } catch {
                    return
                }
            }
            guard !Task.isCancelled, let self else { return }
            let result = await self.performPresetScan(request)
            guard !Task.isCancelled, !result.cancelled,
                  generation == self.presetReloadGeneration else { return }
            await self.applyPresetScanResult(result, root: root, reason: reason)
        }
    }

    private func performPresetScan(_ request: PresetScanRequest) async -> PresetScanResult {
        activePresetScanCount += 1
        isIndexingPresetFiles = true
        defer {
            activePresetScanCount -= 1
            isIndexingPresetFiles = activePresetScanCount > 0
        }

        let worker = Task.detached(priority: .utility) {
            Self.scanStorePresets(request)
        }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private func applyPresetScanResult(_ result: PresetScanResult, root: URL, reason: String) async {
        // Keep the activity indicator true through first-install migration and
        // seeding. Those writes are cooperative so they don't starve UI input.
        activePresetScanCount += 1
        isIndexingPresetFiles = true
        defer {
            activePresetScanCount -= 1
            isIndexingPresetFiles = activePresetScanCount > 0
        }
        let cacheChanged = presetFileCache.count != result.cachedFiles.count ||
            result.cachedFiles.contains { url, entry in
                presetFileCache[url]?.signature != entry.signature
            }
        presetFileCache = result.cachedFiles
        failedPlaceholderProbeURLs = result.failedPlaceholderProbeURLs
        bundledPlaceholderFallbacks = result.bundledPlaceholderFallbacks
        if cacheChanged || presets.map(\.id) != result.presets.map(\.id) {
            presets = result.presets
            // Thumbnail cache keys are content digests, so unchanged
            // payloads stay warm across scans; clearing the whole cache here
            // re-decoded every visible scene card on the main actor after
            // each hydration pass — a multi-frame hitch under the
            // "Indexing files…" banner. Prewarm off-main instead so grid
            // body evaluations hit the cache.
            let scannedPresets = result.presets
            Task.detached(priority: .utility) {
                FractalPreset.prewarmThumbnailCache(for: scannedPresets)
            }
        }
        print(
            "📂 Preset scan [\(reason)]: files=\(result.fileCount), " +
            "decoded=\(result.decodedCount), reused=\(result.reusedCount), " +
            "pending=\(result.pendingDownloadCount), " +
            "retryable=\(result.retryablePlaceholderCount)"
        )

        // Migration/seeding is evaluated only after the detached scan, so its
        // presence checks never perform a second synchronous directory decode.
        var wroteFiles = await migrateAndSeedIfNeeded(
            root: root,
            presentPresetIDs: Set(
                (result.presets + result.bundledPlaceholderFallbacks).map(\.id)
            )
        )
        if !wroteFiles {
            wroteFiles = migrateLegacyWSceneEdgeDetectionIfNeeded(
                root: root,
                placeholderPresetIDs: Set(result.bundledPlaceholderFallbacks.map(\.id))
            )
        }
        if wroteFiles {
            presetFileCache = [:]
            schedulePresetReload(
                root: root,
                reason: "post-migration",
                immediate: true,
                allowsPlaceholderProbe: false
            )
        } else if result.retryablePlaceholderCount > 0 {
            schedulePresetReload(
                root: root,
                reason: "placeholder-probe",
                immediate: false,
                allowsPlaceholderProbe: true
            )
        }
    }

    /// Bundled defaults are seeded once per store; there's nothing to "re-merge"
    /// anymore, so this just reloads the folder (picking up any external changes).
    func refreshBundledPresets() {
        // Bundle resources are immutable for the lifetime of this process. Keep
        // the decoded overlay hot across foreground and view-appearance events;
        // forcing 94 resource reads here caused its own avoidable UI hitch.
        // The initial load is already running on a utility task. If it has not
        // completed, that task will schedule the first store scan when ready.
        guard Self.bundledPresetsCache != nil else { return }
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
        // Off-main encode: the whole-set pretty-JSON encode costs tens of ms
        // for realistic libraries and previously ran on the main actor after
        // every debounced edit. FractalPreset is a value graph, so the copy
        // into the detached task is the transfer.
        let presets = self.presets
        Task.detached(priority: .utility) { [weak self] in
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(presets) else { return }
            await self?.writeBackup(data: data)
        }
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
    /// preset's file, and remove files for ids the app is dropping.
    ///
    /// Removals are attributed to ids that were in the current in-memory set but
    /// are absent from `newPresets` — we do NOT infer them by diffing the folder
    /// scan. A not-yet-downloaded iCloud preset from another device is absent from
    /// the scan yet must not be deleted, or the delete propagates to every device.
    /// Mirrors `AnimationManager.replaceUserScenes`.
    func replaceAll(with newPresets: [FractalPreset]) {
        let droppedIDs = Set(presets.map(\.id)).subtracting(newPresets.map(\.id))
        invalidatePresetReloadForLocalMutation()
        presets = newPresets
        if let root = storeRoot {
            removePresetFiles(ids: droppedIDs, root: root)
            for preset in newPresets { writePresetFile(preset, root: root) }
            presetFileCache = [:]
        }
        scheduleBackup()
    }

    /// Write a timestamped backup with finite retention (`maxBackupCount`).
    private func writeBackup(data: Data) {
        let now = Date()
        if let lastBackupAt, now.timeIntervalSince(lastBackupAt) < backupInterval {
            return
        }
        self.lastBackupAt = now

        let stamp = Self.backupTimestampFormatter.string(from: now)
        let backupURL = backupsDirectory.appendingPathComponent("presets-\(stamp).json")
        do {
            // Atomic: a kill mid-write previously left a truncated backup that
            // looks complete to the prune pass (animations already do this).
            try data.write(to: backupURL, options: .atomic)
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
    @discardableResult
    func savePreset(name: String, settings: RenderSettings, thumbnailData: Data? = nil,
                    embeddedFormula: EmbeddedFormula? = nil) -> PresetSaveResult {
        let preset = FractalPreset.fromSettings(settings, name: name, thumbnailData: thumbnailData, embeddedFormula: embeddedFormula)
        presets.insert(preset, at: 0) // Add to beginning (newest first)
        let result = persist(preset)
        if case .failed = result {
            // Do not leave an in-memory ghost that looks saved but disappears on
            // the next folder reload.
            presets.removeAll { $0.id == preset.id }
            return result
        }
        scheduleBackup()

        // Track for analytics with full preset data
        UsageAnalytics.shared.trackPresetSaved(preset: preset)
        return result
    }

    /// Persist metadata edited from a scene card (for example its explicit
    /// visionOS Mixed-immersion opt-in). If the catalog item is currently only
    /// a bundle/placeholder value, this creates the user's editable store copy.
    @discardableResult
    func updatePreset(_ preset: FractalPreset) -> PresetSaveResult {
        var updated = preset
        updated.tags = SceneTagging.normalized(updated.tags)
        updated.updatedAt = Date()

        let existingIndex = presets.firstIndex { $0.id == updated.id }
        let previous = existingIndex.map { presets[$0] }
        if let existingIndex {
            presets[existingIndex] = updated
        } else {
            presets.insert(updated, at: 0)
        }

        let result = persist(updated)
        if case .failed = result {
            if let existingIndex, let previous {
                presets[existingIndex] = previous
            } else {
                presets.removeAll { $0.id == updated.id }
            }
            return result
        }

        FractalPreset.clearThumbnailCache(for: updated.id)
        scheduleBackup()
        return result
    }

    /// Delete a preset. Removing its file IS the deletion — under folder-as-truth
    /// that removal is what propagates (iCloud syncs the delete to other devices).
    func deletePreset(_ preset: FractalPreset) {
        presets.removeAll { $0.id == preset.id }
        pendingRootWrites.removeValue(forKey: preset.id)
        FractalPreset.clearThumbnailCache(for: preset.id)
        if let root = storeRoot {
            invalidatePresetReloadForLocalMutation()
            removePresetFiles(id: preset.id, root: root)
        } else {
            // Root unresolved: the removal must be queued or the next scan
            // resurrects the deleted scene from its still-present file.
            pendingRootDeletions.insert(preset.id)
            backupCurrentPresetsNow()
            StorageLocation.shared.resolveICloud()
        }
        scheduleBackup()
    }

    /// Delete preset at index
    func deletePreset(at offsets: IndexSet) {
        let removed = offsets.compactMap { index in
            presets.indices.contains(index) ? presets[index] : nil
        }
        presets.remove(atOffsets: offsets)
        if !removed.isEmpty { invalidatePresetReloadForLocalMutation() }
        for preset in removed {
            pendingRootWrites.removeValue(forKey: preset.id)
            FractalPreset.clearThumbnailCache(for: preset.id)
            if let root = storeRoot {
                removePresetFiles(id: preset.id, root: root)
            } else {
                pendingRootDeletions.insert(preset.id)
            }
        }
        if !removed.isEmpty && storeRoot == nil {
            backupCurrentPresetsNow()
            StorageLocation.shared.resolveICloud()
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
    
    /// Export a preset to a `.thresh` file URL. Music-reactivity is a trait
    /// inside the file, so it no longer changes the extension.
    /// Nonisolated: encoding + the temp-file write can take tens of ms for
    /// large presets — call it off the main actor (see `exportOffMain`).
    nonisolated static func exportPresetFile(_ preset: FractalPreset) -> URL? {
        let format: ThresholdExportFormat = .scenePreset
        let fileName = "\(Self.sanitizedExportFileNameStem(preset.name)).\(format.ext)"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try SceneFileCodec.encode(preset, encoder: encoder)
            try data.write(to: tempURL)
            return tempURL
        } catch {
            print("Failed to export preset: \(error)")
            return nil
        }
    }

    func decodePreset(from url: URL) throws -> FractalPreset {
        let data = try Data(contentsOf: url)
        return try SceneFileCodec.decode(FractalPreset.self, from: data, decoder: presetDecoder)
    }

    @discardableResult
    func importPreset(_ preset: FractalPreset) -> FractalPreset {
        var preset = preset
        let existingIndex = presets.firstIndex(where: { $0.id == preset.id })
        let previous = existingIndex.map { presets[$0] }
        if let existingIndex {
            // Keep the file's own merge clock instead of stamping `now`:
            // stamping let an OLDER re-imported export win the newest-wins
            // iCloud reconcile and propagate stale content cross-device. The
            // file's updatedAt is the honest recency signal — if it is
            // genuinely older than the local edit, the local edit wins the
            // merge (and this device's reconcile), so no regression spreads.
            presets[existingIndex] = preset
        } else {
            presets.insert(preset, at: 0)
        }
        let result = persist(preset)
        if case .failed = result {
            // Do not leave an in-memory ghost that looks saved but disappears
            // on the next folder-truth scan (same rollback as savePreset /
            // updatePreset).
            if let existingIndex, let previous {
                presets[existingIndex] = previous
            } else {
                presets.removeAll { $0.id == preset.id }
            }
            return preset
        }
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
    // Built-in presets are stored as preset JSON files under `Examples/`
    // (bundled as app resources). This keeps the preset data in the same format
    // as user exports and avoids hardcoding parameter values in Swift.

    nonisolated private static func loadBundledPresets() -> [FractalPreset] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        // ONE deterministic recursive scan of the bundle's resources. Xcode's
        // synchronized resource folders flatten `Examples/` into the bundle
        // root, so per-directory `subdirectory:` lookups silently found nothing
        // and the old "deep scan safety net" was the only mechanism that
        // actually worked — this names that mechanism directly instead of
        // guessing at folder names.
        //
        // Classification lives inside each file (`mixedModeScene`,
        // `platformVisibility`), never in the folder name, so there is nothing
        // to sniff for here. Legacy `.threshscene` / `.threshmp` and the
        // canonical `.thresh` are all recognised.
        var urls: [URL] = []
        if let resourcePath = Bundle.main.resourcePath {
            let enumerator = FileManager.default.enumerator(atPath: resourcePath)
            while let file = enumerator?.nextObject() as? String {
                let isPreset = file.hasSuffix(".threshscene")
                    || file.hasSuffix(".threshscene.json")
                    || file.hasSuffix(".threshmp")
                    || file.hasSuffix(".threshmp.json")
                    || file.hasSuffix(".thresh")
                guard isPreset else { continue }
                urls.append(URL(fileURLWithPath: resourcePath).appendingPathComponent(file))
            }
        }

        let allURLs = Array(Set(urls))
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        guard !allURLs.isEmpty else {
            print("⚠️ DefaultPresets: no bundled preset files found in the bundle")
            return []
        }
        print("ℹ️ DefaultPresets: found \(allURLs.count) bundled preset file(s)")

        var presets: [FractalPreset] = []
        for url in allURLs {
            do {
                let data = try Data(contentsOf: url)
                presets.append(try SceneFileCodec.decode(FractalPreset.self, from: data, decoder: decoder))
            } catch {
                print("⚠️ DefaultPresets: failed to decode \(url.lastPathComponent) — \(error)")
            }
        }

        // Dedupe by id — a bundle can legitimately hold two copies (e.g. a
        // flattened duplicate). First in sorted order wins.
        var seenIDs = Set<UUID>()
        let uniquePresets = presets.filter { seenIDs.insert($0.id).inserted }
        print("ℹ️ DefaultPresets: successfully decoded \(uniquePresets.count) unique preset(s)")
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
        // The opening scene on a fresh install must open at the Low quality
        // preset: this preset is applied on first launch by restoreLastState
        // (no saved last state), and its DE budget would otherwise stomp the
        // device's Low first-launch defaults back up to a heavier budget.
        preset.fractalIterations = QualityPreset.low.fractalIterations
        preset.maxRaySteps = QualityPreset.low.raySteps
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
            defaultPreset.apply(to: settings, scope: .session)
            return defaultPreset
        }
        
        do {
            let data = try Data(contentsOf: lastStateFileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let preset = try SceneFileCodec.decode(FractalPreset.self, from: data, decoder: decoder)
            preset.apply(to: settings, scope: .session)
            print("✅ Last state restored")
            return preset
        } catch {
            print("Failed to restore last state: \(error)")
            return nil
        }
    }
}
