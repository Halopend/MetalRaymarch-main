//
//  BenchmarkMode.swift
//  Threshold
//
//  Opt-in, env-gated benchmark harness switch. When the app is launched with
//  THRESHOLD_BENCHMARK=1 in its environment, the render loop keeps drawing even
//  while the app is not frontmost (the normal `isAppActive` power gate is
//  bypassed), so an unattended profiler run (xctrace / Instruments) captures a
//  continuous render workload instead of a single stalled frame.
//
//  This is strictly a measurement affordance: it is off unless the env var is
//  explicitly set, so it has zero effect on shipping/interactive behavior.
//

import Foundation

enum BenchmarkMode {
    /// True when the process was launched for an automated performance capture.
    /// Read once at launch — the environment does not change during a run.
    static let isActive: Bool =
        ProcessInfo.processInfo.environment["THRESHOLD_BENCHMARK"] == "1"
}
