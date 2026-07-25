//
//  AudioCaptureSource.swift
//  Threshold
//
//  Platform adapters that translate a capture backend into normalized feature
//  contributions. `AudioHub` owns these adapters; views and renderers never
//  need to know whether the underlying backend is AVAudioEngine or
//  ScreenCaptureKit.
//

import AVFoundation
import Foundation

#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

@MainActor
protocol AudioCaptureSource: AnyObject {
    var sourceID: AudioSourceID { get }
    var descriptor: AudioSourceDescriptor { get }
    var isActive: Bool { get }

    func refreshAvailability() async
    func startCapture() async -> Bool
    func stopCapture() async
    /// Advance display-cadence smoothing toward the analysis core's latest
    /// targets. Called once per `AudioHub.updateFrame()` tick.
    func advanceFrame(at timestamp: TimeInterval)
    func featureContribution(at timestamp: TimeInterval) -> AudioSourceContribution?
}

@MainActor
final class MicrophoneCaptureSource: AudioCaptureSource {
    let sourceID: AudioSourceID = .microphone
    private let analyzer: AudioAnalyzer

    init(analyzer: AudioAnalyzer) {
        self.analyzer = analyzer
    }

    var isActive: Bool { analyzer.isMicrophoneCapturing }

    var descriptor: AudioSourceDescriptor {
        let availability: AudioSourceAvailability
        if analyzer.isMicrophoneCapturing {
            availability = .active
        } else {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .denied, .restricted:
                availability = .unavailable(microphoneSettingsMessage)
            case .notDetermined:
                availability = .permissionRequired("Microphone permission is requested only when you start this source.")
            case .authorized:
                if let errorMessage = analyzer.errorMessage {
                    availability = .failed(errorMessage)
                } else {
                    availability = .available
                }
            @unknown default:
                availability = .failed("Microphone permission status could not be determined.")
            }
        }

        return AudioSourceDescriptor(
            id: sourceID,
            kind: .capture,
            displayName: "Microphone",
            systemImage: analyzer.isMicrophoneCapturing ? "mic.fill" : "mic",
            capabilities: [.pcmFrames, .captureLifecycle],
            availability: availability,
            provenance: .pcm
        )
    }

    func refreshAvailability() async {
        // AVFoundation requests microphone access only from startCapture().
    }

    func startCapture() async -> Bool {
        await analyzer.startCaptureIfNeeded()
    }

    func stopCapture() async {
        analyzer.stopCapture()
    }

    func advanceFrame(at timestamp: TimeInterval) {
        analyzer.tickEnvelopes(at: timestamp)
    }

    func openSettings() {
        #if os(macOS)
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") else { return }
        NSWorkspace.shared.open(url)
        #elseif canImport(UIKit)
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
        #endif
    }

    func featureContribution(at _: TimeInterval) -> AudioSourceContribution? {
        let sampleTime = analyzer.lastSampleTime
        guard analyzer.isMicrophoneCapturing, sampleTime > 0 else { return nil }
        return AudioSourceContribution(
            sourceID: sourceID,
            features: AudioFeatures(
                bass: analyzer.bassLevel,
                mid: analyzer.midLevel,
                treble: analyzer.trebleLevel,
                onset: analyzer.onsetLevel,
                overall: analyzer.level
            ),
            provenance: .pcm,
            timestamp: sampleTime
        )
    }

    private var microphoneSettingsMessage: String {
        #if os(macOS)
        return "Microphone access is denied. Enable Threshold in System Settings → Privacy & Security → Microphone."
        #else
        return "Microphone access is denied. Enable it in Settings."
        #endif
    }
}

#if os(macOS)
@MainActor
final class SystemOutputCaptureSource: AudioCaptureSource {
    let sourceID: AudioSourceID = .systemOutput
    private let analyzer: AudioAnalyzer
    private let capture: SystemAudioTapCapture
    private let policy: SystemOutputCapturePolicy

