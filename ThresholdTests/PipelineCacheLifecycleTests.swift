import Foundation
import Testing
@testable import Threshold

@Suite("Specialized pipeline lifecycle")
struct PipelineCacheLifecycleTests {
    @Test("An evicted in-flight build cannot repopulate the cache")
    func evictedBuild() throws {
        let cache = SpecializationCache<Int>()
        let ticket = try #require(cache.beginBuildIfNeeded("CXold_FI8"))
        cache.evict(prefix: "CXold_")
        cache.store(1, ticket: ticket)
        #expect(cache.pipeline(for: ticket.key) == nil)
        #expect(cache.statistics.staleCompletions == 1)
    }

    @Test("Stale success and failure cannot consume a new build of the same key")
    func sameKeyRebuild() throws {
        let cache = SpecializationCache<Int>()
        let old = try #require(cache.beginBuildIfNeeded("CXa"))
        cache.evict(prefix: "CX")
        let new = try #require(cache.beginBuildIfNeeded("CXa"))
        cache.store(1, ticket: old)
        cache.failBuild(old, now: 10)
        cache.cancelBuild(old)
        #expect(cache.beginBuildIfNeeded("CXa", now: 10) == nil)
        cache.store(2, ticket: new)
        #expect(cache.pipeline(for: "CXa") == 2)
    }

    @Test("Recent variants survive bounded cache eviction")
    func viewportRecency() throws {
        let cache = SpecializationCache<Int>(capacity: 2)
        for (key, value) in [("a", 1), ("b", 2)] {
            cache.store(value, ticket: try #require(cache.beginBuildIfNeeded(key)))
        }
        #expect(cache.pipeline(for: "a") == 1)
        cache.store(3, ticket: try #require(cache.beginBuildIfNeeded("c")))
        #expect(cache.count == 2)
        #expect(cache.pipeline(for: "b") == nil)
        #expect(cache.pipeline(for: "a") == 1)
        #expect(cache.statistics.evictions == 1)
    }

    @Test("Failed builds back off, and a success resets retry history")
    func retryBackoff() throws {
        let cache = SpecializationCache<Int>()
        let first = try #require(cache.beginBuildIfNeeded("a", now: 10))
        cache.failBuild(first, now: 10)
        #expect(cache.beginBuildIfNeeded("a", now: 10.24) == nil)
        let second = try #require(cache.beginBuildIfNeeded("a", now: 10.25))
        cache.failBuild(second, now: 10.25)
        #expect(cache.beginBuildIfNeeded("a", now: 10.74) == nil)
        let third = try #require(cache.beginBuildIfNeeded("a", now: 10.75))
        cache.store(3, ticket: third)
        cache.evict(prefix: "a")
        #expect(cache.beginBuildIfNeeded("a", now: 10.75) != nil)
    }

    @Test("Superseded queued builds can retry without compiler failure delay")
    func cancellation() throws {
        let cache = SpecializationCache<Int>()
        cache.cancelBuild(try #require(cache.beginBuildIfNeeded("a", now: 10)))
        #expect(cache.beginBuildIfNeeded("a", now: 10) != nil)
        #expect(cache.statistics.failures == 0)
    }

    @Test("Vision pipeline cache preserves recently used entries and stays bounded")
    func actorCacheRecency() {
        var cache = BoundedPipelineCache<Int>(capacity: 2)
        cache["a"] = 1
        cache["b"] = 2
        #expect(cache["a"] == 1)
        cache["c"] = 3
        #expect(cache["b"] == nil)
        #expect(cache.count == 2)
        cache.removeValue(forKey: "a")
        cache["d"] = 4
        #expect(cache["c"] == 3)
        cache.removeAll()
        #expect(cache.count == 0)
    }

    @Test("Specialization features remain paired with their captured frame")
    func capturedFeatures() {
        let settings = RenderSettings()
        settings.withPersistenceSuppressed {
            settings.fractalType = .mandelbox
            settings.safetyBubbleEnabled = true
            settings.coherentPacketEnabled = true
            settings.envScrunchEnabled = true
            settings.handAttractionEnabled = true
            let frame = settings.snapshot()
            settings.safetyBubbleEnabled = false
            settings.coherentPacketEnabled = false
            settings.envScrunchEnabled = false
            settings.handAttractionEnabled = false
            let features = PipelineFeatureSnapshot(settings: frame, hasCustomLibrary: true)
            #expect(features.safetyBubble && features.coherentPacket)
            #expect(features.hasEnvScrunch && features.hasHandField && features.hasSpaceWarp)
            #expect(features != PipelineFeatureSnapshot(settings: settings.snapshot(), hasCustomLibrary: false))
        }
    }
}
