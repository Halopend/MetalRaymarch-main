//
//  PipelineBinaryArchive.swift
//  Threshold
//
//  Cross-launch cache for compiled GPU pipeline binaries (MTLBinaryArchive).
//
//  WHAT THIS FIXES
//  ---------------
//  Building an MTLComputePipelineState/MTLRenderPipelineState runs the Metal
//  *back-end* compiler: it lowers the function's AIR (the bytecode inside
//  `default.metallib`) to GPU machine code (ISA) for this specific device, with
//  this specific set of function constants baked in. That result lives only in
//  the process — at exit it is thrown away, so every cold launch pays the same
//  deterministic compile hitch on the perf-critical first frames, and re-pays it
//  for every function-constant permutation the user touches.
//
//  An `MTLBinaryArchive` is the supported way to persist that back-end result.
//  The flow has two halves, and BOTH are required:
//    1. Lookup — attach the archive to a pipeline descriptor *before* the
//       `makeComputePipelineState` call. If the archive already holds a binary
//       for that exact (function + constants) identity, Metal loads it instead
//       of recompiling.
//    2. Capture — after a successful build, add the descriptor's functions back
//       into the archive, then `serialize(to:)` it to disk so the *next* launch
//       can find them.
//
//  NOTE on the other half of "shader compilation": a binary archive does NOT
//  cache `device.makeLibrary(source:)` (the *front-end* compile of a runtime
//  `.threshfx` string → AIR). There is no `MTLLibrary.write(to:)` API; the only
//  way to persist a runtime-compiled library is `MTLDynamicLibrary.serialize`,
//  which requires restructuring the splice into linked visible-functions. So
//  this type covers the pipeline-state compile (built-ins + presets + the
//  custom path's PSO half), not the custom source compile. See
//  CACHE_AND_MEMORY_DESIGN.md §2.1/§2.2.
//
//  WHY IT IS SAFE
//  --------------
//  An archive miss is transparent: the make* helpers probe with
//  `.failOnBinaryArchiveMiss` ONLY to detect a hit (so a warm launch skips the
//  recompile and the re-serialize), and on a miss fall back to a normal compile
//  and capture the result. A missing, corrupt, stale, or wrong-GPU file therefore
//  simply recompiles as today — a regression is impossible; the cache can only
//  ever save work.
//
//  INVALIDATION
//  ------------
//  A serialized archive is specific to the GPU and the exact shader binaries it
//  was built from. The on-disk filename is keyed by `device.registryID` (per-GPU),
//  the OS version+build string, and the app's `CFBundleVersion` (which changes
//  whenever the bundled `default.metallib` is rebuilt). On a key change we prune
//  the stale same-purpose file, so a version bump costs exactly one cold compile
//  and then steady-state cache. Metal additionally validates archive
//  compatibility internally on load — the key only reduces rejection churn.
//
//  THREADING
//  ---------
//  Lazy pipeline builds run on concurrent `Task.detached` executors. The archive
//  is read *inside* `makeComputePipelineState` (the binary lookup) as well as
//  mutated by capture and `serialize`, so ALL THREE — build, capture, serialize —
//  are serialized under `lock` (see `makeComputePipeline`). A lock that guarded
//  only the writers would still leave the in-Metal read racing a concurrent
//  capture. `@unchecked Sendable` is sound for that reason. `serialize` is
//  blocking disk I/O and must be called off the render loop (a background task).
//

import Foundation
@preconcurrency import Metal
import os

final class PipelineBinaryArchive: @unchecked Sendable {
    private static let log = Logger(subsystem: "Threshold", category: "PipelineArchive")

    private let lock = NSLock()
    private let fileURL: URL
    private let archive: MTLBinaryArchive?
    private var dirty = false

    /// - Parameters:
    ///   - device: the Metal device whose pipelines are cached. Its `registryID`
    ///     scopes the on-disk key — a serialized archive is GPU-specific.
    ///   - purpose: short tag distinguishing archives (e.g. `"compute"`), so the
    ///     compute and render paths keep separate files under one directory.
    init?(device: MTLDevice, purpose: String) {
        guard let dir = Self.cacheDirectory() else { return nil }
        let key = Self.invalidationKey(device: device)
        let url = dir.appendingPathComponent("\(purpose)-\(key).metallib")
        self.fileURL = url

        // Drop stale archives for this purpose (different OS/app/GPU key) so a
        // version bump pays exactly one cold compile, then steady-state cache.
        Self.pruneStaleArchives(in: dir, purpose: purpose, keep: url)

        self.archive = Self.loadArchive(device: device, fileURL: url)
        if archive == nil {
            Self.log.debug("Pipeline archive unavailable; falling back to per-launch compile.")
        }
    }

    // MARK: - Pipeline integration

