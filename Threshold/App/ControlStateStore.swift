//
//  ControlStateStore.swift
//  Threshold
//
//  Local state that syncs with RenderSettings periodically to avoid lock contention.
//  Extracted from ContentView.swift for single-responsibility.
//

import SwiftUI
import simd

// MARK: - Gradient Library
// Isolated @Observable so gradient mutations don't invalidate ControlStateStore observers
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
final class ControlStateStore {
    private var parameterPipeline: ParameterPipeline?
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
    var handAttraction: HandAttractionConfig = HandAttractionConfig()
    var quality: QualityConfig = QualityConfig()
    var display: DisplayConfig = DisplayConfig()

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Geometry (target values, not in any config struct)
    // ═══════════════════════════════════════════════════════════════════════════

    var fractalType: FractalModelType = .mandelbox
    /// Short hash of the active `.threshfx` formula when `fractalType == .custom`,
    /// nil otherwise. `.custom` is a single sentinel type shared by every embedded
    /// formula, so this is what distinguishes "which one" for UI selection state.
    var activeCustomFormulaHash: String? = nil
    var fractalScale: Float = 2.0
    var targetMinDistance: Float = 0.8
    var targetFoldingLimit: Float = 1.0
    var targetSphereRadius: Float = 0.5
    var formulaParams: FormulaParams = FractalModelType.mandelbox.defaultFormulaParams()
    var scenePrimitives: [ScenePrimitive] = []
    /// Main-actor mirror of the composable Transform stack. The values themselves
    /// are deliberately ignored by Observation: a slider sample must not invalidate
    /// the complete Transformations screen (lesson guide, every card, and every
    /// disclosure). Structural edits bump `spaceWarpStructureRevision`; live slider
    /// bindings read this mirror directly and keep their own native interaction state.
    @ObservationIgnored private(set) var spaceWarpStack: [SpaceWarpOpValue] = []
    private(set) var spaceWarpStructureRevision = 0

    // === SAVED CUSTOM GRADIENTS (isolated in GradientLibrary to avoid observation cross-talk) ===
    let gradientLibrary = GradientLibrary()

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
    
    // === LIVE STATS (synced from render settings periodically) ===
    // These eliminate direct appModel.renderSettings reads from SwiftUI views,
    // preventing lock contention on the main thread during body evaluation.
    var liveFractalIterations: Int = 9
    var liveMaxRaySteps: Int = 64
    var liveFractalScale: Float = 2.8
    var livePosition: SIMD3<Float> = .zero
    var liveDetailScale: Float = 1.0
    var liveWorldRotation: simd_quatf = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    var liveFPS: Double = 0  // Mirrors renderMetrics.fps without observing RenderMetrics directly
    
    private weak var _appModel: AppModel?
    private var syncTimer: Timer?
    private var syncReferenceCount = 0
    private weak var settings: RenderSettings?
    var renderSettings: RenderSettings? { settings }

    init(renderSettings: RenderSettings? = nil) {
        settings = renderSettings
        if renderSettings != nil {
            loadFromSettings()
        }
    }
    
