//
//  FractalDistanceCache.swift
//  Threshold
//
//  Data side of the fractal distance seed cache (conservative distance-field
//  grids): each exact DE parameter state owns a compact DIST_CACHE_DIM³
//  8-bit fixed-point seed of conservative lower bounds in MODEL space.
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
//    • `isEligible` gates the feature to a stable Mandelbox with no
//      distance-reducing hand field, environment deformation, or distance-LOD.
//      Safety-bubble subtraction is compatible because it only increases DE.
//
//  Prototype scope: Mac fragment path, opt-in via THRESHOLD_DIST_CACHE=1.
//

import Foundation
@preconcurrency import Metal
import simd

final class FractalDistanceCache {
    static let dim = Int(DIST_CACHE_DIM)
    /// Animation tier: one complete seed can be baked in the frame where an
    /// exact parameter key is first encountered. The environment override is
    /// intentionally benchmark-facing until the quality/performance sweep
    /// establishes the production resolution.
    static let animationDim: Int = {
        let raw = ProcessInfo.processInfo.environment[
            "THRESHOLD_DIST_CACHE_ANIMATION_DIM"
        ].flatMap(Int.init) ?? 32
        return min(max(raw, 16), dim)
    }()

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
        let gridDimension: Int32
        let gridExtentBits: UInt32
        let gridCenterXBits: UInt32
        let gridCenterYBits: UInt32
        let gridCenterZBits: UInt32

        init(settings: RenderSettingsSnapshot, gridDimension: Int) {
            minDistanceBits = settings.minDistance.bitPattern
            fractalScaleBits = settings.fractalScale.bitPattern
            fractalIterations = Int32(clamping: settings.fractalIterations)
            foldingLimitBits = settings.foldingLimit.bitPattern
            sphereRadiusBits = settings.sphereRadius.bitPattern
            sphereProjectionEnabled = settings.sphereProjectionEnabled
            // Projection is currently ineligible. Canonicalize its dormant
            // controls so editing them while the toggle is off cannot fragment
            // the exact atlas key space.
            sphereProjectionBlendBits = settings.sphereProjectionEnabled
                ? settings.sphereProjectionBlend.bitPattern : 0
            sphereProjectionRadiusBits = settings.sphereProjectionEnabled
                ? settings.sphereProjectionRadius.bitPattern : 0
            deIterationMismatchBits = settings.deIterationMismatch.bitPattern
            self.gridDimension = Int32(clamping: gridDimension)
            gridExtentBits = FractalDistanceCache.halfExtentModel.bitPattern
            gridCenterXBits = FractalDistanceCache.pageCenterXModel.bitPattern
            gridCenterYBits = FractalDistanceCache.pageCenterYModel.bitPattern
            gridCenterZBits = FractalDistanceCache.pageCenterZModel.bitPattern
        }

        fileprivate var label: String {
            "m\(String(minDistanceBits, radix: 16))"
                + "-s\(String(fractalScaleBits, radix: 16))"
                + "-f\(String(foldingLimitBits, radix: 16))"
                + "-r\(String(sphereRadiusBits, radix: 16))"
                + "-i\(fractalIterations)"
                + "-p\(sphereProjectionEnabled ? 1 : 0)"
                + "-b\(String(sphereProjectionBlendBits, radix: 16))"
                + "-q\(String(sphereProjectionRadiusBits, radix: 16))"
                + "-d\(String(deIterationMismatchBits, radix: 16))"
                + "-g\(gridDimension)"
                + "-e\(String(gridExtentBits, radix: 16))"
                + "-x\(String(gridCenterXBits, radix: 16))"
                + "-y\(String(gridCenterYBits, radix: 16))"
                + "-z\(String(gridCenterZBits, radix: 16))"
        }

