import simd

enum Mandelbox {
    struct Params: Sendable {
        var minRad2: Float
        var fractalScale: Float
        var foldingLimit: Float
        var sphereRadius: Float
        var iterations: Int
        var escapeRadius2: Float

        init(
            minRad2: Float,
            fractalScale: Float,
            foldingLimit: Float,
            sphereRadius: Float,
            iterations: Int,
            escapeRadius2: Float = 1000
        ) {
            self.minRad2 = minRad2
            self.fractalScale = fractalScale
            self.foldingLimit = foldingLimit
            self.sphereRadius = sphereRadius
            self.iterations = iterations
            self.escapeRadius2 = escapeRadius2
        }
    }

    // Baseline Map: mirrors `Shaders.metal` structure.
    static func mapBaseline(_ pos: SIMD3<Float>, _ p: Params) -> Float {
        let minRad2 = p.minRad2
        let scaleW = abs(p.fractalScale) / minRad2
        let scaleXYZ = SIMD3<Float>(repeating: p.fractalScale / minRad2)
        let absScalem1 = abs(p.fractalScale - 1)
        let absScaleRaisedTo1mIters = pow(abs(p.fractalScale), Float(1 - p.iterations))
        let minRadius2 = p.sphereRadius * p.sphereRadius

        var xyz = pos
        var w: Float = 1
        let p0 = pos

        for _ in 0..<p.iterations {
            // Box fold
            xyz = clamp(xyz, -p.foldingLimit, p.foldingLimit) * 2 - xyz

            // Sphere fold
            let r2 = simd_dot(xyz, xyz)
            let t = clamp(1 / max(r2, minRadius2), 1, 1 / minRadius2)
            xyz *= t
            w *= t

            // Scale + translate
            xyz = xyz * scaleXYZ + p0
            w *= scaleW
        }

        return (simd_length(xyz) - absScalem1) / w - absScaleRaisedTo1mIters
    }

    // Early-escape variant: breaks once r2 is large (outside), approximating remaining iterations.
    static func mapEarlyEscape(_ pos: SIMD3<Float>, _ p: Params) -> Float {
        let minRad2 = p.minRad2
        let scaleW = abs(p.fractalScale) / minRad2
        let scaleXYZ = SIMD3<Float>(repeating: p.fractalScale / minRad2)
        let absScalem1 = abs(p.fractalScale - 1)
        let minRadius2 = p.sphereRadius * p.sphereRadius

        var xyz = pos
        var w: Float = 1
        let p0 = pos

        var i = 0
        while i < p.iterations {
            xyz = clamp(xyz, -p.foldingLimit, p.foldingLimit) * 2 - xyz
            let r2 = simd_dot(xyz, xyz)
            if r2 > p.escapeRadius2 {
                // Approximate the tail term using the current step count.
                let tail = pow(abs(p.fractalScale), Float(1 - (i + 1)))
                return (sqrt(r2) - absScalem1) / w - tail
            }

            let t = clamp(1 / max(r2, minRadius2), 1, 1 / minRadius2)
            xyz *= t
            w *= t

            xyz = xyz * scaleXYZ + p0
            w *= scaleW
            i += 1
        }

        let absScaleRaisedTo1mIters = pow(abs(p.fractalScale), Float(1 - p.iterations))
        return (simd_length(xyz) - absScalem1) / w - absScaleRaisedTo1mIters
    }

    // Two-pass variant: cheap coarse iterations; only refine if coarse says “near”.
    static func mapTwoPass(_ pos: SIMD3<Float>, coarseIters: Int, fineIters: Int, nearThreshold: Float, base: Params) -> Float {
        var coarse = base
        coarse.iterations = coarseIters
        let d0 = mapEarlyEscape(pos, coarse)
        if abs(d0) > nearThreshold {
            return d0
        }
        var fine = base
        fine.iterations = fineIters
        return mapEarlyEscape(pos, fine)
    }

    // “Fast float” variant: uses a few micro-optimizations (no pow in hot loop, less work).
    // Still same math shape; it’s primarily a CPU benchmark baseline.
    static func mapFastFloat(_ pos: SIMD3<Float>, _ p: Params) -> Float {
        let minRad2 = p.minRad2
        let invMinRad2 = 1 / minRad2
        let scaleXYZ = SIMD3<Float>(repeating: p.fractalScale * invMinRad2)
        let scaleW = abs(p.fractalScale) * invMinRad2
        let absScalem1 = abs(p.fractalScale - 1)
        let minRadius2 = p.sphereRadius * p.sphereRadius

        var xyz = pos
        var w: Float = 1
        let p0 = pos

        for _ in 0..<p.iterations {
            // manual clamp for CPU speed
            let lo = SIMD3<Float>(repeating: -p.foldingLimit)
            let hi = SIMD3<Float>(repeating: p.foldingLimit)
            xyz = simd_min(simd_max(xyz, lo), hi) * 2 - xyz

            let r2 = simd_dot(xyz, xyz)
            let inv = 1 / max(r2, minRadius2)
            // clamp(inv, 1, 1/minRadius2)
            let t = max(1, min(inv, 1 / minRadius2))
            xyz *= t
            w *= t

            xyz = xyz * scaleXYZ + p0
            w *= scaleW
        }

        let absScaleRaisedTo1mIters = pow(abs(p.fractalScale), Float(1 - p.iterations))
        return (simd_length(xyz) - absScalem1) / w - absScaleRaisedTo1mIters
    }

    // Escape classifier: returns true if orbit exceeds escapeRadius2 within `iterations`.
    static func escapes(_ pos: SIMD3<Float>, _ p: Params) -> Bool {
        let minRad2 = p.minRad2
        let scaleXYZ = SIMD3<Float>(repeating: p.fractalScale / minRad2)
        let minRadius2 = p.sphereRadius * p.sphereRadius

        var xyz = pos
        let p0 = pos

        for _ in 0..<p.iterations {
            xyz = clamp(xyz, -p.foldingLimit, p.foldingLimit) * 2 - xyz
            let r2 = simd_dot(xyz, xyz)
            if !r2.isFinite || r2 > p.escapeRadius2 { return true }
            let t = clamp(1 / max(r2, minRadius2), 1, 1 / minRadius2)
            xyz *= t
            xyz = xyz * scaleXYZ + p0
        }
        return false
    }
}

@inline(__always)
private func clamp(_ x: SIMD3<Float>, _ lo: Float, _ hi: Float) -> SIMD3<Float> {
    simd_min(simd_max(x, SIMD3<Float>(repeating: lo)), SIMD3<Float>(repeating: hi))
}

@inline(__always)
private func clamp(_ x: Float, _ lo: Float, _ hi: Float) -> Float {
    max(lo, min(x, hi))
}
