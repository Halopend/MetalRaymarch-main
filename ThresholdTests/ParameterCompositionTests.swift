import Testing
@testable import Threshold

@MainActor
@Suite("Unified parameter composition")
struct ParameterCompositionTests {
    private func operation(_ source: ParameterOperationSource, _ value: Float,
                           target: String, time: Double = 1) -> ParameterOperation {
        .init(targetID: target, source: source, value: value, timestamp: time,
              frameIndex: 0, smoothing: .init(smoothingTime: 0))
    }

    @Test("A transaction composes its manual base and audio instead of discarding the base")
    func mixedTransaction() {
        let settings = RenderSettings()
        let pipeline = ParameterPipeline()
        let target = ParameterTargetID.Effect.glow
        settings.withPersistenceSuppressed {
            pipeline.dispatch([operation(.audio, 0.2, target: target),
                               operation(.slider, 0.4, target: target)], settings: settings)
            #expect(abs(settings.glowEffect.intensity - 0.6) < 0.0001)
            #expect(pipeline.liveValue(for: target)?.base == 0.4)
        }
    }

    @Test("A slider takes ownership from a previous gesture while preserving additive music")
    func manualOwnership() {
        let settings = RenderSettings()
        let pipeline = ParameterPipeline()
        let target = ParameterTargetID.Effect.glow
        settings.withPersistenceSuppressed {
            pipeline.dispatch([operation(.gesture, 0.3, target: target),
                               operation(.audio, 0.1, target: target)], settings: settings)
            pipeline.dispatch([operation(.slider, 0.6, target: target, time: 2)], settings: settings)
            #expect(abs(settings.glowEffect.intensity - 0.7) < 0.0001)
            pipeline.clearMusicLayers(settings: settings)
            #expect(abs(settings.glowEffect.intensity - 0.6) < 0.0001)
        }
    }

    @Test("UI formula edits and music use the same stack and UI mirrors the evaluated slot")
    func formulaUI() {
        let settings = RenderSettings()
        settings.fractalType = .mandelbulb
        let pipeline = ParameterPipeline()
        let cache = ControlStateStore(renderSettings: settings)
        let target = ParameterTargetID.formula(fractalType: .mandelbulb, formulaIndex: 0, name: "Power")
        pipeline.dispatchUI([operation(.slider, 4, target: target)], cache: cache)
        pipeline.dispatchAudio([operation(.audio, 1, target: target)], settings: settings)
        pipeline.dispatchUI([operation(.slider, 6, target: target, time: 2)], cache: cache)
        #expect(FormulaCatalog.getParam(settings.formulaParams, index: 0) == 7)
        #expect(FormulaCatalog.getParam(cache.formulaParams, index: 0) == 7)
        #expect(pipeline.liveValue(for: target)?.base == 6)
    }

    @Test("Formula operations from an outgoing scene cannot write the same slot in another formula")
    func rejectsOldFormula() {
        let settings = RenderSettings()
        settings.fractalType = .menger
        let before = FormulaCatalog.getParam(settings.formulaParams, index: 0)
        let target = ParameterTargetID.formula(fractalType: .mandelbulb, formulaIndex: 0, name: "Power")
        ParameterPipeline().dispatch([operation(.slider, 8, target: target)], settings: settings)
        #expect(FormulaCatalog.getParam(settings.formulaParams, index: 0) == before)
    }
    @Test("Formula playback composes a manual base and audio exactly once")
    func formulaPlayback() {
        let settings = RenderSettings()
        settings.fractalType = .mandelbulb
        settings.isAnimationPlaying = true
        settings.setAnimationBaseFormulaParams([4])
        let pipeline = ParameterPipeline()
        let target = ParameterTargetID.formula(fractalType: .mandelbulb, formulaIndex: 0, name: "Power")
        pipeline.dispatch([operation(.slider, 6, target: target),
                           operation(.audio, 1, target: target)], settings: settings)
        pipeline.dispatch([operation(.slider, 8, target: target, time: 2)], settings: settings)
        #expect(FormulaCatalog.getParam(settings.formulaParams, index: 0) == 9)
        settings.setAnimationBaseFormulaParams([5])
        #expect(FormulaCatalog.getParam(settings.formulaParams, index: 0) == 10)
    }

    @Test("Animated effects preserve a manual offset separately from music")
    func corePlayback() {
        let settings = RenderSettings()
        settings.isAnimationPlaying = true
        settings.sceneDrivesGlow = true
        settings.animationBaseGlowIntensity = 0.2
        let pipeline = ParameterPipeline()
        let target = ParameterTargetID.Effect.glow
        pipeline.dispatch([operation(.slider, 0.6, target: target),
                           operation(.audio, 0.1, target: target)], settings: settings)
        #expect(abs(settings.manualOffsetGlowIntensity - 0.4) < 0.0001)
        #expect(abs(settings.audioOffsetGlowIntensity - 0.1) < 0.0001)
    }

    @Test("Runtime bindings cover every routed control without UI metadata")
    func runtimeCatalogCoverage() {
        #expect(Set(RenderParameterCatalog.byID.keys) == Set(ControlCatalog.allSpecs.map(\.id)))
        for descriptor in ParameterCatalog.routedDescriptors {
            #expect(RenderParameterCatalog.byID[descriptor.id]?.spec == descriptor.spec)
            #expect(RenderParameterCatalog.byID[descriptor.id]?.music?.defaultSource == descriptor.music?.defaultSource)
        }
    }

}
