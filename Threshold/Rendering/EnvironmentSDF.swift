//
//  EnvironmentSDF.swift
//  Threshold
//
//  Environment Scrunch's data side: a band-limited unsigned distance grid
//  (world meters, ENV_SCRUNCH_DIM³ half floats) baked on the CPU from the
//  scanned surroundings, sampled by the DE via its bindless GPU address
//  (EnvScrunchParams.gridAddress). The shipping source is visionOS scene
//  reconstruction (triangle soup, world space). Synthetic analytic primitives
//  below are deterministic test/diagnostic fixtures only; desktop/iPad render
//  pipelines do not create or bind an environment grid.
//
//  Distances are clamped to `clampFar`; the shader treats out-of-grid (and
//  far-band) samples as "no effect", so inaccuracy beyond the splat radius
//  only ever weakens the effect, never corrupts geometry.
//

import Foundation
import Metal
import simd

/// One immutable baked grid. Rebakes produce a NEW instance (fresh buffer), so
/// a frame that captured the old one keeps a valid buffer for its lifetime —
/// publication is a Mutex swap, no in-place mutation after publish.
final class EnvironmentSDFGrid: @unchecked Sendable {
    static let dim = Int(ENV_SCRUNCH_DIM)
    /// Distances are exact only within the bake's splat radius and clamp here
    /// beyond it. Keep ≥ the max UI reach (2.0 m) so the weight ramp always
    /// has real gradient to work with.
    static let clampFar: Float = 2.0

    let buffer: MTLBuffer
    let originWorld: SIMD3<Float>
    let sizeWorld: SIMD3<Float>

    /// Tight world-space AABB of the scanned surfaces (mesh triangles, or the
    /// finite synthetic primitives). This is the Environment Scrunch *containment*
    /// box: the unsigned distance grid can't tell room-interior from beyond-the-
    /// wall, so the shader clips the fractal to this box to kill the mirror shell.
    /// Defaults to the full grid volume until a bake narrows it.
    var surfaceMinWorld: SIMD3<Float>
    var surfaceMaxWorld: SIMD3<Float>

    var cellSize: SIMD3<Float> { sizeWorld / Float(Self.dim) }
    var gpuAddress: UInt64 { buffer.gpuAddress }

    private init?(device: MTLDevice, originWorld: SIMD3<Float>, sizeWorld: SIMD3<Float>) {
        let count = Self.dim * Self.dim * Self.dim
        guard let buf = device.makeBuffer(length: count * MemoryLayout<UInt16>.stride,
                                          options: .storageModeShared) else { return nil }
        self.buffer = buf
        self.originWorld = originWorld
        self.sizeWorld = sizeWorld
        self.surfaceMinWorld = originWorld
        self.surfaceMaxWorld = originWorld + sizeWorld
    }

    private var values: UnsafeMutablePointer<UInt16> {
        buffer.contents().assumingMemoryBound(to: UInt16.self)
    }

    // MARK: - Synthetic bake (tests/diagnostics only)

    /// Analytic primitive set for the Mac path — exact SDF per voxel, no mesh.
    enum SyntheticPrimitive {
        case floor(y: Float)
        case sphere(center: SIMD3<Float>, radius: Float)
        case box(center: SIMD3<Float>, halfExtent: SIMD3<Float>)

        func distance(to p: SIMD3<Float>) -> Float {
            switch self {
            case .floor(let y):
                return abs(p.y - y)
            case .sphere(let c, let r):
                return simd_length(p - c) - r
            case .box(let c, let h):
                let q = simd_abs(p - c) - h
                return simd_length(simd_max(q, SIMD3<Float>(repeating: 0)))
                    + min(max(q.x, max(q.y, q.z)), 0)
            }
        }
    }