    /// Build a compute pipeline with this archive attached for binary lookup, then
    /// capture the freshly-built functions back into the archive — all under `lock`
    /// so the archive read performed *inside* `makeComputePipelineState` cannot
    /// race a concurrent capture/serialize on another build task. (Attaching and
    /// capturing as two separate unlocked calls left that in-Metal read
    /// unsynchronized, so the previous `attach`/`record` split was not actually
    /// race-free despite the lock around the write half.)
    ///
    /// Trade-off: concurrent builds serialize through this lock. That is fine for
    /// the sequential startup loop and the throttled, low-priority background build
    /// path, and it is the price of a race-free archive. When the on-disk archive
    /// failed to load (`archive == nil`) this degrades to a plain uncached build.
    func makeComputePipeline(device: MTLDevice,
                             descriptor: MTLComputePipelineDescriptor) throws -> MTLComputePipelineState {
        guard let archive else {
            return try device.makeComputePipelineState(descriptor: descriptor, options: [], reflection: nil)
        }
        lock.lock(); defer { lock.unlock() }
        descriptor.binaryArchives = [archive]
        // Hit: load the persisted binary — no recompile, and crucially no dirtying,
        // so a warm launch where everything is already archived performs no
        // needless re-serialize of identical content.
        if let cached = try? device.makeComputePipelineState(descriptor: descriptor,
                                                             options: .failOnBinaryArchiveMiss,
                                                             reflection: nil) {
            return cached
        }
        // Miss: compile, capture for the next launch, and mark dirty so the
        // coalesced serialize persists the genuinely-new binary.
        let pipeline = try device.makeComputePipelineState(descriptor: descriptor, options: [], reflection: nil)
        do {
            try archive.addComputePipelineFunctions(descriptor: descriptor)
            dirty = true
        } catch {
            Self.log.debug("addComputePipelineFunctions failed: \(error.localizedDescription, privacy: .public)")
        }
        return pipeline
    }

    /// Render-pipeline analogue of `makeComputePipeline`: build with the archive
    /// attached for binary lookup, then capture the freshly-built functions — all
    /// under `lock`, so the archive read inside `makeRenderPipelineState` cannot
    /// race a concurrent capture/serialize on another build task. When the on-disk
    /// archive failed to load (`archive == nil`) this degrades to a plain build.
    func makeRenderPipeline(device: MTLDevice,
                            descriptor: MTLRenderPipelineDescriptor) throws -> MTLRenderPipelineState {
        guard let archive else {
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        lock.lock(); defer { lock.unlock() }
        descriptor.binaryArchives = [archive]
        // Hit: load the persisted binary — no recompile, no dirtying (see
        // makeComputePipeline) so a warm launch doesn't re-serialize unchanged.
        if let cached = try? device.makeRenderPipelineState(descriptor: descriptor,
                                                            options: .failOnBinaryArchiveMiss,
                                                            reflection: nil) {
            return cached
        }
        // Miss: compile, capture for the next launch, and mark dirty.
        let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        do {
            try archive.addRenderPipelineFunctions(descriptor: descriptor)
            dirty = true
        } catch {
            Self.log.debug("addRenderPipelineFunctions failed: \(error.localizedDescription, privacy: .public)")
        }
        return pipeline
    }

    // MARK: - Persistence

    /// Write the archive to disk if anything new was added since the last write.
    /// Blocking disk I/O — call from a low-priority/background context, never the
    /// render loop.
    func serializeIfDirty() {
        lock.lock(); defer { lock.unlock() }
        guard dirty, let archive else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try archive.serialize(to: fileURL)
            dirty = false
            Self.log.debug("Serialized pipeline archive → \(self.fileURL.lastPathComponent, privacy: .public)")
        } catch {
            Self.log.debug("serialize failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Disk helpers

    private static func loadArchive(device: MTLDevice, fileURL: URL) -> MTLBinaryArchive? {
        let descriptor = MTLBinaryArchiveDescriptor()
        if FileManager.default.fileExists(atPath: fileURL.path) {
            descriptor.url = fileURL   // load existing; Metal validates compatibility
        }
        if let existing = try? device.makeBinaryArchive(descriptor: descriptor) {
            return existing
        }
        // The on-disk file was rejected (incompatible/corrupt). Start fresh so new
        // builds can still be captured for the next launch.
        return try? device.makeBinaryArchive(descriptor: MTLBinaryArchiveDescriptor())
    }

    private static func cacheDirectory() -> URL? {
        guard let base = try? FileManager.default.url(for: .applicationSupportDirectory,
                                                      in: .userDomainMask,
                                                      appropriateFor: nil,
                                                      create: true) else { return nil }
        return base.appendingPathComponent("ThresholdPipelineArchive", isDirectory: true)
    }

    /// Composite of per-GPU id + OS version/build + app build. `CFBundleVersion`
    /// captures `default.metallib` rebuilds; the OS string captures driver/OS
    /// revisions that change ISA. Uses a stable manual hash — `Hasher` is salted
    /// per process and would never match across launches.
    private static func invalidationKey(device: MTLDevice) -> String {
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let bundle = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "0"
        return "r\(device.registryID)-\(sanitize(os))-v\(sanitize(bundle))"
    }

    private static func sanitize(_ s: String) -> String {
        String(s.map { ($0.isLetter || $0.isNumber) ? $0 : "_" })
    }

    private static func pruneStaleArchives(in dir: URL, purpose: String, keep: URL) {
        guard let items = try? FileManager.default.contentsOfDirectory(at: dir,
                                                                       includingPropertiesForKeys: nil) else { return }
        let prefix = "\(purpose)-"
        for item in items where item.lastPathComponent.hasPrefix(prefix)
            && item.lastPathComponent != keep.lastPathComponent {
            try? FileManager.default.removeItem(at: item)
        }
    }
}
