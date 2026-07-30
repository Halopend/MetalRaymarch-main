//
//  MacBenchmarkHarness.swift
//  Threshold
//
//  Headless, offscreen performance harness for the Mac renderer. When the app is
//  launched with THRESHOLD_BENCHMARK=1, this drives the real raymarch pipeline in
//  a tight loop into an offscreen texture (no window / display link required),
//  executes a benchmark PLAN (a scene × config job matrix) in ONE app launch, and
//  writes machine-readable results to disk before exiting. Driver scripts live in
//  Scripts/ (bench.sh, bench_report.py, perf-gate.sh).
//
//  Why offscreen: the MTKView render loop is display-link driven, which the
//  window server throttles to near-zero for a window that isn't the composited
//  foreground — so an unattended run produces almost no frames. Rendering
//  offscreen with `ViewportRenderer.renderBenchmarkFrame` decouples the
//  benchmark from compositing while staying faithful to the shipping shader.
//
//  Two entry modes:
//
//  PLAN MODE (preferred — one launch, many configs):
//    THRESHOLD_BENCHMARK=1 THRESHOLD_BENCHMARK_PLAN=/path/plan.json
//    Plan file: { "defaults": {<job fields>}, "out": "...", "pngDir": "...",
//                 "jobs": [ { "name": "...", "scene": "...", ...overrides } ] }
//    Job fields (all optional except scene; job value ?? defaults ?? built-in):
//      frames(120) warmup(40) size("1920x1080") settleSeconds(2.5) shadows(bool)
//      png(bool) qc({key:val}) params({"8":17}) ablate(int >=10)
//    "scene": "*" expands the job into one job per keyboard-switchable preset.
//    Output: schemaVersion-2 JSON { meta..., jobs: [{name, scene, config,
//    metrics: PerfSceneRecord, png}] }.
//
//  ENV MODE (legacy single-config; kept byte-compatible — perf-gate.sh uses it):
//    THRESHOLD_BENCHMARK=1                 enable the harness (see BenchmarkMode)
//    THRESHOLD_BENCHMARK_SCENES=a,b,c      comma-separated scene names (default: all
//                                          keyboard-switchable static presets)
//    THRESHOLD_BENCHMARK_FRAMES=240        measured frames per scene
//    THRESHOLD_BENCHMARK_WARMUP=60         warmup frames per scene (discarded)
//    THRESHOLD_BENCHMARK_SIZE=1920x1080    offscreen render resolution
//    THRESHOLD_BENCHMARK_OUT=/path.json    output path (PerfRunRecord JSON)
//    THRESHOLD_BENCHMARK_QC=k=v,k=v        QualityConfig overrides applied after
//                                          each scene load (see applyQCOverride).
//    THRESHOLD_BENCHMARK_ANIMATION=name    deterministically play this animation
//                                          forward on a fixed-rate loop.
//    THRESHOLD_BENCHMARK_LOOPS=2           complete animation loops to measure.
//    THRESHOLD_BENCHMARK_ANIMATION_FPS=60  fixed timeline updates per second.
//    THRESHOLD_BENCHMARK_FREEZE_INTRINSICS=1
//                                          hold the first keyframe's fractal
//                                          geometry while other lanes animate.
//    THRESHOLD_BENCHMARK_FRACTAL_ITERATIONS=24
//                                          force every animation keyframe to the
//                                          same DE iteration cost for cache A/Bs.
//                                          Needed because benchmark launches are
//                                          hermetic: persisted device-local
//                                          settings (incl. the acceleration
//                                          levers) are ignored.
//

#if os(macOS)
import Foundation
import Metal
import QuartzCore
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

@MainActor
enum MacBenchmarkHarness {

    // MARK: - Env (legacy) config

    struct Config {
        var scenes: [String]
        var frames: Int
        var warmup: Int
        var width: Int
        var height: Int
        var outPath: String
        /// Formula-param overrides applied AFTER a scene loads, e.g. "8=12" sets
        /// formula param index 8 to 12. Used for sensitivity sweeps.
        var paramOverride: [(Int, Float)]
        /// If set, one PNG per scene is written here (offscreen frame capture) for
        /// visual-regression checks.
        var pngDir: String?
        /// Force shadows on/off (nil = leave as the scene sets it). Shadows add two
        /// per-pixel shadow marches, so this isolates their DE-call cost.
        var shadows: Bool?
        /// QualityConfig overrides applied after each scene loads, e.g.
        /// "coneMarchStrength=1,distanceLODStrength=0.98". Benchmark launches are
        /// hermetic (persisted device-local settings are ignored), so the
        /// acceleration levers a real install runs with — worth ~2.7× on the
        /// canonical scene — must be pinned explicitly to be measured at all.
        var qcOverride: [(String, Float)]
    }

    // MARK: - Plan (matrix) config

    /// One job in a benchmark plan. Every field except `scene` is optional and
    /// falls back to the plan's `defaults`, then to the built-in default — so a
    /// plan can express a whole A/B/N matrix over one shared config.
    struct BenchJobSpec: Decodable {
        var name: String?
        var scene: String?
        var frames: Int?
        var warmup: Int?
        var size: String?
        var settleSeconds: Double?
        var shadows: Bool?
        var png: Bool?
        var qc: [String: Float]?
        var params: [String: Float]?
        var ablate: UInt32?
    }

    struct BenchPlan: Decodable {
        var defaults: BenchJobSpec?
        var out: String?
        var pngDir: String?
        var jobs: [BenchJobSpec]
    }

    /// A fully-resolved job (spec ?? defaults ?? built-ins).
    struct ResolvedJob {
        var name: String
        var scene: String
        var frames: Int
        var warmup: Int
        var width: Int
        var height: Int
        var settleSeconds: Double
        var shadows: Bool?
        var png: Bool
        var qc: [(String, Float)]
        var params: [(Int, Float)]
        var ablate: UInt32?
    }

    struct BenchJobConfigEcho: Codable {
        var frames: Int
        var warmup: Int
        var width: Int
        var height: Int
        var settleSeconds: Double
        var shadows: Bool?
        var qc: [String: Float]
        var params: [String: Float]
        var ablate: UInt32?
    }

    struct BenchJobResult: Codable {
        var name: String
        var scene: String
        var config: BenchJobConfigEcho
        var metrics: PerfSceneRecord
        var png: String?
    }

