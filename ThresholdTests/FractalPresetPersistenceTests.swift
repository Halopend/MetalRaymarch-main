//
//  FractalPresetPersistenceTests.swift
//  ThresholdTests
//
//  Guards the second lossy-persistence fix: visual scene-state fields that
//  lived in the domain configs (Display/Color/Lighting/SafetyBubble) but were
//  never captured by FractalPreset, so authoring them then saving silently lost
//  them on reload — the same class of bug as the sphere transforms in
//  SpaceModuleTests. Device-local performance/acceleration settings
//  (QualityConfig) are deliberately NOT persisted, with one deliberate
//  exception: the Bound-to-Space room clip — its enable+mode are scene-authored
//  art (round-trip tested below). The manual room dims ride along for now, but
//  intent (2026-07-04) is auto-sizing from the sensed room, manual dims a
//  Mac/dev fallback — see REBUILD_ARCHITECTURE.md §4.5. Environment Scrunch's
//  PARAMETERS (mode/strength/reach/contain) are now scene-authored too (reverses
//  the earlier envScrunchStaysDeviceLocal decision, TECH_DEBT.md #14) — round-trip
//  tested below. Only the scanned-room SDF grid stays live/device-local: it
//  describes the user's physical space and is never serialized.
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
        var edge = EdgeDetectionEffect.outline
        edge.strength = 0.73
        edge.threshold = 0.09
        edge.softness = 0.04
        edge.windowRadius = 3
        settings.edgeDetectionEffect = edge

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
        #expect(preset.edgeDetectionEffect?.enabled == true)
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
        #expect(decoded.edgeDetectionEffect?.enabled == true)
        #expect(abs((decoded.edgeDetectionEffect?.strength ?? -1) - 0.73) < 1e-5)
        #expect(abs((decoded.edgeDetectionEffect?.threshold ?? -1) - 0.09) < 1e-5)
        #expect(abs((decoded.edgeDetectionEffect?.softness ?? -1) - 0.04) < 1e-5)
        #expect(decoded.edgeDetectionEffect?.windowRadius == 3)
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
        #expect(fresh.edgeDetectionEffect.enabled == true)
        #expect(abs(fresh.edgeDetectionEffect.strength - 0.73) < 1e-5)
        #expect(abs(fresh.edgeDetectionEffect.threshold - 0.09) < 1e-5)
        #expect(abs(fresh.edgeDetectionEffect.softness - 0.04) < 1e-5)
        #expect(fresh.edgeDetectionEffect.windowRadius == 3)
        #expect(fresh.safetyBubbleFadeEnabled == false)
        #expect(abs(fresh.safetyBubbleFadeWidth - 0.4) < 1e-5)
    }

    @Test("Bound to Space (removed 'Irregular Shape Bound') always loads OFF, even if a scene saved it on")
    func boundToSpaceLoadsDisabled() throws {
        // The feature was removed 2026-07-06: its UI and enable paths are gone.
        // The CodingKeys are kept for save-file compatibility (old scenes still
        // decode), but apply() force-disables it regardless of the saved value.
        let settings = RenderSettings()
        settings.fractalType = .mandelbox
        settings.boundToSpaceEnabled = true               // an old scene had it on
        settings.boundToSpaceMode = BoundToSpaceMode.ceilingOpen.rawValue
        settings.boundSpaceWidth = 5.5

        let preset = FractalPreset.fromSettings(settings, name: "Room")
        let decoded = try JSONDecoder().decode(
            FractalPreset.self, from: try JSONEncoder().encode(preset))

        // Fields still decode (format compatibility with older saves).
        #expect(decoded.boundToSpaceEnabled == true)

        let fresh = RenderSettings()
        fresh.fractalType = .mandelbox
        fresh.boundToSpaceEnabled = true                  // a stale live value
        decoded.apply(to: fresh)

        // …but the removed feature always loads OFF.
        #expect(fresh.boundToSpaceEnabled == false)
        #expect(fresh.snapshot().resolvedBoundToSpaceMode == 0)
    }

    @Test("Bounding SHAPE (size + Inner Shadow depth + fog mode + enable) survives fromSettings → encode → decode → scene-load apply")
    func boundingShapeRoundTrip() throws {
        // The "Jelly bowl" case: a scene authored with bounding size 1.2 and
        // Inner Shadow at 50% must restore exactly on load. Proven through the
        // SCENE-LOAD path (includePerformance: false) — the path a scene switch
        // actually uses — since the bounding-shape block lives outside that gate.
        let settings = RenderSettings()
        settings.fractalType = .mandelbox
        settings.boundingSphereSkipEnabled = true          // default false
        settings.boundingShapeRadius = 1.2                 // "1.2 bounding size", default 6.0
        settings.boundingShapeFogMode = BoundingFogMode.innerShadow.rawValue
        settings.boundingShapeShadowDepth = 0.5            // "inner shadow at 50%", default 0.35

        let preset = FractalPreset.fromSettings(settings, name: "Jelly bowl")
        let data = try JSONEncoder().encode(preset)
        let decoded = try JSONDecoder().decode(FractalPreset.self, from: data)

        #expect(decoded.boundingShapeEnabled == true)
        #expect(abs((decoded.boundingShapeRadius ?? -1) - 1.2) < 1e-5)
        #expect(decoded.boundingShapeFogMode == BoundingFogMode.innerShadow.rawValue)
        #expect(abs((decoded.boundingShapeShadowDepth ?? -1) - 0.5) < 1e-5)

        let fresh = RenderSettings()
        fresh.fractalType = .mandelbox
        decoded.apply(to: fresh, includePerformance: false)   // the scene-switch path

        #expect(fresh.boundingSphereSkipEnabled == true)
        #expect(abs(fresh.boundingShapeRadius - 1.2) < 1e-5)
        #expect(fresh.boundingShapeFogMode == BoundingFogMode.innerShadow.rawValue)
        #expect(abs(fresh.boundingShapeShadowDepth - 0.5) < 1e-5)
    }

    @Test("Environment Scrunch PARAMETERS survive fromSettings → encode → decode → scene-load apply")
    func envScrunchRoundTrip() throws {
        // The scrunch look (mode/strength/reach/contain) travels with the scene,
        // like the bounding fields. The scanned-room grid itself is not part of
        // the preset — only these parameters.
        let settings = RenderSettings()
        settings.fractalType = .mandelbox
        settings.envScrunchEnabled = true                 // default false
        settings.envScrunchMode = 1                       // Shell (default 0)
        settings.envScrunchStrength = 0.6                 // default 0.8
        settings.envScrunchReach = 1.0                    // default 0.75
        settings.envScrunchContain = 2                    // soft blend (default 0)
        settings.envScrunchContainFeather = 0.2           // default 0.1

        let preset = FractalPreset.fromSettings(settings, name: "Scrunched")
        let data = try JSONEncoder().encode(preset)
        let decoded = try JSONDecoder().decode(FractalPreset.self, from: data)

        #expect(decoded.envScrunchEnabled == true)
        #expect(decoded.envScrunchMode == 1)
        #expect(abs((decoded.envScrunchStrength ?? -1) - 0.6) < 1e-5)
        #expect(abs((decoded.envScrunchReach ?? -1) - 1.0) < 1e-5)
        #expect(decoded.envScrunchContain == 2)
        #expect(abs((decoded.envScrunchContainFeather ?? -1) - 0.2) < 1e-5)

        let fresh = RenderSettings()
        fresh.fractalType = .mandelbox
        decoded.apply(to: fresh, includePerformance: false)   // the scene-switch path

        #expect(fresh.envScrunchEnabled == true)
        #expect(fresh.envScrunchMode == 1)
        #expect(abs(fresh.envScrunchStrength - 0.6) < 1e-5)
        #expect(abs(fresh.envScrunchReach - 1.0) < 1e-5)
        #expect(fresh.envScrunchContain == 2)
        #expect(abs(fresh.envScrunchContainFeather - 0.2) < 1e-5)

        // AUTHORITATIVE: a scene WITHOUT scrunch clears it back to the default,
        // rather than leaking the previous scene's scrunch forward.
        let bare = FractalPreset(name: "Bare")
        let user = RenderSettings()
        user.envScrunchEnabled = true
        user.envScrunchStrength = 0.9
        bare.apply(to: user, includePerformance: false)
        #expect(user.envScrunchEnabled == false)
        #expect(abs(user.envScrunchStrength - 0.8) < 1e-5)
    }

    @Test("Containment mode round-trips: a Surroundings scene stays UNBOUNDED on load")
    func containmentModeRoundTrip() throws {
        // The Containment concept (MixedContainment) is derived from two saved
        // flags — boundingShapeEnabled (Bounded) and envScrunchEnabled
        // (Surroundings). This pins the intent the picker exists for: a scene
        // deliberately authored UNBOUNDED (Surroundings — bounding off, scrunch
        // on) must NOT be forced back to Bounded on load. The bounding-shape
        // apply defaults an ABSENT flag to `mixedModeScene == true`, so the
        // saved explicit `false` is what keeps a Mixed scene unbounded.
        let surroundings = RenderSettings()
        surroundings.fractalType = .mandelbox
        surroundings.boundingSphereSkipEnabled = false   // no bounding shape
        surroundings.envScrunchEnabled = true            // grounded to the room
        surroundings.envScrunchContain = 2               // Blend

        let preset = FractalPreset.fromSettings(surroundings, name: "Grounded")
        let decoded = try JSONDecoder().decode(
            FractalPreset.self, from: try JSONEncoder().encode(preset))

        // Explicit false is saved (not nil) so load can't fall back to the
        // Mixed→Bounded default.
        #expect(decoded.boundingShapeEnabled == false)
        #expect(decoded.envScrunchEnabled == true)

        let fresh = RenderSettings()
        fresh.fractalType = .mandelbox
        fresh.boundingSphereSkipEnabled = true           // a Bounded scene was live before
        decoded.apply(to: fresh, includePerformance: false)

        #expect(fresh.boundingSphereSkipEnabled == false, "Surroundings scene must load unbounded, not forced back to Bounded")
        #expect(fresh.envScrunchEnabled == true)
        #expect(fresh.envScrunchContain == 2)

        // And a Bounded scene loading afterward flips it back — no leak.
        let bounded = RenderSettings()
        bounded.fractalType = .mandelbox
        bounded.boundingSphereSkipEnabled = true
        bounded.envScrunchEnabled = false
        let boundedDecoded = try JSONDecoder().decode(
            FractalPreset.self, from: try JSONEncoder().encode(
                FractalPreset.fromSettings(bounded, name: "Held")))
        boundedDecoded.apply(to: fresh, includePerformance: false)
        #expect(fresh.boundingSphereSkipEnabled == true)
        #expect(fresh.envScrunchEnabled == false)
    }

    @Test("Scene apply is ORDER-INDEPENDENT: loading A then B equals loading B fresh")
    func sceneApplyOrderIndependent() throws {
        // The user-visible bug this pins: "restoring scenes feels broken — it's
        // picking up things from the previous scene." Any field the capture
        // side writes conditionally (nil when default/off) combined with an
        // only-if-present apply() makes the result depend on what was loaded
        // BEFORE. This test loads a kitchen-sink scene A, then a plain scene B,
        // and demands the re-captured scene state be byte-identical to loading
        // B into fresh settings. Deliberate user-owned stickiness (safety
        // bubble, beta-gated hand effects) is deliberately NOT exercised here.
        let a = RenderSettings()
        a.fractalType = .mandelbox
        a.platformEnabled = false
        a.platformRadius = 1.1
        a.cellShadingEnabled = true
        a.cellShadingLevels = 6.0
        a.lightVariationRate = 0.3
        var beat = BeatFlashEffect(); beat.enabled = true; beat.intensity = 0.6
        a.beatFlashEffect = beat
        var polar = PolarRotationEffect(); polar.direction = .clockwise; polar.speed = 0.5
        a.polarRotationEffect = polar
        var julia = JuliaDriftEffect(); julia.enabled = true; julia.speed = 0.4
        a.juliaDriftEffect = julia
        a.boundToSpaceEnabled = true
        a.boundToSpaceMode = BoundToSpaceMode.wallsOpen.rawValue
        a.boundSpaceWidth = 6.0; a.boundSpaceDepth = 3.0; a.boundSpaceHeight = 3.2
        var twist = SpaceWarpOpValue(kind: .twist); twist.strength = 0.7
        var mirror = SpaceWarpOpValue(kind: .mirror); mirror.strength = 1.0
        a.spaceWarpStack = [twist, mirror]
        a.deIterationMismatch = 0.35
        a.sphereProjectionBlend = 0.5
        a.sphereProjectionRadius = 1.4
        a.detailScale = 2.0
        a.targetDetailScale = 2.0
        a.worldRotation = simd_quatf(angle: 0.7, axis: SIMD3<Float>(0, 1, 0))
        a.colorMix = 0.8
        a.fractalScale = 2.4
        a.foldingLimit = 1.2
        a.sphereRadius = 0.4
        a.minDistance = 0.6
        let presetA = FractalPreset.fromSettings(a, name: "A")

        // Scene B: a plain, everything-default scene (like an older file).
        let presetB = FractalPreset.fromSettings(RenderSettings(), name: "B")

        let fixedID = UUID(uuidString: "00000000-0000-0000-0000-0000000000AB")!
        let fixedDate = Date(timeIntervalSince1970: 0)
        // Gradient stops (and similar value objects) mint a random UUID per
        // instance, so two semantically-identical defaults never byte-compare.
        // Strip every "id" key recursively before comparing.
        func scrubIDs(_ value: Any) -> Any {
            if var dict = value as? [String: Any] {
                dict.removeValue(forKey: "id")
                return dict.mapValues { scrubIDs($0) }
            }
            if let arr = value as? [Any] { return arr.map { scrubIDs($0) } }
            return value
        }
        func recapture(_ s: RenderSettings) throws -> (json: String, dict: [String: Any]) {
            let p = FractalPreset.fromSettings(s, name: "cmp", id: fixedID, createdAt: fixedDate)
            let data = try JSONEncoder().encode(p)
            let raw = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let dict = try #require(scrubIDs(raw) as? [String: Any])
            let canonical = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
            return (String(data: canonical, encoding: .utf8) ?? "", dict)
        }

        let fresh = RenderSettings()
        presetB.apply(to: fresh)
        let chained = RenderSettings()
        presetA.apply(to: chained)
        // Live gesture state from "before the load" must not survive it: zoom
        // and rotation offsets ride in manualOffset* even outside animation
        // playback, which was the main "never restores the same way" leak.
        chained.manualOffsetDetailScale = 1.5
        chained.manualOffsetMinDistance = 0.4
        chained.manualRotationOffset = simd_quatf(angle: 0.5, axis: SIMD3<Float>(1, 0, 0))
        presetB.apply(to: chained)
        #expect(chained.manualOffsetDetailScale == 0)
        #expect(chained.manualOffsetMinDistance == 0)

        // Same demand for an OLD scene file with none of the newer keys: after
        // the kitchen-sink scene, loading it must land on the same state as
        // loading it into fresh settings.
        let legacyJSON = """
        {
          "id": "00000000-0000-0000-0000-0000000000CE",
          "name": "Old",
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
        let legacy = try JSONDecoder().decode(FractalPreset.self, from: Data(legacyJSON.utf8))
        let legacyFresh = RenderSettings()
        legacy.apply(to: legacyFresh)
        let legacyChained = RenderSettings()
        presetA.apply(to: legacyChained)
        legacy.apply(to: legacyChained)

        func expectNoLeak(_ fresh: (json: String, dict: [String: Any]),
                          _ chained: (json: String, dict: [String: Any]),
                          label: String) {
            guard fresh.json != chained.json else { return }
            // Name exactly which fields depended on load order.
            let keys = Set(fresh.dict.keys).union(chained.dict.keys).sorted()
            var leaks: [String] = []
            for k in keys {
                let lhs = fresh.dict[k].map { "\($0)" } ?? "∅"
                let rhs = chained.dict[k].map { "\($0)" } ?? "∅"
                if lhs != rhs { leaks.append("\(k): fresh=\(lhs) afterA=\(rhs)") }
            }
            Issue.record("""
                [\(label)] scene apply leaked \(leaks.count) field(s) from the \
                previously loaded scene:\n\(leaks.joined(separator: "\n"))
                """)
        }
        expectNoLeak(try recapture(fresh), try recapture(chained), label: "current-format B")
        expectNoLeak(try recapture(legacyFresh), try recapture(legacyChained), label: "legacy B")
    }

    // NOTE: the former `envScrunchStaysDeviceLocal` test was removed 2026-07-05
    // when scrunch PARAMETERS became scene-authored (see envScrunchRoundTrip
    // above and the file header). Only the scanned-room SDF grid stays live/
    // device-local — it is never part of a FractalPreset in the first place.

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

    @Test("Older scenes without the new keys decode to nil and apply as DEFAULTS (authoritative reset)")
    func legacySceneResetsMissingFieldsToDefaults() throws {
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
        #expect(preset.edgeDetectionEffect == nil)
        #expect(preset.safetyBubbleFadeWidth == nil)

        // Pre-seed non-default live values. Under the ORDER-INDEPENDENT apply
        // semantics (2026-07-04, "scene restore feels broken" fix) a legacy
        // preset RESETS missing fields to their declaration defaults — the
        // previous scene's look must never bleed into the loaded one. (The
        // safety bubble and beta-gated hand effects remain the documented
        // user-owned exceptions.)
        let settings = RenderSettings()
        settings.fractalType = .mandelbox
        settings.platformEnabled = false
        settings.cellShadingEnabled = true
        settings.lightVariationRate = 0.2
        settings.edgeDetectionEffect = .outline
        settings.boundToSpaceEnabled = true
        preset.apply(to: settings)

        #expect(settings.platformEnabled == true)              // default
        #expect(settings.cellShadingEnabled == false)          // default
        #expect(abs(settings.lightVariationRate - 0.5) < 1e-5) // default
        #expect(settings.edgeDetectionEffect == .off)          // default
        #expect(settings.boundToSpaceEnabled == false)         // default

        // Before edgeDetectionEffect had its own scene field, the dedicated
        // lighting preset was the persisted signal. It must still reconstruct
        // its outline rather than following the generic missing-field OFF path.
        var legacyEdgePreset = preset
        legacyEdgePreset.lightingPreset = .edgeDetection
        let edgeSettings = RenderSettings()
        legacyEdgePreset.apply(to: edgeSettings)
        #expect(edgeSettings.edgeDetectionEffect == .outline)

        // The new per-scene performance profile also decodes to nil for older files.
        #expect(preset.coneMarchCompatible == nil)
        #expect(preset.recommendedQuality == nil)
    }

    @Test("Per-scene performance profile (cone-march gate + quality target) round-trips through the scene-load path")
    func performanceProfileRoundTrip() throws {
        let settings = RenderSettings()
        settings.fractalType = .mandelbox
        settings.sceneConeMarchCompatible = false          // default true → this scene opts OUT
        settings.applyRecommendedQuality(.high)            // records target + lifts the governor floor

        let preset = FractalPreset.fromSettings(settings, name: "Profile")
        #expect(preset.coneMarchCompatible == false)
        #expect(preset.recommendedQuality == .high)

        let decoded = try JSONDecoder().decode(
            FractalPreset.self, from: try JSONEncoder().encode(preset))
        #expect(decoded.coneMarchCompatible == false)
        #expect(decoded.recommendedQuality == .high)

        // Restore through the SCENE-SWITCH path (includePerformance: false) — the
        // profile applies there too, so a scene switch honors the gate + floor.
        let fresh = RenderSettings()
        fresh.fractalType = .mandelbox
        decoded.apply(to: fresh, includePerformance: false)
        #expect(fresh.sceneConeMarchCompatible == false)
        #expect(fresh.recommendedQuality == .high)
        #expect(abs(fresh.sceneRenderQualityFloor - SceneQualityTarget.high.visionRenderQualityFloor) < 1e-6)
    }

    @Test("Cone-march gate zeroes the EFFECTIVE march strength for an incompatible scene (device setting untouched)")
    func coneMarchGateSuppressesStrength() {
        let settings = RenderSettings()
        settings.fractalType = .mandelbox
        settings.coneMarchStrength = 0.8                    // user's device setting

        settings.sceneConeMarchCompatible = true
        #expect(abs(settings.snapshot().coneMarchStrength - 0.8) < 1e-6)   // compatible → passes through

        settings.sceneConeMarchCompatible = false
        #expect(settings.snapshot().coneMarchStrength == 0.0)             // incompatible → suppressed

        // Only the effective (snapshot) value is gated; the user's setting is intact.
        #expect(abs(settings.coneMarchStrength - 0.8) < 1e-6)
    }

    @Test("Per-scene profile is AUTHORITATIVE: a plain scene resets the gate + governor floor (no leak)")
    func performanceProfileAuthoritativeReset() {
        // A live "ultra, cone-march-incompatible" scene…
        let live = RenderSettings()
        live.fractalType = .mandelbox
        live.sceneConeMarchCompatible = false
        live.applyRecommendedQuality(.ultra)
        #expect(abs(live.sceneRenderQualityFloor - SceneQualityTarget.ultra.visionRenderQualityFloor) < 1e-6)

        // …then a plain scene carrying neither field must reset both, not inherit them.
        let plain = FractalPreset(name: "Plain")
        #expect(plain.coneMarchCompatible == nil)
        #expect(plain.recommendedQuality == nil)
        plain.apply(to: live, includePerformance: false)

        #expect(live.sceneConeMarchCompatible == true)     // reset to compatible
        #expect(live.recommendedQuality == nil)
        #expect(abs(live.sceneRenderQualityFloor - QualityConfig.visionMinRenderQuality) < 1e-6)  // floor back to global min
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

    @Test("MusicReactiveMapping sanitizes runtime modulation inputs")
    func mappingSanitizesAmountsAndSmoothing() {
        var mapping = MusicReactiveMapping(
            target: .glow,
            source: .bass,
            amount: 99,
            isEnabled: true,
            smoothingWindow: 9,
            hybridCombo: -2
        )

        #expect(mapping.amount == 3.0)
        #expect(mapping.smoothingWindow == 2.0)
        #expect(mapping.hybridCombo == 0.0)

        mapping.amount = -99
        mapping.smoothingWindow = -9
        mapping.hybridCombo = 9
        mapping.sanitizeInPlace()

        #expect(mapping.amount == -3.0)
        #expect(mapping.smoothingWindow == 0.0)
        #expect(mapping.hybridCombo == 1.0)
    }

    @Test("RenderSettings music mappings drop duplicate targets during assignment")
    func renderSettingsMusicMappingsAreDeduplicated() {
        let settings = RenderSettings()
        settings.musicReactiveMappings = [
            MusicReactiveMapping(target: .glow, source: .bass, amount: 1, isEnabled: true),
            MusicReactiveMapping(target: .glow, source: .treble, amount: 2, isEnabled: true),
            MusicReactiveMapping(target: .fog, source: .mid, amount: 1, isEnabled: false)
        ]

        let mappings = settings.musicReactiveMappings
        #expect(mappings.map(\.target) == [.glow, .fog])
        #expect(mappings.first?.source == .bass)
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
        // sceneKey = "_B{bubble}_SW{sw}{deTail}"; the preset key must mirror it
        // exactly. macOS presets prewarm the DE-tail-OFF variant, appending
        // "_ES0_HF0" after _SW; other platforms leave the de-tail segment empty.
        let warped = preset { $0.spaceWarpStack = [SpaceWarpOpValue(kind: .boxFold)] }
        #if os(macOS)
        #expect(warped.pipelineCacheKey.contains("_SW1_ES0_HF0_N"),
                "expected `_SW1_ES0_HF0` immediately before `_N` (the scene-segment slot): \(warped.pipelineCacheKey)")
        #else
        #expect(warped.pipelineCacheKey.contains("_SW1_N"),
                "expected `_SW1` immediately before `_N` (the scene-segment slot): \(warped.pipelineCacheKey)")
        #endif
    }

    @Test("Custom fractals conservatively keep the seam ON (_SW1)")
    func customKeepsSeamOn() {
        let custom = preset { $0.fractalType = .custom; $0.spaceWarpStack = [] }
        #expect(custom.pipelineCacheKey.contains("_SW1"))
    }
}
