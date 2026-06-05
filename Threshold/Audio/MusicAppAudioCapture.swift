//
//  MusicAppAudioCapture.swift
//  Threshold
//
//  macOS-only: captures whole-system audio output via ScreenCaptureKit and
//  feeds it into AudioAnalyzer for FFT analysis.
//
//  This is the supported public path for reacting to any audio playing on the
//  Mac (browsers, Spotify, Music.app, games, …). It uses a display-scoped
//  content filter — NOT an app/PID-scoped one — because per-application capture
//  requires resolving another process's PID via a mach-lookup the App Sandbox
//  forbids without an App-Store-rejected entitlement. Requires user-granted
//  Screen Recording permission. Sandbox-safe; no private APIs.
//

#if os(macOS)

import AVFoundation
import CoreGraphics
@preconcurrency import ScreenCaptureKit
import Observation
import os

@MainActor
@Observable
final class MusicAppAudioCapture {

    // MARK: - Observable state

    private(set) var isCapturing: Bool = false
    private(set) var errorMessage: String?
    /// True when a capture target (a display) is available. With whole-system
    /// audio capture there is no per-app requirement, so this reflects display
    /// availability rather than whether any specific app is running.
    private(set) var hasSystemAudioTarget: Bool = false

    // MARK: - Dependencies

    private let analyzer: AudioAnalyzer
    private let logger = Logger(subsystem: "com.puppypower.Threshold", category: "MusicAppCapture")

    // MARK: - Capture state

    private var stream: SCStream?
    private var output: AudioStreamOutput?
    private var videoOutput: NoopVideoStreamOutput?
    private let sampleQueue = DispatchQueue(label: "com.puppypower.Threshold.MusicAppCapture.audio",
                                            qos: .userInitiated)

    init(analyzer: AudioAnalyzer) {
        self.analyzer = analyzer
    }

    // MARK: - Availability

    /// Refresh whether a capture target (display) is available for whole-system
    /// audio capture. Safe to call without Screen Recording permission; on denial
    /// `errorMessage` will explain how to grant access.
    func refreshAvailability() async {
        // Probe via SCShareableContent (the real SCK gate) rather than
        // CGPreflightScreenCaptureAccess(), which gives false negatives for dev
        // builds and drives the spurious re-prompt loop.
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )

