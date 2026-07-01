//
//  RenderSignposts.swift
//  Threshold
//
//  os_signpost instrumentation for the render loop, for use with Xcode
//  Instruments (Points of Interest, os_signpost, and — via `traceGPU` —
//  correlation against the Metal System Trace instrument).
//
//  Signposts are effectively free when nothing is recording (the underlying
//  os_signpost call short-circuits on an inactive logging channel), so this
//  stays compiled into Release builds rather than being gated behind DEBUG.
//
//  Usage:
//    let state = RenderTrace.begin("Clock Wait")
//    ...
//    RenderTrace.end("Clock Wait", state)
//
//  Or, for a whole function scope with multiple return paths:
//    let state = RenderTrace.begin("Frame")
//    defer { RenderTrace.end("Frame", state) }
//
//  To view: Xcode → Product → Profile (⌘I) → "Blank" or "Points of Interest"
//  template → Instruments → "Points of Interest" or "os_signpost" instrument,
//  filtered to subsystem "com.puppypower.Threshold" / category "Rendering".

import os
import Metal

enum RenderTrace {
    /// Single shared signposter for all render-loop tracing. One category
    /// keeps every phase on the same Instruments track so frame phases line
    /// up visually against each other and against GPU work.
    static let signposter = OSSignposter(subsystem: "com.puppypower.Threshold", category: "Rendering")

    /// Begins a named signpost interval. Each call gets a fresh signpost ID so
    /// overlapping/nested intervals with the same name (e.g. two frames
    /// in-flight at once) don't get merged in the Instruments UI.
    @inline(__always)
    static func begin(_ name: StaticString) -> OSSignpostIntervalState {
        signposter.beginInterval(name, id: signposter.makeSignpostID())
    }

    @inline(__always)
    static func end(_ name: StaticString, _ state: OSSignpostIntervalState) {
        signposter.endInterval(name, state)
    }

    /// A single point-in-time marker (no duration), for one-off events like
    /// "GPU stall detected" or "pipeline rebuilt".
    @inline(__always)
    static func event(_ name: StaticString) {
        signposter.emitEvent(name)
    }

    @inline(__always)
    static func event(_ name: StaticString, _ message: String) {
        signposter.emitEvent(name, "\(message)")
    }

    /// Brackets a Metal command buffer's commit→completion lifetime as a
    /// signpost interval. Call once, right after the command buffer is
    /// created (before any of its possible `commit()` call sites) — the
    /// completion handler fires the matching `end` regardless of which commit
    /// path the frame takes.
    ///
    /// Note this measures submission-to-completion latency (CPU-observed),
    /// not raw GPU busy time — `MTLCommandBuffer.gpuStartTime`/`gpuEndTime`
    /// remain the source of truth for that and are already tracked
    /// separately (see `PerfLog`/`frameBreakdown`). This signpost exists so
    /// that latency is visible on the same Instruments timeline as the CPU
    /// phases, for correlating stalls.
    static func traceGPU(_ name: StaticString, commandBuffer: MTLCommandBuffer) {
        let state = begin(name)
        commandBuffer.addCompletedHandler { _ in
            end(name, state)
        }
    }
}
