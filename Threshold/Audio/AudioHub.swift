//
//  AudioHub.swift
//  Threshold
//
//  The one composition point for reactive audio. It owns capture selection,
//  source lifecycle, feature-source policy, and the thread-safe snapshot read
//  by both renderers.
//

import Foundation
import Observation
import Synchronization

private final class AudioFeatureStore: @unchecked Sendable {
    private let value: Mutex<AudioFeatureSnapshot>

    init(initialValue: AudioFeatureSnapshot) {
        self.value = Mutex(initialValue)
    }

    func replace(_ snapshot: AudioFeatureSnapshot) {
        value.withLock { $0 = snapshot }
    }

    func snapshot() -> AudioFeatureSnapshot {
        value.withLock { $0 }
    }
}

@MainActor
@Observable
final class AudioHub {
    private let microphone: MicrophoneCaptureSource
    private let appleMusic: AppleMusicMetadataFeatureSource
    private let configuration: AudioHubConfiguration
    #if os(macOS)
    private let systemOutput: SystemOutputCaptureSource
    #endif

    /// An explicit capture source wins over automatic fallback selection. When
    /// nil, a live PCM capture wins, then Apple Music's labelled metadata signal.
    private(set) var selectedSourceID: AudioSourceID?
    private(set) var mixPolicy: AudioMixPolicy = .exclusive
    private var transitionGate = AudioSourceTransitionGate()

    nonisolated private let featureStore: AudioFeatureStore

    init(
        microphoneAnalyzer: AudioAnalyzer,
        appleMusicManager: AppleMusicManager,
        configuration: AudioHubConfiguration = .init()
    ) {
        self.configuration = configuration
        self.microphone = MicrophoneCaptureSource(analyzer: microphoneAnalyzer)
        self.appleMusic = AppleMusicMetadataFeatureSource(manager: appleMusicManager)
        #if os(macOS)
        self.systemOutput = SystemOutputCaptureSource(policy: configuration.systemOutputCapturePolicy)
        #endif
        self.featureStore = AudioFeatureStore(initialValue: .empty(at: ProcessInfo.processInfo.systemUptime))
    }

    /// The sole render-thread entry point. It returns one coherent set of
    /// levels, rather than five independently-read mutable source properties.
    nonisolated func latestSnapshot() -> AudioFeatureSnapshot {
        featureStore.snapshot()
    }

    nonisolated var hasActiveFeatureSource: Bool {
        latestSnapshot().isActive
    }

    var sourceDescriptors: [AudioSourceDescriptor] {
        var descriptors: [AudioSourceDescriptor] = [microphone.descriptor]
        #if os(macOS)
        descriptors.append(systemOutput.descriptor)
        #endif
        descriptors.append(appleMusic.descriptor)
        descriptors.append(spotifyDescriptor)
        return descriptors
    }

    /// Every capture source follows the same lifecycle surface; media services
    /// are intentionally shown as context-only rows, not fake audio inputs.
    func canStart(_ sourceID: AudioSourceID) -> Bool {
        !transitionGate.isStarting(sourceID) && captureSource(for: sourceID)?.descriptor.canStart == true
    }

    func isStarting(_ sourceID: AudioSourceID) -> Bool {
        transitionGate.isStarting(sourceID)
    }

    @discardableResult
    func start(_ sourceID: AudioSourceID) async -> Bool {
        guard let source = captureSource(for: sourceID),
              source.descriptor.canStart,
              transitionGate.beginStart(for: sourceID) else {
            return false
        }
        defer { transitionGate.finishStart(for: sourceID) }

        // Start first: a denied permission leaves the currently-working source
        // untouched. Once it is live, stop all other PCM backends so their FFT
        // state cannot accidentally be mixed by an old UI command.
        guard await source.startCapture() else {
            refreshFeatureSnapshot()
            return false
        }

        for other in captureSources where other.sourceID != sourceID && other.isActive {
            await other.stopCapture()
        }

        selectedSourceID = sourceID
        refreshFeatureSnapshot()
        return true
    }

    func stop(_ sourceID: AudioSourceID) async {
        guard let source = captureSource(for: sourceID) else { return }
        await source.stopCapture()
        if selectedSourceID == sourceID {
            selectedSourceID = nil
        }
        refreshFeatureSnapshot()
    }

    func refreshAvailability() async {
        for source in captureSources {
            await source.refreshAvailability()
        }
        refreshFeatureSnapshot()
    }