            // Whole-system capture only needs a display, not a specific app.
            hasSystemAudioTarget = !content.displays.isEmpty
            if errorMessage?.hasPrefix("Screen Recording") == true {
                errorMessage = nil
            }
        } catch {
            hasSystemAudioTarget = false
            errorMessage = screenCapturePermissionMessage(needsRelaunch: false)
            logger.error("🎙️[SysAudio] refreshAvailability SCShareableContent failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Capture lifecycle

    /// Start capturing whole-system audio output. ScreenCaptureKit captures the
    /// entire display's audio when given a display-scoped content filter; we do
    /// NOT target a specific application because resolving another process's PID
    /// requires a `mach-lookup` the App Sandbox forbids (and the entitlement that
    /// would silence it is rejected by the App Store). `excludesCurrentProcessAudio`
    /// removes our own output so the visualizer never feeds back into itself.
    func reactivateSecurityPermissions() async {
        print("🎙️[SysAudio] reactivateSecurityPermissions() called")
        logger.notice("🎙️[SysAudio] reactivateSecurityPermissions() called")
        await refreshAvailability()
        guard !hasSystemAudioTarget else {
            print("🎙️[SysAudio] permission already usable — target available")
            return
        }

        // SCShareableContent failed → no access for this binary yet. Trigger the
        // system prompt exactly once and ask the user to relaunch. We only reach
        // here on a real SCK denial, avoiding the CGPreflight false-negative loop.
        let requested = CGRequestScreenCaptureAccess()
        logger.notice("🎙️[SysAudio] reactivate: CGRequestScreenCaptureAccess() = \(requested, privacy: .public)")
        print("🎙️[SysAudio] reactivate: CGRequestScreenCaptureAccess() = \(requested)")
        if requested {
            errorMessage = screenCapturePermissionMessage(needsRelaunch: true)
        } else {
            errorMessage = screenCapturePermissionMessage(needsRelaunch: false)
        }
        await refreshAvailability()
    }

    func start() async {
        print("🎙️[SysAudio] start() called — isCapturing=\(isCapturing)")
        logger.notice("🎙️[SysAudio] start() called — isCapturing=\(self.isCapturing, privacy: .public)")
        guard !isCapturing else { return }

        // Log the CGPreflight state for diagnostics, but DO NOT hard-gate on it.
        // For audio-only ScreenCaptureKit capture the canonical permission gate
        // is whether `SCShareableContent` succeeds — `CGPreflightScreenCaptureAccess()`
        // checks the *Screen Recording* TCC record, which frequently returns a
        // false negative for dev builds whose code signature/path differs from
        // the granted record, causing the "re-prompt every launch" loop. We trust
        // SCK's own gate instead.
        let preflight = CGPreflightScreenCaptureAccess()
        logger.notice("🎙️[SysAudio] CGPreflightScreenCaptureAccess() = \(preflight, privacy: .public) (diagnostic only — not gating)")
        print("🎙️[SysAudio] CGPreflightScreenCaptureAccess() = \(preflight) (diagnostic only)")

        // Probe permission by attempting to enumerate shareable content. This is
        // the real SCK permission gate: it throws if the user hasn't granted
        // Screen & System Audio Recording for THIS binary.
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
            guard !Task.isCancelled else { return }
            print("🎙️[SysAudio] SCShareableContent OK — displays=\(content.displays.count) apps=\(content.applications.count) windows=\(content.windows.count)")
            logger.notice("🎙️[SysAudio] SCShareableContent OK — displays=\(content.displays.count, privacy: .public) apps=\(content.applications.count, privacy: .public)")
        } catch {
            // Permission not yet granted for this binary. Trigger the system
            // prompt exactly once, then ask the user to relaunch. We only reach
            // here when SCK itself reports no access, so we avoid the spurious
            // re-prompt that CGPreflight caused.
            let ns = error as NSError
            print("🎙️[SysAudio] SCShareableContent FAILED (treating as permission gate): domain=\(ns.domain) code=\(ns.code) — \(error)")
            logger.error("🎙️[SysAudio] SCShareableContent (start) failed: \(error.localizedDescription, privacy: .public)")

            let requested = CGRequestScreenCaptureAccess()
            logger.notice("🎙️[SysAudio] CGRequestScreenCaptureAccess() = \(requested, privacy: .public)")
            print("🎙️[SysAudio] CGRequestScreenCaptureAccess() = \(requested)")

            if requested {
                errorMessage = screenCapturePermissionMessage(needsRelaunch: true)
                print("🎙️[SysAudio] Permission just granted — relaunch required.")
            } else {
                errorMessage = screenCapturePermissionMessage(needsRelaunch: false)
                print("🎙️[SysAudio] Permission denied. If Threshold IS listed under Screen Recording, remove it and re-add the running build (TCC binary mismatch).")
            }
            return
        }

        // Refresh availability now that we know permission is good.
        await refreshAvailability()
        guard !Task.isCancelled else { return }

        guard let display = content.displays.first else {
            errorMessage = "No display available for capture."
            print("🎙️[SysAudio] No display available — STOPPING")
            logger.error("🎙️[SysAudio] No display available for capture")
            return
        }
        print("🎙️[SysAudio] Using display \(display.displayID) \(display.width)x\(display.height)")

        // Whole-system audio filter: capture the entire display's audio output
        // instead of a single application. App-specific capture would require
        // resolving another process's PID via a sandbox-forbidden mach-lookup,
        // so we scope to the display and let `excludesCurrentProcessAudio` strip
        // our own audio. This captures audio from every other app (browsers,
        // Spotify, Music.app, games, …) and stays App-Store-safe.
        let filter = SCContentFilter(
            display: display,
            excludingWindows: []
        )

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        // Minimal video — required by SCStream even when we only want audio.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.queueDepth = 3
        if #available(macOS 15.0, *) {
            config.captureMicrophone = false
        }

        let captureLogger = logger
        let output = AudioStreamOutput(logger: captureLogger) { [weak self] buffer in
            let payload = SendablePCMBuffer(buffer: buffer)
            Task { @MainActor in
                self?.analyzer.ingestExternalBuffer(payload.buffer)
            }
        }
        let videoSink = NoopVideoStreamOutput()

        do {
            let stream = SCStream(filter: filter, configuration: config, delegate: output)
            try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: sampleQueue)
            // Drain video frames into a no-op output so SCK doesn't log
            // "stream output NOT found. Dropping frame" repeatedly.
            try stream.addStreamOutput(videoSink, type: .screen, sampleHandlerQueue: sampleQueue)
            print("🎙️[SysAudio] stream outputs added, calling startCapture()…")
            try await stream.startCapture()

            if Task.isCancelled {
                try? await stream.stopCapture()
                return
            }

            self.stream = stream
            self.output = output
            self.videoOutput = videoSink
            isCapturing = true
            errorMessage = nil
            analyzer.beginExternalCapture(sampleRate: Double(config.sampleRate))
            logger.notice("🎙️[SysAudio] ✅ startCapture() SUCCEEDED (display-scoped, whole-system). Waiting for audio buffers…")
            print("🎙️[SysAudio] ✅ startCapture() SUCCEEDED. Now play audio in any app; watch for 'first sample' / 'flush' logs.")
        } catch {
            self.stream = nil
            self.output = nil
            self.videoOutput = nil
            isCapturing = false
            errorMessage = mapStartError(error)
            logger.error("🎙️[SysAudio] ❌ startCapture() FAILED: \(error.localizedDescription, privacy: .public)")
            print("🎙️[SysAudio] ❌ startCapture() FAILED: \(error)")
        }
    }

    /// Stop capturing and reset analyzer levels.
    func stop() async {
        guard let stream else {
            isCapturing = false
            analyzer.endExternalCapture()
            return
        }

        do {
            try await stream.stopCapture()
        } catch {
            logger.error("SCStream.stopCapture error: \(error.localizedDescription, privacy: .public)")
        }
        self.stream = nil
        self.output = nil
        self.videoOutput = nil
        isCapturing = false
        analyzer.endExternalCapture()
    }

    // MARK: - Helpers

    private func mapStartError(_ error: Error) -> String {
        let ns = error as NSError
        // SCStreamErrorDomain user-declined / missing TCC permission paths.
        if isScreenCapturePermissionError(ns) {
            return screenCapturePermissionMessage(needsRelaunch: CGPreflightScreenCaptureAccess())
        }
        return "Couldn't start system audio capture: \(error.localizedDescription)"
    }

    private func screenCapturePermissionMessage(needsRelaunch: Bool) -> String {
        if needsRelaunch {
            return "Screen Recording permission was granted. Quit and reopen Threshold, then start system audio capture again."
        }

        return "Screen Recording or Screen & System Audio Recording permission required to capture system audio. Enable it in System Settings → Privacy & Security."
    }

    private func isScreenCapturePermissionError(_ error: NSError) -> Bool {
        error.domain.contains("SCStream") ||
        error.domain == "com.apple.ScreenCaptureKit" ||
        error.localizedDescription.localizedCaseInsensitiveContains("declined TCC")
    }
}

