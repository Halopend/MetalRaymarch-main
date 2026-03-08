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

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Quality Shims
    // ═══════════════════════════════════════════════════════════════════════════

    var baseFractalIterations: Int {
        get { quality.baseFractalIterations }
        set { quality.baseFractalIterations = newValue }
    }
    var baseMaxRaySteps: Int {
        get { quality.baseMaxRaySteps }
        set { quality.baseMaxRaySteps = newValue }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Color Shims
    // ═══════════════════════════════════════════════════════════════════════════

    var colorScheme: ColorScheme {
        get { color.colorScheme }
        set { color.colorScheme = newValue }
    }
    var colorMix: Float {
        get { color.colorMix }
        set { color.colorMix = newValue }
    }
    var colorIterations: Float {
        get { color.colorIterations }
        set { color.colorIterations = newValue }
    }
    var colorSchemeAutoTransition: Bool {
        get { color.colorSchemeAutoTransition }
        set { color.colorSchemeAutoTransition = newValue }
    }
    var colorSchemeAutoInterval: Float {
        get { color.colorSchemeAutoInterval }
        set { color.colorSchemeAutoInterval = newValue }
    }
    var colorSchemeTransitionDuration: Float {
        get { color.colorSchemeTransitionDuration }
        set { color.colorSchemeTransitionDuration = newValue }
    }
    var colorSchemeSaturation: Float {
        get { color.colorSchemeSaturation }
        set { color.colorSchemeSaturation = newValue }
    }
    var colorSchemeContrast: Float {
        get { color.colorSchemeContrast }
        set { color.colorSchemeContrast = newValue }
    }
    var colorSchemeGamma: Float {
        get { color.colorSchemeGamma }
        set { color.colorSchemeGamma = newValue }
    }
    var colorSchemeVibrance: Float {
        get { color.colorSchemeVibrance }
        set { color.colorSchemeVibrance = newValue }
    }
    var colorSchemeCurve: Float {
        get { color.colorSchemeCurve }
        set { color.colorSchemeCurve = newValue }
    }
    var colorSchemeShadows: Float {
        get { color.colorSchemeShadows }
        set { color.colorSchemeShadows = newValue }
    }
    var colorSchemeHighlights: Float {
        get { color.colorSchemeHighlights }
        set { color.colorSchemeHighlights = newValue }
    }

    // ── Gradient shims (nested in color.gradientState) ──
    var useGradientColoring: Bool {
        get { color.gradientState.useGradientColoring }
        set { color.gradientState.useGradientColoring = newValue }
    }
    var gradientColorMap: GradientColorMap {
        get { color.gradientState.gradient }
        set { color.gradientState.gradient = newValue }
    }
    var gradientPreset: GradientPreset? {
        get { color.gradientState.gradientPreset }
        set { color.gradientState.gradientPreset = newValue }
    }
    var colorMappingMode: ColorMappingMode {
        get { color.gradientState.gradient.mappingMode }
        set { color.gradientState.gradient.mappingMode = newValue }
    }
    var gradientRepeat: Float {
        get { color.gradientState.gradient.repeatCount }
        set { color.gradientState.gradient.repeatCount = newValue }
    }
    var gradientOffset: Float {
        get { color.gradientState.gradient.offset }
        set { color.gradientState.gradient.offset = newValue }
    }
    var gradientSmoothing: Float {
        get { color.gradientState.gradient.smoothing }
        set { color.gradientState.gradient.smoothing = newValue }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Lighting Shims
    // ═══════════════════════════════════════════════════════════════════════════

    var lightingPreset: LightingPreset {
        get { lighting.lightingPreset }
        set { lighting.lightingPreset = newValue }
    }
    var hueRotationEffect: HueRotationEffect {
        get { lighting.hueRotationEffect }
        set { lighting.hueRotationEffect = newValue }
    }
    var pulseEffect: PulseEffect {
        get { lighting.pulseEffect }
        set { lighting.pulseEffect = newValue }
    }
    var glowEffect: GlowEffect {
        get { lighting.glowEffect }
        set { lighting.glowEffect = newValue }
    }
    var bloomEffect: BloomEffect {
        get { lighting.bloomEffect }
        set { lighting.bloomEffect = newValue }
    }
    var fogEffect: FogEffect {
        get { lighting.fogEffect }
        set { lighting.fogEffect = newValue }
    }
    var gradientCycleEffect: GradientCycleEffect {
        get { lighting.gradientCycleEffect }
        set { lighting.gradientCycleEffect = newValue }
    }
    var polarRotationEffect: PolarRotationEffect {
        get { lighting.polarRotationEffect }
        set { lighting.polarRotationEffect = newValue }
    }
    var beatFlashEffect: BeatFlashEffect {
        get { lighting.beatFlashEffect }
        set { lighting.beatFlashEffect = newValue }
    }
    
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
    
    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Display Shims
    // ═══════════════════════════════════════════════════════════════════════════

    var lightingMode: LightingMode {
        get { display.lightingMode }
        set { display.lightingMode = newValue }
    }
    var lightingSoftness: Float {
        get { color.lightingSoftness }
        set { color.lightingSoftness = newValue }
    }
    
    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Audio Reactive Shims
    // ═══════════════════════════════════════════════════════════════════════════

    var bassSensitivity: Float {
        get { audioReactive.bassSensitivity }
        set { audioReactive.bassSensitivity = newValue }
    }
    var midSensitivity: Float {
        get { audioReactive.midSensitivity }
        set { audioReactive.midSensitivity = newValue }
    }
    var trebleSensitivity: Float {
        get { audioReactive.trebleSensitivity }
        set { audioReactive.trebleSensitivity = newValue }
    }
    var beatSensitivity: Float {
        get { audioReactive.beatSensitivity }
        set { audioReactive.beatSensitivity = newValue }
    }
    var fractalAudioReactiveEnabled: Bool {
        get { audioReactive.fractalAudioReactiveEnabled }
        set { audioReactive.fractalAudioReactiveEnabled = newValue }
    }
    var fractalAudioAmount: Float {
        get { audioReactive.fractalAudioAmount }
        set { audioReactive.fractalAudioAmount = newValue }
    }
    var fractalBeatPunch: Float {
        get { audioReactive.fractalBeatPunch }
        set { audioReactive.fractalBeatPunch = newValue }
    }
    var fractalAudioAffectsScale: Bool {
        get { audioReactive.fractalAudioAffectsScale }
        set { audioReactive.fractalAudioAffectsScale = newValue }
    }
    var fractalAudioAffectsFolding: Bool {
        get { audioReactive.fractalAudioAffectsFolding }
        set { audioReactive.fractalAudioAffectsFolding = newValue }
    }
    var fractalAudioAffectsRadius: Bool {
        get { audioReactive.fractalAudioAffectsRadius }
        set { audioReactive.fractalAudioAffectsRadius = newValue }
    }
    var fractalAudioAffectsColorMix: Bool {
        get { audioReactive.fractalAudioAffectsColorMix }
        set { audioReactive.fractalAudioAffectsColorMix = newValue }
    }
    var fractalAudioAffectsGlow: Bool {
        get { audioReactive.fractalAudioAffectsGlow }
        set { audioReactive.fractalAudioAffectsGlow = newValue }
    }
    var fractalAudioAffectsFog: Bool {
        get { audioReactive.fractalAudioAffectsFog }
        set { audioReactive.fractalAudioAffectsFog = newValue }
    }
    var fractalAudioAffectsBloom: Bool {
        get { audioReactive.fractalAudioAffectsBloom }
        set { audioReactive.fractalAudioAffectsBloom = newValue }
    }
    var fractalAudioAffectsHueSpeed: Bool {
        get { audioReactive.fractalAudioAffectsHueSpeed }
        set { audioReactive.fractalAudioAffectsHueSpeed = newValue }
    }
    var fractalAudioAffectsSaturation: Bool {
        get { audioReactive.fractalAudioAffectsSaturation }
        set { audioReactive.fractalAudioAffectsSaturation = newValue }
    }
    var fractalAudioAffectsIterations: Bool {
        get { audioReactive.fractalAudioAffectsIterations }
        set { audioReactive.fractalAudioAffectsIterations = newValue }
    }
    var musicReactiveMappings: [MusicReactiveMapping] {
        get { audioReactive.musicReactiveMappings }
        set { audioReactive.musicReactiveMappings = newValue }
    }
    
    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Display Shims (cont.)
    // ═══════════════════════════════════════════════════════════════════════════

    var showHUD: Bool {
        get { display.showHUD }
        set { display.showHUD = newValue }
    }
    var showMusicShortcuts: Bool {
        get { display.showMusicShortcuts }
        set { display.showMusicShortcuts = newValue }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Safety Bubble Shims
    // ═══════════════════════════════════════════════════════════════════════════

    var safetyBubbleEnabled: Bool {
        get { safetyBubble.enabled }
        set { safetyBubble.enabled = newValue }
    }
    var safetyBubbleRadius: Float {
        get { safetyBubble.radius }
        set { safetyBubble.radius = newValue }
    }
    var safetyBubbleShape: Float {
        get { safetyBubble.shape }
        set { safetyBubble.shape = newValue }
    }
    var safetyBubbleBlend: Float {
        get { safetyBubble.strength }
        set { safetyBubble.strength = newValue }
    }
    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Gesture Shims
    // ═══════════════════════════════════════════════════════════════════════════

    var useRelativeGestures: Bool {
        get { gesture.useRelativeGestures }
        set { gesture.useRelativeGestures = newValue }
    }
    var extendedGestureRange: Bool {
        get { gesture.extendedGestureRange }
        set { gesture.extendedGestureRange = newValue }
    }
    var rotationAutoSnap: Bool {
        get { gesture.rotationAutoSnap }
        set { gesture.rotationAutoSnap = newValue }
    }
    var rotationSnapWindowDegrees: Float {
        get { gesture.rotationSnapWindowDegrees }
        set { gesture.rotationSnapWindowDegrees = newValue }
    }
    var rotationBreakawayDegrees: Float {
        get { gesture.rotationBreakawayDegrees }
        set { gesture.rotationBreakawayDegrees = newValue }
    }
    var gestureSensitivity: Float {
        get { gesture.gestureSensitivity }
        set { gesture.gestureSensitivity = newValue }
    }
    var gestureSmoothingFactor: Float {
        get { gesture.gestureSmoothingFactor }
        set { gesture.gestureSmoothingFactor = newValue }
    }
    var menuToggleGestureEnabled: Bool {
        get { gesture.menuToggleGestureEnabled }
        set { gesture.menuToggleGestureEnabled = newValue }
    }
    var menuToggleGestureMode: MenuToggleGestureMode {
        get { gesture.menuToggleGestureMode }
        set { gesture.menuToggleGestureMode = newValue }
    }
    var gestureBindings: [String: GestureActionBinding] {
        get { gesture.gestureBindings }
        set { gesture.gestureBindings = newValue }
    }
    var menuToggleHoldDuration: Float {
        get { gesture.menuToggleHoldDuration }
        set { gesture.menuToggleHoldDuration = newValue }
    }
    var menuToggleCooldown: Float {
        get { gesture.menuToggleCooldown }
        set { gesture.menuToggleCooldown = newValue }
    }
    var menuToggleActivateThreshold: Float {
        get { gesture.menuToggleActivateThreshold }
        set { gesture.menuToggleActivateThreshold = newValue }
    }
    var menuToggleReleaseThreshold: Float {
        get { gesture.menuToggleReleaseThreshold }
        set { gesture.menuToggleReleaseThreshold = newValue }
    }
    var twoHandPinchActivateThreshold: Float {
        get { gesture.twoHandPinchActivateThreshold }
        set { gesture.twoHandPinchActivateThreshold = newValue }
    }
    var twoHandPinchReleaseThreshold: Float {
        get { gesture.twoHandPinchReleaseThreshold }
        set { gesture.twoHandPinchReleaseThreshold = newValue }
    }
    var ringPinchActivateThreshold: Float {
        get { gesture.ringPinchActivateThreshold }
        set { gesture.ringPinchActivateThreshold = newValue }
    }
    var ringPinchReleaseThreshold: Float {
        get { gesture.ringPinchReleaseThreshold }
        set { gesture.ringPinchReleaseThreshold = newValue }
    }
    var gestureMinHandDistance: Float {
        get { gesture.gestureMinHandDistance }
        set { gesture.gestureMinHandDistance = newValue }
    }
    var gestureMaxHandDistance: Float {
        get { gesture.gestureMaxHandDistance }
        set { gesture.gestureMaxHandDistance = newValue }
    }
    var gestureMaxStartHandDistance: Float {
        get { gesture.gestureMaxStartHandDistance }
        set { gesture.gestureMaxStartHandDistance = newValue }
    }
    var gestureMaxActiveHandDistance: Float {
        get { gesture.gestureMaxActiveHandDistance }
        set { gesture.gestureMaxActiveHandDistance = newValue }
    }
    var translationSensitivity: Float {
        get { gesture.translationSensitivity }
        set { gesture.translationSensitivity = newValue }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Remaining Quality Shims
    // ═══════════════════════════════════════════════════════════════════════════

    var haltonJitterEnabled: Bool {
        get { quality.haltonJitterEnabled }
        set { quality.haltonJitterEnabled = newValue }
    }
    var dynamicRenderQualityEnabled: Bool {
        get { quality.dynamicRenderQualityEnabled }
        set { quality.dynamicRenderQualityEnabled = newValue }
    }
    var dynamicRenderQualityMin: Float {
        get { quality.dynamicRenderQualityMin }
        set { quality.dynamicRenderQualityMin = newValue }
    }
    var dynamicRenderQualityMax: Float {
        get { quality.dynamicRenderQualityMax }
        set { quality.dynamicRenderQualityMax = newValue }
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
    

    // ── GestureSlot-based binding helpers ──────────────────────────────────

    func gestureBinding(for slot: GestureSlot) -> GestureActionBinding {
        gestureBindings[slot.persistenceKey] ?? .core(.none)
    }

    func setGestureBinding(_ binding: GestureActionBinding, for slot: GestureSlot) {
        // RenderSettings.setBinding handles validation + mutual exclusion + persistence.
        settings?.setBinding(binding, for: slot)
        // Re-sync all 9 slots from the authoritative RenderSettings so the UI
        // reflects any cascade clears from mutual exclusion enforcement.
        if let settings = settings {
            for s in GestureSlot.allSlots {
                gestureBindings[s.persistenceKey] = settings.binding(for: s)
            }
        } else {
            gestureBindings[slot.persistenceKey] = binding
        }
    }

    func gestureSlot(for binding: GestureActionBinding) -> GestureSlot? {
        for slot in GestureSlot.allSlots {
            if gestureBindings[slot.persistenceKey] == binding { return slot }
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
