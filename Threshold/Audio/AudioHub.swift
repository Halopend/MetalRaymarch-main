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

/// Device-local launch preference for microphone capture. It intentionally
/// lives outside scene audio-reactivity settings so opening a saved scene never
/// changes whether the microphone starts with the app.
enum AudioInputLaunchPreference {
    static let microphoneStartsAtLaunchDefaultsKey = "audio.microphone.startsAtLaunch"

    static func microphoneStartsAtLaunch(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: microphoneStartsAtLaunchDefaultsKey)
    }
}

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
    @ObservationIgnored private var didHandleMicrophoneLaunchPreference = false

    /// Fixed for the hub's lifetime. Stored (not computed) so the per-frame
    /// paths don't rebuild an existential array on every access.
    private let captureSources: [any AudioCaptureSource]

    nonisolated private let featureStore: AudioFeatureStore

    /// Main-actor observer for consumers that react to a completed, coherent
    /// audio snapshot (for example cue-driven scene progression). The render
    /// path continues to read `latestSnapshot()` directly and never waits on
    /// this callback.
    @ObservationIgnored var onFeatureSnapshotUpdated: ((AudioFeatureSnapshot) -> Void)?

    init(
        microphoneAnalyzer: AudioAnalyzer,
        appleMusicManager: AppleMusicManager,
        configuration: AudioHubConfiguration = .init()
    ) {
        self.configuration = configuration
        let microphone = MicrophoneCaptureSource(analyzer: microphoneAnalyzer)
        self.microphone = microphone
        self.appleMusic = AppleMusicMetadataFeatureSource(manager: appleMusicManager)
        #if os(macOS)
        let systemOutput = SystemOutputCaptureSource(policy: configuration.systemOutputCapturePolicy)
        self.systemOutput = systemOutput
        self.captureSources = [microphone, systemOutput]
        #else
        self.captureSources = [microphone]
        #endif
        self.featureStore = AudioFeatureStore(initialValue: .empty(at: ProcessInfo.processInfo.systemUptime))
    }

    /// Applies the user's microphone launch preference once per app-model
    /// lifetime. A remounted root view must not restart input that the user
    /// explicitly stopped during the current session.
    func startMicrophoneAtLaunchIfEnabled() async {
        guard !didHandleMicrophoneLaunchPreference else { return }
        didHandleMicrophoneLaunchPreference = true

        guard !SettingsPersistence.benchmarkHermetic,
              AudioInputLaunchPreference.microphoneStartsAtLaunch() else {
            return
        }

        _ = await start(.microphone)
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
        ensureCaptureRefreshTimer()
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

    /// Called by the coalesced main-actor update loop (and by the fallback
    /// timer while capture runs with rendering paused). Capture sources apply
    /// their display-cadence envelope smoothing, Apple Music's timing source
    /// advances, and every active source is then collapsed into an immutable
    /// snapshot for the render thread.
    func updateFrame() {
        let now = ProcessInfo.processInfo.systemUptime
        lastUpdateFrameTime = now
        for source in captureSources {
            source.advanceFrame(at: now)
        }
        appleMusic.advanceFrame()
        refreshFeatureSnapshot(now: now)
    }

    /// Uptime of the most recent `updateFrame()`, whoever drove it. Lets the
    /// fallback timer skip its tick while the render loop is already driving
    /// updates, so envelopes see one stable cadence instead of two interleaved
    /// ones (60 Hz render + 20 Hz timer → jittery deltaTime).
    @ObservationIgnored private var lastUpdateFrameTime: TimeInterval = 0

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

    // MARK: - Fallback refresh

    /// The render loop drives `updateFrame()` while it runs, but the snapshot,
    /// envelopes, and staleness gating must stay live even when rendering is
    /// paused or the visuals aren't in an audio mode — otherwise meters freeze
    /// at stale values. A low-rate timer covers that gap while any capture
    /// source is active, and retires itself once none is.
    private func ensureCaptureRefreshTimer() {
        guard captureRefreshTimer == nil else { return }
        // Not `scheduledTimer`: that installs in `.default` mode only, so the
        // timer would freeze during menu/popover/slider event-tracking loops —
        // exactly when the user is watching the meters. `.common` covers both.
        let timer = Timer(timeInterval: 1.0 / 20.0, repeats: true) { [weak self] timer in
            // The hub is gone: the timer must not keep firing no-ops on the
            // main run loop for the rest of the process lifetime. Handled
            // outside the isolated region so the non-Sendable `timer` is
            // never sent across it.
            guard let self else {
                timer.invalidate()
                return
            }
            MainActor.assumeIsolated {
                guard self.captureSources.contains(where: { $0.isActive }) else {
                    self.captureRefreshTimer?.invalidate()
                    self.captureRefreshTimer = nil
                    self.refreshFeatureSnapshot()
                    return
                }
                // The render loop drove an update moments ago — skip this tick
                // rather than interleave a second cadence into the envelopes.
                let now = ProcessInfo.processInfo.systemUptime
                if now - self.lastUpdateFrameTime < 0.05 { return }
                self.updateFrame()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        captureRefreshTimer = timer
    }

    @ObservationIgnored private var captureRefreshTimer: Timer?

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

        let snapshot = AudioFeatureMixer.mix(
            contributions: candidates,
            selectedSourceIDs: selection,
            policy: mixPolicy,
            now: now
        )
        featureStore.replace(snapshot)
        onFeatureSnapshotUpdated?(snapshot)
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
