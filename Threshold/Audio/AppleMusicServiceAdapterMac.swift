#if os(macOS)
import SwiftUI

@MainActor
final class AppleMusicServiceAdapter: MusicServiceProvider {
    let manager: AppleMusicManager

    init(manager: AppleMusicManager) {
        self.manager = manager
    }

    let serviceID = "appleMusic"
    let displayName = "Apple Music"
    let iconName = "apple.logo"
    var accentColor: Color { .pink }

    var connectionStatus: MusicServiceConnectionStatus {
        .error("Apple Music library playback is unavailable in the macOS build.")
    }

    func connect() {
        manager.requestAuthorization()
    }

    func disconnect() {
        manager.stopMonitoring()
    }

    var nowPlaying: UnifiedTrack? { nil }
    var isPlaying: Bool { manager.isPlaying }
    var progressFraction: Float { manager.progressFraction }
    var currentTimeString: String { manager.currentTimeString }
    var totalTimeString: String { manager.totalTimeString }

    func togglePlayPause() async { manager.togglePlayPause() }
    func next() async { manager.nextTrack() }
    func previous() async { manager.previousTrack() }
    func seek(fraction: Float) async { manager.updateFrame() }

    var librarySongs: [UnifiedTrack] {
        manager.librarySongs.map { song in
            UnifiedTrack(
                id: String(song.id),
                serviceID: serviceID,
                title: song.title,
                artist: song.artist,
                album: song.album,
                artworkURL: nil,
                durationSeconds: 0
            )
        }
    }

    var libraryPlaylists: [UnifiedPlaylist] {
        manager.libraryPlaylists.map { playlist in
            UnifiedPlaylist(
                id: String(playlist.id),
                serviceID: serviceID,
                name: playlist.name,
                trackCount: playlist.trackCount,
                artworkURL: nil,
                ownerName: nil
            )
        }
    }

    var libraryAlbums: [UnifiedAlbum] {
        manager.libraryAlbums.map { album in
            UnifiedAlbum(
                id: String(album.id),
                serviceID: serviceID,
                title: album.title,
                artist: album.artist,
                trackCount: album.trackCount,
                artworkURL: nil
            )
        }
    }

    var isLibraryLoading: Bool { manager.libraryLoading }
    var libraryError: String? { manager.libraryErrorMessage }

    func refreshLibrary() async { manager.refreshLibrary() }
    func playSong(_ track: UnifiedTrack) async { manager.playSong(id: UInt64(track.id) ?? 0) }
    func playSongByNativeID(_ nativeID: String) async -> Bool { false }
    func playPlaylist(_ playlist: UnifiedPlaylist, shuffle: Bool) async { manager.playPlaylist(id: UInt64(playlist.id) ?? 0, shuffle: shuffle) }
    func playAlbum(_ album: UnifiedAlbum, shuffle: Bool) async { manager.playAlbum(id: UInt64(album.id) ?? 0, shuffle: shuffle) }
    func fetchPlaylistTracks(_ playlist: UnifiedPlaylist) async -> [UnifiedTrack] { [] }
    func searchTrack(title: String, artist: String) async -> UnifiedTrack? { nil }
    func createPlaylist(name: String, trackNativeIDs: [String]) async -> String? {
        await manager.createPlaylist(name: name, songIDs: trackNativeIDs.compactMap { UInt64($0) })
    }

    var bassLevel: Float { manager.bassLevel }
    var midLevel: Float { manager.midLevel }
    var trebleLevel: Float { manager.trebleLevel }
    var beatIntensity: Float { manager.beatIntensity }
    var overallLevel: Float { manager.overallLevel }

    func updateFrame() { manager.updateFrame() }
}
#endif