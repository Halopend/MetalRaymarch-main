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
    case warmStart = 13  // Compiles in the temporal-depth march warm-start (FC_WARM_START)
    case coherentPacketEnabled = 14  // Compiles out the coherent-packet experiment when false (compute kernel)
    case coarseWarmStart = 15  // Compiles in the conservative cone coarse-prepass warm-start (FC_COARSE_WARM_START). Index 14 is taken, so this uses index 15.
    case hasEnvScrunch = 16  // Compiles out the Environment Scrunch DE-tail (grid sample + containment) when the device-local toggle is off (FC_HAS_ENVSCRUNCH)
    case sphereProjectionEnabled = 17  // Compiles out per-fold sphere projection for the common unprojected DE path
}

// Fragment texture binding slots - must match [[texture(n)]] in Shaders.metal
enum FragmentTextureIndex: Int {
    case prevDepth = 1  // Previous-frame depth for the temporal march warm-start
    case coarseWarmStart = 2  // Conservative cone coarse-prepass warmT (lower bound on entry distance)
}

enum RendererError: Error {
    case badVertexDescriptor
    case metalLibraryUnavailable
}

// ═══════════════════════════════════════════════════════════════════════════
// TEMPORAL DEPTH WARM-START GATE
// Single owner of "is last frame's depth history safe to warm-start from".
// Render paths that don't write fragment depth call invalidate(); the MetalFX
// fragment path calls recordDepthWritten() after a successful frame; the
// per-frame uniform patch asks allowsWarmStart(). MetalFXManager's separate
// depthHistoryValid flag intentionally stays distinct — it tracks texture
// lifecycle (slot written at the current size), this gate tracks scene
// semantics (written by a compatible distance field).
// ═══════════════════════════════════════════════════════════════════════════
struct WarmStartGate {

    /// Everything that shapes the distance field, split by how a change must
    /// be handled. Discrete settings (fractal type, iterations, inversion
    /// mode, rotation flags) are hashed — any change is a hard cut to a
    /// different field. Continuous settings are kept as values and compared
    /// with a small per-frame tolerance: the warm start already marches from
    /// 0.9×t with an extra 0.3 back-off and falls back to a full march on a
    /// window miss, so a bounded one-frame morph costs at most the fallback,
    /// never correctness. An exact-equality gate here would disable the warm
    /// start whenever smooth-damp or music reactivity nudges any float —
    /// i.e. during essentially all visualizer playback.
    struct GeometryKey {
        let discrete: Int
        let continuous: [Float]

        init(_ s: RenderSettingsSnapshot) {
            var hasher = Hasher()
            hasher.combine(s.fractalType.rawValue)
            hasher.combine(s.fractalIterations)
            hasher.combine(s.sphericalInversionMode.rawValue)
            hasher.combine(s.formulaParams.rotationFlags)
            discrete = hasher.finalize()

            var values: [Float] = [
                s.scale, s.fractalScale, s.minDistance, s.detailScale,
                s.foldingLimit, s.sphereRadius, s.sphericalInversionRadius,
            ]
            values.reserveCapacity(7 + 16 + 18)
            // The 16 formula param slots (C float[16] imports as a tuple of
            // Floats — raw bytes are exactly the packed floats, no padding).
            withUnsafeBytes(of: s.formulaParams.params) { raw in
                values.append(contentsOf: raw.bindMemory(to: Float.self))
            }
            // Rotation matrices morph continuously under audio mappings too.
            // Element-wise (not raw bytes): simd column padding is undefined.
            for m in [s.formulaParams.rotMatrix1, s.formulaParams.rotMatrix2] {
                for c in [m.columns.0, m.columns.1, m.columns.2] {
                    values.append(c.x); values.append(c.y); values.append(c.z)
                }
            }
            continuous = values
        }

        func matches(_ other: GeometryKey) -> Bool {
            guard discrete == other.discrete,
                  continuous.count == other.continuous.count else { return false }
            for i in continuous.indices {
                let a = continuous[i], b = other.continuous[i]
                // 3% relative (small absolute floor near zero): generous for
                // one frame of smooth-damp/audio morph, tight enough that a
                // preset jump or hard parameter snap still invalidates.
                if abs(a - b) > max(0.003, 0.03 * max(abs(a), abs(b))) {
                    return false
                }
            }
            return true
        }
    }

    private var recordedKey: GeometryKey?

    /// The previous frame didn't produce trustworthy fragment depth
    /// (adaptive compute, direct render, MetalFX failure).
    mutating func invalidate() { recordedKey = nil }

    /// A fragment+MetalFX frame just wrote depth under this snapshot.
    mutating func recordDepthWritten(_ s: RenderSettingsSnapshot) {
        recordedKey = GeometryKey(s)
    }

    /// May this frame's rays warm-start from the recorded depth history?
    func allowsWarmStart(for s: RenderSettingsSnapshot) -> Bool {
        guard let recordedKey else { return false }
        // Spherical inversion warps the march ray; reprojection math assumes
        // the unwarped camera ray, so warm start is off entirely there.
        guard s.sphericalInversionMode.rawValue == 0 else { return false }
        return GeometryKey(s).matches(recordedKey)
    }
}

extension LayerRenderer.Clock.Instant.Duration {
    var timeInterval: TimeInterval {
        let nanoseconds = TimeInterval(components.attoseconds / 1_000_000_000)
        return TimeInterval(components.seconds) + (nanoseconds / TimeInterval(NSEC_PER_SEC))
    }
}
