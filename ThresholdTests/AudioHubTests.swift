import Foundation
import Testing
@testable import Threshold

@Suite("Audio hub feature policy")
struct AudioHubTests {
    @Test("Finger-pinch sources are not offered on platforms without hand tracking")
    func fingerSourcesAbsentFromPickerWithoutHandTracking() {
        // The test host is macOS: pinch levels are hardwired zero here, so a
        // finger mapping could never produce input — offering one would let
        // its input offset hold a permanent parameter deviation. The enum
        // cases themselves must still exist for scene decode compatibility.
        #expect(MusicReactiveSource.pickerCases.allSatisfy { !$0.isFingerInput })
        #expect(MusicReactiveSource.allCases.contains(.leftIndexPinch))
    }

    @Test("An empty source selection produces an inactive zero snapshot")
    func emptySelectionProducesZeroSnapshot() {
        let now = 42.0
        let snapshot = AudioFeatureMixer.mix(
            contributions: [contribution(.microphone, at: now)],
            selectedSourceIDs: [],
            policy: .weighted,
            now: now
        )

        #expect(snapshot.timestamp == now)
        #expect(snapshot.contributions.isEmpty)
        #expect(snapshot.mixed == .zero)
        #expect(snapshot.provenance == .unknown)
        #expect(!snapshot.isActive)
    }

    @Test("Weighted mixing uses confidence-adjusted weights and preserves the strongest onset")
    func weightedMixUsesExpectedFeatureMath() {
        let now = 42.0
        let microphone = contribution(
            .microphone,
            features: AudioFeatures(
                bass: 0.2,
                mid: 0.4,
                treble: 0.6,
                onset: 0.25,
                overall: 0.8,
                confidence: 0.5
            ),
            at: now,
            weight: 0.8
        )
        let systemOutput = contribution(
            .systemOutput,
            features: AudioFeatures(
                bass: 0.8,
                mid: 0.6,
                treble: 0.2,
                onset: 0.9,
                overall: 0.4,
                confidence: 1
            ),
            at: now,
            weight: 0.6
        )

        let snapshot = AudioFeatureMixer.mix(
            contributions: [microphone, systemOutput],
            selectedSourceIDs: [.microphone, .systemOutput],
            policy: .weighted,
            now: now
        )

        // Effective weights are 0.4 (microphone) and 0.6 (system output).
        #expect(snapshot.isActive)
        #expect(snapshot.provenance == .pcm)
        #expect(snapshot.contributions.map(\.sourceID) == [.microphone, .systemOutput])
        #expect(approximatelyEqual(snapshot.mixed.bass, 0.56))
        #expect(approximatelyEqual(snapshot.mixed.mid, 0.52))
        #expect(approximatelyEqual(snapshot.mixed.treble, 0.36))
        #expect(approximatelyEqual(snapshot.mixed.overall, 0.56))
        #expect(approximatelyEqual(snapshot.mixed.onset, 0.9))
        #expect(approximatelyEqual(snapshot.mixed.confidence, 0.5))
    }

    @Test("Weighted mixing is independent of contribution input order")
    func weightedMixIsOrderInvariant() {
        let now = 42.0
        let microphone = contribution(.microphone, at: now, weight: 0.25)
        let systemOutput = contribution(
            .systemOutput,
            features: AudioFeatures(bass: 0.9, onset: 0.8, overall: 0.9),
            at: now,
            weight: 0.75
        )

        let forward = AudioFeatureMixer.mix(
            contributions: [microphone, systemOutput],
            selectedSourceIDs: [.microphone, .systemOutput],
            policy: .weighted,
            now: now
        )
        let reversed = AudioFeatureMixer.mix(
            contributions: [systemOutput, microphone],
            selectedSourceIDs: [.microphone, .systemOutput],
            policy: .weighted,
            now: now
        )

        #expect(forward == reversed)
    }

