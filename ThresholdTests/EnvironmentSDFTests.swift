//
//  EnvironmentSDFTests.swift
//  ThresholdTests
//
//  TECH_DEBT.md #18 (+ the #19 farClamp pin) — golden-value tests for the
//  Environment Scrunch CPU geometry. Everything here is pure math (only the
//  bakes need an MTLDevice for their output buffer), and it is the SAME code
//  the not-yet-device-verified visionOS mesh path runs — so a wrong
//  barycentric region or a mis-indexed voxel is a red test here instead of a
//  silently wrong scrunch on device.
//

import Testing
import Foundation
import Metal
import simd
@testable import Threshold

@Suite("EnvironmentSDF — point-triangle / bake / parse golden values")
struct EnvironmentSDFTests {

    // MARK: - point→triangle distance (Ericson 7-region barycentric)

    /// Brute-force reference: dense clamped-barycentric sampling. Slow and
    /// discretized, but obviously correct — the region-test implementation
    /// must agree within the sampling resolution.
    private func referenceDistance(_ p: SIMD3<Float>,
                                   _ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) -> Float {
        var best = Float.greatestFiniteMagnitude
        let n = 200
        for i in 0...n {
            for j in 0...(n - i) {
                let u = Float(i) / Float(n), v = Float(j) / Float(n)
                let q = a + (b - a) * u + (c - a) * v
                best = min(best, simd_length(p - q))
            }
        }
        return best
    }

    @Test("pointTriangleDistance: one analytic golden case per barycentric region")
    func pointTriangleRegions() {
        let a = SIMD3<Float>(0, 0, 0), b = SIMD3<Float>(1, 0, 0), c = SIMD3<Float>(0, 1, 0)
        func d(_ p: SIMD3<Float>) -> Float { EnvironmentSDFGrid.pointTriangleDistance(p, a, b, c) }
        // Face region: directly above the interior.
        #expect(abs(d(SIMD3(0.25, 0.25, 1.0)) - 1.0) < 1e-5)
        // Vertex regions.
        #expect(abs(d(SIMD3(-1, -1, 0)) - sqrt(2.0 as Float)) < 1e-5)   // → a
        #expect(abs(d(SIMD3(2, 0, 0)) - 1.0) < 1e-5)                    // → b
        #expect(abs(d(SIMD3(0, 2, 0)) - 1.0) < 1e-5)                    // → c
        // Edge regions.
        #expect(abs(d(SIMD3(0.5, -1, 0)) - 1.0) < 1e-5)                 // → ab
        #expect(abs(d(SIMD3(-1, 0.5, 0)) - 1.0) < 1e-5)                 // → ac
        #expect(abs(d(SIMD3(1, 1, 0)) - sqrt(0.5 as Float)) < 1e-5)     // → bc midpoint
        // On the triangle itself.
        #expect(d(SIMD3(0.25, 0.25, 0)) < 1e-6)
    }

    @Test("pointTriangleDistance: deterministic fuzz agrees with brute-force reference")
    func pointTriangleFuzz() {
        // Deterministic LCG — no Math.random in tests (repeatability).
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func next() -> Float {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Float((seed >> 33) & 0xFFFFFF) / Float(0xFFFFFF) * 4.0 - 2.0
        }
        let a = SIMD3<Float>(-0.5, 0.2, 0.1), b = SIMD3<Float>(1.1, -0.3, 0.4), c = SIMD3<Float>(0.2, 0.9, -0.8)
        for _ in 0..<60 {
            let p = SIMD3<Float>(next(), next(), next())
            let fast = EnvironmentSDFGrid.pointTriangleDistance(p, a, b, c)
            let ref = referenceDistance(p, a, b, c)
            // Reference is discretized (n=200 over a ~2-unit triangle) — its
            // answer can only be ≥ the true distance, by at most ~half a step.
            #expect(fast <= ref + 1e-4, "fast \(fast) exceeded reference \(ref) at \(p)")
            #expect(ref - fast < 0.02, "fast \(fast) too far below reference \(ref) at \(p)")
        }
    }

