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
            // Containment toggles are hard geometry cuts. In particular, a
            // previous unbounded depth must never warm-start a newly bounded
            // frame past the room/shape surface.
            hasher.combine(s.boundingSphereSkipEnabled)
            hasher.combine(s.boundToSpaceEnabled)
            hasher.combine(s.boundToSpaceMode)
            discrete = hasher.finalize()

            var values: [Float] = [
                s.scale, s.fractalScale, s.minDistance, s.detailScale,
                s.foldingLimit, s.sphereRadius, s.sphericalInversionRadius,
                s.position.x, s.position.y, s.position.z,
                s.worldRotation.vector.x, s.worldRotation.vector.y,
                s.worldRotation.vector.z, s.worldRotation.vector.w,
                s.linearRailWorldOffset.x, s.linearRailWorldOffset.y,
                s.linearRailWorldOffset.z,
                s.boundingShapeRadius, s.boundingShapeType,
                s.boundSpaceSize.x, s.boundSpaceSize.y, s.boundSpaceSize.z,
            ]
            values.reserveCapacity(values.count + 16 + 18)
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
        // Scanned grids and tracked hands change outside RenderSettings, so the
        // snapshot has no stable identity/position to key those dynamic CSG
        // fields. Never retain their depth: a newly-near surface or hand could
        // otherwise be skipped using the old frame's start distance.
        recordedKey = (s.envScrunchEnabled || s.handAttractionEnabled)
            ? nil
            : GeometryKey(s)
    }

    /// May this frame's rays warm-start from the recorded depth history?
    func allowsWarmStart(for s: RenderSettingsSnapshot) -> Bool {
        guard let recordedKey else { return false }
        guard !s.envScrunchEnabled, !s.handAttractionEnabled else { return false }
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
