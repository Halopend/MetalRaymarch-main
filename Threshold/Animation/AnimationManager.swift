//
//  AnimationManager.swift
//  Threshold
//
//  Manages scene playback, storage, and parameter interpolation.
//  Handles saving/loading scenes to disk and driving real-time animation.
//

import Foundation
import simd

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
    
    /// User-created scenes (persisted to disk)
    private(set) var userScenes: [AnimationScene] = []
    
    /// Default scene IDs the user has hidden (persisted via UserDefaults)
    private(set) var hiddenDefaultSceneIDs: Set<UUID> = [] {
        didSet { saveHiddenDefaults() }
    }
    
    /// User-edited copies of default scenes (persisted alongside user scenes).
    /// Key = default scene ID → Value = the user's edited version.
    /// When present, this overlay replaces the built-in original in the list.
    private(set) var editedDefaultOverrides: [UUID: AnimationScene] = [:] {
        didSet { saveOverrides() }
    }
    
    /// The merged list exposed to the UI: visible defaults (possibly overridden) + user scenes.
    var scenes: [AnimationScene] {
        var result: [AnimationScene] = []
        
        // 1. Built-in defaults (in order), unless hidden
        for defaultScene in DefaultScenes.all() {
            guard !hiddenDefaultSceneIDs.contains(defaultScene.id) else { continue }
            // Show the user's edited overlay if it exists, otherwise the original
            if let override = editedDefaultOverrides[defaultScene.id] {
                result.append(override)
            } else {
                result.append(defaultScene)
            }
        }
        
        // 2. User-created scenes
        result.append(contentsOf: userScenes)
        
        return result
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
                playhead.reset()
                playhead.sceneID = currentScene?.id
                uiPlayhead = playhead
                
                // Precompile pipelines for all keyframes in this scene
                precompilePipelinesForCurrentScene()
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
        return scene
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
        
        // Advance time
        playhead.elapsedInSegment += deltaTime * playbackSpeed
        
        // Get current and next keyframe indices
        var fromIndex = playhead.currentKeyframeIndex
        var toIndex = fromIndex + 1
        
        // Handle end of scene
        if toIndex >= keyframeCount {
            if scene.isLooping {
                toIndex = 0  // Wrap to first keyframe
            } else {
                stop()
                return
            }
        }
        
        var fromKeyframe = keyframes[fromIndex]
        var toKeyframe = keyframes[toIndex]
        var actualDuration = segmentDuration(for: keyframes, toIndex: toIndex)
        
        // Check if current segment is complete - advance and carry over excess time
        while playhead.elapsedInSegment >= actualDuration {
            // Carry over excess time to next segment
            playhead.elapsedInSegment -= actualDuration
            
            // Move to next segment
            playhead.currentKeyframeIndex = toIndex
            fromIndex = toIndex
            toIndex = fromIndex + 1
            
            // Handle wrap
            if toIndex >= keyframeCount {
                if scene.isLooping {
                    toIndex = 0
                } else {
                    stop()
                    return
                }
            }
            
            // Update keyframes for new segment
            fromKeyframe = keyframes[fromIndex]
            toKeyframe = keyframes[toIndex]
            actualDuration = segmentDuration(for: keyframes, toIndex: toIndex)
        }
        
        // Calculate progress through current segment (0 to 1)
        let rawProgress = Float(playhead.elapsedInSegment / actualDuration)
        
        // Interpolate using the appropriate method
        let interpolated: AnimationKeyframe
        
        // Determine effective easing: per-keyframe overrides global
        let effectiveEasing = toKeyframe.easingType
        
        if effectiveEasing.usesSplineInterpolation || (easingFunction.usesSplineInterpolation && effectiveEasing == .bezier) {
            // Use Catmull-Rom spline for smooth continuous motion through keyframes
            interpolated = CatmullRomSpline.interpolateKeyframes(
                keyframes,
                fromIndex: fromIndex,
                toIndex: toIndex,
                t: rawProgress,
                isLooping: scene.isLooping
            )
        } else if effectiveEasing.usesBezierHandles {
            // Per-keyframe cubic Bezier easing
            let easedProgress = CubicBezier.evaluate(rawProgress, handle: toKeyframe.bezierHandle)
            interpolated = fromKeyframe.interpolated(to: toKeyframe, t: easedProgress)
        } else {
            // Standard easing interpolation (slows to stop at each keyframe)
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
        settings.scale = keyframe.scale
        settings.position = keyframe.position
        settings.detailScale = keyframe.detailScale
        settings.targetDetailScale = keyframe.detailScale
        settings.worldRotation = keyframe.worldRotation
        settings.targetWorldRotation = keyframe.worldRotation
        
        // Apply formula params for all types (unified path)
        if let vals = keyframe.formulaParamValues {
            var fp = settings.formulaParams
            for i in 0..<min(16, vals.count) {
                FormulaCatalog.setParam(&fp, index: i, value: vals[i])
            }
            settings.formulaParams = fp
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
            settings.glowEffect = glowEffect
        }
          if let bloomEffect = keyframe.bloomEffect,
              settings.bloomEffect != bloomEffect {
            settings.bloomEffect = bloomEffect
        }
          if let fogEffect = keyframe.fogEffect,
              settings.fogEffect != fogEffect {
            settings.fogEffect = fogEffect
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
            settings.colorSchemeSaturation = sat
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
        var fromIndex = min(max(playhead.currentKeyframeIndex, 0), keyframeCount - 1)
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
    
}