    // MARK: - synthetic primitives

    @Test("SyntheticPrimitive.distance: signed analytic values")
    func primitiveDistances() {
        let floor = EnvironmentSDFGrid.SyntheticPrimitive.floor(y: 0)
        #expect(abs(floor.distance(to: SIMD3(3, 1.5, -2)) - 1.5) < 1e-6)
        #expect(abs(floor.distance(to: SIMD3(0, -2, 0)) - 2.0) < 1e-6)   // unsigned plane

        let sphere = EnvironmentSDFGrid.SyntheticPrimitive.sphere(center: .zero, radius: 1)
        #expect(abs(sphere.distance(to: SIMD3(2, 0, 0)) - 1.0) < 1e-6)
        #expect(abs(sphere.distance(to: SIMD3(0.5, 0, 0)) - (-0.5)) < 1e-6) // signed inside

        let box = EnvironmentSDFGrid.SyntheticPrimitive.box(center: .zero, halfExtent: SIMD3(1, 1, 1))
        #expect(abs(box.distance(to: SIMD3(2, 0, 0)) - 1.0) < 1e-6)
        #expect(abs(box.distance(to: SIMD3(2, 2, 0)) - sqrt(2.0 as Float)) < 1e-6) // corner
        #expect(abs(box.distance(to: .zero) - (-1.0)) < 1e-6)                      // signed inside
    }

