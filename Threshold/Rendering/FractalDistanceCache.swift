//
//  FractalDistanceCache.swift
//  Threshold
//
//  Data side of the fractal distance seed cache (conservative distance-field
//  grids): each exact DE parameter state owns a compact DIST_CACHE_DIM³
//  half-float seed of provably conservative lower bounds in MODEL space.
//  While a march sample's cached bound is above the near band the ray steps by
//  the bound without evaluating the analytic DE — attacking the ALU-bound
//  profile by trading iteration-loop math for one buffer read in empty space.
//
//  Correctness contract (mirrors the coarse-prepass conservativeness rule):
//    • A seed is keyed by every DE-shaping parameter and is never exposed to
//      the renderer until every slice has been baked.
//    • Partial seeds are built incrementally across frames. A changing key is
//      debounced, so parameter gestures never trigger a full-volume refresh.
//    • MODEL space ⇒ camera motion and detail-scale zoom never invalidate it.
//    • `isEligible` gates the whole feature to fractal types whose DE is a
//      true Lipschitz-≤1 lower bound (box-fold family) and to frames without
//      camera-dependent DE terms (safety bubble / hands / env scrunch) or
//      distance-LOD, which the bake deliberately excludes.
//
//  Prototype scope: Mac fragment path, opt-in via THRESHOLD_DIST_CACHE=1.
//

import Foundation
@preconcurrency import Metal
import simd

final class FractalDistanceCache {
    static let dim = Int(DIST_CACHE_DIM)

    /// Exact coordinate of one canonical Mandelbox seed in the parameter atlas.
    ///
    /// Only parameters evaluated INSIDE `Map` belong here. Model transforms and
    /// the composable domain-transform stack are deliberately absent: the shader
    /// applies those to the lookup point after selecting this canonical seed.
    /// Float bit patterns keep equality exact and collision-safe (Dictionary may
    /// hash this value, but equality still compares every field).
    struct AtlasKey: Hashable, Sendable {
        let minDistanceBits: UInt32
        let fractalScaleBits: UInt32
        let fractalIterations: Int32
        let foldingLimitBits: UInt32
        let sphereRadiusBits: UInt32
        let sphereProjectionEnabled: Bool
        let sphereProjectionBlendBits: UInt32
        let sphereProjectionRadiusBits: UInt32
        let deIterationMismatchBits: UInt32

        init(settings: RenderSettingsSnapshot) {
            minDistanceBits = settings.minDistance.bitPattern
            fractalScaleBits = settings.fractalScale.bitPattern
            fractalIterations = Int32(clamping: settings.fractalIterations)
            foldingLimitBits = settings.foldingLimit.bitPattern
            sphereRadiusBits = settings.sphereRadius.bitPattern
            sphereProjectionEnabled = settings.sphereProjectionEnabled
            sphereProjectionBlendBits = settings.sphereProjectionBlend.bitPattern
            sphereProjectionRadiusBits = settings.sphereProjectionRadius.bitPattern
            deIterationMismatchBits = settings.deIterationMismatch.bitPattern
        }

        fileprivate var label: String {
            "s\(String(fractalScaleBits, radix: 16))"
                + "-f\(String(foldingLimitBits, radix: 16))"
                + "-r\(String(sphereRadiusBits, radix: 16))"
                + "-i\(fractalIterations)"
        }
    }

    /// One eighth of a 64³ seed per frame: 32,768 DE evaluations instead of
    /// the previous 262,144-evaluation single-frame refresh.
    private static let bakeDepthPerFrame = 8
    /// 12 × 64³ × fp16 = 6 MiB of resident seed data.
    private static let residentSeedLimit = 12
    /// Do not spend GPU work on parameter states that only exist for one frame
    /// while a control, animation, or audio mapping is moving.
    private static let stableFramesBeforeBake = 2

