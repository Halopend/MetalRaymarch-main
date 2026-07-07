//
//  FractalDistanceCache.swift
//  Threshold
//
//  Data side of the fractal distance cache (conservative distance-field grid):
//  the fractal's OWN DE baked on the GPU into a DIST_CACHE_DIM³ half-float
//  grid of provably conservative lower bounds, in MODEL space. While a march
//  sample's cached bound is above the near band the ray steps by the bound
//  without evaluating the analytic DE — attacking the ALU-bound profile by
//  trading iteration-loop math for one buffer read in empty space.
//
//  Correctness contract (mirrors the coarse-prepass conservativeness rule):
//    • Bake and render are encoded in the SAME command buffer, bake first, and
//      only when a DE-shaping parameter changed — the grid is never stale.
//    • MODEL space ⇒ camera motion and detail-scale zoom never invalidate it.
//    • `isEligible` gates the whole feature to fractal types whose DE is a
//      true Lipschitz-≤1 lower bound (box-fold family) and to frames without
//      camera-dependent DE terms (safety bubble / hands / env scrunch) or
//      distance-LOD, which the bake deliberately excludes.
//
//  Prototype scope: Mac fragment path, opt-in via THRESHOLD_DIST_CACHE=1.
//

import Foundation
import Metal
import simd

final class FractalDistanceCache {
    static let dim = Int(DIST_CACHE_DIM)
    /// Grid half-extent in model units. The march runs in model space where the
    /// supported fractal types live within a few units of the origin; samples
    /// outside the grid read 0 and fall back to the analytic DE, so a too-small
    /// extent only costs speed, never correctness.
    static let halfExtentModel: Float = 6.0
    /// Cached bounds at or below this fall back to the analytic DE. Two cells:
    /// comfortably above both the march hit threshold anywhere inside the grid
    /// and the slack subtracted at bake time.
    static let nearBandModel: Float = 2.0 * (2.0 * halfExtentModel) / Float(DIST_CACHE_DIM)

    let buffer: MTLBuffer
    private let pipeline: MTLComputePipelineState
    /// THRESHOLD_DIST_CACHE_DEBUG=1: after each bake, run the GPU validation
    /// kernel (probes points inside every nonzero voxel and counts stored
    /// bounds that exceed the analytic DE there) and log the result.
    private static let debugValidate =
        ProcessInfo.processInfo.environment["THRESHOLD_DIST_CACHE_DEBUG"] == "1"
    private var validatePipeline: MTLComputePipelineState?
    private var validateOut: MTLBuffer?
    /// Hash of the DE-shaping parameters the current grid contents were baked
    /// from. nil = never baked (grid contents are garbage → keep disabled).
    private var bakedKey: Int?

    init?(device: MTLDevice) {
        let count = Self.dim * Self.dim * Self.dim
        guard let library = device.makeDefaultLibrary(),
              let fn = library.makeFunction(name: "distanceCacheBake"),
              let pso = try? device.makeComputePipelineState(function: fn),
              let buf = device.makeBuffer(length: count * MemoryLayout<Float16>.stride,
                                          options: .storageModePrivate) else { return nil }
        buf.label = "FractalDistanceCache grid"
        self.buffer = buf
        self.pipeline = pso
    }

    /// The shader-side params for this grid. `enabled` is the caller's overall
    /// eligibility AND-ed with having a valid bake for the current key.
    func makeParams(enabled: Bool) -> DistanceCacheParams {
        let cell = (2.0 * Self.halfExtentModel) / Float(Self.dim)
        return DistanceCacheParams(
            enabled: enabled ? 1 : 0,
            nearBandModel: Self.nearBandModel,
            gridAddress: buffer.gpuAddress,
            originModel: SIMD3<Float>(repeating: -Self.halfExtentModel),
            invCellModel: SIMD3<Float>(repeating: 1.0 / cell))
    }