    struct AnimationLoopRecord: Codable {
        var loop: Int
        var frames: Int
        var gpuMsAvg: Double
        var gpuMsP95: Double
        var gpuMsMax: Double
        var cpuEncodeMsAvg: Double
        var iterationsAvg: Double
    }

    struct AnimationLoopRun: Codable {
        var capturedAt: String
        var animation: String
        var cacheEnabled: Bool
        var timelineFPS: Double
        var loopDurationSeconds: Double
        var width: Int
        var height: Int
        var loops: [AnimationLoopRecord]
    }

    struct BenchPlanRunRecord: Codable {
        var schemaVersion: Int = 2
        var capturedAt: String
        var gitSHA: String
        var gitDirty: Bool
        var marketingVersion: String
        var buildNumber: String
        var deviceModel: String
        var osVersion: String
        var jobs: [BenchJobResult]
    }

    // MARK: - Config parsing

    /// Apply "key=value" QualityConfig overrides by field name. Unknown keys are
    /// logged and skipped so a typo fails loudly in the run log, not silently.
    private static func applyQCOverride(_ pairs: [(String, Float)], to settings: RenderSettings) {
        guard !pairs.isEmpty else { return }
        var qc = settings.qualityConfig
        for (key, v) in pairs {
            switch key {
            case "coneMarchStrength":            qc.coneMarchStrength = v
            case "distanceLODStrength":          qc.distanceLODStrength = v
            case "overRelaxationMax":            qc.overRelaxationMax = v
            case "smartAdvanceEnabled":          qc.smartAdvanceEnabled = v != 0
            case "boundingSphereSkipEnabled":    qc.boundingSphereSkipEnabled = v != 0
            case "zoomFogCompensationEnabled":   qc.zoomFogCompensationEnabled = v != 0
            case "coarsePrepassWarmStartEnabled": qc.coarsePrepassWarmStartEnabled = v != 0
            case "coherentPacketEnabled":        qc.coherentPacketEnabled = v != 0
            case "foveationStrength":            qc.foveationStrength = v
            case "baseFractalIterations":        qc.baseFractalIterations = Int(v)
            case "baseMaxRaySteps":              qc.baseMaxRaySteps = Int(v)
            case "boundToSpaceEnabled":          qc.boundToSpaceEnabled = v != 0
            case "boundToSpaceMode":             qc.boundToSpaceMode = Int(v)
            case "boundSpaceWidth":              qc.boundSpaceWidth = v
            case "boundSpaceDepth":              qc.boundSpaceDepth = v
            case "boundSpaceHeight":             qc.boundSpaceHeight = v
            case "boundAmbientStrength":         qc.boundAmbientStrength = v
            case "envScrunchEnabled":            qc.envScrunchEnabled = v != 0
            case "envScrunchMode":               qc.envScrunchMode = Int(v)
            case "envScrunchStrength":           qc.envScrunchStrength = v
            case "envScrunchReach":              qc.envScrunchReach = v
            case "envScrunchContain":            qc.envScrunchContain = Int(v)
            case "envScrunchContainFeather":     qc.envScrunchContainFeather = v
            // Not a QualityConfig field, but riding the same override hook:
            // legacy DE mismatch δ for headless A/B captures.
            case "deIterationMismatch":          settings.deIterationMismatch = v
            default: log("  WARN unknown QC override key '\(key)' — skipped")
            }
        }
        settings.qualityConfig = qc
        log("  applied QC override \(pairs.map { "\($0.0)=\($0.1)" }.joined(separator: ","))")
    }

    private static func log(_ s: String) {
        FileHandle.standardError.write(Data("🏁 [bench] \(s)\n".utf8))
    }

    // MARK: - Occupancy probe (per-DE register pressure)

    /// Builds the real compute raymarch kernel specialized per fractal type and
    /// reports `maxTotalThreadsPerThreadgroup` (higher = fewer registers/thread =
    /// more occupancy headroom), `threadExecutionWidth`, and static threadgroup
    /// memory. Since `FC_FRACTAL_TYPE` devirtualizes the DE dispatch at compile
    /// time, each pipeline's register footprint reflects exactly one DE — so this
    /// ranks the DE functions by occupancy cost. Headless, no rendering.
    private static func runOccupancyProbe(device: MTLDevice) {
        guard let library = device.makeDefaultLibrary() else {
            log("OCCUPANCY FATAL: no default library"); return
        }
        let env = ProcessInfo.processInfo.environment
        // Optional CSV history: THRESHOLD_OCCUPANCY_CSV=/path/occupancy_history.csv
        // appends one row per (kernel, fractal, iters). THRESHOLD_OCCUPANCY_TAG
        // labels the run (e.g. "baseline-preA", "leverA-constref") so the history
        // reads as an experiment log. Header is written once if the file is new.
        let csvPath = env["THRESHOLD_OCCUPANCY_CSV"]
        let tag = env["THRESHOLD_OCCUPANCY_TAG"] ?? "adhoc"
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime]
        let stamp = iso.string(from: Date())
        let sha = BuildStamp.gitSHA
        let dirty = BuildStamp.gitDirty ? "dirty" : "clean"
        var csvRows: [String] = []
        func csvRecord(kernel: String, fractal: String, iters: Int32,
                       maxThreads: Int, width: Int, tgm: Int) {
            csvRows.append("\(stamp),\(sha),\(dirty),\(tag),\(kernel),\(fractal),\(iters),\(maxThreads),\(width),\(tgm)")
        }
        // (rawValue, name) — mirrors the FractalType enum in ShaderTypes.h.
        let types: [(Int32, String)] = [
            (0,  "Mandelbox"), (1, "Mandelbulb"), (2, "Menger"),
            (5,  "MandelbulbJulia"), (6, "QuaternionJulia"), (11, "Octahedron"),
            (14, "MengerSphere"), (15, "TheliPseudoKleinian"), (17, "Kleinian"),
        ]
        // Kernels that inline the DE via Map/FractalDE_Dispatch.
        let kernels = ["adaptiveHierarchical8x8", "coneCoarsePrepass8x8"]

