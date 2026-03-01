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
    // Fractal parameters
    var fractalType: FractalModelType = .mandelbox
    var fractalScale: Float = 2.0
    var targetMinDistance: Float = 0.8
    var targetFoldingLimit: Float = 1.0
    var targetSphereRadius: Float = 0.5
    var baseFractalIterations: Int = 9
    var baseMaxRaySteps: Int = 64
    var formulaParams: FormulaParams = FractalModelType.mandelbox.defaultFormulaParams()
    
    // Color & effects
    var colorScheme: ColorScheme = .nebula
    var colorMix: Float = 0.5
    var colorIterations: Float = 8.0
    var colorSchemeAutoTransition: Bool = false
    var colorSchemeAutoInterval: Float = 30.0
    var colorSchemeTransitionDuration: Float = 2.0
    var colorSchemeSaturation: Float = 2.0
    var colorSchemeContrast: Float = 1.05
    var colorSchemeGamma: Float = 0.5
    var colorSchemeVibrance: Float = 1.0
    var colorSchemeCurve: Float = 0.0
    var colorSchemeShadows: Float = 0.0
    var colorSchemeHighlights: Float = 0.0
    
    // === GRADIENT COLORING SYSTEM ===
    var useGradientColoring: Bool = true
    var gradientColorMap: GradientColorMap = GradientPreset.nebula.makeGradient()
    var gradientPreset: GradientPreset? = .nebula
    var colorMappingMode: ColorMappingMode = .orbitTrap
    var gradientRepeat: Float = 1.0
    var gradientOffset: Float = 0.0
    var gradientSmoothing: Float = 1.0
    
    // === MODULAR LIGHTING EFFECTS ===
    var lightingPreset: LightingPreset = .off
    var hueRotationEffect: HueRotationEffect = .off
    var pulseEffect: PulseEffect = .off
    var glowEffect: GlowEffect = .off
    var bloomEffect: BloomEffect = .off
    var fogEffect: FogEffect = FogEffect(enabled: true, intensity: 0.32)
    var gradientCycleEffect: GradientCycleEffect = .off
    var polarRotationEffect: PolarRotationEffect = .off
    
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
        var copy = gradientColorMap
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
            name: name, stops: gradientColorMap.stops,
            mappingMode: gradientColorMap.mappingMode,
            repeatCount: gradientColorMap.repeatCount,
            offset: gradientColorMap.offset,
            smoothing: gradientColorMap.smoothing
        )
        saveSavedGradients()
    }
    
    func applySavedGradient(_ gradient: GradientColorMap) {
        gradientColorMap = gradient
        gradientPreset = nil  // Mark as custom
        settings?.gradientColorMap = gradient
        settings?.useGradientColoring = true
    }
    
    // Lighting - simplified
    var lightingMode: LightingMode = .animated
    var lightingSoftness: Float = 0.0
    
    // === MUSIC / AUDIO REACTIVITY ===
    var bassSensitivity: Float = 1.0
    var midSensitivity: Float = 1.0
    var trebleSensitivity: Float = 1.0
    var beatSensitivity: Float = 1.0
    var fractalAudioReactiveEnabled: Bool = true
    var fractalAudioAmount: Float = 0.6
    var fractalBeatPunch: Float = 0.7
    var fractalAudioAffectsScale: Bool = true
    var fractalAudioAffectsFolding: Bool = true
    var fractalAudioAffectsRadius: Bool = true
    var fractalAudioAffectsColorMix: Bool = true
    
    // === FRACTAL FORGE–INSPIRED EXTENDED AFFECTS ===
    var fractalAudioAffectsGlow: Bool = true
    var fractalAudioAffectsFog: Bool = true
    var fractalAudioAffectsBloom: Bool = true
    var fractalAudioAffectsHueSpeed: Bool = true
    var fractalAudioAffectsSaturation: Bool = true
    var fractalAudioAffectsIterations: Bool = false
    var musicReactiveMappings: [MusicReactiveMapping] = MusicReactiveMapping.defaultMappings()
    
    // Safety & display
    var showHUD: Bool = true
    var safetyBubbleEnabled: Bool = false
    var safetyBubbleRadius: Float = 1.8
    var safetyBubbleShape: Float = 0.0
    var useRelativeGestures: Bool = true
    var extendedGestureRange: Bool = true
    var rotationAutoSnap: Bool = false
    var rotationSnapWindowDegrees: Float = 6.0
    var gestureSensitivity: Float = 3.0
    var menuToggleGestureEnabled: Bool = true
    var menuToggleGestureMode: MenuToggleGestureMode = .middleAndRingToPalm
    // Configurable finger → action assignments
    var indexFingerBinding: GestureActionBinding = .core(.grab)
    var middleFingerBinding: GestureActionBinding = .core(.minDistance)
    var ringFingerBinding: GestureActionBinding = .core(.fractalScale)
    var pinkyFingerBinding: GestureActionBinding = .core(.sphereRadius)
    var menuToggleHoldDuration: Float = 0.06
    var menuToggleCooldown: Float = 0.35
    var menuToggleActivateThreshold: Float = 0.48
    var menuToggleReleaseThreshold: Float = 0.30
    var twoHandPinchActivateThreshold: Float = 0.78
    var twoHandPinchReleaseThreshold: Float = 0.56
    var ringPinchActivateThreshold: Float = 0.46
    var ringPinchReleaseThreshold: Float = 0.28
    var gestureMinHandDistance: Float = 0.05
    var gestureMaxHandDistance: Float = 0.60
    var gestureMaxStartHandDistance: Float = 0.45
    var gestureMaxActiveHandDistance: Float = 0.90
    var translationSensitivity: Float = 1.0
    
    // Halton jitter temporal AA
    var haltonJitterEnabled: Bool = true
    
    // Dynamic quality
    var dynamicRenderQualityEnabled: Bool = true
    var dynamicRenderQualityMin: Float = 0.5
    var dynamicRenderQualityMax: Float = 1.0
    var currentRenderQuality: Float = 0.7
    
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
        fractalType = settings.fractalType
        formulaParams = settings.formulaParams
        fractalScale = settings.targetFractalScale
        targetMinDistance = settings.targetMinDistance
        targetFoldingLimit = settings.targetFoldingLimit
        targetSphereRadius = settings.targetSphereRadius
        baseFractalIterations = settings.baseFractalIterations
        baseMaxRaySteps = settings.baseMaxRaySteps
        colorScheme = settings.colorScheme
        colorMix = settings.colorMix
        colorIterations = settings.colorIterations
        colorSchemeAutoTransition = settings.colorSchemeAutoTransition
        colorSchemeAutoInterval = settings.colorSchemeAutoInterval
        colorSchemeTransitionDuration = settings.colorSchemeTransitionDuration
        colorSchemeSaturation = settings.colorSchemeSaturation
        colorSchemeContrast = settings.colorSchemeContrast
        colorSchemeGamma = settings.colorSchemeGamma
        colorSchemeVibrance = settings.colorSchemeVibrance
        colorSchemeCurve = settings.colorSchemeCurve
        colorSchemeShadows = settings.colorSchemeShadows
        colorSchemeHighlights = settings.colorSchemeHighlights
        useGradientColoring = settings.useGradientColoring
        gradientColorMap = settings.gradientColorMap
        gradientPreset = settings.gradientPreset
        colorMappingMode = settings.colorMappingMode
        gradientRepeat = settings.gradientRepeat
        gradientOffset = settings.gradientOffset
        gradientSmoothing = settings.gradientSmoothing
        lightingPreset = settings.lightingPreset
        hueRotationEffect = settings.hueRotationEffect
        pulseEffect = settings.pulseEffect
        glowEffect = settings.glowEffect
        bloomEffect = settings.bloomEffect
        fogEffect = settings.fogEffect
        gradientCycleEffect = settings.gradientCycleEffect
        polarRotationEffect = settings.polarRotationEffect
        lightingMode = settings.lightingMode
        lightingSoftness = settings.lightingSoftness
        bassSensitivity = settings.bassSensitivity
        midSensitivity = settings.midSensitivity
        trebleSensitivity = settings.trebleSensitivity
        beatSensitivity = settings.beatSensitivity
        fractalAudioReactiveEnabled = settings.fractalAudioReactiveEnabled
        fractalAudioAmount = settings.fractalAudioAmount
        fractalBeatPunch = settings.fractalBeatPunch
        fractalAudioAffectsScale = settings.fractalAudioAffectsScale
        fractalAudioAffectsFolding = settings.fractalAudioAffectsFolding
        fractalAudioAffectsRadius = settings.fractalAudioAffectsRadius
        fractalAudioAffectsColorMix = settings.fractalAudioAffectsColorMix
        fractalAudioAffectsGlow = settings.fractalAudioAffectsGlow
        fractalAudioAffectsFog = settings.fractalAudioAffectsFog
        fractalAudioAffectsBloom = settings.fractalAudioAffectsBloom
        fractalAudioAffectsHueSpeed = settings.fractalAudioAffectsHueSpeed
        fractalAudioAffectsSaturation = settings.fractalAudioAffectsSaturation
        fractalAudioAffectsIterations = settings.fractalAudioAffectsIterations
        musicReactiveMappings = settings.musicReactiveMappings
        showHUD = settings.showHUD
        safetyBubbleEnabled = settings.safetyBubbleEnabled
        safetyBubbleRadius = settings.safetyBubbleRadius
        safetyBubbleShape = settings.safetyBubbleShape
        useRelativeGestures = settings.useRelativeGestures
        extendedGestureRange = settings.extendedGestureRange
        rotationAutoSnap = settings.rotationAutoSnap
        rotationSnapWindowDegrees = settings.rotationSnapWindowDegrees
        gestureSensitivity = settings.gestureSensitivity
        menuToggleGestureEnabled = settings.menuToggleGestureEnabled
        menuToggleGestureMode = settings.menuToggleGestureMode
        indexFingerBinding = settings.indexFingerBinding
        middleFingerBinding = settings.middleFingerBinding
        ringFingerBinding = settings.ringFingerBinding
        pinkyFingerBinding = settings.pinkyFingerBinding
        menuToggleHoldDuration = settings.menuToggleHoldDuration
        menuToggleCooldown = settings.menuToggleCooldown
        menuToggleActivateThreshold = settings.menuToggleActivateThreshold
        menuToggleReleaseThreshold = settings.menuToggleReleaseThreshold
        twoHandPinchActivateThreshold = settings.twoHandPinchActivateThreshold
        twoHandPinchReleaseThreshold = settings.twoHandPinchReleaseThreshold
        ringPinchActivateThreshold = settings.ringPinchActivateThreshold
        ringPinchReleaseThreshold = settings.ringPinchReleaseThreshold
        gestureMinHandDistance = settings.gestureMinHandDistance
        gestureMaxHandDistance = settings.gestureMaxHandDistance
        gestureMaxStartHandDistance = settings.gestureMaxStartHandDistance
        gestureMaxActiveHandDistance = settings.gestureMaxActiveHandDistance
        translationSensitivity = settings.translationSensitivity
        haltonJitterEnabled = settings.haltonJitterEnabled
        dynamicRenderQualityEnabled = settings.dynamicRenderQualityEnabled
        dynamicRenderQualityMin = settings.dynamicRenderQualityMin
        dynamicRenderQualityMax = settings.dynamicRenderQualityMax
        currentRenderQuality = settings.currentRenderQuality
    }
    
    @inline(__always)
    func push<T>(_ keyPath: WritableKeyPath<RenderSettings, T>, value: T) {
        settings?[keyPath: keyPath] = value
    }

    func dispatchParameterOperation(_ operation: ParameterOperation) {
        parameterOperationDispatcher.dispatch(
            ParameterTransaction(frameIndex: operation.frameIndex, operations: [operation]),
            cache: self
        )
    }

    /// Convenience: dispatch a core/effect parameter write through the UI layer.
    /// Use for slider-driven changes to core.*, effect.* targets.
    func dispatchCoreWrite(targetID: String, value: Float) {
        guard let settings else { return }
        let op = ParameterOperation(
            targetID: targetID,
            source: .slider,
            value: .absolute(value),
            frameIndex: 0
        )
        dispatchParameterOperation(op)
    }
    

    func setFingerBinding(_ binding: GestureActionBinding, for pair: FingerPair) {
        switch pair {
        case .index:
            indexFingerBinding = binding
            push(\.indexFingerBinding, value: binding)
        case .middle:
            middleFingerBinding = binding
            push(\.middleFingerBinding, value: binding)
        case .ring:
            ringFingerBinding = binding
            push(\.ringFingerBinding, value: binding)
        case .pinky:
            pinkyFingerBinding = binding
            push(\.pinkyFingerBinding, value: binding)
        }
    }

    func fingerPair(for binding: GestureActionBinding) -> FingerPair? {
        if indexFingerBinding == binding { return .index }
        if middleFingerBinding == binding { return .middle }
        if ringFingerBinding == binding { return .ring }
        if pinkyFingerBinding == binding { return .pinky }
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
        colorScheme = scheme
    }
    
    func pushGradientEnabled(_ enabled: Bool) {
        settings?.useGradientColoring = enabled
    }
    
    func pushGradientMap(_ map: GradientColorMap) {
        settings?.gradientColorMap = map
    }
    
    func applyGradientPreset(_ preset: GradientPreset) {
        settings?.applyGradientPreset(preset)
        gradientColorMap = preset.makeGradient()
        gradientPreset = preset
        useGradientColoring = true
        let pp = preset.postProcessing
        colorSchemeSaturation = pp.saturation
        colorSchemeContrast = pp.contrast
        colorSchemeGamma = pp.gamma
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
        parameterOperationDispatcher.dispatch(
            ParameterTransaction(frameIndex: op.frameIndex, operations: [op]),
            cache: self
        )
    }
    
    /// Reset formula params to defaults for the current type and push.
    func resetFormulaParams() {
        formulaParams = fractalType.defaultFormulaParams()
        settings?.formulaParams = formulaParams
    }
    
    func reloadLightingEffects() {
        guard let settings = settings else { return }
        hueRotationEffect = settings.hueRotationEffect
        pulseEffect = settings.pulseEffect
        glowEffect = settings.glowEffect
        bloomEffect = settings.bloomEffect
        fogEffect = settings.fogEffect
        gradientCycleEffect = settings.gradientCycleEffect
        polarRotationEffect = settings.polarRotationEffect
    }
}
