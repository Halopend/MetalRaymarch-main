//
//  AnimationManager.swift
//  MetalRaymarch
//
//  Manages scene playback, storage, and parameter interpolation.
//  Handles saving/loading scenes to disk and driving real-time animation.
//

import Foundation
import simd

@MainActor
@Observable
final class AnimationManager {
    
    // ═══════════════════════════════════════════════════════════════════════════
    // SCENE STORAGE
    // ═══════════════════════════════════════════════════════════════════════════
    
    /// All saved scenes
    private(set) var scenes: [AnimationScene] = []
    
    /// Currently selected scene for editing/playback
    var currentScene: AnimationScene? {
        didSet {
            // Reset playhead when scene changes
            if currentScene?.id != oldValue?.id {
                playhead.reset()
                playhead.sceneID = currentScene?.id
                
                // Precompile pipelines for all keyframes in this scene
                precompilePipelinesForCurrentScene()
            }
        }
    }
    
    // ═══════════════════════════════════════════════════════════════════════════
    // PLAYBACK STATE
    // ═══════════════════════════════════════════════════════════════════════════
    
    /// Current playback position and state
    var playhead = AnimationPlayhead()
    
    /// Global easing function for all transitions
    /// Default to .smooth for continuous motion through keyframes (no stopping)
    var easingFunction: EasingFunction = .smooth
    
    /// Playback speed multiplier (1.0 = normal, 2.0 = double speed, 0.5 = half speed)
    var playbackSpeed: Double = 1.0
    
    /// Whether animation is currently playing
    var isPlaying: Bool {
        playhead.state == .playing
    }
    
    // ═══════════════════════════════════════════════════════════════════════════
    // RENDER SETTINGS REFERENCE
    // ═══════════════════════════════════════════════════════════════════════════
    
    private weak var renderSettings: RenderSettings?
    
