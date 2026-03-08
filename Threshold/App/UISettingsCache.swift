//
//  UISettingsCache.swift
//  Threshold
//
//  Local state that syncs with RenderSettings periodically to avoid lock contention.
//  Extracted from ContentView.swift for single-responsibility.
//

import SwiftUI

// MARK: - Cached UI Settings
// Local state that syncs with RenderSettings periodically to avoid lock contention
@MainActor
@Observable
final class UISettingsCache {
    let parameterOperationDispatcher = ParameterOperationDispatcher()
    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Domain Config Struct Backing Stores
    // These 7 structs replace ~84 individual stored properties.
    // Computed property shims below maintain backward compatibility with views.
    // ═══════════════════════════════════════════════════════════════════════════

    var color: ColorConfig = ColorConfig()
    var lighting: LightingConfig = LightingConfig()
    var audioReactive: AudioReactiveConfig = AudioReactiveConfig()
    var gesture: GestureConfig = GestureConfig()
    var safetyBubble: SafetyBubbleConfig = SafetyBubbleConfig()
    var quality: QualityConfig = QualityConfig()
    var display: DisplayConfig = DisplayConfig()

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Geometry (target values, not in any config struct)
    // ═══════════════════════════════════════════════════════════════════════════

    var fractalType: FractalModelType = .mandelbox
    var fractalScale: Float = 2.0
    var targetMinDistance: Float = 0.8
    var targetFoldingLimit: Float = 1.0
    var targetSphereRadius: Float = 0.5
    var formulaParams: FormulaParams = FractalModelType.mandelbox.defaultFormulaParams()

    // === SAVED CUSTOM GRADIENTS (persisted via UserDefaults) ===
    var savedCustomGradients: [GradientColorMap] = UISettingsCache.loadSavedGradients()
    
    static func loadSavedGradients() -> [GradientColorMap] {
        guard let data = UserDefaults.standard.data(forKey: "savedCustomGradients"),
              let gradients = try? JSONDecoder().decode([GradientColorMap].self, from: data) else { return [] }
        return gradients
    }
    
    func saveSavedGradients() {
        if let data = try? JSONEncoder().encode(savedCustomGradients) {
            UserDefaults.standard.set(data, forKey: "savedCustomGradients")
        }
    }
    
    func saveCurrentGradientAsCustom() {
        var copy = color.gradientState.gradient
        // Give it a unique name
        let existingCount = savedCustomGradients.count
        copy = GradientColorMap(name: "Custom \(existingCount + 1)", stops: copy.stops,
                                 mappingMode: copy.mappingMode, repeatCount: copy.repeatCount,
                                 offset: copy.offset, smoothing: copy.smoothing)
        savedCustomGradients.append(copy)
        saveSavedGradients()
    }
    
    func deleteSavedGradient(at index: Int) {
        guard index >= 0 && index < savedCustomGradients.count else { return }
        savedCustomGradients.remove(at: index)
        saveSavedGradients()
    }
    
    func renameSavedGradient(at index: Int, to newName: String) {
        guard index >= 0 && index < savedCustomGradients.count else { return }
        savedCustomGradients[index].name = newName
        saveSavedGradients()
    }
    
    /// Overwrite a saved gradient's stops/settings with the current editor state
    func updateSavedGradient(at index: Int) {
        guard index >= 0 && index < savedCustomGradients.count else { return }
        let name = savedCustomGradients[index].name
        savedCustomGradients[index] = GradientColorMap(
            name: name, stops: color.gradientState.gradient.stops,
            mappingMode: color.gradientState.gradient.mappingMode,
            repeatCount: color.gradientState.gradient.repeatCount,
            offset: color.gradientState.gradient.offset,
            smoothing: color.gradientState.gradient.smoothing
        )
        saveSavedGradients()
    }
    
    func applySavedGradient(_ gradient: GradientColorMap) {
        color.gradientState.gradient = gradient
        color.gradientState.gradientPreset = nil  // Mark as custom
        settings?.gradientColorMap = gradient
    }
    
    var currentRenderQuality: Float = 0.7  // Live stat, not in config struct
    
    // === LIVE STATS (synced from render settings periodically) ===
    // These eliminate direct appModel.renderSettings reads from SwiftUI views,
    // preventing lock contention on the main thread during body evaluation.
    var liveFractalIterations: Int = 9
    var liveMaxRaySteps: Int = 64
    var liveFractalScale: Float = 2.8
    var livePosition: SIMD3<Float> = .zero
    var liveDetailScale: Float = 1.0
    var liveWorldRotation: simd_quatf = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    var liveFPS: Double = 0  // Mirrors appModel.fps without triggering @Observable invalidation
    
    private weak var _appModel: AppModel?
    private var syncTimer: Timer?
    private weak var settings: RenderSettings?
    var renderSettings: RenderSettings? { settings }
    
