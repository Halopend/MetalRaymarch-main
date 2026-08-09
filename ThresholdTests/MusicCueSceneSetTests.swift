//
//  MusicCueSceneSetTests.swift
//  ThresholdTests
//
//  Covers the saved scene-set model behind the Cue Scene Switcher: Codable
//  round-trips, legacy single-group migration, and AnimationManager's set
//  management (create/activate/rename/delete, membership editing, and the
//  attached-song contract used by "start set" playback).
//

import Testing
import Foundation
@testable import Threshold

@MainActor
@Suite(.serialized)
struct MusicCueSceneSetTests {

    private static let defaultsKeys = [
        "AnimationManager.musicCueSceneSets",
        "AnimationManager.activeMusicCueSceneSetID",
        "AnimationManager.musicCueSceneGroupIDs",
        "AnimationManager.musicCueSceneSources",
        "AnimationManager.musicCueSceneSwitchEnabled"
    ]

    private func withCleanDefaults(_ body: () throws -> Void) rethrows {
        for key in Self.defaultsKeys { UserDefaults.standard.removeObject(forKey: key) }
        defer {
            for key in Self.defaultsKeys { UserDefaults.standard.removeObject(forKey: key) }
        }
        try body()
    }

    // MARK: Model

    @Test("Scene set round-trips through Codable, including the attached song")
    func codableRoundTrip() throws {
        let animationID = UUID()
        let staticID = UUID()
        let song = SongAttachment(
            trackID: UnifiedTrackID(serviceID: "appleMusic", nativeID: "12345"),
            title: "Silent Shout",
            artist: "The Knife"
        )
        let original = MusicCueSceneSet(
            name: "Drop Set",
            targetIDs: [
                MusicCueSceneTarget.storageID(kind: .animation, sourceID: animationID),
                MusicCueSceneTarget.storageID(kind: .staticScene, sourceID: staticID)
            ],
            attachedSong: song
        )

        let data = try JSONEncoder().encode([original])
        let decoded = try JSONDecoder().decode([MusicCueSceneSet].self, from: data)
        #expect(decoded == [original])
    }

    @Test("Decoding normalizes pre-release UUID-only target ids as animations")
    func decodeNormalizesLegacyTargetIDs() throws {
        let legacyID = UUID()
        let json = """
        [{"id":"\(UUID().uuidString)","name":"Old","targetIDs":["\(legacyID.uuidString)","garbage"]}]
        """
        let decoded = try JSONDecoder().decode([MusicCueSceneSet].self, from: Data(json.utf8))
        let expected = MusicCueSceneTarget.storageID(kind: .animation, sourceID: legacyID)
        #expect(decoded.first?.targetIDs == [expected])
        #expect(decoded.first?.attachedSong == nil)
    }

