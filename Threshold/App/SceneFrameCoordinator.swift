import Foundation

/// Application adapter for the shared engine. All scene-affecting frame work
/// finishes together before a renderer is allowed to observe the result.
final class SceneFrameCoordinator: Sendable {
    private let settings: RenderSettings
    private let evaluator: SceneFrameEvaluator
    private let evaluate: @MainActor @Sendable (SceneFrameInput) -> EvaluatedSceneFrame

    nonisolated init(appModel: AppModel) {
        settings = appModel.renderSettings
        evaluator = appModel.sceneFrameEvaluator
        evaluate = { [weak appModel, settings = appModel.renderSettings] input in
            guard let appModel else { return EvaluatedSceneFrame.capture(settings, at: input.timestamp) }
            guard appModel.isAppActive else {
                return EvaluatedSceneFrame.capture(settings, at: input.timestamp)
            }
            // Capture callbacks may select another scene. Finish those before
            // entering the settings transaction, then evaluate that scene.
            appModel.audioHub.updateFrame()
            let audio = appModel.audioHub.latestSnapshot()
            return appModel.sceneFrameEvaluator.evaluate(
                input, settings: appModel.renderSettings,
                pipeline: appModel.parameterPipeline, audio: audio
            ) { delta in
                appModel.animationManager?.update(deltaTime: delta)
            }
        }
    }

    func frame(_ input: SceneFrameInput) -> EvaluatedSceneFrame {
        evaluator.request(input, settings: settings, evaluate: evaluate)
    }
}