    /// Parses a deterministic fixture specification. Grammar: `;`-separated primitives —
    /// `floor:y` · `sphere:x,y,z,r` · `box:cx,cy,cz,hx,hy,hz`. The value "1"
    /// yields a default demo room (floor + sphere + box in front of the Mac
    /// camera, which sits at world (0,0,3) looking −Z).
    static func parseSynthetic(_ spec: String) -> [SyntheticPrimitive] {
        if spec.trimmingCharacters(in: .whitespaces) == "1" {
            return [.floor(y: 0),
                    .sphere(center: SIMD3<Float>(0.0, 0.9, 1.0), radius: 0.35),
                    .box(center: SIMD3<Float>(-0.7, 0.45, 1.3),
                         halfExtent: SIMD3<Float>(0.3, 0.45, 0.25))]
        }
        var prims: [SyntheticPrimitive] = []
        for part in spec.split(separator: ";") {
            let kv = part.split(separator: ":", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let nums = kv[1].split(separator: ",").compactMap {
                Float($0.trimmingCharacters(in: .whitespaces))
            }
            switch kv[0].trimmingCharacters(in: .whitespaces) {
            case "floor" where nums.count == 1:
                prims.append(.floor(y: nums[0]))
            case "sphere" where nums.count == 4:
                prims.append(.sphere(center: SIMD3(nums[0], nums[1], nums[2]), radius: nums[3]))
            case "box" where nums.count == 6:
                prims.append(.box(center: SIMD3(nums[0], nums[1], nums[2]),
                                  halfExtent: SIMD3(nums[3], nums[4], nums[5])))
            default:
                continue
            }
        }
        return prims
    }

    static func bakeSynthetic(device: MTLDevice,
                              primitives: [SyntheticPrimitive],
                              originWorld: SIMD3<Float> = SIMD3(-4.0, -0.5, -4.0),
                              sizeWorld: SIMD3<Float> = SIMD3(8.0, 4.0, 8.0)) -> EnvironmentSDFGrid? {
        guard !primitives.isEmpty,
              let grid = EnvironmentSDFGrid(device: device, originWorld: originWorld, sizeWorld: sizeWorld)
        else { return nil }
        // Containment AABB from the finite primitives (a floor spans the grid XZ
        // at its y; spheres/boxes contribute their own extents).
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for prim in primitives {
            switch prim {
            case .floor(let y):
                lo = simd_min(lo, SIMD3(originWorld.x, y, originWorld.z))
                hi = simd_max(hi, SIMD3(originWorld.x + sizeWorld.x, y, originWorld.z + sizeWorld.z))
            case .sphere(let c, let r):
                lo = simd_min(lo, c - r); hi = simd_max(hi, c + r)
            case .box(let c, let h):
                lo = simd_min(lo, c - h); hi = simd_max(hi, c + h)
            }
        }
        if lo.x <= hi.x, lo.y <= hi.y, lo.z <= hi.z {
            grid.surfaceMinWorld = lo; grid.surfaceMaxWorld = hi
        }
        let cell = grid.cellSize
        let v = grid.values
        for z in 0..<dim {
            for y in 0..<dim {
                for x in 0..<dim {
                    let p = originWorld + (SIMD3<Float>(Float(x), Float(y), Float(z)) + 0.5) * cell
                    var d = clampFar
                    for prim in primitives { d = min(d, abs(prim.distance(to: p))) }
                    v[(z * dim + y) * dim + x] = Self.floatToHalfBits(max(d, 0))
                }
            }
        }
        return grid
    }

    // MARK: - Mesh bake (visionOS scene reconstruction)

    /// Bakes world-space triangle soup (flat v0,v1,v2 triples) into a fresh
    /// grid. Band-limited splat: the grid initializes to clampFar and each
    /// triangle only refines voxels within `splatRadius` of its AABB, so cost
    /// scales with surface area instead of volume×triangles. Distances between
    /// splatRadius and clampFar stay at clampFar — beyond the default reach,
    /// where the weight ramp is already near zero.
    static func bake(device: MTLDevice,
                     triangles: [SIMD3<Float>],
                     originWorld: SIMD3<Float>,
                     sizeWorld: SIMD3<Float> = SIMD3(8.0, 4.0, 8.0),
                     splatRadius: Float = 1.25) -> EnvironmentSDFGrid? {
        guard triangles.count >= 3,
              originWorld.x.isFinite, originWorld.y.isFinite, originWorld.z.isFinite,
              sizeWorld.x.isFinite, sizeWorld.y.isFinite, sizeWorld.z.isFinite,
              sizeWorld.x > 0, sizeWorld.y > 0, sizeWorld.z > 0,
              splatRadius.isFinite, splatRadius >= 0,
              let grid = EnvironmentSDFGrid(device: device, originWorld: originWorld, sizeWorld: sizeWorld)
        else { return nil }

        // AR scene meshes are external input. Drop malformed and degenerate
        // faces before any Float→Int voxel conversion; NaN/Inf would otherwise
        // trap in optimized Swift and zero-area faces can produce NaN distances.
        var validTriangleOffsets: [Int] = []
        validTriangleOffsets.reserveCapacity(triangles.count / 3)
        for offset in stride(from: 0, to: triangles.count - 2, by: 3) {
            let a = triangles[offset], b = triangles[offset + 1], c = triangles[offset + 2]
            let finite = a.x.isFinite && a.y.isFinite && a.z.isFinite
                && b.x.isFinite && b.y.isFinite && b.z.isFinite
                && c.x.isFinite && c.y.isFinite && c.z.isFinite
            guard finite else { continue }
            let areaSquared = simd_length_squared(simd_cross(b - a, c - a))
            guard areaSquared.isFinite, areaSquared > 1e-12 else { continue }
            validTriangleOffsets.append(offset)
        }
        guard let firstOffset = validTriangleOffsets.first else { return nil }

        // Containment AABB = tight bounds of the scanned triangle soup (≈ the
        // room extent — walls/floor/ceiling dominate). Fixes the scrunch's
        // outside-shell/doubling by giving the shader a hard room boundary.
        var lo = triangles[firstOffset], hi = triangles[firstOffset]
        for offset in validTriangleOffsets {
            lo = simd_min(lo, simd_min(triangles[offset], simd_min(triangles[offset + 1], triangles[offset + 2])))
            hi = simd_max(hi, simd_max(triangles[offset], simd_max(triangles[offset + 1], triangles[offset + 2])))
        }
        grid.surfaceMinWorld = lo
        grid.surfaceMaxWorld = hi
        let cell = grid.cellSize
        let v = grid.values
        for i in 0..<(dim * dim * dim) { v[i] = Self.floatToHalfBits(clampFar) }

        let zeroIndex = SIMD3<Float>(repeating: 0)
        let maxIndex = SIMD3<Float>(repeating: Float(dim - 1))
        for offset in validTriangleOffsets {
            let a = triangles[offset], b = triangles[offset + 1], c = triangles[offset + 2]
            let lo = simd_min(simd_min(a, b), c) - splatRadius
            let hi = simd_max(simd_max(a, b), c) + splatRadius
            let loGrid = (lo - originWorld) / cell
            let hiGrid = (hi - originWorld) / cell
            guard hiGrid.x >= 0, hiGrid.y >= 0, hiGrid.z >= 0,
                  loGrid.x <= maxIndex.x, loGrid.y <= maxIndex.y, loGrid.z <= maxIndex.z
            else { continue }
            // Clamp while still in Float space. Converting an out-of-range
            // Float (or NaN) directly to Int32 is a trapping operation in Swift.
            let loI = SIMD3<Int32>(simd_clamp(loGrid, zeroIndex, maxIndex))
            let hiI = SIMD3<Int32>(simd_clamp(hiGrid, zeroIndex, maxIndex))
            guard loI.x <= hiI.x, loI.y <= hiI.y, loI.z <= hiI.z else { continue }
            for z in Int(loI.z)...Int(hiI.z) {
                for y in Int(loI.y)...Int(hiI.y) {
                    for x in Int(loI.x)...Int(hiI.x) {
                        let idx = (z * dim + y) * dim + x
                        let p = originWorld + (SIMD3<Float>(Float(x), Float(y), Float(z)) + 0.5) * cell
                        let d = pointTriangleDistance(p, a, b, c)
                        if d < Self.halfBitsToFloat(v[idx]) {
                            v[idx] = Self.floatToHalfBits(max(d, 0))
                        }
                    }
                }
            }
        }
        return grid
    }

    /// Exact unsigned point→triangle distance (Ericson, Real-Time Collision
    /// Detection §5.1.5 — closest point via barycentric region tests).
    static func pointTriangleDistance(_ p: SIMD3<Float>,
                                      _ a: SIMD3<Float>,
                                      _ b: SIMD3<Float>,
                                      _ c: SIMD3<Float>) -> Float {
        let ab = b - a, ac = c - a, ap = p - a
        let d1 = simd_dot(ab, ap), d2 = simd_dot(ac, ap)
        if d1 <= 0 && d2 <= 0 { return simd_length(p - a) }
        let bp = p - b
        let d3 = simd_dot(ab, bp), d4 = simd_dot(ac, bp)
        if d3 >= 0 && d4 <= d3 { return simd_length(p - b) }
        let vc = d1 * d4 - d3 * d2
        if vc <= 0 && d1 >= 0 && d3 <= 0 {
            let t = d1 / (d1 - d3)
            return simd_length(p - (a + ab * t))
        }
        let cp = p - c
        let d5 = simd_dot(ab, cp), d6 = simd_dot(ac, cp)
        if d6 >= 0 && d5 <= d6 { return simd_length(p - c) }
        let vb = d5 * d2 - d1 * d6
        if vb <= 0 && d2 >= 0 && d6 <= 0 {
            let t = d2 / (d2 - d6)
            return simd_length(p - (a + ac * t))
        }
        let va = d3 * d6 - d5 * d4
        if va <= 0 && (d4 - d3) >= 0 && (d5 - d6) >= 0 {
            let t = (d4 - d3) / ((d4 - d3) + (d5 - d6))
            return simd_length(p - (b + (c - b) * t))
        }
        let denom = 1.0 / (va + vb + vc)
        let closest = a + ab * (vb * denom) + ac * (vc * denom)
        return simd_length(p - closest)
    }

    private static func floatToHalfBits(_ value: Float) -> UInt16 {
        let bits = value.bitPattern
        let sign = UInt16((bits >> 16) & 0x8000)
        let exponent = Int((bits >> 23) & 0xff) - 127 + 15
        let mantissa = bits & 0x7fffff

        if exponent <= 0 {
            guard exponent >= -10 else { return sign }
            let shifted = (mantissa | 0x800000) >> UInt32(1 - exponent)
            return sign | UInt16((shifted + 0x1000) >> 13)
        }
        if exponent >= 31 {
            return sign | 0x7c00
        }

        var roundedMantissa = (mantissa + 0x1000) >> 13
        var roundedExponent = exponent
        if roundedMantissa == 0x400 {
            roundedMantissa = 0
            roundedExponent += 1
            if roundedExponent >= 31 {
                return sign | 0x7c00
            }
        }
        return sign | UInt16(roundedExponent << 10) | UInt16(roundedMantissa)
    }

    private static func halfBitsToFloat(_ bits: UInt16) -> Float {
        let sign = UInt32(bits & 0x8000) << 16
        var exponent = Int((bits >> 10) & 0x1f)
        var mantissa = UInt32(bits & 0x03ff)

        if exponent == 0 {
            if mantissa == 0 {
                return Float(bitPattern: sign)
            }
            while (mantissa & 0x0400) == 0 {
                mantissa <<= 1
                exponent -= 1
            }
            exponent += 1
            mantissa &= 0x03ff
        } else if exponent == 31 {
            return Float(bitPattern: sign | 0x7f800000 | (mantissa << 13))
        }

        let floatExponent = UInt32(exponent + (127 - 15)) << 23
        return Float(bitPattern: sign | floatExponent | (mantissa << 13))
    }
}
