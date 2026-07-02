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
//  offscreen with `ThresholdMacRenderer.renderBenchmarkFrame` decouples the
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
        /// Bulatov MaxReflections to 12. Used for sensitivity sweeps.
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
        try? await Task.sleep(for: .milliseconds(500))

        guard let device = MTLCreateSystemDefaultDevice() else { log("FATAL no Metal device"); exit(2) }
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm_srgb
        let inputController = ThresholdMacInputController()
        guard let renderer = ThresholdMacRenderer(
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
        if let planPath = env["THRESHOLD_BENCHMARK_PLAN"] {
            await runPlan(path: planPath, appModel: appModel, renderer: renderer, settings: settings)
        } else {
            await runEnvMode(appModel: appModel, renderer: renderer, settings: settings)
        }
        try? await Task.sleep(for: .milliseconds(200))
        exit(0)
    }

    // MARK: - Plan mode (one launch, scene × config matrix)

    private static func runPlan(path: String, appModel: AppModel,
                                renderer: ThresholdMacRenderer, settings: RenderSettings) async {
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

        let all = appModel.presetManager.presets.filter { $0.name != "__lastState__" }
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
                                appModel: AppModel, renderer: ThresholdMacRenderer,
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
        ThresholdMacRenderer.benchAblateMode = job.ablate ?? ThresholdMacRenderer.benchAblateModeEnvDefault

        // Provenance guard: log the quality values actually in effect so a
        // measurement made with the wrong iteration/step budget is visible in the
        // run log instead of silently producing a bogus number.
        let qcNow = settings.qualityConfig
        log("  effective iters=\(qcNow.baseFractalIterations) raySteps=\(qcNow.baseMaxRaySteps) "
            + "resScale=\(settings.resolutionScale) shadows=\(settings.shadowsEnabled)"
            + (job.ablate.map { " ablate=\($0)" } ?? ""))

        // Freeze animation phases + disable the auto color-scheme cycler for
        // the whole job so measurement and capture are run-deterministic.
        if pngDir != nil { settings.benchFreezeAnimationPhases() }

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
                                   renderer: ThresholdMacRenderer, settings: RenderSettings) async {
        let cfg = configFromEnv()
        log("start scenes=\(cfg.scenes.isEmpty ? "<all>" : cfg.scenes.joined(separator: ",")) "
            + "frames=\(cfg.frames) warmup=\(cfg.warmup) size=\(cfg.width)x\(cfg.height)")

        // Resolve requested scenes by exact name.
        let all = appModel.presetManager.presets.filter { $0.name != "__lastState__" }
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
    }
}
#endif