    @Test("Legacy single-group migration produces one set, or none when empty")
    func legacyGroupMigration() {
        #expect(MusicCueSceneSet.migratingLegacyGroup(rawTargetIDs: []).isEmpty)
        #expect(MusicCueSceneSet.migratingLegacyGroup(rawTargetIDs: ["not-an-id"]).isEmpty)

        let animationID = UUID()
        let migrated = MusicCueSceneSet.migratingLegacyGroup(
            rawTargetIDs: [animationID.uuidString]
        )
        #expect(migrated.count == 1)
        #expect(migrated.first?.targetIDs ==
                [MusicCueSceneTarget.storageID(kind: .animation, sourceID: animationID)])
    }

    // MARK: Manager

    @Test("A stored legacy group becomes the initial active set")
    func managerMigratesLegacyGroup() {
        withCleanDefaults {
            let animationID = UUID()
            UserDefaults.standard.set(
                [animationID.uuidString],
                forKey: "AnimationManager.musicCueSceneGroupIDs"
            )

            let manager = AnimationManager()
            #expect(manager.musicCueSceneSets.count == 1)
            #expect(manager.activeMusicCueSceneSetID == manager.musicCueSceneSets.first?.id)
            #expect(manager.musicCueSceneGroupTargetIDs ==
                    [MusicCueSceneTarget.storageID(kind: .animation, sourceID: animationID)])
        }
    }

    @Test("Set management: create, activate, rename, edit membership, delete")
    func managerSetManagement() {
        withCleanDefaults {
            let manager = AnimationManager()
            #expect(manager.musicCueSceneSets.isEmpty)
            #expect(manager.musicCueSceneGroupTargetIDs.isEmpty)

            let first = manager.createMusicCueSceneSet()
            let second = manager.createMusicCueSceneSet(named: "Encore")
            #expect(manager.musicCueSceneSets.count == 2)
            // Creating a set makes it active.
            #expect(manager.activeMusicCueSceneSetID == second.id)

            let target = MusicCueSceneTarget(
                kind: .staticScene,
                sourceID: UUID(),
                name: "Menger Sphere",
                detail: "Static Scene"
            )
            manager.setMusicCueTarget(target, isSelected: true, in: second.id)
            #expect(manager.isMusicCueTargetSelected(target, in: second.id))
            #expect(manager.musicCueSceneGroupTargetIDs == [target.id])
            #expect(!manager.isMusicCueTargetSelected(target, in: first.id))

            // The pool follows the active set.
            manager.activateMusicCueSceneSet(first.id)
            #expect(manager.musicCueSceneGroupTargetIDs.isEmpty)

            manager.renameMusicCueSceneSet(first.id, to: "  Warmup  ")
            #expect(manager.musicCueSceneSet(id: first.id)?.name == "Warmup")
            manager.renameMusicCueSceneSet(first.id, to: "   ")
            #expect(manager.musicCueSceneSet(id: first.id)?.name == "Warmup")

            // Deleting the active set falls back to the first remaining set.
            manager.deleteMusicCueSceneSet(first.id)
            #expect(manager.activeMusicCueSceneSetID == second.id)
            #expect(manager.musicCueSceneGroupTargetIDs == [target.id])

            // Persisted state reloads into a fresh manager.
            let reloaded = AnimationManager()
            #expect(reloaded.musicCueSceneSets == manager.musicCueSceneSets)
            #expect(reloaded.activeMusicCueSceneSetID == second.id)
        }
    }

    @Test("Attaching a song to a set persists and detaches cleanly")
    func managerSongAttachment() {
        withCleanDefaults {
            let manager = AnimationManager()
            let set = manager.createMusicCueSceneSet(named: "Night Drive")
            let song = SongAttachment(
                trackID: UnifiedTrackID(serviceID: "appleMusic", nativeID: "999"),
                title: "Track",
                artist: "Artist"
            )

            manager.setAttachedSong(song, forMusicCueSceneSet: set.id)
            #expect(manager.musicCueSceneSet(id: set.id)?.attachedSong == song)

            let reloaded = AnimationManager()
            #expect(reloaded.musicCueSceneSet(id: set.id)?.attachedSong == song)

            manager.setAttachedSong(nil, forMusicCueSceneSet: set.id)
            #expect(manager.musicCueSceneSet(id: set.id)?.attachedSong == nil)
        }
    }

    @Test("Starting a set with a song activates it, enables cue advance, and plays")
    func managerStartSetPlaysAttachedSong() {
        withCleanDefaults {
            let manager = AnimationManager()
            let idle = manager.createMusicCueSceneSet(named: "Idle")
            let show = manager.createMusicCueSceneSet(named: "Show")
            let song = SongAttachment(
                trackID: UnifiedTrackID(serviceID: "appleMusic", nativeID: "1"),
                title: "Opener",
                artist: "Artist"
            )
            manager.setAttachedSong(song, forMusicCueSceneSet: show.id)
            manager.activateMusicCueSceneSet(idle.id)
            manager.musicCueSceneSwitchEnabled = false

            var played: SongAttachment?
            manager.playSongHandler = { played = $0 }

            manager.startMusicCueSceneSet(show.id)
            #expect(manager.activeMusicCueSceneSetID == show.id)
            #expect(manager.musicCueSceneSwitchEnabled)
            #expect(manager.isMusicCueSceneSourceEnabled(.configuredGroup))
            #expect(played == song)

            // A set without a song only activates; playback state is untouched.
            played = nil
            manager.startMusicCueSceneSet(idle.id)
            #expect(manager.activeMusicCueSceneSetID == idle.id)
            #expect(played == nil)
        }
    }
}
