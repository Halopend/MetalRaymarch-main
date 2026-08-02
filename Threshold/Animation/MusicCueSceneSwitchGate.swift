//
//  MusicCueSceneSwitchGate.swift
//  Threshold
//
//  Edge-triggered gate for advancing animation scenes from audio onsets.
//  Kept independent of audio capture and scene loading so its timing policy
//  remains deterministic and regression-testable.
//

import Foundation

struct MusicCueSceneSwitchGate: Sendable {
    private var wasAboveThreshold = false
    private(set) var lastTriggerTime: TimeInterval?

    /// Returns `true` once when an active audio onset crosses the configured
    /// threshold and the cooldown has elapsed. A sustained onset cannot fire
    /// repeatedly; it must fall below the threshold before it can arm again.
    mutating func consume(
        onset: Float,
        isEnabled: Bool,
        isAudioActive: Bool,
        threshold: Float,
        minimumInterval: TimeInterval,
        at timestamp: TimeInterval
    ) -> Bool {
        guard isEnabled, isAudioActive, timestamp.isFinite else {
            reset()
            return false
        }

        let normalizedOnset = onset.isFinite ? onset.clamped(to: 0...1) : 0
        let normalizedThreshold = threshold.isFinite
            ? threshold.clamped(to: 0.05...1)
            : 0.7
        let normalizedInterval = minimumInterval.isFinite
            ? max(0, minimumInterval)
            : 0
        let isAboveThreshold = normalizedOnset >= normalizedThreshold
        defer { wasAboveThreshold = isAboveThreshold }

        guard isAboveThreshold, !wasAboveThreshold else { return false }
        if let lastTriggerTime,
           timestamp - lastTriggerTime < normalizedInterval {
            return false
        }

        lastTriggerTime = timestamp
        return true
    }

    mutating func reset() {
        wasAboveThreshold = false
        lastTriggerTime = nil
    }
}
