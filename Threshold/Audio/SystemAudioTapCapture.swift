//
//  SystemAudioTapCapture.swift
//  Threshold
//
//  macOS-only: captures a policy-approved application's audio using
//  ScreenCaptureKit (SCStream + capturesAudio) and feeds it into AudioAnalyzer
//  for FFT analysis.
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
//  Capture is scoped to an explicit application allowlist and excludes the
//  current process's own audio. This prevents an unknown service (including
//  browser-hosted streaming) from silently becoming a visualizer input.
//
//  Permission: system-audio capture via ScreenCaptureKit is gated by the
//  "Screen & System Audio Recording" TCC permission, prompted by the system the
//  first time capture starts. There is no Info.plist usage-description key for
//  it.
//
//  Delivery: the sink converts each CMSampleBuffer to an owned AVAudioPCMBuffer
//  and hands it synchronously to `AudioAnalyzer.ingestExternalBuffer`, whose
//  analysis core accumulates windows internally — no intermediate accumulator,
//  no MainActor hop on the audio path.
//

#if os(macOS)

import AVFoundation
import CoreMedia
import CoreGraphics
import ScreenCaptureKit
import AppKit
import Observation
import Synchronization
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
    private let approvedApplicationBundleIDs: Set<String>
    private let logger = Logger(subsystem: "com.puppypower.Threshold", category: "SystemAudioCapture")

    // MARK: - Capture configuration

    /// Requested analysis sample rate. SCStream resamples to this for us; the
    /// analyzer additionally follows the per-buffer delivered rate, so a
    /// stream that ignores the request cannot shift the frequency bands.
    private static let captureSampleRate: Double = 48_000

    /// Distinguishes "the system permission dialog was just shown" from a real
    /// user decline: `CGRequestScreenCaptureAccess` returns false in both
    /// cases, but only a repeated attempt after a shown prompt is a denial.
    /// Tracked per launch, not persisted: a persisted flag survives a TCC
    /// reset and would misreport the fresh system prompt as a denial.
    private var hasRequestedPermissionThisLaunch = false

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
        case promptPending
        case denied
    }

    init(analyzer: AudioAnalyzer, approvedApplicationBundleIDs: Set<String>) {
        self.analyzer = analyzer
        self.approvedApplicationBundleIDs = approvedApplicationBundleIDs
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

    /// Refresh the approved-application capture row without triggering TCC.
    /// Only `start()` asks for Screen & System Audio Recording permission.
    func refreshAvailability() async {
        guard hasScreenRecordingPermission else {
            // `CGPreflightScreenCaptureAccess` reports `false` both before the
            // first request and after a user denial. Keep a fresh source
            // startable so `startCaptureIfNeeded()` can issue the system
            // prompt; a real decline is recorded there and remains blocked
            // until Settings grants access.
            if !permissionDenied {
                errorMessage = nil
            }
            return
        }

        permissionDenied = false
        errorMessage = nil
    }

    /// Collapse to the permission-denied state: only the application-capture entry, a
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

    /// The system permission dialog was just raised for the first time. Not a
    /// denial: keep the source startable and tell the user what to do next.
    private func applyPromptPendingState() {
        permissionDenied = false
        errorMessage = "macOS is asking for Screen & System Audio Recording permission. Grant it in the system dialog, then start capture again. If no dialog appeared, enable Threshold in System Settings → Privacy & Security → Screen & System Audio Recording."
    }

    // MARK: - Capture lifecycle

    /// Start capturing the selected source. The first capture in the app's
    /// lifetime triggers the system "Screen & System Audio Recording" prompt.
    func start() async {
        _ = await startCaptureIfNeeded()
    }

    /// Start capture and report whether a live ScreenCaptureKit stream was
    /// installed. This makes permission/failure state observable by the shared
    /// audio coordinator without a fragile delayed poll from the UI.
    @discardableResult
    func startCaptureIfNeeded() async -> Bool {
        guard !isCapturing else { return true }

        switch ensureScreenRecordingPermission() {
        case .granted:
            break
        case .grantedNeedsRelaunch:
            applyPermissionGrantedNeedsRelaunchState()
            return false
        case .promptPending:
            applyPromptPendingState()
            return false
        case .denied:
            applyPermissionDeniedState()
            return false
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
            return false
        }

        do {
            // Activate the analysis core before the stream starts: buffers can
            // arrive on the delivery queue the moment `startCapture()` returns,
            // and an inactive core silently drops them.
            analyzer.beginExternalCapture(sampleRate: Self.captureSampleRate)
            try await beginCapture(with: content)
            isCapturing = true
            errorMessage = nil
            logger.info("System audio capture started")
            return true
        } catch {
            await teardownStream()
            analyzer.endExternalCapture()
            isCapturing = false
            errorMessage = captureErrorMessage(error)
            logger.error("System audio capture failed to start: \(error.localizedDescription, privacy: .public)")
            return false
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
        let captureApplications = content.applications.filter { application in
            let bundleIdentifier = application.bundleIdentifier
            return bundleIdentifier != ownBundleID && approvedApplicationBundleIDs.contains(bundleIdentifier)
        }
        guard !captureApplications.isEmpty else {
            throw CaptureError.noApprovedApplication
        }
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

        // Capture only the DSP core, not the analyzer: if replayd holds the
        // sink past teardown, it must not keep the analyzer → hub → UI graph
        // alive with it. Same pattern as the microphone tap.
        let core = analyzer.core
        let sink = StreamSink(
            logger: logger,
            ingestHandler: { buffer in
                core.ingest(buffer)
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
            // Detach the outputs before stopping: a stream whose stopCapture
            // throws must not keep delivering into (and retaining) the sink.
            if let sink {
                try? stream.removeStreamOutput(sink, type: .audio)
                try? stream.removeStreamOutput(sink, type: .screen)
            }
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

        let hadRequestedThisLaunch = hasRequestedPermissionThisLaunch
        hasRequestedPermissionThisLaunch = true

        if CGRequestScreenCaptureAccess() {
            return hasScreenRecordingPermission ? .granted : .grantedNeedsRelaunch
        }

        // The request returns false both when the user just saw the dialog for
        // the first time and when access is actually denied. Only treat it as
        // a denial once a prompt has already been shown this launch.
        return hadRequestedThisLaunch ? .denied : .promptPending
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
            case .noApprovedApplication:
                return "No configured approved audio application is running. Open an approved app, then try again."
            }
        }
        // SCStreamError for missing permission lands here.
        return permissionErrorMessage(needsRelaunch: hasScreenRecordingPermission)
    }

    enum CaptureError: Error {
        case noDisplay
        case noApprovedApplication
    }
}

// MARK: - Stream sink
//
// Lives outside the MainActor: ScreenCaptureKit delivers sample buffers on the
// dispatch queues we register, not the main thread. The sink converts each
// CMSampleBuffer to an owned PCM buffer and hands it synchronously to the
// analysis core — the core does its own windowing, so no accumulation happens
// here.

private final class StreamSink: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {

    private let ingestHandler: @Sendable (AVAudioPCMBuffer) -> Void
    private let stopHandler: @Sendable (Error?) -> Void
    private let logger: Logger
    // Atomic (not plain vars) so the @unchecked Sendable annotation holds by
    // construction rather than by SCK's one-serial-queue delivery detail.
    private let hasLoggedConversionFailure = Atomic<Bool>(false)
    private let hasLoggedUnsupportedFormat = Atomic<Bool>(false)

    init(logger: Logger,
         ingestHandler: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
         stopHandler: @escaping @Sendable (Error?) -> Void) {
        self.ingestHandler = ingestHandler
        self.stopHandler = stopHandler
        self.logger = logger
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        guard let pcm = makePCMBuffer(from: sampleBuffer) else {
            if !hasLoggedConversionFailure.exchange(true, ordering: .relaxed) {
                logger.error("System audio sample buffer could not be converted to PCM; dropping audio (further reports suppressed)")
            }
            return
        }
        guard pcm.format.commonFormat == .pcmFormatFloat32 else {
            if !hasLoggedUnsupportedFormat.exchange(true, ordering: .relaxed) {
                logger.error("System audio stream delivered a non-Float32 format; dropping audio (further reports suppressed)")
            }
            return
        }
        ingestHandler(pcm)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        stopHandler(error)
    }

    // Reusable conversion buffer. Safe because the analysis core consumes
    // each buffer SYNCHRONOUSLY inside `ingest` (copies the samples out
    // before returning), and because SCK delivers on one serial queue —
    // these fields are audioQueue-confined, like the delivery path itself.
    // Saves an ~8 KB AVAudioPCMBuffer allocation per callback (~50/s).
    private var scratchPCM: AVAudioPCMBuffer?
    private var scratchASBD = AudioStreamBasicDescription()

    /// Convert an SCStream audio `CMSampleBuffer` into a PCM buffer matching
    /// its native (Float32) stream format, reusing the scratch buffer when
    /// the format and capacity still fit.
    private func makePCMBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else { return nil }
        var asbd = asbdPtr.pointee

        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0 else { return nil }

        let pcm: AVAudioPCMBuffer
        if let scratch = scratchPCM,
           scratch.frameCapacity >= frames,
           scratchASBD.mSampleRate == asbd.mSampleRate,
           scratchASBD.mFormatID == asbd.mFormatID,
           scratchASBD.mFormatFlags == asbd.mFormatFlags,
           scratchASBD.mChannelsPerFrame == asbd.mChannelsPerFrame,
           scratchASBD.mBitsPerChannel == asbd.mBitsPerChannel,
           scratchASBD.mBytesPerFrame == asbd.mBytesPerFrame {
            pcm = scratch
        } else {
            guard let format = AVAudioFormat(streamDescription: &asbd),
                  let fresh = AVAudioPCMBuffer(pcmFormat: format,
                                               frameCapacity: max(frames, 4096)) else { return nil }
            scratchPCM = fresh
            scratchASBD = asbd
            pcm = fresh
        }
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

#endif
