//
//  MusicCueSceneGroupSequence.swift
//  Threshold
//
//  Deterministic ordering helper for user-configured music-cue scene groups.
//

import Foundation

/// Sources that can be combined into the scene pool. Keeping these sources
/// independent lets a performer, for example, cycle every animation together
/// with only the hand-picked static scenes in their cue group.
enum MusicCueSceneSource: String, CaseIterable, Identifiable, Hashable, Sendable {
    case configuredGroup
    case animationLibrary
    case staticSceneLibrary

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .configuredGroup: return "Active Collection"
        case .animationLibrary: return "All Animated Scenes"
        case .staticSceneLibrary: return "All Still Scenes"
        }
    }

    var shortDisplayName: String {
        switch self {
        case .configuredGroup: return "Collection"
        case .animationLibrary: return "Animated"
        case .staticSceneLibrary: return "Still"
        }
    }

    var systemImage: String {
        switch self {
        case .configuredGroup: return "rectangle.stack.badge.play"
        case .animationLibrary: return "film.stack"
        case .staticSceneLibrary: return "cube.transparent"
        }
    }

    var detail: String {
        switch self {
        case .configuredGroup: return "The scenes selected in the active collection"
        case .animationLibrary: return "Every scene with a playable keyframe sequence"
        case .staticSceneLibrary: return "Every saved scene with no animation"
        }
    }
}

/// How the scene pool is traversed. Source selection and traversal are kept
/// separate so every source combination can use any progression behavior.
enum MusicCueSceneTraversalMode: String, CaseIterable, Identifiable, Hashable, Sendable {
    case ordered
    case shuffleBag
    case random

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ordered: return "In Order"
        case .shuffleBag: return "Shuffle Bag"
        case .random: return "Random"
        }
    }

    var systemImage: String {
        switch self {
        case .ordered: return "arrow.right.arrow.left"
        case .shuffleBag: return "shuffle"
        case .random: return "die.face.5"
        }
    }

    var detail: String {
        switch self {
        case .ordered:
            return "Move through the pool's stable order"
        case .shuffleBag:
            return "Visit each available scene before repeating"
        case .random:
            return "Choose freely, without an immediate repeat"
        }
    }
}

/// A selectable item in the scene-switcher group. Animation sequences and
/// static scene presets intentionally share one namespace so a performance can
/// move between either kind of visual without maintaining separate playlists.
struct MusicCueSceneTarget: Identifiable, Equatable {
    enum Kind: String, Equatable {
        case animation
        case staticScene

        var displayName: String {
            switch self {
            case .animation: return "Animated Scene"
            case .staticScene: return "Still Scene"
            }
        }

        var systemImage: String {
            switch self {
            case .animation: return "film.stack"
            case .staticScene: return "cube.transparent"
            }
        }
    }

    let kind: Kind
    let sourceID: UUID
    let name: String
    let detail: String
    let tags: [String]

    init(
        kind: Kind,
        sourceID: UUID,
        name: String,
        detail: String,
        tags: [String] = []
    ) {
        self.kind = kind
        self.sourceID = sourceID
        self.name = name
        self.detail = detail
        self.tags = tags
    }

    /// Source-qualified and stable across renames. This is also the on-disk
    /// representation stored in UserDefaults for cue-group membership.
    var id: String { Self.storageID(kind: kind, sourceID: sourceID) }

    static func storageID(kind: Kind, sourceID: UUID) -> String {
        "\(kind.rawValue):\(sourceID.uuidString)"
    }

    /// Decodes a current namespaced id or a pre-release UUID-only id. The latter
    /// means an animation scene so an early cue group remains usable after static
    /// scenes are added to the switcher.
    static func normalizedStorageID(_ rawValue: String) -> String? {
        if let legacyID = UUID(uuidString: rawValue) {
            return storageID(kind: .animation, sourceID: legacyID)
        }

        let pieces = rawValue.split(separator: ":", maxSplits: 1)
        guard pieces.count == 2,
              let kind = Kind(rawValue: String(pieces[0])),
              let sourceID = UUID(uuidString: String(pieces[1])) else {
            return nil
        }
        return storageID(kind: kind, sourceID: sourceID)
    }
}

enum MusicCueSceneGroupSequence {
    /// Produces the active pool for any combination of source toggles. The
    /// configured group is intentionally first, letting a short curated set
    /// lead into a broader library without duplicated entries.
    static func eligibleTargets(
        sources: Set<MusicCueSceneSource>,
        availableTargets: [MusicCueSceneTarget],
        configuredGroupTargetIDs: Set<String>
    ) -> [MusicCueSceneTarget] {
        var pooledTargets: [MusicCueSceneTarget] = []

        if sources.contains(.configuredGroup) {
            pooledTargets += availableTargets.filter { configuredGroupTargetIDs.contains($0.id) }
        }
        if sources.contains(.animationLibrary) {
            pooledTargets += availableTargets.filter { $0.kind == .animation }
        }
        if sources.contains(.staticSceneLibrary) {
            pooledTargets += availableTargets.filter { $0.kind == .staticScene }
        }

        var seenTargetIDs: Set<String> = []
        return pooledTargets.filter { seenTargetIDs.insert($0.id).inserted }
    }

    /// Resolves one step through `candidateIDs`, wrapping at either end. If the
    /// current scene is outside the group, a forward step enters at the first
    /// member and a backward step enters at the last member.
    static func nextIndex<ID: Hashable>(
        currentID: ID?,
        candidateIDs: [ID],
        step: Int
    ) -> Int? {
        guard candidateIDs.count > 1, step != 0 else { return nil }

        guard let currentID,
              let currentIndex = candidateIDs.firstIndex(of: currentID) else {
            return step > 0 ? 0 : candidateIDs.count - 1
        }

        let offset = step % candidateIDs.count
        return ((currentIndex + offset) % candidateIDs.count + candidateIDs.count) % candidateIDs.count
    }

    /// Candidate ids eligible for an unpredictable selection. When more than
    /// one target exists this omits the current target, so Random and Shuffle
    /// Bag never immediately repeat the displayed scene.
    static func nonRepeatingCandidateIDs<ID: Hashable>(
        currentID: ID?,
        candidateIDs: [ID]
    ) -> [ID] {
        guard let currentID else { return candidateIDs }
        let alternatives = candidateIDs.filter { $0 != currentID }
        return alternatives.isEmpty ? candidateIDs : alternatives
    }
}
