//
//  ShaderWorldFieldGateTests.swift
//  ThresholdTests
//
//  Guards two shader safety/performance gates that have no on-device test:
//
//  1. GetNormal fast-path gate — `worldFieldsMayAlterDistance` must be
//     POSITION-AWARE for the safety bubble (visionOS default-ON), or every hit
//     pixel pays 2-4 extra DE probes per eye per frame. Its exactness claim
//     ("outside fadeWidth + margin of the wall the composed field is the raw
//     field, even at the finite-difference probe points") is pure math over
//     the bubble pseudo-distances, so it is sweep-verified here with Swift
//     ports of the same SDFs. The margin constant is parsed out of
//     Shaders.metal so the test tracks the shader, not a copy.
//
//  2. Cone coarse-prepass trust gate — `domainWarped` must distrust EVERY
//     domain-warp system, including the composable SpaceWarpOp stack (repeat
//     groups use a heuristic additive DE recurrence that is not a proven
//     Lipschitz-1 lower bound). A missing term here silently violates the
//     warm-start "never skips a surface" contract (silhouette holes).
//

import Testing
import Foundation
import simd

@Suite("Shader world-field gates — bubble normal band + cone prepass trust")
struct ShaderWorldFieldGateTests {

    /// Repo root, derived from this source file's compile-time path (same
    /// pattern as EmbedFreshnessTests): tests run from the repo, so a missing
    /// shader file is a real failure, not a skip.
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // …/ThresholdTests
        .deletingLastPathComponent()   // repo root

    private static func shaderSource() throws -> String {
        let url = repoRoot
            .appendingPathComponent("Threshold/Rendering/Shaders.metal")
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Swift ports of the bubble pseudo-distances (Shaders.metal)

    private static func cubeDist(_ p: SIMD3<Float>, _ r: Float) -> Float {
        let d = abs(p) - SIMD3<Float>(repeating: r)
        let outside = simd_length(simd_max(d, SIMD3<Float>(repeating: 0)))
        return outside + min(max(d.x, max(d.y, d.z)), 0)
    }

    private static func tetraDist(_ p: SIMD3<Float>, _ r: Float) -> Float {
        let s: Float = 0.5773502691896258
        let d1 = simd_dot(p, SIMD3<Float>( s,  s,  s))
        let d2 = simd_dot(p, SIMD3<Float>( s, -s, -s))
        let d3 = simd_dot(p, SIMD3<Float>(-s,  s, -s))
        let d4 = simd_dot(p, SIMD3<Float>(-s, -s,  s))
        return max(max(d1, d2), max(d3, d4)) - r * s
    }

    private static func negativeCubeDist(_ p: SIMD3<Float>, _ r: Float) -> Float {
        let e: Float = 0.65
        let q = abs(p) / max(r, 1e-4)
        let superDistance = powf(powf(q.x, e) + powf(q.y, e) + powf(q.z, e), 1.0 / e)
        return (superDistance - 1.0) * r
    }

    private static func octahedronDist(_ p: SIMD3<Float>, _ r: Float) -> Float {
        let q = abs(p)
        return (q.x + q.y + q.z - r) * 0.5773502691896258
    }

    private static func icosahedronDist(_ p: SIMD3<Float>, _ r: Float) -> Float {
        let phi: Float = 1.618033988749895
        let invPhiLen: Float = 0.5257311121191336
        let invTriLen: Float = 0.5773502691896258
        let axisScale: Float = 0.85065080835204
        let q = abs(p)
        let d1 = simd_dot(q, SIMD3<Float>(1, 1, 1) * invTriLen)
        let d2 = simd_dot(q, SIMD3<Float>(0, 1, phi) * invPhiLen)
        let d3 = simd_dot(q, SIMD3<Float>(1, phi, 0) * invPhiLen)
        let d4 = simd_dot(q, SIMD3<Float>(phi, 0, 1) * invPhiLen)
        return max(max(d1, d2), max(d3, d4)) - r * axisScale
    }

    private static func dodecahedronDist(_ p: SIMD3<Float>, _ r: Float) -> Float {
        let phi: Float = 1.618033988749895
        let invPhiLen: Float = 0.5257311121191336
        let axisScale: Float = 0.85065080835204
        let q = abs(p)
        let d1 = simd_dot(q, SIMD3<Float>(phi, 1, 0) * invPhiLen)
        let d2 = simd_dot(q, SIMD3<Float>(1, 0, phi) * invPhiLen)
        let d3 = simd_dot(q, SIMD3<Float>(0, phi, 1) * invPhiLen)
        return max(d1, max(d2, d3)) - r * axisScale
    }

    /// Port of safetyBubbleDistance (bubble center at the origin, matching the
    /// camera-centered use in the renderer).
    private static func bubbleDist(_ p: SIMD3<Float>, radius: Float, shape: Float) -> Float {
        let sphere = simd_length(p) - radius
        let cube = cubeDist(p, radius)
        if shape <= 1.0 {
            let t = max(0, min(1, shape))
            return sphere + (cube - sphere) * t
        }
        switch Int(max(2, min(6, shape + 0.5))) {
        case 2: return tetraDist(p, radius)
        case 3: return negativeCubeDist(p, radius)
        case 4: return octahedronDist(p, radius)
        case 5: return icosahedronDist(p, radius)
        case 6: return dodecahedronDist(p, radius)
        default: return cube
        }
    }

    /// Port of applySafetyBubble's faded compose (smooth polynomial max).
    private static func smaxCompose(d: Float, bubbleDist: Float, k: Float) -> Float {
        let a = d, b = -bubbleDist
        let h = max(0, min(1, 0.5 + 0.5 * (b - a) / k))
        return a + (b - a) * h + k * h * (1 - h)
    }

    private static func parsedNormalBandMargin(from shader: String) throws -> Float {
        let pattern = #"kSafetyBubbleNormalBandMargin = ([0-9]*\.?[0-9]+)f"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(shader.startIndex..., in: shader)
        guard let match = regex.firstMatch(in: shader, range: range),
              let valueRange = Range(match.range(at: 1), in: shader),
              let value = Float(shader[valueRange]) else {
            throw NSError(domain: "ShaderWorldFieldGateTests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "kSafetyBubbleNormalBandMargin not found in Shaders.metal"
            ])
        }
        return value
    }

