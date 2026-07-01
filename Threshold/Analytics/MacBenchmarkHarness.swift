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
//

#if os(macOS)
import Foundation
import Metal
import QuartzCore

@MainActor
enum MacBenchmarkHarness {

    struct Config {
        var scenes: [String]
        var frames: Int
        var warmup: Int
        var width: Int
        var height: Int
        var outPath: String
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
        return Config(scenes: scenes,
                      frames: intEnv("THRESHOLD_BENCHMARK_FRAMES", 240),
                      warmup: intEnv("THRESHOLD_BENCHMARK_WARMUP", 60),
                      width: w, height: h, outPath: out)
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

        let raymarch = PerfRaymarchConfig(from: settings.qualityConfig)
        var records: [PerfSceneRecord] = []

        for preset in targets {
            log("loading '\(preset.name)' (fractalType \(preset.fractalType.rawValue))")
            appModel.loadStaticScene(preset)
            // Let the eased apply + any embedded-DE compile land before warmup.
            try? await Task.sleep(for: .seconds(1.0))

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
        }

        writeOut(cfg: cfg, raymarch: raymarch, records: records)
        log("done → \(cfg.outPath)")
        try? await Task.sleep(for: .milliseconds(200))
        exit(0)
    }

    // MARK: - Helpers

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
