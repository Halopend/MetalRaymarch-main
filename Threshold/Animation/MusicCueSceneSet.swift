//
//  MusicCueSceneSet.swift
//  Threshold
//
//  A named, user-curated subset of switchable scenes. Multiple sets can be
//  saved; the active one supplies the Cue Scene Switcher's configured pool for
//  music cues and arrow-key stepping. A set can carry an attached song so
//  starting the set also starts the music that drives its automatic
//  transitions.
//

import Foundation

struct MusicCueSceneSet: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    /// Source-qualified `MusicCueSceneTarget` storage ids. Ids rather than
    /// scene values so membership survives renames, edits, and an iCloud scene
    /// temporarily not being available.
    var targetIDs: Set<String>
    /// Optional song started together with the set, letting cue-driven scene
    /// advancement run unattended for the length of a track.
    var attachedSong: SongAttachment?

    init(
        id: UUID = UUID(),
        name: String,
        targetIDs: Set<String> = [],
        attachedSong: SongAttachment? = nil
    ) {
        self.id = id
        self.name = name
        self.targetIDs = targetIDs
        self.attachedSong = attachedSong
    }

    enum CodingKeys: String, CodingKey {
        case id, name, targetIDs, attachedSong
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        let rawIDs = try c.decodeIfPresent([String].self, forKey: .targetIDs) ?? []
        targetIDs = Set(rawIDs.compactMap(MusicCueSceneTarget.normalizedStorageID))
        attachedSong = try c.decodeIfPresent(SongAttachment.self, forKey: .attachedSong)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(targetIDs.sorted(), forKey: .targetIDs)
        try c.encodeIfPresent(attachedSong, forKey: .attachedSong)
    }

    /// Converts the pre-sets single configured group into the initial set list.
    /// An empty legacy group migrates to no sets at all, so a fresh install
    /// starts with a clean slate instead of one empty placeholder.
    static func migratingLegacyGroup(rawTargetIDs: [String]) -> [MusicCueSceneSet] {
        let ids = Set(rawTargetIDs.compactMap(MusicCueSceneTarget.normalizedStorageID))
        guard !ids.isEmpty else { return [] }
        return [MusicCueSceneSet(name: "My Scenes", targetIDs: ids)]
    }
}
