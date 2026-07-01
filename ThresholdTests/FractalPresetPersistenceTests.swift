//
//  FractalPresetPersistenceTests.swift
//  ThresholdTests
//
//  Guards the second lossy-persistence fix: ten visual scene-state fields that
//  lived in the domain configs (Display/Color/Lighting/SafetyBubble) but were
//  never captured by FractalPreset, so authoring them then saving silently lost
//  them on reload — the same class of bug as the sphere transforms in
//  SpaceModuleTests. Device-local performance/acceleration settings
//  (QualityConfig) are deliberately NOT persisted and are not exercised here.
//

import Testing
import Foundation
@testable import Threshold

@Suite("FractalPreset — previously-dropped scene state round-trips")
struct FractalPresetPersistenceTests {

    @Test("Platform / cell-shading / light-rate / extra effects / bubble-fade survive fromSettings → encode → decode → apply")
    func droppedFieldsRoundTrip() throws {
        let settings = RenderSettings()
        settings.fractalType = .mandelbox

        // Display
        settings.platformEnabled = false        // default true
        settings.platformRadius = 1.2           // default 1.888

        // Color
        settings.cellShadingEnabled = true       // default false
        settings.cellShadingLevels = 6.0         // default 4.0

        // Lighting
        settings.lightVariationRate = 0.25       // default 0.5
        var beat = BeatFlashEffect(); beat.enabled = true; beat.intensity = 0.7
        settings.beatFlashEffect = beat
        var polar = PolarRotationEffect(); polar.direction = .clockwise; polar.speed = 0.4
        settings.polarRotationEffect = polar
        var julia = JuliaDriftEffect(); julia.enabled = true; julia.speed = 0.35
        settings.juliaDriftEffect = julia

        // Safety bubble edge fade — get-only on RenderSettings, set via the config.
        // Bubble must be ON: apply() only restores bubble fields for scenes that
        // use the bubble (scenes can enable it, never disable — user-owned).
        var sb = settings.safetyBubbleConfig
        sb.enabled = true
        sb.fadeEnabled = false                    // default true
        sb.fadeWidth = 0.4                        // default 0.1
        settings.safetyBubbleConfig = sb

        // Capture → encode → decode (the path that was silently dropping values).
        let preset = FractalPreset.fromSettings(settings, name: "Dropped")
        #expect(preset.platformEnabled == false)
        #expect(preset.cellShadingEnabled == true)
        #expect(preset.safetyBubbleFadeEnabled == false)

        let data = try JSONEncoder().encode(preset)
        let decoded = try JSONDecoder().decode(FractalPreset.self, from: data)

        #expect(decoded.platformEnabled == false)
        #expect(abs((decoded.platformRadius ?? -1) - 1.2) < 1e-5)
        #expect(decoded.cellShadingEnabled == true)
        #expect(abs((decoded.cellShadingLevels ?? -1) - 6.0) < 1e-5)
        #expect(abs((decoded.lightVariationRate ?? -1) - 0.25) < 1e-5)
        #expect(decoded.beatFlashEffect?.enabled == true)
        #expect(abs((decoded.beatFlashEffect?.intensity ?? -1) - 0.7) < 1e-5)
        #expect(decoded.polarRotationEffect?.direction == .clockwise)
        #expect(abs((decoded.polarRotationEffect?.speed ?? -1) - 0.4) < 1e-5)
        #expect(decoded.juliaDriftEffect?.enabled == true)
        #expect(abs((decoded.juliaDriftEffect?.speed ?? -1) - 0.35) < 1e-5)
        #expect(decoded.safetyBubbleFadeEnabled == false)
        #expect(abs((decoded.safetyBubbleFadeWidth ?? -1) - 0.4) < 1e-5)

        // Restore into a fresh settings object.
        let fresh = RenderSettings()
        fresh.fractalType = .mandelbox
        decoded.apply(to: fresh)

        #expect(fresh.platformEnabled == false)
        #expect(abs(fresh.platformRadius - 1.2) < 1e-5)
        #expect(fresh.cellShadingEnabled == true)
        #expect(abs(fresh.cellShadingLevels - 6.0) < 1e-5)
        #expect(abs(fresh.lightVariationRate - 0.25) < 1e-5)
        #expect(fresh.beatFlashEffect.enabled == true)
        #expect(abs(fresh.beatFlashEffect.intensity - 0.7) < 1e-5)
        #expect(fresh.polarRotationEffect.direction == .clockwise)
        #expect(abs(fresh.polarRotationEffect.speed - 0.4) < 1e-5)
        #expect(fresh.juliaDriftEffect.enabled == true)
        #expect(abs(fresh.juliaDriftEffect.speed - 0.35) < 1e-5)
        #expect(fresh.safetyBubbleFadeEnabled == false)
        #expect(abs(fresh.safetyBubbleFadeWidth - 0.4) < 1e-5)
    }