    /// Encodes the bake dispatch if `key` differs from what the grid holds.
    /// `uniformBuffer` is the frame's own uniforms buffer (the kernel reads the
    /// DE params and grid geometry from it), so bake and march can't drift.
    func encodeBakeIfNeeded(commandBuffer: MTLCommandBuffer, uniformBuffer: MTLBuffer, key: Int) {
        guard bakedKey != key else { return }
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.label = "FractalDistanceCache bake"
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(buffer, offset: 0, index: 0)
        encoder.setBuffer(uniformBuffer, offset: 0, index: BufferIndex.uniforms.rawValue)
        let threads = MTLSize(width: Self.dim, height: Self.dim, depth: Self.dim)
        let group = MTLSize(width: 8, height: 8, depth: 4)
        encoder.dispatchThreads(threads, threadsPerThreadgroup: group)
        encoder.endEncoding()
        bakedKey = key

        if Self.debugValidate {
            encodeValidation(commandBuffer: commandBuffer, uniformBuffer: uniformBuffer)
        }
    }

    private func encodeValidation(commandBuffer: MTLCommandBuffer, uniformBuffer: MTLBuffer) {
        let device = buffer.device
        if validatePipeline == nil,
           let library = device.makeDefaultLibrary(),
           let fn = library.makeFunction(name: "distanceCacheValidate") {
            validatePipeline = try? device.makeComputePipelineState(function: fn)
            validateOut = device.makeBuffer(length: MemoryLayout<UInt32>.stride * 3,
                                            options: .storageModeShared)
        }
        guard let pso = validatePipeline, let out = validateOut,
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        memset(out.contents(), 0, MemoryLayout<UInt32>.stride * 3)
        encoder.label = "FractalDistanceCache validate"
        encoder.setComputePipelineState(pso)
        encoder.setBuffer(buffer, offset: 0, index: 0)
        encoder.setBuffer(out, offset: 0, index: 1)
        encoder.setBuffer(uniformBuffer, offset: 0, index: BufferIndex.uniforms.rawValue)
        encoder.dispatchThreads(MTLSize(width: Self.dim, height: Self.dim, depth: Self.dim),
                                threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 4))
        encoder.endEncoding()
        commandBuffer.addCompletedHandler { _ in
            let p = out.contents().bindMemory(to: UInt32.self, capacity: 3)
            let maxExcess = Float(bitPattern: p[1])
            print("🧪 [distCache] validate: violations=\(p[0]) maxExcess=\(maxExcess) nonzeroVoxels=\(p[2])")
        }
    }

    /// Feature gate: only fractal types whose DE is a true lower bound with
    /// local Lipschitz constant ≤ 1 (the box-fold family — the same set that
    /// tolerates relaxedOmegaCap 1.6). Log-DE and fudge-factored estimators
    /// can locally OVERESTIMATE, which would break the baked bound.
    private static let eligibleTypes: Set<FractalModelType> = [
        .mandelbox, .menger, .octahedron, .mengerSphere,
    ]

    /// Whether the cache may run for this frame's settings. Everything the
    /// bake excludes must be off, and distance-LOD must be off (the march's
    /// reduced-iteration DE can dip below the full-iteration baked bound).
    static func isEligible(settings: RenderSettingsSnapshot) -> Bool {
        eligibleTypes.contains(settings.fractalType)
            && !settings.safetyBubbleEnabled
            && !settings.envScrunchEnabled
            && settings.distanceLODStrength <= 0
    }

    /// Hash of every parameter that shapes the DE the bake evaluates. Any
    /// change ⇒ rebake (encoded before the render pass, so never stale).
    static func bakeKey(settings: RenderSettingsSnapshot) -> Int {
        var hasher = Hasher()
        hasher.combine(settings.fractalType.rawValue)
        hasher.combine(settings.fractalScale)
        hasher.combine(settings.minDistance)
        hasher.combine(settings.fractalIterations)
        hasher.combine(settings.foldingLimit)
        hasher.combine(settings.sphereRadius)
        hasher.combine(settings.sphereProjectionEnabled)
        hasher.combine(settings.sphereProjectionBlend)
        hasher.combine(settings.sphereProjectionRadius)
        hasher.combine(settings.spaceWarpStrength)
        hasher.combine(settings.spaceWarpParam1)
        hasher.combine(settings.spaceWarpParam2)
        hasher.combine(settings.spaceWarpParam3)
        hasher.combine(settings.spaceWarpAxis.x)
        hasher.combine(settings.spaceWarpAxis.y)
        hasher.combine(settings.spaceWarpAxis.z)
        var stack = settings.spaceWarpStack
        withUnsafeBytes(of: &stack) { hasher.combine(bytes: $0) }
        var formula = settings.formulaParams
        withUnsafeBytes(of: &formula) { hasher.combine(bytes: $0) }
        return hasher.finalize()
    }
}
