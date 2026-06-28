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
        guard let animDir = iCloudAnimDir else { return }
        importScenesFromiCloud(animDir: animDir)
    }

    /// Scan `animDir` and import any `.threshanim`/`.threshanimv` files whose
    /// UUID is not already present in the full merged scene list (defaults,
    /// edited overrides, and user scenes). All new scenes are bulk-appended
    /// in one operation so `rebuildScenes()` only fires once per call.
    func importScenesFromiCloud(animDir: URL) {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: animDir,
                includingPropertiesForKeys: [.ubiquitousItemDownloadingStatusKey],
            options: .skipsHiddenFiles
        ) else { return }

        // Build once against the FULL merged list (defaults + overrides + user).
        // This prevents bundled default scenes that syncToCloud wrote to iCloud
        // from being re-imported as user scenes, even if DefaultScenes.allIDs
        // hasn't finished loading yet.
        var knownIDs = Set(scenes.map(\.id))

        var newScenes: [AnimationScene] = []
        for url in contents where ["threshanim", "threshanimv"].contains(url.pathExtension) {
            // Trigger download if the file is only a cloud placeholder.
            try? fm.startDownloadingUbiquitousItem(at: url)

            guard fm.fileExists(atPath: url.path) else { continue }
            guard let data = try? Data(contentsOf: url) else { continue }
            guard let scene = try? sceneDecoder.decode(AnimationScene.self, from: data) else {
                print("☁️ Skipping undecodable file: \(url.lastPathComponent)")
                continue
            }
            // Guard against two cloud files sharing a UUID (e.g. a renamed copy).
            guard !knownIDs.contains(scene.id) else { continue }

            newScenes.append(scene)
            knownIDs.insert(scene.id)   // prevent a duplicate in this same pass
        }

        guard !newScenes.isEmpty else { return }

        // Bulk-append so userScenes.didSet / rebuildScenes() fires exactly once.
        userScenes.append(contentsOf: newScenes)
        saveScenes()
        print("☁️ Imported \(newScenes.count) scene(s) from iCloud Drive: \(newScenes.map(\.name).joined(separator: ", "))")
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

    /// Timestamped backups of user scenes, mirroring PresetManager's safety net.
    private var scenesBackupsDirectory: URL {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = documentsPath.appendingPathComponent("AnimationSceneBackups", isDirectory: true)
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

    /// Most-recent backup scenes, used when the main file is missing or corrupt.
    private func loadLatestBackupScenes() -> [AnimationScene] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: scenesBackupsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return [] }
        let latest = files.max { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da < db
        }
        guard let url = latest,
              let data = try? Data(contentsOf: url),
              let scenes = try? sceneDecoder.decode([AnimationScene].self, from: data) else { return [] }
        print("✅ Recovered \(scenes.count) user scenes from backup: \(url.lastPathComponent)")
        return scenes
    }
    
    // ═══════════════════════════════════════════════════════════════════════════
    // INITIALIZATION
    // ═══════════════════════════════════════════════════════════════════════════
    
    init(renderSettings: RenderSettings? = nil) {
        self.renderSettings = renderSettings
        renderSettings?.sceneTransitionDuration = Float(sceneTransitionDuration)
        loadScenes()
        rebuildScenes()
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SCENE MANAGEMENT
    // ═══════════════════════════════════════════════════════════════════════════
    
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
        
        let scene = AnimationScene(name: name, initialKeyframe: initialKeyframe, fractalType: settings.fractalType)
        // Capture current safety bubble / blend window settings into the scene
        var sceneWithBubble = scene
        sceneWithBubble.safetyBubbleEnabled = settings.safetyBubbleEnabled
        sceneWithBubble.safetyBubbleRadius = settings.safetyBubbleRadius
        sceneWithBubble.safetyBubbleShape = settings.safetyBubbleShape
        sceneWithBubble.safetyBubbleBlend = settings.safetyBubbleBlend
        sceneWithBubble.gradientPreset = settings.gradientPreset
        sceneWithBubble.colorMappingMode = settings.colorMappingMode
        sceneWithBubble.gradientRepeat = settings.gradientRepeat
        sceneWithBubble.gradientOffset = settings.gradientOffset
        sceneWithBubble.gradientSmoothing = settings.gradientSmoothing
        sceneWithBubble.colorSchemeSaturation = settings.colorSchemeSaturation
        sceneWithBubble.colorSchemeContrast = settings.colorSchemeContrast
        sceneWithBubble.colorSchemeGamma = settings.colorSchemeGamma
        sceneWithBubble.colorSchemeVibrance = settings.colorSchemeVibrance
        sceneWithBubble.colorSchemeCurve = settings.colorSchemeCurve
        sceneWithBubble.colorSchemeShadows = settings.colorSchemeShadows
        sceneWithBubble.colorSchemeHighlights = settings.colorSchemeHighlights
        sceneWithBubble.lightingSoftness = settings.lightingSoftness
        userScenes.append(sceneWithBubble)
        saveScenes()
        
        print("🎬 Created scene '\(name)' with initial keyframe")
        return sceneWithBubble
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
        
        // Restore the fractal type the scene was authored for.
        // This MUST happen before pipeline precompilation, because pipelines
        // are specialized per-fractal-type (FT is baked into function constants).
        if let settings = renderSettings {
            let sceneFractalType = currentScene?.fractalType ?? .mandelbox
            if settings.fractalType != sceneFractalType {
                settings.fractalType = sceneFractalType
                print("🎬 Switched fractal type to \(sceneFractalType) for scene playback")
            }
        }

        // Ensure pipelines are compiled before playback (after fractal type is set)
        precompilePipelinesForCurrentScene()

        // Apply scene-level safety bubble / blend window settings
        if let settings = renderSettings, let scene = currentScene {
            // Clear lingering user/gesture offsets so playback starts from clean scene values.
            settings.clearAnimationManualOffsets()
            // Scenes own their music-reactive state. Start from defaults so a
            // previous scene's audio settings don't leak into this one.
            settings.audioReactiveConfig = AudioReactiveConfig()

            if isStartingFromBeginning,
               let speedOverride = scene.playbackSpeedOverride {
                playbackSpeed = max(0.1, min(4.0, speedOverride))
            }

            if let enabled = scene.safetyBubbleEnabled {
                settings.safetyBubbleEnabled = enabled
            }
            if let radius = scene.safetyBubbleRadius {
                settings.safetyBubbleRadius = radius
            }
            if let shape = scene.safetyBubbleShape {
                settings.safetyBubbleShape = shape
            }
            if let blend = scene.safetyBubbleBlend {
                settings.safetyBubbleBlend = blend
            }
            
            // ── Apply scene-level gradient / color settings ──────────────
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

            // Apply the current playhead state immediately so first rendered frame
            // does not momentarily show stale values from prior interaction.
            if let keyframe = interpolatedKeyframeAtCurrentPlayhead(in: scene) {
                applyKeyframe(keyframe)
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
        let clamped = max(0.0, min(1.0, normalized))
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
        
        settings.animationBaseMinDistance = keyframe.minDistance
        settings.animationBaseFoldingLimit = keyframe.foldingLimit
        settings.animationBaseSphereRadius = keyframe.sphereRadius
        settings.animationBaseFractalScale = keyframe.fractalScale
        settings.animationBasePosition = keyframe.position
        
        // Compose gesture (manual) AND music (audio) offsets into the targets so both
        // survive playback. minDistance/foldingLimit/sphereRadius music arrives via the
        // mandelbox formula path (audioOffset stays 0 for other types / non-music targets).
        let minDistance = keyframe.minDistance + settings.manualOffsetMinDistance + settings.audioOffsetMinDistance
        let foldingLimit = keyframe.foldingLimit + settings.manualOffsetFoldingLimit + settings.audioOffsetFoldingLimit
        let sphereRadius = keyframe.sphereRadius + settings.manualOffsetSphereRadius + settings.audioOffsetSphereRadius
        let position = keyframe.position + settings.manualOffsetPosition

        // Set IMMEDIATE values for responsive animation playback
        // This bypasses the renderer's interpolateToTargets() smoothing.
        // The music (audio) offset is folded into the live value here so the beat-driven
        // wiggle is full-amplitude and snappy; the gesture offset stays out of the live
        // value (it eases in via the target above) to preserve its smooth blend-in feel.
        settings.minDistance = keyframe.minDistance + settings.audioOffsetMinDistance
        settings.foldingLimit = keyframe.foldingLimit + settings.audioOffsetFoldingLimit
        settings.sphereRadius = keyframe.sphereRadius + settings.audioOffsetSphereRadius
        settings.fractalScale = keyframe.fractalScale + settings.audioOffsetFractalScale
        // Iteration budget: skip when the user has manually overridden it for
        // this scene. The override is cleared on every scene switch so the
        // scene's saved budget restores on first run.
        if !userIterationBudgetOverride {
            settings.baseFractalIterations = keyframe.baseFractalIterations
            settings.baseMaxRaySteps = keyframe.baseMaxRaySteps
        }
        settings.position = keyframe.position
        // Rotation (quaternion) and zoom (detailScale) use the same animationBase +
        // manual-override model as position/shape so a grab gesture overrides them even
        // when the scene animates these channels. Store the scene value as the base, then
        // compose the gesture override on top (quaternion compose for rotation, additive
        // for zoom) and write the composed result. Without this, applyKeyframe's per-frame
        // write stomped the grab every frame in any scene that animates rotation/zoom
        // (e.g. Ambient Blur), while scenes that don't (e.g. Kaleidoscope) appeared to work.
        settings.animationBaseDetailScale = keyframe.detailScale
        settings.animationBaseWorldRotation = keyframe.worldRotation
        // Floor keeps zoom positive if a wide-range scene drives the base small while a
        // grab holds a large negative additive offset (the smoothing logs would otherwise clamp).
        let composedDetailScale = max(0.01, keyframe.detailScale + settings.manualOffsetDetailScale)
        let composedRotation = (settings.manualRotationOffset * keyframe.worldRotation).normalized
        settings.detailScale = composedDetailScale
        settings.targetDetailScale = composedDetailScale
        settings.worldRotation = composedRotation
        settings.targetWorldRotation = composedRotation
        
        // Apply formula params for all types (unified path)
        if let vals = keyframe.formulaParamValues {
            settings.setAnimationBaseFormulaParams(vals)
        }

        // Legacy "mandelboxSphereProjection" scenes fold into base `.mandelbox` +
        // the Space-tab Sphere Projection. The old MSP type read projection
        // blend/radius from formula params[4]/[5] and always projected; reproduce
        // that here every frame so animated projection radius/blend tracks the
        // interpolated keyframe (e.g. Scene 9 / Kaleidoscope animate params[5]).
        if currentScene?.legacyMandelboxSphereProjection == true,
           let vals = keyframe.formulaParamValues, vals.count > 5 {
            settings.sphereProjectionEnabled = true
            settings.sphereProjectionBlend = vals[4]
            settings.sphereProjectionRadius = vals[5]
        }

          if let lightingMode = keyframe.lightingMode,
              settings.lightingMode != lightingMode {
            settings.lightingMode = lightingMode
        }
          if let lightingPreset = keyframe.lightingPreset,
              settings.lightingPreset != lightingPreset {
            settings.lightingPreset = lightingPreset
        }
        if let hueRotationEffect = keyframe.hueRotationEffect {
            settings.sceneDrivesHueSpeed = true
            settings.animationBaseHueSpeed = hueRotationEffect.speed
            if lastKeyframeHue != hueRotationEffect {
                lastKeyframeHue = hueRotationEffect
                settings.hueRotationEffect = hueRotationEffect
            }
            // Layer music on top of the scene's hue speed every frame (non-persisting).
            settings.audioModulateHueSpeed(hueRotationEffect.speed + settings.audioOffsetHueSpeed)
        } else {
            settings.sceneDrivesHueSpeed = false
            lastKeyframeHue = nil
        }
          if let pulseEffect = keyframe.pulseEffect,
              settings.pulseEffect != pulseEffect {
            settings.pulseEffect = pulseEffect
        }
        // Glow / Bloom / Fog: write the full effect struct (which persists + flips the
        // lighting preset to .custom) only when the scene's keyframe changes, then layer
        // gesture + music offsets on top every frame via the non-persisting audioModulate*
        // setters. Comparing against the cached raw keyframe (not the live, modulated
        // value) keeps the expensive persisting write from firing once music is active.
        if let glowEffect = keyframe.glowEffect {
            settings.sceneDrivesGlow = true
            settings.animationBaseGlowIntensity = glowEffect.intensity
            if lastKeyframeGlow != glowEffect {
                lastKeyframeGlow = glowEffect
                settings.glowEffect = glowEffect
            }
            settings.audioModulateGlowIntensity(glowEffect.intensity
                + settings.manualOffsetGlowIntensity
                + settings.audioOffsetGlowIntensity)
        } else {
            settings.sceneDrivesGlow = false
            lastKeyframeGlow = nil
        }
        if let bloomEffect = keyframe.bloomEffect {
            settings.sceneDrivesBloom = true
            settings.animationBaseBloomStrength = bloomEffect.strength
            if lastKeyframeBloom != bloomEffect {
                lastKeyframeBloom = bloomEffect
                settings.bloomEffect = bloomEffect
            }
            settings.audioModulateBloomStrength(bloomEffect.strength
                + settings.manualOffsetBloomStrength
                + settings.audioOffsetBloomStrength)
        } else {
            settings.sceneDrivesBloom = false
            lastKeyframeBloom = nil
        }
        if let fogEffect = keyframe.fogEffect {
            settings.sceneDrivesFog = true
            settings.animationBaseFogIntensity = fogEffect.intensity
            if lastKeyframeFog != fogEffect {
                lastKeyframeFog = fogEffect
                settings.fogEffect = fogEffect
            }
            settings.audioModulateFogIntensity(fogEffect.intensity
                + settings.manualOffsetFogIntensity
                + settings.audioOffsetFogIntensity)
        } else {
            settings.sceneDrivesFog = false
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
            settings.sceneDrivesSaturation = true
            settings.animationBaseSaturation = sat
            if lastKeyframeSaturation != sat {
                lastKeyframeSaturation = sat
                settings.colorSchemeSaturation = max(0.0, min(3.0, sat))
            }
            settings.audioModulateSaturation(sat
                + settings.manualOffsetSaturation
                + settings.audioOffsetSaturation)
        } else {
            settings.sceneDrivesSaturation = false
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
        
        // Also set TARGETS so they're in sync when animation stops
        // This allows hand gestures to blend in naturally
        settings.targetMinDistance = minDistance
        settings.targetFoldingLimit = foldingLimit
        settings.targetSphereRadius = sphereRadius
        settings.targetFractalScale = keyframe.fractalScale + settings.manualOffsetFractalScale + settings.audioOffsetFractalScale
        settings.targetPosition = position
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
            // Load user scenes
            if FileManager.default.fileExists(atPath: scenesFileURL.path) {
                do {
                    let data = try Data(contentsOf: scenesFileURL)
                    userScenes = try sceneDecoder.decode([AnimationScene].self, from: data)
                    print("📂 Loaded \(userScenes.count) user scenes")
                } catch {
                    // Main file is corrupt — recover from the newest backup
                    // rather than starting empty (which a later save would
                    // persist over the only good copy).
                    print("❌ Failed to load scenes: \(error) — attempting backup recovery")
                    userScenes = loadLatestBackupScenes()
                }
            } else {
                // No main file: a backup may still exist (e.g. file lost but
                // backups survived). Recover if so.
                let recovered = loadLatestBackupScenes()
                if !recovered.isEmpty {
                    userScenes = recovered
                } else {
                    print("📂 No saved user scenes found")
                }
            }

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

        print("📂 Defaults: \(DefaultScenes.allIDs.count) built-in, \(hiddenDefaultSceneIDs.count) hidden, \(editedDefaultOverrides.count) edited")
    }
    
    private func saveScenes() {
        do {
            let data = try prettySceneEncoder.encode(userScenes)
            try data.write(to: scenesFileURL, options: .atomic)
            writeSceneBackup(data: data)
            print("💾 Saved \(userScenes.count) user scenes")
        } catch {
            print("❌ Failed to save scenes: \(error)")
        }
    }

    /// Replace all user scenes with the given array and persist.
    func replaceUserScenes(with scenes: [AnimationScene]) {
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
        
        recordingSamples = []
        recordingStartTime = CACurrentMediaTime()
        recordingFractalType = renderSettings?.fractalType
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
        
        // Capture scene-level color grading from current settings
        if let settings = renderSettings {
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
            let scaleDelta = abs(curr.detailScale - prev.detailScale)
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
                || scaleDelta > 0.01
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