    @Test("Composable Transformations STACK survives fromSettings → encode → decode → apply (order + per-op params)")
    func transformationsStackRoundTrip() throws {
        let settings = RenderSettings()
        settings.fractalType = .mandelbulb

        var sphere = SpaceWarpOpValue(kind: .sphereFold)
        sphere.strength = 0.8; sphere.p1 = 0.4; sphere.p2 = 1.7
        var twist = SpaceWarpOpValue(kind: .twist)
        twist.axis = SIMD3<Float>(0.2, 0.5, -0.8)
        var box = SpaceWarpOpValue(kind: .boxFold); box.p2 = 1   // Hall of Mirrors toggle on
        var cox = SpaceWarpOpValue(kind: .coxeter); cox.p1 = 5; cox.p2 = 3
        var plane = SpaceWarpOpValue(kind: .planeFold); plane.p1 = 0.5; plane.axis = SIMD3<Float>(1, -1, 0)
        plane.isEnabled = false   // disabled-state must survive too
        settings.spaceWarpStack = [box, sphere, twist, cox, plane]   // every recent kind, ordered

        let preset = FractalPreset.fromSettings(settings, name: "Stack")
        #expect(preset.spaceWarpOps?.count == 5)

        let data = try JSONEncoder().encode(preset)
        let decoded = try JSONDecoder().decode(FractalPreset.self, from: data)
        #expect(decoded.spaceWarpOps?.count == 5)
        #expect(decoded.spaceWarpOps?[0].type == SpaceWarpKind.boxFold.rawValue)   // order preserved
        #expect(decoded.spaceWarpOps?[1].type == SpaceWarpKind.sphereFold.rawValue)
        #expect(abs((decoded.spaceWarpOps?[1].strength ?? -1) - 0.8) < 1e-5)

        let fresh = RenderSettings()
        fresh.fractalType = .mandelbulb
        decoded.apply(to: fresh)
        #expect(fresh.spaceWarpStack.count == 5)
        #expect(fresh.spaceWarpStack[1].type == SpaceWarpKind.sphereFold.rawValue)
        #expect(abs(fresh.spaceWarpStack[1].p2 - 1.7) < 1e-5)
        #expect(abs(fresh.spaceWarpStack[2].axis.z - (-0.8)) < 1e-5)
        #expect(abs(fresh.spaceWarpStack[0].p2 - 1) < 1e-5)              // Hall of Mirrors toggle
        #expect(fresh.spaceWarpStack[3].type == SpaceWarpKind.coxeter.rawValue)
        #expect(abs(fresh.spaceWarpStack[3].p1 - 5) < 1e-5 && abs(fresh.spaceWarpStack[3].p2 - 3) < 1e-5)  // {5,3}
        #expect(fresh.spaceWarpStack[4].type == SpaceWarpKind.planeFold.rawValue)
        #expect(fresh.spaceWarpStack[4].isEnabled == false)             // disabled state preserved

        // Load is AUTHORITATIVE: a scene with no transforms clears a live stack.
        let emptyPreset = FractalPreset.fromSettings(RenderSettings(), name: "Empty")
        #expect(emptyPreset.spaceWarpOps == nil)
        emptyPreset.apply(to: fresh)
        #expect(fresh.spaceWarpStack.isEmpty)   // previous scene's transforms don't leak through
    }

