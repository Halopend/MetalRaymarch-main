//
//  FramePacingTracker.swift
//  Threshold
//
//  Presentation-based frame pacing statistics. Unlike the simulation delta used
//  by the renderer, these samples come from CAMetalDrawable.presentedTime and
//  therefore include main-thread stalls, drawable starvation, and GPU overruns.
//

import Foundation

struct FramePacingSnapshot: Equatable, Sendable {
    var fps: Double = 0
    var frameGapP95Ms: Double = 0
    var frameGapP99Ms: Double = 0
    var maximumFrameGapMs: Double = 0
    var hitchCount: Int = 0
    var sampleCount: Int = 0
    /// Populated only by `recordPresentation` for the frame just recorded.
    /// A plain `snapshot()` is an aggregate and leaves these event fields clear.
    var lastFrameGapMs: Double = 0
    var didRecordHitch: Bool = false
}

struct FramePacingTracker: Sendable {
    private static let maximumRetainedSamples = 240
    private static let absoluteHitchThresholdMs = 33.3

    private var lastPresentedTime: TimeInterval?
    private var frameGapsMs: [Double] = []
    private var cumulativeHitchCount = 0

    mutating func recordPresentation(at presentedTime: TimeInterval) -> FramePacingSnapshot {
        guard presentedTime.isFinite, presentedTime > 0 else { return snapshot() }
        defer { lastPresentedTime = presentedTime }

        guard let lastPresentedTime else { return snapshot() }
        let gapMs = (presentedTime - lastPresentedTime) * 1_000.0
        guard gapMs.isFinite, gapMs > 0 else { return snapshot() }

        // A frame after wake/backgrounding should not poison the rolling window.
        // It is still a visible discontinuity, so account for it as one hitch.
        if gapMs > 2_000 {
            cumulativeHitchCount += 1
            frameGapsMs.removeAll(keepingCapacity: true)
            return snapshot(
                maximumOverride: gapMs,
                lastFrameGapMs: gapMs,
                didRecordHitch: true
            )
        }

        let previousMedian = percentile(frameGapsMs, 0.5)
        let relativeThreshold = previousMedian > 0 ? previousMedian * 2.0 : 0
        let didRecordHitch = gapMs > max(Self.absoluteHitchThresholdMs, relativeThreshold)
        if didRecordHitch {
            cumulativeHitchCount += 1
        }

        frameGapsMs.append(gapMs)
        if frameGapsMs.count > Self.maximumRetainedSamples {
            frameGapsMs.removeFirst(frameGapsMs.count - Self.maximumRetainedSamples)
        }
        return snapshot(
            maximumOverride: nil,
            lastFrameGapMs: gapMs,
            didRecordHitch: didRecordHitch
        )
    }

    func snapshot() -> FramePacingSnapshot {
        snapshot(maximumOverride: nil, lastFrameGapMs: 0, didRecordHitch: false)
    }

    private func snapshot(
        maximumOverride: Double?,
        lastFrameGapMs: Double,
        didRecordHitch: Bool
    ) -> FramePacingSnapshot {
        guard !frameGapsMs.isEmpty else {
            return FramePacingSnapshot(
                maximumFrameGapMs: maximumOverride ?? 0,
                hitchCount: cumulativeHitchCount,
                lastFrameGapMs: lastFrameGapMs,
                didRecordHitch: didRecordHitch
            )
        }

        let meanGap = frameGapsMs.reduce(0, +) / Double(frameGapsMs.count)
        return FramePacingSnapshot(
            fps: meanGap > 0 ? 1_000.0 / meanGap : 0,
            frameGapP95Ms: percentile(frameGapsMs, 0.95),
            frameGapP99Ms: percentile(frameGapsMs, 0.99),
            maximumFrameGapMs: max(maximumOverride ?? 0, frameGapsMs.max() ?? 0),
            hitchCount: cumulativeHitchCount,
            sampleCount: frameGapsMs.count,
            lastFrameGapMs: lastFrameGapMs,
            didRecordHitch: didRecordHitch
        )
    }

    private func percentile(_ values: [Double], _ percentile: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        guard sorted.count > 1 else { return sorted[0] }
        let position = Double(sorted.count - 1) * percentile
        let lower = Int(position.rounded(.down))
        let upper = min(lower + 1, sorted.count - 1)
        let fraction = position - Double(lower)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * fraction
    }
}
