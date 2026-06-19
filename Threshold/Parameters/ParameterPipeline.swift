import Foundation

/// Shared owner for parameter-operation dispatch across UI, gesture, animation, and audio layers.
/// Keeps one authoritative layer-stack state for conflict resolution and smoothing continuity.
final class ParameterPipeline: @unchecked Sendable {
    private let dispatcher: ParameterOperationDispatcher

    init(dispatcher: ParameterOperationDispatcher = ParameterOperationDispatcher()) {
        self.dispatcher = dispatcher
    }

    func setDebugTraceEnabled(_ enabled: Bool) {
        dispatcher.debugTraceEnabled = enabled
    }

    @MainActor
    func dispatchUI(_ operations: [ParameterOperation], cache: UISettingsCache) {
        dispatcher.dispatch(operations, cache: cache)
    }

    func dispatchGesture(_ operations: [ParameterOperation], settings: RenderSettings) {
        dispatcher.dispatch(operations, settings: settings)
    }

    func dispatchAnimation(_ operations: [ParameterOperation], settings: RenderSettings) {
        dispatcher.dispatch(operations, settings: settings)
    }

    func dispatchAudio(_ operations: [ParameterOperation], settings: RenderSettings) {
        dispatcher.dispatch(operations, settings: settings)
    }

    func clearMusicLayers(settings: RenderSettings) {
        dispatcher.clearMusicLayers(settings: settings)
    }

    func clearFormulaStacks() {
        dispatcher.clearFormulaStacks()
    }

    /// Latest (base, resolved) snapshot for a target, for UI derived-value display.
    func liveValue(for targetID: String) -> ParameterOperationDispatcher.LiveValue? {
        dispatcher.liveValue(for: targetID)
    }
}
