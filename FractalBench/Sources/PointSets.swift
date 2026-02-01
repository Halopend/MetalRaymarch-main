import simd

enum PointSets {
    struct Generated {
        var name: String
        var points: [SIMD3<Float>]
        var referenceDE: [Float]?
    }

    static func makeGrid(countPerAxis: Int, extent: Float) -> Generated {
        let n = max(countPerAxis, 2)
        let step = (2 * extent) / Float(n - 1)
        var pts: [SIMD3<Float>] = []
        pts.reserveCapacity(n * n * n)
        for z in 0..<n {
            for y in 0..<n {
                for x in 0..<n {
                    pts.append(SIMD3<Float>(
                        -extent + Float(x) * step,
                        -extent + Float(y) * step,
                        -extent + Float(z) * step
                    ))
                }
            }
        }
        return Generated(name: "grid", points: pts, referenceDE: nil)
    }

    static func makeRandom(count: Int, seed: UInt64, extent: Float) -> Generated {
        var rng = SplitMix64(seed: seed)
        var pts: [SIMD3<Float>] = []
        pts.reserveCapacity(count)
        for _ in 0..<count {
            pts.append(SIMD3<Float>(
                rng.nextFloat(-extent, extent),
                rng.nextFloat(-extent, extent),
                rng.nextFloat(-extent, extent)
            ))
        }
        return Generated(name: "random", points: pts, referenceDE: nil)
    }

    // Generates near-surface points by shooting rays from the origin and bracketing the
    // inside/outside transition using an escape classifier (no DE needed).
    static func makeNearSurfaceByRays(
        seed: UInt64,
        count: Int,
        maxRadius: Float,
        escape: (SIMD3<Float>) -> Bool,
        referenceDE: (SIMD3<Float>) -> Float
    ) -> Generated {
        var rng = SplitMix64(seed: seed)

        var pts: [SIMD3<Float>] = []
        var ref: [Float] = []
        pts.reserveCapacity(count)
        ref.reserveCapacity(count)

        func randomDirection() -> SIMD3<Float> {
            // Rejection sample for roughly uniform directions.
            while true {
                let v = SIMD3<Float>(
                    rng.nextFloat(-1, 1),
                    rng.nextFloat(-1, 1),
                    rng.nextFloat(-1, 1)
                )
                let l2 = simd_dot(v, v)
                if l2 > 1e-6, l2 <= 1 { return v / sqrt(l2) }
            }
        }

        // Assume the origin is inside; if not, the near-surface bracket will fail.
        if escape(.zero) {
            return Generated(name: "near-surface", points: [], referenceDE: [])
        }

        var attempts = 0
        while pts.count < count, attempts < count * 50 {
            attempts += 1
            let dir = randomDirection()

            var rIn: Float = 0
            var rOut: Float? = nil
            var r: Float = 0.05

            // Expand until we escape or hit maxRadius.
            while r <= maxRadius {
                let p = dir * r
                if escape(p) {
                    rOut = r
                    break
                }
                rIn = r
                r *= 1.25
            }

            guard let out = rOut, out > rIn else { continue }

            // Binary search boundary.
            var lo = rIn
            var hi = out
            for _ in 0..<22 {
                let mid = (lo + hi) * 0.5
                if escape(dir * mid) {
                    hi = mid
                } else {
                    lo = mid
                }
            }
            let hit = dir * ((lo + hi) * 0.5)
            let d = referenceDE(hit)
            if !d.isFinite { continue }

            pts.append(hit)
            ref.append(d)
        }

        return Generated(name: "near-surface", points: pts, referenceDE: ref)
    }
}
