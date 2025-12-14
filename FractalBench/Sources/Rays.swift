import simd

enum Rays {
    struct Ray {
        var origin: SIMD3<Float>
        var dir: SIMD3<Float>
    }

    // Deterministic rays: origins on a sphere, directions roughly toward the origin with small jitter.
    static func makeSphereInward(count: Int, seed: UInt64, originRadius: Float, jitter: Float = 0.02) -> [Ray] {
        var rng = SplitMix64(seed: seed)
        var rays: [Ray] = []
        rays.reserveCapacity(count)

        func randomDir() -> SIMD3<Float> {
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

        for _ in 0..<count {
            let onSphere = randomDir() * originRadius
            var dir = -onSphere
            // jitter to avoid all rays going through the exact center
            dir += SIMD3<Float>(
                rng.nextFloat(-jitter, jitter),
                rng.nextFloat(-jitter, jitter),
                rng.nextFloat(-jitter, jitter)
            )
            dir = simd_normalize(dir)
            rays.append(Ray(origin: onSphere, dir: dir))
        }

        return rays
    }
}