    /// Called by the coalesced main-actor update loop. Apple Music's existing
    /// timing source advances here, and every active source is then collapsed
    /// into an immutable snapshot for the render thread.
    func updateFrame() {
        appleMusic.advanceFrame()
        refreshFeatureSnapshot()
    }

    func setMixPolicy(_ policy: AudioMixPolicy) {
        mixPolicy = policy
        refreshFeatureSnapshot()
    }

    /// ScreenCaptureKit capture must stop when the app becomes inactive. The
    /// method lives here instead of in a specific SwiftUI tab so it stays true
    /// when audio controls move to another surface.
    func stopTransientSources() async {
        #if os(macOS)
        if systemOutput.isActive {
            await systemOutput.stopCapture()
            if selectedSourceID == .systemOutput {
                selectedSourceID = nil
            }
        }
        #endif
        refreshFeatureSnapshot()
    }

    func openSettings(for sourceID: AudioSourceID) {
        if sourceID == .microphone {
            microphone.openSettings()
            return
        }

        #if os(macOS)
        if sourceID == .systemOutput {
            systemOutput.openSettings()
        }
        #endif
    }

    func canOpenSettings(for sourceID: AudioSourceID) -> Bool {
        if sourceID == .microphone { return true }
        #if os(macOS)
        return sourceID == .systemOutput
        #else
        return false
        #endif
    }

    // MARK: - Snapshot policy

    private func refreshFeatureSnapshot(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        let pcmContributions = captureSources.compactMap { $0.featureContribution(at: now) }
        let selectedPCM = resolvedPCMContributions(from: pcmContributions)

        // Metadata-derived features are a fallback only. This preserves existing
        // Apple Music behavior on non-Mac targets without blending a synthetic
        // beat guide into microphone/system PCM or calling it raw audio.
        let candidates = selectedPCM.isEmpty
            ? [appleMusic.featureContribution(at: now)].compactMap { $0 }
            : selectedPCM
        let selection = Set(candidates.map(\.sourceID))

        featureStore.replace(
            AudioFeatureMixer.mix(
                contributions: candidates,
                selectedSourceIDs: selection,
                policy: mixPolicy,
                now: now
            )
        )
    }

    private func resolvedPCMContributions(from contributions: [AudioSourceContribution]) -> [AudioSourceContribution] {
        guard !contributions.isEmpty else { return [] }

        if let selectedSourceID,
           let selected = contributions.first(where: { $0.sourceID == selectedSourceID }) {
            return [selected]
        }

        // Automatic mode is deterministic and conservative: system capture is
        // preferred when explicitly live, otherwise use the microphone. The UI
        // enters explicit mode for every start action, so this only covers
        // recovery from a route change or a legacy call site.
        let ordered = contributions.sorted { lhs, rhs in
            sourcePriority(lhs.sourceID) < sourcePriority(rhs.sourceID)
        }
        return ordered.first.map { [$0] } ?? []
    }

    private func captureSource(for sourceID: AudioSourceID) -> (any AudioCaptureSource)? {
        captureSources.first(where: { $0.sourceID == sourceID })
    }

    private var captureSources: [any AudioCaptureSource] {
        var sources: [any AudioCaptureSource] = [microphone]
        #if os(macOS)
        sources.append(systemOutput)
        #endif
        return sources
    }

    private var spotifyDescriptor: AudioSourceDescriptor {
        AudioCapabilityRegistry.descriptors(
            for: AudioCapabilityContext(
                platform: runtimePlatform,
                systemOutputCapturePolicy: configuration.systemOutputCapturePolicy,
                appleMusicAvailable: !isMacAppleMusicStub,
                // No Spotify provider is registered in this build, so it must
                // remain blocked even if a future product policy is approved.
                spotifyVisualSyncApproved: false
            )
        ).first(where: { $0.id == .spotify })!
    }

    private var runtimePlatform: AudioPlatform {
        #if targetEnvironment(simulator)
        return .simulator
        #elseif os(macOS)
        return .macOS
        #elseif os(visionOS)
        return .visionOS
        #else
        return .iPadOS
        #endif
    }

    private var isMacAppleMusicStub: Bool {
        #if os(macOS)
        return true
        #else
        return false
        #endif
    }

    private func sourcePriority(_ sourceID: AudioSourceID) -> Int {
        switch sourceID {
        case .systemOutput: return 0
        case .microphone: return 1
        case .appleMusic: return 2
        case .spotify: return 3
        }
    }
}