    @Test("WarpCatalog is the single source of truth: one descriptor per kind, valid GPU bridge")
    func warpCatalogCoverage() throws {
        // Every kind resolves to a descriptor with a non-empty GPU apply fn.
        for kind in SpaceWarpKind.allCases {
            let d = kind.descriptor
            #expect(d.kind == kind)
            #expect(!d.gpuApplyFn.isEmpty)
            #expect(!d.displayName.isEmpty)
        }
        // Catalog covers exactly the enum (no orphan / missing entries).
        #expect(WarpCatalog.all.count == SpaceWarpKind.allCases.count)
        // The new radial family is present with the expected GPU bridge.
        #expect(SpaceWarpKind.scaleRepeat.descriptor.gpuApplyFn == "warpScaleRepeat")
        #expect(SpaceWarpKind.scaleRepeat.descriptor.gpuDEScaleFn == "warpScaleRepeatDEScale")
        #expect(SpaceWarpKind.shells.descriptor.gpuDEScaleFn == nil)  // isometric fold → deScale 1
    }

    @Test("cSpaceWarpStack packs enabled ops in order, drops disabled, caps at kMaxSpaceWarpOps")
    func spaceWarpStackPacking() throws {
        var disabled = SpaceWarpOpValue(kind: .twist); disabled.isEnabled = false
        var kept = SpaceWarpOpValue(kind: .boxFold); kept.p1 = 1.25
        let packed = cSpaceWarpStack(from: [disabled, kept])
        #expect(packed.count == 1)   // disabled dropped
        withUnsafePointer(to: packed.ops) { tuplePtr in
            tuplePtr.withMemoryRebound(to: SpaceWarpOp.self, capacity: Int(kMaxSpaceWarpOps)) { base in
                #expect(base[0].type == SpaceWarpKind.boxFold.rawValue)
                #expect(abs(base[0].p1 - 1.25) < 1e-5)
            }
        }
        // Overfilling caps at kMaxSpaceWarpOps. (Use inversion: identical inversions
        // are NOT fusable, so the simplifier can't collapse them out from under the cap.)
        let many = (0..<(Int(kMaxSpaceWarpOps) + 4)).map { _ in SpaceWarpOpValue(kind: .inversion) }
        #expect(cSpaceWarpStack(from: many).count == kMaxSpaceWarpOps)
    }

    @Test("cSpaceWarpStack precomputes GPU-ready fields (axis-normalize, squares, log, π/N)")
    func spaceWarpPrecompute() throws {
        func packed(_ v: SpaceWarpOpValue) -> SpaceWarpOp {
            let stack = cSpaceWarpStack(from: [v])
            return withUnsafePointer(to: stack.ops) { tuplePtr in
                tuplePtr.withMemoryRebound(to: SpaceWarpOp.self, capacity: Int(kMaxSpaceWarpOps)) { $0[0] }
            }
        }
        // scaleRepeat: p1 = log(max(scale, 1.1)) — the win (per-step GPU log removed).
        var sr = SpaceWarpOpValue(kind: .scaleRepeat); sr.p1 = 2.0
        #expect(abs(packed(sr).p1 - logf(2.0)) < 1e-5)
        // kaleidoscope: p1 = π / max(round(segments), 2).
        var kal = SpaceWarpOpValue(kind: .kaleidoscope); kal.p1 = 6
        #expect(abs(packed(kal).p1 - Float.pi / 6) < 1e-5)
        // sphereFold: p1 = minR², p2 = maxR².
        var sf = SpaceWarpOpValue(kind: .sphereFold); sf.p1 = 0.5; sf.p2 = 1.0
        let psf = packed(sf)
        #expect(abs(psf.p1 - 0.25) < 1e-5)   // 0.5²
        #expect(abs(psf.p2 - 1.0) < 1e-5)    // 1.0²
        // inversion: p1 = R².
        var inv = SpaceWarpOpValue(kind: .inversion); inv.p1 = 1.0
        #expect(abs(packed(inv).p1 - 1.0) < 1e-5)
        // axis pre-normalized (so the GPU just loads it).
        var tw = SpaceWarpOpValue(kind: .twist); tw.axis = SIMD3<Float>(0, 3, 0)
        let pa = packed(tw)
        #expect(abs(pa.axisX) < 1e-5 && abs(pa.axisY - 1.0) < 1e-5 && abs(pa.axisZ) < 1e-5)
        // Coxeter {4,3} (octahedral): mirror normals packed as n1=(p1,p2), n2=(axisX,axisY).
        // π/4 → cos=sin=1/√2;  n2.y = −cos(π/3)/sin(π/4) = −0.5/(1/√2) = −1/√2;  n2.z = √(1−½) = 1/√2.
        var cox = SpaceWarpOpValue(kind: .coxeter); cox.p1 = 4; cox.p2 = 3
        let pc = packed(cox)
        let invSqrt2 = 1 / sqrtf(2)
        #expect(abs(pc.p1 - (-invSqrt2)) < 1e-4)      // n1.x = −cos π/4
        #expect(abs(pc.p2 - invSqrt2) < 1e-4)         // n1.y =  sin π/4
        #expect(abs(pc.axisX - (-invSqrt2)) < 1e-4)   // n2.y
        #expect(abs(pc.axisY - invSqrt2) < 1e-4)      // n2.z
        #expect(SpaceWarpKind.coxeter.descriptor.gpuDEScaleFn == nil)   // reflections are isometric
        // Box Fold "Hall of Mirrors" option rides op.p2 untouched through precompute.
        var bf = SpaceWarpOpValue(kind: .boxFold); bf.p1 = 1.0; bf.p2 = 1
        let pbf = packed(bf)
        #expect(abs(pbf.p1 - 1.0) < 1e-5)   // fold limit precomputed (max(1,0.01))
        #expect(abs(pbf.p2 - 1.0) < 1e-5)   // toggle flag passes through
        #expect(SpaceWarpKind.boxFold.toggle != nil)
    }

