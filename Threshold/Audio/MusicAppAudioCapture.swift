//
//  MusicAppAudioCapture.swift
//  Threshold
//
//  macOS-only: captures audio output from the native Music.app process
//  via ScreenCaptureKit and feeds it into AudioAnalyzer for FFT analysis.
//
//  This is the supported public path for reacting to music played in
//  the system Music app on macOS. Requires user-granted Screen Recording
//  permission. Sandbox-safe; no private APIs.
//

#if os(macOS)

import AVFoundation
@preconcurrency import ScreenCaptureKit
import Observation
import os

@MainActor
@Observable
final class MusicAppAudioCapture {

    // MARK: - Observable state

    private(set) var isCapturing: Bool = false
    private(set) var errorMessage: String?
    private(set) var isMusicAppRunning: Bool = false

    // MARK: - Dependencies

    private let analyzer: AudioAnalyzer
    private let logger = Logger(subsystem: "com.puppypower.Threshold", category: "MusicAppCapture")

    // MARK: - Capture state

    private var stream: SCStream?
    private var output: AudioStreamOutput?
    private var videoOutput: NoopVideoStreamOutput?
    private let sampleQueue = DispatchQueue(label: "com.puppypower.Threshold.MusicAppCapture.audio",
                                            qos: .userInitiated)

    private static let musicBundleID = "com.apple.Music"

    init(analyzer: AudioAnalyzer) {
        self.analyzer = analyzer
    }

    // MARK: - Availability

    /// Refresh whether the native Music.app process is available for capture.
    /// Safe to call without Screen Recording permission; on denial
    /// `errorMessage` will explain how to grant access.
    func refreshAvailability() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )

            let musicApp = content.applications.first { $0.bundleIdentifier == Self.musicBundleID }
            isMusicAppRunning = musicApp != nil
            if errorMessage?.hasPrefix("Screen Recording") == true {
                errorMessage = nil
            }
        } catch {
            isMusicAppRunning = false
            errorMessage = "Screen Recording or Screen & System Audio Recording permission required to detect Music.app. Enable it in System Settings → Privacy & Security."
            logger.error("SCShareableContent failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Capture lifecycle

    /// Start capturing audio from the Music.app process. ScreenCaptureKit
    /// routes audio at the application level (windows carry video, processes
    /// carry audio), so the content filter must include Music's
    /// `SCRunningApplication` — a window-only filter will not deliver audio.
    func start() async {
        guard !isCapturing else { return }

        // Always refresh so we pick up Music.app even if the user launched it
        // after the tab first appeared.
        await refreshAvailability()

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
        } catch {
            errorMessage = mapStartError(error)
            logger.error("SCShareableContent (start) failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        guard let musicApp = content.applications.first(where: { $0.bundleIdentifier == Self.musicBundleID }) else {
            errorMessage = "Music app isn't running. Open Music.app, then try again."
            return
        }
        guard let display = content.displays.first else {
            errorMessage = "No display available for capture."
            return
        }

        // Application-scoped filter: captures all audio output from Music.app's
        // process while keeping the video stream minimal.
        let filter = SCContentFilter(
            display: display,
            including: [musicApp],
            exceptingWindows: []
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
            try await stream.startCapture()

            self.stream = stream
            self.output = output
            self.videoOutput = videoSink
            isCapturing = true
            errorMessage = nil
            analyzer.beginExternalCapture(sampleRate: Double(config.sampleRate))
            logger.info("Music.app audio capture started (app-scoped filter)")
        } catch {
            self.stream = nil
            self.output = nil
            self.videoOutput = nil
            isCapturing = false
            errorMessage = mapStartError(error)
            logger.error("Music.app audio capture failed to start: \(error.localizedDescription, privacy: .public)")
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
        if ns.domain.contains("SCStream") || ns.domain == "com.apple.ScreenCaptureKit" {
            return "Couldn't access Music.app audio. Grant Screen Recording or Screen & System Audio Recording permission in System Settings → Privacy & Security."
        }
        return "Couldn't start Music app capture: \(error.localizedDescription)"
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
            logger.info("SCK audio first sample: sr=\(inputFormat.sampleRate, privacy: .public) ch=\(inputFormat.channelCount, privacy: .public) interleaved=\(inputFormat.isInterleaved, privacy: .public) commonFmt=\(inputFormat.commonFormat.rawValue, privacy: .public)")
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
        logger.error("SCStream stopped with error: \(error.localizedDescription, privacy: .public)")
    }

    // MARK: - Accumulation

    private func appendSamples(from sampleBuffer: CMSampleBuffer, inputFormat: AVAudioFormat) {
        guard let accum = accumBuffer,
              let dstPtr = accum.floatChannelData?[0] else { return }
        let target = Self.analyzerFrameCount

        do {
            try sampleBuffer.withAudioBufferList { audioBufferList, _ in
                guard let borrowed = AVAudioPCMBuffer(
                    pcmFormat: inputFormat,
                    bufferListNoCopy: audioBufferList.unsafePointer
                ) else { return }
                let inFrames = Int(borrowed.frameLength)
                guard inFrames > 0 else { return }

                // Read first-channel samples (good enough for visualizer use);
                // SCK typically delivers non-interleaved Float32.
                guard let srcPtr = borrowed.floatChannelData?[0] else {
                    logger.error("SCK audio: unsupported format (no float channel data)")
                    return
                }
                let stride: Int = inputFormat.isInterleaved ? Int(inputFormat.channelCount) : 1

                var consumed = 0
                while consumed < inFrames {
                    let remainingIn = inFrames - consumed
                    let remainingOut = Int(target - accumFilled)
                    let copy = min(remainingIn, remainingOut)
                    let dstStart = Int(accumFilled)
                    if stride == 1 {
                        memcpy(dstPtr.advanced(by: dstStart),
                               srcPtr.advanced(by: consumed),
                               copy * MemoryLayout<Float>.size)
                    } else {
                        // De-interleave: pick L only (channel 0)
                        for i in 0..<copy {
                            dstPtr[dstStart + i] = srcPtr[(consumed + i) * stride]
                        }
                    }
                    accumFilled += AVAudioFrameCount(copy)
                    consumed += copy

                    if accumFilled >= target {
                        flushAccumulator()
                    }
                }
            }
        } catch {
            logger.error("SCK audio: withAudioBufferList threw \(error.localizedDescription, privacy: .public)")
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
                logger.debug("SCK accumulator flush #\(self.sampleCount, privacy: .public) peak=\(peak, privacy: .public)")
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
