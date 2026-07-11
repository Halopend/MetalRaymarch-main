import SwiftUI
#if !os(macOS)
import MediaPlayer
#endif

/// Adapts the platform AppleMusicManager to the shared music-service model.
/// Library mapping lives once; only native transport, lookup, and search differ.
@MainActor
final class AppleMusicServiceAdapter: MusicServiceProvider {
    let manager: AppleMusicManager

    init(manager: AppleMusicManager) {
        self.manager = manager
    }

    var connectionStatus: MusicServiceConnectionStatus {
        switch manager.authorizationStatus {
        case .authorized:
            return .connected
        case .denied:
            #if os(macOS)
            return .error("Access denied. Enable Apple Music access in System Settings.")
            #else
            return .error("Access denied. Enable Apple Music access in Settings.")
            #endif
        case .restricted:
            #if os(macOS)
            return .error("Apple Music is restricted on this Mac.")
            #else
            return .error("Apple Music is restricted on this device.")
            #endif
        case .notDetermined:
            return .disconnected
        @unknown default:
            return .disconnected
        }
    }

    func connect() {
        manager.requestAuthorization()
    }

    var nowPlaying: UnifiedTrack? {
        guard !manager.nowPlayingTitle.isEmpty else { return nil }
        #if os(macOS)
        let id = manager.nowPlayingID ?? UUID().uuidString
        let album = manager.nowPlayingAlbum
        #else
        let item = MPMusicPlayerController.systemMusicPlayer.nowPlayingItem
        let id = item.map { String($0.persistentID) } ?? UUID().uuidString
        let album = item?.albumTitle ?? ""
        #endif
        return makeTrack(
            id: id,
            title: manager.nowPlayingTitle,
            artist: manager.nowPlayingArtist,
            album: album,
            durationSeconds: manager.durationSeconds
        )
    }

    func togglePlayPause() async {
        #if os(macOS)
        await manager.togglePlayPause()
        #else
        manager.togglePlayPause()
        #endif
    }

    func next() async {
        #if os(macOS)
        await manager.nextTrack()
        #else
        manager.nextTrack()
        #endif
    }

    func previous() async {
        #if os(macOS)
        await manager.previousTrack()
        #else
        manager.previousTrack()
        #endif
    }

    func seek(fraction: Float) async {
        #if os(macOS)
        manager.seek(fraction: fraction)
        #else
        let player = MPMusicPlayerController.systemMusicPlayer
        player.currentPlaybackTime = Double(fraction) * manager.durationSeconds
        manager.updateFrame()
        #endif
    }

    var librarySongs: [UnifiedTrack] {
        manager.librarySongs.map { song in
            makeTrack(
                id: String(song.id),
                title: song.title,
                artist: song.artist,
                album: song.album,
                durationSeconds: songDuration(song)
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

    func refreshLibrary() async {
        #if os(macOS)
        await manager.refreshLibrary()
        #else
        manager.refreshLibrary()
        #endif
    }

    func playSong(_ track: UnifiedTrack) async {
        #if os(macOS)
        await manager.playSong(id: track.id)
        #else
        guard let id = UInt64(track.id) else { return }
        manager.playSong(id: id)
        #endif
    }

    func playSongByNativeID(_ nativeID: String) async -> Bool {
        #if os(macOS)
        if !manager.librarySongs.contains(where: { $0.id == nativeID }) {
            await manager.refreshLibrary()
        }
        guard manager.librarySongs.contains(where: { $0.id == nativeID }) else { return false }
        await manager.playSong(id: nativeID)
        #else
        guard let id = UInt64(nativeID) else { return false }
        manager.playSong(id: id)
        #endif
        return true
    }

    func playPlaylist(_ playlist: UnifiedPlaylist, shuffle: Bool) async {
        #if os(macOS)
        await manager.playPlaylist(id: playlist.id, shuffle: shuffle)
        #else
        guard let id = UInt64(playlist.id) else { return }
        manager.playPlaylist(id: id, shuffle: shuffle)
        #endif
    }

    func playAlbum(_ album: UnifiedAlbum, shuffle: Bool) async {
        #if os(macOS)
        await manager.playAlbum(id: album.id, shuffle: shuffle)
        #else
        guard let id = UInt64(album.id) else { return }
        manager.playAlbum(id: id, shuffle: shuffle)
        #endif
    }

    func fetchPlaylistTracks(_ playlist: UnifiedPlaylist) async -> [UnifiedTrack] {
        #if os(macOS)
        let tracks = await manager.playlistTracks(id: playlist.id)
        #else
        guard let id = UInt64(playlist.id) else { return [] }
        let tracks = manager.playlistTracks(id: id)
        #endif
        return tracks.map { track in
            makeTrack(
                id: String(track.id),
                title: track.title,
                artist: track.artist,
                album: track.album,
                durationSeconds: songDuration(track)
            )
        }
    }

    func searchTrack(title: String, artist: String) async -> UnifiedTrack? {
        #if os(macOS)
        if manager.librarySongs.isEmpty, manager.isAuthorized {
            await manager.refreshLibrary()
        }
        let normalizedTitle = normalized(title)
        let normalizedArtist = normalized(artist)
        let match = manager.librarySongs.first {
            normalized($0.title) == normalizedTitle && normalized($0.artist) == normalizedArtist
        } ?? manager.librarySongs.first {
            normalized($0.title).contains(normalizedTitle) && normalized($0.artist).contains(normalizedArtist)
        }
        guard let match else { return nil }
        return makeTrack(
            id: match.id,
            title: match.title,
            artist: match.artist,
            album: match.album,
            durationSeconds: match.durationSeconds
        )
        #else
        guard connectionStatus.isConnected else { return nil }
        let query = MPMediaQuery.songs()
        query.addFilterPredicate(MPMediaPropertyPredicate(
            value: title,
            forProperty: MPMediaItemPropertyTitle,
            comparisonType: .contains
        ))
        guard let items = query.items, !items.isEmpty else { return nil }
        let normalizedArtist = normalized(artist)
        let match = items.first { normalized($0.artist ?? "").contains(normalizedArtist) } ?? items[0]
        return makeTrack(
            id: String(match.persistentID),
            title: match.title ?? title,
            artist: match.artist ?? artist,
            album: match.albumTitle ?? "",
            durationSeconds: match.playbackDuration
        )
        #endif
    }

    func createPlaylist(name: String, trackNativeIDs: [String]) async -> String? {
        #if os(macOS)
        return await manager.createPlaylist(name: name, songIDs: trackNativeIDs)
        #else
        return await manager.createPlaylist(name: name, songIDs: trackNativeIDs.compactMap(UInt64.init))
        #endif
    }

    private func makeTrack(
        id: String,
        title: String,
        artist: String,
        album: String,
        durationSeconds: Double
    ) -> UnifiedTrack {
        UnifiedTrack(
            id: id,
            serviceID: serviceID,
            title: title,
            artist: artist,
            album: album,
            artworkURL: nil,
            durationSeconds: durationSeconds
        )
    }

    private func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    #if os(macOS)
    private func songDuration(_ song: AppleMusicManager.LibrarySong) -> Double {
        song.durationSeconds
    }
    #else
    private func songDuration(_ song: AppleMusicManager.LibrarySong) -> Double {
        0
    }
    #endif
}