    @Test("Unselected and stale contributions do not reach a mixed snapshot")
    func unselectedAndStaleInputsAreExcluded() {
        let now = 42.0
        let freshMicrophone = contribution(
            .microphone,
            features: AudioFeatures(bass: 0.3, onset: 0.4, overall: 0.3),
            at: now
        )
        let staleSystemOutput = contribution(
            .systemOutput,
            features: AudioFeatures(bass: 0.9, onset: 0.9, overall: 0.9),
            at: now - 0.36
        )
        let unselectedAppleMusic = contribution(
            .appleMusic,
            features: AudioFeatures(bass: 0.8, onset: 0.8, overall: 0.8),
            provenance: .metadataSynthetic,
            at: now
        )

        let snapshot = AudioFeatureMixer.mix(
            contributions: [freshMicrophone, staleSystemOutput, unselectedAppleMusic],
            selectedSourceIDs: [.microphone, .systemOutput],
            policy: .weighted,
            now: now
        )

        #expect(snapshot.contributions.map(\.sourceID) == [.microphone])
        #expect(snapshot.mixed == freshMicrophone.features)
        #expect(snapshot.provenance == .pcm)
    }

    @Test("Non-finite features are dropped without diluting healthy source values")
    func nanContributionIsExcluded() {
        let now = 42.0
        let poisonedMicrophone = contribution(
            .microphone,
            features: AudioFeatures(bass: .nan, mid: 0.2, treble: 0.2, onset: 0.2, overall: 0.2),
            at: now
        )
        let healthySystemOutput = contribution(
            .systemOutput,
            features: AudioFeatures(bass: 0.7, mid: 0.6, treble: 0.5, onset: 0.8, overall: 0.7),
            at: now
        )

        let snapshot = AudioFeatureMixer.mix(
            contributions: [poisonedMicrophone, healthySystemOutput],
            selectedSourceIDs: [.microphone, .systemOutput],
            policy: .weighted,
            now: now
        )

        #expect(snapshot.contributions.map(\.sourceID) == [.systemOutput])
        #expect(snapshot.mixed == healthySystemOutput.features)
        #expect(snapshot.mixed.isFinite)
    }

    @Test("System-output capture requires an approved app allowlist on macOS")
    func systemOutputCapabilityPolicyMatrix() {
        let blockedMacOS = AudioCapabilityRegistry.descriptors(
            for: AudioCapabilityContext(
                platform: .macOS,
                microphonePermission: .granted,
                systemAudioPermission: .granted
            )
        )
        let approvedMacOS = AudioCapabilityRegistry.descriptors(
            for: AudioCapabilityContext(
                platform: .macOS,
                microphonePermission: .granted,
                systemAudioPermission: .granted,
                systemOutputCapturePolicy: .approvedApplicationBundleIDs(["com.example.approved-audio"])
            )
        )
        let iPadOS = AudioCapabilityRegistry.descriptors(
            for: AudioCapabilityContext(
                platform: .iPadOS,
                microphonePermission: .granted,
                systemAudioPermission: .granted,
                systemOutputCapturePolicy: .approvedApplicationBundleIDs(["com.example.approved-audio"])
            )
        )

        let blockedMacSystemOutput = descriptor(.systemOutput, in: blockedMacOS)
        let approvedMacSystemOutput = descriptor(.systemOutput, in: approvedMacOS)
        let iPadSystemOutput = descriptor(.systemOutput, in: iPadOS)
        let iPadMicrophone = descriptor(.microphone, in: iPadOS)

        #expect(blockedMacSystemOutput.availability == .policyBlocked("System audio capture is disabled until a policy-approved application allowlist is configured."))
        #expect(!blockedMacSystemOutput.canStart)

        #expect(approvedMacSystemOutput.availability == .available)
        #expect(approvedMacSystemOutput.canStart)
        #expect(approvedMacSystemOutput.capabilities.contains(.pcmFrames))
        #expect(approvedMacSystemOutput.capabilities.contains(.captureLifecycle))
        #expect(approvedMacSystemOutput.capabilities.contains(.systemOutput))

        #expect(iPadSystemOutput.availability == .unavailable("System-output capture is not offered on this platform."))
        #expect(!iPadSystemOutput.canStart)
        #expect(iPadMicrophone.availability == .available)
        #expect(iPadMicrophone.canStart)
        #expect(iPadMicrophone.capabilities.contains(.pcmFrames))
    }

