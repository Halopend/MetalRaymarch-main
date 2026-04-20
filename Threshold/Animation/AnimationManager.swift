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
    @ObservationIgnored private let prettySceneEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
    
    // ═══════════════════════════════════════════════════════════════════════════
    // SCENE STORAGE
    // ═══════════════════════════════════════════════════════════════════════════
    
    // Coalesced persistence — avoids redundant UserDefaults writes during rapid edits
    @ObservationIgnored private var pendingSaveHidden = false
    @ObservationIgnored private var pendingSaveOverrides = false
    @ObservationIgnored private var saveCoalesceTask: Task<Void, Never>?
    
    /// User-created scenes (persisted to disk)
    private(set) var userScenes: [AnimationScene] = [] {
        didSet { rebuildScenes() }
    }
    
    /// Default scene IDs the user has hidden (persisted via UserDefaults)
    private(set) var hiddenDefaultSceneIDs: Set<UUID> = [] {
        didSet { pendingSaveHidden = true; scheduleSaveFlush(); rebuildScenes() }
    }
    
    /// User-edited copies of default scenes (persisted alongside user scenes).
    /// Key = default scene ID → Value = the user's edited version.
    /// When present, this overlay replaces the built-in original in the list.
    private(set) var editedDefaultOverrides: [UUID: AnimationScene] = [:] {
        didSet { pendingSaveOverrides = true; scheduleSaveFlush(); rebuildScenes() }
    }
    
    /// The merged list exposed to the UI: visible defaults (possibly overridden) + user scenes.
    /// Cached — rebuilt automatically when underlying data changes.
    private(set) var scenes: [AnimationScene] = []
    
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
    
    /// Whether animation is currently playing.
    /// Reads from observed `uiPlayhead` so SwiftUI correctly tracks state changes.
    var isPlaying: Bool {
        uiPlayhead.state == .playing
    }
    
    // ═══════════════════════════════════════════════════════════════════════════
    // GESTURE RECORDING
    // ═══════════════════════════════════════════════════════════════════════════
    
    /// Whether we are currently recording gestures
    var isRecording: Bool = false
    
    /// Accumulated timestamped samples during recording
    @ObservationIgnored private var recordingSamples: [(time: TimeInterval, keyframe: AnimationKeyframe)] = []
    
    /// When recording started (monotonic clock)
    @ObservationIgnored private var recordingStartTime: TimeInterval = 0
    
    /// Background task driving the sampling loop
    @ObservationIgnored private var recordingTask: Task<Void, Never>?
    
    /// Sample rate for recording (samples per second)
    private static let recordingSampleRate: Double = 5.0
    
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
    
    // ═══════════════════════════════════════════════════════════════════════════
    // FILE STORAGE
    // ═══════════════════════════════════════════════════════════════════════════
    
    private let scenesFileName = "animation_scenes.json"
    
    private var scenesFileURL: URL {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documentsPath.appendingPathComponent(scenesFileName)
    }
    
    // ═══════════════════════════════════════════════════════════════════════════
    // INITIALIZATION
    // ═══════════════════════════════════════════════════════════════════════════
    
    init(renderSettings: RenderSettings? = nil) {
        self.renderSettings = renderSettings
        loadScenes()
        rebuildScenes()
    }
    
    func setRenderSettings(_ settings: RenderSettings) {
        self.renderSettings = settings
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
            hiddenDefaultSceneIDs.insert(scene.id)
            editedDefaultOverrides.removeValue(forKey: scene.id)
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
    
    /// Add current settings as a new keyframe to the specified scene
    func addKeyframeToScene(_ sceneID: UUID, duration: TimeInterval = 2.0) {
        guard let settings = renderSettings else { return }
        
        if DefaultScenes.isDefault(sceneID) {
            // Edit the overlay (create one from the original if needed)
            var overlay = editedDefaultOverrides[sceneID]
                ?? DefaultScenes.all().first { $0.id == sceneID }
                ?? AnimationScene(name: "Unknown")
            overlay.addKeyframe(from: settings, duration: duration)
            editedDefaultOverrides[sceneID] = overlay
            if currentScene?.id == sceneID { currentScene = overlay }
        } else if let index = userScenes.firstIndex(where: { $0.id == sceneID }) {
            userScenes[index].addKeyframe(from: settings, duration: duration)
            if currentScene?.id == sceneID { currentScene = userScenes[index] }
            saveScenes()
        }
        
        print("➕ Added keyframe to scene")
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
    
    /// Overwrite a keyframe at the given index with current render settings.
    /// Preserves the keyframe's name, duration, and ID.
    func overwriteKeyframe(at index: Int, in sceneID: UUID) {
        guard let settings = renderSettings else { return }
        var scene: AnimationScene?
        if DefaultScenes.isDefault(sceneID) {
            scene = editedDefaultOverrides[sceneID]
                ?? DefaultScenes.all().first { $0.id == sceneID }
        } else if let si = userScenes.firstIndex(where: { $0.id == sceneID }) {
            scene = userScenes[si]
        }
        guard var s = scene, s.keyframes.indices.contains(index) else { return }
        
        var kf = AnimationKeyframe(from: settings, name: s.keyframes[index].name, duration: s.keyframes[index].duration)
        kf.id = s.keyframes[index].id
        s.keyframes[index] = kf
        updateScene(s)
    }
    
    /// Update a specific keyframe in a scene
    func updateKeyframe(_ keyframe: AnimationKeyframe, in sceneID: UUID) {
        if DefaultScenes.isDefault(sceneID) {
            var overlay = editedDefaultOverrides[sceneID]
                ?? DefaultScenes.all().first { $0.id == sceneID }
                ?? AnimationScene(name: "Unknown")
            if let kfIdx = overlay.keyframes.firstIndex(where: { $0.id == keyframe.id }) {
                overlay.keyframes[kfIdx] = keyframe
                overlay.modifiedAt = Date()
                editedDefaultOverrides[sceneID] = overlay
                if currentScene?.id == sceneID { currentScene = overlay }
            }
        } else if let sceneIndex = userScenes.firstIndex(where: { $0.id == sceneID }),
                  let kfIdx = userScenes[sceneIndex].keyframes.firstIndex(where: { $0.id == keyframe.id }) {
            userScenes[sceneIndex].keyframes[kfIdx] = keyframe
            userScenes[sceneIndex].modifiedAt = Date()
            if currentScene?.id == sceneID { currentScene = userScenes[sceneIndex] }
            saveScenes()
        }
    }
    
    // ═══════════════════════════════════════════════════════════════════════════
    // PLAYBACK CONTROLS
    // ═══════════════════════════════════════════════════════════════════════════
    
    /// Start playing the current scene
    func play() {
        guard currentScene != nil else {
            print("⚠️ No scene selected for playback")
            return
        }
        guard (currentScene?.keyframes.count ?? 0) >= 2 else {
            print("⚠️ Scene needs at least 2 keyframes to play")
            return
        }
        
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
        
        // Auto-play attached song when scene starts
        if let song = currentScene?.attachedSong {
            playSongHandler?(song)
        }
    }

    /// Disable user/gesture overrides during playback and re-apply scene-driven
    /// values at the current playhead position.
    func disablePlaybackOverrides() {
        guard let settings = renderSettings,
              let scene = currentScene,
              scene.keyframes.count >= 1 else { return }

        settings.clearAnimationManualOffsets()

        if let keyframe = interpolatedKeyframeAtCurrentPlayhead(in: scene) {
            applyKeyframe(keyframe)
        }
    }
    
    /// Pause playback
    func pause() {
        playhead.state = .paused
        uiPlayhead = playhead
        renderSettings?.isAnimationPlaying = false
        renderSettings?.commitAnimationOffsetsToTargets()
    }
    
    /// Stop playback and reset to beginning
    func stop() {
        playhead.state = .stopped
        playhead.reset()
        uiPlayhead = playhead
        renderSettings?.isAnimationPlaying = false
        renderSettings?.commitAnimationOffsetsToTargets()
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
    
    /// Jump to a specific time across the entire scene's duration
    func jumpToTime(_ time: TimeInterval) {
        guard let scene = currentScene, !scene.keyframes.isEmpty else { return }
        let keyframes = scene.keyframes
        
        if keyframes.count == 1 {
            jumpToKeyframe(0)
            return
        }
        
        let total = scene.totalDuration
        let targetTime = max(0, min(time, total)) // clamp
        
        var accumulated: TimeInterval = 0
        var foundIndex = 0
        var segmentElapsed: TimeInterval = 0
        
        for i in 0..<(keyframes.count - 1) {
            let segDuration = segmentDuration(for: keyframes, toIndex: i + 1)
            let remaining = targetTime - accumulated
            if remaining <= segDuration { // found the segment
                foundIndex = i
                segmentElapsed = remaining
                break
            }
            accumulated += segDuration
            if i == keyframes.count - 2 { // edge case: last segment
                foundIndex = i
                segmentElapsed = segDuration // max out the last segment
            }
        }
        
        playhead.currentKeyframeIndex = foundIndex
        playhead.elapsedInSegment = segmentElapsed
        uiPlayhead = playhead
        
        // Disable scene overrides and re-apply directly at current location
        disablePlaybackOverrides()
    }
    
    /// Calculate current total time of the playhead
    var currentTime: TimeInterval {
        guard let scene = currentScene else { return 0 }
        let keyframes = scene.keyframes
        guard playhead.currentKeyframeIndex < keyframes.count else { return 0 }
        
        var accumulated: TimeInterval = 0
        for i in 0..<playhead.currentKeyframeIndex {
            accumulated += segmentDuration(for: keyframes, toIndex: i + 1)
        }
        return accumulated + playhead.elapsedInSegment
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
    
    /// Update animation state. Call this every frame with delta time.
    /// - Parameter deltaTime: Time since last frame in seconds
    func update(deltaTime: TimeInterval) {
        guard playhead.state == .playing,
              let scene = currentScene,
              scene.keyframes.count >= 2 else { return }
        let keyframes = scene.keyframes
        let keyframeCount = keyframes.count
        let mode = scene.playbackMode

        // Advance time
        playhead.elapsedInSegment += deltaTime * playbackSpeed

        // Resolve the current segment (from → to) based on playback mode.
        // `fromIndex` is the keyframe we started the segment at.
        // `toIndex`   is the keyframe we are interpolating toward.
        var fromIndex = playhead.currentKeyframeIndex
        var toIndex: Int
        var goingForward = mode == .forward ? true : (mode == .reverse ? false : playhead.isGoingForward)

        if goingForward {
            toIndex = fromIndex + 1
            if toIndex >= keyframeCount {
                switch mode {
                case .forward:
                    if scene.isLooping { toIndex = 0 } else { stop(); return }
                case .pingPong:
                    // Bounce: reverse direction, go back one step
                    playhead.isGoingForward = false
                    goingForward = false
                    toIndex = fromIndex - 1
                    if toIndex < 0 { stop(); return }  // only 2 KF edge case
                case .reverse:
                    break  // unreachable
                }
            }
        } else {
            toIndex = fromIndex - 1
            if toIndex < 0 {
                switch mode {
                case .reverse:
                    if scene.isLooping {
                        toIndex = keyframeCount - 1
                    } else { stop(); return }
                case .pingPong:
                    // Bounce: forward again
                    playhead.isGoingForward = true
                    goingForward = true
                    toIndex = fromIndex + 1
                    if toIndex >= keyframeCount { stop(); return }
                case .forward:
                    break  // unreachable
                }
            }
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

            if goingForward {
                toIndex = fromIndex + 1
                if toIndex >= keyframeCount {
                    switch mode {
                    case .forward:
                        if scene.isLooping { toIndex = 0 } else { stop(); return }
                    case .pingPong:
                        playhead.isGoingForward = false
                        goingForward = false
                        toIndex = fromIndex - 1
                        if toIndex < 0 { stop(); return }
                    case .reverse:
                        break
                    }
                }
            } else {
                toIndex = fromIndex - 1
                if toIndex < 0 {
                    switch mode {
                    case .reverse:
                        if scene.isLooping { toIndex = keyframeCount - 1 } else { stop(); return }
                    case .pingPong:
                        playhead.isGoingForward = true
                        goingForward = true
                        toIndex = fromIndex + 1
                        if toIndex >= keyframeCount { stop(); return }
                    case .forward:
                        break
                    }
                }
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

        // Determine effective easing: per-keyframe overrides global
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
        
        let minDistance = keyframe.minDistance + settings.manualOffsetMinDistance
        let foldingLimit = keyframe.foldingLimit + settings.manualOffsetFoldingLimit
        let sphereRadius = keyframe.sphereRadius + settings.manualOffsetSphereRadius
        let position = keyframe.position + settings.manualOffsetPosition
        
        // Set IMMEDIATE values for responsive animation playback
        // This bypasses the renderer's interpolateToTargets() smoothing
        settings.minDistance = keyframe.minDistance
        settings.foldingLimit = keyframe.foldingLimit
        settings.sphereRadius = keyframe.sphereRadius
        settings.fractalScale = keyframe.fractalScale
        settings.baseFractalIterations = keyframe.baseFractalIterations
        settings.baseMaxRaySteps = keyframe.baseMaxRaySteps
        settings.position = keyframe.position
        settings.detailScale = keyframe.detailScale
        settings.targetDetailScale = keyframe.detailScale
        settings.worldRotation = keyframe.worldRotation
        settings.targetWorldRotation = keyframe.worldRotation
        
        // Apply formula params for all types (unified path)
        if let vals = keyframe.formulaParamValues {
            settings.setAnimationBaseFormulaParams(vals)
        }

          if let lightingMode = keyframe.lightingMode,
              settings.lightingMode != lightingMode {
            settings.lightingMode = lightingMode
        }
          if let lightingPreset = keyframe.lightingPreset,
              settings.lightingPreset != lightingPreset {
            settings.lightingPreset = lightingPreset
        }
                    if let hueRotationEffect = keyframe.hueRotationEffect,
                            settings.hueRotationEffect != hueRotationEffect {
                        settings.hueRotationEffect = hueRotationEffect
        }
          if let pulseEffect = keyframe.pulseEffect,
              settings.pulseEffect != pulseEffect {
            settings.pulseEffect = pulseEffect
        }
          if let glowEffect = keyframe.glowEffect,
                            settings.glowEffect != glowEffect {
                        settings.animationBaseGlowIntensity = glowEffect.intensity
                        var resolvedEffect = glowEffect
                        resolvedEffect.intensity = max(0.0, min(1.0, glowEffect.intensity + settings.manualOffsetGlowIntensity))
                        settings.glowEffect = resolvedEffect
        }
          if let bloomEffect = keyframe.bloomEffect,
                            settings.bloomEffect != bloomEffect {
                        settings.animationBaseBloomStrength = bloomEffect.strength
                        var resolvedEffect = bloomEffect
                        resolvedEffect.strength = max(0.0, min(1.0, bloomEffect.strength + settings.manualOffsetBloomStrength))
                        settings.bloomEffect = resolvedEffect
        }
          if let fogEffect = keyframe.fogEffect,
                            settings.fogEffect != fogEffect {
                        settings.animationBaseFogIntensity = fogEffect.intensity
                        var resolvedEffect = fogEffect
                        resolvedEffect.intensity = max(0.0, min(1.0, fogEffect.intensity + settings.manualOffsetFogIntensity))
                        settings.fogEffect = resolvedEffect
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
            settings.animationBaseSaturation = sat
            settings.colorSchemeSaturation = max(0.0, min(3.0, sat + settings.manualOffsetSaturation))
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
        
        // Also set TARGETS so they're in sync when animation stops
        // This allows hand gestures to blend in naturally
        settings.targetMinDistance = minDistance
        settings.targetFoldingLimit = foldingLimit
        settings.targetSphereRadius = sphereRadius
        settings.targetFractalScale = keyframe.fractalScale + settings.manualOffsetFractalScale
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
        // Load user scenes
        if FileManager.default.fileExists(atPath: scenesFileURL.path) {
            do {
                let data = try Data(contentsOf: scenesFileURL)
                userScenes = try sceneDecoder.decode([AnimationScene].self, from: data)
                print("📂 Loaded \(userScenes.count) user scenes")
            } catch {
                print("❌ Failed to load scenes: \(error)")
            }
        } else {
            print("📂 No saved user scenes found")
        }
        
        // Load hidden default IDs
        if let ids = UserDefaults.standard.array(forKey: "hiddenDefaultSceneIDs") as? [String] {
            hiddenDefaultSceneIDs = Set(ids.compactMap { UUID(uuidString: $0) })
        }
        
        // Load edited default overrides
        if let data = UserDefaults.standard.data(forKey: "editedDefaultOverrides") {
            do {
                let overrides = try sceneDecoder.decode([AnimationScene].self, from: data)
                editedDefaultOverrides = Dictionary(uniqueKeysWithValues: overrides.map { ($0.id, $0) })
            } catch {
                print("❌ Failed to load default overrides: \(error)")
            }
        }
        
        print("📂 Defaults: \(DefaultScenes.allIDs.count) built-in, \(hiddenDefaultSceneIDs.count) hidden, \(editedDefaultOverrides.count) edited")
    }
    
    private func saveScenes() {
        do {
            let data = try prettySceneEncoder.encode(userScenes)
            try data.write(to: scenesFileURL)
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
    
    /// Export a scene to a shareable file URL
    func exportSceneToFile(_ scene: AnimationScene) -> URL? {
        let sanitizedName = scene.name.replacingOccurrences(of: " ", with: "_")
        // Use .threshanimv for scenes with attached music, .threshanim otherwise
        let ext = scene.attachedSong != nil ? "threshanimv" : "threshanim"
        let fileName = "\(sanitizedName).\(ext)"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)

        do {
            let data = try prettySceneEncoder.encode(scene)
            try data.write(to: tempURL)
            return tempURL
        } catch {
            print("❌ Failed to export scene file: \(error)")
            return nil
        }
    }
    
    // ═══════════════════════════════════════════════════════════════════════════
    // GESTURE RECORDING
    // ═══════════════════════════════════════════════════════════════════════════
    
    /// Start recording gestures. Samples RenderSettings at 5Hz until stopped.
    func startRecording() {
        guard renderSettings != nil else {
            print("⚠️ Cannot record — no render settings")
            return
        }
        
        // Stop any playback
        if isPlaying { stop() }
        
        recordingSamples = []
        recordingStartTime = CACurrentMediaTime()
        isRecording = true
        
        print("🔴 Recording started")
        
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
        recordingTask?.cancel()
        recordingTask = nil
        isRecording = false
        
        let samples = recordingSamples
        recordingSamples = []
        
        guard samples.count >= 2 else {
            print("⚠️ Recording too short — need at least 2 samples")
            return nil
        }
        
        print("🔴 Recording stopped — \(samples.count) samples over \(String(format: "%.1f", samples.last!.time))s")
        
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
        var scene = AnimationScene(name: "Recorded \(formattedTimestamp())")
        scene.keyframes = keyframes
        scene.isLooping = true
        scene.fractalType = renderSettings?.fractalType
        
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
        
        print("🎬 Created recorded scene '\(scene.name)' with \(keyframes.count) keyframes, duration \(String(format: "%.1f", scene.totalDuration))s")
        return scene
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
    
    private func formattedTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: Date())
    }
}