    init(policy: SystemOutputCapturePolicy) {
        let analyzer = AudioAnalyzer()
        self.analyzer = analyzer
        self.policy = policy
        self.capture = SystemAudioTapCapture(
            analyzer: analyzer,
            approvedApplicationBundleIDs: policy.approvedApplicationBundleIDs
        )
    }

    var isActive: Bool { capture.isCapturing }

    var descriptor: AudioSourceDescriptor {
        let availability: AudioSourceAvailability
        if let reason = policy.blockReason {
            availability = .policyBlocked(reason)
        } else if capture.isCapturing {
            availability = .active
        } else if capture.permissionDenied {
            availability = .unavailable(capture.errorMessage ?? "Screen & System Audio Recording permission is denied.")
        } else if let errorMessage = capture.errorMessage {
            availability = .failed(errorMessage)
        } else {
            availability = .permissionRequired("Screen & System Audio Recording permission is requested when capture starts.")
        }

        return AudioSourceDescriptor(
            id: sourceID,
            kind: .capture,
            displayName: "Approved App Audio",
            systemImage: capture.isCapturing ? "speaker.wave.2.fill" : "speaker.wave.2",
            capabilities: [.pcmFrames, .captureLifecycle, .systemOutput],
            availability: availability,
            provenance: .pcm
        )
    }

    func refreshAvailability() async {
        guard policy.blockReason == nil else { return }
        await capture.refreshAvailability()
    }

    func startCapture() async -> Bool {
        guard policy.blockReason == nil else { return false }
        return await capture.startCaptureIfNeeded()
    }

    func stopCapture() async {
        await capture.stop()
    }

    func advanceFrame(at timestamp: TimeInterval) {
        analyzer.tickEnvelopes(at: timestamp)
    }

    func featureContribution(at _: TimeInterval) -> AudioSourceContribution? {
        let sampleTime = analyzer.lastSampleTime
        guard capture.isCapturing, sampleTime > 0 else { return nil }
        return AudioSourceContribution(
            sourceID: sourceID,
            features: AudioFeatures(
                bass: analyzer.bassLevel,
                mid: analyzer.midLevel,
                treble: analyzer.trebleLevel,
                onset: analyzer.onsetLevel,
                overall: analyzer.level
            ),
            provenance: .pcm,
            timestamp: sampleTime
        )
    }

    func openSettings() {
        capture.openScreenRecordingSettings()
    }
}
#endif

/// Apple Music's current implementation publishes timing/BPM-derived levels,
/// not decoded PCM. It is intentionally a separate feature origin so the UI,
/// mixer, and persisted state can distinguish it from a real captured signal.
@MainActor
final class AppleMusicMetadataFeatureSource {
    private let manager: AppleMusicManager

    init(manager: AppleMusicManager) {
        self.manager = manager
    }

    var descriptor: AudioSourceDescriptor {
        #if os(macOS)
        return AudioSourceDescriptor(
            id: .appleMusic,
            kind: .mediaContext,
            displayName: "Apple Music",
            systemImage: "apple.logo",
            capabilities: [.nowPlaying, .transport, .library, .metadataTempo],
            availability: .unavailable("Apple Music playback and library access are not included in this macOS build."),
            provenance: .metadataSynthetic
        )
        #else
        return AudioSourceDescriptor(
            id: .appleMusic,
            kind: .mediaContext,
            displayName: "Apple Music",
            systemImage: "apple.logo",
            capabilities: [.nowPlaying, .transport, .library, .metadataTempo],
            availability: manager.isActive ? .active : .available,
            provenance: .metadataSynthetic
        )
        #endif
    }

    func advanceFrame() {
        manager.updateFrame()
    }

    func featureContribution(at timestamp: TimeInterval) -> AudioSourceContribution? {
        guard manager.isActive else { return nil }
        return AudioSourceContribution(
            sourceID: .appleMusic,
            features: AudioFeatures(
                bass: manager.bassLevel,
                mid: manager.midLevel,
                treble: manager.trebleLevel,
                onset: manager.beatIntensity,
                overall: manager.overallLevel
            ),
            provenance: .metadataSynthetic,
            timestamp: timestamp
        )
    }
}