    /// Grid half-extent in model units. The march runs in model space where the
    /// supported fractal types live within a few units of the origin; samples
    /// outside the grid read 0 and fall back to the analytic DE, so a too-small
    /// extent only costs speed, never correctness.
    static let halfExtentModel: Float = 6.0
    /// Cached bounds at or below this fall back to the analytic DE. Two cells:
    /// comfortably above both the march hit threshold anywhere inside the grid
    /// and the slack subtracted at bake time.
    static let nearBandModel: Float = 2.0 * (2.0 * halfExtentModel) / Float(DIST_CACHE_DIM)

    /// Per-frame cache selection. Partial seeds carry a bake buffer but no
    /// render buffer; complete seeds carry a render buffer and need no bake.
    struct FrameState {
        fileprivate let key: AtlasKey
        fileprivate let bakeBuffer: MTLBuffer?
        let renderBuffer: MTLBuffer?
        let params: DistanceCacheParams
    }

    private final class Seed {
        let buffer: MTLBuffer
        var nextBakeZ = 0
        var lastUse: UInt64 = 0

        init(buffer: MTLBuffer) {
            self.buffer = buffer
        }

        var isComplete: Bool {
            nextBakeZ >= FractalDistanceCache.dim
        }
    }

    private let device: MTLDevice
    private let pipeline: MTLComputePipelineState
    private var seeds: [AtlasKey: Seed] = [:]
    private var useSerial: UInt64 = 0
    private var candidateKey: AtlasKey?
    private var candidateFrameCount = 0

    /// THRESHOLD_DIST_CACHE_DEBUG=1: after each bake, run the GPU validation
    /// kernel (probes points inside every nonzero voxel and counts stored
    /// bounds that exceed the analytic DE there) and log the result.
    private static let debugValidate =
        ProcessInfo.processInfo.environment["THRESHOLD_DIST_CACHE_DEBUG"] == "1"
    private var validatePipeline: MTLComputePipelineState?
    private var validateOut: MTLBuffer?

    init?(device: MTLDevice) {
        guard let library = device.makeDefaultLibrary(),
              let fn = library.makeFunction(name: "distanceCacheBake"),
              let pso = try? device.makeComputePipelineState(function: fn) else { return nil }
        self.device = device
        self.pipeline = pso
    }

    /// Selects or starts preparing the exact seed for `key`. Completed seeds
    /// are immediately reusable. A new/partial seed remains shader-disabled
    /// until all slices have been encoded.
    func prepareFrame(key: AtlasKey) -> FrameState {
        useSerial &+= 1

        if let seed = seeds[key], seed.isComplete {
            seed.lastUse = useSerial
            return FrameState(
                key: key,
                bakeBuffer: nil,
                renderBuffer: seed.buffer,
                params: makeParams(buffer: seed.buffer, enabled: true))
        }

        if candidateKey == key {
            candidateFrameCount = min(candidateFrameCount + 1, Self.stableFramesBeforeBake)
        } else {
            candidateKey = key
            candidateFrameCount = 1
        }

        guard candidateFrameCount >= Self.stableFramesBeforeBake else {
            return FrameState(
                key: key,
                bakeBuffer: nil,
                renderBuffer: nil,
                params: DistanceCacheParams())
        }

        let seed: Seed
        if let existing = seeds[key] {
            seed = existing
        } else {
            let count = Self.dim * Self.dim * Self.dim
            guard let buffer = device.makeBuffer(
                length: count * MemoryLayout<UInt16>.stride,
                options: .storageModePrivate
            ) else {
                return FrameState(
                    key: key,
                    bakeBuffer: nil,
                    renderBuffer: nil,
                    params: DistanceCacheParams())
            }
            buffer.label = "MandelboxDistanceAtlas \(key.label)"
            seed = Seed(buffer: buffer)
            seeds[key] = seed
            evictSeedsIfNeeded(protecting: key)
        }

        seed.lastUse = useSerial
        return FrameState(
            key: key,
            bakeBuffer: seed.buffer,
            renderBuffer: nil,
            params: makeParams(buffer: seed.buffer, enabled: false))
    }

