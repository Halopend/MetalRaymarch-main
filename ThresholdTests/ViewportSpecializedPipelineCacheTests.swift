//
//  ViewportSpecializedPipelineCacheTests.swift
//  ThresholdTests
//
//  Pins the Mac/iOS specialized-pipeline cache contract after the String→struct
//  key rework: build-scheduling (pending) semantics, and the three eviction
//  operations that replaced prefix matching — evictAll (Force Recompile),
//  evictAllCustom (custom-library deactivation), evict(customHash:) (effect
//  switch). A key that evicts too much wastes compiles; one that evicts too
//  little reuses library-A's pipeline for library-B's DE — silently wrong
//  geometry with no error anywhere.
//

import Testing
import Metal
@testable import Threshold

@Suite("Viewport specialized pipeline cache")
struct ViewportSpecializedPipelineCacheTests {

    private static func makeKey(customHash: String? = nil,
                                fractalType: Int32 = 0,
                                iterations: Int32 = 6,
                                power: Int32? = nil) -> ViewportPipelineKey {
        ViewportPipelineKey(
            customHash: customHash,
            fractalType: fractalType,
            iterations: iterations,
            raySteps: 168,
            colorIterations: 8,
            power: power,
            safetyBubbleEnabled: true,
            shadowsEnabled: true,
            sphereProjectionEnabled: false,
            hasSpaceWarp: false,
            hasEnvScrunch: false,
            hasHandField: false
        )
    }

    /// One trivial render pipeline compiled from source on the real device —
    /// the cache stores `MTLRenderPipelineState` and the protocol has no
    /// public conformable surface, so a real (cheap) pipeline is the honest way
    /// to exercise store/evict. Same host-GPU expectation as
    /// `EmbeddedFormulaCompileTests`.
    private static func makePipeline(device: MTLDevice) throws -> MTLRenderPipelineState {
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        vertex float4 cacheTestVertex() { return float4(0.0); }
        fragment float4 cacheTestFragment() { return float4(0.0); }
        """
        let library = try device.makeLibrary(source: source, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "cacheTestVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "cacheTestFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }

    @Test("beginBuildIfNeeded schedules once; failBuild releases the pending mark")
    func pendingLifecycle() throws {
        let cache = ViewportSpecializedPipelineCache()
        let key = Self.makeKey()

        #expect(cache.beginBuildIfNeeded(key), "first sighting should schedule a build")
        #expect(!cache.beginBuildIfNeeded(key), "in-flight key must not schedule a duplicate compile")

        cache.failBuild(key)
        #expect(cache.beginBuildIfNeeded(key), "a failed build must allow rescheduling")
    }

    @Test("store publishes the pipeline and ends the pending state")
    func storePublishes() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("No Metal device available; skipping pipeline-cache store coverage")
            return
        }
        let cache = ViewportSpecializedPipelineCache()
        let key = Self.makeKey()
        #expect(cache.pipeline(for: key) == nil)

        _ = cache.beginBuildIfNeeded(key)
        let pipeline = try Self.makePipeline(device: device)
        cache.store(pipeline, for: key)

        #expect(cache.pipeline(for: key) === pipeline)
        #expect(!cache.beginBuildIfNeeded(key), "a cached key must not schedule a rebuild")
    }

    @Test("evict(customHash:) retires exactly one effect's pipelines")
    func evictSingleCustomHash() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("No Metal device available; skipping pipeline-cache eviction coverage")
            return
        }
        let cache = ViewportSpecializedPipelineCache()
        let builtin = Self.makeKey()
        let customA = Self.makeKey(customHash: "aaaa1111", fractalType: 1000)
        let customB = Self.makeKey(customHash: "bbbb2222", fractalType: 1000)
        let pipeline = try Self.makePipeline(device: device)
        cache.store(pipeline, for: builtin)
        cache.store(pipeline, for: customA)
        _ = cache.beginBuildIfNeeded(customB)   // B in flight, not yet stored

        cache.evict(customHash: "aaaa1111")
        #expect(cache.pipeline(for: customA) == nil, "evicted hash must drop its cached pipeline")
        #expect(cache.pipeline(for: builtin) === pipeline, "builtin pipelines must survive a custom eviction")

        cache.evict(customHash: "bbbb2222")
        #expect(cache.beginBuildIfNeeded(customB), "evicting an in-flight hash must release its pending mark")
    }

    @Test("evictAllCustom clears every custom entry but keeps builtins")
    func evictAllCustomKeepsBuiltins() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("No Metal device available; skipping pipeline-cache eviction coverage")
            return
        }
        let cache = ViewportSpecializedPipelineCache()
        let builtin = Self.makeKey()
        let customA = Self.makeKey(customHash: "aaaa1111", fractalType: 1000)
        let customB = Self.makeKey(customHash: "bbbb2222")   // warp riding a built-in fractal
        let pipeline = try Self.makePipeline(device: device)
        cache.store(pipeline, for: builtin)
        cache.store(pipeline, for: customA)
        _ = cache.beginBuildIfNeeded(customB)

        cache.evictAllCustom()
        #expect(cache.pipeline(for: customA) == nil)
        #expect(cache.beginBuildIfNeeded(customB), "pending custom builds must be released too")
        #expect(cache.pipeline(for: builtin) === pipeline)
    }

    @Test("evictAll drops everything, cached and pending")
    func evictAllDropsEverything() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("No Metal device available; skipping pipeline-cache eviction coverage")
            return
        }
        let cache = ViewportSpecializedPipelineCache()
        let builtin = Self.makeKey()
        let custom = Self.makeKey(customHash: "aaaa1111")
        let pipeline = try Self.makePipeline(device: device)
        cache.store(pipeline, for: builtin)
        _ = cache.beginBuildIfNeeded(custom)

        cache.evictAll()
        #expect(cache.pipeline(for: builtin) == nil)
        #expect(cache.beginBuildIfNeeded(builtin), "evictAll must allow immediate rebuild scheduling")
        #expect(cache.beginBuildIfNeeded(custom))
    }

    @Test("key identity: every specialization axis participates in equality")
    func keyIdentity() {
        let base = Self.makeKey()
        #expect(base == Self.makeKey())
        #expect(base != Self.makeKey(customHash: "aaaa1111"),
                "customHash must namespace keys — library-A's pipeline must never be reused for library-B")
        #expect(base != Self.makeKey(fractalType: 1))
        #expect(base != Self.makeKey(iterations: 7))
        #expect(base != Self.makeKey(power: 8),
                "nil vs baked Mandelbulb power must be distinct specializations")
    }
}
