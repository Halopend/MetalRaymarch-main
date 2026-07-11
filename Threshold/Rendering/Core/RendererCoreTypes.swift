@preconcurrency import CompositorServices
import Foundation

// The 256 byte aligned size of our uniform structure
let alignedUniformsSize = (MemoryLayout<UniformsArray>.size + 0xFF) & -0x100

// Double buffering for CPU/GPU pipelining (visionOS Renderer only; the Mac
// RaymarchRenderView has its own count). Lets the CPU encode frame N+1 while the
// GPU renders N, hiding encode time behind GPU work — a throughput win while
// GPU-bound (the steady state on Vision Pro, where we run below 45 FPS). Trades
// ~1 frame of latency, which CompositorServices reprojects away at present time.
let maxBuffersInFlight = 2

// Function constant indices - must match the indices in Shaders.metal
// These allow compile-time shader specialization for better performance
enum FunctionConstantIndex: Int {
    case fractalIterations = 0
    case shadowIterations = 1
    case safetyBubbleEnabled = 2
    case hasSpaceWarp = 3  // Compiles out the entire space-warp seam when a scene has no transforms (FC_HAS_SPACEWARP)
    case qualityMode = 4
    case debugHierarchical = 5
    case maxRaySteps = 6  // Base max ray steps (actual count scaled by quality at runtime)
    case fractalType = 7  // Devirtualizes FractalDE_Dispatch
    case neonModeEnabled = 8  // Eliminates neon orbit trap computation when false
    case colorIterations = 9  // Enables loop unrolling in ColourWithScheme
    // index 10 = FC_SHARE_SHADOWS (set in shader only)
    case shadowsEnabled = 11  // GMT-fractals: compile-out entire shadow computation
    case mandelbulbPower = 12  // Bakes integer power for fastPowR dead-code elimination
    case coherentPacketEnabled = 14  // Compiles out the coherent-packet experiment when false (compute kernel)
    case hasEnvScrunch = 16  // Compiles out the Environment Scrunch DE-tail (grid sample + containment) when disabled (FC_HAS_ENVSCRUNCH)
    case sphereProjectionEnabled = 17  // Compiles out per-fold sphere projection for the common unprojected DE path
    case hasHandField = 18  // Compiles out the hand-attraction DE tail when hand interaction is unavailable or disabled
}

enum RendererError: Error {
    case metalLibraryUnavailable
}

extension LayerRenderer.Clock.Instant.Duration {
    var timeInterval: TimeInterval {
        let nanoseconds = TimeInterval(components.attoseconds / 1_000_000_000)
        return TimeInterval(components.seconds) + (nanoseconds / TimeInterval(NSEC_PER_SEC))
    }
}
