//
//  AnimationManager.swift
//  Threshold
//
//  Manages scene playback, storage, and parameter interpolation.
//  Handles saving/loading scenes to disk and driving real-time animation.
//

import Foundation
import simd
import QuartzCore
#if canImport(UIKit)
import UIKit
#endif

@MainActor
@Observable
final class AnimationManager {
    private static let defaultSegmentDuration: TimeInterval = 2.0
    @ObservationIgnored private let sceneDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
    @ObservationIgnored private let sceneEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    @ObservationIgnored private let prettySceneEncoder: JSONEncoder = AnimationManager.makePrettySceneEncoder()

    /// Observers that reload user scenes when the active store root resolves or the
    /// mode changes. `nonisolated(unsafe)` so the nonisolated deinit can unregister
    /// them (removal only; NotificationCenter is thread-safe).
    @ObservationIgnored nonisolated(unsafe) private var storageObservers: [NSObjectProtocol] = []

    private struct SceneFileSignature: Equatable, Sendable {
        let fileSize: Int?
        let modificationDate: Date?
    }

    /// AnimationScene is a value graph. It is immutable while the detached scan
    /// owns it and is transferred to MainActor exactly once when the scan ends.
    private struct CachedSceneFile: @unchecked Sendable {
        let signature: SceneFileSignature
        let scene: AnimationScene
    }

    private struct SceneScanRequest: @unchecked Sendable {
        let root: URL
        let cachedFiles: [URL: CachedSceneFile]
        let allowsPlaceholderProbe: Bool
        let failedPlaceholderProbeURLs: Set<URL>
    }

    private struct SceneScanResult: @unchecked Sendable {
        let scenes: [AnimationScene]
        let cachedFiles: [URL: CachedSceneFile]
        let fileCount: Int
        let decodedCount: Int
        let reusedCount: Int
        let pendingDownloadCount: Int
        let retryablePlaceholderCount: Int
        let failedPlaceholderProbeURLs: Set<URL>
        let cancelled: Bool
    }

    @ObservationIgnored private var sceneFileCache: [URL: CachedSceneFile] = [:]
    @ObservationIgnored private var userSceneReloadTask: Task<Void, Never>?
    @ObservationIgnored private var userSceneReloadGeneration: UInt64 = 0
    @ObservationIgnored private var failedPlaceholderProbeURLs: Set<URL> = []
    @ObservationIgnored private var pendingRootWrites: [UUID: AnimationScene] = [:]
    private static let sceneReloadDebounce: Duration = .milliseconds(350)

    // MARK: - Folder store (user scenes are files under <root>/Animations)

    /// Active store root for the current mode (nil while iCloud is resolving).
    private var storeRoot: URL? { StorageLocation.shared.activeRoot }