    /// Callback to prepare shader pipeline for specific iteration/step values
    /// Set this from AppModel to enable precompilation for animation keyframes
    var preparePipelineHandler: ((Int, Int) -> Void)?
    
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
            scenes.append(scene)
            saveScenes()
            return scene
        }
        
        var initialKeyframe = AnimationKeyframe(from: settings, name: "Start", duration: 0)
        initialKeyframe.duration = 0  // First keyframe is the starting point
        
        let scene = AnimationScene(name: name, initialKeyframe: initialKeyframe)
        scenes.append(scene)
        saveScenes()
        
        print("🎬 Created scene '\(name)' with initial keyframe")
        return scene
    }
    
    /// Delete a scene
    func deleteScene(_ scene: AnimationScene) {
        scenes.removeAll { $0.id == scene.id }
        if currentScene?.id == scene.id {
            currentScene = nil
            stop()
        }
        saveScenes()
        print("🗑️ Deleted scene '\(scene.name)'")
    }
    
    /// Update a scene (after editing keyframes)
    func updateScene(_ scene: AnimationScene) {
        if let index = scenes.firstIndex(where: { $0.id == scene.id }) {
            var updated = scene
            updated.modifiedAt = Date()
            scenes[index] = updated
            
            // Also update currentScene if it's the same
            if currentScene?.id == scene.id {
                currentScene = updated
            }
            
            saveScenes()
            print("💾 Updated scene '\(scene.name)'")
        }
    }
    
    /// Add current settings as a new keyframe to the specified scene
    func addKeyframeToScene(_ sceneID: UUID, duration: TimeInterval = 2.0) {
        guard let settings = renderSettings,
              let index = scenes.firstIndex(where: { $0.id == sceneID }) else { return }
        
        scenes[index].addKeyframe(from: settings, duration: duration)
        
        // Update currentScene if it's the same
        if currentScene?.id == sceneID {
            currentScene = scenes[index]
        }
        
        saveScenes()
        print("➕ Added keyframe to scene '\(scenes[index].name)'")
    }
    
    /// Remove a keyframe from scene
    func removeKeyframe(at keyframeIndex: Int, from sceneID: UUID) {
        guard let index = scenes.firstIndex(where: { $0.id == sceneID }) else { return }
        
        scenes[index].removeKeyframe(at: keyframeIndex)
        
        if currentScene?.id == sceneID {
            currentScene = scenes[index]
        }
        
        saveScenes()
    }
    
    /// Update a specific keyframe in a scene
    func updateKeyframe(_ keyframe: AnimationKeyframe, in sceneID: UUID) {
        guard let sceneIndex = scenes.firstIndex(where: { $0.id == sceneID }),
              let keyframeIndex = scenes[sceneIndex].keyframes.firstIndex(where: { $0.id == keyframe.id }) else { return }
        
        scenes[sceneIndex].keyframes[keyframeIndex] = keyframe
        scenes[sceneIndex].modifiedAt = Date()
        
        if currentScene?.id == sceneID {
            currentScene = scenes[sceneIndex]
        }
        
        saveScenes()
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
        
        // Ensure pipelines are compiled before playback
        precompilePipelinesForCurrentScene()
        
        playhead.state = .playing
        print("▶️ Playing scene '\(currentScene?.name ?? "?")'")  
    }
    
    /// Pause playback
    func pause() {
        playhead.state = .paused
        renderSettings?.isAnimationPlaying = false
        renderSettings?.commitAnimationOffsetsToTargets()
        print("⏸️ Paused")
    }
    
    /// Stop playback and reset to beginning
    func stop() {
        playhead.state = .stopped
        playhead.reset()
        renderSettings?.isAnimationPlaying = false
        renderSettings?.commitAnimationOffsetsToTargets()
        print("⏹️ Stopped")
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
    
    /// Update animation state. Call this every frame with delta time.
    /// - Parameter deltaTime: Time since last frame in seconds
    func update(deltaTime: TimeInterval) {
        guard playhead.state == .playing,
              let scene = currentScene,
              scene.keyframes.count >= 2 else { return }
        
        // Advance time
        playhead.elapsedInSegment += deltaTime * playbackSpeed
        
        // Get current and next keyframe indices
        var fromIndex = playhead.currentKeyframeIndex
        var toIndex = fromIndex + 1
        
        // Handle end of scene
        if toIndex >= scene.keyframes.count {
            if scene.isLooping {
                toIndex = 0  // Wrap to first keyframe
            } else {
                stop()
                return
            }
        }
        
        var fromKeyframe = scene.keyframes[fromIndex]
        var toKeyframe = scene.keyframes[toIndex]
        var segmentDuration = toIndex == 0 ? scene.keyframes[0].duration : toKeyframe.duration
        var actualDuration = segmentDuration > 0 ? segmentDuration : 2.0  // Default 2s if duration is 0
        
        // Check if current segment is complete - advance and carry over excess time
        while playhead.elapsedInSegment >= actualDuration {
            // Carry over excess time to next segment
            playhead.elapsedInSegment -= actualDuration
            
            // Move to next segment
            playhead.currentKeyframeIndex = toIndex
            fromIndex = toIndex
            toIndex = fromIndex + 1
            
            // Handle wrap
            if toIndex >= scene.keyframes.count {
                if scene.isLooping {
                    toIndex = 0
                } else {
                    stop()
                    return
                }
            }
            
            // Update keyframes for new segment
            fromKeyframe = scene.keyframes[fromIndex]
            toKeyframe = scene.keyframes[toIndex]
            segmentDuration = toIndex == 0 ? scene.keyframes[0].duration : toKeyframe.duration
            actualDuration = segmentDuration > 0 ? segmentDuration : 2.0
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
                scene.keyframes,
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
        
        // Also set TARGETS so they're in sync when animation stops
        // This allows hand gestures to blend in naturally
        settings.targetMinDistance = minDistance
        settings.targetFoldingLimit = foldingLimit
        settings.targetSphereRadius = sphereRadius
        settings.targetPosition = position
    }
    
    // ═══════════════════════════════════════════════════════════════════════════
    // PERSISTENCE
    // ═══════════════════════════════════════════════════════════════════════════
    
    private func loadScenes() {
        guard FileManager.default.fileExists(atPath: scenesFileURL.path) else {
            print("📂 No saved scenes found")
            return
        }
        
        do {
            let data = try Data(contentsOf: scenesFileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            scenes = try decoder.decode([AnimationScene].self, from: data)
            print("📂 Loaded \(scenes.count) scenes")
        } catch {
            print("❌ Failed to load scenes: \(error)")
        }
    }
    
    private func saveScenes() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(scenes)
            try data.write(to: scenesFileURL)
            print("💾 Saved \(scenes.count) scenes")
        } catch {
            print("❌ Failed to save scenes: \(error)")
        }
    }
    
    /// Export a scene to JSON string (for manual editing)
    func exportScene(_ scene: AnimationScene) -> String? {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(scene)
            return String(data: data, encoding: .utf8)
        } catch {
            print("❌ Failed to export scene: \(error)")
            return nil
        }
    }
    
    /// Import a scene from JSON string
    func importScene(from json: String) -> AnimationScene? {
        guard let data = json.data(using: .utf8) else { return nil }
        
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var scene = try decoder.decode(AnimationScene.self, from: data)
            
            // Capture all keyframes before re-creating with new ID
            let originalKeyframes = scene.keyframes
            
            // Give it a new ID to avoid conflicts
            scene = AnimationScene(
                name: scene.name + " (imported)",
                initialKeyframe: originalKeyframes.first ?? AnimationKeyframe(
                    name: "Default",
                    duration: 0,
                    minDistance: 0.8,
                    foldingLimit: 1.0,
                    sphereRadius: 0.5,
                    fractalScale: 2.8,
                    position: .zero
                )
            )
            
            // Append remaining keyframes from the original
            if originalKeyframes.count > 1 {
                scene.keyframes.append(contentsOf: originalKeyframes.dropFirst())
            }
            
            scenes.append(scene)
            saveScenes()
            return scene
        } catch {
            print("❌ Failed to import scene: \(error)")
            return nil
        }
    }
}
