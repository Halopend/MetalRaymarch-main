//
//  AudioFeatureSnapshot.swift
//  Threshold
//
//  Platform-neutral contracts for audio capture, analysis, and media context.
//  These types intentionally keep "what is playing" separate from "what PCM
//  frames are available to analyze" so a media SDK is never mistaken for a
//  microphone or system-audio source.
//

import Foundation

// MARK: - Source identity and capabilities

enum AudioSourceID: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case microphone
    case systemOutput
    case appleMusic
    case spotify

    var id: String { rawValue }
}

enum AudioSourceKind: String, Codable, Sendable {
    case capture
    case mediaContext
}

struct AudioSourceCapabilities: OptionSet, Hashable, Sendable {
    let rawValue: UInt16

    static let pcmFrames        = AudioSourceCapabilities(rawValue: 1 << 0)
    static let captureLifecycle = AudioSourceCapabilities(rawValue: 1 << 1)
    static let inputSelection   = AudioSourceCapabilities(rawValue: 1 << 2)
    static let systemOutput     = AudioSourceCapabilities(rawValue: 1 << 3)
    static let nowPlaying       = AudioSourceCapabilities(rawValue: 1 << 4)
    static let transport        = AudioSourceCapabilities(rawValue: 1 << 5)
    static let library          = AudioSourceCapabilities(rawValue: 1 << 6)
    static let metadataTempo    = AudioSourceCapabilities(rawValue: 1 << 7)
}

enum AudioSourceAvailability: Equatable, Sendable {
    case available
    case active
    case permissionRequired(String)
    case failed(String)
    case unavailable(String)
    case policyBlocked(String)

    var canStart: Bool {
        switch self {
        case .available, .permissionRequired, .failed:
            return true
        case .active, .unavailable, .policyBlocked:
            return false
        }
    }

    var isPolicyBlocked: Bool {
        if case .policyBlocked = self { return true }
        return false
    }

    var isUnavailable: Bool {
        if case .unavailable = self { return true }
        return false
    }

    var detail: String? {
        switch self {
        case .available, .active:
            return nil
        case .permissionRequired(let message), .failed(let message), .unavailable(let message), .policyBlocked(let message):
            return message
        }
    }
}

struct AudioSourceDescriptor: Identifiable, Equatable, Sendable {
    let id: AudioSourceID
    let kind: AudioSourceKind
    let displayName: String
    let systemImage: String
    let capabilities: AudioSourceCapabilities
    let availability: AudioSourceAvailability
    let provenance: AudioFeatureProvenance?

    var isActive: Bool { availability == .active }
    var canStart: Bool { availability.canStart && capabilities.contains(.captureLifecycle) }
}

// MARK: - Media-platform policy matrix

enum AudioPlatform: String, Codable, Hashable, Sendable {
    case macOS
    case iPadOS
    case visionOS
    case simulator
}

enum AudioPermissionState: String, Codable, Hashable, Sendable {
    case undetermined
    case granted
    case denied
}

/// Product-policy boundary for ScreenCaptureKit audio. An application-level
/// allowlist is required because a whole-system tap cannot reliably identify a
/// streaming provider (for example, music playing inside a web browser).
enum SystemOutputCapturePolicy: Equatable, Sendable {
    case blocked(reason: String)
    case approvedApplicationBundleIDs(Set<String>)

    static let requiresExplicitApproval = SystemOutputCapturePolicy.blocked(
        reason: "System audio capture is disabled until a policy-approved application allowlist is configured."
    )

    var blockReason: String? {
        guard case .blocked(let reason) = self else { return nil }
        return reason
    }

    var approvedApplicationBundleIDs: Set<String> {
        guard case .approvedApplicationBundleIDs(let bundleIDs) = self else { return [] }
        return bundleIDs
    }
}

/// Runtime configuration for policy decisions that must be made before a
/// capture backend is started. The shipping default is intentionally
/// conservative; a product-approved integration can supply a narrow,
/// non-browser application allowlist at composition time.
struct AudioHubConfiguration: Sendable {
    var systemOutputCapturePolicy: SystemOutputCapturePolicy

    init(systemOutputCapturePolicy: SystemOutputCapturePolicy = .requiresExplicitApproval) {
        self.systemOutputCapturePolicy = systemOutputCapturePolicy
    }
}