// MARK: - Stream output delegate
//
// Lives outside the MainActor because SCStreamOutput callbacks arrive on
// the configured dispatch queue, not on the main thread.

private final class AudioStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {

    /// Target frame count handed to the FFT analyzer. Must match
    /// `AudioAnalyzer.fftSize` so band magnitudes are computed; SCK
    /// typically delivers 480–1024 frames per buffer which is below
    /// the FFT threshold, so we accumulate first.
    private static let analyzerFrameCount: AVAudioFrameCount = 2048

    private let handler: @Sendable (AVAudioPCMBuffer) -> Void
    private let logger: Logger

    // Owned accumulator: a single-channel Float32 buffer of length
    // `analyzerFrameCount` we fill from incoming SCK buffers.
    private var accumFormat: AVAudioFormat?
    private var accumBuffer: AVAudioPCMBuffer?
    private var accumFilled: AVAudioFrameCount = 0

    private var sampleCount: Int = 0
    private var loggedFirstSample = false

    init(logger: Logger, handler: @escaping @Sendable (AVAudioPCMBuffer) -> Void) {
        self.logger = logger
        self.handler = handler
    }

    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio else { return }
        guard sampleBuffer.isValid, sampleBuffer.dataReadiness == .ready else {
            logger.debug("SCK audio sample not ready (skipped)")
            return
        }
        guard let asbdPtr = sampleBuffer.formatDescription?.audioStreamBasicDescription else { return }
        var asbd = asbdPtr
        guard let inputFormat = AVAudioFormat(streamDescription: &asbd) else { return }

