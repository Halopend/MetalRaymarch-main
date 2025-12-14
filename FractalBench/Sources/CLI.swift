import Foundation

enum CLI {
    struct Options {
        var mode: String = "map" // map|ray

        var samples: Int = 200_000
        var warmupSamples: Int = 20_000
        var seed: UInt64 = 0xC0FFEE

        var pointSet: String = "near-surface"
        var outputPath: String = "fractalbench.csv"

        // Ray benchmark options
        var rays: Int = 200_000
        var originRadius: Float = 4.0
        var tMin: Float = 0.05
        var tMax: Float = 12.0
        var hitThreshold: Float = 0.0005
        var maxRaySteps: Int = 64
        var omega: Float = 1.2

        // Mandelbox params (match `Shaders.metal` defaults unless overridden)
        var minRad2: Float = 0.1    // `minDistance` in app/shader defaults
        var fractalScale: Float = 2.8
        var foldingLimit: Float = 1.0
        var sphereRadius: Float = 0.5

        var referenceIterations: Int = 12
        var testIterations: Int = 5

        var algorithms: [String] = ["baseline", "earlyEscape", "twoPass", "fastFloat"]

        var escapeRadius2: Float = 1000.0
        var nearSurfaceTargetCount: Int = 50_000
        var nearSurfacePool: Int = 800_000
        var nearSurfaceMaxAbsDE: Float = 0.002
    }

    static func printUsage() {
        let exe = (CommandLine.arguments.first as NSString?)?.lastPathComponent ?? "fractalbench"
        print("""
        Usage:
          \(exe) [options]

        Options:
                    --mode NAME                map|ray (default: map)

          --samples N                 Timed samples per algorithm (default: 200000)
          --warmup N                  Warmup samples per algorithm (default: 20000)
          --seed N                    RNG seed (default: 12648430)

          --pointSet NAME             grid|random|near-surface (default: near-surface)
          --output PATH               CSV output path (default: fractalbench.csv)

          --minRad2 X                 Mandelbox minRad2 (default: 0.1)
          --scale X                   fractalScale (default: 2.8)
          --foldingLimit X            box folding limit (default: 1.0)
          --sphereRadius X            sphere fold radius (default: 0.5)

          --refIters N                reference iterations (default: 12)
          --iters N                   test iterations (default: 5)

          --algorithms a,b,c          baseline,earlyEscape,twoPass,fastFloat (default: all)
          --escapeR2 X                early-escape radius^2 (default: 1000)

          Ray mode:
          --rays N                    Rays per algorithm (default: 200000)
          --originRadius X            Ray origin radius (default: 4.0)
          --tMin X                    Ray start distance (default: 0.05)
          --tMax X                    Ray max distance (default: 12.0)
          --hitThreshold X            Hit epsilon (default: 0.0005)
          --maxRaySteps N             Max ray steps (default: 64)
          --omega X                   Over-relaxation factor (default: 1.2)

          --nearPool N                pool size for near-surface selection (default: 800000)
          --nearCount N               output count for near-surface set (default: 50000)
          --nearAbsDE X               max |DE| for near-surface (default: 0.002)

        Examples:
          \(exe) --pointSet near-surface --output out.csv
          \(exe) --pointSet random --samples 1000000 --algorithms baseline,earlyEscape
        """)
    }

    static func parse() throws -> Options {
        var opt = Options()
        var i = 1
        func requireValue(_ flag: String) throws -> String {
            guard i + 1 < CommandLine.arguments.count else {
                throw NSError(domain: "CLI", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing value for \(flag)"])
            }
            i += 1
            return CommandLine.arguments[i]
        }

        while i < CommandLine.arguments.count {
            let arg = CommandLine.arguments[i]
            switch arg {
            case "--help", "-h":
                printUsage()
                exit(0)

            case "--mode":
                opt.mode = try requireValue(arg)

            case "--samples":
                opt.samples = Int(try requireValue(arg)) ?? opt.samples
            case "--warmup":
                opt.warmupSamples = Int(try requireValue(arg)) ?? opt.warmupSamples
            case "--seed":
                opt.seed = UInt64(try requireValue(arg)) ?? opt.seed

            case "--pointSet":
                opt.pointSet = try requireValue(arg)
            case "--output":
                opt.outputPath = try requireValue(arg)

            case "--rays":
                opt.rays = Int(try requireValue(arg)) ?? opt.rays
            case "--originRadius":
                opt.originRadius = Float(try requireValue(arg)) ?? opt.originRadius
            case "--tMin":
                opt.tMin = Float(try requireValue(arg)) ?? opt.tMin
            case "--tMax":
                opt.tMax = Float(try requireValue(arg)) ?? opt.tMax
            case "--hitThreshold":
                opt.hitThreshold = Float(try requireValue(arg)) ?? opt.hitThreshold
            case "--maxRaySteps":
                opt.maxRaySteps = Int(try requireValue(arg)) ?? opt.maxRaySteps
            case "--omega":
                opt.omega = Float(try requireValue(arg)) ?? opt.omega

            case "--minRad2":
                opt.minRad2 = Float(try requireValue(arg)) ?? opt.minRad2
            case "--scale":
                opt.fractalScale = Float(try requireValue(arg)) ?? opt.fractalScale
            case "--foldingLimit":
                opt.foldingLimit = Float(try requireValue(arg)) ?? opt.foldingLimit
            case "--sphereRadius":
                opt.sphereRadius = Float(try requireValue(arg)) ?? opt.sphereRadius

            case "--refIters":
                opt.referenceIterations = Int(try requireValue(arg)) ?? opt.referenceIterations
            case "--iters":
                opt.testIterations = Int(try requireValue(arg)) ?? opt.testIterations

            case "--algorithms":
                opt.algorithms = try requireValue(arg).split(separator: ",").map { String($0) }

            case "--escapeR2":
                opt.escapeRadius2 = Float(try requireValue(arg)) ?? opt.escapeRadius2

            case "--nearPool":
                opt.nearSurfacePool = Int(try requireValue(arg)) ?? opt.nearSurfacePool
            case "--nearCount":
                opt.nearSurfaceTargetCount = Int(try requireValue(arg)) ?? opt.nearSurfaceTargetCount
            case "--nearAbsDE":
                opt.nearSurfaceMaxAbsDE = Float(try requireValue(arg)) ?? opt.nearSurfaceMaxAbsDE

            default:
                throw NSError(domain: "CLI", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unknown argument: \(arg)"])
            }
            i += 1
        }
        return opt
    }
}