    @Test("parseSynthetic: grammar, default demo room, malformed-part skipping")
    func parseGrammar() {
        // "1" → the default demo room (floor + sphere + box).
        let demo = EnvironmentSDFGrid.parseSynthetic("1")
        #expect(demo.count == 3)

        let prims = EnvironmentSDFGrid.parseSynthetic(" floor : 0.5 ; sphere: 1, 2, 3, 0.5 ; box:0,1,0,1,2,3 ")
        #expect(prims.count == 3)
        if case .floor(let y) = prims[0] { #expect(abs(y - 0.5) < 1e-6) } else { Issue.record("expected floor") }
        if case .sphere(let c, let r) = prims[1] {
            #expect(c == SIMD3<Float>(1, 2, 3)); #expect(abs(r - 0.5) < 1e-6)
        } else { Issue.record("expected sphere") }
        if case .box(let c, let h) = prims[2] {
            #expect(c == SIMD3<Float>(0, 1, 0)); #expect(h == SIMD3<Float>(1, 2, 3))
        } else { Issue.record("expected box") }

        // Malformed parts are skipped, valid ones survive.
        let partial = EnvironmentSDFGrid.parseSynthetic("floor:;sphere:1,2;bogus:1;box:1,2,3,4,5,6")
        #expect(partial.count == 1)
        if case .box = partial[0] {} else { Issue.record("expected the box to survive") }
    }

    // MARK: - bakes (need a Metal device for the output buffer only)

    @Test("bakeSynthetic: voxel distances match the analytic SDF (unsigned, clamped) + containment AABB")
    func syntheticBakeGoldenValues() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let origin = SIMD3<Float>(-4.0, -0.5, -4.0)
        let size = SIMD3<Float>(8.0, 4.0, 8.0)
        let grid = try #require(EnvironmentSDFGrid.bakeSynthetic(
            device: device, primitives: [.floor(y: 0)], originWorld: origin, sizeWorld: size))
        let dim = EnvironmentSDFGrid.dim
        let cell = grid.cellSize
        let values = grid.buffer.contents().assumingMemoryBound(to: Float16.self)
        func at(_ x: Int, _ y: Int, _ z: Int) -> Float { Float(values[(z * dim + y) * dim + x]) }

        // Voxel-center distances to the y=0 plane, clamped at clampFar.
        for yi in [0, 1, 8, 20, 40, dim - 1] {
            let yCenter = origin.y + (Float(yi) + 0.5) * cell.y
            let expected = min(abs(yCenter), EnvironmentSDFGrid.clampFar)
            // Same value regardless of x/z (plane spans the grid).
            #expect(abs(at(3, yi, 5) - expected) < 0.01, "y index \(yi): got \(at(3, yi, 5)), expected \(expected)")
            #expect(abs(at(60, yi, 60) - expected) < 0.01)
        }
        // Containment AABB: the floor spans the grid footprint at y = 0.
        #expect(grid.surfaceMinWorld == SIMD3<Float>(origin.x, 0, origin.z))
        #expect(grid.surfaceMaxWorld == SIMD3<Float>(origin.x + size.x, 0, origin.z + size.z))

        // Empty primitive list refuses to bake.
        #expect(EnvironmentSDFGrid.bakeSynthetic(device: device, primitives: [], originWorld: origin) == nil)
    }

    @Test("bakeSynthetic: default demo room's containment AABB is the primitive union")
    func syntheticBakeDemoAABB() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let origin = SIMD3<Float>(-4.0, -0.5, -4.0)
        let grid = try #require(EnvironmentSDFGrid.bakeSynthetic(
            device: device, primitives: EnvironmentSDFGrid.parseSynthetic("1"), originWorld: origin))
        // floor y=0 spans grid xz; sphere (0,0.9,1) r 0.35 → y max 1.25; box tops out at 0.9.
        #expect(grid.surfaceMinWorld == SIMD3<Float>(-4.0, 0.0, -4.0))
        #expect(abs(grid.surfaceMaxWorld.y - 1.25) < 1e-6)
        #expect(grid.surfaceMaxWorld.x == 4.0 && grid.surfaceMaxWorld.z == 4.0)
    }

    @Test("bake (mesh): tight triangle AABB, near-voxel accuracy, far-voxel clamp")
    func meshBakeGoldenValues() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let origin = SIMD3<Float>(-4.0, -0.5, -4.0)
        let a = SIMD3<Float>(0, 0, 0), b = SIMD3<Float>(1, 0, 0), c = SIMD3<Float>(0, 0, 1)
        let grid = try #require(EnvironmentSDFGrid.bake(
            device: device, triangles: [a, b, c], originWorld: origin))
        // Containment AABB = the triangle's tight bounds (TECH_DEBT.md #18 widened scope).
        #expect(grid.surfaceMinWorld == SIMD3<Float>(0, 0, 0))
        #expect(grid.surfaceMaxWorld == SIMD3<Float>(1, 0, 1))

        let dim = EnvironmentSDFGrid.dim
        let cell = grid.cellSize
        let values = grid.buffer.contents().assumingMemoryBound(to: Float16.self)
        // Voxel near the triangle: stored distance == exact point-triangle distance.
        let xi = 34, yi = 8, zi = 34   // world ≈ (0.3125, 0.03125, 0.3125), above the tri interior
        let p = origin + (SIMD3<Float>(Float(xi), Float(yi), Float(zi)) + 0.5) * cell
        let exact = EnvironmentSDFGrid.pointTriangleDistance(p, a, b, c)
        let stored = Float(values[(zi * dim + yi) * dim + xi])
        #expect(exact < 1.0, "test voxel should be inside the splat band")
        #expect(abs(stored - exact) < 0.01, "stored \(stored) vs exact \(exact)")
        // Voxel far outside the splat radius stays at the far clamp.
        let farStored = Float(values[(0 * dim + (dim - 1)) * dim + 0])
        #expect(abs(farStored - EnvironmentSDFGrid.clampFar) < 0.01)

        // Fewer than 3 vertices refuses to bake.
        #expect(EnvironmentSDFGrid.bake(device: device, triangles: [a, b], originWorld: origin) == nil)
    }

    // MARK: - makeEnvScrunchParams conversion (world → grid, farClamp pin)

    @Test("makeEnvScrunchParams: grid-coord conversion, containment gating, farClampModel (#19 pin)")
    func envScrunchParamsConversion() {
        let settings = RenderSettings()
        settings.envScrunchEnabled = true
        settings.envScrunchStrength = 0.9
        settings.envScrunchReach = 1.2
        settings.envScrunchContain = 1
        let snap = settings.snapshot()

        let gridOrigin = SIMD3<Float>(-4.0, -0.5, -4.0)
        let gridCell = SIMD3<Float>(0.125, 0.0625, 0.125)
        func make(modelToWorld: matrix_float4x4 = matrix_identity_float4x4,
                  contain: SIMD3<Float> = SIMD3(1, 1, 1)) -> EnvScrunchParams {
            snap.makeEnvScrunchParams(modelToWorld: modelToWorld,
                                      viewerWorld: .zero,
                                      gridOrigin: gridOrigin, gridCell: gridCell,
                                      gridAddress: 0xDEAD_BEEF,
                                      surfaceMinWorld: -contain, surfaceMaxWorld: contain,
                                      farClampMeters: EnvironmentSDFGrid.clampFar)
        }

        // Identity model→world: metersToModel = 1.
        let p = make()
        #expect(p.enabled == 1)
        #expect(p.mode == 0)
        #expect(abs(p.bandModel - 1.2) < 1e-6)
        // #19: the shader's out-of-grid return is the bake's clamp, in model units.
        #expect(abs(p.farClampModel - EnvironmentSDFGrid.clampFar) < 1e-6)
        // World AABB (−1…1) → grid texels: (w − origin) / cell, clamped to [0, dim].
        #expect(abs(p.containMinGrid.x - 24) < 1e-4)
        #expect(abs(p.containMinGrid.y - 0) < 1e-4)   // (−1 − −0.5)/0.0625 = −8 → clamped to 0
        #expect(abs(p.containMaxGrid.x - 40) < 1e-4 && abs(p.containMaxGrid.y - 24) < 1e-4)
        #expect(p.containMode == 1)
        #expect(p.cellModel == gridCell)

        // Uniform model scale 2 → metersToModel 0.5 scales every distance field.
        var scaled = matrix_identity_float4x4
        scaled.columns.0.x = 2; scaled.columns.1.y = 2; scaled.columns.2.z = 2
        let ps = make(modelToWorld: scaled)
        #expect(abs(ps.metersToModel - 0.5) < 1e-6)
        #expect(abs(ps.farClampModel - EnvironmentSDFGrid.clampFar * 0.5) < 1e-6)
        #expect(abs(ps.bandModel - 0.6) < 1e-6)

        // Degenerate surface AABB → containment off, scrunch still on.
        let pd = make(contain: .zero)
        #expect(pd.enabled == 1 && pd.containMode == 0)

        // Contain setting 0 → containMode 0 even with a valid AABB.
        settings.envScrunchContain = 0
        let p0 = settings.snapshot().makeEnvScrunchParams(
            modelToWorld: matrix_identity_float4x4,
            viewerWorld: .zero,
            gridOrigin: gridOrigin, gridCell: gridCell, gridAddress: 0xDEAD_BEEF,
            surfaceMinWorld: SIMD3(-1, -1, -1), surfaceMaxWorld: SIMD3(1, 1, 1),
            farClampMeters: EnvironmentSDFGrid.clampFar)
        #expect(p0.containMode == 0)

        // Grid address 0 → whole feature disabled (never dereferenced).
        let poff = settings.snapshot().makeEnvScrunchParams(
            modelToWorld: matrix_identity_float4x4,
            viewerWorld: .zero,
            gridOrigin: gridOrigin, gridCell: gridCell, gridAddress: 0,
            surfaceMinWorld: SIMD3(-1, -1, -1), surfaceMaxWorld: SIMD3(1, 1, 1),
            farClampMeters: EnvironmentSDFGrid.clampFar)
        #expect(poff.enabled == 0)
    }
}
