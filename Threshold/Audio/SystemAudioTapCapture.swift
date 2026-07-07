//
//  SystemAudioTapCapture.swift
//  Threshold
//
//  macOS-only: captures system audio output using ScreenCaptureKit's audio
//  capture (SCStream + capturesAudio) and feeds it into AudioAnalyzer for FFT
//  analysis.
//
//  Why ScreenCaptureKit and not Core Audio process taps:
//  Core Audio process taps build an in-process aggregate device whose HAL
//  metrics reporter does a Mach lookup of `com.apple.audioanalyticsd`. Under the
//  App Sandbox that lookup is denied and macOS turns it into a hard
//  PRECONDITION FAILURE (abort). Silencing it requires the
//  `com.apple.security.temporary-exception.mach-lookup.global-name` entitlement,
//  which the App Store rejects. ScreenCaptureKit performs the actual capture
//  out-of-process in `replayd`; our sandboxed app only receives CMSampleBuffers
//  over XPC, so the analytics reporter never runs in our address space and the
//  crash cannot occur. This is the supported, App-Store-legal path that shipping
//  sandboxed apps use for system audio.
//
//  Capture uses whole-system output and excludes the current process's own
//  audio so the visualizer does not feed back into itself.
//
//  Permission: system-audio capture via ScreenCaptureKit is gated by the
//  "Screen & System Audio Recording" TCC permission, prompted by the system the
//  first time capture starts. There is no Info.plist usage-description key for
//  it.
//

#if os(macOS)

import AVFoundation
import CoreMedia
import CoreGraphics
import ScreenCaptureKit
import AppKit
import Observation
import os

@MainActor
@Observable
final class SystemAudioTapCapture {

    // MARK: - Observable state

    private(set) var isCapturing: Bool = false
    private(set) var errorMessage: String?

    /// True once the user has declined Screen & System Audio Recording. macOS
    /// won't re-prompt after a decline, so the UI must point the user to System
    /// Settings and we must stop hammering `SCShareableContent`.
    private(set) var permissionDenied: Bool = false

    // MARK: - Dependencies

    private let analyzer: AudioAnalyzer
    private let logger = Logger(subsystem: "com.puppypower.Threshold", category: "SystemAudioCapture")

    // MARK: - Capture configuration

    /// Internal analysis sample rate. SCStream resamples to this for us.
    private static let captureSampleRate: Double = 48_000

    // MARK: - ScreenCaptureKit state

    private var stream: SCStream?
    private var sink: StreamSink?
    private let audioQueue = DispatchQueue(label: "com.puppypower.Threshold.SystemAudioCapture.audio",
                                           qos: .userInitiated)
    private let videoQueue = DispatchQueue(label: "com.puppypower.Threshold.SystemAudioCapture.video",
                                           qos: .utility)

    private enum ScreenRecordingPermissionState {
        case granted
        case grantedNeedsRelaunch
        case denied
    }

    init(analyzer: AudioAnalyzer) {
        self.analyzer = analyzer
    }

    // MARK: - Permission

    /// Non-prompting check of the Screen & System Audio Recording permission.
    private var hasScreenRecordingPermission: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Open System Settings at the Screen & System Audio Recording pane so the
    /// user can grant access after a decline.
    func openScreenRecordingSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Availability

    /// Refresh the whole-system capture row without triggering the TCC prompt.
    /// Only `start()` asks for Screen & System Audio Recording permission.
    func refreshAvailability() async {
        guard hasScreenRecordingPermission else {
            applyPermissionDeniedState()
            return
        }

        permissionDenied = false
        errorMessage = nil
    }

    /// Collapse to the permission-denied state: only the whole-system entry, a
    /// clear message, and the `permissionDenied` flag set so callers stop
    /// retrying.
    private func applyPermissionDeniedState() {
        permissionDenied = true
        errorMessage = permissionErrorMessage(needsRelaunch: false)
    }

    private func applyPermissionGrantedNeedsRelaunchState() {
        permissionDenied = false
        errorMessage = permissionErrorMessage(needsRelaunch: true)
    }

    // MARK: - Capture lifecycle