    private nonisolated static func sanitizedSceneFileName(_ name: String, id: UUID, ext: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:\n\r")
        let cleaned = name.components(separatedBy: invalid).joined()
            .replacingOccurrences(of: " ", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "._- "))
        let stem = cleaned.isEmpty ? "Untitled" : String(cleaned.prefix(64))
        return "\(stem)_\(id.uuidString.prefix(8)).\(ext)"
    }

    /// Decode user scenes (non-default ids) from the store's Animations/ folder.
    /// Default scenes are handled by the built-in overlay, so any default files
    /// present in the folder (e.g. written by a prior sync) are ignored here.
    private nonisolated static func scanUserScenes(_ request: SceneScanRequest) -> SceneScanResult {
        let dir = StorageLocation.animationsDir(request.root)
        let exts = ThresholdExportFormat.extensions(in: .animation)
        let resourceKeys: Set<URLResourceKey> = [
            .contentModificationDateKey,
            .fileSizeKey,
            .fileAllocatedSizeKey,
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey
        ]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        ) else {
            return SceneScanResult(
                scenes: [], cachedFiles: [:], fileCount: 0, decodedCount: 0,
                reusedCount: 0, pendingDownloadCount: 0,
                retryablePlaceholderCount: 0,
                failedPlaceholderProbeURLs: request.failedPlaceholderProbeURLs,
                cancelled: false
            )
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var byID: [UUID: AnimationScene] = [:]
        var newCache: [URL: CachedSceneFile] = [:]
        var decodedCount = 0
        var reusedCount = 0
        var pendingDownloadCount = 0
        var retryablePlaceholderCount = 0
        var didProbePlaceholder = false
        var failedPlaceholderProbeURLs = request.failedPlaceholderProbeURLs
        let sceneURLs = files
            .filter { exts.contains($0.pathExtension) }
            .sorted { $0.path < $1.path }

        for rawURL in sceneURLs {
            if Task.isCancelled {
                return SceneScanResult(
                    scenes: [], cachedFiles: request.cachedFiles, fileCount: sceneURLs.count,
                    decodedCount: decodedCount, reusedCount: reusedCount,
                    pendingDownloadCount: pendingDownloadCount,
                    retryablePlaceholderCount: retryablePlaceholderCount,
                    failedPlaceholderProbeURLs: failedPlaceholderProbeURLs,
                    cancelled: true
                )
            }

            let url = rawURL.standardizedFileURL
            let values = try? url.resourceValues(forKeys: resourceKeys)
            let signature = SceneFileSignature(
                fileSize: values?.fileSize,
                modificationDate: values?.contentModificationDate
            )
            let cached = request.cachedFiles[url]

            if let cached, cached.signature == signature {
                newCache[url] = cached
                byID[cached.scene.id] = cached.scene
                reusedCount += 1
                continue
            }

            let downloadStatus = values?.ubiquitousItemDownloadingStatus
            let requiresHydration = StorePlaceholderReadPolicy.requiresHydration(
                isUbiquitous: values?.isUbiquitousItem == true,
                downloadStatus: downloadStatus
            )
            var isPlaceholderProbe = false

            // Unknown File Provider status is common on macOS. Probe at most one
            // small scene per detached pass; large recordings are only read after
            // File Provider reports them downloaded or gives them local allocation.
            if requiresHydration {
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
                pendingDownloadCount += 1

                let canProbe = request.allowsPlaceholderProbe &&
                    !didProbePlaceholder &&
                    !failedPlaceholderProbeURLs.contains(url) &&
                    StorePlaceholderReadPolicy.canProbeUnknownStatus(
                        downloadStatus: downloadStatus,
                        fileSize: values?.fileSize,
                        allocatedSize: values?.fileAllocatedSize,
                        maximumSize: 1 * 1_024 * 1_024
                    )
                if canProbe {
                    didProbePlaceholder = true
                    isPlaceholderProbe = true
                } else {
                    if let cached {
                        newCache[url] = cached
                        byID[cached.scene.id] = cached.scene
                        reusedCount += 1
                    }
                    if downloadStatus == nil,
                       !failedPlaceholderProbeURLs.contains(url),
                       StorePlaceholderReadPolicy.canProbeUnknownStatus(
                           downloadStatus: downloadStatus,
                           fileSize: values?.fileSize,
                           allocatedSize: values?.fileAllocatedSize,
                           maximumSize: 1 * 1_024 * 1_024
                       ) {
                        retryablePlaceholderCount += 1
                    }
                    continue
                }
            }

            guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
                  let scene = try? decoder.decode(AnimationScene.self, from: data),
                  !DefaultScenes.isDefault(scene.id) else {
                if isPlaceholderProbe {
                    failedPlaceholderProbeURLs.insert(url)
                }
                // Keep the last known-good value if a coordinated external write
                // was observed between directory enumeration and the read.
                if let cached {
                    newCache[url] = cached
                    byID[cached.scene.id] = cached.scene
                    reusedCount += 1
                }
                continue
            }

            decodedCount += 1
            let entry = CachedSceneFile(signature: signature, scene: scene)
            newCache[url] = entry
            guard !DefaultScenes.isDefault(scene.id) else { continue }
            byID[scene.id] = scene
        }

        let scenes = byID.values.sorted {
            if $0.name != $1.name {
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            return $0.id.uuidString < $1.id.uuidString
        }
        return SceneScanResult(
            scenes: scenes,
            cachedFiles: newCache,
            fileCount: sceneURLs.count,
            decodedCount: decodedCount,
            reusedCount: reusedCount,
            pendingDownloadCount: pendingDownloadCount,
            retryablePlaceholderCount: retryablePlaceholderCount,
            failedPlaceholderProbeURLs: failedPlaceholderProbeURLs,
            cancelled: false
        )
    }

    /// Write one user scene as its own file. The replacement is written first;
    /// old names/extensions are removed only after that succeeds, so a failed
    /// encode/write cannot destroy the user's only copy.
    @discardableResult
    private func writeUserSceneFile(_ scene: AnimationScene) -> Bool {
        writeUserSceneFiles([scene]).contains(scene.id)
    }

    /// Batch form used by whole-library saves. Every replacement is written
    /// first, followed by one cleanup scan for all successful IDs; this keeps a
    /// routine save O(scene + files) instead of decoding the folder once per
    /// scene on the main actor.
    @discardableResult
    private func writeUserSceneFiles(_ scenes: [AnimationScene]) -> Set<UUID> {
        guard let root = storeRoot else { return [] }
        let dir = StorageLocation.animationsDir(root)
        invalidateUserSceneReloadForLocalMutation()
        var successfulIDs: Set<UUID> = []
        var writtenURLs: Set<URL> = []
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            print("❌ Failed to create animation directory: \(error)")
            return []
        }

        for scene in scenes {
            do {
                let ext = ThresholdExportFormat.animation(hasSong: scene.attachedSong != nil).ext
                let url = dir.appendingPathComponent(Self.sanitizedSceneFileName(scene.name, id: scene.id, ext: ext))
                let data = try prettySceneEncoder.encode(scene)
                try data.write(to: url, options: .atomic)
                successfulIDs.insert(scene.id)
                writtenURLs.insert(url)
            } catch {
                print("❌ Failed to write scene file '\(scene.name)': \(error)")
            }
        }

        removeUserSceneFiles(ids: successfulIDs, excluding: writtenURLs)
        return successfulIDs
    }

    private func invalidateUserSceneReloadForLocalMutation() {
        userSceneReloadGeneration &+= 1
        userSceneReloadTask?.cancel()
        userSceneReloadTask = nil
    }

    /// Delete every store file whose decoded id matches `id`.
    private func removeUserSceneFile(id: UUID) {
        invalidateUserSceneReloadForLocalMutation()
        removeUserSceneFiles(ids: [id])
    }

    /// Delete every store file whose decoded id is in `ids`, in a single directory
    /// scan (vs one scan per id). Used by the delete site and `replaceUserScenes`.
    private func removeUserSceneFiles(ids: Set<UUID>, excluding: Set<URL> = []) {
        guard !ids.isEmpty, let root = storeRoot else { return }
        let dir = StorageLocation.animationsDir(root)
        let excluded = Set(excluding.map(\.standardizedFileURL))
        let exts = ThresholdExportFormat.extensions(in: .animation)
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for url in files where exts.contains(url.pathExtension) {
            guard !excluded.contains(url.standardizedFileURL) else { continue }
            if let data = try? Data(contentsOf: url),
               let scene = try? sceneDecoder.decode(AnimationScene.self, from: data), ids.contains(scene.id) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// Reload user scenes from the store folder (the source of truth) — reflects
    /// files added or removed in the folder, including external deletes.
    func reloadUserScenesFromStore() {
        scheduleUserSceneReload(reason: "explicit")
    }

    /// An immediate off-main reload for workflows that need the new snapshot
    /// before continuing (notably storage-mode merge). Regular watcher and
    /// foreground notifications should use the debounced method above.
    func reloadUserScenesFromStoreNow() async {
        userSceneReloadGeneration &+= 1
        userSceneReloadTask?.cancel()
        guard let request = makeSceneScanRequest() else {
            applySceneScanResult(.init(
                scenes: [], cachedFiles: [:], fileCount: 0, decodedCount: 0,
                reusedCount: 0, pendingDownloadCount: 0,
                retryablePlaceholderCount: 0,
                failedPlaceholderProbeURLs: [],
                cancelled: false
            ), reason: "immediate")
            return
        }
        let result = await performSceneScan(request)
        guard !result.cancelled else { return }
        applySceneScanResult(result, reason: "immediate")
    }

    private func scheduleUserSceneReload(
        reason: String,
        immediate: Bool = false,
        allowsPlaceholderProbe: Bool = false
    ) {
        if !allowsPlaceholderProbe {
            failedPlaceholderProbeURLs = []
        }
        userSceneReloadGeneration &+= 1
        let generation = userSceneReloadGeneration
        userSceneReloadTask?.cancel()

        userSceneReloadTask = Task { [weak self] in
            if !immediate {
                do {
                    try await Task.sleep(for: Self.sceneReloadDebounce)
                } catch {
                    return
                }
            }
            guard !Task.isCancelled, let self,
                  let request = self.makeSceneScanRequest(
                    allowsPlaceholderProbe: allowsPlaceholderProbe
                  ) else { return }
            let result = await self.performSceneScan(request)
            guard !Task.isCancelled, !result.cancelled,
                  generation == self.userSceneReloadGeneration else { return }
            self.applySceneScanResult(result, reason: reason)
        }
    }

    private func makeSceneScanRequest(
        allowsPlaceholderProbe: Bool = false
    ) -> SceneScanRequest? {
        guard let root = storeRoot else { return nil }
        return SceneScanRequest(
            root: root,
            cachedFiles: sceneFileCache,
            allowsPlaceholderProbe: allowsPlaceholderProbe,
            failedPlaceholderProbeURLs: failedPlaceholderProbeURLs
        )
    }

    private func performSceneScan(_ request: SceneScanRequest) async -> SceneScanResult {
        let worker = Task.detached(priority: .utility) {
            Self.scanUserScenes(request)
        }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private func applySceneScanResult(_ result: SceneScanResult, reason: String) {
        sceneFileCache = result.cachedFiles
        failedPlaceholderProbeURLs = result.failedPlaceholderProbeURLs
        if userScenes != result.scenes {
            withSceneRebuildBatch { userScenes = result.scenes }
        }
        print(
            "📂 Scene scan [\(reason)]: files=\(result.fileCount), " +
            "decoded=\(result.decodedCount), reused=\(result.reusedCount), " +
            "pending=\(result.pendingDownloadCount), " +
            "retryable=\(result.retryablePlaceholderCount)"
        )
        if result.retryablePlaceholderCount > 0 {
            scheduleUserSceneReload(
                reason: "placeholder-probe",
                allowsPlaceholderProbe: true
            )
        }
    }

    /// One-time migration of the legacy single-blob animation_scenes.json into the
    /// per-file store layout. Deferred until a store root exists so nothing is lost.
    private func migrateLegacyUserScenesIfNeeded() {
        guard storeRoot != nil else { return }
        let key = "Scene.legacyMigrated"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        var migrationSucceeded = true
        if FileManager.default.fileExists(atPath: scenesFileURL.path) {
            guard let data = try? Data(contentsOf: scenesFileURL),
                  let legacy = try? sceneDecoder.decode([AnimationScene].self, from: data) else {
                print("❌ Legacy animation migration deferred: animation_scenes.json could not be decoded")
                return
            }
            let migratable = legacy.filter { !DefaultScenes.isDefault($0.id) }
            let written = writeUserSceneFiles(migratable)
            if written.count != migratable.count {
                migrationSucceeded = false
            }
            print("📦 Migrated \(legacy.count) user scene(s) from legacy animation_scenes.json")
        }
        if migrationSucceeded {
            UserDefaults.standard.set(true, forKey: key)
        }
    }

    /// Shared encoder config for scene persistence and (off-main) export.
    nonisolated static func makePrettySceneEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
    
    // ═══════════════════════════════════════════════════════════════════════════
    // SCENE STORAGE
    // ═══════════════════════════════════════════════════════════════════════════
    
    // Coalesced persistence — avoids redundant UserDefaults writes during rapid edits
    @ObservationIgnored private var pendingSaveHidden = false
    @ObservationIgnored private var pendingSaveOverrides = false
    @ObservationIgnored private var saveCoalesceTask: Task<Void, Never>?
    @ObservationIgnored private var sceneRebuildBatchDepth = 0
    @ObservationIgnored private var pendingSceneRebuild = false
    
    /// User-created scenes (persisted to disk)
    private(set) var userScenes: [AnimationScene] = [] {
        didSet { sceneInputsDidChange() }
    }
    
    /// Default scene IDs the user has hidden (persisted via UserDefaults)
    private(set) var hiddenDefaultSceneIDs: Set<UUID> = [] {
        didSet { pendingSaveHidden = true; scheduleSaveFlush(); sceneInputsDidChange() }
    }
    
    /// User-edited copies of default scenes (persisted alongside user scenes).
    /// Key = default scene ID → Value = the user's edited version.
    /// When present, this overlay replaces the built-in original in the list.
    private(set) var editedDefaultOverrides: [UUID: AnimationScene] = [:] {
        didSet { pendingSaveOverrides = true; scheduleSaveFlush(); sceneInputsDidChange() }
    }
    
    /// The merged list exposed to the UI: visible defaults (possibly overridden) + user scenes.
    /// Cached — rebuilt automatically when underlying data changes.
    private(set) var scenes: [AnimationScene] = []

    private func sceneInputsDidChange() {
        guard sceneRebuildBatchDepth == 0 else {
            pendingSceneRebuild = true
            return
        }
        rebuildScenes()
    }

    private func withSceneRebuildBatch(flushAfter updates: () -> Void) {
        sceneRebuildBatchDepth += 1
        defer {
            sceneRebuildBatchDepth -= 1
            if sceneRebuildBatchDepth == 0, pendingSceneRebuild {
                pendingSceneRebuild = false
                rebuildScenes()
            }
        }
        updates()
    }
    
    private func rebuildScenes() {
        var result: [AnimationScene] = []
        for defaultScene in DefaultScenes.all() {
            guard !hiddenDefaultSceneIDs.contains(defaultScene.id) else { continue }
            if let override = editedDefaultOverrides[defaultScene.id] {
                result.append(override)
            } else {
                result.append(defaultScene)
            }
        }
        result.append(contentsOf: userScenes)
        scenes = result
    }
    
    /// Check whether a scene is a built-in default (original or edited overlay)
    func isDefaultScene(_ scene: AnimationScene) -> Bool {
        DefaultScenes.isDefault(scene.id)
    }
    
    /// Check whether a default scene has been edited by the user
    func isEditedDefault(_ scene: AnimationScene) -> Bool {
        editedDefaultOverrides[scene.id] != nil
    }
    
    /// Any default scenes that are currently hidden
    var hiddenDefaultScenes: [AnimationScene] {
        DefaultScenes.all().filter { hiddenDefaultSceneIDs.contains($0.id) }
    }
    
    /// Currently selected scene for editing/playback
    var currentScene: AnimationScene? {
        didSet {
            // Reset playhead when scene changes
            if currentScene?.id != oldValue?.id {
                let wasPlaying = playhead.state == .playing
                playhead.reset()
                playhead.sceneID = currentScene?.id
                uiPlayhead = playhead

                // A new scene starts with the saved iteration budget restored.
                // The user's manual override only takes effect after they touch
                // the slider during this scene's playback.
                userIterationBudgetOverride = false
                
                // Precompile pipelines for all keyframes in this scene
                precompilePipelinesForCurrentScene()
                
                // If playback was active, re-start on the new scene so
                // fractal type, gradient, safety-bubble, and other scene-level
                // settings are applied (they are only set inside play()).
                if wasPlaying && currentScene != nil {
                    play()
                }
            }
        }
    }

    /// When `true`, `applyKeyframe` skips writing the iteration budget
    /// (`baseFractalIterations` / `baseMaxRaySteps`) so the user's manual slider
    /// adjustment wins for the rest of this scene's playback. Reset to `false`
    /// each time the user switches to a different scene, so the scene's saved
    /// budget is restored on the first run.
    @ObservationIgnored var userIterationBudgetOverride: Bool = false

    /// Mark the iteration budget as user-overridden so animation playback
    /// stops clobbering it. Call from any UI control that mutates
    /// `baseFractalIterations` or `baseMaxRaySteps`.
    func markIterationBudgetUserOverridden() {
        userIterationBudgetOverride = true
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SCENE TRANSITION (smoothed scene switching)
    // ═══════════════════════════════════════════════════════════════════════════

    @ObservationIgnored private static let sceneTransitionDurationKey = "AnimationManager.sceneTransitionDuration"
    @ObservationIgnored private static let musicCueSceneSwitchEnabledKey = "AnimationManager.musicCueSceneSwitchEnabled"
    @ObservationIgnored private static let musicCueSceneGroupIDsKey = "AnimationManager.musicCueSceneGroupIDs"
    @ObservationIgnored private static let musicCueSceneSetsKey = "AnimationManager.musicCueSceneSets"
    @ObservationIgnored private static let activeMusicCueSceneSetIDKey = "AnimationManager.activeMusicCueSceneSetID"
    @ObservationIgnored private static let musicCueSceneSourcesKey = "AnimationManager.musicCueSceneSources"
    @ObservationIgnored private static let musicCueSceneTraversalModeKey = "AnimationManager.musicCueSceneTraversalMode"
    @ObservationIgnored private static let musicCueThresholdKey = "AnimationManager.musicCueThreshold"
    @ObservationIgnored private static let musicCueMinimumIntervalKey = "AnimationManager.musicCueMinimumInterval"
    @ObservationIgnored private static let defaultMusicCueThreshold: Float = 0.25
    @ObservationIgnored private static let defaultMusicCueMinimumInterval: TimeInterval = 2

    /// Seconds to ease live parameters toward a newly selected scene's starting
    /// point ("Same Scene Transition Time"). `0` = instant switch (legacy
    /// behavior). The actual easing is performed by `RenderSettings` when a new
    /// scene/preset is loaded; this property is the persisted slider value and
    /// is forwarded to the render settings so the smoothing knows the duration.
    var sceneTransitionDuration: TimeInterval = {
        if UserDefaults.standard.object(forKey: AnimationManager.sceneTransitionDurationKey) == nil {
            return 0.5
        }
        return UserDefaults.standard.double(forKey: AnimationManager.sceneTransitionDurationKey)
    }() {
        didSet {
            UserDefaults.standard.set(sceneTransitionDuration, forKey: Self.sceneTransitionDurationKey)
            renderSettings?.sceneTransitionDuration = Float(sceneTransitionDuration)
        }
    }

    /// When enabled, a qualifying audio onset advances to the next selected
    /// scene target. This is intentionally opt-in: live music commonly has
    /// more transient events than a scene transition should consume.
    var musicCueSceneSwitchEnabled: Bool =
        UserDefaults.standard.bool(forKey: AnimationManager.musicCueSceneSwitchEnabledKey) {
        didSet {
            UserDefaults.standard.set(musicCueSceneSwitchEnabled, forKey: Self.musicCueSceneSwitchEnabledKey)
            musicCueSceneSwitchGate.reset()
        }
    }

    /// The broader static-scene catalog and the production loading path live in
    /// `AppModel`; these seams let the animation-owned switcher include them
    /// without duplicating embedded-formula preparation or preset application.
    @ObservationIgnored var musicCueStaticSceneProvider: (() -> [FractalPreset])?
    @ObservationIgnored var musicCueStaticSceneLoadHandler: ((FractalPreset) -> Void)?
    @ObservationIgnored var musicCueCurrentStaticSceneIDProvider: (() -> UUID?)?

    /// The saved scene sets for music cues and quick scene stepping. Each set
    /// is a named subset of switchable scenes; the active set supplies the
    /// configured pool. On first launch after the update the pre-sets single
    /// configured group migrates into an initial "My Scenes" set.
    private(set) var musicCueSceneSets: [MusicCueSceneSet] = AnimationManager.loadStoredMusicCueSceneSets() {
        didSet {
            persistMusicCueSceneSets()
            let oldActiveTargets = oldValue.first { $0.id == activeMusicCueSceneSetID }?.targetIDs
            if oldActiveTargets != activeMusicCueSceneSet?.targetIDs {
                musicCueSceneSwitchGate.reset()
                resetMusicCueSceneNavigation()
            }
        }
    }

    /// Which saved set currently feeds the Configured Group pool. Nil when no
    /// sets exist yet.
    private(set) var activeMusicCueSceneSetID: UUID? = AnimationManager.loadStoredActiveMusicCueSceneSetID() {
        didSet {
            if let id = activeMusicCueSceneSetID {
                UserDefaults.standard.set(id.uuidString, forKey: Self.activeMusicCueSceneSetIDKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.activeMusicCueSceneSetIDKey)
            }
            guard oldValue != activeMusicCueSceneSetID else { return }
            persistMusicCueSceneSets()
            musicCueSceneSwitchGate.reset()
            resetMusicCueSceneNavigation()
        }
    }

    var activeMusicCueSceneSet: MusicCueSceneSet? {
        musicCueSceneSets.first { $0.id == activeMusicCueSceneSetID }
    }

    /// The active set's membership — the value every existing pool/traversal
    /// consumer reads. Empty when no set is active.
    var musicCueSceneGroupTargetIDs: Set<String> {
        activeMusicCueSceneSet?.targetIDs ?? []
    }

    private static func loadStoredMusicCueSceneSets() -> [MusicCueSceneSet] {
        if let data = UserDefaults.standard.data(forKey: musicCueSceneSetsKey),
           let sets = try? JSONDecoder().decode([MusicCueSceneSet].self, from: data) {
            return sets
        }
        let migrated = MusicCueSceneSet.migratingLegacyGroup(
            rawTargetIDs: UserDefaults.standard.stringArray(forKey: musicCueSceneGroupIDsKey) ?? []
        )
        // Persist the migration right away: the migrated set's id is freshly
        // generated, and the active-set loader below re-reads this storage, so
        // both reads must observe the same ids.
        if !migrated.isEmpty, let data = try? JSONEncoder().encode(migrated) {
            UserDefaults.standard.set(data, forKey: musicCueSceneSetsKey)
        }
        return migrated
    }

    private static func loadStoredActiveMusicCueSceneSetID() -> UUID? {
        let sets = loadStoredMusicCueSceneSets()
        if let raw = UserDefaults.standard.string(forKey: activeMusicCueSceneSetIDKey),
           let id = UUID(uuidString: raw),
           sets.contains(where: { $0.id == id }) {
            return id
        }
        return sets.first?.id
    }

    private func persistMusicCueSceneSets() {
        if let data = try? JSONEncoder().encode(musicCueSceneSets) {
            UserDefaults.standard.set(data, forKey: Self.musicCueSceneSetsKey)
        }
        // Mirror the active set into the pre-sets key so downgraded builds
        // still see a sensible configured group.
        UserDefaults.standard.set(
            musicCueSceneGroupTargetIDs.sorted(),
            forKey: Self.musicCueSceneGroupIDsKey
        )
    }

    /// The sources combined into the active scene pool. The original manual
    /// group remains the default, while library sources can be layered on top
    /// of it to create broader combinations without duplicating scene entries.
    var musicCueSceneSources: Set<MusicCueSceneSource> = {
        guard let rawValues = UserDefaults.standard.stringArray(
            forKey: AnimationManager.musicCueSceneSourcesKey
        ) else {
            return [.configuredGroup]
        }
        return Set(rawValues.compactMap(MusicCueSceneSource.init(rawValue:)))
    }() {
        didSet {
            UserDefaults.standard.set(
                musicCueSceneSources.map(\.rawValue).sorted(),
                forKey: Self.musicCueSceneSourcesKey
            )
            musicCueSceneSwitchGate.reset()
            resetMusicCueSceneNavigation()
        }
    }

    /// Ordered, shuffle-bag, and random traversal all operate on the same
    /// selected pool. The bag/history are reset whenever this choice changes.
    var musicCueSceneTraversalMode: MusicCueSceneTraversalMode = {
        guard let rawValue = UserDefaults.standard.string(
            forKey: AnimationManager.musicCueSceneTraversalModeKey
        ), let mode = MusicCueSceneTraversalMode(rawValue: rawValue) else {
            return .ordered
        }
        return mode
    }() {
        didSet {
            UserDefaults.standard.set(
                musicCueSceneTraversalMode.rawValue,
                forKey: Self.musicCueSceneTraversalModeKey
            )
            resetMusicCueSceneNavigation()
        }
    }

    /// Minimum normalized onset strength required to count as a scene cue.
    var musicCueThreshold: Float = {
        guard UserDefaults.standard.object(forKey: AnimationManager.musicCueThresholdKey) != nil else {
            return AnimationManager.defaultMusicCueThreshold
        }
        let stored = UserDefaults.standard.float(forKey: AnimationManager.musicCueThresholdKey)
        return stored.isFinite
            ? stored.clamped(to: 0.05...1)
            : AnimationManager.defaultMusicCueThreshold
    }() {
        didSet {
            let normalized = musicCueThreshold.isFinite
                ? musicCueThreshold.clamped(to: 0.05...1)
                : Self.defaultMusicCueThreshold
            guard normalized == musicCueThreshold else {
                musicCueThreshold = normalized
                return
            }
            UserDefaults.standard.set(normalized, forKey: Self.musicCueThresholdKey)
            musicCueSceneSwitchGate.reset()
        }
    }

    /// Cooldown between cue-driven changes. A real music track can emit many
    /// onsets per bar, so this keeps the scene progression intentional.
    var musicCueMinimumInterval: TimeInterval = {
        guard UserDefaults.standard.object(forKey: AnimationManager.musicCueMinimumIntervalKey) != nil else {
            return AnimationManager.defaultMusicCueMinimumInterval
        }
        let stored = UserDefaults.standard.double(forKey: AnimationManager.musicCueMinimumIntervalKey)
        return stored.isFinite
            ? stored.clamped(to: 0...30)
            : AnimationManager.defaultMusicCueMinimumInterval
    }() {
        didSet {
            let normalized = musicCueMinimumInterval.isFinite
                ? musicCueMinimumInterval.clamped(to: 0...30)
                : Self.defaultMusicCueMinimumInterval
            guard normalized == musicCueMinimumInterval else {
                musicCueMinimumInterval = normalized
                return
            }
            UserDefaults.standard.set(normalized, forKey: Self.musicCueMinimumIntervalKey)
            musicCueSceneSwitchGate.reset()
        }
    }

    @ObservationIgnored private var musicCueSceneSwitchGate = MusicCueSceneSwitchGate()

    /// A one-keyframe animation cannot play through a transition, so it stays
    /// available elsewhere in the library but is skipped by the cue switcher.
    private var musicCueGroupAvailableAnimationScenes: [AnimationScene] {
        scenes.filter { $0.keyframes.count >= 2 }
    }

    /// Both animation sequences and the static preset catalog can feed the
    /// switcher. This is the complete catalog; the source toggles below derive
    /// the active pool from it without constructing duplicate scene objects.
    var musicCueGroupAvailableTargets: [MusicCueSceneTarget] {
        let animations = musicCueGroupAvailableAnimationScenes.map { scene in
            MusicCueSceneTarget(
                kind: .animation,
                sourceID: scene.id,
                name: scene.name,
                detail: "\(scene.keyframes.count) keyframes",
                tags: scene.tags
            )
        }
        let staticScenes = (musicCueStaticSceneProvider?() ?? [])
            .filter { $0.name != "__lastState__" }
            .map { preset in
                MusicCueSceneTarget(
                    kind: .staticScene,
                sourceID: preset.id,
                name: preset.name,
                detail: preset.fractalType.displayName,
                tags: preset.tags
                )
            }
        return animations + staticScenes
    }

    /// Targets eligible for cue progression in stable source order. The manual
    /// group is laid down first, followed by any enabled libraries; an id is
    /// retained only once so overlapping selections never duplicate a scene.
    private var musicCueEligibleTargets: [MusicCueSceneTarget] {
        MusicCueSceneGroupSequence.eligibleTargets(
            sources: musicCueSceneSources,
            availableTargets: musicCueGroupAvailableTargets,
            configuredGroupTargetIDs: musicCueSceneGroupTargetIDs
        )
    }

    var musicCueSceneGroupSummary: String {
        let count = musicCueEligibleTargets.count
        return count == 1 ? "1 scene" : "\(count) scenes"
    }

    var musicCueSceneSourceSummary: String {
        let names = MusicCueSceneSource.allCases
            .filter { musicCueSceneSources.contains($0) }
            .map(\.shortDisplayName)
        return names.isEmpty ? "No sources" : names.joined(separator: " + ")
    }

    var musicCueSceneSelectionWarning: String? {
        guard !musicCueSceneSources.isEmpty else {
            return "Choose at least one scene source."
        }
        guard musicCueEligibleTargets.count > 1 else {
            if musicCueSceneSources == Set([.configuredGroup]) {
                if musicCueSceneSets.isEmpty {
                    return "Create a scene set with at least two scenes."
                }
                return "Add at least two scenes to the active set."
            }
            return "This source combination needs at least two available scenes."
        }
        return nil
    }

    func isMusicCueSceneSourceEnabled(_ source: MusicCueSceneSource) -> Bool {
        musicCueSceneSources.contains(source)
    }

    func setMusicCueSceneSource(_ source: MusicCueSceneSource, isEnabled: Bool) {
        var sources = musicCueSceneSources
        if isEnabled {
            sources.insert(source)
        } else {
            sources.remove(source)
        }
        musicCueSceneSources = sources
    }

    // MARK: Scene set management

    func musicCueSceneSet(id: UUID) -> MusicCueSceneSet? {
        musicCueSceneSets.first { $0.id == id }
    }

    /// Creates a new set and makes it active so the editor and the switcher
    /// immediately operate on it.
    @discardableResult
    func createMusicCueSceneSet(named name: String? = nil) -> MusicCueSceneSet {
        let set = MusicCueSceneSet(name: name ?? defaultMusicCueSceneSetName())
        musicCueSceneSets.append(set)
        activeMusicCueSceneSetID = set.id
        return set
    }

    private func defaultMusicCueSceneSetName() -> String {
        let existing = Set(musicCueSceneSets.map(\.name))
        var index = musicCueSceneSets.count + 1
        var candidate = "Set \(index)"
        while existing.contains(candidate) {
            index += 1
            candidate = "Set \(index)"
        }
        return candidate
    }

    func activateMusicCueSceneSet(_ id: UUID) {
        guard musicCueSceneSets.contains(where: { $0.id == id }) else { return }
        activeMusicCueSceneSetID = id
    }

    func renameMusicCueSceneSet(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        mutateMusicCueSceneSet(id) { $0.name = trimmed }
    }

    func deleteMusicCueSceneSet(_ id: UUID) {
        guard let index = musicCueSceneSets.firstIndex(where: { $0.id == id }) else { return }
        musicCueSceneSets.remove(at: index)
        if activeMusicCueSceneSetID == id {
            activeMusicCueSceneSetID = musicCueSceneSets.first?.id
        }
    }

    /// Attach (or detach, with nil) the song that starts with this set.
    func setAttachedSong(_ song: SongAttachment?, forMusicCueSceneSet id: UUID) {
        mutateMusicCueSceneSet(id) { $0.attachedSong = song }
    }

    /// Start a set: make it active, ensure the configured pool is a source,
    /// and — when a song is attached — begin playback with cue-driven scene
    /// advancement enabled, entering the set right away so the switch to the
    /// curated visuals is immediate.
    func startMusicCueSceneSet(_ id: UUID) {
        guard let set = musicCueSceneSet(id: id) else { return }
        activateMusicCueSceneSet(id)
        if !musicCueSceneSources.contains(.configuredGroup) {
            var sources = musicCueSceneSources
            sources.insert(.configuredGroup)
            musicCueSceneSources = sources
        }
        guard let song = set.attachedSong else { return }
        musicCueSceneSwitchEnabled = true
        playSongHandler?(song)
        if let currentID = currentMusicCueSceneTargetID,
           !set.targetIDs.contains(currentID) {
            _ = stepMusicCueSceneGroup(by: 1)
        } else if currentMusicCueSceneTargetID == nil {
            _ = stepMusicCueSceneGroup(by: 1)
        }
    }

    private func mutateMusicCueSceneSet(_ id: UUID, _ transform: (inout MusicCueSceneSet) -> Void) {
        guard let index = musicCueSceneSets.firstIndex(where: { $0.id == id }) else { return }
        var set = musicCueSceneSets[index]
        transform(&set)
        musicCueSceneSets[index] = set
    }

    // MARK: Set membership editing

    func isMusicCueTargetSelected(_ target: MusicCueSceneTarget, in setID: UUID) -> Bool {
        musicCueSceneSet(id: setID)?.targetIDs.contains(target.id) ?? false
    }

    func setMusicCueTarget(_ target: MusicCueSceneTarget, isSelected: Bool, in setID: UUID) {
        mutateMusicCueSceneSet(setID) { set in
            if isSelected {
                set.targetIDs.insert(target.id)
            } else {
                set.targetIDs.remove(target.id)
            }
        }
    }

    func selectMusicCueTargets(_ targets: [MusicCueSceneTarget], in setID: UUID) {
        guard !targets.isEmpty else { return }
        mutateMusicCueSceneSet(setID) { $0.targetIDs.formUnion(targets.map(\.id)) }
    }

    func clearMusicCueTargets(_ targets: [MusicCueSceneTarget], in setID: UUID) {
        guard !targets.isEmpty else { return }
        mutateMusicCueSceneSet(setID) { $0.targetIDs.subtract(targets.map(\.id)) }
    }

    func selectAllMusicCueTargets(in setID: UUID) {
        let all = musicCueGroupAvailableTargets.map(\.id)
        mutateMusicCueSceneSet(setID) { $0.targetIDs.formUnion(all) }
    }

    func clearMusicCueSceneSetTargets(in setID: UUID) {
        mutateMusicCueSceneSet(setID) { $0.targetIDs.removeAll() }
        if setID == activeMusicCueSceneSetID {
            lastMusicCueSceneTargetID = nil
        }
    }

    @ObservationIgnored private var lastMusicCueSceneTargetID: String?
    @ObservationIgnored private var musicCueShuffleBag: [String] = []
    @ObservationIgnored private var musicCueSceneHistory: [String] = []
    @ObservationIgnored private var musicCueSceneHistoryIndex: Int = -1

    private func resetMusicCueSceneNavigation() {
        musicCueShuffleBag.removeAll(keepingCapacity: true)
        musicCueSceneHistory.removeAll(keepingCapacity: true)
        musicCueSceneHistoryIndex = -1
    }

    private var currentMusicCueSceneTargetID: String? {
        if let animationID = currentScene?.id {
            return MusicCueSceneTarget.storageID(kind: .animation, sourceID: animationID)
        }
        if let staticSceneID = musicCueCurrentStaticSceneIDProvider?() {
            return MusicCueSceneTarget.storageID(kind: .staticScene, sourceID: staticSceneID)
        }
        return lastMusicCueSceneTargetID
    }

    private var forwardHistoryMusicCueTargetID: String? {
        guard musicCueSceneTraversalMode != .ordered,
              let currentID = currentMusicCueSceneTargetID,
              musicCueSceneHistory.indices.contains(musicCueSceneHistoryIndex),
              musicCueSceneHistory[musicCueSceneHistoryIndex] == currentID else {
            return nil
        }
        let forwardIndex = musicCueSceneHistoryIndex + 1
        guard musicCueSceneHistory.indices.contains(forwardIndex) else { return nil }
        return musicCueSceneHistory[forwardIndex]
    }

    var nextMusicCueSceneName: String? {
        let candidates = musicCueEligibleTargets
        guard candidates.count > 1 else { return nil }

        switch musicCueSceneTraversalMode {
        case .ordered:
            guard let currentID = currentMusicCueSceneTargetID,
                  let currentIndex = candidates.firstIndex(where: { $0.id == currentID }) else {
                return candidates.first?.name
            }
            return candidates[(currentIndex + 1) % candidates.count].name

        case .shuffleBag:
            if let historyID = forwardHistoryMusicCueTargetID,
               let historyTarget = candidates.first(where: { $0.id == historyID }) {
                return historyTarget.name
            }
            if let shuffledID = musicCueShuffleBag.last,
               let shuffledTarget = candidates.first(where: { $0.id == shuffledID }) {
                return shuffledTarget.name
            }
            return "Shuffled scene"

        case .random:
            if let historyID = forwardHistoryMusicCueTargetID,
               let historyTarget = candidates.first(where: { $0.id == historyID }) {
                return historyTarget.name
            }
            return "Random scene"
        }
    }

    var canStepMusicCueSceneGroup: Bool {
        musicCueEligibleTargets.count > 1 && !isRecording
    }

    var canStepMusicCueSceneGroupBackward: Bool {
        guard canStepMusicCueSceneGroup else { return false }
        guard musicCueSceneTraversalMode != .ordered else { return true }
        guard let currentID = currentMusicCueSceneTargetID,
              musicCueSceneHistory.indices.contains(musicCueSceneHistoryIndex),
              musicCueSceneHistory[musicCueSceneHistoryIndex] == currentID else {
            return false
        }
        return musicCueSceneHistoryIndex > 0
    }

    var canAdvanceScenesOnMusicCue: Bool {
        musicCueSceneSwitchEnabled && canStepMusicCueSceneGroup
    }

    /// Receives the coherent audio snapshot published by `AudioHub`. The gate
    /// only opens for a threshold crossing, and `stepMusicCueSceneGroup(by:)`
    /// applies the selected source and traversal mechanisms for automatic and
    /// manual scene changes alike.
    func consumeMusicCue(_ snapshot: AudioFeatureSnapshot) {
        guard canStepMusicCueSceneGroup else {
            musicCueSceneSwitchGate.reset()
            return
        }
        guard musicCueSceneSwitchGate.consume(
            onset: snapshot.mixed.onset,
            isEnabled: musicCueSceneSwitchEnabled,
            isAudioActive: snapshot.isActive,
            threshold: musicCueThreshold,
            minimumInterval: musicCueMinimumInterval,
            at: snapshot.timestamp
        ) else {
            return
        }

        _ = stepMusicCueSceneGroup(by: 1)
    }

    /// Step through the active pool. This is shared by automatic music cues and
    /// the canvas left/right-arrow quick controls on macOS and iPadOS.
    @discardableResult
    func stepMusicCueSceneGroup(by step: Int) -> MusicCueSceneTarget? {
        guard !isRecording, step != 0 else { return nil }
        let candidates = musicCueEligibleTargets
        guard candidates.count > 1 else { return nil }

        let resolution: (target: MusicCueSceneTarget, historyIndex: Int?)?
        if musicCueSceneTraversalMode != .ordered,
           let historyResolution = musicCueHistoryResolution(
               for: step,
               candidates: candidates
           ) {
            resolution = historyResolution
        } else {
            guard step > 0 || musicCueSceneTraversalMode == .ordered,
                  let target = newMusicCueTarget(
                      for: step,
                      candidates: candidates
                  ) else {
                return nil
            }
            resolution = (target, nil)
        }

        guard let resolution,
              activateMusicCueSceneTarget(resolution.target) else {
            return nil
        }

        if let historyIndex = resolution.historyIndex {
            musicCueSceneHistoryIndex = historyIndex
        } else if musicCueSceneTraversalMode != .ordered {
            recordMusicCueSceneHistory(resolution.target.id)
        }
        lastMusicCueSceneTargetID = resolution.target.id
        return resolution.target
    }

    private func musicCueHistoryResolution(
        for step: Int,
        candidates: [MusicCueSceneTarget]
    ) -> (target: MusicCueSceneTarget, historyIndex: Int)? {
        guard let currentID = currentMusicCueSceneTargetID,
              musicCueSceneHistory.indices.contains(musicCueSceneHistoryIndex),
              musicCueSceneHistory[musicCueSceneHistoryIndex] == currentID else {
            return nil
        }

        let nextHistoryIndex = musicCueSceneHistoryIndex + (step > 0 ? 1 : -1)
        guard musicCueSceneHistory.indices.contains(nextHistoryIndex) else { return nil }
        let targetID = musicCueSceneHistory[nextHistoryIndex]
        guard let target = candidates.first(where: { $0.id == targetID }) else { return nil }
        return (target, nextHistoryIndex)
    }

    private func newMusicCueTarget(
        for step: Int,
        candidates: [MusicCueSceneTarget]
    ) -> MusicCueSceneTarget? {
        switch musicCueSceneTraversalMode {
        case .ordered:
            guard let nextIndex = MusicCueSceneGroupSequence.nextIndex(
                currentID: currentMusicCueSceneTargetID,
                candidateIDs: candidates.map(\.id),
                step: step
            ) else {
                return nil
            }
            return candidates[nextIndex]

        case .shuffleBag:
            return nextShuffledMusicCueTarget(from: candidates)

        case .random:
            let currentID = currentMusicCueSceneTargetID
            let candidateIDs = MusicCueSceneGroupSequence.nonRepeatingCandidateIDs(
                currentID: currentID,
                candidateIDs: candidates.map(\.id)
            )
            return candidates
                .filter { candidateIDs.contains($0.id) }
                .randomElement()
        }
    }

    private func nextShuffledMusicCueTarget(
        from candidates: [MusicCueSceneTarget]
    ) -> MusicCueSceneTarget? {
        let currentID = currentMusicCueSceneTargetID
        let validIDs = Set(candidates.map(\.id))
        musicCueShuffleBag.removeAll { identifier in
            !validIDs.contains(identifier) || identifier == currentID
        }

        if musicCueShuffleBag.isEmpty {
            musicCueShuffleBag = MusicCueSceneGroupSequence.nonRepeatingCandidateIDs(
                currentID: currentID,
                candidateIDs: candidates.map(\.id)
            ).shuffled()
        }

        guard let targetID = musicCueShuffleBag.popLast() else { return nil }
        return candidates.first(where: { $0.id == targetID })
    }

    private func recordMusicCueSceneHistory(_ targetID: String) {
        if musicCueSceneHistoryIndex >= 0,
           musicCueSceneHistoryIndex < musicCueSceneHistory.count - 1 {
            musicCueSceneHistory.removeSubrange((musicCueSceneHistoryIndex + 1)..<musicCueSceneHistory.count)
        }
        musicCueSceneHistory.append(targetID)
        musicCueSceneHistoryIndex = musicCueSceneHistory.count - 1
    }

    private func activateMusicCueSceneTarget(_ target: MusicCueSceneTarget) -> Bool {
        switch target.kind {
        case .animation:
            guard let nextScene = scenes.first(where: { $0.id == target.sourceID }) else { return false }
            let wasPlaying = playhead.state == .playing

            // Reuse the same RenderSettings transition used for static scene loads.
            // `currentScene` restarts active playback in its observer; when stopped,
            // start the newly selected scene explicitly after it is installed.
            renderSettings?.beginSceneTransitionSnapshot()
            currentScene = nextScene
            if !wasPlaying {
                play()
            }
            renderSettings?.commitSceneTransition()
            return true

        case .staticScene:
            guard let preset = musicCueStaticSceneProvider?().first(where: { $0.id == target.sourceID }),
                  let loadStaticScene = musicCueStaticSceneLoadHandler else {
                return false
            }
            // AppModel owns static-preset loading so custom formulas, gesture
            // overrides, and the existing eased scene-transition path stay intact.
            loadStaticScene(preset)
            return true
        }
    }

    /// Convenience entry point for an explicit forward cue or UI action.
    @discardableResult
    func advanceToNextSceneForMusicCue() -> MusicCueSceneTarget? {
        stepMusicCueSceneGroup(by: 1)
    }
    
    // ═══════════════════════════════════════════════════════════════════════════
    // PLAYBACK STATE
    // ═══════════════════════════════════════════════════════════════════════════
    
    /// Internal playhead — drives precise per-frame animation timing.
    /// Marked @ObservationIgnored so 90Hz writes don't trigger SwiftUI invalidation.
    @ObservationIgnored var playhead = AnimationPlayhead()
    
    /// Throttled snapshot of playhead for SwiftUI views (updated ~15Hz).
    /// Views should read this instead of `playhead` to avoid per-frame re-renders.
    var uiPlayhead = AnimationPlayhead()
    @ObservationIgnored private var uiThrottleCounter: Int = 0
    private static let uiThrottleInterval: Int = 6   // update every ~6 frames ≈ 15Hz at 90fps
    
    /// Global easing function for all transitions
    /// Default to .smooth for continuous motion through keyframes (no stopping)
    var easingFunction: EasingFunction = .smooth
    
    /// Playback speed multiplier (1.0 = normal, 2.0 = double speed, 0.5 = half speed)
    var playbackSpeed: Double = 1.0

    /// True when current playback should auto-stop once an attached song finishes.
    @ObservationIgnored private var stopWhenAttachedSongEnds = false
    @ObservationIgnored private var attachedSongFadeVelocityScale: Double = 1.0
    private let minimumAttachedSongFadeVelocityScale: Double = 0.05
    
    /// Whether animation is currently playing.
    /// Reads from observed `uiPlayhead` so SwiftUI correctly tracks state changes.
    var isPlaying: Bool {
        uiPlayhead.state == .playing
    }
    
    // ═══════════════════════════════════════════════════════════════════════════
    // LIVE SESSION RECORDING
    // ═══════════════════════════════════════════════════════════════════════════
    
    /// Whether a live session recording is currently capturing render settings.
    var isRecording: Bool = false
    
    /// Accumulated timestamped samples during recording.
    @ObservationIgnored private var recordingSamples: [(time: TimeInterval, keyframe: AnimationKeyframe)] = []
    
    /// When recording started (monotonic clock)
    @ObservationIgnored private var recordingStartTime: TimeInterval = 0
    
    /// Background task driving the sampling loop
    @ObservationIgnored private var recordingTask: Task<Void, Never>?

    @ObservationIgnored private var recordingFractalType: FractalModelType?

    /// Non-animated scene state is captured at record-start, not record-stop,
    /// so changing an animated lane during the take cannot accidentally become
    /// the baseline for the finished scene.
    @ObservationIgnored private var recordingBaseline: SceneState?
    @ObservationIgnored private var recordingEmbeddedFormula: EmbeddedFormula?
    
    /// Sample rate for live recording (samples per second).
    private static let recordingSampleRate: Double = 10.0

    // ═══════════════════════════════════════════════════════════════════════════
    // RENDER SETTINGS REFERENCE
    // ═══════════════════════════════════════════════════════════════════════════
    
    private weak var renderSettings: RenderSettings?

    @inline(__always)
    private func segmentDuration(for keyframes: [AnimationKeyframe], toIndex: Int) -> TimeInterval {
        let duration = toIndex == 0 ? keyframes[0].duration : keyframes[toIndex].duration
        return duration > 0 ? duration : Self.defaultSegmentDuration
    }
    
    /// Callback to prepare shader pipeline for specific iteration/step values
    /// Set this from AppModel to enable precompilation for animation keyframes
    var preparePipelineHandler: ((Int, Int) -> Void)?
    
    /// Callback to start playing the scene's attached song.
    /// Set from AppModel — receives the SongAttachment to play.
    var playSongHandler: ((SongAttachment) -> Void)?

    /// Callback to stop any scene-driven song playback.
    /// Set from AppModel.
    var stopSongHandler: (() -> Void)?
    
    // ═══════════════════════════════════════════════════════════════════════════
    // iCLOUD DROP-IN WATCHER
    // ═══════════════════════════════════════════════════════════════════════════

    /// Metadata query watching the iCloud Animations/ folder for new scene files.
    @ObservationIgnored private var iCloudQuery: NSMetadataQuery?
    /// The Animations/ folder URL currently being watched.
    @ObservationIgnored private var iCloudAnimDir: URL?
    @ObservationIgnored private var iCloudQueryObservers: [NSObjectProtocol] = []

    /// Start watching `animDir` (the iCloud Drive Animations/ subfolder) for new
    /// `.threshanim` / `.threshanimv` files. Idempotent — calling again with the
    /// same URL is a no-op; calling with a new URL restarts the query.
    func startWatchingiCloudAnimations(animDir: URL) {
        guard iCloudAnimDir != animDir else { return }
        stopWatchingiCloudAnimations()
        iCloudAnimDir = animDir

        // Do an immediate import pass for files already sitting in the folder.
        importScenesFromiCloud(animDir: animDir)

        // Then set up an NSMetadataQuery to catch files added later (including
        // those that are still downloading from the cloud).
        let query = NSMetadataQuery()
        // Scope Spotlight to the resolved Animations folder itself; using the
        // broad ubiquitous-documents scope can trigger sandboxed file-provider
        // permission noise for unrelated iCloud content on macOS.
        query.searchScopes = [animDir]
        // Restrict to files inside our Animations subfolder.
        query.predicate = NSPredicate(
            format: "%K BEGINSWITH %@ AND (%K ENDSWITH '.threshanim' OR %K ENDSWITH '.threshanimv')",
            NSMetadataItemPathKey, animDir.path,
            NSMetadataItemFSNameKey,
            NSMetadataItemFSNameKey
        )
        query.operationQueue = .main

        let finishObserver = NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidFinishGathering,
            object: query,
            queue: .main
        ) { [weak self] _ in
                Task { @MainActor in
                    self?.handleiCloudQueryUpdate()
                }
        }
        let updateObserver = NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidUpdate,
            object: query,
            queue: .main
        ) { [weak self] _ in
                Task { @MainActor in
                    self?.handleiCloudQueryUpdate()
                }
        }
        iCloudQueryObservers = [finishObserver, updateObserver]

        query.start()
        iCloudQuery = query
        print("☁️ Watching iCloud Animations folder: \(animDir.lastPathComponent)")
    }

    func stopWatchingiCloudAnimations() {
        if let query = iCloudQuery {
            query.stop()
            iCloudQuery = nil
        }
        for observer in iCloudQueryObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        iCloudQueryObservers.removeAll()
        iCloudAnimDir = nil
    }

    private func handleiCloudQueryUpdate() {
        // The Animations/ folder is the source of truth — re-mirror it so files
        // added OR removed in iCloud Drive both reflect (the old additive import
        // could never reflect a delete).
        scheduleUserSceneReload(reason: "iCloud metadata")
    }

    /// Re-mirror the store's Animations/ folder into `userScenes`. Kept for the
    /// watcher's immediate first pass; delegates to `reloadUserScenesFromStore`.
    func importScenesFromiCloud(animDir: URL) {
        scheduleUserSceneReload(reason: "iCloud watcher start")
    }

    @discardableResult
    func importScene(from url: URL) -> AnimationScene? {
        do {
            return importScene(try decodeScene(from: url))
        } catch {
            print("❌ Failed to import scene from \(url.lastPathComponent): \(error)")
            return nil
        }
    }

    func decodeScene(from url: URL) throws -> AnimationScene {
        let data = try Data(contentsOf: url)
        return try sceneDecoder.decode(AnimationScene.self, from: data)
    }

    @discardableResult
    func importScene(_ scene: AnimationScene) -> AnimationScene {
        if let existingUserIndex = userScenes.firstIndex(where: { $0.id == scene.id }) {
            userScenes[existingUserIndex] = scene
            saveScenes()
            return scene
        }

        if let existingScene = scenes.first(where: { $0.id == scene.id }) {
            return existingScene
        }

        userScenes.append(scene)
        saveScenes()
        return scene
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // FILE STORAGE
    // ═══════════════════════════════════════════════════════════════════════════
    
    private let scenesFileName = "animation_scenes.json"
    
    private var scenesFileURL: URL {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documentsPath.appendingPathComponent(scenesFileName)
    }

    /// Timestamped backups of user scenes — always local, mode-independent safety
    /// net (mirrors PresetManager, under the shared Backups root).
    private var scenesBackupsDirectory: URL {
        let dir = StorageLocation.shared.backupsRoot.appendingPathComponent("Scenes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var lastSceneBackupAt: Date?
    private let sceneBackupInterval: TimeInterval = 60
    private let maxSceneBackupCount = 20

    private static let sceneBackupTimestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Write a timestamped backup of the given scene data (throttled).
    private func writeSceneBackup(data: Data) {
        let now = Date()
        if let lastSceneBackupAt, now.timeIntervalSince(lastSceneBackupAt) < sceneBackupInterval {
            return
        }
        lastSceneBackupAt = now
        let stamp = Self.sceneBackupTimestampFormatter.string(from: now)
        let url = scenesBackupsDirectory.appendingPathComponent("scenes-\(stamp).json")
        do {
            try data.write(to: url, options: .atomic)
            pruneSceneBackups(keeping: maxSceneBackupCount)
        } catch {
            print("❌ Failed to write scenes backup: \(error)")
        }
    }

    /// Force an immediate backup of the CURRENT user scenes, bypassing the
    /// throttle. Call before any destructive replace (e.g. iCloud restore).
    func backupCurrentScenesNow() {
        guard !userScenes.isEmpty else { return }
        do {
            let data = try prettySceneEncoder.encode(userScenes)
            lastSceneBackupAt = nil // defeat the throttle for this safety snapshot
            writeSceneBackup(data: data)
        } catch {
            print("❌ Failed to write pre-restore scenes backup: \(error)")
        }
    }

    private func pruneSceneBackups(keeping count: Int) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: scenesBackupsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return }
        let sorted = files.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da > db
        }
        for url in sorted.dropFirst(count) {
            try? FileManager.default.removeItem(at: url)
        }
    }


    // ═══════════════════════════════════════════════════════════════════════════
    // INITIALIZATION
    // ═══════════════════════════════════════════════════════════════════════════
    
    init(renderSettings: RenderSettings? = nil) {
        self.renderSettings = renderSettings
        renderSettings?.sceneTransitionDuration = Float(sceneTransitionDuration)
        loadScenes()
        rebuildScenes()
        // The store folder is the source of truth: reload user scenes when the
        // active root resolves (iCloud discovery) or the user switches storage mode.
        for name in [StorageLocation.rootResolvedNotification, StorageLocation.modeChangedNotification] {
            let observer = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.flushPendingRootWrites()
                    self?.loadScenes()
                }
            }
            storageObservers.append(observer)
        }
    }

    deinit {
        storageObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SCENE MANAGEMENT
    // ═══════════════════════════════════════════════════════════════════════════

    /// Capture the full scene-owned baseline. Presentation is user-owned and is
    /// intentionally excluded; Mixed is an explicit editor opt-in on the scene.
    private func captureSceneBaseline(from settings: RenderSettings) -> SceneState {
        SceneState(capturing: settings)
    }

    /// Mirror the baseline into the old flat animation fields. Current builds
    /// restore from `baseline`; populating these keeps new exports useful in
    /// older builds that do not know about SceneState yet.
    private func populateLegacySceneFields(_ scene: inout AnimationScene,
                                           from baseline: SceneState) {
        let gradient = baseline.color.gradientState
        scene.gradientPreset = gradient.gradientPreset
        scene.colorMappingMode = gradient.gradient.mappingMode
        scene.gradientRepeat = gradient.gradient.repeatCount
        scene.gradientOffset = gradient.gradient.offset
        scene.gradientSmoothing = gradient.gradient.smoothing
        scene.colorSchemeSaturation = baseline.color.colorSchemeSaturation
        scene.colorSchemeContrast = baseline.color.colorSchemeContrast
        scene.colorSchemeGamma = baseline.color.colorSchemeGamma
        scene.colorSchemeVibrance = baseline.color.colorSchemeVibrance
        scene.colorSchemeCurve = baseline.color.colorSchemeCurve
        scene.colorSchemeShadows = baseline.color.colorSchemeShadows
        scene.colorSchemeHighlights = baseline.color.colorSchemeHighlights
        scene.lightingSoftness = baseline.color.lightingSoftness
        scene.safetyBubbleEnabled = baseline.safetyBubble.enabled
        scene.safetyBubbleRadius = baseline.safetyBubble.radius
        scene.safetyBubbleShape = baseline.safetyBubble.shape
        scene.safetyBubbleBlend = baseline.safetyBubble.strength
        scene.spaceWarpOps = baseline.space.warpStack.isEmpty ? nil : baseline.space.warpStack
    }
    
    /// Create a new scene and add current settings as first keyframe
    func createScene(name: String) -> AnimationScene {
        guard let settings = renderSettings else {
            let scene = AnimationScene(name: name)
            userScenes.append(scene)
            saveScenes()
            return scene
        }
        
        var initialKeyframe = AnimationKeyframe(from: settings, name: "Start", duration: 0)
        initialKeyframe.duration = 0  // First keyframe is the starting point
        
        var scene = AnimationScene(name: name, initialKeyframe: initialKeyframe, fractalType: settings.fractalType)
        let baseline = captureSceneBaseline(from: settings)
        scene.baseline = baseline
        scene.embeddedFormula = AppModel.shared?.activeEmbeddedFormula
        populateLegacySceneFields(&scene, from: baseline)
        userScenes.append(scene)
        saveScenes()
        
        print("🎬 Created scene '\(name)' with initial keyframe")
        return scene
    }
    
    /// Delete a scene.
    /// Default scenes are hidden (not destroyed) — they can be restored.
    /// User scenes are permanently removed.
    func deleteScene(_ scene: AnimationScene) {
        if DefaultScenes.isDefault(scene.id) {
            // Hide the default; also discard any edited overlay
            withSceneRebuildBatch {
                hiddenDefaultSceneIDs.insert(scene.id)
                editedDefaultOverrides.removeValue(forKey: scene.id)
            }
            print("👁️‍🗨️ Hid default scene '\(scene.name)'")
        } else {
            userScenes.removeAll { $0.id == scene.id }
            pendingRootWrites.removeValue(forKey: scene.id)
            // Removing the file IS the deletion — under folder-as-truth that
            // removal is what propagates (iCloud syncs the delete to other devices).
            removeUserSceneFile(id: scene.id)
            saveScenes()
            print("🗑️ Deleted scene '\(scene.name)'")
        }
        
        if currentScene?.id == scene.id {
            currentScene = nil
            stop()
        }
    }
    
    /// Restore a previously hidden default scene
    func restoreDefaultScene(_ id: UUID) {
        hiddenDefaultSceneIDs.remove(id)
        print("♻️ Restored default scene")
    }
    
    /// Reset an edited default back to the built-in original
    func resetDefaultScene(_ id: UUID) {
        editedDefaultOverrides.removeValue(forKey: id)
        // If this scene is currently selected, update it to the original
        if currentScene?.id == id {
            currentScene = DefaultScenes.all().first { $0.id == id }
        }
        print("🔄 Reset default scene to original")
    }
    
    /// Update a scene (after editing keyframes).
    /// For default scenes, saves an edited overlay that preserves the original underneath.
    func updateScene(_ scene: AnimationScene) {
        var updated = scene
        updated.tags = SceneTagging.normalized(updated.tags)
        updated.modifiedAt = Date()
        
        if DefaultScenes.isDefault(scene.id) {
            // Store as an edited overlay — the original stays intact
            editedDefaultOverrides[scene.id] = updated
            print("💾 Saved edited overlay for default scene '\(scene.name)'")
        } else if let index = userScenes.firstIndex(where: { $0.id == scene.id }) {
            userScenes[index] = updated
            saveScenes()
            print("💾 Updated scene '\(scene.name)'")
        }
        
        // Also update currentScene if it's the same
        if currentScene?.id == scene.id {
            currentScene = updated
        }
    }
    
    /// Remove a keyframe from scene
    func removeKeyframe(at keyframeIndex: Int, from sceneID: UUID) {
        if DefaultScenes.isDefault(sceneID) {
            var overlay = editedDefaultOverrides[sceneID]
                ?? DefaultScenes.all().first { $0.id == sceneID }
                ?? AnimationScene(name: "Unknown")
            overlay.removeKeyframe(at: keyframeIndex)
            editedDefaultOverrides[sceneID] = overlay
            if currentScene?.id == sceneID { currentScene = overlay }
        } else if let index = userScenes.firstIndex(where: { $0.id == sceneID }) {
            userScenes[index].removeKeyframe(at: keyframeIndex)
            if currentScene?.id == sceneID { currentScene = userScenes[index] }
            saveScenes()
        }
    }
    
    // ═══════════════════════════════════════════════════════════════════════════
    // PLAYBACK CONTROLS
    // ═══════════════════════════════════════════════════════════════════════════
    
    /// Start playing the current scene
    func play() {
        guard !isRecording else {
            print("⚠️ Stop live recording before playback")
            return
        }

        guard currentScene != nil else {
            print("⚠️ No scene selected for playback")
            return
        }
        guard (currentScene?.keyframes.count ?? 0) >= 2 else {
            print("⚠️ Scene needs at least 2 keyframes to play")
            return
        }

        // Force the first keyframe to re-assert every effect (the caches gate the
        // persisting effect setters, so a stale cache would skip the initial write).
        resetKeyframeEffectCaches()

        let isStartingFromBeginning = playhead.state == .stopped ||
            (playhead.currentKeyframeIndex == 0 && playhead.elapsedInSegment <= 0.0001)
        
        // Restore the complete scene baseline before pipeline precompilation:
        // fractal type is part of GeometryConfig and is baked into function
        // constants. The legacy flat fields remain compatibility overrides.
        if let settings = renderSettings, let scene = currentScene {
            settings.withPersistenceSuppressed {
                settings.clearAnimationManualOffsets()
                settings.clearAudioPlaybackOffsets()
                settings.setSpaceWarpAudioOffsets([:])
                if isStartingFromBeginning {
                    settings.resetSceneAnimationPhases()
                }

                if let baseline = scene.baseline {
                    baseline.apply(to: settings, includePerformance: false, scope: .scene)
                    if let legacyWarpStack = scene.spaceWarpOps {
                        settings.spaceWarpStack = legacyWarpStack
                    }
                } else {
                    // Backward-compatible authoritative baseline for animations
                    // authored before SceneState existed. Preserve destination
                    // comfort/hand settings unless the legacy animation explicitly
                    // opts into them below, while clearing every visual lane that
                    // otherwise could leak from the previously loaded scene.
                    let legacyFractalType = scene.fractalType ?? .mandelbox
                    var legacyBaseline = SceneState()
                    legacyBaseline.geometry.fractalType = legacyFractalType
                    legacyBaseline.geometry.formulaParams = legacyFractalType.defaultFormulaParams()
                    legacyBaseline.safetyBubble.enabled = false
                    legacyBaseline.handAttraction = settings.handAttractionConfig
                    legacyBaseline.apply(to: settings, includePerformance: false, scope: .scene)
                    settings.spaceWarpStack = scene.spaceWarpOps ?? []
                }

                let sceneFractalType: FractalModelType
                if scene.embeddedFormula?.effectKind == .fractal {
                    sceneFractalType = .custom
                } else {
                    sceneFractalType = scene.fractalType
                        ?? scene.baseline?.geometry.fractalType
                        ?? .mandelbox
                }
                if settings.fractalType != sceneFractalType {
                    settings.fractalType = sceneFractalType
                    print("🎬 Switched fractal type to \(sceneFractalType) for scene playback")
                }
            }
        }

        // Ensure pipelines are compiled before playback (after fractal type is set)
        precompilePipelinesForCurrentScene()

        // Apply scene-level safety bubble / blend window settings
        if let settings = renderSettings, let scene = currentScene {
            settings.withPersistenceSuppressed {
                if isStartingFromBeginning,
                   let speedOverride = scene.playbackSpeedOverride {
                    playbackSpeed = max(0.1, min(4.0, speedOverride))
                }

                #if os(visionOS)
                if let app = AppModel.shared {
                    app.applySceneImmersionPreference(isMixedScene: scene.mixedModeScene == true)
                }
                #endif

                // Shared animations follow the same comfort contract as static
                // scenes: they may opt the bubble on and author its shape, but a
                // downloaded animation may not disable the user's active bubble.
                if scene.safetyBubbleEnabled == true {
                    settings.safetyBubbleEnabled = true
                    if let radius = scene.safetyBubbleRadius {
                        settings.safetyBubbleRadius = radius
                    }
                    if let shape = scene.safetyBubbleShape {
                        settings.safetyBubbleShape = shape
                    }
                    if let blend = scene.safetyBubbleBlend {
                        settings.safetyBubbleBlend = blend
                    }
                }
            
                // ── Apply scene-level gradient / color settings ──────────
                if let preset = scene.gradientPreset {
                    settings.applyGradientPreset(preset)
                    print("🎬 Restored gradient preset to \(preset) for scene playback")
                }
                if let mode = scene.colorMappingMode {
                    settings.colorMappingMode = mode
                }
                if let rep = scene.gradientRepeat {
                    settings.gradientRepeat = rep
                }
                if let off = scene.gradientOffset {
                    settings.gradientOffset = off
                }
                if let sm = scene.gradientSmoothing {
                    settings.gradientSmoothing = sm
                }
                if let sat = scene.colorSchemeSaturation {
                    settings.colorSchemeSaturation = sat
                }
                if let con = scene.colorSchemeContrast {
                    settings.colorSchemeContrast = con
                }
                if let gam = scene.colorSchemeGamma {
                    settings.colorSchemeGamma = gam
                }
                if let vib = scene.colorSchemeVibrance {
                    settings.colorSchemeVibrance = vib
                }
                if let cur = scene.colorSchemeCurve {
                    settings.colorSchemeCurve = cur
                }
                if let shd = scene.colorSchemeShadows {
                    settings.colorSchemeShadows = shd
                }
                if let hlt = scene.colorSchemeHighlights {
                    settings.colorSchemeHighlights = hlt
                }
                if let soft = scene.lightingSoftness {
                    settings.lightingSoftness = soft
                }

                // Apply the current playhead state immediately so first rendered
                // frame does not momentarily show values from prior interaction.
                if let keyframe = interpolatedKeyframeAtCurrentPlayhead(in: scene) {
                    applyKeyframe(keyframe)
                }
            }
        }

        // Signal render loop to tick animation updates every frame.
        // Renderer gates animationManager.update(...) behind this flag.
        renderSettings?.isAnimationPlaying = true

        // Initialise playhead direction for the current scene's playback mode.
        let mode = currentScene?.playbackMode ?? .forward
        switch mode {
        case .forward, .pingPong:
            playhead.isGoingForward = true
        case .reverse:
            // Start at the last segment so the first tick runs N-1 → N-2.
            let kfCount = currentScene?.keyframes.count ?? 2
            playhead.currentKeyframeIndex = kfCount - 1
            playhead.elapsedInSegment = 0
            playhead.isGoingForward = false
        }

        playhead.state = .playing
        uiPlayhead = playhead
        uiThrottleCounter = 0
        UsageAnalytics.shared.trackAnimationUsed()

        let hadAttachedSceneSong = stopWhenAttachedSongEnds
        stopWhenAttachedSongEnds = (currentScene?.attachedSong != nil)
        attachedSongFadeVelocityScale = 1.0
        
        // Auto-play attached song when scene starts
        if let song = currentScene?.attachedSong {
            playSongHandler?(song)
        } else if hadAttachedSceneSong {
            // Prevent audio carry-over from a previously selected music scene.
            stopSongHandler?()
        }
    }

    /// Fully clears active scene playback/selection and any scene-driven song.
    func clearCurrentSceneSelection() {
        let shouldStopSceneSong = stopWhenAttachedSongEnds || (currentScene?.attachedSong != nil)
        stop()
        currentScene = nil
        if shouldStopSceneSong {
            stopSongHandler?()
        }
    }

    /// Pause playback
    func pause() {
        playhead.state = .paused
        uiPlayhead = playhead
        attachedSongFadeVelocityScale = 1.0
        renderSettings?.isAnimationPlaying = false
        renderSettings?.commitAnimationOffsetsToTargets()
    }
    
    /// Stop playback and reset to beginning
    func stop() {
        playhead.state = .stopped
        playhead.reset()
        uiPlayhead = playhead
        stopWhenAttachedSongEnds = false
        attachedSongFadeVelocityScale = 1.0
        renderSettings?.isAnimationPlaying = false
        renderSettings?.commitAnimationOffsetsToTargets()
    }

    /// Stop playback only when we are actively playing a song-attached scene.
    /// Returns true when a stop was performed.
    @discardableResult
    func stopIfAttachedSongFinished() -> Bool {
        guard playhead.state == .playing,
              stopWhenAttachedSongEnds,
              currentScene?.attachedSong != nil else {
            return false
        }

        stop()
        print("🎬 Stopped looping scene because attached song finished")
        return true
    }

    /// Adjust the animation's shape-stream velocity based on attached-song tail settings.
    /// Called from AppModel using live playback progress from the music subsystem.
    func updateAttachedSongFade(currentTime: TimeInterval,
                                duration: TimeInterval,
                                isSongPlaying: Bool) {
        guard playhead.state == .playing,
              stopWhenAttachedSongEnds,
              currentScene?.attachedSong != nil,
              isSongPlaying,
              duration > 0 else {
            attachedSongFadeVelocityScale = 1.0
            return
        }

        guard let scene = currentScene else {
            attachedSongFadeVelocityScale = 1.0
            return
        }

        let fadeDuration = max(0.0, scene.songFadeOutDuration ?? 0.0)
        let fadeOffset = max(0.0, scene.songFadeOutOffset ?? 0.0)

        if fadeDuration <= 0.0 && fadeOffset <= 0.0 {
            attachedSongFadeVelocityScale = 1.0
            return
        }

        let remaining = max(0.0, duration - max(0.0, currentTime))
        let fadeStartRemaining = fadeOffset + fadeDuration

        if remaining > fadeStartRemaining {
            attachedSongFadeVelocityScale = 1.0
            return
        }

        if remaining <= fadeOffset {
            attachedSongFadeVelocityScale = minimumAttachedSongFadeVelocityScale
            return
        }

        let normalized = (fadeStartRemaining - remaining) / max(0.001, fadeDuration)
        let clamped = normalized.clamped(to: 0.0...1.0)
        let eased = clamped * clamped * (3.0 - 2.0 * clamped) // smoothstep
        attachedSongFadeVelocityScale = 1.0 - (1.0 - minimumAttachedSongFadeVelocityScale) * eased
    }
    
    /// Toggle play/pause
    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }
    
    /// Jump to a specific keyframe
    func jumpToKeyframe(_ index: Int) {
        guard let scene = currentScene,
              scene.keyframes.indices.contains(index) else { return }
        
        playhead.currentKeyframeIndex = index
        playhead.elapsedInSegment = 0
        uiPlayhead = playhead
        
        // Apply the keyframe immediately
        applyKeyframe(scene.keyframes[index])
    }
    
    /// Precompile shader pipelines for all keyframes in the current scene.
    /// This ensures smooth playback by compiling all needed pipelines ahead of time.
    private func precompilePipelinesForCurrentScene() {
        guard let scene = currentScene,
              let handler = preparePipelineHandler else { return }
        
        // Collect unique iteration/step combinations from all keyframes
        var compiledConfigs = Set<String>()
        
        for keyframe in scene.keyframes {
            let configKey = "\(keyframe.baseFractalIterations)_\(keyframe.baseMaxRaySteps)"
            
            // Skip if already compiled in this batch
            guard !compiledConfigs.contains(configKey) else { continue }
            compiledConfigs.insert(configKey)
            
            // Trigger pipeline compilation via the handler
            handler(keyframe.baseFractalIterations, keyframe.baseMaxRaySteps)
        }
        
        if !compiledConfigs.isEmpty {
            print("🔧 [Animation] Precompiled pipelines for \(compiledConfigs.count) unique configs in scene '\(scene.name)'")
        }
    }
    
    // ═══════════════════════════════════════════════════════════════════════════
    // ANIMATION UPDATE (called every frame)
    // ═══════════════════════════════════════════════════════════════════════════

    /// Outcome of advancing the playhead from one keyframe segment to the next.
    private enum SegmentAdvance {
        case next(toIndex: Int, goingForward: Bool)
        case stop
    }

    /// Pure direction/boundary logic shared by the initial segment resolve and the
    /// carry-over loop in `update(deltaTime:)`: given the current segment origin and
    /// direction it returns the next target keyframe (handling loop / ping-pong
    /// bounce) or `.stop` when a non-looping animation runs off the end. Extracted so
    /// the two call sites can never drift apart.
    private enum SegmentAdvancer {
        static func advance(fromIndex: Int,
                            goingForward: Bool,
                            mode: AnimationPlaybackMode,
                            isLooping: Bool,
                            keyframeCount: Int) -> SegmentAdvance {
            if goingForward {
                var toIndex = fromIndex + 1
                if toIndex >= keyframeCount {
                    switch mode {
                    case .forward:
                        if isLooping { toIndex = 0 } else { return .stop }
                    case .pingPong:
                        // Bounce: reverse direction, go back one step.
                        toIndex = fromIndex - 1
                        if toIndex < 0 { return .stop }   // only the 2-keyframe edge case
                        return .next(toIndex: toIndex, goingForward: false)
                    case .reverse:
                        break  // unreachable: reverse mode never goes forward
                    }
                }
                return .next(toIndex: toIndex, goingForward: true)
            } else {
                var toIndex = fromIndex - 1
                if toIndex < 0 {
                    switch mode {
                    case .reverse:
                        if isLooping { toIndex = keyframeCount - 1 } else { return .stop }
                    case .pingPong:
                        // Bounce: forward again.
                        toIndex = fromIndex + 1
                        if toIndex >= keyframeCount { return .stop }
                        return .next(toIndex: toIndex, goingForward: true)
                    case .forward:
                        break  // unreachable: forward mode never goes backward
                    }
                }
                return .next(toIndex: toIndex, goingForward: false)
            }
        }
    }

    /// Update animation state. Call this every frame with delta time.
    /// - Parameter deltaTime: Time since last frame in seconds
    func update(deltaTime: TimeInterval) {
        guard playhead.state == .playing,
              let scene = currentScene,
              scene.keyframes.count >= 2 else { return }
        let keyframes = scene.keyframes
        let keyframeCount = keyframes.count
        let mode = scene.playbackMode

        // Advance time. Attached-song fade can temporarily damp velocity near track end.
        let activityFactor = Double(renderSettings?.animationActivityFactor ?? 1.0)
        let effectivePlaybackVelocity = playbackSpeed * attachedSongFadeVelocityScale * activityFactor
        playhead.elapsedInSegment += deltaTime * effectivePlaybackVelocity

        // Resolve the current segment (from → to) based on playback mode.
        // `fromIndex` is the keyframe we started the segment at.
        // `toIndex`   is the keyframe we are interpolating toward.
        var fromIndex = playhead.currentKeyframeIndex
        var toIndex: Int
        var goingForward = mode == .forward ? true : (mode == .reverse ? false : playhead.isGoingForward)

        switch SegmentAdvancer.advance(fromIndex: fromIndex, goingForward: goingForward,
                                       mode: mode, isLooping: scene.isLooping, keyframeCount: keyframeCount) {
        case .stop:
            stop(); return
        case .next(let nextTo, let nextForward):
            toIndex = nextTo
            goingForward = nextForward
            playhead.isGoingForward = nextForward
        }

        // The segment duration is keyed to the destination keyframe (same as forward mode).
        // For reverse segments we use the from-index's duration so timing is symmetric.
        var fromKeyframe = keyframes[fromIndex]
        var toKeyframe   = keyframes[toIndex]
        // Use the later keyframe's duration for the segment regardless of direction.
        let durationIndex = max(fromIndex, toIndex)
        var actualDuration = segmentDuration(for: keyframes, toIndex: durationIndex)

        // Check if current segment is complete — advance and carry over excess time
        while playhead.elapsedInSegment >= actualDuration {
            playhead.elapsedInSegment -= actualDuration
            playhead.currentKeyframeIndex = toIndex
            fromIndex = toIndex

            switch SegmentAdvancer.advance(fromIndex: fromIndex, goingForward: goingForward,
                                           mode: mode, isLooping: scene.isLooping, keyframeCount: keyframeCount) {
            case .stop:
                stop(); return
            case .next(let nextTo, let nextForward):
                toIndex = nextTo
                goingForward = nextForward
                playhead.isGoingForward = nextForward
            }

            fromKeyframe  = keyframes[fromIndex]
            toKeyframe    = keyframes[toIndex]
            let durIdx    = max(fromIndex, toIndex)
            actualDuration = segmentDuration(for: keyframes, toIndex: durIdx)
        }

        // Calculate progress through current segment (0 to 1)
        let rawProgress = Float(playhead.elapsedInSegment / actualDuration)

        // Interpolate using the appropriate method
        let interpolated: AnimationKeyframe

        // Easing is always the per-keyframe easingType; the global easingFunction
        // only feeds the spline-gate OR condition below (it can promote a .bezier
        // keyframe to spline interpolation), never replacing effectiveEasing.
        let effectiveEasing = toKeyframe.easingType

        if effectiveEasing.usesSplineInterpolation || (easingFunction.usesSplineInterpolation && effectiveEasing == .bezier) {
            interpolated = CatmullRomSpline.interpolateKeyframes(
                keyframes,
                fromIndex: fromIndex,
                toIndex: toIndex,
                t: rawProgress,
                isLooping: scene.isLooping
            )
        } else if effectiveEasing.usesBezierHandles {
            let easedProgress = CubicBezier.evaluate(rawProgress, handle: toKeyframe.bezierHandle)
            interpolated = fromKeyframe.interpolated(to: toKeyframe, t: easedProgress)
        } else {
            let easedProgress = effectiveEasing.apply(rawProgress)
            interpolated = fromKeyframe.interpolated(to: toKeyframe, t: easedProgress)
        }

        applyKeyframe(interpolated)

        // Throttle UI playhead updates to ~15Hz to avoid per-frame SwiftUI invalidation
        uiThrottleCounter += 1
        if uiThrottleCounter >= Self.uiThrottleInterval {
            uiThrottleCounter = 0
            uiPlayhead = playhead
        }
    }

    // Last scene-keyframe effect structs actually written through the persisting setters.
    // The effect setters flip the lighting preset to .custom and persist to disk, so we
    // only call them when the scene's keyframe value changes — NOT every frame. Music
    // modulation is layered on afterwards via the non-persisting audioModulate* setters,
    // so these caches must compare the raw keyframe value, not the live (modulated) value.
    private var lastKeyframeGlow: GlowEffect?
    private var lastKeyframeBloom: BloomEffect?
    private var lastKeyframeFog: FogEffect?
    private var lastKeyframeHue: HueRotationEffect?
    private var lastKeyframeSaturation: Float?

    /// Reset the per-effect keyframe caches so the next `applyKeyframe` re-asserts the
    /// scene's effect values (call when playback starts/stops or the scene changes).
    private func resetKeyframeEffectCaches() {
        lastKeyframeGlow = nil
        lastKeyframeBloom = nil
        lastKeyframeFog = nil
        lastKeyframeHue = nil
        lastKeyframeSaturation = nil
    }

    /// Apply a keyframe's values to render settings
    /// During playback, we set IMMEDIATE values (bypassing smoothing) for responsive animation.
    /// Targets are also updated so hand gestures can blend in when animation stops.
    private func applyKeyframe(_ keyframe: AnimationKeyframe) {
        guard let settings = renderSettings else { return }
        settings.withPersistenceSuppressed {
            applyKeyframeWithoutPersistence(keyframe, to: settings)
        }
    }

    /// Inner hot path. The caller establishes the scene-mutation boundary once
    /// so effect setters cannot rewrite device/user preference blobs.
    ///
    /// Split into two halves:
    /// 1. Change-gated writes stay ordinary setters — they fire once per
    ///    keyframe change (guarded by the lastKeyframe* caches / != checks)
    ///    and carry persistence and preset side effects.
    /// 2. The ~45 unconditional per-frame writes go through one batched
    ///    settings lock (`applyAnimationKeyframeBatch`) instead of ~45
    ///    individual acquisitions at 90 Hz. The gated struct writes run
    ///    FIRST so the batch's per-frame modulated values land on top,
    ///    matching the original statement order.
    private func applyKeyframeWithoutPersistence(_ keyframe: AnimationKeyframe,
                                                 to settings: RenderSettings) {
          if let lightingMode = keyframe.lightingMode,
              settings.lightingMode != lightingMode {
            settings.lightingMode = lightingMode
        }
          if let lightingPreset = keyframe.lightingPreset,
              settings.lightingPreset != lightingPreset {
            settings.lightingPreset = lightingPreset
        }
        // Hue / Glow / Bloom / Fog / Saturation: write the full effect struct
        // (which persists + flips the lighting preset to .custom) only when
        // the scene's keyframe changes; the batch below layers gesture +
        // music offsets onto the live value every frame without persisting.
        // Comparing against the cached raw keyframe (not the live, modulated
        // value) keeps the expensive persisting write from firing once music
        // is active.
        if let hueRotationEffect = keyframe.hueRotationEffect {
            if lastKeyframeHue != hueRotationEffect {
                lastKeyframeHue = hueRotationEffect
                settings.hueRotationEffect = hueRotationEffect
            }
        } else {
            lastKeyframeHue = nil
        }
          if let pulseEffect = keyframe.pulseEffect,
              settings.pulseEffect != pulseEffect {
            settings.pulseEffect = pulseEffect
        }
        if let glowEffect = keyframe.glowEffect {
            if lastKeyframeGlow != glowEffect {
                lastKeyframeGlow = glowEffect
                settings.glowEffect = glowEffect
            }
        } else {
            lastKeyframeGlow = nil
        }
        if let bloomEffect = keyframe.bloomEffect {
            if lastKeyframeBloom != bloomEffect {
                lastKeyframeBloom = bloomEffect
                settings.bloomEffect = bloomEffect
            }
        } else {
            lastKeyframeBloom = nil
        }
        if let fogEffect = keyframe.fogEffect {
            if lastKeyframeFog != fogEffect {
                lastKeyframeFog = fogEffect
                settings.fogEffect = fogEffect
            }
        } else {
            lastKeyframeFog = nil
        }
          if let gradientCycleEffect = keyframe.gradientCycleEffect,
              settings.gradientCycleEffect != gradientCycleEffect {
            settings.gradientCycleEffect = gradientCycleEffect
        }

        // ── Per-keyframe color overrides ─────────────────────────────────
        if let preset = keyframe.gradientPreset,
           settings.gradientPreset != preset {
            settings.applyGradientPreset(preset)
        }
        if let mode = keyframe.colorMappingMode {
            settings.colorMappingMode = mode
        }
        if let rep = keyframe.gradientRepeat {
            settings.gradientRepeat = rep
        }
        if let off = keyframe.gradientOffset {
            settings.gradientOffset = off
        }
        if let sm = keyframe.gradientSmoothing {
            settings.gradientSmoothing = sm
        }
        if let sat = keyframe.colorSchemeSaturation {
            if lastKeyframeSaturation != sat {
                lastKeyframeSaturation = sat
                settings.colorSchemeSaturation = max(0.0, min(3.0, sat))
            }
        } else {
            lastKeyframeSaturation = nil
        }
        if let con = keyframe.colorSchemeContrast {
            settings.colorSchemeContrast = con
        }
        if let gam = keyframe.colorSchemeGamma {
            settings.colorSchemeGamma = gam
        }
        if let vib = keyframe.colorSchemeVibrance {
            settings.colorSchemeVibrance = vib
        }
        if let cur = keyframe.colorSchemeCurve {
            settings.colorSchemeCurve = cur
        }
        if let shd = keyframe.colorSchemeShadows {
            settings.colorSchemeShadows = shd
        }
        if let hlt = keyframe.colorSchemeHighlights {
            settings.colorSchemeHighlights = hlt
        }
        if let soft = keyframe.lightingSoftness {
            settings.lightingSoftness = soft
        }

        let resolvedMusicConfig = keyframe.musicReactiveConfig ?? AudioReactiveConfig()
        if settings.audioReactiveConfig != resolvedMusicConfig {
            settings.audioReactiveConfig = resolvedMusicConfig
        }

        // Legacy "mandelboxSphereProjection" scenes fold into base `.mandelbox` +
        // the Space-tab Sphere Projection. The old MSP type read projection
        // blend/radius from formula params[4]/[5] and always projected; reproduce
        // that every frame so animated projection radius/blend tracks the
        // interpolated keyframe (e.g. Scene 9 / Kaleidoscope animate params[5]).
        let legacyMSP = currentScene?.legacyMandelboxSphereProjection == true
        let mspParams: (blend: Float, radius: Float)? = {
            guard legacyMSP, let vals = keyframe.formulaParamValues, vals.count > 5 else { return nil }
            return (vals[4], vals[5])
        }()

        settings.applyAnimationKeyframeBatch(.init(
            minDistance: keyframe.minDistance,
            foldingLimit: keyframe.foldingLimit,
            sphereRadius: keyframe.sphereRadius,
            fractalScale: keyframe.fractalScale,
            scale: keyframe.scale,
            position: keyframe.position,
            detailScale: keyframe.detailScale,
            worldRotation: keyframe.worldRotation,
            // Iteration budget: skip when the user has manually overridden it
            // for this scene. The override is cleared on every scene switch so
            // the scene's saved budget restores on first run.
            baseFractalIterations: userIterationBudgetOverride ? nil : keyframe.baseFractalIterations,
            baseMaxRaySteps: userIterationBudgetOverride ? nil : keyframe.baseMaxRaySteps,
            formulaParamValues: keyframe.formulaParamValues,
            legacyProjectionBlend: mspParams?.blend,
            legacyProjectionRadius: mspParams?.radius,
            hueSpeedBase: keyframe.hueRotationEffect?.speed,
            glowIntensityBase: keyframe.glowEffect?.intensity,
            bloomStrengthBase: keyframe.bloomEffect?.strength,
            fogIntensityBase: keyframe.fogEffect?.intensity,
            saturationBase: keyframe.colorSchemeSaturation
        ))
    }

    /// Returns the keyframe state corresponding to the current playhead time.
    /// Does not mutate playhead time/index.
    private func interpolatedKeyframeAtCurrentPlayhead(in scene: AnimationScene) -> AnimationKeyframe? {
        let keyframes = scene.keyframes
        guard keyframes.count >= 1 else { return nil }
        guard keyframes.count >= 2 else { return keyframes[0] }

        let keyframeCount = keyframes.count
        let fromIndex = min(max(playhead.currentKeyframeIndex, 0), keyframeCount - 1)
        var toIndex = fromIndex + 1
        if toIndex >= keyframeCount {
            toIndex = scene.isLooping ? 0 : keyframeCount - 1
        }

        let segmentDuration = segmentDuration(for: keyframes, toIndex: toIndex)
        let rawProgress: Float
        if segmentDuration > 0 {
            rawProgress = Float(min(max(playhead.elapsedInSegment / segmentDuration, 0.0), 1.0))
        } else {
            rawProgress = 1.0
        }

        let fromKeyframe = keyframes[fromIndex]
        let toKeyframe = keyframes[toIndex]

        // Easing is always the per-keyframe easingType; the global easingFunction
        // only feeds the spline-gate OR condition below (it can promote a .bezier
        // keyframe to spline interpolation), never replacing effectiveEasing.
        let effectiveEasing = toKeyframe.easingType
        if effectiveEasing.usesSplineInterpolation || (easingFunction.usesSplineInterpolation && effectiveEasing == .bezier) {
            return CatmullRomSpline.interpolateKeyframes(
                keyframes,
                fromIndex: fromIndex,
                toIndex: toIndex,
                t: rawProgress,
                isLooping: scene.isLooping
            )
        }

        if effectiveEasing.usesBezierHandles {
            let easedProgress = CubicBezier.evaluate(rawProgress, handle: toKeyframe.bezierHandle)
            return fromKeyframe.interpolated(to: toKeyframe, t: easedProgress)
        }

        let easedProgress = effectiveEasing.apply(rawProgress)
        return fromKeyframe.interpolated(to: toKeyframe, t: easedProgress)
    }
    
    // ═══════════════════════════════════════════════════════════════════════════
    // PERSISTENCE
    // ═══════════════════════════════════════════════════════════════════════════
    
    private func loadScenes() {
        withSceneRebuildBatch {
            // User scenes now live as individual files under <root>/Animations.
            // Migrate the legacy blob once, then mirror the folder (source of truth).
            migrateLegacyUserScenesIfNeeded()

            // Load hidden default IDs
            if let ids = UserDefaults.standard.array(forKey: "hiddenDefaultSceneIDs") as? [String] {
                hiddenDefaultSceneIDs = Set(ids.compactMap { UUID(uuidString: $0) })
            }

            // Load edited default overrides
            if let data = UserDefaults.standard.data(forKey: "editedDefaultOverrides") {
                do {
                    let overrides = try sceneDecoder.decode([AnimationScene].self, from: data)
                    let deduplicatedOverrides = Dictionary(
                        overrides.map { ($0.id, $0) },
                        uniquingKeysWith: { _, replacement in replacement }
                    )
                    if deduplicatedOverrides.count != overrides.count {
                        print("⚠️ Deduplicated \(overrides.count - deduplicatedOverrides.count) edited default scene overrides with repeated IDs")
                    }
                    editedDefaultOverrides = deduplicatedOverrides
                } catch {
                    print("❌ Failed to load default overrides: \(error)")
                }
            }
        }

        // File enumeration and JSON decoding can involve hundreds of megabytes
        // of iCloud-backed data. Schedule it after the synchronous defaults and
        // overrides are ready so app launch never waits for the store.
        scheduleUserSceneReload(reason: "manager load", immediate: true)

        print("📂 Defaults: \(DefaultScenes.allIDs.count) built-in, \(hiddenDefaultSceneIDs.count) hidden, \(editedDefaultOverrides.count) edited")
    }

    /// Mirror `userScenes` into the store's Animations/ folder in a single pass:
    /// one directory scan, remove stale renamed copies, write each current scene.
    /// Also drops a throttled whole-set backup snapshot (the safety net). Default
    /// files in the folder are left untouched.
    ///
    /// Deletions are NOT inferred here by diffing the folder against `userScenes`.
    /// That was a cross-device data-loss trap: `scanUserScenes` skips not-yet-
    /// downloaded iCloud files, so a scene another device just added (still a
    /// dataless placeholder at reload, then materialized moments later) would be
    /// absent from the in-memory list and get deleted from the shared folder on
    /// the next routine edit — propagating the delete to every device. A real
    /// deletion removes its file at the delete site (`removeUserSceneFile`) or via
    /// `replaceUserScenes`, both of which only ever drop ids the app already knew.
    private func saveScenes() {
        if storeRoot == nil {
            for scene in userScenes { pendingRootWrites[scene.id] = scene }
        } else {
            let written = writeUserSceneFiles(userScenes)
            for id in written {
                pendingRootWrites.removeValue(forKey: id)
            }
        }
        if let data = try? prettySceneEncoder.encode(userScenes) { writeSceneBackup(data: data) }
        print("💾 Saved \(userScenes.count) user scenes")
    }

    private func flushPendingRootWrites() {
        guard storeRoot != nil, !pendingRootWrites.isEmpty else { return }
        let written = writeUserSceneFiles(Array(pendingRootWrites.values))
        for id in written {
            pendingRootWrites.removeValue(forKey: id)
        }
    }

    /// Replace all user scenes with the given array and mirror into the folder.
    /// Files for ids the app is dropping (present in the current in-memory set,
    /// absent from the new one) are removed explicitly. We never infer deletions
    /// by diffing the folder — a not-yet-downloaded iCloud scene from another
    /// device is absent from memory yet must NOT be deleted, or the delete would
    /// propagate to every device.
    func replaceUserScenes(with scenes: [AnimationScene]) {
        let droppedIDs = Set(userScenes.map(\.id)).subtracting(scenes.map(\.id))
        invalidateUserSceneReloadForLocalMutation()
        removeUserSceneFiles(ids: droppedIDs)
        for id in droppedIDs { pendingRootWrites.removeValue(forKey: id) }
        userScenes = scenes
        saveScenes()
    }
    
    private func saveHiddenDefaults() {
        let ids = hiddenDefaultSceneIDs.map { $0.uuidString }
        UserDefaults.standard.set(ids, forKey: "hiddenDefaultSceneIDs")
    }
    
    private func saveOverrides() {
        do {
            let overrides = Array(editedDefaultOverrides.values)
            let data = try sceneEncoder.encode(overrides)
            UserDefaults.standard.set(data, forKey: "editedDefaultOverrides")
        } catch {
            print("❌ Failed to save default overrides: \(error)")
        }
    }
    
    /// Debounced flush — coalesces rapid didSet writes into a single save
    private func scheduleSaveFlush() {
        saveCoalesceTask?.cancel()
        saveCoalesceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled, let self else { return }
            if self.pendingSaveHidden {
                self.pendingSaveHidden = false
                self.saveHiddenDefaults()
            }
            if self.pendingSaveOverrides {
                self.pendingSaveOverrides = false
                self.saveOverrides()
            }
        }
    }
    
    /// Export a scene to a shareable file URL.
    /// Nonisolated: encode + write can take tens of ms — call it off the main
    /// actor (see `exportOffMain`).
    nonisolated static func exportSceneFile(_ scene: AnimationScene) -> URL? {
        let sanitizedName = PresetManager.sanitizedExportFileNameStem(scene.name)
        // Scenes with attached music export as music videos.
        let format: ThresholdExportFormat = scene.attachedSong != nil ? .musicVideoScene : .animationScene
        let fileName = "\(sanitizedName).\(format.ext)"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)

        do {
            let data = try makePrettySceneEncoder().encode(scene)
            try data.write(to: tempURL)
            return tempURL
        } catch {
            print("❌ Failed to export scene file: \(error)")
            return nil
        }
    }
    
    // ═══════════════════════════════════════════════════════════════════════════
    // LIVE SESSION RECORDING
    // ═══════════════════════════════════════════════════════════════════════════
    
    /// Start recording the live session. Samples RenderSettings until stopped.
    func startRecording() {
        guard renderSettings != nil else {
            print("⚠️ Cannot record — no render settings")
            return
        }

        guard !isRecording else { return }
        
        // Stop any playback
        if isPlaying { stop() }
        
        guard let settings = renderSettings else { return }

        recordingSamples = []
        recordingStartTime = CACurrentMediaTime()
        recordingFractalType = settings.fractalType
        recordingBaseline = captureSceneBaseline(from: settings)
        recordingEmbeddedFormula = AppModel.shared?.activeEmbeddedFormula
        isRecording = true
        UsageAnalytics.shared.trackRecordingUsed()
        
        print("🔴 Live session recording started")
        
        let interval = 1.0 / Self.recordingSampleRate
        recordingTask = Task { [weak self] in
            var nextSampleTime = CACurrentMediaTime()
            while !Task.isCancelled {
                guard let self, let settings = self.renderSettings else { return }
                
                let elapsed = CACurrentMediaTime() - self.recordingStartTime
                var sample = AnimationKeyframe(from: settings, name: "", duration: 0)
                sample.easingType = .linear
                sample.bezierHandle = .linear
                self.recordingSamples.append((time: elapsed, keyframe: sample))
                
                // Schedule next sample at fixed intervals to avoid drift
                nextSampleTime += interval
                let delay = max(0, nextSampleTime - CACurrentMediaTime())
                try? await Task.sleep(for: .milliseconds(Int(delay * 1000)))
            }
        }
    }
    
    /// Stop recording and convert samples into a new scene.
    /// Returns the created scene, or nil if recording was too short.
    @discardableResult
    func stopRecording() -> AnimationScene? {
        guard isRecording else { return nil }

        recordingTask?.cancel()
        recordingTask = nil
        isRecording = false
        
        let samples = recordingSamples
        recordingSamples = []
        let recordedFractalType = recordingFractalType
        recordingFractalType = nil
        let recordedBaseline = recordingBaseline
        recordingBaseline = nil
        let recordedEmbeddedFormula = recordingEmbeddedFormula
        recordingEmbeddedFormula = nil
        
        guard samples.count >= 2, let lastSample = samples.last else {
            print("⚠️ Live recording too short — need at least 2 samples")
            return nil
        }
        
        print("🔴 Live session recording stopped — \(samples.count) samples over \(String(format: "%.1f", lastSample.time))s")
        
        // Simplify: remove samples where nothing changed significantly
        let simplified = simplifySamples(samples)
        print("🔴 Simplified to \(simplified.count) keyframes")
        
        // Build keyframes with proper durations
        var keyframes: [AnimationKeyframe] = []
        for (i, sample) in simplified.enumerated() {
            var kf = sample.keyframe
            kf.name = i == 0 ? "Start" : "KF \(i + 1)"
            
            if i == 0 {
                kf.duration = 0
            } else {
                kf.duration = sample.time - simplified[i - 1].time
            }
            
            keyframes.append(kf)
        }
        
        // Create the scene
        var scene = AnimationScene(name: "Live Recording \(formattedTimestamp())")
        scene.keyframes = keyframes
        scene.isLooping = true
        scene.fractalType = recordedFractalType ?? renderSettings?.fractalType
        scene.baseline = recordedBaseline
        scene.embeddedFormula = recordedEmbeddedFormula
        if let recordedBaseline {
            populateLegacySceneFields(&scene, from: recordedBaseline)
        }
        
        // Legacy fallback for a recording begun before a baseline was available.
        if recordedBaseline == nil, let settings = renderSettings {
            scene.colorSchemeSaturation = settings.colorSchemeSaturation
            scene.colorSchemeContrast = settings.colorSchemeContrast
            scene.colorSchemeGamma = settings.colorSchemeGamma
            scene.colorSchemeVibrance = settings.colorSchemeVibrance
            scene.colorSchemeCurve = settings.colorSchemeCurve
            scene.colorSchemeShadows = settings.colorSchemeShadows
            scene.colorSchemeHighlights = settings.colorSchemeHighlights
            scene.lightingSoftness = settings.lightingSoftness
            scene.gradientPreset = settings.gradientPreset
            scene.colorMappingMode = settings.colorMappingMode
            scene.gradientRepeat = settings.gradientRepeat
            scene.gradientOffset = settings.gradientOffset
            scene.gradientSmoothing = settings.gradientSmoothing
        }
        
        userScenes.append(scene)
        saveScenes()
        currentScene = scene
        
        print("🎬 Created live recording '\(scene.name)' with \(keyframes.count) keyframes, duration \(String(format: "%.1f", scene.totalDuration))s")
        return scene
    }

    @discardableResult
    func toggleRecording() -> AnimationScene? {
        if isRecording {
            return stopRecording()
        }

        startRecording()
        return nil
    }
    
    /// Elapsed recording time for UI display
    var recordingElapsed: TimeInterval {
        guard isRecording else { return 0 }
        return CACurrentMediaTime() - recordingStartTime
    }
    
    /// Remove samples where parameters haven't changed enough to matter.
    /// Always keeps first and last sample.
    private func simplifySamples(_ samples: [(time: TimeInterval, keyframe: AnimationKeyframe)]) -> [(time: TimeInterval, keyframe: AnimationKeyframe)] {
        guard samples.count > 2 else { return samples }
        
        var result: [(time: TimeInterval, keyframe: AnimationKeyframe)] = [samples[0]]
        
        for i in 1..<(samples.count - 1) {
            let prev = result.last!.keyframe
            let curr = samples[i].keyframe
            
            // Check if any parameter changed significantly
            let positionDelta = simd_length(curr.position - prev.position)
            let baseScaleDelta = abs(curr.scale - prev.scale)
            let detailScaleDelta = abs(curr.detailScale - prev.detailScale)
            let rotDelta = abs(1.0 - abs(simd_dot(curr.worldRotation, prev.worldRotation)))
            let minDistDelta = abs(curr.minDistance - prev.minDistance)
            let foldDelta = abs(curr.foldingLimit - prev.foldingLimit)
            let sphereDelta = abs(curr.sphereRadius - prev.sphereRadius)
            let fracScaleDelta = abs(curr.fractalScale - prev.fractalScale)
            
            // Check formula params
            var formulaChanged = false
            if let pVals = prev.formulaParamValues, let cVals = curr.formulaParamValues, pVals.count == cVals.count {
                for j in 0..<pVals.count where abs(pVals[j] - cVals[j]) > 0.001 {
                    formulaChanged = true
                    break
                }
            } else if (prev.formulaParamValues == nil) != (curr.formulaParamValues == nil) {
                formulaChanged = true
            }
            
            let changed = positionDelta > 0.001
                || baseScaleDelta > 0.001
                || detailScaleDelta > 0.01
                || rotDelta > 0.0001
                || minDistDelta > 0.001
                || foldDelta > 0.001
                || sphereDelta > 0.001
                || fracScaleDelta > 0.001
                || formulaChanged
            
            if changed {
                result.append(samples[i])
            }
        }
        
        result.append(samples.last!)
        return result
    }
    
    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "HH-mm-ss"
        return f
    }()

    private func formattedTimestamp() -> String {
        return Self.timestampFormatter.string(from: Date())
    }
}