    @Test("SpaceWarpStackSimplifier collapses only EXACT-equivalent adjacent ops")
    func spaceWarpSimplify() throws {
        func types(_ ops: [SpaceWarpOpValue]) -> [Int32] {
            SpaceWarpStackSimplifier.simplify(ops).map { $0.type }
        }
        func full(_ kind: SpaceWarpKind, p1: Float? = nil) -> SpaceWarpOpValue {
            var op = SpaceWarpOpValue(kind: kind); op.strength = 1.0
            if let p1 { op.p1 = p1 }
            return op
        }

        // R1 — identity ops (strength ≤ 0) are dropped.
        var dead = SpaceWarpOpValue(kind: .mirror); dead.strength = 0
        #expect(SpaceWarpStackSimplifier.simplify([dead, full(.twist)]).count == 1)

        // R2 — idempotent folds collapse at full strength with identical params…
        #expect(SpaceWarpStackSimplifier.simplify([full(.mirror), full(.mirror)]).count == 1)
        #expect(SpaceWarpStackSimplifier.simplify([full(.mirror), full(.mirror), full(.mirror)]).count == 1)
        #expect(SpaceWarpStackSimplifier.simplify([full(.shells), full(.shells)]).count == 1)
        #expect(SpaceWarpStackSimplifier.simplify([full(.scaleRepeat, p1: 2), full(.scaleRepeat, p1: 2)]).count == 1)
        // …but NOT when blended (mix at t<1 is not idempotent)…
        var half1 = SpaceWarpOpValue(kind: .mirror); half1.strength = 0.5
        var half2 = SpaceWarpOpValue(kind: .mirror); half2.strength = 0.5
        #expect(SpaceWarpStackSimplifier.simplify([half1, half2]).count == 2)
        // …and NOT when params differ (different self-similar octave size).
        #expect(SpaceWarpStackSimplifier.simplify([full(.scaleRepeat, p1: 2), full(.scaleRepeat, p1: 3)]).count == 2)

        // GUARD: kaleido and boxFold LOOK idempotent but are not — must stay separate.
        #expect(SpaceWarpStackSimplifier.simplify([full(.kaleidoscope), full(.kaleidoscope)]).count == 2)
        #expect(SpaceWarpStackSimplifier.simplify([full(.boxFold), full(.boxFold)]).count == 2)
        // GUARD: Coxeter's iterative fold isn't exactly idempotent — stays separate.
        #expect(SpaceWarpStackSimplifier.simplify([full(.coxeter), full(.coxeter)]).count == 2)

        // R3 — parallel twists add; non-parallel and cross-kind do not fuse.
        var tA = SpaceWarpOpValue(kind: .twist); tA.strength = 0.6; tA.axis = SIMD3(0, 1, 0)
        var tB = SpaceWarpOpValue(kind: .twist); tB.strength = 0.6; tB.axis = SIMD3(0, 2, 0)  // same dir, longer
        let fused = SpaceWarpStackSimplifier.simplify([tA, tB])
        #expect(fused.count == 1)
        #expect(abs(fused[0].strength - 1.2) < 1e-4)   // θ₁+θ₂
        var tC = SpaceWarpOpValue(kind: .twist); tC.axis = SIMD3(1, 0, 0)
        #expect(SpaceWarpStackSimplifier.simplify([tA, tC]).count == 2)   // different axis
        #expect(types([full(.mirror), full(.twist)]).count == 2)          // different kind

        // Order is preserved (warps don't commute) — only neighbours fuse.
        #expect(types([full(.mirror), full(.twist), full(.mirror)]) ==
                [SpaceWarpKind.mirror.rawValue, SpaceWarpKind.twist.rawValue, SpaceWarpKind.mirror.rawValue])