        // Fixed non-type constants so only the DE differs run-to-run. Iteration
        // count drives loop-unroll register cost, so probe a low and a high count.
        //
        // deTailBaked controls FC 3/16/17 (hasSpaceWarp/hasEnvScrunch/hasHandField):
        //   nil   → left UNDEFINED (not set at all) — this is what
        //           `buildComputePipeline` produced for every compute pipeline
        //           BEFORE the selectComputePipeline DE-tail plumbing: the shader's
        //           is_function_constant_defined(...) fallback makes them default
        //           ON, so every DE eval pays the full space-warp/env-scrunch/
        //           hand-field tail regardless of runtime state.
        //   false → explicitly baked OFF — what selectComputePipeline now bakes
        //           for a clean scene (no active space warp, env scrunch off,
        //           hand attraction off), letting the whole tail DCE.
        // Comparing these two isolates exactly the register/occupancy delta the
        // fix unlocks, independent of every other function constant (which stay
        // fixed across both variants).
        func constants(type: Int32, iterations: Int32, deTailBaked: Bool?) -> MTLFunctionConstantValues {
            let c = MTLFunctionConstantValues()
            func setI(_ x: Int32, _ idx: Int) { var t = x; c.setConstantValue(&t, type: .int, index: idx) }
            func setB(_ x: Bool, _ idx: Int) { var t = x; c.setConstantValue(&t, type: .bool, index: idx) }
            setI(iterations, 0)   // FC_FRACTAL_ITERATIONS
            setI(max(iterations - 2, 2), 1) // FC_SHADOW_ITERATIONS
            setI(1, 4)            // FC_QUALITY_MODE
            setI(128, 6)          // FC_MAX_RAY_STEPS
            setI(type, 7)         // FC_FRACTAL_TYPE
            setB(false, 8)        // FC_NEON_MODE_ENABLED
            setI(iterations, 9)   // FC_COLOR_ITERATIONS
            setB(true, 11)        // FC_SHADOWS_ENABLED
            setB(false, 2)        // FC_SAFETY_BUBBLE_ENABLED
            setI(8, 12)           // FC_MANDELBULB_POWER
            if let deTailBaked {
                setB(deTailBaked, 3)   // FC_HAS_SPACEWARP
                setB(deTailBaked, 16)  // FC_HAS_ENVSCRUNCH
                setB(deTailBaked, 17)  // FC_HAS_HANDFIELD
            }
            setB(false, 13)       // FC_WARM_START
            setB(false, 15)       // FC_COARSE_WARM_START
            setB(false, 14)       // FC_COHERENT_PACKET
            return c
        }

        for kernel in kernels {
            // Only adaptiveHierarchical8x8 is wired to selectComputePipeline's new
            // DE-tail bakes (coneCoarsePrepass8x8 stays intentionally generic — see
            // Renderer.swift's "Increment 1" comment — so it has nothing to compare).
            let compareDETail = kernel == "adaptiveHierarchical8x8"
            log("── occupancy: \(kernel) (maxThreads/threadgroup — higher = more occupancy) ──")
            for iters: Int32 in [6, 12] {
                var line = "  iters=\(iters)  "
                var undefinedLine = "  iters=\(iters) [FC undefined, pre-fix]  "
                var bakedOffLine = "  iters=\(iters) [FC baked off, post-fix]  "
                for (raw, name) in types {
                    if compareDETail {
                        do {
                            let fnU = try library.makeFunction(name: kernel, constantValues: constants(type: raw, iterations: iters, deTailBaked: nil))
                            let psoU = try device.makeComputePipelineState(function: fnU)
                            undefinedLine += "\(name)=\(psoU.maxTotalThreadsPerThreadgroup)(tgm\(psoU.staticThreadgroupMemoryLength)) "
                            csvRecord(kernel: "\(kernel)-fcUndefined", fractal: name, iters: iters,
                                      maxThreads: psoU.maxTotalThreadsPerThreadgroup,
                                      width: psoU.threadExecutionWidth,
                                      tgm: psoU.staticThreadgroupMemoryLength)

                            let fnB = try library.makeFunction(name: kernel, constantValues: constants(type: raw, iterations: iters, deTailBaked: false))
                            let psoB = try device.makeComputePipelineState(function: fnB)
                            bakedOffLine += "\(name)=\(psoB.maxTotalThreadsPerThreadgroup)(tgm\(psoB.staticThreadgroupMemoryLength)) "
                            csvRecord(kernel: "\(kernel)-fcBakedOff", fractal: name, iters: iters,
                                      maxThreads: psoB.maxTotalThreadsPerThreadgroup,
                                      width: psoB.threadExecutionWidth,
                                      tgm: psoB.staticThreadgroupMemoryLength)
                        } catch {
                            undefinedLine += "\(name)=ERR "
                            bakedOffLine += "\(name)=ERR "
                        }
                    } else {
                        do {
                            let fn = try library.makeFunction(name: kernel, constantValues: constants(type: raw, iterations: iters, deTailBaked: false))
                            let pso = try device.makeComputePipelineState(function: fn)
                            line += "\(name)=\(pso.maxTotalThreadsPerThreadgroup)(w\(pso.threadExecutionWidth),tgm\(pso.staticThreadgroupMemoryLength)) "
                            csvRecord(kernel: kernel, fractal: name, iters: iters,
                                      maxThreads: pso.maxTotalThreadsPerThreadgroup,
                                      width: pso.threadExecutionWidth,
                                      tgm: pso.staticThreadgroupMemoryLength)
                        } catch {
                            line += "\(name)=ERR "
                        }
                    }
                }
                if compareDETail {
                    log(undefinedLine)
                    log(bakedOffLine)
                } else {
                    log(line)
                }
            }
        }