    private func makeParams(buffer: MTLBuffer, enabled: Bool) -> DistanceCacheParams {
        let cell = (2.0 * Self.halfExtentModel) / Float(Self.dim)
        return DistanceCacheParams(
            enabled: enabled ? 1 : 0,
            nearBandModel: Self.nearBandModel,
            gridAddress: buffer.gpuAddress,
            originModel: SIMD3<Float>(repeating: -Self.halfExtentModel),
            invCellModel: SIMD3<Float>(repeating: 1.0 / cell))
    }

    /// Encodes at most one Z slab for the selected partial seed. The seed stays
    /// disabled for this frame even when this is its final slab; it becomes
    /// visible on the next frame, after command-queue ordering guarantees that
    /// the complete write precedes the fragment read.
    func encodeBakeSliceIfNeeded(
        commandBuffer: MTLCommandBuffer,
        uniformBuffer: MTLBuffer,
        frame: FrameState
    ) {
        guard let expectedBuffer = frame.bakeBuffer,
              let seed = seeds[frame.key],
              seed.buffer === expectedBuffer,
              !seed.isComplete else { return }
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }

        let startZ = seed.nextBakeZ
        let depth = min(Self.bakeDepthPerFrame, Self.dim - startZ)
        var zOffset = UInt32(startZ)

        encoder.label = "FractalDistanceSeed bake \(startZ)..<\(startZ + depth)"
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(seed.buffer, offset: 0, index: 0)
        encoder.setBuffer(uniformBuffer, offset: 0, index: BufferIndex.uniforms.rawValue)
        // Keep this kernel-private scalar away from the shared BufferIndex
        // namespace used by the render and compute pipelines.
        encoder.setBytes(&zOffset, length: MemoryLayout<UInt32>.stride, index: 30)
        let threads = MTLSize(width: Self.dim, height: Self.dim, depth: depth)
        let group = MTLSize(width: 8, height: 8, depth: 4)
        encoder.dispatchThreads(threads, threadsPerThreadgroup: group)
        encoder.endEncoding()
        seed.nextBakeZ += depth

        if seed.isComplete, Self.debugValidate {
            encodeValidation(
                commandBuffer: commandBuffer,
                uniformBuffer: uniformBuffer,
                grid: seed.buffer)
        }
    }

    private func evictSeedsIfNeeded(protecting protectedKey: AtlasKey) {
        while seeds.count > Self.residentSeedLimit {
            guard let victim = seeds
                .filter({ $0.key != protectedKey })
                .min(by: { lhs, rhs in
                    if lhs.value.isComplete != rhs.value.isComplete {
                        return !lhs.value.isComplete
                    }
                    return lhs.value.lastUse < rhs.value.lastUse
                })?.key else { return }
            seeds.removeValue(forKey: victim)
        }
    }

    private func encodeValidation(
        commandBuffer: MTLCommandBuffer,
        uniformBuffer: MTLBuffer,
        grid: MTLBuffer
    ) {
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
        encoder.setBuffer(grid, offset: 0, index: 0)
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

    /// Whether the canonical Mandelbox atlas may run for this frame. World-space
    /// CSG fields remain ineligible because they cannot be reconstructed from the
    /// base seed. Domain transforms ARE eligible: they are applied to the atlas
    /// lookup point in the shader and therefore do not shape the stored seed.
    static func isEligible(settings: RenderSettingsSnapshot) -> Bool {
        settings.fractalType == .mandelbox
            && !settings.safetyBubbleEnabled
            && !settings.handAttractionEnabled
            && !settings.envScrunchEnabled
            && settings.distanceLODStrength <= 0
    }

    /// Exact intrinsic coordinate of the canonical Mandelbox. Transform changes
    /// intentionally return the same key and reuse the same seed.
    static func bakeKey(settings: RenderSettingsSnapshot) -> AtlasKey {
        AtlasKey(settings: settings)
    }
}
