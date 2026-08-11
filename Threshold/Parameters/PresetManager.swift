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
    /// Cold-launch readiness for the iPad bootstrap surface. This stays false
    /// through the first detached folder scan and any one-time bundled-scene
    /// seeding pass, so the app does not reveal an apparently frozen workspace
    /// while those main-actor writes are still in progress.
    private(set) var isInitialLoadComplete = false
    private static var bundledPresetsCache: [FractalPreset]?
    /// The baseline bundle marker intentionally never re-seeds an existing
    /// store. Each entry in `officialCatalogUpdates` carries its own versioned
    /// marker so a deliberate catalog update arrives exactly once without
    /// resurrecting defaults a user has since deleted. Updates are applied in
    /// order, so a store that skipped several releases receives every
    /// generation it is missing.
    struct OfficialCatalogUpdate {
        let markerFileName: String
        let ids: Set<UUID>
    }
    static let officialSceneCatalogUpdateMarkerFileName = ".seeded-official-scenes-v1.json"
    static let officialMusicPresetCatalogUpdateMarkerFileName = ".seeded-official-scenes-v2.json"
    /// Existing installs seeded the original `w` asset with a near-max edge
    /// detector. Keep this correction independent from catalog seeding: it must
    /// update that exact bad payload without recreating a scene the user deleted.
    static let wSceneEdgeDetectionFixMarkerFileName = ".migrated-w-edge-detection-v1.json"
    static let wSceneID = UUID(uuidString: "35AB0B54-3FCB-4CB0-A7D2-D6F7FFDAD1D1")!
    static let officialSceneCatalogUpdateIDs = Set([
        "00000000-0022-0000-0000-000000000001", // Distorted
        "3F4AF708-7B41-4A60-B1A5-9D965E807C9A", // Embedded Mandelbulb
        "F7A845E9-53F1-4E48-BFB0-7A07650C8E45", // Fractal Cartoon
        "66E632EF-0C14-414C-9057-7ED1D49A74A5", // Goop again
        "AC36AB1F-22BE-43C5-82AA-37D4C53BF055", // Great sphere
        "D9799129-E303-4BB5-84CE-04C047257B59", // Hold
        "B1D7E3A2-6C44-4F18-9E70-2A91C5D0F3A4", // Hyperbolic Tessellation
        "2B1C086E-B352-5940-BDF1-F184D7AA6269", // Polychora (4D Solids)
        "880ABBF6-13C5-554A-B393-E679FF46151D", // Pseudo Kleinian
        "D3B14883-7F39-542C-BE66-DC7DB104D952", // Pseudo Kleinian Quaternion Julia
        "F2F53E77-7DDA-51D7-82CD-A640A7E4B965", // Pseudo Knightyan
        "95B889CF-3C8E-5F65-B5D6-DA1AC9A14725", // Pseudo MandalayBox
        "48AC358B-764A-44E6-ADEB-96F3073295FE", // Stress test
        "B4234FA7-8F8B-4700-A0EA-9C4321E635C0", // Wave Rail
        "35AB0B54-3FCB-4CB0-A7D2-D6F7FFDAD1D1"  // w
    ].compactMap(UUID.init(uuidString:)))
    /// v2: the 2026-08 music-preset drop promoted from the working iCloud store.
    static let officialMusicPresetCatalogUpdateIDs = Set([
        "12538C1A-8A0A-4F0E-9C47-76CE3CCBEB41", // 11
        "A591B61A-2D13-4567-B555-C182158B6D4A", // Aaa
        "24E95293-F293-40E8-956D-DAAB4586E486", // Angel
        "C787446B-73FF-46E5-9538-BB8212FE13D5", // BATT
        "1EA5F7B8-F7BC-4E08-B296-BA5A7B577583", // Baal3
        "327C57B2-CC84-4604-93E1-236F014C21E1", // Banana bonnet
        "A4AAF425-99CD-4446-8602-68F798C56083", // Blue hero
        "2D5C1112-F995-480C-BE90-D9CC55440D32", // Buggy reset
        "1E08F8AC-77CE-4616-BB36-71A440A9E7A0", // Cartoon Life
        "26097079-D6D7-4DE2-84FD-A9DF10BD3DAD", // Chords
        "F43C1F99-A804-4B73-B9D9-8FB1D0BC3F99", // Disappearing act
        "F88D66E1-9180-475E-90BE-1B325790F4DF", // Escaping boundaries
        "A9A2DDCB-72C9-4DA5-B7A7-D94F8AEF752E", // Fleur
        "A4CC0A16-9EAD-41E0-BAFC-579936D9EFA4", // Free a a bird
        "203BC310-D591-430C-A982-3561850F3CE8", // Fun
        "719B541B-69BD-480E-BA19-19FB658314EE", // Knocker
        "AB6DD09E-FDE5-4D84-A0B7-59046450F2B2", // Mono Lisa
        "4F7B7DB9-50C0-4843-B80B-FD599AFC1031", // Mountain
        "654A6ED8-2773-449C-A73F-100AC727D3D4", // Mpva
        "11AB86DE-AE7B-452A-B1B7-05A963B8C72D", // Pool
        "1564CE4F-9DB6-410D-87EC-FC8924B66D96", // Pull-up
        "7C7E4627-7385-4E6C-8241-01A2A538C42A", // Ring around the Rosie
        "79BCD40E-4AE1-4818-A340-7B5DDC477526", // Room
        "5F1DFE4B-CBEE-4684-A05E-BBB97A79C93D", // Rooms2
        "BA218EBF-8198-4CBA-90AB-125D87B347D7", // Silent Shout
        "CFD42F09-1F7B-4190-B288-9AE523B6A799", // Wavving
        "9E9E0831-B188-4638-98CE-608D50D71C71", // Yacctm
        "A7FCE90B-D5CA-462F-8823-313B27FEACB4", // corner cut
        "9971C8D0-310F-4282-816C-F852CD9699FC", // static
        "1E99CEAF-9709-4258-B205-F40DE7B86337"  // what's it like
    ].compactMap(UUID.init(uuidString:)))
    /// Applied oldest-first. Append a new generation here (with a fresh marker
    /// filename) whenever curated bundle content must reach existing stores.
    static let officialCatalogUpdates: [OfficialCatalogUpdate] = [
        OfficialCatalogUpdate(
            markerFileName: officialSceneCatalogUpdateMarkerFileName,
            ids: officialSceneCatalogUpdateIDs
        ),
        OfficialCatalogUpdate(
            markerFileName: officialMusicPresetCatalogUpdateMarkerFileName,
            ids: officialMusicPresetCatalogUpdateIDs
        )
    ]
    private static let legacyWSceneEdgeDetection = EdgeDetectionEffect(
        enabled: true,
        strength: 0.98378974,
        threshold: 0.10392282,
        softness: 0.043115318,
        windowRadius: 3
    )
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
    @ObservationIgnored private var failedPlaceholderProbeURLs: Set<URL> = []
    @ObservationIgnored private var mostRecentWriteError: String?
    /// Saves made while iCloud/root discovery is unresolved. They are flushed
    /// before the first reload from that root so the folder-as-truth scan cannot
    /// discard an in-memory scene the user just created.
    @ObservationIgnored private var pendingRootWrites: [UUID: FractalPreset] = [:]
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
        loadPresets(immediate: true)
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
    var sceneCatalogPresets: [FractalPreset] {
        var catalogByID = Dictionary(uniqueKeysWithValues: bundledPlaceholderFallbacks.map { ($0.id, $0) })
        for preset in presets {
            catalogByID[preset.id] = preset
        }
        return Self.filterSceneCatalogPresets(
            Array(catalogByID.values).sorted { $0.createdAt > $1.createdAt },
            bundledPresets: Self.bundledPresets(),
            supportsEnvironmentReconstruction: Self.supportsEnvironmentReconstructionInSceneCatalog
        )
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
        supportsEnvironmentReconstruction: Bool
    ) -> [FractalPreset] {
        guard !supportsEnvironmentReconstruction else { return presets }

        let environmentBundledIDs = Set(bundledPresets.compactMap { preset -> UUID? in
            let requiresEnvironment = preset.envScrunchEnabled == true
                || preset.sceneState?.quality.envScrunchEnabled == true
            return requiresEnvironment ? preset.id : nil
        })

        guard !environmentBundledIDs.isEmpty else { return presets }
        return presets.filter { !environmentBundledIDs.contains($0.id) }
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
        for dir in [StorageLocation.scenesDir(request.root), StorageLocation.musicPresetsDir(request.root)] {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: Array(resourceKeys),
                options: [.skipsHiddenFiles]
            ) else { continue }
            allURLs.append(contentsOf: files.filter { exts.contains($0.pathExtension) })
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
                  let preset = try? decoder.decode(FractalPreset.self, from: data) else {
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

    /// One-time-per-store setup: migrate the legacy blob into per-file layout, and
    /// seed bundled defaults exactly once per store.
    ///
    /// Seeding is gated on the marker file's EXISTENCE, not its contents. The store
    /// lives in iCloud, where the marker can be an un-downloaded placeholder whose
    /// read fails; if we treated a failed read as "never seeded" we'd re-write every
    /// bundled default and RESURRECT any default the user deleted (the store's files
    /// are the source of truth). Existence survives the placeholder, so once seeded
    /// we never seed again and a deleted default stays deleted.
    @discardableResult
    private func migrateAndSeedIfNeeded(root: URL, presentPresetIDs: Set<UUID>) -> Bool {
        let marker = root.appendingPathComponent(".seeded-bundled.json")
        let alreadySeeded = FileManager.default.fileExists(atPath: marker.path)

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
                for preset in legacy where !present.contains(preset.id) {
                    if writeNewPresetFile(preset, root: root) != nil {
                        present.insert(preset.id)
                        wroteFiles = true
                    } else {
                        migrationSucceeded = false
                    }
                }
                print("📦 Migrated \(legacy.count) preset(s) from legacy presets.json")
            }
            if migrationSucceeded {
                UserDefaults.standard.set(true, forKey: legacyMigratedKey)
            }
        }

        // Seed bundled defaults ONCE per store. `!present` keeps any migrated/edited
        // copy; the marker then locks seeding off forever for this store. A later,
        // explicitly curated catalog update is handled below with its own marker.
        if !alreadySeeded {
            let bundled = Self.bundledPresets()
            var seedSucceeded = true
            for preset in bundled where !present.contains(preset.id) {
                if writeNewPresetFile(preset, root: root) != nil {
                    present.insert(preset.id)
                    wroteFiles = true
                } else {
                    seedSucceeded = false
                }
            }
            let seededIDs = bundled.map(\.id)
            if seedSucceeded, let data = try? presetEncoder.encode(seededIDs) {
                do {
                    try data.write(to: marker, options: .atomic)
                } catch {
                    seedSucceeded = false
                    print("❌ Failed to write bundled-preset seed marker: \(error)")
                }
            }
            if seedSucceeded {
                print("🌱 Seeded \(seededIDs.count) bundled preset(s) into store")
                for update in Self.officialCatalogUpdates {
                    _ = markOfficialCatalogUpdateApplied(update, root: root)
                }
            }
            return wroteFiles
        }

        for update in Self.officialCatalogUpdates {
            let result = seedOfficialCatalogUpdateIfNeeded(
                update,
                root: root,
                presentPresetIDs: present
            )
            present.formUnion(result.seededIDs)
            if result.wroteFiles {
                wroteFiles = true
            }
        }
        return wroteFiles
    }

    /// Adds a deliberately curated bundle update exactly once. The independent
    /// marker is checked by existence rather than contents for the same File
    /// Provider reason as the baseline marker: an unhydrated marker must not
    /// cause a deleted default to reappear.
    private func seedOfficialCatalogUpdateIfNeeded(
        _ update: OfficialCatalogUpdate,
        root: URL,
        presentPresetIDs: Set<UUID>
    ) -> (wroteFiles: Bool, seededIDs: Set<UUID>) {
        let marker = root.appendingPathComponent(update.markerFileName)
        guard !FileManager.default.fileExists(atPath: marker.path) else { return (false, []) }

        let additions = Self.bundledPresets().filter {
            update.ids.contains($0.id)
        }
        guard additions.count == update.ids.count else {
            print("❌ Official catalog update \(update.markerFileName) is incomplete in this bundle; deferring seed")
            return (false, [])
        }

        var present = presentPresetIDs
        var seeded: Set<UUID> = []
        var wroteFiles = false
        var seedSucceeded = true
        for preset in additions where !present.contains(preset.id) {
            if writeNewPresetFile(preset, root: root) != nil {
                present.insert(preset.id)
                seeded.insert(preset.id)
                wroteFiles = true
            } else {
                seedSucceeded = false
            }
        }

        guard seedSucceeded else { return (wroteFiles, seeded) }
        guard markOfficialCatalogUpdateApplied(update, root: root) else {
            return (wroteFiles, seeded)
        }
        print("🌱 Seeded official catalog update \(update.markerFileName) (\(additions.count) preset(s)) into store")
        return (wroteFiles, seeded)
    }

    private func markOfficialCatalogUpdateApplied(_ update: OfficialCatalogUpdate, root: URL) -> Bool {
        let marker = root.appendingPathComponent(update.markerFileName)
        guard let data = try? presetEncoder.encode(update.ids.sorted { $0.uuidString < $1.uuidString }) else { return false }
        do {
            try data.write(to: marker, options: .atomic)
            return true
        } catch {
            print("❌ Failed to write official scene catalog update marker: \(error)")
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

    /// Write one preset as its own file, routed by music-reactivity
    /// (.threshmp → Music Presets/, .threshscene → Scenes/). Removes any prior
    /// file for the same id only AFTER the replacement is safely on disk. This
    /// preserves the previous copy if encoding or writing fails.
    @discardableResult
    private func writePresetFile(_ preset: FractalPreset, root: URL) -> Bool {
        guard let writtenURL = writeNewPresetFile(preset, root: root) else { return false }
        removePresetFiles(id: preset.id, root: root, excluding: [writtenURL])
        return true
    }

    /// Write a known-absent preset without scanning the store first. Used by
    /// migration/seeding after the detached scan has already established IDs.
    @discardableResult
    private func writeNewPresetFile(_ preset: FractalPreset, root: URL) -> URL? {
        let hasMusic = preset.hasMusicReactiveMappings
        let dir = hasMusic ? StorageLocation.musicPresetsDir(root) : StorageLocation.scenesDir(root)
        let ext = ThresholdExportFormat.preset(hasMusic: hasMusic).ext
        let url = dir.appendingPathComponent(Self.sanitizedFileName(preset.name, id: preset.id, ext: ext))
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try presetEncoder.encode(preset)
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
    private func removePresetFiles(ids: Set<UUID>, root: URL, excluding: Set<URL> = []) {
        guard !ids.isEmpty else { return }
        let excluded = Set(excluding.map(\.standardizedFileURL))
        let exts = ThresholdExportFormat.extensions(in: .preset)
        for dir in [StorageLocation.scenesDir(root), StorageLocation.musicPresetsDir(root)] {
            guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for url in files where exts.contains(url.pathExtension) {
                guard !excluded.contains(url.standardizedFileURL) else { continue }
                if let data = try? Data(contentsOf: url),
                   let preset = try? presetDecoder.decode(FractalPreset.self, from: data), ids.contains(preset.id) {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
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
        guard let root = storeRoot, !pendingRootWrites.isEmpty else { return }
        invalidatePresetReloadForLocalMutation()
        let pending = pendingRootWrites
        for (id, preset) in pending {
            if writePresetFile(preset, root: root) {
                pendingRootWrites.removeValue(forKey: id)
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
            presets = pendingRootWrites.values.sorted { $0.createdAt > $1.createdAt }
            // Root discovery can continue in the background; an unresolved
            // iCloud container must not leave the launch screen up forever.
            isInitialLoadComplete = true
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
        applyPresetScanResult(result, root: root, reason: "immediate")
    }

    private func makePresetScanRequest(
        root: URL,
        allowsPlaceholderProbe: Bool
    ) -> PresetScanRequest {
        let bundledByName = Dictionary(
            Self.bundledPresets().map { preset in
                let ext = ThresholdExportFormat.preset(
                    hasMusic: preset.hasMusicReactiveMappings
                ).ext
                return (
                    Self.sanitizedFileName(preset.name, id: preset.id, ext: ext),
                    preset
                )
            },
            uniquingKeysWith: { first, _ in first }
        )
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
            self.applyPresetScanResult(result, root: root, reason: reason)
        }
    }

    private func performPresetScan(_ request: PresetScanRequest) async -> PresetScanResult {
        let worker = Task.detached(priority: .utility) {
            Self.scanStorePresets(request)
        }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private func applyPresetScanResult(_ result: PresetScanResult, root: URL, reason: String) {
        let cacheChanged = presetFileCache.count != result.cachedFiles.count ||
            result.cachedFiles.contains { url, entry in
                presetFileCache[url]?.signature != entry.signature
            }
        presetFileCache = result.cachedFiles
        failedPlaceholderProbeURLs = result.failedPlaceholderProbeURLs
        bundledPlaceholderFallbacks = result.bundledPlaceholderFallbacks
        if cacheChanged || presets.map(\.id) != result.presets.map(\.id) {
            presets = result.presets
            FractalPreset.clearThumbnailCache()
        }
        print(
            "📂 Preset scan [\(reason)]: files=\(result.fileCount), " +
            "decoded=\(result.decodedCount), reused=\(result.reusedCount), " +
            "pending=\(result.pendingDownloadCount), " +
            "retryable=\(result.retryablePlaceholderCount)"
        )

        // Migration/seeding is evaluated only after the detached scan, so its
        // presence checks never perform a second synchronous directory decode.
        var wroteFiles = migrateAndSeedIfNeeded(
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

        // A write pass always schedules an immediate verification scan above.
        // Only publish readiness once a complete pass needs no more migration
        // or seeding work; placeholder hydration is intentionally progressive.
        if !wroteFiles {
            isInitialLoadComplete = true
        }
    }

    /// Bundled defaults are seeded once per store; there's nothing to "re-merge"
    /// anymore, so this just reloads the folder (picking up any external changes).
    func refreshBundledPresets() {
        // Bundle resources are immutable for the lifetime of this process. Keep
        // the decoded overlay hot across foreground and view-appearance events;
        // forcing 94 resource reads here caused its own avoidable UI hitch.
        _ = Self.bundledPresets()
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
    @discardableResult
    func savePreset(name: String, settings: RenderSettings, thumbnailData: Data? = nil,
                    embeddedFormula: EmbeddedFormula? = nil,
                    embeddedLighting: EmbeddedFormula? = nil) -> PresetSaveResult {
        let preset = FractalPreset.fromSettings(
            settings,
            name: name,
            thumbnailData: thumbnailData,
            embeddedFormula: embeddedFormula,
            embeddedLighting: embeddedLighting
        )
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
        var preset = preset
        if let existingIndex = presets.firstIndex(where: { $0.id == preset.id }) {
            // Overwriting an existing id is a content change — advance the merge
            // clock so the iCloud newest-wins reconcile favors this edit. (Not on
            // the merge/reconcile path itself, so no ping-pong.) TECH_DEBT #6.
            preset.updatedAt = Date()
            presets[existingIndex] = preset
        } else {
            presets.insert(preset, at: 0)
        }
        _ = persist(preset)
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
    func saveLastState(from settings: RenderSettings,
                       embeddedFormula: EmbeddedFormula? = nil,
                       embeddedLighting: EmbeddedFormula? = nil) {
        let preset = FractalPreset.fromSettings(
            settings,
            name: "__lastState__",
            embeddedFormula: embeddedFormula,
            embeddedLighting: embeddedLighting
        )
        
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
            let preset = try decoder.decode(FractalPreset.self, from: data)
            preset.apply(to: settings, scope: .session)
            print("✅ Last state restored")
            return preset
        } catch {
            print("Failed to restore last state: \(error)")
            return nil
        }
    }
}