        // Idempotent: simplify∘simplify == simplify.
        let once = SpaceWarpStackSimplifier.simplify([full(.mirror), full(.mirror), tA, tB, dead])
        #expect(SpaceWarpStackSimplifier.simplify(once).map { $0.type } == once.map { $0.type })

        // End-to-end: the packed GPU buffer reflects the collapse (count + summed twist).
        let packedTwist = cSpaceWarpStack(from: [tA, tB])
        #expect(packedTwist.count == 1)
        withUnsafePointer(to: packedTwist.ops) { tuplePtr in
            tuplePtr.withMemoryRebound(to: SpaceWarpOp.self, capacity: Int(kMaxSpaceWarpOps)) { base in
                #expect(base[0].type == SpaceWarpKind.twist.rawValue)
                #expect(abs(base[0].strength - 1.2) < 1e-4)
            }
        }
        #expect(cSpaceWarpStack(from: [full(.mirror), full(.mirror)]).count == 1)
    }

    @Test("Plane Fold (kIFS) precompute: normal normalized, distance passthrough, isometric")
    func planeFoldPrecompute() throws {
        var pf = SpaceWarpOpValue(kind: .planeFold)
        #expect(pf.axis == SIMD3<Float>(1, -1, 0))                 // diagonal default normal
        #expect(SpaceWarpKind.planeFold.usesAxis)                  // normal is user-aimed
        #expect(SpaceWarpKind.planeFold.descriptor.gpuDEScaleFn == nil)  // reflection → isometric
        pf.p1 = 0.5                                                // plane distance
        pf.axis = SIMD3<Float>(0, 0, 3)                            // non-unit → must normalize
        let stack = cSpaceWarpStack(from: [pf])
        let op = withUnsafePointer(to: stack.ops) { tuplePtr in
            tuplePtr.withMemoryRebound(to: SpaceWarpOp.self, capacity: Int(kMaxSpaceWarpOps)) { $0[0] }
        }
        #expect(abs(op.axisX) < 1e-5 && abs(op.axisY) < 1e-5 && abs(op.axisZ - 1.0) < 1e-5)  // unit normal
        #expect(abs(op.p1 - 0.5) < 1e-5)                           // distance unchanged
    }

    @Test("Transform-stack music targets resolve dynamically + fold into snapshot strength")
    func spaceWarpMusicTargets() throws {
        // Slot resolution + availability against the live stack depth.
        #expect(MusicReactiveTarget.spaceWarp0.spaceWarpSlot == 0)
        #expect(MusicReactiveTarget.spaceWarp3.spaceWarpSlot == 3)
        #expect(MusicReactiveTarget.glow.spaceWarpSlot == nil)
        #expect(MusicReactiveTarget.availableSpaceWarpCases(count: 3) == [.spaceWarp0, .spaceWarp1, .spaceWarp2])
        #expect(MusicReactiveTarget.availableSpaceWarpCases(count: 0).isEmpty)

        // DYNAMIC id: static is nil (so it stays out of the routed-node lockstep that
        // validateStartupRouting enforces), resolved one via parameterTargetID(for:).
        #expect(MusicReactiveTarget.spaceWarp2.parameterTargetID == nil)
        #expect(MusicReactiveTarget.spaceWarp2.parameterTargetID(for: .mandelbulb)
                == ParameterTargetID.SpaceWarp.opStrength(slot: 2))
        #expect(MusicReactiveTarget.spaceWarp0.category == .transform)
        #expect(MusicReactiveTarget.spaceWarp0.allowedRange == 0...1)

        // The engine publishes a per-slot offset; the snapshot folds it into op strength.
        func packedStrength0(_ s: RenderSettings) -> Float {
            withUnsafePointer(to: s.snapshot().spaceWarpStack.ops) { tuplePtr in
                tuplePtr.withMemoryRebound(to: SpaceWarpOp.self, capacity: Int(kMaxSpaceWarpOps)) { $0[0].strength }
            }
        }
        let settings = RenderSettings()
        var op = SpaceWarpOpValue(kind: .mirror); op.strength = 0.4
        settings.spaceWarpStack = [op]
        settings.setSpaceWarpAudioOffsets([SpaceWarpFieldKey(slot: 0, field: .strength): 0.5])
        #expect(abs(packedStrength0(settings) - 0.9) < 1e-5)   // 0.4 + 0.5, within range
        settings.setSpaceWarpAudioOffsets([:])                 // cleared → base restored
        #expect(abs(packedStrength0(settings) - 0.4) < 1e-5)
    }

    @Test("Coxeter diagram naming: {p,q} → spherical / Euclidean / hyperbolic")
    func coxeterDiagramNaming() throws {
        // Spherical (1/p + 1/q > 1/2) — the polyhedral families.
        #expect(coxeterSymmetryName(p: 3, q: 3) == "Tetrahedral")
        #expect(coxeterSymmetryName(p: 4, q: 3) == "Octahedral")
        #expect(coxeterSymmetryName(p: 3, q: 4) == "Octahedral")   // dual reads the same
        #expect(coxeterSymmetryName(p: 5, q: 3) == "Icosahedral")
        #expect(coxeterSymmetryName(p: 3, q: 5) == "Icosahedral")
        #expect(coxeterSymmetryName(p: 2, q: 6) == "Dihedral")
        // Euclidean (1/p + 1/q == 1/2) — the three flat tilings.
        #expect(coxeterSymmetryName(p: 4, q: 4) == "Euclidean")
        #expect(coxeterSymmetryName(p: 3, q: 6) == "Euclidean")
        #expect(coxeterSymmetryName(p: 6, q: 3) == "Euclidean")
        // Hyperbolic (1/p + 1/q < 1/2).
        #expect(coxeterSymmetryName(p: 7, q: 3) == "Hyperbolic")
        #expect(coxeterSymmetryName(p: 5, q: 4) == "Hyperbolic")
    }

    @Test("Affine Coxeter parser: named groups → rank, renderability, aliases")
    func affineCoxeterParser() throws {
        // Renderable (tiles ≤ 3-D), catalogued symbols.
        guard case let .ok(c3) = AffineCoxeter.parse("C3~") else { Issue.record("C3~ should parse"); return }
        #expect(c3.rank == 3 && c3.actingDim == 3 && c3.coxeterSymbol == "[4,3,4]")
        guard case let .ok(g2) = AffineCoxeter.parse("G2~") else { Issue.record("G2~ should parse"); return }
        #expect(g2.rank == 2 && g2.coxeterSymbol == "[6,3]")
        // Tilde optional + lowercase both parse to the same group.
        #expect(AffineCoxeter.parse("c3") == AffineCoxeter.parse("C3~"))
        // Low-rank aliases: B̃₂ ≡ C̃₂, D̃₃ ≡ Ã₃.
        if case let .ok(b2) = AffineCoxeter.parse("B2~") { #expect(b2.family == "C" && b2.rank == 2) } else { Issue.record("B2~") }
        if case let .ok(d3) = AffineCoxeter.parse("D3~") { #expect(d3.family == "A" && d3.rank == 3) } else { Issue.record("D3~") }
        // Valid but NOT renderable (acts on > 3-D).
        guard case let .notRenderable(f4) = AffineCoxeter.parse("F4~") else { Issue.record("F4~ should be non-renderable"); return }
        #expect(f4.actingDim == 4 && !f4.renderable)
        if case .notRenderable = AffineCoxeter.parse("E8~") {} else { Issue.record("E8~ should be non-renderable") }
        // Invalid names / impossible ranks.
        if case .invalid = AffineCoxeter.parse("Z9~") {} else { Issue.record("Z9~ should be invalid") }
        if case .invalid = AffineCoxeter.parse("G3~") {} else { Issue.record("G3~ should be invalid (only G̃₂ exists)") }
        if case .invalid = AffineCoxeter.parse("F5~") {} else { Issue.record("F5~ should be invalid") }
    }

    @Test("Older scenes without the new keys decode to nil and leave live values untouched on apply")
    func legacySceneLeavesFieldsUntouched() throws {
        // A minimal flat scene with none of the newly-added keys (an older file).
        let json = """
        {
          "id": "00000000-0000-0000-0000-0000000000DD",
          "name": "Legacy",
          "createdAt": 0,
          "fractalIterations": 9,
          "maxRaySteps": 64,
          "colorMix": 0.5,
          "colorIterations": 8,
          "position": [0, 0, -1.2],
          "scale": 1,
          "fractalType": "mandelbox",
          "minDistance": 0.8,
          "fractalScale": 2.8,
          "foldingLimit": 1.0,
          "sphereRadius": 0.5
        }
        """
        let preset = try JSONDecoder().decode(FractalPreset.self, from: Data(json.utf8))
        #expect(preset.platformEnabled == nil)
        #expect(preset.cellShadingEnabled == nil)
        #expect(preset.lightVariationRate == nil)
        #expect(preset.beatFlashEffect == nil)
        #expect(preset.safetyBubbleFadeWidth == nil)

        // Pre-seed non-default live values; a legacy preset must NOT clobber them.
        let settings = RenderSettings()
        settings.fractalType = .mandelbox
        settings.platformEnabled = false
        settings.cellShadingEnabled = true
        settings.lightVariationRate = 0.2
        preset.apply(to: settings)

        #expect(settings.platformEnabled == false)
        #expect(settings.cellShadingEnabled == true)
        #expect(abs(settings.lightVariationRate - 0.2) < 1e-5)
    }
}

@Suite("Transform music field-binding — back-compat + per-field fold")
struct SpaceWarpMusicFieldTests {

    // A mapping saved before `spaceWarpField` existed has no such key; it must decode
    // to `.strength` so old scenes behave exactly as before.
    @Test("MusicReactiveMapping without spaceWarpField decodes to .strength")
    func backCompatDecodeDefaultsToStrength() throws {
        let m = MusicReactiveMapping(target: .spaceWarp0, source: .bass, amount: 1, isEnabled: true)
        let data = try JSONEncoder().encode(m)
        var obj = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["spaceWarpField"] != nil, "encode should emit the field key")
        obj.removeValue(forKey: "spaceWarpField")
        let stripped = try JSONSerialization.data(withJSONObject: obj)
        let decoded = try JSONDecoder().decode(MusicReactiveMapping.self, from: stripped)
        #expect(decoded.spaceWarpField == .strength)
    }

    @Test("A non-default spaceWarpField round-trips through Codable")
    func fieldRoundTrips() throws {
        var m = MusicReactiveMapping(target: .spaceWarp2, source: .treble, amount: 1, isEnabled: true)
        m.spaceWarpField = .param1
        let decoded = try JSONDecoder().decode(MusicReactiveMapping.self, from: JSONEncoder().encode(m))
        #expect(decoded.spaceWarpField == .param1)
    }

    @Test("applyAudioDelta writes the chosen field and clamps to its range")
    func foldAppliesToFieldAndClamps() {
        // Strength (ripple range 0…2).
        var op = SpaceWarpOpValue(kind: .ripple)
        op.strength = 0.5
        op.applyAudioDelta(0.3, field: .strength)
        #expect(abs(op.strength - 0.8) < 1e-5)
        op.applyAudioDelta(100, field: .strength)
        #expect(op.strength == 2.0)                 // clamped to strengthRange.upper

        // Param 1 (ripple Frequency, range 0.1…8, default 2).
        var op2 = SpaceWarpOpValue(kind: .ripple)
        op2.applyAudioDelta(1.0, field: .param1)
        #expect(abs(op2.p1 - 3.0) < 1e-5)

        // Axis component (range −1…1; twist default axis is (0,1,0)).
        var op3 = SpaceWarpOpValue(kind: .twist)
        op3.applyAudioDelta(0.5, field: .axisX)
        #expect(abs(op3.axis.x - 0.5) < 1e-5)
        op3.applyAudioDelta(5, field: .axisY)
        #expect(op3.axis.y == 1.0)                  // clamped to axis range upper
    }

    @Test("musicFields exposes exactly the fields each transform actually has")
    func musicFieldsMatchTransform() {
        #expect(SpaceWarpKind.mirror.musicFields == [.strength])                       // no params, no axis
        #expect(SpaceWarpKind.sphereFold.musicFields == [.strength, .param1, .param2]) // two slots, no axis
        #expect(SpaceWarpKind.ripple.musicFields == [.strength, .param1, .axisX, .axisY, .axisZ]) // slot1 + axis
    }
}

