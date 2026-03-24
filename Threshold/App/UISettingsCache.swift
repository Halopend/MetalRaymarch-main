//
//  UISettingsCache.swift
//  Threshold
//
//  Local state that syncs with RenderSettings periodically to avoid lock contention.
//  Extracted from ContentView.swift for single-responsibility.
//

import SwiftUI

// MARK: - Gradient Library
// Isolated @Observable so gradient mutations don't invalidate UISettingsCache observers
@MainActor
@Observable
final class GradientLibrary {
    var savedCustomGradients: [GradientColorMap] = GradientLibrary.load()

    static func load() -> [GradientColorMap] {
        guard let data = UserDefaults.standard.data(forKey: "savedCustomGradients"),
              let gradients = try? JSONDecoder().decode([GradientColorMap].self, from: data) else { return [] }
        return gradients
    }

    func persist() {
        if let data = try? JSONEncoder().encode(savedCustomGradients) {
            UserDefaults.standard.set(data, forKey: "savedCustomGradients")
        }
    }
}

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

    // === SAVED CUSTOM GRADIENTS (isolated in GradientLibrary to avoid observation cross-talk) ===
    let gradientLibrary = GradientLibrary()
    
    func saveCurrentGradientAsCustom() {
        var copy = color.gradientState.gradient
        let existingCount = gradientLibrary.savedCustomGradients.count
        copy = GradientColorMap(name: "Custom \(existingCount + 1)", stops: copy.stops,
                                 mappingMode: copy.mappingMode, repeatCount: copy.repeatCount,
                                 offset: copy.offset, smoothing: copy.smoothing)
        gradientLibrary.savedCustomGradients.append(copy)
        gradientLibrary.persist()
    }
    
    func deleteSavedGradient(at index: Int) {
        guard index >= 0 && index < gradientLibrary.savedCustomGradients.count else { return }
        gradientLibrary.savedCustomGradients.remove(at: index)
        gradientLibrary.persist()
    }
    
    func renameSavedGradient(at index: Int, to newName: String) {
        guard index >= 0 && index < gradientLibrary.savedCustomGradients.count else { return }
        gradientLibrary.savedCustomGradients[index].name = newName
        gradientLibrary.persist()
    }
    
    /// Overwrite a saved gradient's stops/settings with the current editor state
    func updateSavedGradient(at index: Int) {
        guard index >= 0 && index < gradientLibrary.savedCustomGradients.count else { return }
        let name = gradientLibrary.savedCustomGradients[index].name
        gradientLibrary.savedCustomGradients[index] = GradientColorMap(
            name: name, stops: color.gradientState.gradient.stops,
            mappingMode: color.gradientState.gradient.mappingMode,
            repeatCount: color.gradientState.gradient.repeatCount,
            offset: color.gradientState.gradient.offset,
            smoothing: color.gradientState.gradient.smoothing
        )
        gradientLibrary.persist()
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
            Task { @MainActor in
                self?.syncLiveStats()
            }
        }
    }
    
    func stopSync() {
        syncTimer?.invalidate()
        syncTimer = nil
    }
    
    private func syncLiveStats() {
        guard let settings else { return }
        // Skip syncing when app is backgrounded — no UI visible to update
        guard _appModel?.isAppActive ?? false else { return }
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

        // ── Config struct snapshots ──
        // Only assign when changed (Equatable check) to suppress no-op @Observable invalidation.
        let newColor = settings.colorConfig
        if color != newColor { color = newColor }
        let newLighting = settings.lightingConfig
        if lighting != newLighting { lighting = newLighting }
        let newAudioReactive = settings.audioReactiveConfig
        if audioReactive != newAudioReactive { audioReactive = newAudioReactive }
        let newGesture = settings.gestureConfig
        if gesture != newGesture { gesture = newGesture }
        let newSafetyBubble = settings.safetyBubbleConfig
        if safetyBubble != newSafetyBubble { safetyBubble = newSafetyBubble }
        let newQuality = settings.qualityConfig
        if quality != newQuality { quality = newQuality }
        let newDisplay = settings.displayConfig
        if display != newDisplay { display = newDisplay }

        // ── Geometry (target values, not in any config struct) ──
        let geo = settings.geometryConfig
        if fractalType != geo.fractalType { fractalType = geo.fractalType }
        formulaParams = geo.formulaParams
        let newScale = settings.targetFractalScale
        if fractalScale != newScale { fractalScale = newScale }
        let newMinDist = settings.targetMinDistance
        if targetMinDistance != newMinDist { targetMinDistance = newMinDist }
        let newFold = settings.targetFoldingLimit
        if targetFoldingLimit != newFold { targetFoldingLimit = newFold }
        let newSphere = settings.targetSphereRadius
        if targetSphereRadius != newSphere { targetSphereRadius = newSphere }

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
            value: .absolute(value),
            frameIndex: 0
        )
        parameterOperationDispatcher.dispatch([op], cache: self)
    }
    
    /// Reset formula params to defaults for the current type and push.
    func resetFormulaParams() {
        parameterOperationDispatcher.clearFormulaStacks()
        formulaParams = fractalType.defaultFormulaParams()
        if let settings, settings.isAnimationPlaying {
            settings.setManualFormulaParamOverrides((0..<16).map { FormulaCatalog.getParam(formulaParams, index: $0) })
            formulaParams = settings.formulaParams
        } else {
            settings?.formulaParams = formulaParams
        }
    }
    
    func reloadLightingEffects() {
        guard let settings = settings else { return }
        lighting = settings.lightingConfig
    }

    /// Route effect intensity/strength through the ParameterLayerStack so audio
    /// modulation combines additively with the slider value instead of overwriting it.
    func pushEffectParam(_ targetID: String, value: Float) {
        let op = ParameterOperation(
            targetID: targetID,
            source: .slider,
            value: .absolute(value),
            frameIndex: 0
        )
        parameterOperationDispatcher.dispatch([op], cache: self)
    }

    func commitHueRotationEffect() {
        push(\.hueRotationEffect, value: lighting.hueRotationEffect)
        pushEffectParam("effect.hueSpeed", value: lighting.hueRotationEffect.speed)
    }

    func commitPulseEffect() {
        push(\.pulseEffect, value: lighting.pulseEffect)
    }

    func commitGlowEffect() {
        guard let settings else { return }
        if settings.isAnimationPlaying {
            settings.manualOffsetGlowIntensity = lighting.glowEffect.intensity - settings.animationBaseGlowIntensity
            settings.glowEffect = lighting.glowEffect
        } else {
            push(\.glowEffect, value: lighting.glowEffect)
            pushEffectParam("effect.glow", value: lighting.glowEffect.intensity)
        }
    }

    func commitBloomEffect() {
        guard let settings else { return }
        if settings.isAnimationPlaying {
            settings.manualOffsetBloomStrength = lighting.bloomEffect.strength - settings.animationBaseBloomStrength
            settings.bloomEffect = lighting.bloomEffect
        } else {
            push(\.bloomEffect, value: lighting.bloomEffect)
            pushEffectParam("effect.bloom", value: lighting.bloomEffect.strength)
        }
    }

    func commitFogEffect() {
        guard let settings else { return }
        if settings.isAnimationPlaying {
            settings.manualOffsetFogIntensity = lighting.fogEffect.intensity - settings.animationBaseFogIntensity
            settings.fogEffect = lighting.fogEffect
        } else {
            push(\.fogEffect, value: lighting.fogEffect)
            pushEffectParam("effect.fog", value: lighting.fogEffect.intensity)
        }
    }

    func commitGradientCycleEffect() {
        push(\.gradientCycleEffect, value: lighting.gradientCycleEffect)
    }

    func commitBeatFlashEffect() {
        push(\.beatFlashEffect, value: lighting.beatFlashEffect)
    }

    func commitColorSchemeSaturation() {
        guard let settings else { return }
        if settings.isAnimationPlaying {
            settings.manualOffsetSaturation = color.colorSchemeSaturation - settings.animationBaseSaturation
            settings.colorSchemeSaturation = color.colorSchemeSaturation
        } else {
            push(\.colorSchemeSaturation, value: color.colorSchemeSaturation)
            pushEffectParam("effect.saturation", value: color.colorSchemeSaturation)
        }
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
