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
        var sb = settings.safetyBubbleConfig
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
        settings.spaceWarpStack = [SpaceWarpOpValue(kind: .boxFold), sphere, twist]   // multiple kinds, ordered

        let preset = FractalPreset.fromSettings(settings, name: "Stack")
        #expect(preset.spaceWarpOps?.count == 3)

        let data = try JSONEncoder().encode(preset)
        let decoded = try JSONDecoder().decode(FractalPreset.self, from: data)
        #expect(decoded.spaceWarpOps?.count == 3)
        #expect(decoded.spaceWarpOps?[0].type == SpaceWarpKind.boxFold.rawValue)   // order preserved
        #expect(decoded.spaceWarpOps?[1].type == SpaceWarpKind.sphereFold.rawValue)
        #expect(abs((decoded.spaceWarpOps?[1].strength ?? -1) - 0.8) < 1e-5)

        let fresh = RenderSettings()
        fresh.fractalType = .mandelbulb
        decoded.apply(to: fresh)
        #expect(fresh.spaceWarpStack.count == 3)
        #expect(fresh.spaceWarpStack[1].type == SpaceWarpKind.sphereFold.rawValue)
        #expect(abs(fresh.spaceWarpStack[1].p2 - 1.7) < 1e-5)
        #expect(abs(fresh.spaceWarpStack[2].axis.z - (-0.8)) < 1e-5)
    }

    @Test("SpaceWarpStackCodegen emits unrolled type-dispatched MSL + a structure signature")
    func warpStackCodegen() throws {
        // Empty → no codegen (keep the bundled runtime loop).
        let empty = SpaceWarpStackCodegen.generate([])
        #expect(empty.source == nil)
        #expect(empty.signature == "s0")

        var sphere = SpaceWarpOpValue(kind: .sphereFold)
        var disabled = SpaceWarpOpValue(kind: .twist); disabled.isEnabled = false
        let gen = SpaceWarpStackCodegen.generate([SpaceWarpOpValue(kind: .boxFold), sphere, disabled])

        #expect(gen.signature == "s3.4")   // boxFold=3, sphereFold=4; disabled twist dropped
        let src = try #require(gen.source)
        #expect(src.contains("#define THRESHOLD_CODEGEN_SPACEWARP_STACK"))
        // Unrolled, type-dispatched, fixed indices, live uniform reads.
        #expect(src.contains("warpBoxFold(p, params.spaceWarpOps[0])"))
        #expect(src.contains("warpSphereFold(p, params.spaceWarpOps[1])"))
        // Sphere fold contributes a DE divisor; box fold does not.
        #expect(src.contains("warpSphereFoldDEScale(q, params.spaceWarpOps[1])"))
        #expect(!src.contains("warpTwist"))   // disabled op absent
        // Fused hot-path sweep is emitted too: point + DE divisor in one pass.
        #expect(src.contains("FORCE_INLINE SpaceTransform spaceWarpStackTransform"))
        #expect(src.contains("r.point = warpBoxFold(r.point, params.spaceWarpOps[0])"))
        #expect(src.contains("r.deScale *= warpSphereFoldDEScale(r.point, params.spaceWarpOps[1])"))
        _ = sphere
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

    @Test("Codegen drives the new radial kinds straight from the catalog")
    func warpStackCodegenRadial() throws {
        let gen = SpaceWarpStackCodegen.generate([
            SpaceWarpOpValue(kind: .shells), SpaceWarpOpValue(kind: .scaleRepeat),
        ])
        #expect(gen.signature == "s9.10")
        let src = try #require(gen.source)
        #expect(src.contains("warpShells(p, params.spaceWarpOps[0])"))
        #expect(src.contains("warpScaleRepeat(p, params.spaceWarpOps[1])"))
        #expect(src.contains("warpScaleRepeatDEScale(q, params.spaceWarpOps[1])"))
        // Shells is isometric → no deScale multiply emitted for it.
        #expect(!src.contains("warpShellsDEScale"))
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
        // Overfilling caps at kMaxSpaceWarpOps.
        let many = (0..<(Int(kMaxSpaceWarpOps) + 4)).map { _ in SpaceWarpOpValue(kind: .mirror) }
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