        if !loggedFirstSample {
            loggedFirstSample = true
            logger.notice("🎙️[SysAudio] FIRST audio sample: sr=\(inputFormat.sampleRate, privacy: .public) ch=\(inputFormat.channelCount, privacy: .public) interleaved=\(inputFormat.isInterleaved, privacy: .public) commonFmt=\(inputFormat.commonFormat.rawValue, privacy: .public)")
            print("🎙️[SysAudio] FIRST audio sample received: sr=\(inputFormat.sampleRate) ch=\(inputFormat.channelCount) interleaved=\(inputFormat.isInterleaved) commonFmt=\(inputFormat.commonFormat.rawValue) — capture pipeline IS delivering buffers")
        }

        // Build (or rebuild on rate change) a mono Float32 non-interleaved
        // accumulator matching the input sample rate.
        if accumFormat?.sampleRate != inputFormat.sampleRate {
            guard let monoFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: inputFormat.sampleRate,
                channels: 1,
                interleaved: false
            ),
            let buffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: Self.analyzerFrameCount) else {
                logger.error("SCK audio: failed to allocate accumulator")
                return
            }
            accumFormat = monoFormat
            accumBuffer = buffer
            accumFilled = 0
        }

        // Append the new samples (mixed to mono) into the accumulator,
        // flushing a full 2048-frame buffer to the handler each time
        // we cross the threshold.
        appendSamples(from: sampleBuffer, inputFormat: inputFormat)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        logger.error("🎙️[SysAudio] SCStream stopped with error: \(error.localizedDescription, privacy: .public)")
        print("🎙️[SysAudio] SCStream stopped with error: \(error)")
    }

    // MARK: - Accumulation

    private func appendSamples(from sampleBuffer: CMSampleBuffer, inputFormat: AVAudioFormat) {
        guard let accum = accumBuffer,
              let dstPtr = accum.floatChannelData?[0] else { return }
        let target = Self.analyzerFrameCount
        let inFrames = Int(CMSampleBufferGetNumSamples(sampleBuffer))
        guard inFrames > 0 else { return }

        do {
            try sampleBuffer.withAudioBufferList { audioBufferList, _ in
                guard audioBufferList.count > 0 else { return }
                guard let srcBase = audioBufferList[0].mData else { return }
                let stride: Int = inputFormat.isInterleaved ? Int(inputFormat.channelCount) : 1

                switch inputFormat.commonFormat {
                case .pcmFormatFloat32:
                    let srcPtr = srcBase.assumingMemoryBound(to: Float.self)
                    copySamples(
                        from: srcPtr,
                        frameCount: inFrames,
                        sourceStride: stride,
                        target: target,
                        destination: dstPtr
                    )

                case .pcmFormatInt16:
                    let srcPtr = srcBase.assumingMemoryBound(to: Int16.self)
                    let scale = 1.0 / Float(Int16.max)
                    copySamples(
                        from: srcPtr,
                        frameCount: inFrames,
                        sourceStride: stride,
                        target: target,
                        destination: dstPtr
                    ) { Float($0) * scale }

                case .pcmFormatInt32:
                    let srcPtr = srcBase.assumingMemoryBound(to: Int32.self)
                    let scale = 1.0 / Float(Int32.max)
                    copySamples(
                        from: srcPtr,
                        frameCount: inFrames,
                        sourceStride: stride,
                        target: target,
                        destination: dstPtr
                    ) { Float($0) * scale }

                default:
                    logger.error("SCK audio: unsupported format \(inputFormat.commonFormat.rawValue, privacy: .public)")
                    return
                }
            }
        } catch {
            logger.error("SCK audio: withAudioBufferList threw \(error.localizedDescription, privacy: .public)")
        }
    }

    private func copySamples<T>(
        from srcPtr: UnsafePointer<T>,
        frameCount: Int,
        sourceStride: Int,
        target: AVAudioFrameCount,
        destination dstPtr: UnsafeMutablePointer<Float>,
        transform: (T) -> Float = { value in
            if let value = value as? Float {
                return value
            }
            fatalError("Unsupported sample type")
        }
    ) {
        var consumed = 0
        while consumed < frameCount {
            let remainingIn = frameCount - consumed
            let remainingOut = Int(target - accumFilled)
            let copy = min(remainingIn, remainingOut)
            let dstStart = Int(accumFilled)

            if sourceStride == 1 {
                for i in 0..<copy {
                    let sample = transform(srcPtr[consumed + i])
                    dstPtr[dstStart + i] = sample.isFinite ? sample : 0
                }
            } else {
                for i in 0..<copy {
                    let sample = transform(srcPtr[(consumed + i) * sourceStride])
                    dstPtr[dstStart + i] = sample.isFinite ? sample : 0
                }
            }

            accumFilled += AVAudioFrameCount(copy)
            consumed += copy
            if accumFilled >= target {
                flushAccumulator()
            }
        }
    }

    private func flushAccumulator() {
        guard let accum = accumBuffer else { return }
        accum.frameLength = Self.analyzerFrameCount

        sampleCount += 1
        if sampleCount == 1 || sampleCount % 60 == 0 {
            if let ch0 = accum.floatChannelData?[0] {
                var peak: Float = 0
                for i in 0..<Int(accum.frameLength) {
                    let v = abs(ch0[i])
                    if v > peak { peak = v }
                }
                logger.notice("🎙️[SysAudio] accumulator flush #\(self.sampleCount, privacy: .public) peak=\(peak, privacy: .public)")
                if self.sampleCount == 1 || self.sampleCount % 300 == 0 {
                    print("🎙️[SysAudio] flush #\(self.sampleCount) peak=\(peak) \(peak < 0.0001 ? "(SILENT — no audio reaching capture; is something actually playing?)" : "(audio flowing ✅)")")
                }
            }
        }

        handler(accum)

        // Reset for the next FFT window. We allocate a fresh buffer so the
        // one we just handed off can be safely retained by the consumer
        // until the MainActor hop reads it.
        if let monoFormat = accumFormat,
           let fresh = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: Self.analyzerFrameCount) {
            accumBuffer = fresh
        }
        accumFilled = 0
    }
}

/// Drains video frames so SCK doesn't log "stream output NOT found".
private final class NoopVideoStreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        // Intentionally empty: we only care about audio.
    }
}

/// Crosses the actor boundary when handing an owned PCM buffer from the
/// SCK sample queue to MainActor. AVAudioPCMBuffer isn't Sendable; this
/// wrapper is safe because the buffer is fully owned and only the
/// consumer touches it on the MainActor.
private struct SendablePCMBuffer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
}

#endif