        if let csvPath {
            let header = "timestamp,gitSHA,gitState,tag,kernel,fractal,iterations,maxThreadsPerThreadgroup,threadExecutionWidth,threadgroupMemBytes\n"
            let body = csvRows.joined(separator: "\n") + "\n"
            let fm = FileManager.default
            if !fm.fileExists(atPath: csvPath) {
                try? (header + body).write(toFile: csvPath, atomically: true, encoding: .utf8)
                log("occupancy CSV created → \(csvPath) (\(csvRows.count) rows, tag=\(tag))")
            } else if let handle = FileHandle(forWritingAtPath: csvPath) {
                handle.seekToEndOfFile()
                handle.write(Data(body.utf8))
                try? handle.close()
                log("occupancy CSV appended → \(csvPath) (\(csvRows.count) rows, tag=\(tag))")
            } else {
                log("occupancy CSV: could not open \(csvPath)")
            }
        }
        log("occupancy probe done")
    }

    private static func parseSize(_ s: String?, defaultW: Int, defaultH: Int) -> (Int, Int) {
        guard let s, let x = s.firstIndex(of: "x"),
              let w = Int(s[..<x]), let h = Int(s[s.index(after: x)...]) else {
            return (defaultW, defaultH)
        }
        return (w, h)
    }

    static func configFromEnv() -> Config {
        let env = ProcessInfo.processInfo.environment
        let scenes = (env["THRESHOLD_BENCHMARK_SCENES"] ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        func intEnv(_ k: String, _ d: Int) -> Int { env[k].flatMap { Int($0) } ?? d }
        let (w, h) = parseSize(env["THRESHOLD_BENCHMARK_SIZE"], defaultW: 1920, defaultH: 1080)
        let out = env["THRESHOLD_BENCHMARK_OUT"] ?? (NSHomeDirectory() + "/mac-bench.json")

        var overrides: [(Int, Float)] = []
        for pair in (env["THRESHOLD_BENCHMARK_PARAM_OVERRIDE"] ?? "").split(separator: ",") {
            let kv = pair.split(separator: "=")
            if kv.count == 2, let i = Int(kv[0].trimmingCharacters(in: .whitespaces)),
               let v = Float(kv[1].trimmingCharacters(in: .whitespaces)) {
                overrides.append((i, v))
            }
        }
        let pngDir = env["THRESHOLD_BENCHMARK_PNG_DIR"]
        let shadows = env["THRESHOLD_BENCHMARK_SHADOWS"].map { $0 == "1" }

        var qcOverride: [(String, Float)] = []
        for pair in (env["THRESHOLD_BENCHMARK_QC"] ?? "").split(separator: ",") {
            let kv = pair.split(separator: "=")
            if kv.count == 2, let v = Float(kv[1].trimmingCharacters(in: .whitespaces)) {
                qcOverride.append((kv[0].trimmingCharacters(in: .whitespaces), v))
            }
        }

        return Config(scenes: scenes,
                      frames: intEnv("THRESHOLD_BENCHMARK_FRAMES", 240),
                      warmup: intEnv("THRESHOLD_BENCHMARK_WARMUP", 60),
                      width: w, height: h, outPath: out,
                      paramOverride: overrides, pngDir: pngDir, shadows: shadows,
                      qcOverride: qcOverride)
    }

    /// Resolve a plan's job specs against its defaults and the built-in defaults,
    /// expanding `"scene": "*"` into one job per keyboard-switchable preset.
    private static func resolveJobs(_ plan: BenchPlan, allScenes: [String]) -> [ResolvedJob] {
        let d = plan.defaults
        var out: [ResolvedJob] = []
        for (i, spec) in plan.jobs.enumerated() {
            guard let sceneField = spec.scene ?? d?.scene else {
                log("WARN job #\(i) has no scene — skipped"); continue
            }
            let sceneNames = sceneField == "*" ? allScenes : [sceneField]
            for scene in sceneNames {
                let (w, h) = parseSize(spec.size ?? d?.size, defaultW: 1920, defaultH: 1080)
                let baseName = spec.name ?? "job\(i)"
                let name = sceneField == "*" ? "\(baseName)-\(scene)" : baseName
                // qc/params merge: defaults first, job overrides win per key.
                var qc = d?.qc ?? [:]
                for (k, v) in spec.qc ?? [:] { qc[k] = v }
                var params = d?.params ?? [:]
                for (k, v) in spec.params ?? [:] { params[k] = v }
                out.append(ResolvedJob(
                    name: name,
                    scene: scene,
                    frames: spec.frames ?? d?.frames ?? 120,
                    warmup: spec.warmup ?? d?.warmup ?? 40,
                    width: w, height: h,
                    settleSeconds: spec.settleSeconds ?? d?.settleSeconds ?? 2.5,
                    shadows: spec.shadows ?? d?.shadows,
                    png: spec.png ?? d?.png ?? false,
                    qc: qc.sorted { $0.key < $1.key }.map { ($0.key, $0.value) },
                    params: params.sorted { $0.key < $1.key }
                        .compactMap { k, v in Int(k).map { ($0, v) } },
                    ablate: spec.ablate ?? d?.ablate))
            }
        }
        return out
    }

    // MARK: - Run

    static func run(appModel: AppModel) async {
        appModel.presetManager.refreshBundledPresets()
        // Benchmark scene resolution must not race the app's debounced startup
        // reload. Await the same off-main scan explicitly so every plan sees a
        // deterministic catalog without putting file I/O back on MainActor.
        await appModel.presetManager.loadPresetsNow()

        guard let device = MTLCreateSystemDefaultDevice() else { log("FATAL no Metal device"); exit(2) }

        // THRESHOLD_OCCUPANCY_PROBE=1: build the real compute raymarch kernel
        // (adaptiveHierarchical8x8) specialized per fractal type and report
        // maxTotalThreadsPerThreadgroup — a headless per-DE register-pressure /
        // occupancy proxy — then exit. Does not touch the render pipeline.
        if ProcessInfo.processInfo.environment["THRESHOLD_OCCUPANCY_PROBE"] == "1" {
            runOccupancyProbe(device: device)
            exit(0)
        }

        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm_srgb
        let inputController = ViewportInputAccumulator()
        guard let renderer = ViewportRenderer(
            device: device,
            appModel: appModel,
            inputController: inputController,
            metalLayer: layer,
            colorPixelFormat: .bgra8Unorm_srgb,
            depthPixelFormat: .depth32Float,
            clearColor: MTLClearColor(red: 0.005, green: 0.006, blue: 0.008, alpha: 1.0)) else {
            log("FATAL renderer init failed"); exit(3)
        }

        // Mirror the view's Coordinator so embedded-DE (.threshfx) scenes compile.
        appModel.activateEmbeddedFormulaHandler =
            renderer.embeddedFormulaActivator(renderSettings: appModel.renderSettings)
        appModel.forceShaderRecompileHandler = renderer.shaderRecompiler(appModel: appModel)
        appModel.rendererStartupWarmupComplete = true

        // Native res + fragment full-march + armed step counter, so GPU cost and
        // "iterations to converge" are measured consistently (as PerfSweepRunner does).
        let settings = appModel.renderSettings
        settings.resolutionScale = 1.0
        settings.tileSize = 0
        // Snap scene loads instead of the user's eased transition: an ease still
        // mid-flight when measurement starts makes both the perf numbers (march
        // steps drift run-to-run) and the PNG capture nondeterministic.
        settings.sceneTransitionDuration = 0
        BenchmarkManager.shared.collectIterations = true
        defer { BenchmarkManager.shared.collectIterations = false }

        let env = ProcessInfo.processInfo.environment
        if let animationName = env["THRESHOLD_BENCHMARK_ANIMATION"],
           !animationName.isEmpty {
            await runAnimationLoopMode(
                name: animationName,
                appModel: appModel,
                renderer: renderer,
                settings: settings
            )
        } else if let planPath = env["THRESHOLD_BENCHMARK_PLAN"] {
            await runPlan(path: planPath, appModel: appModel, renderer: renderer, settings: settings)
        } else {
            await runEnvMode(appModel: appModel, renderer: renderer, settings: settings)
        }
        try? await Task.sleep(for: .milliseconds(200))
        exit(0)
    }

    // MARK: - Plan mode (one launch, scene × config matrix)

    private static func benchmarkPresetCatalog(_ manager: PresetManager) -> [FractalPreset] {
        let store = manager.presets.filter { $0.name != "__lastState__" }
        let storeIDs = Set(store.map(\.id))
        let storeNames = Set(store.map(\.name))
        let bundledFallbacks = PresetManager.bundledPresetsForBenchmark().filter {
            !storeIDs.contains($0.id) && !storeNames.contains($0.name)
        }
        // PresetManager keeps the hydrated store newest-first. Preserve that
        // ordering so duplicate user names resolve exactly as they did before;
        // immutable bundle entries are fallback-only.
        return store + bundledFallbacks
    }

    /// Deterministic animation benchmark. The normal render loop is not running
    /// in benchmark mode, so advance the AnimationManager by one fixed timeline
    /// step before each offscreen frame. This makes cache-off/cache-on runs sample
    /// exactly the same geometry and keeps loop boundaries independent of GPU speed.
    private static func runAnimationLoopMode(
        name: String,
        appModel: AppModel,
        renderer: ViewportRenderer,
        settings: RenderSettings
    ) async {
        let env = ProcessInfo.processInfo.environment
        let cfg = configFromEnv()
        guard let manager = appModel.animationManager else {
            log("FATAL animation manager unavailable")
            return
        }
        guard var scene = manager.scenes.first(where: {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        }) else {
            log("FATAL animation not found: '\(name)' — available: "
                + manager.scenes.map(\.name).joined(separator: " | "))
            return
        }
        guard scene.keyframes.count >= 2 else {
            log("FATAL animation '\(scene.name)' has fewer than two keyframes")
            return
        }

        if env["THRESHOLD_BENCHMARK_FREEZE_INTRINSICS"] == "1" {
            let seed = scene.keyframes[0]
            for index in scene.keyframes.indices {
                scene.keyframes[index].minDistance = seed.minDistance
                scene.keyframes[index].fractalScale = seed.fractalScale
                scene.keyframes[index].foldingLimit = seed.foldingLimit
                scene.keyframes[index].sphereRadius = seed.sphereRadius
                scene.keyframes[index].baseFractalIterations = seed.baseFractalIterations
                scene.keyframes[index].formulaParamValues = seed.formulaParamValues
            }
            log("  froze intrinsic Mandelbox geometry at keyframe 0")
        }

        if let forcedIterations = env["THRESHOLD_BENCHMARK_FRACTAL_ITERATIONS"]
            .flatMap(Int.init) {
            let clampedIterations = max(2, forcedIterations)
            for index in scene.keyframes.indices {
                scene.keyframes[index].baseFractalIterations = clampedIterations
            }
            log("  forced fractal iterations=\(clampedIterations)")
        }

        let timelineFPS = max(
            1.0,
            Double(env["THRESHOLD_BENCHMARK_ANIMATION_FPS"] ?? "") ?? 60.0
        )
        let requestedLoops = Int(env["THRESHOLD_BENCHMARK_LOOPS"] ?? "") ?? 2
        let loopCount = max(2, requestedLoops)

        // Match AnimationManager.segmentDuration and SegmentAdvancer for forced
        // forward looping, including the final-keyframe → first-keyframe segment.
        var loopDuration = 0.0
        for fromIndex in scene.keyframes.indices {
            let toIndex = (fromIndex + 1) % scene.keyframes.count
            let durationIndex = max(fromIndex, toIndex)
            let authored = scene.keyframes[durationIndex].duration
            loopDuration += authored > 0 ? authored : 2.0
        }
        let framesPerLoop = max(1, Int(ceil(loopDuration * timelineFPS)))

        scene.isLooping = true
        scene.playbackMode = .forward
        manager.currentScene = scene
        manager.play()
        manager.playbackSpeed = 1.0
        guard manager.isPlaying else {
            log("FATAL animation '\(scene.name)' did not enter playback")
            return
        }

        if let shadows = cfg.shadows {
            settings.shadowsEnabled = shadows
        }
        applyQCOverride(cfg.qcOverride, to: settings)
        settings.resolutionScale = 1.0
        settings.tileSize = 0

        // Allocate benchmark targets and compile the active render path without
        // advancing the timeline or completing a cache bake.
        _ = renderer.renderBenchmarkFrame(
            appModel: appModel, width: cfg.width, height: cfg.height
        )

        log("animation '\(scene.name)' loops=\(loopCount) timeline=\(timelineFPS)Hz "
            + "duration=\(String(format: "%.3f", loopDuration))s "
            + "framesPerLoop=\(framesPerLoop) size=\(cfg.width)x\(cfg.height) "
            + "cache=\(env["THRESHOLD_DIST_CACHE"] == "1" ? "on" : "off")")

        var records: [AnimationLoopRecord] = []
        for loopIndex in 1...loopCount {
            var gpu: [Double] = []
            var cpuSum = 0.0
            var stepSum = 0.0
            var stepCount = 0
            var measured = 0

            for _ in 0..<framesPerLoop {
                manager.update(deltaTime: 1.0 / timelineFPS)
                guard let metric = renderer.renderBenchmarkFrame(
                    appModel: appModel, width: cfg.width, height: cfg.height
                ) else { continue }
                measured += 1
                if metric.gpuMs > 0 {
                    gpu.append(metric.gpuMs)
                }
                cpuSum += metric.cpuEncodeMs
                if metric.avgSteps > 0 {
                    stepSum += metric.avgSteps
                    stepCount += 1
                }
            }

            let sortedGPU = gpu.sorted()
            let record = AnimationLoopRecord(
                loop: loopIndex,
                frames: measured,
                gpuMsAvg: gpu.reduce(0, +) / Double(max(gpu.count, 1)),
                gpuMsP95: percentile(sortedGPU, 0.95),
                gpuMsMax: sortedGPU.last ?? 0,
                cpuEncodeMsAvg: cpuSum / Double(max(measured, 1)),
                iterationsAvg: stepCount > 0
                    ? stepSum / Double(stepCount)
                    : 0
            )
            records.append(record)
            log(String(
                format: "  loop %d → gpu avg %.3fms p95 %.3fms max %.3fms "
                    + "steps %.2f cpuEnc %.3fms",
                loopIndex, record.gpuMsAvg, record.gpuMsP95,
                record.gpuMsMax, record.iterationsAvg, record.cpuEncodeMsAvg
            ))
        }
        manager.stop()

        if records.count >= 2 {
            let first = records[0].gpuMsAvg
            let second = records[1].gpuMsAvg
            let delta = first > 0 ? 100.0 * (second - first) / first : 0
            let speedup = second > 0 ? first / second : 0
            log(String(
                format: "  loop 2 vs 1 → %+.2f%%, %.3fx",
                delta, speedup
            ))
        }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let run = AnimationLoopRun(
            capturedAt: iso.string(from: Date()),
            animation: scene.name,
            cacheEnabled: env["THRESHOLD_DIST_CACHE"] == "1",
            timelineFPS: timelineFPS,
            loopDurationSeconds: loopDuration,
            width: cfg.width,
            height: cfg.height,
            loops: records
        )
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(run).write(
                to: URL(fileURLWithPath: cfg.outPath),
                options: .atomic
            )
            log("done → \(cfg.outPath)")
        } catch {
            log("FATAL animation benchmark write failed: \(error)")
        }
    }

    private static func runPlan(path: String, appModel: AppModel,
                                renderer: ViewportRenderer, settings: RenderSettings) async {
        let plan: BenchPlan
        do {
            plan = try JSONDecoder().decode(BenchPlan.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        } catch {
            log("FATAL plan decode failed (\(path)): \(error)"); exit(4)
        }
        let env = ProcessInfo.processInfo.environment
        let outPath = env["THRESHOLD_BENCHMARK_OUT"] ?? plan.out
            ?? (path as NSString).deletingPathExtension + ".results.json"
        let pngDir = env["THRESHOLD_BENCHMARK_PNG_DIR"] ?? plan.pngDir
            ?? (outPath as NSString).deletingLastPathComponent + "/png"

        // The active iCloud store may legitimately contain unhydrated placeholders.
        // Use immutable bundled scenes only as fallbacks for missing store entries.
        let all = benchmarkPresetCatalog(appModel.presetManager)
        let allSceneNames = all.filter { $0.isKeyboardSwitchableStaticPreset }.map { $0.name }
        let jobs = resolveJobs(plan, allScenes: allSceneNames)
        guard !jobs.isEmpty else { log("FATAL plan has no runnable jobs"); exit(4) }
        log("plan \(path): \(jobs.count) job(s), out=\(outPath)")

        var results: [BenchJobResult] = []
        var lastLoadedScene: String?
        for job in jobs {
            guard let preset = resolvePreset(named: job.scene, in: all) else {
                log("WARN scene not found: '\(job.scene)' — job '\(job.name)' skipped. Available: "
                    + all.map { $0.name }.joined(separator: " | "))
                continue
            }
            // Consecutive jobs on the same scene skip the reload + settle: the
            // per-job overrides below re-pin every config axis a job can vary, so
            // the only state a reload would reset is exactly what we re-apply.
            let needsLoad = lastLoadedScene != job.scene
            if let record = await measure(job: job, preset: preset, reload: needsLoad,
                                          appModel: appModel, renderer: renderer, settings: settings,
                                          pngDir: job.png ? pngDir : nil) {
                results.append(record)
                lastLoadedScene = job.scene
            }
        }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let run = BenchPlanRunRecord(
            capturedAt: iso.string(from: Date()),
            gitSHA: BuildStamp.gitSHA,
            gitDirty: BuildStamp.gitDirty,
            marketingVersion: BuildStamp.marketingVersion,
            buildNumber: BuildStamp.buildNumber,
            deviceModel: BuildStamp.deviceModel,
            osVersion: BuildStamp.osVersion,
            jobs: results)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            try FileManager.default.createDirectory(
                atPath: (outPath as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true)
            try encoder.encode(run).write(to: URL(fileURLWithPath: outPath))
            log("done — \(results.count)/\(jobs.count) job(s) → \(outPath)")
        } catch {
            log("FATAL write failed: \(error)"); exit(5)
        }
    }

    /// Measure one resolved job. `reload: false` skips the scene load + settle
    /// (valid only when the same scene is already loaded — every config axis a
    /// job can carry is re-applied below regardless).
    private static func measure(job: ResolvedJob, preset: FractalPreset, reload: Bool,
                                appModel: AppModel, renderer: ViewportRenderer,
                                settings: RenderSettings, pngDir: String?) async -> BenchJobResult? {
        log("job '\(job.name)': scene '\(job.scene)' \(job.width)x\(job.height) "
            + "frames=\(job.frames) warmup=\(job.warmup)\(reload ? "" : " (scene cached)")")
        if reload {
            appModel.loadStaticScene(preset)
            // Let the (snapped) apply + any embedded-DE compile + the renderer's
            // exponential camera smoothers settle before warmup.
            try? await Task.sleep(for: .seconds(job.settleSeconds))
        }

        // Re-pin every config axis after the scene's own values applied.
        if let s = job.shadows { settings.shadowsEnabled = s; log("  forced shadows=\(s)") }
        applyQCOverride(job.qc, to: settings)

        // Dev hook: force a zoom level (detail scale) for zoom-out captures.
        // Set the target too — interpolateToTargets stomps the raw value.
        if let ds = ProcessInfo.processInfo.environment["THRESHOLD_BENCHMARK_DETAIL_SCALE"].flatMap(Float.init) {
            settings.detailScale = ds
            settings.targetDetailScale = ds
            log("  forced detailScale=\(ds)")
            try? await Task.sleep(for: .seconds(1))
        }

        // Ablation mode is read by the renderer per frame; racy-by-design gate
        // (main-actor write, render-thread read) like the other benchmark toggles.
        ViewportRenderer.benchAblateMode = job.ablate ?? ViewportRenderer.benchAblateModeEnvDefault

        // Provenance guard: log the quality values actually in effect so a
        // measurement made with the wrong iteration/step budget is visible in the
        // run log instead of silently producing a bogus number.
        let qcNow = settings.qualityConfig
        log("  effective iters=\(qcNow.baseFractalIterations) raySteps=\(qcNow.baseMaxRaySteps) "
            + "resScale=\(settings.resolutionScale) shadows=\(settings.shadowsEnabled)"
            + (job.ablate.map { " ablate=\($0)" } ?? ""))

        // Start every job from the same animation phase, even when PNG capture
        // is disabled. Otherwise A/B jobs render different geometry and their
        // GPU times and march-step counts are not directly comparable.
        settings.benchFreezeAnimationPhases()

        // Formula-param overrides (e.g. MaxReflections sweep) after the apply
        // has settled, so they aren't stomped by the transition.
        if !job.params.isEmpty {
            var fp = settings.formulaParams
            for (i, v) in job.params { FormulaCatalog.setParam(&fp, index: i, value: v) }
            settings.formulaParams = fp
            log("  applied param override \(job.params.map { "\($0.0)=\($0.1)" }.joined(separator: ","))")
            try? await Task.sleep(for: .milliseconds(300))
        }

        for _ in 0..<job.warmup {
            _ = renderer.renderBenchmarkFrame(appModel: appModel, width: job.width, height: job.height)
        }

        var gpu: [Double] = []
        var cpuSum = 0.0
        var stepSum = 0.0
        var stepN = 0
        var measured = 0
        for _ in 0..<job.frames {
            guard let m = renderer.renderBenchmarkFrame(appModel: appModel,
                                                        width: job.width, height: job.height) else { continue }
            measured += 1
            if m.gpuMs > 0 { gpu.append(m.gpuMs) }
            cpuSum += m.cpuEncodeMs
            if m.avgSteps > 0 { stepSum += m.avgSteps; stepN += 1 }
        }

        let rec = makeRecord(preset: preset, gpu: gpu,
                             cpuAvg: cpuSum / Double(max(measured, 1)),
                             iterAvg: stepN > 0 ? stepSum / Double(stepN) : 0,
                             frames: measured, w: job.width, h: job.height,
                             qc: settings.qualityConfig)
        log(String(format: "  '%@' → gpu avg %.2fms  p95 %.2fms  max %.2fms  steps %.1f  cpuEnc %.2fms",
                   job.name, rec.gpuMsAvg, rec.gpuMsP95, rec.gpuMsMax, rec.iterationsAvg, rec.cpuEncodeMsAvg))

        var pngPath: String?
        if let dir = pngDir {
            // Pin the phase accumulators again right before capture (they resume
            // integrating during the measurement frames).
            settings.benchFreezeAnimationPhases()
            if let cap = renderer.captureBenchmarkBytes(appModel: appModel,
                                                        width: job.width, height: job.height) {
                let safe = job.name.replacingOccurrences(of: "/", with: "_")
                let path = (dir as NSString).appendingPathComponent("\(safe).png")
                try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                if writePNG(bytes: cap.bytes, width: job.width, height: job.height,
                            bytesPerRow: cap.bytesPerRow, to: path) {
                    pngPath = path
                    log("  wrote \(path)")
                } else {
                    log("  PNG write FAILED for '\(job.name)'")
                }
            }
        }

        return BenchJobResult(
            name: job.name,
            scene: job.scene,
            config: BenchJobConfigEcho(
                frames: job.frames, warmup: job.warmup,
                width: job.width, height: job.height,
                settleSeconds: job.settleSeconds,
                shadows: job.shadows,
                qc: Dictionary(uniqueKeysWithValues: job.qc),
                params: Dictionary(uniqueKeysWithValues: job.params.map { (String($0.0), $0.1) }),
                ablate: job.ablate),
            metrics: rec,
            png: pngPath)
    }

    private static func resolvePreset(named name: String, in all: [FractalPreset]) -> FractalPreset? {
        if let p = all.first(where: { $0.name == name }) { return p }
        if name == "Mandelbox" || name == "__default__"
            || name.caseInsensitiveCompare("start") == .orderedSame {
            // The app's startup scene is a built-in mandelbox default, not a
            // bundled .threshscene, so resolve it directly.
            return PresetManager.mandelboxDefaultPreset()
        }
        return nil
    }

    // MARK: - Env (legacy) mode — behavior kept identical for perf-gate.sh

    private static func runEnvMode(appModel: AppModel,
                                   renderer: ViewportRenderer, settings: RenderSettings) async {
        let cfg = configFromEnv()
        log("start scenes=\(cfg.scenes.isEmpty ? "<all>" : cfg.scenes.joined(separator: ",")) "
            + "frames=\(cfg.frames) warmup=\(cfg.warmup) size=\(cfg.width)x\(cfg.height)")

        // Resolve requested scenes by exact name.
        let all = benchmarkPresetCatalog(appModel.presetManager)
        var targets: [FractalPreset] = []
        if cfg.scenes.isEmpty {
            targets = all.filter { $0.isKeyboardSwitchableStaticPreset }
        } else {
            for name in cfg.scenes {
                if let p = resolvePreset(named: name, in: all) {
                    targets.append(p)
                } else {
                    log("WARN scene not found: '\(name)' — available: "
                        + all.map { $0.name }.joined(separator: " | "))
                }
            }
        }
        guard !targets.isEmpty else { log("FATAL no matching scenes"); exit(4) }

        var records: [PerfSceneRecord] = []
        for preset in targets {
            log("loading '\(preset.name)' (fractalType \(preset.fractalType.rawValue))")
            let job = ResolvedJob(
                name: preset.name, scene: preset.name,
                frames: cfg.frames, warmup: cfg.warmup,
                width: cfg.width, height: cfg.height,
                settleSeconds: 2.5,
                shadows: cfg.shadows,
                png: cfg.pngDir != nil,
                qc: cfg.qcOverride,
                params: cfg.paramOverride,
                ablate: nil)
            if let r = await measure(job: job, preset: preset, reload: true,
                                     appModel: appModel, renderer: renderer, settings: settings,
                                     pngDir: cfg.pngDir) {
                records.append(r.metrics)
            }
        }

        // Captured after the scene loop so QC overrides (applied per scene) are
        // reflected in the recorded config.
        let raymarch = PerfRaymarchConfig(from: settings.qualityConfig)
        writeOut(cfg: cfg, raymarch: raymarch, records: records)
        log("done → \(cfg.outPath)")
    }

    // MARK: - Helpers

    /// Encode BGRA8 (sRGB) bytes to a PNG file. Returns true on success.
    private static func writePNG(bytes: Data, width: Int, height: Int, bytesPerRow: Int, to path: String) -> Bool {
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: bytes as CFData) else { return false }
        // The offscreen target is bgra8Unorm_srgb → byteOrder32Little + skip-first alpha.
        let bitmapInfo = CGBitmapInfo(rawValue:
            CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let cg = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                               bytesPerRow: bytesPerRow, space: cs, bitmapInfo: bitmapInfo,
                               provider: provider, decode: nil, shouldInterpolate: false,
                               intent: .defaultIntent) else { return false }
        let url = URL(fileURLWithPath: path) as CFURL
        guard let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(dest, cg, nil)
        return CGImageDestinationFinalize(dest)
    }

    private static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let idx = min(sorted.count - 1, max(0, Int((p * Double(sorted.count)).rounded(.down))))
        return sorted[idx]
    }

    private static func makeRecord(preset: FractalPreset, gpu: [Double], cpuAvg: Double,
                                   iterAvg: Double, frames: Int, w: Int, h: Int,
                                   qc: QualityConfig) -> PerfSceneRecord {
        let g = gpu.sorted()
        let gpuAvg = g.isEmpty ? 0 : g.reduce(0, +) / Double(g.count)
        // Offscreen frames are rendered serially (commit → waitUntilCompleted), so
        // the GPU-bound ceiling fps is 1000 / gpuAvg. Reported as context only.
        let fps = gpuAvg > 0 ? 1000.0 / gpuAvg : 0
        return PerfSceneRecord(
            name: preset.name,
            fractalType: Int(preset.fractalType.rawValue),
            frames: frames,
            holdSeconds: 0,
            iterationsAvg: iterAvg,
            gpuMsAvg: gpuAvg,
            gpuMsMin: g.first ?? 0,
            gpuMsMax: g.last ?? 0,
            gpuMsP95: percentile(g, 0.95),
            fpsAvg: fps,
            fpsMin: g.last.map { $0 > 0 ? 1000.0 / $0 : 0 } ?? 0,
            cpuEncodeMsAvg: cpuAvg,
            renderPath: "mac-offscreen",
            drawableWidth: w,
            drawableHeight: h,
            tileSize: 0,
            iters: qc.baseFractalIterations,
            raySteps: qc.baseMaxRaySteps,
            views: 1)
    }

    private static func writeOut(cfg: Config, raymarch: PerfRaymarchConfig, records: [PerfSceneRecord]) {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let run = PerfRunRecord(
            capturedAt: iso.string(from: Date()),
            gitSHA: BuildStamp.gitSHA,
            gitDirty: BuildStamp.gitDirty,
            marketingVersion: BuildStamp.marketingVersion,
            buildNumber: BuildStamp.buildNumber,
            deviceModel: BuildStamp.deviceModel,
            osVersion: BuildStamp.osVersion,
            raymarch: raymarch,
            scenes: records)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(run) else { log("FATAL encode failed"); return }
        do {
            try data.write(to: URL(fileURLWithPath: cfg.outPath))
        } catch {
            log("FATAL write failed: \(error)")
        }

        appendPerfCSV(run: run, tag: ProcessInfo.processInfo.environment["THRESHOLD_PERF_TAG"] ?? "adhoc")
    }

    /// Optional CSV perf history: THRESHOLD_PERF_CSV=/path/perf_history.csv appends
    /// one row per scene per run, tagged by THRESHOLD_PERF_TAG, so GPU-time history
    /// reads as an experiment log (companion to the occupancy CSV).
    private static func appendPerfCSV(run: PerfRunRecord, tag: String) {
        guard let csvPath = ProcessInfo.processInfo.environment["THRESHOLD_PERF_CSV"] else { return }
        let dirty = run.gitDirty ? "dirty" : "clean"
        let rows = run.scenes.map { s in
            "\(run.capturedAt),\(run.gitSHA),\(dirty),\(tag),\(s.name),\(s.fractalType),"
            + "\(s.drawableWidth)x\(s.drawableHeight),\(s.renderPath),\(s.iters),"
            + String(format: "%.3f,%.3f,%.3f,%.2f", s.gpuMsAvg, s.gpuMsP95, s.gpuMsMax, s.iterationsAvg)
        }
        let body = rows.joined(separator: "\n") + "\n"
        let fm = FileManager.default
        if !fm.fileExists(atPath: csvPath) {
            let header = "timestamp,gitSHA,gitState,tag,scene,fractalType,size,renderPath,iters,gpuMsAvg,gpuMsP95,gpuMsMax,stepsAvg\n"
            try? (header + body).write(toFile: csvPath, atomically: true, encoding: .utf8)
            log("perf CSV created → \(csvPath) (\(rows.count) rows, tag=\(tag))")
        } else if let h = FileHandle(forWritingAtPath: csvPath) {
            h.seekToEndOfFile(); h.write(Data(body.utf8)); try? h.close()
            log("perf CSV appended → \(csvPath) (\(rows.count) rows, tag=\(tag))")
        }
    }
}
#endif
