#if os(macOS) || os(iOS)
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
        switch manager.authorizationStatus {
        case .authorized:
            return .connected
        case .denied:
            return .error("Access denied. Enable Apple Music access in System Settings.")
        case .restricted:
            return .error("Apple Music is restricted on this Mac.")
        case .notDetermined:
            return .disconnected
        @unknown default:
            return .disconnected
        }
    }

    func connect() {
        manager.requestAuthorization()
    }

    func disconnect() {
        manager.stopMonitoring()
    }

    var nowPlaying: UnifiedTrack? {
        guard !manager.nowPlayingTitle.isEmpty else { return nil }
        return UnifiedTrack(
            id: manager.nowPlayingID ?? UUID().uuidString,
            serviceID: serviceID,
            title: manager.nowPlayingTitle,
            artist: manager.nowPlayingArtist,
            album: manager.nowPlayingAlbum,
            artworkURL: nil,
            durationSeconds: manager.durationSeconds
        )
    }

    var isPlaying: Bool { manager.isPlaying }
    var progressFraction: Float { manager.progressFraction }
    var currentTimeString: String { manager.currentTimeString }
    var totalTimeString: String { manager.totalTimeString }

    func togglePlayPause() async { await manager.togglePlayPause() }
    func next() async { await manager.nextTrack() }
    func previous() async { await manager.previousTrack() }
    func seek(fraction: Float) async { manager.seek(fraction: fraction) }

    var librarySongs: [UnifiedTrack] {
        manager.librarySongs.map { song in
            UnifiedTrack(
                id: song.id,
                serviceID: serviceID,
                title: song.title,
                artist: song.artist,
                album: song.album,
                artworkURL: nil,
                durationSeconds: song.durationSeconds
            )
        }
    }

    var libraryPlaylists: [UnifiedPlaylist] {
        manager.libraryPlaylists.map { playlist in
            UnifiedPlaylist(
                id: playlist.id,
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
                id: album.id,
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

    func refreshLibrary() async { await manager.refreshLibrary() }

    func playSong(_ track: UnifiedTrack) async {
        await manager.playSong(id: track.id)
    }

    func playSongByNativeID(_ nativeID: String) async -> Bool {
        if !manager.librarySongs.contains(where: { $0.id == nativeID }) {
            await manager.refreshLibrary()
        }

        guard manager.librarySongs.contains(where: { $0.id == nativeID }) else {
            return false
        }

        await manager.playSong(id: nativeID)
        return true
    }

    func playPlaylist(_ playlist: UnifiedPlaylist, shuffle: Bool) async {
        await manager.playPlaylist(id: playlist.id, shuffle: shuffle)
    }

    func playAlbum(_ album: UnifiedAlbum, shuffle: Bool) async {
        await manager.playAlbum(id: album.id, shuffle: shuffle)
    }

    func fetchPlaylistTracks(_ playlist: UnifiedPlaylist) async -> [UnifiedTrack] {
        await manager.playlistTracks(id: playlist.id).map { track in
            UnifiedTrack(
                id: track.id,
                serviceID: serviceID,
                title: track.title,
                artist: track.artist,
                album: track.album,
                artworkURL: nil,
                durationSeconds: track.durationSeconds
            )
        }
    }

    func searchTrack(title: String, artist: String) async -> UnifiedTrack? {
        if manager.librarySongs.isEmpty, manager.isAuthorized {
            await manager.refreshLibrary()
        }

        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        let bestMatch = manager.librarySongs.first {
            $0.title.lowercased() == normalizedTitle && $0.artist.lowercased() == normalizedArtist
        } ?? manager.librarySongs.first {
            $0.title.lowercased().contains(normalizedTitle) && $0.artist.lowercased().contains(normalizedArtist)
        }

        guard let bestMatch else { return nil }

        return UnifiedTrack(
            id: bestMatch.id,
            serviceID: serviceID,
            title: bestMatch.title,
            artist: bestMatch.artist,
            album: bestMatch.album,
            artworkURL: nil,
            durationSeconds: bestMatch.durationSeconds
        )
    }

    func createPlaylist(name: String, trackNativeIDs: [String]) async -> String? {
        await manager.createPlaylist(name: name, songIDs: trackNativeIDs)
    }

    var bassLevel: Float { manager.bassLevel }
    var midLevel: Float { manager.midLevel }
    var trebleLevel: Float { manager.trebleLevel }
    var beatIntensity: Float { manager.beatIntensity }
    var overallLevel: Float { manager.overallLevel }

    func updateFrame() { manager.updateFrame() }
}
#endif