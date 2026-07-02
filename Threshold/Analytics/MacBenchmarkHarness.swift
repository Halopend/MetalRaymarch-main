//
//  MacBenchmarkHarness.swift
//  Threshold
//
//  Headless, offscreen performance harness for the Mac renderer. When the app is
//  launched with THRESHOLD_BENCHMARK=1, this drives the real raymarch pipeline in
//  a tight loop into an offscreen texture (no window / display link required),
//  sweeps a caller-named set of scenes, and writes one machine-readable
//  PerfRunRecord to disk before exiting. A driver script reads that JSON to report
//  bottlenecks.
//
//  Why offscreen: the MTKView render loop is display-link driven, which the
//  window server throttles to near-zero for a window that isn't the composited
//  foreground — so an unattended run produces almost no frames. Rendering
//  offscreen with `ThresholdMacRenderer.renderBenchmarkFrame` decouples the
//  benchmark from compositing while staying faithful to the shipping shader.
//
//  Env config (all optional except SCENES):
//    THRESHOLD_BENCHMARK=1                 enable the harness (see BenchmarkMode)
//    THRESHOLD_BENCHMARK_SCENES=a,b,c      comma-separated scene names (default: all
//                                          keyboard-switchable static presets)
//    THRESHOLD_BENCHMARK_FRAMES=240        measured frames per scene
//    THRESHOLD_BENCHMARK_WARMUP=60         warmup frames per scene (discarded)
//    THRESHOLD_BENCHMARK_SIZE=1920x1080    offscreen render resolution
//    THRESHOLD_BENCHMARK_OUT=/path.json    output path for the PerfRunRecord JSON
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
            case "coarsePrepassWarmStartEnabled": qc.coarsePrepassWarmStartEnabled = v != 0
            case "coherentPacketEnabled":        qc.coherentPacketEnabled = v != 0
            case "foveationStrength":            qc.foveationStrength = v
            case "baseFractalIterations":        qc.baseFractalIterations = Int(v)
            case "baseMaxRaySteps":              qc.baseMaxRaySteps = Int(v)
            default: log("  WARN unknown QC override key '\(key)' — skipped")
            }
        }
        settings.qualityConfig = qc
        log("  applied QC override \(pairs.map { "\($0.0)=\($0.1)" }.joined(separator: ","))")
    }

    private static func log(_ s: String) {
        FileHandle.standardError.write(Data("🏁 [bench] \(s)\n".utf8))
    }

    static func configFromEnv() -> Config {
        let env = ProcessInfo.processInfo.environment
        let scenes = (env["THRESHOLD_BENCHMARK_SCENES"] ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        func intEnv(_ k: String, _ d: Int) -> Int { env[k].flatMap { Int($0) } ?? d }
        var w = 1920, h = 1080
        if let size = env["THRESHOLD_BENCHMARK_SIZE"], let x = size.firstIndex(of: "x") {
            w = Int(size[..<x]) ?? w
            h = Int(size[size.index(after: x)...]) ?? h
        }
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

    static func run(appModel: AppModel) async {
        let cfg = configFromEnv()
        log("start scenes=\(cfg.scenes.isEmpty ? "<all>" : cfg.scenes.joined(separator: ",")) "
            + "frames=\(cfg.frames) warmup=\(cfg.warmup) size=\(cfg.width)x\(cfg.height)")

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
        renderer.drawableSizeDidChange(CGSize(width: cfg.width, height: cfg.height))

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

        // Resolve requested scenes by exact name.
        let all = appModel.presetManager.presets.filter { $0.name != "__lastState__" }
        var targets: [FractalPreset] = []
        if cfg.scenes.isEmpty {
            targets = all.filter { $0.isKeyboardSwitchableStaticPreset }
        } else {
            for name in cfg.scenes {
                if let p = all.first(where: { $0.name == name }) {
                    targets.append(p)
                } else if name == "Mandelbox" || name == "__default__"
                            || name.caseInsensitiveCompare("start") == .orderedSame {
                    // The app's startup scene is a built-in mandelbox default, not a
                    // bundled .threshscene, so resolve it directly.
                    targets.append(PresetManager.mandelboxDefaultPreset())
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
            appModel.loadStaticScene(preset)
            // Let the (snapped) apply + any embedded-DE compile + the renderer's
            // exponential camera smoothers settle before warmup.
            try? await Task.sleep(for: .seconds(2.5))

            // Re-assert shadow override after the scene's own value has applied.
            if let s = cfg.shadows { settings.shadowsEnabled = s; log("  forced shadows=\(s)") }

            // Pin the acceleration levers (and any other QualityConfig field)
            // after the scene apply so the measured config is exactly what the
            // caller asked for.
            applyQCOverride(cfg.qcOverride, to: settings)

            // Provenance guard: log the quality values actually in effect so a
            // measurement made with the wrong iteration/step budget (stale
            // persisted state, a preset resolving to an unexpected copy, an
            // apply that didn't land) is visible in the run log instead of
            // silently producing a bogus number. Compare against the scene
            // file's authored fractalIterations/maxRaySteps when in doubt.
            let qcNow = settings.qualityConfig
            log("  effective iters=\(qcNow.baseFractalIterations) raySteps=\(qcNow.baseMaxRaySteps) "
                + "resScale=\(settings.resolutionScale) shadows=\(settings.shadowsEnabled)")

            // Freeze animation phases + disable the auto color-scheme cycler for
            // the whole scene so measurement and capture are run-deterministic
            // (the cycler otherwise advances on wall-clock mid-scene).
            if cfg.pngDir != nil { settings.benchFreezeAnimationPhases() }

            // Apply formula-param overrides (e.g. MaxReflections sweep) after the
            // eased apply has settled, so they aren't stomped by the transition.
            if !cfg.paramOverride.isEmpty {
                var fp = settings.formulaParams
                for (i, v) in cfg.paramOverride { FormulaCatalog.setParam(&fp, index: i, value: v) }
                settings.formulaParams = fp
                log("  applied param override \(cfg.paramOverride.map { "\($0.0)=\($0.1)" }.joined(separator: ","))")
                try? await Task.sleep(for: .milliseconds(300))
            }

            for _ in 0..<cfg.warmup {
                _ = renderer.renderBenchmarkFrame(appModel: appModel, width: cfg.width, height: cfg.height)
            }

            var gpu: [Double] = []
            var cpuSum = 0.0
            var stepSum = 0.0
            var stepN = 0
            var measured = 0
            for _ in 0..<cfg.frames {
                guard let m = renderer.renderBenchmarkFrame(appModel: appModel,
                                                            width: cfg.width, height: cfg.height) else { continue }
                measured += 1
                if m.gpuMs > 0 { gpu.append(m.gpuMs) }
                cpuSum += m.cpuEncodeMs
                if m.avgSteps > 0 { stepSum += m.avgSteps; stepN += 1 }
            }

            let rec = makeRecord(preset: preset, gpu: gpu,
                                 cpuAvg: cpuSum / Double(max(measured, 1)),
                                 iterAvg: stepN > 0 ? stepSum / Double(stepN) : 0,
                                 frames: measured, w: cfg.width, h: cfg.height,
                                 qc: settings.qualityConfig)
            records.append(rec)
            log(String(format: "  '%@' → gpu avg %.2fms  p95 %.2fms  max %.2fms  steps %.1f  cpuEnc %.2fms",
                       preset.name, rec.gpuMsAvg, rec.gpuMsP95, rec.gpuMsMax, rec.iterationsAvg, rec.cpuEncodeMsAvg))

            if cfg.pngDir != nil {
                // Pin all CPU-side animation phase accumulators so the capture is
                // phase-deterministic across runs (see benchFreezeAnimationPhases).
                settings.benchFreezeAnimationPhases()
            }
            if let dir = cfg.pngDir,
               let cap = renderer.captureBenchmarkBytes(appModel: appModel, width: cfg.width, height: cfg.height) {
                let safe = preset.name.replacingOccurrences(of: "/", with: "_")
                let path = (dir as NSString).appendingPathComponent("\(safe).png")
                if writePNG(bytes: cap.bytes, width: cfg.width, height: cfg.height,
                            bytesPerRow: cap.bytesPerRow, to: path) {
                    log("  wrote \(path)")
                } else {
                    log("  PNG write FAILED for '\(preset.name)'")
                }
            }
        }

        // Captured after the scene loop so QC overrides (applied per scene) are
        // reflected in the recorded config.
        let raymarch = PerfRaymarchConfig(from: settings.qualityConfig)
        writeOut(cfg: cfg, raymarch: raymarch, records: records)
        log("done → \(cfg.outPath)")
        try? await Task.sleep(for: .milliseconds(200))
        exit(0)
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