    /// Start capturing the selected source. The first capture in the app's
    /// lifetime triggers the system "Screen & System Audio Recording" prompt.
    func start() async {
        guard !isCapturing else { return }

        switch ensureScreenRecordingPermission() {
        case .granted:
            break
        case .grantedNeedsRelaunch:
            applyPermissionGrantedNeedsRelaunchState()
            return
        case .denied:
            applyPermissionDeniedState()
            return
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
        } catch {
            errorMessage = captureErrorMessage(error)
            logger.error("Shareable content unavailable: \(error.localizedDescription, privacy: .public)")
            return
        }

        do {
            try await beginCapture(with: content)
            isCapturing = true
            errorMessage = nil
            analyzer.beginExternalCapture(sampleRate: Self.captureSampleRate)
            logger.info("System audio capture started")
        } catch {
            await teardownStream()
            isCapturing = false
            errorMessage = captureErrorMessage(error)
            logger.error("System audio capture failed to start: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Stop capturing and let analyzer levels decay to zero.
    func stop() async {
        await teardownStream()
        if isCapturing {
            analyzer.endExternalCapture()
        }
        isCapturing = false
    }

    // MARK: - ScreenCaptureKit setup

    private func beginCapture(with content: SCShareableContent) async throws {
        guard let display = content.displays.first else {
            throw CaptureError.noDisplay
        }

        let ownBundleID = Bundle.main.bundleIdentifier
        let captureApplications = content.applications.filter { $0.bundleIdentifier != ownBundleID }
        let filter = SCContentFilter(
            display: display,
            including: captureApplications,
            exceptingWindows: []
        )

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = Int(Self.captureSampleRate)
        config.channelCount = 2
        if #available(macOS 15.0, *) {
            config.captureMicrophone = false
        }
        // Audio-only: keep a tiny, slow video stream alive. SCStream misbehaves
        // and logs errors when only an audio output is attached, so we add a
        // minimal screen output and discard its frames in the sink.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.queueDepth = 3

        let sink = StreamSink(
            sampleRate: Self.captureSampleRate,
            logger: logger,
            ingestHandler: { [weak self] buffer in
                let payload = SendableTapBuffer(buffer: buffer)
                Task { @MainActor in
                    self?.analyzer.ingestExternalBuffer(payload.buffer)
                }
            },
            stopHandler: { [weak self] error in
                Task { @MainActor in
                    await self?.handleStreamStopped(error)
                }
            }
        )
        self.sink = sink

        let stream = SCStream(filter: filter, configuration: config, delegate: sink)
        try stream.addStreamOutput(sink, type: .audio, sampleHandlerQueue: audioQueue)
        try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: videoQueue)
        try await stream.startCapture()
        self.stream = stream
    }

    private func teardownStream() async {
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
        sink = nil
    }

    /// Invoked when SCStream stops itself (e.g. permission revoked, display
    /// removed). Reflect that in observable state so the UI can recover.
    private func handleStreamStopped(_ error: Error?) async {
        guard isCapturing else { return }
        await teardownStream()
        analyzer.endExternalCapture()
        isCapturing = false
        if let error {
            errorMessage = captureErrorMessage(error)
            logger.error("System audio capture stopped: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Errors

    private func ensureScreenRecordingPermission() -> ScreenRecordingPermissionState {
        if hasScreenRecordingPermission {
            return .granted
        }

        if CGRequestScreenCaptureAccess() {
            return hasScreenRecordingPermission ? .granted : .grantedNeedsRelaunch
        }

        return .denied
    }

    private func permissionErrorMessage(needsRelaunch: Bool) -> String {
        if needsRelaunch {
            return "Screen & System Audio Recording permission was granted. Quit and reopen Threshold, then start system audio capture again."
        }

        return "Threshold needs permission to capture system audio. Open System Settings → Privacy & Security → Screen & System Audio Recording, enable Threshold, then quit and reopen the app."
    }

    private func captureErrorMessage(_ error: Error) -> String {
        if let capture = error as? CaptureError {
            switch capture {
            case .noDisplay:
                return "No display is available to capture system audio from."
            }
        }
        // SCStreamError for missing permission lands here.
        return permissionErrorMessage(needsRelaunch: hasScreenRecordingPermission)
    }

    enum CaptureError: Error {
        case noDisplay
    }
}

// MARK: - Stream sink
//
// Lives outside the MainActor: ScreenCaptureKit delivers sample buffers on the
// dispatch queues we register, not the main thread. The sink keeps the callback
// minimal — convert the CMSampleBuffer to PCM, hand it to the accumulator, and
// return — so no heavy analysis happens on the capture thread.

private final class StreamSink: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {

    private let accumulator: TapStreamAccumulator
    private let stopHandler: @Sendable (Error?) -> Void
    private let logger: Logger

    init(sampleRate: Double,
         logger: Logger,
         ingestHandler: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
         stopHandler: @escaping @Sendable (Error?) -> Void) {
        self.accumulator = TapStreamAccumulator(sampleRate: sampleRate, handler: ingestHandler)
        self.stopHandler = stopHandler
        self.logger = logger
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        guard let pcm = Self.makePCMBuffer(from: sampleBuffer) else {
            logger.error("System audio sample buffer could not be converted to PCM")
            return
        }
        accumulator.ingest(pcmBuffer: pcm)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        stopHandler(error)
    }

    /// Convert an SCStream audio `CMSampleBuffer` into an `AVAudioPCMBuffer`
    /// matching its native (Float32) stream format.
    private static func makePCMBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else { return nil }
        var asbd = asbdPtr.pointee
        guard let format = AVAudioFormat(streamDescription: &asbd) else { return nil }

        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0,
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        pcm.frameLength = frames

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frames),
            into: pcm.mutableAudioBufferList
        )
        guard status == noErr else { return nil }
        return pcm
    }
}

// MARK: - IO accumulator
//
// Mixes incoming audio to mono and accumulates fixed 2048-frame windows
// (matching AudioAnalyzer.fftSize) before handing owned buffers off for FFT
// analysis on the MainActor.

private final class TapStreamAccumulator: @unchecked Sendable {