/// Inputs used to produce a platform-specific source list. The live `AudioHub`
/// supplies these from real capture backends; tests can inject every state
/// without invoking TCC, AVAudioEngine, or ScreenCaptureKit.
struct AudioCapabilityContext: Sendable {
    var platform: AudioPlatform
    var microphonePermission: AudioPermissionState
    var systemAudioPermission: AudioPermissionState
    var systemOutputCapturePolicy: SystemOutputCapturePolicy
    var appleMusicAvailable: Bool
    var spotifyVisualSyncApproved: Bool

    init(platform: AudioPlatform,
         microphonePermission: AudioPermissionState = .undetermined,
         systemAudioPermission: AudioPermissionState = .undetermined,
         systemOutputCapturePolicy: SystemOutputCapturePolicy = .requiresExplicitApproval,
         appleMusicAvailable: Bool = true,
         spotifyVisualSyncApproved: Bool = false) {
        self.platform = platform
        self.microphonePermission = microphonePermission
        self.systemAudioPermission = systemAudioPermission
        self.systemOutputCapturePolicy = systemOutputCapturePolicy
        self.appleMusicAvailable = appleMusicAvailable
        self.spotifyVisualSyncApproved = spotifyVisualSyncApproved
    }
}

/// Pure capability registry. This is deliberately independent of UI and the
/// runtime capture classes so unsupported paths do not leak through a platform
/// conditional in a view.
enum AudioCapabilityRegistry {
    static func descriptors(for context: AudioCapabilityContext) -> [AudioSourceDescriptor] {
        var descriptors = [
            microphoneDescriptor(permission: context.microphonePermission),
            systemOutputDescriptor(
                platform: context.platform,
                permission: context.systemAudioPermission,
                policy: context.systemOutputCapturePolicy
            ),
            appleMusicDescriptor(isAvailable: context.appleMusicAvailable)
        ]
        // No Spotify provider ships on iPad/iPhone. A blocked placeholder is
        // useful on desktop for policy visibility, but exposing it as an iPad
        // Source row implies a connection path that does not exist.
        if context.platform != .iPadOS && context.platform != .simulator {
            descriptors.append(spotifyDescriptor(visualSyncApproved: context.spotifyVisualSyncApproved))
        }
        return descriptors
    }

    private static func microphoneDescriptor(permission: AudioPermissionState) -> AudioSourceDescriptor {
        let availability: AudioSourceAvailability
        switch permission {
        case .granted:
            availability = .available
        case .undetermined:
            availability = .permissionRequired("Microphone permission is requested only when you start this source.")
        case .denied:
            availability = .unavailable("Microphone access is denied in system settings.")
        }

        return AudioSourceDescriptor(
            id: .microphone,
            kind: .capture,
            displayName: "Microphone",
            systemImage: "mic",
            capabilities: [.pcmFrames, .captureLifecycle],
            availability: availability,
            provenance: .pcm
        )
    }

    private static func systemOutputDescriptor(platform: AudioPlatform,
                                               permission: AudioPermissionState,
                                               policy: SystemOutputCapturePolicy) -> AudioSourceDescriptor {
        let availability: AudioSourceAvailability
        if platform != .macOS {
            availability = .unavailable("System-output capture is not offered on this platform.")
        } else if let reason = policy.blockReason {
            availability = .policyBlocked(reason)
        } else {
            switch permission {
            case .granted:
                availability = .available
            case .undetermined:
                availability = .permissionRequired("System-output capture is not included in this release.")
            case .denied:
                availability = .unavailable("System-output capture is not included in this release.")
            }
        }

        return AudioSourceDescriptor(
            id: .systemOutput,
            kind: .capture,
            displayName: "System Audio",
            systemImage: "speaker.wave.2",
            capabilities: [.pcmFrames, .captureLifecycle, .systemOutput],
            availability: availability,
            provenance: .pcm
        )
    }

    private static func appleMusicDescriptor(isAvailable: Bool) -> AudioSourceDescriptor {
        AudioSourceDescriptor(
            id: .appleMusic,
            kind: .mediaContext,
            displayName: "Apple Music",
            systemImage: "apple.logo",
            capabilities: [.nowPlaying, .transport, .library, .metadataTempo],
            availability: isAvailable
                ? .available
                : .unavailable("Apple Music playback and library access are not included in this build."),
            provenance: .metadataSynthetic
        )
    }