    func startSync(with settings: RenderSettings, appModel: AppModel) {
        self.settings = settings
        self._appModel = appModel
        self.parameterPipeline = appModel.parameterPipeline
        loadFromSettings()
        syncReferenceCount += 1
        guard syncTimer == nil else { return }
        syncTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.syncLiveStats()
            }
        }
    }
    
    func stopSync() {
        syncReferenceCount = max(0, syncReferenceCount - 1)
        guard syncReferenceCount == 0 else { return }
        syncTimer?.invalidate()
        syncTimer = nil
    }
    
    private func syncLiveStats() {
        guard let appModel = _appModel else { return }
        refreshLiveStats(
            isAppActive: appModel.isAppActive,
            immersiveSpaceIsOpen: appModel.immersiveSpaceState == .open,
            fps: appModel.renderMetrics.fps
        )
    }

    /// Refreshes renderer-backed values without making SwiftUI evaluate locked
    /// `RenderSettings` properties. Desktop and mobile keep rendering in their
    /// windows; only visionOS needs an open immersive space for live values.
    func refreshLiveStats(isAppActive: Bool, immersiveSpaceIsOpen: Bool, fps: Double) {
        guard let settings,
              Self.shouldRefreshLiveStats(
                isAppActive: isAppActive,
                immersiveSpaceIsOpen: immersiveSpaceIsOpen
              ) else { return }
        liveFractalIterations = settings.fractalIterations
        liveMaxRaySteps = settings.maxRaySteps
        liveFractalScale = settings.fractalScale
        livePosition = settings.position
        liveDetailScale = settings.detailScale
        liveWorldRotation = settings.worldRotation
        liveFPS = fps
    }

    static func shouldRefreshLiveStats(isAppActive: Bool, immersiveSpaceIsOpen: Bool) -> Bool {
        guard isAppActive else { return false }
#if os(visionOS)
        return immersiveSpaceIsOpen
#else
        return true
#endif
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
        let newHandAttraction = settings.handAttractionConfig
        if handAttraction != newHandAttraction { handAttraction = newHandAttraction }
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
        if scenePrimitives != geo.scenePrimitives {
            scenePrimitives = geo.scenePrimitives
        }
        let newSpaceWarpStack = settings.spaceWarpStack
        if spaceWarpStack != newSpaceWarpStack {
            let structureChanged = !Self.hasSameSpaceWarpStructure(
                spaceWarpStack,
                newSpaceWarpStack
            )
            spaceWarpStack = newSpaceWarpStack
            if structureChanged {
                spaceWarpStructureRevision &+= 1
            }
        }

    }
    
    @inline(__always)
    func push<T>(_ keyPath: WritableKeyPath<RenderSettings, T>, value: T) {
        settings?[keyPath: keyPath] = value
    }

    /// True while music-reactive modulation is enabled and driving parameters.
    var isMusicReactiveActive: Bool { audioReactive.fractalAudioReactiveEnabled }

    /// Latest (base, resolved) snapshot for a modulated parameter, used by sliders
    /// to draw a live "derived value" ghost indicator. nil if the parameter has
    /// never been driven through the pipeline.
    func liveDerivedValue(for targetID: String) -> ParameterPipeline.LiveValue? {
        parameterPipeline?.liveValue(for: targetID)
    }

    func dispatchParameterOperation(_ operation: ParameterOperation) {
        parameterPipeline?.dispatchUI([operation], cache: self)
    }

    /// Mutates one Transform-stack instance by stable identity and commits the
    /// complete value array back to RenderSettings. Resolving the live slot from
    /// the UUID also recenters any music mapping after a reorder instead of
    /// accidentally targeting the transform that used to occupy that index.
    @discardableResult
    func updateSpaceWarpOp(
        id: UUID,
        _ mutate: (inout SpaceWarpOpValue) -> Void
    ) -> Bool {
        guard let settings else { return false }
        // Resolve against the authoritative live stack. A renderer-side scene
        // load or reorder can land between low-rate cache reconciliations; using
        // the mirror here would replay its stale ordering along with the edit.
        var updated = settings.spaceWarpStack
        guard let index = updated.firstIndex(where: { $0.id == id }) else { return false }
        let previous = updated[index]
        mutate(&updated[index])
        guard updated[index] != previous else { return true }
        settings.spaceWarpStack = updated
        spaceWarpStack = updated
        settings.requestMusicRecenter(targetID: ParameterTargetID.SpaceWarp.opStrength(slot: index))
        return true
    }

    /// Commits an add/remove/reorder/grouping edit and invalidates only consumers
    /// whose presentation depends on stack structure. Parameter-only mutations use
    /// `updateSpaceWarpOp` and intentionally avoid the revision bump.
    func replaceSpaceWarpStack(_ updated: [SpaceWarpOpValue]) {
        guard let settings else { return }
        let structureChanged = !Self.hasSameSpaceWarpStructure(spaceWarpStack, updated)
        settings.spaceWarpStack = updated
        spaceWarpStack = updated
        if structureChanged {
            spaceWarpStructureRevision &+= 1
        }
    }

    func addScenePrimitive(_ kind: ScenePrimitiveKind) {
        guard scenePrimitives.count < ScenePrimitive.maximumCount else { return }
        var primitive = ScenePrimitive(kind: kind)
        // New objects remain immediately distinguishable while keeping the first
        // addition centered. Users can type exact values into the placement row.
        let column = scenePrimitives.count % 4
        primitive.position.x = Float(column) * 2.5
        if kind == .benchy {
            // Canonical Benchy is baked floor-up (0...1.6); center it around the
            // scene origin by default.
            primitive.position.y = -0.8
        }
        scenePrimitives.append(primitive)
        settings?.scenePrimitives = scenePrimitives
    }

    @discardableResult
    func updateScenePrimitive(
        id: UUID,
        _ mutate: (inout ScenePrimitive) -> Void
    ) -> Bool {
        guard let index = scenePrimitives.firstIndex(where: { $0.id == id }) else {
            return false
        }
        mutate(&scenePrimitives[index])
        scenePrimitives[index].scale = min(max(scenePrimitives[index].scale, 0.01), 30)
        scenePrimitives[index].dimensions = simd_clamp(
            scenePrimitives[index].dimensions,
            SIMD3<Float>(repeating: 0.001),
            SIMD3<Float>(repeating: 30)
        )
        settings?.scenePrimitives = scenePrimitives
        return true
    }

    func removeScenePrimitive(id: UUID) {
        scenePrimitives.removeAll { $0.id == id }
        settings?.scenePrimitives = scenePrimitives
    }

    private static func hasSameSpaceWarpStructure(
        _ lhs: [SpaceWarpOpValue],
        _ rhs: [SpaceWarpOpValue]
    ) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { left, right in
            left.id == right.id
                && left.type == right.type
                && left.groupID == right.groupID
                && left.groupIterations == right.groupIterations
                && left.groupMode == right.groupMode
        }
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
    func pushFractalType(_ type: FractalModelType) {
        if let appModel = _appModel {
            appModel.switchFractalType(type)
            activeCustomFormulaHash = nil
            loadFromSettings()
            return
        }

        // Standalone previews/tests can construct a cache without AppModel.
        // Preserve the local fallback while production uses the canonical path.
        let oldType = settings?.fractalType
        settings?.fractalType = type
        activeCustomFormulaHash = nil
        if oldType != type {
            // Clear stale formula parameter layer stacks from the old type
            parameterPipeline?.clearFormulaStacks()
            if let settings {
                FractalDefaultsStore.applyFractalDefaults(for: type, to: settings)
            }
            loadFromSettings()
            // Reset now targets the freshly-selected type's defaults (not the
            // previously-loaded scene's type). Snapshot after defaults applied.
            _appModel?.rememberActiveResetPresetFromCurrent()
        }
    }

    /// Activate a custom (`.threshfx`-embedded) distance estimator: compiles it
    /// in the renderer if needed, then switches to `FractalModelType.custom` and
    /// resets shape parameters to the formula's own defaults — mirroring
    /// `pushFractalType`'s built-in behavior, but keyed by formula hash since
    /// `.custom` is a single shared enum case.
    @MainActor
    func pushCustomFormula(_ formula: EmbeddedFormula) {
        guard let appModel = _appModel else { return }
        Task { @MainActor in
            let result = await appModel.installEmbeddedFormulaIfNeededAndWait(formula)
            guard result != .failed else { return }
            settings?.fractalType = .custom
            activeCustomFormulaHash = formula.shortHash
            parameterPipeline?.clearFormulaStacks()
            appModel.applyFractalDefaults()
            loadFromSettings()
            appModel.rememberActiveResetPresetFromCurrent()
        }
    }

    /// Re-register an edited custom formula definition in place — same
    /// formula id, new source and/or params — and regenerate the parameter UI
    /// without losing slider values. This is the live-editing path: unlike
    /// `pushCustomFormula` it never applies fractal defaults wholesale.
    ///
    /// Values are preserved BY INDEX: a param index that exists in both the
    /// old and new definitions keeps its current value; indices new to the
    /// draft get the draft's declared default. Layer stacks are cleared so
    /// gesture/music layers can't keep the old definition's ranges.
    @MainActor
    func noteCustomFormulaDefinitionChanged(_ draft: EmbeddedFormula) {
        let previousIndices = Set(
            FormulaCatalog.shared.descriptor(for: .custom)?.params.map(\.index) ?? []
        )

        FormulaCatalog.shared.registerEphemeral(draft)
        FractalTypeRegistry.registerCustom(draft)
        parameterPipeline?.clearFormulaStacks()

        if let settings {
            var params = settings.formulaParams
            for param in draft.params where !previousIndices.contains(param.index) {
                FormulaCatalog.setParam(&params, index: param.index, value: param.default)
            }
            settings.formulaParams = params
        }
        activeCustomFormulaHash = draft.shortHash
        loadFromSettings()
    }

    /// Select a trusted analytic primitive from the bundled Metal library while
    /// retaining its EmbeddedFormula payload for scene attribution/portability.
    @MainActor
    func pushConstructionPrimitive(_ primitive: FractalPrimitiveKind) {
        let authoredParams = primitive.bundledFormulaParams

        guard let appModel = _appModel else {
            settings?.fractalType = .constructionPrimitive
            settings?.formulaParams = authoredParams
            loadFromSettings()
            return
        }

        Task { @MainActor in
            // Switch first: the canonical built-in path detaches any previous
            // runtime custom fractal. Apply type defaults before writing the
            // selected primitive params so defaults cannot replace it with Sphere.
            appModel.switchFractalType(.constructionPrimitive)
            parameterPipeline?.clearFormulaStacks()
            appModel.applyFractalDefaults()
            settings?.formulaParams = authoredParams
            let result = await appModel.installEmbeddedFormulaIfNeededAndWait(primitive.formula)
            guard result == .ready else { return }
            activeCustomFormulaHash = primitive.formula.shortHash
            loadFromSettings()
            appModel.rememberActiveResetPresetFromCurrent()
        }
    }

    func pushGradientMap(_ map: GradientColorMap) {
        settings?.gradientColorMap = map
    }
    
    func applyGradientPreset(_ preset: GradientPreset) {
        settings?.applyGradientPreset(preset)
        // Preserve user mapping settings when switching presets
        let savedMode = color.gradientState.gradient.mappingMode
        let savedRepeat = color.gradientState.gradient.repeatCount
        let savedOffset = color.gradientState.gradient.offset
        let savedSmoothing = color.gradientState.gradient.smoothing
        color.gradientState.gradient = preset.makeGradient()
        color.gradientState.gradient.mappingMode = savedMode
        color.gradientState.gradient.repeatCount = savedRepeat
        color.gradientState.gradient.offset = savedOffset
        color.gradientState.gradient.smoothing = savedSmoothing
        color.gradientState.gradientPreset = preset
        let pp = preset.postProcessing
        color.colorSchemeSaturation = pp.saturation
        color.colorSchemeContrast = pp.contrast
        color.colorSchemeGamma = pp.gamma
    }
    
    /// Reset formula params to defaults for the current type and push.
    func resetFormulaParams() {
        parameterPipeline?.clearFormulaStacks()
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
            value: value,
            frameIndex: 0
        )
        parameterPipeline?.dispatchUI([op], cache: self)
    }

    func commitHueRotationEffect() {
        push(\.hueRotationEffect, value: lighting.hueRotationEffect)
        pushEffectParam(ParameterTargetID.Effect.hueSpeed, value: lighting.hueRotationEffect.speed)
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
            pushEffectParam(ParameterTargetID.Effect.glow, value: lighting.glowEffect.intensity)
        }
    }

    func commitBloomEffect() {
        guard let settings else { return }
        if settings.isAnimationPlaying {
            settings.manualOffsetBloomStrength = lighting.bloomEffect.strength - settings.animationBaseBloomStrength
            settings.bloomEffect = lighting.bloomEffect
        } else {
            push(\.bloomEffect, value: lighting.bloomEffect)
            pushEffectParam(ParameterTargetID.Effect.bloom, value: lighting.bloomEffect.strength)
        }
    }

    func commitEdgeDetectionEffect() {
        guard let settings else { return }
        lighting.edgeDetectionEffect.normalize()
        settings.edgeDetectionEffect = lighting.edgeDetectionEffect
    }

    func commitConvolutionEffect() {
        guard let settings else { return }
        lighting.convolutionEffect.normalize()
        settings.convolutionEffect = lighting.convolutionEffect
    }

    func commitFogEffect() {
        guard let settings else { return }
        if settings.isAnimationPlaying {
            settings.manualOffsetFogIntensity = lighting.fogEffect.intensity - settings.animationBaseFogIntensity
            settings.fogEffect = lighting.fogEffect
        } else {
            push(\.fogEffect, value: lighting.fogEffect)
            pushEffectParam(ParameterTargetID.Effect.fog, value: lighting.fogEffect.intensity)
        }
    }

    func commitSphericalInversion() {
        guard let settings else { return }
        settings.sphericalInversionMode = display.sphericalInversionMode
        settings.sphericalInversionRadius = display.sphericalInversionRadius
    }

    func commitSphereProjection() {
        guard let settings else { return }
        settings.sphereProjectionEnabled = display.sphereProjectionEnabled
        // Persist the base values via the direct setters, then route blend & radius
        // through the parameter layer stack so music/gesture compose additively with
        // the slider (and a slider edit recenters the music drift), mirroring fog/glow.
        settings.sphereProjectionBlend = display.sphereProjectionBlend
        settings.sphereProjectionRadius = display.sphereProjectionRadius
        pushEffectParam(ParameterTargetID.Space.sphereProjectionBlend, value: display.sphereProjectionBlend)
        pushEffectParam(ParameterTargetID.Space.sphereProjectionRadius, value: display.sphereProjectionRadius)
    }

    func commitPlatformRadius() {
        settings?.platformRadius = display.platformRadius
    }

    func setPlatformEnabled(_ enabled: Bool) {
        display.platformEnabled = enabled
        settings?.platformEnabled = enabled
    }

    /// The current containment mode, derived from the shape, authored-space,
    /// and scanned-surroundings enable flags. `.custom` is any manual
    /// combination with more than one system enabled.
    var mixedContainment: MixedContainment {
        let bounded = quality.boundingSphereSkipEnabled
        let space = quality.boundToSpaceEnabled
        let scrunch = quality.envScrunchEnabled
        let enabledCount = [bounded, space, scrunch].filter { $0 }.count
        guard enabledCount <= 1 else { return .custom }
        if bounded { return .bounded }
        if space { return .space }
        if scrunch { return quality.envScrunchMode == 1 ? .environment : .surroundings }
        return .free
    }

    /// Apply a canonical containment mode from the top-bar picker: sets the
    /// shape, authored-space, and scrunch flags MUTUALLY EXCLUSIVELY. Entering
    /// `.surroundings` also defaults Contain to Blend when it was still Off —
    /// without Contain the scrunch mirrors past scanned walls (the room scan is
    /// an unsigned distance field). `.custom` is a derived, read-only state, so
    /// it's a no-op here (there's no canonical combo to set). Every flag touched
    /// is scene-persisted (FractalPreset), so the mode is captured on save.
    func applyMixedContainment(_ mode: MixedContainment) {
        guard mode != .custom else { return }
        let bounded = (mode == .bounded)
        let space = (mode == .space)
        let scrunch = (mode == .surroundings || mode == .environment)
        quality.boundingSphereSkipEnabled = bounded
        push(\.boundingSphereSkipEnabled, value: bounded)
        quality.boundToSpaceEnabled = space
        push(\.boundToSpaceEnabled, value: space)
        quality.envScrunchEnabled = scrunch
        push(\.envScrunchEnabled, value: scrunch)
        if mode == .surroundings || mode == .environment {
            let envMode = mode == .environment ? 1 : 0
            quality.envScrunchMode = envMode
            push(\.envScrunchMode, value: envMode)
        }
        if mode == .environment {
            quality.envScrunchContain = 1
            push(\.envScrunchContain, value: 1)
        } else if scrunch && quality.envScrunchContain == 0 {
            quality.envScrunchContain = 2
            push(\.envScrunchContain, value: 2)
        }
    }

    /// Toggle the bounding shape independently. It does not alter authored
    /// space or scanned-surroundings containment; combinations become Custom.
    func setBoundingShapeEnabled(_ on: Bool) {
        quality.boundingSphereSkipEnabled = on
        push(\.boundingSphereSkipEnabled, value: on)
    }

    /// Toggle the authored room bound independently. Combining it with Shape
    /// or scanned Surroundings intentionally produces the Custom state.
    func setBoundToSpaceEnabled(_ on: Bool) {
        quality.boundToSpaceEnabled = on
        push(\.boundToSpaceEnabled, value: on)
    }

    /// Toggle Scrunch INDEPENDENTLY — the individual side/quick toggle, which
    /// does not touch the bounding shape. Turning it on defaults Contain to
    /// Blend when it was still Off (same reason as the picker path). Leaving
    /// both on moves the Containment picker to `.custom`.
    func setScrunchEnabled(_ on: Bool) {
        quality.envScrunchEnabled = on
        push(\.envScrunchEnabled, value: on)
        if on && quality.envScrunchContain == 0 {
            quality.envScrunchContain = 2
            push(\.envScrunchContain, value: 2)
        }
    }

    func commitGradientCycleEffect() {
        push(\.gradientCycleEffect, value: lighting.gradientCycleEffect)
    }

    func commitLightVariationRate() {
        push(\.lightVariationRate, value: lighting.lightVariationRate)
    }

    func commitLinearRailEffect() {
        push(\.linearRailEffect, value: lighting.linearRailEffect)
    }

    func commitBeatFlashEffect() {
        push(\.beatFlashEffect, value: lighting.beatFlashEffect)
    }

    func commitJuliaDriftEffect() {
        push(\.juliaDriftEffect, value: lighting.juliaDriftEffect)
    }

    func commitColorSchemeSaturation() {
        guard let settings else { return }
        if settings.isAnimationPlaying {
            settings.manualOffsetSaturation = color.colorSchemeSaturation - settings.animationBaseSaturation
            settings.colorSchemeSaturation = color.colorSchemeSaturation
        } else {
            push(\.colorSchemeSaturation, value: color.colorSchemeSaturation)
            pushEffectParam(ParameterTargetID.Effect.saturation, value: color.colorSchemeSaturation)
        }
    }

    /// Gradient phase offset ("Color Offset"). Persists the base, then routes through
    /// the layer stack so music composes additively (and a slider edit recenters the
    /// music drift), mirroring saturation/sphere projection.
    func commitGradientOffset() {
        push(\.gradientOffset, value: color.gradientState.gradient.offset)
        pushEffectParam(ParameterTargetID.Effect.gradientOffset, value: color.gradientState.gradient.offset)
    }
}

extension ControlStateStore {
    static func blendValueToSlider(_ value: Float) -> Float {
        sqrt(value.clamped(to: 0.0...1.0))
    }

    static func blendSliderToValue(_ slider: Float) -> Float {
        let clamped = slider.clamped(to: 0.0...1.0)
        return clamped * clamped
    }
}
