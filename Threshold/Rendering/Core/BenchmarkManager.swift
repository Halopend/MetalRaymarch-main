//
//  BenchmarkManager.swift
//  Threshold
//
//  Per-scene performance accumulator for the benchmark sweep (PerfSweepRunner).
//  `recordSample` is fed every frame from the render completion thread (via
//  RendererRenderSupport.recordFramePerf); begin/endScene are driven from the
//  MainActor sweep. Release-safe: when no sweep is active the hot path costs one
//  bool read. Produces a `PerfSceneRecord` per scene for the per-build perf log.
//

import Foundation
import os

final class BenchmarkManager: @unchecked Sendable {
    static let shared = BenchmarkManager()

    /// Cheap, lock-free gate checked on the hot path so a normal (non-benchmark)
    /// frame never takes the lock. Racy by design — correctness comes from the
    /// lock inside the begin/record/end methods.
    private(set) nonisolated(unsafe) var isCapturing = false

    /// When true the renderer enables the in-kernel iteration counter (binds the
    /// counter buffer + sets the uniform flag) so "iterations to converge" is only
    /// measured during a sweep. Racy gate — set on the main actor, read on the
    /// render thread; that's fine for a measurement toggle.
    nonisolated(unsafe) var collectIterations = false

    /// Continuous "steps to converge" profiling driven by the Performance ▸ Metrics
    /// dashboard toggle, independent of a benchmark sweep. Arms the same in-kernel
    /// counter so the average is surfaced live to RenderMetrics.avgStepsPerPixel.
    /// Default off: the per-hit-ray atomics add GPU cost that would distort the
    /// frame-time reading shown beside it, so the user opts in to measure. Racy
    /// gate — set on the main actor, read on the render thread.
    nonisolated(unsafe) var liveStepMeasurement = false

    /// The renderer arms the iteration counter (binds the buffer + sets
    /// `benchCollectSteps`) whenever a sweep OR the live dashboard wants it.
    var shouldCollectSteps: Bool { collectIterations || liveStepMeasurement }

    private var lock = os_unfair_lock()
    private var accum: SceneAccum?

    private struct SceneAccum {
        let name: String
        let fractalType: Int
        var frames = 0
        var gpu: [Double] = []           // all GPU-ms samples, for percentiles
        var totalCPU = 0.0
        var totalFrame = 0.0
        var fpsMin = Double.greatestFiniteMagnitude
        // Average march iterations to converge — the headline metric. Summed as
        // per-frame averages (the GPU counter is read back once per frame).
        var iterSum = 0.0
        var iterFrames = 0
        // Latest render context (identical every frame within a scene).
        var renderPath = "—"
        var drawableWidth = 0
        var drawableHeight = 0
        var tileSize = 0
        var iters = 0
        var raySteps = 0
        var views = 0
    }

    /// Start accumulating frames for a scene. Called after the scene has settled.
    func beginScene(name: String, fractalType: Int) {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        accum = SceneAccum(name: name, fractalType: fractalType)
        isCapturing = true
    }

    /// Fed once per rendered frame from the render thread while a scene is active.
    func recordSample(gpuMs: Double?, cpuMs: Double, frameTimeMs: Double,
                      iterationsAvg: Double? = nil,
                      renderPath: String, drawableWidth: Int, drawableHeight: Int,
                      tileSize: Int, iters: Int, raySteps: Int, views: Int) {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        guard accum != nil else { return }
        accum!.frames += 1
        if let g = gpuMs, g > 0 { accum!.gpu.append(g) }
        if let it = iterationsAvg, it > 0 { accum!.iterSum += it; accum!.iterFrames += 1 }
        accum!.totalCPU += cpuMs
        accum!.totalFrame += frameTimeMs
        if frameTimeMs > 0 { accum!.fpsMin = min(accum!.fpsMin, 1000.0 / frameTimeMs) }
        accum!.renderPath = renderPath
        accum!.drawableWidth = drawableWidth
        accum!.drawableHeight = drawableHeight
        accum!.tileSize = tileSize
        accum!.iters = iters
        accum!.raySteps = raySteps
        accum!.views = views
    }

    /// Stop the current scene and produce its record (nil if no frames landed).
    func endScene(holdSeconds: Double) -> PerfSceneRecord? {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        defer { accum = nil; isCapturing = false }
        guard let a = accum, a.frames > 0 else { return nil }

        let gpu = a.gpu.sorted()
        func percentile(_ p: Double) -> Double {
            guard !gpu.isEmpty else { return 0 }
            let idx = min(gpu.count - 1, max(0, Int((p * Double(gpu.count)).rounded(.down))))
            return gpu[idx]
        }
        let gpuAvg = gpu.isEmpty ? 0 : gpu.reduce(0, +) / Double(gpu.count)
        let avgFrame = a.totalFrame / Double(a.frames)

        return PerfSceneRecord(
            name: a.name, fractalType: a.fractalType, frames: a.frames, holdSeconds: holdSeconds,
            iterationsAvg: a.iterFrames > 0 ? a.iterSum / Double(a.iterFrames) : 0,
            gpuMsAvg: gpuAvg, gpuMsMin: gpu.first ?? 0, gpuMsMax: gpu.last ?? 0, gpuMsP95: percentile(0.95),
            fpsAvg: avgFrame > 0 ? 1000.0 / avgFrame : 0,
            fpsMin: a.fpsMin == .greatestFiniteMagnitude ? 0 : a.fpsMin,
            cpuEncodeMsAvg: a.totalCPU / Double(a.frames),
            renderPath: a.renderPath, drawableWidth: a.drawableWidth, drawableHeight: a.drawableHeight,
            tileSize: a.tileSize, iters: a.iters, raySteps: a.raySteps, views: a.views)
    }

    /// Abort any in-progress capture (e.g. the sweep was cancelled).
    func cancel() {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        accum = nil
        isCapturing = false
    }
}