    // MARK: - Finding: bubble gate must be position-aware (fast normals back)

    @Test("worldFieldsMayAlterDistance is position-aware and band-gated")
    func bubbleGateIsPositionAware() throws {
        let shader = try Self.shaderSource()
        guard let declStart = shader.range(of: "FORCE_INLINE bool worldFieldsMayAlterDistance(") else {
            Issue.record("worldFieldsMayAlterDistance not found in Shaders.metal")
            return
        }
        let body = String(shader[declStart.lowerBound...].prefix(1400))
        // Takes the shaded point — an enabled-only check would force the
        // finite-difference normal path onto every visionOS hit pixel.
        #expect(body.contains("float3 pos"),
                "gate lost its position parameter — bubble would disable fast normals globally")
        // …and evaluates the bubble field AT that point against the band.
        #expect(body.contains("safetyBubbleDistance(pos"),
                "gate no longer spatially bounds the bubble's influence")
        #expect(body.contains("kSafetyBubbleNormalBandMargin"),
                "gate no longer includes the probe-reach margin")
    }

    @Test("smooth-max compose is a bit-exact identity outside the fade band")
    func smaxIdentityOutsideBand() {
        // The gate's exactness claim: whenever bubbleDist + d >= fadeWidth the
        // composed distance IS the raw distance (h saturates to 0), so the fast
        // normal paths see an unmodified field. Bit-exact, not approximate.
        let fadeWidths: [Float] = [0.001, 0.1, 0.5, 1.0]
        let ds: [Float] = [-0.03, 0.0, 0.004, 0.2, 5.0]
        for k in fadeWidths {
            for d in ds {
                // Boundary of the identity region: bubbleDist = k - d.
                for extra in [Float(0), 1e-4, 0.15, 2.0] {
                    let bd = (k - d) + extra
                    let composed = Self.smaxCompose(d: d, bubbleDist: bd, k: k)
                    #expect(composed == d,
                            "smax not identity at d=\(d) bubbleDist=\(bd) k=\(k)")
                }
            }
        }
    }

    @Test("normal-band margin covers probe reach for every bubble shape")
    func marginCoversProbeReach() throws {
        let margin = try Self.parsedNormalBandMargin(from: Self.shaderSource())

        // Model of the shader's worst case, mirroring the derivation comment in
        // Shaders.metal: a hit at pos (bubble centered on the camera at the
        // origin, so hit distance t = |pos|) may penetrate the surface by up to
        // the march hit threshold, and GetNormal's widest probe reach is
        // e = 0.001·t (the full-iteration fallback). The invariant: for any pos
        // ON the gate threshold (bubbleDist == fadeWidth + margin), every probe
        // q still satisfies bubbleDist(q) + d(q) >= fadeWidth, i.e. the drop in
        // bubbleDist over one probe step obeys drop <= margin - penetration - e.
        let penetration: Float = 0.03

        let shapes: [Float] = [0, 0.5, 1, 2, 3, 4, 5, 6]
        let radii: [Float] = [0.5, 1.8, 2.5]          // ControlSpec.safetyBubbleRadius range
        let fadeWidths: [Float] = [0, 0.1, 1.0]       // SafetyBubbleConfig.clamp range

        // Deterministic LCG — no random in tests (repeatability).
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func next() -> Float {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Float((seed >> 33) & 0xFFFFFF) / Float(0xFFFFFF) * 2.0 - 1.0
        }
        func randomUnit() -> SIMD3<Float> {
            var v = SIMD3<Float>(next(), next(), next())
            while simd_length_squared(v) < 1e-4 { v = SIMD3<Float>(next(), next(), next()) }
            return simd_normalize(v)
        }

        for shape in shapes {
            for radius in radii {
                for fadeWidth in fadeWidths {
                    let threshold = fadeWidth + margin

                    // Directions: random, plus near-axis rays — the Negative
                    // Cube superellipsoid's gradient spikes where a component
                    // crosses zero, which is its worst case.
                    var directions: [SIMD3<Float>] = (0..<24).map { _ in randomUnit() }
                    for delta in [Float(0), 1e-4, 1e-3, 1e-2] {
                        directions.append(simd_normalize(SIMD3<Float>(1, delta, delta * 0.5)))
                        directions.append(simd_normalize(SIMD3<Float>(delta, 1, delta)))
                    }

                    for dir in directions {
                        // All bubble pseudo-distances increase monotonically
                        // along a ray from the center — bisect to the point
                        // sitting exactly on the gate threshold.
                        var lo: Float = 0, hi: Float = radius
                        while Self.bubbleDist(dir * hi, radius: radius, shape: shape) < threshold {
                            hi *= 2
                            if hi > 1e4 { break }
                        }
                        for _ in 0..<48 {
                            let mid = (lo + hi) * 0.5
                            if Self.bubbleDist(dir * mid, radius: radius, shape: shape) < threshold {
                                lo = mid
                            } else {
                                hi = mid
                            }
                        }
                        let pos = dir * hi
                        let t = simd_length(pos)
                        let e = 0.001 * t
                        let d0 = Self.bubbleDist(pos, radius: radius, shape: shape)

                        // Probe steps: axes, along/against the ray, random, and
                        // the targeted "zero the smallest component" move.
                        var steps: [SIMD3<Float>] = [
                            SIMD3(e, 0, 0), SIMD3(-e, 0, 0),
                            SIMD3(0, e, 0), SIMD3(0, -e, 0),
                            SIMD3(0, 0, e), SIMD3(0, 0, -e),
                            dir * e, dir * -e,
                        ]
                        for _ in 0..<12 { steps.append(randomUnit() * e) }
                        let ax = abs(pos)
                        let minAxis: Int = (ax.x <= ax.y && ax.x <= ax.z) ? 0 : (ax.y <= ax.z ? 1 : 2)
                        var zeroing = SIMD3<Float>(repeating: 0)
                        zeroing[minAxis] = pos[minAxis] >= 0
                            ? -min(ax[minAxis], e) : min(ax[minAxis], e)
                        steps.append(zeroing)

                        var maxDrop: Float = 0
                        for step in steps {
                            let dq = Self.bubbleDist(pos + step, radius: radius, shape: shape)
                            maxDrop = max(maxDrop, d0 - dq)
                        }
                        #expect(maxDrop + penetration + e <= margin,
                                "margin \(margin) too tight: drop \(maxDrop) + pen + e exceeds it (shape \(shape), radius \(radius), fade \(fadeWidth), t \(t))")
                    }
                }
            }
        }
    }

    // MARK: - Finding: cone prepass must distrust the composable warp stack

    @Test("cone prepass domainWarped covers every warp system, incl. the stack")
    func conePrepassDistrustsWarpStack() throws {
        let shader = try Self.shaderSource()
        guard let declStart = shader.range(of: "bool domainWarped"),
              let stmtEnd = shader.range(of: ";", range: declStart.upperBound..<shader.endIndex) else {
            Issue.record("domainWarped guard not found in Shaders.metal")
            return
        }
        let statement = String(shader[declStart.lowerBound..<stmtEnd.lowerBound])
        // The warm-start lower bound is only proven on an UN-warped domain.
        // Every system that can reshape it must appear in the distrust guard —
        // the composable stack runs whenever count > 0, independent of the
        // legacy spaceWarpStrength uniform.
        #expect(statement.contains("sphericalInversionMode"))
        #expect(statement.contains("sphereProjectionBlend"))
        #expect(statement.contains("spaceWarpStrength"))
        #expect(statement.contains("spaceWarpStack.count"),
                "cone prepass trusts warmT while the SpaceWarpOp stack warps the domain — warm starts can overshoot surfaces (silhouette holes)")
    }
}
