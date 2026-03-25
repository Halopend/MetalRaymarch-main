import Foundation

@MainActor
@Observable
final class AnimationManager {
    var currentScene: AnimationScene?
    private(set) var userScenes: [AnimationScene] = []
    private(set) var scenes: [AnimationScene] = []
    var hiddenDefaultScenes: [AnimationScene] { [] }

    var isPlaying: Bool = false
    var isRecording: Bool = false
    var playbackSpeed: Float = 1.0
    var easingFunction: EasingFunction = .smooth
    var uiPlayhead: AnimationPlayhead = .init()

    var preparePipelineHandler: ((Int, Int) -> Void)?
    var playSongHandler: ((AttachedSong) -> Void)?

    private weak var renderSettings: RenderSettings?

    init(renderSettings: RenderSettings? = nil) {
        self.renderSettings = renderSettings
    }

    func setRenderSettings(_ settings: RenderSettings) {
        self.renderSettings = settings
    }

    func isDefaultScene(_ scene: AnimationScene) -> Bool { false }
    func isEditedDefault(_ scene: AnimationScene) -> Bool { false }
    func resetDefaultScene(_ id: UUID) {}
    func restoreDefaultScene(_ id: UUID) {}

    @discardableResult
    func createScene(name: String) -> AnimationScene {
        let scene = AnimationScene(name: name, initialKeyframe: renderSettings.map { AnimationKeyframe(from: $0, name: "Start", duration: 0) }, fractalType: renderSettings?.fractalType)
        userScenes.append(scene)
        scenes = userScenes
        currentScene = scene
        return scene
    }

    func deleteScene(_ scene: AnimationScene) {
        userScenes.removeAll { $0.id == scene.id }
        scenes = userScenes
        if currentScene?.id == scene.id {
            currentScene = scenes.first
        }
    }

    func updateScene(_ scene: AnimationScene) {
        if let idx = userScenes.firstIndex(where: { $0.id == scene.id }) {
            userScenes[idx] = scene
        } else {
            userScenes.append(scene)
        }
        scenes = userScenes
        if currentScene?.id == scene.id { currentScene = scene }
    }

    func updateKeyframe(_ keyframe: AnimationKeyframe, in sceneID: UUID) {
        guard let sidx = userScenes.firstIndex(where: { $0.id == sceneID }) else { return }
        guard let kidx = userScenes[sidx].keyframes.firstIndex(where: { $0.id == keyframe.id }) else { return }
        userScenes[sidx].keyframes[kidx] = keyframe
        scenes = userScenes
    }

    func addKeyframe(to scene: AnimationScene, duration: TimeInterval = 2.0) {
        guard let settings = renderSettings else { return }
        guard let idx = userScenes.firstIndex(where: { $0.id == scene.id }) else { return }
        userScenes[idx].addKeyframe(from: settings, duration: duration)
        scenes = userScenes
    }

    func play() {
        guard currentScene != nil else { return }
        isPlaying = true
        uiPlayhead.state = .playing
    }

    func stop() {
        isPlaying = false
        uiPlayhead.state = .stopped
        uiPlayhead.currentKeyframeIndex = 0
        uiPlayhead.elapsedInSegment = 0
    }

    func togglePlayPause() {
        if isPlaying {
            isPlaying = false
            uiPlayhead.state = .paused
        } else {
            guard currentScene != nil else { return }
            isPlaying = true
            uiPlayhead.state = .playing
        }
    }

    func disablePlaybackOverrides() {
        stop()
    }

    func jumpToKeyframe(_ index: Int) {
        uiPlayhead.currentKeyframeIndex = max(0, index)
        uiPlayhead.elapsedInSegment = 0
    }

    func jumpToTime(_ time: TimeInterval) {
        uiPlayhead.elapsedInSegment = max(0, time)
    }

    func update(deltaTime: TimeInterval) {
        guard isPlaying else { return }
        uiPlayhead.elapsedInSegment += max(0, deltaTime) * Double(playbackSpeed)
    }

    func replaceUserScenes(with scenes: [AnimationScene]) {
        userScenes = scenes
        self.scenes = scenes
        if let current = currentScene, !scenes.contains(where: { $0.id == current.id }) {
            currentScene = scenes.first
        }
    }

    func exportSceneToFile(_ scene: AnimationScene) -> URL? {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        let name = scene.name.replacingOccurrences(of: " ", with: "_")
        let url = docs.appendingPathComponent("\(name).threshanim")
        do {
            let data = try JSONEncoder().encode(scene)
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    func startRecording() {
        isRecording = true
    }

    @discardableResult
    func stopRecording() -> AnimationScene? {
        isRecording = false
        return nil
    }
}