        fileprivate var fileName: String {
            func hex(_ value: UInt32) -> String {
                String(format: "%08x", value)
            }
            return "mb"
                + "-m\(hex(minDistanceBits))"
                + "-s\(hex(fractalScaleBits))"
                + "-i\(fractalIterations)"
                + "-f\(hex(foldingLimitBits))"
                + "-r\(hex(sphereRadiusBits))"
                + "-p\(sphereProjectionEnabled ? 1 : 0)"
                + "-b\(hex(sphereProjectionBlendBits))"
                + "-q\(hex(sphereProjectionRadiusBits))"
                + "-d\(hex(deIterationMismatchBits))"
                + "-g\(gridDimension)"
                + "-e\(hex(gridExtentBits))"
                + "-x\(hex(gridCenterXBits))"
                + "-y\(hex(gridCenterYBits))"
                + "-z\(hex(gridCenterZBits))"
                + ".mbseed"
        }
    }

    /// Four slices of a 128³ seed per frame: 65,536 DE evaluations, spread over
    /// 32 frames instead of a single 2,097,152-evaluation refresh.
    private static let bakeDepthPerFrame = 4
    /// Shared budget permits a bounded active parameter region while the full
    /// atlas remains disk-backed. Override in MiB for resolution sweeps.
    private static let residentByteBudget: Int = {
        let megabytes = ProcessInfo.processInfo.environment[
            "THRESHOLD_DIST_CACHE_RESIDENT_MB"
        ].flatMap(Int.init) ?? 96
        return min(max(megabytes, 16), 2048) * 1024 * 1024
    }()
    private static func seedByteCount(for dimension: Int) -> Int {
        dimension * dimension * dimension * MemoryLayout<UInt8>.stride
    }
    /// Do not spend GPU work on parameter states that only exist for one frame
    /// while a control, animation, or audio mapping is moving.
    private static let stableFramesBeforeBake = 2

    /// Versioned, bounded backing store for exact canonical Mandelbox seeds.
    /// Disk reads/writes and directory scans stay on `ioQueue`; the render
    /// thread only polls a small locked result map.
    private final class DiskAtlasStore: @unchecked Sendable {
        enum Lookup {
            case loading
            case hit(Data)
            case missing
        }

        private enum LoadResult {
            case hit(Data)
            case missing
        }

        // v1 admitted native per-fold sphere projection. v2 used insufficient
        // voxel slack. v3 stored fp16 bounds; v4 uses conservative uint8 fixed
        // point for a smaller, more cache-local hot-path representation.
        private static let formatVersion = "v13"
        private static let byteBudget: Int64 = 4 * 1024 * 1024 * 1024

        private let rootURL: URL
        private let directoryURL: URL
        private let ioQueue = DispatchQueue(
            label: "com.threshold.mandelbox-atlas",
            qos: .utility)
        private let lock = NSLock()
        private var pendingLoads: Set<AtlasKey> = []
        private var completedLoads: [AtlasKey: LoadResult] = [:]
        private var knownMissing: Set<AtlasKey> = []
        private var writesSincePrune = 0

        init?() {
            let root: URL
            if let override = ProcessInfo.processInfo.environment[
                "THRESHOLD_MANDELBOX_ATLAS_DIR"
            ], !override.isEmpty {
                root = URL(fileURLWithPath: override, isDirectory: true)
            } else {
                guard let base = try? FileManager.default.url(
                    for: .cachesDirectory,
                    in: .userDomainMask,
                    appropriateFor: nil,
                    create: true
                ) else { return nil }
                root = base.appendingPathComponent(
                    "ThresholdMandelboxAtlas",
                    isDirectory: true)
            }
            let build = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "0"
            let namespace = "\(Self.formatVersion)-\(Self.sanitize(build))"
            let directory = root.appendingPathComponent(namespace, isDirectory: true)

            do {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true)
            } catch {
                return nil
            }

            rootURL = root
            directoryURL = directory

            ioQueue.async { [self] in
                pruneStaleNamespaces()
                pruneToBudget()
            }
        }

        func lookup(_ key: AtlasKey) -> Lookup {
            lock.lock()
            if let result = completedLoads.removeValue(forKey: key) {
                lock.unlock()
                switch result {
                case .hit(let data): return .hit(data)
                case .missing: return .missing
                }
            }
            if knownMissing.contains(key) {
                lock.unlock()
                return .missing
            }
            if pendingLoads.contains(key) {
                lock.unlock()
                return .loading
            }
            pendingLoads.insert(key)
            lock.unlock()

            let url = fileURL(for: key)
            ioQueue.async { [self] in
                let data = try? Data(contentsOf: url, options: .mappedIfSafe)
                let result: LoadResult
                let expectedBytes = FractalDistanceCache.seedByteCount(
                    for: Int(key.gridDimension))
                if let data, data.count == expectedBytes {
                    result = .hit(data)
                    try? FileManager.default.setAttributes(
                        [.modificationDate: Date()],
                        ofItemAtPath: url.path)
                    if FractalDistanceCache.logEvents {
                        print("[MandelboxAtlas] disk hit \(key.label)")
                    }
                } else {
                    result = .missing
                    if data != nil {
                        try? FileManager.default.removeItem(at: url)
                    }
                    if FractalDistanceCache.logEvents {
                        print("[MandelboxAtlas] disk miss \(key.label)")
                    }
                }

                lock.lock()
                pendingLoads.remove(key)
                completedLoads[key] = result
                if case .missing = result {
                    knownMissing.insert(key)
                }
                lock.unlock()
            }
            return .loading
        }

        /// Compact animation seeds are only 32 KiB, so a mapped synchronous
        /// read is cheaper than missing the exact key for an entire animation
        /// loop while the serial IO queue catches up. The returned bytes still
        /// upload through the frame command buffer before becoming renderable.
        func loadCompactImmediately(_ key: AtlasKey) -> Data? {
            guard key.gridDimension == Int32(FractalDistanceCache.animationDim) else {
                return nil
            }
            let url = fileURL(for: key)
            let expectedBytes = FractalDistanceCache.seedByteCount(
                for: Int(key.gridDimension))
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  data.count == expectedBytes else {
                return nil
            }
            if FractalDistanceCache.logEvents {
                print("[MandelboxAtlas] disk hit \(key.label)")
            }
            ioQueue.async {
                try? FileManager.default.setAttributes(
                    [.modificationDate: Date()],
                    ofItemAtPath: url.path)
            }
            return data
        }

        func persist(_ data: Data, for key: AtlasKey) {
            guard data.count == FractalDistanceCache.seedByteCount(
                for: Int(key.gridDimension)) else { return }
            let url = fileURL(for: key)
            ioQueue.async { [self] in
                do {
                    try data.write(to: url, options: .atomic)
                    if FractalDistanceCache.logEvents {
                        print("[MandelboxAtlas] persisted \(key.label)")
                    }
                    lock.lock()
                    knownMissing.remove(key)
                    lock.unlock()

                    writesSincePrune += 1
                    if writesSincePrune >= 64 {
                        writesSincePrune = 0
                        pruneToBudget()
                    }
                } catch {
                    // The atlas is strictly additive. A failed write leaves the
                    // complete resident seed usable and simply misses next launch.
                }
            }
        }

        private func fileURL(for key: AtlasKey) -> URL {
            directoryURL.appendingPathComponent(key.fileName)
        }

        private func pruneStaleNamespaces() {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: .skipsHiddenFiles
            ) else { return }

            for entry in entries
            where entry.standardizedFileURL != directoryURL.standardizedFileURL {
                try? FileManager.default.removeItem(at: entry)
            }
        }

        private func pruneToBudget() {
            let keys: Set<URLResourceKey> = [
                .fileSizeKey,
                .contentModificationDateKey,
            ]
            guard let urls = try? FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: Array(keys),
                options: .skipsHiddenFiles
            ) else { return }

            var entries: [(url: URL, bytes: Int64, date: Date)] = []
            var total: Int64 = 0
            for url in urls where url.pathExtension == "mbseed" {
                guard let values = try? url.resourceValues(forKeys: keys) else { continue }
                let bytes = Int64(values.fileSize ?? 0)
                total += bytes
                entries.append((
                    url: url,
                    bytes: bytes,
                    date: values.contentModificationDate ?? .distantPast))
            }

            guard total > Self.byteBudget else { return }
            entries.sort { $0.date < $1.date }
            for entry in entries where total > Self.byteBudget {
                if (try? FileManager.default.removeItem(at: entry.url)) != nil {
                    total -= entry.bytes
                }
            }
        }

        private static func sanitize(_ value: String) -> String {
            String(value.map { ($0.isLetter || $0.isNumber) ? $0 : "_" })
        }
    }

    /// Grid half-extent in model units. The march runs in model space where the
    /// supported fractal types live within a few units of the origin; samples
    /// outside the grid read 0 and fall back to the analytic DE, so a too-small
    /// extent only costs speed, never correctness.
    static let halfExtentModel: Float = {
        let raw = ProcessInfo.processInfo.environment[
            "THRESHOLD_DIST_CACHE_HALF_EXTENT"
        ].flatMap(Float.init) ?? 6.0
        return min(max(raw, 1.0), 32.0)
    }()
    /// Prototype spatial page center. Every axis is part of the exact disk key,
    /// so pages can follow the active approach corridor without aliasing.
    static let pageCenterXModel: Float = {
        let raw = ProcessInfo.processInfo.environment[
            "THRESHOLD_DIST_CACHE_CENTER_X"
        ].flatMap(Float.init) ?? 0.0
        return min(max(raw, -64.0), 64.0)
    }()
    static let pageCenterYModel: Float = {
        let raw = ProcessInfo.processInfo.environment[
            "THRESHOLD_DIST_CACHE_CENTER_Y"
        ].flatMap(Float.init) ?? 0.0
        return min(max(raw, -64.0), 64.0)
    }()
    static let pageCenterZModel: Float = {
        let raw = ProcessInfo.processInfo.environment[
            "THRESHOLD_DIST_CACHE_CENTER_Z"
        ].flatMap(Float.init) ?? 0.0
        return min(max(raw, -64.0), 64.0)
    }()
    /// The shader combines this floor with its per-ray hit threshold. A positive
    /// cached value is already a proven lower bound; forcing a wider fixed band
    /// defeats transformed seeds because their Jacobian divisor can shrink every
    /// valid bound below that band.
    static let nearBandModel: Float = {
        guard let raw = ProcessInfo.processInfo.environment[
            "THRESHOLD_DIST_CACHE_NEAR_BAND"
        ], let value = Float(raw) else { return 0.0 }
        return max(value, 0.0)
    }()

    /// Per-frame cache selection. Partial seeds carry a bake buffer but no
    /// render buffer; complete seeds carry a render buffer and need no bake.
    struct FrameState {
        fileprivate let key: AtlasKey
        fileprivate let bakeBuffer: MTLBuffer?
        fileprivate let uploadBuffer: MTLBuffer?
        let renderBuffer: MTLBuffer?
        let params: DistanceCacheParams
    }

    private final class Seed {
        let buffer: MTLBuffer
        let dimension: Int
        var nextBakeZ = 0
        var lastUse: UInt64 = 0
        var pendingUpload: MTLBuffer?
        var ready = false

        init(
            buffer: MTLBuffer,
            dimension: Int,
            pendingUpload: MTLBuffer? = nil
        ) {
            self.buffer = buffer
            self.dimension = dimension
            self.pendingUpload = pendingUpload
        }

        var isComplete: Bool {
            ready
        }
    }

    private let device: MTLDevice
    private let pipeline: MTLComputePipelineState
    private let diskAtlas: DiskAtlasStore?
    private var seeds: [AtlasKey: Seed] = [:]
    private var useSerial: UInt64 = 0
    private var candidateKey: AtlasKey?
    private var candidateFrameCount = 0

    /// THRESHOLD_DIST_CACHE_DEBUG=1: after each bake, run the GPU validation
    /// kernel (probes points inside every nonzero voxel and counts stored
    /// bounds that exceed the analytic DE there) and log the result.
    private static let debugValidate =
        ProcessInfo.processInfo.environment["THRESHOLD_DIST_CACHE_DEBUG"] == "1"
    private static let logEvents =
        ProcessInfo.processInfo.environment["THRESHOLD_DIST_CACHE_LOG"] == "1"
    private var validatePipeline: MTLComputePipelineState?
    private var validateOut: MTLBuffer?

    init?(device: MTLDevice) {
        let constants = MTLFunctionConstantValues()
        guard let library = device.makeDefaultLibrary(),
              let fn = try? library.makeFunction(
                name: "distanceCacheBake",
                constantValues: constants
              ),
              let pso = try? device.makeComputePipelineState(function: fn) else { return nil }
        self.device = device
        self.pipeline = pso
        self.diskAtlas = DiskAtlasStore()
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
                uploadBuffer: nil,
                renderBuffer: seed.buffer,
                params: makeParams(
                    buffer: seed.buffer,
                    dimension: seed.dimension,
                    enabled: true))
        }

        let previousCandidateFrameCount = candidateFrameCount
        if candidateKey == key {
            candidateFrameCount = min(candidateFrameCount + 1, Self.stableFramesBeforeBake)
        } else {
            candidateKey = key
            candidateFrameCount = 1
            if Self.logEvents {
                print("[MandelboxAtlas] candidate \(key.label)")
            }
        }
        if previousCandidateFrameCount < Self.stableFramesBeforeBake,
           candidateFrameCount >= Self.stableFramesBeforeBake,
           Self.logEvents {
            print("[MandelboxAtlas] stable \(key.label)")
        }

        let requiredStableFrames = key.gridDimension == Int32(Self.animationDim)
            ? 1
            : Self.stableFramesBeforeBake
        guard candidateFrameCount >= requiredStableFrames else {
            return FrameState(
                key: key,
                bakeBuffer: nil,
                uploadBuffer: nil,
                renderBuffer: nil,
                params: DistanceCacheParams())
        }

        let seed: Seed
        if let existing = seeds[key] {
            seed = existing
        } else {
            if key.gridDimension == Int32(Self.animationDim) {
                guard let data = diskAtlas?.loadCompactImmediately(key),
                      let loaded = makeSeedForUpload(data: data, key: key) else {
                    return makeNewBakeSeedFrame(key: key)
                }
                seed = loaded
            } else {
                switch diskAtlas?.lookup(key) {
                case .loading:
                    return FrameState(
                        key: key,
                        bakeBuffer: nil,
                        uploadBuffer: nil,
                        renderBuffer: nil,
                        params: DistanceCacheParams())
                case .hit(let data):
                    guard let loaded = makeSeedForUpload(data: data, key: key) else {
                        return makeNewBakeSeedFrame(key: key)
                    }
                    seed = loaded
                case .missing, .none:
                    return makeNewBakeSeedFrame(key: key)
                }
            }
            seeds[key] = seed
            evictSeedsIfNeeded(protecting: key)
        }

        seed.lastUse = useSerial
        return FrameState(
            key: key,
            bakeBuffer: seed.buffer,
            uploadBuffer: seed.pendingUpload,
            renderBuffer: nil,
            params: makeParams(
                buffer: seed.buffer,
                dimension: seed.dimension,
                enabled: false))
    }

    private func makeNewBakeSeedFrame(key: AtlasKey) -> FrameState {
        let dimension = Int(key.gridDimension)
        let byteCount = Self.seedByteCount(for: dimension)
        guard let buffer = device.makeBuffer(
            length: byteCount,
            options: .storageModePrivate
        ) else {
            return FrameState(
                key: key,
                bakeBuffer: nil,
                uploadBuffer: nil,
                renderBuffer: nil,
                params: DistanceCacheParams())
        }
        buffer.label = "MandelboxDistanceAtlas \(key.label)"
        let seed = Seed(buffer: buffer, dimension: dimension)
        seed.lastUse = useSerial
        seeds[key] = seed
        evictSeedsIfNeeded(protecting: key)
        return FrameState(
            key: key,
            bakeBuffer: buffer,
            uploadBuffer: nil,
            renderBuffer: nil,
            params: makeParams(
                buffer: buffer,
                dimension: dimension,
                enabled: false))
    }

    private func makeSeedForUpload(data: Data, key: AtlasKey) -> Seed? {
        let dimension = Int(key.gridDimension)
        let byteCount = Self.seedByteCount(for: dimension)
        guard data.count == byteCount,
              let destination = device.makeBuffer(
                length: byteCount,
                options: .storageModePrivate
              ) else { return nil }
        let staging = data.withUnsafeBytes { bytes -> MTLBuffer? in
            guard let base = bytes.baseAddress else { return nil }
            return device.makeBuffer(
                bytes: base,
                length: byteCount,
                options: .storageModeShared)
        }
        guard let staging else { return nil }
        destination.label = "MandelboxDistanceAtlas disk upload"
        staging.label = "MandelboxDistanceAtlas upload staging"
        let seed = Seed(
            buffer: destination,
            dimension: dimension,
            pendingUpload: staging)
        seed.nextBakeZ = dimension
        return seed
    }

    private func makeParams(
        buffer: MTLBuffer,
        dimension: Int,
        enabled: Bool
    ) -> DistanceCacheParams {
        let cell = (2.0 * Self.halfExtentModel) / Float(dimension)
        return DistanceCacheParams(
            enabled: enabled ? 1 : 0,
            nearBandModel: Self.nearBandModel,
            gridAddress: buffer.gpuAddress,
            originModel: SIMD4<Float>(
                Self.pageCenterXModel - Self.halfExtentModel,
                Self.pageCenterYModel - Self.halfExtentModel,
                Self.pageCenterZModel - Self.halfExtentModel,
                Float(dimension)),
            invCellModel: SIMD3<Float>(repeating: 1.0 / cell))
    }

    /// Uploads a disk hit or encodes at most one Z slab for a new seed. The seed
    /// stays disabled for this frame; it becomes visible on the next frame after
    /// command-queue ordering guarantees the complete write precedes the read.
    func encodePreparationIfNeeded(
        commandBuffer: MTLCommandBuffer,
        uniformBuffer: MTLBuffer,
        frame: FrameState
    ) {
        guard let expectedBuffer = frame.bakeBuffer,
              let seed = seeds[frame.key],
              seed.buffer === expectedBuffer,
              !seed.isComplete else { return }

        if let upload = frame.uploadBuffer,
           let pendingUpload = seed.pendingUpload,
           upload === pendingUpload,
           let encoder = commandBuffer.makeBlitCommandEncoder() {
            encoder.label = "MandelboxDistanceAtlas upload"
            encoder.copy(
                from: upload,
                sourceOffset: 0,
                to: seed.buffer,
                destinationOffset: 0,
                size: Self.seedByteCount(for: seed.dimension))
            encoder.endEncoding()
            seed.pendingUpload = nil
            seed.ready = true
            if Self.logEvents {
                print("[MandelboxAtlas] uploaded \(frame.key.label)")
            }
            if Self.debugValidate {
                encodeValidation(
                    commandBuffer: commandBuffer,
                    uniformBuffer: uniformBuffer,
                    grid: seed.buffer,
                    dimension: seed.dimension)
            }
            return
        }

        guard seed.pendingUpload == nil else { return }
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }

        let startZ = seed.nextBakeZ
        let depthPerFrame = seed.dimension == Self.animationDim
            ? seed.dimension
            : Self.bakeDepthPerFrame
        let depth = min(depthPerFrame, seed.dimension - startZ)
        var zOffset = UInt32(startZ)

        encoder.label = "FractalDistanceSeed bake \(startZ)..<\(startZ + depth)"
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(seed.buffer, offset: 0, index: 0)
        encoder.setBuffer(uniformBuffer, offset: 0, index: BufferIndex.uniforms.rawValue)
        // Keep this kernel-private scalar away from the shared BufferIndex
        // namespace used by the render and compute pipelines.
        encoder.setBytes(&zOffset, length: MemoryLayout<UInt32>.stride, index: 30)
        let threads = MTLSize(
            width: seed.dimension,
            height: seed.dimension,
            depth: depth)
        let group = MTLSize(width: 8, height: 8, depth: 4)
        encoder.dispatchThreads(threads, threadsPerThreadgroup: group)
        encoder.endEncoding()
        seed.nextBakeZ += depth

        if seed.nextBakeZ >= seed.dimension {
            seed.ready = true
            if Self.logEvents {
                print("[MandelboxAtlas] baked \(frame.key.label)")
            }
            if Self.debugValidate {
                encodeValidation(
                    commandBuffer: commandBuffer,
                    uniformBuffer: uniformBuffer,
                    grid: seed.buffer,
                    dimension: seed.dimension)
            }
            encodePersistenceReadback(
                commandBuffer: commandBuffer,
                key: frame.key,
                grid: seed.buffer)
        }
    }

    private func encodePersistenceReadback(
        commandBuffer: MTLCommandBuffer,
        key: AtlasKey,
        grid: MTLBuffer
    ) {
        guard let diskAtlas,
              let seed = seeds[key],
              seed.buffer === grid,
              let byteCount = Optional(
                Self.seedByteCount(for: seed.dimension)),
              let readback = device.makeBuffer(
                length: byteCount,
                options: .storageModeShared),
              let encoder = commandBuffer.makeBlitCommandEncoder() else { return }
        readback.label = "MandelboxDistanceAtlas readback"
        encoder.label = "MandelboxDistanceAtlas persist"
        encoder.copy(
            from: grid,
            sourceOffset: 0,
            to: readback,
            destinationOffset: 0,
            size: byteCount)
        encoder.endEncoding()

        commandBuffer.addCompletedHandler { completed in
            guard completed.status == .completed else { return }
            let data = Data(
                bytes: readback.contents(),
                count: byteCount)
            diskAtlas.persist(data, for: key)
        }
    }

    private func evictSeedsIfNeeded(protecting protectedKey: AtlasKey) {
        while seeds.values.reduce(0, { $0 + $1.buffer.length })
            > Self.residentByteBudget {
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
        grid: MTLBuffer,
        dimension: Int
    ) {
        let constants = MTLFunctionConstantValues()
        if validatePipeline == nil,
           let library = device.makeDefaultLibrary(),
           let fn = try? library.makeFunction(
            name: "distanceCacheValidate",
            constantValues: constants
           ) {
            validatePipeline = try? device.makeComputePipelineState(function: fn)
            validateOut = device.makeBuffer(length: MemoryLayout<UInt32>.stride * 5,
                                            options: .storageModeShared)
        }
        guard let pso = validatePipeline, let out = validateOut,
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        memset(out.contents(), 0, MemoryLayout<UInt32>.stride * 5)
        encoder.label = "FractalDistanceCache validate"
        encoder.setComputePipelineState(pso)
        encoder.setBuffer(grid, offset: 0, index: 0)
        encoder.setBuffer(out, offset: 0, index: 1)
        encoder.setBuffer(uniformBuffer, offset: 0, index: BufferIndex.uniforms.rawValue)
        encoder.dispatchThreads(MTLSize(
                                    width: dimension,
                                    height: dimension,
                                    depth: dimension),
                                threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 4))
        encoder.endEncoding()
        commandBuffer.addCompletedHandler { _ in
            let p = out.contents().bindMemory(to: UInt32.self, capacity: 5)
            let canonicalMaxExcess = Float(bitPattern: p[1])
            let transformedMaxExcess = Float(bitPattern: p[4])
            print(
                "🧪 [distCache] validate: canonicalViolations=\(p[0]) " +
                "canonicalMaxExcess=\(canonicalMaxExcess) nonzeroVoxels=\(p[2]) " +
                "transformedViolations=\(p[3]) transformedMaxExcess=\(transformedMaxExcess)"
            )
        }
    }

    /// Whether the canonical Mandelbox atlas may run for this frame. The safety
    /// bubble is eligible because its subtraction only increases the base DE.
    /// Native per-fold sphere projection, distance-reducing hand fields, and
    /// environment deformation, and scene-level unions remain ineligible.
    /// Domain transforms are applied to the atlas lookup point and do not shape
    /// the stored seed.
    static func isEligible(
        settings: RenderSettingsSnapshot,
        handFieldActive: Bool = false
    ) -> Bool {
        settings.fractalType == .mandelbox
            && settings.geometryState == .stable
            && !settings.isGeometryGestureActive
            && !settings.sphereProjectionEnabled
            && !handFieldActive
            && !settings.envScrunchEnabled
            && settings.scenePrimitives.isEmpty
            && settings.distanceLODStrength <= 0
    }

    /// Exact intrinsic coordinate of the canonical Mandelbox. Transform changes
    /// intentionally return the same key and reuse the same seed.
    static func bakeKey(
        settings: RenderSettingsSnapshot,
        compact: Bool = false
    ) -> AtlasKey {
        AtlasKey(
            settings: settings,
            gridDimension: compact ? animationDim : dim)
    }
}