    /// Must match `AudioAnalyzer.fftSize` so band magnitudes are computed.
    private static let analyzerFrameCount: AVAudioFrameCount = 2048

    private let handler: @Sendable (AVAudioPCMBuffer) -> Void
    private let monoFormat: AVAudioFormat?

    private var accumBuffer: AVAudioPCMBuffer?
    private var accumFilled: AVAudioFrameCount = 0

    init(sampleRate: Double, handler: @escaping @Sendable (AVAudioPCMBuffer) -> Void) {
        self.handler = handler
        self.monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )
        if let monoFormat {
            accumBuffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: Self.analyzerFrameCount)
        }
    }

    func ingest(pcmBuffer: AVAudioPCMBuffer) {
        guard pcmBuffer.frameLength > 0,
              let accum = accumBuffer,
              let dstPtr = accum.floatChannelData?[0] else { return }

        let inFrames = Int(pcmBuffer.frameLength)
        let target = Self.analyzerFrameCount
        let stride = pcmBuffer.format.isInterleaved ? Int(pcmBuffer.format.channelCount) : 1

        switch pcmBuffer.format.commonFormat {
        case .pcmFormatFloat32:
            guard let srcPtr = pcmBuffer.floatChannelData?[0] else { return }
            appendFrames(
                frameCount: inFrames,
                target: target,
                destination: dstPtr,
                sourceStride: stride
            ) { frameIndex in
                srcPtr[frameIndex * stride]
            }

        case .pcmFormatInt16:
            guard let srcPtr = pcmBuffer.int16ChannelData?[0] else { return }
            let scale = 1.0 / Float(Int16.max)
            appendFrames(
                frameCount: inFrames,
                target: target,
                destination: dstPtr,
                sourceStride: stride
            ) { frameIndex in
                Float(srcPtr[frameIndex * stride]) * scale
            }

        case .pcmFormatInt32:
            guard let srcPtr = pcmBuffer.int32ChannelData?[0] else { return }
            let scale = 1.0 / Float(Int32.max)
            appendFrames(
                frameCount: inFrames,
                target: target,
                destination: dstPtr,
                sourceStride: stride
            ) { frameIndex in
                Float(srcPtr[frameIndex * stride]) * scale
            }

        default:
            return
        }
    }

    private func appendFrames(
        frameCount: Int,
        target: AVAudioFrameCount,
        destination dstPtr: UnsafeMutablePointer<Float>,
        sourceStride _: Int,
        sampleAt: (Int) -> Float
    ) {
        var consumed = 0
        while consumed < frameCount {
            let remainingIn = frameCount - consumed
            let remainingOut = Int(target - accumFilled)
            let copy = min(remainingIn, remainingOut)
            let dstStart = Int(accumFilled)

            for i in 0..<copy {
                dstPtr[dstStart + i] = sampleAt(consumed + i)
            }

            accumFilled += AVAudioFrameCount(copy)
            consumed += copy
            if accumFilled >= target {
                flush()
            }
        }
    }

    private func flush() {
        guard let accum = accumBuffer else { return }
        accum.frameLength = Self.analyzerFrameCount
        handler(accum)
        // Allocate a fresh window so the consumer can retain the handed-off
        // buffer across the MainActor hop.
        if let monoFormat {
            accumBuffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: Self.analyzerFrameCount)
        }
        accumFilled = 0
    }
}

private struct SendableTapBuffer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
}

#endif