@Suite("FC_HAS_SPACEWARP pipeline-key gate")
struct SpaceWarpPipelineKeyTests {

    // The renderer bakes FC_HAS_SPACEWARP into a distinct pipeline variant and folds
    // its state into the cache key as `_SW0/_SW1`. `FractalPreset.pipelineCacheKey`
    // must carry the SAME segment (in the `_B..._SW..._N` scene slot) or a
    // prewarmed/preset pipeline is stored under a key `selectPipeline` never looks up.
    // These lock the key ⇄ FC pairing so a warped scene can never collide with the
    // `_SW0` (seam-compiled-out) variant.

    private func preset(_ configure: (RenderSettings) -> Void) -> FractalPreset {
        let s = RenderSettings()
        s.fractalType = .mandelbox
        configure(s)
        return FractalPreset.fromSettings(s, name: "k")
    }

    @Test("Empty stack bakes _SW0; any transform bakes _SW1; keys are distinct")
    func keyReflectsSpaceWarpPresence() {
        let noWarp = preset { $0.spaceWarpStack = [] }
        #expect(noWarp.pipelineCacheKey.contains("_SW0"))
        #expect(!noWarp.pipelineCacheKey.contains("_SW1"))

        let warped = preset { $0.spaceWarpStack = [SpaceWarpOpValue(kind: .mirror)] }
        #expect(warped.pipelineCacheKey.contains("_SW1"))

        // Distinct keys ⇒ distinct pipeline variants ⇒ no collision.
        #expect(noWarp.pipelineCacheKey != warped.pipelineCacheKey)
    }

    @Test("The _SW segment sits in the scene slot, matching RenderPipelineKeyContext")
    func keySegmentPosition() {
        // RenderPipelineKeyContext builds `..._RS{n}{sceneKey}_N{neon}...` with
        // sceneKey = "_B{bubble}_SW{sw}"; the preset key must mirror it exactly.
        let warped = preset { $0.spaceWarpStack = [SpaceWarpOpValue(kind: .boxFold)] }
        #expect(warped.pipelineCacheKey.contains("_SW1_N"),
                "expected `_SW1` immediately before `_N` (the scene-segment slot): \(warped.pipelineCacheKey)")
    }

    @Test("Custom fractals conservatively keep the seam ON (_SW1)")
    func customKeepsSeamOn() {
        let custom = preset { $0.fractalType = .custom; $0.spaceWarpStack = [] }
        #expect(custom.pipelineCacheKey.contains("_SW1"))
    }
}
