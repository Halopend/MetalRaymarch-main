#if os(macOS) || os(iOS)
import Metal
import Synchronization

/// `Mutex`-protected cache of function-constant–specialized `fragmentShaderMono`
/// pipelines for the macOS/iOS renderer. Specializing on iteration/ray-step/fractal
/// counts lets the Metal compiler fully unroll the `Map()` and `Scene()` loops
/// and devirtualize the DE dispatch — the same optimization the visionOS
/// `Renderer` already performs. Builds run asynchronously off the render thread;
/// the generic pipeline is used until the specialized variant is ready.
///
/// The render thread reads the cache *synchronously* every frame (see
/// `resolveActivePipeline`) and must return a pipeline for the current frame, so
/// an `actor` is the wrong tool — it would force the hot-path read to be `async`.
/// `Mutex` keeps the access synchronous while giving compiler-checked `Sendable`
/// isolation, so the async `makeRenderPipelineState` completion handler can safely
/// store results without manual lock management.
final class MacSpecializedPipelineCache: Sendable {
    private struct State {
        var cache: [String: MTLRenderPipelineState] = [:]
        var pending: Set<String> = []
    }

    private let state = Mutex(State())

    func pipeline(for key: String) -> MTLRenderPipelineState? {
        state.withLock { $0.cache[key] }
    }

    /// Returns `true` if the caller should kick off a build (not cached and not
    /// already in flight). Marks the key pending so concurrent frames don't
    /// schedule duplicate compiles.
    func beginBuildIfNeeded(_ key: String) -> Bool {
        state.withLock { current in
            if current.cache[key] != nil || current.pending.contains(key) { return false }
            current.pending.insert(key)
            return true
        }
    }

    func store(_ pipeline: MTLRenderPipelineState, for key: String) {
        state.withLock { current in
            current.cache[key] = pipeline
            current.pending.remove(key)
        }
    }

    func failBuild(_ key: String) {
        state.withLock { $0.pending.remove(key) }
    }
}
#endif
