import simd
import Testing
@testable import Threshold

/// Pins the default-ON `WarmStartGate` tolerance math (tech debt #20). The
/// gate decides whether the visionOS fragment path may warm-start from last
/// frame's depth history. Too loose → stale warm starts (ghost geometry on
/// the DEFAULT path); too tight → the accelerator silently does nothing.
@Suite("Warm start gate")
struct WarmStartGateTests {
    /// Builds a snapshot from a fresh `RenderSettings`. Hand attraction
    /// defaults ON (which would make `recordDepthWritten` refuse to record),
    /// so the helper turns it off unless a case asks otherwise.
    private func snapshot(mutate: (RenderSettings) -> Void = { _ in }) -> RenderSettingsSnapshot {
        let settings = RenderSettings()
        settings.withPersistenceSuppressed {
            settings.handAttractionEnabled = false
            mutate(settings)
        }
        return settings.snapshot()
    }

    @Test("A recorded frame allows warm start for the same state")
    func recordedStateAllowsWarmStart() {
        var gate = WarmStartGate()
        gate.recordDepthWritten(snapshot())
        #expect(gate.allowsWarmStart(for: snapshot()))
    }

    @Test("No record means no warm start")
    func unrecordedGateRefusesWarmStart() {
        var gate = WarmStartGate()
        #expect(!gate.allowsWarmStart(for: snapshot()))
    }

    @Test("invalidate drops recorded history")
    func invalidateDropsHistory() {
        var gate = WarmStartGate()
        gate.recordDepthWritten(snapshot())
        gate.invalidate()
        #expect(!gate.allowsWarmStart(for: snapshot()))
    }

    @Test("A discrete change (fractal type) is a hard cut in both directions")
    func discreteFractalTypeChangeCuts() {
        var gate = WarmStartGate()
        gate.recordDepthWritten(snapshot { $0.fractalType = .mandelbox })
        #expect(!gate.allowsWarmStart(for: snapshot { $0.fractalType = .mandelbulb }))
        // And the reverse order must cut too (matches is symmetric on the
        // discrete hash).
        var reverse = WarmStartGate()
        reverse.recordDepthWritten(snapshot { $0.fractalType = .mandelbulb })
        #expect(!reverse.allowsWarmStart(for: snapshot { $0.fractalType = .mandelbox }))
    }

    @Test("A one-frame continuous morph within tolerance keeps the warm start")
    func smallContinuousMorphStaysWarm() {
        var gate = WarmStartGate()
        gate.recordDepthWritten(snapshot { $0.scale = 1.0 })
        // 2% delta < the 3% relative tolerance.
        #expect(gate.allowsWarmStart(for: snapshot { $0.scale = 1.02 }))
    }

    @Test("A continuous snap beyond tolerance invalidates")
    func largeContinuousSnapCuts() {
        var gate = WarmStartGate()
        gate.recordDepthWritten(snapshot { $0.scale = 1.0 })
        // 5% delta > the 3% relative tolerance.
        #expect(!gate.allowsWarmStart(for: snapshot { $0.scale = 1.05 }))
    }

    @Test("Near-zero values use the small absolute floor")
    func nearZeroFloor() {
        var gate = WarmStartGate()
        gate.recordDepthWritten(snapshot { $0.position = SIMD3<Float>(0, 0, 0) })
        // 0.002 < the 0.003 absolute floor.
        #expect(gate.allowsWarmStart(for: snapshot { $0.position = SIMD3<Float>(0, 0, 0.002) }))
        // 0.004 > the floor, and 3% of ~0 is ~0, so this must cut.
        #expect(!gate.allowsWarmStart(for: snapshot { $0.position = SIMD3<Float>(0, 0, 0.004) }))
    }

    @Test("Bounding-sphere toggles are hard cuts, including newly-unbounded")
    func boundingToggleIsHardCut() {
        // Previously-unbounded depth must never warm-start a newly-bounded
        // frame past the room surface…
        var newlyBounded = WarmStartGate()
        newlyBounded.recordDepthWritten(snapshot { $0.boundingSphereSkipEnabled = false })
        #expect(!newlyBounded.allowsWarmStart(for: snapshot { $0.boundingSphereSkipEnabled = true }))
        // …and previously-bounded depth must not warm-start an unbounded one.
        var newlyUnbounded = WarmStartGate()
        newlyUnbounded.recordDepthWritten(snapshot { $0.boundingSphereSkipEnabled = true })
        #expect(!newlyUnbounded.allowsWarmStart(for: snapshot { $0.boundingSphereSkipEnabled = false }))
    }

    @Test("An env-scrunch scene never records depth to warm-start from")
    func envScrunchSceneRecordsNothing() {
        var gate = WarmStartGate()
        gate.recordDepthWritten(snapshot { $0.envScrunchEnabled = true })
        #expect(!gate.allowsWarmStart(for: snapshot { $0.envScrunchEnabled = true }))
    }

    @Test("Enabling env-scrunch after recording cuts the warm start")
    func envScrunchAtQueryCuts() {
        var gate = WarmStartGate()
        gate.recordDepthWritten(snapshot())
        #expect(!gate.allowsWarmStart(for: snapshot { $0.envScrunchEnabled = true }))
    }

    @Test("Enabling hand attraction after recording cuts the warm start")
    func handAttractionAtQueryCuts() {
        var gate = WarmStartGate()
        gate.recordDepthWritten(snapshot())
        #expect(!gate.allowsWarmStart(for: snapshot { $0.handAttractionEnabled = true }))
    }

    @Test("Spherical inversion disables the warm start")
    func sphericalInversionCuts() {
        var gate = WarmStartGate()
        gate.recordDepthWritten(snapshot())
        #expect(!gate.allowsWarmStart(for: snapshot { $0.sphericalInversionMode = .outwardIn }))
    }

    @Test("A formula-param morph within tolerance keeps the warm start; a snap cuts")
    func formulaParamTolerance() {
        func params(_ first: Float) -> FormulaParams {
            var fp = FractalModelType.mandelbox.defaultFormulaParams()
            fp.params.0 = first
            return fp
        }
        var gate = WarmStartGate()
        gate.recordDepthWritten(snapshot { $0.formulaParams = params(0.5) })
        // 2% of 0.5 = 0.01, under both the floor and the 3% relative band.
        #expect(gate.allowsWarmStart(for: snapshot { $0.formulaParams = params(0.51) }))
        // 0.1/0.5 = 20% — a hard parameter snap must invalidate.
        #expect(!gate.allowsWarmStart(for: snapshot { $0.formulaParams = params(0.6) }))
    }

    @Test("A rotation-matrix morph within tolerance keeps the warm start")
    func rotationMatrixTolerance() {
        func params(angle: Float) -> FormulaParams {
            var fp = FractalModelType.mandelbox.defaultFormulaParams()
            fp.rotMatrix1 = simd_float4x4(simd_quatf(angle: angle, axis: SIMD3<Float>(0, 1, 0)))
            return fp
        }
        var gate = WarmStartGate()
        gate.recordDepthWritten(snapshot { $0.formulaParams = params(angle: 0.0) })
        // A 0.01 rad rotation moves matrix entries by ~0.01 < 3% of 1.0.
        #expect(gate.allowsWarmStart(for: snapshot { $0.formulaParams = params(angle: 0.01) }))
        // 0.1 rad moves entries ~0.1 > 0.03 — beyond tolerance.
        #expect(!gate.allowsWarmStart(for: snapshot { $0.formulaParams = params(angle: 0.1) }))
    }
}
