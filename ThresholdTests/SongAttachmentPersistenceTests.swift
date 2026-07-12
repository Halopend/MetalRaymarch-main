//
//  SongAttachmentPersistenceTests.swift
//  ThresholdTests
//
//  Guards the lossless service-source persistence contract for animation
//  attachments. A scene must not change providers just because this build does
//  not have that provider installed.
//

import Foundation
import Testing
@testable import Threshold

@Suite("Song attachment service-source persistence")
struct SongAttachmentPersistenceTests {

    @Test("Current Spotify attachments round-trip as Spotify")
    func spotifyAttachmentRoundTrips() throws {
        let original = SongAttachment(
            trackID: UnifiedTrackID(
                serviceID: "spotify",
                nativeID: "spotify:track:6rqhFgbbKwnb9MLmUQDhG6"
            ),
            title: "Song",
            artist: "Artist"
        )

        #expect(original.source == .spotify)
        #expect(original.spotifyURI == "spotify:track:6rqhFgbbKwnb9MLmUQDhG6")

        let decoded = try JSONDecoder().decode(
            SongAttachment.self,
            from: JSONEncoder().encode(original)
        )
        #expect(decoded == original)
    }

    @Test("Unknown provider IDs remain opaque through source and attachment persistence")
    func unknownProviderRoundTrips() throws {
        let original = SongAttachment(
            trackID: UnifiedTrackID(serviceID: "tidal", nativeID: "track-123"),
            title: "Song",
            artist: "Artist"
        )

        #expect(original.source == .other("tidal"))
        #expect(original.source.serviceID == "tidal")
        #expect(original.source.rawValue == "tidal")

        let encodedSource = try JSONEncoder().encode(original.source)
        #expect(try JSONDecoder().decode(SongSource.self, from: encodedSource) == .other("tidal"))

        let decoded = try JSONDecoder().decode(
            SongAttachment.self,
            from: JSONEncoder().encode(original)
        )
        #expect(decoded == original)
        #expect(decoded.trackID.serviceID == "tidal")
    }

    @Test("Legacy Spotify URI scenes migrate without becoming Apple Music")
    func legacySpotifyAttachmentMigrates() throws {
        let data = Data(
            """
            {
              "source": "spotify",
              "title": "Song",
              "artist": "Artist",
              "spotifyURI": "spotify:track:6rqhFgbbKwnb9MLmUQDhG6"
            }
            """.utf8
        )

        let attachment = try JSONDecoder().decode(SongAttachment.self, from: data)

        #expect(attachment.source == .spotify)
        #expect(attachment.trackIDs == [
            UnifiedTrackID(
                serviceID: "spotify",
                nativeID: "spotify:track:6rqhFgbbKwnb9MLmUQDhG6"
            )
        ])
        #expect(attachment.spotifyURI == "spotify:track:6rqhFgbbKwnb9MLmUQDhG6")
    }

    @Test("Existing Apple Music legacy scenes retain their source and ID")
    func legacyAppleMusicAttachmentStillDecodes() throws {
        let data = Data(
            """
            {
              "source": "appleMusic",
              "title": "Song",
              "artist": "Artist",
              "appleMusicID": "1234567890"
            }
            """.utf8
        )

        let attachment = try JSONDecoder().decode(SongAttachment.self, from: data)

        #expect(attachment.source == .appleMusic)
        #expect(attachment.trackIDs == [
            UnifiedTrackID(serviceID: "appleMusic", nativeID: "1234567890")
        ])
        #expect(attachment.appleMusicID == "1234567890")
    }

    @Test("A missing source is inferred from a generic primary ID")
    func missingSourceUsesPrimaryTrackService() throws {
        let data = Data(
            """
            {
              "title": "Song",
              "artist": "Artist",
              "trackID": "spotify:spotify:track:6rqhFgbbKwnb9MLmUQDhG6"
            }
            """.utf8
        )

        let attachment = try JSONDecoder().decode(SongAttachment.self, from: data)

        #expect(attachment.source == .spotify)
        #expect(attachment.trackID.serviceID == "spotify")
    }
}
