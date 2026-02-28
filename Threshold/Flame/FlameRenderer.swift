import Foundation
import CoreGraphics
import simd

enum FlameRenderer {
    struct Output {
        let image: CGImage
        let sampleCount: Int
    }

    static func render(
        flame: FlameDocument,
        width: Int = 640,
        height: Int = 640,
        iterations: Int = 1_300_000,
        burnIn: Int = 24_000
    ) -> Output? {
        guard !flame.transforms.isEmpty, width > 0, height > 0 else { return nil }

        let transforms = flame.transforms
        let cumulative = cumulativeWeights(for: transforms)
        guard let totalWeight = cumulative.last, totalWeight > 0 else { return nil }

        let accepted = max(64_000, iterations - burnIn)
        var xs = [Float]()
        var ys = [Float]()
        var cs = [Float]()
        xs.reserveCapacity(accepted)
        ys.reserveCapacity(accepted)
        cs.reserveCapacity(accepted)

        var rng = LCG(seed: 0xC0FFEE)
        var p = SIMD2<Float>(0, 0)
        var color: Float = 0.5

        for i in 0..<iterations {
            let transform = chooseTransform(transforms: transforms, cumulative: cumulative, totalWeight: totalWeight, rng: &rng)
            p = apply(transform: transform, to: p)
            color = 0.5 * color + 0.5 * transform.color
            if i >= burnIn {
                xs.append(p.x)
                ys.append(p.y)
                cs.append(color)
            }
        }

        guard !xs.isEmpty else { return nil }

        var minX = xs[0], maxX = xs[0], minY = ys[0], maxY = ys[0]
        for i in 1..<xs.count {
            minX = min(minX, xs[i]); maxX = max(maxX, xs[i])
            minY = min(minY, ys[i]); maxY = max(maxY, ys[i])
        }

        let spanX = max(1e-4, maxX - minX)
        let spanY = max(1e-4, maxY - minY)
        let scale = min(Float(width) / spanX, Float(height) / spanY) * 0.92
        let centerX = 0.5 * (minX + maxX)
        let centerY = 0.5 * (minY + maxY)

        let pixelCount = width * height
        var density = [Float](repeating: 0, count: pixelCount)
        var rAcc = [Float](repeating: 0, count: pixelCount)
        var gAcc = [Float](repeating: 0, count: pixelCount)
        var bAcc = [Float](repeating: 0, count: pixelCount)

        for i in 0..<xs.count {
            let x = (xs[i] - centerX) * scale + Float(width) * 0.5
            let y = (ys[i] - centerY) * scale + Float(height) * 0.5
            let px = Int(x)
            let py = Int(y)
            if px < 0 || px >= width || py < 0 || py >= height { continue }
            let idx = py * width + px
            density[idx] += 1
            let rgb = colorFromHue(cs[i])
            rAcc[idx] += rgb.x
            gAcc[idx] += rgb.y
            bAcc[idx] += rgb.z
        }

        var maxDensity: Float = 0
        for d in density where d > maxDensity { maxDensity = d }
        guard maxDensity > 0 else { return nil }

        let invLogMax = 1.0 / log(1 + maxDensity)
        let gamma = max(0.1, flame.gamma)
        let brightness = max(0.01, flame.brightness)

        var rgba = [UInt8](repeating: 0, count: pixelCount * 4)
        for i in 0..<pixelCount {
            let d = density[i]
            if d <= 0 { continue }
            let alpha = log(1 + d) * invLogMax
            let inv = 1.0 / d
            let r = pow(max(0, rAcc[i] * inv * alpha * brightness), 1.0 / gamma)
            let g = pow(max(0, gAcc[i] * inv * alpha * brightness), 1.0 / gamma)
            let b = pow(max(0, bAcc[i] * inv * alpha * brightness), 1.0 / gamma)

            let o = i * 4
            rgba[o + 0] = UInt8(max(0, min(255, Int(r * 255))))
            rgba[o + 1] = UInt8(max(0, min(255, Int(g * 255))))
            rgba[o + 2] = UInt8(max(0, min(255, Int(b * 255))))
            rgba[o + 3] = 255
        }

        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            return nil
        }

        return Output(image: image, sampleCount: xs.count)
    }

    private static func cumulativeWeights(for transforms: [FlameTransform]) -> [Float] {
        var out = [Float]()
        out.reserveCapacity(transforms.count)
        var run: Float = 0
        for t in transforms {
            run += max(0, t.weight)
            out.append(run)
        }
        return out
    }

    private static func chooseTransform(
        transforms: [FlameTransform],
        cumulative: [Float],
        totalWeight: Float,
        rng: inout LCG
    ) -> FlameTransform {
        let target = rng.nextFloat() * totalWeight
        var lo = 0
        var hi = cumulative.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if cumulative[mid] < target { lo = mid + 1 } else { hi = mid }
        }
        return transforms[lo]
    }

    private static func apply(transform: FlameTransform, to p: SIMD2<Float>) -> SIMD2<Float> {
        let a = transform.affine
        let q = SIMD2<Float>(
            a.a * p.x + a.b * p.y + a.e,
            a.c * p.x + a.d * p.y + a.f
        )

        var out = SIMD2<Float>(repeating: 0)
        var totalWeight: Float = 0

        for (name, w) in transform.variations {
            guard w != 0 else { continue }
            totalWeight += abs(w)
            let v: SIMD2<Float>
            switch name {
            case "linear":
                v = q
            case "sinusoidal":
                v = SIMD2<Float>(sin(q.x), sin(q.y))
            case "spherical":
                let r2 = max(1e-6, q.x * q.x + q.y * q.y)
                v = q / r2
            case "swirl":
                let r2 = q.x * q.x + q.y * q.y
                let s = sin(r2)
                let c = cos(r2)
                v = SIMD2<Float>(q.x * s - q.y * c, q.x * c + q.y * s)
            case "horseshoe":
                let r = max(1e-6, sqrt(q.x * q.x + q.y * q.y))
                v = SIMD2<Float>((q.x - q.y) * (q.x + q.y) / r, 2 * q.x * q.y / r)
            default:
                v = q
            }
            out += v * w
        }

        if totalWeight <= 0 { return q }
        return out / totalWeight
    }

    private static func colorFromHue(_ hue: Float) -> SIMD3<Float> {
        let h = (hue - floor(hue)) * 6
        let i = Int(h)
        let f = h - Float(i)
        switch i {
        case 0: return SIMD3<Float>(1, f, 0)
        case 1: return SIMD3<Float>(1 - f, 1, 0)
        case 2: return SIMD3<Float>(0, 1, f)
        case 3: return SIMD3<Float>(0, 1 - f, 1)
        case 4: return SIMD3<Float>(f, 0, 1)
        default: return SIMD3<Float>(1, 0, 1 - f)
        }
    }
}

private struct LCG {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed == 0 ? 0x123456789abcdef : seed
    }

    mutating func nextUInt32() -> UInt32 {
        state = 6364136223846793005 &* state &+ 1
        return UInt32(truncatingIfNeeded: state >> 32)
    }

    mutating func nextFloat() -> Float {
        Float(nextUInt32()) / Float(UInt32.max)
    }
}
