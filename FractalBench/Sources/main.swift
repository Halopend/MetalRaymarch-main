import Foundation
import simd

do {
    let opt = try CLI.parse()

        // Build reference evaluator
        let refParams = Mandelbox.Params(
            minRad2: opt.minRad2,
            fractalScale: opt.fractalScale,
            foldingLimit: opt.foldingLimit,
            sphereRadius: opt.sphereRadius,
            iterations: opt.referenceIterations,
            escapeRadius2: opt.escapeRadius2
        )
        let referenceEval: (SIMD3<Float>) -> Float = { p in
            Mandelbox.mapBaseline(p, refParams)
        }

        let extent: Float = 2.2

        // Base params for test algorithms
        let base = Mandelbox.Params(
            minRad2: opt.minRad2,
            fractalScale: opt.fractalScale,
            foldingLimit: opt.foldingLimit,
            sphereRadius: opt.sphereRadius,
            iterations: opt.testIterations,
            escapeRadius2: opt.escapeRadius2
        )

        var rows: [String] = []
        rows.reserveCapacity(opt.algorithms.count)

        if opt.mode == "map" {
            // Create point set
            let generated: PointSets.Generated
            switch opt.pointSet {
            case "grid":
                generated = PointSets.makeGrid(countPerAxis: 40, extent: extent)
            case "random":
                generated = PointSets.makeRandom(count: opt.samples, seed: opt.seed, extent: extent)
            case "near-surface":
                let escapeParams = Mandelbox.Params(
                    minRad2: opt.minRad2,
                    fractalScale: opt.fractalScale,
                    foldingLimit: opt.foldingLimit,
                    sphereRadius: opt.sphereRadius,
                    iterations: opt.referenceIterations,
                    escapeRadius2: opt.escapeRadius2
                )
                let escapeEval: (SIMD3<Float>) -> Bool = { p in
                    Mandelbox.escapes(p, escapeParams)
                }
                generated = PointSets.makeNearSurfaceByRays(
                    seed: opt.seed,
                    count: opt.nearSurfaceTargetCount,
                    maxRadius: extent,
                    escape: escapeEval,
                    referenceDE: referenceEval
                )
                if generated.points.isEmpty {
                    throw NSError(
                        domain: "PointSets",
                        code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "Near-surface generation failed. Ensure the origin is inside the fractal."]
                    )
                }
            default:
                throw NSError(domain: "Main", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unknown pointSet: \(opt.pointSet)"])
            }

            let points: [SIMD3<Float>] = Array(generated.points.prefix(opt.samples))
            // Compute reference for error stats
            var refDE: [Float] = []
            refDE.reserveCapacity(points.count)
            for p in points { refDE.append(referenceEval(p)) }

            for alg in opt.algorithms {
                let eval: (SIMD3<Float>) -> Float
                let itersUsed: Int

                switch alg {
                case "baseline":
                    eval = { Mandelbox.mapBaseline($0, base) }
                    itersUsed = base.iterations
                case "earlyEscape":
                    eval = { Mandelbox.mapEarlyEscape($0, base) }
                    itersUsed = base.iterations
                case "twoPass":
                    let coarse = max(2, min(6, base.iterations))
                    let fine = max(coarse, base.iterations)
                    let near = max(0.001, opt.nearSurfaceMaxAbsDE * 2)
                    eval = { Mandelbox.mapTwoPass($0, coarseIters: coarse, fineIters: fine, nearThreshold: near, base: base) }
                    itersUsed = fine
                case "fastFloat":
                    eval = { Mandelbox.mapFastFloat($0, base) }
                    itersUsed = base.iterations
                default:
                    throw NSError(domain: "Main", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unknown algorithm: \(alg)"])
                }

                let (nsTotal, sink) = Benchmark.time(name: alg, points: points, warmup: opt.warmupSamples, eval: eval)
                _ = sink

                var pred: [Float] = []
                pred.reserveCapacity(points.count)
                for p in points { pred.append(eval(p)) }
                let stats = Benchmark.errorStats(pred: pred, ref: refDE)

                let row = Benchmark.ResultRow(
                    timestampISO8601: Benchmark.nowISO8601(),
                    mode: "map",
                    algorithm: alg,
                    pointSet: generated.name,
                    points: points.count,
                    warmup: min(opt.warmupSamples, points.count),
                    iters: itersUsed,
                    refIters: opt.referenceIterations,
                    minRad2: opt.minRad2,
                    scale: opt.fractalScale,
                    foldingLimit: opt.foldingLimit,
                    sphereRadius: opt.sphereRadius,
                    escapeR2: opt.escapeRadius2,
                    rays: 0,
                    hits: 0,
                    avgStepsPerRay: 0,
                    avgMapCallsPerRay: 0,
                    tMeanAbsErr: 0,
                    tMaxAbsErr: 0,
                    nsTotal: nsTotal,
                    nsPerEval: Double(nsTotal) / Double(max(points.count, 1)),
                    mae: stats.mae,
                    rmse: stats.rmse,
                    maxAbsErr: stats.maxAbsErr,
                    signMismatchRate: stats.signMismatchRate,
                    usedFraction: stats.usedFraction
                ).toCSV()
                rows.append(row)
            }
        } else if opt.mode == "ray" {
            let raysAll = Rays.makeSphereInward(count: opt.rays, seed: opt.seed, originRadius: opt.originRadius)

            let refMapParams = Mandelbox.Params(
                minRad2: opt.minRad2,
                fractalScale: opt.fractalScale,
                foldingLimit: opt.foldingLimit,
                sphereRadius: opt.sphereRadius,
                iterations: opt.referenceIterations,
                escapeRadius2: opt.escapeRadius2
            )
            let refMap: (SIMD3<Float>) -> Float = { Mandelbox.mapBaseline($0, refMapParams) }
            let refSettings = Raymarch.Settings(
                tMin: opt.tMin,
                tMax: opt.tMax,
                hitThreshold: max(opt.hitThreshold * 0.5, 1e-6),
                maxSteps: max(opt.maxRaySteps * 2, opt.maxRaySteps),
                omega: 1.0
            )

            // Reference hit distances
            var refT: [Float] = []
            refT.reserveCapacity(raysAll.count)
            for r in raysAll {
                let tr = Raymarch.trace(origin: r.origin, dir: r.dir, map: refMap, settings: refSettings)
                refT.append(tr.hit ? tr.t : Float.nan)
            }

            let settings = Raymarch.Settings(tMin: opt.tMin, tMax: opt.tMax, hitThreshold: opt.hitThreshold, maxSteps: opt.maxRaySteps, omega: opt.omega)

            for alg in opt.algorithms {
                let mapEval: (SIMD3<Float>) -> Float
                let itersUsed: Int
                switch alg {
                case "baseline":
                    mapEval = { Mandelbox.mapBaseline($0, base) }
                    itersUsed = base.iterations
                case "earlyEscape":
                    mapEval = { Mandelbox.mapEarlyEscape($0, base) }
                    itersUsed = base.iterations
                case "twoPass":
                    let coarse = max(2, min(6, base.iterations))
                    let fine = max(coarse, base.iterations)
                    let near: Float = 0.01
                    mapEval = { Mandelbox.mapTwoPass($0, coarseIters: coarse, fineIters: fine, nearThreshold: near, base: base) }
                    itersUsed = fine
                case "fastFloat":
                    mapEval = { Mandelbox.mapFastFloat($0, base) }
                    itersUsed = base.iterations
                default:
                    throw NSError(domain: "Main", code: 3, userInfo: [NSLocalizedDescriptionKey: "Unknown algorithm: \(alg)"])
                }

                // Warmup
                let warmCount = min(opt.warmupSamples, raysAll.count)
                var warmSink: Float = 0
                if warmCount > 0 {
                    for i in 0..<warmCount {
                        let r = raysAll[i]
                        let tr = Raymarch.trace(origin: r.origin, dir: r.dir, map: mapEval, settings: settings)
                        warmSink += tr.t
                    }
                }
                _ = warmSink

                let start = DispatchTime.now().uptimeNanoseconds
                var hits = 0
                var stepsSum: Int = 0
                var callsSum: Int = 0
                var sink: Float = 0

                var tAbsErrSum: Double = 0
                var tAbsErrMax: Double = 0
                var used = 0

                for (idx, r) in raysAll.enumerated() {
                    let tr = Raymarch.trace(origin: r.origin, dir: r.dir, map: mapEval, settings: settings)
                    sink += tr.t
                    if tr.hit { hits += 1 }
                    stepsSum += tr.steps
                    callsSum += tr.mapCalls

                    let rt = refT[idx]
                    if tr.hit, rt.isFinite {
                        let ae = Double(abs(tr.t - rt))
                        tAbsErrSum += ae
                        tAbsErrMax = max(tAbsErrMax, ae)
                        used += 1
                    }
                }
                let end = DispatchTime.now().uptimeNanoseconds
                _ = sink

                let nsTotal = end - start
                let nRays = max(raysAll.count, 1)
                let tMeanAbsErr = used > 0 ? (tAbsErrSum / Double(used)) : 0

                let row = Benchmark.ResultRow(
                    timestampISO8601: Benchmark.nowISO8601(),
                    mode: "ray",
                    algorithm: alg,
                    pointSet: "sphere-inward",
                    points: 0,
                    warmup: warmCount,
                    iters: itersUsed,
                    refIters: opt.referenceIterations,
                    minRad2: opt.minRad2,
                    scale: opt.fractalScale,
                    foldingLimit: opt.foldingLimit,
                    sphereRadius: opt.sphereRadius,
                    escapeR2: opt.escapeRadius2,
                    rays: raysAll.count,
                    hits: hits,
                    avgStepsPerRay: Double(stepsSum) / Double(nRays),
                    avgMapCallsPerRay: Double(callsSum) / Double(nRays),
                    tMeanAbsErr: tMeanAbsErr,
                    tMaxAbsErr: tAbsErrMax,
                    nsTotal: nsTotal,
                    nsPerEval: Double(nsTotal) / Double(nRays),
                    mae: 0,
                    rmse: 0,
                    maxAbsErr: 0,
                    signMismatchRate: 0,
                    usedFraction: raysAll.count > 0 ? Double(used) / Double(raysAll.count) : 0
                ).toCSV()
                rows.append(row)
            }
        } else {
            throw NSError(domain: "Main", code: 4, userInfo: [NSLocalizedDescriptionKey: "Unknown mode: \(opt.mode)"])
        }

    try CSV.write(path: opt.outputPath, header: Benchmark.ResultRow.header, rows: rows)
    print("Wrote \(rows.count) rows to \(opt.outputPath) (mode=\(opt.mode)).")
} catch {
    fputs("Error: \(error)\n", stderr)
    CLI.printUsage()
    exit(1)
}
