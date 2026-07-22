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

/// A gravity-aligned rectangular approximation of the sensed room. `yawRadians`
/// rotates the room's local X axis in the world XZ plane; Y remains aligned to
/// gravity. Bound to Space uses this instead of assuming that the AR session
/// origin is the room center or that the room walls follow world X/Z.
struct EnvironmentRoomBounds: Sendable, Equatable {
    var centerWorld: SIMD3<Float>
    var sizeWorld: SIMD3<Float>
    var yawRadians: Float

    static func manual(sizeWorld: SIMD3<Float>) -> EnvironmentRoomBounds {
        let safeSize = simd_max(sizeWorld, SIMD3<Float>(repeating: 0.01))
        return EnvironmentRoomBounds(
            centerWorld: SIMD3<Float>(0, safeSize.y * 0.5, 0),
            sizeWorld: safeSize,
            yawRadians: 0
        )
    }

    /// World meters -> room-local meters, with the room centered at the local
    /// origin. The shader can therefore clip against `+-sizeWorld / 2`.
    var worldToRoomMatrix: matrix_float4x4 {
        let c = cos(yawRadians)
        let s = sin(yawRadians)
        let axisX = SIMD3<Float>(c, 0, s)
        let axisZ = SIMD3<Float>(-s, 0, c)
        return matrix_float4x4(columns: (
            SIMD4<Float>(c, 0, -s, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(s, 0, c, 0),
            SIMD4<Float>(-simd_dot(centerWorld, axisX),
                         -centerWorld.y,
                         -simd_dot(centerWorld, axisZ),
                         1)
        ))
    }

    /// Fits a gravity-aligned oriented box to triangle soup. Dominant vertical
    /// triangle normals establish the two orthogonal wall axes. Trimmed
    /// projected extents reject sparse reconstruction outliers while keeping
    /// the enclosing room surfaces. Returns nil for partial scans that do not
    /// yet establish a usable footprint and floor-to-ceiling height.
    static func estimateRectangularRoom(
        triangles: [SIMD3<Float>],
        trimFraction: Float = 0.0025
    ) -> EnvironmentRoomBounds? {
        guard triangles.count >= 3 else { return nil }

        var orientationCos: Float = 0
        var orientationSin: Float = 0
        var verticalArea: Float = 0
        for offset in stride(from: 0, to: triangles.count - 2, by: 3) {
            let a = triangles[offset]
            let b = triangles[offset + 1]
            let c = triangles[offset + 2]
            guard a.allFinite, b.allFinite, c.allFinite else { continue }
            let cross = simd_cross(b - a, c - a)
            let doubleArea = simd_length(cross)
            guard doubleArea.isFinite, doubleArea > 1e-6 else { continue }
            let normal = cross / doubleArea
            // Walls are nearly vertical. Four-angle averaging makes both
            // opposite normals and the perpendicular wall pair agree.
            guard abs(normal.y) < 0.35 else { continue }
            let area = doubleArea * 0.5
            let theta = atan2(normal.z, normal.x)
            orientationCos += area * cos(4 * theta)
            orientationSin += area * sin(4 * theta)
            verticalArea += area
        }

        let orientationStrength = hypot(orientationCos, orientationSin)
        let yaw: Float = verticalArea > 0.25 && orientationStrength > verticalArea * 0.08
            ? atan2(orientationSin, orientationCos) * 0.25
            : 0
        let axisX = SIMD2<Float>(cos(yaw), sin(yaw))
        let axisZ = SIMD2<Float>(-sin(yaw), cos(yaw))

        // Scene meshes can contain hundreds of thousands of repeated triangle
        // vertices. A uniform bounded sample keeps sorting cost predictable on
        // Vision Pro while retaining coverage across the anchor stream.
        let maxSamples = 12_000
        let sampleStride = max(1, triangles.count / maxSamples)
        var xs: [Float] = []
        var ys: [Float] = []
        var zs: [Float] = []
        xs.reserveCapacity(min(triangles.count, maxSamples))
        ys.reserveCapacity(min(triangles.count, maxSamples))
        zs.reserveCapacity(min(triangles.count, maxSamples))
        var index = 0
        while index < triangles.count {
            let point = triangles[index]
            if point.allFinite {
                let xz = SIMD2<Float>(point.x, point.z)
                xs.append(simd_dot(xz, axisX))
                ys.append(point.y)
                zs.append(simd_dot(xz, axisZ))
            }
            index += sampleStride
        }
        guard xs.count >= 24 else { return nil }
        xs.sort(); ys.sort(); zs.sort()

        let trim = max(0, min(0.04, trimFraction))
        func trimmedRange(_ values: [Float]) -> (Float, Float) {
            let last = values.count - 1
            let inset = min(last / 3, Int(Float(last) * trim))
            return (values[inset], values[last - inset])
        }
        var (minX, maxX) = trimmedRange(xs)
        var (minY, maxY) = trimmedRange(ys)
        var (minZ, maxZ) = trimmedRange(zs)

        // Pull the virtual boundary just inside the reconstructed wall/ceiling
        // surfaces. This suppresses the thin outside shell caused by mesh noise
        // without noticeably shrinking the usable room.
        let wallInset: Float = 0.025
        let ceilingInset: Float = 0.025
        minX += wallInset; maxX -= wallInset
        minZ += wallInset; maxZ -= wallInset
        maxY -= ceilingInset

        let size = SIMD3<Float>(maxX - minX, maxY - minY, maxZ - minZ)
        guard size.allFinite,
              size.x >= 0.8, size.y >= 1.6, size.z >= 0.8,
              size.x <= 40, size.y <= 12, size.z <= 40
        else { return nil }

        let centerX = (minX + maxX) * 0.5
        let centerZ = (minZ + maxZ) * 0.5
        let centerXZ = axisX * centerX + axisZ * centerZ
        return EnvironmentRoomBounds(
            centerWorld: SIMD3<Float>(centerXZ.x, (minY + maxY) * 0.5, centerXZ.y),
            sizeWorld: size,
            yawRadians: yaw
        )
    }

    /// Smooths normal reconstruction refinement while treating a 90-degree axis
    /// relabel as the same rectangle (and swapping width/depth accordingly).
    func blended(toward candidate: EnvironmentRoomBounds, alpha: Float) -> EnvironmentRoomBounds {
        let t = max(0, min(1, alpha))
        var alignedYaw = candidate.yawRadians
        var alignedSize = candidate.sizeWorld
        let quarterTurn = Float.pi * 0.5
        while alignedYaw - yawRadians > Float.pi * 0.25 {
            alignedYaw -= quarterTurn
            alignedSize = SIMD3<Float>(alignedSize.z, alignedSize.y, alignedSize.x)
        }
        while alignedYaw - yawRadians < -Float.pi * 0.25 {
            alignedYaw += quarterTurn
            alignedSize = SIMD3<Float>(alignedSize.z, alignedSize.y, alignedSize.x)
        }
        return EnvironmentRoomBounds(
            centerWorld: simd_mix(centerWorld, candidate.centerWorld, SIMD3<Float>(repeating: t)),
            sizeWorld: simd_mix(sizeWorld, alignedSize, SIMD3<Float>(repeating: t)),
            yawRadians: yawRadians + (alignedYaw - yawRadians) * t
        )
    }

    func isMeaningfullyDifferent(from other: EnvironmentRoomBounds) -> Bool {
        simd_length(centerWorld - other.centerWorld) > 0.02
            || simd_length(sizeWorld - other.sizeWorld) > 0.03
            || abs(yawRadians - other.yawRadians) > (.pi / 180)
    }
}

private extension SIMD3 where Scalar == Float {
    var allFinite: Bool { x.isFinite && y.isFinite && z.isFinite }
}

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