    func startSync(with settings: RenderSettings, appModel: AppModel) {
        self.settings = settings
        self._appModel = appModel
        loadFromSettings()
        syncTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.syncLiveStats()
        }
    }
    
    func stopSync() {
        syncTimer?.invalidate()
        syncTimer = nil
    }
    
    private func syncLiveStats() {
        guard let settings else { return }
        currentRenderQuality = settings.currentRenderQuality
        liveFractalIterations = settings.fractalIterations
        liveMaxRaySteps = settings.maxRaySteps
        liveFractalScale = settings.fractalScale
        livePosition = settings.position
        liveDetailScale = settings.detailScale
        liveWorldRotation = settings.worldRotation
        if let appModel = _appModel {
            liveFPS = appModel.fps
        }
    }
    
    func loadFromSettings() {
        guard let settings else { return }

        // ── Config struct snapshots (7 domain assignments replace ~95 individual lines) ──
        color = settings.colorConfig
        lighting = settings.lightingConfig
        audioReactive = settings.audioReactiveConfig
        gesture = settings.gestureConfig
        safetyBubble = settings.safetyBubbleConfig
        quality = settings.qualityConfig
        display = settings.displayConfig

        // ── Geometry (target values, not in any config struct) ──
        let geo = settings.geometryConfig
        fractalType = geo.fractalType
        formulaParams = geo.formulaParams
        fractalScale = settings.targetFractalScale
        targetMinDistance = settings.targetMinDistance
        targetFoldingLimit = settings.targetFoldingLimit
        targetSphereRadius = settings.targetSphereRadius

        // ── Live stat ──
        currentRenderQuality = settings.currentRenderQuality
    }
    
    @inline(__always)
    func push<T>(_ keyPath: WritableKeyPath<RenderSettings, T>, value: T) {
        settings?[keyPath: keyPath] = value
    }

    func dispatchParameterOperation(_ operation: ParameterOperation) {
        parameterOperationDispatcher.dispatch([operation], cache: self)
    }

    

    // ── GestureSlot-based binding helpers ──────────────────────────────────

    func gestureBinding(for slot: GestureSlot) -> GestureActionBinding {
        gesture.gestureBindings[slot.persistenceKey] ?? .core(.none)
    }

    func setGestureBinding(_ binding: GestureActionBinding, for slot: GestureSlot) {
        // RenderSettings.setBinding handles validation + mutual exclusion + persistence.
        settings?.setBinding(binding, for: slot)
        // Re-sync all 9 slots from the authoritative RenderSettings so the UI
        // reflects any cascade clears from mutual exclusion enforcement.
        if let settings = settings {
            for s in GestureSlot.allSlots {
                gesture.gestureBindings[s.persistenceKey] = settings.binding(for: s)
            }
        } else {
            gesture.gestureBindings[slot.persistenceKey] = binding
        }
    }

    func gestureSlot(for binding: GestureActionBinding) -> GestureSlot? {
        for slot in GestureSlot.allSlots {
            if gesture.gestureBindings[slot.persistenceKey] == binding { return slot }
        }
        return nil
    }

    @MainActor
    func pushFractalType(_ type: FractalModelType, gestureController: GestureController?) {
        let oldType = settings?.fractalType
        settings?.fractalType = type
        if oldType != type {
            // Clear stale formula parameter layer stacks from the old type
            parameterOperationDispatcher.clearFormulaStacks()
            gestureController?.applyFractalDefaults()
            loadFromSettings()
        }
    }
    
    func pushColorScheme(_ scheme: ColorScheme) {
        settings?.transitionToColorScheme(scheme)
        color.colorScheme = scheme
    }
    
    func pushGradientMap(_ map: GradientColorMap) {
        settings?.gradientColorMap = map
    }
    
    func applyGradientPreset(_ preset: GradientPreset) {
        settings?.applyGradientPreset(preset)
        color.gradientState.gradient = preset.makeGradient()
        color.gradientState.gradientPreset = preset
        let pp = preset.postProcessing
        color.colorSchemeSaturation = pp.saturation
        color.colorSchemeContrast = pp.contrast
        color.colorSchemeGamma = pp.gamma
    }
    
    /// Update a single formula param slot and push the entire struct to RenderSettings.
    /// Routes through the parameter operation dispatcher so layer precedence is respected.
    func pushFormulaParam(index: Int, value: Float) {
        guard let settings else { return }
        let targetID = "formula.\(settings.fractalType.rawValue).\(index)"
        let op = ParameterOperation(
            targetID: targetID,
            source: .slider,
            value: value,
            frameIndex: 0
        )
        parameterOperationDispatcher.dispatch([op], cache: self)
    }
    
    /// Reset formula params to defaults for the current type and push.
    func resetFormulaParams() {
        formulaParams = fractalType.defaultFormulaParams()
        settings?.formulaParams = formulaParams
    }
    
    func reloadLightingEffects() {
        guard let settings = settings else { return }
        lighting = settings.lightingConfig
    }
}

extension UISettingsCache {
    static func blendValueToSlider(_ value: Float) -> Float {
        sqrt(max(0.0, min(1.0, value)))
    }

    static func blendSliderToValue(_ slider: Float) -> Float {
        let clamped = max(0.0, min(1.0, slider))
        return clamped * clamped
    }
}
