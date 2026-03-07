@preconcurrency import CompositorServices
import Foundation

// The 256 byte aligned size of our uniform structure
let alignedUniformsSize = (MemoryLayout<UniformsArray>.size + 0xFF) & -0x100

// Double buffering for CPU/GPU pipelining.
// Allows CPU to prepare frame N+1 while GPU renders N.
// This prevents the 45fps vsync lock while minimizing latency.
let maxBuffersInFlight = 2

// Function constant indices - must match the indices in Shaders.metal
// These allow compile-time shader specialization for better performance
enum FunctionConstantIndex: Int {
    case fractalIterations = 0
    case shadowIterations = 1
    case safetyBubbleEnabled = 2
    case showHUD = 3
    case qualityMode = 4
    case debugHierarchical = 5
    case maxRaySteps = 6  // Base max ray steps (actual count scaled by quality at runtime)
    case fractalType = 7  // Devirtualizes FractalDE_Dispatch
    case neonModeEnabled = 8  // Eliminates neon orbit trap computation when false
    case colorIterations = 9  // Enables loop unrolling in ColourWithScheme
    // index 10 = FC_SHARE_SHADOWS (set in shader only)
    case shadowsEnabled = 11  // GMT-fractals: compile-out entire shadow computation
    case mandelbulbPower = 12  // Bakes integer power for fastPowR dead-code elimination
}

enum RendererError: Error {
    case badVertexDescriptor
    case metalLibraryUnavailable
}

extension LayerRenderer.Clock.Instant.Duration {
    var timeInterval: TimeInterval {
        let nanoseconds = TimeInterval(components.attoseconds / 1_000_000_000)
        return TimeInterval(components.seconds) + (nanoseconds / TimeInterval(NSEC_PER_SEC))
    }
}