    private static func spotifyDescriptor(visualSyncApproved: Bool) -> AudioSourceDescriptor {
        AudioSourceDescriptor(
            id: .spotify,
            kind: .mediaContext,
            displayName: "Spotify",
            systemImage: "music.note",
            capabilities: [.nowPlaying, .transport, .library],
            availability: visualSyncApproved
                ? .available
                : .policyBlocked("Spotify visual synchronization requires product and policy approval before it can drive reactive visuals."),
            provenance: nil
        )
    }
}

/// Main-actor lifecycle helper that keeps two UI events from starting the same
/// backend concurrently while a permission or capture request is suspended.
struct AudioSourceTransitionGate: Sendable {
    private(set) var startingSourceIDs: Set<AudioSourceID> = []

    mutating func beginStart(for sourceID: AudioSourceID) -> Bool {
        startingSourceIDs.insert(sourceID).inserted
    }

    mutating func finishStart(for sourceID: AudioSourceID) {
        startingSourceIDs.remove(sourceID)
    }

    func isStarting(_ sourceID: AudioSourceID) -> Bool {
        startingSourceIDs.contains(sourceID)
    }
}

// MARK: - Normalized feature values

enum AudioFeatureProvenance: String, Codable, Hashable, Sendable {
    /// FFT/RMS/onset values derived from PCM frames captured by this app.
    case pcm
    /// Values synthesized from metadata, tempo, or playback position.
    case metadataSynthetic
    /// A blend of two or more feature origins.
    case mixed
    case unknown
}

struct AudioFeatures: Equatable, Sendable {
    var bass: Float
    var mid: Float
    var treble: Float
    var onset: Float
    var overall: Float
    var confidence: Float

    init(bass: Float = 0,
         mid: Float = 0,
         treble: Float = 0,
         onset: Float = 0,
         overall: Float = 0,
         confidence: Float = 1) {
        self.bass = bass
        self.mid = mid
        self.treble = treble
        self.onset = onset
        self.overall = overall
        self.confidence = confidence
    }

    static let zero = AudioFeatures(confidence: 0)

    var isFinite: Bool {
        bass.isFinite && mid.isFinite && treble.isFinite && onset.isFinite &&
            overall.isFinite && confidence.isFinite
    }

    func sanitized() -> AudioFeatures {
        AudioFeatures(
            bass: normalized(bass),
            mid: normalized(mid),
            treble: normalized(treble),
            onset: normalized(onset),
            overall: normalized(overall),
            confidence: normalized(confidence)
        )
    }
}

struct AudioSourceContribution: Equatable, Sendable {
    let sourceID: AudioSourceID
    let features: AudioFeatures
    let provenance: AudioFeatureProvenance
    let timestamp: TimeInterval
    let weight: Float

    init(sourceID: AudioSourceID,
         features: AudioFeatures,
         provenance: AudioFeatureProvenance,
         timestamp: TimeInterval,
         weight: Float = 1) {
        self.sourceID = sourceID
        self.features = features
        self.provenance = provenance
        self.timestamp = timestamp
        self.weight = weight
    }
}

enum AudioMixPolicy: String, Codable, Hashable, Sendable {
    /// One deterministic source is selected. The hub uses this while capture
    /// sources are transitioning so microphone and system output cannot
    /// accidentally double-count the same sound.
    case exclusive
    /// Continuous features are weighted; transient onset remains the maximum.
    case weighted
}

struct AudioFeatureSnapshot: Equatable, Sendable {
    let timestamp: TimeInterval
    let contributions: [AudioSourceContribution]
    let mixed: AudioFeatures
    let provenance: AudioFeatureProvenance
    let isActive: Bool

    static func empty(at timestamp: TimeInterval) -> AudioFeatureSnapshot {
        AudioFeatureSnapshot(
            timestamp: timestamp,
            contributions: [],
            mixed: .zero,
            provenance: .unknown,
            isActive: false
        )
    }
}

private func normalized(_ value: Float) -> Float {
    guard value.isFinite else { return 0 }
    return min(1, max(0, value))
}