    @Test("Source transition gate rejects a duplicate start until the first finishes")
    func transitionGateSerializesStarts() {
        var gate = AudioSourceTransitionGate()

        let firstMicrophoneStart = gate.beginStart(for: .microphone)
        #expect(firstMicrophoneStart)
        #expect(gate.isStarting(.microphone))
        let duplicateMicrophoneStart = gate.beginStart(for: .microphone)
        #expect(!duplicateMicrophoneStart)
        let systemOutputStart = gate.beginStart(for: .systemOutput)
        #expect(systemOutputStart)

        gate.finishStart(for: .microphone)

        #expect(!gate.isStarting(.microphone))
        let resumedMicrophoneStart = gate.beginStart(for: .microphone)
        #expect(resumedMicrophoneStart)
    }

    @Test("Spotify remains a policy-blocked media-context source by default")
    func spotifyDescriptorIsPolicyBlocked() {
        let spotify = descriptor(
            .spotify,
            in: AudioCapabilityRegistry.descriptors(
                for: AudioCapabilityContext(platform: .macOS, spotifyVisualSyncApproved: false)
            )
        )

        #expect(spotify.kind == .mediaContext)
        #expect(spotify.availability == .policyBlocked("Spotify visual synchronization requires product and policy approval before it can drive reactive visuals."))
        #expect(!spotify.canStart)
        #expect(!spotify.capabilities.contains(.pcmFrames))
        #expect(spotify.provenance == nil)
    }

    @Test("Apple Music is a metadata context, never a PCM capture source")
    func appleMusicDescriptorDoesNotAdvertisePCM() {
        let appleMusic = descriptor(
            .appleMusic,
            in: AudioCapabilityRegistry.descriptors(
                for: AudioCapabilityContext(platform: .iPadOS, appleMusicAvailable: true)
            )
        )

        #expect(appleMusic.kind == .mediaContext)
        #expect(appleMusic.availability == .available)
        #expect(appleMusic.provenance == .metadataSynthetic)
        #expect(!appleMusic.canStart)
        #expect(!appleMusic.capabilities.contains(.pcmFrames))
        #expect(!appleMusic.capabilities.contains(.captureLifecycle))
        #expect(appleMusic.capabilities.contains(.nowPlaying))
        #expect(appleMusic.capabilities.contains(.metadataTempo))
    }

    private func contribution(
        _ sourceID: AudioSourceID,
        features: AudioFeatures = AudioFeatures(
            bass: 0.2,
            mid: 0.3,
            treble: 0.4,
            onset: 0.5,
            overall: 0.3
        ),
        provenance: AudioFeatureProvenance = .pcm,
        at timestamp: TimeInterval,
        weight: Float = 1
    ) -> AudioSourceContribution {
        AudioSourceContribution(
            sourceID: sourceID,
            features: features,
            provenance: provenance,
            timestamp: timestamp,
            weight: weight
        )
    }

    private func descriptor(
        _ sourceID: AudioSourceID,
        in descriptors: [AudioSourceDescriptor]
    ) -> AudioSourceDescriptor {
        guard let descriptor = descriptors.first(where: { $0.id == sourceID }) else {
            Issue.record("Missing descriptor for \(sourceID.rawValue)")
            fatalError("Missing descriptor for \(sourceID.rawValue)")
        }
        return descriptor
    }

    private func approximatelyEqual(_ lhs: Float, _ rhs: Float, tolerance: Float = 0.0001) -> Bool {
        abs(lhs - rhs) < tolerance
    }
}
