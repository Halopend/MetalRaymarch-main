//
//  PerfSweepRunner.swift
//  Threshold
//
//  Drives a deterministic on-device performance sweep for the per-build perf log
//  (Vision Pro focus). For each curated scene it: loads the scene, lets it settle,
//  measures GPU/CPU/FPS over a hold window (via BenchmarkManager fed by the render
//  loop), then writes one PerfRunRecord to the device PerfLog (see PerfLog).
//
//  Trigger: the "Run Benchmark Sweep" button in Settings. Run it while the
//  immersive view is up — that's where frames are actually rendered.
//

import Foundation
import Observation

@MainActor
@Observable
final class PerfSweepRunner {
    private(set) var isRunning = false
    private(set) var progressText = "Idle"
    private(set) var currentScene = 0
    private(set) var totalScenes = 0
    private(set) var lastResultPath: String?

    /// Seconds to let a freshly-loaded scene settle (camera/animation/geometry)
    /// before measuring, so load transients don't pollute the numbers.
    var settleSeconds: Double = 2.0
    /// Seconds to measure each scene.
    var holdSeconds: Double = 8.0
    /// Cap on distinct scenes in the curated subset (~1–2 min total).
    var maxScenes: Int = 10

    private var task: Task<Void, Never>?

    func start(appModel: AppModel) {
        guard !isRunning else { return }
        task = Task { @MainActor in await self.run(appModel: appModel) }
    }

    func cancel() {
        task?.cancel()
        BenchmarkManager.shared.cancel()
    }

    private func run(appModel: AppModel) async {
        let scenes = curatedScenes(appModel: appModel)
        guard !scenes.isEmpty else { progressText = "No scenes to sweep"; return }

        isRunning = true
        totalScenes = scenes.count
        lastResultPath = nil
        defer { isRunning = false }

        // Force the fragment full-march path during the sweep so "iterations to
        // converge" is measured consistently (the compute path's coarse seeding
        // makes its fine-march count path-dependent). Restore the user's mode after.
        let settings = appModel.renderSettings
        let userTileSize = settings.tileSize
        let userResolutionScale = settings.resolutionScale
        settings.tileSize = 0           // fragment full-march path (instrumented)
        settings.resolutionScale = 1.0  // native res → no MetalFX warm-start undercount
        BenchmarkManager.shared.collectIterations = true
        defer {
            settings.tileSize = userTileSize
            settings.resolutionScale = userResolutionScale
            BenchmarkManager.shared.collectIterations = false
        }

        let raymarch = PerfRaymarchConfig(from: settings.qualityConfig)

        var records: [PerfSceneRecord] = []
        for (i, scene) in scenes.enumerated() {
            if Task.isCancelled { BenchmarkManager.shared.cancel(); progressText = "Cancelled"; return }
            currentScene = i + 1
            progressText = "Loading \(scene.name) (\(i + 1)/\(scenes.count))"
            appModel.loadStaticScene(scene)
            try? await Task.sleep(for: .seconds(settleSeconds))

            BenchmarkManager.shared.beginScene(name: scene.name, fractalType: Int(scene.fractalType.rawValue))
            progressText = "Measuring \(scene.name) (\(i + 1)/\(scenes.count))"
            try? await Task.sleep(for: .seconds(holdSeconds))

            if let record = BenchmarkManager.shared.endScene(holdSeconds: holdSeconds) {
                records.append(record)
            }
        }

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

        lastResultPath = PerfLog.write(run)
        if records.isEmpty {
            progressText = "Done — no frames captured (is the immersive view running?)"
        } else {
            let file = lastResultPath.map { ($0 as NSString).lastPathComponent } ?? "perf-log.jsonl"
            progressText = "Saved \(records.count) scenes → \(file)"
        }
    }

    /// One representative scene per distinct fractal type, in the bundled order,
    /// capped at `maxScenes`. Static (keyboard-switchable) presets only, so runs
    /// are reproducible — excludes the music-reactive scenes (audio variance).
    private func curatedScenes(appModel: AppModel) -> [FractalPreset] {
        let all = appModel.presetManager.presets
            .filter { $0.name != "__lastState__" && $0.isKeyboardSwitchableStaticPreset }
        var seenTypes = Set<Int>()
        var picked: [FractalPreset] = []
        for preset in all {
            let type = Int(preset.fractalType.rawValue)
            if seenTypes.insert(type).inserted {
                picked.append(preset)
                if picked.count >= maxScenes { break }
            }
        }
        return picked
    }
}
