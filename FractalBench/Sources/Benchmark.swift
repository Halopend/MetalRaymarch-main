import Foundation
import simd

enum Benchmark {
    struct ResultRow {
        var timestampISO8601: String
        var mode: String
        var algorithm: String
        var pointSet: String
        var points: Int
        var warmup: Int
        var iters: Int
        var refIters: Int
        var minRad2: Float
        var scale: Float
        var foldingLimit: Float
        var sphereRadius: Float
        var escapeR2: Float

        // Ray mode metrics (0 when mode==map)
        var rays: Int
        var hits: Int
        var avgStepsPerRay: Double
        var avgMapCallsPerRay: Double
        var tMeanAbsErr: Double
        var tMaxAbsErr: Double

        var nsTotal: UInt64
        var nsPerEval: Double

        // Error vs reference (when available)
        var mae: Double
        var rmse: Double
        var maxAbsErr: Double
        var signMismatchRate: Double
        var usedFraction: Double

        func toCSV() -> String {
            [
                timestampISO8601,
                mode,
                algorithm,
                pointSet,
                String(points),
                String(warmup),
                String(iters),
                String(refIters),
                String(minRad2),
                String(scale),
                String(foldingLimit),
                String(sphereRadius),
                String(escapeR2),

                String(rays),
                String(hits),
                String(format: "%.6g", avgStepsPerRay),
                String(format: "%.6g", avgMapCallsPerRay),
                String(format: "%.6g", tMeanAbsErr),
                String(format: "%.6g", tMaxAbsErr),

                String(nsTotal),
                String(format: "%.3f", nsPerEval),
                String(format: "%.6g", mae),
                String(format: "%.6g", rmse),
                String(format: "%.6g", maxAbsErr),
                String(format: "%.6g", signMismatchRate),
                String(format: "%.6g", usedFraction),
            ].joined(separator: ",")
        }

        static var header: String {
            "timestamp,mode,algorithm,pointSet,points,warmup,iters,refIters,minRad2,scale,foldingLimit,sphereRadius,escapeR2,rays,hits,avgStepsPerRay,avgMapCallsPerRay,tMeanAbsErr,tMaxAbsErr,nsTotal,nsPerEval,mae,rmse,maxAbsErr,signMismatchRate,usedFraction"
        }
    }

    static func time(
        name: String,
        points: [SIMD3<Float>],
        warmup: Int,
        eval: (SIMD3<Float>) -> Float
    ) -> (nsTotal: UInt64, sink: Float) {
        // Warmup
        var sink: Float = 0
        let warmCount = min(warmup, points.count)
        if warmCount > 0 {
            for i in 0..<warmCount {
                sink += eval(points[i])
            }
        }

        let start = DispatchTime.now().uptimeNanoseconds
        for p in points {
            sink += eval(p)
        }
        let end = DispatchTime.now().uptimeNanoseconds
        return (end - start, sink)
    }

    static func errorStats(pred: [Float], ref: [Float]) -> (mae: Double, rmse: Double, maxAbsErr: Double, signMismatchRate: Double, usedFraction: Double) {
        precondition(pred.count == ref.count)
        let n = pred.count
        if n == 0 { return (0, 0, 0, 0, 0) }

        var sumAbs: Double = 0
        var sumSq: Double = 0
        var maxAbs: Double = 0
        var signMismatch: Int = 0

        var used = 0
        for i in 0..<n {
            let a = pred[i]
            let b = ref[i]
            if !a.isFinite || !b.isFinite { continue }

            let e = Double(a - b)
            let ae = abs(e)
            sumAbs += ae
            sumSq += e * e
            maxAbs = max(maxAbs, ae)

            let s1 = a >= 0
            let s2 = b >= 0
            if s1 != s2 { signMismatch += 1 }

            used += 1
        }

        if used == 0 { return (0, 0, 0, 0, 0) }
        return (
            mae: sumAbs / Double(used),
            rmse: sqrt(sumSq / Double(used)),
            maxAbsErr: maxAbs,
            signMismatchRate: Double(signMismatch) / Double(used),
            usedFraction: Double(used) / Double(n)
        )
    }

    static func nowISO8601() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}
